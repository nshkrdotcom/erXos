/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "spawn_action.h"

int
posix_spawn_file_actions_addfchdir_np(posix_spawn_file_actions_t *fa, int fd)
{
	if (fd < 0)
		return (EBADF);
	return (spawn_action_add(fa, (erx_spawn_action_t){ .op = ERX_SPAWN_FCHDIR, .fd = fd }, ""));
}
