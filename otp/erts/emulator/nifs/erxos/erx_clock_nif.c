/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The calls under erx_clock_nif (docs/design-time.md, "The NIF and the liberx calls"):
 * the reading side, which needs nothing beyond the time page every domain maps, and the
 * setter, the runtime's one call of erx_time_set_offset (imports.txt, only_erx_clock_nif),
 * which erXos's kernel admits only with WRITE on the page. The setter is a dirty I/O NIF: on
 * Fiasco it is a round trip to the root's one service thread, which answers only after the
 * body it is running, so on a normal scheduler it would hold every process there behind a
 * stopped domain's teardown (docs/design-fiasco.md, "The loop").
 */

#define STATIC_ERLANG_NIF 1

#include <stdbool.h>
#include <stdint.h>

#include "erl_nif.h"

#include "liberx/backend/api.h"
#include "liberx/backend/runtime_entry.h"

/* The page's offset and whether its sequence is zero, then the monotonic clock right after. */
static ERL_NIF_TERM
read_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ERL_NIF_TERM keys[3], values[3], page;
	int64_t offset_ns;
	bool cold;

	(void)argc;
	(void)argv;
	if (!erx_time_offset(&offset_ns, &cold))
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "limit")));
	keys[0] = enif_make_atom(env, "offset");
	values[0] = enif_make_int64(env, offset_ns);
	keys[1] = enif_make_atom(env, "cold");
	values[1] = enif_make_atom(env, cold ? "true" : "false");
	keys[2] = enif_make_atom(env, "monotonic");
	values[2] = enif_make_uint64(env, erx_clock_ns());
	if (!enif_make_map_from_arrays(env, keys, values, 3, &page))
		return (enif_make_badarg(env));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), page));
}

/* erx_time_set_offset's status as the atom erx_clock_nif:set_offset/1 answers. */
static ERL_NIF_TERM
set_status(ErlNifEnv *env, int status)
{
	switch (status) {
	case ERX_OK:
		return (enif_make_atom(env, "ok"));
	case ERX_EINVAL:
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg")));
	case ERX_ELIMIT:
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "limit")));
	case ERX_ENOTSUP:
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "unsupported")));
	default:
		/* A status outside the setter's contract is no answer the caller can act on. */
		return (enif_raise_exception(env, enif_make_tuple2(env, enif_make_atom(env, "erx_time_set_offset"),
		    enif_make_int(env, status))));
	}
}

/* Stores the offset; a term that is no u64 is badarg here, and the setter's range check is the one. */
static ERL_NIF_TERM
set_offset_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 offset_ns;

	(void)argc;
	if (!enif_get_uint64(env, argv[0], &offset_ns))
		return (set_status(env, ERX_EINVAL));
	return (set_status(env, erx_time_set_offset(erx_boot_info()->time_page, offset_ns)));
}

static ErlNifFunc nif_funcs[] = {
	{ "read_nif", 0, read_nif, 0 },
	{ "set_offset_nif", 1, set_offset_nif, ERL_NIF_DIRTY_JOB_IO_BOUND },
};

ERL_NIF_INIT(erx_clock_nif, nif_funcs, NULL, NULL, NULL, NULL)
