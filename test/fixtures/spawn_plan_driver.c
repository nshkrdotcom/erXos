/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The spawn planner's host driver (test/host/spawn_plan_test.rb).
 *
 *   spawn_plan_driver examples
 *	plans hand-built spawns whose outcome FreeBSD's posix_spawn fixes and
 *	prints "ok NAME" for each that plans as it should;
 *   spawn_plan_driver random SEED COUNT
 *	runs tools/fuzz/spawn_plan_fuzz.c's checks over COUNT inputs drawn
 *	from SEED, which abort on a broken case, then prints how many plans
 *	each verdict ended, "accepted N" and "errno N COUNT".
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../tools/fuzz/spawn_plan_fuzz.c"

static erx_prog_obj_t null_obj = { .kind = ERX_PROG_OBJ_NULL };
static erx_prog_obj_t pipe_a = { .kind = ERX_PROG_OBJ_PIPE };
static erx_prog_obj_t mem_obj = { .kind = ERX_PROG_OBJ_MEM };
static erx_prog_slot_t table[ERX_PROG_FDS_MAX];
static erx_spawn_plan_t plan;
static char *const no_strings[] = { NULL };

static erx_spawn_action_t *
action(erx_spawn_op_t op, int fd, int src, const char *path, int oflag, erx_spawn_action_t *next)
{
	erx_spawn_action_t *a = calloc(1, sizeof(*a) + strlen(path) + 1);

	check(a != NULL);
	*a = (erx_spawn_action_t){ .next = next, .op = op, .fd = fd, .src = src, .oflag = oflag };
	strcpy(a->path, path);
	return (a);
}

static void
sig_add(erx_prog_sigset_t *set, int signo)
{
	set->bits[(signo - 1) / 64] |= UINT64_C(1) << ((signo - 1) % 64);
}

/* A spawn of /bin/x with no arguments by a starter in /home/u holding table. */
static erx_spawn_request_t
request(const erx_spawn_action_t *actions)
{
	return ((erx_spawn_request_t){ .path = "/bin/x", .argv = no_strings, .envp = no_strings,
	    .actions = actions });
}

static const erx_spawn_starter_t starter = { .table = table, .cwd = "/home/u" };

static void
example(const char *name, bool held)
{
	if (!held) {
		printf("broken %s\n", name);
		exit(1);
	}
	printf("ok %s\n", name);
}

static void
examples(void)
{
	erx_spawn_request_t req;
	erx_spawn_action_t *open0, *open1;
	char *const two_big[] = { big, big, NULL };
	char *const past[] = { big, big, big + BIG, NULL };

	fill_texts();
	table[0] = (erx_prog_slot_t){ .obj = &null_obj };
	table[1] = (erx_prog_slot_t){ .obj = &pipe_a };
	table[3] = (erx_prog_slot_t){ .obj = &pipe_a, .cloexec = true };
	table[4] = (erx_prog_slot_t){ .obj = &pipe_a, .cloexec = true };
	table[6] = (erx_prog_slot_t){ .obj = &mem_obj };

	req = request(NULL);
	example("FD_CLOEXEC and a mem range close, the rest pass",
	    erx_spawn_plan(&req, &starter, &plan) == 0 && plan.fds[0].kind == ERX_SPAWN_FD_HELD &&
	    plan.fds[0].held == &null_obj && plan.fds[1].held == &pipe_a &&
	    plan.fds[3].kind == ERX_SPAWN_FD_NONE && plan.fds[4].kind == ERX_SPAWN_FD_NONE &&
	    plan.fds[6].kind == ERX_SPAWN_FD_NONE && strcmp(plan.cwd, "/home/u") == 0);

	req = request(action(ERX_SPAWN_DUP2, 3, 3, "", 0, action(ERX_SPAWN_DUP2, 5, 1, "", 0,
	    action(ERX_SPAWN_CLOSE, 9, 0, "", 0, action(ERX_SPAWN_DUP2, 7, 6, "", 0, NULL)))));
	example("adddup2 onto itself clears FD_CLOEXEC, a dup2 makes a dup, closing a closed one is no error",
	    erx_spawn_plan(&req, &starter, &plan) == 0 && plan.fds[3].kind == ERX_SPAWN_FD_DUP &&
	    plan.fds[3].dup == 1 && plan.fds[5].kind == ERX_SPAWN_FD_DUP && plan.fds[5].dup == 1 &&
	    plan.fds[4].kind == ERX_SPAWN_FD_NONE);
	example("a dup2 of a mem range hands on nothing", plan.fds[7].kind == ERX_SPAWN_FD_NONE);

	req = request(action(ERX_SPAWN_DUP2, 2, 8, "", 0, NULL));
	example("adddup2 of a closed descriptor is EBADF", erx_spawn_plan(&req, &starter, &plan) == EBADF);
	req = request(action(ERX_SPAWN_DUP2, (int)ERX_PROG_FDS_MAX, 1, "", 0, NULL));
	example("adddup2 past the table is EBADF", erx_spawn_plan(&req, &starter, &plan) == EBADF);
	req = request(action(ERX_SPAWN_FCHDIR, 1, 0, "", 0, NULL));
	example("addfchdir of a pipe end is ENOTDIR", erx_spawn_plan(&req, &starter, &plan) == ENOTDIR);

	open1 = action(ERX_SPAWN_OPEN, 1, 0, "../g", O_WRONLY | O_CREAT, NULL);
	open0 = action(ERX_SPAWN_OPEN, 0, 0, "f", O_RDONLY | O_CLOEXEC, action(ERX_SPAWN_CHDIR, 0, 0, "sub/./", 0, open1));
	req = request(open0);
	example("addopen makes an open without FD_CLOEXEC against the directory addchdir set",
	    erx_spawn_plan(&req, &starter, &plan) == 0 && plan.fds[0].kind == ERX_SPAWN_FD_OPEN &&
	    plan.fds[0].open == open0 && plan.fds[1].open == open1 && strcmp(plan.cwd, "/home/u/sub") == 0);
	req.path = "../bin/y";
	example("a relative executable path is the child's, against the directory addchdir set",
	    erx_spawn_plan(&req, &starter, &plan) == 0 && strcmp(plan.path, "/home/u/bin/y") == 0);

	req = request(action(ERX_SPAWN_DUP2, 2, 8, "", 0, NULL));
	req.attr.sets_group_session_or_policy = true;
	example("a process group is ENOSYS, before the file actions", erx_spawn_plan(&req, &starter, &plan) == ENOSYS);

	req = request(NULL);
	sig_add(&req.mask, ERX_SIGTERM);
	req.attr.sets_mask = true;
	sig_add(&req.attr.mask, ERX_SIGKILL);
	sig_add(&req.attr.mask, ERX_SIGINT);
	req.attr.sets_defaults = true;
	sig_add(&req.attr.defaults, ERX_SIGQUIT);
	{
		erx_spawn_starter_t ignoring = starter;

		sig_add(&ignoring.ignored, ERX_SIGQUIT);
		sig_add(&ignoring.ignored, ERX_SIGPIPE);
		example("POSIX_SPAWN_SETSIGMASK replaces the mask without SIGKILL, SETSIGDEF resets what it names",
		    erx_spawn_plan(&req, &ignoring, &plan) == 0 && has(&plan.sigmask, ERX_SIGINT) &&
		    !has(&plan.sigmask, ERX_SIGKILL) && !has(&plan.sigmask, ERX_SIGTERM) &&
		    has(&plan.sigignore, ERX_SIGPIPE) && !has(&plan.sigignore, ERX_SIGQUIT));
	}

	req = request(NULL);
	req.argv = two_big;
	example("argv of ERX_PROG_ARGS_MAX bytes passes", erx_spawn_plan(&req, &starter, &plan) == 0 &&
	    plan.args_bytes == ERX_PROG_ARGS_MAX);
	req.argv = past;
	example("one byte more is E2BIG", erx_spawn_plan(&req, &starter, &plan) == E2BIG);
}

static uint64_t
next_random(uint64_t *state)
{
	*state ^= *state << 13;
	*state ^= *state >> 7;
	*state ^= *state << 17;
	return (*state);
}

static void
random_cases(uint64_t seed, unsigned long count)
{
	static unsigned long verdicts[256];
	static uint8_t input[512];
	unsigned long accepted = 0;
	uint64_t state = seed * 2 + 1;

	for (unsigned long i = 0; i < count; i++) {
		const size_t len = next_random(&state) % sizeof(input);
		for (size_t j = 0; j < len; j++)
			input[j] = (uint8_t)next_random(&state);
		const int verdict = run_case(input, len);

		if (verdict == 0)
			accepted++;
		else
			verdicts[verdict & 0xff]++;
	}
	printf("accepted %lu\n", accepted);
	for (int e = 1; e < 256; e++)
		if (verdicts[e] != 0)
			printf("errno %d %lu\n", e, verdicts[e]);
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "examples") == 0) {
		examples();
		return (0);
	}
	if (argc == 4 && strcmp(argv[1], "random") == 0) {
		random_cases(strtoull(argv[2], NULL, 0), strtoul(argv[3], NULL, 0));
		return (0);
	}
	fprintf(stderr, "usage: spawn_plan_driver examples | random SEED COUNT\n");
	return (2);
}
