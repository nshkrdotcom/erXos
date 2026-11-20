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
#ifdef ERX_DMA_SEED_NO_LENGTH_TEST
#define SEED_NO_LENGTH_TEST	true
#else
#define SEED_NO_LENGTH_TEST	false
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

/* What the check derived of one record: its table and the references its meaning gives. */
typedef struct judged {
	uint32_t		table;
	size_t			reference_count;
	erx_meaning_reference_t	references[ERX_MEANING_REFERENCES_MAX];
} judged_t;

/* Whether `length` bytes from `offset` lie inside `size` bytes, with no sum that can wrap. */
static bool
inside(uint64_t offset, uint64_t length, uint64_t size)
{
	return (offset <= size && length <= size - offset);
}

/* The meanings, widths, names, held and lengths rules over one record. */
static erx_dma_verdict_t
judge_record(const erx_dma_ledger_t *ledger, const erx_dma_description_t *record, judged_t *judged)
{
	const erx_dma_layout_t *layout = erx_dma_ledger_layout(ledger);
	const int table = erx_dma_ledger_table(ledger, record->structure);

	if (table < 0 || layout->tables[table].placing != ERX_DMA_PLACED_FREE ||
	    (!SEED_NO_MEANING_TEST && erx_meaning_structure(record->meaning) != record->structure))
		return (ERX_DMA_BREAKS_MEANINGS);
	judged->table = (uint32_t)table;
	if (!erx_meaning_describes(record->meaning, &record->described, judged->references,
	    &judged->reference_count)) {
		if (!SEED_NO_WIDTH_TEST)
			return (ERX_DMA_BREAKS_WIDTHS);
		judged->reference_count = record->name_count < ERX_MEANING_REFERENCES_MAX ? record->name_count :
		    ERX_MEANING_REFERENCES_MAX;
		for (size_t index = 0; index < judged->reference_count; index++)
			judged->references[index] = (erx_meaning_reference_t){ ERX_REFERS_DATA, 0 };
	}
	if (record->name_count != judged->reference_count)
		return (ERX_DMA_BREAKS_NAMES);
	for (size_t index = 0; index < judged->reference_count; index++) {
		const erx_dma_name_t name = record->names[index];

		/* Names of an input context or an endpoint come with the TRB form; a buffer's data is all a split ring names. */
		if (judged->references[index].target != ERX_REFERS_DATA ||
		    (!SEED_NO_RANGE_TEST && name.buffer >= layout->pool.count))
			return (ERX_DMA_BREAKS_NAMES);
		if (!SEED_NO_HELD_TEST && erx_dma_ledger_buffer_held(ledger, name.buffer))
			return (ERX_DMA_BREAKS_HELD);
		if (!SEED_NO_LENGTH_TEST && !inside(name.offset, judged->references[index].length, layout->pool.size))
			return (ERX_DMA_BREAKS_LENGTHS);
	}
	return (ERX_DMA_PASSES);
}

/* The buffers the publication names, each once, into `buffers`; their count, or more than the bound. */
static uint32_t
distinct_buffers(const erx_dma_publication_t *publication, uint32_t buffers[ERX_DMA_HELD_BUFFERS_MAX + 1])
{
	uint32_t count = 0;

	for (uint32_t record = 0; record < publication->record_count; record++) {
		for (uint32_t index = 0; index < publication->records[record].name_count; index++) {
			const uint32_t buffer = publication->records[record].names[index].buffer;
			bool seen = false;

			for (uint32_t earlier = 0; earlier < count; earlier++)
				seen = seen || buffers[earlier] == buffer;
			if (!seen && count <= ERX_DMA_HELD_BUFFERS_MAX)
				buffers[count++] = buffer;
		}
	}
	return (count);
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
	uint32_t described[ERX_DMA_TABLES_MAX] = { 0 }, in_order = 0, buffers[ERX_DMA_HELD_BUFFERS_MAX + 1];

	for (uint32_t record = 0; record < publication->record_count; record++)
		described[judged[record].table]++;
	for (uint32_t table = 0; table < layout->table_count; table++) {
		if (layout->tables[table].placing == ERX_DMA_PLACED_IN_ORDER) {
			const erx_dma_place_t next = { table, erx_dma_ledger_position(ledger, table).index };

			if (erx_dma_ledger_record_held(ledger, next))
				return (false);
			in_order++;
		}
		if (described[table] > erx_dma_ledger_free_records(ledger, table))
			return (false);
	}
	return (publication->record_count + in_order <= ERX_DMA_HELD_RECORDS_MAX &&
	    distinct_buffers(publication, buffers) <= ERX_DMA_HELD_BUFFERS_MAX);
}

/* The fills rule over one fill: inside a range a record of the publication names. */
static bool
filled_inside_a_name(const erx_dma_publication_t *publication, const judged_t *judged, const erx_dma_fill_t *fill)
{
	for (uint32_t record = 0; record < publication->record_count; record++) {
		for (size_t index = 0; index < judged[record].reference_count; index++) {
			const erx_dma_name_t name = publication->records[record].names[index];

			if (name.buffer == fill->buffer && fill->offset >= name.offset &&
			    inside(fill->offset - name.offset, fill->length, judged[record].references[index].length))
				return (true);
		}
	}
	return (false);
}

erx_dma_verdict_t
erx_dma_publication_check(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication)
{
	judged_t judged[ERX_DMA_HELD_RECORDS_MAX];

	/* A run of more records than a holding holds cannot fit, and none is judged past the bound. */
	if (publication->record_count == 0 || publication->record_count > ERX_DMA_HELD_RECORDS_MAX)
		return (ERX_DMA_BREAKS_ROOM);
	for (uint32_t record = 0; record < publication->record_count; record++) {
		const erx_dma_verdict_t verdict = judge_record(ledger, &publication->records[record], &judged[record]);

		if (verdict != ERX_DMA_PASSES)
			return (verdict);
	}
	if (!SEED_NO_ROOM_TEST && !room(ledger, publication, judged))
		return (ERX_DMA_BREAKS_ROOM);
	for (uint32_t fill = 0; fill < publication->fill_count; fill++) {
		if (!SEED_NO_FILLS_TEST && !filled_inside_a_name(publication, judged, &publication->fills[fill]))
			return (ERX_DMA_BREAKS_FILLS);
	}
	return (ERX_DMA_PASSES);
}
