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
#ifdef ERX_DMA_SEED_BIND_BOUND_ENDPOINT
#define SEED_BIND_BOUND_ENDPOINT	true
#else
#define SEED_BIND_BOUND_ENDPOINT	false
#endif
#ifdef ERX_DMA_SEED_NO_STRIDE_TEST
#define SEED_NO_STRIDE_TEST	true
#else
#define SEED_NO_STRIDE_TEST	false
#endif
#ifdef ERX_DMA_SEED_RING_NO_LINK
#define SEED_RING_NO_LINK	true
#else
#define SEED_RING_NO_LINK	false
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
		.pool_count = 1,
		.pools = { { .first = pool_offset, .count = size, .size = buffer_size,
			  .stride = (uint32_t)round_up(buffer_size, granule) } },
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
 * `*end`, and inside the memory. Moves `*end` past it; disjoint() judges the regions together.
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

	const bool described = table->placing != ERX_DMA_PLACED_IN_ORDER && !device_writes(layout, index);
	const uint32_t record_size = erx_structure_record_size(table->structure);

	*end = 0;
	if (!region_valid(layout, table->region, table->region_length, end))
		return (false);
	/*
	 * A ring holds its link and at least one description, at the link's stride, since the
	 * sequencer writes a link into every ring, whether its structure has meanings or not.
	 */
	return (table->structure != ERX_REFERS_DATA && table->count != 0 && table->stride != 0 &&
	    (SEED_NO_STRIDE_TEST || ((record_size == 0 || table->stride == record_size) &&
	    (table->placing != ERX_DMA_PLACED_RING || table->stride == ERX_XHCI_TRB_LINK_SIZE))) &&
	    table->first >= table->region &&
	    erx_dma_inside(table->first - table->region, (uint64_t)table->count * table->stride, table->region_length) &&
	    (table->placing != ERX_DMA_PLACED_RING || table->count >= 2) &&
	    (!described || table->pool < layout->pool_count) &&
	    (!table->needs_binding || (described && table->placing == ERX_DMA_PLACED_RING)));
}

/* A table a run finds by its structure: one descriptions fill that needs no binding. */
static bool
found_by_structure(const erx_dma_layout_t *layout, uint32_t table)
{
	return (!layout->tables[table].needs_binding && layout->tables[table].placing != ERX_DMA_PLACED_IN_ORDER &&
	    !device_writes(layout, table));
}

/* Whether two tables a run finds by structure share one, so a run of it could not find its table. */
static bool
structure_shared(const erx_dma_layout_t *layout)
{
	for (uint32_t one = 0; one < layout->table_count; one++) {
		for (uint32_t other = 0; other < one; other++) {
			if (found_by_structure(layout, one) && found_by_structure(layout, other) &&
			    layout->tables[one].structure == layout->tables[other].structure)
				return (true);
		}
	}
	return (false);
}

/* Whether the `count` regions of `starts` and `ends` share no byte, in whatever order they lie. */
static bool
disjoint(const uint64_t *starts, const uint64_t *ends, uint32_t count)
{
	for (uint32_t one = 0; one < count; one++) {
		for (uint32_t other = 0; other < one; other++) {
			if (starts[one] < ends[other] && starts[other] < ends[one])
				return (false);
		}
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
	const uint64_t widest = widest_address(layout);
	uint64_t starts[ERX_DMA_TABLES_MAX + ERX_DMA_POOLS_MAX], ends[ERX_DMA_TABLES_MAX + ERX_DMA_POOLS_MAX];
	uint64_t end = 0, last;
	uint32_t regions = 0;

	if (!power_of_two(layout->granule) || layout->address_bits == 0 || layout->address_bits > 64 ||
	    layout->table_count > ERX_DMA_TABLES_MAX || layout->pool_count == 0 || layout->pool_count > ERX_DMA_POOLS_MAX ||
	    structure_shared(layout))
		return (false);
	for (uint32_t index = 0; index < layout->table_count; index++, regions++) {
		if (!table_valid(layout, index, &ends[regions]))
			return (false);
		starts[regions] = layout->tables[index].region;
	}
	/* Each buffer is a region of its own, one stride long, so whole granules make them disjoint. */
	for (uint32_t index = 0; index < layout->pool_count; index++, regions++) {
		const erx_dma_pool_t *pool = &layout->pools[index];

		ends[regions] = 0;
		if (pool->count == 0 || pool->size == 0 || pool->size > pool->stride ||
		    (!SEED_NO_GRANULE_TEST && (pool->stride & (layout->granule - 1)) != 0) ||
		    !region_valid(layout, pool->first, (uint64_t)pool->count * pool->stride, &ends[regions]))
			return (false);
		starts[regions] = pool->first;
	}
	if (!disjoint(starts, ends, regions))
		return (false);
	for (uint32_t index = 0; index < regions; index++)
		end = ends[index] > end ? ends[index] : end;
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
	bzero(ledger->bound, sizeof(ledger->bound));
}

uint32_t
erx_dma_layout_buffers(const erx_dma_layout_t *layout)
{
	uint32_t count = 0;

	for (uint32_t pool = 0; pool < layout->pool_count; pool++)
		count += layout->pools[pool].count;
	return (count);
}

const erx_dma_pool_t *
erx_dma_layout_buffer_pool(const erx_dma_layout_t *layout, uint32_t buffer, uint32_t *pool)
{
	for (uint32_t index = 0; index < layout->pool_count; index++) {
		if (buffer < layout->pools[index].count) {
			*pool = index;
			return (&layout->pools[index]);
		}
		buffer -= layout->pools[index].count;
	}
	return (NULL);
}

/* A buffer of the layout's: its pool and its place there exist. */
uint64_t
erx_dma_layout_buffer_offset(const erx_dma_layout_t *layout, uint32_t buffer, uint64_t offset)
{
	uint32_t index = 0;

	for (; index + 1 < layout->pool_count && buffer >= layout->pools[index].count; index++)
		buffer -= layout->pools[index].count;
	return (layout->pools[index].first + (uint64_t)buffer * layout->pools[index].stride + offset);
}

/* Whether a holding holds a record of `table`. */
static bool
table_held(const erx_dma_ledger_t *ledger, uint32_t table)
{
	return (erx_dma_ledger_free_records(ledger, table) != ledger->layout.tables[table].count);
}

bool
erx_dma_ledger_may_bind(const erx_dma_ledger_t *ledger, erx_dma_binding_t binding)
{
	return (binding.endpoint != 0 && binding.table < ledger->layout.table_count &&
	    ledger->layout.tables[binding.table].needs_binding && ledger->bound[binding.table] == 0 &&
	    (SEED_BIND_BOUND_ENDPOINT || erx_dma_ledger_bound_table(ledger, binding.endpoint) < 0));
}

bool
erx_dma_ledger_unbind(erx_dma_ledger_t *ledger, uint32_t table)
{
	if (table >= ledger->layout.table_count || ledger->bound[table] == 0 || table_held(ledger, table))
		return (false);
	ledger->bound[table] = 0;
	return (true);
}

uint32_t
erx_dma_ledger_binding(const erx_dma_ledger_t *ledger, uint32_t table)
{
	return (table < ledger->layout.table_count ? ledger->bound[table] : 0);
}

int
erx_dma_ledger_bound_table(const erx_dma_ledger_t *ledger, uint32_t endpoint)
{
	for (uint32_t table = 0; table < ledger->layout.table_count && endpoint != 0; table++) {
		if (ledger->bound[table] == endpoint)
			return ((int)table);
	}
	return (-1);
}

/* The cycle state on lap `lap` of a ring: 1 on lap 0, where a binding starts it, toggled by each link. */
static uint32_t
ring_cycle(uint32_t lap)
{
	return (~lap & 1u);
}

uint32_t
erx_dma_ledger_ring_run(const erx_dma_ledger_t *ledger, uint32_t table, uint32_t descriptions,
    erx_dma_ring_step_t steps[ERX_DMA_RING_STEPS_MAX])
{
	uint32_t index, lap, link, count = 0;

	if (table >= ledger->layout.table_count || ledger->layout.tables[table].placing != ERX_DMA_PLACED_RING ||
	    descriptions == 0 || descriptions > ERX_DMA_HELD_RECORDS_MAX ||
	    descriptions >= ledger->layout.tables[table].count)
		return (0);
	index = ledger->positions[table].index;
	lap = ledger->positions[table].lap;
	link = ledger->layout.tables[table].count - 1;
	for (uint32_t description = 0; description <= descriptions; description++) {
		/* The link where a description would land on it, and where the run ends just before it. */
		if (index == link && !(SEED_RING_NO_LINK && description == descriptions)) {
			steps[count++] = (erx_dma_ring_step_t){ { table, index }, ring_cycle(lap), true };
			index = 0;
			lap++;
		}
		if (description < descriptions)
			steps[count++] = (erx_dma_ring_step_t){ { table, index++ }, ring_cycle(lap), false };
	}
	return (count);
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
	/* The layout's check let at most one such table of a structure through. */
	for (uint32_t index = 0; index < ledger->layout.table_count; index++) {
		if (ledger->layout.tables[index].structure == structure && !ledger->layout.tables[index].needs_binding)
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
 * Whether `holding` may begin, and how many records it takes of each table placed in order or as
 * a ring: every record a table's that no holding holds, named once, not the device's, and, in a
 * table placed in order or as a ring, one of the next `taken` from its position, so, named once,
 * they are those next ones in whatever order the holding lists them (its head first); every
 * buffer one of the layout's and unheld.
 */
static bool
holding_valid(const erx_dma_ledger_t *ledger, const erx_dma_holding_t *holding, uint32_t taken[ERX_DMA_TABLES_MAX])
{
	if (ledger->live == ERX_DMA_HOLDINGS_MAX)
		return (false);
	for (uint32_t record = 0; record < holding->record_count; record++) {
		const erx_dma_place_t place = holding->records[record];

		if (place.table >= ledger->layout.table_count)
			return (false);
		taken[place.table] += ledger->layout.tables[place.table].placing != ERX_DMA_PLACED_FREE;
	}
	for (uint32_t record = 0; record < holding->record_count; record++) {
		const erx_dma_place_t place = holding->records[record];
		const erx_dma_table_t *table;

		table = &ledger->layout.tables[place.table];
		if (place.index >= table->count || device_writes(&ledger->layout, place.table) ||
		    (!SEED_HOLD_WHILE_HELD && erx_dma_ledger_record_held(ledger, place)))
			return (false);
		for (uint32_t earlier = 0; earlier < record; earlier++) {
			if (same_place(holding->records[earlier], place))
				return (false);
		}
		/* Named once, so at most count of a table: its distance from the position is below count. */
		if (table->placing != ERX_DMA_PLACED_FREE &&
		    (place.index + table->count - ledger->positions[place.table].index) % table->count >= taken[place.table])
			return (false);
	}
	for (uint32_t index = 0; index < holding->buffer_count; index++) {
		const uint32_t buffer = holding->buffers[index];

		if (buffer >= erx_dma_layout_buffers(&ledger->layout) ||
		    (!SEED_HOLD_WHILE_HELD && erx_dma_ledger_buffer_held(ledger, buffer)))
			return (false);
	}
	return (true);
}

/*
 * The holding of `publication` at `records`, with the buffers its names reach and the binding it
 * carries. False when there are more records or buffers than a holding holds.
 */
static bool
holding_of(const erx_dma_publication_t *publication, const erx_dma_place_t *records, uint32_t record_count,
    erx_dma_holding_t *holding)
{
	*holding = (erx_dma_holding_t){ .record_count = record_count };
	/* Endpoint 0 is no binding, whatever table it names: the holding keeps none. */
	if (publication->binds.endpoint != 0)
		holding->binding = publication->binds;
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
	/* A binding's ring, bound to no endpoint, takes none of the run: it holds no record before or after. */
	if (holding.binding.endpoint != 0 &&
	    (!erx_dma_ledger_may_bind(ledger, holding.binding) || taken[holding.binding.table] != 0))
		return (false);
	holding.serial = ++ledger->begun;
	ledger->holdings[ledger->live++] = holding;
	for (uint32_t table = 0; table < ledger->layout.table_count; table++)
		advance(ledger, table, taken[table]);
	if (holding.binding.endpoint != 0) {
		ledger->bound[holding.binding.table] = holding.binding.endpoint;
		/* The first record, on lap 0, of cycle state 1, where the sequencer's zeroed ring starts. */
		ledger->positions[holding.binding.table] = (erx_dma_position_t){ .index = 0, .lap = 0 };
	}
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

erx_dma_found_t
erx_dma_ledger_holding(const erx_dma_ledger_t *ledger, erx_dma_place_t head)
{
	for (uint32_t live = 0; live < ledger->live; live++) {
		if (same_place(ledger->holdings[live].records[0], head))
			return ((erx_dma_found_t){ &ledger->holdings[live], ledger->holdings[live].serial });
	}
	return ((erx_dma_found_t){ NULL, 0 });
}

bool
erx_dma_ledger_release_holding(erx_dma_ledger_t *ledger, uint32_t reports, erx_dma_found_t found)
{
	if (reports >= ledger->layout.table_count || !device_writes(&ledger->layout, reports) ||
	    ledger->acquired[reports] == 0)
		return (false);
	/*
	 * By equality: a pointer the ledger did not give compares equal to none of its holdings, and
	 * a holding begun since has another serial.
	 */
	for (uint32_t live = 0; live < ledger->live; live++) {
		if (&ledger->holdings[live] == found.holding && found.holding->serial == found.serial) {
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
