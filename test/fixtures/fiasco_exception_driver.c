/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives erx_fiasco_exception_kind on the host: every exception class, with
 * the syndrome's other bits all clear and all set, must give async_error for
 * an SError and undefined for anything else. Prints the first wrong answer.
 */

#include <stdint.h>
#include <stdio.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/exception.h"

#define DRIVER_CLASS_SHIFT	26u
#define DRIVER_CLASS_SERROR	UINT64_C(0x2f)
#define DRIVER_CLASSES		UINT64_C(64)

int
main(void)
{
	static const uint64_t others[] = { 0, ~(UINT64_C(0x3f) << DRIVER_CLASS_SHIFT) };

	for (uint64_t class = 0; class < DRIVER_CLASSES; class++) {
		const erx_fault_kind_t expected = class == DRIVER_CLASS_SERROR ? ERX_FAULT_ASYNC_ERROR : ERX_FAULT_UNDEFINED;

		for (size_t i = 0; i < sizeof(others) / sizeof(others[0]); i++) {
			const uint64_t syndrome = (class << DRIVER_CLASS_SHIFT) | others[i];
			const erx_fault_kind_t kind = erx_fiasco_exception_kind(syndrome);

			if (kind != expected) {
				printf("class %#llx syndrome %#llx: kind %u, expected %u\n", (unsigned long long)class,
				    (unsigned long long)syndrome, (unsigned)kind, (unsigned)expected);
				return (1);
			}
		}
	}
	puts("ok");
	return (0);
}
