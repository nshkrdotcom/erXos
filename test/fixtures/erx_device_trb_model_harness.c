/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's publication and long traces over the hosted model of a non-coherent cache
 * (test/host/erx_device_trb_test.rb; docs/design-usb.md, Verification, "Host tests of the cores").
 *
 * The harness is the effect layer: it keeps the form's bookkeeping in erx_device_trb, turns each
 * install, post, command and take-back into a plan from the bookkeeping's view before to its view
 * after, has erx_device_dma_order order it, and runs the effects on erx_dma_model, the CPU's stores
 * through its cache and the maintenance on its lines. The controller is erx_device_trb_model,
 * which takes a TRB the moment its cycle bit matches, doorbell or not, and acts after any effect:
 * a TRB published before its bytes, or before its own cleans, is taken with stale bytes, which the
 * harness sees as an out buffer read wrong or an in buffer overwritten.
 *
 * The decisions a completion makes from events are the next package's; here the harness makes
 * them from the model's report directly, checking that each names the oldest transfer of its queue.
 *
 * The trace enables slots, addresses them, configures an interrupt IN and a bulk OUT endpoint,
 * posts control, interrupt and bulk transfers of random lengths, fails some, stops queues and
 * moves their dequeue pointers, and disables and re-enables slots, until 100,000 transfers have
 * completed and 1,000 slots have been reused, with the cache line equal to the granule and a
 * quarter of it, at both context sizes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "otp/erts/emulator/nifs/erxos/erx_device_dma.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_trb.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_trb_model.h"
#include "otp/erts/emulator/nifs/erxos/erx_dma_model.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define GRANULE		64u
#define DEVICE_BASE	UINT64_C(0x40000000)
#define DOORBELLS	0x2000u
#define SLOTS		4u
#define TRANSFERS	100000u
#define REUSES		1000u
#define ITERATIONS	4000000u
#define STEPS_MAX	(ERX_DEVICE_TRB_COMMAND_STEPS > ERX_DEVICE_TRB_LINK_STEPS ? ERX_DEVICE_TRB_COMMAND_STEPS : \
	    ERX_DEVICE_TRB_LINK_STEPS)
#define EFFECTS_MAX	ERX_DMA_EFFECTS_BOUND(ERX_DMA_REGIONS_MAX, STEPS_MAX)
#define EP0		1u
#define EP1_IN		3u
#define EP2_OUT		4u

/* What a posted transfer's buffer must hold: an out transfer's bytes, drawn from a pattern. */
typedef struct expectation {
	bool		out;
	uint32_t	pattern;
	uint32_t	length;
} expectation_t;

typedef struct harness {
	erx_device_trb_layout_t		layout;
	erx_device_trb_t		trb;
	erx_dma_state_t			state;		/* who writes each region, as the last plan left it */
	erx_dma_model_t			cache;
	erx_device_trb_model_t		device;
	uint32_t			line;
	uint64_t			random;
	bool				teardown[SLOTS + 1];
	expectation_t			expected[ERX_DEVICE_TRB_BLOCKS_MAX][ERX_DEVICE_TRB_BUFFERS_MAX];
	uint32_t			patterns;
	uint64_t			tags;
	uint32_t			completed;
	uint32_t			reuses;
	uint32_t			failures;
	uint32_t			stops;
	uint8_t				bytes[ERX_DEVICE_BUFFER_MAX];
	uint8_t				read[ERX_DEVICE_BUFFER_MAX];
} harness_t;

static erx_dma_step_t steps[STEPS_MAX];
static erx_dma_effect_t effect_storage[EFFECTS_MAX];

static uint32_t
draw(harness_t *h, uint32_t bound)
{
	h->random ^= h->random << 13;
	h->random ^= h->random >> 7;
	h->random ^= h->random << 17;
	return ((uint32_t)(h->random % bound));
}

static bool
device_read(void *context, uint64_t addr, uint8_t *bytes, uint32_t length)
{
	harness_t *const h = context;

	return (addr >= DEVICE_BASE && erx_dma_model_device_read(&h->cache, addr - DEVICE_BASE, bytes, length));
}

static bool
device_write(void *context, uint64_t addr, const uint8_t *bytes, uint32_t length)
{
	harness_t *const h = context;

	return (addr >= DEVICE_BASE && erx_dma_model_device_write(&h->cache, addr - DEVICE_BASE, bytes, length));
}

/* The block and buffer whose buffer starts at device address `addr`. */
static void
buffer_at(const harness_t *h, uint64_t addr, uint32_t *block, uint32_t *buffer)
{
	for (uint32_t b = 0; b < ERX_DEVICE_TRB_BLOCKS_MAX; b++) {
		const erx_device_trb_kind_t kind = erx_device_trb_block_kind(&h->layout.shape, b);

		for (uint32_t i = 0; i < h->layout.shape.buffers[kind]; i++) {
			if (DEVICE_BASE + h->layout.regions[h->layout.buffer[b][i]].offset == addr) {
				*block = b;
				*buffer = i;
				return;
			}
		}
	}
	CHECK(!"an out TRB names a buffer of the form");
}

/* The controller read an out buffer: it must hold exactly what the post wrote. */
static void
sink(void *context, uint32_t slot, uint32_t dci, uint64_t addr, const uint8_t *bytes, uint32_t length)
{
	harness_t *const h = context;
	uint32_t block, buffer;
	const expectation_t *expected;

	buffer_at(h, addr, &block, &buffer);
	expected = &h->expected[block][buffer];
	CHECK(h->trb.blocks[block].slot == slot && h->trb.blocks[block].dci == dci);
	CHECK(expected->out && expected->length == length);
	for (uint32_t index = 0; index < length; index++)
		CHECK(bytes[index] == erx_device_trb_model_pattern(expected->pattern, index));
}

static void
store_le(harness_t *h, uint64_t offset, uint64_t value, uint32_t width)
{
	uint8_t bytes[8];

	for (uint32_t index = 0; index < width; index++)
		bytes[index] = (uint8_t)(value >> (8u * index));
	CHECK(erx_dma_model_cpu_store(&h->cache, offset, bytes, width));
}

static void
run_step(harness_t *h, const erx_dma_step_t *step)
{
	CHECK(step->kind == ERX_DMA_WRITE || step->kind == ERX_DMA_PUBLISH);
	if (step->target == ERX_DMA_REGISTER) {
		CHECK(step->kind == ERX_DMA_PUBLISH && step->reg >= DOORBELLS && (step->reg - DOORBELLS) % 4u == 0);
		erx_device_trb_model_doorbell(&h->device, (step->reg - DOORBELLS) / 4u, (uint32_t)step->value);
		return;
	}
	switch (step->source) {
	case ERX_DMA_BYTES:
		CHECK(erx_dma_model_cpu_store(&h->cache, step->offset, step->bytes, step->length));
		break;
	case ERX_DMA_ZEROS:
		CHECK(erx_dma_model_cpu_zero(&h->cache, step->offset, step->length));
		break;
	case ERX_DMA_VALUE:
	case ERX_DMA_ADDRESS:
		store_le(h, step->offset, step->value, step->width);
		break;
	}
}

/* A plan from the last state to the bookkeeping's view now, ordered and run, the cache and the controller free to act between effects. */
static void
apply(harness_t *h, erx_dma_call_t call, uint32_t count)
{
	erx_dma_state_t after;
	const erx_dma_plan_t plan = { .call = call, .count = count, .steps = steps };
	erx_dma_effects_t effects = { .capacity = EFFECTS_MAX, .effects = effect_storage };

	erx_device_trb_view(&h->trb, &h->layout, &after);
	CHECK(erx_device_dma_order(&h->state, &after, &plan, false, GRANULE, h->line, &effects));
	for (uint32_t index = 0; index < effects.count; index++) {
		const erx_dma_effect_t *const effect = &effects.effects[index];

		switch (effect->kind) {
		case ERX_DMA_EFFECT_ZERO:
			CHECK(erx_dma_model_cpu_zero(&h->cache, effect->offset, effect->length));
			break;
		case ERX_DMA_EFFECT_STEP:
			run_step(h, &plan.steps[effect->step]);
			break;
		case ERX_DMA_EFFECT_CLEAN:
			CHECK(erx_dma_model_clean(&h->cache, effect->offset, effect->length, effect->line));
			break;
		case ERX_DMA_EFFECT_CLEAN_INVAL:
			CHECK(erx_dma_model_clean_inval(&h->cache, effect->offset, effect->length, effect->line));
			break;
		case ERX_DMA_EFFECT_BARRIER:
			break;
		}
		erx_dma_model_tick(&h->cache);
		if (draw(h, 4) == 0)
			CHECK(erx_device_trb_model_run(&h->device) == ERX_OK);
	}
	h->state = after;
}

/* Buffers answered `stopped` come back, and their expectations go. */
static void
take_back_stopped(harness_t *h, const erx_device_trb_stopped_t *stopped, uint32_t count)
{
	for (uint32_t index = 0; index < count; index++)
		bzero(&h->expected[stopped[index].block][stopped[index].buffer], sizeof(expectation_t));
	apply(h, ERX_DMA_CALL_COMPLETE, 0);
}

static uint32_t
block_of(const harness_t *h, const erx_device_trb_block_t *block)
{
	return ((uint32_t)(block - h->trb.blocks));
}

/* A transfer's completion: it names its queue's oldest transfer's last TRB; an in buffer holds the controller's pattern. */
static void
transfer_completed(harness_t *h, const erx_device_trb_model_event_t *event)
{
	const erx_device_trb_block_t *const queue = erx_device_trb_queue(&h->trb, event->slot, event->dci);
	erx_device_trb_transfer_t done;
	uint32_t block;
	uint64_t offset;

	CHECK(queue != NULL && queue->posted != 0);
	block = block_of(h, queue);
	CHECK(event->pointer == DEVICE_BASE + erx_device_trb_position_offset(&h->layout, block,
	    queue->transfers[queue->head].last));
	CHECK(erx_device_trb_retire(&h->trb, event->slot, event->dci, &done));
	if (event->code != ERX_XHCI_COMPLETION_SUCCESS)
		CHECK(erx_device_trb_halt(&h->trb, event->slot, event->dci));
	apply(h, ERX_DMA_CALL_COMPLETE, 0);
	if (event->code == ERX_XHCI_COMPLETION_SUCCESS && !h->expected[block][done.buffer].out) {
		CHECK(event->length == done.length);
		offset = h->layout.regions[h->layout.buffer[block][done.buffer]].offset;
		CHECK(erx_dma_model_cpu_load(&h->cache, offset, h->read, done.length));
		for (uint32_t index = 0; index < done.length; index++)
			CHECK(h->read[index] == erx_device_trb_model_pattern(event->pattern, index));
	}
	bzero(&h->expected[block][done.buffer], sizeof(expectation_t));
	h->completed++;
}

static void
command_completed(harness_t *h, const erx_device_trb_model_event_t *event)
{
	erx_device_trb_stopped_t stopped[ERX_DEVICE_TRB_STOPPED_MAX];
	const erx_device_trb_command_kind_t kind = h->trb.command.kind;
	const uint32_t slot = h->trb.command.slot;
	uint32_t count;
	uint64_t tag;

	CHECK(kind != ERX_DEVICE_TRB_NO_COMMAND);
	CHECK(event->pointer == DEVICE_BASE + erx_device_trb_position_offset(&h->layout, ERX_DEVICE_TRB_BLOCKS_MAX,
	    h->trb.command.position));
	CHECK(erx_device_trb_command_done(&h->trb, &h->layout, event->code == ERX_XHCI_COMPLETION_SUCCESS ?
	    ERX_DEVICE_TRB_SUCCESS : ERX_DEVICE_TRB_FAILED, event->slot, &tag, stopped, &count));
	take_back_stopped(h, stopped, count);
	if (kind == ERX_DEVICE_TRB_DISABLE_SLOT) {
		h->teardown[slot] = false;
		h->reuses++;
	}
}

static void
drain(harness_t *h)
{
	for (uint32_t index = 0; index < h->device.event_count; index++) {
		const erx_device_trb_model_event_t event = h->device.events[index];

		if (event.kind == ERX_DEVICE_TRB_MODEL_COMMAND)
			command_completed(h, &event);
		else
			transfer_completed(h, &event);
	}
	h->device.event_count = 0;
}

static const erx_device_trb_endpoint_t endpoints[] = {
	{ .number = 1, .in = true, .kind = ERX_DEVICE_TRB_INTERRUPT, .packet = 64, .interval = 3, .payload = 64 },
	{ .number = 2, .in = false, .kind = ERX_DEVICE_TRB_BULK, .packet = 64, .payload = 64 },
};

static bool
slot_quiet(const harness_t *h, uint32_t slot)
{
	for (uint32_t dci = EP0; dci <= EP2_OUT; dci++) {
		const erx_device_trb_block_t *const queue = erx_device_trb_queue(&h->trb, slot, dci);

		if (queue != NULL && queue->posted != 0)
			return (false);
	}
	return (true);
}

/* The next command the trace needs, if any: recovery first, then teardown, then bring-up, then a random stop. */
static bool
next_command(harness_t *h, erx_device_trb_command_t *command)
{
	for (uint8_t slot = 1; slot <= SLOTS; slot++) {
		for (uint8_t dci = EP0; dci <= EP2_OUT; dci++) {
			const erx_device_trb_block_t *const queue = erx_device_trb_queue(&h->trb, slot, dci);

			if (queue == NULL)
				continue;
			if (queue->state == ERX_DEVICE_TRB_HALTED)
				*command = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_RESET_ENDPOINT, .slot = slot, .dci = dci };
			else if (queue->state == ERX_DEVICE_TRB_STOPPED)
				*command = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_SET_TR_DEQUEUE, .slot = slot, .dci = dci };
			else
				continue;
			return (true);
		}
	}
	for (uint8_t slot = 1; slot <= SLOTS; slot++) {
		if (!h->trb.slots[slot].enabled)
			continue;
		if (h->teardown[slot] && slot_quiet(h, slot))
			*command = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_DISABLE_SLOT, .slot = slot };
		else if (!h->teardown[slot] && erx_device_trb_queue(&h->trb, slot, EP0) == NULL)
			*command = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_ADDRESS_DEVICE, .slot = slot,
			    .route = slot, .root_port = 1, .speed = ERX_XHCI_SPEED_HIGH, .ep0_packet = 64 };
		else if (!h->teardown[slot] && erx_device_trb_queue(&h->trb, slot, EP1_IN) == NULL)
			*command = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS, .slot = slot,
			    .add_count = 2, .add = endpoints };
		else
			continue;
		return (true);
	}
	for (uint8_t slot = 1; slot <= SLOTS; slot++) {
		if (!h->trb.slots[slot].enabled) {
			*command = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_ENABLE_SLOT };
			return (true);
		}
	}
	if (draw(h, 64) == 0) {
		const uint8_t slot = (uint8_t)(1u + draw(h, SLOTS)), dci = (uint8_t)(EP0 + draw(h, EP2_OUT));
		const erx_device_trb_block_t *const queue = erx_device_trb_queue(&h->trb, slot, dci);

		if (queue != NULL && queue->state == ERX_DEVICE_TRB_OPEN) {
			*command = (erx_device_trb_command_t){ .kind = ERX_DEVICE_TRB_STOP_ENDPOINT, .slot = slot, .dci = dci };
			h->stops++;
			return (true);
		}
	}
	return (false);
}

/* A random transfer on a random queue of a slot that is not being torn down. */
static void
post_transfer(harness_t *h)
{
	const uint32_t slot = 1u + draw(h, SLOTS), dci = EP0 + draw(h, EP2_OUT);
	const erx_device_trb_block_t *const queue = erx_device_trb_queue(&h->trb, slot, dci);
	erx_device_trb_request_t request = { .bytes = h->bytes };
	erx_device_trb_kind_t kind;
	uint32_t count, block, size;
	erx_device_trb_verdict_t verdict;

	if (queue == NULL || h->teardown[slot])
		return;
	block = block_of(h, queue);
	kind = erx_device_trb_block_kind(&h->layout.shape, block);
	size = h->layout.shape.buffer_size[kind];
	request.control = kind == ERX_DEVICE_TRB_CONTROL;
	request.data = !request.control || draw(h, 4) != 0;
	request.device_writes = request.control ? draw(h, 2) == 0 : dci % 2u == 1u;
	request.length = !request.data ? 0 : request.control ? 1u + draw(h, size) : draw(h, size + 1u);
	request.setup[0] = request.data && request.device_writes ? 0x80 : 0x40;
	request.setup[1] = 6;
	request.setup[6] = (uint8_t)request.length;
	request.setup[7] = (uint8_t)(request.length >> 8);
	for (uint32_t index = 0; index < request.length; index++)
		h->bytes[index] = erx_device_trb_model_pattern(h->patterns, index);
	verdict = erx_device_trb_post(&h->trb, &h->layout, slot, dci, &request, h->tags++, steps, &count);
	if (verdict != ERX_DEVICE_TRB_ACCEPTED) {
		CHECK(verdict == ERX_DEVICE_TRB_REFUSE_FULL || verdict == ERX_DEVICE_TRB_REFUSE_HALTED);
		return;
	}
	CHECK(count <= ERX_DEVICE_TRB_POST_STEPS);
	h->expected[block][queue->transfers[(queue->head + queue->posted - 1u) % ERX_DEVICE_TRB_BUFFERS_MAX].buffer] =
	    (expectation_t){ .out = request.data && !request.device_writes, .pattern = h->patterns++,
	    .length = request.length };
	apply(h, ERX_DMA_CALL_POST, count);
}

static void
run_trace(uint32_t context_size, uint32_t line, uint64_t seed)
{
	const erx_device_trb_controller_t controller = { .slots = SLOTS, .ports = 4, .scratchpads = 2,
	    .context_size = context_size, .doorbells = DOORBELLS };
	const erx_device_trb_memory_t memory = { .read = device_read, .write = device_write };
	harness_t *const h = calloc(1, sizeof(*h));
	erx_device_trb_memory_t own = memory;
	erx_device_trb_command_t command;
	uint32_t count, iterations = 0;

	CHECK(h != NULL);
	h->line = line;
	h->random = seed;
	CHECK(erx_device_trb_layout(&h->layout, &erx_device_trb_shape, &controller, DEVICE_BASE, GRANULE, 1u << 20));
	CHECK(h->layout.bytes < (1u << 20));
	CHECK(erx_dma_model_init(&h->cache, (h->layout.bytes + GRANULE - 1) / GRANULE * GRANULE, GRANULE, line, seed));
	own.context = h;
	erx_device_trb_model_init(&h->device, &h->layout, &own, sink, h);
	erx_device_trb_init(&h->trb);
	erx_device_trb_view(&h->trb, &h->layout, &h->state);
	h->trb.installed = true;
	apply(h, ERX_DMA_CALL_INSTALL, erx_device_trb_link_steps(&h->layout, steps));

	while ((h->completed < TRANSFERS || h->reuses < REUSES) && iterations++ < ITERATIONS) {
		drain(h);
		if (h->trb.command.kind == ERX_DEVICE_TRB_NO_COMMAND && next_command(h, &command)) {
			CHECK(erx_device_trb_command(&h->trb, &h->layout, &command, h->tags++, steps, &count) ==
			    ERX_DEVICE_TRB_ACCEPTED);
			apply(h, ERX_DMA_CALL_POST, count);
		}
		post_transfer(h);
		if (draw(h, 512) == 0) {
			const uint32_t slot = 1u + draw(h, SLOTS);

			h->device.rings[slot][EP0 + draw(h, EP2_OUT)].fail = true;
			h->failures++;
		}
		if (draw(h, 100) == 0)
			h->teardown[1u + draw(h, SLOTS)] = true;
		CHECK(erx_device_trb_model_run(&h->device) == ERX_OK);
	}
	CHECK(h->completed >= TRANSFERS && h->reuses >= REUSES);
	printf("trace: context %u, line %u: %u transfers, %u slot reuses, %u failures, %u stops, %u iterations\n",
	    context_size, line, h->completed, h->reuses, h->failures, h->stops, iterations);
	erx_dma_model_fini(&h->cache);
	free(h);
}

int
main(void)
{
	run_trace(32, GRANULE, 0x9e3779b97f4a7c15u);
	run_trace(64, GRANULE / 4u, 0x2545f4914f6cdd1du);
	printf("erx_device_trb_model done\n");
	return (0);
}
