/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Descriptions, and the rules the check judges a publication's by (docs/design-device-dma.md,
 * "The check", "Descriptions", "The rules"). It reads no hardware and no shared memory, needs
 * nothing of ERTS and builds for the host, where its tests run.
 *
 * A core says what it wants and never where: a description names a record's meaning, the
 * values of its free places and, for each reference, a buffer of the pool and an offset into
 * it, never an address, a position or a fixed field. The free places' union, the structure each
 * meaning belongs to, the width of each free place and which free place gives a reference's
 * length are generated from abi/formats into erx/abi.h, so the check holds no copy of a format.
 *
 * erx_dma_publication_check judges a publication against the ledger, before anything is placed
 * or written, and names the first rule it breaks:
 *   calls     its call is one the type offers: a run describes at least one record; an
 *             install describes no record, no fill, no endpoint and no binding and finds the
 *             ledger idle, nothing held, acquired or moved, so no ring it zeroes is one a live
 *             chain is on (that the queue is not ready already is the form core's, as
 *             erx_split_ring_install refuses it); an
 *             install passes on this rule alone, its every step derived from the layout;
 *   meanings  each record's structure is a table of the layout that descriptions fill, and its
 *             meaning is one that structure's tables offer;
 *   widths    each free value fits its place, as the meaning's encoder takes it;
 *   names     each reference names a buffer of the layout, as many names as the meaning has
 *             references, each of a buffer's data;
 *   bindings  a run's records are of one table: the ring the ledger binds to the publication's
 *             endpoint, or, for endpoint 0, its structure's one table that needs no binding;
 *             each name is of a buffer of that table's pool, so a transfer reaches only its own
 *             queue's buffers; the bindings it carries are ones erx_dma_ledger_may_bind allows, so
 *             only a command whose meaning binds carries any, and its run is on a table that needs
 *             none, as a binding command is on the command ring;
 *   reach     a transfer's endpoint is running, design-usb.md's open queue, and not closed by
 *             the live command; a command's endpoints exist where its reach acts: the endpoint a
 *             stop or a restart names is bound and enabled, each a bind drops is bound and
 *             stopped, or running with no live transfer, and no endpoint of a disable's group is
 *             running with a live transfer, and an endpoint an evaluate holds is running or
 *             stopped with no live transfer (erx_dma_ledger_reach_allows);
 *   held      no name is of a buffer a live holding holds;
 *   lengths   each reference's length lies inside its buffer from its offset;
 *   room      the run fits: as many unheld records of each table placed free as it describes,
 *             the next record of each table placed in order unheld, every position a ring's run
 *             takes, its links included, unheld, no live command on a ring that takes commands
 *             and fewer holdings than its pool's buffers on any other, and the holding it makes no
 *             larger than a holding holds;
 *   fills     at most ERX_DMA_FILLS_MAX fills, an out segment's bytes go only inside a range a
 *             record of the publication names, and no two fills share a byte; a region entry's
 *             fill is one entry long and names a persistent region the ledger holds, so a
 *             region of another device, or none, fails.
 * The controls rule and the releases rule over acquired reports belong to the forms and the
 * sequencer that move onto this check after the split ring.
 */

#ifndef ERX_DEVICE_RULES_H
#define ERX_DEVICE_RULES_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"

/* The most fills a publication carries: a post's out segments, at most a chain's. */
#define ERX_DMA_FILLS_MAX	ERX_DEVICE_CHAIN_MAX

/* A reference as a core names it: a buffer of the pool, and an offset into it. */
typedef struct erx_dma_name {
	uint32_t	buffer;
	uint64_t	offset;
} erx_dma_name_t;

/* One record a core wants, in a table of `structure`: what it means, says and names. */
typedef struct erx_dma_description {
	uint32_t		structure;	/* ERX_STRUCTURE_* */
	uint32_t		meaning;	/* ERX_MEANING_* */
	erx_meaning_free_t	described;	/* the member of `meaning` */
	uint32_t		name_count;
	erx_dma_name_t		names[ERX_MEANING_REFERENCES_MAX];
} erx_dma_description_t;

/* What a fill stores. */
typedef enum erx_dma_fill_kind {
	ERX_DMA_FILL_BYTES,		/* an out segment's bytes, which the effect layer stores */
	ERX_DMA_FILL_REGION_ENTRY,	/* a region entry, which the sequencer encodes */
} erx_dma_fill_kind_t;

/*
 * An out segment's `length` bytes, stored into `buffer` from `offset`. A region entry's fill
 * names its persistent region and no more (docs/design-device-dma.md, "Descriptions"): the
 * sequencer encodes the entry from the ledger's record of that region, never a core's values.
 */
typedef struct erx_dma_fill {
	erx_dma_fill_kind_t	kind;
	uint32_t		buffer;
	uint64_t		offset;
	uint64_t		length;
	uint32_t		region;		/* a region entry's: the persistent region's name */
} erx_dma_fill_t;

/*
 * A publication's call, which says what the sequencer makes live (docs/design-device-dma.md,
 * "Publication"), from this closed set and no other:
 *   RUN      the records it describes, made live by the next entry of the table placed in order;
 *   INSTALL  the queue: every table zeroed and cleaned, the queue's registers from the layout,
 *            made live by the ready bit (erx_device_sequencer.h).
 */
typedef enum erx_dma_publication_call {
	ERX_DMA_PUBLISH_RUN,
	ERX_DMA_PUBLISH_INSTALL,
} erx_dma_publication_call_t;

/*
 * What a decision that hands over describes: its records, in the order of the run, its fills and
 * its call; for a transfer, the endpoint whose ring it runs on; for a command, the endpoints it
 * acts on, and, for one whose meaning binds, the bindings its holding makes (erx_dma_ledger_hold);
 * for a command whose TRB names the input context, the parameters its caller states, from which
 * the sequencer writes it (erx_dma_input_context), and NULL for any other publication.
 */
typedef struct erx_dma_publication {
	uint32_t			record_count;
	const erx_dma_description_t	*records;
	uint32_t			fill_count;
	const erx_dma_fill_t		*fills;
	erx_dma_publication_call_t	call;
	uint32_t			endpoint;
	uint32_t			bind_count;
	erx_dma_binding_t		binds[ERX_DMA_BINDS_MAX];
	erx_dma_reach_t			reach;
	const erx_device_trb_contexts_t	*contexts;
} erx_dma_publication_t;

/* The rule a publication breaks first, or ERX_DMA_PASSES. */
typedef enum erx_dma_verdict {
	ERX_DMA_PASSES,
	ERX_DMA_BREAKS_CALLS,
	ERX_DMA_BREAKS_MEANINGS,
	ERX_DMA_BREAKS_WIDTHS,
	ERX_DMA_BREAKS_NAMES,
	ERX_DMA_BREAKS_HELD,
	ERX_DMA_BREAKS_LENGTHS,
	ERX_DMA_BREAKS_ROOM,
	ERX_DMA_BREAKS_FILLS,
	ERX_DMA_BREAKS_BINDINGS,
	ERX_DMA_BREAKS_REACH,
} erx_dma_verdict_t;

erx_dma_verdict_t	erx_dma_publication_check(const erx_dma_ledger_t *ledger,
			    const erx_dma_publication_t *publication);

/*
 * The table a run is placed in, as the bindings rule gives it: the ring bound to the publication's
 * endpoint, or for endpoint 0 the one table of its first record's structure that needs no binding;
 * -1 for none.
 */
int	erx_dma_run_table(const erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication);

/*
 * The buffers a publication's names reach, each once, in the order first named: what its holding
 * hands to the device, which erx_dma_ledger_hold takes from here and the room rule bounds, so the
 * two never disagree. One publication may name one buffer at several ranges, as a split ring's
 * chain names its head's buffer. False when there are more than a holding holds.
 */
bool	erx_dma_publication_buffers(const erx_dma_publication_t *publication,
	    uint32_t buffers[ERX_DMA_HELD_BUFFERS_MAX], uint32_t *count);

#endif /* ERX_DEVICE_RULES_H */
