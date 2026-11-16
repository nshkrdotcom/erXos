/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_PM_WDT_H
#define ERX_FIASCO_PM_WDT_H

#include <stdbool.h>

#include "erx/core/dt.h"
#include "erx/mmio.h"
#include "erx/watchdog.h"

/*
 * The board's hardware watchdog on the stopgap (docs/design-platforms.md, "The
 * watchdog"; docs/design-stopgap.md, "The Raspberry Pi 4"), which the root's watchdog
 * thread drives in the kernel platform layer's place: the device shim around
 * kernel/core/pm_wdt.c, and the only code of the root that touches the watchdog's
 * registers. No runtime holds its window: its unit is of no kind.
 *
 * device.length is 0 while the board has no watchdog the root may drive.
 * armed says the hardware has been written once. Only the watchdog thread holds one.
 */
typedef struct erx_fiasco_pm_wdt {
	erx_mmio_t	device;
	bool		armed;
} erx_fiasco_pm_wdt_t;

/* What the root found of the board's hardware watchdog (erx_fiasco_program_watchdog). */
typedef enum erx_fiasco_board_wdt {
	/* The manifest gives the system domain none. */
	ERX_FIASCO_BOARD_WDT_ABSENT = 1,
	/* Its row is confirmed by the tree and its registers are mapped. */
	ERX_FIASCO_BOARD_WDT_READY,
	/* The tree does not confirm its row, or its page cannot be mapped: the board has none. */
	ERX_FIASCO_BOARD_WDT_UNCONFIRMED
} erx_fiasco_board_wdt_t;

/*
 * Maps the page of window, the platform row's window that the tree has confirmed
 * (erx_fiasco_program_watchdog, through erx_dt_registers), and reads both registers once
 * to prove they lie in what is mapped. False, with *wdt holding no device, for a page the
 * root cannot map or a window too short. Nothing is written.
 */
bool	erx_fiasco_pm_wdt_open(erx_dt_window_t window, erx_fiasco_pm_wdt_t *wdt);

/*
 * Carries out one step of the kernel's watchdog on the hardware: arms it on ARM,
 * reloads it on a RELOAD once armed, and writes nothing once an end of the machine is
 * taken (erx_pm_wdt_writes). A wdt with no device does nothing.
 */
void	erx_fiasco_pm_wdt_step(erx_fiasco_pm_wdt_t *wdt, erx_watchdog_action_t action);

#endif /* ERX_FIASCO_PM_WDT_H */
