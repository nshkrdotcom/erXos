/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host DMA architecture layer of arch/host/erx_dma_arch.c with its maintenance counted,
 * for test/fixtures/erx_device_dma_harness.c: the harness's device shares the CPU's caches,
 * so cleaning still does nothing, but each clean and each clean-and-invalidate adds one to
 * erx_dma_maintenance_count, so the harness can tell a queue whose plans run as for a
 * coherent device from one whose plans run as for a device that is not. The last
 * ERX_DMA_RANGES_KEPT ranges are kept as well, so the harness can ask whether the bytes a
 * device reads were cleaned and the bytes it wrote invalidated.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx_dma_arch.h"
#include "erx_dma_arch_counting.h"

#define HOST_GRANULE	64u
#define HOST_LINE	64u

uint64_t erx_dma_maintenance_count;

#define ERX_DMA_RANGES_KEPT	64u

/* One maintained range: its first byte, its length and whether it was invalidated. */
typedef struct {
	uintptr_t	start;
	uint64_t	length;
	bool		invalidated;
} kept_range_t;

static kept_range_t kept[ERX_DMA_RANGES_KEPT];
static uint32_t kept_count;

static void
keep(volatile uint8_t *start, uint64_t length, bool invalidated)
{
	erx_dma_maintenance_count++;
	kept[kept_count % ERX_DMA_RANGES_KEPT] = (kept_range_t){ (uintptr_t)start, length, invalidated };
	kept_count++;
}

void
erx_dma_forget_ranges(void)
{
	kept_count = 0;
}

bool
erx_dma_maintained(const volatile void *start, uint64_t length, bool invalidated)
{
	const uintptr_t first = (uintptr_t)start;

	if (kept_count > ERX_DMA_RANGES_KEPT)
		return (false);
	for (uint32_t at = 0; at < kept_count; at++) {
		if (kept[at].invalidated == invalidated && kept[at].start <= first &&
		    first - kept[at].start <= kept[at].length && length <= kept[at].length - (first - kept[at].start))
			return (true);
	}
	return (false);
}

uint32_t
erx_dma_granule(void)
{
	return (HOST_GRANULE);
}

uint32_t
erx_dma_line(void)
{
	return (HOST_LINE);
}

void
erx_dma_clean(volatile uint8_t *start, uint64_t length, uint32_t step)
{
	(void)step;
	keep(start, length, false);
}

void
erx_dma_clean_inval(volatile uint8_t *start, uint64_t length, uint32_t step)
{
	(void)step;
	keep(start, length, true);
}

void
erx_dma_publish_barrier(bool completes)
{
	(void)completes;
	atomic_thread_fence(memory_order_seq_cst);
}

void
erx_dma_report_barrier(void)
{
	atomic_thread_fence(memory_order_seq_cst);
}

void
erx_dma_completion_barrier(void)
{
	atomic_thread_fence(memory_order_seq_cst);
}

void
erx_dma_store_wait(void)
{
	atomic_thread_fence(memory_order_seq_cst);
}
