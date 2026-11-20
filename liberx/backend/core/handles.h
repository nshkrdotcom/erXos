/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_HANDLES_H
#define ERX_BACKEND_HANDLES_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/core/grow_table.h"

/*
 * Object records and handle tables (docs/design-fiasco.md, "Handles"). The service
 * keeps one table of object records and one handle table per task. A handle's value is
 * laid out as every capability value is (abi/kernel.txt, "Capability values and
 * tables"): bits 0-23 hold the entry's number, its index plus one, so 0 stays
 * ERX_CAP_NULL, and bits 24-63 the entry's generation. An entry names a record and the
 * generation the record had when the entry was made, and holds the rights its holder
 * has to the object.
 *
 * Two generations, each advanced by the one free that changes it. A close advances the
 * entry's, so the value its holder had names nothing from then on; a record's free
 * advances the record's, so an entry made for the object that went names nothing
 * either, until its holder closes it. An entry or a record that reaches the last value
 * of its generation retires at its free and is never taken again, so no generation
 * wraps back to a value a holder may still keep. Free entries are taken first in,
 * first out, and a table grows by a page only when none is free.
 *
 * Every use of a handle goes through erx_backend_handle_find, or erx_backend_handle_close
 * for the holder's own entry, and so through the one lookup: the entry's number within
 * the table, the entry in use and the value's generation equal to the entry's, then
 * the record live at the entry's record generation, each failing ERX_ESTALE; then the
 * kind, ERX_ETYPE; then the rights, ERX_ERIGHTS.
 *
 * Every decision is here and every effect is the caller's: the core says which record
 * a create took, or that a close left a record with no handle and no mapping, and the
 * caller frees what the record's kind holds before it frees the record. The core takes
 * pages only through each table's source, so it builds for the host and its tests run
 * there.
 */

/* What a record is: free, retired, or the kind of object it holds. */
typedef enum erx_backend_object_kind {
	ERX_BACKEND_OBJECT_FREE = 0,
	ERX_BACKEND_OBJECT_RETIRED,
	ERX_BACKEND_OBJECT_MEMORY,
	ERX_BACKEND_OBJECT_GATE,
	ERX_BACKEND_OBJECT_SPACE,
	ERX_BACKEND_OBJECT_BUDGET,
	ERX_BACKEND_OBJECT_GROUP,
	ERX_BACKEND_OBJECT_IRQ
} erx_backend_object_kind_t;

/* The number of the entry a handle names: its index plus one, 0 for ERX_CAP_NULL's, which names none. */
#define ERX_BACKEND_HANDLE_NUMBER_MASK	((UINT64_C(1) << ERX_CAP_SLOT_BITS) - 1)
#define ERX_BACKEND_HANDLE_NUMBER(handle)	((uint32_t)((handle) & ERX_BACKEND_HANDLE_NUMBER_MASK))

/* For erx_backend_handle_find: any live kind will do. */
#define ERX_BACKEND_OBJECT_ANY	UINT32_MAX

/* The last value of an entry's generation, the most a handle's generation bits hold. */
#define ERX_BACKEND_HANDLE_GENERATION_LAST	((UINT64_C(1) << ERX_CAP_GENERATION_BITS) - 1)

/* A record's budget when it is charged to the root's own budget, which has no record. */
#define ERX_BACKEND_BUDGET_ROOT	UINT64_MAX

typedef struct erx_backend_object {
	uint32_t	kind;		/* erx_backend_object_kind_t */
	uint32_t	creator;	/* the task that made it, the one whose destroy is honoured */
	uint64_t	budget;		/* the index of the budget record it is charged to, or ERX_BACKEND_BUDGET_ROOT */
	uint32_t	generation;
	uint32_t	handles;	/* entries in any table naming this record at this generation */
	uint32_t	mappings;	/* maps made of it, which keep it while it has no handle */
	uint32_t	ending;		/* nonzero: ended by the service before it answers (fiasco/object.c) */
	uint32_t	kept;		/* nonzero: kept until the machine ends (erx_fiasco_object_keep) */
} erx_backend_object_t;

typedef struct erx_backend_handle_entry {
	uint64_t	generation;		/* the entry's own: a handle's bits 24-63 while in use, the next one's while free */
	uint32_t	object;			/* the record's index plus one, or 0 for an entry not in use */
	uint32_t	object_generation;	/* the record's generation when the entry was made */
	uint32_t	rights;			/* the holder's erXos rights to the object (ERX_HR_*) */
	uint32_t	next_free;		/* on the free list: the next free entry's number, or 0 at its tail */
} erx_backend_handle_entry_t;

typedef struct erx_backend_handles {
	erx_backend_grow_table_t entries;	/* erx_backend_handle_entry_t */
	uint32_t	limit;			/* the most entries, the cap_limit its space was made with */
	uint32_t	free_first;		/* the free list's head and tail, as entry numbers, or 0 when empty */
	uint32_t	free_last;
} erx_backend_handles_t;

/* The object records, empty, whose pages come from source. */
void	erx_backend_objects_init(erx_backend_grow_table_t *objects, const erx_backend_grow_pages_t *source);

/* The record at index, or NULL past the table. */
erx_backend_object_t	*erx_backend_object_at(const erx_backend_grow_table_t *objects, uint32_t index);

/*
 * Takes the lowest free record for an object of this kind and creator, with no handle
 * and no mapping. ERX_ENOMEM when the table cannot grow.
 */
int	erx_backend_object_take(erx_backend_grow_table_t *objects, uint32_t kind, uint32_t creator, uint64_t budget,
	    uint32_t *index) ERX_WARN_UNUSED_RESULT;

/*
 * Frees a live record: every entry naming it is stale from now on. A record at its
 * last generation is retired and never taken again.
 */
void	erx_backend_object_free(erx_backend_grow_table_t *objects, uint32_t index);

/*
 * Returns a record no entry has ever named, as a create that failed leaves it, to free
 * at the generation it had, so a record that never held an object stays at generation 0.
 */
void	erx_backend_object_unmake(erx_backend_grow_table_t *objects, uint32_t index);

/* Whether a record holds an object: neither free nor retired. */
bool	erx_backend_object_live(const erx_backend_object_t *);

/* Whether a live record has no handle, no mapping and no keep, and so is to be freed. */
bool	erx_backend_object_unreferenced(const erx_backend_object_t *);

/*
 * An empty handle table of at most limit entries; a table holds no more than its
 * grow table's limit either, whatever limit says.
 */
void	erx_backend_handles_init(erx_backend_handles_t *, uint32_t limit, const erx_backend_grow_pages_t *source);

/* How many of the table's entries are in use. */
uint32_t	erx_backend_handles_used(const erx_backend_handles_t *);

/*
 * Adds an entry naming the live record at index with these rights, in the free list's
 * first entry, and counts it in the record. ERX_ELIMIT when every entry up to the
 * limit is in use; ERX_ENOMEM when the list is empty and the table cannot grow.
 */
int	erx_backend_handle_add(erx_backend_grow_table_t *objects, erx_backend_handles_t *, uint32_t index,
	    uint32_t rights, uint64_t *handle) ERX_WARN_UNUSED_RESULT;

/*
 * The record a handle names, which must be of kind, or of any live kind for
 * ERX_BACKEND_OBJECT_ANY, through an entry holding every right of needed. ERX_ESTALE
 * for a value that names no entry in use at its generation, or whose object has gone;
 * ERX_ETYPE for a live object of another kind; ERX_ERIGHTS for an entry that lacks a
 * right of needed.
 */
int	erx_backend_handle_find(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *, uint64_t handle,
	    uint32_t kind, uint32_t needed, uint32_t *index) ERX_WARN_UNUSED_RESULT;

/*
 * Adds a second entry naming what handle names, at handle's rights, and gives the record
 * and the rights the copy names: erx_backend_handle_find's refusals, then
 * erx_backend_handle_add's.
 */
int	erx_backend_handle_dup(erx_backend_grow_table_t *objects, erx_backend_handles_t *, uint64_t handle,
	    uint64_t *copy, uint32_t *index, uint32_t *rights) ERX_WARN_UNUSED_RESULT;

/*
 * Frees handle's entry, whether or not its object still lives: the lookup's entry step
 * alone, so ERX_ESTALE for a value that names no entry in use at its generation. The
 * entry takes a holder off its record only while the record is the object the entry
 * was made for. *freed is set to whether the entry was the last reference to a live
 * record, which the caller then frees. *index is set to the record whenever the entry
 * named a live one, and left alone for a stale entry.
 */
int	erx_backend_handle_close(erx_backend_grow_table_t *objects, erx_backend_handles_t *, uint64_t handle,
	    bool *freed, uint32_t *index) ERX_WARN_UNUSED_RESULT;

/*
 * Closes every entry in use, as erx_backend_handle_close does, and calls unheld with
 * each live record whose last reference that was, which the caller then frees.
 */
void	erx_backend_handles_close_all(erx_backend_grow_table_t *objects, erx_backend_handles_t *,
	    void (*unheld)(uint32_t index));

/* Gives the table's pages back; its entries must all have been closed. */
void	erx_backend_handles_clear(erx_backend_handles_t *);

#endif /* ERX_BACKEND_HANDLES_H */
