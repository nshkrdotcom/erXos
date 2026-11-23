/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root service's bands, pure (docs/design-fiasco.md, "Bands"): the levels, the table of
 * each band's base and ceiling, indexed by the band itself, and the bands a new task takes.
 * The configured domains are not ranked: the root task's ordinary work, the drivers' and the
 * interactive domains' all start at the base level, and only the urgent level and the
 * watchdog's are above it. Priority 1, the lowest Fiasco gives a thread, is the app level,
 * so no thread runs below it. No band, a zeroed row's, and any value past the table have
 * levels of 0, which Fiasco refuses (Sched_context::check_param in
 * fiasco/kernel/src/kern/sched_context-fixed_prio.cpp refuses any priority at or below its
 * Kernel_prio, 0), so a thread of a row a writer forgot to fill never starts, rather than
 * starting above its band.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/band.h"

/* The levels, each a Fiasco priority. */
enum {
	LEVEL_APP = 1,		/* code the system does not trust */
	LEVEL_BASE = 2,		/* every configured domain's ordinary work and the root service */
	LEVEL_URGENT = 3,	/* a thread that waits for urgent work */
	LEVEL_WATCHDOG = 255,	/* the root's watchdog */
};

/* Two bands on one index would give one of them the other's levels. */
_Static_assert(ERX_BAND_DRIVER < ERX_FIASCO_BAND_ROOT && ERX_BAND_INTERACTIVE < ERX_FIASCO_BAND_ROOT &&
    ERX_BAND_APP < ERX_FIASCO_BAND_ROOT && ERX_FIASCO_BAND_NONE < ERX_BAND_DRIVER &&
    ERX_FIASCO_BAND_NONE < ERX_BAND_INTERACTIVE && ERX_FIASCO_BAND_NONE < ERX_BAND_APP,
    "the root's bands and none lie outside erx_band_t's members");

static const erx_fiasco_band_levels_t band_levels[] = {
	[ERX_FIASCO_BAND_WATCHDOG] = { .base = LEVEL_WATCHDOG, .ceiling = LEVEL_WATCHDOG },
	[ERX_FIASCO_BAND_ROOT] = { .base = LEVEL_BASE, .ceiling = LEVEL_URGENT },
	[ERX_BAND_DRIVER] = { .base = LEVEL_BASE, .ceiling = LEVEL_URGENT },
	[ERX_BAND_INTERACTIVE] = { .base = LEVEL_BASE, .ceiling = LEVEL_BASE },
	[ERX_BAND_APP] = { .base = LEVEL_APP, .ceiling = LEVEL_APP },
};

erx_fiasco_band_levels_t
erx_fiasco_band_levels(erx_band_t band)
{
	return (band < sizeof(band_levels) / sizeof(band_levels[0]) ? band_levels[band] :
	    (erx_fiasco_band_levels_t){ 0 });
}

int
erx_fiasco_band_domain(const erx_fiasco_domain_space_create_request_t *request, erx_fiasco_task_band_t *row)
{
	if (erx_band_name(request->band) == NULL || erx_band_name(request->space_band) == NULL ||
	    request->slice_us < ERX_SLICE_MIN_US || request->slice_us > ERX_SLICE_MAX_US)
		return (ERX_EINVAL);
	*row = (erx_fiasco_task_band_t){ .band = request->band, .space_band = request->space_band,
	    .slice_us = request->slice_us, .cpuset = request->cpuset };
	return (ERX_OK);
}

erx_fiasco_task_band_t
erx_fiasco_band_inherit(const erx_fiasco_task_band_t *creator, uint32_t creator_domain)
{
	return ((erx_fiasco_task_band_t){ .domain = creator_domain, .band = creator->space_band });
}
