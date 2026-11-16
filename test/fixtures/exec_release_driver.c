/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver of the program layer's erx_prog_enter (liberx/program/program.c)
 * and the erx_exec_release (liberx/exec/release.c) it calls, for
 * test/host/exec_release_test.rb.
 *
 *   enter EXEC OWN_BASE OWN_SIZE REFUSE
 *	runs erx_prog_enter with register 7, program_arg's exec, EXEC, in a
 *	program whose own image is OWN_BASE and OWN_SIZE, over a stand-in
 *	space: a release prints "release ADDRESS SIZE STATUS" and touches no
 *	memory; REFUSE, when not 0, makes the REFUSE-th release fail with
 *	ERX_EINVAL. A stop prints "stop STATUS" and exits. When erx_prog_enter
 *	returns, the driver prints "entered", where musl's start would run the
 *	constructors next.
 *
 * Bad arguments exit 3.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/program/program.h"

static uint32_t releases, refuse_release;
static erx_exec_range_t own;

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
	const int status = space == ERX_CAP_SELF && ++releases != refuse_release ? ERX_OK : ERX_EINVAL;

	printf("release %" PRIu64 " %" PRIu64 " %d\n", addr, size, status);
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

int
main(int argc, char **argv)
{
	uint64_t regs[ERX_ARCH_START_ARGS] = { 0 };

	if (argc != 6 || strcmp(argv[1], "enter") != 0)
		return (3);
	regs[ERX_PROGRAM_ARG_EXEC] = number(argv[2]);
	own = (erx_exec_range_t){ .address = number(argv[3]), .size = number(argv[4]) };
	refuse_release = (uint32_t)number(argv[5]);
	erx_prog_enter(regs);
	printf("entered\n");
	return (0);
}
