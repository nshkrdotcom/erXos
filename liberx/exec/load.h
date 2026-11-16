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
 * A range of the program's space: size bytes from address. A load holds
 * its view and its reservation as ranges until its outcome, size 0 holding
 * nothing; the executable's start-up releases the loader's span as one
 * (release.h).
 */
typedef struct erx_exec_range {
	uint64_t	address;
	uint64_t	size;
} erx_exec_range_t;

/*
 * A loaded executable: its base and entry, and the reservation that holds
 * it, which stays the executable's image.
 */
typedef struct erx_exec_image {
	uint64_t	base;
	uint64_t	entry;
	uint64_t	reserved;
	uint64_t	reserved_size;
} erx_exec_image_t;

/*
 * What a load came to (docs/design-programs.md, "A release that fails"):
 * loaded, with its view of the object released; failed, with the failure
 * filled in and the reservation and the view released; or refused
 * cleanup, when the space refused one of those releases, which is
 * terminal: the program is never entered and no diagnostic is attempted.
 */
typedef enum erx_exec_outcome {
	ERX_EXEC_LOADED,
	ERX_EXEC_FAILED,
	ERX_EXEC_CLEANUP_REFUSED,
} erx_exec_outcome_t;

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
 * Loads the executable file whose file_bytes bytes begin the sealed code
 * object object, the rest of whose last page the object holds as zeros,
 * into the caller's space, charging each writable segment's copy to
 * budget. The plan reads exactly the file's bytes. image is filled when
 * the outcome is ERX_EXEC_LOADED, failure when it is ERX_EXEC_FAILED.
 */
erx_exec_outcome_t erx_exec_load(uint64_t object, uint64_t file_bytes,
	    uint64_t budget, erx_exec_image_t *image, erx_exec_failure_t *failure);

#endif /* !LIBERX_EXEC_LOAD_H */
