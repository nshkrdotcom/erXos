/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's core: see erx_device_trb_form.h.
 *
 * The ERX_TRB_FORM_SEED_* macros plant the faults test/host/erx_device_trb_form_test.rb shows its
 * harness catches (docs/design-device-dma.md, Verification).
 */

#include <strings.h>

#include "erx_device_trb_form.h"

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

/* The form's device addresses: every address place of its TRBs and contexts is 64 bits wide. */
#define ADDRESS_BITS	64u

static uint32_t
block_count(const erx_device_trb_shape_t *shape)
{
	return (shape->blocks[ERX_DEVICE_TRB_CONTROL] + shape->blocks[ERX_DEVICE_TRB_INTERRUPT] +
	    shape->blocks[ERX_DEVICE_TRB_BULK]);
}

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
	const uint32_t blocks = block_count(&trb->shape);
	const uint32_t command_pool = blocks;

	if (trb->shape.ring_trbs > ERX_DEVICE_TRB_RING_TRBS)
		return (false);
	*layout = (erx_dma_layout_t){ .memory_size = trb->bytes, .device_base = trb->device_base,
	    .address_bits = ADDRESS_BITS, .granule = trb->granule, .table_count = blocks + 2u,
	    .pool_count = blocks + 1u };
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
	form->shape = trb->shape;
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
 * The TRBs of `request` over `buffer`, as erx_device_trb_post's transfer_words writes them, into
 * `records`, zeroed so the check sees no stale free value; their count.
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
		pool = (pool + 1u) % block_count(&form->shape);
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

/* Whether ring `table` is bound to the endpoint a transfer event names by its slot and dci. */
static bool
bound_to_event(const erx_trb_form_t *form, uint32_t table, uint32_t control)
{
	const uint32_t endpoint = erx_trb_form_endpoint(erx_xhci_trb_transfer_event_control_slot_get(control),
	    erx_xhci_trb_transfer_event_control_endpoint_get(control));

	return (SEED_ANY_ENDPOINT || (endpoint != 0 && erx_dma_ledger_binding(&form->ledger, table) == endpoint));
}

/*
 * A short packet on a control transfer's data stage, at `place`: the TRB just before the head of
 * a live transfer with a data stage on its ring, skipping no link, since a link is never the data
 * stage; the first such event for it, its residue inside the stage's length. Passed, ending
 * nothing; the bytes the stage moved are kept for the status stage's event.
 */
static bool
short_data_stage(erx_trb_form_t *form, const erx_report_record_t *event, erx_dma_place_t place)
{
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	const uint32_t link = layout->tables[place.table].count - 1u;
	const uint32_t residue = erx_xhci_trb_transfer_event_status_residue_get(event->xhci_trb_transfer_event.status);
	erx_dma_place_t head = { place.table, place.index + 1u == link ? 0 : place.index + 1u };
	erx_trb_transfer_t *transfer;

	if (place.index == link || erx_dma_ledger_holding(&form->ledger, head).holding == NULL)
		return (false);
	transfer = &form->transfers[head.table][head.index];
	if (!transfer->data_stage || transfer->short_data || residue > transfer->length ||
	    !bound_to_event(form, place.table, event->xhci_trb_transfer_event.control) ||
	    !erx_dma_pass(&form->ledger, event_ring(form), event))
		return (false);
	transfer->short_data = true;
	transfer->moved = transfer->length - residue;
	return (true);
}

/*
 * A transfer event: the end of the transfer whose head it names, or a short data stage, as the
 * header says; *answered whether it answers. False for any other.
 */
static bool
transfer_event(erx_trb_form_t *form, const erx_report_record_t *event, erx_trb_answer_t *answer, bool *answered)
{
	const erx_xhci_trb_transfer_event_t *const record = &event->xhci_trb_transfer_event;
	const uint32_t code = erx_xhci_trb_transfer_event_status_code_get(record->status);
	const uint32_t residue = erx_xhci_trb_transfer_event_status_residue_get(record->status);
	const erx_dma_found_t found = erx_dma_report_holding(&form->ledger, event_ring(form), event);
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	erx_trb_transfer_t transfer;
	erx_dma_place_t place;
	uint32_t moved;

	*answered = false;
	if (erx_xhci_trb_transfer_event_control_event_data_get(record->control) != 0 ||
	    (code != ERX_XHCI_COMPLETION_SUCCESS && code != ERX_XHCI_COMPLETION_SHORT_PACKET))
		return (false);
	if (found.holding == NULL) {
		return (code == ERX_XHCI_COMPLETION_SHORT_PACKET &&
		    erx_dma_layout_place(layout, ERX_STRUCTURE_XHCI_TRANSFER_RING, record->pointer, &place) &&
		    short_data_stage(form, event, place));
	}
	place = found.holding->records[0];
	transfer = form->transfers[place.table][place.index];
	/* A control transfer's last TRB is its status stage, which moves nothing: its residue is 0. */
	if (!bound_to_event(form, place.table, record->control) ||
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
 * A command completion naming the live command: its holding ends on every code, and a failing
 * command's binding with it. A failing binding command whose ring a transfer holds is refused
 * before anything ends: the reach rule keeps such a transfer from being posted.
 */
static bool
command_event(erx_trb_form_t *form, const erx_report_record_t *event, erx_trb_answer_t *answer)
{
	const erx_xhci_trb_command_event_t *const record = &event->xhci_trb_command_event;
	const uint32_t code = erx_xhci_trb_command_event_status_code_get(record->status);
	const erx_dma_found_t found = erx_dma_report_holding(&form->ledger, event_ring(form), event);
	const erx_dma_layout_t *const layout = erx_dma_ledger_layout(&form->ledger);
	erx_dma_binding_t ends = { 0 };

	if (found.holding == NULL)
		return (false);
	if (code != ERX_XHCI_COMPLETION_SUCCESS)
		ends = found.holding->binding;
	if ((ends.endpoint != 0 &&
	    erx_dma_ledger_free_records(&form->ledger, ends.table) != layout->tables[ends.table].count) ||
	    !erx_dma_consume(&form->ledger, event_ring(form), found) ||
	    (ends.endpoint != 0 && !erx_dma_ledger_unbind(&form->ledger, ends.table)))
		return (false);
	*answer = (erx_trb_answer_t){ .kind = ERX_TRB_ANSWER_COMMAND, .code = code,
	    .parameter = erx_xhci_trb_command_event_status_parameter_get(record->status),
	    .slot = erx_xhci_trb_command_event_control_slot_get(record->control) };
	return (true);
}

/* One acquired event, as the header says; *answered whether it answers. False breaks the form. */
static bool
consume_event(erx_trb_form_t *form, const erx_report_record_t *event, erx_trb_answer_t *answer, bool *answered)
{
	uint32_t meaning;

	*answered = false;
	if (!erx_report_meaning(ERX_STRUCTURE_XHCI_EVENT_RING, event, &meaning))
		return (false);
	switch (meaning) {
	case ERX_MEANING_XHCI_TRB_TRANSFER_EVENT:
		return (transfer_event(form, event, answer, answered));
	case ERX_MEANING_XHCI_TRB_COMMAND_EVENT:
		return (*answered = command_event(form, event, answer));
	case ERX_MEANING_XHCI_TRB_PORT_EVENT:
		if (!erx_dma_pass(&form->ledger, event_ring(form), event))
			return (false);
		*answer = (erx_trb_answer_t){ .kind = ERX_TRB_ANSWER_PORT,
		    .code = erx_xhci_trb_port_event_status_code_get(event->xhci_trb_port_event.status),
		    .port = erx_xhci_trb_port_event_parameter_port_get(event->xhci_trb_port_event.parameter) };
		return (*answered = true);
	default:
		return (false);
	}
}

int
erx_trb_form_complete(erx_trb_form_t *form, const erx_report_record_t *events, uint32_t count,
    erx_trb_answer_t *answers, uint32_t *answered, uint64_t *dequeue)
{
	const uint32_t ring = event_ring(form);
	bool answers_it;

	*answered = 0;
	*dequeue = erx_dma_dequeue_address(&form->ledger, ring);
	if (form->broken)
		return (ERX_ECORRUPT);
	for (uint32_t k = 0; k < count && erx_dma_ledger_acquired(&form->ledger, ring) > 0; k++) {
		if (!consume_event(form, &events[k], &answers[*answered], &answers_it)) {
			form->broken = true;
			break;
		}
		*answered += answers_it;
	}
	if (!SEED_DEQUEUE_STALE)
		*dequeue = erx_dma_dequeue_address(&form->ledger, ring);
	return (*answered == 0 && form->broken ? ERX_ECORRUPT : ERX_OK);
}

void
erx_trb_form_reset(erx_trb_form_t *form)
{
	erx_dma_ledger_reset(&form->ledger);
	bzero(form->transfers, sizeof(form->transfers));
	form->broken = false;
}
