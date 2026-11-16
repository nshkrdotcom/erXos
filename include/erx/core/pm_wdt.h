/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_PM_WDT_H
#define ERX_CORE_PM_WDT_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/watchdog.h"

/*
 * The board's hardware watchdog behind the kernel's watchdog (docs/design-platforms.md,
 * "The watchdog"): the BCM2711's power-management watchdog, armed at the watchdog's
 * start and reloaded at every tick, so a hang of everything that ticks resets the board
 * within ERX_PM_WDT_TIMEOUT_S. This is the pure part: whether a step writes the
 * hardware, and the two words a write puts in WDOG and then RSTC. The caller's device
 * shim reads RSTC, writes the words and nothing else. The register facts are
 * hw/svd/pm_wdt/pm_wdt.svd's.
 *
 * Arming and reloading are the same two writes: a WDOG write with the password starts
 * the count again from its time, and the RSTC write keeps the full reset selected. Nothing
 * here ever stops the watchdog: no end, requested or not, stops it.
 */

/* The device tree's compatible string of the watchdog's block, which the platform row names. */
#define ERX_PM_WDT_COMPATIBLE	"brcm,bcm2835-pm-wdt"
/* The time from a write to the reset when no write follows, in seconds. */
#define ERX_PM_WDT_TIMEOUT_S	4u
/* WDOG's time counts in units of 1/65536 s. */
#define ERX_PM_WDT_UNITS_PER_S	65536u

/* The two words of one write, WDOG's first. */
typedef struct erx_pm_wdt_words {
	uint32_t	wdog;
	uint32_t	rstc;
} erx_pm_wdt_words_t;

/*
 * Whether the hardware is written after a step of the kernel's watchdog that asked for
 * action: an ARM arms it, a RELOAD reloads it once it is armed, and nothing writes it
 * once an end of the machine is taken, so the end's own reset, or the halt of a board
 * turned off on request, is never pushed out. A RELOAD before an ARM, as the
 * deterministic mode's ticks are, leaves an unarmed watchdog unarmed.
 */
bool	erx_pm_wdt_writes(erx_watchdog_action_t action, bool armed, bool ending);

/*
 * The words of one write given RSTC as read: WDOG the timeout with the password, RSTC as
 * read with the full reset selected and the password in place of whatever its top byte read.
 */
erx_pm_wdt_words_t	erx_pm_wdt_words(uint32_t rstc);

#endif /* ERX_CORE_PM_WDT_H */
