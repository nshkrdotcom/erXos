/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The ledger of a queue's DMA memory (docs/design-device-dma.md, "The check", "The ledger"):
 * the one value the check and the sequencer judge and change, and nothing else does. It reads
 * no hardware and no shared memory, needs nothing of ERTS and builds for the host, where its
 * tests run.
 *
 * The layout says what the memory holds: tables, each a region of whole granules holding one
 * structure of abi/formats, its record count and stride; and the pool, `count` buffers at a
 * stride of whole granules. It is checked once, when a ledger is made from it, and never
 * changes after: every region whole granules, ascending, disjoint, inside the memory and below
 * the form's address width.
 *
 * A holding is one publication the device may still act on: the records it made live and the
 * buffers it handed to the device. Its first record, its head, is what the report that ends it
 * names. The ledger keeps the live holdings and, for each table placed in order and each the
 * device writes, its position. Its state machine has two transitions, and each refuses,
 * changing nothing, what the design's order forbids:
 *   hold     begins the holding of a publication from the records the sequencer placed it in
 *            and the buffers its names reach, each once, taken from the publication itself so
 *            no buffer it names goes to the device unheld: none of them is held already, its
 *            records of a table placed in order are the next ones from that table's position,
 *            which moves past them, and it holds no record of a table the device writes;
 *   release  ends the live holding a report names, from the report table's consumer position,
 *            which moves past it; a report naming no live holding's head ends nothing.
 * The idle report after a reset ends every holding (erx_dma_ledger_reset). A region's writer
 * is derived from the holdings, never stated: a buffer is the device's while a holding holds
 * it, and a table is its structure's writer, as abi/formats declares it.
 *
 * Offsets are bytes from the start of the record's memory; a device address is the record's
 * device base plus an offset.
 */

#ifndef ERX_DEVICE_LEDGER_H
#define ERX_DEVICE_LEDGER_H

#include <stdbool.h>
#include <stdint.h>

#include "erx_device_dma.h"

/* Bounds of this record's queues: three tables (virtio's split ring), and one chain's records and buffers. */
#define ERX_DMA_TABLES_MAX		3u
#define ERX_DMA_HELD_RECORDS_MAX	(ERX_DEVICE_CHAIN_MAX + 1u)
#define ERX_DMA_HELD_BUFFERS_MAX	ERX_DEVICE_CHAIN_MAX
#define ERX_DMA_HOLDINGS_MAX		ERX_DEVICE_QUEUE_SIZE_MAX

/*
 * How the sequencer places a table's records, as the form's table says (docs/design-device-dma.md,
 * "What each form's tables say"). It applies to a structure the CPU writes; one the device writes,
 * as abi/formats declares, is the device's reports, consumed in order from its position.
 */
typedef enum erx_dma_placing {
	ERX_DMA_PLACED_FREE,	/* a description's record, at any record no holding holds (virtio's descriptors) */
	ERX_DMA_PLACED_IN_ORDER,	/* the sequencer's own, at its position (virtio's available ring) */
} erx_dma_placing_t;

typedef struct erx_dma_table {
	uint32_t		structure;	/* ERX_STRUCTURE_* of erx/abi.h */
	erx_dma_placing_t	placing;
	uint64_t		region;		/* the offset of the table's region */
	uint64_t		region_length;	/* whole granules */
	uint64_t		first;		/* the offset of record 0, past a ring's head */
	uint32_t		count;
	uint32_t		stride;
} erx_dma_table_t;

/* `count` buffers, buffer b at first + b * stride, of which a name reaches `size` bytes. */
typedef struct erx_dma_pool {
	uint64_t	first;
	uint32_t	count;
	uint32_t	size;
	uint32_t	stride;
} erx_dma_pool_t;

typedef struct erx_dma_layout {
	uint64_t		memory_size;	/* the record's memory, from offset 0 */
	uint64_t		device_base;	/* the device address of offset 0 */
	uint32_t		address_bits;	/* the widest device address the form can hold, 1..64 */
	uint32_t		granule;	/* G: a power of two */
	uint32_t		table_count;
	erx_dma_table_t		tables[ERX_DMA_TABLES_MAX];
	erx_dma_pool_t		pool;
} erx_dma_layout_t;

/* A record of a table: the table's index in the layout, and the record's in the table. */
typedef struct erx_dma_place {
	uint32_t	table;
	uint32_t	index;
} erx_dma_place_t;

typedef struct erx_dma_holding {
	uint32_t	record_count;
	erx_dma_place_t	records[ERX_DMA_HELD_RECORDS_MAX];	/* records[0] is the head */
	uint32_t	buffer_count;
	uint32_t	buffers[ERX_DMA_HELD_BUFFERS_MAX];
} erx_dma_holding_t;

/* What a decision that hands over describes (erx_device_rules.h). */
struct erx_dma_publication;

/*
 * A table's position: the next record to publish at, for one placed in order, or to consume,
 * for one the device writes, and how many times the position has wrapped, from which a form
 * derives its running index (virtio's) or its cycle state (a TRB ring's).
 */
typedef struct erx_dma_position {
	uint32_t	index;
	uint32_t	lap;
} erx_dma_position_t;

/*
 * The ledger. Its fields are the module's: callers read it through the accessors below and
 * change it only through hold, release and reset, so its invariants hold by construction: the
 * layout was checked when the ledger was made, the first `live` holdings are the live ones, and
 * no record or buffer is held twice.
 */
typedef struct erx_dma_ledger {
	erx_dma_layout_t	layout;
	erx_dma_position_t	positions[ERX_DMA_TABLES_MAX];
	uint32_t		live;
	erx_dma_holding_t	holdings[ERX_DMA_HOLDINGS_MAX];
} erx_dma_ledger_t;

/*
 * The layout of virtio's split ring of `size` entries and its `size` buffers of `buffer_size`
 * bytes (docs/design-device-dma.md, "The descriptor forms"): the descriptor table, the
 * available ring and the used ring, each a region of its own from a granule, then the pool.
 * The sizes come from abi/formats' layouts. False for a size that is not a power of two up to
 * ERX_DEVICE_QUEUE_SIZE_MAX, a granule that is not a power of two up to ERX_DEVICE_GRANULE_MAX,
 * or a buffer size of 0 or over ERX_DEVICE_BUFFER_MAX. It does not check the layout against the
 * memory: erx_dma_ledger_make does.
 */
bool	erx_dma_layout_split_ring(uint32_t size, uint32_t buffer_size, uint32_t granule, uint64_t memory_size,
	    uint64_t device_base, uint32_t address_bits, erx_dma_layout_t *layout);

/*
 * A ledger with no holding and every position at 0, from `layout` if it passes the install's
 * check: every region whole granules, ascending, disjoint, inside the memory and below the
 * address width; each table's records inside its region; at most one table of each structure,
 * and one buffer's bytes no more than its stride. False, writing nothing, otherwise.
 */
bool	erx_dma_ledger_make(erx_dma_ledger_t *ledger, const erx_dma_layout_t *layout);

/*
 * Begins the holding of `publication`, placed at the `record_count` records `records`, the
 * first its head, as the header comment says. False, changing nothing, when it may not begin.
 */
bool	erx_dma_ledger_hold(erx_dma_ledger_t *ledger, const struct erx_dma_publication *publication,
	    const erx_dma_place_t *records, uint32_t record_count);
/*
 * Ends the live holding whose head is `head`, on a report of table `reports`, the table the
 * device writes, at its consumer position. False, changing nothing, when none is live.
 */
bool	erx_dma_ledger_release(erx_dma_ledger_t *ledger, uint32_t reports, erx_dma_place_t head);
/* The device's idle report after a reset: every holding ends and every position returns to 0. */
void	erx_dma_ledger_reset(erx_dma_ledger_t *ledger);

/* The accessors. A table or buffer number outside the layout is held by nothing. */
const erx_dma_layout_t	*erx_dma_ledger_layout(const erx_dma_ledger_t *ledger);
/* The index of the layout's table of `structure`, or -1. */
int			 erx_dma_ledger_table(const erx_dma_ledger_t *ledger, uint32_t structure);
erx_dma_position_t	 erx_dma_ledger_position(const erx_dma_ledger_t *ledger, uint32_t table);
bool			 erx_dma_ledger_record_held(const erx_dma_ledger_t *ledger, erx_dma_place_t place);
bool			 erx_dma_ledger_buffer_held(const erx_dma_ledger_t *ledger, uint32_t buffer);
/* The derived writer of a buffer: the device's while a holding holds it. */
erx_dma_writer_t	 erx_dma_ledger_buffer_writer(const erx_dma_ledger_t *ledger, uint32_t buffer);
/* The records of a table no holding holds. */
uint32_t		 erx_dma_ledger_free_records(const erx_dma_ledger_t *ledger, uint32_t table);
uint32_t		 erx_dma_ledger_live(const erx_dma_ledger_t *ledger);

/* Whether `length` bytes from `offset` lie inside `size` bytes, with no sum that can wrap. */
static inline bool
erx_dma_inside(uint64_t offset, uint64_t length, uint64_t size)
{
	return (offset <= size && length <= size - offset);
}

#endif /* ERX_DEVICE_LEDGER_H */
