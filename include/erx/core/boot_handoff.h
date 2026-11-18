/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_BOOT_HANDOFF_H
#define ERX_CORE_BOOT_HANDOFF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The record's size, which Fiasco's options block embeds, the bounds of what it
 * carries and its CPU words' count, generated from the ABI for bootstrap's C++,
 * which does not include erx/abi.h.
 */
#include "erx/core/abi_boot.h"
#include "erx/core/boot_pair.h"
#include "erx/core/boot_range.h"

/*
 * What the kernel accepts from bootstrap (docs/design-fiasco.md, "Boot
 * handoff"). The record lives in the kernel's own image, which only bootstrap
 * wrote before the kernel ran; these checks catch a first stage and a kernel
 * built apart, and a boot that skipped bootstrap's validator, whose record is
 * all zeros.
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct erx_boot_handoff_view erx_boot_handoff_view_t;

struct erx_boot_handoff_view {
	uint32_t	 flags;
	bool		 development;
	/* The image carries test code: a test image, always a development build. */
	bool		 test_code;
	uint8_t		 build_id[ERX_BUILD_ID_SIZE];
	uint8_t		 index_hash[ERX_PACK_HASH_SIZE];
	erx_boot_range_t image;
	uint64_t	 pool_usable;
	uint64_t	 pool_heap;
	uint32_t	 pool_regions;
	const char	*bootargs;
	uint32_t	 bootargs_len;
	/*
	 * The full path of the node /chosen/stdout-path names, as bootstrap
	 * resolved it: a '/' and node-name characters, empty when the tree
	 * names no node. Not NUL-terminated.
	 */
	const char	*stdout_path;
	uint32_t	 stdout_path_len;
	/* The boot value and its slot bootstrap derived from /chosen/bootloader. */
	erx_boot_pair_t	 boot;
	/*
	 * The packed read-only copy of the firmware's device tree bootstrap
	 * made: page-aligned, 1 to ERX_BOOT_TREE_MAX bytes, its end inside the
	 * address space. Its bytes are untrusted until erx_dt_accept takes them.
	 */
	erx_boot_range_t tree;
	/*
	 * The boot CPU's identification registers as bootstrap read them, one
	 * word for each member of the architecture's cpu_id_word (abi/arch/<arch>.txt),
	 * at the word it numbers; what they claim is untrusted until the root's
	 * feature core takes them.
	 */
	uint64_t	 cpu_id[ERX_CPU_ID_WORD_COUNT];
};

/*
 * A node path as a device tree spells it: empty, or '/' and names of the
 * characters the specification allows (letters, digits, ",._+-" and '@'),
 * so nothing in it is a control, an escape or a byte outside ASCII. The
 * handoff's writer stores only such a path and its reader accepts only one.
 */
static inline bool
erx_boot_node_path_valid(const uint8_t *path, size_t length)
{
	if (length == 0)
		return (true);
	if (path[0] != '/')
		return (false);
	for (size_t at = 1; at < length; at++) {
		const uint8_t c = path[at];

		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		    (c >= '0' && c <= '9') || c == ',' || c == '.' || c == '_' ||
		    c == '+' || c == '-' || c == '@' || c == '/'))
			return (false);
	}
	return (true);
}

/*
 * The boot image's build identifier as one number, its bytes read big-endian,
 * as the root's identity line prints them in order. The root gives it to the
 * system domain and the domain library to every other domain, as -erx_record build.
 */
static inline uint64_t
erx_boot_handoff_build_id(const erx_boot_handoff_view_t *handoff)
{
	uint64_t id = 0;

	for (size_t at = 0; at < sizeof(handoff->build_id); at++)
		id = id << 8 | handoff->build_id[at];
	return (id);
}

/*
 * Whether a device-tree copy's range is one the handoff carries: start
 * page-aligned, length from 1 to ERX_BOOT_TREE_MAX, end not overflowing.
 * The writer stores only such a range and the reader accepts only one.
 */
static inline bool
erx_boot_tree_range_valid(uint64_t start, uint64_t size)
{
	uint64_t end;

	return ((start % ERX_PAGE_SIZE) == 0 && size != 0 &&
	    size <= ERX_BOOT_TREE_MAX &&
	    !__builtin_add_overflow(start, size, &end));
}

/*
 * Reads the boot CPU's identification registers into id, in kernel mode, each at
 * the word the architecture's cpu_id_word numbers it (abi/arch/<arch>.txt;
 * kernel/arch/<arch>/cpu_id.c). Bootstrap calls it and hands the words to
 * erx_boot_handoff_write.
 */
void erx_boot_cpu_id_read(uint64_t id[ERX_CPU_ID_WORD_COUNT]);

/* Returns NULL when the record is good, else the check that failed. */
const char *erx_boot_handoff_accept(const uint8_t *, size_t,
    erx_boot_handoff_view_t *);

/* Whether one of the ranges covers the archive whole. */
bool erx_boot_handoff_covered(const erx_boot_handoff_view_t *,
    const erx_boot_range_t *, size_t);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_BOOT_HANDOFF_H */
