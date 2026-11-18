/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * How each end of the machine ends it, on the host (docs/design-fiasco.md, "The end
 * path"): only a requested power-off turns it off, and every end nobody ordered resets
 * it, so that an update's trial boot falls back.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/end_how.h"

static const struct {
	const char		*name;
	erx_fiasco_end_cause_t	 cause;
	uint32_t		 how;
} cases[] = {
	{ "a requested power-off", ERX_FIASCO_END_ASKED_OFF, ERX_END_OFF },
	{ "a requested reset", ERX_FIASCO_END_ASKED_RESET, ERX_END_RESET },
	{ "the root's stop", ERX_FIASCO_END_STOP, ERX_END_RESET },
	{ "a root fault", ERX_FIASCO_END_FAULT, ERX_END_RESET },
	{ "a missed pet", ERX_FIASCO_END_PET, ERX_END_RESET },
	{ "a refusal", ERX_FIASCO_END_REFUSED, ERX_END_RESET },
};

static const char *
how_name(uint32_t how)
{
	return (how == ERX_END_OFF ? "off" : how == ERX_END_RESET ? "reset" : "neither");
}

int
main(void)
{
	int failed = 0;

	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		const uint32_t how = erx_fiasco_end_how(cases[i].cause);

		if (how != cases[i].how) {
			printf("%s ends %s, not %s\n", cases[i].name, how_name(how), how_name(cases[i].how));
			failed = 1;
		}
	}
	if (failed == 0)
		printf("end: %zu cases\n", sizeof(cases) / sizeof(cases[0]));
	return (failed);
}
