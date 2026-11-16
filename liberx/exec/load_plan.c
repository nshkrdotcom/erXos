/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_exec's decisions (load_plan.h): where an executable goes in its
 * reservation, which steps map each segment, and the relocations. The
 * layout is made whole before load.c applies any step, so a refusal leaves
 * nothing to undo but the reservation.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/elf_plan.h"
#include "liberx/exec/load_plan.h"

static bool
erx_exec_fail(erx_elf_error_t *error, const char *reason, uint64_t offset)
{
	*error = (erx_elf_error_t){ .reason = reason, .offset = offset };
	return (false);
}

/* Bytes up to whole pages; the planner bounds every size below the user limit. */
static uint64_t
erx_exec_pages(uint64_t bytes)
{
	return ((bytes + ERX_PAGE_SIZE - 1) & ~((uint64_t)ERX_PAGE_SIZE - 1));
}

static void
erx_exec_add(erx_exec_layout_t *out, erx_exec_step_t step)
{
	out->steps[out->nsteps++] = step;
}

bool
erx_exec_reservation(const erx_elf_plan_t *plan, uint64_t *size,
    erx_elf_error_t *error)
{
	if ((plan->flags & ERX_IMAGE_FIXED) != 0)
		return (erx_exec_fail(error, "fixed_image", plan->fixed_base));
	if (__builtin_add_overflow(plan->span,
	    (uint64_t)plan->base_alignment - ERX_PAGE_SIZE, size))
		return (erx_exec_fail(error, "reservation", plan->span));
	return (true);
}

/*
 * A writable segment: its file pages as a private copy, zeros past its file
 * size in the last of them, and the rest committed, which reads as zeros. A
 * segment with no file bytes is committed whole.
 */
static void
erx_exec_writable(erx_exec_layout_t *out, const erx_elf_load_t *load,
    uint64_t address)
{
	const uint64_t file_bytes = erx_exec_pages(load->segment.file_size);
	const uint64_t mem_bytes = erx_exec_pages(load->segment.mem_size);

	if (file_bytes != 0) {
		erx_exec_add(out, (erx_exec_step_t){ .kind = ERX_EXEC_CHILD,
		    .address = address, .size = file_bytes,
		    .offset = load->source_offset });
	}
	if (file_bytes != load->segment.file_size) {
		erx_exec_add(out, (erx_exec_step_t){ .kind = ERX_EXEC_ZERO,
		    .address = address + load->segment.file_size,
		    .size = file_bytes - load->segment.file_size });
	}
	if (mem_bytes != file_bytes) {
		erx_exec_add(out, (erx_exec_step_t){ .kind = ERX_EXEC_COMMIT,
		    .address = address + file_bytes,
		    .size = mem_bytes - file_bytes });
	}
}

bool
erx_exec_layout(const erx_elf_plan_t *plan, uint64_t reserved,
    uint64_t reserved_size, erx_exec_layout_t *out, erx_elf_error_t *error)
{
	const uint64_t alignment = plan->base_alignment;
	const erx_elf_load_t *load;
	uint64_t base, end, limit;

	/* The first aligned address of the reservation, and the span from it inside. */
	if (__builtin_add_overflow(reserved, alignment - 1, &base) ||
	    __builtin_add_overflow(reserved, reserved_size, &limit))
		return (erx_exec_fail(error, "reservation", reserved));
	base &= ~(alignment - 1);
	if (__builtin_add_overflow(base, plan->span, &end) || end > limit)
		return (erx_exec_fail(error, "reservation", reserved));
	*out = (erx_exec_layout_t){ .base = base, .entry = base + plan->entry };
	for (uint32_t index = 0; index < plan->nloads; index++) {
		load = &plan->loads[index];
		if (load->segment.prot == ERX_PROT_RW) {
			erx_exec_writable(out, load, base + load->segment.mem_offset);
			continue;
		}
		/* Shared with every program that runs the file: as long in memory as in it. */
		erx_exec_add(out, (erx_exec_step_t){ .kind = ERX_EXEC_MAP,
		    .prot = load->segment.prot,
		    .address = base + load->segment.mem_offset,
		    .size = erx_exec_pages(load->segment.mem_size),
		    .offset = load->source_offset });
	}
	return (true);
}

static void
erx_exec_put64(uint8_t *bytes, uint64_t value)
{
	for (size_t index = 0; index < sizeof(value); index++)
		bytes[index] = (uint8_t)(value >> (8 * index));
}

void
erx_exec_relocate(const uint8_t *file, const erx_elf_plan_t *plan,
    uint64_t base, uint8_t *image)
{
	erx_elf_relocation_t relocation;

	for (uint64_t index = 0; index < plan->relocation_count; index++) {
		relocation = erx_elf_relocation(file, plan, index);
		/* The value is the program's own; unsigned addition wraps modulo 2^64. */
		erx_exec_put64(image + relocation.offset, base + relocation.addend);
	}
}
