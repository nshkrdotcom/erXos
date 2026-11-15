/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The spawn planner (liberx/program/spawn_plan.c) against a model of
 * FreeBSD's posix_spawn child, which replays the same file actions on a
 * table of its own with dup2, close and open as the system calls behave,
 * then closes what exec closes.  The input picks a starter's table from a
 * pool of objects (the null object, five pipe ends, one mem range), its
 * ignored signals, the thread's mask, the attributes, a working directory,
 * up to 32 file actions, the executable's path and argv and env whose
 * lengths sit at E2BIG's bound; descriptor numbers lean to the ends of the
 * table and just past it.  test/host/spawn_plan_test.rb runs the same
 * harness over seeded inputs, so each case must hold:
 *
 *  - the planner and the model refuse with the same error, or both accept;
 *  - a refusal or an acceptance leaves the table and the actions as they were;
 *  - an accepted plan names, at each number, what the model's table holds,
 *    an object the starter holds that is no mem range or an addopen's open,
 *    and names each object once, at its lowest number, a higher number
 *    being a dup of that one;
 *  - its executable path, masks, working directory and argument bytes are
 *    the model's.
 *
 * A broken case aborts.
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <erx/abi.h>

#include "liberx/program/spawn_plan.h"

int	LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define POOL		7	/* the null object, five pipe ends and a mem range */
#define ACTIONS_MAX	32
#define BIG		65535	/* two such strings with their NULs are ERX_PROG_ARGS_MAX */

typedef struct cursor {
	const uint8_t	*at;
	size_t		 left;
} cursor_t;

/* The next byte, or 0 past the end, so every input decodes. */
static uint8_t
take(cursor_t *in)
{
	if (in->left == 0)
		return (0);
	in->left--;
	return (*in->at++);
}

static void
check(bool held)
{
	if (!held)
		abort();
}

/* A descriptor number: 0 to 15, the table's last sixteen and the first four past it, -1, or any. */
static int
fd_of(uint8_t pick)
{
	if (pick < 16)
		return (pick);
	if (pick < 36)
		return ((int)ERX_PROG_FDS_MAX - 16 + (pick - 16));
	if (pick == 36)
		return (-1);
	return ((int)((pick * 37u) % ERX_PROG_FDS_MAX));
}

static char long_path[ERX_PROG_PATH_MAX + 2];	/* "/" and 'p's, ERX_PROG_PATH_MAX + 1 bytes */
static char near_path[ERX_PROG_PATH_MAX - 2];	/* "/" and 'q's, 3 bytes short of the bound */
static char exact_path[ERX_PROG_PATH_MAX + 1];	/* "/" and 'r's, ERX_PROG_PATH_MAX bytes */
static char back_path[ERX_PROG_PATH_MAX + 5];	/* 's's past the bound, then "/.." */
static char big[BIG + 1];			/* BIG 'a's */

static void
fill_texts(void)
{
	memset(long_path, 'p', sizeof(long_path) - 1);
	long_path[0] = '/';
	memset(near_path, 'q', sizeof(near_path) - 1);
	near_path[0] = '/';
	memset(exact_path, 'r', sizeof(exact_path) - 1);
	exact_path[0] = '/';
	memset(back_path, 's', sizeof(back_path) - 4);
	memcpy(back_path + sizeof(back_path) - 4, "/..", 3);
	memset(big, 'a', BIG);
}

static const char *
path_of(uint8_t pick)
{
	static const char *const paths[] = { "", "a", "/x/y", "..", "../../b", "./c/", "d//e/.", "/" };

	if (pick == 8)
		return (near_path);
	if (pick == 9)
		return (long_path);
	if (pick == 10)
		return (exact_path);
	if (pick == 11)
		return (back_path);
	return (paths[pick % 8]);
}

static const char *
cwd_of(uint8_t pick)
{
	switch (pick % 4) {
	case 0:
		return ("/");
	case 1:
		return ("/home/u");
	case 2:
		return (near_path);
	default:
		return ("/a/b/c");
	}
}

/* A string of argv or env: empty, one byte, BIG bytes or one less. */
static const char *
arg_of(uint8_t pick)
{
	switch (pick % 4) {
	case 0:
		return (big + BIG);
	case 1:
		return (big + BIG - 1);
	case 2:
		return (big);
	default:
		return (big + 1);
	}
}

static erx_prog_sigset_t
sigset_of(cursor_t *in)
{
	erx_prog_sigset_t set = { { 0, 0 } };

	for (int i = 0; i < 4; i++) {
		const int signo = 1 + take(in) % 128;

		set.bits[(signo - 1) / 64] |= UINT64_C(1) << ((signo - 1) % 64);
	}
	return (set);
}

static bool
has(const erx_prog_sigset_t *set, int signo)
{
	return ((set->bits[(signo - 1) / 64] >> ((signo - 1) % 64)) & 1);
}

/* One case: the starter, the request, and the storage both point into. */
typedef struct spawn_case {
	erx_prog_obj_t		 pool[POOL];
	erx_prog_slot_t		 table[ERX_PROG_FDS_MAX];
	erx_spawn_action_t	*actions[ACTIONS_MAX];
	size_t			 nactions;
	char			*argv[4];
	char			*envp[4];
	erx_spawn_starter_t	 starter;
	erx_spawn_request_t	 req;
} spawn_case_t;

static erx_spawn_action_t *
action_of(cursor_t *in)
{
	const uint8_t op = take(in) % 5;
	const int fd = fd_of(take(in));
	const int src = fd_of(take(in));
	const char *path = path_of(take(in) % 12);
	const size_t len = strlen(path);
	erx_spawn_action_t *action = malloc(sizeof(*action) + len + 1);

	check(action != NULL);
	*action = (erx_spawn_action_t){ .op = (erx_spawn_op_t)op, .fd = fd, .src = src, .oflag = 0, .mode = 0644 };
	memcpy(action->path, path, len + 1);
	return (action);
}

static void
decode(cursor_t *in, spawn_case_t *c)
{
	const uint8_t flags = take(in);
	const size_t slots = take(in);
	size_t n;

	for (int i = 0; i < POOL; i++)
		c->pool[i] = (erx_prog_obj_t){ .kind = i == 0 ? ERX_PROG_OBJ_NULL :
		    i == POOL - 1 ? ERX_PROG_OBJ_MEM : ERX_PROG_OBJ_PIPE };
	for (size_t i = 0; i < slots; i++) {
		const int fd = fd_of(take(in));
		const uint8_t object = take(in);

		if (fd >= 0 && fd < (int)ERX_PROG_FDS_MAX)
			c->table[fd] = (erx_prog_slot_t){ .obj = &c->pool[(object & 0x7f) % POOL],
			    .cloexec = (object & 0x80) != 0 };
	}
	if ((flags & 0x20) != 0)
		for (size_t fd = 0; fd < ERX_PROG_FDS_MAX; fd++)
			if (c->table[fd].obj == NULL)
				c->table[fd].obj = &c->pool[1 + fd % 5];

	c->starter.table = c->table;
	c->starter.ignored = sigset_of(in);
	c->starter.ignored.bits[(ERX_SIGKILL - 1) / 64] &= ~(UINT64_C(1) << ((ERX_SIGKILL - 1) % 64));
	c->starter.ignored.bits[(ERX_SIGSTOP - 1) / 64] &= ~(UINT64_C(1) << ((ERX_SIGSTOP - 1) % 64));
	c->starter.umask = (uint16_t)(take(in) | take(in) << 8);
	c->starter.cwd = cwd_of(take(in));

	c->req.attr.sets_mask = (flags & 0x01) != 0;
	c->req.attr.mask = sigset_of(in);
	c->req.attr.sets_defaults = (flags & 0x02) != 0;
	c->req.attr.defaults = sigset_of(in);
	c->req.attr.sets_group_session_or_policy = (flags & 0x1c) == 0x1c;
	c->req.mask = sigset_of(in);
	c->req.path = (flags & 0x40) != 0 ? path_of(take(in) % 12) : "/bin/x";

	n = take(in) % (ACTIONS_MAX + 1);
	for (c->nactions = 0; c->nactions < n; c->nactions++) {
		c->actions[c->nactions] = action_of(in);
		if (c->nactions > 0)
			c->actions[c->nactions - 1]->next = c->actions[c->nactions];
	}
	c->req.actions = c->nactions > 0 ? c->actions[0] : NULL;

	n = take(in) % 4;
	for (size_t i = 0; i < n; i++)
		c->argv[i] = (char *)arg_of(take(in));
	n = take(in) % 4;
	for (size_t i = 0; i < n; i++)
		c->envp[i] = (char *)arg_of(take(in));
	c->req.argv = (flags & 0x80) != 0 && (flags & 0x08) == 0 ? NULL : c->argv;
	c->req.envp = c->envp;
}

/*
 * The model's path join: the components of dir, then those of path, onto a
 * stack, ".." popping one, then written out; ENAMETOOLONG past the bound.
 */
static int
model_join(const char *dir, const char *path, char *out)
{
	static const char *parts[2 * ERX_PROG_PATH_MAX];
	static size_t lens[2 * ERX_PROG_PATH_MAX];
	size_t depth = 0, len = 0;
	const char *texts[2] = { path[0] == '/' ? "" : dir, path };

	for (int t = 0; t < 2; t++)
		for (const char *p = texts[t]; *p != '\0';) {
			size_t n = strcspn(p, "/");

			if (n == 2 && p[0] == '.' && p[1] == '.') {
				if (depth > 0)
					depth--;
			} else if (n > 0 && !(n == 1 && p[0] == '.')) {
				parts[depth] = p;
				lens[depth++] = n;
			}
			p += n;
			p += strspn(p, "/");
		}
	for (size_t i = 0; i < depth; i++)
		len += 1 + lens[i];
	if (len > ERX_PROG_PATH_MAX)
		return (ENAMETOOLONG);
	out[0] = '/';
	out[1] = '\0';
	len = 0;
	for (size_t i = 0; i < depth; i++) {
		out[len++] = '/';
		memcpy(out + len, parts[i], lens[i]);
		len += lens[i];
		out[len] = '\0';
	}
	return (0);
}

/* The model's table: what each number holds, a starter's object or an open. */
typedef struct model_slot {
	const erx_prog_obj_t	 *obj;
	const erx_spawn_action_t *open;
	bool			  cloexec;
} model_slot_t;

typedef struct model {
	model_slot_t	slots[ERX_PROG_FDS_MAX];
	char		cwd[ERX_PROG_PATH_MAX + 1];
	char		path[ERX_PROG_PATH_MAX + 1];
	size_t		args_bytes;
} model_t;

static bool
model_open(const model_t *m, int fd)
{
	return (fd >= 0 && fd < (int)ERX_PROG_FDS_MAX && (m->slots[fd].obj != NULL || m->slots[fd].open != NULL));
}

static int
model_action(model_t *m, const spawn_case_t *c, size_t i)
{
	const erx_spawn_action_t *a = c->actions[i];
	const bool fd_ok = a->fd >= 0 && a->fd < (int)ERX_PROG_FDS_MAX;
	char dir[ERX_PROG_PATH_MAX + 1];
	bool room = false;

	switch (a->op) {
	case ERX_SPAWN_CLOSE:
		if (fd_ok)
			m->slots[a->fd] = (model_slot_t){ 0 };
		return (0);
	case ERX_SPAWN_DUP2:
		if (!model_open(m, a->src) || !fd_ok)
			return (EBADF);
		m->slots[a->fd] = m->slots[a->src];
		m->slots[a->fd].cloexec = false;
		return (0);
	case ERX_SPAWN_OPEN:
		if (a->path[0] == '\0')
			return (ENOENT);
		if (model_join(m->cwd, a->path, dir) != 0)
			return (ENAMETOOLONG);
		for (int fd = 0; fd < (int)ERX_PROG_FDS_MAX; fd++)
			room = room || !model_open(m, fd);
		if (!room)
			return (EMFILE);
		if (!fd_ok)
			return (EBADF);
		m->slots[a->fd] = (model_slot_t){ .open = a };
		return (0);
	case ERX_SPAWN_CHDIR:
		if (a->path[0] == '\0')
			return (ENOENT);
		if (model_join(m->cwd, a->path, dir) != 0)
			return (ENAMETOOLONG);
		strcpy(m->cwd, dir);
		return (0);
	case ERX_SPAWN_FCHDIR:
		if (!model_open(m, a->fd))
			return (EBADF);
		return (m->slots[a->fd].open != NULL ? ENOTSUP : ENOTDIR);
	}
	abort();
}

static int
model_args(char *const *strings, size_t *bytes)
{
	for (; *strings != NULL; strings++)
		*bytes += strlen(*strings) + 1;
	return (*bytes > ERX_PROG_ARGS_MAX ? E2BIG : 0);
}

/* What FreeBSD's child would do with c: 0 with m its table after exec, or the error. */
static int
model_spawn(const spawn_case_t *c, model_t *m)
{
	int error;

	if (c->req.attr.sets_group_session_or_policy)
		return (ENOSYS);
	for (int fd = 0; fd < (int)ERX_PROG_FDS_MAX; fd++)
		m->slots[fd] = (model_slot_t){ .obj = c->table[fd].obj, .cloexec = c->table[fd].cloexec };
	check(model_join(c->starter.cwd, "", m->cwd) == 0);
	for (size_t i = 0; i < c->nactions; i++)
		if ((error = model_action(m, c, i)) != 0)
			return (error);
	for (int fd = 0; fd < (int)ERX_PROG_FDS_MAX; fd++)
		if (m->slots[fd].cloexec || (m->slots[fd].obj != NULL && m->slots[fd].obj->kind == ERX_PROG_OBJ_MEM))
			m->slots[fd] = (model_slot_t){ 0 };
	if (c->req.argv == NULL || c->req.envp == NULL)
		return (EFAULT);
	if (c->req.path[0] == '\0')
		return (ENOENT);
	if (model_join(m->cwd, c->req.path, m->path) != 0)
		return (ENAMETOOLONG);
	m->args_bytes = 0;
	if (model_args(c->req.argv, &m->args_bytes) != 0 || model_args(c->req.envp, &m->args_bytes) != 0)
		return (E2BIG);
	return (0);
}

/* The object plan names at fd, through a dup, as an object pointer or an open action. */
static const void *
named(const erx_spawn_plan_t *plan, size_t fd)
{
	const erx_spawn_fd_t *slot = &plan->fds[fd];

	if (slot->kind == ERX_SPAWN_FD_DUP) {
		check(slot->dup < fd);
		slot = &plan->fds[slot->dup];
		check(slot->kind == ERX_SPAWN_FD_HELD || slot->kind == ERX_SPAWN_FD_OPEN);
	}
	switch (slot->kind) {
	case ERX_SPAWN_FD_NONE:
		return (NULL);
	case ERX_SPAWN_FD_HELD:
		return (slot->held);
	case ERX_SPAWN_FD_OPEN:
		return (slot->open);
	case ERX_SPAWN_FD_DUP:
		break;
	}
	abort();
}

static void
check_signals(const spawn_case_t *c, const erx_spawn_plan_t *plan)
{
	const erx_prog_sigset_t *mask = c->req.attr.sets_mask ? &c->req.attr.mask : &c->req.mask;

	for (int signo = 1; signo <= 128; signo++) {
		const bool valid = signo <= ERX_SIGRTMAX && erx_sig_valid(signo);
		const bool masked = valid && has(mask, signo) && signo != ERX_SIGKILL && signo != ERX_SIGSTOP;
		const bool ignored = valid && has(&c->starter.ignored, signo) &&
		    !(c->req.attr.sets_defaults && has(&c->req.attr.defaults, signo));

		check(has(&plan->sigmask, signo) == masked);
		check(has(&plan->sigignore, signo) == ignored);
	}
}

static void
check_plan(const spawn_case_t *c, const model_t *m, const erx_spawn_plan_t *plan)
{
	const void *first[ERX_PROG_FDS_MAX];	/* each object a held or open slot named, in order */
	size_t nfirst = 0;

	for (size_t fd = 0; fd < ERX_PROG_FDS_MAX; fd++) {
		const model_slot_t *want = &m->slots[fd];
		const void *got = named(plan, fd);

		check(got == (want->obj != NULL ? (const void *)want->obj : (const void *)want->open));
		/* A held or open slot names an object no lower slot named; a dup names its first. */
		if (plan->fds[fd].kind == ERX_SPAWN_FD_HELD || plan->fds[fd].kind == ERX_SPAWN_FD_OPEN) {
			for (size_t i = 0; i < nfirst; i++)
				check(first[i] != got);
			first[nfirst++] = got;
		}
	}
	check(strcmp(plan->cwd, m->cwd) == 0);
	check(plan->umask == (c->starter.umask & 0777));
	check(strcmp(plan->path, m->path) == 0 && plan->argv == c->req.argv && plan->envp == c->req.envp);
	check(plan->args_bytes == m->args_bytes);
	check_signals(c, plan);
}

/* Checks one case: its verdict, 0 or the error both refused with. */
static int
run_case(const uint8_t *data, size_t size)
{
	static spawn_case_t c;
	static model_t m;
	static erx_spawn_plan_t plan;
	static erx_prog_slot_t table_before[ERX_PROG_FDS_MAX];
	erx_spawn_action_t *actions_before[ACTIONS_MAX];
	size_t sizes[ACTIONS_MAX];
	cursor_t in = { data, size };
	int want, got;

	if (big[0] == '\0')
		fill_texts();
	memset(&c, 0, sizeof(c));
	decode(&in, &c);
	memcpy(table_before, c.table, sizeof(table_before));
	for (size_t i = 0; i < c.nactions; i++) {
		sizes[i] = sizeof(*c.actions[i]) + strlen(c.actions[i]->path) + 1;
		actions_before[i] = malloc(sizes[i]);
		check(actions_before[i] != NULL);
		memcpy(actions_before[i], c.actions[i], sizes[i]);
	}

	want = model_spawn(&c, &m);
	got = erx_spawn_plan(&c.req, &c.starter, &plan);
	check(got == want);
	check(memcmp(table_before, c.table, sizeof(table_before)) == 0);
	for (size_t i = 0; i < c.nactions; i++)
		check(memcmp(actions_before[i], c.actions[i], sizes[i]) == 0);
	if (got == 0)
		check_plan(&c, &m, &plan);

	for (size_t i = 0; i < c.nactions; i++) {
		free(c.actions[i]);
		free(actions_before[i]);
	}
	return (got);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	(void)run_case(data, size);
	return (0);
}
