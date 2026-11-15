/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs erx_ed25519_check, the core of erx_bytes:ed25519_verify/3, over the requests
 * in a text file, one a line, and prints one answer a line, so test/host/erx_ed25519_test.rb
 * can judge it against RFC 8032's vectors and the host's OpenSSL:
 *
 *   SIGNATURE KEY MESSAGE   in hexadecimal, "-" for the empty message
 *     -> 1 when erx_ed25519_check accepts, 0 when it refuses
 *
 * The signature and the key are any length the request gives: one of the wrong length is
 * answered 0 without a call, as the BIF raises badarg for it. Each is copied into a buffer of
 * its exact size, so a sanitizer sees any read past it.
 */

#define _DEFAULT_SOURCE

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_ed25519.h"

typedef struct {
	uint8_t	*bytes;
	size_t	 length;
} driver_bytes_t;

static _Noreturn void driver_usage(const char *);
static char *driver_token(char **);
static driver_bytes_t driver_hex(const char *);
static bool driver_check(const driver_bytes_t *, const driver_bytes_t *,
    const driver_bytes_t *);

static _Noreturn void
driver_usage(const char *why)
{
	fprintf(stderr, "ed25519_driver: %s\n", why);
	exit(2);
}

static char *
driver_token(char **cursor)
{
	char *token;

	token = strsep(cursor, " ");
	if (token == NULL || *token == '\0')
		driver_usage("missing field");
	return (token);
}

/* An exact-size copy of the bytes, at least one byte allocated; "-" is no bytes. */
static driver_bytes_t
driver_hex(const char *text)
{
	driver_bytes_t result = { NULL, 0 };
	size_t digits;

	digits = strcmp(text, "-") == 0 ? 0 : strlen(text);
	if (digits % 2 != 0)
		driver_usage("odd hex length");
	result.length = digits / 2;
	if ((result.bytes = malloc(result.length == 0 ? 1 : result.length)) == NULL)
		driver_usage("out of memory");
	for (size_t index = 0; index < result.length; index++) {
		unsigned int byte;

		if (sscanf(text + 2 * index, "%2x", &byte) != 1)
			driver_usage("bad hex");
		result.bytes[index] = (uint8_t)byte;
	}
	return (result);
}

static bool
driver_check(const driver_bytes_t *signature, const driver_bytes_t *key,
    const driver_bytes_t *message)
{
	if (signature->length != ERX_ED25519_SIGNATURE_BYTES || key->length != ERX_ED25519_KEY_BYTES)
		return (false);
	return (erx_ed25519_check(signature->bytes, key->bytes, message->bytes, message->length));
}

int
main(int argc, char **argv)
{
	FILE *input;
	char *line = NULL, *cursor;
	size_t room = 0;
	ssize_t length;

	if (argc != 2)
		driver_usage("usage: ed25519_driver REQUESTS");
	if ((input = fopen(argv[1], "r")) == NULL)
		driver_usage("cannot open the requests");
	while ((length = getline(&line, &room, input)) > 0) {
		driver_bytes_t fields[3];

		if (line[length - 1] == '\n')
			line[length - 1] = '\0';
		cursor = line;
		for (size_t index = 0; index < 3; index++)
			fields[index] = driver_hex(driver_token(&cursor));
		if (cursor != NULL)
			driver_usage("extra field");
		printf("%d\n", driver_check(&fields[0], &fields[1], &fields[2]) ? 1 : 0);
		for (size_t index = 0; index < 3; index++)
			free(fields[index].bytes);
	}
	free(line);
	fclose(input);
	return (0);
}
