/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_CACHE_H
#define ERX_FIASCO_CACHE_H

#include <stddef.h>
#include <stdint.h>

/* After this returns, every CPU's next fetch from the range sees what was written to it. */
void	erx_fiasco_cache_make_coherent(uintptr_t start, size_t size);

/* After this returns, what this CPU wrote to the range is at the point of coherence. */
void	erx_fiasco_cache_clean(uintptr_t start, size_t size);

/*
 * After this returns, the range holds no line this CPU fetched before the call: its next
 * reads see what a device or the firmware wrote at the point of coherence before the call.
 * Whatever this CPU wrote to the range is cleaned first, so nothing written is lost.
 */
void	erx_fiasco_cache_clean_invalidate(uintptr_t start, size_t size);

#endif /* ERX_FIASCO_CACHE_H */
