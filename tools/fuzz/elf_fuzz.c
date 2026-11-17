/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx/elf_plan.h"
#include "liberx/exec/load_plan.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static bool erx_fuzz_writable(const erx_elf_plan_t *, uint64_t);
static void erx_fuzz_layout(const erx_elf_plan_t *);

/* Whether the eight bytes at offset lie inside one writable segment. */
static bool
erx_fuzz_writable(const erx_elf_plan_t *plan, uint64_t offset)
{
	const erx_image_segment_t *segment;

	for (uint32_t index = 0; index < plan->nloads; index++) {
		segment = &plan->loads[index].segment;
		if (segment->prot == ERX_PROT_RW && offset >= segment->mem_offset &&
		    segment->mem_size >= 8 &&
		    offset - segment->mem_offset <= segment->mem_size - 8)
			return (true);
	}
	return (false);
}

/*
 * erx_exec's layout of an accepted position-independent plan, in a reservation
 * starting off its alignment: the span fits from an aligned base, every step lies
 * whole inside it, a shared map is read-only or read-execute, and a zeroing stays
 * inside the copy mapped just before it.
 */
static void
erx_fuzz_layout(const erx_elf_plan_t *plan)
{
	const uint64_t reserved = UINT64_C(0x40000000) + ERX_PAGE_SIZE;
	const erx_exec_step_t *step, *copy = NULL;
	erx_exec_layout_t layout;
	erx_elf_error_t error;
	uint64_t size;

	if ((plan->flags & ERX_IMAGE_FIXED) != 0) {
		if (erx_exec_reservation(plan, &size, &error))
			abort();
		return;
	}
	if (!erx_exec_reservation(plan, &size, &error) ||
	    !erx_exec_layout(plan, reserved, size, &layout, &error))
		abort();
	if (layout.base % plan->base_alignment != 0 || layout.base < reserved ||
	    layout.base - reserved + plan->span > size ||
	    layout.entry - layout.base >= plan->span)
		abort();
	for (uint32_t index = 0; index < layout.nsteps; index++) {
		step = &layout.steps[index];
		if (step->address < layout.base || step->size == 0 ||
		    step->address - layout.base > plan->span ||
		    step->size > plan->span - (step->address - layout.base))
			abort();
		if (step->kind == ERX_EXEC_MAP &&
		    step->prot != ERX_PROT_R && step->prot != ERX_PROT_RX)
			abort();
		if (step->kind == ERX_EXEC_ZERO && (copy == NULL ||
		    step->address < copy->address ||
		    step->address + step->size != copy->address + copy->size))
			abort();
		copy = step->kind == ERX_EXEC_CHILD ? step : NULL;
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_elf_plan_t plan = {0};
	erx_elf_error_t error;
	erx_elf_relocation_t relocation;

	if (erx_elf_plan(bytes, length, UINT64_C(16) * 1024 * 1024,
	    &plan, &error)) {
		if (plan.nloads == 0 || plan.nloads > ERX_ELF_SEGMENTS_MAX ||
		    plan.output_size > UINT64_C(16) * 1024 * 1024)
			abort();
		for (uint32_t index = 0; index < plan.nloads; index++) {
			if (plan.loads[index].source_offset > length ||
			    plan.loads[index].segment.file_size >
			    length - plan.loads[index].source_offset ||
			    plan.loads[index].segment.mem_offset > plan.span ||
			    plan.loads[index].segment.mem_size >
			    plan.span - plan.loads[index].segment.mem_offset)
				abort();
		}
		/* The table lies in the file, and every write stays in a writable segment. */
		if (plan.relocation_offset > length ||
		    plan.relocation_count > (length - plan.relocation_offset) /
		    ERX_ELF64_RELA_SIZE)
			abort();
		for (uint64_t index = 0; index < plan.relocation_count; index++) {
			relocation = erx_elf_relocation(bytes, &plan, index);
			if (relocation.offset % 8 != 0 ||
			    !erx_fuzz_writable(&plan, relocation.offset))
				abort();
		}
		erx_fuzz_layout(&plan);
	} else if (plan.nloads != 0 || plan.output_size != 0) {
		abort();
	}
	return (0);
}
