/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A host driver for liberx/backend/core/handles.c. It replays every sequence of
 * creates, dups, closes, destroys and one aging hook up to a fixed depth on a table of
 * three entries, and after each step checks every value the table ever handed out,
 * and some it never did, against a model: each object has a serial, a destroy ends it,
 * an entry's generation advances at each close and the entry retires at its last one,
 * free entries are taken first in, first out, and a value is good exactly while its
 * entry is in use at its generation and its object lives. The hook sets the lowest free
 * record's generation, and the generation of the entry the next add takes, to their last
 * values, as the Fiasco backend's test hook does for records, so a sequence that reuses
 * either meets its retirement. Then the fixed cases: a value used after its entry is
 * taken again, an entry's retirement, the reuse order, the limit and the pool running
 * dry, every refusal of the lookup, and a close after the object's destroy. Prints
 * "ok: N checks" or fails with the case and what disagreed.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/core/handles.h"

#define PAGE		((size_t)ERX_PAGE_SIZE)
#define LIMIT		3u
#define DEPTH		6u
#define SERIALS		(DEPTH + 1u)
#define OTHER_KIND	(ERX_BACKEND_OBJECT_MEMORY + 1u)
#define RIGHTS		(ERX_HR_READ | ERX_HR_MAP)
#define GENERATION_LAST	ERX_BACKEND_HANDLE_GENERATION_LAST
#define NUMBER_MASK	((UINT64_C(1) << ERX_CAP_SLOT_BITS) - 1)

typedef enum op {
	OP_CREATE,
	OP_DUP,
	OP_CLOSE,
	OP_DESTROY,
	OP_AGE
} op_t;

/* A step names an entry by number; the driver uses the value the model says that entry has, or last had. */
typedef struct step {
	op_t		op;
	uint32_t	number;
} step_t;

/* What the driver knows of objects, entries and the free list, with no record or table in it. */
typedef struct model {
	uint32_t	entry[LIMIT];		/* the serial plus one an entry names, or 0 */
	uint64_t	generation[LIMIT];	/* an entry's: its value's while in use, the next one's while free */
	uint64_t	issued[LIMIT];		/* the generation of the last value an entry gave, while given[] */
	bool		given[LIMIT];
	uint32_t	queue[LIMIT];		/* the free entries' numbers, first in first */
	uint32_t	queued;
	bool		grown;			/* whether the table has its page, whose entries joined the list */
	bool		live[SERIALS];
	uint32_t	refs[SERIALS];
	uint32_t	record[SERIALS];
	uint32_t	serials;
} model_t;

static uint32_t		 pages_left;
static uint32_t		 pages_held;
static const char	*current_case = "setup";
static unsigned long	 checks;
static step_t		 path[DEPTH];
static uint32_t		 unheld_count;
static uint32_t		 unheld_last;

static _Noreturn void
fail(const char *what, uint64_t detail)
{
	fprintf(stderr, "%s: %s (0x%llx)\n", current_case, what, (unsigned long long)detail);
	for (uint32_t i = 0; i < DEPTH; i++)
		fprintf(stderr, " step %u: op %d entry %u\n", i, (int)path[i].op, path[i].number);
	exit(1);
}

static void
check(bool ok, const char *what, uint64_t detail)
{
	checks++;
	if (!ok)
		fail(what, detail);
}

static uintptr_t
source_take(void)
{
	void *page = NULL;

	if (pages_left == 0)
		return (0);
	if (posix_memalign(&page, PAGE, PAGE) != 0)
		fail("the host gave no page", 0);
	pages_left--;
	pages_held++;
	memset(page, 0xa5, PAGE);
	return ((uintptr_t)page);
}

static void
source_give(uintptr_t page)
{
	if (pages_held == 0)
		fail("more pages given back than taken", page);
	pages_held--;
	free((void *)page);
}

static const erx_backend_grow_pages_t source = { .take = source_take, .give = source_give };

static uint64_t
value_of(uint32_t number, uint64_t generation)
{
	return (generation << ERX_CAP_SLOT_BITS | number);
}

/* The value a step on entry number uses: the one it holds, else the last it gave, else generation 0's. */
static uint64_t
model_value(const model_t *model, uint32_t number)
{
	const uint32_t at = number - 1;

	if (model->entry[at] != 0)
		return (value_of(number, model->generation[at]));
	return (value_of(number, model->given[at] ? model->issued[at] : 0));
}

/* Whether value names an entry in use at its generation, the lookup's entry step, by the model alone. */
static bool
model_entry(const model_t *model, uint64_t value)
{
	const uint64_t number = value & NUMBER_MASK;

	return (number != 0 && number <= LIMIT && model->entry[number - 1] != 0 &&
	    model->generation[number - 1] == value >> ERX_CAP_SLOT_BITS);
}

/* What the lookup must answer for value, of any kind and needing no right, by the model alone. */
static int
model_find(const model_t *model, uint64_t value)
{
	if (!model_entry(model, value))
		return (ERX_ESTALE);
	return (model->live[model->entry[(value & NUMBER_MASK) - 1] - 1] ? ERX_OK : ERX_ESTALE);
}

/* The entry an add takes, first in, first out, the table's one page joining in index order at the first; 0 when none. */
static uint32_t
model_take(model_t *model)
{
	uint32_t number;

	if (model->queued == 0 && !model->grown) {
		model->grown = true;
		for (number = 1; number <= LIMIT; number++)
			model->queue[model->queued++] = number;
	}
	if (model->queued == 0)
		return (0);
	number = model->queue[0];
	memmove(&model->queue[0], &model->queue[1], (model->queued - 1) * sizeof(model->queue[0]));
	model->queued--;
	return (number);
}

/* An add's value, checked against the entry the model took, and that entry given to serial. */
static void
model_give(model_t *model, uint32_t number, uint32_t serial, uint64_t value)
{
	const uint32_t at = number - 1;

	check(value == value_of(number, model->generation[at]), "an add took another entry or generation", value);
	model->entry[at] = serial + 1;
	model->issued[at] = model->generation[at];
	model->given[at] = true;
}

/* A closed entry: its generation advanced and the entry at the list's tail, or retired at its last generation. */
static void
model_release(model_t *model, uint32_t number)
{
	const uint32_t at = number - 1;

	model->entry[at] = 0;
	if (model->generation[at] == GENERATION_LAST)
		return;
	model->generation[at]++;
	model->queue[model->queued++] = number;
}

/* Sets a free entry's generation, as a test hook does. */
static void
entry_age(erx_backend_handles_t *handles, uint32_t number, uint64_t generation)
{
	((erx_backend_handle_entry_t *)erx_backend_grow_table_at(&handles->entries, number - 1))->generation = generation;
}

/* The lowest free record and the entry the next add takes, each set to its last generation. */
static void
age(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, model_t *model)
{
	for (uint32_t index = 0; index < erx_backend_grow_table_capacity(objects); index++)
		if (erx_backend_object_at(objects, index)->kind == ERX_BACKEND_OBJECT_FREE) {
			erx_backend_object_at(objects, index)->generation = UINT32_MAX;
			break;
		}
	if (model->queued == 0)
		return;
	model->generation[model->queue[0] - 1] = GENERATION_LAST;
	entry_age(handles, model->queue[0], GENERATION_LAST);
}

/* One value the core must answer as the model does; a good one names its serial's record. */
static void
check_value(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *handles, const model_t *model,
    uint64_t value)
{
	uint32_t index = UINT32_MAX;
	const int want = model_find(model, value);
	const int got = erx_backend_handle_find(objects, handles, value, ERX_BACKEND_OBJECT_MEMORY, 0, &index);

	check(got == want, "a handle answers otherwise than the model", value);
	if (got == ERX_OK)
		check(index == model->record[model->entry[(value & NUMBER_MASK) - 1] - 1], "a handle names another record",
		    value);
}

/* Every value an entry holds, last gave or gives next, its generation 0's, and values that name no entry. */
static void
check_all(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *handles, const model_t *model)
{
	static const uint64_t strays[] = { ERX_CAP_NULL, LIMIT + 1u, ERX_CAP_SELF, ERX_CAP_SELF_THREAD, UINT64_MAX };
	uint32_t used = 0;

	for (uint32_t number = 1; number <= LIMIT; number++) {
		check_value(objects, handles, model, value_of(number, model->generation[number - 1]));
		check_value(objects, handles, model, model_value(model, number));
		check_value(objects, handles, model, value_of(number, 0));
		used += model->entry[number - 1] != 0;
	}
	for (size_t at = 0; at < sizeof(strays) / sizeof(strays[0]); at++)
		check_value(objects, handles, model, strays[at]);
	check(erx_backend_handles_used(handles) == used, "the table miscounts its entries in use", used);
}

static void
apply(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, model_t *model, const step_t *step)
{
	const uint64_t value = step->number == 0 ? 0 : model_value(model, step->number);
	uint32_t index = UINT32_MAX, number, serial;
	uint64_t handle = 0;
	bool freed = true, live;
	int status;

	switch (step->op) {
	case OP_CREATE:
		check(erx_backend_object_take(objects, ERX_BACKEND_OBJECT_MEMORY, 7, 9, &index) == ERX_OK, "a take failed", 0);
		for (serial = 0; serial < model->serials; serial++)
			check(!model->live[serial] || model->record[serial] != index, "a take reused a live record", index);
		status = erx_backend_handle_add(objects, handles, index, RIGHTS, &handle);
		number = model_take(model);
		if (number == 0) {
			check(status == ERX_ELIMIT, "an add past the limit was given", (uint64_t)status);
			erx_backend_object_unmake(objects, index);
			return;
		}
		check(status == ERX_OK, "an add failed", (uint64_t)status);
		model->record[model->serials] = index;
		model->live[model->serials] = true;
		model->refs[model->serials] = 1;
		model_give(model, number, model->serials++, handle);
		return;
	case OP_DUP:
		status = erx_backend_handle_dup(objects, handles, value, &handle);
		if (model_find(model, value) != ERX_OK) {
			check(status == model_find(model, value), "a dup of a bad handle answered otherwise", value);
			return;
		}
		number = model_take(model);
		if (number == 0) {
			check(status == ERX_ELIMIT, "a dup past the limit was given", (uint64_t)status);
			return;
		}
		check(status == ERX_OK, "a dup failed", (uint64_t)status);
		serial = model->entry[step->number - 1] - 1;
		model->refs[serial]++;
		model_give(model, number, serial, handle);
		return;
	case OP_CLOSE:
		status = erx_backend_handle_close(objects, handles, value, &freed, &index);
		if (!model_entry(model, value)) {
			check(status == ERX_ESTALE, "a close of no entry answered otherwise", (uint64_t)status);
			return;
		}
		check(status == ERX_OK, "a close failed", (uint64_t)status);
		serial = model->entry[step->number - 1] - 1;
		live = model->live[serial];
		if (live)
			model->refs[serial]--;
		check(freed == (live && model->refs[serial] == 0), "a close's last reference misjudged", serial);
		if (freed) {
			check(index == model->record[serial], "a close freed another record", index);
			erx_backend_object_free(objects, index);
			model->live[serial] = false;
		}
		model_release(model, step->number);
		return;
	case OP_DESTROY:
		status = erx_backend_handle_find(objects, handles, value, ERX_BACKEND_OBJECT_ANY, 0, &index);
		check(status == model_find(model, value), "a destroy's find answered otherwise", value);
		if (status == ERX_OK) {
			erx_backend_object_free(objects, index);
			model->live[model->entry[step->number - 1] - 1] = false;
		}
		return;
	case OP_AGE:
		age(objects, handles, model);
		return;
	}
}

/* Replays path[0..depth) on fresh tables, checking after each step. */
static void
replay(uint32_t depth)
{
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	model_t model = { 0 };

	pages_left = UINT32_MAX;
	erx_backend_objects_init(&objects, &source);
	erx_backend_handles_init(&handles, LIMIT, &source);
	for (uint32_t i = 0; i < depth; i++) {
		apply(&objects, &handles, &model, &path[i]);
		check_all(&objects, &handles, &model);
	}
	erx_backend_handles_clear(&handles);
	erx_backend_grow_table_clear(&objects);
	check(pages_held == 0, "a table kept a page", pages_held);
}

static void
explore(uint32_t depth)
{
	static const op_t entry_ops[] = { OP_DUP, OP_CLOSE, OP_DESTROY };

	replay(depth);
	if (depth == DEPTH)
		return;
	path[depth] = (step_t){ .op = OP_CREATE };
	explore(depth + 1);
	path[depth] = (step_t){ .op = OP_AGE };
	explore(depth + 1);
	for (size_t op = 0; op < sizeof(entry_ops) / sizeof(entry_ops[0]); op++)
		for (uint32_t number = 1; number <= LIMIT; number++) {
			path[depth] = (step_t){ .op = entry_ops[op], .number = number };
			explore(depth + 1);
		}
	path[depth] = (step_t){ 0 };
}

/* Fresh tables with every page they ask for: the records, and a handle table of limit entries. */
static void
open_tables(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint32_t limit, const char *name)
{
	current_case = name;
	pages_left = UINT32_MAX;
	erx_backend_objects_init(objects, &source);
	erx_backend_handles_init(handles, limit, &source);
}

static void
close_tables(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles)
{
	erx_backend_handles_clear(handles);
	erx_backend_grow_table_clear(objects);
	check(pages_held == 0, "a table kept a page", pages_held);
}

/* A new record of kind with an entry naming it; returns the entry's value. */
static uint64_t
create(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint32_t kind, uint32_t *index)
{
	uint64_t value = 0;

	check(erx_backend_object_take(objects, kind, 0, 0, index) == ERX_OK &&
	    erx_backend_handle_add(objects, handles, *index, RIGHTS, &value) == ERX_OK, "a create failed", kind);
	return (value);
}

/* Closes value's entry as the last reference to its record, and frees the record. */
static void
close_last(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint64_t value)
{
	uint32_t index = UINT32_MAX;
	bool freed = false;

	check(erx_backend_handle_close(objects, handles, value, &freed, &index) == ERX_OK && freed, "a last close failed",
	    value);
	erx_backend_object_free(objects, index);
}

static void
count_unheld(uint32_t index)
{
	unheld_count++;
	unheld_last = index;
}

/*
 * The old value, used after its entry is taken again, names nothing: ERX_ESTALE, never
 * the new object, whether the new object is of the old one's kind or of another.
 */
static void
case_stale_after_reuse(void)
{
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint32_t index, found = UINT32_MAX;
	uint64_t old, fresh, other;

	open_tables(&objects, &handles, 1, "stale_after_reuse");
	old = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	close_last(&objects, &handles, old);
	fresh = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	check((fresh & NUMBER_MASK) == (old & NUMBER_MASK), "a table of one entry gave another", fresh);
	check(erx_backend_handle_find(&objects, &handles, old, ERX_BACKEND_OBJECT_MEMORY, 0, &found) == ERX_ESTALE,
	    "the old value names the new object", found);
	close_last(&objects, &handles, fresh);
	other = create(&objects, &handles, OTHER_KIND, &index);
	check(erx_backend_handle_find(&objects, &handles, fresh, ERX_BACKEND_OBJECT_MEMORY, 0, &found) == ERX_ESTALE,
	    "a value whose entry another kind took answers otherwise than ERX_ESTALE", other);
	close_tables(&objects, &handles);
}

/* An entry closed at its last generation retires: its value names nothing, and no add takes it again. */
static void
case_retirement(void)
{
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint32_t index, found;
	uint64_t first, second, last, refused = 0;

	open_tables(&objects, &handles, 2, "retirement");
	first = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	close_last(&objects, &handles, first);
	entry_age(&handles, 1, GENERATION_LAST);
	second = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	last = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	check(second == value_of(2, 0) && last == value_of(1, GENERATION_LAST), "the entries came in another order", last);
	check(erx_backend_handle_find(&objects, &handles, last, ERX_BACKEND_OBJECT_MEMORY, 0, &found) == ERX_OK,
	    "a value at the last generation was refused", last);
	close_last(&objects, &handles, last);
	check(erx_backend_handle_find(&objects, &handles, last, ERX_BACKEND_OBJECT_MEMORY, 0, &found) == ERX_ESTALE &&
	    erx_backend_handle_find(&objects, &handles, first, ERX_BACKEND_OBJECT_MEMORY, 0, &found) == ERX_ESTALE,
	    "a retired entry's value was found", last);
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 0, 0, &index) == ERX_OK, "a take failed", 0);
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &refused) == ERX_ELIMIT,
	    "a retired entry was taken again", refused);
	close_last(&objects, &handles, second);
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 0, 0, &index) == ERX_OK, "a take failed", 0);
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &refused) == ERX_OK && refused == value_of(2, 1),
	    "the one entry left was not taken", refused);
	check(erx_backend_handles_used(&handles) == 1, "a retired entry counts as in use", 0);
	close_tables(&objects, &handles);
}

/* Never-used entries in index order, then the entry freed first is taken first. */
static void
case_reuse_order(void)
{
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint64_t value[4];
	uint32_t index;

	open_tables(&objects, &handles, 4, "reuse_order");
	value[0] = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	value[1] = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	check(value[0] == value_of(1, 0) && value[1] == value_of(2, 0), "never-used entries were taken out of index order",
	    value[0]);
	close_last(&objects, &handles, value[0]);
	value[2] = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	value[3] = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	check(value[2] == value_of(3, 0) && value[3] == value_of(4, 0),
	    "a closed entry was taken before a never-used one", value[2]);
	value[0] = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	check(value[0] == value_of(1, 1), "the closed entry was not taken last", value[0]);
	close_last(&objects, &handles, value[2]);
	close_last(&objects, &handles, value[0]);
	value[2] = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	value[0] = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	check(value[2] == value_of(3, 1) && value[0] == value_of(1, 2), "the entry freed first was not taken first",
	    value[2]);
	close_tables(&objects, &handles);
}

/*
 * A table limited only by its pages: an add with a free entry takes no page, the add
 * after the first page's last entry needs a grow, and close_all frees the record once.
 */
static void
case_limits_and_pool(void)
{
	const uint32_t per_page = (uint32_t)(PAGE / sizeof(erx_backend_handle_entry_t));
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint32_t index, found;
	uint64_t handle, fifth = 0;
	bool freed;

	current_case = "limits_and_pool";
	pages_left = 0;
	erx_backend_objects_init(&objects, &source);
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 0, 0, &index) == ERX_ENOMEM,
	    "a take with no page was given", 0);
	pages_left = 2;
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 0, 0, &index) == ERX_OK && index == 0,
	    "the first take is not record 0", index);
	erx_backend_handles_init(&handles, per_page + 1, &source);
	pages_left = 0;
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_ENOMEM,
	    "an add with no page was given", 0);
	check(erx_backend_object_at(&objects, index)->handles == 0, "a refused add counted", 0);
	pages_left = 2;
	for (uint32_t i = 0; i < per_page; i++) {
		check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_OK && handle == i + 1u,
		    "an add within the first page failed", i);
		fifth = i == 4 ? handle : fifth;
	}
	pages_left = 0;
	check(erx_backend_handle_close(&objects, &handles, fifth, &freed, &found) == ERX_OK && !freed,
	    "a close of one of many handles failed", fifth);
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_OK && handle == value_of(5, 1),
	    "an add with a free entry did not take it", handle);
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_ENOMEM,
	    "a grow with no page was given", 0);
	pages_left = 1;
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_OK && handle == per_page + 1u,
	    "the add the limit allows failed", handle);
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_ELIMIT,
	    "an add past the limit was given", 0);
	check(erx_backend_handle_find(&objects, &handles, per_page + 2u, ERX_BACKEND_OBJECT_ANY, 0, &found) == ERX_ESTALE,
	    "an entry past the limit was found", 0);
	check(erx_backend_object_at(&objects, 0)->handles == per_page + 1u &&
	    erx_backend_handles_used(&handles) == per_page + 1u, "the record or the table miscounts its handles", 0);
	unheld_count = 0;
	erx_backend_handles_close_all(&objects, &handles, count_unheld);
	check(unheld_count == 1 && unheld_last == 0 && erx_backend_object_at(&objects, 0)->handles == 0 &&
	    erx_backend_handles_used(&handles) == 0, "close_all misjudged the last handle", unheld_count);
	erx_backend_handles_clear(&handles);
	erx_backend_grow_table_clear(&objects);
	check(pages_held == 0, "a table kept a page", pages_held);
}

/* Every refusal of the lookup, in its order, a dup's rights, and a mapped or kept object outliving its last handle. */
static void
case_refusals(void)
{
	static const uint64_t strays[] = { ERX_CAP_NULL, 2, ERX_CAP_SELF, ERX_CAP_SELF_THREAD, UINT64_MAX };
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint32_t index, found;
	uint64_t handle, copy = 0;
	bool freed;

	open_tables(&objects, &handles, 0, "refusals");
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 3, 4, &index) == ERX_OK, "a take failed", 0);
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_ELIMIT,
	    "a table of no entries took one", 0);
	erx_backend_handles_init(&handles, ERX_CAPS_MAX, &source);
	check(erx_backend_handle_add(&objects, &handles, index, RIGHTS, &handle) == ERX_OK && handle == 1, "an add failed",
	    0);
	for (size_t at = 0; at < sizeof(strays) / sizeof(strays[0]); at++)
		check(erx_backend_handle_find(&objects, &handles, strays[at], ERX_BACKEND_OBJECT_ANY, 0, &found) == ERX_ESTALE,
		    "a value that names no entry in use was found", strays[at]);
	check(erx_backend_handle_find(&objects, &handles, value_of(1, 1), ERX_BACKEND_OBJECT_ANY, 0, &found) == ERX_ESTALE,
	    "a value of another generation was found", 0);
	check(erx_backend_handle_find(&objects, &handles, handle, OTHER_KIND, 0, &found) == ERX_ETYPE,
	    "a kind was not checked", 0);
	check(erx_backend_handle_find(&objects, &handles, handle, OTHER_KIND, ERX_HR_WRITE, &found) == ERX_ETYPE,
	    "the rights were checked before the kind", 0);
	check(erx_backend_handle_find(&objects, &handles, handle, ERX_BACKEND_OBJECT_MEMORY, RIGHTS | ERX_HR_WRITE,
	    &found) == ERX_ERIGHTS, "a right the entry lacks was granted", 0);
	check(erx_backend_handle_find(&objects, &handles, handle, ERX_BACKEND_OBJECT_MEMORY, RIGHTS, &found) == ERX_OK &&
	    found == index, "the rights the entry holds were refused", found);
	check(erx_backend_handle_dup(&objects, &handles, handle, &copy) == ERX_OK &&
	    erx_backend_handle_find(&objects, &handles, copy, ERX_BACKEND_OBJECT_MEMORY, RIGHTS, &found) == ERX_OK &&
	    erx_backend_handle_find(&objects, &handles, copy, ERX_BACKEND_OBJECT_MEMORY, ERX_HR_WRITE, &found) ==
	    ERX_ERIGHTS, "a dup's rights are not its source's", copy);
	check(erx_backend_handle_dup(&objects, &handles, ERX_CAP_NULL, &copy) == ERX_ESTALE &&
	    erx_backend_handle_close(&objects, &handles, ERX_CAP_NULL, &freed, &found) == ERX_ESTALE,
	    "the null handle was dup'd or closed", 0);
	check(erx_backend_object_at(&objects, index)->creator == 3 && erx_backend_object_at(&objects, index)->budget == 4,
	    "a record lost its creator or budget", 0);
	check(erx_backend_handle_close(&objects, &handles, copy, &freed, &found) == ERX_OK && !freed, "a dup's close failed",
	    copy);
	erx_backend_object_at(&objects, index)->mappings = 1;
	check(erx_backend_handle_close(&objects, &handles, 1, &freed, &found) == ERX_OK && !freed,
	    "a mapped object went with its last handle", 0);
	check(erx_backend_handle_close(&objects, &handles, 1, &freed, &found) == ERX_ESTALE, "a closed entry closed again",
	    0);
	erx_backend_object_at(&objects, index)->mappings = 0;
	erx_backend_object_at(&objects, index)->kept = 1;
	check(!erx_backend_object_unreferenced(erx_backend_object_at(&objects, index)), "a kept record went unreferenced",
	    0);
	erx_backend_object_at(&objects, index)->kept = 0;
	check(erx_backend_object_unreferenced(erx_backend_object_at(&objects, index)), "an unreferenced record kept", 0);
	/* A record taken again is not kept, whatever its last object was. */
	erx_backend_object_at(&objects, index)->kept = 1;
	erx_backend_object_free(&objects, index);
	check(erx_backend_object_at(&objects, index)->kind == ERX_BACKEND_OBJECT_FREE &&
	    erx_backend_object_at(&objects, index)->generation == 1, "a free did not move the generation on", 0);
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 3, 4, &found) == ERX_OK && found == index,
	    "a freed record was not taken again", found);
	check(erx_backend_object_at(&objects, index)->kept == 0, "a freed record kept its keep", 0);
	erx_backend_object_unmake(&objects, index);
	check(erx_backend_object_at(&objects, index)->kind == ERX_BACKEND_OBJECT_FREE &&
	    erx_backend_object_at(&objects, index)->generation == 1, "an unmake moved the generation", 0);
	close_tables(&objects, &handles);
}

/*
 * A close of an entry whose object was destroyed, after the record is taken again for
 * a new object: the entry frees, and the new object keeps every holder.
 */
static void
case_close_after_destroy(void)
{
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint32_t index, again, found = UINT32_MAX;
	uint64_t gone, kept;
	bool freed = true;
	int status;

	open_tables(&objects, &handles, 4, "close_after_destroy");
	gone = create(&objects, &handles, ERX_BACKEND_OBJECT_MEMORY, &index);
	erx_backend_object_free(&objects, index);
	kept = create(&objects, &handles, OTHER_KIND, &again);
	check(again == index, "the record was not taken again", again);
	check(erx_backend_handle_find(&objects, &handles, gone, ERX_BACKEND_OBJECT_ANY, 0, &found) == ERX_ESTALE,
	    "a destroyed object's entry names the new one", found);
	status = erx_backend_handle_close(&objects, &handles, gone, &freed, &found);
	check(erx_backend_object_at(&objects, again)->handles == 1, "the new object lost a holder",
	    erx_backend_object_at(&objects, again)->handles);
	check(status == ERX_OK && !freed, "the stale entry's close misjudged the record", found);
	check(erx_backend_handle_find(&objects, &handles, kept, OTHER_KIND, 0, &found) == ERX_OK && found == again,
	    "the new object's handle went with the stale one", kept);
	close_last(&objects, &handles, kept);
	close_tables(&objects, &handles);
}

int
main(void)
{
	case_stale_after_reuse();
	case_reuse_order();
	case_retirement();
	case_limits_and_pool();
	case_refusals();
	case_close_after_destroy();
	current_case = "sequences";
	explore(0);
	printf("ok: %lu checks\n", checks);
	return (0);
}
