/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_exec_load (load.h): the effects around load_plan.h's decisions. Each
 * executable or read-only segment maps the sealed object's own pages, so
 * they are shared with every program that runs the file and never written;
 * each writable segment maps a private copy of its file pages
 * (erx_mem_child), charged to the program's budget and never executable,
 * then its private rest; the relocations write only those copies. Every
 * load ends by releasing its read-only view of the object, and a failed one
 * its reservation too, which removes every mapping made in them; the
 * failure is reported once, at the step that failed, and a release the
 * space refuses makes the outcome refused cleanup.
 */

#include <stdbool.h>
#include <stdint.h>
#include <strings.h>

#include "erx/abi.h"
#include "erx/elf_plan.h"
#include "liberx/backend/api.h"
#include "liberx/exec/load.h"
#include "liberx/exec/load_plan.h"

/* A kernel call that failed: its name and status. */
static bool
erx_exec_call_failed(erx_exec_failure_t *failure, const char *call, int status)
{
	*failure = (erx_exec_failure_t){ .call = call, .status = status };
	return (false);
}

/* A writable segment's file pages: the copy, mapped read-write; the mapping keeps it. */
static int
erx_exec_child(uint64_t object, uint64_t budget, const erx_exec_step_t *step)
{
	uint64_t child;
	int status;

	status = erx_mem_child(object, budget, step->offset, step->size, &child);
	if (status != ERX_OK)
		return (status);
	status = erx_vm_map(ERX_CAP_SELF, step->address, step->size, child, 0, ERX_PROT_RW);
	(void)erx_cap_close((erx_cap_t){ .raw = child });
	return (status);
}

static bool
erx_exec_apply(uint64_t object, uint64_t budget, const erx_exec_step_t *step,
    erx_exec_failure_t *failure)
{
	const char *call = NULL;
	int status = ERX_OK;

	switch (step->kind) {
	case ERX_EXEC_MAP:
		call = "map";
		status = erx_vm_map(ERX_CAP_SELF, step->address, step->size, object, step->offset,
		    step->prot);
		break;
	case ERX_EXEC_CHILD:
		call = "child";
		status = erx_exec_child(object, budget, step);
		break;
	case ERX_EXEC_ZERO:
		bzero((void *)(uintptr_t)step->address, (size_t)step->size);
		break;
	case ERX_EXEC_COMMIT:
		call = "commit";
		status = erx_vm_commit(ERX_CAP_SELF, step->address, step->size);
		break;
	}
	if (status != ERX_OK)
		return (erx_exec_call_failed(failure, call, status));
	return (true);
}

/*
 * The object's pages holding the file, mapped read-only for the plan to
 * read. view->size is set once the view is reserved, so the one cleanup
 * releases it whether or not the map succeeds. A length whose page
 * rounding overflows fails the view as the space would refuse it.
 */
static bool
erx_exec_view(uint64_t object, uint64_t file_bytes, erx_exec_range_t *view,
    erx_exec_failure_t *failure)
{
	uint64_t address, size;
	int status;

	if (__builtin_add_overflow(file_bytes, ERX_PAGE_SIZE - 1, &size))
		return (erx_exec_call_failed(failure, "view", ERX_EINVAL));
	size &= ~((uint64_t)ERX_PAGE_SIZE - 1);
	status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &address);
	if (status != ERX_OK)
		return (erx_exec_call_failed(failure, "view", status));
	*view = (erx_exec_range_t){ .address = address, .size = size };
	status = erx_vm_map(ERX_CAP_SELF, address, size, object, 0, ERX_PROT_R);
	if (status != ERX_OK)
		return (erx_exec_call_failed(failure, "view", status));
	return (true);
}

/*
 * Plans the file's bytes in the view, then reserves, lays out and applies.
 * span->size is set once the span is reserved, for the cleanup.
 */
static bool
erx_exec_place(uint64_t object, uint64_t file_bytes, uint64_t budget,
    const erx_exec_range_t *view, erx_exec_range_t *span,
    erx_exec_layout_t *layout, erx_exec_failure_t *failure)
{
	const uint8_t *file = (const uint8_t *)(uintptr_t)view->address;
	erx_elf_plan_t plan;
	uint64_t reserved, size;
	int status;

	if (!erx_elf_plan(file, (size_t)file_bytes, UINT64_MAX, &plan, &failure->refusal))
		return (false);
	if (!erx_exec_reservation(&plan, &size, &failure->refusal))
		return (false);
	status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &reserved);
	if (status != ERX_OK)
		return (erx_exec_call_failed(failure, "reserve", status));
	*span = (erx_exec_range_t){ .address = reserved, .size = size };
	if (!erx_exec_layout(&plan, span->address, span->size, layout, &failure->refusal))
		return (false);
	for (uint32_t index = 0; index < layout->nsteps; index++) {
		if (!erx_exec_apply(object, budget, &layout->steps[index], failure))
			return (false);
	}
	erx_exec_relocate(file, &plan, layout->base, (uint8_t *)(uintptr_t)layout->base);
	return (true);
}

/* Releases a range; false when the space refuses. */
static bool
erx_exec_unreserve(const erx_exec_range_t *range)
{
	return (range->size == 0 ||
	    erx_vm_release(ERX_CAP_SELF, range->address, range->size) == ERX_OK);
}

erx_exec_outcome_t
erx_exec_load(uint64_t object, uint64_t file_bytes, uint64_t budget,
    erx_exec_image_t *image, erx_exec_failure_t *failure)
{
	erx_exec_range_t view = { 0 }, span = { 0 };
	erx_exec_layout_t layout;
	bool loaded, refused;

	*image = (erx_exec_image_t){ 0 };
	*failure = (erx_exec_failure_t){ 0 };
	loaded = erx_exec_view(object, file_bytes, &view, failure);
	if (loaded)
		loaded = erx_exec_place(object, file_bytes, budget, &view, &span, &layout, failure);
	/* The one cleanup: every load releases its view, a failed one its span too. */
	refused = false;
	if (!loaded && !erx_exec_unreserve(&span))
		refused = true;
	if (!erx_exec_unreserve(&view))
		refused = true;
	if (refused)
		return (ERX_EXEC_CLEANUP_REFUSED);
	if (!loaded)
		return (ERX_EXEC_FAILED);
	*image = (erx_exec_image_t){ .base = layout.base, .entry = layout.entry,
	    .reserved = span.address, .reserved_size = span.size };
	return (ERX_EXEC_LOADED);
}
