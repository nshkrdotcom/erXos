/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/end_how.h"

uint32_t
erx_fiasco_end_how(erx_fiasco_end_cause_t cause)
{
	switch (cause) {
	case ERX_FIASCO_END_ASKED_OFF:
	case ERX_FIASCO_END_STOP:
		return (ERX_END_OFF);
	case ERX_FIASCO_END_ASKED_RESET:
	case ERX_FIASCO_END_FAULT:
	case ERX_FIASCO_END_PET:
		break;
	}
	/* The reset group's end, and any cause the enum does not name. */
	return (ERX_END_RESET);
}
