/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host tests of the sequencer over virtio's split ring (docs/design-device-dma.md, Verification,
 * The check), run by test/host/erx_device_sequencer_test.rb: a publication's records written
 * whole through the encoder, its chain in free descriptors, its available entry and activation,
 * rule 1's zeros around its fills and the cleans of everything passing to the device; a refused
 * publication changing nothing; a region entry encoded from its region's name in place of a
 * fill's bytes; the acquisition's count and the consumption of used elements,
 * each releasing its chain, and refusing a used index past what is live or an id naming no live
 * chain. The first failed expectation prints a FAILED line and exits non-zero.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_sequencer.h"

#define EXPECT(condition, what)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, (what));	\
			exit(1);						\
		}								\
	} while (0)

/* Four entries, buffers of 100 bytes, a granule of 64: rings at 0, 64 and 128, the pool at 192. */
enum { SIZE = 4, BUFFER = 100, GRANULE = 64, MEMORY = 192 + SIZE * 128, BASE = 0x40000000 };
enum { DESC = 0, AVAIL = 1, USED = 2 };

/* A chain over one buffer: a header the device reads, filled, then a status byte it writes. */
static const erx_dma_description_t chain[2] = {
	{ .structure = ERX_STRUCTURE_VIRTQ_DESC, .meaning = ERX_MEANING_VIRTQ_DESC,
	  .described = { .virtq_desc = { .len = 16, .flags_write = 0 } }, .name_count = 1, .names = { { 0, 0 } } },
	{ .structure = ERX_STRUCTURE_VIRTQ_DESC, .meaning = ERX_MEANING_VIRTQ_DESC,
	  .described = { .virtq_desc = { .len = 1, .flags_write = 1 } }, .name_count = 1, .names = { { 0, 40 } } },
};
static const erx_dma_fill_t header = { .buffer = 0, .offset = 0, .length = 16 };

/* The device's region table, which fresh empties. */
static erx_dma_regions_t regions;

static erx_dma_ledger_t
fresh(void)
{
	erx_dma_layout_t layout;
	erx_dma_ledger_t ledger;

	EXPECT(erx_dma_layout_split_ring(SIZE, BUFFER, GRANULE, MEMORY, BASE, 32, &layout) &&
	    erx_dma_ledger_make(&ledger, &layout, (bzero(&regions, sizeof(regions)), &regions)), "the split ring's ledger");
	return (ledger);
}

static erx_virtq_desc_t
descriptor(const erx_dma_store_t *store)
{
	erx_virtq_desc_t record;

	EXPECT(store->length == sizeof(record), "a descriptor written whole");
	memcpy(&record, store->bytes, sizeof(record));
	return (record);
}

static uint16_t
half(const erx_dma_store_t *store)
{
	uint16_t value;

	EXPECT(store->length == sizeof(value), "a ring field written as one 16-bit store");
	memcpy(&value, store->bytes, sizeof(value));
	return (value);
}

/* Whether `ranges` covers [offset, offset + length) with no byte outside a covered range missed. */
static bool
covers(const erx_dma_range_t *ranges, uint32_t count, uint64_t offset, uint64_t length)
{
	for (uint64_t byte = offset; byte < offset + length; byte++) {
		bool found = false;

		for (uint32_t index = 0; index < count && !found; index++)
			found = byte >= ranges[index].offset && byte - ranges[index].offset < ranges[index].length;
		if (!found)
			return (false);
	}
	return (true);
}

/* A used element's holding, as erx_dma_report_holding finds it, copied out, then consumed. */
static bool
consume(erx_dma_ledger_t *ledger, const erx_report_record_t *record, erx_dma_holding_t *ended)
{
	const erx_dma_found_t found = erx_dma_report_holding(ledger, USED, record);

	if (found.holding != NULL)
		*ended = *found.holding;
	return (erx_dma_consume(ledger, USED, found));
}

/* The install: the calls rule first, then every table zeroed and cleaned, the registers from the layout, the ready bit. */
static void
test_install(void)
{
	erx_dma_ledger_t ledger = fresh();
	erx_dma_sequence_t sequence;
	const erx_dma_publication_t install = { .call = ERX_DMA_PUBLISH_INSTALL };

	EXPECT(erx_dma_publish(&ledger, &install, &sequence) == ERX_DMA_PASSES && erx_dma_ledger_idle(&ledger),
		"an install of an idle ledger, which begins no holding");
	EXPECT(sequence.zero_count == 3 && sequence.clean_count == 3 && sequence.zeros[2].offset == 128 &&
		sequence.cleans[2].length == sequence.zeros[2].length && sequence.store_count == 0 && sequence.fill_count == 0,
		"every table zeroed and cleaned, nothing else stored");
	EXPECT(sequence.register_count == 4 && sequence.registers[0].reg == ERX_DMA_VIRTQ_NUM &&
		sequence.registers[0].value == SIZE && sequence.registers[1].value == BASE &&
		sequence.registers[2].value == BASE + 64 && sequence.registers[3].reg == ERX_DMA_VIRTQ_DEVICE &&
		sequence.registers[3].value == BASE + 128, "the queue's size and its rings' addresses from the layout");
	EXPECT(sequence.activation.kind == ERX_DMA_ACTIVATE_REGISTER && sequence.activation.reg.reg == ERX_DMA_VIRTQ_READY &&
		sequence.activation.reg.value == 1, "the ready bit is the install's activation");
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 1, chain, 0, NULL, ERX_DMA_PUBLISH_INSTALL, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) ==
		ERX_DMA_BREAKS_CALLS, "an install that describes a record");
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 0, NULL, 0, NULL, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) ==
		ERX_DMA_BREAKS_CALLS, "a run of no record");
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 2, chain, 1, &header, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) == ERX_DMA_PASSES,
		"a chain published");
	EXPECT(erx_dma_publish(&ledger, &install, &sequence) == ERX_DMA_BREAKS_CALLS && erx_dma_ledger_live(&ledger) == 1,
		"an install while a chain is live zeroes nothing");
	erx_dma_ledger_reset(&ledger);
	EXPECT(erx_dma_publish(&ledger, &install, &sequence) == ERX_DMA_PASSES, "the install after the idle report");
}

static void
test_publication(void)
{
	erx_dma_ledger_t ledger = fresh();
	const erx_dma_publication_t publication = { 2, chain, 1, &header, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL };
	erx_dma_sequence_t sequence;
	erx_virtq_desc_t first, second;
	const uint64_t pool = erx_dma_ledger_layout(&ledger)->pools[0].first;

	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_PASSES, "a chain is published");
	EXPECT(sequence.store_count == 3, "two descriptors and the available entry");
	first = descriptor(&sequence.stores[0]);
	second = descriptor(&sequence.stores[1]);
	EXPECT(sequence.stores[0].offset == 0 && sequence.stores[1].offset == 16, "the chain in free descriptors 0 and 1");
	EXPECT(first.addr == BASE + pool && first.len == 16 && erx_virtq_desc_flags_next_get(first.flags) && !erx_virtq_desc_flags_write_get(first.flags) &&
	    first.next == 1, "the head names its buffer, its length and its successor");
	EXPECT(second.addr == BASE + pool + 40 && second.len == 1 && !erx_virtq_desc_flags_next_get(second.flags) && erx_virtq_desc_flags_write_get(second.flags) &&
	    second.next == 0, "the tail is written by the device and ends the chain");
	EXPECT(sequence.stores[2].offset == 64 + ERX_VIRTQ_RING_HEAD_SIZE && half(&sequence.stores[2]) == 0,
	    "the available entry names the head");
	EXPECT(sequence.activation.store.offset == 64 + ERX_VIRTQ_RING_HEAD_OFF_IDX && half(&sequence.activation.store) == 1,
	    "the available index is the activation");
	EXPECT(sequence.fill_count == 1 && sequence.fills[0].offset == pool && sequence.fills[0].length == 16,
	    "the fill at its buffer");
	EXPECT(sequence.zero_count == 1 && sequence.zeros[0].offset == pool + 16 && sequence.zeros[0].length == BUFFER - 16,
	    "rule 1 zeroes every byte of the buffer the fill does not");
	EXPECT(covers(sequence.cleans, sequence.clean_count, 0, 32) &&
	    covers(sequence.cleans, sequence.clean_count, 64 + ERX_VIRTQ_RING_HEAD_SIZE, 2) &&
	    covers(sequence.cleans, sequence.clean_count, pool, 128), "every record and the buffer are cleaned");
	EXPECT(erx_dma_ledger_buffer_held(&ledger, 0) && erx_dma_ledger_live(&ledger) == 1, "the holding begins");

	/* The buffer is held: a second publication naming it is refused and changes nothing. */
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_HELD, "a held buffer posted again");
	EXPECT(erx_dma_ledger_live(&ledger) == 1 && erx_dma_ledger_position(&ledger, AVAIL).index == 1,
	    "a refused publication changes nothing");
}

static void
test_acquisition(void)
{
	erx_dma_ledger_t ledger = fresh();
	erx_dma_description_t other[1] = { chain[0] };
	erx_dma_sequence_t sequence;
	erx_report_record_t report = { .virtq_used_elem = { .id = 2, .len = 16 } };
	const erx_report_record_t stale = { .virtq_used_elem = { .id = 0 } };
	erx_dma_holding_t ended;
	uint32_t count;

	other[0].names[0].buffer = 1;
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 2, chain, 1, &header, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) == ERX_DMA_PASSES &&
	    erx_dma_publish(&ledger, &(erx_dma_publication_t){ 1, other, 0, NULL, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) == ERX_DMA_PASSES,
	    "two chains published");
	EXPECT(sequence.stores[0].offset == 2 * ERX_VIRTQ_DESC_SIZE && half(&sequence.activation.store) == 2,
	    "the second chain in the next free descriptor, the index past both entries");
	EXPECT(sequence.zero_count == 1 && sequence.zeros[0].length == BUFFER, "an unfilled buffer zeroed whole");

	EXPECT(!erx_dma_acquire(&ledger, USED, 3, SIZE, &count), "a used index past what is live breaks the queue");
	EXPECT(!erx_dma_acquire(&ledger, DESC, 1, SIZE, &count), "no acquisition of a table the CPU writes");
	EXPECT(erx_dma_acquire(&ledger, USED, 2, 1, &count) && count == 1, "the count bounded by the call's most");
	EXPECT(erx_dma_acquire_record(&ledger, USED, 0).offset == 128 + ERX_VIRTQ_RING_HEAD_SIZE &&
	    erx_dma_acquire_record(&ledger, USED, 1).length == 0,
	    "the first used element at the consumer position, and none past the count");

	EXPECT(consume(&ledger, &report, &ended), "the used element releases the second chain");
	EXPECT(ended.records[0].index == 2 && ended.buffer_count == 1 && ended.buffers[0] == 1 &&
	    !erx_dma_ledger_buffer_held(&ledger, 1), "its descriptor, its entry and its buffer come back");
	EXPECT(!consume(&ledger, &stale, &ended),
	    "a stale element past the acquired count releases no live chain");

	EXPECT(erx_dma_acquire(&ledger, USED, 2, SIZE, &count) && count == 1, "the second element acquired");
	EXPECT(!consume(&ledger, &report, &ended), "a chain released twice breaks the queue");
	report.virtq_used_elem.id = SIZE;
	EXPECT(!consume(&ledger, &report, &ended), "an id past the table breaks the queue");
	EXPECT(consume(&ledger, &stale, &ended) && erx_dma_ledger_live(&ledger) == 0,
	    "the first chain comes back");
	EXPECT(erx_dma_ledger_position(&ledger, USED).index == 2, "the consumer position moved past both elements");
}

/*
 * A region entry in place of a header's bytes, by its region's name: one store from its encoder
 * at the fill's offset, nothing for the effect layer to fill there, no zero over it, cleaned with
 * its buffer; two entries 8 bytes apart, the second's address over the first's length, refused
 * with nothing held.
 */
static void
test_region_entry(void)
{
	erx_dma_ledger_t ledger = fresh();
	const erx_dma_persistent_region_t region = { .name = 2, .address = 0x80042000, .length = 0x3000 };
	erx_dma_description_t request[2] = { chain[0], chain[1] };
	erx_dma_fill_t entries[2] = {
		{ .kind = ERX_DMA_FILL_REGION_ENTRY, .buffer = 0, .offset = 0, .length = ERX_VIRTIO_GPU_MEM_ENTRY_SIZE,
		  .region = 2 },
		{ .kind = ERX_DMA_FILL_REGION_ENTRY, .buffer = 0, .offset = 8, .length = ERX_VIRTIO_GPU_MEM_ENTRY_SIZE,
		  .region = 2 },
	};
	const uint64_t pool = 192;
	erx_dma_sequence_t sequence;
	erx_virtio_gpu_mem_entry_t written;
	const erx_dma_store_t *store;

	EXPECT(erx_dma_regions_add(&regions, region), "the device's region");
	request[0].described.virtq_desc.len = 32;
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 2, request, 2, entries, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) ==
	    ERX_DMA_BREAKS_FILLS && erx_dma_ledger_live(&ledger) == 0, "two region entries 8 bytes apart, refused");
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 2, chain, 1, entries, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) == ERX_DMA_PASSES &&
	    sequence.store_count == 4 && sequence.fill_count == 1 && sequence.fills[0].offset == pool &&
	    sequence.fills[0].length == 0, "the chain, its available entry and the region entry stored; no bytes to fill");
	store = &sequence.stores[3];
	EXPECT(store->offset == pool && store->length == sizeof(written), "the region entry whole, at the fill's offset");
	memcpy(&written, store->bytes, sizeof(written));
	EXPECT(written.addr == region.address && written.length == region.length && written.padding == 0,
	    "the entry's address and length are the region's, its padding 0");
	for (uint32_t index = 0; index < sequence.zero_count; index++)
		EXPECT(sequence.zeros[index].offset >= pool + ERX_VIRTIO_GPU_MEM_ENTRY_SIZE ||
		    sequence.zeros[index].offset + sequence.zeros[index].length <= pool, "no zero over the region entry");
	EXPECT(covers(sequence.cleans, sequence.clean_count, pool, ERX_VIRTIO_GPU_MEM_ENTRY_SIZE),
	    "the region entry cleaned with its buffer");
}

/*
 * Ten rounds over a queue of four, past two laps: each publication's activation and each
 * acquisition's count follow the running index; and a chain placed around a held descriptor
 * links to the descriptor it took, not to the next number.
 */
static void
test_laps(void)
{
	erx_dma_ledger_t ledger = fresh();
	erx_dma_description_t one[1] = { chain[0] };
	erx_dma_sequence_t sequence;
	erx_report_record_t report = { .virtq_used_elem = { .id = 0 } };
	erx_dma_holding_t ended;
	uint32_t count;

	for (uint16_t round = 1; round <= 10; round++) {
		EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 1, one, 0, NULL, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) == ERX_DMA_PASSES &&
		    half(&sequence.activation.store) == round, "the activation is the running index past the entry");
		EXPECT(erx_dma_acquire(&ledger, USED, round, SIZE, &count) && count == 1,
		    "one element covered each round");
		report.virtq_used_elem.id = (uint32_t)(sequence.stores[0].offset / ERX_VIRTQ_DESC_SIZE);
		EXPECT(consume(&ledger, &report, &ended), "each round's chain comes back");
	}
	one[0].names[0].buffer = 1;
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 1, one, 0, NULL, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) == ERX_DMA_PASSES &&
	    sequence.stores[0].offset == 0, "a chain of one holds descriptor 0");
	EXPECT(erx_dma_publish(&ledger, &(erx_dma_publication_t){ 2, chain, 0, NULL, ERX_DMA_PUBLISH_RUN, 0, 0, { { 0, 0 } }, { 0, 0, 0 }, NULL }, &sequence) == ERX_DMA_PASSES &&
	    descriptor(&sequence.stores[0]).next == 2 && sequence.stores[1].offset == 2 * ERX_VIRTQ_DESC_SIZE,
	    "a chain placed around a held descriptor links past it");
}

int
main(void)
{
	test_install();
	test_publication();
	test_acquisition();
	test_region_entry();
	test_laps();
	printf("erx_device_sequencer done\n");
	return (0);
}
