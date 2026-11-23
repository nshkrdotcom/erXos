/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_BAND_H
#define ERX_FIASCO_BAND_H

#include <stdint.h>

#include "erx/abi.h"

/*
 * The bands of the Fiasco backend (docs/design-fiasco.md, "Bands"). A band is an erx_band_t:
 * one of the ABI's three, the bands a domain may run at, or one of the root task's own two
 * above them, which no manifest names and which only the backend's own code writes. A band
 * is the Fiasco priority every thread of a task starts at, and erx_fiasco_band_priority is
 * the one table of those priorities, which every thread start reads, the root service's and
 * the watchdog's included. Band 0 is no band: a zeroed row's, with no priority.
 */
#define ERX_FIASCO_BAND_NONE		UINT32_C(0)
#define ERX_FIASCO_BAND_SYSTEM		UINT32_C(4)	/* the root service and the system domain's threads */
#define ERX_FIASCO_BAND_WATCHDOG	UINT32_C(5)	/* the root's watchdog, which takes no lock */

/*
 * What a task row keeps of its bands. Every task names its domain row, the task its domain's
 * domain_space_create made, or the root's own row; a domain row also holds the band of every
 * space made below the domain and the domain's CPU set.
 */
typedef struct erx_fiasco_task_band {
	uint32_t	domain;		/* its domain row's task index */
	erx_band_t	band;		/* its threads' */
	erx_band_t	space_band;	/* in a domain row: its sub-spaces' */
	uint64_t	cpuset;		/* in a domain row: its grant's CPU set */
} erx_fiasco_task_band_t;

/* The Fiasco priority of a band a row holds: an erx_band_t member or one of the root's own. */
uint32_t	erx_fiasco_band_priority(erx_band_t band);

/*
 * The domain row a domain_space_create request asks for, checked before anything is made:
 * the request's bands and CPU set. A band outside erx_band_t's members is ERX_EINVAL, and
 * *row is left as it was. A domain row names itself, so its domain, the new task's index,
 * is written by the fill that picks the index.
 */
int	erx_fiasco_band_domain(const erx_fiasco_domain_space_create_request_t *request, erx_fiasco_task_band_t *row);

/*
 * The bands of any other space, made by a task whose domain row is `creator`, at task index
 * creator_domain: it names that domain row and runs at the row's sub-space band, never at
 * its creator's own band.
 */
erx_fiasco_task_band_t	erx_fiasco_band_inherit(const erx_fiasco_task_band_t *creator, uint32_t creator_domain);

#endif /* ERX_FIASCO_BAND_H */
