/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The split ring's form core (otp/erts/emulator/nifs/erxos/erx_device_virtio_core.h) over the
 * sequencer, against a hostile device and any post's pieces. The input is a script: a byte, the
 * ring's size as a power of two (its value mod 9); a u16, one less than its buffers' size; a
 * byte whose bit 0 picks a granule of 4096 rather than 64 and whose bit 1 puts the memory at the
 * very top of the device's address space; then operations, each an opcode byte and its operands:
 *
 *   0  post: a count byte (mod 6), then per piece a length u16 and a byte whose bit 0 lets the
 *      device write it
 *   1  the used index: any u16, as a device may write it, and a byte, the most to cover (mod 33)
 *   2  the used index: the elements consumed plus a byte, as an honest device would, and a most
 *   3  a completion: a count byte, then per element a byte whose bit 0 makes it honest (the head
 *      of a posted chain picked by a u8, with a length u32 cut to the chain's writable bytes
 *      when bit 31 is clear) or raw (any u32 id and u32 len), then a u32 of bytes_max
 *   4  reset
 *
 * The harness keeps its own record of every chain posted, by its buffer, and checks after each
 * step: a post passes only with 1..ERX_DEVICE_CHAIN_MAX pieces, none empty, none read after one
 * written, fitting a buffer together, and always when it is valid and the ring has room; its
 * descriptors, decoded from the sequence's stores, name a buffer no posted chain holds, from its
 * first byte, end to end, each piece's length and direction; every range the sequence writes or
 * cleans lies inside the memory; a refused post changes nothing. A completion answers only chains
 * posted and not answered, with their tags, from the first byte the device may write and no
 * further than the chain let it, in no more answers than the elements given or acquired, stopping
 * once bytes_max are answered; a broken ring refuses everything until its reset.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_virtio_core.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define FUZZ_BASE	UINT64_C(0x40000000)
#define MOST_MAX	33u

typedef struct shadow_chain {
	bool		posted;
	uint64_t	tag;
	uint32_t	head;
	uint32_t	desc_count;
	uint32_t	avail_slot;
	uint64_t	written;	/* the memory offset of the first byte the device may write */
	uint32_t	writable;
} shadow_chain_t;

typedef struct script {
	const uint8_t	*bytes;
	size_t		left;
} script_t;

static erx_split_ring_t ring, before;
/* The device's region table, empty: the fuzzer posts no region piece (test_region_piece covers them). */
static const erx_dma_regions_t no_regions;
static erx_dma_layout_t layout;
static shadow_chain_t shadow[ERX_DEVICE_QUEUE_SIZE_MAX];
static uint32_t posted_count, acquired, posts;
static uint16_t consumed;
static uint64_t next_tag;
static const uint8_t out_bytes[ERX_DEVICE_BUFFER_MAX];

static void
check(bool condition)
{
	if (!condition)
		abort();
}

static uint64_t
take(script_t *script, size_t bytes)
{
	uint64_t value = 0;

	for (size_t index = 0; index < bytes && script->left > 0; index++, script->left--, script->bytes++)
		value |= (uint64_t)script->bytes[0] << (8 * index);
	return (value);
}

static bool
inside(erx_dma_range_t range)
{
	return (erx_dma_inside(range.offset, range.length, layout.memory_size));
}

static void
forget_all(void)
{
	memset(shadow, 0, sizeof(shadow));
	posted_count = acquired = posts = 0;
	consumed = 0;
}

/* Whether virtio's rules and the buffer's size let the pieces post at all. */
static bool
pieces_valid(const erx_dma_piece_t *pieces, uint32_t count)
{
	uint64_t total = 0;

	if (count == 0 || count > ERX_DEVICE_CHAIN_MAX)
		return (false);
	for (uint32_t index = 0; index < count; index++) {
		total += pieces[index].length;
		if (pieces[index].length == 0 || (index > 0 && pieces[index - 1].device_writes && !pieces[index].device_writes))
			return (false);
	}
	return (total <= layout.pool.size);
}

/*
 * Whether the ring has room for a chain of `count`: a free buffer, as many free descriptors and
 * the next available entry no posted chain holds.
 */
static bool
room(uint32_t count)
{
	const erx_dma_ledger_t *const ledger = erx_split_ring_ledger(&ring);
	const uint32_t size = layout.tables[erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_DESC)].count;
	uint32_t held = 0;

	for (uint32_t buffer = 0; buffer < layout.pool.count; buffer++) {
		if (!shadow[buffer].posted)
			continue;
		held += shadow[buffer].desc_count;
		if (shadow[buffer].avail_slot == posts % size)
			return (false);
	}
	return (posted_count < layout.pool.count && size - held >= count);
}

/* The posted chain's descriptors, as the sequence stores them, against its pieces. */
static void
check_posted(const erx_dma_sequence_t *sequence, const erx_dma_piece_t *pieces, uint32_t count, uint64_t tag)
{
	const erx_dma_table_t *const desc = &layout.tables[erx_dma_ledger_table(erx_split_ring_ledger(&ring),
	    ERX_STRUCTURE_VIRTQ_DESC)];
	shadow_chain_t chain = { .posted = true, .tag = tag, .desc_count = count, .avail_slot = posts % desc->count };
	uint64_t buffer_start = 0, at = 0;
	uint32_t buffer = 0, fills = 0;
	bool writing = false;

	check(sequence->store_count == count + 1 && sequence->fill_count <= count);
	for (uint32_t index = 0; index < sequence->zero_count; index++)
		check(inside(sequence->zeros[index]));
	for (uint32_t index = 0; index < sequence->fill_count; index++)
		check(inside(sequence->fills[index]) && sequence->fills[index].length == pieces[index].length &&
		    !pieces[index].device_writes);
	for (uint32_t index = 0; index < sequence->clean_count; index++)
		check(inside(sequence->cleans[index]));
	check(erx_dma_inside(sequence->activation.store.offset, sequence->activation.store.length, layout.memory_size));
	for (uint32_t index = 0; index < count; index++) {
		const erx_dma_store_t *const store = &sequence->stores[index];
		erx_virtq_desc_t record;
		uint64_t offset;

		check(store->length == sizeof(record) && store->offset >= desc->first &&
		    store->offset - desc->first < (uint64_t)desc->count * desc->stride &&
		    (store->offset - desc->first) % desc->stride == 0);
		memcpy(&record, store->bytes, sizeof(record));
		check(record.addr >= layout.device_base + layout.pool.first);
		offset = record.addr - layout.device_base;
		if (index == 0) {
			check((offset - layout.pool.first) % layout.pool.stride == 0);
			buffer = (uint32_t)((offset - layout.pool.first) / layout.pool.stride);
			check(buffer < layout.pool.count && !shadow[buffer].posted);
			buffer_start = at = offset;
			chain.head = (uint32_t)((store->offset - desc->first) / desc->stride);
		}
		check(offset == at && record.len == pieces[index].length && record.len > 0 &&
		    at + record.len <= buffer_start + layout.pool.size);
		check(erx_virtq_desc_flags_write_get(record.flags) == pieces[index].device_writes);
		check(!writing || pieces[index].device_writes);
		if (pieces[index].device_writes) {
			if (!writing)
				chain.written = at;
			writing = true;
			chain.writable += record.len;
		} else {
			fills++;
		}
		at += record.len;
	}
	check(fills == sequence->fill_count);
	if (!writing)
		chain.written = at;
	shadow[buffer] = chain;
	posted_count++;
	posts++;
}

static void
post(script_t *script)
{
	erx_dma_piece_t pieces[ERX_DEVICE_CHAIN_MAX + 1];
	const uint32_t count = (uint32_t)(take(script, 1) % (ERX_DEVICE_CHAIN_MAX + 2));
	const bool broken = ring.broken;
	const uint64_t tag = next_tag++;
	erx_dma_sequence_t sequence;
	int status;

	for (uint32_t index = 0; index < count; index++) {
		pieces[index].length = (uint32_t)take(script, 2);
		pieces[index].device_writes = (take(script, 1) & 1) != 0;
		pieces[index].bytes = pieces[index].device_writes ? NULL : out_bytes;
		pieces[index].names_region = false;
		pieces[index].region = 0;
	}
	before = ring;
	status = erx_split_ring_post(&ring, pieces, count, tag, &sequence);
	if (status != ERX_OK) {
		check(memcmp(&before, &ring, sizeof(ring)) == 0);
		check(status == ERX_EINVAL || status == ERX_EWOULDBLOCK || status == ERX_ECORRUPT);
		check(status != ERX_ECORRUPT || broken);
		check(broken || !pieces_valid(pieces, count) || !room(count));
		return;
	}
	check(!broken && pieces_valid(pieces, count));
	check_posted(&sequence, pieces, count, tag);
}

static void
acquire(uint16_t index, uint32_t most)
{
	const bool broken = ring.broken;
	uint32_t count;
	const int status = erx_split_ring_acquire(&ring, index, most, &count);

	if (status != ERX_OK) {
		check(status == ERX_ECORRUPT && ring.broken);
		return;
	}
	check(!broken && count <= most && count <= erx_dma_ledger_live(erx_split_ring_ledger(&ring)));
	check(erx_split_ring_element(&ring, count).length == 0);
	for (uint32_t k = 0; k < count; k++)
		check(inside(erx_split_ring_element(&ring, k)));
	acquired = count;
}

/* The buffer of a posted chain picked by `pick`, or `pick` itself when none is posted. */
static uint32_t
posted_buffer(uint32_t pick)
{
	for (uint32_t step = 0; step < layout.pool.count; step++) {
		const uint32_t buffer = (pick + step) % layout.pool.count;

		if (shadow[buffer].posted)
			return (buffer);
	}
	return (pick % layout.pool.count);
}

/* The posted chain whose head is `head`: one at most, since no descriptor is in two chains. */
static shadow_chain_t *
posted_chain(uint32_t head)
{
	for (uint32_t buffer = 0; buffer < layout.pool.count; buffer++)
		if (shadow[buffer].posted && shadow[buffer].head == head)
			return (&shadow[buffer]);
	return (NULL);
}

static void
complete(script_t *script)
{
	erx_report_record_t elements[MOST_MAX];
	erx_split_ring_answer_t answers[MOST_MAX];
	const uint32_t count = (uint32_t)(take(script, 1) % MOST_MAX);
	const bool broken = ring.broken;
	uint64_t bytes_max, answered = 0;
	uint32_t done;
	int status;

	for (uint32_t k = 0; k < count; k++) {
		memset(&elements[k], 0, sizeof(elements[k]));
		if ((take(script, 1) & 1) != 0) {
			const shadow_chain_t *const chain = &shadow[posted_buffer((uint32_t)take(script, 1))];
			uint32_t len = (uint32_t)take(script, 4);

			if ((len & 0x80000000u) == 0)
				len %= chain->writable + 1;
			elements[k].virtq_used_elem = (erx_virtq_used_elem_t){ .id = chain->head, .len = len };
		} else {
			elements[k].virtq_used_elem.id = (uint32_t)take(script, 4);
			elements[k].virtq_used_elem.len = (uint32_t)take(script, 4);
		}
	}
	bytes_max = take(script, 4);
	status = erx_split_ring_complete(&ring, elements, count, bytes_max, answers, &done);
	check(done <= count && done <= acquired);
	check(status == (done == 0 && ring.broken ? ERX_ECORRUPT : ERX_OK));
	check(!broken || done == 0);
	for (uint32_t k = 0; k < done; k++) {
		const erx_dma_range_t written = answers[k].written;
		shadow_chain_t *const chain = posted_chain(elements[k].virtq_used_elem.id);

		check(answered < bytes_max && chain != NULL);
		check(chain->tag == answers[k].tag &&
		    written.offset == chain->written && written.length == elements[k].virtq_used_elem.len &&
		    written.length <= chain->writable && inside(written));
		answered += written.length;
		chain->posted = false;
		posted_count--;
	}
	acquired -= done;
	consumed = (uint16_t)(consumed + done);
}

/* The layout of the script's ring, its memory just long enough, from FUZZ_BASE or at the top. */
static void
make(script_t *script)
{
	const uint32_t size = 1u << (take(script, 1) % 9);
	const uint32_t buffer_size = (uint32_t)take(script, 2) + 1;
	const uint32_t bits = (uint32_t)take(script, 1);
	const uint32_t granule = (bits & 1) != 0 ? 4096 : 64;
	uint64_t memory_size;

	check(erx_dma_layout_split_ring(size, buffer_size, granule, UINT64_MAX, 0, 64, &layout));
	memory_size = layout.pool.first + (uint64_t)layout.pool.count * layout.pool.stride;
	check(erx_split_ring_make(&ring, size, buffer_size, granule, memory_size,
	    (bits & 2) != 0 ? UINT64_MAX - memory_size + 1 : FUZZ_BASE, 64, &no_regions));
	layout = *erx_dma_ledger_layout(erx_split_ring_ledger(&ring));
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	script_t script = { .bytes = data, .left = size };
	uint16_t index;

	make(&script);
	forget_all();
	next_tag = 0;
	while (script.left > 0) {
		switch (take(&script, 1) % 5) {
		case 0:
			post(&script);
			break;
		case 1:
			index = (uint16_t)take(&script, 2);
			acquire(index, (uint32_t)(take(&script, 1) % MOST_MAX));
			break;
		case 2:
			index = (uint16_t)(consumed + take(&script, 1));
			acquire(index, (uint32_t)(take(&script, 1) % MOST_MAX));
			break;
		case 3:
			complete(&script);
			break;
		default:
			erx_split_ring_reset(&ring);
			forget_all();
			check(!ring.broken);
			break;
		}
		check(ring.broken || posted_count == erx_dma_ledger_live(erx_split_ring_ledger(&ring)));
	}
	return (0);
}
