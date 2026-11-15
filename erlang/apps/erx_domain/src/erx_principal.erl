%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal).
-moduledoc """
The principal service's app half (docs/design-packaging.md, "An app's
principal"): the boot's registry of app principals. `register_app/2`,
which only the package process calls, writes an app's record when a
package of its name is committed; `app_registry/0` answers what admission
compares a package with.

The registry is a value the domain service keeps, since it starts every
session and names each from its principal: the functions below it are pure
and the two calls are the edge. Its bounds are the domain library's: an
app principal is the library's app entry, one of the `max` the apps row
holds, numbered for the whole boot (`erx_dom_apps_place`), so a record is
keyed by its name and holds its entry. An entry is never freed within a
boot: there is no unregister, and a name keeps its entry and signer until
the machine reboots, so the names and entries the registry holds stay
within `max` (PK9). A record holds the app's entry, its signer and its
declared memory, the memory each of its sessions' own budgets holds, and
nothing else: an app principal has no credentials, so no login starts a
session of one (AP2).
""".

-export([register_app/2, app_registry/0]).
-export([new/1, register/3, registry/1, app/2]).
-export_type([apps/0, app/0, reason/0]).

-doc "An app principal's record.".
-type app() :: #{entry := non_neg_integer(),
                    signer := erx_pkg_header:authenticator(),
                    memory := pos_integer()}.

-doc """
The boot's app principals: `max`, the apps row's, and each registered
name's record.
""".
-opaque apps() :: #{max := non_neg_integer(),
                    names := #{binary() => app()}}.

-doc """
Why a registration is refused: a name or record of the wrong shape; a
record whose entry is not the one `erx_app_admit:entry/4` gives the name
now; or that rule's own refusal, every entry held (none without an apps
row, whose `max` is 0) or the name registered under another signer.
Admission decides by the same rule before the package is committed.
""".
-type reason() :: badarg
                | {entry, non_neg_integer()}
                | apps_full
                | {signer_changed, binary()}.

-doc """
Register the app `Name` with the record of `Admitted`, the package's
admission (`erx_app_admit:admitted/0`), of which it keeps the entry, the
signer and the declared memory.
""".
-spec register_app(binary(), erx_app_admit:admitted()) -> ok | {error, reason()}.
register_app(Name, Admitted) ->
    gen_server:call(erx_domain_srv, {register_app, Name, Admitted}, infinity).

-doc "The registry admission reads: each registered name's entry and signer.".
-spec app_registry() -> erx_app_admit:registry().
app_registry() ->
    gen_server:call(erx_domain_srv, app_registry, infinity).

-doc "An empty registry of `Max` entries, the apps row's `max`, 0 without the row.".
-spec new(non_neg_integer()) -> apps().
new(Max) when is_integer(Max), Max >= 0 ->
    #{max => Max, names => #{}}.

-doc """
`Apps` with `Name`'s record, the entry, signer and memory of `Admitted`,
written in the entry `erx_app_admit:entry/4` gives it, the one admission
gave: a name not yet registered takes the lowest entry no name holds, and
a registered one writes its record again in its own entry, with its own
signer only.
""".
-spec register(binary(), erx_app_admit:admitted(), apps()) -> {ok, apps()} | {error, reason()}.
register(Name, Admitted, Apps) when is_binary(Name), is_map(Admitted) ->
    case maps:with([entry, signer, memory], Admitted) of
        #{entry := Entry, signer := _, memory := Memory} = Record
          when is_integer(Entry), Entry >= 0, is_integer(Memory), Memory > 0 ->
            write(Name, Record, Apps);
        #{} ->
            {error, badarg}
    end;
register(_Name, _Admitted, _Apps) ->
    {error, badarg}.

write(Name, #{entry := Entry, signer := Signer} = Record, #{max := Max, names := Names} = Apps) ->
    case erx_app_admit:entry(Name, Signer, Max, registry(Apps)) of
        {ok, Entry} -> {ok, Apps#{names := Names#{Name => Record}}};
        {ok, _Given} -> {error, {entry, Entry}};
        {error, _} = Refused -> Refused
    end.

-doc "What admission compares a package with: each name's entry and signer.".
-spec registry(apps()) -> erx_app_admit:registry().
registry(#{names := Names}) ->
    #{Name => maps:with([entry, signer], Record) || Name := Record <- Names}.

-doc """
`Name`'s record, or `error` for a name not registered in this boot: what
the start of an app's session reads.
""".
-spec app(binary(), apps()) -> {ok, app()} | error.
app(Name, #{names := Names}) ->
    maps:find(Name, Names).
