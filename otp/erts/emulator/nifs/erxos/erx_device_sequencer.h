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
 * derives the activation and begins the publication's holding. A binding command's publication
 * also zeroes the ring it binds, writes the ring's link on lap 0 and cleans the ring, all before
 * the command's activation, as the holding binds it. An install places nothing and
 * begins no holding: it zeroes and cleans every table, derives the queue's size and its rings'
 * device addresses from the layout, and activates with the ready bit, so no ring is live before
 * it is zero in memory. What it returns is applied as:
 *   1. the zeros: rule 1's, every byte of a buffer passing to the device that no fill covers, and
 *      the whole region of an install's tables and of a ring a binding command binds;
 *   2. the fills, the publication's `out` bytes, at the offsets given here; a region entry's
 *      fill is empty here, since its entry is a store;
 *   3. the stores, each record whole, region entries included;
 *   4. the cleans, every range passing to the device, then the publish barrier;
 *   5. an install's registers, in order, after the queue's select, which the effect layer writes
 *      first from the record, since it banks them (Virtio 1.2, section 4.2.2);
 *   6. the activation: a run's one store, the clean of its line, then the doorbell; an install's
 *      ready bit.
 *
 * An acquisition reads a structure the device writes in two phases: the validity (a used ring's
 * index, or each event TRB's cycle bit from the consumer position on) gives how many records it
 * covers, then each record is read whole and consumed in order.
 * A record's meaning comes from its selector through the generated erx_report_meaning, and what
 * it ends from its meaning's `releases` mark through erx_report_releases. A record whose selector
 * names no meaning, or that releases no live holding, is refused, and the queue breaks: the
 * sequencer cannot tell what it would release, and a skip would consume a report the design
 * gives no meaning. A record whose meaning releases nothing, or one the form judges the design
 * gives no release, such as a short data stage's event, is passed: consumed, ending nothing.
 */

#ifndef ERX_DEVICE_SEQUENCER_H
#define ERX_DEVICE_SEQUENCER_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_rules.h"

/* The widest record the sequencer writes: an input context's context (xHCI 1.2, 6.2.5, p. 460). */
#define ERX_DMA_STORE_BYTES_MAX		32u
/*
 * The contexts of an input context a publication carries: the input control context, the slot
 * context, and an endpoint context for each binding, or EP0's for Evaluate Context, which binds
 * none (erx_dma_input_context).
 */
#define ERX_DMA_INPUT_PARTS_MAX		(2u + ERX_DMA_BINDS_MAX)
/* Each record of a run, its available entry, a region entry for each fill, each binding's link and the input context. */
#define ERX_DMA_STORES_MAX		(ERX_DMA_HELD_RECORDS_MAX + ERX_DMA_FILLS_MAX + ERX_DMA_BINDS_MAX + ERX_DMA_INPUT_PARTS_MAX)
/* Rule 1 leaves at most one gap before each fill of a buffer and one after the last; each binding's ring. */
#define ERX_DMA_ZEROS_MAX		(ERX_DMA_HELD_BUFFERS_MAX + ERX_DMA_FILLS_MAX + ERX_DMA_BINDS_MAX)
/* Each buffer passing to the device, each record and the available entry, and each binding's ring. */
#define ERX_DMA_CLEANS_MAX		(ERX_DMA_HELD_BUFFERS_MAX + ERX_DMA_HELD_RECORDS_MAX + ERX_DMA_BINDS_MAX)
/* An install's queue size and three ring addresses. */
#define ERX_DMA_REGISTERS_MAX		4u

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

/*
 * A register an install writes, by what it says, virtio-mmio's (Virtio 1.2, section 4.2.2). The
 * effect layer maps each to the register of its device it owns (erx_device.c), and writes an
 * address as its low word's register, then its high word's.
 */
typedef enum erx_dma_register {
	ERX_DMA_VIRTQ_NUM,	/* the queue's size, its tables' count */
	ERX_DMA_VIRTQ_DESC,	/* the descriptor table's device address */
	ERX_DMA_VIRTQ_DRIVER,	/* the available ring's */
	ERX_DMA_VIRTQ_DEVICE,	/* the used ring's */
	ERX_DMA_VIRTQ_READY,	/* 1: an install's activation */
} erx_dma_register_t;

typedef struct erx_dma_register_write {
	erx_dma_register_t	reg;
	uint64_t		value;
} erx_dma_register_write_t;

/* The one write that makes a publication live: a run's store into memory, or an install's register. */
typedef enum erx_dma_activation_kind {
	ERX_DMA_ACTIVATE_STORE,
	ERX_DMA_ACTIVATE_REGISTER,
} erx_dma_activation_kind_t;

typedef struct erx_dma_activation {
	erx_dma_activation_kind_t	kind;
	erx_dma_store_t			store;	/* ERX_DMA_ACTIVATE_STORE's */
	erx_dma_register_write_t	reg;	/* ERX_DMA_ACTIVATE_REGISTER's */
} erx_dma_activation_t;

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
	uint32_t		register_count;
	erx_dma_register_write_t	registers[ERX_DMA_REGISTERS_MAX];
	erx_dma_activation_t	activation;
} erx_dma_sequence_t;

/*
 * Judges `publication` and, when it passes, sequences it into `sequence` and begins its holding
 * in `ledger`; an install begins none. Any other verdict changes neither: it is a bug in the form's core, and the call
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
 * it, would end, without ending it, so a form judges the rest of the record first; its pointer
 * NULL where erx_dma_consume would refuse it. The pointer is the ledger's, valid until the
 * ledger changes; erx_dma_consume ends the holding only while it is live (erx_dma_found_t).
 */
erx_dma_found_t		erx_dma_report_holding(const erx_dma_ledger_t *ledger, uint32_t reports,
			    const erx_report_record_t *record);

/*
 * Consumes the record at the consumer position of table `reports`, ending the holding `found`
 * names, as erx_dma_report_holding gave it for that record, so the record is decoded once and
 * judged whole before anything ends. False, changing nothing, which breaks the queue, for a
 * NULL holding (a record past what the acquisition covered, one whose selector names no meaning,
 * one that releases nothing the split ring knows, or one naming no live holding) or one that has
 * ended since it was found (erx_dma_ledger_release_holding).
 */
bool	erx_dma_consume(erx_dma_ledger_t *ledger, uint32_t reports, erx_dma_found_t found);
/*
 * Where the cycle word of the record `k` places past the consumer position of table `reports`, an
 * event ring, lies, for the validity's one load of each; empty past one lap or for a table the
 * device does not write as an event ring.
 */
erx_dma_range_t	erx_dma_validity_word(const erx_dma_ledger_t *ledger, uint32_t reports, uint32_t k);
/*
 * The validity of table `reports`, an event ring, from `word_count` cycle words read at the places
 * erx_dma_validity_word gave, in order: the leading records whose cycle bit is the ledger's consumer
 * cycle state there, which toggles where the position wraps, stopping at the first that is not,
 * into `*count`, kept in the ledger as what may be consumed. A record not yet written is never
 * covered. False, changing nothing, for a table that is not an event ring or more words than its
 * records.
 */
bool	erx_dma_acquire_cycles(erx_dma_ledger_t *ledger, uint32_t reports, const uint32_t *words, uint32_t word_count,
	    uint32_t *count);
/*
 * Consumes the record at the consumer position of table `reports`, as the acquisition read it,
 * ending nothing (erx_dma_ledger_pass): one whose meaning releases nothing, or one whose release
 * names a record a live holding holds but not its head, as a short data stage's event names its
 * data stage. False, changing nothing, which breaks the queue, for a record past what the
 * acquisition covered, one whose selector names no meaning, or a release naming a live holding's
 * head, which only erx_dma_consume consumes, or a record no live holding holds.
 */
bool	erx_dma_pass(erx_dma_ledger_t *ledger, uint32_t reports, const erx_report_record_t *record);
/*
 * The device address of the record at the consumer position of table `reports`: what the event
 * ring's dequeue register names once a decision has consumed its reports; 0 for a table the
 * layout lacks.
 */
uint64_t	erx_dma_dequeue_address(const erx_dma_ledger_t *ledger, uint32_t reports);

/*
 * What the core posting a command derives for its input context, never its caller: whether the
 * slot context is carried (Address Device, Configure Endpoint) with its Context Entries, the drop
 * flags, and, by device context index, each carried endpoint's TR Dequeue Pointer with its cycle
 * state in bit 0, the endpoint context's dequeue word. A publication's are the sequencer's own,
 * from the publication's meaning, bindings and drops and the ledger's rings.
 */
typedef struct erx_dma_context_derivation {
	bool		slot;
	uint32_t	entries;
	uint32_t	drop;
	uint64_t	dequeue[ERX_XHCI_DEVICE_CONTEXTS];
} erx_dma_context_derivation_t;

/* One context of an input context: its offset from the input context's start, its endpoint's index or 0, its bytes. */
typedef struct erx_dma_context_part {
	uint32_t	offset;
	uint32_t	dci;
	uint8_t		bytes[ERX_XHCI_SLOT_CONTEXT_SIZE];
} erx_dma_context_part_t;

/* The input control context, the slot context and an endpoint context for each index (xHCI 1.2, 6.2.5, p. 460). */
#define ERX_DMA_CONTEXT_PARTS_MAX	(1u + ERX_XHCI_DEVICE_CONTEXTS)

/*
 * The one composition of the input context (xHCI 1.2, 6.2.5, Figure 6-5, p. 460), every context
 * through its layout's generated encoder, into `parts`; their count, or 0 for a refusal. Context k
 * lies at k times the context size, the input control context first and the slot context next, so
 * endpoint context dci at dci + 1 (6.2.5, p. 460, with 64-byte contexts at 40h apart); each part
 * is the context's first 32 bytes, the rest of a 64-byte context reserved and zero (6.2.2,
 * p. 447; 6.2.3, p. 453; 6.2.5.1, p. 461), as is every byte no part covers. The add flags are
 * the contexts written, A0 with the slot context and A(dci) with each endpoint context, so a flag
 * never names a context left zero (Table 6-16, p. 461); the drop flags, Context Entries and each
 * dequeue word are `derived`'s; the average TRB length 8 for a control endpoint and otherwise the
 * packet times the burst plus one (Table 6-11, p. 453; 4.14.1.1, p. 258). Refused: a context size
 * other than 32 or 64, more endpoints than ERX_DEVICE_TRB_DCI_MAX, an index outside 1..31 or
 * written twice, drop flags on indexes 0 and 1 (Table 6-15, p. 461), and a value its encoder
 * refuses. An index both dropped and added is Configure Endpoint's drop-and-add (4.6.6, p. 120).
 */
uint32_t	erx_dma_input_context(const erx_device_trb_contexts_t *stated, const erx_dma_context_derivation_t *derived,
		    erx_dma_context_part_t parts[ERX_DMA_CONTEXT_PARTS_MAX]);

#endif /* ERX_DEVICE_SEQUENCER_H */
