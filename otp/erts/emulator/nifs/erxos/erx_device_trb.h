/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's memory and stated parameters, xHCI's descriptor form of the DMA handoff
 * sequencer (docs/design-usb.md, "The TRB ring form"; docs/design-device-dma.md, "The descriptor
 * forms"): its memory laid out once, the transfer requests and input-context parameters a caller
 * states, and the one check of each. The form's core, erx_device_trb_form.h, posts, commands and
 * completes over the ledger from these. It reads no hardware and no shared memory, needs nothing
 * of ERTS and builds for the host, where its tests run. Every TRB and context field comes from the
 * generated layouts of abi/formats/xhci.txt; no bit is packed here by hand.
 *
 * The record's memory is divided into regions, each on a granule (erx_device_trb_layout). A
 * queue block is a transfer ring of `ring_trbs` TRBs, the last a link back to the first,
 * followed by a pad of its own size, and a pool of buffers; the command ring is a ring of the
 * same shape.
 */

#ifndef ERX_DEVICE_TRB_H
#define ERX_DEVICE_TRB_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"

#include "erx_device_dma.h"

/* A transfer or command ring's TRBs, its link the last, and the event ring's one segment. */
#define ERX_DEVICE_TRB_RING_TRBS	16u
#define ERX_DEVICE_TRB_EVENT_TRBS	512u
/* The most scratchpad pages a controller may ask for (5.4.3, p. 400). */
#define ERX_DEVICE_TRB_SCRATCHPADS_MAX	64u
#define ERX_DEVICE_TRB_SLOTS_MAX	ERX_USB_DEVICES_MAX
/* Queue blocks: 16 control, 16 interrupt and 4 bulk, each with at most 4 buffers. */
#define ERX_DEVICE_TRB_BLOCKS_MAX	36u
#define ERX_DEVICE_TRB_BUFFERS_MAX	4u
/* The most TRBs one transfer takes: a control transfer's setup, data and status stages. */
#define ERX_DEVICE_TRB_TRANSFER_TRBS	3u
#define ERX_DEVICE_TRB_REGIONS_MAX	(6u + ERX_DEVICE_TRB_SLOTS_MAX + ERX_DEVICE_TRB_BLOCKS_MAX + \
	    ERX_DEVICE_TRB_BLOCKS_MAX * ERX_DEVICE_TRB_BUFFERS_MAX)
/* The device context indexes a slot's queues take: EP0's 1 up to 31. */
#define ERX_DEVICE_TRB_DCI_MAX		(ERX_XHCI_DEVICE_CONTEXTS - 1u)

_Static_assert(ERX_DEVICE_TRB_REGIONS_MAX <= ERX_DMA_REGIONS_MAX, "the form's regions fit a DMA state");

typedef enum erx_device_trb_kind {
	ERX_DEVICE_TRB_CONTROL,
	ERX_DEVICE_TRB_INTERRUPT,
	ERX_DEVICE_TRB_BULK,
	ERX_DEVICE_TRB_KINDS,
} erx_device_trb_kind_t;

/*
 * The form's sizes: its rings' TRBs and, by kind, its blocks, each block's buffers and their
 * bytes. erx_device_trb_shape is the form's own; a host test explores a smaller one. A shape is
 * refused unless every block's posted TRBs, at most its buffers times three, leave three positions
 * of its ring free, the link, the start of the stop span and the enqueue position, so the span
 * always covers every posted TRB.
 */
typedef struct erx_device_trb_shape {
	uint32_t	ring_trbs;
	uint32_t	blocks[ERX_DEVICE_TRB_KINDS];
	uint32_t	buffers[ERX_DEVICE_TRB_KINDS];
	uint32_t	buffer_size[ERX_DEVICE_TRB_KINDS];
} erx_device_trb_shape_t;

extern const erx_device_trb_shape_t erx_device_trb_shape;

typedef enum erx_device_trb_region_kind {
	ERX_DEVICE_TRB_SCRATCHPAD,	/* the pages, then the array of their addresses */
	ERX_DEVICE_TRB_BUFFER,
	ERX_DEVICE_TRB_EVENT_RING,	/* the segment and its pad */
	ERX_DEVICE_TRB_DEVICE_CONTEXT,
	ERX_DEVICE_TRB_INPUT_CONTEXT,
	ERX_DEVICE_TRB_BLOCK_RING,	/* the segment and its pad */
	ERX_DEVICE_TRB_COMMAND_RING,	/* the segment and its pad */
	ERX_DEVICE_TRB_DCBAA,
	ERX_DEVICE_TRB_SEGMENT_TABLE,
} erx_device_trb_region_kind_t;

/* One region: offset and bytes in the record's memory, a whole number of granules. */
typedef struct erx_device_trb_region {
	uint64_t			offset;
	uint64_t			length;
	erx_device_trb_region_kind_t	kind;
	uint32_t			index;		/* the slot, block or buffer it belongs to */
} erx_device_trb_region_t;

/*
 * The record's memory laid out, with the controller's facts the plans name. `regions` is in
 * placement order, ascending and disjoint; the other tables index into it.
 */
typedef struct erx_device_trb_layout {
	erx_device_trb_shape_t	shape;
	uint64_t		device_base;	/* the device address of offset 0 */
	uint64_t		bytes;		/* the memory the regions take, from offset 0 */
	uint32_t		granule;
	uint32_t		context_size;	/* 32, or 64 when HCCPARAMS1.CSZ is set */
	uint32_t		slots;		/* the slots the controller enables, 1..ERX_DEVICE_TRB_SLOTS_MAX */
	uint32_t		ports;		/* its root ports */
	uint32_t		scratchpads;	/* the pages it asks for */
	uint32_t		doorbells;	/* doorbell 0's offset in the register window */
	uint32_t		region_count;
	erx_device_trb_region_t	regions[ERX_DEVICE_TRB_REGIONS_MAX];
	uint16_t		dcbaa;
	uint16_t		scratchpad;	/* UINT16_MAX when no page is asked for */
	uint16_t		segment_table;
	uint16_t		event_ring;
	uint16_t		command_ring;
	uint16_t		input_context;
	uint16_t		device_context[ERX_DEVICE_TRB_SLOTS_MAX + 1];	/* by slot, from 1 */
	uint16_t		block_ring[ERX_DEVICE_TRB_BLOCKS_MAX];
	uint16_t		buffer[ERX_DEVICE_TRB_BLOCKS_MAX][ERX_DEVICE_TRB_BUFFERS_MAX];
} erx_device_trb_layout_t;

/* What the controller reports that the layout needs. */
typedef struct erx_device_trb_controller {
	uint32_t	slots;
	uint32_t	ports;
	uint32_t	scratchpads;
	uint32_t	context_size;
	uint32_t	doorbells;
} erx_device_trb_controller_t;

/*
 * The layout of `shape` over memory at `device_base`, each region on a `granule` and inside the
 * boundary Table 6-1 gives it (pp. 439-440): a ring segment with its pad inside 64 KiB, a context,
 * the DCBAA and the scratchpad array inside a page, each buffer aligned to its size. False for a
 * shape the form refuses, a granule that is not a power of two from 16 to ERX_DEVICE_GRANULE_MAX,
 * a device base off the granule, controller counts out of range (more than 64 scratchpad pages
 * among them), or regions past `memory_size`.
 */
bool	erx_device_trb_layout(erx_device_trb_layout_t *layout, const erx_device_trb_shape_t *shape,
	    const erx_device_trb_controller_t *controller, uint64_t device_base, uint32_t granule,
	    uint64_t memory_size);

/* The blocks of `shape`, of every kind. */
uint32_t	erx_device_trb_block_count(const erx_device_trb_shape_t *shape);
/* The kind of block `block`: the control blocks first, then the interrupt, then the bulk. */
erx_device_trb_kind_t	erx_device_trb_block_kind(const erx_device_trb_shape_t *shape, uint32_t block);
/* The offset of ring position `position` of block `block`, or of the command ring for ERX_DEVICE_TRB_BLOCKS_MAX. */
uint64_t	erx_device_trb_position_offset(const erx_device_trb_layout_t *layout, uint32_t block, uint32_t position);

/* How a post or a command is answered: accepted, `badarg`, `{error, halted}`, or no room. */
typedef enum erx_device_trb_verdict {
	ERX_DEVICE_TRB_ACCEPTED,
	ERX_DEVICE_TRB_REFUSE_BADARG,
	ERX_DEVICE_TRB_REFUSE_HALTED,
	ERX_DEVICE_TRB_REFUSE_FULL,
} erx_device_trb_verdict_t;

/*
 * A transfer (docs/design-usb.md, "What Erlang names and what the NIF builds"): a control
 * transfer, with a data stage when `data`, or a normal one; the direction, the length, at most
 * the block's buffer, and an out transfer's bytes; a control transfer's 8 setup bytes.
 */
typedef struct erx_device_trb_request {
	bool		control;
	bool		data;
	bool		device_writes;
	uint32_t	length;
	const uint8_t	*bytes;
	uint8_t		setup[8];
} erx_device_trb_request_t;

/*
 * Whether `request` is a transfer the form may post on queue `dci` of a block of `kind` whose
 * buffers hold `buffer_size` bytes: a control transfer only on a control queue and a normal one
 * only on another, so never on EP0; within the buffer; a normal transfer in its endpoint's
 * direction (4.5.1); a control transfer's data stage in its setup's direction (4.11.2.2) and as
 * long as the setup says, and no SET_ADDRESS. The DMA check carries no direction: it is the form's.
 */
bool	erx_device_trb_request_valid(const erx_device_trb_request_t *request, erx_device_trb_kind_t kind,
	    uint32_t dci, uint32_t buffer_size);

/*
 * The input context's stated parameters (docs/design-usb.md, "What Erlang names and what the NIF
 * builds"): the slot context's and each carried endpoint context's fields a command's caller
 * states, the generated free structs of abi/formats/xhci.txt. What the posting core derives, the
 * add and drop flags, Context Entries, each TR Dequeue Pointer with its cycle state and the
 * average TRB length, is not here: the sequencer's composition writes it. Address
 * Device states the slot context's device fields and EP0's context, Configure Endpoint the hub
 * fields and each endpoint it adds (the TRB form adds the slot's addressed fields to the slot context
 * it hands the sequencer), Evaluate Context EP0's context alone. The context size is the
 * layout's, from the controller's HCCPARAMS1.CSZ, never stated.
 */
typedef struct erx_device_trb_context_endpoint {
	uint32_t				dci;		/* 1..ERX_DEVICE_TRB_DCI_MAX */
	erx_xhci_endpoint_context_free_t	context;
} erx_device_trb_context_endpoint_t;

typedef struct erx_device_trb_contexts {
	erx_xhci_slot_context_free_t		slot_context;	/* with the slot context: Address Device, Configure Endpoint */
	uint32_t				endpoint_count;
	erx_device_trb_context_endpoint_t	endpoints[ERX_DEVICE_TRB_DCI_MAX];
} erx_device_trb_contexts_t;

/*
 * The checks of the stated parameters, the one test of each, which a core applies where a command
 * enters it, before anything changes (xHCI 1.2, 6.2.2 and 6.2.3, pp. 444-456):
 *   address slot    Address Device's slot context: a route string of a port of 1 to 15 at each tier,
 *                   then nothing; a speed of full to SuperSpeed; a root port of 1..`ports`; a TT hub's
 *                   slot of 1..`slots` and its port of 1..ERX_USB_HUB_PORTS_MAX together, or neither,
 *                   multi-TT only with them; the hub fields 0.
 *   configure slot  Configure Endpoint's: the hub fields alone, 0 for a function, or a hub of
 *                   1..ERX_USB_HUB_PORTS_MAX ports, think time 0 to 3 and its multi-TT flag; the
 *                   device fields 0, since the core carries the slot's addressed ones itself
 *                   (6.2.2.2, p. 448: a high-speed hub's think time and multi-TT need its speed).
 *   EP0             a control context of no burst, interval or payload, its packet 8, 64 or 512 for
 *                   Address Device (`exact`) and 8 to 512 for Evaluate Context.
 *   endpoint        an endpoint Configure Endpoint adds on a block of `kind` whose buffers hold
 *                   `buffer_size` bytes, of a slot addressed at `speed`: an index of 2..31; the type
 *                   of its kind in its index's direction, a control endpoint taking the IN index as
 *                   EP0 does (4.5.1, p. 96); a packet of 1 to 1024, a burst of 0 to 15; an interval
 *                   exponent of 0 to 15, 0 for a bulk or control endpoint, as FreeBSD sets it
 *                   (abi/formats/xhci.txt, the interval); a
 *                   service-interval payload of at least 1, at most the packet times the burst plus
 *                   one and the buffer, and equal to that product unless the endpoint is an interrupt
 *                   endpoint of a SuperSpeed slot.
 */
bool	erx_device_trb_address_slot_valid(const erx_xhci_slot_context_free_t *slot, uint32_t ports, uint32_t slots);
bool	erx_device_trb_configure_slot_valid(const erx_xhci_slot_context_free_t *slot);
bool	erx_device_trb_ep0_valid(const erx_xhci_endpoint_context_free_t *context, bool exact);
bool	erx_device_trb_endpoint_valid(const erx_device_trb_context_endpoint_t *endpoint, erx_device_trb_kind_t kind,
	    uint32_t buffer_size, uint32_t speed);

#endif /* ERX_DEVICE_TRB_H */
