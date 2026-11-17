/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives kernel/core/pm_wdt.c for test/host/pm_wdt_test.rb. Each line of standard
 * input is one request and gets one line of answer:
 *
 *   writes ACTION ARMED ENDING  -> writes 0|1, for ACTION none|arm|reload|end and
 *                                  ARMED, ENDING 0 or 1
 *   words RSTC                  -> words WDOG RSTC, the words of a write after RSTC read
 *                                  RSTC, all in hexadecimal
 */

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "erx/core/pm_wdt.h"

static const struct {
	const char		*name;
	erx_watchdog_action_t	action;
} actions[] = {
	{ "none", ERX_WATCHDOG_NONE },
	{ "arm", ERX_WATCHDOG_ARM },
	{ "reload", ERX_WATCHDOG_RELOAD },
	{ "end", ERX_WATCHDOG_END },
};

int
main(void)
{
	char request[256], name[16];
	unsigned armed, ending;
	uint32_t rstc;

	while (fgets(request, sizeof(request), stdin) != NULL) {
		if (sscanf(request, "writes %15s %u %u", name, &armed, &ending) == 3) {
			size_t at = 0;

			while (at < sizeof(actions) / sizeof(actions[0]) && strcmp(actions[at].name, name) != 0)
				at++;
			if (at == sizeof(actions) / sizeof(actions[0])) {
				printf("unknown action\n");
				continue;
			}
			printf("writes %d\n", erx_pm_wdt_writes(actions[at].action, armed != 0, ending != 0) ? 1 : 0);
		} else if (sscanf(request, "words %" SCNx32, &rstc) == 1) {
			const erx_pm_wdt_words_t words = erx_pm_wdt_words(rstc);

			printf("words %08" PRIx32 " %08" PRIx32 "\n", words.wdog, words.rstc);
		} else {
			printf("unknown request\n");
		}
	}
	return (0);
}
