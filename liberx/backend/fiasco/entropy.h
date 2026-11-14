/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_ENTROPY_H
#define ERX_FIASCO_ENTROPY_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/dt.h"

/*
 * The entropy calls' bodies (docs/design-stopgap.md, "The call table"): the kernel's
 * generator, kernel/core/rng.c, in the root. The service alone runs the bodies, and the
 * root's first thread the init before the service runs, so nothing here takes a lock.
 */

/*
 * Seeds the generator from the counter and seeds, /chosen's or NULL (erx_rng_seed), and
 * says on the console what went in.
 */
void	erx_fiasco_entropy_init(const erx_dt_seeds_t *seeds);
/* The next two words of output. */
int	erx_fiasco_entropy_read_body(uint64_t *first, uint64_t *second);
/* Mixes in the request's bytes. More than its four words hold is ERX_EINVAL. */
int	erx_fiasco_entropy_add_body(const erx_fiasco_entropy_add_request_t *request);

#endif /* ERX_FIASCO_ENTROPY_H */
