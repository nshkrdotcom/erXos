/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef TEST_GUEST_NATIVE_DOMAIN_MODES_H
#define TEST_GUEST_NATIVE_DOMAIN_MODES_H

/* What program.c ends with: a halt, or a boot page that does not read as a domain's. */
#define HALT_STATUS	42
#define BAD_PAGE_STATUS	13
/* "code:": a refused step of the code object check ends with CODE_STATUS plus its number. */
#define CODE_STATUS	60
/* "code:" and the 16 lower-case hex digits of the copy the root writes into the boot page. */
#define CODE_WORD	"code:"
#define CODE_DIGITS	16

/* What the release's one file, release.txt, begins with. */
#define RELEASE_TEXT	"erx native_domain release"

#endif /* TEST_GUEST_NATIVE_DOMAIN_MODES_H */
