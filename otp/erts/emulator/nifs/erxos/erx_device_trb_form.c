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
		form->tags[head.table][head.index] = tag;
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
	*tag = form->tags[head.table][head.index];
	return (true);
}
