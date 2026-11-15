/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * posix_spawn's file actions on erXos: a posix_spawn_file_actions_t's
 * __actions is the first of a list of liberx's erx_spawn_action_t, in the
 * order the actions were added, which is the order the spawn planner
 * (liberx/program/spawn_plan.h) applies them in.  Like musl's own fdop.h,
 * the list is allocated with musl's malloc, never one a program replaces.
 */

#define malloc __libc_malloc
#define calloc __libc_calloc
#define realloc undef
#define free __libc_free

#include <errno.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/program/spawn_plan.h"

/* Adds an action at the end of fa's list, path copied: 0, or ENOMEM with fa unchanged. */
static inline int
spawn_action_add(posix_spawn_file_actions_t *fa, erx_spawn_action_t fields, const char *path)
{
	const size_t len = strlen(path) + 1;
	erx_spawn_action_t *action = malloc(sizeof(*action) + len), *last;

	if (action == NULL)
		return (ENOMEM);
	*action = fields;
	action->next = NULL;
	memcpy(action->path, path, len);
	if (fa->__actions == NULL) {
		fa->__actions = action;
		return (0);
	}
	for (last = fa->__actions; last->next != NULL; last = last->next)
		continue;
	last->next = action;
	return (0);
}
