/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/rng_seed.h"

/* Each seed the reader gives is one digest's input, so it mixes as one part. */
_Static_assert(ERX_DT_SEED_MAX == ERX_RNG_DIGEST_INPUT_MAX, "a seed is one digest's input");

erx_rng_seeded_t
erx_rng_seed(erx_rng_t *rng, uint64_t counter, const erx_dt_seeds_t *seeds)
{
	erx_rng_seeded_t seeded = { { 0 } };
	erx_rng_digest_t digest;

	if (erx_rng_digest(&digest, &counter, sizeof(counter)))
		erx_rng_init(rng, &digest);
	if (seeds == NULL)
		return (seeded);
	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++) {
		const size_t length = seeds->length[seed];

		if (length != 0 && erx_rng_seed_add(rng, seeds->bytes[seed], length))
			seeded.length[seed] = length;
	}
	return (seeded);
}

bool
erx_rng_seed_add(erx_rng_t *rng, const void *bytes, size_t length)
{
	erx_rng_digest_t digest;

	return (erx_rng_digest(&digest, bytes, length) && erx_rng_mix(rng, &digest));
}
