/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The sequencer (docs/design-device-dma.md, "The check", "Publication", "Releases"): the one
 * writer of every record a device reads and the one reader of every record it writes. It is a
 * pure function over the ledger: it reads no hardware and no shared memory, needs nothing of
 * ERTS and builds for the host, where its tests run. The effect layer applies what it returns,
 * in the order this header gives, and stores nothing else into a region holding a structure.
 *
 * A publication is judged by erx_dma_publication_check, then the sequencer places its run (each
 * description at a free record of its table, chained in the plan's order; each table placed in
 * order at its position), encodes every record whole through its meaning's generated encoder,
 * and each region entry through its layout's from the ledger's record of the region it names,
 * derives the activation and begins the publication's holding. What it returns is applied as:
 *   1. the zeros, rule 1: every byte of a buffer passing to the device that no fill covers;
 *   2. the fills, the publication's `out` bytes, at the offsets given here; a region entry's
 *      fill is empty here, since its entry is a store;
 *   3. the stores, each record whole, region entries included;
 *   4. the cleans, every range passing to the device, then the publish barrier;
 *   5. the activation, one store, and the clean of its line; then the doorbell.
 *
 * An acquisition reads a structure the device writes in two phases: the validity (a used ring's
 * index) gives how many records it covers, then each record is read whole and consumed in order.
 * A record's meaning comes from its selector through the generated erx_report_meaning, and what
 * it ends from its meaning's `releases` mark through erx_report_releases. A record whose selector
 * names no meaning, or that releases no live holding, is refused, and the queue breaks: the
 * sequencer cannot tell what it would release, and a skip would consume a report the design
 * gives no meaning.
 */

#ifndef ERX_DEVICE_SEQUENCER_H
#define ERX_DEVICE_SEQUENCER_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_rules.h"

/* The widest record the sequencer writes: a descriptor or a region entry. */
#define ERX_DMA_STORE_BYTES_MAX		16u
/* Each record of a run, its available entry, and a region entry for each fill. */
#define ERX_DMA_STORES_MAX		(ERX_DMA_HELD_RECORDS_MAX + ERX_DMA_FILLS_MAX)
/* Rule 1 leaves at most one gap before each fill of a buffer and one after the last. */
#define ERX_DMA_ZEROS_MAX		(ERX_DMA_HELD_BUFFERS_MAX + ERX_DMA_FILLS_MAX)
/* Each buffer passing to the device, each record and the available entry. */
#define ERX_DMA_CLEANS_MAX		(ERX_DMA_HELD_BUFFERS_MAX + ERX_DMA_HELD_RECORDS_MAX)

/* `length` bytes from `offset` of the record's memory. */
typedef struct erx_dma_range {
	uint64_t	offset;
	uint64_t	length;
} erx_dma_range_t;

/* One store: `length` bytes of `bytes`, at `offset` of the record's memory. */
typedef struct erx_dma_store {
	uint64_t	offset;
	uint32_t	length;
	uint8_t		bytes[ERX_DMA_STORE_BYTES_MAX];
} erx_dma_store_t;

/* What a publication applies, in the header's order; fills[i] is publication->fills[i]'s place. */
typedef struct erx_dma_sequence {
	uint32_t		zero_count;
	erx_dma_range_t		zeros[ERX_DMA_ZEROS_MAX];
	uint32_t		fill_count;
	erx_dma_range_t		fills[ERX_DMA_FILLS_MAX];
	uint32_t		store_count;
	erx_dma_store_t		stores[ERX_DMA_STORES_MAX];
	uint32_t		clean_count;
	erx_dma_range_t		cleans[ERX_DMA_CLEANS_MAX];
	erx_dma_store_t		activation;
} erx_dma_sequence_t;

/*
 * Judges `publication` and, when it passes, sequences it into `sequence` and begins its holding
 * in `ledger`. Any other verdict changes neither: it is a bug in the form's core, and the call
 * is badarg with nothing applied.
 */
erx_dma_verdict_t	erx_dma_publish(erx_dma_ledger_t *ledger, const erx_dma_publication_t *publication,
			    erx_dma_sequence_t *sequence);

/*
 * The validity of table `reports`, a used ring: the records its device-written index `index`
 * covers from the ledger's consumer position, at most `most`, into `*count`, kept in the ledger
 * as what erx_dma_consume may consume (erx_dma_ledger_acquire). False, changing nothing, when it
 * covers more than the live holdings, a malformed index that breaks the queue, or for a table
 * the device does not write.
 */
bool	erx_dma_acquire(erx_dma_ledger_t *ledger, uint32_t reports, uint16_t index, uint32_t most, uint32_t *count);

/*
 * Where the record `k` places past the consumer position of `reports` lies, to read whole;
 * empty past what the acquisition left.
 */
erx_dma_range_t	erx_dma_acquire_record(const erx_dma_ledger_t *ledger, uint32_t reports, uint32_t k);

/*
 * The live holding the record at the consumer position of `reports`, as the acquisition read
 * it, would end, without ending it, so a form judges the rest of the record first; NULL where
 * erx_dma_consume would refuse it. The holding is the ledger's, valid until the ledger changes.
 */
const erx_dma_holding_t	*erx_dma_report_holding(const erx_dma_ledger_t *ledger, uint32_t reports,
			    const erx_report_record_t *record);

/*
 * Consumes the record at the consumer position of table `reports`, as the acquisition read it,
 * and ends the holding it releases into `*ended`. False, changing nothing, for a record past
 * what the acquisition covered, one whose selector names no meaning, one that releases nothing
 * the split ring knows, or one naming no live holding: the queue breaks.
 */
bool	erx_dma_consume(erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record,
	    erx_dma_holding_t *ended);

#endif /* ERX_DEVICE_SEQUENCER_H */
