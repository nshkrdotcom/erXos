/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The sequencer: see erx_device_sequencer.h.
 *
 * The ERX_DMA_SEED_* macros below plant the faults test/host/erx_device_sequencer_test.rb shows
 * its harness catches (docs/design-device-dma.md, Verification): rule 1's zeros left out, so a
 * stale byte reaches a buffer the device holds. The INSTALL_* seeds, which
 * test/host/erx_device_virtio_core_test.rb shows its harness catches, plant faults in the install:
 * the used ring left unzeroed; the used ring's register given the available ring's address, a
 * value not from the layout's used table; the rings' cleans left out, so the ready bit comes
 * before the zeroing reaches memory.
 */

#include <string.h>

#include "erx_device_sequencer.h"

_Static_assert(sizeof(erx_virtq_desc_t) <= ERX_DMA_STORE_BYTES_MAX &&
    sizeof(erx_virtio_gpu_mem_entry_t) <= ERX_DMA_STORE_BYTES_MAX, "every record the sequencer encodes fits a store");
_Static_assert(sizeof(erx_xhci_trb_normal_t) <= ERX_DMA_STORE_BYTES_MAX, "a TRB fits a store");
/* The split ring's three tables, the only layout an install takes. */
#define SPLIT_RING_TABLES	3u
_Static_assert(SPLIT_RING_TABLES <= ERX_DMA_ZEROS_MAX && SPLIT_RING_TABLES <= ERX_DMA_CLEANS_MAX,
    "an install zeroes and cleans every table");

#ifdef ERX_DMA_SEED_INSTALL_NOT_ZEROED
#define SEED_INSTALL_NOT_ZEROED	true
#else
#define SEED_INSTALL_NOT_ZEROED	false
#endif
#ifdef ERX_DMA_SEED_INSTALL_REGISTER
#define SEED_INSTALL_REGISTER	true
#else
#define SEED_INSTALL_REGISTER	false
#endif
#ifdef ERX_DMA_SEED_INSTALL_UNCLEANED
#define SEED_INSTALL_UNCLEANED	true
#else
#define SEED_INSTALL_UNCLEANED	false
#endif
#ifdef ERX_DMA_SEED_FIRST_CYCLE_LIVE
#define SEED_FIRST_CYCLE_LIVE	true
#else
#define SEED_FIRST_CYCLE_LIVE	false
#endif

#ifdef ERX_DMA_SEED_NO_ZEROS
#define SEED_NO_ZEROS		true
#else
#define SEED_NO_ZEROS		false
#endif

/* The offset of byte `offset` of buffer `buffer` in the record's memory. */
static uint64_t
buffer_offset(const erx_dma_layout_t *layout, uint32_t buffer, uint64_t offset)
{
	return (erx_dma_layout_buffer_offset(layout, buffer, offset));
}

static uint64_t
record_offset(const erx_dma_layout_t *layout, erx_dma_place_t place)
{
	const erx_dma_table_t *table = &layout->tables[place.table];

	return (table->first + (uint64_t)place.index * table->stride);
}

static void
add_range(erx_dma_range_t *ranges, uint32_t *count, uint64_t offset, uint64_t length)
{
	if (length != 0)
		ranges[(*count)++] = (erx_dma_range_t){ offset, length };
}

/*
 * Rule 1 for one buffer: the gaps between its fills over its first `size` bytes. Each gap ends
 * where a fill begins, or at the end, so a buffer adds at most one more gap than its fills.
 */
static void
zero_gaps(const erx_dma_layout_t *layout, const erx_dma_publication_t *publication, uint32_t buffer,
    erx_dma_sequence_t *sequence)
{
	uint64_t cursor = 0;

	uint32_t pool;
	const uint64_t size = erx_dma_layout_buffer_pool(layout, buffer, &pool)->size;

	while (cursor < size) {
		uint64_t covered = cursor, next = size;

		for (uint32_t index = 0; index < publication->fill_count; index++) {
			const erx_dma_fill_t *fill = &publication->fills[index];

			if (fill->buffer != buffer || fill->length == 0)
				continue;
			if (fill->offset <= cursor && fill->offset + fill->length > covered)
				covered = fill->offset + fill->length;
			else if (fill->offset > cursor && fill->offset < next)
				next = fill->offset;
		}
		if (covered > cursor) {
			cursor = covered;
			continue;
		}
		add_range(sequence->zeros, &sequence->zero_count, buffer_offset(layout, buffer, cursor), next - cursor);
		cursor = next;
	}
}

/*
 * A table's 16-bit running index at its position: exact modulo 2^16 because the table's count,
 * a power of two up to ERX_DEVICE_QUEUE_SIZE_MAX, divides 2^16 (Virtio 1.2, 2.7.6).
 */
static uint16_t
running_index(const erx_dma_ledger_t *ledger, uint32_t table)
{
	const erx_dma_position_t position = erx_dma_ledger_position(ledger, table);

	return ((uint16_t)((uint64_t)position.lap * erx_dma_ledger_layout(ledger)->tables[table].count + position.index));
}

/* The lowest record of `table` no holding holds and not among the `count` already placed. */
static uint32_t
free_record(const erx_dma_ledger_t *ledger, uint32_t table, const erx_dma_place_t *placed, uint32_t count)
{
	uint32_t index = 0;

	for (;; index++) {
		bool taken = erx_dma_ledger_record_held(ledger, (erx_dma_place_t){ table, index });

		for (uint32_t earlier = 0; earlier < count && !taken; earlier++)
			taken = placed[earlier].table == table && placed[earlier].index == index;
		if (!taken)
			return (index);
	}
}

/*
 * One description's record, whole, through its meaning's encoder: its references' addresses
 * from its names and the layout, the chain's link to `next` when the run goes on, and a TRB's
 * cycle bit `cycle`. False for a meaning the sequencer has no encoder for yet, or a value its
 * encoder refuses.
 */
static bool
encode(const erx_dma_layout_t *layout, const erx_dma_description_t *description, erx_dma_place_t place,
    const erx_dma_place_t *next, uint32_t cycle, erx_dma_store_t *store)
{
	/* A TRB names at most one buffer, its data; one that names none has no address place. */
	const uint64_t data = description->name_count == 0 ? 0 : layout->device_base +
	    buffer_offset(layout, description->names[0].buffer, description->names[0].offset);

	*store = (erx_dma_store_t){ .offset = record_offset(layout, place) };
	switch (description->meaning) {
	case ERX_MEANING_VIRTQ_DESC: {
		const erx_virtq_desc_placed_t placed = {
			.addr = layout->device_base + buffer_offset(layout, description->names[0].buffer,
			    description->names[0].offset),
			.flags_next = next != NULL,
			.next = next != NULL ? next->index : 0,
		};
		erx_virtq_desc_t record;

		if (!erx_virtq_desc_encode(&record, &description->described.virtq_desc, &placed))
			return (false);
		store->length = sizeof(record);
		memcpy(store->bytes, &record, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_NORMAL: {
		const erx_xhci_trb_normal_placed_t placed = { .buffer = data, .control_cycle = cycle };
		erx_xhci_trb_normal_t record;

		if (!erx_xhci_trb_normal_encode(&record, &description->described.xhci_trb_normal, &placed))
			return (false);
		store->length = sizeof(record);
		memcpy(store->bytes, &record, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_DATA: {
		const erx_xhci_trb_data_placed_t placed = { .buffer = data, .control_cycle = cycle };
		erx_xhci_trb_data_t record;

		if (!erx_xhci_trb_data_encode(&record, &description->described.xhci_trb_data, &placed))
			return (false);
		store->length = sizeof(record);
		memcpy(store->bytes, &record, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_SETUP: {
		const erx_xhci_trb_setup_placed_t placed = { .control_cycle = cycle };
		erx_xhci_trb_setup_t record;

		if (!erx_xhci_trb_setup_encode(&record, &description->described.xhci_trb_setup, &placed))
			return (false);
		store->length = sizeof(record);
		memcpy(store->bytes, &record, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_STATUS: {
		const erx_xhci_trb_status_placed_t placed = { .control_cycle = cycle };
		erx_xhci_trb_status_t record;

		if (!erx_xhci_trb_status_encode(&record, &description->described.xhci_trb_status, &placed))
			return (false);
		store->length = sizeof(record);
		memcpy(store->bytes, &record, sizeof(record));
		return (true);
	}
	case ERX_MEANING_XHCI_TRB_NOOP_COMMAND: {
		const erx_xhci_trb_noop_command_placed_t placed = { .control_cycle = cycle };
		erx_xhci_trb_noop_command_t record;

		if (!erx_xhci_trb_noop_command_encode(&record, &placed))
			return (false);
		store->length = sizeof(record);
		memcpy(store->bytes, &record, sizeof(record));
		return (true);
	}
	default:
		return (false);
	}
}

/* A ring's link at `step`, back to the ring's first record, with the cycle state of its lap. */
static bool
encode_link(const erx_dma_layout_t *layout, erx_dma_ring_step_t step, erx_dma_store_t *store)
{
	const erx_xhci_trb_link_placed_t placed = {
		.segment_segment_pointer = layout->device_base + layout->tables[step.place.table].first,
		.control_cycle = step.cycle,
	};
	erx_xhci_trb_link_t record;

	if (!erx_xhci_trb_link_encode(&record, &placed))
		return (false);
	*store = (erx_dma_store_t){ .offset = record_offset(layout, step.place), .length = sizeof(record) };
	memcpy(store->bytes, &record, sizeof(record));
	return (true);
}

/*
 * A ring's run (docs/design-device-dma.md, "Publication"): each description at the next position
 * the ledger gives, with the cycle state there, a link it reaches among them; the first written
 * with the other cycle bit, so the device takes none of the run before the activation, the store
 * of the first's control word with its own. Every meaning of a ring activates on the one bit of
 * that word, which the generator holds for a structure's meanings. Its places begin with the
 * head, the last description, which the report of the TD's end names.
 */
static erx_dma_verdict_t
place_ring(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, uint32_t table,
    erx_dma_place_t *places, uint32_t *count, erx_dma_sequence_t *out)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	erx_dma_ring_step_t steps[ERX_DMA_RING_STEPS_MAX];
	const uint32_t taken = erx_dma_ledger_ring_run(ledger, table, publication->record_count, steps);
	uint32_t description = 0;
	erx_dma_store_t live;

	*count = 1;
	for (uint32_t step = 0; step < taken; step++) {
		erx_dma_store_t *const store = &out->stores[out->store_count];
		const bool first = description == 0 && !steps[step].link;

		if (steps[step].link) {
			if (!encode_link(layout, steps[step], store))
				return (ERX_DMA_BREAKS_MEANINGS);
			places[(*count)++] = steps[step].place;
		} else {
			const erx_dma_description_t *const record = &publication->records[description];

			if (!encode(layout, record, steps[step].place, NULL,
			    first && !SEED_FIRST_CYCLE_LIVE ? !steps[step].cycle : steps[step].cycle, store) ||
			    (first && !encode(layout, record, steps[step].place, NULL, steps[step].cycle, &live)))
				return (ERX_DMA_BREAKS_MEANINGS);
			if (++description == publication->record_count)
				places[0] = steps[step].place;
			else
				places[(*count)++] = steps[step].place;
		}
		if (first) {
			out->activation.kind = ERX_DMA_ACTIVATE_STORE;
			out->activation.store = (erx_dma_store_t){ .offset = live.offset + ERX_XHCI_TRB_NORMAL_OFF_CONTROL,
			    .length = sizeof(uint32_t) };
			memcpy(out->activation.store.bytes, live.bytes + ERX_XHCI_TRB_NORMAL_OFF_CONTROL, sizeof(uint32_t));
		}
		add_range(out->cleans, &out->clean_count, store->offset, store->length);
		out->store_count++;
	}
	return (ERX_DMA_PASSES);
}

/*
 * A region entry, whole, through its layout's encoder, at `at` of the record's memory: the
 * persistent region's device address and whole length. False where the encoder refuses them,
 * which cannot happen: erx_dma_regions_add refuses a length the entry cannot state.
 */
static bool
encode_region_entry(const erx_dma_persistent_region_t *region, uint64_t at, erx_dma_store_t *store)
{
	const erx_virtio_gpu_mem_entry_placed_t placed = { .addr = region->address, .length = region->length };
	erx_virtio_gpu_mem_entry_t record;

	if (!erx_virtio_gpu_mem_entry_encode(&record, &placed))
		return (false);
	*store = (erx_dma_store_t){ .offset = at, .length = sizeof(record) };
	memcpy(store->bytes, &record, sizeof(record));
	return (true);
}

/*
 * The record of the sequencer's own at a table placed in order, and the activation that makes
 * the run live. Only virtio's available ring is such a table: its entry names the chain's head,
 * and the available index, one past the entry's running index, is the activation.
 */
static bool
place_in_order(const erx_dma_ledger_t *ledger, uint32_t table, erx_dma_place_t head, erx_dma_store_t *entry,
    erx_dma_store_t *activation)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const erx_dma_position_t position = erx_dma_ledger_position(ledger, table);
	uint16_t value;

	if (layout->tables[table].structure != ERX_STRUCTURE_VIRTQ_AVAIL)
		return (false);
	value = (uint16_t)head.index;
	*entry = (erx_dma_store_t){ .offset = record_offset(layout, (erx_dma_place_t){ table, position.index }),
	    .length = sizeof(value) };
	memcpy(entry->bytes, &value, sizeof(value));
	value = (uint16_t)(running_index(ledger, table) + 1u);
	*activation = (erx_dma_store_t){ .offset = layout->tables[table].region + ERX_VIRTQ_RING_HEAD_OFF_IDX,
	    .length = sizeof(value) };
	memcpy(activation->bytes, &value, sizeof(value));
	return (true);
}

/*
 * The effects of a binding a publication carries, which its holding makes (erx_dma_ledger_hold):
 * ring `table`'s region zeroed, its link written on lap 0, where the binding starts it, so its
 * cycle bit is that lap's state, and the region cleaned, all before the command's activation, so
 * the controller finds a ring of TRBs whose cycle bit is 0 behind the position. False where the
 * link's encoder refuses the layout's address.
 */
static bool
bind_ring(const erx_dma_layout_t *layout, uint32_t table, erx_dma_sequence_t *out)
{
	const erx_dma_ring_step_t link = { .place = { .table = table, .index = layout->tables[table].count - 1 },
	    .cycle = 1, .link = true };

	if (!encode_link(layout, link, &out->stores[out->store_count]))
		return (false);
	out->store_count++;
	add_range(out->zeros, &out->zero_count, layout->tables[table].region, layout->tables[table].region_length);
	add_range(out->cleans, &out->clean_count, layout->tables[table].region, layout->tables[table].region_length);
	return (true);
}

/* The device address of a table's region, where a ring's head is: what a queue register names. */
static uint64_t
table_address(const erx_dma_layout_t *layout, int table)
{
	return (layout->device_base + layout->tables[table].region);
}

/*
 * The install of virtio's split ring, which the check found idle: every table's region zeroed and
 * cleaned, then the queue's size and its three rings' addresses from the layout, and the ready bit
 * as the activation. The idle report left every position at 0, where the device starts, so the
 * ledger does not change. BREAKS_CALLS for a layout of a form whose install the sequencer does not
 * write.
 */
static erx_dma_verdict_t
install(const erx_dma_ledger_t *ledger, erx_dma_sequence_t *sequence)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const int desc = erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_DESC);
	const int avail = erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_AVAIL);
	const int used = erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_USED);
	erx_dma_sequence_t out = { 0 };

	if (desc < 0 || avail < 0 || used < 0 || layout->table_count != SPLIT_RING_TABLES)
		return (ERX_DMA_BREAKS_CALLS);
	for (uint32_t table = 0; table < layout->table_count; table++) {
		const erx_dma_table_t *const at = &layout->tables[table];

		if (!(SEED_INSTALL_NOT_ZEROED && (int)table == used))
			add_range(out.zeros, &out.zero_count, at->region, at->region_length);
		if (!SEED_INSTALL_UNCLEANED)
			add_range(out.cleans, &out.clean_count, at->region, at->region_length);
	}
	out.registers[0] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_NUM, layout->tables[desc].count };
	out.registers[1] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_DESC, table_address(layout, desc) };
	out.registers[2] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_DRIVER, table_address(layout, avail) };
	out.registers[3] = (erx_dma_register_write_t){ ERX_DMA_VIRTQ_DEVICE,
	    table_address(layout, SEED_INSTALL_REGISTER ? avail : used) };
	out.register_count = 4;
	out.activation = (erx_dma_activation_t){ .kind = ERX_DMA_ACTIVATE_REGISTER, .reg = { ERX_DMA_VIRTQ_READY, 1 } };
	*sequence = out;
	return (ERX_DMA_PASSES);
}

erx_dma_verdict_t
erx_dma_publish(erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, erx_dma_sequence_t *sequence)
{
	const erx_dma_verdict_t verdict = erx_dma_publication_check(ledger, publication);
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	erx_dma_place_t places[ERX_DMA_HELD_RECORDS_MAX];
	uint32_t buffers[ERX_DMA_HELD_BUFFERS_MAX], buffer_count, count = 0;
	erx_dma_sequence_t out = { 0 };
	bool activated = false, on_ring = false;
	uint32_t run, pool;

	if (verdict != ERX_DMA_PASSES)
		return (verdict);
	if (publication->call == ERX_DMA_PUBLISH_INSTALL)
		return (install(ledger, sequence));
	/* The check passed: every record is in the run's one table, a ring or one placed free, with room for the run. */
	run = (uint32_t)erx_dma_run_table(ledger, publication);
	if (layout->tables[run].placing == ERX_DMA_PLACED_RING) {
		const erx_dma_verdict_t placed = place_ring(ledger, publication, run, places, &count, &out);

		if (placed != ERX_DMA_PASSES)
			return (placed);
		activated = on_ring = true;
	}
	if (publication->binds.endpoint != 0 && !bind_ring(layout, publication->binds.table, &out))
		return (ERX_DMA_BREAKS_BINDINGS);
	for (uint32_t record = 0; !on_ring && record < publication->record_count; record++) {
		places[count] = (erx_dma_place_t){ run, free_record(ledger, run, places, count) };
		count++;
	}
	for (uint32_t record = 0; !on_ring && record < publication->record_count; record++) {
		const bool chained = record + 1 < publication->record_count && places[record + 1].table == places[record].table;

		if (!encode(layout, &publication->records[record], places[record], chained ? &places[record + 1] : NULL,
		    0, &out.stores[out.store_count]))
			return (ERX_DMA_BREAKS_MEANINGS);
		add_range(out.cleans, &out.clean_count, out.stores[out.store_count].offset,
		    out.stores[out.store_count].length);
		out.store_count++;
	}
	for (uint32_t table = 0; table < layout->table_count; table++) {
		if (erx_structure_device_writes(layout->tables[table].structure) ||
		    layout->tables[table].placing != ERX_DMA_PLACED_IN_ORDER)
			continue;
		if (activated ||
		    !place_in_order(ledger, table, places[0], &out.stores[out.store_count], &out.activation.store))
			return (ERX_DMA_BREAKS_ROOM);
		out.activation.kind = ERX_DMA_ACTIVATE_STORE;
		activated = true;
		places[count++] = (erx_dma_place_t){ table, erx_dma_ledger_position(ledger, table).index };
		add_range(out.cleans, &out.clean_count, out.stores[out.store_count].offset,
		    out.stores[out.store_count].length);
		out.store_count++;
	}
	if (!activated || !erx_dma_publication_buffers(publication, buffers, &buffer_count))
		return (ERX_DMA_BREAKS_ROOM);
	for (uint32_t index = 0; index < buffer_count; index++) {
		if (!SEED_NO_ZEROS)
			zero_gaps(layout, publication, buffers[index], &out);
		add_range(out.cleans, &out.clean_count, buffer_offset(layout, buffers[index], 0),
		    erx_dma_layout_buffer_pool(layout, buffers[index], &pool)->stride);
	}
	for (uint32_t index = 0; index < publication->fill_count; index++) {
		const erx_dma_fill_t *const fill = &publication->fills[index];
		const uint64_t at = buffer_offset(layout, fill->buffer, fill->offset);

		if (fill->kind != ERX_DMA_FILL_REGION_ENTRY) {
			out.fills[out.fill_count++] = (erx_dma_range_t){ at, fill->length };
			continue;
		}
		/* The check found the region in the ledger. */
		if (!encode_region_entry(erx_dma_ledger_region(ledger, fill->region), at, &out.stores[out.store_count++]))
			return (ERX_DMA_BREAKS_FILLS);
		out.fills[out.fill_count++] = (erx_dma_range_t){ at, 0 };
	}
	if (!erx_dma_ledger_hold(ledger, publication, places, count))
		return (ERX_DMA_BREAKS_ROOM);
	*sequence = out;
	return (ERX_DMA_PASSES);
}

bool
erx_dma_acquire(erx_dma_ledger_t *ledger, uint32_t reports, uint16_t index, uint32_t most, uint32_t *count)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	uint32_t covered;

	if (reports >= layout->table_count || !erx_structure_device_writes(layout->tables[reports].structure))
		return (false);
	covered = (uint16_t)(index - running_index(ledger, reports));
	if (covered > erx_dma_ledger_live(ledger))
		return (false);
	*count = covered < most ? covered : most;
	return (erx_dma_ledger_acquire(ledger, reports, *count));
}

erx_dma_range_t
erx_dma_acquire_record(const erx_dma_ledger_t *ledger, uint32_t reports, uint32_t k)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const erx_dma_table_t *table;
	uint32_t index;

	/* Only a table the device writes has an acquisition. */
	if (k >= erx_dma_ledger_acquired(ledger, reports))
		return ((erx_dma_range_t){ 0, 0 });
	table = &layout->tables[reports];
	index = (uint32_t)(((uint64_t)erx_dma_ledger_position(ledger, reports).index + k) % table->count);
	return ((erx_dma_range_t){ record_offset(layout, (erx_dma_place_t){ reports, index }), table->stride });
}

/*
 * The head of the holding the record at the consumer position of `reports` names, through its
 * meaning's `releases` mark. False for a record past what the acquisition covered, one whose
 * selector names no meaning, or one naming no record of a table the ledger has.
 */
static bool
report_head(const erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record,
    erx_dma_place_t *head)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	uint32_t meaning, structure;
	uint64_t value;
	int target;

	if (erx_dma_ledger_acquired(ledger, reports) == 0)
		return (false);
	if (!erx_report_meaning(layout->tables[reports].structure, record, &meaning))
		return (false);
	/* A report naming a record by its address, as an event TRB does, comes with the TRB form. */
	if (!erx_report_releases(meaning, record, &structure, &value))
		return (false);
	target = erx_dma_ledger_table(ledger, structure);
	if (target < 0 || value >= layout->tables[target].count)
		return (false);
	*head = (erx_dma_place_t){ (uint32_t)target, (uint32_t)value };
	return (true);
}

erx_dma_found_t
erx_dma_report_holding(const erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record)
{
	erx_dma_place_t head;

	return (report_head(ledger, reports, record, &head) ? erx_dma_ledger_holding(ledger, head) :
	    (erx_dma_found_t){ NULL, 0 });
}

bool
erx_dma_consume(erx_dma_ledger_t *ledger, uint32_t reports, erx_dma_found_t found)
{
	return (erx_dma_ledger_release_holding(ledger, reports, found));
}
