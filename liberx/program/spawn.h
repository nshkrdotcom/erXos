/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_SPAWN_H
#define LIBERX_PROGRAM_SPAWN_H

#include <sys/types.h>

#include "liberx/program/spawn_plan.h"

/*
 * posix_spawn in a program (docs/design-programs.md, "Starting a program",
 * steps 1 and 2): plans req with erx_spawn_plan against what the program
 * holds, a counted reference to each descriptor's object, its signal
 * dispositions, its file mode creation mask and its working directory, and
 * sends the plan to the handler as {spawn, Path, Start}.  The request
 * union of abi/protocols/prog.txt holds no {spawn}, so an accepted plan
 * answers ENOSYS; a refused one answers the planner's error.  Either way
 * the references go and nothing else changed.  ENOMEM when the layer has
 * no pages to plan in.
 */
int	erx_prog_spawn(pid_t *pid, const erx_spawn_request_t *req);

#endif /* !LIBERX_PROGRAM_SPAWN_H */
