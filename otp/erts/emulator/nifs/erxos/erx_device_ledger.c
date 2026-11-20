/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The ledger of a queue's DMA memory: see erx_device_ledger.h.
 *
 * The ERX_DMA_SEED_* macros plant the faults test/host/erx_device_ledger_test.rb shows its
 * harness catches (docs/design-device-dma.md, Verification, The check).
 */

#include <strings.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_rules.h"

#ifdef ERX_DMA_SEED_NO_GRANULE_TEST
#define SEED_NO_GRANULE_TEST	true
#else
#define SEED_NO_GRANULE_TEST	false
#endif
#ifdef ERX_DMA_SEED_HOLD_WHILE_HELD
#define SEED_HOLD_WHILE_HELD	true
#else
#define SEED_HOLD_WHILE_HELD	false
#endif
#ifdef ERX_DMA_SEED_RELEASE_TWICE
#define SEED_RELEASE_TWICE	true
#else
#define SEED_RELEASE_TWICE	false
#endif
#ifdef ERX_DMA_SEED_ANY_REGION
#define SEED_ANY_REGION		true
#else
#define SEED_ANY_REGION		false
#endif
#ifdef ERX_DMA_SEED_REGION_MEETS_QUEUE
#define SEED_REGION_MEETS_QUEUE	true
#else
#define SEED_REGION_MEETS_QUEUE	false
#endif

static bool
power_of_two(uint64_t value)
{
	return (value != 0 && (value & (value - 1)) == 0);
}

static uint64_t
round_up(uint64_t value, uint64_t granule)
{
	return ((value + granule - 1) & ~(granule - 1));
}

static bool
same_place(erx_dma_place_t a, erx_dma_place_t b)
{
	return (a.table == b.table && a.index == b.index);
}

/* Where a ring starts at or after `end`: on a granule, and on the ring's own alignment (Virtio 1.2, 2.7). */
static uint64_t
ring_start(uint64_t end, uint32_t granule, uint32_t align)
{
	return (round_up(end, granule > align ? granule : align));
}

bool
erx_dma_layout_split_ring(uint32_t size, uint32_t buffer_size, uint32_t granule, uint64_t memory_size,
    uint64_t device_base, uint32_t address_bits, erx_dma_layout_t *layout)
{
	/* Each ring is its head, `size` entries and a trailing event word this driver leaves unused. */
	const uint64_t avail_bytes = ERX_VIRTQ_RING_HEAD_SIZE + (uint64_t)size * sizeof(uint16_t) + sizeof(uint16_t);
	const uint64_t used_bytes = ERX_VIRTQ_RING_HEAD_SIZE + (uint64_t)size * ERX_VIRTQ_USED_ELEM_SIZE +
	    sizeof(uint16_t);
	uint64_t avail_offset, used_offset, pool_offset;

	if (!power_of_two(size) || size > ERX_DEVICE_QUEUE_SIZE_MAX || !power_of_two(granule) ||
	    granule > ERX_DEVICE_GRANULE_MAX || buffer_size == 0 || buffer_size > ERX_DEVICE_BUFFER_MAX ||
	    device_base % ERX_VIRTQ_DESC_TABLE_ALIGN != 0 || device_base % ERX_VIRTQ_AVAIL_RING_ALIGN != 0 ||
	    device_base % ERX_VIRTQ_USED_RING_ALIGN != 0)
		return (false);
	avail_offset = ring_start((uint64_t)size * ERX_VIRTQ_DESC_SIZE, granule, ERX_VIRTQ_AVAIL_RING_ALIGN);
	used_offset = ring_start(avail_offset + avail_bytes, granule, ERX_VIRTQ_USED_RING_ALIGN);
	pool_offset = round_up(used_offset + used_bytes, granule);
	*layout = (erx_dma_layout_t){
		.memory_size = memory_size,
		.device_base = device_base,
		.address_bits = address_bits,
		.granule = granule,
		.table_count = 3,
		.tables = {
			{ .structure = ERX_STRUCTURE_VIRTQ_DESC, .placing = ERX_DMA_PLACED_FREE,
			  .region = 0, .region_length = avail_offset, .first = 0,
			  .count = size, .stride = ERX_VIRTQ_DESC_SIZE },
			{ .structure = ERX_STRUCTURE_VIRTQ_AVAIL, .placing = ERX_DMA_PLACED_IN_ORDER,
			  .region = avail_offset, .region_length = used_offset - avail_offset,
			  .first = avail_offset + ERX_VIRTQ_RING_HEAD_SIZE, .count = size, .stride = sizeof(uint16_t) },
			{ .structure = ERX_STRUCTURE_VIRTQ_USED,
			  .region = used_offset, .region_length = pool_offset - used_offset,
			  .first = used_offset + ERX_VIRTQ_RING_HEAD_SIZE, .count = size, .stride = ERX_VIRTQ_USED_ELEM_SIZE },
		},
		.pool = { .first = pool_offset, .count = size, .size = buffer_size,
			  .stride = (uint32_t)round_up(buffer_size, granule) },
	};
	return (true);
}

/* Whether the device writes the table's structure, as abi/formats declares: its reports. */
static bool
device_writes(const erx_dma_layout_t *layout, uint32_t table)
{
	return (erx_structure_device_writes(layout->tables[table].structure));
}

/*
 * One region of the install's check: `length` bytes from `offset`, whole granules, not before
 * `*end`, the end of the region before it, and inside the memory. Moves `*end` past it.
 */
static bool
region_valid(const erx_dma_layout_t *layout, uint64_t offset, uint64_t length, uint64_t *end)
{
	const uint64_t granule_mask = (uint64_t)layout->granule - 1;
	uint64_t region_end;

	if (length == 0 || offset < *end || __builtin_add_overflow(offset, length, &region_end) ||
	    region_end > layout->memory_size)
		return (false);
	if (!SEED_NO_GRANULE_TEST && ((offset | length) & granule_mask) != 0)
		return (false);
	*end = region_end;
	return (true);
}

static bool
table_valid(const erx_dma_layout_t *layout, uint32_t index, uint64_t *end)
{
	const erx_dma_table_t *table = &layout->tables[index];

	if (!region_valid(layout, table->region, table->region_length, end) || table->structure == ERX_REFERS_DATA ||
	    table->count == 0 || table->stride == 0 || table->first < table->region ||
	    !erx_dma_inside(table->first - table->region, (uint64_t)table->count * table->stride, table->region_length))
		return (false);
	for (uint32_t other = 0; other < index; other++) {
		if (layout->tables[other].structure == table->structure)
			return (false);
	}
	return (true);
}

/* The widest device address the form can hold. */
static uint64_t
widest_address(const erx_dma_layout_t *layout)
{
	return (layout->address_bits == 64 ? UINT64_MAX : (UINT64_C(1) << layout->address_bits) - 1);
}

static bool
layout_valid(const erx_dma_layout_t *layout)
{
	const erx_dma_pool_t *pool = &layout->pool;
	const uint64_t widest = widest_address(layout);
	uint64_t end = 0, last;

	if (!power_of_two(layout->granule) || layout->address_bits == 0 || layout->address_bits > 64 ||
	    layout->table_count > ERX_DMA_TABLES_MAX)
		return (false);
	for (uint32_t index = 0; index < layout->table_count; index++) {
		if (!table_valid(layout, index, &end))
			return (false);
	}
	/* Each buffer is a region of its own, one stride long, so whole granules make them disjoint. */
	if (pool->count == 0 || pool->size == 0 || pool->size > pool->stride ||
	    (!SEED_NO_GRANULE_TEST && (pool->stride & (layout->granule - 1)) != 0) ||
	    !region_valid(layout, pool->first, (uint64_t)pool->count * pool->stride, &end))
		return (false);
	return (!__builtin_add_overflow(layout->device_base, end - 1, &last) && last <= widest);
}

/*
 * Whether `region`'s device addresses and the queue's memory share one, from whichever starts
 * first, so no end is summed.
 */
static bool
meets_the_queue(const erx_dma_layout_t *layout, erx_dma_persistent_region_t region)
{
	if (region.address >= layout->device_base)
		return (region.address - layout->device_base < layout->memory_size);
	return (layout->device_base - region.address < region.length);
}

/* The longest region an entry states: its length field's width, as the generated layout gives it. */
static const uint64_t longest_region = UINT64_MAX >> (64 - 8 * sizeof(((erx_virtio_gpu_mem_entry_t *)NULL)->length));

/*
 * Whether a region entry in a queue of `layout` may name `region`: a length an entry states, and
 * its range below the form's address width and apart from the queue's memory, which no entry
 * may point the device into.
 */
static bool
region_fits_queue(const erx_dma_layout_t *layout, erx_dma_persistent_region_t region)
{
	uint64_t last;

	return (region.length != 0 && region.length <= longest_region &&
	    !__builtin_add_overflow(region.address, region.length - 1, &last) && last <= widest_address(layout) &&
	    (SEED_REGION_MEETS_QUEUE || !meets_the_queue(layout, region)));
}

bool
erx_dma_ledger_make(erx_dma_ledger_t *ledger, const erx_dma_layout_t *layout, const erx_dma_regions_t *regions)
{
	if (!layout_valid(layout))
		return (false);
	bzero(ledger, sizeof(*ledger));
	ledger->layout = *layout;
	ledger->regions = regions;
	return (true);
}

void
erx_dma_ledger_reset(erx_dma_ledger_t *ledger)
{
	ledger->live = 0;
	bzero(ledger->positions, sizeof(ledger->positions));
	bzero(ledger->acquired, sizeof(ledger->acquired));
}

/* The region of `regions` named `name`, or NULL. */
static const erx_dma_persistent_region_t *
region_named(const erx_dma_regions_t *regions, uint32_t name)
{
	for (uint32_t index = 0; index < regions->count; index++) {
		if (regions->regions[index].name == name)
			return (&regions->regions[index]);
	}
	return (NULL);
}

bool
erx_dma_regions_add(erx_dma_regions_t *regions, erx_dma_persistent_region_t region)
{
	const erx_dma_persistent_region_t *const held = region_named(regions, region.name);

	/* erx_device_region gives the same region again for the same request, so a repeat adds nothing. */
	if (held != NULL)
		return (held->address == region.address && held->length == region.length);
	if (regions->count == ERX_DEVICE_REGIONS_MAX || region.length == 0 || region.length > longest_region)
		return (false);
	regions->regions[regions->count++] = region;
	return (true);
}

const erx_dma_persistent_region_t *
erx_dma_ledger_region(const erx_dma_ledger_t *ledger, uint32_t name)
{
	const erx_dma_persistent_region_t *const region = SEED_ANY_REGION && ledger->regions->count > 0 ?
	    &ledger->regions->regions[0] : region_named(ledger->regions, name);

	return (region != NULL && region_fits_queue(&ledger->layout, *region) ? region : NULL);
}

const erx_dma_layout_t *
erx_dma_ledger_layout(const erx_dma_ledger_t *ledger)
{
	return (&ledger->layout);
}

int
erx_dma_ledger_table(const erx_dma_ledger_t *ledger, uint32_t structure)
{
	for (uint32_t index = 0; index < ledger->layout.table_count; index++) {
		if (ledger->layout.tables[index].structure == structure)
			return ((int)index);
	}
	return (-1);
}

erx_dma_position_t
erx_dma_ledger_position(const erx_dma_ledger_t *ledger, uint32_t table)
{
	return (table < ledger->layout.table_count ? ledger->positions[table] : (erx_dma_position_t){ 0, 0 });
}

bool
erx_dma_ledger_record_held(const erx_dma_ledger_t *ledger, erx_dma_place_t place)
{
	for (uint32_t live = 0; live < ledger->live; live++) {
		const erx_dma_holding_t *holding = &ledger->holdings[live];

		for (uint32_t record = 0; record < holding->record_count; record++) {
			if (same_place(holding->records[record], place))
				return (true);
		}
	}
	return (false);
}

bool
erx_dma_ledger_buffer_held(const erx_dma_ledger_t *ledger, uint32_t buffer)
{
	for (uint32_t live = 0; live < ledger->live; live++) {
		const erx_dma_holding_t *holding = &ledger->holdings[live];

		for (uint32_t index = 0; index < holding->buffer_count; index++) {
			if (holding->buffers[index] == buffer)
				return (true);
		}
	}
	return (false);
}

erx_dma_writer_t
erx_dma_ledger_buffer_writer(const erx_dma_ledger_t *ledger, uint32_t buffer)
{
	return (erx_dma_ledger_buffer_held(ledger, buffer) ? ERX_DMA_DEVICE : ERX_DMA_CPU);
}

uint32_t
erx_dma_ledger_free_records(const erx_dma_ledger_t *ledger, uint32_t table)
{
	uint32_t held = 0;

	if (table >= ledger->layout.table_count)
		return (0);
	for (uint32_t live = 0; live < ledger->live; live++) {
		const erx_dma_holding_t *holding = &ledger->holdings[live];

		for (uint32_t record = 0; record < holding->record_count; record++)
			held += holding->records[record].table == table;
	}
	return (ledger->layout.tables[table].count - held);
}

uint32_t
erx_dma_ledger_live(const erx_dma_ledger_t *ledger)
{
	return (ledger->live);
}

bool
erx_dma_ledger_idle(const erx_dma_ledger_t *ledger)
{
	for (uint32_t table = 0; table < ERX_DMA_TABLES_MAX; table++) {
		if (ledger->positions[table].index != 0 || ledger->positions[table].lap != 0 ||
		    ledger->acquired[table] != 0)
			return (false);
	}
	return (ledger->live == 0);
}

static void
advance(erx_dma_ledger_t *ledger, uint32_t table, uint32_t records)
{
	erx_dma_position_t *position = &ledger->positions[table];

	position->index += records;
	if (position->index >= ledger->layout.tables[table].count) {
		position->index -= ledger->layout.tables[table].count;
		position->lap++;
	}
}

/*
 * Whether `holding` may begin, and how many records it takes of each table placed in order:
 * every record a table's that no holding holds, named once, not the device's, and, in a table
 * placed in order, the next one from its position; every buffer the pool's and unheld.
 */
static bool
holding_valid(const erx_dma_ledger_t *ledger, const erx_dma_holding_t *holding, uint32_t taken[ERX_DMA_TABLES_MAX])
{
	if (ledger->live == ERX_DMA_HOLDINGS_MAX)
		return (false);
	for (uint32_t record = 0; record < holding->record_count; record++) {
		const erx_dma_place_t place = holding->records[record];
		const erx_dma_table_t *table;

		if (place.table >= ledger->layout.table_count)
			return (false);
		table = &ledger->layout.tables[place.table];
		if (place.index >= table->count || device_writes(&ledger->layout, place.table) ||
		    (!SEED_HOLD_WHILE_HELD && erx_dma_ledger_record_held(ledger, place)))
			return (false);
		for (uint32_t earlier = 0; earlier < record; earlier++) {
			if (same_place(holding->records[earlier], place))
				return (false);
		}
		if (table->placing == ERX_DMA_PLACED_IN_ORDER) {
			/* Records named once and at most count of them, so the sum stays below 2 * count. */
			if (place.index != (ledger->positions[place.table].index + taken[place.table]) % table->count)
				return (false);
			taken[place.table]++;
		}
	}
	for (uint32_t index = 0; index < holding->buffer_count; index++) {
		const uint32_t buffer = holding->buffers[index];

		if (buffer >= ledger->layout.pool.count ||
		    (!SEED_HOLD_WHILE_HELD && erx_dma_ledger_buffer_held(ledger, buffer)))
			return (false);
	}
	return (true);
}

/*
 * The holding of `publication` at `records`, with the buffers its names reach. False when there
 * are more records or buffers than a holding holds.
 */
static bool
holding_of(const erx_dma_publication_t *publication, const erx_dma_place_t *records, uint32_t record_count,
    erx_dma_holding_t *holding)
{
	*holding = (erx_dma_holding_t){ .record_count = record_count };
	if (record_count == 0 || record_count > ERX_DMA_HELD_RECORDS_MAX)
		return (false);
	for (uint32_t record = 0; record < record_count; record++)
		holding->records[record] = records[record];
	return (erx_dma_publication_buffers(publication, holding->buffers, &holding->buffer_count));
}

bool
erx_dma_ledger_hold(erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication,
    const erx_dma_place_t *records, uint32_t record_count)
{
	uint32_t taken[ERX_DMA_TABLES_MAX] = { 0 };
	erx_dma_holding_t holding;

	if (!holding_of(publication, records, record_count, &holding) || !holding_valid(ledger, &holding, taken))
		return (false);
	ledger->holdings[ledger->live++] = holding;
	for (uint32_t table = 0; table < ledger->layout.table_count; table++)
		advance(ledger, table, taken[table]);
	return (true);
}

bool
erx_dma_ledger_acquire(erx_dma_ledger_t *ledger, uint32_t reports, uint32_t count)
{
	if (reports >= ledger->layout.table_count || !device_writes(&ledger->layout, reports) || count > ledger->live)
		return (false);
	ledger->acquired[reports] = count;
	return (true);
}

uint32_t
erx_dma_ledger_acquired(const erx_dma_ledger_t *ledger, uint32_t table)
{
	return (table < ledger->layout.table_count ? ledger->acquired[table] : 0);
}

const erx_dma_holding_t *
erx_dma_ledger_holding(const erx_dma_ledger_t *ledger, erx_dma_place_t head)
{
	for (uint32_t live = 0; live < ledger->live; live++) {
		if (same_place(ledger->holdings[live].records[0], head))
			return (&ledger->holdings[live]);
	}
	return (NULL);
}

bool
erx_dma_ledger_release_holding(erx_dma_ledger_t *ledger, uint32_t reports, const erx_dma_holding_t *holding)
{
	if (reports >= ledger->layout.table_count || !device_writes(&ledger->layout, reports) ||
	    ledger->acquired[reports] == 0)
		return (false);
	/* By equality alone: a pointer the ledger did not give compares equal to none of its holdings. */
	for (uint32_t live = 0; live < ledger->live; live++) {
		if (&ledger->holdings[live] == holding) {
			ledger->holdings[live] = ledger->holdings[--ledger->live];
			ledger->acquired[reports]--;
			advance(ledger, reports, 1);
			return (true);
		}
	}
	if (SEED_RELEASE_TWICE) {
		advance(ledger, reports, 1);
		return (true);
	}
	return (false);
}
