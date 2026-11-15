/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The Ed25519 check under erx_bytes:ed25519_verify/3: Monocypher's crypto_ed25519_check
 * (monocypher/) behind the one rule it leaves out. Monocypher decodes a point's y modulo p,
 * so it takes y + p for y, and takes x = 0 with the sign bit set for x = 0; RFC 8032's
 * section 5.1.3 refuses both, and so does docs/design-ssh.md's verifier. This file refuses
 * those encodings of the key and of R before the call. A canonical encoding is one of
 * exactly one point, so a signature accepted here is accepted with only the bytes it was
 * made with. Builds for the host, where test/host/erx_ed25519_test.rb and the ed25519 fuzz
 * target run it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <strings.h>

#include "monocypher/monocypher-ed25519.h"

#include "erx_ed25519.h"

/* A point's encoding: y in little-endian order, with x's sign in the last byte's top bit. */
#define ED25519_SIGN_BIT	0x80u

/* p = 2^255 - 19, and the two y for which x is 0: 1 and p - 1; all little-endian. */
static const uint8_t ed25519_p[ERX_ED25519_KEY_BYTES] = {
	0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f,
};
static const uint8_t ed25519_one[ERX_ED25519_KEY_BYTES] = { 0x01 };
static const uint8_t ed25519_p_minus_one[ERX_ED25519_KEY_BYTES] = {
	0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f,
};

static bool ed25519_below(const uint8_t *, const uint8_t *);
static bool ed25519_canonical(const uint8_t *);

/* a < b, both little-endian integers of ERX_ED25519_KEY_BYTES bytes. */
static bool
ed25519_below(const uint8_t *a, const uint8_t *b)
{
	for (size_t index = ERX_ED25519_KEY_BYTES; index-- > 0;) {
		if (a[index] != b[index])
			return (a[index] < b[index]);
	}
	return (false);
}

/*
 * True when encoding is the one encoding of its y and sign: y is below p, and the sign bit
 * is clear when x is 0, which it is for y = 1 and y = p - 1 alone. Whether a point with that
 * y exists is Monocypher's to decide.
 */
static bool
ed25519_canonical(const uint8_t *encoding)
{
	uint8_t y[ERX_ED25519_KEY_BYTES];
	bool sign;

	bcopy(encoding, y, sizeof(y));
	sign = (y[ERX_ED25519_KEY_BYTES - 1] & ED25519_SIGN_BIT) != 0;
	y[ERX_ED25519_KEY_BYTES - 1] &= (uint8_t)~ED25519_SIGN_BIT;
	if (!ed25519_below(y, ed25519_p))
		return (false);
	return (!sign || (bcmp(y, ed25519_one, sizeof(y)) != 0 &&
	    bcmp(y, ed25519_p_minus_one, sizeof(y)) != 0));
}

bool
erx_ed25519_check(const uint8_t signature[ERX_ED25519_SIGNATURE_BYTES],
    const uint8_t key[ERX_ED25519_KEY_BYTES], const uint8_t *message, size_t length)
{
	if (!ed25519_canonical(key) || !ed25519_canonical(signature))
		return (false);
	return (crypto_ed25519_check(signature, key, message, length) == 0);
}
