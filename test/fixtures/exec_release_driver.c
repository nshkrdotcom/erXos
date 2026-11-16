/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver of erx_exec_release (liberx/exec/release.c) and of the
 * program layer's erx_prog_enter (liberx/program/program.c), which calls
 * it, for test/host/exec_release_test.rb.
 *
 *   check RECORD BASE SIZE OWN_BASE OWN_SIZE LOADER_BASE LOADER_SIZE
 *	prints the check's verdict for the record at RECORD whose loader span
 *	is BASE and SIZE, in a program whose image is OWN_BASE and OWN_SIZE
 *	and whose linked loader is LOADER_BASE and LOADER_SIZE.
 *   enter RECORD BASE SIZE OWN_BASE OWN_SIZE LOADER_BASE LOADER_SIZE REFUSE
 *	runs erx_prog_enter over a stand-in space, one arena of pages,
 *	every address an offset into it: register 7 is the arena's RECORD,
 *	or 0 for "-", and the record there gives the span BASE and SIZE, or
 *	holds 0 in both for BASE "-", as the record of a load that failed
 *	does. The program's own image is OWN_BASE and OWN_SIZE and its
 *	linked loader LOADER_BASE and LOADER_SIZE, or size 0 for "-", as a
 *	fixed-link task's. A release
 *	fills its range with 0xdd and prints "release OFFSET SIZE STATUS";
 *	REFUSE, when not 0, makes the REFUSE-th release fail with ERX_EINVAL.
 *	A stop prints "stop STATUS" and exits. When erx_prog_enter returns,
 *	the driver prints "entered" and then, as a constructor that musl's
 *	start would run next, "constructor WORD", the record's first word.
 *
 * Bad arguments exit 3.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/exec/release.h"
#include "liberx/program/program.h"

#define	ARENA_PAGES	64

static uint8_t *arena;
static uint32_t releases, refuse_release;
static erx_exec_range_t own, loader;

static const char *const verdicts[] = {
	[ERX_EXEC_RELEASE_GO] = "go",
	[ERX_EXEC_RELEASE_RECORD] = "record",
	[ERX_EXEC_RELEASE_LOADER] = "loader",
	[ERX_EXEC_RELEASE_LOADER_IMAGE] = "loader-image",
	[ERX_EXEC_RELEASE_RECORD_IMAGE] = "record-image",
	[ERX_EXEC_RELEASE_RECORD_LOADER] = "record-loader",
};

static uint64_t
address(uint64_t offset)
{
	return ((uint64_t)(uintptr_t)arena + offset);
}

static uint64_t
number(const char *text)
{
	char *end;
	unsigned long long value = strtoull(text, &end, 0);

	if (*text == '\0' || *end != '\0')
		exit(3);
	return ((uint64_t)value);
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	const uint64_t start = (uint64_t)(uintptr_t)arena;
	int status = ERX_OK;

	if (space != ERX_CAP_SELF || ++releases == refuse_release || addr < start ||
	    addr - start > ARENA_PAGES * ERX_PAGE_SIZE || size > ARENA_PAGES * ERX_PAGE_SIZE - (addr - start))
		status = ERX_EINVAL;
	else
		memset((void *)(uintptr_t)addr, 0xdd, (size_t)size);
	printf("release %" PRIu64 " %" PRIu64 " %d\n", addr - start, size, status);
	return (status);
}

int
erx_space_stop(uint64_t space, int64_t status)
{
	if (space != ERX_CAP_SELF)
		exit(3);
	printf("stop %" PRId64 "\n", status);
	exit(0);
}

erx_exec_range_t
erx_prog_image(void)
{
	return (own);
}

erx_exec_range_t
erx_exec_loader(void)
{
	return (loader);
}

static int
check(char **argv)
{
	const erx_exec_range_t recorded = { .address = number(argv[1]), .size = number(argv[2]) };
	const erx_exec_range_t image = { .address = number(argv[3]), .size = number(argv[4]) };
	const erx_exec_range_t linked = { .address = number(argv[5]), .size = number(argv[6]) };

	printf("%s\n", verdicts[erx_exec_release_check(number(argv[0]), recorded, image, linked)]);
	return (0);
}

static int
enter(char **argv)
{
	uint64_t regs[ERX_ARCH_START_ARGS] = { 0 };
	erx_exec_record_t record = { .object = { .raw = 0x5a5a }, .file_bytes = 12345 };
	uint64_t at, word;

	if ((arena = aligned_alloc(ERX_PAGE_SIZE, ARENA_PAGES * ERX_PAGE_SIZE)) == NULL)
		return (3);
	memset(arena, 0, ARENA_PAGES * ERX_PAGE_SIZE);
	own = (erx_exec_range_t){ .address = address(number(argv[3])), .size = number(argv[4]) };
	if (strcmp(argv[5], "-") != 0)
		loader = (erx_exec_range_t){ .address = address(number(argv[5])), .size = number(argv[6]) };
	refuse_release = (uint32_t)number(argv[7]);
	if (strcmp(argv[1], "-") != 0) {
		record.loader_base = address(number(argv[1]));
		record.loader_size = number(argv[2]);
	}
	if (strcmp(argv[0], "-") != 0) {
		at = number(argv[0]);
		if (at > (ARENA_PAGES - 1) * ERX_PAGE_SIZE)
			return (3);
		memcpy(arena + at, &record, sizeof(record));
		regs[ERX_PROGRAM_ARG_EXEC] = address(at);
	}
	erx_prog_enter(regs);
	printf("entered\n");
	if (regs[ERX_PROGRAM_ARG_EXEC] != 0) {
		memcpy(&word, (const void *)(uintptr_t)regs[ERX_PROGRAM_ARG_EXEC], sizeof(word));
		printf("constructor %016" PRIx64 "\n", word);
	}
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc == 9 && strcmp(argv[1], "check") == 0)
		return (check(argv + 2));
	if (argc == 10 && strcmp(argv[1], "enter") == 0)
		return (enter(argv + 2));
	return (3);
}
