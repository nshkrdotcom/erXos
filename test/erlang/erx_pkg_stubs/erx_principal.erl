%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal).
-moduledoc """
A stub of the principal service's app registry for erx_pkg's tests: each
registration is logged in erx_pkg_medium's table under `registered`,
and the registry holds each logged name's entry and signer.
""".
-export([app_registry/0, register_app/2]).

app_registry() ->
    maps:from_list([{Name, maps:with([entry, signer], Admitted)}
                    || {Name, Admitted} <- registrations()]).

register_app(Name, Admitted) ->
    ets:insert(erx_pkg_medium, {registered, registrations() ++ [{Name, Admitted}]}),
    ok.

registrations() ->
    case ets:lookup(erx_pkg_medium, registered) of
        [{registered, Log}] -> Log;
        [] -> []
    end.
