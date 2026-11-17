/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver of erx_exec's pure core (liberx/exec/load_plan.h), for
 * test/host/exec_load_test.rb: exec-load FILE RESERVED SIZE OUT plans FILE,
 * a code object's bytes, with erx_elf_plan, lays it out in the reservation
 * [RESERVED, RESERVED + SIZE) (SIZE 0: erx_exec_reservation's), prints the
 * base, the entry, the span and each step, then applies the steps to a
 * buffer standing for the span, its unmapped bytes 0xee, relocates it and
 * writes it to OUT. A refusal prints "error REASON OFFSET" and exits 1; a
 * step outside the span exits 2.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/elf_plan.h"
#include "liberx/exec/load_plan.h"

static const char *const kinds[] = { "map", "child", "zero", "commit" };

static uint8_t *
read_file(const char *path, size_t *length)
{
	FILE *file = fopen(path, "rb");
	uint8_t *bytes;
	long size;

	if (file == NULL || fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) <= 0 ||
	    fseek(file, 0, SEEK_SET) != 0 || (bytes = malloc((size_t)size)) == NULL ||
	    fread(bytes, 1, (size_t)size, file) != (size_t)size) {
		fprintf(stderr, "cannot read %s\n", path);
		exit(3);
	}
	fclose(file);
	*length = (size_t)size;
	return (bytes);
}

static void
refuse(const erx_elf_error_t *error)
{
	printf("error %s %" PRIu64 "\n", error->reason, error->offset);
	exit(1);
}

int
main(int argc, char **argv)
{
	erx_exec_layout_t layout;
	erx_elf_error_t error;
	erx_elf_plan_t plan;
	const erx_exec_step_t *step;
	uint64_t reserved, size, at;
	uint8_t *bytes, *image;
	size_t length;
	FILE *out;

	if (argc != 5)
		return (3);
	bytes = read_file(argv[1], &length);
	reserved = strtoull(argv[2], NULL, 0);
	size = strtoull(argv[3], NULL, 0);
	if (!erx_elf_plan(bytes, length, UINT64_MAX, &plan, &error))
		refuse(&error);
	if (size == 0 && !erx_exec_reservation(&plan, &size, &error))
		refuse(&error);
	if (!erx_exec_layout(&plan, reserved, size, &layout, &error))
		refuse(&error);
	printf("base %" PRIu64 " entry %" PRIu64 " span %" PRIu64 " reserve %" PRIu64 "\n",
	    layout.base, layout.entry, plan.span, size);
	if ((image = malloc((size_t)plan.span)) == NULL)
		return (3);
	memset(image, 0xee, (size_t)plan.span);
	for (uint32_t index = 0; index < layout.nsteps; index++) {
		step = &layout.steps[index];
		printf("step %s %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu32 "\n", kinds[step->kind],
		    step->address, step->size, step->offset, step->prot);
		at = step->address - layout.base;
		if (step->address < layout.base || at > plan.span || step->size > plan.span - at)
			return (2);
		if (step->kind == ERX_EXEC_MAP || step->kind == ERX_EXEC_CHILD) {
			if (step->offset > length || step->size > length - step->offset)
				return (2);
			memcpy(image + at, bytes + step->offset, (size_t)step->size);
		} else
			memset(image + at, 0, (size_t)step->size);
	}
	erx_exec_relocate(bytes, &plan, layout.base, image);
	if ((out = fopen(argv[4], "wb")) == NULL || fwrite(image, 1, (size_t)plan.span, out) != plan.span ||
	    fclose(out) != 0)
		return (3);
	return (0);
}
