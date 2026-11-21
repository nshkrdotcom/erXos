/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DMA_ARCH_COUNTING_H
#define ERX_DMA_ARCH_COUNTING_H

#include <stdbool.h>
#include <stdint.h>

/* The cleans and clean-and-invalidates test/fixtures/erx_dma_arch_counting.c has been asked for. */
extern uint64_t erx_dma_maintenance_count;

/* Forgets the kept ranges, so erx_dma_maintained answers for what follows. */
void	erx_dma_forget_ranges(void);

/*
 * Whether one range kept since the last erx_dma_forget_ranges covers the `length` bytes at
 * `start`, cleaned or, if `invalidated`, cleaned and invalidated; false once more were kept
 * than the layer remembers.
 */
bool	erx_dma_maintained(const volatile void *start, uint64_t length, bool invalidated);

#endif /* ERX_DMA_ARCH_COUNTING_H */
