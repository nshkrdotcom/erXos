/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_END_HOW_H
#define ERX_FIASCO_END_HOW_H

#include <stdbool.h>
#include <stdint.h>

/*
 * How each end of the machine ends it (docs/design-stopgap.md, "The end path"):
 * pure functions of why it ends, so the host tests them. Only a requested power-off
 * turns the machine off; every end nobody ordered resets it, so that an update's
 * trial boot that fails falls back to its other slot.
 */

typedef enum erx_fiasco_end_cause {
	ERX_FIASCO_END_ASKED_OFF = 1,	/* erx_machine_end with ERX_END_OFF, or a test root's own power-off */
	ERX_FIASCO_END_ASKED_RESET,	/* erx_machine_end with ERX_END_RESET */
	ERX_FIASCO_END_STOP,		/* the root stopped itself, as ERTS's halt does */
	ERX_FIASCO_END_FAULT,		/* the root faulted */
	ERX_FIASCO_END_PET,		/* the watchdog's pet was missed */
	ERX_FIASCO_END_REFUSED		/* the boot, the kernel or the service refused a step the root needs */
} erx_fiasco_end_cause_t;

/* ERX_END_OFF or ERX_END_RESET. */
uint32_t	erx_fiasco_end_how(erx_fiasco_end_cause_t cause);
/*
 * Whether the end first writes the debug log's waiting records: an end the service
 * takes, since the service alone writes the log ring, and a test root's own power-off,
 * made from its own thread when no task is left to log through the service; not a
 * refusal, which may come on any thread, nor a missed pet, with the service mid-write.
 */
bool	erx_fiasco_end_drains_log(erx_fiasco_end_cause_t cause);

#endif /* ERX_FIASCO_END_HOW_H */
