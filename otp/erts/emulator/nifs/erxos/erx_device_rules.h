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
 *   meanings  each record's structure is a table of the layout that descriptions fill, and its
 *             meaning is one that structure's tables offer;
 *   widths    each free value fits its place, as the meaning's encoder takes it;
 *   names     each reference names a buffer of the pool, as many names as the meaning has
 *             references, each of a buffer's data;
 *   held      no name is of a buffer a live holding holds;
 *   lengths   each reference's length lies inside its buffer from its offset;
 *   room      the run fits: as many unheld records of each table as it describes, the next
 *             record of each table placed in order unheld, and the holding it makes no larger
 *             than a holding holds;
 *   fills     an out segment's bytes go only inside a range a record of the publication names.
 * The calls rule holds by the type: a publication carries records and fills and no other step.
 * The bindings, reach and controls rules, and the releases rule over acquired reports, belong
 * to the forms and the sequencer that move onto this check after the split ring.
 */

#ifndef ERX_DEVICE_RULES_H
#define ERX_DEVICE_RULES_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"

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

/* An out segment's `length` bytes, stored into `buffer` from `offset`. */
typedef struct erx_dma_fill {
	uint32_t	buffer;
	uint64_t	offset;
	uint64_t	length;
} erx_dma_fill_t;

/* What a decision that hands over describes: its records, in the order of the run, and its fills. */
typedef struct erx_dma_publication {
	uint32_t			record_count;
	const erx_dma_description_t	*records;
	uint32_t			fill_count;
	const erx_dma_fill_t		*fills;
} erx_dma_publication_t;

/* The rule a publication breaks first, or ERX_DMA_PASSES. */
typedef enum erx_dma_verdict {
	ERX_DMA_PASSES,
	ERX_DMA_BREAKS_MEANINGS,
	ERX_DMA_BREAKS_WIDTHS,
	ERX_DMA_BREAKS_NAMES,
	ERX_DMA_BREAKS_HELD,
	ERX_DMA_BREAKS_LENGTHS,
	ERX_DMA_BREAKS_ROOM,
	ERX_DMA_BREAKS_FILLS,
} erx_dma_verdict_t;

erx_dma_verdict_t	erx_dma_publication_check(const erx_dma_ledger_t *ledger,
			    const erx_dma_publication_t *publication);

/*
 * The buffers a publication's names reach, each once, in the order first named: what its holding
 * hands to the device, which erx_dma_ledger_hold takes from here and the room rule bounds, so the
 * two never disagree. One publication may name one buffer at several ranges, as a split ring's
 * chain names its head's buffer. False when there are more than a holding holds.
 */
bool	erx_dma_publication_buffers(const erx_dma_publication_t *publication,
	    uint32_t buffers[ERX_DMA_HELD_BUFFERS_MAX], uint32_t *count);

#endif /* ERX_DEVICE_RULES_H */
