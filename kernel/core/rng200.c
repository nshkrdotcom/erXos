/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>

#include "erx/core/rng200.h"

erx_rng200_read_t
erx_rng200_start(uint64_t now_ns)
{
	erx_rng200_read_t read = { .words = 0 };

	if (__builtin_add_overflow(now_ns, ERX_RNG200_WAIT_NS, &read.deadline_ns))
		read.deadline_ns = UINT64_MAX;
	return (read);
}

erx_rng200_action_t
erx_rng200_next(const erx_rng200_read_t *read, uint32_t count, uint64_t now_ns, uint32_t *take)
{
	const uint32_t missing = ERX_RNG200_WORDS - read->words;

	*take = 0;
	if (missing == 0)
		return (ERX_RNG200_DONE);
	if (now_ns >= read->deadline_ns)
		return (ERX_RNG200_TIMED_OUT);
	if (count == 0)
		return (ERX_RNG200_POLL);
	*take = count < missing ? count : missing;
	return (ERX_RNG200_TAKE);
}

void
erx_rng200_take(erx_rng200_read_t *read, uint32_t word)
{
	if (read->words < ERX_RNG200_WORDS)
		read->word[read->words++] = word;
}
