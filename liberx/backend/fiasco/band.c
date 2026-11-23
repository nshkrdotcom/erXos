/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root service's bands, pure (docs/design-fiasco.md, "Bands"): the table of their
 * priorities, indexed by the band itself, and the bands a new task takes. The table leaves
 * no gaps between the bands below the watchdog, and priority 1, the lowest Fiasco gives a
 * thread, is the app band's, so no thread runs below it. No band, a zeroed row's, and any
 * value past the table have priority 0, which Fiasco refuses, so a thread of a row a writer
 * forgot to fill never starts, rather than starting above its band.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/band.h"

/* Two bands on one index would give one of them the other's priority. */
_Static_assert(ERX_BAND_DRIVER < ERX_FIASCO_BAND_SYSTEM && ERX_BAND_INTERACTIVE < ERX_FIASCO_BAND_SYSTEM &&
    ERX_BAND_APP < ERX_FIASCO_BAND_SYSTEM && ERX_FIASCO_BAND_NONE < ERX_BAND_DRIVER &&
    ERX_FIASCO_BAND_NONE < ERX_BAND_INTERACTIVE && ERX_FIASCO_BAND_NONE < ERX_BAND_APP,
    "the root's bands and none lie outside erx_band_t's members");

static const uint8_t band_priorities[] = {
	[ERX_FIASCO_BAND_WATCHDOG] = 255,
	[ERX_FIASCO_BAND_SYSTEM] = 4,
	[ERX_BAND_DRIVER] = 3,
	[ERX_BAND_INTERACTIVE] = 2,
	[ERX_BAND_APP] = 1,
};

uint32_t
erx_fiasco_band_priority(erx_band_t band)
{
	return (band < sizeof(band_priorities) / sizeof(band_priorities[0]) ? band_priorities[band] : 0);
}

int
erx_fiasco_band_domain(const erx_fiasco_domain_space_create_request_t *request, erx_fiasco_task_band_t *row)
{
	if (erx_band_name(request->band) == NULL || erx_band_name(request->space_band) == NULL)
		return (ERX_EINVAL);
	*row = (erx_fiasco_task_band_t){ .band = request->band, .space_band = request->space_band,
	    .cpuset = request->cpuset };
	return (ERX_OK);
}

erx_fiasco_task_band_t
erx_fiasco_band_inherit(const erx_fiasco_task_band_t *creator, uint32_t creator_domain)
{
	return ((erx_fiasco_task_band_t){ .domain = creator_domain, .band = creator->space_band });
}
