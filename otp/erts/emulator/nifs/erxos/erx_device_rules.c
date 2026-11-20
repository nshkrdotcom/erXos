/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Descriptions and the check's rules: see erx_device_rules.h.
 *
 * The ERX_DMA_SEED_* macros plant the faults test/host/erx_device_ledger_test.rb shows its
 * harness catches (docs/design-device-dma.md, Verification, The check): each removes one
 * rule's test, so a publication that rule exists to refuse passes.
 */

#include "erx_device_rules.h"

#ifdef ERX_DMA_SEED_NO_MEANING_TEST
#define SEED_NO_MEANING_TEST	true
#else
#define SEED_NO_MEANING_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_WIDTH_TEST
#define SEED_NO_WIDTH_TEST	true
#else
#define SEED_NO_WIDTH_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_RANGE_TEST
#define SEED_NO_RANGE_TEST	true
#else
#define SEED_NO_RANGE_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_HELD_TEST
#define SEED_NO_HELD_TEST	true
#else
#define SEED_NO_HELD_TEST	false
#endif
/* Caught by test/host/erx_device_sequencer_test.rb. */
#ifdef ERX_DMA_SEED_NO_IDLE_TEST
#define SEED_NO_IDLE_TEST	true
#else
#define SEED_NO_IDLE_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_LENGTH_TEST
#define SEED_NO_LENGTH_TEST	true
#else
#define SEED_NO_LENGTH_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_BINDING_TEST
#define SEED_NO_BINDING_TEST	true
#else
#define SEED_NO_BINDING_TEST	false
#endif
#ifdef ERX_DMA_SEED_RING_REUSE_HELD
#define SEED_RING_REUSE_HELD	true
#else
#define SEED_RING_REUSE_HELD	false
#endif
#ifdef ERX_DMA_SEED_NO_ROOM_TEST
#define SEED_NO_ROOM_TEST	true
#else
#define SEED_NO_ROOM_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_FILLS_TEST
#define SEED_NO_FILLS_TEST	true
#else
#define SEED_NO_FILLS_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_ENTRY_LENGTH_TEST
#define SEED_NO_ENTRY_LENGTH_TEST	true
#else
#define SEED_NO_ENTRY_LENGTH_TEST	false
#endif
#ifdef ERX_DMA_SEED_NO_OVERLAP_TEST
#define SEED_NO_OVERLAP_TEST	true
#else
#define SEED_NO_OVERLAP_TEST	false
#endif

/* What the check derived of one record: its table and the references its meaning gives. */
typedef struct judged {
	uint32_t		table;
	size_t			reference_count;
	erx_meaning_reference_t	references[ERX_MEANING_REFERENCES_MAX];
} judged_t;

int
erx_dma_run_table(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, uint32_t structure)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const int one = erx_dma_ledger_table(ledger, structure);
	const int bound = erx_dma_ledger_bound_table(ledger, publication->endpoint);

	if (one >= 0)
		return (one);
	return (bound >= 0 && layout->tables[bound].structure == structure ? bound : -1);
}

/* The meanings, bindings, widths, names, held and lengths rules over one record. */
static erx_dma_verdict_t
judge_record(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication,
    const erx_dma_description_t *record, judged_t *judged)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const int table = erx_dma_run_table(ledger, publication, record->structure);
	const erx_dma_pool_t *pool;
	uint32_t pool_index;

	if (table < 0 && erx_dma_ledger_tables(ledger, record->structure) > 1)
		return (ERX_DMA_BREAKS_BINDINGS);
	if (table < 0 || erx_structure_device_writes(record->structure) ||
	    layout->tables[table].placing == ERX_DMA_PLACED_IN_ORDER ||
	    (!SEED_NO_MEANING_TEST && erx_meaning_structure(record->meaning) != record->structure))
		return (ERX_DMA_BREAKS_MEANINGS);
	judged->table = (uint32_t)table;
	if (!erx_meaning_describes(record->meaning, &record->described, judged->references,
	    &judged->reference_count)) {
		if (!SEED_NO_WIDTH_TEST)
			return (ERX_DMA_BREAKS_WIDTHS);
		/* The seed judges the record as one reference of no bytes, which every later rule passes. */
		judged->reference_count = 1;
		judged->references[0] = (erx_meaning_reference_t){ ERX_REFERS_DATA, 0 };
	}
	if (record->name_count != judged->reference_count)
		return (ERX_DMA_BREAKS_NAMES);
	for (size_t index = 0; index < judged->reference_count; index++) {
		const erx_dma_name_t name = record->names[index];

		/* Names of an input context or an endpoint come with the TRB form; a buffer's data is all a split ring names. */
		if (judged->references[index].target != ERX_REFERS_DATA ||
		    (pool = erx_dma_layout_buffer_pool(layout, SEED_NO_RANGE_TEST ? 0 : name.buffer, &pool_index)) == NULL)
			return (ERX_DMA_BREAKS_NAMES);
		if (!SEED_NO_BINDING_TEST && pool_index != layout->tables[table].pool)
			return (ERX_DMA_BREAKS_BINDINGS);
		if (!SEED_NO_HELD_TEST && erx_dma_ledger_buffer_held(ledger, name.buffer))
			return (ERX_DMA_BREAKS_HELD);
		if (!SEED_NO_LENGTH_TEST && !erx_dma_inside(name.offset, judged->references[index].length, pool->size))
			return (ERX_DMA_BREAKS_LENGTHS);
	}
	return (ERX_DMA_PASSES);
}

bool
erx_dma_publication_buffers(const erx_dma_publication_t *publication, uint32_t buffers[ERX_DMA_HELD_BUFFERS_MAX],
    uint32_t *count)
{
	*count = 0;
	for (uint32_t record = 0; record < publication->record_count; record++) {
		const erx_dma_description_t *description = &publication->records[record];

		for (uint32_t index = 0; index < description->name_count && index < ERX_MEANING_REFERENCES_MAX; index++) {
			const uint32_t buffer = description->names[index].buffer;
			bool seen = false;

			for (uint32_t earlier = 0; earlier < *count; earlier++)
				seen = seen || buffers[earlier] == buffer;
			if (seen)
				continue;
			if (*count == ERX_DMA_HELD_BUFFERS_MAX)
				return (false);
			buffers[(*count)++] = buffer;
		}
	}
	return (true);
}

/*
 * The room rule: a publication describes at least one record, and the holding it makes, its
 * records and one record of each table placed in order, fits a holding; each table has as many
 * unheld records as it describes; the next record of each table placed in order is unheld.
 */
static bool
room(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication, const judged_t *judged)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	uint32_t described[ERX_DMA_TABLES_MAX] = { 0 }, in_order = 0, buffers[ERX_DMA_HELD_BUFFERS_MAX], count;
	erx_dma_ring_step_t steps[ERX_DMA_RING_STEPS_MAX];

	for (uint32_t record = 0; record < publication->record_count; record++)
		described[judged[record].table]++;
	for (uint32_t table = 0; table < layout->table_count; table++) {
		if (layout->tables[table].placing == ERX_DMA_PLACED_IN_ORDER) {
			const erx_dma_place_t next = { table, erx_dma_ledger_position(ledger, table).index };

			if (erx_dma_ledger_record_held(ledger, next))
				return (false);
			in_order++;
		}
		if (layout->tables[table].placing == ERX_DMA_PLACED_RING && described[table] != 0) {
			const uint32_t taken = erx_dma_ledger_ring_run(ledger, table, described[table], steps);

			if (taken == 0)
				return (false);
			/* The links it takes count with its records; a ring's run has no record placed in order. */
			in_order += taken - described[table];
			for (uint32_t step = 0; step < taken && !SEED_RING_REUSE_HELD; step++) {
				if (erx_dma_ledger_record_held(ledger, steps[step].place))
					return (false);
			}
			continue;
		}
		if (described[table] > erx_dma_ledger_free_records(ledger, table))
			return (false);
	}
	return (publication->record_count + in_order <= ERX_DMA_HELD_RECORDS_MAX &&
	    erx_dma_publication_buffers(publication, buffers, &count));
}

/*
 * The fills rule over a region entry's fill: one entry long, naming a persistent region the
 * ledger holds. A fill of bytes has no region.
 */
static bool
region_entry_valid(const erx_dma_ledger_t *ledger, const erx_dma_fill_t *fill)
{
	if (fill->kind != ERX_DMA_FILL_REGION_ENTRY)
		return (true);
	return ((SEED_NO_ENTRY_LENGTH_TEST || fill->length == ERX_VIRTIO_GPU_MEM_ENTRY_SIZE) &&
	    erx_dma_ledger_region(ledger, fill->region) != NULL);
}

/* The fills rule over one fill: inside a range a record of the publication names. */
static bool
filled_inside_a_name(const erx_dma_publication_t *publication, const judged_t *judged, const erx_dma_fill_t *fill)
{
	for (uint32_t record = 0; record < publication->record_count; record++) {
		for (size_t index = 0; index < judged[record].reference_count; index++) {
			const erx_dma_name_t name = publication->records[record].names[index];

			if (name.buffer == fill->buffer && fill->offset >= name.offset &&
			    erx_dma_inside(fill->offset - name.offset, fill->length, judged[record].references[index].length))
				return (true);
		}
	}
	return (false);
}

/*
 * The fills rule over two fills, each already inside a name, so no sum wraps: whether a byte of
 * one buffer is in both, where the later store would overwrite part of the earlier.
 */
static bool
fills_overlap(const erx_dma_fill_t *one, const erx_dma_fill_t *other)
{
	return (one->buffer == other->buffer && one->length != 0 && other->length != 0 &&
	    one->offset < other->offset + other->length && other->offset < one->offset + one->length);
}

/* The calls rule, as the header gives it. */
static bool
call_valid(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication)
{
	switch (publication->call) {
	case ERX_DMA_PUBLISH_RUN:
		return (publication->record_count > 0);
	case ERX_DMA_PUBLISH_INSTALL:
		return (publication->record_count == 0 && publication->fill_count == 0 &&
		    (SEED_NO_IDLE_TEST || erx_dma_ledger_idle(ledger)));
	}
	return (false);
}

erx_dma_verdict_t
erx_dma_publication_check(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication)
{
	judged_t judged[ERX_DMA_HELD_RECORDS_MAX];

	if (!call_valid(ledger, publication))
		return (ERX_DMA_BREAKS_CALLS);
	if (publication->call == ERX_DMA_PUBLISH_INSTALL)
		return (ERX_DMA_PASSES);
	/* A run of more records than a holding holds cannot fit, and none is judged past the bound. */
	if (publication->record_count > ERX_DMA_HELD_RECORDS_MAX)
		return (ERX_DMA_BREAKS_ROOM);
	for (uint32_t record = 0; record < publication->record_count; record++) {
		const erx_dma_verdict_t verdict = judge_record(ledger, publication, &publication->records[record],
		    &judged[record]);

		/* A run's records lie in one table, so a ring's run is placed whole on its ring. */
		if (verdict == ERX_DMA_PASSES && judged[record].table != judged[0].table)
			return (ERX_DMA_BREAKS_BINDINGS);

		if (verdict != ERX_DMA_PASSES)
			return (verdict);
	}
	if (!SEED_NO_ROOM_TEST && !room(ledger, publication, judged))
		return (ERX_DMA_BREAKS_ROOM);
	if (publication->fill_count > ERX_DMA_FILLS_MAX)
		return (ERX_DMA_BREAKS_FILLS);
	for (uint32_t fill = 0; fill < publication->fill_count; fill++) {
		if ((!SEED_NO_FILLS_TEST && !filled_inside_a_name(publication, judged, &publication->fills[fill])) ||
		    !region_entry_valid(ledger, &publication->fills[fill]))
			return (ERX_DMA_BREAKS_FILLS);
		for (uint32_t earlier = 0; earlier < fill && !SEED_NO_OVERLAP_TEST; earlier++) {
			if (fills_overlap(&publication->fills[earlier], &publication->fills[fill]))
				return (ERX_DMA_BREAKS_FILLS);
		}
	}
	return (ERX_DMA_PASSES);
}
