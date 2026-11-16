/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host harness of test/host/facet_parameters_test.rb: a NIF of
 * erx_facet_parameters_tests whose served/1 builds the domain library's
 * boot view from a packed manifest's bytes, as the root does
 * (liberx/system/dom_boot_view.c), and answers the view's services and
 * grants as erx_domain_lib:configured/0 does, through the NIF's own
 * erx_domain_served_terms: {ok, {Services, Grants}}, or {refused, Reason}
 * for a manifest the view refuses.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erl_nif.h"

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/dom_lib.h"
#include "erx_domain_terms.h"

static ERL_NIF_TERM
served(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary binary;
	erx_manifest_view_t manifest;
	erx_abi_error_t error;
	erx_dom_boot_sizes_t sizes;
	erx_dom_boot_tables_t tables;
	erx_dom_lib_t *lib;
	ERL_NIF_TERM services, grants, result = 0;
	bool answered = false;
	const char *reason;
	uint8_t *bytes, *region;
	size_t region_len;

	if (argc != 1 || !enif_inspect_binary(env, argv[0], &binary))
		return (enif_make_badarg(env));
	/* The view points into the bytes and the tables, so both outlive the terms' making. */
	bytes = malloc(binary.size == 0 ? 1 : binary.size);
	lib = calloc(1, sizeof(*lib));
	region = NULL;
	if (bytes == NULL || lib == NULL)
		goto out;
	memcpy(bytes, binary.data, binary.size);
	if (!erx_manifest_open(bytes, binary.size, &manifest, &error)) {
		result = enif_make_atom(env, "unreadable");
		answered = true;
		goto out;
	}
	sizes = erx_dom_view_sizes(&manifest, 0);
	if (!erx_dom_boot_layout(&sizes, 0, &tables, &region_len) || region_len > SIZE_MAX - ERX_PAGE_SIZE)
		goto out;
	region_len = (region_len + ERX_PAGE_SIZE) / ERX_PAGE_SIZE * ERX_PAGE_SIZE;
	if ((region = aligned_alloc(ERX_PAGE_SIZE, region_len)) == NULL ||
	    !erx_dom_boot_layout(&sizes, (uintptr_t)region, &tables, &region_len))
		goto out;
	if ((reason = erx_dom_view_build(lib, &manifest, 0, &tables)) != NULL) {
		result = enif_make_tuple2(env, enif_make_atom(env, "refused"), enif_make_string(env, reason, ERL_NIF_LATIN1));
		answered = true;
	} else if (erx_domain_served_terms(env, &lib->view, &services, &grants)) {
		result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_tuple2(env, services, grants));
		answered = true;
	}
out:
	free(region);
	free(lib);
	free(bytes);
	/* enif_make_badarg raises once made, so it is made only for a failure. */
	return (answered ? result : enif_make_badarg(env));
}

static ErlNifFunc functions[] = {
	{ "served", 1, served, 0 },
};

ERL_NIF_INIT(erx_facet_parameters_tests, functions, NULL, NULL, NULL, NULL)
