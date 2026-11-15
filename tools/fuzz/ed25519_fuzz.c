/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "monocypher/monocypher-ed25519.h"

#include "erx_ed25519.h"

#define FUZZ_SIGNATURE	ERX_ED25519_SIGNATURE_BYTES
#define FUZZ_KEY	ERX_ED25519_KEY_BYTES
#define FUZZ_HEADER	(FUZZ_SIGNATURE + FUZZ_KEY)
/* ed25519_verify/3's bound on a message, ERX_BYTES_CALL_MAX. */
#define FUZZ_MESSAGE_MAX	65536

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint8_t *fuzz_copy(const uint8_t *, size_t);
static bool fuzz_check(const uint8_t *, const uint8_t *, const uint8_t *, size_t);

/* An exact-size copy, so the sanitizer sees any access past the end. */
static uint8_t *
fuzz_copy(const uint8_t *bytes, size_t length)
{
	uint8_t *copy;

	if ((copy = malloc(length == 0 ? 1 : length)) == NULL)
		abort();
	if (length != 0)
		memcpy(copy, bytes, length);
	return (copy);
}

/*
 * The check over exact-size copies of its three inputs, which it must leave as they were. It
 * accepts nothing Monocypher's own check refuses: it only adds the canonical encoding rule.
 */
static bool
fuzz_check(const uint8_t *signature, const uint8_t *key, const uint8_t *message, size_t length)
{
	uint8_t *signature_copy, *key_copy, *message_copy;
	bool valid;

	signature_copy = fuzz_copy(signature, FUZZ_SIGNATURE);
	key_copy = fuzz_copy(key, FUZZ_KEY);
	message_copy = fuzz_copy(message, length);
	valid = erx_ed25519_check(signature_copy, key_copy, message_copy, length);
	if (valid && crypto_ed25519_check(signature_copy, key_copy, message_copy, length) != 0)
		abort();
	if (memcmp(signature_copy, signature, FUZZ_SIGNATURE) != 0 ||
	    memcmp(key_copy, key, FUZZ_KEY) != 0 ||
	    (length != 0 && memcmp(message_copy, message, length) != 0))
		abort();
	free(message_copy);
	free(key_copy);
	free(signature_copy);
	return (valid);
}

/*
 * The input is a signature, a public key and a message, of at most FUZZ_MESSAGE_MAX bytes,
 * as an untrusted package's seal gives them. The check over them reads only their bytes and
 * answers the same twice. Then the input's first 32 bytes are a key pair's seed: a signature
 * of the message by that key is accepted, and refused once one bit the input chooses is
 * flipped in the signature, the key or the message.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint8_t seed[32], secret[64], key[FUZZ_KEY], signature[FUZZ_SIGNATURE];
	const uint8_t *message;
	uint8_t *altered;
	size_t length, field, bit;

	if (size < FUZZ_HEADER || size - FUZZ_HEADER > FUZZ_MESSAGE_MAX)
		return (0);
	message = data + FUZZ_HEADER;
	length = size - FUZZ_HEADER;
	if (fuzz_check(data, data + FUZZ_SIGNATURE, message, length) !=
	    fuzz_check(data, data + FUZZ_SIGNATURE, message, length))
		abort();

	memcpy(seed, data, sizeof(seed));
	crypto_ed25519_key_pair(secret, key, seed);
	crypto_ed25519_sign(signature, secret, message, length);
	if (!fuzz_check(signature, key, message, length))
		abort();

	field = data[32] % (length == 0 ? 2 : 3);
	bit = ((size_t)data[33] << 8 | data[34]);
	switch (field) {
	case 0:
		signature[bit / 8 % FUZZ_SIGNATURE] ^= (uint8_t)(1u << (bit % 8));
		break;
	case 1:
		key[bit / 8 % FUZZ_KEY] ^= (uint8_t)(1u << (bit % 8));
		break;
	default:
		break;
	}
	altered = fuzz_copy(message, length);
	if (field == 2)
		altered[bit / 8 % length] ^= (uint8_t)(1u << (bit % 8));
	if (fuzz_check(signature, key, altered, length))
		abort();
	free(altered);
	return (0);
}
