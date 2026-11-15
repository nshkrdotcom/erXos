/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * strsignal: the signal table's description of a signal a program may name
 * (docs/design-programs.md, "Signal numbers"), FreeBSD's sys_siglist text, and
 * musl's catch-all for any other number: a reserved or real-time signal, or no
 * signal.
 */

#include <string.h>

#include "erx/abi.h"
#include "locale_impl.h"

char *
strsignal(int signum)
{
	const char *description = erx_sig_description(signum);

	return ((char *)LCTRANS_CUR(description != NULL ? description : "Unknown signal"));
}
