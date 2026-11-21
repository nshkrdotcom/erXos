/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_PAGE_POOL_H
#define ERX_FIASCO_PAGE_POOL_H

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/core/grow_table.h"
#include "liberx/backend/core/vm_table.h"

/*
 * The pool of free pages (docs/design-fiasco.md, "The pool"). A page's identity
 * is its address in the window, and the free pages are a list threaded through
 * the pages themselves, so the pool costs no memory of its own. A free page
 * holds its link and whatever its last holder left; it is zeroed when taken, so
 * what a taker sees never depends on who held the page before.
 *
 * held_pages counts the pages taken and not yet put back: the budget topic's
 * used (docs/design-fiasco.md, "Reporting a budget"). The service alone calls
 * the pool, one call at a time, so the count needs no lock of its own.
 *
 * This core touches only the pages it is handed, so it builds for the host.
 */
typedef struct erx_fiasco_pool {
	uintptr_t	head;		/* first free page's address, or 0 */
	uint64_t	free_pages;
	uint64_t	held_pages;	/* taken and not put back */
	uint64_t	pages;		/* the pages added as the pool was built: the machine topic's memory_total */
} erx_fiasco_pool_t;

/* Adds one page the pool has never handed out, as the pool is built. */
void		erx_fiasco_pool_add(erx_fiasco_pool_t *, uintptr_t);

/*
 * Gives back one page the pool handed out. No one may hold a mapping of it any more.
 * held_pages stays at 0 rather than wrap, should a page come back that was never taken.
 */
void		erx_fiasco_pool_put(erx_fiasco_pool_t *, uintptr_t);

/* A zeroed page's window address, or 0 when the pool is empty. */
uintptr_t	erx_fiasco_pool_take(erx_fiasco_pool_t *);

/*
 * The contiguous pool (docs/design-fiasco.md, "The pool"): one flexpage's pages,
 * handed out first fit, each run aligned to a page, on the claim, unverified against the
 * architecture's report of its writeback granule (TODO.md), that no cache-writeback
 * granule exceeds a page. A run is never given back: an unconfined device may still write it.
 *
 * The flexpage is as large as the devices' memory the manifest declares: the
 * smallest power of two that holds the total, of an order from
 * ERX_FIASCO_CONTIG_ORDER_MIN to ERX_FIASCO_CONTIG_ORDER_MAX (abi/erx_abi.txt), 2 MiB
 * to 16 MiB (erx_fiasco_contig_order). Each device's memory is made once, so runs
 * of that total always fit. The packer counts the same figure in what the boot
 * keeps (Manifest::RootStartup.contiguous_pool_bytes in tools/lib/erx/manifest.rb,
 * which reads the two orders from the generated ABI).
 */
/* The pages of the largest pool. */
#define ERX_FIASCO_CONTIG_PAGES	((uint32_t)((UINT64_C(1) << ERX_FIASCO_CONTIG_ORDER_MAX) / ERX_PAGE_SIZE))
#define ERX_FIASCO_CONTIG_NONE	UINT32_MAX

typedef struct erx_fiasco_contig {
	uint32_t	pages;					/* the pool's pages, at most ERX_FIASCO_CONTIG_PAGES */
	uint64_t	used[ERX_FIASCO_CONTIG_PAGES / 64];	/* bit n: page n is held */
} erx_fiasco_contig_t;

/*
 * The order of the flexpage a pool for this many declared bytes takes: the smallest
 * power of two at least bytes, and at least ERX_FIASCO_CONTIG_ORDER_MIN; 0 when that
 * is past ERX_FIASCO_CONTIG_ORDER_MAX.
 */
unsigned	erx_fiasco_contig_order(uint64_t bytes);

/*
 * How many of a pool's first pages, the pool starting at physical address physical and
 * holding pages pages, lie wholly inside CPU addresses first through last: the limit
 * erx_fiasco_contig_take takes for a device that reaches only those. 0 when the window starts above the pool's first
 * page, so such a device gets nothing rather than a run the take cannot place; the pool
 * is the lowest RAM sigma0 has free, and no supported board's window starts above it.
 */
uint32_t	erx_fiasco_contig_reach(uint64_t physical, uint32_t pages, uint64_t first, uint64_t last);

/* The first page of a run of this length wholly below page limit, or ERX_FIASCO_CONTIG_NONE. */
uint32_t	erx_fiasco_contig_take(erx_fiasco_contig_t *, uint32_t pages, uint32_t limit);

/*
 * The device window (docs/design-fiasco.md, "The pool"): the root's addresses where each
 * physical object's registers are mapped, a fresh range for each object. A take places a
 * range first fit, in the lowest gap between the taken ranges that holds it; a give takes
 * it back once its object has ended and the root has unmapped its pages from every space,
 * so a range taken again holds nothing of the object before. The taken ranges are records
 * sorted by address and disjoint, one for each live range: a take adds one, so it alone
 * needs room, and a give removes one, so it cannot fail.
 */
typedef struct erx_fiasco_device_window {
	erx_backend_grow_table_t taken;		/* erx_backend_vm_range_t, sorted and disjoint */
	uint32_t		 ntaken;	/* records in use, from the first */
	uint64_t		 start;		/* the window's addresses, page-aligned; end is exclusive */
	uint64_t		 end;
} erx_fiasco_device_window_t;

/* An empty window over [start, end), whose records come from records, which outlives it. */
void	erx_fiasco_device_window_init(erx_fiasco_device_window_t *, uint64_t start, uint64_t end,
	    const erx_backend_grow_pages_t *records);

/*
 * Takes a range of size bytes, a nonzero multiple of a page, and gives its start.
 * ERX_ENOMEM when no gap holds it or the records have no room for one more.
 */
int	erx_fiasco_device_window_take(erx_fiasco_device_window_t *, uint64_t size, uint64_t *start) ERX_WARN_UNUSED_RESULT;

/* Gives back the range a take placed at start and nothing has given back since. */
void	erx_fiasco_device_window_give(erx_fiasco_device_window_t *, uint64_t start);

#endif /* ERX_FIASCO_PAGE_POOL_H */
