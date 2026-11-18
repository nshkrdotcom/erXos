/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver of erx_exec_load (liberx/exec/load.c), for
 * test/host/exec_load_test.rb, over memory calls of its own that stand for
 * the program's space: exec-load-effects FILE REFUSE FAIL loads FILE's exact
 * bytes from a code object holding them and then zeros to its last page, as
 * a sealed object of the file does.
 *
 * The space is one arena: erx_vm_reserve hands out its pages in order, a
 * map copies the object's or a child's bytes in, a commit zeroes, and a
 * release fills with 0xdd. A map past the object's end fails with
 * ERX_EINVAL, as the space refuses it. REFUSE, when not 0, makes the
 * REFUSE-th release fail with ERX_EINVAL; FAIL, CALL:N or "-", makes the
 * N-th call named CALL ("reserve", "map", "child" or "commit") fail with
 * ERX_ENOMEM.
 *
 * Beside the arena, the stand-in keeps the Fiasco backend's placement: the
 * program's own image, the loader's, is LOADER_BYTES from exec_window_base
 * (abi/protocols/prog.txt) and the session mapped the record's page, and a
 * reservation without an address takes the lowest place from ROOM below
 * the window that meets nothing taken, as the space's first fit does,
 * while its bytes live in the arena. A fixed reservation, which must not
 * replace (ERX_VM_NOREPLACE), takes its place and no bytes; one that meets
 * a place taken fails with ERX_EEXIST. FAIL's CALL may also be "window",
 * the fixed one.
 *
 * It prints each fixed reservation as "window ADDRESS SIZE", each other
 * as "reserve OFFSET SIZE", relative to the arena, then "place ADDRESS",
 * and each release, relative to the arena, then the outcome: "loaded BASE ENTRY", "failed CALL STATUS",
 * "refused REASON OFFSET" or "cleanup_refused". Bad arguments exit 3.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/exec/load.h"
#include "liberx/program/program.h"

#define	ARENA_SIZE	(UINT64_C(4) << 20)
#define	OBJECT		UINT64_C(0x100)
#define	BUDGET		UINT64_C(0x300)
#define	CHILD_FIRST	UINT64_C(0x200)
#define	CHILDREN_MAX	16
/* The loader's image, and the backend's room below the window: from the end of its task area (time.h). */
#define	LOADER_BYTES	(UINT64_C(64) << 10)
#define	ROOM		(UINT64_C(760) << 10)
#define	TAKEN_MAX	8

static uint8_t *arena;
static uint64_t arena_used;
static uint8_t *object;
static uint64_t object_size;
static uint64_t child_offsets[CHILDREN_MAX];
static uint32_t nchildren;
static uint32_t releases, refuse_release;
static erx_exec_range_t taken[TAKEN_MAX];
static uint32_t ntaken;
static const char *fail_call;
static uint32_t fail_index;

static uint64_t
relative(uint64_t address)
{
	return (address - (uint64_t)(uintptr_t)arena);
}

/* Whether this call, the next of its name, is the one FAIL names. */
static bool
failing(const char *call)
{
	if (fail_call == NULL || strcmp(call, fail_call) != 0)
		return (false);
	return (--fail_index == 0);
}

/* Whether [address, address + size) lies in the arena. */
static bool
in_arena(uint64_t address, uint64_t size)
{
	uint64_t start = (uint64_t)(uintptr_t)arena;

	return (address >= start && address - start <= ARENA_SIZE &&
	    size <= ARENA_SIZE - (address - start));
}

/* Whether [address, address + size) meets a place taken. */
static bool
meets_taken(uint64_t address, uint64_t size)
{
	for (uint32_t index = 0; index < ntaken; index++) {
		if (address < taken[index].address + taken[index].size &&
		    taken[index].address < address + size)
			return (true);
	}
	return (false);
}

/* Takes [address, address + size); false when the table is full. */
static bool
take(uint64_t address, uint64_t size)
{
	if (ntaken == TAKEN_MAX)
		return (false);
	taken[ntaken++] = (erx_exec_range_t){ .address = address, .size = size };
	return (true);
}

/* The lowest place from ROOM below the window that meets nothing taken, page by page. */
static uint64_t
first_fit(uint64_t size)
{
	uint64_t address = ERX_EXEC_WINDOW_BASE - ROOM;

	while (meets_taken(address, size))
		address += ERX_PAGE_SIZE;
	return (address);
}

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	uint64_t place;

	(void)space;
	if (failing(addr != 0 ? "window" : "reserve"))
		return (ERX_ENOMEM);
	if (size == 0 || size % ERX_PAGE_SIZE != 0 || addr % ERX_PAGE_SIZE != 0)
		return (ERX_EINVAL);
	if (addr != 0) {
		if (flags != (ERX_VM_FIXED | ERX_VM_NOREPLACE))
			return (ERX_EINVAL);
		if (meets_taken(addr, size))
			return (ERX_EEXIST);
		if (!take(addr, size))
			return (ERX_ENOMEM);
		*reserved = addr;
		printf("window %" PRIu64 " %" PRIu64 "\n", addr, size);
		return (ERX_OK);
	}
	if (flags != 0 || size > ARENA_SIZE - arena_used)
		return (ERX_EINVAL);
	place = first_fit(size);
	if (!take(place, size))
		return (ERX_ENOMEM);
	*reserved = (uint64_t)(uintptr_t)arena + arena_used;
	arena_used += size;
	printf("reserve %" PRIu64 " %" PRIu64 "\n", relative(*reserved), size);
	printf("place %" PRIu64 "\n", place);
	return (ERX_OK);
}

erx_exec_range_t
erx_prog_image(void)
{
	return ((erx_exec_range_t){ .address = ERX_EXEC_WINDOW_BASE, .size = LOADER_BYTES });
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	(void)space;
	(void)prot;
	if (failing("map"))
		return (ERX_ENOMEM);
	if (mem >= CHILD_FIRST && mem - CHILD_FIRST < nchildren) {
		offset += child_offsets[mem - CHILD_FIRST];
		mem = OBJECT;
	}
	if (mem != OBJECT || !in_arena(addr, size) || offset > object_size ||
	    size > object_size - offset)
		return (ERX_EINVAL);
	memcpy((void *)(uintptr_t)addr, object + offset, (size_t)size);
	return (ERX_OK);
}

int
erx_mem_child(uint64_t parent, uint64_t budget, uint64_t offset, uint64_t size, uint64_t *child)
{
	if (failing("child"))
		return (ERX_ENOMEM);
	if (parent != OBJECT || budget != BUDGET || nchildren == CHILDREN_MAX ||
	    offset > object_size || size > object_size - offset)
		return (ERX_EINVAL);
	child_offsets[nchildren] = offset;
	*child = CHILD_FIRST + nchildren++;
	return (ERX_OK);
}

int
erx_vm_commit(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	if (failing("commit"))
		return (ERX_ENOMEM);
	if (!in_arena(addr, size))
		return (ERX_EINVAL);
	memset((void *)(uintptr_t)addr, 0, (size_t)size);
	return (ERX_OK);
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	int status = ERX_OK;

	(void)space;
	if (++releases == refuse_release || !in_arena(addr, size))
		status = ERX_EINVAL;
	else
		memset((void *)(uintptr_t)addr, 0xdd, (size_t)size);
	printf("release %" PRIu64 " %" PRIu64 " %d\n", relative(addr), size, status);
	return (status);
}

int
erx_cap_close(erx_cap_t cap)
{
	(void)cap;
	return (ERX_OK);
}

static uint64_t
read_object(const char *path)
{
	FILE *file = fopen(path, "rb");
	long size;

	if (file == NULL || fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) <= 0 ||
	    fseek(file, 0, SEEK_SET) != 0)
		exit(3);
	object_size = ((uint64_t)size + ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE;
	if ((object = calloc(1, (size_t)object_size)) == NULL ||
	    fread(object, 1, (size_t)size, file) != (size_t)size)
		exit(3);
	fclose(file);
	return ((uint64_t)size);
}

int
main(int argc, char **argv)
{
	erx_exec_failure_t failure;
	erx_exec_image_t image;
	uint64_t file_bytes;
	char *colon, *end;

	if (argc != 4 || (arena = aligned_alloc(UINT64_C(1) << 16, ARENA_SIZE)) == NULL)
		return (3);
	file_bytes = read_object(argv[1]);
	if (!take(ERX_EXEC_WINDOW_BASE, LOADER_BYTES) || !take(ERX_EXEC_RECORD_PAGE, ERX_PAGE_SIZE))
		return (3);
	refuse_release = (uint32_t)strtoul(argv[2], NULL, 0);
	if (strcmp(argv[3], "-") != 0) {
		if ((colon = strchr(argv[3], ':')) == NULL)
			return (3);
		*colon = '\0';
		fail_call = argv[3];
		fail_index = (uint32_t)strtoul(colon + 1, &end, 10);
		if (fail_index == 0 || *end != '\0' || (strcmp(fail_call, "window") != 0 && strcmp(fail_call, "reserve") != 0 &&
		    strcmp(fail_call, "map") != 0 && strcmp(fail_call, "child") != 0 &&
		    strcmp(fail_call, "commit") != 0))
			return (3);
	}
	switch (erx_exec_load(OBJECT, file_bytes, BUDGET, &image, &failure)) {
	case ERX_EXEC_LOADED:
		printf("loaded %" PRIu64 " %" PRIu64 "\n", relative(image.base), relative(image.entry));
		break;
	case ERX_EXEC_FAILED:
		if (failure.call != NULL)
			printf("failed %s %d\n", failure.call, failure.status);
		else
			printf("refused %s %" PRIu64 "\n", failure.refusal.reason, failure.refusal.offset);
		break;
	case ERX_EXEC_CLEANUP_REFUSED:
		printf("cleanup_refused\n");
		break;
	}
	return (0);
}
