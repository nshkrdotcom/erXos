/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the root service's reply slots (liberx/backend/fiasco/reply_slots.c) on the
 * host: a parked fault moves the receive to another slot, the slot comes back once its
 * task is no longer live and is used again, a full table parks no more, and over a long
 * mix of parks and takes the receive slot is never a parked one and a slot comes back
 * only from a task no longer live. Prints the first wrong answer.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "liberx/backend/fiasco/reply_slots.h"

#define DRIVER_TASKS	8u
#define DRIVER_STEPS	100000u

/* Which tasks driver_live calls live: bit n for task n, every task at or past DRIVER_TASKS dead. */
static uint32_t driver_live_bits;

static bool
driver_live(uint32_t task)
{
	return (task < DRIVER_TASKS && (driver_live_bits >> task & 1u) != 0);
}

static uint32_t
driver_parked(const erx_fiasco_reply_slots_t *slots)
{
	uint32_t count = 0;

	for (uint32_t slot = 0; slot < ERX_FIASCO_REPLY_SLOTS; slot++)
		count += slots->parked[slot] != 0;
	return (count);
}

static bool
driver_fail(const char *what)
{
	printf("%s\n", what);
	return (false);
}

/* One fault parks its slot; the slot comes back only when its task is no longer live, and the next park uses it again. */
static bool
driver_one(void)
{
	erx_fiasco_reply_slots_t slots = { 0 };
	uint32_t slot;

	driver_live_bits = UINT32_MAX;
	erx_fiasco_reply_park(&slots, 5);
	if (slots.receive == 0 || slots.parked[0] != 6)
		return (driver_fail("a parked fault keeps the receive in its slot"));
	if (erx_fiasco_reply_take(&slots, driver_live, &slot))
		return (driver_fail("a live task's fault comes back"));
	driver_live_bits = ~(UINT32_C(1) << 5);
	if (!erx_fiasco_reply_take(&slots, driver_live, &slot) || slot != 0 || slots.parked[0] != 0)
		return (driver_fail("a stopped task's fault does not come back"));
	if (erx_fiasco_reply_take(&slots, driver_live, &slot))
		return (driver_fail("a slot comes back twice"));
	erx_fiasco_reply_park(&slots, 7);
	if (slots.receive != 0 || slots.parked[1] != 8)
		return (driver_fail("a slot that came back is not used again"));
	return (true);
}

/* A full table parks no more: the fault stays in the receive slot, which the next receive takes over. */
static bool
driver_full(void)
{
	erx_fiasco_reply_slots_t slots = { 0 };
	uint32_t receive;

	for (uint32_t fault = 0; fault + 1 < ERX_FIASCO_REPLY_SLOTS; fault++)
		erx_fiasco_reply_park(&slots, fault);
	if (driver_parked(&slots) != ERX_FIASCO_REPLY_SLOTS - 1 || slots.parked[slots.receive] != 0)
		return (driver_fail("the table does not fill to all slots but the receive"));
	receive = slots.receive;
	erx_fiasco_reply_park(&slots, 1);
	if (slots.receive != receive || slots.parked[receive] != 0 || driver_parked(&slots) != ERX_FIASCO_REPLY_SLOTS - 1)
		return (driver_fail("a full table parks a fault"));
	return (true);
}

/* A long mix of parks, takes and stops, from a fixed seed. */
static bool
driver_mix(void)
{
	erx_fiasco_reply_slots_t slots = { 0 };
	uint64_t seed = UINT64_C(0x9e3779b97f4a7c15);
	uint32_t slot;

	driver_live_bits = UINT32_MAX;
	for (uint32_t step = 0; step < DRIVER_STEPS; step++) {
		seed = seed * UINT64_C(6364136223846793005) + UINT64_C(1442695040888963407);
		const uint32_t task = (uint32_t)(seed >> 33) % DRIVER_TASKS;

		switch ((seed >> 60) % 4) {
		case 0:
		case 1:
			erx_fiasco_reply_park(&slots, task);
			break;
		case 2:
			driver_live_bits ^= UINT32_C(1) << task;
			break;
		default:
			while (erx_fiasco_reply_take(&slots, driver_live, &slot))
				if (slots.parked[slot] != 0 || slot == slots.receive)
					return (driver_fail("a slot came back still parked, or as the receive"));
			for (slot = 0; slot < ERX_FIASCO_REPLY_SLOTS; slot++)
				if (slots.parked[slot] != 0 && !driver_live((uint32_t)(slots.parked[slot] - 1)))
					return (driver_fail("a stopped task's fault stays parked after the takes"));
			break;
		}
		if (slots.receive >= ERX_FIASCO_REPLY_SLOTS || slots.parked[slots.receive] != 0)
			return (driver_fail("the receive fills a parked slot"));
	}
	return (true);
}

int
main(void)
{
	if (!driver_one() || !driver_full() || !driver_mix())
		return (1);
	puts("ok");
	return (0);
}
