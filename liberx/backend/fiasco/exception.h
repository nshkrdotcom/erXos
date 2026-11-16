/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_EXCEPTION_H
#define ERX_FIASCO_EXCEPTION_H

#include <stdint.h>

#include "erx/abi.h"

/*
 * The fault kind of an exception Fiasco reports for a task's thread, decided from
 * the syndrome word of its exception record (l4_exc_regs_t's err) alone: an
 * asynchronous error is async_error, presumed the thread's since Fiasco delivers
 * it to whichever thread ran in user mode when it was taken; anything else is
 * undefined.
 */
erx_fault_kind_t	erx_fiasco_exception_kind(uint64_t syndrome);

#endif /* ERX_FIASCO_EXCEPTION_H */
