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
 * then its private rest; the relocations write only those copies. A
 * failure releases the reservation and the view, which removes every
 * mapping made in them, and is reported once, at the step that failed.
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

/* Plans the viewed bytes, then reserves, lays out and applies; image->view is already set. */
static bool
erx_exec_place(uint64_t object, uint64_t budget, erx_exec_image_t *image,
    erx_exec_failure_t *failure)
{
	const uint8_t *file = (const uint8_t *)(uintptr_t)image->view;
	erx_exec_layout_t layout;
	erx_elf_plan_t plan;
	uint64_t reserved, size;
	int status;

	*failure = (erx_exec_failure_t){ 0 };
	if (!erx_elf_plan(file, (size_t)image->view_size, UINT64_MAX, &plan, &failure->refusal))
		return (false);
	if (!erx_exec_reservation(&plan, &size, &failure->refusal))
		return (false);
	status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &reserved);
	if (status != ERX_OK)
		return (erx_exec_call_failed(failure, "reserve", status));
	image->reserved = reserved;
	image->reserved_size = size;
	if (!erx_exec_layout(&plan, image->reserved, image->reserved_size, &layout, &failure->refusal))
		return (false);
	for (uint32_t index = 0; index < layout.nsteps; index++) {
		if (!erx_exec_apply(object, budget, &layout.steps[index], failure))
			return (false);
	}
	erx_exec_relocate(file, &plan, layout.base, (uint8_t *)(uintptr_t)layout.base);
	image->base = layout.base;
	image->entry = layout.entry;
	return (true);
}

bool
erx_exec_load(uint64_t object, uint64_t object_size, uint64_t budget,
    erx_exec_image_t *image, erx_exec_failure_t *failure)
{
	int status;

	*image = (erx_exec_image_t){ .view_size = object_size };
	status = erx_vm_reserve(ERX_CAP_SELF, 0, object_size, 0, &image->view);
	if (status != ERX_OK)
		return (erx_exec_call_failed(failure, "view", status));
	status = erx_vm_map(ERX_CAP_SELF, image->view, object_size, object, 0, ERX_PROT_R);
	if (status != ERX_OK) {
		(void)erx_vm_release(ERX_CAP_SELF, image->view, object_size);
		return (erx_exec_call_failed(failure, "view", status));
	}
	if (erx_exec_place(object, budget, image, failure))
		return (true);
	if (image->reserved_size != 0)
		(void)erx_vm_release(ERX_CAP_SELF, image->reserved, image->reserved_size);
	(void)erx_vm_release(ERX_CAP_SELF, image->view, object_size);
	return (false);
}
