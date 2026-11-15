%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_manifest).
-moduledoc """
What the system manifest says about packages (docs/design-packaging.md,
"The `apps` row", "Where a package lies" and "The SDK"), read through
`erx_manifest`, the reader generated from `abi/manifest.txt`, which checks
every count, span, index and string before a field is read:

* `apps`: the `apps` row, its budget, how many apps a boot holds and the
  names of the services an app may take, or `none` when the manifest has
  no row and the machine takes no packages;
* `packages`: the image's packages, each its app's name, the SHA-256 of
  its header, by which the machine trusts it, and whether its start row
  is enabled, in the order the manifest packs them, which the build sorts
  by name;
* `signers`: each `signer` row's name and Ed25519 public key, in packed
  order;
* `development`: the public half of the builder's development package
  key, which only a development manifest holds, or `none`.

The reader takes no policy decision; the package process builds its
recovery's config from this answer.
""".

-export([system_config/1]).
-export_type([config/0, apps/0, package/0]).

-include("generated/erx_abi.hrl").

-doc "The `apps` row: its budget in bytes, its max and its services' names.".
-type apps() :: #{memory := pos_integer(),
                  max := pos_integer(),
                  services := [binary()]}.

-doc "A package of the image.".
-type package() :: #{name := binary(),
                     sha256 := <<_:256>>,
                     enabled := boolean()}.

-doc "What the manifest says about packages.".
-type config() :: #{apps := none | apps(),
                    packages := [package()],
                    signers := [{binary(), <<_:256>>}],
                    development := none | <<_:256>>}.

-doc """
Read `Manifest`, the bytes of a system manifest, or refuse it with the
generated reader's error.
""".
-spec system_config(binary()) -> {ok, config()} | {error, erx_manifest:error()}.
system_config(Manifest) ->
    maybe
        {ok, View} ?= erx_manifest:open(Manifest),
        {ok, Apps} ?= rows(View, apps),
        {ok, Services} ?= services(View),
        {ok, Packages} ?= rows(View, packages),
        {ok, Signers} ?= rows(View, signers),
        {ok, Development} ?= rows(View, development_key),
        {ok, PackageNames} ?= names(View, Packages),
        {ok, SignerNames} ?= names(View, Signers),
        {ok, #{apps => apps(Apps, Services),
               packages => [package(Name, Row) || {Name, Row} <- lists:zip(PackageNames, Packages)],
               signers => [{Name, Key} || {Name, #{key := Key}} <- lists:zip(SignerNames, Signers)],
               development => development(Development)}}
    end.

%% The reader bounds the apps table to one row, whose services partition
%% app_services, so the row's services are that table's rows.
apps([], []) ->
    none;
apps([#{memory := Memory, max := Max}], Services) ->
    #{memory => Memory, max => Max, services => Services}.

package(Name, #{flags := Flags, sha256 := Sha256}) ->
    #{name => Name, sha256 => Sha256, enabled => Flags band ?ERX_MF_PACKAGE_ENABLED =/= 0}.

%% The reader bounds the development key's table to one row.
development([]) ->
    none;
development([#{key := Key}]) ->
    Key.

%% The names of the services app_services indexes, each index checked by the reader.
services(View) ->
    maybe
        {ok, Rows} ?= rows(View, app_services),
        {ok, Services} ?= fetch_each(View, services, [Index || #{service := Index} <- Rows]),
        names(View, Services)
    end.

%% The name of each row, a reference into the string table.
names(View, Rows) ->
    strings(View, [Name || #{name := Name} <- Rows]).

rows(View, Table) ->
    maybe
        {ok, Reversed} ?= erx_manifest:fold(View, Table, fun(Row, Acc) -> [Row | Acc] end, []),
        {ok, lists:reverse(Reversed)}
    end.

fetch_each(View, Table, Indices) ->
    collect(fun(Index) -> erx_manifest:fetch(View, Table, Index) end, Indices).

strings(View, References) ->
    collect(fun(Reference) -> erx_manifest:string(View, Reference) end, References).

%% Each element's {ok, Value}, in order, or the first error.
collect(_Read, []) ->
    {ok, []};
collect(Read, [Item | Items]) ->
    maybe
        {ok, Value} ?= Read(Item),
        {ok, Values} ?= collect(Read, Items),
        {ok, [Value | Values]}
    end.
