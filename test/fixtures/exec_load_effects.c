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
 * It prints each reservation and release, their addresses relative to the
 * arena, then the outcome: "loaded BASE ENTRY", "failed CALL STATUS",
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

#define	ARENA_SIZE	(UINT64_C(4) << 20)
#define	OBJECT		UINT64_C(0x100)
#define	BUDGET		UINT64_C(0x300)
#define	CHILD_FIRST	UINT64_C(0x200)
#define	CHILDREN_MAX	16

static uint8_t *arena;
static uint64_t arena_used;
static uint8_t *object;
static uint64_t object_size;
static uint64_t child_offsets[CHILDREN_MAX];
static uint32_t nchildren;
static uint32_t releases, refuse_release;
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

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	(void)space;
	if (failing("reserve"))
		return (ERX_ENOMEM);
	if (addr != 0 || flags != 0 || size == 0 || size % ERX_PAGE_SIZE != 0 ||
	    size > ARENA_SIZE - arena_used)
		return (ERX_EINVAL);
	*reserved = (uint64_t)(uintptr_t)arena + arena_used;
	arena_used += size;
	printf("reserve %" PRIu64 " %" PRIu64 "\n", relative(*reserved), size);
	return (ERX_OK);
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
	refuse_release = (uint32_t)strtoul(argv[2], NULL, 0);
	if (strcmp(argv[3], "-") != 0) {
		if ((colon = strchr(argv[3], ':')) == NULL)
			return (3);
		*colon = '\0';
		fail_call = argv[3];
		fail_index = (uint32_t)strtoul(colon + 1, &end, 10);
		if (fail_index == 0 || *end != '\0' || (strcmp(fail_call, "reserve") != 0 &&
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
