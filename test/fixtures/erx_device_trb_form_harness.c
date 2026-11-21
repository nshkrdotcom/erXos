/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB form's core on the DMA ledger (erx_device_trb_form.h): its layout derived from the
 * form's own, over the form's shape and a small one; the endpoint of a queue; and every sequence
 * of posts and releases up to a fixed depth over the small shape, against a reference model of
 * each ring's positions and cycle state and each pool's buffers, every release through an event
 * the controller writes, across a wrap of the event ring; and the events the form refuses. Until
 * binding commands have meanings, a No Op command on the command ring carries each binding.
 * test/host/erx_device_trb_form_test.rb builds it with each seeded fault and shows it caught.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_trb_form.h"

#define EXPECT(condition, what)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, what);	\
			exit(1);						\
		}								\
	} while (0)

/*
 * The small shape: rings of RING TRBs, the last each one's link; a control block of one buffer and
 * two bulk blocks of two, the first bound to an IN endpoint and the second to an OUT one. Tables
 * 0..2 are the blocks' rings, then the command ring and the event ring.
 */
enum { RING = 6, BLOCKS = 3, COMMANDS = 3, EVENTS = 4, BUFFERS_MAX = 2, LIVE_MAX = 8, DEPTH = 6, EVENT_BATCH = 32 };
enum { CONTROL_BLOCK = 0, IN_BLOCK = 1, OUT_BLOCK = 2 };
enum { POST_CONTROL_DATA, POST_CONTROL, POST_IN, POST_OUT, POSTS };
#define BASE		UINT64_C(0x100000)
#define SLOT		1u
#define NO_BUFFER	UINT32_MAX

static const erx_dma_regions_t no_regions;
static const uint32_t block_dci[BLOCKS] = { 1, 3, 2 };	/* EP0, EP1 IN, EP1 OUT */
static const uint8_t out_bytes[64];

static const erx_device_trb_shape_t small_shape = {
	.ring_trbs = RING, .blocks = { 1, 0, 2 }, .buffers = { 1, 0, 2 }, .buffer_size = { 64, 0, 64 },
};
static const erx_device_trb_controller_t controller = {
	.slots = 2, .ports = 1, .scratchpads = 0, .context_size = 32, .doorbells = 0,
};

/*
 * The model: each ring's position, cycle state and held positions; each block's held buffers; the
 * event ring's consumer position and cycle state.
 */
typedef struct transfer {
	uint32_t	block;
	uint32_t	buffer;		/* the block's buffer, or NO_BUFFER */
	uint32_t	head;
	uint32_t	length;
	uint32_t	data;		/* a control transfer's data stage, or NO_BUFFER */
	bool		short_data;
	uint32_t	moved;
	uint32_t	position_count;
	uint32_t	positions[2 * 3 + 1];
	uint64_t	tag;
} transfer_t;

typedef struct model {
	uint32_t	position[BLOCKS];
	uint32_t	cycle[BLOCKS];
	bool		held[BLOCKS][RING];
	bool		buffer_held[BLOCKS][BUFFERS_MAX];
	uint32_t	live;
	transfer_t	transfers[LIVE_MAX];
	uint64_t	next_tag;
	uint32_t	event_index;
	uint32_t	event_cycle;
} model_t;

typedef struct state {
	erx_trb_form_t	form;
	model_t		model;
} state_t;

static erx_device_trb_layout_t trb;
static uint64_t states;

static erx_device_trb_request_t
request(uint32_t post)
{
	/* GET_DESCRIPTOR of 8 bytes, IN; SET_CONFIGURATION 1, with no data stage. */
	static const uint8_t get_descriptor[8] = { 0x80, 6, 0, 1, 0, 0, 8, 0 };
	static const uint8_t set_configuration[8] = { 0x00, 9, 1, 0, 0, 0, 0, 0 };
	erx_device_trb_request_t made = { 0 };

	switch (post) {
	case POST_CONTROL_DATA:
		made = (erx_device_trb_request_t){ .control = true, .data = true, .device_writes = true, .length = 8 };
		memcpy(made.setup, get_descriptor, sizeof(made.setup));
		break;
	case POST_CONTROL:
		made = (erx_device_trb_request_t){ .control = true };
		memcpy(made.setup, set_configuration, sizeof(made.setup));
		break;
	case POST_IN:
		made = (erx_device_trb_request_t){ .device_writes = true, .length = 64 };
		break;
	default:
		made = (erx_device_trb_request_t){ .length = 10, .bytes = out_bytes };
		break;
	}
	return (made);
}

static uint32_t
post_block(uint32_t post)
{
	return (post == POST_IN ? IN_BLOCK : post == POST_OUT ? OUT_BLOCK : CONTROL_BLOCK);
}

static uint32_t
post_trbs(uint32_t post)
{
	return (post == POST_CONTROL_DATA ? 3 : post == POST_CONTROL ? 2 : 1);
}

/* The record offset of position `position` of block `block`'s ring, by the form's own layout. */
static uint64_t
position_offset(uint32_t block, uint32_t position)
{
	return (erx_device_trb_position_offset(&trb, block, position));
}

static const erx_dma_store_t *
stored_at(const erx_dma_sequence_t *sequence, uint64_t offset)
{
	for (uint32_t index = 0; index < sequence->store_count; index++) {
		if (sequence->stores[index].offset == offset)
			return (&sequence->stores[index]);
	}
	return (NULL);
}

/* A TRB's 64-bit parameter and control word as stored, little-endian. */
static uint64_t
parameter(const erx_dma_store_t *store)
{
	uint64_t value;

	memcpy(&value, store->bytes, sizeof(value));
	return (value);
}

static uint32_t
control_cycle(const uint8_t *word)
{
	uint32_t value;

	memcpy(&value, word, sizeof(value));
	return (value & 1u);
}

/* The record offset of event `index` of the event ring, and of command `index` of the command ring. */
static uint64_t
event_offset(uint32_t index)
{
	return (trb.regions[trb.event_ring].offset + 16u * (uint64_t)index);
}

static uint64_t
command_offset(uint32_t index)
{
	return (trb.regions[trb.command_ring].offset + 16u * (uint64_t)index);
}

/*
 * An event TRB as the controller writes it, its cycle bit left for deliver: the type, slot and
 * endpoint in the control word, the code and residue (or a command's parameter) in the status
 * word, the TRB pointer (or a port event's port, in bits 31:24) in the parameter.
 */
static erx_report_record_t
event_trb(uint32_t type, uint64_t pointer, uint32_t code, uint32_t residue, uint32_t dci)
{
	return ((erx_report_record_t){ .xhci_trb_transfer_event = { .pointer = pointer, .status = code << 24 | residue,
	    .control = (dci == 0 ? 0 : SLOT << 24 | dci << 16) | type << 10 } });
}

/*
 * Hands the form the `count` events `events`, written from the model's consumer position, each
 * with the cycle state there: checks where the acquisition reads each cycle word and each event,
 * that every one is acquired, and that the dequeue pointer after the completion is past the
 * `consumed` events it should consume, where the model's position moves. The completion's status.
 */
static int
deliver(state_t *state, erx_report_record_t *events, uint32_t count, uint32_t consumed, erx_trb_answer_t *answers,
    uint32_t *answered)
{
	model_t *const model = &state->model;
	uint32_t words[EVENT_BATCH], acquired, index = model->event_index, cycle = model->event_cycle;
	uint64_t dequeue;
	int status;

	for (uint32_t k = 0; k < count; k++) {
		events[k].xhci_trb_transfer_event.control |= cycle;
		words[k] = events[k].xhci_trb_transfer_event.control;
		EXPECT(erx_trb_form_validity_word(&state->form, k).offset == event_offset(index) + 12u,
		    "the acquisition reads each event's control word from the consumer position");
		if (++index == ERX_DEVICE_TRB_EVENT_TRBS) {
			index = 0;
			cycle ^= 1u;
		}
	}
	EXPECT(erx_trb_form_acquire(&state->form, words, count, &acquired) == ERX_OK && acquired == count,
	    "every event written with the consumer cycle state is acquired");
	for (uint32_t k = 0; k < count; k++)
		EXPECT(erx_trb_form_event(&state->form, k).offset ==
		    event_offset((model->event_index + k) % ERX_DEVICE_TRB_EVENT_TRBS), "each acquired event is read whole where it lies");
	status = erx_trb_form_complete(&state->form, events, count, answers, answered, &dequeue);
	for (uint32_t k = 0; k < consumed; k++) {
		if (++model->event_index == ERX_DEVICE_TRB_EVENT_TRBS) {
			model->event_index = 0;
			model->event_cycle ^= 1u;
		}
	}
	EXPECT(dequeue == BASE + event_offset(model->event_index), "the dequeue pointer is past the consumed events");
	return (status);
}

/* The No Op command that binds ring `table` to `endpoint`, then its completion with `code`. */
static void
bind(state_t *state, uint32_t table, uint32_t endpoint, uint32_t code)
{
	const erx_dma_description_t noop = { .structure = ERX_STRUCTURE_XHCI_COMMAND_RING,
	    .meaning = ERX_MEANING_XHCI_TRB_NOOP_COMMAND };
	const erx_dma_publication_t publication = { .record_count = 1, .records = &noop, .call = ERX_DMA_PUBLISH_RUN,
	    .binds = { endpoint, table } };
	const uint32_t head = erx_dma_ledger_position(&state->form.ledger, COMMANDS).index;
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(head),
	    code, 0x2a, 0);
	erx_trb_answer_t answer;
	erx_dma_sequence_t sequence;
	uint32_t answered;

	EXPECT(erx_dma_publish(&state->form.ledger, &publication, &sequence) == ERX_DMA_PASSES, "a binding command");
	EXPECT(erx_dma_ledger_binding(&state->form.ledger, table) == endpoint, "its publication binds the ring");
	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 1 &&
	    answer.kind == ERX_TRB_ANSWER_COMMAND && answer.code == code && answer.parameter == 0x2a &&
	    erx_dma_ledger_live(&state->form.ledger) == 0, "the command's completion ends its holding on any code");
	EXPECT(erx_dma_ledger_binding(&state->form.ledger, table) == (code == ERX_XHCI_COMPLETION_SUCCESS ? endpoint : 0),
	    "a success keeps the binding, and a failure ends it");
}

/* Port events, in batches, until the event ring's consumer position is `index`. */
static void
pass_ports(state_t *state, uint32_t index)
{
	erx_report_record_t events[EVENT_BATCH];
	erx_trb_answer_t answers[EVENT_BATCH];
	uint32_t answered;

	while (state->model.event_index != index) {
		const uint32_t left = (index + ERX_DEVICE_TRB_EVENT_TRBS - state->model.event_index) % ERX_DEVICE_TRB_EVENT_TRBS;
		const uint32_t count = left < EVENT_BATCH ? left : EVENT_BATCH;

		for (uint32_t k = 0; k < count; k++)
			events[k] = event_trb(ERX_XHCI_TRB_TYPE_PORT_STATUS_CHANGE_EVENT, UINT64_C(1) << 24,
			    ERX_XHCI_COMPLETION_SUCCESS, 0, 0);
		EXPECT(deliver(state, events, count, count, answers, &answered) == ERX_OK && answered == count &&
		    answers[count - 1u].kind == ERX_TRB_ANSWER_PORT && answers[count - 1u].port == 1,
		    "port events are answered and end nothing");
	}
}

/* The model at a form with no ring bound, as made or after its reset. */
static void
model_idle(model_t *model)
{
	memset(model, 0, sizeof(*model));
	for (uint32_t block = 0; block < BLOCKS; block++)
		model->cycle[block] = 1;
	model->event_cycle = 1;
	model->next_tag = 0x7a90;
}

/*
 * The small form with every block's ring bound, its event ring's consumer position three short of
 * the wrap, so the explored completions cross it.
 */
static void
make_small(state_t *state)
{
	memset(state, 0, sizeof(*state));
	EXPECT(erx_device_trb_layout(&trb, &small_shape, &controller, BASE, 64, UINT64_C(1) << 20), "the small layout");
	EXPECT(erx_trb_form_make(&state->form, &trb, &no_regions), "a form over the small layout");
	model_idle(&state->model);
	for (uint32_t block = 0; block < BLOCKS; block++)
		bind(state, block, erx_trb_form_endpoint(SLOT, block_dci[block]), ERX_XHCI_COMPLETION_SUCCESS);
	pass_ports(state, ERX_DEVICE_TRB_EVENT_TRBS - 3u);
}

/* The live transfers of `block`'s ring in the model. */
static uint32_t
live_on(const model_t *model, uint32_t block)
{
	uint32_t live = 0;

	for (uint32_t index = 0; index < model->live; index++)
		live += model->transfers[index].block == block;
	return (live);
}

/* A control transfer's data stage: the TRB before its head, in ring order, past any link. */
static uint32_t
data_stage(const transfer_t *transfer)
{
	uint32_t before = NO_BUFFER, last = NO_BUFFER;

	for (uint32_t index = 0; index < transfer->position_count; index++) {
		if (transfer->positions[index] != RING - 1) {
			before = last;
			last = transfer->positions[index];
		}
	}
	return (before);
}

/*
 * The model's run of `count` descriptions on `block`'s ring: the positions it takes from the
 * ring's position, the link where it reaches it or ends just before it; false where one is held.
 */
static bool
model_run(const model_t *model, uint32_t block, uint32_t count, transfer_t *transfer, uint32_t *first)
{
	uint32_t position = model->position[block], described = 0;

	transfer->position_count = 0;
	*first = position;
	while (described < count || position == RING - 1) {
		if (model->held[block][position])
			return (false);
		transfer->positions[transfer->position_count++] = position;
		if (position == RING - 1) {
			position = 0;
		} else {
			transfer->head = position++;
			described++;
		}
	}
	return (true);
}

static void
check_post(state_t *state, uint32_t post)
{
	model_t *const model = &state->model;
	const erx_device_trb_request_t made = request(post);
	const uint32_t block = post_block(post), kind = erx_device_trb_block_kind(&trb.shape, block);
	const uint32_t live = erx_dma_ledger_live(&state->form.ledger);
	transfer_t transfer = { .block = block, .buffer = NO_BUFFER, .tag = model->next_tag++ };
	erx_dma_sequence_t sequence;
	erx_device_trb_verdict_t verdict;
	uint32_t first;
	bool room;

	if (!made.control || made.data) {
		for (uint32_t buffer = 0; buffer < trb.shape.buffers[kind] && transfer.buffer == NO_BUFFER; buffer++) {
			if (!model->buffer_held[block][buffer])
				transfer.buffer = buffer;
		}
		room = transfer.buffer != NO_BUFFER;
	} else {
		room = true;
	}
	room = room && live_on(model, block) < trb.shape.buffers[kind] &&
	    model_run(model, block, post_trbs(post), &transfer, &first);
	verdict = erx_trb_form_post(&state->form, SLOT, block_dci[block], &made, transfer.tag, &sequence);
	if (!room) {
		EXPECT(verdict == ERX_DEVICE_TRB_REFUSE_FULL && erx_dma_ledger_live(&state->form.ledger) == live,
		    "a post with no free buffer, as many TDs as buffers or too few free positions is full and holds nothing");
		return;
	}
	EXPECT(verdict == ERX_DEVICE_TRB_ACCEPTED, "a post the model has room for is accepted");
	transfer.length = made.length;
	transfer.data = made.control && made.data ? data_stage(&transfer) : NO_BUFFER;

	/* The buffer, the lowest free one of the ring's own block, named by the normal or data TRB. */
	if (transfer.buffer != NO_BUFFER) {
		const uint64_t offset = trb.regions[trb.buffer[block][transfer.buffer]].offset;
		const uint32_t named = made.control ? transfer.positions[transfer.positions[1] == RING - 1 ? 2 : 1] :
		    transfer.head;
		const erx_dma_store_t *const store = stored_at(&sequence, position_offset(block, named));

		EXPECT(store != NULL && parameter(store) == BASE + offset, "the TRB names the lowest free buffer of its block");
		EXPECT(!made.control || named == transfer.data, "the data stage is the TRB before the head");
		if (!made.device_writes)
			EXPECT(sequence.fill_count == 1 && sequence.fills[0].offset == offset &&
			    sequence.fills[0].length == made.length, "an out transfer's bytes fill its buffer from offset 0");
		model->buffer_held[block][transfer.buffer] = true;
	}

	/* Nothing is live before the activation, the first TRB's control word with the ring's cycle. */
	{
		const erx_dma_store_t *const store = stored_at(&sequence, position_offset(block, first));

		EXPECT(sequence.activation.kind == ERX_DMA_ACTIVATE_STORE &&
		    sequence.activation.store.offset == position_offset(block, first) + 12u &&
		    control_cycle(sequence.activation.store.bytes) == model->cycle[block] &&
		    store != NULL && control_cycle(store->bytes + 12) != model->cycle[block],
		    "the first TRB is stored with the other cycle and made live by the activation");
	}

	/* The tag is the head's, the TD's last TRB, which the completion names. */
	{
		uint64_t tag = 0;

		EXPECT(erx_trb_form_tag(&state->form, erx_dma_ledger_holding(&state->form.ledger,
		    (erx_dma_place_t){ block, transfer.head }), &tag) && tag == transfer.tag,
		    "the transfer's tag is kept by its head");
	}

	for (uint32_t index = 0; index < transfer.position_count; index++) {
		model->held[block][transfer.positions[index]] = true;
		if (transfer.positions[index] == RING - 1)
			model->cycle[block] ^= 1u;
	}
	model->position[block] = (transfer.positions[transfer.position_count - 1u] + 1u) % RING;
	model->transfers[model->live++] = transfer;
}

/* The model's live transfer `live` ends: its positions and buffer come back. */
static void
model_end(model_t *model, uint32_t live)
{
	const transfer_t transfer = model->transfers[live];

	for (uint32_t index = 0; index < transfer.position_count; index++)
		model->held[transfer.block][transfer.positions[index]] = false;
	if (transfer.buffer != NO_BUFFER)
		model->buffer_held[transfer.block][transfer.buffer] = false;
	model->transfers[live] = model->transfers[--model->live];
}

/*
 * The event that completes live transfer `live`, naming its head: Success, or a Short Packet with a
 * residue for an IN transfer. It ends the holding and answers the tag and the bytes moved in the
 * buffer: its length less the residue, or what its short data stage moved.
 */
static void
check_complete(state_t *state, uint32_t live)
{
	model_t *const model = &state->model;
	const transfer_t transfer = model->transfers[live];
	const uint32_t residue = transfer.block == IN_BLOCK ? 3u : 0;
	const uint32_t moved = transfer.short_data ? transfer.moved : transfer.length - residue;
	const erx_dma_found_t found = erx_dma_ledger_holding(&state->form.ledger, (erx_dma_place_t){ transfer.block,
	    transfer.head });
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(transfer.block,
	    transfer.head), residue != 0 ? ERX_XHCI_COMPLETION_SHORT_PACKET : ERX_XHCI_COMPLETION_SUCCESS, residue,
	    block_dci[transfer.block]);
	erx_trb_answer_t answer;
	uint32_t answered;
	uint64_t tag = 0;

	EXPECT(erx_trb_form_tag(&state->form, found, &tag) && tag == transfer.tag, "a completion's head gives its tag");
	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 1 &&
	    answer.kind == ERX_TRB_ANSWER_TRANSFER && answer.tag == transfer.tag &&
	    erx_dma_ledger_live(&state->form.ledger) == model->live - 1u, "the completion ends the transfer's holding");
	EXPECT(transfer.buffer == NO_BUFFER ? answer.data.length == 0 :
	    answer.data.offset == trb.regions[trb.buffer[transfer.block][transfer.buffer]].offset &&
	    answer.data.length == moved, "the answer names the bytes moved, from the buffer's first");
	EXPECT(!erx_trb_form_tag(&state->form, found, &tag), "a holding kept past its release gives no tag");
	model_end(model, live);
}

/*
 * A Short Packet on live control transfer `live`'s data stage: it ends nothing and answers
 * nothing, and the bytes the stage moved are what the status stage's event answers.
 */
static void
check_short(state_t *state, uint32_t live)
{
	transfer_t *const transfer = &state->model.transfers[live];
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(transfer->block,
	    transfer->data), ERX_XHCI_COMPLETION_SHORT_PACKET, 5, block_dci[transfer->block]);
	erx_trb_answer_t answer;
	uint32_t answered;

	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 0 &&
	    erx_dma_ledger_live(&state->form.ledger) == state->model.live, "a short data stage ends nothing");
	transfer->short_data = true;
	transfer->moved = transfer->length - 5u;
}

static void
check_port(state_t *state)
{
	erx_report_record_t event = event_trb(ERX_XHCI_TRB_TYPE_PORT_STATUS_CHANGE_EVENT, UINT64_C(1) << 24,
	    ERX_XHCI_COMPLETION_SUCCESS, 0, 0);
	erx_trb_answer_t answer;
	uint32_t answered;

	EXPECT(deliver(state, &event, 1, 1, &answer, &answered) == ERX_OK && answered == 1 &&
	    answer.kind == ERX_TRB_ANSWER_PORT && answer.port == 1 &&
	    erx_dma_ledger_live(&state->form.ledger) == state->model.live, "a port event ends nothing");
}

/*
 * Every sequence of posts and events to DEPTH: each post, the completion of each live transfer in
 * any order, across rings, a short data stage of each live control transfer that has had none, and
 * a port event.
 */
static void
explore(const state_t *state, uint32_t depth)
{
	const uint32_t live = state->model.live;

	states++;
	if (depth == DEPTH)
		return;
	for (uint32_t step = 0; step < POSTS + 2u * live + 1u; step++) {
		state_t next = *state;

		if (step < POSTS) {
			check_post(&next, step);
		} else if (step < POSTS + live) {
			check_complete(&next, step - POSTS);
		} else if (step < POSTS + 2u * live) {
			const transfer_t *const transfer = &next.model.transfers[step - POSTS - live];

			if (transfer->data == NO_BUFFER || transfer->short_data)
				continue;
			check_short(&next, step - POSTS - live);
		} else {
			check_port(&next);
		}
		explore(&next, depth + 1);
	}
}

/*
 * An event the form refuses: delivered alone, it is consumed by nothing, answers nothing, breaks
 * the form and ends no holding; the broken form refuses every call until its reset.
 */
static void
refused(state_t *state, erx_report_record_t event, const char *what)
{
	const uint32_t live = erx_dma_ledger_live(&state->form.ledger);
	erx_trb_answer_t answer;
	uint32_t answered, count;

	if (deliver(state, &event, 1, 0, &answer, &answered) != ERX_ECORRUPT || answered != 0 ||
	    erx_dma_ledger_live(&state->form.ledger) != live || erx_trb_form_acquire(&state->form, NULL, 0, &count) != ERX_ECORRUPT) {
		printf("FAILED %s:%d: refused: %s\n", __FILE__, __LINE__, what);
		exit(1);
	}
}

/* A small form with an IN transfer, a control transfer with a data stage and an OUT one posted. */
static void
make_posted(state_t *state)
{
	make_small(state);
	check_post(state, POST_IN);
	check_post(state, POST_CONTROL_DATA);
	check_post(state, POST_OUT);
}

static erx_report_record_t
completing(const transfer_t *transfer, uint32_t code, uint32_t residue)
{
	return (event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(transfer->block, transfer->head),
	    code, residue, block_dci[transfer->block]));
}

static void
test_refusals(void)
{
	static state_t state;
	const transfer_t *in, *control;
	erx_report_record_t event, events[2];
	erx_trb_answer_t answers[2];
	erx_dma_sequence_t sequence;
	uint32_t answered, count, words[ERX_DEVICE_TRB_EVENT_TRBS + 1u] = { 0 };
	uint64_t dequeue;

	make_posted(&state);
	in = &state.model.transfers[0];
	control = &state.model.transfers[1];
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.pointer = BASE + trb.regions[trb.input_context].offset;
	refused(&state, event, "a pointer outside every ring");

	make_posted(&state);
	event = completing(control, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.pointer = BASE + position_offset(control->block, control->positions[0]);
	refused(&state, event, "a pointer one TRB off the head: the setup stage");
	event = completing(control, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.pointer += 4;
	erx_trb_form_reset(&state.form);
	EXPECT(erx_dma_ledger_idle(&state.form.ledger) && erx_trb_form_acquire(&state.form, NULL, 0, &count) == ERX_OK &&
	    count == 0, "the reset's idle report makes the form whole and ends every holding");

	make_posted(&state);
	refused(&state, event, "a pointer inside the head, not at its start");

	make_posted(&state);
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.control = (event.xhci_trb_transfer_event.control & ~(UINT32_C(0x1f) << 16)) |
	    block_dci[OUT_BLOCK] << 16;
	refused(&state, event, "an event of another endpoint naming this one's head");

	make_posted(&state);
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.control = (event.xhci_trb_transfer_event.control & ~(UINT32_C(0x3f) << 10)) |
	    (uint32_t)ERX_XHCI_TRB_TYPE_HOST_CONTROLLER_EVENT << 10;
	refused(&state, event, "a type no meaning of the event ring selects");

	make_posted(&state);
	refused(&state, completing(in, ERX_XHCI_COMPLETION_SHORT_PACKET, 65), "a residue past the TRB's length");

	make_posted(&state);
	check_short(&state, 1);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(control->block, control->data),
	    ERX_XHCI_COMPLETION_SHORT_PACKET, 5, block_dci[control->block]), "a second short data stage");

	make_posted(&state);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(control->block, control->data),
	    ERX_XHCI_COMPLETION_SHORT_PACKET, 5, block_dci[IN_BLOCK]), "a short data stage of another endpoint's transfer");

	make_posted(&state);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, BASE + position_offset(control->block, control->data),
	    ERX_XHCI_COMPLETION_SHORT_PACKET, 9, block_dci[control->block]), "a short data stage's residue past its length");

	make_posted(&state);
	event = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	event.xhci_trb_transfer_event.control |= 1u << 2;
	refused(&state, event, "the event-data flag");

	make_posted(&state);
	refused(&state, completing(in, ERX_XHCI_COMPLETION_STALL, 0), "an error code, until the endpoints' states");

	make_posted(&state);
	refused(&state, event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(0),
	    ERX_XHCI_COMPLETION_SUCCESS, 0, 0), "a command completion naming no live command");

	/* A record not yet written: its cycle bit is not the consumer cycle state, so it is not acquired. */
	make_posted(&state);
	events[0] = completing(in, ERX_XHCI_COMPLETION_SUCCESS, 0);
	events[1] = completing(&state.model.transfers[2], ERX_XHCI_COMPLETION_SUCCESS, 0);
	events[0].xhci_trb_transfer_event.control |= state.model.event_cycle;
	events[1].xhci_trb_transfer_event.control |= state.model.event_cycle ^ 1u;
	words[0] = events[0].xhci_trb_transfer_event.control;
	words[1] = events[1].xhci_trb_transfer_event.control;
	EXPECT(erx_trb_form_acquire(&state.form, words + 1, 1, &count) == ERX_OK && count == 0 &&
	    erx_trb_form_complete(&state.form, events + 1, 1, answers, &answered, &dequeue) == ERX_OK && answered == 0 &&
	    dequeue == BASE + event_offset(state.model.event_index) && erx_dma_ledger_live(&state.form.ledger) == 3,
	    "an event with a stale cycle bit is not acquired, consumed or answered");
	EXPECT(erx_trb_form_acquire(&state.form, words, 2, &count) == ERX_OK && count == 1 &&
	    erx_trb_form_complete(&state.form, events, 2, answers, &answered, &dequeue) == ERX_OK && answered == 1 &&
	    erx_dma_ledger_live(&state.form.ledger) == 2, "the acquisition stops at the first stale cycle bit");
	EXPECT(erx_trb_form_acquire(&state.form, words, ERX_DEVICE_TRB_EVENT_TRBS + 1u, &count) == ERX_ECORRUPT,
	    "more cycle words than the event ring has breaks the form");

	/* A failing binding command ends its binding, unless a transfer holds the ring (the reach rule's). */
	erx_trb_form_reset(&state.form);
	model_idle(&state.model);
	bind(&state, IN_BLOCK, erx_trb_form_endpoint(SLOT, block_dci[IN_BLOCK]), ERX_XHCI_COMPLETION_TRB_ERROR);
	{
		const erx_dma_description_t noop = { .structure = ERX_STRUCTURE_XHCI_COMMAND_RING,
		    .meaning = ERX_MEANING_XHCI_TRB_NOOP_COMMAND };
		const erx_dma_publication_t publication = { .record_count = 1, .records = &noop,
		    .call = ERX_DMA_PUBLISH_RUN, .binds = { erx_trb_form_endpoint(SLOT, block_dci[IN_BLOCK]), IN_BLOCK } };
		const uint32_t head = erx_dma_ledger_position(&state.form.ledger, COMMANDS).index;

		EXPECT(erx_dma_publish(&state.form.ledger, &publication, &sequence) == ERX_DMA_PASSES, "a binding command again");
		check_post(&state, POST_IN);
		refused(&state, event_trb(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, BASE + command_offset(head),
		    ERX_XHCI_COMPLETION_TRB_ERROR, 0, 0), "a failing binding command whose ring a transfer holds");
		EXPECT(erx_dma_ledger_binding(&state.form.ledger, IN_BLOCK) != 0, "the refused failure keeps the binding");
	}
}


/* The form's own shape: every block's ring and pool where erx_device_trb_layout put them. */
static void
test_layout(void)
{
	static erx_trb_form_t form;
	static erx_device_trb_layout_t full;
	const erx_device_trb_controller_t four = { .slots = 4, .ports = 2, .scratchpads = 2, .context_size = 64 };
	erx_device_trb_shape_t longer = erx_device_trb_shape;
	erx_dma_layout_t layout;
	uint32_t blocks = 0;

	EXPECT(erx_device_trb_layout(&full, &erx_device_trb_shape, &four, BASE, 64, UINT64_C(1) << 26), "the form's layout");
	EXPECT(erx_trb_form_make(&form, &full, &no_regions), "the ledger takes the form's own shape");
	layout = *erx_dma_ledger_layout(erx_trb_form_ledger(&form));
	for (uint32_t kind = 0; kind < ERX_DEVICE_TRB_KINDS; kind++)
		blocks += erx_device_trb_shape.blocks[kind];
	EXPECT(layout.table_count == blocks + 2u && layout.pool_count == blocks + 1u, "a ring and a pool per block");
	for (uint32_t block = 0; block < blocks; block++) {
		const uint32_t kind = erx_device_trb_block_kind(&erx_device_trb_shape, block);

		EXPECT(layout.tables[block].first == erx_device_trb_position_offset(&full, block, 0) &&
		    layout.tables[block].count == ERX_DEVICE_TRB_RING_TRBS && layout.tables[block].pool == block,
		    "block b's ring is table b, its pool pool b");
		for (uint32_t buffer = 0; buffer < erx_device_trb_shape.buffers[kind]; buffer++)
			EXPECT(layout.pools[block].first + (uint64_t)buffer * layout.pools[block].stride ==
			    full.regions[full.buffer[block][buffer]].offset, "a pool's buffers are its block's regions");
	}
	EXPECT(layout.tables[blocks].first == full.regions[full.command_ring].offset &&
	    layout.tables[blocks].pool == blocks && layout.pools[blocks].count == 1 &&
	    layout.pools[blocks].first == full.regions[full.input_context].offset,
	    "the command ring's pool holds just the input context");
	EXPECT(layout.tables[blocks + 1u].first == full.regions[full.event_ring].offset &&
	    layout.tables[blocks + 1u].count == ERX_DEVICE_TRB_EVENT_TRBS, "the event ring's segment");

	longer.ring_trbs = ERX_DEVICE_TRB_RING_TRBS + 1u;
	EXPECT(erx_device_trb_layout(&full, &longer, &four, BASE, 64, UINT64_C(1) << 26) && !erx_trb_form_layout(&full, &layout),
	    "a ring longer than the tags keep is refused");
}

static void
test_endpoints_and_requests(void)
{
	static state_t state;
	const erx_device_trb_request_t in = request(POST_IN), control = request(POST_CONTROL);
	erx_device_trb_request_t made;
	erx_dma_sequence_t sequence;

	EXPECT(erx_trb_form_endpoint(1, 1) == 0x21 && erx_trb_form_endpoint(ERX_DEVICE_TRB_SLOTS_MAX, 31) != 0 &&
	    erx_trb_form_endpoint(0, 1) == 0 && erx_trb_form_endpoint(1, 0) == 0 &&
	    erx_trb_form_endpoint(ERX_DEVICE_TRB_SLOTS_MAX + 1u, 1) == 0 && erx_trb_form_endpoint(1, 32) == 0 &&
	    erx_trb_form_endpoint(UINT32_MAX, UINT32_MAX) == 0, "a pair out of range names no endpoint");
	make_small(&state);
	EXPECT(erx_trb_form_post(&state.form, 0, 3, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, SLOT, 32 + 3, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, 2, 3, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a queue out of range or with no ring bound is badarg");
	EXPECT(erx_trb_form_post(&state.form, SLOT, 1, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, SLOT, 3, &control, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG &&
	    erx_trb_form_post(&state.form, SLOT, 2, &in, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a normal transfer on EP0, a control one on a bulk queue and an IN one on an OUT queue are badarg");
	made = in;
	made.length = 65;
	EXPECT(erx_trb_form_post(&state.form, SLOT, 3, &made, 1, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG,
	    "a transfer longer than its block's buffer is badarg");
	EXPECT(erx_dma_ledger_live(&state.form.ledger) == 0, "a refused post holds nothing");
}

int
main(void)
{
	static state_t start;

	test_layout();
	test_endpoints_and_requests();
	test_refusals();
	make_small(&start);
	explore(&start, 0);
	printf("erx_device_trb_form done (%llu states)\n", (unsigned long long)states);
	return (0);
}
