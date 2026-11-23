/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Answers test/host/bcm2711_pins_test.rb's requests to the root's on-board pin shim,
 * liberx/backend/fiasco/bcm2711_pins.c, over a stand-in register block in memory, one a
 * line: "apply LEN W0 W1 W2 W3 W4 W5 G:A ..." with the window's length in bytes, the six
 * GPFSEL words the block holds in hex and each row's pin and alternate. The answer is the
 * shim's outcome, "set", "refused" or "mismatch", and the six words the block holds after.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/bcm2711_pins.h"
#include "liberx/backend/fiasco/bcm2711_pins.h"
#include "liberx/backend/fiasco/vm.h"

/* The shim's mapping step, which the requests never reach: they hand the block to the apply step. */
int
erx_fiasco_vm_device_page(uint64_t page, uintptr_t *window)
{
	(void)page;
	(void)window;
	return (ERX_ENOTSUP);
}

static const char *
outcome_name(erx_fiasco_board_pins_t outcome)
{
	switch (outcome) {
	case ERX_FIASCO_BOARD_PINS_SET:
		return ("set");
	case ERX_FIASCO_BOARD_PINS_REFUSED:
		return ("refused");
	case ERX_FIASCO_BOARD_PINS_MISMATCH:
		return ("mismatch");
	default:
		return ("unexpected");
	}
}

int
main(void)
{
	char request[512];

	while (fgets(request, sizeof(request), stdin) != NULL) {
		erx_mf_onboard_pin_t rows[ERX_BCM2711_PINS_ROWS_MAX];
		uint32_t block[ERX_BCM2711_PINS_REGISTERS];
		erx_mmio_t device;
		size_t count = 0;
		char *word = strtok(request, " \n");

		if (word == NULL || strcmp(word, "apply") != 0 || (word = strtok(NULL, " \n")) == NULL) {
			printf("unknown request\n");
			continue;
		}
		device.base = (volatile uint8_t *)block;
		device.length = (size_t)strtoul(word, NULL, 10);
		for (uint32_t at = 0; at < ERX_BCM2711_PINS_REGISTERS; at++) {
			word = strtok(NULL, " \n");
			block[at] = word == NULL ? 0 : (uint32_t)strtoul(word, NULL, 16);
		}
		while ((word = strtok(NULL, " \n")) != NULL && count < ERX_BCM2711_PINS_ROWS_MAX) {
			unsigned gpio, alternate;

			if (sscanf(word, "%u:%u", &gpio, &alternate) != 2)
				break;
			rows[count++] = (erx_mf_onboard_pin_t){ .gpio = gpio, .alternate = alternate };
		}
		fputs(outcome_name(erx_fiasco_bcm2711_pins_apply(device, rows, count)), stdout);
		for (uint32_t at = 0; at < ERX_BCM2711_PINS_REGISTERS; at++)
			printf(" %08" PRIx32, block[at]);
		printf("\n");
	}
	return (0);
}
