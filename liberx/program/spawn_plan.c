/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The spawn planner (spawn_plan.h).  plan->fds is the model of the child's
 * table while the file actions replay, each slot naming the starter's
 * object or an addopen's open, and a local array beside it keeps each
 * slot's FD_CLOEXEC; exec_close then empties what exec would close, and
 * name_once turns every later number for an object into a dup of its
 * first.
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <erx/abi.h>

#include "liberx/program/spawn_plan.h"

static bool
sig_has(const erx_prog_sigset_t *set, int signo)
{
	return ((set->bits[(signo - 1) / 64] >> ((signo - 1) % 64)) & 1);
}

/*
 * The signals of set that a program may name and that drop does not hold,
 * which leaves out every number the startup message cannot carry.
 */
static erx_prog_sigset_t
sig_without(const erx_prog_sigset_t *set, const erx_prog_sigset_t *drop)
{
	erx_prog_sigset_t out = { { 0, 0 } };

	for (int signo = 1; signo <= ERX_SIGRTMAX; signo++)
		if (sig_has(set, signo) && !sig_has(drop, signo) && erx_sig_valid(signo))
			out.bits[(signo - 1) / 64] |= UINT64_C(1) << ((signo - 1) % 64);
	return (out);
}

/* The set of the two signals no program masks or ignores. */
static erx_prog_sigset_t
unblockable(void)
{
	erx_prog_sigset_t set = { { 0, 0 } };

	set.bits[(ERX_SIGKILL - 1) / 64] |= UINT64_C(1) << ((ERX_SIGKILL - 1) % 64);
	set.bits[(ERX_SIGSTOP - 1) / 64] |= UINT64_C(1) << ((ERX_SIGSTOP - 1) % 64);
	return (set);
}

static bool
in_table(int fd)
{
	return (fd >= 0 && (unsigned)fd < ERX_PROG_FDS_MAX);
}

/*
 * Adds the strings of a NULL-terminated array to *bytes, each with its NUL:
 * 0, or E2BIG once the total would pass ERX_PROG_ARGS_MAX, which *bytes
 * never does.
 */
static int
count_args(char *const *strings, size_t *bytes)
{
	for (; *strings != NULL; strings++) {
		const size_t len = strnlen(*strings, ERX_PROG_ARGS_MAX);

		if (len >= ERX_PROG_ARGS_MAX - *bytes)
			return (E2BIG);
		*bytes += len + 1;
	}
	return (0);
}

/*
 * Writes path, taken against the absolute normalised directory dir, into
 * out, absolute and normalised: empty and "." components go, and ".." takes
 * the last component off, never past "/", as the startup message's cwd is
 * written.  0, or ENAMETOOLONG when the result passes ERX_PROG_PATH_MAX.
 * While it is built, out holds each component as "/name" and the root as
 * no bytes at all, so a lone "/" goes in last.
 * A component that does not fit is counted in beyond instead, where only a
 * later ".." can take it off again, so "x/.." past the bound still fits.
 */
static int
path_join(const char *dir, const char *path, char out[ERX_PROG_PATH_MAX + 1])
{
	size_t len = 0, beyond = 0;

	if (path[0] != '/') {
		len = strnlen(dir, ERX_PROG_PATH_MAX + 1);
		if (len > ERX_PROG_PATH_MAX)
			return (ENAMETOOLONG);
		memcpy(out, dir, len);
		/* The one normalised directory of one byte is the root. */
		if (len == 1)
			len = 0;
	}
	while (*path != '\0') {
		const char *end;
		size_t n;

		while (*path == '/')
			path++;
		for (end = path; *end != '\0' && *end != '/'; end++)
			continue;
		n = (size_t)(end - path);
		if (n == 2 && path[0] == '.' && path[1] == '.') {
			if (beyond > 0) {
				beyond--;
			} else {
				while (len > 0 && out[len - 1] != '/')
					len--;
				if (len > 0)
					len--;
			}
		} else if (n != 0 && !(n == 1 && path[0] == '.')) {
			if (beyond > 0 || n >= ERX_PROG_PATH_MAX - len) {
				beyond++;
				path = end;
				continue;
			}
			out[len++] = '/';
			memcpy(out + len, path, n);
			len += n;
		}
		path = end;
	}
	if (beyond > 0)
		return (ENAMETOOLONG);
	if (len == 0)
		out[len++] = '/';
	out[len] = '\0';
	return (0);
}

static bool
has_empty_slot(const erx_spawn_plan_t *plan)
{
	for (size_t fd = 0; fd < ERX_PROG_FDS_MAX; fd++)
		if (plan->fds[fd].kind == ERX_SPAWN_FD_NONE)
			return (true);
	return (false);
}

/*
 * addfchdir's error for a descriptor the child holds, by the object's kind,
 * so a new kind makes the compiler ask what it answers.  None of the
 * starter's kinds is a directory.  An addopen's open may be one, but the
 * plan cannot tell before the open is made, so it refuses (TODO.md).
 */
static int
fchdir_error(const erx_spawn_fd_t *fd)
{
	if (fd->kind == ERX_SPAWN_FD_OPEN)
		return (ENOTSUP);
	switch (fd->held->kind) {
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_PIPE:
	case ERX_PROG_OBJ_MEM:
	case ERX_PROG_OBJ_FILE:
		return (ENOTDIR);
	}
	return (ENOTDIR);
}

/* Applies one file action to the model of the child's table: 0 or its error (spawn_plan.h). */
static int
apply(const erx_spawn_action_t *action, erx_spawn_plan_t *plan, bool cloexec[ERX_PROG_FDS_MAX])
{
	char path[ERX_PROG_PATH_MAX + 1];
	int error;

	switch (action->op) {
	case ERX_SPAWN_CLOSE:
		if (in_table(action->fd))
			plan->fds[action->fd].kind = ERX_SPAWN_FD_NONE;
		return (0);
	case ERX_SPAWN_DUP2:
		if (!in_table(action->src) || plan->fds[action->src].kind == ERX_SPAWN_FD_NONE ||
		    !in_table(action->fd))
			return (EBADF);
		plan->fds[action->fd] = plan->fds[action->src];
		cloexec[action->fd] = false;
		return (0);
	case ERX_SPAWN_OPEN:
		/* The joined path only has to fit; the starter resolves it when it opens. */
		if (action->path[0] == '\0')
			return (ENOENT);
		if ((error = path_join(plan->cwd, action->path, path)) != 0)
			return (error);
		if (!has_empty_slot(plan))
			return (EMFILE);
		if (!in_table(action->fd))
			return (EBADF);
		plan->fds[action->fd] = (erx_spawn_fd_t){ .kind = ERX_SPAWN_FD_OPEN, .open = action };
		cloexec[action->fd] = false;
		return (0);
	case ERX_SPAWN_CHDIR:
		if (action->path[0] == '\0')
			return (ENOENT);
		if ((error = path_join(plan->cwd, action->path, path)) != 0)
			return (error);
		memcpy(plan->cwd, path, strlen(path) + 1);
		return (0);
	case ERX_SPAWN_FCHDIR:
		if (!in_table(action->fd) || plan->fds[action->fd].kind == ERX_SPAWN_FD_NONE)
			return (EBADF);
		return (fchdir_error(&plan->fds[action->fd]));
	}
	return (EINVAL);
}

/* Empties every slot exec closes: one with FD_CLOEXEC, and a mem range, which no spawn hands on. */
static void
exec_close(erx_spawn_plan_t *plan, const bool cloexec[ERX_PROG_FDS_MAX])
{
	for (size_t fd = 0; fd < ERX_PROG_FDS_MAX; fd++) {
		erx_spawn_fd_t *slot = &plan->fds[fd];

		if (cloexec[fd]) {
			slot->kind = ERX_SPAWN_FD_NONE;
			continue;
		}
		if (slot->kind != ERX_SPAWN_FD_HELD)
			continue;
		switch (slot->held->kind) {
		case ERX_PROG_OBJ_NULL:
		case ERX_PROG_OBJ_PIPE:
		case ERX_PROG_OBJ_FILE:
			break;
		case ERX_PROG_OBJ_MEM:
			slot->kind = ERX_SPAWN_FD_NONE;
			break;
		}
	}
}

static bool
same_object(const erx_spawn_fd_t *a, const erx_spawn_fd_t *b)
{
	switch (a->kind) {
	case ERX_SPAWN_FD_NONE:
	case ERX_SPAWN_FD_DUP:
		return (false);
	case ERX_SPAWN_FD_HELD:
		return (b->kind == ERX_SPAWN_FD_HELD && a->held == b->held);
	case ERX_SPAWN_FD_OPEN:
		return (b->kind == ERX_SPAWN_FD_OPEN && a->open == b->open);
	}
	return (false);
}

/*
 * Makes every number but the lowest that names an object a dup of the
 * lowest.  A slot already made a dup matches nothing (same_object), so the
 * first match is always the object's lowest number.
 */
_Static_assert(ERX_PROG_FDS_MAX <= UINT16_MAX, "descriptor numbers fit a dup's uint16_t");

static void
name_once(erx_spawn_plan_t *plan)
{
	for (uint16_t fd = 1; fd < ERX_PROG_FDS_MAX; fd++) {
		if (plan->fds[fd].kind == ERX_SPAWN_FD_NONE)
			continue;
		for (uint16_t first = 0; first < fd; first++)
			if (same_object(&plan->fds[first], &plan->fds[fd])) {
				plan->fds[fd] = (erx_spawn_fd_t){ .kind = ERX_SPAWN_FD_DUP, .dup = first };
				break;
			}
	}
}

/*
 * The order is FreeBSD's child's: the attributes, then the file actions,
 * then exec's own checks of the path and the arguments.
 */
int
erx_spawn_plan(const erx_spawn_request_t *req, const erx_spawn_starter_t *starter, erx_spawn_plan_t *plan)
{
	const erx_prog_sigset_t none = { { 0, 0 } };
	const erx_prog_sigset_t kill_stop = unblockable();
	bool cloexec[ERX_PROG_FDS_MAX];
	int error;

	if (req->attr.sets_group_session_or_policy)
		return (ENOSYS);
	plan->sigmask = sig_without(req->attr.sets_mask ? &req->attr.mask : &req->mask, &kill_stop);
	plan->sigignore = sig_without(&starter->ignored, req->attr.sets_defaults ? &req->attr.defaults : &none);
	plan->umask = starter->umask & 0777;

	if ((error = path_join(starter->cwd, "", plan->cwd)) != 0)
		return (error);
	for (size_t fd = 0; fd < ERX_PROG_FDS_MAX; fd++) {
		const erx_prog_slot_t *slot = &starter->table[fd];

		plan->fds[fd] = slot->obj != NULL ?
		    (erx_spawn_fd_t){ .kind = ERX_SPAWN_FD_HELD, .held = slot->obj } :
		    (erx_spawn_fd_t){ .kind = ERX_SPAWN_FD_NONE };
		cloexec[fd] = slot->obj != NULL && slot->cloexec;
	}
	for (const erx_spawn_action_t *action = req->actions; action != NULL; action = action->next)
		if ((error = apply(action, plan, cloexec)) != 0)
			return (error);
	exec_close(plan, cloexec);
	name_once(plan);

	if (req->argv == NULL || req->envp == NULL)
		return (EFAULT);
	if (req->path[0] == '\0')
		return (ENOENT);
	if ((error = path_join(plan->cwd, req->path, plan->path)) != 0)
		return (error);
	plan->argv = req->argv;
	plan->envp = req->envp;
	plan->args_bytes = 0;
	if ((error = count_args(req->argv, &plan->args_bytes)) != 0 ||
	    (error = count_args(req->envp, &plan->args_bytes)) != 0)
		return (error);
	return (0);
}
