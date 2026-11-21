/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB rings on the DMA core (docs/design-device-dma.md, "The ledger", "Publication"): a
 * ring's runs, placed in order with the sequencer's link and cycle state, explored against a
 * reference model on every sequence of runs and releases up to a fixed depth; and the bindings,
 * which place a run on the ring bound to its endpoint and keep its names inside that ring's pool.
 * test/host/erx_device_trb_ring_test.rb builds it with each ERX_DMA_SEED_* fault and shows the
 * fault caught.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_rules.h"
#include "erx_device_sequencer.h"

#define EXPECT(condition, what)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, what);	\
			exit(1);						\
		}								\
	} while (0)

/*
 * Two transfer rings of RING TRBs, the last each one's link, each with a pool of two buffers, which
 * take runs only once bound; and the command ring, which needs none, with a pool of one buffer, the
 * input context a Configure Endpoint names as it binds a ring to an endpoint of slot 1.
 */
enum { RING = 5, RING0 = 0, RING1 = 1, EVENTS = 2, COMMANDS = 3, BUFFERS = 2, DEPTH = 8, RUN_MAX = 3 };
#define BASE		UINT64_C(0x40000)
#define ENDPOINT0	UINT32_C(0x22)	/* slot 1, device context index 2 */
#define ENDPOINT1	UINT32_C(0x23)
#define NO_BUFFER	UINT32_MAX

static const erx_dma_regions_t no_regions;
/* The heads of the transfers a command retires, which these tests do not read. */
static erx_dma_place_t retired[ERX_DMA_HOLDINGS_MAX];
static uint32_t retired_count;

/* The input context at 32-byte contexts, granule-rounded: its pool's one buffer. */
#define INPUT_CONTEXT_BYTES	1088u

static erx_dma_layout_t
layout(void)
{
	return ((erx_dma_layout_t){
		.memory_size = 2048, .device_base = BASE, .address_bits = 64, .granule = 64, .context_size = 32, .table_count = 4,
		.tables = {
			{ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .placing = ERX_DMA_PLACED_RING,
			  .pool = 0, .region = 0, .region_length = 128, .first = 0, .count = RING, .stride = 16 },
			{ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .placing = ERX_DMA_PLACED_RING,
			  .pool = 1, .region = 128, .region_length = 128, .first = 128, .count = RING, .stride = 16 },
			{ .structure = ERX_STRUCTURE_XHCI_EVENT_RING, .region = 256, .region_length = 128, .first = 256,
			  .count = 8, .stride = 16 },
			{ .structure = ERX_STRUCTURE_XHCI_COMMAND_RING, .placing = ERX_DMA_PLACED_RING, .pool = 2,
			  .region = 640, .region_length = 128, .first = 640, .count = RING, .stride = 16 },
		},
		.pool_count = 3,
		.pools = { { .first = 512, .count = BUFFERS, .size = 64, .stride = 64 },
			   { .first = 384, .count = BUFFERS, .size = 64, .stride = 64 },
			   { .first = 768, .count = 1, .size = INPUT_CONTEXT_BYTES, .stride = INPUT_CONTEXT_BYTES } },
	});
}

static erx_dma_description_t
normal(uint32_t buffer, uint32_t length)
{
	return ((erx_dma_description_t){ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .meaning = ERX_MEANING_XHCI_TRB_NORMAL,
	    .described.xhci_trb_normal = { .status_length = length, .control_interrupt_on_short = 1,
	    .control_interrupt_on_completion = 1 }, .name_count = 1, .names = { { buffer, 0 } } });
}

/* A No Op command, the command ring's one meaning, which stands in for a binding command. */
static erx_dma_description_t
noop(void)
{
	return ((erx_dma_description_t){ .structure = ERX_STRUCTURE_XHCI_COMMAND_RING,
	    .meaning = ERX_MEANING_XHCI_TRB_NOOP_COMMAND });
}

/* The input context a binding command adding `endpoint` carries: a bulk OUT endpoint of 64-byte packets. */
static const erx_device_trb_contexts_t *
carried(uint32_t endpoint)
{
	static erx_device_trb_contexts_t contexts;

	contexts = (erx_device_trb_contexts_t){ .endpoint_count = 1, .endpoints = { {
	    .dci = endpoint % ERX_DMA_GROUP_ENDPOINTS, .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_BULK_OUT,
	    .config_max_packet = 64, .payload_max_esit_payload = 64 } } } };
	return (&contexts);
}

/* A Configure Endpoint, naming the command ring's one buffer, the input context. */
static erx_dma_description_t
configure(void)
{
	return ((erx_dma_description_t){ .structure = ERX_STRUCTURE_XHCI_COMMAND_RING,
	    .meaning = ERX_MEANING_XHCI_TRB_CONFIGURE_ENDPOINT_COMMAND, .name_count = 1, .names = { { 2u * BUFFERS, 0 } } });
}

static erx_dma_description_t
setup(void)
{
	return ((erx_dma_description_t){ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .meaning = ERX_MEANING_XHCI_TRB_SETUP,
	    .described.xhci_trb_setup = { .setup = UINT64_C(0x0008000006000680), .control_transfer_type = 3 } });
}

static erx_dma_description_t
data(uint32_t buffer)
{
	return ((erx_dma_description_t){ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .meaning = ERX_MEANING_XHCI_TRB_DATA,
	    .described.xhci_trb_data = { .status_length = 8, .control_interrupt_on_short = 1, .control_direction_in = 1 },
	    .name_count = 1, .names = { { buffer, 0 } } });
}

static erx_dma_description_t
status(void)
{
	return ((erx_dma_description_t){ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .meaning = ERX_MEANING_XHCI_TRB_STATUS,
	    .described.xhci_trb_status = { .control_interrupt_on_completion = 1 } });
}

/* A run of `n` descriptions: a normal TRB, a control transfer with no data stage, or one with one. */
static uint32_t
run(uint32_t n, uint32_t buffer, erx_dma_description_t records[RUN_MAX])
{
	switch (n) {
	case 1:
		records[0] = normal(buffer, 64);
		return (1);
	case 2:
		records[0] = setup();
		records[1] = status();
		return (2);
	default:
		records[0] = setup();
		records[1] = data(buffer);
		records[2] = status();
		return (3);
	}
}

static erx_dma_publication_t
on(uint32_t endpoint, const erx_dma_description_t *records, uint32_t count)
{
	return ((erx_dma_publication_t){ .record_count = count, .records = records, .call = ERX_DMA_PUBLISH_RUN,
	    .endpoint = endpoint });
}

/*
 * A binding command: one TRB on the command ring, carrying the binding of `ring` to `endpoint`,
 * which its holding makes. `command` is its TRB's description.
 */
static erx_dma_verdict_t
bind(erx_dma_ledger_t *ledger, uint32_t ring, uint32_t endpoint, erx_dma_description_t command,
    erx_dma_sequence_t *sequence)
{
	const erx_dma_publication_t publication = { .record_count = 1, .records = &command, .call = ERX_DMA_PUBLISH_RUN,
	    .bind_count = 1, .binds = { { endpoint, ring } }, .reach = { .group = endpoint / ERX_DMA_GROUP_ENDPOINTS },
	    .contexts = carried(endpoint) };

	return (erx_dma_publish(ledger, &publication, sequence));
}

/* The command's report ends its holding, as a success leaves the binding it made. */
static void
complete_command(erx_dma_ledger_t *ledger, uint32_t index)
{
	EXPECT(erx_dma_ledger_acquire(ledger, EVENTS, 1) &&
	    erx_dma_ledger_complete_command(ledger, EVENTS, erx_dma_ledger_holding(ledger, (erx_dma_place_t){ COMMANDS, index }),
	    true, retired, &retired_count),
	    "the command's report ends it");
}

/* The control word of a stored TRB, and its fields, by the generated accessors. */
static uint32_t
control(const erx_dma_store_t *store, uint32_t at)
{
	uint32_t word;

	memcpy(&word, store->bytes + at, sizeof(word));
	return (word);
}

/* The reference model: ring 0's position and its live runs, oldest first. */
typedef struct model_run {
	uint32_t	count;
	uint32_t	positions[2 * RUN_MAX + 1];
	uint32_t	head;
	uint32_t	buffer;
} model_run_t;

typedef struct model {
	uint32_t	index;
	uint32_t	lap;
	uint32_t	live;
	model_run_t	runs[RING];
} model_t;

static bool
model_held(const model_t *model, uint32_t position)
{
	for (uint32_t live = 0; live < model->live; live++) {
		for (uint32_t index = 0; index < model->runs[live].count; index++) {
			if (model->runs[live].positions[index] == position)
				return (true);
		}
	}
	return (false);
}

static uint32_t
model_free_buffer(const model_t *model)
{
	for (uint32_t buffer = 0; buffer < BUFFERS; buffer++) {
		bool used = false;

		for (uint32_t live = 0; live < model->live; live++)
			used = used || model->runs[live].buffer == buffer;
		if (!used)
			return (buffer);
	}
	return (NO_BUFFER);
}

/* Where a run of `n` lands, in the model's own walk: each position, its cycle, and whether a link. */
typedef struct model_step {
	uint32_t	position;
	uint32_t	cycle;
	bool		link;
} model_step_t;

static uint32_t
model_walk(const model_t *model, uint32_t n, model_step_t steps[2 * RUN_MAX + 1], uint32_t *index, uint32_t *lap)
{
	uint32_t count = 0, placed = 0;

	*index = model->index;
	*lap = model->lap;
	while (placed < n || *index == RING - 1) {
		const bool link = *index == RING - 1;

		steps[count++] = (model_step_t){ *index, *lap % 2 == 0, link };
		placed += !link;
		if (link) {
			*index = 0;
			++*lap;
		} else {
			++*index;
		}
	}
	return (count);
}

static void
check_run(const erx_dma_ledger_t *ledger, const model_t *before, const erx_dma_sequence_t *sequence,
    const model_step_t *steps, uint32_t count, uint32_t buffer)
{
	bool first = true;

	EXPECT(sequence->store_count == count, "a store for each description and each link the run takes");
	for (uint32_t step = 0; step < count; step++) {
		const erx_dma_store_t *store = &sequence->stores[step];
		const uint32_t word = control(store, ERX_XHCI_TRB_NORMAL_OFF_CONTROL);

		EXPECT(store->offset == steps[step].position * 16u && store->length == 16, "each at its position, whole");
		EXPECT(!model_held(before, steps[step].position), "no store into a TRB a live run holds");
		if (steps[step].link) {
			erx_xhci_trb_link_t link;

			memcpy(&link, store->bytes, sizeof(link));
			EXPECT(erx_xhci_trb_link_control_type_get(link.control) == ERX_XHCI_TRB_TYPE_LINK &&
			    erx_xhci_trb_link_control_toggle_cycle_get(link.control) == 1 &&
			    erx_xhci_trb_link_control_cycle_get(link.control) == steps[step].cycle &&
			    erx_xhci_trb_link_segment_segment_pointer_get(link.segment) == BASE,
			    "a link back to the ring's first TRB, toggling, with its lap's cycle");
			continue;
		}
		EXPECT(erx_xhci_trb_normal_control_cycle_get(word) == (first ? !steps[step].cycle : steps[step].cycle),
		    "the first TRB written with the other cycle bit, the rest with their lap's");
		if (first) {
			const uint32_t live = control(&sequence->activation.store, 0);

			EXPECT(sequence->activation.kind == ERX_DMA_ACTIVATE_STORE &&
			    sequence->activation.store.offset == store->offset + ERX_XHCI_TRB_NORMAL_OFF_CONTROL &&
			    sequence->activation.store.length == 4 &&
			    erx_xhci_trb_normal_control_cycle_get(live) == steps[step].cycle &&
			    erx_xhci_trb_normal_control_type_get(live) == erx_xhci_trb_normal_control_type_get(word),
			    "the activation is the first TRB's control word with its live cycle bit");
		}
		if (erx_xhci_trb_normal_control_type_get(word) == ERX_XHCI_TRB_TYPE_NORMAL ||
		    erx_xhci_trb_normal_control_type_get(word) == ERX_XHCI_TRB_TYPE_DATA_STAGE) {
			uint64_t address;

			memcpy(&address, store->bytes, sizeof(address));
			EXPECT(address == BASE + 512 + 64u * buffer, "a TRB's buffer is its ring's pool's");
		}
		first = false;
	}
	EXPECT(erx_dma_ledger_position(ledger, RING0).index != RING - 1, "the position never rests on the link");
}

static void
explore(const erx_dma_ledger_t *ledger, const model_t *model, uint32_t depth)
{
	if (depth == 0)
		return;
	for (uint32_t n = 1; n <= RUN_MAX; n++) {
		erx_dma_ledger_t next = *ledger;
		model_t after = *model;
		erx_dma_description_t records[RUN_MAX];
		model_step_t steps[2 * RUN_MAX + 1];
		const uint32_t buffer = n == 2 ? NO_BUFFER : model_free_buffer(model);
		uint32_t count, index, lap;
		bool fits = true;
		erx_dma_sequence_t sequence;
		erx_dma_publication_t publication;
		erx_dma_verdict_t checked, verdict;

		if (n != 2 && buffer == NO_BUFFER)
			continue;
		publication = on(ENDPOINT0, records, run(n, buffer, records));
		count = model_walk(model, n, steps, &index, &lap);
		for (uint32_t step = 0; step < count; step++)
			fits = fits && !model_held(model, steps[step].position);
		/* A ring holds no more TDs than its pool has buffers, though a run of setup and status names none. */
		fits = fits && model->live < BUFFERS;
		checked = erx_dma_publication_check(&next, &publication);
		verdict = erx_dma_publish(&next, &publication, &sequence);
		EXPECT(checked == verdict, "the check's verdict is the publication's");
		if (!fits) {
			EXPECT(checked == ERX_DMA_BREAKS_ROOM, "a run over a held TRB, or past the pool's buffers, breaks the room rule");
			continue;
		}
		EXPECT(verdict == ERX_DMA_PASSES, "a run with room passes");
		check_run(&next, model, &sequence, steps, count, buffer);
		after.runs[after.live] = (model_run_t){ .count = count, .buffer = buffer };
		for (uint32_t step = 0; step < count; step++) {
			after.runs[after.live].positions[step] = steps[step].position;
			if (!steps[step].link)
				after.runs[after.live].head = steps[step].position;
		}
		EXPECT(erx_dma_ledger_holding(&next, (erx_dma_place_t){ RING0, after.runs[after.live].head }).holding != NULL,
		    "the holding's head is the TD's last TRB");
		after.live++;
		after.index = index;
		after.lap = lap;
		EXPECT(erx_dma_ledger_position(&next, RING0).index == index &&
		    erx_dma_ledger_position(&next, RING0).lap == lap, "the ledger's position is the model's");
		explore(&next, &after, depth - 1);
	}
	if (model->live != 0) {
		erx_dma_ledger_t next = *ledger;
		model_t after = *model;
		const erx_dma_found_t found = erx_dma_ledger_holding(&next,
		    (erx_dma_place_t){ RING0, model->runs[0].head });

		EXPECT(erx_dma_ledger_acquire(&next, EVENTS, 1) && erx_dma_ledger_release_holding(&next, EVENTS, found),
		    "the oldest run's report ends it");
		memmove(&after.runs[0], &after.runs[1], (after.live - 1) * sizeof(after.runs[0]));
		after.live--;
		explore(&next, &after, depth - 1);
	}
}

/* The stored TRB at `offset` of a sequence, or NULL. */
static const erx_dma_store_t *
stored_at(const erx_dma_sequence_t *sequence, uint64_t offset)
{
	for (uint32_t index = 0; index < sequence->store_count; index++) {
		if (sequence->stores[index].offset == offset)
			return (&sequence->stores[index]);
	}
	return (NULL);
}

/* A binding command's binding is judged with the rest of its publication and made with its holding. */
static void
test_binding_command(void)
{
	const erx_dma_layout_t planned = layout();
	erx_dma_ledger_t ledger;
	erx_dma_sequence_t sequence;
	erx_dma_description_t wrong_meaning = noop();
	erx_dma_found_t found;
	erx_xhci_trb_link_t link;
	const erx_dma_store_t *ring_link;

	EXPECT(erx_dma_ledger_make(&ledger, &planned, &no_regions), "two rings that need a binding and one that needs none");
	EXPECT(bind(&ledger, RING0, ENDPOINT0, configure(), &sequence) == ERX_DMA_PASSES, "a binding command binds ring 0");
	ring_link = stored_at(&sequence, (RING - 1) * 16u);
	EXPECT(ring_link != NULL, "the bound ring's link is stored");
	memcpy(&link, ring_link->bytes, sizeof(link));
	EXPECT(sequence.zero_count == 2 && sequence.zeros[0].offset == 0 && sequence.zeros[0].length == 128 &&
	    sequence.store_count == 2 + 3 && stored_at(&sequence, 640) != NULL && stored_at(&sequence, 768) != NULL &&
	    stored_at(&sequence, 768 + 32) != NULL && stored_at(&sequence, 768 + (ENDPOINT0 % ERX_DMA_GROUP_ENDPOINTS + 1u) * 32u) != NULL &&
	    sequence.clean_count == 3 &&
	    erx_xhci_trb_link_control_cycle_get(link.control) == 1 &&
	    sequence.activation.store.offset == 640 + ERX_XHCI_TRB_NORMAL_OFF_CONTROL,
	    "the command zeroes the ring, writes its link with cycle 1, writes the input context it names (its control, slot and "
	    "endpoint contexts) and cleans both, and activates its own TRB");
	found = erx_dma_ledger_holding(&ledger, (erx_dma_place_t){ COMMANDS, 0 });
	EXPECT(erx_dma_ledger_binding(&ledger, RING0) == ENDPOINT0 && erx_dma_ledger_bound_table(&ledger, ENDPOINT0) == RING0 &&
	    found.holding != NULL && found.holding->bind_count == 1 && found.holding->binds[0].table == RING0 &&
	    found.holding->binds[0].endpoint == ENDPOINT0,
	    "the ring is bound, and the command's holding records the binding its failure ends");

	EXPECT(bind(&ledger, RING0, ENDPOINT1, configure(), &sequence) == ERX_DMA_BREAKS_BINDINGS &&
	    bind(&ledger, RING1, ENDPOINT0, configure(), &sequence) == ERX_DMA_BREAKS_BINDINGS &&
	    bind(&ledger, COMMANDS, ENDPOINT1, configure(), &sequence) == ERX_DMA_BREAKS_BINDINGS &&
	    bind(&ledger, EVENTS, ENDPOINT1, configure(), &sequence) == ERX_DMA_BREAKS_BINDINGS &&
	    bind(&ledger, 9, ENDPOINT1, configure(), &sequence) == ERX_DMA_BREAKS_BINDINGS,
	    "a bound ring, a bound endpoint, rings that need no binding and a table past the layout are refused");
	wrong_meaning.meaning = ERX_MEANING_XHCI_TRB_NORMAL;
	EXPECT(bind(&ledger, RING1, ENDPOINT1, wrong_meaning, &sequence) == ERX_DMA_BREAKS_BINDINGS,
	    "a binding on a TRB whose meaning has no reach that binds");
	EXPECT(erx_dma_ledger_binding(&ledger, RING1) == 0 && erx_dma_ledger_live(&ledger) == 1,
	    "a refused binding command binds nothing and holds nothing");
	complete_command(&ledger, 0);
	EXPECT(erx_dma_ledger_binding(&ledger, RING0) == ENDPOINT0, "the command's success keeps its binding");
}

static void
test_bindings(void)
{
	const erx_dma_layout_t planned = layout();
	erx_dma_ledger_t ledger;
	erx_dma_sequence_t sequence;
	erx_dma_description_t records[RUN_MAX];
	erx_dma_publication_t publication;

	EXPECT(erx_dma_ledger_make(&ledger, &planned, &no_regions), "two rings of one structure, pools before them, pass");
	publication = on(ENDPOINT0, records, run(1, 0, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_BINDINGS,
	    "a run on an endpoint no ring is bound to");
	publication = on(0, records, run(1, 0, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_MEANINGS,
	    "a transfer of endpoint 0 finds no table: a transfer ring needs a binding");
	EXPECT(bind(&ledger, RING0, ENDPOINT0, configure(), &sequence) == ERX_DMA_PASSES, "ring 0 bound to endpoint 0");

	publication = on(ENDPOINT0, records, run(1, BUFFERS, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_BINDINGS,
	    "a TRB naming another ring's pool's buffer");
	publication = on(ENDPOINT0, records, run(1, 2 * BUFFERS + 1, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_NAMES, "a buffer past every pool");
	publication = (erx_dma_publication_t){ .record_count = 1, .records = records, .call = ERX_DMA_PUBLISH_RUN,
	    .endpoint = ENDPOINT0, .bind_count = 1, .binds = { { ENDPOINT1, RING1 } } };
	run(1, 0, records);
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_BINDINGS &&
	    erx_dma_ledger_binding(&ledger, RING1) == 0, "a transfer carries no binding");

	{
		/* No binding, so the check reaches the held rule: the bindings rule comes first. */
		const erx_dma_description_t command = configure();
		const erx_dma_publication_t second = { .record_count = 1, .records = &command, .call = ERX_DMA_PUBLISH_RUN,
		    .reach = { .group = ENDPOINT1 / ERX_DMA_GROUP_ENDPOINTS } };

		EXPECT(erx_dma_publish(&ledger, &second, &sequence) == ERX_DMA_BREAKS_HELD,
		    "a second command while one is in flight: the command ring's pool holds one buffer, the input context");
	}
	{
		/* A Stop Endpoint names no buffer: the room rule refuses it, as the pool's one buffer is one command. */
		const erx_dma_description_t stop = { .structure = ERX_STRUCTURE_XHCI_COMMAND_RING,
		    .meaning = ERX_MEANING_XHCI_TRB_STOP_ENDPOINT_COMMAND };
		const erx_dma_publication_t second = { .record_count = 1, .records = &stop, .call = ERX_DMA_PUBLISH_RUN,
		    .reach = { .group = ENDPOINT0 / ERX_DMA_GROUP_ENDPOINTS, .index = ENDPOINT0 % ERX_DMA_GROUP_ENDPOINTS } };

		EXPECT(erx_dma_publish(&ledger, &second, &sequence) == ERX_DMA_BREAKS_ROOM && erx_dma_ledger_live(&ledger) == 1,
		    "a second command that names no buffer while one is in flight");
	}
	complete_command(&ledger, 0);
	EXPECT(bind(&ledger, RING1, ENDPOINT1, configure(), &sequence) == ERX_DMA_PASSES, "ring 1 bound to endpoint 1");
	publication = on(ENDPOINT0, records, run(1, 0, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_PASSES, "a run on the bound ring");
	publication = on(ENDPOINT1, records, run(1, BUFFERS, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_REACH,
	    "an endpoint its binding command still holds is closed");
	complete_command(&ledger, 1);
	{
		/* What a binding reach may drop is judged without bindings too. */
		const erx_dma_description_t address = { .structure = ERX_STRUCTURE_XHCI_COMMAND_RING,
		    .meaning = ERX_MEANING_XHCI_TRB_ADDRESS_DEVICE_COMMAND, .name_count = 1, .names = { { 2u * BUFFERS, 0 } } };
		const erx_dma_description_t command = configure();
		erx_dma_publication_t drop = { .record_count = 1, .records = &command, .call = ERX_DMA_PUBLISH_RUN,
		    .reach = { .group = ENDPOINT0 / ERX_DMA_GROUP_ENDPOINTS, .drops = 2u } };

		EXPECT(erx_dma_publish(&ledger, &drop, &sequence) == ERX_DMA_BREAKS_BINDINGS, "a Configure Endpoint dropping EP0");
		drop.records = &address;
		drop.reach.drops = 1u << (ENDPOINT0 % ERX_DMA_GROUP_ENDPOINTS);
		EXPECT(erx_dma_publish(&ledger, &drop, &sequence) == ERX_DMA_BREAKS_BINDINGS &&
		    erx_dma_ledger_live(&ledger) == 1, "an Address Device with no binding of EP0, dropping an endpoint");
	}
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_PASSES &&
	    sequence.stores[0].offset == 128, "the other endpoint's run on its own ring, from its own pool");
	erx_dma_ledger_reset(&ledger);
	EXPECT(erx_dma_ledger_binding(&ledger, RING0) == 0 && erx_dma_ledger_idle(&ledger),
	    "the reset's idle report ends every binding");
	EXPECT(bind(&ledger, RING1, ENDPOINT0, configure(), &sequence) == ERX_DMA_PASSES && erx_dma_ledger_acquire(&ledger, EVENTS, 1) &&
	    erx_dma_ledger_complete_command(&ledger, EVENTS, erx_dma_ledger_holding(&ledger, (erx_dma_place_t){ COMMANDS, 0 }),
	    false, retired, &retired_count) && erx_dma_ledger_binding(&ledger, RING1) == 0, "a failed binding command's binding ends");

	/* A drop-and-add: the new ring is bound beside the old while the endpoint is closed. */
	EXPECT(bind(&ledger, RING0, ENDPOINT0, configure(), &sequence) == ERX_DMA_PASSES, "ring 0 bound again");
	{
		/* One command at a time is the ledger's own fact, not only the check's. */
		const erx_dma_description_t command = noop();
		const erx_dma_publication_t second = { .record_count = 1, .records = &command, .call = ERX_DMA_PUBLISH_RUN };
		const erx_dma_place_t place = { COMMANDS, erx_dma_ledger_position(&ledger, COMMANDS).index };

		EXPECT(!erx_dma_ledger_hold(&ledger, &second, &place, 1) && erx_dma_ledger_live(&ledger) == 1,
		    "the ledger holds no second command while one is live");
	}
	complete_command(&ledger, 1);
	{
		const erx_dma_description_t command = configure();
		erx_dma_publication_t drop_add = { .record_count = 1, .records = &command, .call = ERX_DMA_PUBLISH_RUN,
		    .bind_count = 1, .binds = { { ENDPOINT0, RING1 } },
		    .reach = { .group = ENDPOINT0 / ERX_DMA_GROUP_ENDPOINTS, .drops = 1u << (ENDPOINT0 % ERX_DMA_GROUP_ENDPOINTS) },
		    .contexts = carried(ENDPOINT0) };

		drop_add.reach.drops = 0;
		EXPECT(erx_dma_publish(&ledger, &drop_add, &sequence) == ERX_DMA_BREAKS_BINDINGS,
		    "an add of a bound endpoint the command does not drop");
		drop_add.reach.drops = 1u << (ENDPOINT0 % ERX_DMA_GROUP_ENDPOINTS);
		EXPECT(erx_dma_publish(&ledger, &drop_add, &sequence) == ERX_DMA_PASSES &&
		    erx_dma_ledger_bound_table(&ledger, ENDPOINT0) == RING0 && erx_dma_ledger_binding(&ledger, RING1) == ENDPOINT0 &&
		    erx_dma_ledger_closed(&ledger, ENDPOINT0), "a drop-and-add binds the new ring beside the old");
		publication = on(ENDPOINT0, records, run(1, 0, records));
		EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_REACH, "the closed endpoint takes no run");
		complete_command(&ledger, 2);
		EXPECT(erx_dma_ledger_binding(&ledger, RING0) == 0 && erx_dma_ledger_bound_table(&ledger, ENDPOINT0) == RING1 &&
		    !erx_dma_ledger_closed(&ledger, ENDPOINT0), "its success ends the old ring's binding: one ring per endpoint");
	}
	/* A No Op carries no binding: only a command whose meaning's reach binds does. */
	EXPECT(bind(&ledger, RING0, ENDPOINT1, noop(), &sequence) == ERX_DMA_BREAKS_BINDINGS &&
	    erx_dma_ledger_binding(&ledger, RING0) == 0, "a command carrying a binding its meaning does not allow");
}

/* The layout's check of the tables and their bindings. */
static void
test_layout(void)
{
	erx_dma_layout_t planned = layout();
	erx_dma_ledger_t ledger;
	erx_dma_sequence_t sequence;
	erx_dma_description_t records[RING];
	erx_dma_publication_t publication;

	EXPECT(erx_dma_ledger_make(&ledger, &planned, &no_regions), "the harness's layout");
	for (uint32_t index = 0; index < RING; index++)
		records[index] = noop();
	publication = on(0, records, RING);
	EXPECT(erx_dma_publication_check(&ledger, &publication) == ERX_DMA_BREAKS_ROOM &&
	    erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_ROOM,
	    "a run as long as its ring would name a position twice");
	publication = on(0, records, 1);
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_PASSES, "a run on the command ring, which needs no binding");

	planned.tables[RING0].stride = 8;
	EXPECT(!erx_dma_ledger_make(&ledger, &planned, &no_regions), "a ring of TRBs at a stride of 8 bytes");
	planned = layout();
	planned.tables[COMMANDS].structure = ERX_STRUCTURE_VIRTQ_AVAIL;
	planned.tables[COMMANDS].stride = 8;
	EXPECT(!erx_dma_ledger_make(&ledger, &planned, &no_regions),
	    "a ring of a structure with no meanings at a stride other than its link's, which would overrun the ring");
	planned = layout();
	planned.tables[RING0].structure = ERX_STRUCTURE_XHCI_COMMAND_RING;
	EXPECT(!erx_dma_ledger_make(&ledger, &planned, &no_regions),
	    "two tables of one structure that need no binding, between which a run could not choose");
	planned = layout();
	planned.tables[COMMANDS].structure = ERX_STRUCTURE_XHCI_EVENT_RING;
	EXPECT(!erx_dma_ledger_make(&ledger, &planned, &no_regions),
	    "two event rings, of a structure that needs no binding, between which a run could not choose");
	planned = layout();
	planned.tables[RING0].placing = ERX_DMA_PLACED_FREE;
	EXPECT(!erx_dma_ledger_make(&ledger, &planned, &no_regions), "a transfer ring, which needs a binding, placed free");
}

int
main(void)
{
	const erx_dma_layout_t planned = layout();
	erx_dma_ledger_t ledger;
	erx_dma_sequence_t sequence;
	const model_t start = { 0 };

	test_binding_command();
	test_bindings();
	test_layout();
	EXPECT(erx_dma_ledger_make(&ledger, &planned, &no_regions) &&
	    bind(&ledger, RING0, ENDPOINT0, configure(), &sequence) == ERX_DMA_PASSES, "ring 0 bound");
	complete_command(&ledger, 0);
	explore(&ledger, &start, DEPTH);
	printf("erx_device_trb_ring done\n");
	return (0);
}
