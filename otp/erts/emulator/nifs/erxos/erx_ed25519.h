/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_ED25519_H
#define ERX_ED25519_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The sizes of RFC 8032's Ed25519 signature, R then S, and public key. */
#define ERX_ED25519_SIGNATURE_BYTES	64u
#define ERX_ED25519_KEY_BYTES	32u

/*
 * True when signature is a valid Ed25519 signature of the length bytes at message by the
 * public key, under the acceptance rules of docs/design-ssh.md ("The verifier's acceptance
 * rules"), which are RFC 8032's (section 5.1.7) with the strict decoding of section 5.1.3:
 * the key and R each decode as a point, with y below p, a square root that exists, and not
 * x = 0 with the sign bit set; S is below the group's order L; and [8][S]B = [8]R + [8][k]A.
 * Every input is public, and the time taken depends on them. message may be NULL when length
 * is 0.
 */
bool erx_ed25519_check(const uint8_t signature[ERX_ED25519_SIGNATURE_BYTES],
    const uint8_t key[ERX_ED25519_KEY_BYTES], const uint8_t *message, size_t length);

#endif
