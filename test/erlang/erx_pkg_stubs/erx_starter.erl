%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter).
-moduledoc """
A stub of the start service's `packages/2` for erx_pkg's tests: each
publication is logged in erx_pkg_medium's table under `published`, and
answered `{error, eio}` while `fail_publish` is set.
""".
-export([packages/2]).

packages(Lifetime, Set) ->
    case ets:lookup(erx_pkg_medium, fail_publish) of
        [{fail_publish, true}] ->
            {error, eio};
        _ ->
            Log = case ets:lookup(erx_pkg_medium, published) of
                      [{published, Sets}] -> Sets;
                      [] -> []
                  end,
            ets:insert(erx_pkg_medium, {published, Log ++ [{Lifetime, Set}]}),
            ok
    end.
