/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_OUTPUT_LINE_H
#define ERX_FIASCO_OUTPUT_LINE_H

/*
 * A runtime's own C output as debug log records, the same in the root and in a domain's
 * task (docs/design-runtime.md, "The console and standard I/O"). What ERTS and musl write to
 * standard output and standard error, and the root's group report, is gathered into whole
 * lines in the writing thread's record (thread.h), and each line goes to erx_debug_log as
 * one record, which the log escapes, labels with the writer's space and rate-limits. The
 * log writes it to the UART by polling until the log service's first take and leaves it in
 * the ring for that service after it, so the console's one sink writes it whole. A partial
 * line a thread leaves at its end is dropped, and standard output and standard error share
 * the thread's line. The log never waits: past the space's rate it drops and counts the
 * line, and a full ring overwrites its oldest record, which the reader reports lost, so
 * nothing is retried.
 *
 * Every thread liberx starts has a record, and so does the first thread once
 * erx_fiasco_thread_first_init has run. The watchdog's thread has none and writes only
 * through the end path. The root service's thread has none (service.c,
 * service_start), and the line's call to erx_debug_log would be a call to its own gate:
 * it never writes here, as its sources compile without musl's headers, so no stdio
 * reaches it, and none of them includes this header.
 */

#include <stddef.h>

/* Standard output's and standard error's bytes, as written, on a thread with a record. */
void	erx_fiasco_output_write(const void *bytes, size_t length);

#endif /* ERX_FIASCO_OUTPUT_LINE_H */
