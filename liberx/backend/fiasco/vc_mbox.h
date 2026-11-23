/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_VC_MBOX_H
#define ERX_FIASCO_VC_MBOX_H

#include <stdbool.h>

#include "erx/core/dt.h"

/*
 * The firmware's mailbox on Fiasco (docs/design-fiasco.md, "The call table",
 * erx_firmware_request; docs/design-kernel.md, "Firmware requests"): the root task maps
 * its registers in the kernel's place, and this device shim is the only code of the root
 * that touches them. No runtime holds its window: its unit is of no kind, so the mailbox,
 * which can read the board's key, goes to no driver (docs/design-platforms.md, PL2).
 *
 * The shim keeps the one mapping for the boot, for the request routine of the firmware
 * request, erx_firmware_request_row (liberx/backend/api.h), which drives the
 * kernel/core/vc_mailbox.c state machine over a buffer page of the root's own.
 */

/*
 * Maps the page of window, the platform row's window that the tree has confirmed
 * (erx_fiasco_program_board, through erx_dt_registers), reads STATUS once to prove it
 * lies in what is mapped, and keeps the mapping for the boot. False, with no mailbox kept,
 * for a page the root cannot map or a window too short for STATUS. Nothing is written.
 * Only the root's first thread calls it, once, before any request.
 */
bool	erx_fiasco_vc_mbox_open(erx_dt_window_t window);

/* Whether the root keeps a mailbox, which a firmware request needs to post to. */
bool	erx_fiasco_vc_mbox_kept(void);

#endif /* ERX_FIASCO_VC_MBOX_H */
