/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_EXEC_LOAD_PLAN_H
#define LIBERX_EXEC_LOAD_PLAN_H

/*
 * The pure core of the loader erx_exec (docs/design-programs.md, "What a
 * program can start", "An executable file", "Placing and relocating"): from
 * the plan erx_elf_plan made of a code object's bytes, the reservation the
 * executable needs, the steps that map it into that reservation, decided
 * whole before the first is applied, and the relocations written into the
 * mapped image. It reads only its arguments and writes only its result and
 * the image it is handed, so it builds and is tested on the host
 * (test/host/exec_load_test.rb); load.c applies its steps.
 *
 * The plan is erx_elf_plan's of the object's whole bytes, a whole number of
 * pages, so a segment's source pages, rounded up, lie in the object. A
 * position-independent plan's virtual origin is 0, so its offsets, a
 * relocation's among them, are offsets from the base; only a writable
 * segment is longer in memory than in the file; and every relocation's eight
 * bytes lie inside one writable segment.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/elf_plan.h"

typedef enum erx_exec_step_kind {
	ERX_EXEC_MAP,		/* map object pages [offset, offset + size) at address, prot */
	ERX_EXEC_CHILD,		/* the same pages as a private copy, read-write */
	ERX_EXEC_ZERO,		/* zero size bytes at address, in a copy just mapped */
	ERX_EXEC_COMMIT		/* commit size bytes of private memory, zeros, at address */
} erx_exec_step_kind_t;

typedef struct erx_exec_step {
	erx_exec_step_kind_t	kind;
	uint32_t		prot;		/* ERX_EXEC_MAP's: ERX_PROT_R or ERX_PROT_RX */
	uint64_t		address;
	uint64_t		size;
	uint64_t		offset;		/* ERX_EXEC_MAP's and ERX_EXEC_CHILD's, in the object */
} erx_exec_step_t;

/* A segment takes at most a child, its last page's zeroing and a commit. */
#define ERX_EXEC_STEPS_MAX	(3 * ERX_ELF_SEGMENTS_MAX)

/*
 * The executable placed: its base, aligned to the plan's base alignment
 * inside the reservation, its entry, and the steps in the order they apply,
 * a segment's zeroing after its copy is mapped.
 */
typedef struct erx_exec_layout {
	uint64_t	base;
	uint64_t	entry;
	uint32_t	nsteps;
	erx_exec_step_t	steps[ERX_EXEC_STEPS_MAX];
} erx_exec_layout_t;

/*
 * The bytes to reserve for plan: its span plus its base alignment less a
 * page, so an aligned base fits whatever address the reservation starts at.
 * False, with error's reason, for a fixed plan ("fixed_image"), since a fixed
 * address could meet the loader's own, or a size that overflows
 * ("reservation").
 */
bool	erx_exec_reservation(const erx_elf_plan_t *plan, uint64_t *size,
	    erx_elf_error_t *error);

/*
 * The layout of plan in the reservation [reserved, reserved + reserved_size),
 * which erx_exec_reservation sized: each executable or read-only segment
 * mapped from the object, each writable one a private copy of its file pages
 * with the last one's bytes past the file size zeroed, and the rest of it
 * committed. plan is one erx_exec_reservation accepted, so not fixed. False,
 * with error's reason, for a reservation the aligned span does not fit
 * ("reservation").
 */
bool	erx_exec_layout(const erx_elf_plan_t *plan, uint64_t reserved,
	    uint64_t reserved_size, erx_exec_layout_t *out, erx_elf_error_t *error);

/*
 * Writes plan's relocations into image, the executable's bytes from its base
 * mapped writable as layout's steps left them: for each, base plus the
 * addend, modulo 2^64, little-endian, at image plus the offset. file is the
 * bytes erx_elf_plan accepted, unchanged since, as a sealed object's are.
 */
void	erx_exec_relocate(const uint8_t *file, const erx_elf_plan_t *plan,
	    uint64_t base, uint8_t *image);

#endif /* !LIBERX_EXEC_LOAD_PLAN_H */
