/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's layout and stated-parameter checks (erx_device_trb.h; docs/design-usb.md,
 * "The TRB ring form").
 */

#include "erx_device_trb.h"

#include "erx/abi.h"
#include "liberx/backend/core/mem.h"

const erx_device_trb_shape_t erx_device_trb_shape = {
	.ring_trbs = ERX_DEVICE_TRB_RING_TRBS,
	.blocks = { 16u, 16u, 4u },
	.buffers = { 1u, 4u, 2u },
	.buffer_size = { ERX_XHCI_CONTROL_BUFFER_SIZE, ERX_XHCI_INTERRUPT_BUFFER_SIZE, ERX_XHCI_BULK_BUFFER_SIZE },
};

/* Each TRB is 16 bytes, so a ring position lies at its index times that. */
#define TRB_SIZE		ERX_XHCI_TRB_NORMAL_SIZE
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
    ERX_XHCI_TRB_COMMAND_SIZE == TRB_SIZE, "every TRB is one size");
_Static_assert(16u + 16u + 4u == ERX_DEVICE_TRB_BLOCKS_MAX, "the form's blocks fill the bound");

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

uint32_t
erx_device_trb_block_count(const erx_device_trb_shape_t *shape)
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
	blocks = erx_device_trb_block_count(shape);

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

uint64_t
erx_device_trb_position_offset(const erx_device_trb_layout_t *layout, uint32_t block, uint32_t position)
{
	const uint16_t ring = block == COMMAND_RING ? layout->command_ring : layout->block_ring[block];

	return (region_offset(layout, ring) + (uint64_t)position * TRB_SIZE);
}

/* The transfer request's check. */

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

/* The one test of a transfer, the TRB form's at its post (erx_device_trb.h). */
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
