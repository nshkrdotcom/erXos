/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's publication and long traces over the hosted model of a non-coherent cache
 * (test/host/erx_device_trb_form_model_test.rb; docs/design-usb.md, Verification, "Host tests of
 * the cores").
 *
 * The harness is the effect layer over the form's pure core (erx_device_trb_form.h): it applies
 * each sequence the form returns in erx_device_sequencer.h's order onto erx_dma_model, the CPU's
 * stores and loads through its cache and the maintenance on its lines, then rings the queue's
 * doorbell. The controller is erx_device_trb_model, which takes a TRB the moment its cycle bit
 * matches, doorbell or not, and may act after any effect: a TRB published before its bytes are
 * clean is taken with stale bytes, which the harness sees as an out buffer read wrong, an in
 * buffer overwritten, or a TRB or input context the controller refuses.
 *
 * Completions take the form's own path: the controller writes Transfer and Command Completion
 * events into the event ring the segment table names, and the harness acquires them as the form
 * says (each cycle word invalidated and loaded, erx_trb_form_acquire, each event read whole,
 * erx_trb_form_complete, the dequeue pointer written back), then checks every answer against
 * what it posted: an out transfer's bytes as the controller read them are the posted ones; an in
 * transfer's answer covers what the controller wrote, short packets included, and its buffer,
 * invalidated and loaded, holds it; a transaction error answers only a transfer on a queue the
 * harness asked to fail; `stopped` answers only a transfer of the queue or slot the command just
 * completed restarted or removed; every command succeeds.
 *
 * The trace enables slots, addresses them, configures an interrupt IN and a bulk OUT endpoint,
 * posts control, interrupt and bulk transfers of random lengths, fails some and recovers with
 * Reset Endpoint and Set TR Dequeue Pointer, stops queues and moves their dequeue pointers, drops
 * the bulk endpoint and adds it again, and disables and re-enables slots, until 100,000 transfers
 * have completed and 1,000 slots have been reused, with the cache line equal to the granule and
 * a quarter of it, at both context sizes.
 *
 * HARNESS_SEED_PUBLISH_BEFORE_CLEAN plants a fault in this effect layer that the test shows the
 * harness catches: a run's activation stored before the cleans of what it publishes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_trb_form.h"
#include "erx_device_trb_model.h"
#include "erx_dma_model.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#ifdef HARNESS_SEED_PUBLISH_BEFORE_CLEAN
#define SEED_PUBLISH_BEFORE_CLEAN	true
#else
#define SEED_PUBLISH_BEFORE_CLEAN	false
#endif

#define GRANULE		64u
#define DEVICE_BASE	UINT64_C(0x40000000)
#define SLOTS		4u
#define TRANSFERS	100000u
#define REUSES		1000u
#define ITERATIONS	4000000u
#define EP0		1u
#define EP1_IN		3u
#define EP2_OUT		4u
/* Each queue takes at most as many transfers as its pool has buffers. */
#define POSTS_MAX	(SLOTS * 3u * ERX_DEVICE_TRB_BUFFERS_MAX)
#define LAP		ERX_DEVICE_TRB_EVENT_TRBS

static const erx_dma_regions_t no_regions;
/* The queues the trace configures on every slot, by device context index. */
static const uint32_t queues[] = { EP0, EP1_IN, EP2_OUT };

/* A transfer posted and not yet answered, and what the controller moved for it. */
typedef struct post {
	bool		live;
	uint64_t	tag;
	uint32_t	slot;
	uint32_t	dci;
	bool		names_buffer;
	bool		in;
	uint32_t	length;
	uint32_t	pattern;	/* an out transfer's bytes */
	bool		moved;		/* the controller took the TRB naming its buffer */
	uint64_t	addr;		/* where it moved them */
	uint32_t	moved_length;
	uint8_t		written[ERX_DEVICE_BUFFER_MAX];	/* an in transfer's bytes as written */
} post_t;

typedef struct harness {
	erx_device_trb_layout_t		layout;
	erx_trb_form_t			form;
	erx_dma_model_t			cache;
	erx_device_trb_model_t		device;
	uint32_t			line;
	uint64_t			random;
	bool				enabled[SLOTS + 1];
	bool				teardown[SLOTS + 1];
	uint32_t			armed[SLOTS + 1][ERX_XHCI_DEVICE_CONTEXTS];	/* failures asked for */
	bool				command_live;
	erx_trb_command_t		command;	/* the one in flight, or the last completed */
	uint64_t			command_tag;
	uint64_t			dequeue;	/* the event ring dequeue register, as last written */
	post_t				posts[POSTS_MAX];
	uint32_t			patterns;
	uint64_t			tags;
	uint32_t			completed;
	uint32_t			reuses;
	uint32_t			failures;
	uint32_t			stopped;
	uint32_t			shorts;
	uint32_t			commands[ERX_TRB_COMMAND_KINDS];	/* completed, by kind */
	uint8_t				bytes[ERX_DEVICE_BUFFER_MAX];
} harness_t;

static erx_dma_sequence_t sequence;
static uint32_t words[LAP];
static erx_report_record_t events[LAP];
static erx_trb_answer_t answers[ERX_TRB_FORM_ANSWERS_MAX(LAP)];

static uint32_t
draw(harness_t *h, uint32_t bound)
{
	h->random ^= h->random << 13;
	h->random ^= h->random >> 7;
	h->random ^= h->random << 17;
	return ((uint32_t)(h->random % bound));
}

static uint32_t
endpoint_of(uint32_t slot, uint32_t dci)
{
	return (erx_trb_form_endpoint(slot, dci));
}

static erx_dma_endpoint_state_t
state_of(const harness_t *h, uint32_t slot, uint32_t dci)
{
	return (erx_dma_ledger_endpoint_state(erx_trb_form_ledger(&h->form), endpoint_of(slot, dci)));
}

/* -------------------------------------------------------------------------------------------
 * The controller's side
 */

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

/*
 * The controller moved a buffer of queue {slot, dci}: it runs a ring's TDs in order, so the buffer
 * is the oldest live post's on the queue whose buffer it has not moved. An out buffer must hold
 * exactly what the post wrote; an in buffer's bytes are kept for its answer.
 */
static void
sink(void *context, uint32_t slot, uint32_t dci, uint64_t addr, const uint8_t *bytes, uint32_t length, bool in)
{
	harness_t *const h = context;
	post_t *oldest = NULL;

	for (uint32_t at = 0; at < POSTS_MAX; at++) {
		post_t *const post = &h->posts[at];

		if (post->live && post->slot == slot && post->dci == dci && post->names_buffer && !post->moved &&
		    (oldest == NULL || post->tag < oldest->tag))
			oldest = post;
	}
	CHECK(oldest != NULL && oldest->in == in);
	oldest->moved = true;
	oldest->addr = addr;
	oldest->moved_length = length;
	if (in) {
		bcopy(bytes, oldest->written, length);
		return;
	}
	CHECK(length == oldest->length);
	for (uint32_t index = 0; index < length; index++)
		CHECK(bytes[index] == erx_device_trb_model_pattern(oldest->pattern, index));
}

/* -------------------------------------------------------------------------------------------
 * The effect layer over the model
 */

/* One effect done: the model may evict or refetch, and the controller may act on what memory shows. */
static void
settle(harness_t *h)
{
	erx_dma_model_tick(&h->cache);
	if (draw(h, 8) == 0)
		CHECK(erx_device_trb_model_run(&h->device) == ERX_OK);
}

/* The clean, or clean and invalidate, of every line `range` touches. */
static void
maintain(harness_t *h, erx_dma_range_t range, bool invalidate)
{
	const uint64_t mask = ~(uint64_t)(h->line - 1);
	const uint64_t start = range.offset & mask;
	const uint64_t end = (range.offset + range.length + h->line - 1) & mask;

	if (range.length == 0)
		return;
	if (invalidate)
		CHECK(erx_dma_model_clean_inval(&h->cache, start, end - start, h->line));
	else
		CHECK(erx_dma_model_clean(&h->cache, start, end - start, h->line));
	settle(h);
}

/* A run's activation: its first TRB's control word, the clean of its line, the publish barrier. */
static void
activate_run(harness_t *h, const erx_dma_activation_t *activation)
{
	CHECK(activation->kind == ERX_DMA_ACTIVATE_STORE);
	CHECK(erx_dma_model_cpu_store(&h->cache, activation->store.offset, activation->store.bytes,
	    activation->store.length));
	settle(h);
	maintain(h, (erx_dma_range_t){ activation->store.offset, activation->store.length }, false);
}

/*
 * A sequence applied in erx_device_sequencer.h's order: the zeros, the out bytes (`out` fills
 * sequence->fills[0]), the stores, the clean of every range passing to the controller and the
 * publish barrier, then the activation and doorbell `doorbell` with `target`. A TRB run writes no
 * registers. The model runs one access at a time, so every barrier holds already.
 *
 * This follows test/fixtures/erx_device_dma_model_harness.c's apply_sequence rather than sharing
 * it: the two differ in their activations (a doorbell here, virtio's registers and ready bit
 * there) and each is bound to its own harness's model and device, so a shared one would take more
 * hooks than the thirty lines it would save.
 */
static void
apply_sequence(harness_t *h, const erx_dma_sequence_t *s, const uint8_t *out, uint32_t doorbell, uint32_t target)
{
	CHECK(s->fill_count <= 1 && s->register_count == 0);
	for (uint32_t at = 0; at < s->zero_count; at++) {
		CHECK(erx_dma_model_cpu_zero(&h->cache, s->zeros[at].offset, s->zeros[at].length));
		settle(h);
	}
	for (uint32_t at = 0; at < s->fill_count; at++) {
		if (s->fills[at].length == 0)
			continue;
		CHECK(out != NULL && erx_dma_model_cpu_store(&h->cache, s->fills[at].offset, out, s->fills[at].length));
		settle(h);
	}
	for (uint32_t at = 0; at < s->store_count; at++) {
		CHECK(erx_dma_model_cpu_store(&h->cache, s->stores[at].offset, s->stores[at].bytes, s->stores[at].length));
		settle(h);
	}
	if (SEED_PUBLISH_BEFORE_CLEAN)
		activate_run(h, &s->activation);
	for (uint32_t at = 0; at < s->clean_count; at++)
		maintain(h, s->cleans[at], false);
	if (!SEED_PUBLISH_BEFORE_CLEAN)
		activate_run(h, &s->activation);
	erx_device_trb_model_doorbell(&h->device, doorbell, target);
	settle(h);
}

/*
 * The install: every region zeroed and cleaned, the event ring among them, so no event is live
 * before the controller writes it; the segment table's one entry written and cleaned; then the
 * segment table's base register, and the dequeue register at the ring's first TRB.
 */
static void
install(harness_t *h)
{
	const erx_device_trb_region_t *const event_ring = &h->layout.regions[h->layout.event_ring];
	const erx_device_trb_region_t *const table = &h->layout.regions[h->layout.segment_table];
	uint64_t base = 0;
	uint32_t size = 0;

	CHECK(erx_dma_model_cpu_zero(&h->cache, 0, h->cache.size));
	maintain(h, (erx_dma_range_t){ 0, h->cache.size }, false);
	/*
	 * The install's one record, written field by field through the generated setters: only the
	 * sequencer calls a record's encoder, and the form has no install of its own (TODO.md).
	 */
	CHECK(erx_xhci_segment_table_entry_base_address_set(&base, DEVICE_BASE + event_ring->offset) &&
	    erx_xhci_segment_table_entry_size_trbs_set(&size, LAP));
	CHECK(erx_dma_model_cpu_store(&h->cache, table->offset + ERX_XHCI_SEGMENT_TABLE_ENTRY_OFF_BASE, &base,
	    sizeof(base)));
	CHECK(erx_dma_model_cpu_store(&h->cache, table->offset + ERX_XHCI_SEGMENT_TABLE_ENTRY_OFF_SIZE, &size,
	    sizeof(size)));
	maintain(h, (erx_dma_range_t){ table->offset, ERX_XHCI_SEGMENT_TABLE_ENTRY_SIZE }, false);
	CHECK(erx_device_trb_model_segment_table(&h->device, DEVICE_BASE + table->offset));
	h->dequeue = DEVICE_BASE + event_ring->offset;
	CHECK(erx_device_trb_model_dequeue(&h->device, h->dequeue));
}

/* -------------------------------------------------------------------------------------------
 * Completions, through the event ring
 */

static post_t *
post_tagged(harness_t *h, uint64_t tag)
{
	for (uint32_t at = 0; at < POSTS_MAX; at++) {
		if (h->posts[at].live && h->posts[at].tag == tag)
			return (&h->posts[at]);
	}
	CHECK(!"an answer names a transfer the harness posted");
	return (NULL);
}

/* Whether the command just completed restarted or removed queue {slot, dci}. */
static bool
command_retires(const erx_trb_command_t *command, uint32_t slot, uint32_t dci)
{
	switch (command->kind) {
	case ERX_TRB_COMMAND_SET_TR_DEQUEUE:
		return (command->slot == slot && command->dci == dci);
	case ERX_TRB_COMMAND_DISABLE_SLOT:
		return (command->slot == slot);
	case ERX_TRB_COMMAND_CONFIGURE_ENDPOINT:
		return (command->slot == slot && (command->drops >> dci & 1u) != 0);
	default:
		return (false);
	}
}

/*
 * A transfer's answer: its bytes as the controller moved them, a failure the harness asked for, or
 * `stopped` by the command just completed.
 */
static void
transfer_answered(harness_t *h, const erx_trb_answer_t *answer)
{
	post_t *const post = post_tagged(h, answer->tag);
	uint8_t bytes[ERX_DEVICE_BUFFER_MAX];

	switch (answer->code) {
	case ERX_XHCI_COMPLETION_SUCCESS:
	case ERX_XHCI_COMPLETION_SHORT_PACKET:
		if (!post->names_buffer) {
			CHECK(answer->data.length == 0);
			break;
		}
		CHECK(post->moved && DEVICE_BASE + answer->data.offset == post->addr &&
		    answer->data.length == post->moved_length);
		if (post->in) {
			maintain(h, answer->data, true);
			CHECK(erx_dma_model_cpu_load(&h->cache, answer->data.offset, bytes, answer->data.length));
			CHECK(memcmp(bytes, post->written, answer->data.length) == 0);
		}
		h->shorts += post->moved_length < post->length;
		h->completed++;
		break;
	case ERX_XHCI_COMPLETION_STOPPED:
		CHECK(!h->command_live && command_retires(&h->command, post->slot, post->dci));
		CHECK(answer->data.length == 0);
		h->stopped++;
		break;
	default:
		CHECK(answer->code == ERX_XHCI_COMPLETION_TRANSACTION_ERROR && h->armed[post->slot][post->dci] > 0);
		CHECK(answer->data.length == 0);
		h->armed[post->slot][post->dci]--;
		h->failures++;
		break;
	}
	post->live = false;
}

static void
command_answered(harness_t *h, const erx_trb_answer_t *answer)
{
	CHECK(h->command_live && answer->tag == h->command_tag && answer->code == ERX_XHCI_COMPLETION_SUCCESS);
	h->command_live = false;
	h->commands[h->command.kind]++;
	if (h->command.kind == ERX_TRB_COMMAND_ENABLE_SLOT) {
		CHECK(answer->slot >= 1 && answer->slot <= SLOTS && !h->enabled[answer->slot]);
		h->enabled[answer->slot] = true;
	} else if (h->command.kind == ERX_TRB_COMMAND_DISABLE_SLOT) {
		h->enabled[h->command.slot] = false;
		h->teardown[h->command.slot] = false;
		h->reuses++;
	}
}

/*
 * The acquisition's two phases: the cycle words from the consumer position, each line invalidated
 * and the word loaded once, in growing batches while every word read is written; then each
 * acquired event invalidated and read whole, the completion, and the dequeue register.
 */
static void
drain(harness_t *h)
{
	uint32_t read = 0, count = 0, answered;

	for (uint32_t batch = 4;; batch *= 2) {
		while (read < batch) {
			const erx_dma_range_t word = erx_trb_form_validity_word(&h->form, read);
			uint8_t bytes[4];

			if (word.length == 0)
				break;
			CHECK(word.length == sizeof(bytes));
			maintain(h, word, true);
			CHECK(erx_dma_model_cpu_load(&h->cache, word.offset, bytes, sizeof(bytes)));
			words[read++] = (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 |
			    (uint32_t)bytes[3] << 24;
		}
		CHECK(erx_trb_form_acquire(&h->form, words, read, &count) == ERX_OK);
		if (count < read || read < batch)
			break;
	}
	if (count == 0)
		return;
	for (uint32_t k = 0; k < count; k++) {
		const erx_dma_range_t event = erx_trb_form_event(&h->form, k);

		CHECK(event.length == sizeof(events[k].bytes));
		maintain(h, event, true);
		CHECK(erx_dma_model_cpu_load(&h->cache, event.offset, events[k].bytes, event.length));
	}
	CHECK(erx_trb_form_complete(&h->form, events, count, answers, &answered, &h->dequeue) == ERX_OK);
	CHECK(erx_device_trb_model_dequeue(&h->device, h->dequeue));
	for (uint32_t at = 0; at < answered; at++) {
		CHECK(answers[at].kind != ERX_TRB_ANSWER_PORT);
		if (answers[at].kind == ERX_TRB_ANSWER_COMMAND)
			command_answered(h, &answers[at]);
		else
			transfer_answered(h, &answers[at]);
	}
}

/* -------------------------------------------------------------------------------------------
 * The trace
 */

/* Slot `slot`'s queue block of `kind`: the slot-th of that kind, so a slot reuses its blocks. */
static uint32_t
block_for(const harness_t *h, uint32_t slot, erx_device_trb_kind_t kind)
{
	uint32_t seen = 0;

	for (uint32_t block = 0; block < ERX_DEVICE_TRB_BLOCKS_MAX; block++) {
		if (erx_device_trb_block_kind(&h->layout.shape, block) == kind && ++seen == slot)
			return (block);
	}
	CHECK(!"a block for every slot");
	return (0);
}

static erx_trb_add_t
add_of(const harness_t *h, uint32_t slot, uint32_t dci)
{
	switch (dci) {
	case EP0:
		return ((erx_trb_add_t){ .dci = EP0, .block = block_for(h, slot, ERX_DEVICE_TRB_CONTROL),
		    .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL, .config_max_packet = 64 } });
	case EP1_IN:
		return ((erx_trb_add_t){ .dci = EP1_IN, .block = block_for(h, slot, ERX_DEVICE_TRB_INTERRUPT),
		    .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_INTERRUPT_IN, .config_max_packet = 64,
		    .info_interval = 3, .payload_max_esit_payload = 64 } });
	default:
		return ((erx_trb_add_t){ .dci = EP2_OUT, .block = block_for(h, slot, ERX_DEVICE_TRB_BULK),
		    .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_BULK_OUT, .config_max_packet = 64,
		    .payload_max_esit_payload = 64 } });
	}
}

/* Whether no ring of slot `slot` holds a transfer. */
static bool
slot_quiet(const harness_t *h, uint32_t slot)
{
	const erx_dma_ledger_t *const ledger = erx_trb_form_ledger(&h->form);

	for (uint32_t dci = EP0; dci <= EP2_OUT; dci++) {
		const int table = erx_dma_ledger_bound_table(ledger, endpoint_of(slot, dci));

		if (table >= 0 && erx_dma_ledger_holdings_on(ledger, (uint32_t)table) != 0)
			return (false);
	}
	return (true);
}

/*
 * The next command the trace needs, if any: recovery first (Reset Endpoint on a halted queue, Set
 * TR Dequeue Pointer on a stopped one), then teardown, then bring-up, then a random stop or drop.
 */
static bool
next_command(harness_t *h, erx_trb_command_t *command)
{
	const erx_dma_ledger_t *const ledger = erx_trb_form_ledger(&h->form);

	*command = (erx_trb_command_t){ 0 };
	for (uint32_t slot = 1; slot <= SLOTS; slot++) {
		for (uint32_t dci = EP0; dci <= EP2_OUT && h->enabled[slot]; dci++) {
			const erx_dma_endpoint_state_t state = state_of(h, slot, dci);

			if (state != ERX_DMA_ENDPOINT_HALTED && state != ERX_DMA_ENDPOINT_STOPPED)
				continue;
			command->kind = state == ERX_DMA_ENDPOINT_HALTED ? ERX_TRB_COMMAND_RESET_ENDPOINT :
			    ERX_TRB_COMMAND_SET_TR_DEQUEUE;
			command->slot = slot;
			command->dci = dci;
			return (true);
		}
	}
	for (uint32_t slot = 1; slot <= SLOTS; slot++) {
		if (!h->enabled[slot])
			continue;
		command->slot = slot;
		if (h->teardown[slot] && slot_quiet(h, slot)) {
			command->kind = ERX_TRB_COMMAND_DISABLE_SLOT;
			return (true);
		}
		if (h->teardown[slot])
			continue;
		if (state_of(h, slot, EP0) == ERX_DMA_ENDPOINT_DISABLED) {
			command->kind = ERX_TRB_COMMAND_ADDRESS_DEVICE;
			command->slot_context = (erx_xhci_slot_context_free_t){ .route_speed = ERX_XHCI_SPEED_HIGH,
			    .ports_root_port = 1 };
			command->adds[command->add_count++] = add_of(h, slot, EP0);
			return (true);
		}
		for (uint32_t dci = EP1_IN; dci <= EP2_OUT; dci++) {
			if (state_of(h, slot, dci) == ERX_DMA_ENDPOINT_DISABLED)
				command->adds[command->add_count++] = add_of(h, slot, dci);
		}
		if (command->add_count != 0) {
			command->kind = ERX_TRB_COMMAND_CONFIGURE_ENDPOINT;
			return (true);
		}
	}
	for (uint32_t slot = 1; slot <= SLOTS; slot++) {
		if (!h->enabled[slot]) {
			*command = (erx_trb_command_t){ .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
			return (true);
		}
	}
	if (draw(h, 64) == 0) {
		const uint32_t slot = 1u + draw(h, SLOTS), dci = queues[draw(h, 3)];
		const int table = erx_dma_ledger_bound_table(ledger, endpoint_of(slot, dci));

		if (state_of(h, slot, dci) != ERX_DMA_ENDPOINT_RUNNING)
			return (false);
		*command = (erx_trb_command_t){ .kind = ERX_TRB_COMMAND_STOP_ENDPOINT, .slot = slot, .dci = dci };
		/* A drop of an idle bulk endpoint, which the bring-up adds again. */
		if (dci == EP2_OUT && draw(h, 2) == 0 && erx_dma_ledger_holdings_on(ledger, (uint32_t)table) == 0)
			*command = (erx_trb_command_t){ .kind = ERX_TRB_COMMAND_CONFIGURE_ENDPOINT, .slot = slot,
			    .drops = 1u << EP2_OUT };
		return (true);
	}
	return (false);
}

/* A free entry for a post. */
static post_t *
free_post(harness_t *h)
{
	for (uint32_t at = 0; at < POSTS_MAX; at++) {
		if (!h->posts[at].live)
			return (&h->posts[at]);
	}
	CHECK(!"a queue takes no more transfers than its pool has buffers");
	return (NULL);
}

/* A random transfer on a random queue of an enabled slot that is not being torn down. */
static void
post_transfer(harness_t *h)
{
	const uint32_t slot = 1u + draw(h, SLOTS), dci = queues[draw(h, 3)];
	const int table = erx_dma_ledger_bound_table(erx_trb_form_ledger(&h->form), endpoint_of(slot, dci));
	const erx_dma_endpoint_state_t state = state_of(h, slot, dci);
	erx_device_trb_request_t request = { .bytes = h->bytes };
	erx_device_trb_kind_t kind;
	erx_device_trb_verdict_t verdict;
	uint32_t size;
	post_t *post;

	if (!h->enabled[slot] || h->teardown[slot])
		return;
	if (table < 0) {
		CHECK(erx_trb_form_post(&h->form, slot, dci, &request, h->tags++, &sequence) == ERX_DEVICE_TRB_REFUSE_BADARG);
		return;
	}
	kind = erx_device_trb_block_kind(&h->layout.shape, (uint32_t)table);
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
	verdict = erx_trb_form_post(&h->form, slot, dci, &request, h->tags, &sequence);
	if (verdict != ERX_DEVICE_TRB_ACCEPTED) {
		/* A full ring is refused before a closed endpoint, so a stopped or halted queue may answer either. */
		CHECK(verdict == ERX_DEVICE_TRB_REFUSE_HALTED || verdict == ERX_DEVICE_TRB_REFUSE_FULL);
		return;
	}
	CHECK(state == ERX_DMA_ENDPOINT_RUNNING);
	post = free_post(h);
	*post = (post_t){ .live = true, .tag = h->tags++, .slot = slot, .dci = dci, .names_buffer = request.data,
	    .in = request.device_writes, .length = request.length, .pattern = h->patterns++ };
	apply_sequence(h, &sequence, h->bytes, slot, dci);
}

/* A failure or a short packet asked of a random running queue's next TD. */
static void
perturb(harness_t *h)
{
	const uint32_t slot = 1u + draw(h, SLOTS), dci = queues[draw(h, 3)];
	erx_device_trb_model_ring_t *const ring = &h->device.rings[slot][dci];

	if (state_of(h, slot, dci) != ERX_DMA_ENDPOINT_RUNNING)
		return;
	if (draw(h, 32) == 0 && !ring->fail) {
		ring->fail = true;
		h->armed[slot][dci]++;
	} else {
		ring->short_packet = true;
	}
}

static void
run_trace(uint32_t context_size, uint32_t line, uint64_t seed)
{
	const erx_device_trb_controller_t controller = { .slots = SLOTS, .ports = 4, .scratchpads = 2,
	    .context_size = context_size, .doorbells = 0x2000 };
	harness_t *const h = calloc(1, sizeof(*h));
	erx_device_trb_memory_t memory = { .read = device_read, .write = device_write };
	erx_trb_command_t command;
	uint32_t iterations = 0;

	CHECK(h != NULL);
	h->line = line;
	h->random = seed;
	memory.context = h;
	CHECK(erx_device_trb_layout(&h->layout, &erx_device_trb_shape, &controller, DEVICE_BASE, GRANULE, 1u << 20));
	CHECK(erx_dma_model_init(&h->cache, (h->layout.bytes + GRANULE - 1) / GRANULE * GRANULE, GRANULE, line, seed));
	CHECK(erx_trb_form_make(&h->form, &h->layout, &no_regions));
	erx_device_trb_model_init(&h->device, &h->layout, &memory, sink, h);
	install(h);

	while ((h->completed < TRANSFERS || h->reuses < REUSES) && iterations++ < ITERATIONS) {
		drain(h);
		if (!h->command_live && next_command(h, &command)) {
			CHECK(erx_trb_form_command(&h->form, &command, h->tags, &sequence) == ERX_DEVICE_TRB_ACCEPTED);
			h->command = command;
			h->command_tag = h->tags++;
			h->command_live = true;
			apply_sequence(h, &sequence, NULL, 0, 0);
		}
		post_transfer(h);
		if (draw(h, 16) == 0)
			perturb(h);
		if (draw(h, 100) == 0) {
			const uint32_t slot = 1u + draw(h, SLOTS);

			h->teardown[slot] = h->enabled[slot];
		}
		if (draw(h, 4) == 0)
			CHECK(erx_device_trb_model_run(&h->device) == ERX_OK);
	}
	CHECK(h->completed >= TRANSFERS && h->reuses >= REUSES);
	printf("trace: context %u, line %u: %u transfers, %u short, %u slot reuses, %u failures, %u stopped, "
	    "%u stops, %u dequeue moves, %u iterations, %llu evictions\n", context_size, line, h->completed, h->shorts,
	    h->reuses, h->failures, h->stopped, h->commands[ERX_TRB_COMMAND_STOP_ENDPOINT],
	    h->commands[ERX_TRB_COMMAND_SET_TR_DEQUEUE], iterations, (unsigned long long)h->cache.evictions);
	erx_dma_model_fini(&h->cache);
	free(h);
}

int
main(void)
{
	run_trace(32, GRANULE, 0x9e3779b97f4a7c15u);
	run_trace(64, GRANULE / 4u, 0x2545f4914f6cdd1du);
	printf("erx_device_trb_form_model done\n");
	return (0);
}
