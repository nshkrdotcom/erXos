/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_CONSOLE_H
#define ERX_FIASCO_CONSOLE_H

#include <stddef.h>

/*
 * The root task's way to the kernel's polled UART output, and the sleep of a thread
 * that has nothing left to do (docs/design-fiasco.md, "The console"). Neither
 * takes a lock: the threads that call them take none around them.
 */
void erx_fiasco_console_write(const char *, size_t);
_Noreturn void	erx_fiasco_sleep_forever(void);

#endif /* ERX_FIASCO_CONSOLE_H */
