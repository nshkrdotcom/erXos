/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/core/pm_wdt.h"
#include "erx/hw/pm_wdt.h"

_Static_assert((uint64_t)ERX_PM_WDT_TIMEOUT_S * ERX_PM_WDT_UNITS_PER_S <= 0xfffffu,
    "the timeout fits WDOG's 20-bit time");

bool
erx_pm_wdt_writes(erx_watchdog_action_t action, bool armed, bool ending)
{
	if (ending)
		return (false);
	return (action == ERX_WATCHDOG_ARM || (action == ERX_WATCHDOG_RELOAD && armed));
}

/*
 * Each setter takes a value its field holds (the assertion above, and the SVD's
 * enumerations), so none refuses, and the words start from what each setter wrote.
 */
erx_pm_wdt_words_t
erx_pm_wdt_words(uint32_t rstc)
{
	erx_pm_wdt_words_t words = { .wdog = 0, .rstc = rstc };

	(void)erx_pm_wdt_wdog_time_set(words.wdog, ERX_PM_WDT_TIMEOUT_S * ERX_PM_WDT_UNITS_PER_S, &words.wdog);
	(void)erx_pm_wdt_wdog_passwd_set(words.wdog, ERX_PM_WDT_WDOG_PASSWD_KEY, &words.wdog);
	(void)erx_pm_wdt_rstc_wrcfg_set(words.rstc, ERX_PM_WDT_RSTC_WRCFG_FULL_RESET, &words.rstc);
	(void)erx_pm_wdt_rstc_passwd_set(words.rstc, ERX_PM_WDT_RSTC_PASSWD_KEY, &words.rstc);
	return (words);
}
