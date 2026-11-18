/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_RNG_SEED_H
#define ERX_CORE_RNG_SEED_H

/*
 * A generator's boot seed (docs/design-kernel.md, "Entropy"), the one
 * sequence of seed sources: the counter keys the generator, then each seed
 * the device tree's /chosen carries is mixed in on its own, in
 * erx_dt_seed_t's order. Mixing never weakens the key (erx/core/rng.h), so
 * a firmware's poor seed costs nothing. A board whose /chosen carries no
 * seed adds its random generator's bytes after (erx_rng_seed_add). The root on Fiasco and erXos's
 * kernel both seed through it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/dt.h"
#include "erx/core/rng.h"

#ifdef __cplusplus
extern "C" {
#endif

/* What a seed mixed: length[s], the bytes of seed s that went in, 0 for one that did not. */
typedef struct erx_rng_seeded {
	size_t	 length[ERX_DT_SEEDS];
} erx_rng_seeded_t;

/*
 * Keys rng from counter's digest, then mixes in each seed of seeds, which
 * is NULL for a boot without a device tree. The seeds' bytes stay the
 * caller's to erase. Reports only what was mixed: a generator the counter
 * could not key mixes nothing, and its reads are refused.
 */
erx_rng_seeded_t	erx_rng_seed(erx_rng_t *rng, uint64_t counter, const erx_dt_seeds_t *seeds);
/*
 * Mixes in length bytes of one more source, at most ERX_RNG_DIGEST_INPUT_MAX, as
 * erx_rng_seed mixes each seed. Returns whether they went in.
 */
bool			erx_rng_seed_add(erx_rng_t *rng, const void *bytes, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_RNG_SEED_H */
