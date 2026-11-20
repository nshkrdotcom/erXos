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
 * device writes, its position and how many of its records the last acquisition covered that
 * are not consumed yet. Its state machine has three transitions, and each refuses,
 * changing nothing, what the design's order forbids:
 *   hold     begins the holding of a publication from the records the sequencer placed it in
 *            and the buffers its names reach, each once, taken from the publication itself so
 *            no buffer it names goes to the device unheld: none of them is held already, its
 *            records of a table placed in order are the next ones from that table's position,
 *            which moves past them, and it holds no record of a table the device writes;
 *   acquire  records how many reports of a table the device writes its validity covers from
 *            the consumer position, at most the live holdings;
 *   release  ends the live holding a report names, from the report table's consumer position,
 *            which moves past it, spending one report the acquisition covered; a report naming
 *            no live holding's head, or past what the acquisition covered, ends nothing, so a
 *            stale report past the validity never releases a live holding.
 * The idle report after a reset ends every holding (erx_dma_ledger_reset). A region's writer
 * is derived from the holdings, never stated: a buffer is the device's while a holding holds
 * it, and a table is its structure's writer, as abi/formats declares it.
 *
 * The ledger reads the persistent regions a region entry may name from its device's one region
 * table, which the device record owns and every queue's ledger of that device points to, so a
 * region of another device is a name no ledger of this device holds, by construction. The one
 * lookup, erx_dma_ledger_region, gives a queue only a region that fits it: below its form's
 * address width and apart from its memory, whichever of the region and the queue came first. No
 * holding holds a persistent region: its writer is always the CPU.
 *
 * Offsets are bytes from the start of the record's memory; a device address is the record's
 * device base plus an offset.
 */

#ifndef ERX_DEVICE_LEDGER_H
#define ERX_DEVICE_LEDGER_H

#include <stdbool.h>
#include <stdint.h>

#include "erx_device.h"
#include "erx_device_dma.h"

/*
 * Bounds of a record's ledger: its tables, virtio's three or the TRB form's 36 transfer rings,
 * command ring and event ring; its pools, virtio's one or a pool per queue block; and one chain's
 * records and buffers.
 */
#define ERX_DMA_TABLES_MAX		40u
#define ERX_DMA_POOLS_MAX		36u
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
	ERX_DMA_PLACED_RING,	/* descriptions at its next positions, its last record the sequencer's link (a TRB ring) */
} erx_dma_placing_t;

typedef struct erx_dma_table {
	uint32_t		structure;	/* ERX_STRUCTURE_* of erx/abi.h */
	erx_dma_placing_t	placing;
	uint32_t		pool;		/* a table descriptions fill: the pool its names reach */
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
	uint32_t		pool_count;
	erx_dma_pool_t		pools[ERX_DMA_POOLS_MAX];	/* buffers numbered across them, in order */
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

/*
 * One of the device's persistent regions (docs/design-device-dma.md, "The ledger"), by the
 * name erx_device_region gave it: kept for the boot, written by the CPU alone and read by the
 * device whenever a region entry names it.
 */
typedef struct erx_dma_persistent {
	uint32_t	name;
	uint64_t	address;	/* its device address */
	uint64_t	length;		/* its whole length */
} erx_dma_persistent_region_t;

/*
 * A device's persistent regions, each named once: one table per device record, which only
 * erx_dma_regions_add changes, under the device lock that serialises its queue calls, and each of
 * the device's ledgers reads through a const pointer.
 */
typedef struct erx_dma_regions {
	uint32_t			count;
	erx_dma_persistent_region_t	regions[ERX_DEVICE_REGIONS_MAX];
} erx_dma_regions_t;

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
 * change it only through hold, acquire, release_holding and reset, so its invariants hold by
 * construction: the layout was checked when the ledger was made, the first `live` holdings are
 * the live ones, and no record or buffer is held twice. Its regions are its device's table.
 */
typedef struct erx_dma_ledger {
	erx_dma_layout_t	layout;
	erx_dma_position_t	positions[ERX_DMA_TABLES_MAX];
	uint32_t		acquired[ERX_DMA_TABLES_MAX];	/* reports covered, not consumed */
	uint32_t		live;
	erx_dma_holding_t	holdings[ERX_DMA_HOLDINGS_MAX];
	uint32_t		bound[ERX_DMA_TABLES_MAX];	/* a ring's endpoint, 0 when unbound */
	const erx_dma_regions_t	*regions;	/* the device record's, never NULL */
} erx_dma_ledger_t;

/*
 * One position a ring's run takes (docs/design-device-dma.md, "The ledger"): the record, the
 * cycle state there, and whether it is the ring's link, which the sequencer writes.
 */
typedef struct erx_dma_ring_step {
	erx_dma_place_t	place;
	uint32_t	cycle;
	bool		link;
} erx_dma_ring_step_t;

/* A run of descriptions and the links it takes. */
#define ERX_DMA_RING_STEPS_MAX	(2u * ERX_DMA_HELD_RECORDS_MAX + 1u)

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
 * address width, in any order; each table's records inside its region, a ring of at least two,
 * a table descriptions fill naming one of its pools; and one buffer's bytes no more than its stride. False, writing nothing, otherwise. `regions` is
 * its device's table, which the ledger reads and never changes.
 */
bool	erx_dma_ledger_make(erx_dma_ledger_t *ledger, const erx_dma_layout_t *layout, const erx_dma_regions_t *regions);

/*
 * Begins the holding of `publication`, placed at the `record_count` records `records`, the
 * first its head, as the header comment says. False, changing nothing, when it may not begin.
 */
bool	erx_dma_ledger_hold(erx_dma_ledger_t *ledger, const struct erx_dma_publication *publication,
	    const erx_dma_place_t *records, uint32_t record_count);
/*
 * Records that the validity of table `reports`, one the device writes, covers `count` reports
 * from its consumer position, replacing what an earlier acquisition covered. False, changing
 * nothing, for a table the device does not write or a count past the live holdings.
 */
bool	erx_dma_ledger_acquire(erx_dma_ledger_t *ledger, uint32_t reports, uint32_t count);
/*
 * Ends `holding`, a live holding of this ledger as erx_dma_ledger_holding gave it, on a report of
 * table `reports`, the table the device writes, at its consumer position. False, changing nothing,
 * for a table the device does not write, an acquisition with no report left, or a holding that is
 * not one of the ledger's live ones, NULL included. A caller reads what it needs of the holding
 * first: the pointer is the ledger's, and no longer names it after.
 */
bool	erx_dma_ledger_release_holding(erx_dma_ledger_t *ledger, uint32_t reports, const erx_dma_holding_t *holding);
/*
 * The device's idle report after a reset: every holding and acquisition ends and every position
 * returns to 0. The persistent regions stay.
 */
void	erx_dma_ledger_reset(erx_dma_ledger_t *ledger);
/*
 * Adds `region` to its device's table `regions`, which a region entry may then name; the same
 * region again adds nothing. False, changing nothing, for a name already added with another
 * address or length, more regions than a device has (ERX_DEVICE_REGIONS_MAX), or a length of 0
 * or past what a region entry states. Each queue judges the rest at its lookup.
 */
bool	erx_dma_regions_add(erx_dma_regions_t *regions, erx_dma_persistent_region_t region);

/* The accessors. A table or buffer number outside the layout is held by nothing. */
const erx_dma_layout_t	*erx_dma_ledger_layout(const erx_dma_ledger_t *ledger);
/* The index of the layout's first table of `structure`, or -1. */
int			 erx_dma_ledger_table(const erx_dma_ledger_t *ledger, uint32_t structure);
erx_dma_position_t	 erx_dma_ledger_position(const erx_dma_ledger_t *ledger, uint32_t table);
bool			 erx_dma_ledger_record_held(const erx_dma_ledger_t *ledger, erx_dma_place_t place);
bool			 erx_dma_ledger_buffer_held(const erx_dma_ledger_t *ledger, uint32_t buffer);
/* The derived writer of a buffer: the device's while a holding holds it. */
erx_dma_writer_t	 erx_dma_ledger_buffer_writer(const erx_dma_ledger_t *ledger, uint32_t buffer);
/* The live holding whose head is `head`, or NULL; valid until the ledger changes. */
const erx_dma_holding_t	*erx_dma_ledger_holding(const erx_dma_ledger_t *ledger, erx_dma_place_t head);
/* The records of a table no holding holds. */
uint32_t		 erx_dma_ledger_free_records(const erx_dma_ledger_t *ledger, uint32_t table);
uint32_t		 erx_dma_ledger_live(const erx_dma_ledger_t *ledger);
/* Whether the ledger is as the idle report left it: no holding, no acquisition, every position at 0. */
bool			 erx_dma_ledger_idle(const erx_dma_ledger_t *ledger);
/* The reports of table `table` the last acquisition covered that are not consumed yet. */
uint32_t		 erx_dma_ledger_acquired(const erx_dma_ledger_t *ledger, uint32_t table);
/*
 * The persistent region named `name`, or NULL for a name its device's table lacks or a region that
 * does not fit the queue: past its address width or sharing a byte with its memory.
 */
const erx_dma_persistent_region_t	*erx_dma_ledger_region(const erx_dma_ledger_t *ledger, uint32_t name);

/*
 * The buffers, numbered across the layout's pools in order: how many there are, the pool buffer
 * `buffer` lies in (NULL past the last), and the offset of its byte `offset` in the record's memory.
 */
uint32_t		 erx_dma_layout_buffers(const erx_dma_layout_t *layout);
const erx_dma_pool_t	*erx_dma_layout_buffer_pool(const erx_dma_layout_t *layout, uint32_t buffer, uint32_t *pool);
uint64_t		 erx_dma_layout_buffer_offset(const erx_dma_layout_t *layout, uint32_t buffer, uint64_t offset);

/*
 * The bindings (docs/design-device-dma.md, "The ledger"). erx_dma_ledger_bind binds ring `table`
 * to `endpoint`, not 0, and returns its position to the first record on a new lap of cycle state
 * 1; false, changing nothing, for a table that is not a ring or one bound already. An unbound
 * ring holds no record, since only a run on a bound ring holds one and erx_dma_ledger_unbind,
 * which ends a binding, is refused while a holding holds a record of the ring. The sequencer calls both, with the effects of each (erx_dma_bind).
 */
bool		erx_dma_ledger_bind(erx_dma_ledger_t *ledger, uint32_t table, uint32_t endpoint);
bool		erx_dma_ledger_unbind(erx_dma_ledger_t *ledger, uint32_t table);
/* The endpoint ring `table` is bound to, or 0. */
uint32_t	erx_dma_ledger_binding(const erx_dma_ledger_t *ledger, uint32_t table);
/* The one ring bound to `endpoint`, or -1 for none or more than one. */
int		erx_dma_ledger_bound_table(const erx_dma_ledger_t *ledger, uint32_t endpoint);
/*
 * The positions a run of `descriptions` records takes on ring `table` from its position, in ring
 * order, into `steps`: a description's, and a link's where the run reaches it or ends just before
 * it, so the position never rests on the link. Their count, or 0 for a table that is not a ring,
 * no description or more than ERX_DMA_HELD_RECORDS_MAX. Whether they are free is the room rule's.
 */
uint32_t	erx_dma_ledger_ring_run(const erx_dma_ledger_t *ledger, uint32_t table, uint32_t descriptions,
		    erx_dma_ring_step_t steps[ERX_DMA_RING_STEPS_MAX]);

/* Whether `length` bytes from `offset` lie inside `size` bytes, with no sum that can wrap. */
static inline bool
erx_dma_inside(uint64_t offset, uint64_t length, uint64_t size)
{
	return (offset <= size && length <= size - offset);
}

#endif /* ERX_DEVICE_LEDGER_H */
