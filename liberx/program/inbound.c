/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The event executor's pure decisions on the inbound lane
 * (liberx/program/inbound.h).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/program/inbound.h"

erx_prog_inbound_t
erx_prog_inbound_open(bool started, uint32_t kind, uint64_t zero, uint32_t len)
{
	if (kind != ERX_REC_FRAME || zero != 0 || len == 0)
		return (ERX_PROG_INBOUND_REFUSE);
	if (!started)
		return (len <= ERX_PROG_FRAME_MAX ? ERX_PROG_INBOUND_START :
		    ERX_PROG_INBOUND_REFUSE);
	return (len <= ERX_PROG_REPORT_MAX ? ERX_PROG_INBOUND_FRAME :
	    ERX_PROG_INBOUND_REFUSE);
}

void
erx_prog_slots_init(erx_prog_slots_t *slots)
{
	for (unsigned slot = 0; slot < ERX_PROFILE_SLOTS; slot++)
		slots->busy[slot] = ERX_PROFILE_NONE;
	slots->held = 0;
}

unsigned
erx_prog_slot_take(erx_prog_slots_t *slots, uint16_t request)
{
	for (unsigned slot = 0; slot < ERX_PROG_EXECUTOR_SLOT; slot++) {
		if ((slots->held & (1u << slot)) == 0) {
			slots->held |= (uint16_t)(1u << slot);
			slots->busy[slot] = request;
			return (slot);
		}
	}
	return (ERX_PROFILE_SLOTS);
}

bool
erx_prog_slot_answered(const erx_prog_slots_t *slots, unsigned slot)
{
	return ((slots->held & (1u << slot)) != 0 && slots->busy[slot] == ERX_PROFILE_NONE);
}

void
erx_prog_slot_release(erx_prog_slots_t *slots, unsigned slot)
{
	slots->held &= (uint16_t)~(1u << slot);
	slots->busy[slot] = ERX_PROFILE_NONE;
}

bool
erx_prog_inbound_read(erx_prog_slots_t *slots, const uint8_t *frame,
    size_t len, void *scratch, size_t scratch_len, erx_prog_to_program_t *got)
{
	erx_profile_refusal_t refusal;

	if (!erx_prog_check_to_program(frame, len, scratch, scratch_len,
	    slots->busy, got, &refusal))
		return (false);
	if (got->frame == ERX_PROG_FRAME_REPLY) {
		slots->replies[got->slot] = got->u.reply;
		slots->busy[got->slot] = ERX_PROFILE_NONE;
	}
	return (true);
}
