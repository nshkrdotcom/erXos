%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock_nif).
-moduledoc """
The time page's reading side (docs/design-time.md, "The NIF and the
liberx calls"), which every domain may call: the page maps read-only in
each.
""".

-export([read/0]).
-export_type([page/0]).
-nifs([read_nif/0]).
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
