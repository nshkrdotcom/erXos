/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel's log object, as the root task holds it from the start
 * (docs/design-fiasco.md, "Boot handoff"). Bytes go out as given: text
 * attributed to a source is escaped by its caller before it gets here, and a
 * program's own output is not filtered.
 */

#include <l4/sys/consts.h>
#include <l4/sys/ipc.h>
#include <l4/sys/vcon.h>

#include "liberx/backend/fiasco/console.h"

/*
 * Writes one call's worth at a time. A console that fails drops the rest, as
 * the kernel's early console drops a byte its UART will not take: the caller's
 * result never depends on the console.
 */
void
erx_fiasco_console_write(const char *text, size_t length)
{
	size_t chunk;

	while (length > 0) {
		chunk = length < L4_VCON_WRITE_SIZE ? length : L4_VCON_WRITE_SIZE;
		if (l4_vcon_write(L4_BASE_LOG_CAP, text, (unsigned)chunk) < 0)
			return;
		text += chunk;
		length -= chunk;
	}
}

_Noreturn void
erx_fiasco_sleep_forever(void)
{
	for (;;)
		(void)l4_ipc_sleep(L4_IPC_NEVER);
}
