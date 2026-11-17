/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The tiny native program a domain of the native_domain suite runs
 * (test/guest/native_domain/guest.c). Its first thread's argument is its boot
 * page's address; the page's first argument word says what to do: "halt"
 * returns HALT_STATUS once the page reads as a domain's, "fault" stores
 * through a null pointer, "wait" sleeps until its domain is stopped, and
 * CODE_WORD followed by a code object's value in its table checks what the
 * session's copy allows (code_check).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "test/guest/native_domain/modes.h"

/* Whether the release slice, mapped at the boot page's address, begins with RELEASE_TEXT. */
static bool
release_reads(const erx_boot_info_t *info)
{
	const char *text = (const char *)(uintptr_t)info->release_addr;

	if (info->release.raw == ERX_CAP_NULL || text == NULL)
		return (false);
	for (size_t at = 0; RELEASE_TEXT[at] != '\0'; at++)
		if (text[at] != RELEASE_TEXT[at])
			return (false);
	return (true);
}

/*
 * The session's copy of a code object, the value hex names in CODE_DIGITS
 * lower-case digits: it maps neither writable nor, unsealed, to run, and
 * does not destroy its object; it is filled from the release slice, sealed,
 * refuses a supply once sealed, and then maps to run with the bytes it was
 * filled with. HALT_STATUS, or CODE_STATUS plus the first refused step.
 */
static int64_t
code_check(const erx_boot_info_t *info, const char *hex)
{
	const uint64_t text = sizeof(RELEASE_TEXT) - 1;
	uint64_t code = 0, addr;
	const char *mapped;

	for (size_t at = 0; at < CODE_DIGITS; at++) {
		const char digit = hex[at];

		if (!((digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f')))
			return (CODE_STATUS + 1);
		code = code << 4 | (uint64_t)(digit <= '9' ? digit - '0' : digit - 'a' + 10);
	}
	if (erx_vm_reserve(ERX_CAP_SELF, 0, ERX_PAGE_SIZE, 0, &addr) != ERX_OK)
		return (CODE_STATUS + 2);
	if (erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, code, 0, ERX_PROT_RW) != ERX_ERIGHTS)
		return (CODE_STATUS + 3);
	if (erx_object_destroy(code) != ERX_ERIGHTS)
		return (CODE_STATUS + 4);
	if (erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, code, 0, ERX_PROT_RX) != ERX_EBUSY)
		return (CODE_STATUS + 5);
	if (erx_mem_supply(code, 0, info->release.raw, 0, text) != ERX_OK)
		return (CODE_STATUS + 6);
	if (erx_mem_seal(code) != ERX_OK)
		return (CODE_STATUS + 7);
	if (erx_mem_supply(code, 0, info->release.raw, 0, text) != ERX_ERIGHTS)
		return (CODE_STATUS + 8);
	if (erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, code, 0, ERX_PROT_RX) != ERX_OK)
		return (CODE_STATUS + 9);
	mapped = (const char *)(uintptr_t)addr;
	for (size_t at = 0; at < text; at++)
		if (mapped[at] != RELEASE_TEXT[at])
			return (CODE_STATUS + 10);
	return (HALT_STATUS);
}

/* Whether text begins with prefix. */
static bool
word_starts(const char *text, const char *prefix)
{
	for (size_t at = 0; prefix[at] != '\0'; at++)
		if (text[at] != prefix[at])
			return (false);
	return (true);
}

static bool
word_is(const char *word, const char *text)
{
	size_t at = 0;

	for (; text[at] != '\0'; at++)
		if (word[at] != text[at])
			return (false);
	return (word[at] == '\0');
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	const uint64_t argument = args[0];
	const erx_boot_info_t *info = (const erx_boot_info_t *)(uintptr_t)argument;
	const char *word = (const char *)(uintptr_t)(argument + info->args_off);
	static _Atomic uint32_t never;

	if (info->version != ERX_BOOT_VERSION || info->domain_id <= 4 || info->args_len == 0 ||
	    info->budget.raw == ERX_CAP_NULL || info->time_page.raw == ERX_CAP_NULL || !release_reads(info))
		return (BAD_PAGE_STATUS);
	if (word_is(word, "halt"))
		return (HALT_STATUS);
	if (word_starts(word, CODE_WORD))
		return (code_check(info, word + sizeof(CODE_WORD) - 1));
	if (word_is(word, "fault"))
		*(volatile uint64_t *)(uintptr_t)0 = 1;
	for (;;)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&never, 0, ERX_WAIT_FOREVER);
}
