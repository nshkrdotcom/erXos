/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_END_HOW_H
#define ERX_FIASCO_END_HOW_H

#include <stdint.h>

/*
 * How each end of the machine ends it (docs/design-stopgap.md, "The end path"):
 * a pure function of why it ends, so the host tests it. An end nobody asked for
 * resets the machine, so that an update's trial boot falls back to its other slot;
 * the root's request and its own stop end as they say.
 */

typedef enum erx_fiasco_end_cause {
	ERX_FIASCO_END_ASKED_OFF = 1,	/* erx_machine_end with ERX_END_OFF */
	ERX_FIASCO_END_ASKED_RESET,	/* erx_machine_end with ERX_END_RESET */
	ERX_FIASCO_END_STOP,		/* the root stopped itself */
	ERX_FIASCO_END_FAULT,		/* the root faulted */
	ERX_FIASCO_END_PET		/* the watchdog's pet was missed */
} erx_fiasco_end_cause_t;

/* ERX_END_OFF or ERX_END_RESET. */
uint32_t	erx_fiasco_end_how(erx_fiasco_end_cause_t cause);

#endif /* ERX_FIASCO_END_HOW_H */
