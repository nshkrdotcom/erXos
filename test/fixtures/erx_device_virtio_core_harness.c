/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host tests of the split ring's form core (otp/erts/emulator/nifs/erxos/erx_device_virtio_core.h)
 * over the sequencer, run by test/host/erx_device_virtio_core_test.rb. The harness applies each
 * sequence to a memory of its own and plays the device on it: it fetches each chain from the
 * available ring through the descriptors' links, checks the chain against virtio's rules (no
 * piece empty, none read after one written, the pieces end to end in one buffer, the readable
 * ones holding the post's bytes and the rest zeros) and writes used elements and the used index
 * as an honest or a malformed device would. A model of its own says what every call answers:
 * each post's status, each acquisition's count and each completion's answers, with their tags,
 * ranges and bytes, under the entry and byte limits.
 *
 * The state machine is searched exhaustively: every sequence of DEPTH operations of the
 * alphabet `ops` from a fresh ring, on rings of two and of four entries. Directed cases add
 * what the depth does not reach: indexes past a u16's wrap, elements passed beyond the
 * acquisition, and a layout that is not a split ring's. The first failed expectation prints a
 * FAILED line and exits non-zero.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_virtio_core.h"

#define EXPECT(condition, what)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, (what));	\
			exit(1);						\
		}								\
	} while (0)

enum { SIZE_MAX_HERE = 4, BUFFER = 64, GRANULE = 64, MEMORY = 1024, BASE = 0x40000000, DEPTH = 5 };
enum { DESC = 0, AVAIL = 1, USED = 2 };

/* A chain the device fetched: where it lies and what completing it hands back. */
typedef struct fetched {
	uint32_t	head;
	uint32_t	desc_count;
	uint32_t	descs[ERX_DEVICE_CHAIN_MAX];
	uint32_t	avail_slot;
	uint64_t	tag;
	uint64_t	written;	/* the memory offset of the first byte the device may write */
	uint32_t	writable;
} fetched_t;

/*
 * A used element the device wrote and the driver has not consumed, and what it should answer. A
 * valid one names a chain the ledger holds until the driver consumes it.
 */
typedef struct element {
	bool		valid;
	uint32_t	head;
	uint32_t	avail_slot;
	uint32_t	desc_count;
	uint64_t	tag;
	uint64_t	written;
	uint32_t	len;
	uint8_t		pattern;
} element_t;

typedef struct world {
	erx_split_ring_t	ring;
	erx_dma_layout_t	layout;
	uint32_t		size;
	uint8_t			memory[MEMORY];
	/* Bytes the CPU stored that no clean has written to memory yet. */
	bool			dirty[MEMORY];
	/* The device's queue registers, as the install wrote them. */
	uint64_t		queue_num, queue_desc, queue_driver, queue_device;
	bool			ready;
	/* The model and the device. */
	bool			broken;
	uint16_t		posts;		/* available entries since the reset */
	uint16_t		used_idx;	/* the device's used index */
	uint16_t		consumed;	/* the elements the driver consumed */
	uint32_t		holdings;	/* chains posted and not consumed */
	uint32_t		free_descs;
	uint32_t		fetched_count;
	fetched_t		fetched[SIZE_MAX_HERE];
	uint32_t		pending_count;
	element_t		pending[SIZE_MAX_HERE + DEPTH + 1];
	bool			stale_valid;
	uint32_t		stale_head;
	uint8_t			next_pattern;
} world_t;

static uint8_t payload[BUFFER];
/* The device's region table: the core's region entries are the ledger's and the sequencer's, tested there. */
static const erx_dma_regions_t no_regions;

/* The states the exhaustive search must reach, so a model that never gets there fails. */
enum {
	REACH_FULL_BUFFERS, REACH_FULL_DESCS, REACH_FULL_AVAIL, REACH_MOST, REACH_BYTES, REACH_PARTIAL,
	REACH_BAD_LATER_DESC, REACH_BAD_STALE, REACH_BAD_OUTSIDE, REACH_FOUR, REACH_INSTALL_BUSY, REACH_COUNT
};
static uint64_t reached[REACH_COUNT];

static uint16_t
load16(const world_t *w, uint64_t offset)
{
	uint16_t value;

	memcpy(&value, &w->memory[offset], sizeof(value));
	return (value);
}

static void
store16(world_t *w, uint64_t offset, uint16_t value)
{
	memcpy(&w->memory[offset], &value, sizeof(value));
}

static void install(world_t *w);

static void
fresh(world_t *w, uint32_t size)
{
	memset(w, 0, sizeof(*w));
	w->size = size;
	w->free_descs = size;
	EXPECT(erx_dma_layout_split_ring(size, BUFFER, GRANULE, MEMORY, BASE, 32, &w->layout) &&
	    erx_split_ring_make(&w->ring, &w->layout, &no_regions), "the split ring is made");
	memset(w->memory, 0xa5, w->layout.pool.first);
	install(w);
}

static void
reset(world_t *w)
{
	const uint32_t size = w->size;
	const erx_dma_layout_t layout = w->layout;
	erx_split_ring_t ring = w->ring;

	erx_split_ring_reset(&ring);
	memset(w, 0, sizeof(*w));
	w->ring = ring;
	w->layout = layout;
	w->size = size;
	w->free_descs = size;
	EXPECT(erx_dma_ledger_live(erx_split_ring_ledger(&w->ring)) == 0, "the reset ends every chain");
	memset(w->memory, 0xa5, w->layout.pool.first);
	install(w);
}

static bool
inside(uint64_t offset, uint64_t length)
{
	return (offset <= MEMORY && length <= MEMORY - offset);
}

/* Where the device finds a ring: the address its register holds, as an offset of the memory. */
static uint64_t
ring_at(uint64_t address)
{
	return (address - BASE);
}

static void
stored(world_t *w, uint64_t offset, uint64_t length)
{
	memset(&w->dirty[offset], true, length);
}

/*
 * The sequence applied as the effect layer applies it: zeros, fills, stores, cleans, registers, the
 * activation. A byte stored and not cleaned before the activation is one the device may not see.
 */
static void
apply(world_t *w, const erx_dma_sequence_t *sequence, const erx_dma_piece_t *pieces)
{
	for (uint32_t index = 0; index < sequence->zero_count; index++) {
		EXPECT(inside(sequence->zeros[index].offset, sequence->zeros[index].length), "a zero inside the memory");
		memset(&w->memory[sequence->zeros[index].offset], 0, sequence->zeros[index].length);
		stored(w, sequence->zeros[index].offset, sequence->zeros[index].length);
	}
	for (uint32_t index = 0; index < sequence->fill_count; index++) {
		EXPECT(inside(sequence->fills[index].offset, sequence->fills[index].length) &&
		    sequence->fills[index].length == pieces[index].length && !pieces[index].device_writes,
		    "fill i is piece i's, a piece the device reads");
		memcpy(&w->memory[sequence->fills[index].offset], pieces[index].bytes, pieces[index].length);
		stored(w, sequence->fills[index].offset, sequence->fills[index].length);
	}
	for (uint32_t index = 0; index < sequence->store_count; index++) {
		EXPECT(inside(sequence->stores[index].offset, sequence->stores[index].length), "a store inside the memory");
		memcpy(&w->memory[sequence->stores[index].offset], sequence->stores[index].bytes,
		    sequence->stores[index].length);
		stored(w, sequence->stores[index].offset, sequence->stores[index].length);
	}
	for (uint32_t index = 0; index < sequence->clean_count; index++) {
		EXPECT(inside(sequence->cleans[index].offset, sequence->cleans[index].length), "a clean inside the memory");
		memset(&w->dirty[sequence->cleans[index].offset], false, sequence->cleans[index].length);
	}
	for (uint32_t offset = 0; offset < MEMORY; offset++)
		EXPECT(!w->dirty[offset], "every byte stored is clean before the activation");
	for (uint32_t index = 0; index < sequence->register_count; index++) {
		const erx_dma_register_write_t write = sequence->registers[index];

		EXPECT(!w->ready, "no queue register written while the queue is ready");
		w->queue_num = write.reg == ERX_DMA_VIRTQ_NUM ? write.value : w->queue_num;
		w->queue_desc = write.reg == ERX_DMA_VIRTQ_DESC ? write.value : w->queue_desc;
		w->queue_driver = write.reg == ERX_DMA_VIRTQ_DRIVER ? write.value : w->queue_driver;
		w->queue_device = write.reg == ERX_DMA_VIRTQ_DEVICE ? write.value : w->queue_device;
	}
	if (sequence->activation.kind == ERX_DMA_ACTIVATE_REGISTER) {
		EXPECT(sequence->activation.reg.reg == ERX_DMA_VIRTQ_READY && sequence->activation.reg.value == 1,
		    "an install's activation is the ready bit");
		w->ready = true;
		return;
	}
	EXPECT(w->ready, "nothing is made live before the install");
	EXPECT(inside(sequence->activation.store.offset, sequence->activation.store.length), "the activation inside the memory");
	memcpy(&w->memory[sequence->activation.store.offset], sequence->activation.store.bytes, sequence->activation.store.length);
}

/*
 * The install, as negotiate/2 runs it: refused while the ring is not as the reset left it;
 * otherwise the rings, which may hold a former queue's bytes, zeroed and handed to the device.
 */
static void
install(world_t *w)
{
	const int expected = w->broken ? ERX_ECORRUPT : w->ready || w->posts != 0 ? ERX_EBUSY : ERX_OK;
	const erx_split_ring_t before = w->ring;
	erx_dma_sequence_t sequence;
	const int status = erx_split_ring_install(&w->ring, &sequence);

	EXPECT(status == expected, "an install answers as the model says");
	if (status != ERX_OK) {
		EXPECT(memcmp(&before, &w->ring, sizeof(before)) == 0, "a refused install changes nothing");
		reached[REACH_INSTALL_BUSY] += status == ERX_EBUSY;
		return;
	}
	apply(w, &sequence, NULL);
	for (uint64_t offset = 0; offset < w->layout.pool.first; offset++)
		EXPECT(w->memory[offset] == 0, "the install zeroes every ring");
	EXPECT(w->queue_num == w->size && w->queue_desc == BASE + w->layout.tables[DESC].region &&
	    w->queue_driver == BASE + w->layout.tables[AVAIL].region && w->queue_device == BASE + w->layout.tables[USED].region,
	    "the queue registers name the layout's rings");
}

/*
 * The device fetches the chain the post made live, as virtio's device does: the available index,
 * the head its entry names, and each descriptor through NEXT and next. It holds the chain to
 * virtio's rules, and its bytes to the post's.
 */
static void
fetch(world_t *w, const erx_dma_piece_t *pieces, uint32_t count, uint64_t tag)
{
	const uint64_t descs = ring_at(w->queue_desc), avail = ring_at(w->queue_driver);
	const uint64_t pool = w->layout.pool.first, stride = w->layout.pool.stride;
	const uint32_t slot = (uint32_t)(w->posts % w->size);
	fetched_t chain = { .avail_slot = slot, .tag = tag };
	uint64_t buffer = 0, at = 0;
	bool writing = false;
	uint32_t index;

	EXPECT(load16(w, avail + ERX_VIRTQ_RING_HEAD_OFF_IDX) == (uint16_t)(w->posts + 1),
	    "the available index moves past the one entry");
	chain.head = index = load16(w, avail + ERX_VIRTQ_RING_HEAD_SIZE + 2u * slot);
	for (;;) {
		erx_virtq_desc_t record;
		uint64_t offset;

		EXPECT(index < w->size && chain.desc_count < count, "the chain is as long as its pieces");
		memcpy(&record, &w->memory[descs + (uint64_t)index * ERX_VIRTQ_DESC_SIZE], sizeof(record));
		EXPECT(record.addr >= BASE + pool, "a descriptor names the pool");
		offset = record.addr - BASE;
		if (chain.desc_count == 0) {
			EXPECT((offset - pool) % stride == 0 && (offset - pool) / stride < w->size,
			    "the head names a buffer's first byte");
			buffer = at = offset;
		}
		EXPECT(offset == at, "the pieces lie end to end");
		EXPECT(record.len == pieces[chain.desc_count].length && record.len > 0, "no piece is empty");
		EXPECT(at + record.len <= buffer + BUFFER, "the chain stays in its one buffer");
		EXPECT(erx_virtq_desc_flags_write_get(record.flags) == pieces[chain.desc_count].device_writes,
		    "the piece's direction");
		EXPECT(!writing || erx_virtq_desc_flags_write_get(record.flags), "nothing read after something written");
		if (erx_virtq_desc_flags_write_get(record.flags)) {
			if (!writing)
				chain.written = at;
			writing = true;
			chain.writable += record.len;
			for (uint32_t byte = 0; byte < record.len; byte++)
				EXPECT(w->memory[at + byte] == 0, "rule 1 zeroes what the device writes");
		} else {
			EXPECT(memcmp(&w->memory[at], pieces[chain.desc_count].bytes, record.len) == 0,
			    "the device reads the post's bytes");
		}
		chain.descs[chain.desc_count++] = index;
		at += record.len;
		if (!erx_virtq_desc_flags_next_get(record.flags))
			break;
		index = record.next;
	}
	EXPECT(chain.desc_count == count, "the chain ends at its last piece");
	if (!writing)
		chain.written = at;
	w->fetched[w->fetched_count++] = chain;
}

static uint32_t
sum(const erx_dma_piece_t *pieces, uint32_t count)
{
	uint32_t total = 0;

	for (uint32_t index = 0; index < count; index++)
		total += pieces[index].length;
	return (total);
}

static bool
avail_held(const world_t *w)
{
	for (uint32_t index = 0; index < w->fetched_count; index++)
		if (w->fetched[index].avail_slot == w->posts % w->size)
			return (true);
	for (uint32_t index = 0; index < w->pending_count; index++)
		if (w->pending[index].valid && w->pending[index].avail_slot == w->posts % w->size)
			return (true);
	return (false);
}

/* What the model says a post answers. */
static int
expected_post(const world_t *w, const erx_dma_piece_t *pieces, uint32_t count)
{
	if (count == 0 || count > ERX_DEVICE_CHAIN_MAX || sum(pieces, count) > BUFFER)
		return (ERX_EINVAL);
	/* A malformed chain is EINVAL on every ring, full or broken. */
	for (uint32_t index = 0; index < count; index++)
		if (pieces[index].length == 0 || (index > 0 && pieces[index - 1].device_writes && !pieces[index].device_writes))
			return (ERX_EINVAL);
	if (w->broken)
		return (ERX_ECORRUPT);
	if (w->holdings == w->size) {
		reached[REACH_FULL_BUFFERS]++;
		return (ERX_EWOULDBLOCK);
	}
	if (w->free_descs < count) {
		reached[REACH_FULL_DESCS]++;
		return (ERX_EWOULDBLOCK);
	}
	if (avail_held(w)) {
		reached[REACH_FULL_AVAIL]++;
		return (ERX_EWOULDBLOCK);
	}
	reached[REACH_FOUR] += count == 4;
	return (ERX_OK);
}

static void
post(world_t *w, const erx_dma_piece_t *pieces, uint32_t count)
{
	const uint64_t tag = 0x7a00u + w->posts;
	const int expected = expected_post(w, pieces, count);
	const erx_split_ring_t before = w->ring;
	erx_dma_sequence_t sequence;
	const int status = erx_split_ring_post(&w->ring, pieces, count, tag, &sequence);

	EXPECT(status == expected, "a post answers as the model says");
	if (status != ERX_OK) {
		EXPECT(memcmp(&before, &w->ring, sizeof(before)) == 0, "a refused post changes nothing");
		return;
	}
	apply(w, &sequence, pieces);
	fetch(w, pieces, count, tag);
	w->posts++;
	w->holdings++;
	w->free_descs -= count;
}

/* The device writes a used element, and its used index past it. */
static void
device_used(world_t *w, uint32_t id, uint32_t len, element_t expected)
{
	const uint64_t used = ring_at(w->queue_device);
	const erx_virtq_used_elem_t record = { .id = id, .len = len };

	memcpy(&w->memory[used + ERX_VIRTQ_RING_HEAD_SIZE + (uint64_t)(w->used_idx % w->size) * ERX_VIRTQ_USED_ELEM_SIZE], &record,
	    sizeof(record));
	w->used_idx++;
	store16(w, used + ERX_VIRTQ_RING_HEAD_OFF_IDX, w->used_idx);
	w->pending[w->pending_count++] = expected;
}

/* The device completes fetched chain `which`, writing `len` bytes of a pattern of its own. */
static void
device_complete(world_t *w, uint32_t which, uint32_t len)
{
	const fetched_t chain = w->fetched[which];
	const uint8_t pattern = (uint8_t)(0xa0u + w->next_pattern++);
	const bool valid = len <= chain.writable;

	if (valid)
		memset(&w->memory[chain.written], pattern, len);
	device_used(w, chain.head, len, (element_t){ .valid = valid, .head = chain.head, .avail_slot = chain.avail_slot,
	    .desc_count = chain.desc_count, .tag = chain.tag, .written = chain.written, .len = len, .pattern = pattern });
	memmove(&w->fetched[which], &w->fetched[which + 1], (w->fetched_count - which - 1) * sizeof(fetched_t));
	w->fetched_count--;
	w->stale_head = chain.head;
	w->stale_valid = true;
}

/*
 * The driver's completion: the used index as one load, the elements it covers read whole from
 * where the ring says, and their answers, each against what the device wrote.
 */
static void
driver(world_t *w, uint32_t most, uint64_t bytes_max)
{
	const erx_dma_table_t *const used = &w->layout.tables[USED];
	const uint16_t index = load16(w, used->region + ERX_VIRTQ_RING_HEAD_OFF_IDX);
	const uint32_t covered = (uint16_t)(index - w->consumed);
	erx_report_record_t elements[SIZE_MAX_HERE + 1];
	erx_split_ring_answer_t answers[SIZE_MAX_HERE + 1];
	uint32_t count, done, expected_done = 0;
	uint64_t answered = 0;
	bool breaks = false;
	int status;

	status = erx_split_ring_acquire(&w->ring, index, most, &count);
	if (w->broken || covered > w->holdings) {
		EXPECT(status == ERX_ECORRUPT, "a broken ring, or a used index past the live chains, is ECORRUPT");
		EXPECT(erx_split_ring_complete(&w->ring, elements, 0, UINT64_MAX, answers, &done) == ERX_ECORRUPT &&
		    done == 0, "a broken ring completes nothing");
		w->broken = true;
		return;
	}
	EXPECT(status == ERX_OK && count == (covered < most ? covered : most), "the acquisition counts what is new");
	EXPECT(erx_split_ring_element(&w->ring, count).length == 0, "no element past the acquisition");
	for (uint32_t k = 0; k < count; k++) {
		const erx_dma_range_t range = erx_split_ring_element(&w->ring, k);

		EXPECT(range.offset == used->first + (uint64_t)((uint16_t)(w->consumed + k) % w->size) * used->stride &&
		    range.length == sizeof(erx_virtq_used_elem_t), "each element at its used slot, read whole");
		memset(&elements[k], 0, sizeof(elements[k]));
		memcpy(&elements[k], &w->memory[range.offset], range.length);
	}
	while (expected_done < count && answered < bytes_max) {
		if (!w->pending[expected_done].valid) {
			breaks = true;
			break;
		}
		answered += w->pending[expected_done++].len;
	}
	reached[REACH_MOST] += covered > most;
	reached[REACH_BYTES] += !breaks && expected_done < count;
	reached[REACH_PARTIAL] += breaks && expected_done > 0;
	status = erx_split_ring_complete(&w->ring, elements, count, bytes_max, answers, &done);
	EXPECT(done == expected_done, "the answers stop at the limits or at a malformed element");
	EXPECT(status == (done == 0 && breaks ? ERX_ECORRUPT : ERX_OK), "ECORRUPT only with no answer");
	for (uint32_t k = 0; k < done; k++) {
		const element_t *const e = &w->pending[k];

		EXPECT(answers[k].tag == e->tag && answers[k].written.offset == e->written &&
		    answers[k].written.length == e->len, "each answer is its chain's tag and the range written");
		for (uint32_t byte = 0; byte < e->len; byte++)
			EXPECT(w->memory[e->written + byte] == e->pattern, "the range holds the device's bytes");
		w->free_descs += e->desc_count;
	}
	memmove(&w->pending[0], &w->pending[done], (w->pending_count - done) * sizeof(element_t));
	w->pending_count -= done;
	w->consumed = (uint16_t)(w->consumed + done);
	w->holdings -= done;
	if (breaks) {
		w->broken = true;
		EXPECT(erx_split_ring_post(&w->ring, (erx_dma_piece_t[]){ { payload, 4, false, false, 0 } }, 1, 0,
		    &(erx_dma_sequence_t){ 0 }) == ERX_ECORRUPT, "a broken ring posts nothing");
	}
}

/* An id that names no live chain's head: a later descriptor of a chain, a stale head, or past the table. */
static uint32_t
bad_id(const world_t *w)
{
	for (uint32_t index = 0; index < w->fetched_count; index++)
		if (w->fetched[index].desc_count > 1) {
			reached[REACH_BAD_LATER_DESC]++;
			return (w->fetched[index].descs[1]);
		}
	if (w->stale_valid) {
		bool live = false;

		for (uint32_t index = 0; index < w->fetched_count; index++)
			live = live || w->fetched[index].head == w->stale_head;
		for (uint32_t index = 0; index < w->pending_count; index++)
			live = live || (w->pending[index].valid && w->pending[index].head == w->stale_head);
		if (!live) {
			reached[REACH_BAD_STALE]++;
			return (w->stale_head);
		}
	}
	reached[REACH_BAD_OUTSIDE]++;
	return (w->size);
}

enum {
	OP_POST_HEADER, OP_POST_WHOLE, OP_POST_FOUR, OP_POST_BAD, OP_DONE_OLDEST, OP_DONE_NEWEST_SHORT, OP_DONE_ALL,
	OP_BAD_LEN, OP_BAD_ID, OP_BAD_INDEX, OP_RESET, OP_INSTALL, OPS
};

static void
step(world_t *w, int op)
{
	/* A block request's shape: a header the device reads, then a status it writes. */
	const erx_dma_piece_t header[2] = { { payload, 8, false, false, 0 }, { NULL, 4, true, false, 0 } };
	const erx_dma_piece_t whole[1] = { { NULL, BUFFER, true, false, 0 } };
	const erx_dma_piece_t four[4] = { { payload, 1, false, false, 0 }, { payload + 1, 1, false, false, 0 },
	    { NULL, 1, true, false, 0 }, { NULL, 2, true, false, 0 } };
	const erx_dma_piece_t empty[2] = { { payload, 8, false, false, 0 }, { NULL, 0, true, false, 0 } };
	const erx_dma_piece_t reversed[2] = { { NULL, 4, true, false, 0 }, { payload, 4, false, false, 0 } };
	const erx_dma_piece_t long_[2] = { { NULL, 40, true, false, 0 }, { NULL, 40, true, false, 0 } };

	switch (op) {
	case OP_POST_HEADER: post(w, header, 2); break;
	case OP_POST_WHOLE: post(w, whole, 1); break;
	case OP_POST_FOUR: post(w, four, 4); break;
	case OP_POST_BAD:
		post(w, empty, 2);
		post(w, reversed, 2);
		post(w, long_, 2);
		post(w, header, 0);
		post(w, four, 5);
		break;
	case OP_DONE_OLDEST:
		if (w->fetched_count > 0)
			device_complete(w, 0, w->fetched[0].writable);
		driver(w, w->size, UINT64_MAX);
		break;
	case OP_DONE_NEWEST_SHORT:
		if (w->fetched_count > 0)
			device_complete(w, w->fetched_count - 1, w->fetched[w->fetched_count - 1].writable / 2);
		driver(w, w->size, UINT64_MAX);
		break;
	case OP_DONE_ALL:
		/* At most two answers a call and a buffer's bytes, so the limits end calls early. */
		while (w->fetched_count > 0)
			device_complete(w, 0, w->fetched[0].writable);
		for (uint32_t round = 0; round <= w->size; round++)
			driver(w, 2, BUFFER);
		EXPECT(w->broken || w->pending_count == 0, "every element is answered within the rounds");
		break;
	case OP_BAD_LEN:
		/* The others answered honestly first, so the answers before the malformed one stand. */
		while (w->fetched_count > 1)
			device_complete(w, 0, w->fetched[0].writable);
		if (w->fetched_count > 0)
			device_complete(w, 0, w->fetched[0].writable + 1);
		driver(w, w->size, UINT64_MAX);
		break;
	case OP_BAD_ID:
		device_used(w, bad_id(w), 0, (element_t){ .valid = false });
		driver(w, w->size, UINT64_MAX);
		break;
	case OP_BAD_INDEX:
		store16(w, ring_at(w->queue_device) + ERX_VIRTQ_RING_HEAD_OFF_IDX,
		    (uint16_t)(w->consumed + w->holdings + 1));
		driver(w, w->size, UINT64_MAX);
		break;
	case OP_RESET:
		reset(w);
		break;
	case OP_INSTALL:
		install(w);
		break;
	}
}

static uint64_t paths;

static void
explore(const world_t *w, int depth)
{
	if (depth == DEPTH) {
		paths++;
		return;
	}
	for (int op = 0; op < OPS; op++) {
		world_t next = *w;

		step(&next, op);
		explore(&next, depth + 1);
	}
}

static void
test_exhaustive(uint32_t size)
{
	static world_t start;

	fresh(&start, size);
	paths = 0;
	explore(&start, 0);
	printf("erx_device_virtio_core: %llu paths of %d operations on a ring of %u\n", (unsigned long long)paths,
	    DEPTH, size);
}

/* Past a u16's wrap of the available and used indexes, each round's chain comes back. */
static void
test_laps(void)
{
	static world_t w;

	fresh(&w, 2);
	for (uint32_t round = 0; round < 70000; round++) {
		step(&w, OP_POST_HEADER);
		step(&w, OP_DONE_OLDEST);
		EXPECT(!w.broken && w.holdings == 0, "each round's chain answered");
	}
}

/* Elements passed beyond the acquisition end the call without breaking the ring. */
static void
test_beyond_acquisition(void)
{
	static world_t w;
	erx_report_record_t elements[2] = { { .virtq_used_elem = { .id = 0, .len = 4 } },
	    { .virtq_used_elem = { .id = 1, .len = 4 } } };
	erx_split_ring_answer_t answers[2];
	uint32_t count, done;

	fresh(&w, 2);
	step(&w, OP_POST_WHOLE);
	step(&w, OP_POST_WHOLE);
	EXPECT(erx_split_ring_acquire(&w.ring, 1, 2, &count) == ERX_OK && count == 1, "one element new");
	elements[0].virtq_used_elem.id = w.fetched[0].head;
	EXPECT(erx_split_ring_complete(&w.ring, elements, 2, UINT64_MAX, answers, &done) == ERX_OK && done == 1,
	    "the one acquired element answered");
	EXPECT(!w.ring.broken && erx_dma_ledger_live(erx_split_ring_ledger(&w.ring)) == 1,
	    "the element past the acquisition is not consumed and breaks nothing");
}

/*
 * A used len past what the chain let the device write is judged before the chain is released:
 * the ring breaks and its ledger still holds the chain's buffer, which the device may still write.
 */
static void
test_bad_len_keeps_chain(void)
{
	static world_t w;
	erx_report_record_t element = { .virtq_used_elem = { .len = UINT32_MAX } };
	erx_split_ring_answer_t answer;
	uint32_t count, done;

	fresh(&w, 2);
	step(&w, OP_POST_WHOLE);
	EXPECT(erx_split_ring_acquire(&w.ring, 1, 1, &count) == ERX_OK && count == 1, "one element new");
	element.virtq_used_elem.id = w.fetched[0].head;
	EXPECT(erx_split_ring_complete(&w.ring, &element, 1, UINT64_MAX, &answer, &done) == ERX_ECORRUPT && done == 0,
	    "a len past the chain's writable bytes is ECORRUPT");
	EXPECT(w.ring.broken && erx_dma_ledger_live(erx_split_ring_ledger(&w.ring)) == 1 &&
	    erx_dma_ledger_buffer_held(erx_split_ring_ledger(&w.ring), 0),
	    "a bad len releases nothing: the chain's buffer stays held");
}

/*
 * A piece naming a region is the device's region entry, which the sequencer encodes from the
 * ledger's record of the region by its name: a store, not a fill, and only of its device's table.
 */
static void
test_region_piece(void)
{
	static world_t w;
	static erx_dma_regions_t regions;
	const erx_dma_persistent_region_t region = { .name = 5, .address = 0x90000000, .length = 0x2000 };
	erx_dma_piece_t pieces[2] = { { NULL, 0, false, true, 6 }, { NULL, 8, true, false, 0 } };
	erx_dma_sequence_t sequence;
	bool entry_stored = false;

	EXPECT(erx_dma_layout_split_ring(2, BUFFER, GRANULE, MEMORY, BASE, 32, &w.layout) &&
	    erx_split_ring_make(&w.ring, &w.layout, &regions), "a ring of a device with regions");
	EXPECT(erx_dma_regions_add(&regions, region) &&
	    erx_dma_regions_add(&regions, (erx_dma_persistent_region_t){ .name = 6, .address = BASE, .length = 0x1000 }),
	    "the device's regions");
	EXPECT(erx_split_ring_post(&w.ring, pieces, 2, 1, &sequence) == ERX_EINVAL,
	    "a region over the queue's own memory, which the queue does not hold");
	pieces[0].region = 7;
	EXPECT(erx_split_ring_post(&w.ring, pieces, 2, 1, &sequence) == ERX_EINVAL, "a region the device does not have");
	pieces[0].region = 5;
	pieces[0].device_writes = true;
	EXPECT(erx_split_ring_post(&w.ring, pieces, 2, 1, &sequence) == ERX_EINVAL, "a region the device writes");
	pieces[0].device_writes = false;
	EXPECT(erx_split_ring_post(&w.ring, pieces, 2, 1, &sequence) == ERX_OK && sequence.fill_count == 1 &&
	    sequence.fills[0].length == 0, "a region's entry is no fill");
	for (uint32_t index = 0; index < sequence.store_count; index++) {
		erx_virtio_gpu_mem_entry_t entry;

		if (sequence.stores[index].length != sizeof(entry))
			continue;
		memcpy(&entry, sequence.stores[index].bytes, sizeof(entry));
		entry_stored |= sequence.stores[index].offset == sequence.fills[0].offset &&
		    entry.addr == region.address && entry.length == region.length;
	}
	EXPECT(entry_stored, "the entry is stored at the piece's place from the region's record");
}

/* A layout without a used ring is not a split ring's. */
static void
test_layout(void)
{
	static world_t w;
	erx_dma_layout_t layout;

	EXPECT(erx_dma_layout_split_ring(2, BUFFER, GRANULE, MEMORY, BASE, 32, &layout), "the layout");
	layout.table_count = 2;
	EXPECT(!erx_split_ring_make(&w.ring, &layout, &no_regions), "a ring needs its used ring");
}

int
main(void)
{
	for (uint32_t byte = 0; byte < BUFFER; byte++)
		payload[byte] = (uint8_t)(byte * 7 + 1);
	test_layout();
	test_beyond_acquisition();
	test_bad_len_keeps_chain();
	test_region_piece();
	test_laps();
	test_exhaustive(2);
	test_exhaustive(4);
	for (int state = 0; state < REACH_COUNT; state++)
		if (reached[state] == 0)
			printf("unreached state %d\n", state);
	for (int state = 0; state < REACH_COUNT; state++)
		EXPECT(reached[state] > 0, "the search reaches every state it is meant to");
	printf("erx_device_virtio_core done\n");
	return (0);
}
