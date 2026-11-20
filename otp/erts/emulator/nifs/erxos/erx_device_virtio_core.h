/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The split ring's form core over the sequencer (docs/design-device-dma.md, "The descriptor
 * forms", "Publication", "Releases"): what virtio's split virtqueue adds to the check's rules.
 * It reads no hardware and no shared memory, needs nothing of ERTS and builds for the host,
 * where its tests and its fuzz target run.
 *
 * The sequencer places, encodes and releases every record; the ledger says which buffers and
 * descriptors the device holds. What is left to the form is virtio's own meaning of a chain:
 *
 *   post      1..ERX_DEVICE_CHAIN_MAX pieces become one description per piece, each a descriptor
 *             naming the chain's one buffer, packed end to end from its first byte, and a fill
 *             per piece the device reads. No piece is empty, and none the device reads follows
 *             one it writes (Virtio 1.2, section 2.7.4.2), so the fills are the first pieces in
 *             order and the bytes the device writes are one range, from the readable pieces'
 *             end. The buffer is the lowest one no holding holds.
 *   acquire   the used index, loaded once, says how many used elements are new: at most the
 *             live chains (erx_dma_acquire).
 *   complete  each used element, read whole, releases the chain whose head its id names
 *             (erx_dma_consume), and its len is at most what that chain let the device write;
 *             the chain's answer is its tag and the range of its buffer the device wrote.
 *
 * Anything else a device writes breaks the ring: every later post, acquisition and completion
 * fails with ERX_ECORRUPT until the reset, so a malformed element never lets a buffer the
 * device may still write be posted again. The ring keeps, per buffer, what it posted there;
 * whether that is live is the ledger's, never the ring's own: a buffer's chain is live while a
 * holding holds the buffer.
 */

#ifndef ERX_DEVICE_VIRTIO_CORE_H
#define ERX_DEVICE_VIRTIO_CORE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_sequencer.h"

/* What the ring posted in a buffer: the tag to give back and the range the device may write. */
typedef struct erx_split_ring_chain {
	uint64_t	tag;
	uint32_t	written_from;	/* the readable pieces' end, from the buffer's first byte */
	uint32_t	writable;	/* the device-writable pieces' sum, which a used len may not pass */
} erx_split_ring_chain_t;

/*
 * One split ring. Its fields are the module's: callers read the ledger through
 * erx_split_ring_ledger and change the ring only through the calls below.
 */
typedef struct erx_split_ring {
	erx_dma_ledger_t	ledger;
	bool			broken;
	erx_split_ring_chain_t	chains[ERX_DEVICE_QUEUE_SIZE_MAX];	/* by buffer */
} erx_split_ring_t;

/* A completed chain: its tag, and where in the ring's memory the bytes the device wrote lie. */
typedef struct erx_split_ring_answer {
	uint64_t	tag;
	erx_dma_range_t	written;	/* its length is the used element's len */
} erx_split_ring_answer_t;

/*
 * An empty ring over `layout`, a split ring's as erx_dma_layout_split_ring makes it. False, writing
 * nothing, for a layout erx_dma_ledger_make refuses, one lacking a descriptor table, an available
 * ring or a used ring, or one of more than ERX_DEVICE_QUEUE_SIZE_MAX buffers.
 */
bool	erx_split_ring_make(erx_split_ring_t *ring, const erx_dma_layout_t *layout);
/* The device's idle report after a reset: every chain ends and the ring is whole again. */
void	erx_split_ring_reset(erx_split_ring_t *ring);
const erx_dma_ledger_t	*erx_split_ring_ledger(const erx_split_ring_t *ring);

/*
 * Posts `count` pieces as one chain tagged `tag` into `sequence`, which the effect layer
 * applies as erx_device_sequencer.h says; sequence->fills[i] is where pieces[i]'s bytes go.
 * ERX_EINVAL, in order, for a count outside 1..ERX_DEVICE_CHAIN_MAX or pieces longer together
 * than a buffer; ERX_ECORRUPT for a broken ring; ERX_EWOULDBLOCK for no free buffer; ERX_EINVAL
 * for an empty piece or one the device reads after one it writes; then ERX_EWOULDBLOCK for too
 * few free descriptors or a held next available entry (the check's room rule), and ERX_EINVAL
 * for any other verdict, a bug of this core. Anything but ERX_OK changes nothing.
 */
int	erx_split_ring_post(erx_split_ring_t *ring, const erx_dma_piece_t *pieces, uint32_t count, uint64_t tag,
	    erx_dma_sequence_t *sequence);

/*
 * The used elements the used index `index`, as one load read it, makes new, at most `most`,
 * into `*count`. ERX_ECORRUPT for a broken ring, or an index past the live chains, which
 * breaks it.
 */
int	erx_split_ring_acquire(erx_split_ring_t *ring, uint16_t index, uint32_t most, uint32_t *count);
/*
 * Where the `k`th element not yet consumed of those the acquisition covered lies, to read whole;
 * empty past them. erx_split_ring_complete's elements[k] is what this gave for k when that call
 * began.
 */
erx_dma_range_t	erx_split_ring_element(const erx_split_ring_t *ring, uint32_t k);

/*
 * Completes the acquired elements `elements`, each read whole, in order, into `answers`, which
 * holds `count`: while one is acquired and fewer than `bytes_max` bytes are answered, so the
 * answers' lengths sum to less than bytes_max plus one buffer. `*done` is how many. An element
 * that names no live chain's head, or whose len passes what its chain let the device write,
 * breaks the ring and ends the call: the answers before it stand. ERX_OK with the answers, or
 * ERX_ECORRUPT, with none, for a broken ring.
 */
int	erx_split_ring_complete(erx_split_ring_t *ring, const erx_report_record_t *elements, uint32_t count,
	    uint64_t bytes_max, erx_split_ring_answer_t *answers, uint32_t *done);

#endif /* ERX_DEVICE_VIRTIO_CORE_H */
