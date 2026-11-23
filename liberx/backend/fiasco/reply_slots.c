/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/fiasco/reply_slots.h"

void
erx_fiasco_reply_park(erx_fiasco_reply_slots_t *slots, uint32_t task)
{
	for (uint32_t slot = 0; slot < ERX_FIASCO_REPLY_SLOTS; slot++)
		if (slot != slots->receive && slots->parked[slot] == 0) {
			slots->parked[slots->receive] = (uint64_t)task + 1;
			slots->receive = slot;
			return;
		}
}

bool
erx_fiasco_reply_take(erx_fiasco_reply_slots_t *slots, bool (*live)(uint32_t task), uint32_t *slot)
{
	for (uint32_t index = 0; index < ERX_FIASCO_REPLY_SLOTS; index++)
		if (slots->parked[index] != 0 && !live((uint32_t)(slots->parked[index] - 1))) {
			slots->parked[index] = 0;
			*slot = index;
			return (true);
		}
	return (false);
}
