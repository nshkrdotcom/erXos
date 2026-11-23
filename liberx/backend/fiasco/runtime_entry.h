/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H
#define ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H

#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "erx/core/dt.h"
#include "liberx/backend/fiasco/bcm2711_pins.h"
#include "liberx/backend/fiasco/entropy.h"
#include "liberx/backend/fiasco/boot_args.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/pm_wdt.h"

/* include/erx/pack.h's; that header's erx_boot_inputs_t is the first stage's, not the boot page's. */
typedef struct erx_pack_view erx_pack_view_t;

/*
 * Accepts the firmware's device tree into *tree, once, before the root's service and
 * generator are up (docs/design-device-tree.md, "Facts into records"), and fills *seeds
 * from it: its /chosen seeds (erx_dt_seeds) and, when /chosen carries neither, the read
 * of the board's random generator that manifest gives the system domain
 * (erx_fiasco_rng200_read). The caller erases *seeds. Returns NULL, or why the root cannot
 * boot: the handoff carries no tree, the reader refused it, or the generator's row names
 * no node path. A root built without a program reads no tree: root_no_program.c leaves
 * *tree alone and gives no seeds.
 */
const char	*erx_fiasco_program_tree(erx_dt_t *tree, const erx_manifest_view_t *manifest, erx_fiasco_seeds_t *seeds);

/*
 * The board's hardware watchdog (docs/design-platforms.md, "The watchdog"): the unit of
 * ERX_PM_WDT_COMPATIBLE that manifest gives the system domain (erx_boot_held_row), mapped
 * into *wdt when tree, the one erx_fiasco_program_tree accepted, confirms its row
 * (erx_fiasco_pm_wdt_open); *wdt has no device otherwise, and nothing is written. *found
 * says which. Returns NULL,
 * or why the root cannot boot: the row's path is not a node path. A root built without a
 * program has no board watchdog.
 */
const char	*erx_fiasco_program_watchdog(const erx_dt_t *tree, const erx_manifest_view_t *manifest,
		    erx_fiasco_pm_wdt_t *wdt, erx_fiasco_board_wdt_t *found);

/* What the root found of the firmware's mailbox (erx_fiasco_program_mailbox). */
typedef enum erx_fiasco_board_mbox {
	/* The manifest gives the system domain none, as on QEMU virt. */
	ERX_FIASCO_BOARD_MBOX_ABSENT = 1,
	/* Its row is confirmed by the tree and its registers are mapped. */
	ERX_FIASCO_BOARD_MBOX_READY,
	/* The tree does not confirm its row, or its page cannot be mapped: the board has none. */
	ERX_FIASCO_BOARD_MBOX_UNCONFIRMED
} erx_fiasco_board_mbox_t;

/*
 * The firmware's mailbox (docs/design-fiasco.md, "The call table", erx_firmware_request):
 * the unit of ERX_VC_MAILBOX_COMPATIBLE that manifest gives the system domain
 * (erx_boot_held_row), mapped by its shim (erx_fiasco_vc_mbox_open) when tree, the one
 * erx_fiasco_program_tree accepted, confirms its row; nothing is written. *found says
 * which. Returns NULL, or why the root cannot boot: the row's path is not a node path. A
 * root built without a program has no mailbox.
 */
const char	*erx_fiasco_program_mailbox(const erx_dt_t *tree, const erx_manifest_view_t *manifest,
		    erx_fiasco_board_mbox_t *found);

/*
 * The on-board pins (docs/design-header-io.md, "On-board pins"): the manifest's
 * onboard_pins rows, set through the unit of ERX_BCM2711_PINS_COMPATIBLE that manifest
 * gives the system domain (erx_boot_held_row) when tree, the one erx_fiasco_program_tree
 * accepted, confirms its row (erx_fiasco_bcm2711_pins_set). *found says what was done.
 * Returns NULL, or why the root cannot boot: the row's path is not a node path. A root
 * built without a program sets no pin.
 */
const char	*erx_fiasco_program_pins(const erx_dt_t *tree, const erx_manifest_view_t *manifest,
		    erx_fiasco_board_pins_t *found);

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
 * on a stack of its own with a guard below it (docs/design-fiasco.md, "musl over the
 * backend"). Needs the root service running. A start that comes back ends the machine.
 */
_Noreturn void	 erx_fiasco_libc_root_start(int (*program)(int, char **, char **), erx_fiasco_cpu_features_t features);

#endif /* ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H */
