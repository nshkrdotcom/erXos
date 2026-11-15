/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_LIBERX_LIBC_SPAWN_H
#define ERX_LIBERX_LIBC_SPAWN_H

#include <stdbool.h>

struct erx_spawn_request;

/*
 * posix_spawn's seam (musl/src/process/erxos/posix_spawn.c): starts the
 * spawn req asks for, in the spawn planner's terms (liberx/program/spawn_plan.h).
 * true when the entry took the spawn, with *result the child's pid, above
 * 0, or a negative errno; false when it offers no spawn, and posix_spawn answers
 * ENOSYS.  Every entry file of a backend that links musl defines it, so a
 * build without it fails to link: the Fiasco backend's program entry
 * (program_task.c) spawns through its program layer (liberx/program/spawn.h);
 * the other entries start no processes and take no spawn.
 *
 * It lives outside the backends' headers so that musl's erXos layer reaches
 * the spawn through liberx's interface, never through a backend.
 */
bool	erx_libc_spawn(const struct erx_spawn_request *req, long *result);

#endif /* !ERX_LIBERX_LIBC_SPAWN_H */
