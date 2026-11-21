/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form, xHCI's descriptor form of the DMA handoff sequencer
 * (docs/design-usb.md, "The TRB ring form"; docs/design-device-dma.md, "The descriptor forms"):
 * its memory laid out once, its queues and their states, the plans of its posts with their
 * two publications, and each queue's stop span. It reads no hardware and no shared memory,
 * needs nothing of ERTS and builds for the host, where its tests run. Every TRB and context
 * field comes from the generated layouts of abi/formats/xhci.txt; no bit is packed here by hand.
 *
 * The record's memory is divided into regions, each on a granule (erx_device_trb_layout). A
 * queue block is a transfer ring of `ring_trbs` TRBs, the last a link back to the first,
 * followed by a pad of its own size, and a pool of buffers; the command ring is a ring of the
 * same shape. A ring keeps its enqueue position and producer cycle state for the life of the
 * install, across the queues that use it, so stale TRBs of an earlier queue always carry the
 * other cycle and the controller never takes them.
 *
 * Two rules hold by construction: the enqueue position never rests on a link TRB, since a post
 * whose last TRB lands just before the link hands the link over with it; and a post writes its
 * first TRB with the controller's old cycle bit, so the plan's first publication is that TRB's
 * control word and its second the doorbell.
 *
 * Each queue's states and the commands each accepts are the design's table. The functions that
 * apply a command's completion, retire a transfer or halt a queue are the bookkeeping a
 * completion's decisions apply; deciding from an event is the completion's own.
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
/* The most steps of a transfer's post: three steps a TRB, the link, the out bytes, two publications. */
#define ERX_DEVICE_TRB_POST_STEPS	(3u * ERX_DEVICE_TRB_TRANSFER_TRBS + 4u)
/* The most steps of a command's post: the contexts of 30 added endpoints, four fields each, and the rest. */
#define ERX_DEVICE_TRB_COMMAND_STEPS	(4u * (ERX_DEVICE_TRB_DCI_MAX - 1u) + 16u)
/* The most steps of the links an install writes: two per ring. */
#define ERX_DEVICE_TRB_LINK_STEPS	(2u * (ERX_DEVICE_TRB_BLOCKS_MAX + 1u))
/* No position: a transfer without a data stage. */
#define ERX_DEVICE_TRB_NO_POSITION	UINT8_MAX

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

/* The kind of block `block`: the control blocks first, then the interrupt, then the bulk. */
erx_device_trb_kind_t	erx_device_trb_block_kind(const erx_device_trb_shape_t *shape, uint32_t block);
/* The offset of ring position `position` of block `block`, or of the command ring for ERX_DEVICE_TRB_BLOCKS_MAX. */
uint64_t	erx_device_trb_position_offset(const erx_device_trb_layout_t *layout, uint32_t block, uint32_t position);

/* A ring's next position to write and the producer cycle state its TRBs take there. */
typedef struct erx_device_trb_ring {
	uint8_t	enqueue;
	uint8_t	cycle;
} erx_device_trb_ring_t;

/* A posted transfer: its tag, its buffer, the bytes posted and its TRBs' ring positions. */
typedef struct erx_device_trb_transfer {
	uint64_t	tag;
	uint32_t	length;
	uint8_t		buffer;
	uint8_t		first;
	uint8_t		data;		/* a control transfer's data stage, or ERX_DEVICE_TRB_NO_POSITION */
	uint8_t		last;
} erx_device_trb_transfer_t;

/*
 * A block's state: free, reserved by the command in flight that adds its queue, or the queue's
 * state of the design's table.
 */
typedef enum erx_device_trb_state {
	ERX_DEVICE_TRB_FREE,
	ERX_DEVICE_TRB_RESERVED,
	ERX_DEVICE_TRB_OPEN,
	ERX_DEVICE_TRB_STOPPING,
	ERX_DEVICE_TRB_STOPPED,
	ERX_DEVICE_TRB_HALTED,
} erx_device_trb_state_t;

/*
 * A queue block. While its state is a queue's, it is the queue {slot, dci}. `span_start` is
 * where the stop span starts: the last TRB of the transfer that most recently completed, or
 * the position the ring last started at when none has completed since. The posted transfers
 * are a FIFO from `head`, in ring order.
 */
typedef struct erx_device_trb_block {
	uint8_t				state;		/* erx_device_trb_state_t */
	uint8_t				slot;
	uint8_t				dci;
	uint8_t				span_start;
	erx_device_trb_ring_t		ring;
	uint8_t				head;
	uint8_t				posted;
	uint8_t				busy;		/* a bit per buffer posted */
	erx_device_trb_transfer_t	transfers[ERX_DEVICE_TRB_BUFFERS_MAX];
} erx_device_trb_block_t;

/* A slot: enabled by the controller, and whether its device context is the controller's. */
typedef struct erx_device_trb_slot {
	bool	enabled;
	bool	context_given;
	uint8_t	speed;
} erx_device_trb_slot_t;

typedef enum erx_device_trb_command_kind {
	ERX_DEVICE_TRB_NO_COMMAND,
	ERX_DEVICE_TRB_ENABLE_SLOT,
	ERX_DEVICE_TRB_ADDRESS_DEVICE,
	ERX_DEVICE_TRB_EVALUATE_CONTEXT,
	ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS,
	ERX_DEVICE_TRB_STOP_ENDPOINT,
	ERX_DEVICE_TRB_RESET_ENDPOINT,
	ERX_DEVICE_TRB_SET_TR_DEQUEUE,
	ERX_DEVICE_TRB_DISABLE_SLOT,
} erx_device_trb_command_kind_t;

/*
 * The one command in flight: what it is, where its TRB is, the queues of its slot it holds, which
 * accept no post until it completes (EP0 for Evaluate Context, the drops of Configure Endpoint,
 * every queue for Disable Slot), the blocks it removes and the blocks it reserved.
 */
typedef struct erx_device_trb_pending {
	uint8_t		kind;		/* erx_device_trb_command_kind_t */
	uint8_t		slot;
	uint8_t		dci;
	uint8_t		position;
	uint8_t		speed;		/* Address Device: the slot's speed once it succeeds */
	uint32_t	held;		/* a bit per device context index */
	uint64_t	dropped;	/* a bit per block */
	uint64_t	reserved;	/* a bit per block */
	uint64_t	tag;
} erx_device_trb_pending_t;

/* The form's bookkeeping, plain data that its caller serialises. */
typedef struct erx_device_trb {
	erx_device_trb_slot_t		slots[ERX_DEVICE_TRB_SLOTS_MAX + 1];	/* by slot, from 1 */
	erx_device_trb_block_t		blocks[ERX_DEVICE_TRB_BLOCKS_MAX];
	erx_device_trb_ring_t		command_ring;
	erx_device_trb_pending_t	command;
	bool				installed;	/* the scratchpad and the event ring are the controller's */
} erx_device_trb_t;

/* Bookkeeping as an install leaves it: every block free, every ring at its first TRB with cycle 1. */
void	erx_device_trb_init(erx_device_trb_t *trb);

/*
 * Who writes each region: the scratchpad and the event ring the device while installed, a
 * slot's device context the device from its Address Device to its disable, a buffer the
 * device while a transfer is posted on it, and every other region the CPU.
 */
void	erx_device_trb_view(const erx_device_trb_t *trb, const erx_device_trb_layout_t *layout, erx_dma_state_t *state);

/*
 * Every ring's link TRB as an install writes it: the ring's base as its segment pointer, with
 * the ring's bytes as its reach, and its control word with toggle-cycle set and cycle 0, the
 * other cycle from the producer's first lap.
 */
uint32_t	erx_device_trb_link_steps(const erx_device_trb_layout_t *layout, erx_dma_step_t *steps);

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
 * average TRB length, is not here: the sequencer's erx_dma_input_context writes it. Address
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

/*
 * The post of `request` under `tag` on the queue {slot, dci}: its TRBs into the ring and an out
 * transfer's bytes into a free buffer, then the first TRB's control word with the new cycle and
 * the slot's doorbell with the queue's index. REFUSE_BADARG for a queue that does not exist, a
 * transfer of the wrong kind or direction for it, a length past the buffer or a setup whose
 * length differs from it, or a standard SET_ADDRESS; REFUSE_HALTED for a queue that is not open or that
 * the command in flight holds;
 * REFUSE_FULL for no free buffer. Nothing changes unless it is accepted.
 */
erx_device_trb_verdict_t	erx_device_trb_post(erx_device_trb_t *trb, const erx_device_trb_layout_t *layout,
	    uint32_t slot, uint32_t dci, const erx_device_trb_request_t *request, uint64_t tag,
	    erx_dma_step_t *steps, uint32_t *count);

/* An endpoint Configure Endpoint adds, and the hub fields it sets. */
typedef struct erx_device_trb_endpoint {
	uint8_t		number;		/* 1..15 */
	bool		in;		/* false for a control endpoint, which takes the IN index as EP0 does */
	uint8_t		kind;		/* erx_device_trb_kind_t */
	uint16_t	packet;		/* 1..1024 */
	uint8_t		burst;		/* 0..15 */
	uint8_t		interval;	/* the exponent, 0..15 */
	uint32_t	payload;	/* the service-interval payload */
} erx_device_trb_endpoint_t;

typedef struct erx_device_trb_command {
	uint8_t		kind;		/* erx_device_trb_command_kind_t */
	uint8_t		slot;
	uint8_t		dci;		/* Stop Endpoint, Reset Endpoint and Set TR Dequeue */
	/* Address Device */
	uint32_t	route;
	uint8_t		root_port;
	uint8_t		speed;
	bool		tt;
	uint8_t		tt_slot;
	uint8_t		tt_port;
	bool		tt_multi;
	/* Address Device and Evaluate Context */
	uint16_t	ep0_packet;
	/* Configure Endpoint */
	uint32_t				add_count;
	const erx_device_trb_endpoint_t		*add;
	uint32_t				drops;		/* a bit per device context index, 2..31 */
	bool					hub;
	uint8_t					hub_ports;	/* 1..15 */
	uint8_t					hub_think_time;	/* 0..3 */
	bool					hub_multi_tt;
} erx_device_trb_command_t;

/*
 * The post of `command` under `tag` in the states the design's table accepts it, its contexts
 * built from its bounded parameters, then its TRB's control word and doorbell 0. Address Device
 * zeroes the slot's device context and points its DCBAA entry at it the first time, which
 * hands the context to the controller until the slot's disable completes. REFUSE_BADARG for a
 * parameter out of range or a command the queue's or slot's state does not accept; REFUSE_FULL while
 * a command is in flight or for no free block for a queue it adds.
 */
erx_device_trb_verdict_t	erx_device_trb_command(erx_device_trb_t *trb, const erx_device_trb_layout_t *layout,
	    const erx_device_trb_command_t *command, uint64_t tag, erx_dma_step_t *steps, uint32_t *count);

/* How a command completed, as the completion classifies its code. */
typedef enum erx_device_trb_outcome {
	ERX_DEVICE_TRB_SUCCESS,
	ERX_DEVICE_TRB_CONTEXT_STATE_ERROR,
	ERX_DEVICE_TRB_FAILED,
} erx_device_trb_outcome_t;

/* A transfer answered `stopped`: its tag, and the block and buffer it returns. */
typedef struct erx_device_trb_stopped {
	uint64_t	tag;
	uint8_t		block;
	uint8_t		buffer;
} erx_device_trb_stopped_t;

/* The most transfers one command's success answers `stopped`: every buffer of the blocks of a slot. */
#define ERX_DEVICE_TRB_STOPPED_MAX	(ERX_DEVICE_TRB_BLOCKS_MAX * ERX_DEVICE_TRB_BUFFERS_MAX)

/*
 * The completion of the command in flight, with its tag. Success applies the design's state
 * changes: Enable Slot enables `slot`; an adding command opens its queues at their rings'
 * enqueue positions; a command that restarts or removes a ring answers every transfer still
 * posted on it `stopped` into `stopped`, and a removed queue's block returns. A failure returns
 * what the command reserved and changes no state, except a Stop Endpoint failing with a context
 * state error, which halts the queue. False, changing nothing, for no command in flight, or an
 * Enable Slot success naming a slot out of range or enabled: the completion breaks the form.
 */
bool	erx_device_trb_command_done(erx_device_trb_t *trb, const erx_device_trb_layout_t *layout,
	    erx_device_trb_outcome_t outcome, uint32_t slot, uint64_t *tag, erx_device_trb_stopped_t *stopped,
	    uint32_t *count);

/* The queue {slot, dci}'s block, or NULL when it does not exist. */
const erx_device_trb_block_t	*erx_device_trb_queue(const erx_device_trb_t *trb, uint32_t slot, uint32_t dci);

/*
 * The oldest transfer posted on the queue completes: it leaves the FIFO into *done, its buffer
 * returns and the stop span starts at its last TRB. False, changing nothing, for no queue or
 * nothing posted.
 */
bool	erx_device_trb_retire(erx_device_trb_t *trb, uint32_t slot, uint32_t dci, erx_device_trb_transfer_t *done);

/* A transfer event with an error code halts the queue. False for no queue. */
bool	erx_device_trb_halt(erx_device_trb_t *trb, uint32_t slot, uint32_t dci);

/*
 * Whether ring position `position` lies in the queue's stop span: from `span_start` up to and
 * including the enqueue position, across the link.
 */
bool	erx_device_trb_in_stop_span(const erx_device_trb_layout_t *layout, const erx_device_trb_block_t *block,
	    uint32_t position);

#endif /* ERX_DEVICE_TRB_H */
