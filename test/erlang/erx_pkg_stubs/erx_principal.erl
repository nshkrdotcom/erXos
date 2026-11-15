%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal).
-moduledoc """
A stub of the principal service's app registry for erx_pkg's tests: each
registration is logged in erx_pkg_test_medium's table under `registered`.
""".
-export([app_registry/0, register_app/2]).

app_registry() -> #{}.

register_app(Name, Admitted) ->
    Log = case ets:lookup(erx_pkg_test_medium, registered) of
              [{registered, Names}] -> Names;
              [] -> []
          end,
    ets:insert(erx_pkg_test_medium, {registered, Log ++ [{Name, Admitted}]}),
    ok.
