%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock_nif).
-moduledoc """
The time page (docs/design-time.md, "The NIF and the liberx calls"):
its reading side, which every domain may call, since the page maps
read-only in each, and its setter, set_offset/1, which only the clock
service, erx_clock, calls.
""".

-export([read/0, set_offset/1]).
-export_type([page/0]).
-nifs([read_nif/0, set_offset_nif/1]).
-on_load(on_load/0).

-type page() :: #{offset := integer(), cold := boolean(), monotonic := non_neg_integer()}.

on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-doc """
The page's wall offset in nanoseconds, whether its sequence is zero (so
nothing set the clock this boot), and the monotonic clock read right
after; `{error, limit}` when the page's sequence has run out.
""".
-spec read() -> {ok, page()} | {error, limit}.
read() ->
    read_nif().

read_nif() ->
    erlang:nif_error(undef).

-doc """
Stores OffsetNs as the page's wall offset, so wall time reads M +
OffsetNs at monotonic time M; monotonic time does not move. `badarg` for
an offset outside 0..ERX_TIME_OFFSET_MAX, `limit` when the page's
sequence has run out, `unsupported` where the backend cannot set wall
time.
""".
-spec set_offset(non_neg_integer()) -> ok | {error, badarg | limit | unsupported}.
set_offset(OffsetNs) ->
    set_offset_nif(OffsetNs).

set_offset_nif(_OffsetNs) ->
    erlang:nif_error(undef).
