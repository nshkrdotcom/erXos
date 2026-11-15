/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "spawn_action.h"

int
posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *restrict fa, int fd, const char *restrict path,
    int oflag, mode_t mode)
{
	if (fd < 0)
		return (EBADF);
	return (spawn_action_add(fa, (erx_spawn_action_t){ .op = ERX_SPAWN_OPEN, .fd = fd, .oflag = oflag,
	    .mode = mode }, path));
}
