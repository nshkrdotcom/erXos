/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_EXEC_RELEASE_H
#define LIBERX_EXEC_RELEASE_H

/*
 * The end of a loader's tenure (docs/design-programs.md, "The loader's
 * bootstrap", Release): an executable that erx_exec loaded starts with
 * program_arg's exec not 0, and its start-up releases the loader's window
 * (abi/protocols/prog.txt, exec_window_base and exec_window_bytes) whole,
 * before musl's start runs any constructor. The window is a fact of the
 * ABI, not of the loader's build or the record: it holds the loader's
 * image, the rest erx_exec_load reserved before anything else, and the
 * exec record's page, and nothing else, so one release removes all three
 * and no memory of the executable's. The executable reads no record.
 *
 * Neither the release nor its caller uses thread-local storage or a musl
 * function that does, since musl's start has not run.
 */

#include <stdbool.h>

#include "liberx/exec/range.h"

/*
 * Releases the loader's window from the calling program's space, in a
 * program whose own image is own. False, releasing nothing, when the
 * window meets own, as it does in a fixed-link task, which the task script
 * links at the window's base and no loader enters; false too when the
 * space refuses the release. The caller then stops the program with
 * ERX_PROG_STATUS_RELEASE.
 */
bool	erx_exec_release(erx_exec_range_t own);

#endif /* !LIBERX_EXEC_RELEASE_H */
