/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H
#define ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H

#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "erx/core/dt.h"
#include "liberx/backend/fiasco/boot_args.h"
#include "liberx/backend/fiasco/libc_start.h"

/* include/erx/pack.h's; that header's erx_boot_inputs_t is the first stage's, not the boot page's. */
typedef struct erx_pack_view erx_pack_view_t;

/*
 * Accepts the firmware's device tree into *tree, once, before the root's service and
 * generator are up (docs/design-device-tree.md, "Facts into records"), and fills *seeds
 * from its /chosen (erx_dt_seeds), whose bytes the caller erases. Returns NULL, or why
 * the root cannot boot: the handoff carries no tree, or the reader refused it. A root
 * built without a program reads no tree: root_no_program.c leaves *tree alone and gives
 * no seeds.
 */
const char	*erx_fiasco_program_tree(erx_dt_t *tree, erx_dt_seeds_t *seeds);

/*
 * What the root task runs once it is up: it joins tree's facts to the manifest's devices,
 * fills the boot information page, builds the domain library from the manifest and the
 * archive, pack, and enters musl's start path. tree is the one erx_fiasco_program_tree
 * accepted. Returns only on a refusal, with the reason. A root built without a program
 * answers this with root_no_program.c.
 */
const char	*erx_fiasco_program_start(const erx_boot_handoff_view_t *handoff, const erx_manifest_view_t *manifest,
	    const erx_pack_view_t *pack, const erx_dt_t *tree, const erx_boot_args_t *boot_args);

/*
 * Enters musl's start path with program as main and features as its AT_HWCAP and AT_HWCAP2,
 * on a stack of its own with a guard below it (docs/design-stopgap.md, "musl over the
 * backend"). Needs the root service running. A start that comes back ends the machine.
 */
_Noreturn void	 erx_fiasco_libc_root_start(int (*program)(int, char **, char **), erx_fiasco_cpu_features_t features);

#endif /* ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H */
