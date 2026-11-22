/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The cache maintenance the root runs in user mode, which Fiasco lets it run
 * (docs/design-arch-aarch64.md, "Cache maintenance"). For code written by this CPU, the
 * sequence asmjit and ERTS use: clean the data side to the point of unification,
 * invalidate the instruction side on every CPU, and synchronize this one. For memory the
 * firmware reads and writes, the firmware request's buffer (docs/design-fiasco.md, "The
 * firmware request"): clean to the point of coherence before the firmware reads it, and
 * clean and invalidate after it wrote, the sequences the device NIF runs for a device that
 * is not coherent (otp/erts/emulator/nifs/erxos/arch/aarch64/erx_dma_arch.c).
 */

#include <stddef.h>
#include <stdint.h>

#include "liberx/backend/fiasco/cache.h"

#define CACHE_CTR_DMINLINE_SHIFT	16u
#define CACHE_CTR_LINE_MASK		UINT64_C(0xf)
/* Each field holds the log2 of the line in words. */
#define CACHE_WORD_BYTES		UINT64_C(4)

static uint64_t
cache_type(void)
{
	uint64_t type;

	__asm__ volatile("mrs %0, ctr_el0" : "=r"(type));
	return (type);
}

/* The smallest data cache line of any cache this CPU's maintenance reaches, from CTR_EL0's type. */
static uint64_t
cache_data_line(uint64_t type)
{
	return (CACHE_WORD_BYTES << ((type >> CACHE_CTR_DMINLINE_SHIFT) & CACHE_CTR_LINE_MASK));
}

void
erx_fiasco_cache_make_coherent(uintptr_t start, size_t size)
{
	const uintptr_t end = start + size;
	const uint64_t type = cache_type();
	const uint64_t data_line = cache_data_line(type);
	const uint64_t instruction_line = CACHE_WORD_BYTES << (type & CACHE_CTR_LINE_MASK);

	for (uintptr_t line = start & ~(data_line - 1); line < end; line += data_line)
		__asm__ volatile("dc cvau, %0" :: "r"(line));
	__asm__ volatile("dsb ish");
	for (uintptr_t line = start & ~(instruction_line - 1); line < end; line += instruction_line)
		__asm__ volatile("ic ivau, %0" :: "r"(line));
	__asm__ volatile("dsb ish\n\tisb");
}

/*
 * The stores to the range come before the clean of each of their lines in program order,
 * which orders them; the memory clobber keeps the compiler from moving them past it.
 */
void
erx_fiasco_cache_clean(uintptr_t start, size_t size)
{
	const uintptr_t end = start + size;
	const uint64_t data_line = cache_data_line(cache_type());

	for (uintptr_t line = start & ~(data_line - 1); line < end; line += data_line)
		__asm__ volatile("dc cvac, %0" :: "r"(line) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

/*
 * The first barrier finishes the read that found the firmware done (a device register's,
 * no access to the range) before any line is invalidated, so no line fetched before the
 * firmware's writes survives the invalidate.
 */
void
erx_fiasco_cache_clean_invalidate(uintptr_t start, size_t size)
{
	const uintptr_t end = start + size;
	const uint64_t data_line = cache_data_line(cache_type());

	__asm__ volatile("dsb sy" ::: "memory");
	for (uintptr_t line = start & ~(data_line - 1); line < end; line += data_line)
		__asm__ volatile("dc civac, %0" :: "r"(line) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}
