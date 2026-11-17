%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter).
-moduledoc """
A stub of the start service's `packages/2` for erx_pkg's tests: each
publication is logged in the case's public ETS table erx_pkg_stubs under `published`, and
answered `{error, eio}` while `fail_publish` is set.
""".
-export([packages/2]).

packages(Lifetime, Set) ->
    case ets:lookup(erx_pkg_stubs, fail_publish) of
        [{fail_publish, true}] ->
            {error, eio};
        _ ->
            Log = case ets:lookup(erx_pkg_stubs, published) of
                      [{published, Sets}] -> Sets;
                      [] -> []
                  end,
            ets:insert(erx_pkg_stubs, {published, Log ++ [{Lifetime, Set}]}),
            ok
    end.
