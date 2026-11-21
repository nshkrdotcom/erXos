/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's core: see erx_device_trb_form.h.
 *
 * The ERX_TRB_FORM_SEED_* macros plant the faults test/host/erx_device_trb_form_test.rb shows its
 * harness catches (docs/design-device-dma.md, Verification).
 */

#include "erx_device_trb_form.h"

#include "liberx/backend/core/mem.h"

#ifdef ERX_TRB_FORM_SEED_ADDRESS_UNENABLED
#define SEED_ADDRESS_UNENABLED	true
#else
#define SEED_ADDRESS_UNENABLED	false
#endif
#ifdef ERX_TRB_FORM_SEED_ANY_STOP
#define SEED_ANY_STOP	true
#else
#define SEED_ANY_STOP	false
#endif
#ifdef ERX_TRB_FORM_SEED_ANSWER_HALTED
#define SEED_ANSWER_HALTED	true
#else
#define SEED_ANSWER_HALTED	false
#endif
#ifdef ERX_TRB_FORM_SEED_ANY_TRANSFER
#define SEED_ANY_TRANSFER	true
#else
#define SEED_ANY_TRANSFER	false
#endif
#ifdef ERX_TRB_FORM_SEED_HALT_HEAD_OF_NEWEST
#define SEED_HALT_HEAD_OF_NEWEST	true
#else
#define SEED_HALT_HEAD_OF_NEWEST	false
#endif
#ifdef ERX_TRB_FORM_SEED_HIGHEST_BUFFER
#define SEED_HIGHEST_BUFFER	true
#else
#define SEED_HIGHEST_BUFFER	false
#endif
#ifdef ERX_TRB_FORM_SEED_NO_OUT_FILL
#define SEED_NO_OUT_FILL	true
#else
#define SEED_NO_OUT_FILL	false
#endif
#ifdef ERX_TRB_FORM_SEED_TAG_AT_FIRST
#define SEED_TAG_AT_FIRST	true
#else
#define SEED_TAG_AT_FIRST	false
#endif
#ifdef ERX_TRB_FORM_SEED_NO_REQUEST_CHECK
#define SEED_NO_REQUEST_CHECK	true
#else
#define SEED_NO_REQUEST_CHECK	false
#endif
#ifdef ERX_TRB_FORM_SEED_ANY_ENDPOINT
#define SEED_ANY_ENDPOINT	true
#else
#define SEED_ANY_ENDPOINT	false
#endif
#ifdef ERX_TRB_FORM_SEED_DEQUEUE_STALE
#define SEED_DEQUEUE_STALE	true
#else
#define SEED_DEQUEUE_STALE	false
#endif
#ifdef ERX_TRB_FORM_SEED_OTHER_POOL
#define SEED_OTHER_POOL		true
#else
#define SEED_OTHER_POOL		false
#endif
#ifdef ERX_TRB_FORM_SEED_CONFIGURE_UNADDRESSED
#define SEED_CONFIGURE_UNADDRESSED	true
#else
#define SEED_CONFIGURE_UNADDRESSED	false
#endif
#ifdef ERX_TRB_FORM_SEED_CONFIGURE_SPEED_ZEROED
#define SEED_CONFIGURE_SPEED_ZEROED	true
#else
#define SEED_CONFIGURE_SPEED_ZEROED	false
#endif

/* The form's device addresses: every address place of its TRBs and contexts is 64 bits wide. */
#define ADDRESS_BITS	64u

/* A table over region `region` of `trb`, its records from the region's start. */
static erx_dma_table_t
table(const erx_device_trb_layout_t *trb, uint16_t region, uint32_t structure, erx_dma_placing_t placing,
    uint32_t pool, uint32_t count)
{
	return ((erx_dma_table_t){ .structure = structure, .placing = placing, .pool = pool,
	    .region = trb->regions[region].offset, .region_length = trb->regions[region].length,
	    .first = trb->regions[region].offset, .count = count, .stride = erx_structure_record_size(structure) });
}

bool
erx_trb_form_layout(const erx_device_trb_layout_t *trb, erx_dma_layout_t *layout)
{
	const uint32_t blocks = erx_device_trb_block_count(&trb->shape);
	const uint32_t command_pool = blocks;

	if (trb->shape.ring_trbs > ERX_DEVICE_TRB_RING_TRBS)
		return (false);
	*layout = (erx_dma_layout_t){ .memory_size = trb->bytes, .device_base = trb->device_base,
	    .address_bits = ADDRESS_BITS, .granule = trb->granule, .context_size = trb->context_size,
	    .table_count = blocks + 2u, .pool_count = blocks + 1u };
	/*
	 * A block's buffers lie one after another, each its region's length from the last, since
	 * erx_device_trb_layout places them in order at one size and alignment.
	 */
	for (uint32_t block = 0; block < blocks; block++) {
		const erx_device_trb_kind_t kind = erx_device_trb_block_kind(&trb->shape, block);
		const erx_device_trb_region_t *const first = &trb->regions[trb->buffer[block][0]];

		layout->tables[block] = table(trb, trb->block_ring[block], ERX_STRUCTURE_XHCI_TRANSFER_RING,
		    ERX_DMA_PLACED_RING, block, trb->shape.ring_trbs);
		layout->pools[block] = (erx_dma_pool_t){ .first = first->offset, .count = trb->shape.buffers[kind],
		    .size = trb->shape.buffer_size[kind], .stride = (uint32_t)first->length };
	}
	layout->tables[blocks] = table(trb, trb->command_ring, ERX_STRUCTURE_XHCI_COMMAND_RING, ERX_DMA_PLACED_RING,
	    command_pool, trb->shape.ring_trbs);
	layout->tables[blocks + 1u] = table(trb, trb->event_ring, ERX_STRUCTURE_XHCI_EVENT_RING, ERX_DMA_PLACED_FREE,
	    0, ERX_DEVICE_TRB_EVENT_TRBS);
	/* The input context's region, whole. */
	layout->pools[command_pool] = (erx_dma_pool_t){ .first = trb->regions[trb->input_context].offset, .count = 1,
	    .size = (uint32_t)trb->regions[trb->input_context].length,
	    .stride = (uint32_t)trb->regions[trb->input_context].length };
	return (true);
}

bool
erx_trb_form_make(erx_trb_form_t *form, const erx_device_trb_layout_t *trb, const erx_dma_regions_t *regions)
{
	erx_dma_layout_t layout;

	bzero(form, sizeof(*form));
	form->layout = *trb;
	form->shape = trb->shape;
	form->ports = trb->ports;
	form->slots = trb->slots;
	return (erx_trb_form_layout(trb, &layout) && erx_dma_ledger_make(&form->ledger, &layout, regions));
}

const erx_dma_ledger_t *
erx_trb_form_ledger(const erx_trb_form_t *form)
{
	return (&form->ledger);
}

uint32_t
erx_trb_form_endpoint(uint32_t slot, uint32_t dci)
{
	if (slot < 1 || slot > ERX_DEVICE_TRB_SLOTS_MAX || dci < 1 || dci > ERX_DEVICE_TRB_DCI_MAX)
		return (0);
	return (slot << 5 | dci);
}

/* The number of pool `pool`'s first buffer: buffers are numbered across the pools, in order. */
static uint32_t
pool_first_buffer(const erx_dma_layout_t *layout, uint32_t pool)
{
	uint32_t first = 0;

	for (uint32_t index = 0; index < pool; index++)
		first += layout->pools[index].count;
	return (first);
}

/* The lowest buffer of pool `pool` no holding holds, into `*buffer`; false for none. */
static bool
free_buffer(const erx_dma_ledger_t *ledger, uint32_t pool, uint32_t *buffer)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(ledger);
	const uint32_t first = pool_first_buffer(layout, pool), count = layout->pools[pool].count;

	for (uint32_t k = 0; k < count; k++) {
		const uint32_t candidate = first + (SEED_HIGHEST_BUFFER ? count - 1u - k : k);

		if (!erx_dma_ledger_buffer_held(ledger, candidate)) {
			*buffer = candidate;
			return (true);
		}
	}
	return (false);
}

/* Whether the request's TRBs name a buffer: a normal TRB, or a control transfer's data stage. */
static bool
names_buffer(const erx_device_trb_request_t *request)
{
	return (!request->control || request->data);
}

/*
 * The TRBs of `request` over `buffer` (docs/design-usb.md, "What Erlang names and what the NIF
 * builds"), into `records`, zeroed so the check sees no stale free value; their count.
 */
static uint32_t
describe(const erx_device_trb_request_t *request, uint32_t buffer, erx_dma_description_t records[ERX_DEVICE_TRB_TRANSFER_TRBS])
{
	const erx_dma_name_t name = { .buffer = buffer, .offset = 0 };
	uint64_t setup = 0;
	uint32_t count = 0;

	bzero(records, ERX_DEVICE_TRB_TRANSFER_TRBS * sizeof(records[0]));
	for (uint32_t index = 0; index < ERX_DEVICE_TRB_TRANSFER_TRBS; index++)
		records[index].structure = ERX_STRUCTURE_XHCI_TRANSFER_RING;
	if (!request->control) {
		records[0].meaning = ERX_MEANING_XHCI_TRB_NORMAL;
		records[0].described.xhci_trb_normal = (erx_xhci_trb_normal_free_t){ .status_length = request->length,
		    .control_interrupt_on_short = 1, .control_interrupt_on_completion = 1 };
		records[0].name_count = 1;
		records[0].names[0] = name;
		return (1);
	}
	for (uint32_t index = 0; index < sizeof(request->setup); index++)
		setup |= (uint64_t)request->setup[index] << (8u * index);
	records[count].meaning = ERX_MEANING_XHCI_TRB_SETUP;
	records[count++].described.xhci_trb_setup = (erx_xhci_trb_setup_free_t){ .setup = setup,
	    .control_transfer_type = !request->data ? ERX_XHCI_TRANSFER_TYPE_NONE :
	    request->device_writes ? ERX_XHCI_TRANSFER_TYPE_IN : ERX_XHCI_TRANSFER_TYPE_OUT };
	if (request->data) {
		records[count].meaning = ERX_MEANING_XHCI_TRB_DATA;
		records[count].described.xhci_trb_data = (erx_xhci_trb_data_free_t){ .status_length = request->length,
		    .control_interrupt_on_short = 1, .control_direction_in = request->device_writes };
		records[count].name_count = 1;
		records[count++].names[0] = name;
	}
	/* The status stage runs in the other direction from the data, and IN with none (4.11.2.2). */
	records[count].meaning = ERX_MEANING_XHCI_TRB_STATUS;
	records[count++].described.xhci_trb_status = (erx_xhci_trb_status_free_t){
	    .control_direction_in = !request->data || !request->device_writes, .control_interrupt_on_completion = 1 };
	return (count);
}

erx_device_trb_verdict_t
erx_trb_form_post(erx_trb_form_t *form, uint32_t slot, uint32_t dci, const erx_device_trb_request_t *request,
    uint64_t tag, erx_dma_sequence_t *sequence)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	const uint32_t endpoint = erx_trb_form_endpoint(slot, dci);
	const int ring = endpoint == 0 ? -1 : erx_dma_ledger_bound_table(&form->ledger, endpoint);
	erx_dma_description_t records[ERX_DEVICE_TRB_TRANSFER_TRBS];
	erx_dma_fill_t fill;
	erx_dma_publication_t publication = { .records = records, .fills = &fill, .call = ERX_DMA_PUBLISH_RUN,
	    .endpoint = endpoint };
	erx_device_trb_kind_t kind;
	erx_dma_found_t found;
	erx_dma_place_t head;
	uint32_t buffer = 0, pool;

	/* The refusals in the order the header gives. */
	if (ring < 0)
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	kind = erx_device_trb_block_kind(&form->shape, (uint32_t)ring);
	if (!SEED_NO_REQUEST_CHECK &&
	    !erx_device_trb_request_valid(request, kind, dci, form->shape.buffer_size[kind]))
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	pool = layout->tables[ring].pool;
	if (SEED_OTHER_POOL)
		pool = (pool + 1u) % erx_device_trb_block_count(&form->shape);
	if (names_buffer(request) && !free_buffer(&form->ledger, pool, &buffer))
		return (ERX_DEVICE_TRB_REFUSE_FULL);

	publication.record_count = describe(request, buffer, records);
	if (!SEED_NO_OUT_FILL && !request->device_writes && request->length != 0) {
		fill = (erx_dma_fill_t){ .kind = ERX_DMA_FILL_BYTES, .buffer = buffer, .offset = 0, .length = request->length };
		publication.fill_count = 1;
	}
	switch (erx_dma_publish(&form->ledger, &publication, sequence)) {
	case ERX_DMA_PASSES:
		/* The holding's head, the TD's last TRB, which its completion names: records[0]. */
		found = erx_dma_ledger_newest(&form->ledger);
		head = found.holding->records[SEED_TAG_AT_FIRST && found.holding->record_count > 1 ? 1 : 0];
		form->transfers[head.table][head.index] = (erx_trb_transfer_t){ .tag = tag, .length = request->length,
		    .buffer = buffer, .names_buffer = names_buffer(request), .data_stage = request->control && request->data };
		return (ERX_DEVICE_TRB_ACCEPTED);
	case ERX_DMA_BREAKS_ROOM:
		return (ERX_DEVICE_TRB_REFUSE_FULL);
	case ERX_DMA_BREAKS_REACH:
		return (ERX_DEVICE_TRB_REFUSE_HALTED);
	default:
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	}
}

/* Each command's meaning, by kind. */
static const uint32_t command_meanings[ERX_TRB_COMMAND_KINDS] = {
	[ERX_TRB_COMMAND_NOOP] = ERX_MEANING_XHCI_TRB_NOOP_COMMAND,
	[ERX_TRB_COMMAND_ENABLE_SLOT] = ERX_MEANING_XHCI_TRB_ENABLE_SLOT_COMMAND,
	[ERX_TRB_COMMAND_DISABLE_SLOT] = ERX_MEANING_XHCI_TRB_DISABLE_SLOT_COMMAND,
	[ERX_TRB_COMMAND_ADDRESS_DEVICE] = ERX_MEANING_XHCI_TRB_ADDRESS_DEVICE_COMMAND,
	[ERX_TRB_COMMAND_CONFIGURE_ENDPOINT] = ERX_MEANING_XHCI_TRB_CONFIGURE_ENDPOINT_COMMAND,
	[ERX_TRB_COMMAND_EVALUATE_CONTEXT] = ERX_MEANING_XHCI_TRB_EVALUATE_CONTEXT_COMMAND,
	[ERX_TRB_COMMAND_RESET_ENDPOINT] = ERX_MEANING_XHCI_TRB_RESET_ENDPOINT_COMMAND,
	[ERX_TRB_COMMAND_STOP_ENDPOINT] = ERX_MEANING_XHCI_TRB_STOP_ENDPOINT_COMMAND,
	[ERX_TRB_COMMAND_SET_TR_DEQUEUE] = ERX_MEANING_XHCI_TRB_SET_DEQUEUE_COMMAND,
};

/*
 * Whether each added endpoint's stated context passes its check (erx_device_trb.h) for a block of
 * the form, of the kind its type needs: EP0 alone for Address Device, indexes 2 and up for
 * Configure Endpoint, at the slot's speed.
 */
static bool
adds_valid(const erx_trb_form_t *form, const erx_trb_command_t *command)
{
	for (uint32_t k = 0; k < command->add_count; k++) {
		const erx_trb_add_t *const add = &command->adds[k];
		const erx_device_trb_context_endpoint_t endpoint = { .dci = add->dci, .context = add->context };
		erx_device_trb_kind_t kind;

		if (add->block >= erx_device_trb_block_count(&form->shape))
			return (false);
		kind = erx_device_trb_block_kind(&form->shape, add->block);
		if (command->kind == ERX_TRB_COMMAND_ADDRESS_DEVICE ? add->dci != 1 || kind != ERX_DEVICE_TRB_CONTROL ||
		    !erx_device_trb_ep0_valid(&add->context, true) :
		    !erx_device_trb_endpoint_valid(&endpoint, kind, form->shape.buffer_size[kind],
		    form->addressed[command->slot].route_speed))
			return (false);
	}
	return (true);
}

/*
 * Whether `slot` of the layout's has an Address Device that succeeded since its Disable Slot or a
 * reset, whose fields `addressed` holds: a valid Address Device states a speed (erx_device_trb.h),
 * and the slot's entry is zero until one succeeds.
 */
static bool
slot_addressed(const erx_trb_form_t *form, uint32_t slot)
{
	return (form->addressed[slot].route_speed != 0);
}

/*
 * The stated parameters' one test, at the command's entry, before anything changes: the slot of
 * every command that names one, a slot of the layout's; and those of the three commands that carry
 * the input context, Address Device's for a slot an Enable Slot enabled (4.6.5, p. 114, where any
 * other slot answers Slot Not Enabled and its binding would stay until a Disable Slot that cannot
 * succeed), Configure Endpoint's for an addressed slot (6.2.2.2's Addressed or Configured
 * precondition, p. 448), whose fields its slot context composes from. A command that carries none
 * states none.
 */
static bool
parameters_valid(const erx_trb_form_t *form, const erx_trb_command_t *command)
{
	if (command->kind != ERX_TRB_COMMAND_NOOP && command->kind != ERX_TRB_COMMAND_ENABLE_SLOT &&
	    (command->slot < 1 || command->slot > form->slots))
		return (false);
	switch (command->kind) {
	case ERX_TRB_COMMAND_ADDRESS_DEVICE:
		return ((form->enabled[command->slot] || SEED_ADDRESS_UNENABLED) && command->add_count == 1 &&
		    erx_device_trb_address_slot_valid(&command->slot_context, form->ports, form->slots) &&
		    adds_valid(form, command));
	case ERX_TRB_COMMAND_CONFIGURE_ENDPOINT:
		return ((slot_addressed(form, command->slot) || SEED_CONFIGURE_UNADDRESSED) &&
		    erx_device_trb_configure_slot_valid(&command->slot_context) && adds_valid(form, command));
	case ERX_TRB_COMMAND_EVALUATE_CONTEXT:
		return (command->add_count == 0 && erx_device_trb_ep0_valid(&(erx_xhci_endpoint_context_free_t){
		    .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL, .config_max_packet = command->ep0_packet }, false));
	default:
		return (true);
	}
}

/*
 * Configure Endpoint's slot context: the fields its slot was addressed with (route string, speed,
 * root port, TT hub slot and port, and that hub's multi-TT flag) and the stated hub fields. Think
 * time and multi-TT are a high-speed hub's own (6.2.2.2, p. 448): a slot at another speed keeps
 * the addressed multi-TT flag and think time 0.
 */
static erx_xhci_slot_context_free_t
configure_slot(const erx_trb_form_t *form, const erx_trb_command_t *command)
{
	const erx_xhci_slot_context_free_t *const hub = &command->slot_context;
	erx_xhci_slot_context_free_t slot = form->addressed[command->slot];
	const bool high_speed = slot.route_speed == ERX_XHCI_SPEED_HIGH;

	slot.route_hub = hub->route_hub;
	slot.ports_port_count = hub->ports_port_count;
	if (high_speed) {
		slot.route_multi_tt = hub->route_multi_tt;
		slot.tt_tt_think_time = hub->tt_tt_think_time;
	}
	if (SEED_CONFIGURE_SPEED_ZEROED)
		slot.route_speed = 0;
	return (slot);
}

/*
 * The input context's stated parameters of a command that carries it, for the sequencer: the slot
 * context, Configure Endpoint's with its slot's addressed fields, and each add's endpoint context,
 * or, for Evaluate Context, EP0's with its new packet.
 */
static void
contexts_of(const erx_trb_form_t *form, const erx_trb_command_t *command, erx_device_trb_contexts_t *contexts)
{
	switch (command->kind) {
	case ERX_TRB_COMMAND_EVALUATE_CONTEXT:
		*contexts = (erx_device_trb_contexts_t){ .endpoint_count = 1, .endpoints = { { .dci = 1, .context = {
		    .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL, .config_max_packet = command->ep0_packet } } } };
		return;
	case ERX_TRB_COMMAND_CONFIGURE_ENDPOINT:
		*contexts = (erx_device_trb_contexts_t){ .slot_context = configure_slot(form, command) };
		break;
	default:
		*contexts = (erx_device_trb_contexts_t){ .slot_context = command->slot_context };
		break;
	}
	contexts->endpoint_count = command->add_count;
	for (uint32_t k = 0; k < command->add_count; k++)
		contexts->endpoints[k] = (erx_device_trb_context_endpoint_t){ .dci = command->adds[k].dci,
		    .context = command->adds[k].context };
}

erx_device_trb_verdict_t
erx_trb_form_command(erx_trb_form_t *form, const erx_trb_command_t *command, uint64_t tag, erx_dma_sequence_t *sequence)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	const uint32_t command_pool = erx_device_trb_block_count(&form->shape);
	erx_dma_description_t record = { .structure = ERX_STRUCTURE_XHCI_COMMAND_RING };
	erx_dma_publication_t publication = { .records = &record, .record_count = 1, .call = ERX_DMA_PUBLISH_RUN,
	    .reach = { .group = command->slot, .index = command->dci, .drops = command->drops } };
	erx_device_trb_contexts_t contexts;

	if ((uint32_t)command->kind >= ERX_TRB_COMMAND_KINDS || command->add_count > ERX_DMA_BINDS_MAX ||
	    !parameters_valid(form, command))
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	record.meaning = command_meanings[command->kind];
	if (erx_dma_carries_input_context(record.meaning)) {
		contexts_of(form, command, &contexts);
		publication.contexts = &contexts;
		record.name_count = 1;
		record.names[0] = (erx_dma_name_t){ .buffer = pool_first_buffer(layout, command_pool), .offset = 0 };
	}
	publication.bind_count = command->add_count;
	for (uint32_t k = 0; k < command->add_count; k++) {
		publication.binds[k] = (erx_dma_binding_t){ .endpoint = erx_trb_form_endpoint(command->slot,
		    command->adds[k].dci), .table = command->adds[k].block };
	}
	switch (erx_dma_publish(&form->ledger, &publication, sequence)) {
	case ERX_DMA_PASSES:
		form->command = *command;
		form->command_tag = tag;
		form->stop_event = false;
		return (ERX_DEVICE_TRB_ACCEPTED);
	case ERX_DMA_BREAKS_ROOM:
	case ERX_DMA_BREAKS_HELD:
		return (ERX_DEVICE_TRB_REFUSE_FULL);
	case ERX_DMA_BREAKS_REACH:
		/* A command the queue's state does not accept is badarg (design-usb.md's queue table). */
	default:
		return (ERX_DEVICE_TRB_REFUSE_BADARG);
	}
}

bool
erx_trb_form_tag(const erx_trb_form_t *form, erx_dma_found_t found, uint64_t *tag)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	erx_dma_place_t head;

	if (!erx_dma_ledger_found_live(&form->ledger, found))
		return (false);
	/* A transfer ring is table b of block b, and its positions number fewer than the tags keep. */
	head = found.holding->records[0];
	if (!erx_structure_needs_binding(layout->tables[head.table].structure))
		return (false);
	*tag = form->transfers[head.table][head.index].tag;
	return (true);
}

/* The event ring: the layout's one table of its structure, which needs no binding. */
static uint32_t
event_ring(const erx_trb_form_t *form)
{
	return ((uint32_t)erx_dma_ledger_table(&form->ledger, ERX_STRUCTURE_XHCI_EVENT_RING));
}

erx_dma_range_t
erx_trb_form_validity_word(const erx_trb_form_t *form, uint32_t k)
{
	return (erx_dma_validity_word(&form->ledger, event_ring(form), k));
}

int
erx_trb_form_acquire(erx_trb_form_t *form, const uint32_t *words, uint32_t word_count, uint32_t *count)
{
	if (form->broken)
		return (ERX_ECORRUPT);
	if (!erx_dma_acquire_cycles(&form->ledger, event_ring(form), words, word_count, count)) {
		form->broken = true;
		return (ERX_ECORRUPT);
	}
	return (ERX_OK);
}

erx_dma_range_t
erx_trb_form_event(const erx_trb_form_t *form, uint32_t k)
{
	return (erx_dma_acquire_record(&form->ledger, event_ring(form), k));
}

/* The endpoint a transfer event names by its slot and dci, or 0. */
static uint32_t
event_endpoint(const erx_report_record_t *event)
{
	return (erx_trb_form_endpoint(erx_xhci_trb_transfer_event_control_slot_get(event->xhci_trb_transfer_event.control),
	    erx_xhci_trb_transfer_event_control_endpoint_get(event->xhci_trb_transfer_event.control)));
}

/* Whether ring `table` is bound to the endpoint a transfer event names. */
static bool
bound_to_event(const erx_trb_form_t *form, uint32_t table, const erx_report_record_t *event)
{
	const uint32_t endpoint = event_endpoint(event);

	return (SEED_ANY_ENDPOINT || (endpoint != 0 && erx_dma_ledger_binding(&form->ledger, table) == endpoint));
}

/*
 * Whether `found`, a live holding on ring `table`, is the ring's oldest, the TD the controller
 * runs first (docs/design-usb.md, "Completing").
 */
static bool
oldest_on_ring(const erx_trb_form_t *form, uint32_t table, erx_dma_found_t found)
{
	return (SEED_ANY_TRANSFER || erx_dma_ledger_oldest_on(&form->ledger, table).holding == found.holding);
}

/*
 * A short packet on a control transfer's data stage, at `place`: the TRB just before the head of
 * its ring's oldest live transfer, which has a data stage, skipping no link, since a link is never
 * the data stage; the first such event for it, its residue inside the stage's length. Passed,
 * ending nothing; the bytes the stage moved are kept for the status stage's event.
 */
static bool
short_data_stage(erx_trb_form_t *form, const erx_report_record_t *event, erx_dma_place_t place)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	const uint32_t link = layout->tables[place.table].count - 1u;
	const uint32_t residue = erx_xhci_trb_transfer_event_status_residue_get(event->xhci_trb_transfer_event.status);
	erx_dma_place_t head = { place.table, place.index + 1u == link ? 0 : place.index + 1u };
	erx_dma_found_t found;
	erx_trb_transfer_t *transfer;

	if (place.index == link || (found = erx_dma_ledger_holding(&form->ledger, head)).holding == NULL ||
	    !oldest_on_ring(form, place.table, found))
		return (false);
	transfer = &form->transfers[head.table][head.index];
	if (!transfer->data_stage || transfer->short_data || transfer->halted || residue > transfer->length ||
	    !bound_to_event(form, place.table, event) || !erx_dma_pass(&form->ledger, event_ring(form), event))
		return (false);
	transfer->short_data = true;
	transfer->moved = transfer->length - residue;
	return (true);
}

/* Whether `place` is one of the records `holding` holds: a TRB of its TD, or a link it reached. */
static bool
holds_record(const erx_dma_holding_t *holding, erx_dma_place_t place)
{
	for (uint32_t k = 0; k < holding->record_count; k++) {
		if (holding->records[k].table == place.table && holding->records[k].index == place.index)
			return (true);
	}
	return (false);
}

/*
 * An error code on a TRB of the oldest live transfer on a ring bound to the event's endpoint, not
 * answered yet: the endpoint halts, and the transfer is answered with the code and no bytes, its
 * holding kept (xHCI 1.2, 4.10.2).
 */
static bool
error_event(erx_trb_form_t *form, const erx_report_record_t *event, uint32_t code, erx_trb_answer_t *answer)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	erx_dma_found_t oldest;
	erx_dma_place_t place, head;
	erx_trb_transfer_t *transfer;

	if (!erx_dma_layout_place(layout, ERX_STRUCTURE_XHCI_TRANSFER_RING, event->xhci_trb_transfer_event.pointer, &place) ||
	    (oldest = erx_dma_ledger_oldest_on(&form->ledger, place.table)).holding == NULL ||
	    !holds_record(oldest.holding, place) || !bound_to_event(form, place.table, event))
		return (false);
	/* The seed halts the newest transfer, an error event releasing the wrong holding. */
	head = (SEED_HALT_HEAD_OF_NEWEST ? erx_dma_ledger_newest(&form->ledger) : oldest).holding->records[0];
	transfer = &form->transfers[head.table][head.index];
	if (transfer->halted || !erx_dma_pass(&form->ledger, event_ring(form), event) ||
	    !erx_dma_ledger_halt(&form->ledger, place.table))
		return (false);
	transfer->halted = true;
	*answer = (erx_trb_answer_t){ .kind = ERX_TRB_ANSWER_TRANSFER, .code = code, .tag = transfer->tag };
	return (true);
}

/*
 * A stop's event: a record of the ring bound to the endpoint the Stop Endpoint in flight names,
 * the first for that stop. Passed; it completes nothing and its length is not read.
 */
static bool
stop_event(erx_trb_form_t *form, const erx_report_record_t *event)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	const uint32_t endpoint = event_endpoint(event);
	/* While the ledger has a live command, form->command is that command. */
	const bool stopping = erx_dma_ledger_command(&form->ledger).holding != NULL &&
	    form->command.kind == ERX_TRB_COMMAND_STOP_ENDPOINT &&
	    !form->stop_event && endpoint == erx_trb_form_endpoint(form->command.slot, form->command.dci);
	erx_dma_place_t place;

	/* The seed takes a stop's event with no Stop Endpoint in flight, or a second one. */
	if ((!stopping && !SEED_ANY_STOP) || endpoint == 0 ||
	    !erx_dma_layout_place(layout, ERX_STRUCTURE_XHCI_TRANSFER_RING, event->xhci_trb_transfer_event.pointer, &place) ||
	    erx_dma_ledger_binding(&form->ledger, place.table) != endpoint ||
	    !erx_dma_pass(&form->ledger, event_ring(form), event))
		return (false);
	form->stop_event = true;
	return (true);
}

static bool
stop_code(uint32_t code)
{
	return (code == ERX_XHCI_COMPLETION_STOPPED || code == ERX_XHCI_COMPLETION_STOPPED_LENGTH_INVALID ||
	    code == ERX_XHCI_COMPLETION_STOPPED_SHORT_PACKET);
}

/*
 * A transfer event: the end of the transfer whose head it names, a short data stage, an error or
 * a stop's event, as the header says; *answered whether it answers. False for any other.
 */
static bool
transfer_event(erx_trb_form_t *form, const erx_report_record_t *event, erx_trb_answer_t *answer, bool *answered)
{
	const erx_xhci_trb_transfer_event_t *const record = &event->xhci_trb_transfer_event;
	const uint32_t code = erx_xhci_trb_transfer_event_status_code_get(record->status);
	const uint32_t residue = erx_xhci_trb_transfer_event_status_residue_get(record->status);
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	erx_dma_found_t found;
	erx_trb_transfer_t transfer;
	erx_dma_place_t place;
	uint32_t moved;

	*answered = false;
	if (erx_xhci_trb_transfer_event_control_event_data_get(record->control) != 0)
		return (false);
	if (stop_code(code))
		return (stop_event(form, event));
	if (code != ERX_XHCI_COMPLETION_SUCCESS && code != ERX_XHCI_COMPLETION_SHORT_PACKET)
		return (*answered = error_event(form, event, code, answer));
	found = erx_dma_report_holding(&form->ledger, event_ring(form), event);
	if (found.holding == NULL) {
		return (code == ERX_XHCI_COMPLETION_SHORT_PACKET &&
		    erx_dma_layout_place(layout, ERX_STRUCTURE_XHCI_TRANSFER_RING, record->pointer, &place) &&
		    short_data_stage(form, event, place));
	}
	place = found.holding->records[0];
	transfer = form->transfers[place.table][place.index];
	/* A control transfer's last TRB is its status stage, which moves nothing: its residue is 0. */
	if (!bound_to_event(form, place.table, event) || !oldest_on_ring(form, place.table, found) || transfer.halted ||
	    residue > (transfer.data_stage || !transfer.names_buffer ? 0 : transfer.length))
		return (false);
	moved = transfer.short_data ? transfer.moved : transfer.length - residue;
	if (!erx_dma_consume(&form->ledger, event_ring(form), found))
		return (false);
	*answer = (erx_trb_answer_t){ .kind = ERX_TRB_ANSWER_TRANSFER, .code = code, .tag = transfer.tag };
	if (transfer.names_buffer)
		answer->data = (erx_dma_range_t){ erx_dma_layout_buffer_offset(layout, transfer.buffer, 0), moved };
	*answered = true;
	return (true);
}

/*
 * A command completion naming the live command: its holding ends on every code, and its reach
 * acts on success, or its own bindings end on failure, as erx_dma_ledger_complete_command says.
 * Its answers: the command's, then each transfer its success retires that no error answered
 * already, `stopped` with no bytes under its own tag; their count goes to *answered.
 */
static bool
command_event(erx_trb_form_t *form, const erx_report_record_t *event, erx_trb_answer_t *answers, uint32_t *answered)
{
	const erx_xhci_trb_command_event_t *const record = &event->xhci_trb_command_event;
	const uint32_t code = erx_xhci_trb_command_event_status_code_get(record->status);
	const uint32_t slot = erx_xhci_trb_command_event_control_slot_get(record->control);
	const erx_dma_found_t found = erx_dma_report_holding(&form->ledger, event_ring(form), event);
	erx_dma_place_t retired[ERX_DMA_HOLDINGS_MAX];
	uint32_t retired_count;

	if (found.holding == NULL || !erx_dma_ledger_complete_command(&form->ledger, event_ring(form), found,
	    code == ERX_XHCI_COMPLETION_SUCCESS, retired, &retired_count))
		return (false);
	/*
	 * The slot's state: an Enable Slot's success enables the slot its completion names, one of the
	 * layout's (4.6.3, p. 108); an Address Device's writes its addressed fields; a Disable Slot's
	 * clears both.
	 */
	if (code == ERX_XHCI_COMPLETION_SUCCESS && form->command.kind == ERX_TRB_COMMAND_ENABLE_SLOT && slot >= 1 &&
	    slot <= form->slots)
		form->enabled[slot] = true;
	else if (code == ERX_XHCI_COMPLETION_SUCCESS && form->command.kind == ERX_TRB_COMMAND_ADDRESS_DEVICE)
		form->addressed[form->command.slot] = form->command.slot_context;
	else if (code == ERX_XHCI_COMPLETION_SUCCESS && form->command.kind == ERX_TRB_COMMAND_DISABLE_SLOT) {
		form->enabled[form->command.slot] = false;
		bzero(&form->addressed[form->command.slot], sizeof(form->addressed[form->command.slot]));
	}
	answers[0] = (erx_trb_answer_t){ .kind = ERX_TRB_ANSWER_COMMAND, .code = code, .tag = form->command_tag,
	    .parameter = erx_xhci_trb_command_event_status_parameter_get(record->status),
	    .slot = slot };
	*answered = 1;
	/* A retired holding is a transfer's, its head on a transfer ring, table b of block b. */
	for (uint32_t k = 0; k < retired_count; k++) {
		const erx_trb_transfer_t *const transfer = &form->transfers[retired[k].table][retired[k].index];

		if (!transfer->halted || SEED_ANSWER_HALTED)
			answers[(*answered)++] = (erx_trb_answer_t){ .kind = ERX_TRB_ANSWER_TRANSFER,
			    .code = ERX_XHCI_COMPLETION_STOPPED, .tag = transfer->tag };
	}
	return (true);
}

/* One acquired event, as the header says, its answers into `answers`, their count into *answered. False breaks the form. */
static bool
consume_event(erx_trb_form_t *form, const erx_report_record_t *event, erx_trb_answer_t *answers, uint32_t *answered)
{
	uint32_t meaning;
	bool answers_it;

	*answered = 0;
	if (!erx_report_meaning(ERX_STRUCTURE_XHCI_EVENT_RING, event, &meaning))
		return (false);
	switch (meaning) {
	case ERX_MEANING_XHCI_TRB_TRANSFER_EVENT:
		if (!transfer_event(form, event, &answers[0], &answers_it))
			return (false);
		*answered = answers_it;
		return (true);
	case ERX_MEANING_XHCI_TRB_COMMAND_EVENT:
		return (command_event(form, event, answers, answered));
	case ERX_MEANING_XHCI_TRB_PORT_EVENT:
		if (!erx_dma_pass(&form->ledger, event_ring(form), event))
			return (false);
		answers[0] = (erx_trb_answer_t){ .kind = ERX_TRB_ANSWER_PORT,
		    .code = erx_xhci_trb_port_event_status_code_get(event->xhci_trb_port_event.status),
		    .port = erx_xhci_trb_port_event_parameter_port_get(event->xhci_trb_port_event.parameter) };
		*answered = 1;
		return (true);
	default:
		return (false);
	}
}

int
erx_trb_form_complete(erx_trb_form_t *form, const erx_report_record_t *events, uint32_t count,
    erx_trb_answer_t *answers, uint32_t *answered, uint64_t *dequeue)
{
	const uint32_t ring = event_ring(form);
	uint32_t answer_count;

	*answered = 0;
	*dequeue = erx_dma_dequeue_address(&form->ledger, ring);
	if (form->broken)
		return (ERX_ECORRUPT);
	for (uint32_t k = 0; k < count && erx_dma_ledger_acquired(&form->ledger, ring) > 0; k++) {
		if (!consume_event(form, &events[k], &answers[*answered], &answer_count)) {
			form->broken = true;
			break;
		}
		*answered += answer_count;
	}
	if (!SEED_DEQUEUE_STALE)
		*dequeue = erx_dma_dequeue_address(&form->ledger, ring);
	return (*answered == 0 && form->broken ? ERX_ECORRUPT : ERX_OK);
}

int
erx_trb_form_install(const erx_trb_form_t *form, bool reaches_64_bits, erx_dma_sequence_t *sequence)
{
	const erx_device_trb_layout_t *const layout = &form->layout;

	if (form->broken)
		return (ERX_ECORRUPT);
	if (!reaches_64_bits && (layout->device_base > UINT32_MAX || layout->bytes > (UINT64_C(1) << 32) - layout->device_base))
		return (ERX_ERANGE);
	switch (erx_dma_install_controller(&form->ledger, layout, sequence)) {
	case ERX_DMA_PASSES:
		return (ERX_OK);
	case ERX_DMA_BREAKS_CALLS:
		return (ERX_EBUSY);
	default:
		return (ERX_EINVAL);
	}
}

void
erx_trb_form_reset(erx_trb_form_t *form)
{
	erx_dma_ledger_reset(&form->ledger);
	bzero(form->enabled, sizeof(form->enabled));
	bzero(form->addressed, sizeof(form->addressed));
	bzero(form->transfers, sizeof(form->transfers));
	bzero(&form->command, sizeof(form->command));
	form->command_tag = 0;
	form->stop_event = false;
	form->broken = false;
}
