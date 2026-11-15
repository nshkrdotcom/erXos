/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LIBC_SPAWN_H
#define ERX_FIASCO_LIBC_SPAWN_H

#include <sys/types.h>

struct erx_spawn_request;

/*
 * posix_spawn's seam (musl/src/process/erxos/posix_spawn.c): starts the
 * spawn req asks for, in the spawn planner's terms (liberx/program/spawn_plan.h).
 * posix_spawn's return: 0 with *pid the child's, or an error.  Every entry
 * file defines it beside erx_fiasco_libc_fd (libc_start.h), so a build
 * without it fails to link: a program's (program_task.c) spawns through
 * its program layer (liberx/program/spawn.h), and the others, which start
 * no processes, answer ENOSYS.
 */
int	erx_fiasco_libc_spawn(pid_t *pid, const struct erx_spawn_request *req);

#endif /* !ERX_FIASCO_LIBC_SPAWN_H */
