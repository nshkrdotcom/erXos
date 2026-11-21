/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's core over the sequencer (docs/design-device-dma.md, "The descriptor forms",
 * "The ledger", "Publication"; docs/design-usb.md, "What the DMA check judges"): what xHCI's rings
 * add to the check's rules. It reads no hardware and no shared memory, needs nothing of ERTS and
 * builds for the host, where its tests run.
 *
 * The form's memory is laid out once, by erx_device_trb_layout; erx_trb_form_layout derives the
 * ledger's tables and pools from that layout and no one else's, so a ring, a buffer and an input
 * context lie where the controller is told they do:
 *
 *   tables    a transfer ring per queue block, table b for block b, each needing a binding (its
 *             structure's mark in abi/formats) and placed as a ring; the command ring, which needs
 *             none; the event ring, which the device writes.
 *   pools     a pool per block, its buffers; and the command ring's, which holds just the input
 *             context, so a command's input-context name is a buffer of the command ring's pool,
 *             held while the command is in flight.
 *
 * A transfer reaches a ring only through the binding of its endpoint {slot, dci}, which the
 * ledger makes with its binding command's holding; a pair out of range names endpoint 0, which no
 * binding binds, so it reaches no ring. Its TRBs name only a buffer of that ring's pool, which the
 * check asks of every name, and the form takes the lowest no holding holds. Its transfer record, its
 * tag and length, is kept by the holding's head, the TD's last TRB, which its completion names,
 * since a control transfer without a data stage names no buffer. A ring takes no more TDs or
 * commands than its pool has buffers (the check's room rule), so a control block's transfers in
 * flight, and the commands in flight, are as many as design-usb.md's count of events allows.
 *
 * The releases come from the event ring, the structure the controller writes
 * (docs/design-usb.md, "Completing", "What the DMA check judges"): the sequencer acquires its
 * events by their cycle bits, and each is consumed in order, judged whole before anything ends:
 *   Transfer Event, Success or Short Packet, naming the head of a live transfer on a ring bound
 *            to the event's slot and endpoint: the transfer's holding ends, answered with its tag
 *            and the bytes moved, its length less the residue, or what its short data stage moved;
 *   Transfer Event, Short Packet, naming the data stage of a live control transfer on a ring bound
 *            to its endpoint, the first such for it: nothing ends, and the bytes the stage moved
 *            are kept for the status stage's event;
 *   Transfer Event, an error code, naming a TRB of the oldest live transfer on a ring bound to its
 *            endpoint, not yet answered: nothing ends; the endpoint halts and the transfer is
 *            answered with the code and no bytes, its holding the controller's until a command
 *            restarts or removes the ring (xHCI 1.2, 4.10.2);
 *   Transfer Event, a stop's code, naming a record of the ring bound to the endpoint a Stop
 *            Endpoint in flight names, the first for that stop: nothing ends, nothing is answered;
 *   Command Completion naming the live command: its holding ends, on every code, and its reach
 *            acts on success, or its own bindings end on failure (erx_dma_ledger_complete_command);
 *            answered with the command's tag, and then each transfer its success retires that no
 *            error answered, `stopped` with no bytes under its own tag;
 *   Port Status Change: nothing ends.
 * A transfer event names its ring's oldest live transfer, since the controller runs a ring's TDs in
 * order. Any other event breaks the form, changing no holding, as a malformed used element breaks
 * a split ring: one naming no live holding or a record of no ring, a transfer not its ring's oldest
 * or answered already, an unknown type, a residue past its TRB's length, a second short data stage
 * or stop's event, the event-data flag, a stop's code with no Stop Endpoint in flight on its
 * endpoint. A record whose cycle bit is not the consumer cycle state is not yet written: the
 * acquisition stops before it, so it is never read.
 */

#ifndef ERX_DEVICE_TRB_FORM_H
#define ERX_DEVICE_TRB_FORM_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_sequencer.h"
#include "erx_device_trb.h"

/* A transfer in flight, kept by its head: what its completion answers. */
typedef struct erx_trb_transfer {
	uint64_t	tag;
	uint32_t	length;		/* the bytes it asks to move */
	uint32_t	buffer;		/* the buffer its normal or data TRB names, when names_buffer */
	bool		names_buffer;
	bool		data_stage;	/* a control transfer with a data stage */
	bool		short_data;	/* its data stage's short packet came */
	uint32_t	moved;		/* the bytes that stage moved, when short_data */
	bool		halted;		/* an error event answered it; its holding waits for a restart or removal */
} erx_trb_transfer_t;

/*
 * The commands (docs/design-usb.md, "What Erlang names and what the NIF builds"), each one meaning
 * of the command ring in abi/formats/xhci.txt.
 */
typedef enum erx_trb_command_kind {
	ERX_TRB_COMMAND_NOOP,
	ERX_TRB_COMMAND_ENABLE_SLOT,
	ERX_TRB_COMMAND_DISABLE_SLOT,
	ERX_TRB_COMMAND_ADDRESS_DEVICE,
	ERX_TRB_COMMAND_CONFIGURE_ENDPOINT,
	ERX_TRB_COMMAND_EVALUATE_CONTEXT,
	ERX_TRB_COMMAND_RESET_ENDPOINT,
	ERX_TRB_COMMAND_STOP_ENDPOINT,
	ERX_TRB_COMMAND_SET_TR_DEQUEUE,
	ERX_TRB_COMMAND_KINDS
} erx_trb_command_kind_t;

/*
 * An endpoint a binding command adds: its device context index, the queue block whose ring it
 * takes, and its endpoint context's stated fields (erx_device_trb.h).
 */
typedef struct erx_trb_add {
	uint32_t				dci;
	uint32_t				block;
	erx_xhci_endpoint_context_free_t	context;
} erx_trb_add_t;

/*
 * A command: its slot, but for Enable Slot and No Op; the endpoint Reset Endpoint, Stop Endpoint
 * and Set TR Dequeue Pointer name; and the endpoints Address Device adds, EP0 alone, and
 * Configure Endpoint adds and drops (a mask of bit dci); and the input context's stated parameters
 * (docs/design-usb.md, "What Erlang names and what the NIF builds"): Address Device's slot context
 * device fields and EP0 as its one add, Configure Endpoint's hub fields and its adds, Evaluate
 * Context's EP0 packet size. The sequencer writes the whole input context from these and from what
 * the publication derives (the composition in erx_device_sequencer.c).
 */
typedef struct erx_trb_command {
	erx_trb_command_kind_t	kind;
	uint32_t		slot;
	uint32_t		dci;
	uint32_t		drops;
	uint32_t		add_count;
	erx_trb_add_t		adds[ERX_DMA_BINDS_MAX];
	erx_xhci_slot_context_free_t	slot_context;	/* Address Device, Configure Endpoint */
	uint32_t		ep0_packet;	/* Evaluate Context */
} erx_trb_command_t;

/*
 * One controller's rings. Its fields are the module's: callers read the ledger through
 * erx_trb_form_ledger and change the form only through the calls below. A transfer is live while
 * a holding has its position as its head. A broken form answers every acquisition and completion
 * ERX_ECORRUPT until its reset.
 */
typedef struct erx_trb_form {
	erx_dma_ledger_t	ledger;
	erx_device_trb_layout_t	layout;		/* the memory's, from which the ledger's layout was derived */
	erx_device_trb_shape_t	shape;
	uint32_t		ports;
	uint32_t		slots;
	/* each slot enabled from an Enable Slot's success to its Disable Slot's success or a reset */
	bool			enabled[ERX_DEVICE_TRB_SLOTS_MAX + 1];
	/* each slot's Address Device slot context, from its last success since Disable Slot or a reset */
	erx_xhci_slot_context_free_t	addressed[ERX_DEVICE_TRB_SLOTS_MAX + 1];
	erx_trb_transfer_t	transfers[ERX_DEVICE_TRB_BLOCKS_MAX][ERX_DEVICE_TRB_RING_TRBS];	/* by head */
	erx_trb_command_t	command;	/* the command in flight, while the command ring holds one */
	uint64_t		command_tag;
	bool			stop_event;	/* the Stop Endpoint in flight has had its stop's event */
	bool			broken;
} erx_trb_form_t;

/* What a consumed event answers. */
typedef enum erx_trb_answer_kind {
	ERX_TRB_ANSWER_TRANSFER,	/* a transfer's holding ended */
	ERX_TRB_ANSWER_COMMAND,		/* the command's holding ended */
	ERX_TRB_ANSWER_PORT,		/* a root hub port changed */
} erx_trb_answer_kind_t;

typedef struct erx_trb_answer {
	erx_trb_answer_kind_t	kind;
	uint32_t		code;		/* the completion code */
	uint64_t		tag;		/* a transfer's or a command's */
	erx_dma_range_t		data;		/* a transfer's bytes moved in its buffer, from its first; empty for none */
	uint32_t		parameter;	/* a command's completion parameter */
	uint32_t		slot;		/* a command's slot */
	uint32_t		port;		/* a port event's port */
} erx_trb_answer_t;

/*
 * The ledger's layout of `trb`, into `layout`: tables and pools as the header says, each table's
 * stride its structure's record size, at the form's 64-bit device addresses. False for a ring of
 * more than ERX_DEVICE_TRB_RING_TRBS TRBs, past what the tags keep.
 */
bool	erx_trb_form_layout(const erx_device_trb_layout_t *trb, erx_dma_layout_t *layout);

/*
 * A form over `trb`, with no ring bound, its region entries naming the regions of `regions`
 * (erx_dma_ledger_make). False, writing nothing the caller may use, for a layout
 * erx_trb_form_layout or erx_dma_ledger_make refuses.
 */
bool	erx_trb_form_make(erx_trb_form_t *form, const erx_device_trb_layout_t *trb, const erx_dma_regions_t *regions);

const erx_dma_ledger_t	*erx_trb_form_ledger(const erx_trb_form_t *form);

/*
 * The ledger's endpoint of queue {slot, dci}: slot << 5 | dci, for a slot of 1..ERX_DEVICE_TRB_SLOTS_MAX
 * and a dci of 1..ERX_DEVICE_TRB_DCI_MAX, and 0, no endpoint, for any other pair.
 */
uint32_t	erx_trb_form_endpoint(uint32_t slot, uint32_t dci);

/*
 * Posts `request` under `tag` on queue {slot, dci} into `sequence`, which the effect layer applies
 * as erx_device_sequencer.h says; an out transfer's bytes go to sequence->fills[0]. The TRBs are
 * design-usb.md's: a normal TRB, or a setup stage, a data stage when the request has one, and
 * a status stage. The refusals, in order:
 *   ERX_DEVICE_TRB_REFUSE_BADARG  no ring bound to the queue's endpoint, or a request
 *                                 erx_device_trb_request_valid refuses for the ring's block;
 *   ERX_DEVICE_TRB_REFUSE_FULL    no free buffer in the ring's pool, or too few free positions on
 *                                 the ring (the check's room rule), judged before the next, so a
 *                                 full ring of a closed endpoint is full;
 *   ERX_DEVICE_TRB_REFUSE_HALTED  an endpoint not running, or one the command in flight closes
 *                                 (the check's reach rule; design-usb.md's queue table);
 *   ERX_DEVICE_TRB_REFUSE_BADARG  any other verdict, a bug of this core.
 * Anything but ERX_DEVICE_TRB_ACCEPTED changes nothing.
 */
erx_device_trb_verdict_t	erx_trb_form_post(erx_trb_form_t *form, uint32_t slot, uint32_t dci,
				    const erx_device_trb_request_t *request, uint64_t tag, erx_dma_sequence_t *sequence);

/*
 * Posts `command` under `tag` on the command ring into `sequence`: its meaning's one TRB, naming
 * the input context when it carries it, with the bindings of the endpoints it adds and its reach
 * (erx_device_ledger.h), which the check judges. The refusals:
 *   ERX_DEVICE_TRB_REFUSE_FULL    a command in flight: the ledger takes one at a time;
 *   ERX_DEVICE_TRB_REFUSE_BADARG  an endpoint whose state its reach does not allow (the check's
 *                                 reach rule), a command the queue's state does not accept as
 *                                 design-usb.md's queue table has it: a stop or restart of a
 *                                 disabled endpoint, a drop of a halted, disabled or busy one, a
 *                                 disable of a slot with a busy one, an Evaluate Context while EP0
 *                                 is not running or stopped, or has a transfer posted;
 *   ERX_DEVICE_TRB_REFUSE_BADARG  any other: a stated parameter its check in erx_device_trb.h
 *                                 refuses, judged first (Address Device adds EP0 alone, on a control
 *                                 block; Configure Endpoint adds indexes 2 and up, each on a block of
 *                                 its type, for the slot's speed; Evaluate Context adds none), a slot
 *                                 outside the layout's, a Configure Endpoint on a slot with no
 *                                 successful Address Device since its Disable Slot or a reset, more
 *                                 adds than ERX_DMA_BINDS_MAX, an add of a bound
 *                                 block or endpoint, drops on a command whose reach drops none
 *                                 (only Configure Endpoint drops), a kind out of range.
 * Anything but ERX_DEVICE_TRB_ACCEPTED changes nothing.
 */
erx_device_trb_verdict_t	erx_trb_form_command(erx_trb_form_t *form, const erx_trb_command_t *command, uint64_t tag,
				    erx_dma_sequence_t *sequence);

/*
 * The install, after the controller's reset (docs/design-usb.md, "Install"), into `sequence`, which
 * the effect layer applies as erx_device_sequencer.h says (erx_dma_install_controller): every region
 * zeroed and cleaned, DCBAA entry 0, the scratchpad array, the segment table and the command ring's
 * link written, then the controller's registers and its run. `reaches_64_bits` is HCCPARAMS1.AC64.
 *   ERX_ECORRUPT  a broken form, which only erx_trb_form_reset mends;
 *   ERX_ERANGE  a controller without AC64 under memory reaching past 4 GiB;
 *   ERX_EBUSY   anything held: a holding the reset's idle report (erx_trb_form_reset) has not ended;
 *   ERX_EINVAL  any other verdict, a bug of this core.
 * Anything but ERX_OK changes nothing; ERX_OK changes nothing of the form either.
 */
int	erx_trb_form_install(const erx_trb_form_t *form, bool reaches_64_bits, erx_dma_sequence_t *sequence);

/*
 * The tag of the transfer whose holding `found` is, as a query of the ledger found it, into `*tag`.
 * False for a holding no longer live (erx_dma_ledger_found_live), and for one of the command ring,
 * whose head is no transfer's.
 */
bool	erx_trb_form_tag(const erx_trb_form_t *form, erx_dma_found_t found, uint64_t *tag);

/*
 * Where the cycle word of the event `k` places past the event ring's consumer position lies, for
 * the acquisition's first phase; empty past one lap.
 */
erx_dma_range_t	erx_trb_form_validity_word(const erx_trb_form_t *form, uint32_t k);
/*
 * The events the cycle words `words`, read in order at the places erx_trb_form_validity_word gave,
 * show written, into `*count`: the leading ones whose cycle bit is the consumer cycle state there
 * (erx_dma_acquire_cycles). ERX_ECORRUPT for a broken form, or more words than the event ring's,
 * which breaks it.
 */
int	erx_trb_form_acquire(erx_trb_form_t *form, const uint32_t *words, uint32_t word_count, uint32_t *count);
/* Where the `k`th acquired event not yet consumed lies, to read whole; empty past them. */
erx_dma_range_t	erx_trb_form_event(const erx_trb_form_t *form, uint32_t k);
/*
 * The answers erx_trb_form_complete may give for `count` events: one for each event, and the
 * transfers one command's success retires, at most every holding but the command's, which the
 * ledger caps at ERX_DMA_HOLDINGS_MAX across every ring a Disable Slot may retire; one call
 * completes at most one command,
 * since the ledger takes one at a time.
 */
#define ERX_TRB_FORM_ANSWERS_MAX(count)	((count) + ERX_DMA_HOLDINGS_MAX - 1u)
/*
 * Consumes the acquired events `events`, each read whole, in order, while one is acquired, as the
 * header says, into `answers`, which holds ERX_TRB_FORM_ANSWERS_MAX(count); `*answered` is how many, and `*dequeue` the
 * device address of the event ring's consumer position after them, which the effect layer writes
 * to ERDP with the busy bit. An event the header refuses breaks the form and ends the call: the
 * answers before it stand. ERX_OK with the answers, or ERX_ECORRUPT, with none, for a broken form.
 */
int	erx_trb_form_complete(erx_trb_form_t *form, const erx_report_record_t *events, uint32_t count,
	    erx_trb_answer_t *answers, uint32_t *answered, uint64_t *dequeue);
/*
 * The controller's idle report after its reset: every holding, binding and transfer ends, and the
 * form is whole again. The event ring's positions return to their first, so the effect layer
 * zeroes and cleans the event ring before the controller runs again, as an install does: an event
 * left from before the reset carries the first lap's cycle bit and would be acquired.
 */
void	erx_trb_form_reset(erx_trb_form_t *form);

/*
 * The controller's reset and start, which erx_device:negotiate/2 takes one step a call
 * (docs/design-usb.md, "Install"; xHCI 1.2, 4.2 and 5.4.1, pp. 80-82 and 393-394): run cleared;
 * once the controller reads halted, HCRST, which it allows only then; once HCRST and the
 * controller-not-ready bit read clear, before which no other register may be written, the
 * reset's idle report (erx_trb_form_reset) and the install (erx_trb_form_install), whose last
 * write is run; once the controller leaves halted, started. Each call reads USBCMD and USBSTS
 * once, at its start, and the decision is a pure function of that reading and of the step the
 * last call left, so no call waits: a wait is one reading a call, answered `{error, ebusy}`
 * until it ends, and the controller core holds the install's one deadline, past which it fails
 * the controller (erx_xhci_core).
 */
typedef enum erx_trb_start_step {
	ERX_TRB_START_BEGIN,		/* the next call begins a negotiation: a new record's, or a started one's */
	ERX_TRB_START_HALTING,		/* run cleared: waits for USBSTS.HCH */
	ERX_TRB_START_RESETTING,	/* HCRST written: waits for it and USBSTS.CNR to read clear */
	ERX_TRB_START_STARTING,		/* installed and run: waits for HCH to read clear */
} erx_trb_start_step_t;

/* The call's one reading of the controller, taken before it writes anything. */
typedef struct erx_trb_start_seen {
	bool	halted;		/* USBSTS.HCH */
	bool	resetting;	/* USBCMD.HCRST */
	bool	not_ready;	/* USBSTS.CNR */
} erx_trb_start_seen_t;

/* The one write a call makes, or the install's sequence. */
typedef enum erx_trb_start_effect {
	ERX_TRB_START_NOTHING,
	ERX_TRB_START_CLEAR_RUN,	/* USBCMD.RS 0 */
	ERX_TRB_START_RESET,		/* USBCMD.HCRST 1 */
	ERX_TRB_START_INSTALL,		/* erx_trb_form_reset, then erx_trb_form_install's sequence applied */
} erx_trb_start_effect_t;

typedef struct erx_trb_start_next {
	erx_trb_start_effect_t	effect;
	erx_trb_start_step_t	step;		/* what the next call takes up */
	bool			started;	/* the call answers ok; otherwise `{error, ebusy}` */
} erx_trb_start_next_t;

/*
 * The call that finds the start at `step`, reading `seen`. An install the effect layer cannot
 * apply ends the negotiation with its error, and the next call begins again (ERX_TRB_START_BEGIN).
 */
erx_trb_start_next_t	erx_trb_form_start_next(erx_trb_start_step_t step, erx_trb_start_seen_t seen);

#endif /* ERX_DEVICE_TRB_FORM_H */
