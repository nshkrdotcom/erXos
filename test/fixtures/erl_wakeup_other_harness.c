/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Runs the wakeup-other checks of otp/erts/emulator/beam/erl_wakeup_other.h on
 * the cases test/host/erl_wakeup_other_test.rb writes to standard input, one
 * a line:
 *
 *   default COUNT REDS LEN LIMIT INC DEC_SHIFT DIRTY
 *   legacy COUNT REDS LEN LIMIT INC DEC
 *
 * and prints each step as "COUNT OVER", then "erl_wakeup_other done".
 */

#include <stdio.h>
#include <string.h>

#include "erl_wakeup_other.h"

int
main(void)
{
	char kind[16];
	int count, len, limit, inc, last, dirty;
	long long reds;
	ErtsWakeupOtherStep step;

	while (scanf("%15s %d %lld %d %d %d %d", kind, &count, &reds, &len,
	    &limit, &inc, &last) == 7) {
		if (strcmp(kind, "default") == 0) {
			if (scanf("%d", &dirty) != 1)
				return (2);
			step = erts_wakeup_other_step(count, reds, len, limit,
			    inc, last, dirty != 0);
		} else if (strcmp(kind, "legacy") == 0)
			step = erts_wakeup_other_step_legacy(count, reds, len,
			    limit, inc, last);
		else
			return (2);
		printf("%d %d\n", step.count, step.over ? 1 : 0);
	}
	printf("erl_wakeup_other done\n");
	return (0);
}
