%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal).
-moduledoc """
A stub of the principal service's app registry for erx_pkg's tests: each
registration is logged in erx_pkg_medium's table under `registered`, as
the package's name, place, the entry `erx_app_admit:entry/4` gives it and
its admission, and the registry holds each logged name's entry and signer.
""".
-export([app_registry/0, register_app/1]).

%% More entries than any case registers.
-define(MAX, 16).

app_registry() ->
    maps:from_list([{Name, #{entry => Entry, signer => Signer}}
                    || {Name, _Place, Entry, #{signer := Signer}} <- registrations()]).

register_app(#{name := Name, place := Place, checked := #{header := #{layout := _, start := _}},
               admitted := #{signer := Signer} = Admitted}) ->
    {ok, Entry} = erx_app_admit:entry(Name, Signer, ?MAX, app_registry()),
    ets:insert(erx_pkg_medium, {registered, registrations() ++ [{Name, Place, Entry, Admitted}]}),
    ok.

registrations() ->
    case ets:lookup(erx_pkg_medium, registered) of
        [{registered, Log}] -> Log;
        [] -> []
    end.
