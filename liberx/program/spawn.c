/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects around the spawn planner (spawn.h): what the program holds
 * goes in, the plan comes out, and the send is the one step that would
 * reach the handler.
 */

#include <errno.h>
#include <signal.h>
#include <stdint.h>

#include <erx/abi.h>

#include "liberx/program/fd.h"
#include "liberx/program/pages.h"
#include "liberx/program/program.h"
#include "liberx/program/signal.h"
#include "liberx/program/spawn.h"
#include "liberx/program/spawn_plan.h"

/* What a spawn plans in: the table's snapshot and the plan, a run of pages of its own. */
typedef struct spawn_work {
	erx_prog_slot_t		table[ERX_PROG_FDS_MAX];
	erx_spawn_plan_t	plan;
} spawn_work_t;

static erx_prog_sigset_t
ignored_signals(void)
{
	erx_prog_sigset_t set = { { 0, 0 } };
	struct sigaction now;

	for (int signo = 1; signo <= ERX_SIGRTMAX; signo++)
		if (erx_sig_valid(signo) && erx_prog_sigaction(signo, NULL, &now) == 0 && now.sa_handler == SIG_IGN)
			set.bits[(signo - 1) / 64] |= UINT64_C(1) << ((signo - 1) % 64);
	return (set);
}

/* Step 2's send: abi/protocols/prog.txt's request union holds no {spawn}, so nothing goes. */
static int
send_spawn(const erx_spawn_plan_t *plan, pid_t *pid)
{
	(void)plan;
	(void)pid;
	return (ENOSYS);
}

int
erx_prog_spawn(pid_t *pid, const erx_spawn_request_t *req)
{
	spawn_work_t *work = erx_prog_pages_take(sizeof(*work));
	const erx_prog_self_t *self = erx_prog_self();
	erx_spawn_starter_t starter;
	int error;

	if (work == NULL)
		return (ENOMEM);
	erx_prog_fd_snapshot(work->table);
	starter = (erx_spawn_starter_t){ .table = work->table, .ignored = ignored_signals(),
	    .umask = self->umask, .cwd = self->cwd };
	error = erx_spawn_plan(req, &starter, &work->plan);
	if (error == 0)
		error = send_spawn(&work->plan, pid);
	for (int fd = 0; fd < (int)ERX_PROG_FDS_MAX; fd++)
		if (work->table[fd].obj != NULL)
			erx_prog_obj_put(work->table[fd].obj);
	erx_prog_pages_give(work, sizeof(*work));
	return (error);
}
