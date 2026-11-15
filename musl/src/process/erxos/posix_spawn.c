/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * posix_spawn on erXos (docs/design-programs.md, "Starting a program"): a
 * spawn is a request to the program's handler, never a fork, so musl's
 * child and its pipe are gone.  This decodes the attributes and the
 * calling thread's mask into the spawn planner's request and hands it to
 * the entry's seam (libc_spawn.h), which plans and sends it in a program
 * and answers ENOSYS in a runtime, which has no processes.
 */

#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>

#include "liberx/backend/fiasco/libc_spawn.h"
#include "liberx/program/spawn_plan.h"

/* musl's signal numbers are the ABI's (abi/signals.txt). */
static erx_prog_sigset_t
sigset_of(const sigset_t *set)
{
	erx_prog_sigset_t out = { { 0, 0 } };

	for (int signo = 1; signo <= ERX_SIGRTMAX && signo < _NSIG; signo++)
		if (sigismember(set, signo) == 1)
			out.bits[(signo - 1) / 64] |= UINT64_C(1) << ((signo - 1) % 64);
	return (out);
}

int
posix_spawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *fa,
    const posix_spawnattr_t *restrict attr, char *const argv[restrict], char *const envp[restrict])
{
	const int flags = attr != NULL ? attr->__flags : 0;
	erx_spawn_request_t req = {
		.path = path,
		.argv = argv,
		.envp = envp != NULL ? envp : __environ,
		.actions = fa != NULL ? fa->__actions : NULL,
	};
	sigset_t mask;

	pthread_sigmask(SIG_BLOCK, NULL, &mask);
	req.mask = sigset_of(&mask);
	if (attr != NULL) {
		req.attr.sets_mask = (flags & POSIX_SPAWN_SETSIGMASK) != 0;
		req.attr.mask = sigset_of(&attr->__mask);
		req.attr.sets_defaults = (flags & POSIX_SPAWN_SETSIGDEF) != 0;
		req.attr.defaults = sigset_of(&attr->__def);
		req.attr.sets_group_session_or_policy = (flags & (POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSID |
		    POSIX_SPAWN_SETSCHEDULER | POSIX_SPAWN_SETSCHEDPARAM)) != 0;
	}
	return (erx_fiasco_libc_spawn(pid, &req));
}
