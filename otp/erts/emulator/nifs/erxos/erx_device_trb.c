/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's core (erx_device_trb.h; docs/design-usb.md, "The TRB ring form").
 */

#include "erx_device_trb.h"

#include "erx/abi.h"
#include "erx_device_sequencer.h"
#include "liberx/backend/core/mem.h"

const erx_device_trb_shape_t erx_device_trb_shape = {
	.ring_trbs = ERX_DEVICE_TRB_RING_TRBS,
	.blocks = { 16u, 16u, 4u },
	.buffers = { 1u, 4u, 2u },
	.buffer_size = { ERX_XHCI_CONTROL_BUFFER_SIZE, ERX_XHCI_INTERRUPT_BUFFER_SIZE, ERX_XHCI_BULK_BUFFER_SIZE },
};

/* Each TRB is 16 bytes; every format puts its parameter, status and control words in the same places. */
#define TRB_SIZE		ERX_XHCI_TRB_NORMAL_SIZE
#define TRB_PARAMETER		ERX_XHCI_TRB_NORMAL_OFF_BUFFER
#define TRB_STATUS		ERX_XHCI_TRB_NORMAL_OFF_STATUS
#define TRB_CONTROL		ERX_XHCI_TRB_NORMAL_OFF_CONTROL
/* The command ring, where a block number names a ring. */
#define COMMAND_RING		ERX_DEVICE_TRB_BLOCKS_MAX
#define NO_REGION		UINT16_MAX
/* An input context holds the input control context before a device context's 32 (6.2.5). */
#define INPUT_CONTEXTS		(ERX_XHCI_DEVICE_CONTEXTS + 1u)
/* The doorbell array is of 32-bit registers, doorbell i for slot i, 0 for the command ring (5.6). */
#define DOORBELL_STRIDE		((uint32_t)sizeof(uint32_t))
/* The most hub tiers a route string names (abi/formats/xhci.txt, the slot context). */
#define ROUTE_TIERS		(20u / ERX_XHCI_ROUTE_TIER_BITS)
#define ROUTE_TIER_MASK		((1u << ERX_XHCI_ROUTE_TIER_BITS) - 1u)
/* An endpoint context's largest Max Burst Size (xHCI 1.2, Table 6-9, p. 452); the seed lets the field's whole width through. */
#ifdef ERX_DEVICE_TRB_SEED_BURST_UNCHECKED
#define BURST_MAX		255u
#else
#define BURST_MAX		15u
#endif

_Static_assert(ERX_XHCI_TRB_LINK_SIZE == TRB_SIZE && ERX_XHCI_TRB_SETUP_SIZE == TRB_SIZE &&
    ERX_XHCI_TRB_COMMAND_SIZE == TRB_SIZE && ERX_XHCI_TRB_SET_DEQUEUE_COMMAND_OFF_PARAMETER == TRB_PARAMETER &&
    ERX_XHCI_TRB_LINK_OFF_CONTROL == TRB_CONTROL && ERX_XHCI_TRB_COMMAND_OFF_CONTROL == TRB_CONTROL,
    "every TRB format has one shape");
_Static_assert(16u + 16u + 4u == ERX_DEVICE_TRB_BLOCKS_MAX, "the form's blocks fill the bound");
_Static_assert(ERX_DEVICE_TRB_SLOTS_MAX < 64u && ERX_DEVICE_TRB_BLOCKS_MAX <= 64u, "reservations fit a mask");

/* A plan being built into the caller's steps. */
typedef struct plan {
	erx_dma_step_t	*steps;
	uint32_t	count;
} plan_t;

static void
add(plan_t *plan, erx_dma_step_t step)
{
	plan->steps[plan->count++] = step;
}

static erx_dma_step_t
memory_step(erx_dma_step_kind_t kind, erx_dma_source_t source, uint64_t offset, uint32_t width)
{
	return ((erx_dma_step_t){ .kind = kind, .target = ERX_DMA_MEMORY, .source = source, .width = width,
	    .reg = ERX_DMA_NO_REGISTER, .reg_high = ERX_DMA_NO_REGISTER, .offset = offset });
}

static void
add_value(plan_t *plan, uint64_t offset, uint32_t width, uint64_t value)
{
	erx_dma_step_t step = memory_step(ERX_DMA_WRITE, ERX_DMA_VALUE, offset, width);

	step.value = value;
	add(plan, step);
}

/* A device address the device may reach `extent` bytes from; xHCI's carry flags in their low bits, such as a dequeue cycle. */
static void
add_address(plan_t *plan, uint64_t offset, uint64_t address, uint64_t extent)
{
	erx_dma_step_t step = memory_step(ERX_DMA_WRITE, ERX_DMA_ADDRESS, offset, 8u);

	step.value = address;
	step.extent = extent;
	add(plan, step);
}

static void
add_zeros(plan_t *plan, uint64_t offset, uint64_t length)
{
	erx_dma_step_t step = memory_step(ERX_DMA_WRITE, ERX_DMA_ZEROS, offset, 0u);

	step.length = length;
	add(plan, step);
}

static void
add_bytes(plan_t *plan, uint64_t offset, const uint8_t *bytes, uint32_t length)
{
	erx_dma_step_t step = memory_step(ERX_DMA_WRITE, ERX_DMA_BYTES, offset, 0u);

	step.length = length;
	step.bytes = bytes;
	add(plan, step);
}

/* The two publications: a TRB's control word with its new cycle, then a doorbell. */
static void
add_publications(plan_t *plan, const erx_device_trb_layout_t *layout, uint64_t control_offset, uint32_t control,
    uint32_t doorbell, uint32_t target)
{
	erx_dma_step_t cycle = memory_step(ERX_DMA_PUBLISH, ERX_DMA_VALUE, control_offset, 4u);
	const erx_dma_step_t ring = { .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE,
	    .width = 4u, .reg = layout->doorbells + doorbell * DOORBELL_STRIDE, .reg_high = ERX_DMA_NO_REGISTER,
	    .value = target };

	cycle.value = control;
	add(plan, cycle);
	add(plan, ring);
}

/* The layout. */

static bool
power_of_two(uint64_t value)
{
	return (value != 0 && (value & (value - 1)) == 0);
}

static uint64_t
round_up(uint64_t value, uint64_t align)
{
	return ((value + align - 1) & ~(align - 1));
}

static uint32_t
trbs_per_transfer(erx_device_trb_kind_t kind)
{
	return (kind == ERX_DEVICE_TRB_CONTROL ? ERX_DEVICE_TRB_TRANSFER_TRBS : 1u);
}

static bool
shape_valid(const erx_device_trb_shape_t *shape)
{
	uint32_t blocks = 0;

	if (shape->ring_trbs < 4u || shape->ring_trbs > UINT8_MAX)
		return (false);
	for (uint32_t kind = 0; kind < ERX_DEVICE_TRB_KINDS; kind++) {
		blocks += shape->blocks[kind];
		if (shape->blocks[kind] != 0 && (shape->buffers[kind] == 0 ||
		    shape->buffers[kind] > ERX_DEVICE_TRB_BUFFERS_MAX ||
		    shape->buffers[kind] * trbs_per_transfer(kind) > shape->ring_trbs - 3u ||
		    !power_of_two(shape->buffer_size[kind]) || shape->buffer_size[kind] > ERX_DEVICE_BUFFER_MAX))
			return (false);
	}
	return (blocks <= ERX_DEVICE_TRB_BLOCKS_MAX);
}

static bool
controller_valid(const erx_device_trb_controller_t *controller)
{
	return (controller->slots >= 1 && controller->slots <= ERX_DEVICE_TRB_SLOTS_MAX && controller->ports >= 1 &&
	    controller->ports <= UINT8_MAX && controller->scratchpads <= ERX_DEVICE_TRB_SCRATCHPADS_MAX &&
	    controller->doorbells % DOORBELL_STRIDE == 0 &&
	    controller->doorbells <= UINT32_MAX - ERX_DEVICE_TRB_SLOTS_MAX * DOORBELL_STRIDE &&
	    (controller->context_size == ERX_XHCI_SLOT_CONTEXT_SIZE ||
	    controller->context_size == 2u * ERX_XHCI_SLOT_CONTEXT_SIZE));
}

/* Placing regions in order from offset 0: `cursor` is the first free offset, `limit` the memory's size. */
typedef struct placer {
	erx_device_trb_layout_t	*layout;
	uint64_t		cursor;
	uint64_t		limit;
	bool			fits;
} placer_t;

/*
 * The next region of `length` bytes, rounded to the granule, at a device address aligned to
 * `align` and the granule, moved to the next multiple of `boundary` when it would cross one.
 */
static uint16_t
place(placer_t *placer, erx_device_trb_region_kind_t kind, uint32_t index, uint64_t length, uint64_t align,
    uint64_t boundary)
{
	erx_device_trb_layout_t *const layout = placer->layout;
	const uint64_t granule = layout->granule, bytes = round_up(length, granule);
	uint64_t start = round_up(layout->device_base + placer->cursor, align > granule ? align : granule);
	const uint16_t region = (uint16_t)layout->region_count;

	if (boundary != 0 && start / boundary != (start + bytes - 1) / boundary)
		start = round_up(start, boundary);
	layout->regions[region] = (erx_device_trb_region_t){ .offset = start - layout->device_base,
	    .length = bytes, .kind = kind, .index = index };
	layout->region_count++;
	placer->cursor = start - layout->device_base + bytes;
	placer->fits = placer->fits && placer->cursor <= placer->limit;
	return (region);
}

/* A ring's segment followed by its pad of the same size, inside one 64 KiB boundary. */
static uint64_t
ring_bytes(uint32_t trbs)
{
	return (2u * (uint64_t)trbs * TRB_SIZE);
}

erx_device_trb_kind_t
erx_device_trb_block_kind(const erx_device_trb_shape_t *shape, uint32_t block)
{
	if (block < shape->blocks[ERX_DEVICE_TRB_CONTROL])
		return (ERX_DEVICE_TRB_CONTROL);
	if (block < shape->blocks[ERX_DEVICE_TRB_CONTROL] + shape->blocks[ERX_DEVICE_TRB_INTERRUPT])
		return (ERX_DEVICE_TRB_INTERRUPT);
	return (ERX_DEVICE_TRB_BULK);
}

static uint32_t
block_count(const erx_device_trb_shape_t *shape)
{
	return (shape->blocks[ERX_DEVICE_TRB_CONTROL] + shape->blocks[ERX_DEVICE_TRB_INTERRUPT] +
	    shape->blocks[ERX_DEVICE_TRB_BULK]);
}

bool
erx_device_trb_layout(erx_device_trb_layout_t *layout, const erx_device_trb_shape_t *shape,
    const erx_device_trb_controller_t *controller, uint64_t device_base, uint32_t granule, uint64_t memory_size)
{
	const uint64_t slack = 2u * ERX_XHCI_SEGMENT_BOUNDARY;
	placer_t placer = { .layout = layout, .limit = memory_size, .fits = true };
	uint32_t blocks, scratchpads;

	if (!shape_valid(shape) || !controller_valid(controller) || !power_of_two(granule) || granule < TRB_SIZE ||
	    granule > ERX_DEVICE_GRANULE_MAX || device_base % granule != 0 || memory_size > UINT64_MAX - slack ||
	    device_base > UINT64_MAX - slack - memory_size)
		return (false);
	bzero(layout, sizeof(*layout));
	layout->shape = *shape;
	layout->device_base = device_base;
	layout->granule = granule;
	layout->context_size = controller->context_size;
	layout->slots = controller->slots;
	layout->ports = controller->ports;
	layout->scratchpads = scratchpads = controller->scratchpads;
	layout->doorbells = controller->doorbells;
	blocks = block_count(shape);

	/* Largest alignments first, so that little is lost to them. */
	layout->scratchpad = NO_REGION;
	if (scratchpads != 0)
		layout->scratchpad = place(&placer, ERX_DEVICE_TRB_SCRATCHPAD, 0,
		    (uint64_t)scratchpads * ERX_XHCI_PAGE_SIZE + (uint64_t)scratchpads * sizeof(uint64_t),
		    ERX_XHCI_PAGE_SIZE, 0);
	for (uint32_t kind = ERX_DEVICE_TRB_KINDS; kind-- > 0;) {
		for (uint32_t block = 0; block < blocks; block++) {
			if (erx_device_trb_block_kind(shape, block) != kind)
				continue;
			for (uint32_t buffer = 0; buffer < shape->buffers[kind]; buffer++)
				layout->buffer[block][buffer] = place(&placer, ERX_DEVICE_TRB_BUFFER,
				    block * ERX_DEVICE_TRB_BUFFERS_MAX + buffer, shape->buffer_size[kind],
				    shape->buffer_size[kind], 0);
		}
	}
	layout->event_ring = place(&placer, ERX_DEVICE_TRB_EVENT_RING, 0, ring_bytes(ERX_DEVICE_TRB_EVENT_TRBS),
	    ERX_XHCI_EVENT_RING_ALIGN, ERX_XHCI_SEGMENT_BOUNDARY);
	for (uint32_t slot = 1; slot <= layout->slots; slot++)
		layout->device_context[slot] = place(&placer, ERX_DEVICE_TRB_DEVICE_CONTEXT, slot,
		    (uint64_t)ERX_XHCI_DEVICE_CONTEXTS * layout->context_size, ERX_XHCI_DEVICE_CONTEXT_ALIGN,
		    ERX_XHCI_PAGE_SIZE);
	layout->input_context = place(&placer, ERX_DEVICE_TRB_INPUT_CONTEXT, 0,
	    (uint64_t)INPUT_CONTEXTS * layout->context_size, ERX_XHCI_INPUT_CONTEXT_ALIGN, ERX_XHCI_PAGE_SIZE);
	for (uint32_t block = 0; block < blocks; block++)
		layout->block_ring[block] = place(&placer, ERX_DEVICE_TRB_BLOCK_RING, block, ring_bytes(shape->ring_trbs),
		    ERX_XHCI_TRANSFER_RING_ALIGN, ERX_XHCI_SEGMENT_BOUNDARY);
	layout->command_ring = place(&placer, ERX_DEVICE_TRB_COMMAND_RING, 0, ring_bytes(shape->ring_trbs),
	    ERX_XHCI_COMMAND_RING_ALIGN, ERX_XHCI_SEGMENT_BOUNDARY);
	layout->dcbaa = place(&placer, ERX_DEVICE_TRB_DCBAA, 0, (uint64_t)(layout->slots + 1u) * sizeof(uint64_t),
	    ERX_XHCI_DCBAA_ALIGN, ERX_XHCI_PAGE_SIZE);
	layout->segment_table = place(&placer, ERX_DEVICE_TRB_SEGMENT_TABLE, 0, ERX_XHCI_SEGMENT_TABLE_ENTRY_SIZE,
	    ERX_XHCI_SEGMENT_TABLE_ALIGN, ERX_XHCI_PAGE_SIZE);
	layout->bytes = placer.cursor;
	return (placer.fits);
}

static uint64_t
region_offset(const erx_device_trb_layout_t *layout, uint16_t region)
{
	return (layout->regions[region].offset);
}

static uint64_t
device_address(const erx_device_trb_layout_t *layout, uint64_t offset)
{
	return (layout->device_base + offset);
}

uint64_t
erx_device_trb_position_offset(const erx_device_trb_layout_t *layout, uint32_t block, uint32_t position)
{
	const uint16_t ring = block == COMMAND_RING ? layout->command_ring : layout->block_ring[block];

	return (region_offset(layout, ring) + (uint64_t)position * TRB_SIZE);
}

/* The bookkeeping. */

void
erx_device_trb_init(erx_device_trb_t *trb)
{
	bzero(trb, sizeof(*trb));
	trb->command_ring.cycle = 1;
	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++)
		trb->blocks[block].ring.cycle = 1;
}

static erx_dma_writer_t
writer_of(const erx_device_trb_t *trb, const erx_device_trb_region_t *region)
{
	const erx_device_trb_block_t *block;

	switch (region->kind) {
	case ERX_DEVICE_TRB_SCRATCHPAD:
	case ERX_DEVICE_TRB_EVENT_RING:
		return (trb->installed ? ERX_DMA_DEVICE : ERX_DMA_CPU);
	case ERX_DEVICE_TRB_DEVICE_CONTEXT:
		return (trb->slots[region->index].context_given ? ERX_DMA_DEVICE : ERX_DMA_CPU);
	case ERX_DEVICE_TRB_BUFFER:
		block = &trb->blocks[region->index / ERX_DEVICE_TRB_BUFFERS_MAX];
		return ((block->busy >> (region->index % ERX_DEVICE_TRB_BUFFERS_MAX) & 1u) != 0 ? ERX_DMA_DEVICE :
		    ERX_DMA_CPU);
	case ERX_DEVICE_TRB_INPUT_CONTEXT:
	case ERX_DEVICE_TRB_BLOCK_RING:
	case ERX_DEVICE_TRB_COMMAND_RING:
	case ERX_DEVICE_TRB_DCBAA:
	case ERX_DEVICE_TRB_SEGMENT_TABLE:
		break;
	}
	return (ERX_DMA_CPU);
}

void
erx_device_trb_view(const erx_device_trb_t *trb, const erx_device_trb_layout_t *layout, erx_dma_state_t *state)
{
	state->count = layout->region_count;
	for (uint32_t index = 0; index < layout->region_count; index++) {
		const erx_device_trb_region_t *const region = &layout->regions[index];

		state->regions[index] = (erx_dma_region_t){ .offset = region->offset, .length = region->length,
		    .kind = region->kind == ERX_DEVICE_TRB_BUFFER ? ERX_DMA_BUFFER : ERX_DMA_RING,
		    .writer = writer_of(trb, region) };
	}
}

/* A link TRB's control word: toggle-cycle always, the chain bit never, since no TD of the form spans two TRBs. */
static uint32_t
link_control(uint32_t cycle)
{
	uint32_t control = 0;

	(void)erx_xhci_trb_link_control_type_set(&control, ERX_XHCI_TRB_TYPE_LINK);
	(void)erx_xhci_trb_link_control_toggle_cycle_set(&control, 1);
	(void)erx_xhci_trb_link_control_cycle_set(&control, cycle);
	return (control);
}

uint32_t
erx_device_trb_link_steps(const erx_device_trb_layout_t *layout, erx_dma_step_t *steps)
{
	const uint32_t blocks = block_count(&layout->shape), link = layout->shape.ring_trbs - 1u;
	plan_t plan = { .steps = steps };

	for (uint32_t block = 0; block <= blocks; block++) {
		const uint32_t ring = block == blocks ? COMMAND_RING : block;
		const uint64_t at = erx_device_trb_position_offset(layout, ring, link);
		const uint64_t base = erx_device_trb_position_offset(layout, ring, 0);

		add_address(&plan, at + TRB_PARAMETER, device_address(layout, base),
		    (uint64_t)layout->shape.ring_trbs * TRB_SIZE);
		add_value(&plan, at + TRB_CONTROL, 4u, link_control(0));
	}
	return (plan.count);
}

/*
 * Where the next `count` TRBs of a post go on `ring`, and the cycle each takes there. A TRB that
 * lands just before the link hands the link over with the cycle of the lap it ends, and the
 * next TRB goes to the first position with the cycle toggled, so the enqueue position never
 * rests on the link. The link's control word is written into the plan; its address is the install's.
 */
typedef struct placement {
	uint8_t	position[ERX_DEVICE_TRB_TRANSFER_TRBS];
	uint8_t	cycle[ERX_DEVICE_TRB_TRANSFER_TRBS];
} placement_t;

static placement_t
take_positions(plan_t *plan, const erx_device_trb_layout_t *layout, uint32_t ring_block, erx_device_trb_ring_t *ring,
    uint32_t count)
{
	const uint32_t link = layout->shape.ring_trbs - 1u;
	placement_t placement = { { 0 }, { 0 } };

	for (uint32_t index = 0; index < count; index++) {
		placement.position[index] = ring->enqueue;
		placement.cycle[index] = ring->cycle;
#ifdef ERX_DEVICE_TRB_SEED_LINK_REST
		if (ring->enqueue + 1u == link && index + 1u == count) {
			ring->enqueue++;
			continue;
		}
#endif
		if (ring->enqueue + 1u != link) {
			ring->enqueue++;
			continue;
		}
		add_value(plan, erx_device_trb_position_offset(layout, ring_block, link) + TRB_CONTROL, 4u,
		    link_control(ring->cycle));
		ring->enqueue = 0;
		ring->cycle ^= 1u;
	}
	return (placement);
}

/*
 * One TRB: its parameter, a plain value or a device address, its status and its control word. The
 * control word of a post's first TRB goes in with the controller's old cycle; its publication
 * follows the cleans.
 */
typedef struct trb_words {
	bool		address;
	uint64_t	parameter;
	uint64_t	extent;
	uint32_t	status;
	uint32_t	control;
} trb_words_t;

static void
add_trb(plan_t *plan, uint64_t at, const trb_words_t *words)
{
	if (words->address)
		add_address(plan, at + TRB_PARAMETER, words->parameter, words->extent);
	else
		add_value(plan, at + TRB_PARAMETER, 8u, words->parameter);
	add_value(plan, at + TRB_STATUS, 4u, words->status);
	add_value(plan, at + TRB_CONTROL, 4u, words->control);
}

/* The TRB's control word with its cycle bit, which sits at bit 0 in every format. */
static uint32_t
with_cycle(uint32_t control, uint32_t cycle)
{
	(void)erx_xhci_trb_normal_control_cycle_set(&control, cycle);
	return (control);
}

/*
 * The TRBs of a placement, the first with the old cycle, then the publication of its control
 * word with the new cycle and the doorbell.
 */
static void
add_trbs(plan_t *plan, const erx_device_trb_layout_t *layout, uint32_t ring_block, const placement_t *placement,
    const trb_words_t *words, uint32_t count, uint32_t doorbell, uint32_t target)
{
	uint64_t first = 0;

	for (uint32_t index = 0; index < count; index++) {
		const uint64_t at = erx_device_trb_position_offset(layout, ring_block, placement->position[index]);
		trb_words_t trb = words[index];

		trb.control = with_cycle(trb.control, placement->cycle[index]);
		if (index == 0) {
			first = at;
#ifndef ERX_DEVICE_TRB_SEED_CYCLE_WITH_WRITES
			trb.control = with_cycle(trb.control, placement->cycle[0] ^ 1u);
#endif
		}
		add_trb(plan, at, &trb);
	}
	add_publications(plan, layout, first + TRB_CONTROL, with_cycle(words[0].control, placement->cycle[0]), doorbell,
	    target);
}

/* Queues. */

static bool
is_queue(const erx_device_trb_block_t *block)
{
	return (block->state >= ERX_DEVICE_TRB_OPEN);
}

static uint32_t
find_queue(const erx_device_trb_t *trb, uint32_t slot, uint32_t dci)
{
	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++)
		if (is_queue(&trb->blocks[block]) && trb->blocks[block].slot == slot && trb->blocks[block].dci == dci)
			return (block);
	return (ERX_DEVICE_TRB_BLOCKS_MAX);
}

const erx_device_trb_block_t *
erx_device_trb_queue(const erx_device_trb_t *trb, uint32_t slot, uint32_t dci)
{
	const uint32_t block = find_queue(trb, slot, dci);

	return (block == ERX_DEVICE_TRB_BLOCKS_MAX ? NULL : &trb->blocks[block]);
}

/* An odd device context index above EP0's 1 is an IN endpoint's: the endpoint number times two plus the direction (4.5.1, p. 96). */
static bool
dci_in(uint32_t dci)
{
	return (dci > 1u && dci % 2u == 1u);
}

static uint16_t
setup_length(const uint8_t setup[8])
{
	return ((uint16_t)(setup[6] | setup[7] << 8));
}

/* Whether a setup's data stage, if any, runs from the device to the host: bmRequestType's bit 7 (usb.h). */
static bool
setup_in(const uint8_t setup[8])
{
	return ((setup[0] & ERX_USB_REQUEST_DIR_IN) != 0);
}

/* A standard request to the device, of any direction, whose request is SET_ADDRESS (usb.h's values). */
static bool
setup_sets_address(const uint8_t setup[8])
{
	return ((setup[0] & (ERX_USB_REQUEST_TYPE_MASK | ERX_USB_REQUEST_RECIPIENT_MASK)) ==
	    (ERX_USB_REQUEST_TYPE_STANDARD | ERX_USB_RECIPIENT_DEVICE) && setup[1] == ERX_USB_REQUEST_SET_ADDRESS);
}

/* The one test of a transfer, the post's and the TRB form core's (erx_device_trb.h). */
bool
erx_device_trb_request_valid(const erx_device_trb_request_t *request, erx_device_trb_kind_t kind,
    uint32_t dci, uint32_t buffer_size)
{
	if (request->control != (kind == ERX_DEVICE_TRB_CONTROL) || request->length > buffer_size ||
	    (request->length != 0 && !request->device_writes && request->bytes == NULL))
		return (false);
	if (!request->control)
		return (request->device_writes == dci_in(dci));
	return (!setup_sets_address(request->setup) && setup_length(request->setup) == request->length &&
	    (request->data ? request->length != 0 && request->device_writes == setup_in(request->setup) :
	    request->length == 0));
}

static uint32_t
free_buffer(const erx_device_trb_block_t *block, uint32_t buffers)
{
	for (uint32_t buffer = 0; buffer < buffers; buffer++)
		if ((block->busy >> buffer & 1u) == 0)
			return (buffer);
	return (buffers);
}

/* The TRB words of a transfer over the buffer at `buffer_address`. */
static uint32_t
transfer_words(const erx_device_trb_request_t *request, uint64_t buffer_address, uint32_t buffer_size,
    trb_words_t words[ERX_DEVICE_TRB_TRANSFER_TRBS])
{
	uint32_t count = 0;

	bzero(words, ERX_DEVICE_TRB_TRANSFER_TRBS * sizeof(words[0]));
	if (!request->control) {
		words[0] = (trb_words_t){ .address = true, .parameter = buffer_address, .extent = buffer_size };
		(void)erx_xhci_trb_normal_status_length_set(&words[0].status, request->length);
		(void)erx_xhci_trb_normal_control_type_set(&words[0].control, ERX_XHCI_TRB_TYPE_NORMAL);
		(void)erx_xhci_trb_normal_control_interrupt_on_short_set(&words[0].control, 1);
		(void)erx_xhci_trb_normal_control_interrupt_on_completion_set(&words[0].control, 1);
		return (1);
	}
	for (uint32_t index = 0; index < 8; index++)
		words[0].parameter |= (uint64_t)request->setup[index] << (8u * index);
	(void)erx_xhci_trb_setup_status_length_set(&words[0].status, (uint32_t)sizeof(request->setup));
	(void)erx_xhci_trb_setup_control_type_set(&words[0].control, ERX_XHCI_TRB_TYPE_SETUP_STAGE);
	(void)erx_xhci_trb_setup_control_immediate_data_set(&words[0].control, 1);
	(void)erx_xhci_trb_setup_control_transfer_type_set(&words[0].control, !request->data ? ERX_XHCI_TRANSFER_TYPE_NONE :
	    request->device_writes ? ERX_XHCI_TRANSFER_TYPE_IN : ERX_XHCI_TRANSFER_TYPE_OUT);
	count = 1;
	if (request->data) {
		words[1] = (trb_words_t){ .address = true, .parameter = buffer_address, .extent = buffer_size };
		(void)erx_xhci_trb_data_status_length_set(&words[1].status, request->length);
		(void)erx_xhci_trb_data_control_type_set(&words[1].control, ERX_XHCI_TRB_TYPE_DATA_STAGE);
		(void)erx_xhci_trb_data_control_interrupt_on_short_set(&words[1].control, 1);
		(void)erx_xhci_trb_data_control_direction_in_set(&words[1].control, request->device_writes);
		count = 2;
	}
	/* The status stage runs in the other direction from the data, and IN with none (4.11.2.2). */
	(void)erx_xhci_trb_status_control_type_set(&words[count].control, ERX_XHCI_TRB_TYPE_STATUS_STAGE);
	(void)erx_xhci_trb_status_control_direction_in_set(&words[count].control,
	    !request->data || !request->device_writes);
	(void)erx_xhci_trb_status_control_interrupt_on_completion_set(&words[count].control, 1);
	return (count + 1);
}

erx_device_trb_verdict_t
erx_device_trb_post(erx_device_trb_t *trb, const erx_device_trb_layout_t *layout, uint32_t slot, uint32_t dci,
    const erx_device_trb_request_t *request, uint64_t tag, erx_dma_step_t *steps, uint32_t *count)
{
	const uint32_t index = find_queue(trb, slot, dci);
	plan_t plan = { .steps = steps };
	trb_words_t words[ERX_DEVICE_TRB_TRANSFER_TRBS];
	erx_device_trb_block_t *block;
	erx_device_trb_kind_t kind;
	uint32_t buffer, trbs;
	uint64_t buffer_offset;
	placement_t placement;

	if (index == ERX_DEVICE_TRB_BLOCKS_MAX)
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	block = &trb->blocks[index];
	kind = erx_device_trb_block_kind(&layout->shape, index);
	if (!erx_device_trb_request_valid(request, kind, dci, layout->shape.buffer_size[kind]))
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	if (block->state != ERX_DEVICE_TRB_OPEN || (trb->command.kind != ERX_DEVICE_TRB_NO_COMMAND &&
	    trb->command.slot == slot && (trb->command.held >> dci & 1u) != 0))
		return (ERX_DEVICE_TRB_REFUSE_HALTED);
	buffer = free_buffer(block, layout->shape.buffers[kind]);
	if (buffer == layout->shape.buffers[kind])
		return (ERX_DEVICE_TRB_REFUSE_FULL);

	buffer_offset = region_offset(layout, layout->buffer[index][buffer]);
	trbs = transfer_words(request, device_address(layout, buffer_offset), layout->shape.buffer_size[kind], words);
	placement = take_positions(&plan, layout, index, &block->ring, trbs);
	if (!request->device_writes && request->length != 0)
		add_bytes(&plan, buffer_offset, request->bytes, request->length);
	add_trbs(&plan, layout, index, &placement, words, trbs, slot, dci);

	block->transfers[(block->head + block->posted) % ERX_DEVICE_TRB_BUFFERS_MAX] = (erx_device_trb_transfer_t){
	    .tag = tag, .length = request->length, .buffer = (uint8_t)buffer, .first = placement.position[0],
	    .data = request->control && request->data ? placement.position[1] : ERX_DEVICE_TRB_NO_POSITION,
	    .last = placement.position[trbs - 1u] };
	block->posted++;
	block->busy |= (uint8_t)(1u << buffer);
	*count = plan.count;
	return (ERX_DEVICE_TRB_ACCEPTED);
}

bool
erx_device_trb_retire(erx_device_trb_t *trb, uint32_t slot, uint32_t dci, erx_device_trb_transfer_t *done)
{
	const uint32_t index = find_queue(trb, slot, dci);
	erx_device_trb_block_t *block;

	if (index == ERX_DEVICE_TRB_BLOCKS_MAX || trb->blocks[index].posted == 0)
		return (false);
	block = &trb->blocks[index];
	*done = block->transfers[block->head];
	bzero(&block->transfers[block->head], sizeof(block->transfers[0]));
	block->head = (uint8_t)((block->head + 1u) % ERX_DEVICE_TRB_BUFFERS_MAX);
	block->posted--;
	if (block->posted == 0)
		block->head = 0;
	block->busy &= (uint8_t)~(1u << done->buffer);
	block->span_start = done->last;
	return (true);
}

bool
erx_device_trb_halt(erx_device_trb_t *trb, uint32_t slot, uint32_t dci)
{
	const uint32_t index = find_queue(trb, slot, dci);

	if (index == ERX_DEVICE_TRB_BLOCKS_MAX)
		return (false);
	trb->blocks[index].state = ERX_DEVICE_TRB_HALTED;
	return (true);
}

bool
erx_device_trb_in_stop_span(const erx_device_trb_layout_t *layout, const erx_device_trb_block_t *block,
    uint32_t position)
{
	const uint32_t trbs = layout->shape.ring_trbs;
	uint32_t start = block->span_start;

#ifdef ERX_DEVICE_TRB_SEED_NARROW_SPAN
	start = block->posted != 0 ? block->transfers[block->head].first : block->ring.enqueue;
#endif
	return (position < trbs && (position + trbs - start) % trbs <= (block->ring.enqueue + trbs - start) % trbs);
}

/* Every transfer posted on a ring answered `stopped`: its buffers return and the stop span starts at the enqueue position. */
static void
answer_stopped(erx_device_trb_block_t *block, uint32_t index, erx_device_trb_stopped_t *stopped, uint32_t *count)
{
	for (uint32_t taken = 0; taken < block->posted; taken++) {
		const erx_device_trb_transfer_t *const transfer =
		    &block->transfers[(block->head + taken) % ERX_DEVICE_TRB_BUFFERS_MAX];

		stopped[(*count)++] = (erx_device_trb_stopped_t){ .tag = transfer->tag, .block = (uint8_t)index,
		    .buffer = transfer->buffer };
	}
	bzero(block->transfers, sizeof(block->transfers));
	block->head = 0;
	block->posted = 0;
	block->busy = 0;
	block->span_start = block->ring.enqueue;
}

/* A block returned: free, its ring kept where it is. */
static void
release(erx_device_trb_block_t *block)
{
	const erx_device_trb_ring_t ring = block->ring;

	bzero(block, sizeof(*block));
	block->ring = ring;
	block->span_start = ring.enqueue;
}

/* Commands. */

/* A route string names a port of 1 to 15 at each tier below the root, then nothing (abi/formats/xhci.txt). */
static bool
route_valid(uint64_t route)
{
	bool ended = false;

	if (route >> (ROUTE_TIERS * ERX_XHCI_ROUTE_TIER_BITS) != 0)
		return (false);
	for (uint32_t tier = 0; tier < ROUTE_TIERS; tier++) {
		const uint64_t port = route >> (tier * ERX_XHCI_ROUTE_TIER_BITS) & ROUTE_TIER_MASK;

		if (ended && port != 0)
			return (false);
		ended = port == 0;
	}
	return (true);
}

bool
erx_device_trb_address_slot_valid(const erx_xhci_slot_context_free_t *slot, uint32_t ports, uint32_t slots)
{
	const bool tt = slot->tt_tt_slot != 0 || slot->tt_tt_port != 0;

	return (route_valid(slot->route_route_string) && slot->route_speed >= ERX_XHCI_SPEED_FULL &&
	    slot->route_speed <= ERX_XHCI_SPEED_SUPER && slot->ports_root_port >= 1 && slot->ports_root_port <= ports &&
	    (!tt || (slot->tt_tt_slot >= 1 && slot->tt_tt_slot <= slots && slot->tt_tt_port >= 1 &&
	    slot->tt_tt_port <= ERX_USB_HUB_PORTS_MAX)) && slot->route_multi_tt <= (tt ? 1u : 0u) &&
	    slot->route_hub == 0 && slot->ports_port_count == 0 && slot->tt_tt_think_time == 0);
}

bool
erx_device_trb_configure_slot_valid(const erx_xhci_slot_context_free_t *slot)
{
	const bool hub_fields = slot->route_hub == 1 && slot->ports_port_count >= 1 &&
	    slot->ports_port_count <= ERX_USB_HUB_PORTS_MAX && slot->tt_tt_think_time <= 3 && slot->route_multi_tt <= 1;
	const bool function = slot->route_hub == 0 && slot->ports_port_count == 0 && slot->tt_tt_think_time == 0 &&
	    slot->route_multi_tt == 0;

	return ((hub_fields || function) && slot->route_route_string == 0 && slot->route_speed == 0 &&
	    slot->ports_root_port == 0 && slot->tt_tt_slot == 0 && slot->tt_tt_port == 0);
}

bool
erx_device_trb_ep0_valid(const erx_xhci_endpoint_context_free_t *context, bool exact)
{
	const uint64_t packet = context->config_max_packet;

	return (context->config_endpoint_type == ERX_XHCI_ENDPOINT_TYPE_CONTROL && context->config_max_burst == 0 &&
	    context->info_interval == 0 && context->payload_max_esit_payload == 0 &&
	    (exact ? packet == 8u || packet == 64u || packet == 512u : packet >= 8u && packet <= 512u));
}

/* The xHCI endpoint type of a kind and direction (abi/formats/xhci.txt). */
static uint32_t
endpoint_type(erx_device_trb_kind_t kind, bool in)
{
	switch (kind) {
	case ERX_DEVICE_TRB_CONTROL:
		return (ERX_XHCI_ENDPOINT_TYPE_CONTROL);
	case ERX_DEVICE_TRB_INTERRUPT:
		return (in ? ERX_XHCI_ENDPOINT_TYPE_INTERRUPT_IN : ERX_XHCI_ENDPOINT_TYPE_INTERRUPT_OUT);
	case ERX_DEVICE_TRB_BULK:
	case ERX_DEVICE_TRB_KINDS:
		break;
	}
	return (in ? ERX_XHCI_ENDPOINT_TYPE_BULK_IN : ERX_XHCI_ENDPOINT_TYPE_BULK_OUT);
}

bool
erx_device_trb_endpoint_valid(const erx_device_trb_context_endpoint_t *endpoint, erx_device_trb_kind_t kind,
    uint32_t buffer_size, uint32_t speed)
{
	const erx_xhci_endpoint_context_free_t *const context = &endpoint->context;
	/* An odd index is IN's, or a control endpoint's, which takes the IN index as EP0 does (4.5.1, p. 96). */
	const bool in = (endpoint->dci & 1u) != 0;
	const uint64_t most = context->config_max_packet * (context->config_max_burst + 1u);

	if (endpoint->dci < 2 || endpoint->dci > ERX_DEVICE_TRB_DCI_MAX || kind >= ERX_DEVICE_TRB_KINDS ||
	    (kind == ERX_DEVICE_TRB_CONTROL && !in) || context->config_endpoint_type != endpoint_type(kind, in) ||
	    context->config_max_packet < 1 || context->config_max_packet > 1024 || context->config_max_burst > BURST_MAX ||
	    context->info_interval > (kind == ERX_DEVICE_TRB_INTERRUPT ? 15u : 0u))
		return (false);
	if (kind == ERX_DEVICE_TRB_INTERRUPT && speed == ERX_XHCI_SPEED_SUPER)
		return (context->payload_max_esit_payload >= 1 && context->payload_max_esit_payload <= most &&
		    context->payload_max_esit_payload <= buffer_size);
	return (context->payload_max_esit_payload == most && most <= buffer_size);
}

/* An Address Device's slot context, as erx_device_trb_address_slot_valid judges it. */
static erx_xhci_slot_context_free_t
address_slot(const erx_device_trb_command_t *command)
{
	return ((erx_xhci_slot_context_free_t){ .route_route_string = command->route, .route_speed = command->speed,
	    .route_multi_tt = command->tt && command->tt_multi, .ports_root_port = command->root_port,
	    .tt_tt_slot = command->tt ? command->tt_slot : 0u, .tt_tt_port = command->tt ? command->tt_port : 0u });
}

/* EP0's context of packet `packet`. */
static erx_device_trb_context_endpoint_t
ep0_context(uint32_t packet)
{
	return ((erx_device_trb_context_endpoint_t){ .dci = 1,
	    .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL, .config_max_packet = packet } });
}

static bool
address_valid(const erx_device_trb_layout_t *layout, const erx_device_trb_command_t *command)
{
	const erx_xhci_slot_context_free_t slot = address_slot(command);
	const erx_device_trb_context_endpoint_t ep0 = ep0_context(command->ep0_packet);

	return (erx_device_trb_address_slot_valid(&slot, layout->ports, layout->slots) &&
	    erx_device_trb_ep0_valid(&ep0.context, true));
}

/* A queue a Configure Endpoint may drop, or drop and add again: open with nothing posted, or stopped. */
static bool
droppable(const erx_device_trb_block_t *block)
{
	return ((block->state == ERX_DEVICE_TRB_OPEN && block->posted == 0) || block->state == ERX_DEVICE_TRB_STOPPED);
}

/* The endpoint number times two plus the direction, a control endpoint's that of IN as EP0's (4.5.1, p. 96). */
static uint32_t
endpoint_dci(const erx_device_trb_endpoint_t *endpoint)
{
	return (2u * endpoint->number + (endpoint->in || endpoint->kind == ERX_DEVICE_TRB_CONTROL ? 1u : 0u));
}

/* An added endpoint's context: its index from its number and direction, its type from its kind. */
static erx_device_trb_context_endpoint_t
endpoint_context(const erx_device_trb_endpoint_t *endpoint)
{
	return ((erx_device_trb_context_endpoint_t){ .dci = endpoint_dci(endpoint), .context = {
	    .info_interval = endpoint->interval, .config_endpoint_type = endpoint_type(endpoint->kind, endpoint->in),
	    .config_max_burst = endpoint->burst, .config_max_packet = endpoint->packet,
	    .payload_max_esit_payload = endpoint->payload } });
}

/* An added endpoint: a number of 1 to 15, a kind, a control endpoint naming no direction, and its context. */
static bool
endpoint_valid(const erx_device_trb_layout_t *layout, const erx_device_trb_endpoint_t *endpoint, uint32_t speed)
{
	const erx_device_trb_context_endpoint_t context = endpoint_context(endpoint);

	return (endpoint->number >= 1 && endpoint->number <= 15 && endpoint->kind < ERX_DEVICE_TRB_KINDS &&
	    !(endpoint->kind == ERX_DEVICE_TRB_CONTROL && endpoint->in) &&
	    erx_device_trb_endpoint_valid(&context, endpoint->kind, layout->shape.buffer_size[endpoint->kind], speed));
}

/* A free block of `kind` not yet in `reserved`, or ERX_DEVICE_TRB_BLOCKS_MAX. */
static uint32_t
free_block(const erx_device_trb_t *trb, const erx_device_trb_shape_t *shape, erx_device_trb_kind_t kind,
    uint64_t reserved)
{
	for (uint32_t block = 0; block < block_count(shape); block++)
		if (erx_device_trb_block_kind(shape, block) == kind && trb->blocks[block].state == ERX_DEVICE_TRB_FREE &&
		    (reserved >> block & 1u) == 0)
			return (block);
	return (ERX_DEVICE_TRB_BLOCKS_MAX);
}

/* The accepted command's bookkeeping, built before anything changes so that a refusal changes nothing. */
typedef struct acceptance {
	uint64_t	reserved;
	uint8_t		dci[ERX_DEVICE_TRB_BLOCKS_MAX];		/* the queue each reserved block will be */
	uint32_t	held;
	uint64_t	dropped;
	uint32_t	entries;				/* the slot context's last valid index */
	uint32_t	queue;					/* the block of the queue the command names */
} acceptance_t;

static erx_device_trb_verdict_t
accept_configure(const erx_device_trb_t *trb, const erx_device_trb_layout_t *layout,
    const erx_device_trb_command_t *command, acceptance_t *accepted)
{
	uint32_t adds = 0, live = 0;

	if (command->add_count > ERX_DEVICE_TRB_DCI_MAX - 1u || (command->drops & 0x3u) != 0 ||
	    (command->hub && (command->hub_ports < 1 || command->hub_ports > ERX_USB_HUB_PORTS_MAX ||
	    command->hub_think_time > 3)))
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	for (uint32_t dci = 2; dci <= ERX_DEVICE_TRB_DCI_MAX; dci++) {
		const uint32_t block = find_queue(trb, command->slot, dci);

		if ((command->drops >> dci & 1u) != 0 &&
		    (block == ERX_DEVICE_TRB_BLOCKS_MAX || !droppable(&trb->blocks[block])))
			return (ERX_DEVICE_TRB_REFUSE_BADARG);
		if ((command->drops >> dci & 1u) != 0)
			accepted->dropped |= UINT64_C(1) << block;
		else if (block != ERX_DEVICE_TRB_BLOCKS_MAX)
			live |= 1u << dci;
	}
	for (uint32_t index = 0; index < command->add_count; index++) {
		const erx_device_trb_endpoint_t *const endpoint = &command->add[index];
		uint32_t dci, block;

		if (!endpoint_valid(layout, endpoint, trb->slots[command->slot].speed))
			return (ERX_DEVICE_TRB_REFUSE_BADARG);
		dci = endpoint_dci(endpoint);
		if (((adds | live) >> dci & 1u) != 0)
			return (ERX_DEVICE_TRB_REFUSE_BADARG);
		adds |= 1u << dci;
		block = free_block(trb, &layout->shape, endpoint->kind, accepted->reserved);
		if (block == ERX_DEVICE_TRB_BLOCKS_MAX)
			return (ERX_DEVICE_TRB_REFUSE_FULL);
		accepted->reserved |= UINT64_C(1) << block;
		accepted->dci[block] = (uint8_t)dci;
	}
	accepted->held = command->drops;
	live |= adds | 1u << 1;
	accepted->entries = 31u - (uint32_t)__builtin_clz(live);
	return (ERX_DEVICE_TRB_ACCEPTED);
}

/* Disable Slot: every queue of the slot stopped, halted or open with nothing posted (4.6.4, pp. 109-110). */
static bool
slot_quiet(const erx_device_trb_t *trb, uint32_t slot)
{
	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++) {
		const erx_device_trb_block_t *const queue = &trb->blocks[block];

		if (!is_queue(queue) || queue->slot != slot)
			continue;
#ifdef ERX_DEVICE_TRB_SEED_DISABLE_RUNNING
		if (queue->state == ERX_DEVICE_TRB_OPEN)
			continue;
#endif
		if (queue->state == ERX_DEVICE_TRB_STOPPING || (queue->state == ERX_DEVICE_TRB_OPEN && queue->posted != 0))
			return (false);
	}
	return (true);
}

static bool
has_queue_or_reservation(const erx_device_trb_t *trb, uint32_t slot, uint32_t dci)
{
	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++)
		if (trb->blocks[block].state != ERX_DEVICE_TRB_FREE && trb->blocks[block].slot == slot &&
		    trb->blocks[block].dci == dci)
			return (true);
	return (false);
}

/* Whether the command's slot and queue are in a state its row of the design's table accepts, with what it reserves. */
static erx_device_trb_verdict_t
accept(const erx_device_trb_t *trb, const erx_device_trb_layout_t *layout, const erx_device_trb_command_t *command,
    acceptance_t *accepted)
{
	const bool enabled = command->slot >= 1 && command->slot <= layout->slots && trb->slots[command->slot].enabled;
	const uint32_t queue = enabled ? find_queue(trb, command->slot, command->dci) : ERX_DEVICE_TRB_BLOCKS_MAX;
	const erx_device_trb_block_t *const block = queue == ERX_DEVICE_TRB_BLOCKS_MAX ? NULL : &trb->blocks[queue];
	erx_device_trb_context_endpoint_t packet;
	uint32_t ep0;

	accepted->queue = queue;
	switch (command->kind) {
	case ERX_DEVICE_TRB_ENABLE_SLOT:
		return (ERX_DEVICE_TRB_ACCEPTED);
	case ERX_DEVICE_TRB_ADDRESS_DEVICE:
		if (!enabled || has_queue_or_reservation(trb, command->slot, 1) || !address_valid(layout, command))
			return (ERX_DEVICE_TRB_REFUSE_BADARG);
		ep0 = free_block(trb, &layout->shape, ERX_DEVICE_TRB_CONTROL, 0);
		if (ep0 == ERX_DEVICE_TRB_BLOCKS_MAX)
			return (ERX_DEVICE_TRB_REFUSE_FULL);
		accepted->reserved = UINT64_C(1) << ep0;
		accepted->dci[ep0] = 1;
		return (ERX_DEVICE_TRB_ACCEPTED);
	case ERX_DEVICE_TRB_EVALUATE_CONTEXT:
		packet = ep0_context(command->ep0_packet);
		accepted->held = 1u << 1;
		ep0 = enabled ? find_queue(trb, command->slot, 1) : ERX_DEVICE_TRB_BLOCKS_MAX;
		return (ep0 != ERX_DEVICE_TRB_BLOCKS_MAX && trb->blocks[ep0].posted == 0 &&
		    erx_device_trb_ep0_valid(&packet.context, false) ? ERX_DEVICE_TRB_ACCEPTED :
		    ERX_DEVICE_TRB_REFUSE_BADARG);
	case ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS:
		return (enabled && find_queue(trb, command->slot, 1) != ERX_DEVICE_TRB_BLOCKS_MAX ?
		    accept_configure(trb, layout, command, accepted) : ERX_DEVICE_TRB_REFUSE_BADARG);
	case ERX_DEVICE_TRB_STOP_ENDPOINT:
		return (block != NULL && block->state == ERX_DEVICE_TRB_OPEN ? ERX_DEVICE_TRB_ACCEPTED :
		    ERX_DEVICE_TRB_REFUSE_BADARG);
	case ERX_DEVICE_TRB_RESET_ENDPOINT:
		return (block != NULL && block->state == ERX_DEVICE_TRB_HALTED ? ERX_DEVICE_TRB_ACCEPTED :
		    ERX_DEVICE_TRB_REFUSE_BADARG);
	case ERX_DEVICE_TRB_SET_TR_DEQUEUE:
		return (block != NULL && block->state == ERX_DEVICE_TRB_STOPPED ? ERX_DEVICE_TRB_ACCEPTED :
		    ERX_DEVICE_TRB_REFUSE_BADARG);
	case ERX_DEVICE_TRB_DISABLE_SLOT:
		accepted->held = UINT32_MAX;
		return (enabled && slot_quiet(trb, command->slot) ? ERX_DEVICE_TRB_ACCEPTED : ERX_DEVICE_TRB_REFUSE_BADARG);
	}
	return (ERX_DEVICE_TRB_REFUSE_BADARG);
}

/* The device address and cycle state of a ring's enqueue position, as a context or Set TR Dequeue gives it. */
static uint64_t
dequeue_of(const erx_device_trb_layout_t *layout, uint32_t block, const erx_device_trb_ring_t *ring)
{
	uint64_t dequeue = 0;

	(void)erx_xhci_endpoint_context_dequeue_dequeue_pointer_set(&dequeue,
	    device_address(layout, erx_device_trb_position_offset(layout, block, ring->enqueue)));
	(void)erx_xhci_endpoint_context_dequeue_dequeue_cycle_set(&dequeue, ring->cycle);
	return (dequeue);
}

/* The bytes the controller may follow a ring from its enqueue position to its link, which leads back to the base. */
static uint64_t
dequeue_reach(const erx_device_trb_layout_t *layout, const erx_device_trb_ring_t *ring)
{
	return ((uint64_t)(layout->shape.ring_trbs - ring->enqueue) * TRB_SIZE);
}

/*
 * The input context's plan: the region zeroed, then each context the sequencer's one composition
 * (erx_dma_input_context) gives, a step per word that is not 0 and the endpoint contexts' dequeue
 * words as addresses the controller follows to its link, `reach[dci]` bytes.
 */
static void
add_input_context(plan_t *plan, const erx_device_trb_layout_t *layout, const erx_device_trb_contexts_t *contexts,
    const erx_dma_context_derivation_t *derived, const uint64_t reach[ERX_XHCI_DEVICE_CONTEXTS])
{
	const uint64_t at = region_offset(layout, layout->input_context);
	erx_dma_context_part_t parts[ERX_DMA_CONTEXT_PARTS_MAX];
	const uint32_t count = erx_dma_input_context(contexts, derived, parts);

	add_zeros(plan, at, layout->regions[layout->input_context].length);
	for (uint32_t part = 0; part < count; part++) {
		for (uint32_t offset = 0; offset < sizeof(parts[part].bytes); offset += sizeof(uint32_t)) {
			uint32_t word;
			uint64_t dequeue;

			if (parts[part].dci != 0 && offset == ERX_XHCI_ENDPOINT_CONTEXT_OFF_DEQUEUE) {
				bcopy(parts[part].bytes + offset, &dequeue, sizeof(dequeue));
				add_address(plan, at + parts[part].offset + offset, dequeue, reach[parts[part].dci]);
				offset += sizeof(uint32_t);
				continue;
			}
			bcopy(parts[part].bytes + offset, &word, sizeof(word));
			if (word != 0)
				add_value(plan, at + parts[part].offset + offset, sizeof(word), word);
		}
	}
}

/* Address Device's contexts: the slot context with one entry, and EP0's, at its block's ring. */
static void
add_address_contexts(plan_t *plan, const erx_device_trb_layout_t *layout, const erx_device_trb_t *trb,
    const erx_device_trb_command_t *command, uint32_t ep0)
{
	erx_device_trb_contexts_t contexts = { .slot_context = address_slot(command),
	    .endpoint_count = 1 };
	erx_dma_context_derivation_t derived = { .slot = true, .entries = 1, .context_size = layout->context_size };
	uint64_t reach[ERX_XHCI_DEVICE_CONTEXTS] = { 0 };

	contexts.endpoints[0] = ep0_context(command->ep0_packet);
	derived.dequeue[1] = dequeue_of(layout, ep0, &trb->blocks[ep0].ring);
	reach[1] = dequeue_reach(layout, &trb->blocks[ep0].ring);
	add_input_context(plan, layout, &contexts, &derived, reach);
}

/* Evaluate Context's: EP0's context whole, with the new packet, at its bound ring's position. */
static void
add_evaluate_contexts(plan_t *plan, const erx_device_trb_layout_t *layout, const erx_device_trb_t *trb,
    const erx_device_trb_command_t *command, uint32_t ep0)
{
	erx_device_trb_contexts_t contexts = { .endpoint_count = 1 };
	erx_dma_context_derivation_t derived = { .slot = false, .context_size = layout->context_size };
	uint64_t reach[ERX_XHCI_DEVICE_CONTEXTS] = { 0 };

	contexts.endpoints[0] = ep0_context(command->ep0_packet);
	derived.dequeue[1] = dequeue_of(layout, ep0, &trb->blocks[ep0].ring);
	reach[1] = dequeue_reach(layout, &trb->blocks[ep0].ring);
	add_input_context(plan, layout, &contexts, &derived, reach);
}

/* Configure Endpoint's: the slot context's hub fields and last valid index, and each added endpoint's at its block's ring. */
static void
add_configure_contexts(plan_t *plan, const erx_device_trb_layout_t *layout, const erx_device_trb_t *trb,
    const erx_device_trb_command_t *command, const acceptance_t *accepted)
{
	erx_device_trb_contexts_t contexts = { .slot_context = {
	    .route_hub = command->hub, .route_multi_tt = command->hub && command->hub_multi_tt,
	    .ports_port_count = command->hub ? command->hub_ports : 0u,
	    .tt_tt_think_time = command->hub ? command->hub_think_time : 0u } };
	erx_dma_context_derivation_t derived = { .slot = true, .drop = accepted->held, .entries = accepted->entries,
	    .context_size = layout->context_size };
	uint64_t reach[ERX_XHCI_DEVICE_CONTEXTS] = { 0 };

	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++) {
		for (uint32_t index = 0; (accepted->reserved >> block & 1u) != 0 && index < command->add_count; index++) {
			const erx_device_trb_context_endpoint_t endpoint = endpoint_context(&command->add[index]);

			if (endpoint.dci != accepted->dci[block])
				continue;
			contexts.endpoints[contexts.endpoint_count++] = endpoint;
			derived.dequeue[endpoint.dci] = dequeue_of(layout, block, &trb->blocks[block].ring);
			reach[endpoint.dci] = dequeue_reach(layout, &trb->blocks[block].ring);
		}
	}
	add_input_context(plan, layout, &contexts, &derived, reach);
}

/* The command TRB's words: the input context's address for the commands that read it, the slot and the endpoint. */
static trb_words_t
command_words(const erx_device_trb_layout_t *layout, const erx_device_trb_t *trb,
    const erx_device_trb_command_t *command, uint32_t queue)
{
	static const uint8_t types[] = {
		[ERX_DEVICE_TRB_ENABLE_SLOT] = ERX_XHCI_TRB_TYPE_ENABLE_SLOT,
		[ERX_DEVICE_TRB_ADDRESS_DEVICE] = ERX_XHCI_TRB_TYPE_ADDRESS_DEVICE,
		[ERX_DEVICE_TRB_EVALUATE_CONTEXT] = ERX_XHCI_TRB_TYPE_EVALUATE_CONTEXT,
		[ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS] = ERX_XHCI_TRB_TYPE_CONFIGURE_ENDPOINT,
		[ERX_DEVICE_TRB_STOP_ENDPOINT] = ERX_XHCI_TRB_TYPE_STOP_ENDPOINT,
		[ERX_DEVICE_TRB_RESET_ENDPOINT] = ERX_XHCI_TRB_TYPE_RESET_ENDPOINT,
		[ERX_DEVICE_TRB_SET_TR_DEQUEUE] = ERX_XHCI_TRB_TYPE_SET_TR_DEQUEUE,
		[ERX_DEVICE_TRB_DISABLE_SLOT] = ERX_XHCI_TRB_TYPE_DISABLE_SLOT,
	};
	trb_words_t words = { .address = false };

	(void)erx_xhci_trb_command_control_type_set(&words.control, types[command->kind]);
	if (command->kind != ERX_DEVICE_TRB_ENABLE_SLOT)
		(void)erx_xhci_trb_command_control_slot_set(&words.control, command->slot);
	switch (command->kind) {
	case ERX_DEVICE_TRB_ADDRESS_DEVICE:
	case ERX_DEVICE_TRB_EVALUATE_CONTEXT:
	case ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS:
		words.address = true;
		words.parameter = device_address(layout, region_offset(layout, layout->input_context));
		words.extent = (uint64_t)INPUT_CONTEXTS * layout->context_size;
		break;
	case ERX_DEVICE_TRB_SET_TR_DEQUEUE:
		words.address = true;
		words.parameter = dequeue_of(layout, queue, &trb->blocks[queue].ring);
		words.extent = dequeue_reach(layout, &trb->blocks[queue].ring);
		/* FALLTHROUGH */
	case ERX_DEVICE_TRB_STOP_ENDPOINT:
	case ERX_DEVICE_TRB_RESET_ENDPOINT:
		(void)erx_xhci_trb_command_control_endpoint_set(&words.control, command->dci);
		break;
	default:
		break;
	}
	return (words);
}

erx_device_trb_verdict_t
erx_device_trb_command(erx_device_trb_t *trb, const erx_device_trb_layout_t *layout,
    const erx_device_trb_command_t *command, uint64_t tag, erx_dma_step_t *steps, uint32_t *count)
{
	acceptance_t accepted = { .reserved = 0 };
	plan_t plan = { .steps = steps };
	erx_device_trb_verdict_t verdict;
	trb_words_t words;
	placement_t placement;

	if (trb->command.kind != ERX_DEVICE_TRB_NO_COMMAND)
		return (ERX_DEVICE_TRB_REFUSE_FULL);
	if (command->kind == ERX_DEVICE_TRB_NO_COMMAND || command->kind > ERX_DEVICE_TRB_DISABLE_SLOT)
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	verdict = accept(trb, layout, command, &accepted);
	if (verdict != ERX_DEVICE_TRB_ACCEPTED)
		return (verdict);

	if (command->kind == ERX_DEVICE_TRB_ADDRESS_DEVICE) {
		erx_device_trb_slot_t *const slot = &trb->slots[command->slot];
		const uint32_t ep0 = (uint32_t)__builtin_ctzll(accepted.reserved);

		if (!slot->context_given) {
			const uint16_t context = layout->device_context[command->slot];

			add_zeros(&plan, region_offset(layout, context), layout->regions[context].length);
			add_address(&plan, region_offset(layout, layout->dcbaa) + command->slot * sizeof(uint64_t),
			    device_address(layout, region_offset(layout, context)),
			    (uint64_t)ERX_XHCI_DEVICE_CONTEXTS * layout->context_size);
			slot->context_given = true;
		}
		add_address_contexts(&plan, layout, trb, command, ep0);
	} else if (command->kind == ERX_DEVICE_TRB_EVALUATE_CONTEXT) {
		add_evaluate_contexts(&plan, layout, trb, command, find_queue(trb, command->slot, 1));
	} else if (command->kind == ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS) {
		add_configure_contexts(&plan, layout, trb, command, &accepted);
	}
	words = command_words(layout, trb, command, accepted.queue);
	placement = take_positions(&plan, layout, COMMAND_RING, &trb->command_ring, 1);
	add_trbs(&plan, layout, COMMAND_RING, &placement, &words, 1, 0, 0);

	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++) {
		if ((accepted.reserved >> block & 1u) == 0)
			continue;
		trb->blocks[block].state = ERX_DEVICE_TRB_RESERVED;
		trb->blocks[block].slot = command->slot;
		trb->blocks[block].dci = accepted.dci[block];
	}
	if (command->kind == ERX_DEVICE_TRB_STOP_ENDPOINT)
		trb->blocks[accepted.queue].state = ERX_DEVICE_TRB_STOPPING;
	trb->command = (erx_device_trb_pending_t){ .kind = command->kind, .slot = command->slot, .dci = command->dci,
	    .position = placement.position[0], .speed = command->speed, .held = accepted.held, .dropped = accepted.dropped,
	    .reserved = accepted.reserved, .tag = tag };
	*count = plan.count;
	return (ERX_DEVICE_TRB_ACCEPTED);
}

/* The reserved blocks become their queues, open at their rings' enqueue positions; or, on failure, free again. */
static void
settle_reserved(erx_device_trb_t *trb, uint64_t reserved, bool open)
{
	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++) {
		if ((reserved >> block & 1u) == 0)
			continue;
		if (!open) {
			release(&trb->blocks[block]);
			continue;
		}
		trb->blocks[block].state = ERX_DEVICE_TRB_OPEN;
		trb->blocks[block].span_start = trb->blocks[block].ring.enqueue;
	}
}

/* A queue removed: its posted transfers answered `stopped` and its block returned. */
static void
remove_queue(erx_device_trb_t *trb, uint32_t block, erx_device_trb_stopped_t *stopped, uint32_t *count)
{
	answer_stopped(&trb->blocks[block], block, stopped, count);
	release(&trb->blocks[block]);
}

bool
erx_device_trb_command_done(erx_device_trb_t *trb, const erx_device_trb_layout_t *layout,
    erx_device_trb_outcome_t outcome, uint32_t slot, uint64_t *tag, erx_device_trb_stopped_t *stopped,
    uint32_t *count)
{
	const erx_device_trb_pending_t command = trb->command;
	const bool success = outcome == ERX_DEVICE_TRB_SUCCESS;
	const uint32_t queue = find_queue(trb, command.slot, command.dci);

	*count = 0;
	if (command.kind == ERX_DEVICE_TRB_NO_COMMAND || (command.kind == ERX_DEVICE_TRB_ENABLE_SLOT && success &&
	    (slot < 1 || slot > layout->slots || trb->slots[slot].enabled)))
		return (false);
	switch (command.kind) {
	case ERX_DEVICE_TRB_ENABLE_SLOT:
		if (success)
			trb->slots[slot] = (erx_device_trb_slot_t){ .enabled = true };
		break;
	case ERX_DEVICE_TRB_CONFIGURE_ENDPOINTS:
		for (uint32_t block = 0; success && block < ERX_DEVICE_TRB_BLOCKS_MAX; block++)
			if ((command.dropped >> block & 1u) != 0)
				remove_queue(trb, block, stopped, count);
		settle_reserved(trb, command.reserved, success);
		break;
	case ERX_DEVICE_TRB_ADDRESS_DEVICE:
		if (success)
			trb->slots[command.slot].speed = command.speed;
		settle_reserved(trb, command.reserved, success);
		break;
	case ERX_DEVICE_TRB_STOP_ENDPOINT:
		if (trb->blocks[queue].state != ERX_DEVICE_TRB_STOPPING)
			break;
		trb->blocks[queue].state = success ? ERX_DEVICE_TRB_STOPPED :
		    outcome == ERX_DEVICE_TRB_CONTEXT_STATE_ERROR ? ERX_DEVICE_TRB_HALTED : ERX_DEVICE_TRB_OPEN;
		break;
	case ERX_DEVICE_TRB_RESET_ENDPOINT:
		if (success)
			trb->blocks[queue].state = ERX_DEVICE_TRB_STOPPED;
		break;
	case ERX_DEVICE_TRB_SET_TR_DEQUEUE:
		if (success) {
			answer_stopped(&trb->blocks[queue], queue, stopped, count);
			trb->blocks[queue].state = ERX_DEVICE_TRB_OPEN;
		}
		break;
	case ERX_DEVICE_TRB_DISABLE_SLOT:
		for (uint32_t block = 0; success && block < ERX_DEVICE_TRB_BLOCKS_MAX; block++)
			if (is_queue(&trb->blocks[block]) && trb->blocks[block].slot == command.slot)
				remove_queue(trb, block, stopped, count);
		if (success)
			trb->slots[command.slot] = (erx_device_trb_slot_t){ .enabled = false };
		break;
	default:
		break;
	}
	*tag = command.tag;
	bzero(&trb->command, sizeof(trb->command));
	return (true);
}
