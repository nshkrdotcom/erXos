/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_EXEC_LOAD_H
#define LIBERX_EXEC_LOAD_H

/*
 * erx_exec's effects (docs/design-programs.md, "An executable file"): the
 * one function of liberx that maps an executable file's code into a
 * program. It maps the code object read-only, plans its bytes with
 * erx_elf_plan, reserves the executable's span, applies the layout
 * load_plan.h decided whole, and writes the relocations, all in the calling
 * program's own space.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/elf_plan.h"

/*
 * A loaded executable: its base and entry, the reservation that holds it,
 * and the read-only view of the code object the plan read, which the
 * executable's start releases with the rest of erx_exec's ranges.
 */
typedef struct erx_exec_image {
	uint64_t	base;
	uint64_t	entry;
	uint64_t	reserved;
	uint64_t	reserved_size;
	uint64_t	view;
	uint64_t	view_size;
} erx_exec_image_t;

/*
 * Why a load failed. A refused file, which ends the program with status 127
 * and the planner's diagnostic, has call NULL and refusal the planner's or
 * the layout's reason; a kernel call that failed has call its name ("view",
 * "reserve", "map", "child", "commit") and status its status.
 */
typedef struct erx_exec_failure {
	const char	*call;
	int		 status;
	erx_elf_error_t	 refusal;
} erx_exec_failure_t;

/*
 * Loads the sealed code object object, object_size bytes, a whole number of
 * pages, into the caller's space, charging each writable segment's copy to
 * budget. False, with failure filled, and nothing of the load left.
 */
bool	erx_exec_load(uint64_t object, uint64_t object_size, uint64_t budget,
	    erx_exec_image_t *image, erx_exec_failure_t *failure);

#endif /* !LIBERX_EXEC_LOAD_H */
