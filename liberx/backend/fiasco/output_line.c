/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The runtime's C output as debug log records (output_line.h). Alone in its file, beside
 * nothing of the start path: musl refers to erx_fiasco_libc_write, which calls this, from
 * every stdio call, and a root links liberxroot.a ahead of its own objects.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/core/line_gather.h"
#include "liberx/backend/fiasco/output_line.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/generated/calls.h"

/* A gathered piece is one debug log call's text, so its length is a valid erx_utcb_length_t. */
_Static_assert(ERX_LINE_GATHER_BYTES <= ERX_UTCB_BYTES_MAX, "a gathered line fits one debug log record");

static erx_line_gather_emit_t	log_line;

void
erx_fiasco_output_write(const void *bytes, size_t length)
{
	erx_line_gather_write(&erx_fiasco_thread_self()->line, bytes, length, log_line, NULL);
}

/* One whole line, without its newline, or a full gather's piece of a longer one, as one record. */
static void
log_line(void *context, const char *line, size_t length)
{
	(void)context;
	erx_fiasco_utcb_store_bytes(line, length);
	(void)erx_debug_log((erx_utcb_length_t){ .raw = (uint32_t)length });
}
