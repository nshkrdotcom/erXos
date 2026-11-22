/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A root built with nothing to run, as the boot suite's is: it has checked the handoff and
 * the archive, says so, and ends the machine. It links no device-tree reader, so its
 * generator starts from the counter alone.
 */

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/runtime_entry.h"
#include "liberx/backend/fiasco/service.h"

static const char line[] = "erx: root task: this image holds no program\n";

const char *
erx_fiasco_program_tree(erx_dt_t *tree, const erx_manifest_view_t *manifest, erx_fiasco_seeds_t *seeds)
{
	(void)tree;
	(void)manifest;
	*seeds = (erx_fiasco_seeds_t){ .board = ERX_BOARD_NONE };
	return (NULL);
}

const char *
erx_fiasco_program_watchdog(const erx_dt_t *tree, const erx_manifest_view_t *manifest, erx_fiasco_pm_wdt_t *wdt,
    erx_fiasco_board_wdt_t *found)
{
	(void)tree;
	(void)manifest;
	*wdt = (erx_fiasco_pm_wdt_t){ .armed = false };
	*found = ERX_FIASCO_BOARD_WDT_ABSENT;
	return (NULL);
}

const char *
erx_fiasco_program_mailbox(const erx_dt_t *tree, const erx_manifest_view_t *manifest, erx_fiasco_board_mbox_t *found)
{
	(void)tree;
	(void)manifest;
	*found = ERX_FIASCO_BOARD_MBOX_ABSENT;
	return (NULL);
}

const char *
erx_fiasco_program_start(const erx_boot_handoff_view_t *handoff, const erx_manifest_view_t *manifest,
    const erx_pack_view_t *pack, const erx_dt_t *tree, const erx_boot_args_t *boot_args)
{
	(void)handoff;
	(void)manifest;
	(void)pack;
	(void)tree;
	(void)boot_args;
	erx_fiasco_console_write(line, sizeof(line) - 1);
	(void)erx_machine_end(0, ERX_END_OFF);
	return ("the service refused the machine's end");
}
