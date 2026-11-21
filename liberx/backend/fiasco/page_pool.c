/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/page_pool.h"
#include "liberx/backend/fiasco/root_mem.h"

void
erx_fiasco_pool_add(erx_fiasco_pool_t *pool, uintptr_t page)
{
	*(uintptr_t *)page = pool->head;
	pool->head = page;
	pool->free_pages++;
	pool->pages++;
}

void
erx_fiasco_pool_put(erx_fiasco_pool_t *pool, uintptr_t page)
{
	/* Back on the free list, but not added: pages counts the pool as it was built. */
	*(uintptr_t *)page = pool->head;
	pool->head = page;
	pool->free_pages++;
	if (pool->held_pages > 0)
		pool->held_pages--;
}

uintptr_t
erx_fiasco_pool_take(erx_fiasco_pool_t *pool)
{
	uintptr_t page;

	page = pool->head;
	if (page == 0)
		return (0);
	pool->head = *(uintptr_t *)page;
	pool->free_pages--;
	pool->held_pages++;
	bzero((void *)page, ERX_PAGE_SIZE);
	return (page);
}

static bool
contig_held(const erx_fiasco_contig_t *pool, uint32_t page)
{
	return ((pool->used[page / 64] >> (page % 64) & 1) != 0);
}

unsigned
erx_fiasco_contig_order(uint64_t bytes)
{
	unsigned order = ERX_FIASCO_CONTIG_ORDER_MIN;

	while (order <= ERX_FIASCO_CONTIG_ORDER_MAX && (UINT64_C(1) << order) < bytes)
		order++;
	return (order <= ERX_FIASCO_CONTIG_ORDER_MAX ? order : 0);
}

uint32_t
erx_fiasco_contig_reach(uint64_t physical, uint32_t pages, uint64_t first, uint64_t last)
{
	uint64_t span, whole;

	if (first > physical || last < physical)
		return (0);
	/* span + 1 bytes of the pool lie at or below last, and only whole pages count. */
	span = last - physical;
	whole = span == UINT64_MAX ? UINT64_MAX / ERX_PAGE_SIZE : (span + 1) / ERX_PAGE_SIZE;
	return (whole < pages ? (uint32_t)whole : pages);
}

/* One pass up the pool, keeping the length of the free run that ends at each page. */
uint32_t
erx_fiasco_contig_take(erx_fiasco_contig_t *pool, uint32_t pages, uint32_t limit)
{
	const uint32_t end = limit < pool->pages ? limit : pool->pages;
	uint32_t free_run = 0;

	if (pages == 0 || pages > pool->pages)
		return (ERX_FIASCO_CONTIG_NONE);
	for (uint32_t last = 0; last < end; last++) {
		free_run = contig_held(pool, last) ? 0 : free_run + 1;
		if (free_run < pages)
			continue;
		for (uint32_t page = last + 1 - pages; page <= last; page++)
			pool->used[page / 64] |= UINT64_C(1) << (page % 64);
		return (last + 1 - pages);
	}
	return (ERX_FIASCO_CONTIG_NONE);
}

void
erx_fiasco_device_window_init(erx_fiasco_device_window_t *window, uint64_t start, uint64_t end,
    const erx_backend_grow_pages_t *records)
{
	*window = (erx_fiasco_device_window_t){ .start = start, .end = end };
	erx_backend_grow_table_init(&window->taken, sizeof(erx_backend_vm_range_t), records);
}

static erx_backend_vm_range_t *
device_taken(const erx_fiasco_device_window_t *window, uint32_t index)
{
	return (erx_backend_grow_table_at(&window->taken, index));
}

/*
 * The gaps, lowest first, are the one below each taken range and the one above the last.
 * Each lies at or above the window's start and below its end, so no subtraction wraps, and
 * a range placed in one ends at or below the gap's end, so its end does not wrap either.
 */
int
erx_fiasco_device_window_take(erx_fiasco_device_window_t *window, uint64_t size, uint64_t *start)
{
	uint64_t gap = window->start;
	uint32_t at;

	for (at = 0; at < window->ntaken; at++) {
		if (device_taken(window, at)->start - gap >= size)
			break;
		gap = device_taken(window, at)->end;
	}
	if (at == window->ntaken && window->end - gap < size)
		return (ERX_ENOMEM);
	if (erx_backend_grow_table_room(&window->taken, window->ntaken + 1) != ERX_OK)
		return (ERX_ENOMEM);
	erx_backend_grow_table_move(&window->taken, at + 1, at, window->ntaken - at);
	*device_taken(window, at) = (erx_backend_vm_range_t){ .start = gap, .end = gap + size };
	window->ntaken++;
	*start = gap;
	return (ERX_OK);
}

void
erx_fiasco_device_window_give(erx_fiasco_device_window_t *window, uint64_t start)
{
	uint32_t at = 0;

	while (device_taken(window, at)->start != start)
		at++;
	erx_backend_grow_table_move(&window->taken, at, at + 1, window->ntaken - at - 1);
	window->ntaken--;
}
