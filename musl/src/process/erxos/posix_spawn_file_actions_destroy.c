/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "spawn_action.h"

int
posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *fa)
{
	erx_spawn_action_t *action = fa->__actions, *next;

	for (; action != NULL; action = next) {
		next = action->next;
		free(action);
	}
	fa->__actions = NULL;
	return (0);
}
