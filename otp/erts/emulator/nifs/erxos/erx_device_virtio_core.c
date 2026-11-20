/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The split ring's form core. See erx_device_virtio_core.h.
 *
 * The ERX_DMA_SEED_* macros below plant the faults test/host/erx_device_virtio_core_test.rb
 * shows its harness catches; no build defines them.
 */

#include "erx_device_virtio_core.h"

#include "liberx/backend/core/mem.h"

#ifdef ERX_DMA_SEED_EMPTY_PIECE
#define SEED_EMPTY_PIECE	true
#else
#define SEED_EMPTY_PIECE	false
#endif
#ifdef ERX_DMA_SEED_READ_AFTER_WRITE
#define SEED_READ_AFTER_WRITE	true
#else
#define SEED_READ_AFTER_WRITE	false
#endif
#ifdef ERX_DMA_SEED_NOT_PACKED
#define SEED_NOT_PACKED		true
#else
#define SEED_NOT_PACKED		false
#endif
#ifdef ERX_DMA_SEED_LEN_UNCHECKED
#define SEED_LEN_UNCHECKED	true
#else
#define SEED_LEN_UNCHECKED	false
#endif

/* The layout's table of the used ring, which erx_split_ring_make found there. */
static uint32_t
used_table(const erx_split_ring_t *ring)
{
	return ((uint32_t)erx_dma_ledger_table(&ring->ledger, ERX_STRUCTURE_VIRTQ_USED));
}

bool
erx_split_ring_make(erx_split_ring_t *ring, const erx_dma_layout_t *layout, const erx_dma_regions_t *regions)
{
	erx_dma_ledger_t ledger;

	if (layout->pool.count > ERX_DEVICE_QUEUE_SIZE_MAX || !erx_dma_ledger_make(&ledger, layout, regions) ||
	    erx_dma_ledger_table(&ledger, ERX_STRUCTURE_VIRTQ_DESC) < 0 ||
	    erx_dma_ledger_table(&ledger, ERX_STRUCTURE_VIRTQ_AVAIL) < 0 ||
	    erx_dma_ledger_table(&ledger, ERX_STRUCTURE_VIRTQ_USED) < 0)
		return (false);
	bzero(ring, sizeof(*ring));
	ring->ledger = ledger;
	return (true);
}

void
erx_split_ring_reset(erx_split_ring_t *ring)
{
	erx_dma_ledger_reset(&ring->ledger);
	ring->broken = false;
}

const erx_dma_ledger_t *
erx_split_ring_ledger(const erx_split_ring_t *ring)
{
	return (&ring->ledger);
}

/* A piece's bytes in the buffer: a region's entry is one entry long, whatever the piece says. */
static uint32_t
piece_length(const erx_dma_piece_t *piece)
{
	return (piece->names_region ? ERX_VIRTIO_GPU_MEM_ENTRY_SIZE : piece->length);
}

/* Whether the pieces, end to end, fit in a buffer of `size` bytes, with no sum that can wrap. */
static bool
pieces_fit(const erx_dma_piece_t *pieces, uint32_t count, uint32_t size)
{
	uint32_t offset = 0;

	for (uint32_t index = 0; index < count; index++) {
		if (piece_length(&pieces[index]) > size - offset)
			return (false);
		offset += piece_length(&pieces[index]);
	}
	return (true);
}

/*
 * Virtio's rules for a chain: no piece empty, and every piece the device writes after every
 * one it reads (Virtio 1.2, section 2.7.4.2); a device may answer any other order by asking
 * for a reset. A region's entry is a piece the device reads.
 */
static bool
pieces_virtio_valid(const erx_dma_piece_t *pieces, uint32_t count)
{
	for (uint32_t index = 0; index < count; index++) {
		if (piece_length(&pieces[index]) == 0 && !SEED_EMPTY_PIECE)
			return (false);
		if (pieces[index].names_region && pieces[index].device_writes)
			return (false);
		if (index > 0 && pieces[index - 1].device_writes && !pieces[index].device_writes &&
		    !SEED_READ_AFTER_WRITE)
			return (false);
	}
	return (true);
}

/* The lowest buffer no holding holds; a split ring has one whenever a descriptor is free. */
static bool
free_buffer(const erx_split_ring_t *ring, uint32_t *buffer)
{
	const uint32_t count = erx_dma_ledger_layout(&ring->ledger)->pool.count;

	for (uint32_t candidate = 0; candidate < count; candidate++) {
		if (!erx_dma_ledger_buffer_held(&ring->ledger, candidate)) {
			*buffer = candidate;
			return (true);
		}
	}
	return (false);
}

int
erx_split_ring_post(erx_split_ring_t *ring, const erx_dma_piece_t *pieces, uint32_t count, uint64_t tag,
    erx_dma_sequence_t *sequence)
{
	erx_dma_description_t records[ERX_DEVICE_CHAIN_MAX];
	erx_dma_fill_t fills[ERX_DEVICE_CHAIN_MAX];
	erx_split_ring_chain_t chain = { .tag = tag };
	erx_dma_publication_t publication = { .record_count = count, .records = records, .fills = fills };
	uint32_t buffer, offset = 0;

	/* The refusals in the order the header gives, which erx_device_post's callers see. */
	if (count == 0 || count > ERX_DEVICE_CHAIN_MAX ||
	    !pieces_fit(pieces, count, erx_dma_ledger_layout(&ring->ledger)->pool.size))
		return (ERX_EINVAL);
	if (ring->broken)
		return (ERX_ECORRUPT);
	if (!free_buffer(ring, &buffer))
		return (ERX_EWOULDBLOCK);
	if (!pieces_virtio_valid(pieces, count))
		return (ERX_EINVAL);
	/* Field by field over zeroed records, so the check sees no stale free value. */
	bzero(records, sizeof(records));
	for (uint32_t index = 0; index < count; index++) {
		const erx_dma_piece_t *const piece = &pieces[index];
		const uint32_t length = piece_length(piece);

		records[index].structure = ERX_STRUCTURE_VIRTQ_DESC;
		records[index].meaning = ERX_MEANING_VIRTQ_DESC;
		records[index].described.virtq_desc.len = length;
		records[index].described.virtq_desc.flags_write = piece->device_writes ? 1 : 0;
		records[index].name_count = 1;
		records[index].names[0] = (erx_dma_name_t){ .buffer = buffer, .offset = offset };
		/* The readable pieces come first, so fills[i] is pieces[i]'s, as the header promises. */
		if (piece->device_writes) {
			chain.writable += length;
		} else {
			fills[publication.fill_count++] = (erx_dma_fill_t){
				.kind = piece->names_region ? ERX_DMA_FILL_REGION_ENTRY : ERX_DMA_FILL_BYTES,
				.buffer = buffer, .offset = offset, .length = length, .region = piece->region };
			chain.written_from += length;
		}
		if (!SEED_NOT_PACKED)
			offset += length;
	}
	switch (erx_dma_publish(&ring->ledger, &publication, sequence)) {
	case ERX_DMA_PASSES:
		ring->chains[buffer] = chain;
		return (ERX_OK);
	case ERX_DMA_BREAKS_ROOM:
		return (ERX_EWOULDBLOCK);
	default:
		return (ERX_EINVAL);
	}
}

int
erx_split_ring_acquire(erx_split_ring_t *ring, uint16_t index, uint32_t most, uint32_t *count)
{
	if (ring->broken)
		return (ERX_ECORRUPT);
	if (!erx_dma_acquire(&ring->ledger, used_table(ring), index, most, count)) {
		ring->broken = true;
		return (ERX_ECORRUPT);
	}
	return (ERX_OK);
}

erx_dma_range_t
erx_split_ring_element(const erx_split_ring_t *ring, uint32_t k)
{
	return (erx_dma_acquire_record(&ring->ledger, used_table(ring), k));
}

int
erx_split_ring_complete(erx_split_ring_t *ring, const erx_report_record_t *elements, uint32_t count,
    uint64_t bytes_max, erx_split_ring_answer_t *answers, uint32_t *done)
{
	const erx_dma_pool_t *const pool = &erx_dma_ledger_layout(&ring->ledger)->pool;
	const uint32_t used = used_table(ring);
	uint64_t answered = 0;

	*done = 0;
	if (ring->broken)
		return (ERX_ECORRUPT);
	while (*done < count && answered < bytes_max && erx_dma_ledger_acquired(&ring->ledger, used) > 0) {
		const uint32_t len = elements[*done].virtq_used_elem.len;
		const erx_dma_holding_t *const holding = erx_dma_report_holding(&ring->ledger, used, &elements[*done]);
		erx_split_ring_chain_t chain;
		uint32_t buffer;
		erx_dma_holding_t ended;

		/*
		 * The element is judged whole before its chain is released, so a bad one leaves the
		 * chain held: the device may still write its buffer. The ring's every publication names
		 * one buffer, which the ledger's names rule kept below the pool's count.
		 */
		if (holding == NULL) {
			ring->broken = true;
			break;
		}
		buffer = holding->buffers[0];
		chain = ring->chains[buffer];
		if (len > chain.writable && !SEED_LEN_UNCHECKED) {
			ring->broken = true;
			break;
		}
		/* Cannot refuse: erx_dma_report_holding found the holding it ends. */
		(void)erx_dma_consume(&ring->ledger, used, &elements[*done], &ended);
		answers[*done] = (erx_split_ring_answer_t){ .tag = chain.tag,
		    .written = { .offset = pool->first + (uint64_t)buffer * pool->stride + chain.written_from,
		    .length = len } };
		answered += len;
		(*done)++;
	}
	return (*done == 0 && ring->broken ? ERX_ECORRUPT : ERX_OK);
}
