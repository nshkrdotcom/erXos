/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "spawn_action.h"

int
posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *fa, int src, int fd)
{
	if (src < 0 || fd < 0)
		return (EBADF);
	return (spawn_action_add(fa, (erx_spawn_action_t){ .op = ERX_SPAWN_DUP2, .fd = fd, .src = src }, ""));
}
