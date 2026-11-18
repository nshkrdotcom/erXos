/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_SIGNAL_H
#define LIBERX_PROGRAM_SIGNAL_H

/*
 * A program's signal dispositions (docs/design-programs.md, "Signals in
 * liberx", on Fiasco): with no vCPU upcalls a program takes default
 * actions only, so sigaction records SIG_DFL and SIG_IGN for every signal
 * of the ABI file's signal table and refuses a handler with EINVAL, the
 * error POSIX gives for a signal that cannot be caught.  A signal raised
 * for the calling thread, SIGPIPE for a pipe write that failed with EPIPE,
 * is dropped when ignored and ends the program by its default action
 * otherwise.
 */

#include <signal.h>
#include <stdbool.h>

#include "liberx/program/startup.h"

/* What a raised signal does to the program: nothing, or its end by the signal. */
typedef enum erx_prog_sig_fate {
	ERX_PROG_SIG_DROP,
	ERX_PROG_SIG_END
} erx_prog_sig_fate_t;

/*
 * Sets the dispositions a program starts with: SIG_IGN for each signal of
 * ignored, its startup message's sigignore, and SIG_DFL for the rest, as
 * POSIX's posix_spawn and exec leave them (docs/design-programs.md, "The
 * startup message").  Called once, before main.
 */
void	erx_prog_sig_start(const erx_prog_sigset_t *ignored);

/*
 * Whether sigaction may set act for signo: 0, or -EINVAL for a number the
 * signal table does not list or reserves, SIG_IGN for SIGKILL or SIGSTOP,
 * or a handler.  A NULL act only reads, and is 0 for any signal
 * the table lists.
 */
int	erx_prog_sig_check(int signo, const struct sigaction *act);

/*
 * What raising signo does, given whether its disposition is SIG_IGN; under
 * SIG_DFL the signal table's default action decides.
 */
erx_prog_sig_fate_t	erx_prog_sig_fate(int signo, bool ignored);

/*
 * sigaction: stores *act when given, after copying the action it replaces
 * into *old when given; 0 or erx_prog_sig_check's -EINVAL, with nothing
 * stored or copied.
 */
int	erx_prog_sigaction(int signo, const struct sigaction *act, struct sigaction *old);

/*
 * Raises signo for the calling thread: returns when the signal is dropped,
 * and otherwise stops the program's space with ERX_EXIT_SIGNAL plus signo
 * and does not return.
 */
void	erx_prog_sig_raise(int signo);

/*
 * kill(pid, signo) for a process id pid and a number signo of the ABI
 * file's signal table, through the request {kill, Pid, Signal} on the
 * channel, or for signo 0 through {probe, Pid}, which asks whether a kill
 * would reach pid and signals nothing (docs/design-programs.md, "The
 * program protocol"): 0, or the handler's error negated.  Without a
 * request: -ENOSYS for pid 0 or below, a process group, for which the
 * request table offers no target; -EINVAL for a number the signal table
 * does not list or reserves; -ESRCH for process 1, the session.  -EIO
 * when the channel cannot carry the request.
 */
int	erx_prog_kill(int pid, int signo);

#endif /* !LIBERX_PROGRAM_SIGNAL_H */
