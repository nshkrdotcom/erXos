/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Answers test/host/bcm2711_pins_test.rb's requests to kernel/core/bcm2711_pins.c, one a
 * line: "plan W0 W1 W2 W3 W4 W5 G:A ..." with the six GPFSEL words as read in hex and each
 * row's pin and alternate, answered "plan", or "refused" for a plan the core refuses,
 * and the six words after it.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/bcm2711_pins.h"

int
main(void)
{
	char request[512];

	while (fgets(request, sizeof(request), stdin) != NULL) {
		erx_mf_pin_t rows[ERX_BCM2711_PINS_ROWS_MAX + 2];
		erx_bcm2711_fsel_t fsel;
		size_t count = 0;
		char *word = strtok(request, " \n");

		if (word == NULL || strcmp(word, "plan") != 0) {
			printf("unknown request\n");
			continue;
		}
		for (uint32_t at = 0; at < ERX_BCM2711_PINS_REGISTERS; at++) {
			word = strtok(NULL, " \n");
			fsel.word[at] = word == NULL ? 0 : (uint32_t)strtoul(word, NULL, 16);
		}
		while ((word = strtok(NULL, " \n")) != NULL && count < sizeof(rows) / sizeof(rows[0])) {
			unsigned gpio, alternate;

			if (sscanf(word, "%u:%u", &gpio, &alternate) != 2)
				break;
			rows[count++] = (erx_mf_pin_t){ .pin = gpio, .function = ERX_PIN_FUNCTION_ALTERNATE, .alternate = alternate };
		}
		fputs(erx_bcm2711_pins_plan(rows, count, &fsel) ? "plan" : "refused", stdout);
		for (uint32_t at = 0; at < ERX_BCM2711_PINS_REGISTERS; at++)
			printf(" %08" PRIx32, fsel.word[at]);
		printf("\n");
	}
	return (0);
}
