/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The model of an xHCI controller's ring side (erx_device_trb_model.h).
 */

#include "erx_device_trb_model.h"

#include "erx/abi.h"
#include "liberx/backend/core/mem.h"

#define TRB_SIZE	ERX_XHCI_TRB_NORMAL_SIZE
/* The most TRBs one run takes from a ring before it yields: more than any ring holds. */
#define RUN_BOUND	1024u

typedef struct trb {
	uint64_t	parameter;
	uint32_t	status;
	uint32_t	control;
} trb_t;

static uint64_t
load_le(const uint8_t *bytes, uint32_t width)
{
	uint64_t value = 0;

	for (uint32_t index = width; index-- > 0;)
		value = value << 8 | bytes[index];
	return (value);
}

static bool
read_trb(const erx_device_trb_model_t *model, uint64_t addr, trb_t *trb)
{
	uint8_t bytes[TRB_SIZE];

	if (!model->memory.read(model->memory.context, addr, bytes, TRB_SIZE))
		return (false);
	trb->parameter = load_le(bytes + ERX_XHCI_TRB_NORMAL_OFF_BUFFER, 8);
	trb->status = (uint32_t)load_le(bytes + ERX_XHCI_TRB_NORMAL_OFF_STATUS, 4);
	trb->control = (uint32_t)load_le(bytes + ERX_XHCI_TRB_NORMAL_OFF_CONTROL, 4);
	return (true);
}

static void
store_le(uint8_t *bytes, uint64_t value, uint32_t width)
{
	for (uint32_t index = 0; index < width; index++)
		bytes[index] = (uint8_t)(value >> (8u * index));
}

static bool
read_u32(const erx_device_trb_model_t *model, uint64_t addr, uint32_t *value)
{
	uint8_t bytes[4];

	if (!model->memory.read(model->memory.context, addr, bytes, 4))
		return (false);
	*value = (uint32_t)load_le(bytes, 4);
	return (true);
}

static bool
read_u64(const erx_device_trb_model_t *model, uint64_t addr, uint64_t *value)
{
	uint8_t bytes[8];

	if (!model->memory.read(model->memory.context, addr, bytes, 8))
		return (false);
	*value = load_le(bytes, 8);
	return (true);
}

void
erx_device_trb_model_init(erx_device_trb_model_t *model, const erx_device_trb_layout_t *layout,
    const erx_device_trb_memory_t *memory, erx_device_trb_model_sink_t *sink, void *sink_context)
{
	bzero(model, sizeof(*model));
	model->layout = layout;
	model->memory = *memory;
	model->sink = sink;
	model->sink_context = sink_context;
	model->command = (erx_device_trb_model_ring_t){ .running = true, .cycle = 1,
	    .dequeue = layout->device_base + erx_device_trb_position_offset(layout, ERX_DEVICE_TRB_BLOCKS_MAX, 0) };
}

void
erx_device_trb_model_doorbell(erx_device_trb_model_t *model, uint32_t doorbell, uint32_t target)
{
	erx_device_trb_model_ring_t *ring;

	if (doorbell == 0 || doorbell > model->layout->slots || target < 1 || target >= ERX_XHCI_DEVICE_CONTEXTS)
		return;
	ring = &model->rings[doorbell][target];
	if (model->enabled[doorbell] && ring->dequeue != 0 && !ring->halted)
		ring->running = true;
}

bool
erx_device_trb_model_segment_table(erx_device_trb_model_t *model, uint64_t table)
{
	uint64_t base;
	uint32_t size;

	if (!read_u64(model, table + ERX_XHCI_SEGMENT_TABLE_ENTRY_OFF_BASE, &base) ||
	    !read_u32(model, table + ERX_XHCI_SEGMENT_TABLE_ENTRY_OFF_SIZE, &size))
		return (false);
	base = erx_xhci_segment_table_entry_base_address_get(base);
	size = erx_xhci_segment_table_entry_size_trbs_get(size);
	if (size == 0 || !model->memory.read(model->memory.context, base + (uint64_t)(size - 1u) * TRB_SIZE,
	    model->scratch, TRB_SIZE))
		return (false);
	model->event_base = base;
	model->event_trbs = size;
	model->event_enqueue = 0;
	model->event_dequeue = 0;
	model->event_cycle = 1;
	return (true);
}

bool
erx_device_trb_model_dequeue(erx_device_trb_model_t *model, uint64_t dequeue)
{
	if (dequeue < model->event_base || (dequeue - model->event_base) % TRB_SIZE != 0 ||
	    (dequeue - model->event_base) / TRB_SIZE >= model->event_trbs)
		return (false);
	model->event_dequeue = (uint32_t)((dequeue - model->event_base) / TRB_SIZE);
	return (true);
}

/*
 * One event TRB written whole at the enqueue position with the producer cycle state, the position
 * moving on and the state toggling past the segment's end. False with no room: the next position
 * is the one the dequeue register names.
 */
static bool
report(erx_device_trb_model_t *model, uint64_t pointer, uint32_t status, uint32_t control)
{
	uint8_t bytes[TRB_SIZE];

	if (model->event_trbs == 0 || (model->event_enqueue + 1u) % model->event_trbs == model->event_dequeue ||
	    !erx_xhci_trb_transfer_event_control_cycle_set(&control, model->event_cycle))
		return (false);
	store_le(bytes + ERX_XHCI_TRB_TRANSFER_EVENT_OFF_POINTER, pointer, 8);
	store_le(bytes + ERX_XHCI_TRB_TRANSFER_EVENT_OFF_STATUS, status, 4);
	store_le(bytes + ERX_XHCI_TRB_TRANSFER_EVENT_OFF_CONTROL, control, 4);
	if (!model->memory.write(model->memory.context, model->event_base + (uint64_t)model->event_enqueue * TRB_SIZE,
	    bytes, TRB_SIZE))
		return (false);
	model->event_enqueue = (model->event_enqueue + 1u) % model->event_trbs;
	if (model->event_enqueue == 0)
		model->event_cycle ^= 1u;
	return (true);
}

/* A Transfer Event naming the TRB at `at` (6.4.2.1). */
static bool
report_transfer(erx_device_trb_model_t *model, uint32_t slot, uint32_t dci, uint64_t at, uint32_t code,
    uint32_t residue)
{
	uint32_t status = 0, control = 0;

	return (erx_xhci_trb_transfer_event_status_code_set(&status, code) &&
	    erx_xhci_trb_transfer_event_status_residue_set(&status, residue) &&
	    erx_xhci_trb_transfer_event_control_type_set(&control, ERX_XHCI_TRB_TYPE_TRANSFER_EVENT) &&
	    erx_xhci_trb_transfer_event_control_slot_set(&control, slot) &&
	    erx_xhci_trb_transfer_event_control_endpoint_set(&control, dci) &&
	    report(model, at, status, control));
}

/* A Command Completion Event naming the command TRB at `at` (6.4.2.2). */
static bool
report_command(erx_device_trb_model_t *model, uint64_t at, uint32_t code, uint32_t slot)
{
	uint32_t status = 0, control = 0;

	return (erx_xhci_trb_command_event_status_code_set(&status, code) &&
	    erx_xhci_trb_command_event_control_type_set(&control, ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT) &&
	    erx_xhci_trb_command_event_control_slot_set(&control, slot) &&
	    report(model, at, status, control));
}

/* A ring started where an endpoint context or Set TR Dequeue points: its dequeue pointer and cycle. */
static void
start_ring(erx_device_trb_model_ring_t *ring, uint64_t dequeue)
{
	*ring = (erx_device_trb_model_ring_t){ .dequeue = erx_xhci_endpoint_context_dequeue_dequeue_pointer_get(dequeue),
	    .cycle = erx_xhci_endpoint_context_dequeue_dequeue_cycle_get(dequeue) };
}

/* The rings an input context adds start, and the ones it drops stop. */
static bool
read_input_context(erx_device_trb_model_t *model, uint32_t slot, uint64_t input)
{
	const uint32_t size = model->layout->context_size;
	uint32_t drop, adds;

	if (!read_u32(model, input + ERX_XHCI_INPUT_CONTROL_CONTEXT_OFF_DROP, &drop) ||
	    !read_u32(model, input + ERX_XHCI_INPUT_CONTROL_CONTEXT_OFF_ADD, &adds))
		return (false);
	for (uint32_t dci = 1; dci < ERX_XHCI_DEVICE_CONTEXTS; dci++) {
		uint64_t dequeue;

		if ((drop >> dci & 1u) != 0)
			bzero(&model->rings[slot][dci], sizeof(model->rings[slot][dci]));
		if ((adds >> dci & 1u) == 0)
			continue;
		if (!read_u64(model, input + (uint64_t)(dci + 1u) * size + ERX_XHCI_ENDPOINT_CONTEXT_OFF_DEQUEUE, &dequeue))
			return (false);
		start_ring(&model->rings[slot][dci], dequeue);
	}
	return (true);
}

static uint32_t
lowest_free_slot(const erx_device_trb_model_t *model)
{
	for (uint32_t slot = 1; slot <= model->layout->slots; slot++)
		if (!model->enabled[slot])
			return (slot);
	return (0);
}

/* One command TRB, completed at once. */
static int
take_command(erx_device_trb_model_t *model, const trb_t *trb, uint64_t at)
{
	const uint32_t type = erx_xhci_trb_command_control_type_get(trb->control);
	uint32_t slot = erx_xhci_trb_command_control_slot_get(trb->control);
	const uint32_t dci = erx_xhci_trb_command_control_endpoint_get(trb->control);
	uint32_t code = ERX_XHCI_COMPLETION_SUCCESS;

	if (type != ERX_XHCI_TRB_TYPE_ENABLE_SLOT && (slot < 1 || slot > model->layout->slots || !model->enabled[slot]))
		return (ERX_ECORRUPT);
	switch (type) {
	case ERX_XHCI_TRB_TYPE_ENABLE_SLOT:
		slot = lowest_free_slot(model);
		if (slot == 0)
			code = ERX_XHCI_COMPLETION_NO_SLOTS;
		else
			model->enabled[slot] = true;
		break;
	case ERX_XHCI_TRB_TYPE_ADDRESS_DEVICE:
	case ERX_XHCI_TRB_TYPE_CONFIGURE_ENDPOINT:
		if (!read_input_context(model, slot, erx_xhci_trb_command_parameter_pointer_get(trb->parameter)))
			return (ERX_ECORRUPT);
		break;
	case ERX_XHCI_TRB_TYPE_EVALUATE_CONTEXT:
		break;
	case ERX_XHCI_TRB_TYPE_STOP_ENDPOINT:
		/* A ring stopped inside a TD reports where it stopped: the TRB it would take next. */
		if (model->rings[slot][dci].in_td && !report_transfer(model, slot, dci, model->rings[slot][dci].dequeue,
		    ERX_XHCI_COMPLETION_STOPPED, 0))
			return (ERX_ECORRUPT);
		model->rings[slot][dci].running = false;
		break;
	case ERX_XHCI_TRB_TYPE_RESET_ENDPOINT:
		model->rings[slot][dci].halted = false;
		break;
	case ERX_XHCI_TRB_TYPE_SET_TR_DEQUEUE:
		start_ring(&model->rings[slot][dci], trb->parameter);
		break;
	case ERX_XHCI_TRB_TYPE_DISABLE_SLOT:
		model->enabled[slot] = false;
		bzero(model->rings[slot], sizeof(model->rings[slot]));
		break;
	default:
		return (ERX_ECORRUPT);
	}
	return (report_command(model, at, code, slot) ? ERX_OK : ERX_ECORRUPT);
}

/*
 * A buffer moved as its TRB is taken, the bytes moved into *moved: an out buffer goes to the sink
 * whole; an in buffer receives a fresh pattern, half of it on a short packet, and the sink sees
 * what was written.
 */
static bool
move_buffer(erx_device_trb_model_t *model, erx_device_trb_model_ring_t *ring, uint32_t slot, uint32_t dci,
    uint64_t addr, uint32_t length, bool in, uint32_t *moved)
{
	uint32_t pattern;

	if (length > sizeof(model->scratch))
		return (false);
	*moved = length;
	if (!in) {
		if (!model->memory.read(model->memory.context, addr, model->scratch, length))
			return (false);
		model->sink(model->sink_context, slot, dci, addr, model->scratch, length, false);
		return (true);
	}
	if (ring->short_packet && length != 0) {
		ring->short_packet = false;
		*moved = length / 2u;
	}
	pattern = model->patterns++;
	for (uint32_t index = 0; index < *moved; index++)
		model->scratch[index] = erx_device_trb_model_pattern(pattern, index);
	if (!model->memory.write(model->memory.context, addr, model->scratch, *moved))
		return (false);
	model->sink(model->sink_context, slot, dci, addr, model->scratch, *moved, true);
	return (true);
}

/*
 * One transfer TRB. A TD's last, with interrupt on completion, reports it: success, a short
 * packet with its residue, or the transaction error `fail` asked for, which halts the ring. A
 * short packet on a control data stage with interrupt on short reports there, and the status
 * stage still completes the TD.
 */
static int
take_transfer(erx_device_trb_model_t *model, uint32_t slot, uint32_t dci, const trb_t *trb, uint64_t at)
{
	erx_device_trb_model_ring_t *const ring = &model->rings[slot][dci];
	const uint32_t type = erx_xhci_trb_normal_control_type_get(trb->control);
	uint32_t length = 0, moved = 0, code = ERX_XHCI_COMPLETION_SUCCESS;
	bool completes = false;

	switch (type) {
	case ERX_XHCI_TRB_TYPE_SETUP_STAGE:
		if (erx_xhci_trb_setup_control_immediate_data_get(trb->control) == 0)
			return (ERX_ECORRUPT);
		break;
	case ERX_XHCI_TRB_TYPE_DATA_STAGE:
		length = erx_xhci_trb_data_status_length_get(trb->status);
		if (!move_buffer(model, ring, slot, dci, trb->parameter, length,
		    erx_xhci_trb_data_control_direction_in_get(trb->control) != 0, &moved))
			return (ERX_ECORRUPT);
		if (moved < length && erx_xhci_trb_data_control_interrupt_on_short_get(trb->control) != 0 &&
		    !report_transfer(model, slot, dci, at, ERX_XHCI_COMPLETION_SHORT_PACKET, length - moved))
			return (ERX_ECORRUPT);
		moved = length;
		break;
	case ERX_XHCI_TRB_TYPE_NORMAL:
		length = erx_xhci_trb_normal_status_length_get(trb->status);
		if (!move_buffer(model, ring, slot, dci, trb->parameter, length, dci > 1u && dci % 2u == 1u, &moved))
			return (ERX_ECORRUPT);
		completes = erx_xhci_trb_normal_control_interrupt_on_completion_get(trb->control) != 0;
		break;
	case ERX_XHCI_TRB_TYPE_STATUS_STAGE:
		completes = erx_xhci_trb_status_control_interrupt_on_completion_get(trb->control) != 0;
		break;
	default:
		return (ERX_ECORRUPT);
	}
	ring->in_td = !completes;
	if (!completes)
		return (ERX_OK);
	if (ring->fail) {
		ring->fail = false;
		ring->halted = true;
		ring->running = false;
		code = ERX_XHCI_COMPLETION_TRANSACTION_ERROR;
		moved = length;
	} else if (moved < length) {
		code = ERX_XHCI_COMPLETION_SHORT_PACKET;
	}
	return (report_transfer(model, slot, dci, at, code, length - moved) ? ERX_OK : ERX_ECORRUPT);
}

/* A ring run as far as its cycle bits allow, following its links. */
static int
run_ring(erx_device_trb_model_t *model, erx_device_trb_model_ring_t *ring, uint32_t slot, uint32_t dci)
{
	for (uint32_t taken = 0; taken < RUN_BOUND && ring->running; taken++) {
		const uint64_t at = ring->dequeue;
		trb_t trb;
		int status;

		if (!read_trb(model, at, &trb))
			return (ERX_ECORRUPT);
		if (erx_xhci_trb_normal_control_cycle_get(trb.control) != ring->cycle)
			return (ERX_OK);
		if (erx_xhci_trb_normal_control_type_get(trb.control) == ERX_XHCI_TRB_TYPE_LINK) {
			ring->dequeue = erx_xhci_trb_link_segment_segment_pointer_get(trb.parameter);
			ring->cycle ^= erx_xhci_trb_link_control_toggle_cycle_get(trb.control);
			continue;
		}
		ring->dequeue = at + TRB_SIZE;
		status = slot == 0 ? take_command(model, &trb, at) : take_transfer(model, slot, dci, &trb, at);
		if (status != ERX_OK)
			return (status);
	}
	return (ring->running ? ERX_ECORRUPT : ERX_OK);
}

int
erx_device_trb_model_run(erx_device_trb_model_t *model)
{
	int status = run_ring(model, &model->command, 0, 0);

	for (uint32_t slot = 1; status == ERX_OK && slot <= model->layout->slots; slot++)
		for (uint32_t dci = 1; status == ERX_OK && dci < ERX_XHCI_DEVICE_CONTEXTS; dci++)
			if (model->enabled[slot])
				status = run_ring(model, &model->rings[slot][dci], slot, dci);
	return (status);
}
