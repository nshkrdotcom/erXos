/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "spawn_action.h"

int
posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *restrict fa, const char *restrict path)
{
	return (spawn_action_add(fa, (erx_spawn_action_t){ .op = ERX_SPAWN_CHDIR, .fd = -1 }, path));
}
