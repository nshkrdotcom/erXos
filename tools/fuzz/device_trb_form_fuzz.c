/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The TRB form's event ring processing (otp/erts/emulator/nifs/erxos/erx_device_trb_form.h) over
 * the sequencer, against a hostile controller writing any event TRBs. The form is a small one: a
 * control block of one buffer and two bulk blocks of two, each ring bound by Address Device or
 * Configure Endpoint. The input is a script of operations, each an opcode byte and its operands:
 *
 *   0  post: a byte, the transfer (mod 4: a control transfer with an IN data stage, one with none,
 *      a bulk IN, a bulk OUT)
 *   1  events: a count byte (mod 33), then per event a byte whose bit 0 makes it honest and whose
 *      bit 3 writes it with the stale cycle. Honest with bit 4: the completion of the command in
 *      flight, Success or, with bit 1, a Context State Error. Honest without: the event of a
 *      posted transfer picked by a u8, its code Success, Short Packet, Stall or Stopped by bits
 *      1-2, its residue a u8, the pointer at its head or, with bit 5, at the TRB before it. Raw:
 *      any u64 parameter, u32 status and u32 control
 *   2  reset
 *   3  command: a kind byte (mod the kinds), a slot byte (SLOT for an even one), a dci byte (mod
 *      32), a u32 drop mask, an add count byte (mod 3) and per add a dci byte (mod 32) and a block
 *      byte (mod 4)
 *
 * The harness keeps its own record of every transfer posted, by its tag, and checks after each
 * step: a transfer answer names a transfer posted and not answered yet, with its tag, and bytes
 * inside its buffer from the buffer's first, or, for an error, no bytes and its holding kept; a
 * command answer gives the command's tag; a holding ends without its own answer only in a batch
 * with a command's successful completion; every live transfer lies on a bound ring; the live
 * holdings are the transfers posted and not ended and the command in flight; the dequeue pointer
 * is a record of the event ring; nothing is consumed past the acquisition, and a broken form refuses
 * every call until its reset.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_trb_form.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define FUZZ_BASE	UINT64_C(0x40000000)
#define EVENTS_MAX	33u
#define SHADOW_MAX	64u
#define SLOT		1u

typedef struct shadow {
	bool		live;
	bool		halted;		/* answered with an error: its holding waits for a command */
	uint64_t	tag;
	uint32_t	block;
	uint32_t	head;		/* the TD's last TRB: the newest holding's head */
	uint64_t	buffer_offset;	/* the first byte of its buffer, or UINT64_MAX for none */
	uint32_t	buffer_size;
} shadow_t;

typedef struct script {
	const uint8_t	*bytes;
	size_t		left;
} script_t;

static const erx_device_trb_shape_t shape = {
	.ring_trbs = 6, .blocks = { 1, 0, 2 }, .buffers = { 1, 0, 2 }, .buffer_size = { 64, 0, 64 },
};
static const erx_device_trb_controller_t controller = {
	.slots = 2, .ports = 1, .scratchpads = 0, .context_size = 32, .doorbells = 0,
};
static const uint32_t block_dci[3] = { 1, 3, 2 };
static const erx_dma_regions_t no_regions;
static const uint8_t out_bytes[64];
static erx_device_trb_layout_t trb;
static erx_trb_form_t form;
static shadow_t shadow[SHADOW_MAX];
static uint64_t next_tag;
static bool command_live;
static uint64_t command_tag;
static uint32_t command_head;

static void
check(bool condition)
{
	if (!condition)
		abort();
}

static uint64_t
take(script_t *script, size_t bytes)
{
	uint64_t value = 0;

	for (size_t index = 0; index < bytes && script->left > 0; index++, script->left--)
		value |= (uint64_t)*script->bytes++ << (8u * index);
	return (value);
}

static uint32_t
live_transfers(void)
{
	uint32_t live = 0;

	for (uint32_t index = 0; index < SHADOW_MAX; index++)
		live += shadow[index].live;
	return (live);
}

/* Posts `command` and consumes its success, its completion naming the slot, through the form. */
static void
run_command(const erx_trb_command_t *command)
{
	const uint32_t head = erx_dma_ledger_position(&form.ledger, 3).index;
	erx_report_record_t event = { .xhci_trb_transfer_event = {
	    .pointer = FUZZ_BASE + trb.regions[trb.command_ring].offset + 16u * head,
	    .status = (uint32_t)ERX_XHCI_COMPLETION_SUCCESS << 24,
	    .control = SLOT << 24 | (uint32_t)ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT << 10 |
	    erx_dma_ledger_cycle(&form.ledger, 4) } };
	uint32_t word = event.xhci_trb_transfer_event.control, count, answered;
	erx_trb_answer_t answers[ERX_TRB_FORM_ANSWERS_MAX(1)];
	erx_dma_sequence_t sequence;
	uint64_t dequeue;

	check(erx_trb_form_command(&form, command, 0, &sequence) == ERX_DEVICE_TRB_ACCEPTED);
	check(erx_trb_form_acquire(&form, &word, 1, &count) == ERX_OK && count == 1 &&
	    erx_trb_form_complete(&form, &event, 1, answers, &answered, &dequeue) == ERX_OK && answered == 1);
}

/* Enables the slot, then binds each block's ring. */
static void
bind_all(void)
{
	run_command(&(erx_trb_command_t){ .kind = ERX_TRB_COMMAND_ENABLE_SLOT });
	for (uint32_t block = 0; block < 3; block++) {
		const bool ep0 = block_dci[block] == 1;
		/* EP0 of 64 bytes on a high-speed device at port 1, or a bulk endpoint of 64-byte packets. */
		const erx_trb_command_t bind = { .kind = ep0 ? ERX_TRB_COMMAND_ADDRESS_DEVICE : ERX_TRB_COMMAND_CONFIGURE_ENDPOINT,
		    .slot = SLOT, .add_count = 1, .adds = { { block_dci[block], block, { .config_max_packet = 64,
		    .config_endpoint_type = ep0 ? ERX_XHCI_ENDPOINT_TYPE_CONTROL : (block_dci[block] & 1u) != 0 ?
		    ERX_XHCI_ENDPOINT_TYPE_BULK_IN : ERX_XHCI_ENDPOINT_TYPE_BULK_OUT, .payload_max_esit_payload = ep0 ? 0u : 64u } } },
		    .slot_context = { .route_speed = ep0 ? ERX_XHCI_SPEED_HIGH : 0u, .ports_root_port = ep0 ? 1u : 0u } };

		run_command(&bind);
	}
	memset(shadow, 0, sizeof(shadow));
	command_live = false;
}

/* A packet size from the script: the edges of the endpoint context's ranges, or any 16 bits. */
static uint64_t
packet_of(script_t *script)
{
	static const uint64_t edges[] = { 0, 1, 2, 8, 32, 64, 512, 1024, 1025, 0xffff };
	const uint64_t pick = take(script, 1);

	return (pick < 160 ? edges[pick % (sizeof(edges) / sizeof(edges[0]))] : take(script, 2));
}

/* The stated parameters of a command from the script, each a little past its range at most, so most are refused. */
static void
parameters(script_t *script, erx_trb_command_t *made)
{
	made->slot_context = (erx_xhci_slot_context_free_t){ .route_route_string = take(script, 1) % 4u == 0 ?
	    take(script, 3) : take(script, 1) % 16u, .route_speed = take(script, 1) % 6u,
	    .route_multi_tt = take(script, 1) % 3u, .route_hub = take(script, 1) % 3u,
	    .ports_root_port = take(script, 1) % 3u, .ports_port_count = take(script, 1) % 17u,
	    .tt_tt_slot = take(script, 1) % 4u, .tt_tt_port = take(script, 1) % 17u, .tt_tt_think_time = take(script, 1) % 5u };
	made->ep0_packet = (uint32_t)packet_of(script);
	for (uint32_t k = 0; k < made->add_count; k++) {
		erx_xhci_endpoint_context_free_t *const context = &made->adds[k].context;

		context->config_endpoint_type = take(script, 1) % 8u;
		context->config_max_packet = packet_of(script);
		context->config_max_burst = take(script, 1) % 17u;
		context->info_interval = take(script, 1) % 17u;
		context->payload_max_esit_payload = take(script, 1) % 2u == 0 ?
		    context->config_max_packet * (context->config_max_burst + 1u) : take(script, 2);
	}
}

/*
 * What an accepted command carrying the input context wrote there, decoded by xHCI 1.2's bit
 * positions (6.2.2, 6.2.3, 6.2.5.1): every store inside the input context, no add flag past the
 * contexts written nor A1 on Configure Endpoint, and each field within its parameter's range.
 */
static void
check_contexts(const erx_trb_command_t *made, const erx_dma_sequence_t *sequence)
{
	const erx_device_trb_region_t *const region = &trb.regions[trb.input_context];
	const uint64_t bytes = (1u + ERX_XHCI_DEVICE_CONTEXTS) * trb.context_size;

	for (uint32_t k = 0; k < sequence->store_count; k++) {
		const erx_dma_store_t *const store = &sequence->stores[k];
		uint32_t word[4];
		uint64_t context;

		if (store->offset < region->offset || store->offset >= region->offset + region->length)
			continue;
		check(store->offset + store->length <= region->offset + bytes && store->length >= sizeof(word));
		context = (store->offset - region->offset) / trb.context_size;
		memcpy(word, store->bytes, sizeof(word));
		if (context == 0)
			check((word[0] & 3u) == 0 && (made->kind != ERX_TRB_COMMAND_CONFIGURE_ENDPOINT || (word[1] & 2u) == 0));
		else if (context == 1)
			check(word[0] >> 27 >= 1 && (word[0] >> 20 & 0xfu) <= ERX_XHCI_SPEED_SUPER &&
			    (word[1] >> 16 & 0xffu) <= trb.ports && (word[1] >> 24) <= ERX_USB_HUB_PORTS_MAX &&
			    (word[2] & 0xffu) <= trb.slots && (word[2] >> 8 & 0xffu) <= ERX_USB_HUB_PORTS_MAX);
		else
			check((word[0] >> 16 & 0xffu) <= 15u && (word[1] >> 1 & 3u) == 3u && (word[1] >> 8 & 0xffu) <= 15u &&
			    (word[1] >> 16) >= 1u && (word[1] >> 16) <= 1024u && (word[1] >> 3 & 7u) != 0 &&
			    (word[1] >> 3 & 7u) != ERX_XHCI_ENDPOINT_TYPE_ISOCH_OUT &&
			    (word[1] >> 3 & 7u) != ERX_XHCI_ENDPOINT_TYPE_ISOCH_IN);
	}
}

/* A command from the script, with stated parameters near their ranges, posted when the form accepts it. */
static void
command(script_t *script)
{
	erx_trb_command_t made = { .kind = (erx_trb_command_kind_t)(take(script, 1) % ERX_TRB_COMMAND_KINDS) };
	const uint32_t slot = (uint32_t)take(script, 1);
	erx_dma_sequence_t sequence;
	uint32_t head;

	made.slot = (slot & 1u) == 0 ? SLOT : slot;
	made.dci = (uint32_t)(take(script, 1) % 32u);
	/* Configure Endpoint drops; on another kind one script byte in eight plants drops, a refusal. */
	made.drops = made.kind == ERX_TRB_COMMAND_CONFIGURE_ENDPOINT || take(script, 1) % 8u == 0 ?
	    (uint32_t)take(script, 4) : 0;
	made.add_count = (uint32_t)(take(script, 1) % 3u);
	for (uint32_t k = 0; k < made.add_count; k++) {
		made.adds[k].dci = (uint32_t)(take(script, 1) % 32u);
		made.adds[k].block = (uint32_t)(take(script, 1) % 4u);
	}
	parameters(script, &made);
	head = erx_dma_ledger_position(&form.ledger, 3).index;
	if (erx_trb_form_command(&form, &made, next_tag, &sequence) != ERX_DEVICE_TRB_ACCEPTED)
		return;
	check(!command_live);
	check_contexts(&made, &sequence);
	command_live = true;
	command_tag = next_tag++;
	command_head = head;
}

static void
post(script_t *script)
{
	const uint32_t kind = (uint32_t)(take(script, 1) % 4);
	static const uint8_t get_descriptor[8] = { 0x80, 6, 0, 1, 0, 0, 8, 0 };
	erx_device_trb_request_t request = { .control = kind < 2, .data = kind == 0, .device_writes = kind != 3,
	    .length = kind == 0 ? 8 : kind == 1 ? 0 : 64, .bytes = kind == 3 ? out_bytes : NULL };
	const uint32_t block = kind < 2 ? 0 : kind == 2 ? 1 : 2;
	erx_dma_sequence_t sequence;
	erx_dma_found_t found;
	uint32_t slot = 0;

	memcpy(request.setup, get_descriptor, sizeof(request.setup));
	while (slot < SHADOW_MAX && shadow[slot].live)
		slot++;
	if (slot == SHADOW_MAX ||
	    erx_trb_form_post(&form, SLOT, block_dci[block], &request, next_tag, &sequence) != ERX_DEVICE_TRB_ACCEPTED)
		return;
	found = erx_dma_ledger_newest(&form.ledger);
	shadow[slot] = (shadow_t){ .live = true, .tag = next_tag++, .block = block,
	    .head = found.holding->records[0].index, .buffer_offset = UINT64_MAX };
	if (found.holding->buffer_count == 1) {
		shadow[slot].buffer_offset = erx_dma_layout_buffer_offset(&form.ledger.layout, found.holding->buffers[0], 0);
		shadow[slot].buffer_size = 64;
	}
}

static erx_report_record_t
event(script_t *script, uint32_t *word, uint32_t index)
{
	const uint32_t mode = (uint32_t)take(script, 1);
	const uint32_t ring = (uint32_t)erx_dma_ledger_table(&form.ledger, ERX_STRUCTURE_XHCI_EVENT_RING);
	const uint32_t at = erx_dma_ledger_position(&form.ledger, ring).index + index;
	uint32_t cycle = erx_dma_ledger_cycle(&form.ledger, ring) ^ (at >= ERX_DEVICE_TRB_EVENT_TRBS);
	erx_report_record_t made = { 0 };

	if ((mode & 0x11u) == 0x11u) {
		made.xhci_trb_transfer_event = (erx_xhci_trb_transfer_event_t){
		    .pointer = FUZZ_BASE + trb.regions[trb.command_ring].offset + 16u * command_head,
		    .status = (uint32_t)((mode & 2u) ? ERX_XHCI_COMPLETION_CONTEXT_STATE_ERROR : ERX_XHCI_COMPLETION_SUCCESS) << 24,
		    .control = (uint32_t)ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT << 10 };
	} else if (mode & 1u) {
		static const uint32_t codes[4] = { ERX_XHCI_COMPLETION_SUCCESS, ERX_XHCI_COMPLETION_SHORT_PACKET,
		    ERX_XHCI_COMPLETION_STALL, ERX_XHCI_COMPLETION_STOPPED };
		const shadow_t *const transfer = &shadow[take(script, 1) % SHADOW_MAX];
		const uint32_t residue = (uint32_t)take(script, 1);
		const uint32_t head = (mode & 0x20u) && transfer->head != 0 ? transfer->head - 1u : transfer->head;

		made.xhci_trb_transfer_event = (erx_xhci_trb_transfer_event_t){
		    .pointer = FUZZ_BASE + erx_device_trb_position_offset(&trb, transfer->block, head),
		    .status = codes[mode >> 1 & 3u] << 24 | residue, .control = SLOT << 24 | block_dci[transfer->block] << 16 |
		    (uint32_t)ERX_XHCI_TRB_TYPE_TRANSFER_EVENT << 10 };
	} else {
		made.xhci_trb_transfer_event.pointer = take(script, 8);
		made.xhci_trb_transfer_event.status = (uint32_t)take(script, 4);
		made.xhci_trb_transfer_event.control = (uint32_t)take(script, 4) & ~1u;
	}
	if (mode & 8u)
		cycle ^= 1u;
	made.xhci_trb_transfer_event.control |= cycle;
	*word = made.xhci_trb_transfer_event.control;
	return (made);
}

/*
 * One answer, against the record; whether it is a command's success. A transfer answered `stopped`
 * was retired by the command answered after it, and its holding is gone; one an error answered is
 * never answered again.
 */
static bool
check_answer(const erx_trb_answer_t *answer)
{
	const bool error = answer->code != ERX_XHCI_COMPLETION_SUCCESS && answer->code != ERX_XHCI_COMPLETION_SHORT_PACKET;

	if (answer->kind == ERX_TRB_ANSWER_COMMAND) {
		check(command_live && answer->tag == command_tag);
		command_live = false;
		return (answer->code == ERX_XHCI_COMPLETION_SUCCESS);
	}
	if (answer->kind != ERX_TRB_ANSWER_TRANSFER)
		return (false);
	for (uint32_t index = 0; index < SHADOW_MAX; index++) {
		shadow_t *const transfer = &shadow[index];

		if (!transfer->live || transfer->halted || transfer->tag != answer->tag)
			continue;
		if (answer->code == ERX_XHCI_COMPLETION_STOPPED) {
			check(answer->data.length == 0 && erx_dma_ledger_holding(&form.ledger,
			    (erx_dma_place_t){ transfer->block, transfer->head }).holding == NULL);
			transfer->live = false;
			return (false);
		}
		check(error || transfer->buffer_offset == UINT64_MAX ? answer->data.length == 0 :
		    answer->data.offset == transfer->buffer_offset && answer->data.length <= transfer->buffer_size);
		transfer->halted = error;
		transfer->live = error;
		return (false);
	}
	check(false);
	return (false);
}

static void
events(script_t *script)
{
	const uint32_t count = (uint32_t)(take(script, 1) % EVENTS_MAX);
	const uint32_t ring = (uint32_t)erx_dma_ledger_table(&form.ledger, ERX_STRUCTURE_XHCI_EVENT_RING);
	const erx_dma_table_t *const table = &form.ledger.layout.tables[ring];
	erx_report_record_t made[EVENTS_MAX];
	erx_trb_answer_t answers[ERX_TRB_FORM_ANSWERS_MAX(EVENTS_MAX)];
	uint32_t words[EVENTS_MAX], acquired = 0, answered = 0;
	const bool broken = form.broken;
	bool succeeded = false;
	uint64_t dequeue;
	int status;

	for (uint32_t k = 0; k < count; k++)
		made[k] = event(script, &words[k], k);
	status = erx_trb_form_acquire(&form, words, count, &acquired);
	check(broken ? status == ERX_ECORRUPT : status == ERX_OK && acquired <= count);
	status = erx_trb_form_complete(&form, made, acquired, answers, &answered, &dequeue);
	check(!broken || (status == ERX_ECORRUPT && answered == 0));
	check(answered <= ERX_TRB_FORM_ANSWERS_MAX(acquired) && dequeue >= FUZZ_BASE + table->first &&
	    dequeue < FUZZ_BASE + table->first + (uint64_t)table->count * table->stride &&
	    (dequeue - FUZZ_BASE - table->first) % table->stride == 0);
	for (uint32_t k = 0; k < answered; k++)
		succeeded = check_answer(&answers[k]) || succeeded;
	/*
	 * A holding gone with no answer in this call was retired by a command's success after an error
	 * answered it; none lies on an unbound ring.
	 */
	for (uint32_t index = 0; index < SHADOW_MAX; index++) {
		shadow_t *const transfer = &shadow[index];

		if (!transfer->live)
			continue;
		if (erx_dma_ledger_holding(&form.ledger, (erx_dma_place_t){ transfer->block, transfer->head }).holding == NULL) {
			check(succeeded && transfer->halted);
			transfer->live = false;
			continue;
		}
		check(erx_dma_ledger_binding(&form.ledger, transfer->block) != 0);
	}
	check(erx_dma_ledger_live(&form.ledger) == live_transfers() + (command_live ? 1u : 0));
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	script_t script = { .bytes = data, .left = size };

	check(erx_device_trb_layout(&trb, &shape, &controller, FUZZ_BASE, 64, UINT64_C(1) << 20) &&
	    erx_trb_form_make(&form, &trb, &no_regions));
	bind_all();
	next_tag = 1;
	while (script.left > 0) {
		switch (take(&script, 1) % 4) {
		case 0:
			post(&script);
			break;
		case 1:
			events(&script);
			break;
		case 2:
			erx_trb_form_reset(&form);
			bind_all();
			break;
		default:
			command(&script);
			break;
		}
	}
	return (0);
}
