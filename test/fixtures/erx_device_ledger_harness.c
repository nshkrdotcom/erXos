/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host tests of the ledger and the check's rules (docs/design-device-dma.md, Verification, The
 * check), run by test/host/erx_device_ledger_test.rb: the install's check of a layout; each rule
 * refusing the publication it exists for, by name; and the ledger's state machine, hold and
 * release over a queue of two entries, against a reference model on every sequence of events up
 * to a fixed depth. The first failed expectation prints a FAILED line and exits non-zero.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_rules.h"

#define EXPECT(condition, what)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, (what));	\
			exit(1);						\
		}								\
	} while (0)

/* Four entries, buffers of 100 bytes, a granule of 64: rings at 0, 64 and 128, the pool at 192. */
enum { SIZE = 4, BUFFER = 100, GRANULE = 64, MEMORY = 192 + SIZE * 128 };
enum { DESC = 0, AVAIL = 1, USED = 2 };

/* The holding a release ended, which these tests do not read. */
static erx_dma_holding_t ended;

static erx_dma_layout_t
split_ring(uint64_t memory, uint64_t base, uint32_t bits)
{
	erx_dma_layout_t layout;

	EXPECT(erx_dma_layout_split_ring(SIZE, BUFFER, GRANULE, memory, base, bits, &layout), "a split ring's layout");
	return (layout);
}

static void
test_layout(void)
{
	erx_dma_ledger_t ledger;
	erx_dma_layout_t layout = split_ring(MEMORY, 0x40000000, 32), planted;

	EXPECT(erx_dma_ledger_make(&ledger, &layout), "the split ring's layout passes the install's check");
	EXPECT(layout.tables[AVAIL].region == 64 && layout.tables[USED].region == 128 && layout.pool.first == 192 &&
	    layout.pool.stride == 128, "each ring a region of its own from a granule, buffers at a granule stride");
	EXPECT(erx_dma_ledger_table(&ledger, ERX_STRUCTURE_VIRTQ_USED) == USED, "the used ring's table");
	EXPECT(!erx_dma_layout_split_ring(3, BUFFER, GRANULE, MEMORY, 0, 32, &planted), "a size not a power of two");
	EXPECT(!erx_dma_layout_split_ring(SIZE, BUFFER, GRANULE, MEMORY, 8, 32, &planted),
	    "a device base off the descriptor table's alignment");
	EXPECT(erx_dma_layout_split_ring(SIZE, BUFFER, 1, MEMORY, 0, 32, &planted) &&
	    planted.tables[AVAIL].region % ERX_VIRTQ_AVAIL_RING_ALIGN == 0 &&
	    planted.tables[USED].region % ERX_VIRTQ_USED_RING_ALIGN == 0 &&
	    planted.tables[USED].region >= planted.tables[AVAIL].first + SIZE * sizeof(uint16_t) + sizeof(uint16_t),
	    "below a granule of their alignment the rings keep virtio's alignments");

	planted = split_ring(MEMORY - 1, 0, 32);
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "a pool past the memory is refused");
	planted = split_ring(MEMORY, 512, 10);
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "a region past the address width is refused");
	planted = split_ring(MEMORY, UINT64_MAX - 111, 64);
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "a device base whose regions wrap is refused");
	planted = layout;
	planted.tables[DESC].region_length = 128;
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "overlapping regions are refused");
	planted = layout;
	planted.pool.size = planted.pool.stride + 1;
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "a buffer longer than its stride is refused");
	planted = layout;
	planted.tables[AVAIL].structure = ERX_STRUCTURE_VIRTQ_DESC;
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "two tables of one structure are refused");
	planted = layout;
	planted.tables[AVAIL].count = SIZE * 32;
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "records past their region are refused");

	/* The seed's case: a form planted to lay out an unaligned region, then an unrounded stride. */
	planted = layout;
	planted.tables[AVAIL].region = 72;
	planted.tables[AVAIL].region_length = 56;
	planted.tables[AVAIL].first = 76;
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "a region off a granule is refused");
	planted = layout;
	planted.pool.stride = BUFFER;
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "buffers sharing a granule are refused");
	planted = layout;
	planted.pool.stride = 96;
	EXPECT(!erx_dma_ledger_make(&ledger, &planted), "a stride off a granule is refused, the pool's length on one");
}

static erx_dma_description_t
descriptor(uint32_t buffer, uint64_t offset, uint64_t length, bool device_writes)
{
	return ((erx_dma_description_t){
		.structure = ERX_STRUCTURE_VIRTQ_DESC,
		.meaning = ERX_MEANING_VIRTQ_DESC,
		.described = { .virtq_desc = { .len = length, .flags_write = device_writes } },
		.name_count = 1,
		.names = { { buffer, offset } },
	});
}

static erx_dma_verdict_t
check(const erx_dma_ledger_t *ledger, const erx_dma_description_t *records, uint32_t record_count,
    const erx_dma_fill_t *fills, uint32_t fill_count)
{
	const erx_dma_publication_t publication = { record_count, records, fill_count, fills };

	return (erx_dma_publication_check(ledger, &publication));
}

/* Begins, or tries to, the holding of one descriptor naming `buffer`, or of none for -1, at `places`. */
static bool
hold_at(erx_dma_ledger_t *ledger, int buffer, const erx_dma_place_t *places, uint32_t count)
{
	const erx_dma_description_t record = descriptor(buffer < 0 ? 0 : (uint32_t)buffer, 0, 8, false);
	const erx_dma_publication_t publication = { buffer < 0 ? 0 : 1, &record, 0, NULL };

	return (erx_dma_ledger_hold(ledger, &publication, places, count));
}

static void
test_rules(void)
{
	const erx_dma_layout_t layout = split_ring(MEMORY, 0, 32);
	const erx_dma_description_t chain[2] = { descriptor(0, 0, 16, false), descriptor(0, 16, 84, true) };
	const erx_dma_fill_t header = { .buffer = 0, .offset = 0, .length = 16 };
	erx_dma_description_t bad[ERX_DMA_HELD_RECORDS_MAX + 1];
	erx_dma_fill_t fill, pair[2];
	erx_dma_ledger_t ledger;

	EXPECT(erx_dma_ledger_make(&ledger, &layout), "a ledger");
	EXPECT(check(&ledger, chain, 2, &header, 1) == ERX_DMA_PASSES, "a request's chain with its header filled");

	/* meanings: a transfer TRB described on the descriptor table; a ring the sequencer or the device owns. */
	bad[0] = descriptor(1, 0, 8, false);
	bad[0].meaning = ERX_MEANING_XHCI_TRB_NORMAL;
	bad[0].described = (erx_meaning_free_t){ .xhci_trb_normal = { .status_length = 8 } };
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_MEANINGS, "another structure's meaning");
	bad[0] = descriptor(1, 0, 8, false);
	bad[0].structure = ERX_STRUCTURE_VIRTQ_AVAIL;
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_MEANINGS, "a record of the available ring");
	bad[0].structure = ERX_STRUCTURE_VIRTQ_USED;
	bad[0].meaning = ERX_MEANING_VIRTQ_USED_ELEM;
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_MEANINGS, "a used element described");

	/* widths: a length one bit wider than its field; WRITE given two bits. */
	bad[0] = descriptor(1, 0, UINT64_C(1) << 32, false);
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_WIDTHS, "a length wider than its field");
	bad[0] = descriptor(1, 0, 8, false);
	bad[0].described.virtq_desc.flags_write = 2;
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_WIDTHS, "a flag wider than its bit");

	/* names: a buffer past the pool; a record with no name. */
	bad[0] = descriptor(SIZE, 0, 8, false);
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_NAMES, "a buffer index past the pool");
	bad[0] = descriptor(1, 0, 8, false);
	bad[0].name_count = 0;
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_NAMES, "a reference with no name");

	/* lengths: past the buffer, and an offset whose sum with the length wraps. */
	bad[0] = descriptor(1, 90, 20, true);
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_LENGTHS, "a transfer past its buffer");
	bad[0] = descriptor(1, UINT64_MAX, 2, true);
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_LENGTHS, "an offset and length that wrap");
	bad[0] = descriptor(1, 0, BUFFER, true);
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_PASSES, "a whole buffer");

	/* fills: a buffer no record names; bytes straddling two names; inside one name. */
	fill = (erx_dma_fill_t){ .buffer = 1, .offset = 0, .length = 4 };
	EXPECT(check(&ledger, chain, 2, &fill, 1) == ERX_DMA_BREAKS_FILLS, "out bytes into a buffer no record names");
	fill = (erx_dma_fill_t){ .buffer = 0, .offset = 10, .length = 7 };
	EXPECT(check(&ledger, chain, 2, &fill, 1) == ERX_DMA_BREAKS_FILLS, "out bytes past their name");
	fill = (erx_dma_fill_t){ .buffer = 0, .offset = UINT64_MAX, .length = 2 };
	EXPECT(check(&ledger, chain, 2, &fill, 1) == ERX_DMA_BREAKS_FILLS, "a fill whose sum wraps");
	fill = (erx_dma_fill_t){ .buffer = 0, .offset = 20, .length = 80 };
	EXPECT(check(&ledger, chain, 2, &fill, 1) == ERX_DMA_PASSES, "out bytes inside a name");
	/* fills: two over the same bytes, so a later store overwrites an earlier; end to end; in two buffers. */
	pair[0] = (erx_dma_fill_t){ .buffer = 0, .offset = 0, .length = 16 };
	pair[1] = (erx_dma_fill_t){ .buffer = 0, .offset = 8, .length = 8 };
	EXPECT(check(&ledger, chain, 2, pair, 2) == ERX_DMA_BREAKS_FILLS, "two fills over the same bytes");
	pair[1] = (erx_dma_fill_t){ .buffer = 0, .offset = 16, .length = 8 };
	EXPECT(check(&ledger, chain, 2, pair, 2) == ERX_DMA_PASSES, "two fills end to end");

	/* room: nothing; more records than a holding holds. */
	EXPECT(check(&ledger, chain, 0, NULL, 0) == ERX_DMA_BREAKS_ROOM, "an empty publication");
	for (uint32_t index = 0; index < ERX_DMA_HELD_RECORDS_MAX + 1; index++)
		bad[index] = descriptor(index % SIZE, 0, 8, false);
	EXPECT(check(&ledger, bad, ERX_DMA_HELD_RECORDS_MAX + 1, NULL, 0) == ERX_DMA_BREAKS_ROOM, "a run past a holding");

	/* held: buffer 0 handed to the device by a live holding, then named again with a descriptor free. */
	EXPECT(hold_at(&ledger, 0, (erx_dma_place_t[]){ { DESC, 0 }, { DESC, 1 }, { DESC, 2 }, { AVAIL, 0 } }, 4),
	    "a holding of three descriptors and buffer 0");
	EXPECT(check(&ledger, chain, 1, &header, 1) == ERX_DMA_BREAKS_HELD, "a buffer the device holds, posted again");
	EXPECT(erx_dma_ledger_buffer_writer(&ledger, 0) == ERX_DMA_DEVICE &&
	    erx_dma_ledger_buffer_writer(&ledger, 1) == ERX_DMA_CPU, "a buffer's writer follows its holding");

	/* room: one free descriptor left for a run of two. */
	bad[0] = descriptor(1, 0, 8, false);
	bad[1] = descriptor(1, 8, 8, true);
	EXPECT(check(&ledger, bad, 2, NULL, 0) == ERX_DMA_BREAKS_ROOM, "a run longer than the free descriptors");
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_PASSES, "a run of the one free descriptor");

	/* room: every available entry held, with descriptors free. */
	EXPECT(erx_dma_ledger_make(&ledger, &layout), "a ledger");
	for (uint32_t index = 0; index < SIZE; index++)
		EXPECT(hold_at(&ledger, -1, &(erx_dma_place_t){ AVAIL, index }, 1), "a holding of an available entry");
	EXPECT(check(&ledger, bad, 1, NULL, 0) == ERX_DMA_BREAKS_ROOM, "a chain while its available entry is held");
}

/*
 * The persistent regions: added once each, kept over a reset, refused when they repeat a name,
 * outrun a device's regions, are empty, longer than an entry states, past the address width or
 * over the queue's memory; and the fills rule over a region entry: one entry long, naming a
 * region the ledger holds, never two over the same bytes.
 */
static void
test_regions(void)
{
	const erx_dma_layout_t layout = split_ring(MEMORY, 0, 32);
	const erx_dma_description_t whole = descriptor(0, 0, BUFFER, false);
	const erx_dma_persistent_region_t region = { .name = 7, .address = 0x80000000, .length = 0x3000 };
	erx_dma_fill_t entries[2] = {
		{ .kind = ERX_DMA_FILL_REGION_ENTRY, .buffer = 0, .offset = 0, .length = ERX_VIRTIO_GPU_MEM_ENTRY_SIZE,
		  .region = 7 },
		{ .kind = ERX_DMA_FILL_REGION_ENTRY, .buffer = 0, .offset = 8, .length = ERX_VIRTIO_GPU_MEM_ENTRY_SIZE,
		  .region = 7 },
	};
	erx_dma_layout_t wide;
	erx_dma_ledger_t ledger;

	EXPECT(erx_dma_ledger_make(&ledger, &layout), "a ledger");
	EXPECT(erx_dma_ledger_region(&ledger, 7) == NULL, "no region before one is added");
	EXPECT(check(&ledger, &whole, 1, entries, 1) == ERX_DMA_BREAKS_FILLS, "a region entry before its region is added");
	EXPECT(erx_dma_ledger_add_region(&ledger, region), "a region of the device");
	entries[0].region = 3;
	EXPECT(check(&ledger, &whole, 1, entries, 1) == ERX_DMA_BREAKS_FILLS,
	    "a region entry naming a region the ledger does not hold, as another device's");
	entries[0].region = 7;
	EXPECT(erx_dma_ledger_add_region(&ledger, region), "the same region again adds nothing");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 7, 0x90000000, 0x1000 }),
	    "a name added again with another address");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 8, 0x90000000, 0 }), "an empty region");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 8, 0x90000000, UINT64_C(1) << 32 }),
	    "a region longer than an entry's length states");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 8, 0xfffff000, 0x2000 }),
	    "a region past the address width");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 8, MEMORY - 8, 0x1000 }) &&
	    !erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 8, 0, 0x1000 }) &&
	    !erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 8, UINT64_MAX - 8, 4 }),
	    "a region over the queue's memory, or past the address width");
	for (uint32_t name = 8; name < 8 + ERX_DEVICE_REGIONS_MAX - 1; name++)
		EXPECT(erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ name, 0x90000000 + name * 0x1000, 0x1000 }),
		    "the device's other regions");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 99, 0xa0000000, 0x1000 }),
	    "more regions than a device has");
	erx_dma_ledger_reset(&ledger);
	EXPECT(erx_dma_ledger_region(&ledger, 7) != NULL && erx_dma_ledger_region(&ledger, 7)->address == region.address,
	    "a reset keeps the persistent regions");

	EXPECT(check(&ledger, &whole, 1, entries, 1) == ERX_DMA_PASSES, "a region entry naming the device's region");
	entries[0].length = 8;
	EXPECT(check(&ledger, &whole, 1, entries, 1) == ERX_DMA_BREAKS_FILLS, "a region entry's fill shorter than an entry");
	entries[0].length = ERX_VIRTIO_GPU_MEM_ENTRY_SIZE;
	EXPECT(check(&ledger, &whole, 1, entries, 2) == ERX_DMA_BREAKS_FILLS, "two region entries 8 bytes apart");
	entries[1].offset = ERX_VIRTIO_GPU_MEM_ENTRY_SIZE;
	EXPECT(check(&ledger, &whole, 1, entries, 2) == ERX_DMA_PASSES, "two region entries end to end");

	/* The queue's memory from a base above 0, at a 64-bit width: each edge, from either side, and a wrap. */
	wide = split_ring(MEMORY, 0x40000000, 64);
	EXPECT(erx_dma_ledger_make(&ledger, &wide), "a 64-bit ledger");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 1, 0x40000000 - 0x1000, 0x1001 }),
	    "a region from below the queue into its first byte");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 1, 0x40000000 + MEMORY - 1, 0x1000 }),
	    "a region from the queue's last byte");
	EXPECT(!erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 1, UINT64_MAX - 8, 0x1000 }),
	    "a region whose end wraps");
	EXPECT(erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 1, 0x40000000 - 0x1000, 0x1000 }) &&
	    erx_dma_ledger_add_region(&ledger, (erx_dma_persistent_region_t){ 2, 0x40000000 + MEMORY, 0x1000 }),
	    "regions ending at the queue's first byte and starting past its last");
}

static void
test_transitions(void)
{
	const erx_dma_layout_t layout = split_ring(MEMORY, 0, 32);
	const erx_dma_place_t head = { DESC, 0 };
	erx_dma_ledger_t ledger;

	EXPECT(erx_dma_ledger_make(&ledger, &layout), "a ledger");
	EXPECT(!hold_at(&ledger, 0, (erx_dma_place_t[]){ { DESC, 0 }, { USED, 0 } }, 2),
	    "a holding of a record the device writes");
	EXPECT(!hold_at(&ledger, 0, (erx_dma_place_t[]){ { DESC, 0 }, { AVAIL, 1 } }, 2), "an available entry out of order");
	EXPECT(!hold_at(&ledger, 0, (erx_dma_place_t[]){ { DESC, 0 }, { DESC, 0 } }, 2), "a record named twice");
	EXPECT(!hold_at(&ledger, SIZE, &head, 1), "a buffer past the pool");
	EXPECT(!hold_at(&ledger, 0, &(erx_dma_place_t){ DESC, SIZE }, 1), "a record past its table");
	EXPECT(!hold_at(&ledger, 0, &head, 0), "a holding of no record");
	EXPECT(erx_dma_ledger_live(&ledger) == 0, "nothing began");
	EXPECT(hold_at(&ledger, 0, (erx_dma_place_t[]){ { DESC, 0 }, { AVAIL, 0 } }, 2), "a chain of one descriptor");
	EXPECT(!hold_at(&ledger, 0, (erx_dma_place_t[]){ { DESC, 1 }, { AVAIL, 1 } }, 2),
	    "a buffer a live holding holds, with descriptors free");
	EXPECT(!erx_dma_ledger_release(&ledger, DESC, head, &ended), "a release on a table the CPU writes");
	EXPECT(!erx_dma_ledger_release(&ledger, USED, head, &ended), "a release no acquisition covered");
	EXPECT(!erx_dma_ledger_acquire(&ledger, USED, 2) && !erx_dma_ledger_acquire(&ledger, DESC, 1),
	    "an acquisition past the live holdings, or of a table the CPU writes");
	EXPECT(erx_dma_ledger_free_records(&ledger, DESC) == SIZE - 1, "three free descriptors");
	erx_dma_ledger_reset(&ledger);
	EXPECT(erx_dma_ledger_live(&ledger) == 0 && !erx_dma_ledger_buffer_held(&ledger, 0) &&
	    erx_dma_ledger_position(&ledger, AVAIL).index == 0, "the idle report ends every holding");
}

/*
 * The state machine, exhaustively: on a queue of two entries, every sequence of up to DEPTH
 * events, each a chain of one or two descriptors from head h with its buffer h and the next
 * available entry, or a used element naming head h. The reference model says which events the
 * design's order allows and what each leaves held; after every event the ledger agrees.
 */
enum { QUEUE = 2, DEPTH = 6, EVENTS = 3 * QUEUE };

typedef struct model {
	unsigned	descs, avails, buffers;	/* bit i: record or buffer i held */
	unsigned	heads;			/* bit h: a live holding's head is descriptor h */
	unsigned	chain[QUEUE];		/* the descriptors of the holding headed by h */
	unsigned	avail_of[QUEUE];	/* its available entry */
	unsigned	avail, avail_lap, used, used_lap;
} model_t;

static unsigned
chain_of(unsigned head, unsigned length)
{
	return (length == 1 ? 1u << head : 3u);
}

static void
agree(const erx_dma_ledger_t *ledger, const model_t *model)
{
	for (uint32_t index = 0; index < QUEUE; index++) {
		EXPECT(erx_dma_ledger_record_held(ledger, (erx_dma_place_t){ DESC, index }) ==
		    ((model->descs >> index) & 1), "a descriptor held as the model holds it");
		EXPECT(erx_dma_ledger_record_held(ledger, (erx_dma_place_t){ AVAIL, index }) ==
		    ((model->avails >> index) & 1), "an available entry held as the model holds it");
		EXPECT(erx_dma_ledger_buffer_held(ledger, index) == ((model->buffers >> index) & 1),
		    "a buffer held as the model holds it");
	}
	EXPECT(erx_dma_ledger_live(ledger) == (unsigned)__builtin_popcount(model->heads), "the live holdings");
	EXPECT(erx_dma_ledger_position(ledger, AVAIL).index == model->avail &&
	    erx_dma_ledger_position(ledger, AVAIL).lap == model->avail_lap, "the available ring's position");
	EXPECT(erx_dma_ledger_position(ledger, USED).index == model->used &&
	    erx_dma_ledger_position(ledger, USED).lap == model->used_lap, "the used ring's position");
}

static void
step(const erx_dma_ledger_t *before, const model_t *was, unsigned event, unsigned depth, unsigned long *runs)
{
	erx_dma_ledger_t *ledger = malloc(sizeof(*ledger));
	model_t model = *was;
	const unsigned head = event % QUEUE, kind = event / QUEUE;
	bool allowed, done;

	EXPECT(ledger != NULL, "memory for a ledger");
	memcpy(ledger, before, sizeof(*ledger));
	if (kind < 2) {
		const unsigned chain = chain_of(head, kind + 1);
		erx_dma_place_t places[3] = { { DESC, head } };
		uint32_t count = 1;

		if (kind == 1)
			places[count++] = (erx_dma_place_t){ DESC, 1 - head };
		places[count++] = (erx_dma_place_t){ AVAIL, model.avail };
		allowed = (model.descs & chain) == 0 && (model.buffers & (1u << head)) == 0 &&
		    (model.avails & (1u << model.avail)) == 0;
		done = hold_at(ledger, (int)head, places, count);
		if (allowed) {
			model.descs |= chain;
			model.buffers |= 1u << head;
			model.avails |= 1u << model.avail;
			model.heads |= 1u << head;
			model.chain[head] = chain;
			model.avail_of[head] = model.avail;
			model.avail_lap += (model.avail + 1) / QUEUE;
			model.avail = (model.avail + 1) % QUEUE;
		}
	} else {
		allowed = (model.heads >> head) & 1;
		/* The acquisition is not explored here: each release follows one covering every live holding. */
		EXPECT(erx_dma_ledger_acquire(ledger, USED, erx_dma_ledger_live(ledger)), "an acquisition of what is live");
		done = erx_dma_ledger_release(ledger, USED, (erx_dma_place_t){ DESC, head }, &ended);
		if (allowed) {
			model.descs &= ~model.chain[head];
			model.buffers &= ~(1u << head);
			model.avails &= ~(1u << model.avail_of[head]);
			model.heads &= ~(1u << head);
			model.used_lap += (model.used + 1) / QUEUE;
			model.used = (model.used + 1) % QUEUE;
		}
	}
	EXPECT(done == allowed, kind < 2 ? "a holding begins exactly when nothing it names is held" :
	    "a release ends exactly a live holding");
	agree(ledger, &model);
	(*runs)++;
	if (depth + 1 < DEPTH) {
		for (unsigned next = 0; next < EVENTS; next++)
			step(ledger, &model, next, depth + 1, runs);
	}
	free(ledger);
}

static void
test_state_machine(void)
{
	erx_dma_layout_t queue;
	erx_dma_ledger_t *ledger = malloc(sizeof(*ledger));
	const model_t empty = { 0 };
	unsigned long runs = 0;

	EXPECT(ledger != NULL, "memory for a ledger");
	EXPECT(erx_dma_layout_split_ring(QUEUE, BUFFER, GRANULE, 192 + QUEUE * 128, 0, 32, &queue), "a queue of two");
	EXPECT(erx_dma_ledger_make(ledger, &queue), "its ledger");
	for (unsigned event = 0; event < EVENTS; event++)
		step(ledger, &empty, event, 0, &runs);
	printf("state machine: %lu events checked\n", runs);
	free(ledger);
}

int
main(void)
{
	test_layout();
	test_rules();
	test_regions();
	test_transitions();
	test_state_machine();
	printf("erx_device_ledger done\n");
	return (0);
}
