/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LIBC_SPAWN_H
#define ERX_FIASCO_LIBC_SPAWN_H

#include <stdbool.h>

struct erx_spawn_request;

/*
 * posix_spawn's seam (musl/src/process/erxos/posix_spawn.c): starts the
 * spawn req asks for, in the spawn planner's terms (liberx/program/spawn_plan.h).
 * true when the entry took the spawn, with *result the child's pid, above
 * 0, or a negative errno; false when it offers no spawn, and posix_spawn answers
 * ENOSYS.  Every entry file defines it beside erx_fiasco_libc_fd
 * (libc_start.h), so a build without it fails to link: a program's
 * (program_task.c) spawns through its program layer (liberx/program/spawn.h),
 * and the others, which start no processes, take no spawn.
 */
bool	erx_fiasco_libc_spawn(const struct erx_spawn_request *req, long *result);

#endif /* !ERX_FIASCO_LIBC_SPAWN_H */
