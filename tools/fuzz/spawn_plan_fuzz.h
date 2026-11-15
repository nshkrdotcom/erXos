/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The spawn planner's fuzz harness (tools/fuzz/spawn_plan_fuzz.c), as
 * test/fixtures/spawn_plan_driver.c links it to run the same checks over
 * seeded inputs.
 */

#ifndef TOOLS_FUZZ_SPAWN_PLAN_FUZZ_H
#define TOOLS_FUZZ_SPAWN_PLAN_FUZZ_H

#include <stddef.h>
#include <stdint.h>

#include <erx/abi.h>

/* The length of a string two of which, with their NULs, are ERX_PROG_ARGS_MAX bytes. */
#define SPAWN_PLAN_FUZZ_BIG	(ERX_PROG_ARGS_MAX / 2 - 1)

/*
 * Decodes one input into a spawn, plans it and replays it on the model,
 * aborting on a broken case; returns the verdict, 0 or the error both
 * refused with.
 */
int	spawn_plan_fuzz_case(const uint8_t *data, size_t size);

#endif /* TOOLS_FUZZ_SPAWN_PLAN_FUZZ_H */
