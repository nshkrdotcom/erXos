/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB form's core on the DMA ledger (erx_device_trb_form.h): its layout derived from the
 * form's own, over the form's shape and a small one; the endpoint of a queue; and every sequence
 * of posts and releases up to a fixed depth over the small shape, against a reference model of
 * each ring's positions and cycle state and each pool's buffers. Until binding commands have
 * meanings, a No Op command on the command ring carries each binding. test/host/
 * erx_device_trb_form_test.rb builds it with each ERX_TRB_FORM_SEED_* fault and shows it caught.
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
enum { RING = 6, BLOCKS = 3, COMMANDS = 3, EVENTS = 4, BUFFERS_MAX = 2, LIVE_MAX = 8, DEPTH = 6 };
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

/* The model: each ring's position, cycle state and held positions; each block's held buffers. */
typedef struct transfer {
	uint32_t	block;
	uint32_t	buffer;		/* the block's buffer, or NO_BUFFER */
	uint32_t	head;
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

/* The No Op command that binds ring `table` to `endpoint`, then its completion. */
static void
bind(erx_trb_form_t *form, uint32_t table, uint32_t endpoint)
{
	const erx_dma_description_t noop = { .structure = ERX_STRUCTURE_XHCI_COMMAND_RING,
	    .meaning = ERX_MEANING_XHCI_TRB_NOOP_COMMAND };
	const erx_dma_publication_t publication = { .record_count = 1, .records = &noop, .call = ERX_DMA_PUBLISH_RUN,
	    .binds = { endpoint, table } };
	const erx_dma_place_t head = { COMMANDS, erx_dma_ledger_position(&form->ledger, COMMANDS).index };
	erx_dma_sequence_t sequence;

	EXPECT(erx_dma_publish(&form->ledger, &publication, &sequence) == ERX_DMA_PASSES, "a binding command");
	EXPECT(erx_dma_ledger_acquire(&form->ledger, EVENTS, 1) &&
	    erx_dma_ledger_release_holding(&form->ledger, EVENTS, erx_dma_ledger_holding(&form->ledger, head)),
	    "the binding command completes");
	EXPECT(erx_dma_ledger_binding(&form->ledger, table) == endpoint, "the ring is bound");
}

static void
make_small(state_t *state)
{
	memset(state, 0, sizeof(*state));
	EXPECT(erx_device_trb_layout(&trb, &small_shape, &controller, BASE, 64, UINT64_C(1) << 20), "the small layout");
	EXPECT(erx_trb_form_make(&state->form, &trb, &no_regions), "a form over the small layout");
	for (uint32_t block = 0; block < BLOCKS; block++) {
		bind(&state->form, block, erx_trb_form_endpoint(SLOT, block_dci[block]));
		state->model.cycle[block] = 1;
	}
	state->model.next_tag = 0x7a90;
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
	room = room && model_run(model, block, post_trbs(post), &transfer, &first);
	verdict = erx_trb_form_post(&state->form, SLOT, block_dci[block], &made, transfer.tag, &sequence);
	if (!room) {
		EXPECT(verdict == ERX_DEVICE_TRB_REFUSE_FULL && erx_dma_ledger_live(&state->form.ledger) == live,
		    "a post with no free buffer or too few free positions is full and holds nothing");
		return;
	}
	EXPECT(verdict == ERX_DEVICE_TRB_ACCEPTED, "a post the model has room for is accepted");

	/* The buffer, the lowest free one of the ring's own block, named by the normal or data TRB. */
	if (transfer.buffer != NO_BUFFER) {
		const uint64_t offset = trb.regions[trb.buffer[block][transfer.buffer]].offset;
		const uint32_t named = made.control ? transfer.positions[transfer.positions[1] == RING - 1 ? 2 : 1] :
		    transfer.head;
		const erx_dma_store_t *const store = stored_at(&sequence, position_offset(block, named));

		EXPECT(store != NULL && parameter(store) == BASE + offset, "the TRB names the lowest free buffer of its block");
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

static void
check_release(state_t *state, uint32_t live)
{
	model_t *const model = &state->model;
	const transfer_t transfer = model->transfers[live];
	const erx_dma_found_t found = erx_dma_ledger_holding(&state->form.ledger, (erx_dma_place_t){ transfer.block,
	    transfer.head });
	uint64_t tag = 0;

	EXPECT(erx_trb_form_tag(&state->form, found, &tag) && tag == transfer.tag, "a completion's head gives its tag");
	EXPECT(erx_dma_ledger_acquire(&state->form.ledger, EVENTS, 1) &&
	    erx_dma_ledger_release_holding(&state->form.ledger, EVENTS, found), "the completion ends the holding");
	EXPECT(!erx_trb_form_tag(&state->form, found, &tag), "a holding kept past its release gives no tag");
	for (uint32_t index = 0; index < transfer.position_count; index++)
		model->held[transfer.block][transfer.positions[index]] = false;
	if (transfer.buffer != NO_BUFFER)
		model->buffer_held[transfer.block][transfer.buffer] = false;
	model->transfers[live] = model->transfers[--model->live];
}

static void
explore(const state_t *state, uint32_t depth)
{
	states++;
	if (depth == DEPTH)
		return;
	for (uint32_t step = 0; step < POSTS + state->model.live; step++) {
		state_t next = *state;

		if (step < POSTS)
			check_post(&next, step);
		else
			check_release(&next, step - POSTS);
		explore(&next, depth + 1);
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
	make_small(&start);
	explore(&start, 0);
	printf("erx_device_trb_form done (%llu states)\n", (unsigned long long)states);
	return (0);
}
