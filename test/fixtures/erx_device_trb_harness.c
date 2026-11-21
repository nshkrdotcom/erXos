/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's bookkeeping explored (test/host/erx_device_trb_test.rb; docs/design-usb.md,
 * Verification, "Host tests of the cores").
 *
 * The shape is the design's small model: rings of six TRBs and a link, two slots, two queues each
 * (EP0 on a control block, an interrupt IN endpoint on an interrupt block) and one buffer a queue.
 * From the state an install leaves, every command, transfer post, retirement, halt and command
 * completion of every outcome is applied to every state reached, breadth first and deduplicated,
 * so ring wrap, stops, resets, dequeue moves, drops and slot reuse are all reachable. The states
 * are too many for a fixed point, so the search stops at a bound on states and prints the depth
 * it reached; the model harness's traces carry the longer sequences.
 *
 * Every state reached must keep the form's invariants, checked here from the state alone: the
 * enqueue position never rests on the link; each posted transfer holds its own buffer and lies
 * in ring order inside the stop span, whose start is in it; a reserved block belongs to the
 * command in flight; and a queue belongs to an enabled slot. Every Disable Slot accepted must
 * find each queue of its slot stopped, halted or open with nothing posted, and no post is accepted
 * on a queue the command in flight evaluates, drops or disables.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "otp/erts/emulator/nifs/erxos/erx_device_trb.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define RING_TRBS	7u
#define SLOTS		2u
#define BLOCKS		4u		/* two control, two interrupt */
#define STATES_MAX	400000u
#define TABLE_SIZE	(1u << 20)	/* open addressing over the visited states' hashes */
#define EP1_IN		3u		/* endpoint 1 IN's device context index */

/* The part of the bookkeeping the small shape uses, the unit the search stores and hashes. */
typedef struct projection {
	erx_device_trb_slot_t		slots[SLOTS + 1];
	erx_device_trb_block_t		blocks[BLOCKS];
	erx_device_trb_ring_t		command_ring;
	erx_device_trb_pending_t	command;
} projection_t;

static const erx_device_trb_shape_t shape = { .ring_trbs = RING_TRBS, .blocks = { 2, 2, 0 }, .buffers = { 1, 1, 1 },
    .buffer_size = { 64, 64, 64 } };
static erx_device_trb_layout_t layout;
static projection_t *states;
static uint32_t *depths;
static uint64_t *table;
static uint32_t state_count;
static erx_dma_step_t steps[ERX_DEVICE_TRB_COMMAND_STEPS];

static void
project(const erx_device_trb_t *trb, projection_t *projection)
{
	bzero(projection, sizeof(*projection));
	memcpy(projection->slots, trb->slots, sizeof(projection->slots));
	memcpy(projection->blocks, trb->blocks, sizeof(projection->blocks));
	projection->command_ring = trb->command_ring;
	projection->command = trb->command;
}

static void
restore(const projection_t *projection, erx_device_trb_t *trb)
{
	erx_device_trb_init(trb);
	memcpy(trb->slots, projection->slots, sizeof(projection->slots));
	memcpy(trb->blocks, projection->blocks, sizeof(projection->blocks));
	trb->command_ring = projection->command_ring;
	trb->command = projection->command;
}

static uint64_t
hash(const projection_t *projection)
{
	const uint8_t *const bytes = (const uint8_t *)projection;
	uint64_t value = 0xcbf29ce484222325u;

	for (size_t index = 0; index < sizeof(*projection); index++)
		value = (value ^ bytes[index]) * 0x100000001b3u;
	return (value | 1u);
}

/* Whether the state is new; a new one is stored at `depth`. */
static bool
visit(const erx_device_trb_t *trb, uint32_t depth)
{
	projection_t projection;
	uint64_t key;
	uint32_t at;

	project(trb, &projection);
	key = hash(&projection);
	for (at = (uint32_t)key & (TABLE_SIZE - 1); table[at] != 0; at = (at + 1) & (TABLE_SIZE - 1)) {
		const uint32_t index = (uint32_t)(table[at] >> 40);

		if ((table[at] & 0xffffffffffu) == (key & 0xffffffffffu) &&
		    memcmp(&states[index], &projection, sizeof(projection)) == 0)
			return (false);
	}
	if (state_count == STATES_MAX)
		return (false);
	states[state_count] = projection;
	depths[state_count] = depth;
	table[at] = (uint64_t)state_count << 40 | (key & 0xffffffffffu);
	state_count++;
	return (true);
}

static uint32_t
distance(uint32_t from, uint32_t to)
{
	return ((to + RING_TRBS - from) % RING_TRBS);
}

static void
check_block(const erx_device_trb_t *trb, uint32_t index)
{
	const erx_device_trb_block_t *const block = &trb->blocks[index];
	uint32_t previous = 0, busy = 0;

	CHECK(block->ring.enqueue < RING_TRBS - 1u);
	CHECK(block->state != ERX_DEVICE_TRB_RESERVED || (trb->command.reserved >> index & 1u) != 0);
	CHECK(block->state < ERX_DEVICE_TRB_OPEN || trb->slots[block->slot].enabled);
	CHECK(block->state >= ERX_DEVICE_TRB_OPEN || block->posted == 0);
	CHECK(erx_device_trb_in_stop_span(&layout, block, block->span_start));
	CHECK(erx_device_trb_in_stop_span(&layout, block, block->ring.enqueue));
	for (uint32_t taken = 0; taken < block->posted; taken++) {
		const erx_device_trb_transfer_t *const transfer =
		    &block->transfers[(block->head + taken) % ERX_DEVICE_TRB_BUFFERS_MAX];

		CHECK((busy >> transfer->buffer & 1u) == 0);
		busy |= 1u << transfer->buffer;
		CHECK(distance(block->span_start, transfer->first) >= previous);
		CHECK(distance(block->span_start, transfer->first) <= distance(block->span_start, transfer->last));
		CHECK(distance(block->span_start, transfer->last) < distance(block->span_start, block->ring.enqueue));
		CHECK(erx_device_trb_in_stop_span(&layout, block, transfer->first));
		CHECK(erx_device_trb_in_stop_span(&layout, block, transfer->last));
		previous = distance(block->span_start, transfer->last) + 1u;
	}
	CHECK(busy == block->busy);
}

static void
check_state(const erx_device_trb_t *trb)
{
	for (uint32_t index = 0; index < BLOCKS; index++)
		check_block(trb, index);
	CHECK(trb->command_ring.enqueue < RING_TRBS - 1u);
}

/* The oracle of Disable Slot: what the design's table says, from the state before it. */
static bool
disable_allowed(const erx_device_trb_t *trb, uint32_t slot)
{
	for (uint32_t index = 0; index < BLOCKS; index++) {
		const erx_device_trb_block_t *const block = &trb->blocks[index];

		if (block->state >= ERX_DEVICE_TRB_OPEN && block->slot == slot && block->state != ERX_DEVICE_TRB_STOPPED &&
		    block->state != ERX_DEVICE_TRB_HALTED && !(block->state == ERX_DEVICE_TRB_OPEN && block->posted == 0))
			return (false);
	}
	return (true);
}

/* The oracle of a post: no queue that the command in flight evaluates, drops or disables takes one. */
static bool
held(const erx_device_trb_t *trb, uint32_t slot, uint32_t dci)
{
	const erx_device_trb_pending_t *const command = &trb->command;

	return (command->slot == slot && ((command->kind == ERX_DEVICE_TRB_EVALUATE_CONTEXT && dci == 1) ||
	    command->kind == ERX_DEVICE_TRB_DISABLE_SLOT ||
	    (command->kind == ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS && dci == EP1_IN && (command->held >> dci & 1u) != 0)));
}

static const erx_device_trb_endpoint_t ep1_in = { .number = 1, .in = true, .kind = ERX_DEVICE_TRB_INTERRUPT,
    .packet = 8, .interval = 3, .payload = 8 };

/* The commands the search posts: every kind on every slot and queue, valid parameters. */
static uint32_t
commands(erx_device_trb_command_t *out)
{
	uint32_t count = 0;

	out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_ENABLE_SLOT };
	for (uint8_t slot = 1; slot <= SLOTS; slot++) {
		out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_ADDRESS_DEVICE, .slot = slot,
		    .route = 0, .root_port = 1, .speed = ERX_XHCI_SPEED_FULL, .ep0_packet = 8 };
		out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_EVALUATE_CONTEXT, .slot = slot,
		    .ep0_packet = 64 };
		out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS, .slot = slot,
		    .add_count = 1, .add = &ep1_in };
		out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS, .slot = slot,
		    .drops = 1u << EP1_IN };
		out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS, .slot = slot,
		    .add_count = 1, .add = &ep1_in, .drops = 1u << EP1_IN };
		for (uint8_t dci = 1; dci <= EP1_IN; dci += 2) {
			out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_STOP_ENDPOINT, .slot = slot, .dci = dci };
			out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_RESET_ENDPOINT, .slot = slot, .dci = dci };
			out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_SET_TR_DEQUEUE, .slot = slot, .dci = dci };
		}
		out[count++] = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_DISABLE_SLOT, .slot = slot };
	}
	return (count);
}

/* Every successor of state `index`, each checked and visited. */
static void
expand(uint32_t index)
{
	static const uint8_t payload[8] = { 0 };
	/* Each request, and whether the form may ever accept it on EP0 or on the IN endpoint. */
	static const struct {
		erx_device_trb_request_t	request;
		bool				acceptable;
	} requests[] = {
		{ { .control = true, .data = false, .setup = { 0x00, 9, 1, 0, 0, 0, 0, 0 } }, true },
		{ { .control = true, .data = true, .device_writes = true, .length = 8,
		    .setup = { 0x80, 6, 0, 1, 0, 0, 8, 0 } }, true },
		{ { .control = false, .device_writes = true, .length = 8 }, true },
		/* A data stage the device writes behind a setup whose direction is OUT. */
		{ { .control = true, .data = true, .device_writes = true, .length = 8,
		    .setup = { 0x00, 9, 1, 0, 0, 0, 8, 0 } }, false },
		/* A data stage the device reads behind a setup whose direction is IN. */
		{ { .control = true, .data = true, .device_writes = false, .length = 8, .bytes = payload,
		    .setup = { 0x80, 6, 0, 1, 0, 0, 8, 0 } }, false },
		/* A normal transfer the device reads, against EP0's kind and the IN endpoint's direction. */
		{ { .control = false, .device_writes = false, .length = 8, .bytes = payload }, false },
	};
	const uint32_t depth = depths[index] + 1u;
	erx_device_trb_command_t list[32];
	const uint32_t command_count = commands(list);
	erx_device_trb_t trb, before;
	erx_device_trb_stopped_t stopped[ERX_DEVICE_TRB_STOPPED_MAX];
	erx_device_trb_transfer_t done;
	uint32_t count;
	uint64_t tag;

	restore(&states[index], &before);
	for (uint32_t command = 0; command < command_count; command++) {
		trb = before;
		if (erx_device_trb_command(&trb, &layout, &list[command], 0, steps, &count) != ERX_DEVICE_TRB_ACCEPTED)
			continue;
		CHECK(count <= ERX_DEVICE_TRB_COMMAND_STEPS);
		if (list[command].kind == ERX_DEVICE_TRB_DISABLE_SLOT)
			CHECK(disable_allowed(&before, list[command].slot));
		check_state(&trb);
		visit(&trb, depth);
	}
	for (uint32_t outcome = ERX_DEVICE_TRB_SUCCESS; outcome <= ERX_DEVICE_TRB_FAILED; outcome++) {
		for (uint32_t slot = 1; slot <= SLOTS; slot++) {
			trb = before;
			if (!erx_device_trb_command_done(&trb, &layout, outcome, slot, &tag, stopped, &count))
				continue;
			CHECK(count <= ERX_DEVICE_TRB_STOPPED_MAX);
			check_state(&trb);
			visit(&trb, depth);
		}
	}
	for (uint32_t slot = 1; slot <= SLOTS; slot++) {
		for (uint32_t dci = 1; dci <= EP1_IN; dci += 2) {
			for (uint32_t request = 0; request < sizeof(requests) / sizeof(requests[0]); request++) {
				trb = before;
				if (erx_device_trb_post(&trb, &layout, slot, dci, &requests[request].request, 0, steps, &count) !=
				    ERX_DEVICE_TRB_ACCEPTED)
					continue;
				CHECK(requests[request].acceptable);
				CHECK(count <= ERX_DEVICE_TRB_POST_STEPS);
				CHECK(!held(&before, slot, dci));
				check_state(&trb);
				visit(&trb, depth);
			}
			trb = before;
			if (erx_device_trb_retire(&trb, slot, dci, &done)) {
				check_state(&trb);
				visit(&trb, depth);
			}
			trb = before;
			if (erx_device_trb_halt(&trb, slot, dci)) {
				check_state(&trb);
				visit(&trb, depth);
			}
		}
	}
}

int
main(void)
{
	const erx_device_trb_controller_t controller = { .slots = SLOTS, .ports = 2, .context_size = 32,
	    .doorbells = 0x2000 };
	erx_device_trb_t trb;
	uint32_t next = 0, wraps = 0, reuses = 0;

	CHECK(erx_device_trb_layout(&layout, &shape, &controller, 0x100000, 64, 1u << 20));
	states = calloc(STATES_MAX, sizeof(*states));
	depths = calloc(STATES_MAX, sizeof(*depths));
	table = calloc(TABLE_SIZE, sizeof(*table));
	CHECK(states != NULL && depths != NULL && table != NULL);
	erx_device_trb_init(&trb);
	check_state(&trb);
	visit(&trb, 0);
	while (next < state_count && state_count < STATES_MAX)
		expand(next++);

	/* Ring wrap and slot reuse must be among the states reached. */
	for (uint32_t index = 0; index < state_count; index++) {
		wraps += states[index].blocks[0].ring.cycle == 0;
		reuses += states[index].blocks[0].state >= ERX_DEVICE_TRB_OPEN && states[index].blocks[0].slot == 2;
	}
	CHECK(wraps != 0 && reuses != 0);
	printf("erx_device_trb explored %u states to depth %u (fixed point %s)\n", state_count,
	    depths[state_count - 1], next == state_count ? "reached" : "not reached");
	free(states);
	free(depths);
	free(table);
	printf("erx_device_trb done\n");
	return (0);
}
