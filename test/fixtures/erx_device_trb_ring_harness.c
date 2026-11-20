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

/* Two transfer rings of RING TRBs, the last each one's link, each with a pool of two buffers. */
enum { RING = 5, RING0 = 0, RING1 = 1, EVENTS = 2, BUFFERS = 2, DEPTH = 8, RUN_MAX = 3 };
#define BASE		UINT64_C(0x40000)
#define ENDPOINT0	UINT32_C(0x21)	/* slot 1, EP0 */
#define ENDPOINT1	UINT32_C(0x22)
#define NO_BUFFER	UINT32_MAX

static const erx_dma_regions_t no_regions;

static erx_dma_layout_t
layout(void)
{
	return ((erx_dma_layout_t){
		.memory_size = 1024, .device_base = BASE, .address_bits = 64, .granule = 64, .table_count = 3,
		.tables = {
			{ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .placing = ERX_DMA_PLACED_RING, .pool = 0,
			  .region = 0, .region_length = 128, .first = 0, .count = RING, .stride = 16 },
			{ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .placing = ERX_DMA_PLACED_RING, .pool = 1,
			  .region = 128, .region_length = 128, .first = 128, .count = RING, .stride = 16 },
			{ .structure = ERX_STRUCTURE_XHCI_EVENT_RING, .region = 256, .region_length = 128, .first = 256,
			  .count = 8, .stride = 16 },
		},
		.pool_count = 2,
		.pools = { { .first = 512, .count = BUFFERS, .size = 64, .stride = 64 },
			   { .first = 384, .count = BUFFERS, .size = 64, .stride = 64 } },
	});
}

static erx_dma_description_t
normal(uint32_t buffer, uint32_t length)
{
	return ((erx_dma_description_t){ .structure = ERX_STRUCTURE_XHCI_TRANSFER_RING, .meaning = ERX_MEANING_XHCI_TRB_NORMAL,
	    .described.xhci_trb_normal = { .status_length = length, .control_interrupt_on_short = 1,
	    .control_interrupt_on_completion = 1 }, .name_count = 1, .names = { { buffer, 0 } } });
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
		checked = erx_dma_publication_check(&next, &publication);
		verdict = erx_dma_publish(&next, &publication, &sequence);
		EXPECT(checked == verdict, "the check's verdict is the publication's");
		if (!fits) {
			EXPECT(checked == ERX_DMA_BREAKS_ROOM, "a run over a held TRB breaks the room rule");
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

static void
test_bindings(void)
{
	const erx_dma_layout_t planned = layout();
	erx_dma_ledger_t ledger;
	erx_dma_sequence_t sequence;
	erx_dma_description_t records[RUN_MAX];
	erx_dma_publication_t publication;
	erx_xhci_trb_link_t link;

	EXPECT(erx_dma_ledger_make(&ledger, &planned, &no_regions), "two rings of one structure, pools before them, pass");
	publication = on(ENDPOINT0, records, run(1, 0, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_BINDINGS,
	    "a run on an endpoint no ring is bound to");
	EXPECT(erx_dma_bind(&ledger, RING0, ENDPOINT0, &sequence), "a ring bound to an endpoint");
	memcpy(&link, sequence.stores[0].bytes, sizeof(link));
	EXPECT(sequence.zero_count == 1 && sequence.zeros[0].offset == 0 && sequence.zeros[0].length == 128 &&
	    sequence.clean_count == 1 && sequence.store_count == 1 && sequence.stores[0].offset == (RING - 1) * 16u &&
	    erx_xhci_trb_link_control_cycle_get(link.control) == 1,
	    "a binding zeroes the ring, writes its link with cycle 1 and cleans it");
	EXPECT(!erx_dma_bind(&ledger, RING0, ENDPOINT1, &sequence) && !erx_dma_bind(&ledger, EVENTS, ENDPOINT1, &sequence) &&
	    !erx_dma_ledger_bind(&ledger, RING1, 0), "a bound ring, a table that is no ring and endpoint 0 are refused");
	EXPECT(erx_dma_ledger_bound_table(&ledger, ENDPOINT0) == RING0 && erx_dma_ledger_binding(&ledger, RING0) == ENDPOINT0,
	    "the endpoint's ring");

	publication = on(ENDPOINT0, records, run(1, BUFFERS, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_BINDINGS,
	    "a TRB naming another ring's pool's buffer");
	publication = on(ENDPOINT0, records, run(1, 2 * BUFFERS, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_NAMES, "a buffer past every pool");

	EXPECT(erx_dma_bind(&ledger, RING1, ENDPOINT0, &sequence), "a second ring bound to one endpoint");
	publication = on(ENDPOINT0, records, run(1, 0, records));
	EXPECT(erx_dma_ledger_bound_table(&ledger, ENDPOINT0) == -1 &&
	    erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_BINDINGS,
	    "a run on an endpoint with two rings has no ring");
	EXPECT(erx_dma_ledger_unbind(&ledger, RING1) && erx_dma_bind(&ledger, RING1, ENDPOINT1, &sequence),
	    "an idle ring is unbound and bound again");

	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_PASSES, "a run on the bound ring");
	EXPECT(!erx_dma_ledger_unbind(&ledger, RING0), "a ring a run holds stays bound");
	publication = on(ENDPOINT1, records, run(1, BUFFERS, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_PASSES &&
	    sequence.stores[0].offset == 128, "the other endpoint's run on its own ring, from its own pool");
	erx_dma_ledger_reset(&ledger);
	EXPECT(erx_dma_ledger_binding(&ledger, RING0) == 0 && erx_dma_ledger_idle(&ledger),
	    "the reset's idle report ends every binding");
}

/* A ring that is its structure's one table, as the command ring is, takes runs unbound. */
static void
test_sole_ring(void)
{
	erx_dma_layout_t planned = layout();
	erx_dma_ledger_t ledger;
	erx_dma_sequence_t sequence;
	erx_dma_description_t records[RING];
	erx_dma_publication_t publication;

	planned.tables[RING1].structure = ERX_STRUCTURE_XHCI_COMMAND_RING;
	EXPECT(erx_dma_ledger_make(&ledger, &planned, &no_regions), "one transfer ring and a command ring");
	for (uint32_t index = 0; index < RING; index++)
		records[index] = status();
	publication = on(0, records, RING);
	EXPECT(erx_dma_publication_check(&ledger, &publication) == ERX_DMA_BREAKS_ROOM &&
	    erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_BREAKS_ROOM,
	    "a run as long as its ring would name a position twice");
	publication = on(0, records, run(1, 0, records));
	EXPECT(erx_dma_publish(&ledger, &publication, &sequence) == ERX_DMA_PASSES, "a run on the sole ring");
	EXPECT(!erx_dma_bind(&ledger, RING0, ENDPOINT0, &sequence),
	    "a ring a run holds is not bound, which would zero the TRBs the device holds");
}

int
main(void)
{
	const erx_dma_layout_t planned = layout();
	erx_dma_ledger_t ledger;
	erx_dma_sequence_t sequence;
	const model_t start = { 0 };

	test_bindings();
	test_sole_ring();
	EXPECT(erx_dma_ledger_make(&ledger, &planned, &no_regions) && erx_dma_bind(&ledger, RING0, ENDPOINT0, &sequence),
	    "ring 0 bound");
	explore(&ledger, &start, DEPTH);
	printf("erx_device_trb_ring done\n");
	return (0);
}
