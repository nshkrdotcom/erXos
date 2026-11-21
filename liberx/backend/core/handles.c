/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Object records and handle tables: see handles.h. Both are grow tables, so a record
 * or an entry never moves and every reference is an index. A record is taken by a
 * linear search, lowest first; an entry from the head of its table's free list, whose
 * links live in the free entries themselves.
 */

#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/core/handles.h"


_Static_assert(ERX_CAP_SLOT_BITS + ERX_CAP_GENERATION_BITS == 64, "a handle is an entry's number and its generation");
/* The grow table's limit bounds every table, the root's included, whatever limit it was opened with. */
_Static_assert((uint64_t)ERX_BACKEND_GROW_PAGES_MAX * (ERX_PAGE_SIZE / sizeof(erx_backend_handle_entry_t)) <= ERX_CAPS_MAX,
    "every entry's number is at most caps_max");
_Static_assert(ERX_CAPS_MAX < (ERX_CAP_SELF_THREAD & ERX_BACKEND_HANDLE_NUMBER_MASK) && ERX_CAPS_MAX < (ERX_CAP_SELF & ERX_BACKEND_HANDLE_NUMBER_MASK),
    "no entry's number is a reserved value's");

static int	handle_lookup(const erx_backend_grow_table_t *, const erx_backend_handles_t *, uint64_t, uint32_t, uint32_t,
		    const erx_backend_handle_entry_t **);
static uint32_t	entries_usable(const erx_backend_handles_t *);
static int	entries_grow(erx_backend_handles_t *);
static erx_backend_handle_entry_t *entry_slot(const erx_backend_handles_t *, uint32_t);
static erx_backend_handle_entry_t *entry_in_use(const erx_backend_handles_t *, uint64_t);
static erx_backend_handle_entry_t *entry_step(const erx_backend_handles_t *, uint64_t);
static bool	entry_live(const erx_backend_grow_table_t *, const erx_backend_handle_entry_t *);
static void	entry_close(erx_backend_grow_table_t *, erx_backend_handles_t *, uint32_t, bool *, uint32_t *);
static void	entry_append(erx_backend_handles_t *, uint32_t);

void
erx_backend_objects_init(erx_backend_grow_table_t *objects, const erx_backend_grow_pages_t *source)
{
	erx_backend_grow_table_init(objects, sizeof(erx_backend_object_t), source);
}

erx_backend_object_t *
erx_backend_object_at(const erx_backend_grow_table_t *objects, uint32_t index)
{
	return (erx_backend_grow_table_at(objects, index));
}

int
erx_backend_object_take(erx_backend_grow_table_t *objects, uint32_t kind, uint32_t creator, uint64_t budget,
    uint32_t *index)
{
	const uint32_t capacity = erx_backend_grow_table_capacity(objects);
	uint32_t found = 0;
	erx_backend_object_t *record;

	while (found < capacity && erx_backend_object_at(objects, found)->kind != ERX_BACKEND_OBJECT_FREE)
		found++;
	/* A record a grow adds reads zero: free, at generation 0. */
	if (found == capacity && (capacity == UINT32_MAX || erx_backend_grow_table_room(objects, capacity + 1) != ERX_OK))
		return (ERX_ENOMEM);
	record = erx_backend_object_at(objects, found);
	record->kind = kind;
	record->creator = creator;
	record->budget = budget;
	record->handles = 0;
	record->mappings = 0;
	record->ending = 0;
	record->kept = 0;
	*index = found;
	return (ERX_OK);
}

void
erx_backend_object_free(erx_backend_grow_table_t *objects, uint32_t index)
{
	erx_backend_object_t *const record = erx_backend_object_at(objects, index);

	record->handles = 0;
	record->mappings = 0;
	record->ending = 0;
	record->kept = 0;
	if (record->generation == UINT32_MAX) {
		record->kind = ERX_BACKEND_OBJECT_RETIRED;
		return;
	}
	record->generation++;
	record->kind = ERX_BACKEND_OBJECT_FREE;
}

void
erx_backend_object_unmake(erx_backend_grow_table_t *objects, uint32_t index)
{
	erx_backend_object_at(objects, index)->kind = ERX_BACKEND_OBJECT_FREE;
}

bool
erx_backend_object_live(const erx_backend_object_t *record)
{
	return (record->kind != ERX_BACKEND_OBJECT_FREE && record->kind != ERX_BACKEND_OBJECT_RETIRED);
}

bool
erx_backend_object_unreferenced(const erx_backend_object_t *record)
{
	return (record->handles == 0 && record->mappings == 0 && record->kept == 0);
}

void
erx_backend_handles_init(erx_backend_handles_t *handles, uint32_t limit, const erx_backend_grow_pages_t *source)
{
	erx_backend_grow_table_init(&handles->entries, sizeof(erx_backend_handle_entry_t), source);
	handles->limit = limit;
	handles->free_first = 0;
	handles->free_last = 0;
}

uint32_t
erx_backend_handles_used(const erx_backend_handles_t *handles)
{
	uint32_t used = 0;

	for (uint32_t slot = 0; slot < entries_usable(handles); slot++)
		used += entry_slot(handles, slot)->object != 0;
	return (used);
}

int
erx_backend_handle_add(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint32_t index,
    uint32_t rights, uint64_t *handle)
{
	erx_backend_object_t *const record = erx_backend_object_at(objects, index);
	erx_backend_handle_entry_t *entry;
	uint32_t number;

	if (handles->free_first == 0) {
		const int status = entries_grow(handles);

		if (status != ERX_OK)
			return (status);
	}
	number = handles->free_first;
	entry = entry_slot(handles, number - 1);
	handles->free_first = entry->next_free;
	if (handles->free_first == 0)
		handles->free_last = 0;
	entry->next_free = 0;
	entry->object = index + 1;
	entry->object_generation = record->generation;
	entry->rights = rights;
	record->handles++;
	*handle = entry->generation << ERX_CAP_SLOT_BITS | number;
	return (ERX_OK);
}

int
erx_backend_handle_find(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *handles, uint64_t handle,
    uint32_t kind, uint32_t needed, uint32_t *index)
{
	const erx_backend_handle_entry_t *entry;
	const int status = handle_lookup(objects, handles, handle, kind, needed, &entry);

	if (status == ERX_OK)
		*index = entry->object - 1;
	return (status);
}

int
erx_backend_handle_dup(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint64_t handle,
    uint64_t *copy, uint32_t *index, uint32_t *rights)
{
	const erx_backend_handle_entry_t *entry;
	const int status = handle_lookup(objects, handles, handle, ERX_BACKEND_OBJECT_ANY, 0, &entry);

	if (status != ERX_OK)
		return (status);
	/* The add may grow the table, so the entry is read before it. */
	*index = entry->object - 1;
	*rights = entry->rights;
	return (erx_backend_handle_add(objects, handles, *index, *rights, copy));
}

int
erx_backend_handle_close(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint64_t handle,
    bool *freed, uint32_t *index)
{
	erx_backend_handle_entry_t *const entry = entry_step(handles, handle);

	if (entry == NULL)
		return (ERX_ESTALE);
	entry_close(objects, handles, (uint32_t)(handle & ERX_BACKEND_HANDLE_NUMBER_MASK), freed, index);
	return (ERX_OK);
}

void
erx_backend_handles_close_all(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles,
    void (*unheld)(uint32_t index))
{
	for (uint32_t number = 1; number <= entries_usable(handles); number++) {
		uint32_t index;
		bool freed;

		if (entry_slot(handles, number - 1)->object == 0)
			continue;
		entry_close(objects, handles, number, &freed, &index);
		if (freed)
			unheld(index);
	}
}

void
erx_backend_handles_clear(erx_backend_handles_t *handles)
{
	erx_backend_grow_table_clear(&handles->entries);
	handles->free_first = 0;
	handles->free_last = 0;
}

/*
 * The one lookup. The entry step (the number within the table, the entry in use, the
 * generation) and then the object step (the record live at the entry's record
 * generation) each fail ERX_ESTALE, before the kind and the rights are looked at, so
 * ERX_ETYPE means a live object of another kind and nothing else.
 */
static int
handle_lookup(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *handles, uint64_t handle,
    uint32_t kind, uint32_t needed, const erx_backend_handle_entry_t **found)
{
	const erx_backend_handle_entry_t *const entry = entry_step(handles, handle);

	if (entry == NULL || !entry_live(objects, entry))
		return (ERX_ESTALE);
	if (kind != ERX_BACKEND_OBJECT_ANY && erx_backend_object_at(objects, entry->object - 1)->kind != kind)
		return (ERX_ETYPE);
	if ((entry->rights & needed) != needed)
		return (ERX_ERIGHTS);
	*found = entry;
	return (ERX_OK);
}

/* How many entries may be used: those the table has pages for, up to its limit. */
static uint32_t
entries_usable(const erx_backend_handles_t *handles)
{
	const uint32_t capacity = erx_backend_grow_table_capacity(&handles->entries);

	return (capacity < handles->limit ? capacity : handles->limit);
}

/*
 * Grows the table by a page for an add that found the free list empty: the page's
 * entries up to the limit join the list in index order. ERX_ELIMIT when the table has
 * every entry its limit allows; ERX_ENOMEM when it cannot grow.
 */
static int
entries_grow(erx_backend_handles_t *handles)
{
	const uint32_t usable = entries_usable(handles);

	if (usable >= handles->limit)
		return (ERX_ELIMIT);
	if (erx_backend_grow_table_room(&handles->entries, usable + 1) != ERX_OK)
		return (ERX_ENOMEM);
	for (uint32_t number = usable + 1; number <= entries_usable(handles); number++)
		entry_append(handles, number);
	return (ERX_OK);
}

/* The entry at an index below the capacity, free or in use. */
static erx_backend_handle_entry_t *
entry_slot(const erx_backend_handles_t *handles, uint32_t slot)
{
	return (erx_backend_grow_table_at(&handles->entries, slot));
}

/* The entry in use that handle's number names within the table, whatever its generation, or NULL. */
static erx_backend_handle_entry_t *
entry_in_use(const erx_backend_handles_t *handles, uint64_t handle)
{
	const uint64_t number = handle & ERX_BACKEND_HANDLE_NUMBER_MASK;
	erx_backend_handle_entry_t *entry;

	if (number == 0 || number > entries_usable(handles))
		return (NULL);
	entry = entry_slot(handles, (uint32_t)(number - 1));
	return (entry->object != 0 ? entry : NULL);
}

/* The lookup's entry step: the entry in use that handle names, at handle's generation, or NULL. */
static erx_backend_handle_entry_t *
entry_step(const erx_backend_handles_t *handles, uint64_t handle)
{
	erx_backend_handle_entry_t *const entry = entry_in_use(handles, handle);

	return (entry != NULL && entry->generation == handle >> ERX_CAP_SLOT_BITS ? entry : NULL);
}

/* The lookup's object step: whether the record an entry in use names is still the object the entry was made for. */
static bool
entry_live(const erx_backend_grow_table_t *objects, const erx_backend_handle_entry_t *entry)
{
	const erx_backend_object_t *const record = erx_backend_object_at(objects, entry->object - 1);

	return (record != NULL && erx_backend_object_live(record) && record->generation == entry->object_generation);
}

/*
 * Frees the entry in use at number: a holder off its record while the record is the
 * object the entry was made for, then the entry's generation advanced and the entry at
 * the free list's tail, or, at its last generation, retired and never taken again.
 */
static void
entry_close(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint32_t number, bool *freed,
    uint32_t *index)
{
	erx_backend_handle_entry_t *const entry = entry_slot(handles, number - 1);
	erx_backend_object_t *record;

	*freed = false;
	if (entry_live(objects, entry)) {
		record = erx_backend_object_at(objects, entry->object - 1);
		record->handles--;
		*freed = erx_backend_object_unreferenced(record);
		*index = entry->object - 1;
	}
	entry->object = 0;
	if (entry->generation == ERX_BACKEND_HANDLE_GENERATION_LAST)
		return;
	entry->generation++;
	entry_append(handles, number);
}

/* Puts the free entry at number at the free list's tail. */
static void
entry_append(erx_backend_handles_t *handles, uint32_t number)
{
	entry_slot(handles, number - 1)->next_free = 0;
	if (handles->free_last == 0)
		handles->free_first = number;
	else
		entry_slot(handles, handles->free_last - 1)->next_free = number;
	handles->free_last = number;
}
