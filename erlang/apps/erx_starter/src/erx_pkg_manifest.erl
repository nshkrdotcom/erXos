%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_manifest).
-moduledoc """
What the system manifest says about packages (docs/design-packaging.md,
"The `apps` row", "Admission", "Where a package lies" and "The SDK"), read
through `erx_manifest`, the reader generated from `abi/manifest.txt`, which
checks every count, span, index and string before a field is read:

* `apps`: the `apps` row as admission reads it (`erx_app_admit:apps()`),
  or `none` when the manifest has no row and the machine takes no
  packages. Beside the row's budget and max, it holds the rows of the app
  template, the one session template whose principal is absent: the facet
  row granted to it for the `packages` service, and for each service of
  the row, its name, whether its interface is `windows`, and the facet row
  granted to the template for it;
* `reserved`: the names no app may take, those of the manifest's
  principal, domain, service and facet rows, sorted;
* `packages`: the image's packages, each its app's name, the SHA-256 of
  its header, by which the machine trusts it, and whether its start row
  is enabled, in the order the manifest packs them, which the build sorts
  by name;
* `signers`: each `signer` row's name and Ed25519 public key, in packed
  order;
* `development`: the public half of the builder's development package
  key, which the generated reader accepts in a development manifest
  alone, or `none`.

A manifest with an `apps` row and not exactly one app template, or whose
template holds not exactly one facet row of the `packages` service or of
a service of the row, is refused: the domain library places no app
entries for it, and admission would have no row to keep. The reader reads
the bytes alone, so the packer runs it, and admission over its answer, on
the host. It takes no policy decision; the package process builds its
recovery's config from this answer.
""".

-export([system_config/1, admission/1]).
-export_type([config/0, package/0, error/0]).

-include("generated/erx_abi.hrl").

-doc "A package of the image.".
-type package() :: #{name := binary(),
                     sha256 := <<_:256>>,
                     enabled := boolean()}.

-doc "What the manifest says about packages.".
-type config() :: #{apps := none | erx_app_admit:apps(),
                    reserved := [binary()],
                    packages := [package()],
                    signers := [{binary(), <<_:256>>}],
                    development := none | <<_:256>>}.

-doc """
Why a manifest is refused: the generated reader's error, or an `apps` row
whose app template is not one session template (`{templates, Count}`), or
whose template holds `Count` facet rows, not one, of the service named
`Service` (`{grants, Service, Count}`).
""".
-type error() :: erx_manifest:error()
               | {apps, {templates, non_neg_integer()}
                      | {grants, binary(), non_neg_integer()}}.

-doc "Read `Manifest`, the bytes of a system manifest, or refuse it.".
-spec system_config(binary()) -> {ok, config()} | {error, error()}.
system_config(Manifest) ->
    try
        {ok, config(Manifest)}
    catch
        throw:{?MODULE, Error} -> {error, Error}
    end.

-doc "What admission reads of a manifest (`erx_app_admit:admit/3`).".
-spec admission(config()) -> erx_app_admit:manifest().
admission(#{apps := Apps, reserved := Reserved, packages := Packages}) ->
    #{apps => Apps, reserved => Reserved,
      packages => [Name || #{name := Name} <- Packages]}.

config(Manifest) ->
    View = checked(erx_manifest:open(Manifest)),
    #{apps => apps(View, rows(View, apps)),
      reserved => lists:usort(lists:append([names(View, rows(View, Table))
                                            || Table <- [principals, domains, services, facets]])),
      packages => [package(View, Row) || Row <- rows(View, packages)],
      signers => [{name(View, Row), Key} || #{key := Key} = Row <- rows(View, signers)],
      development => development(rows(View, development_key))}.

%% The reader bounds the apps table to one row, whose services partition
%% app_services, so the row's services are that table's rows.
apps(_View, []) ->
    none;
apps(View, [#{memory := Memory, max := Max}]) ->
    Services = list_to_tuple(rows(View, services)),
    Granted = granted(app_template(rows(View, sessions)), rows(View, facets)),
    IsPackages = fun(Index) -> name(View, element(Index + 1, Services)) =:= ?ERX_PACKAGES_SERVICE_BYTES end,
    #{memory => Memory,
      max => Max,
      packages_row => template_row(Granted, IsPackages, ?ERX_PACKAGES_SERVICE_BYTES),
      services => [service(View, Index, element(Index + 1, Services), Granted)
                   || #{service := Index} <- rows(View, app_services)]}.

%% The index of the app template, the one session template whose principal
%% is absent.
app_template(Sessions) ->
    case [Index || {Index, #{principal := ?ERX_MF_NONE}} <- lists:enumerate(0, Sessions)] of
        [Template] -> Template;
        Templates -> throw({?MODULE, {apps, {templates, length(Templates)}}})
    end.

%% The facet rows granted to the sessions of Template, each its index and
%% its service's; a row granted to a domain, the system domain or another
%% template is none of them.
granted(Template, Facets) ->
    [{Row, Service} || {Row, #{grantee_kind := ?ERX_MF_GRANTEE_SESSION, grantee := Grantee,
                               service := Service}} <- lists:enumerate(0, Facets),
                       Grantee =:= Template].

%% The one row of Granted whose service IsService takes, or the refusal
%% naming Service.
template_row(Granted, IsService, Service) ->
    case [Row || {Row, Index} <- Granted, IsService(Index)] of
        [Row] -> Row;
        Rows -> throw({?MODULE, {apps, {grants, Service, length(Rows)}}})
    end.

service(View, Index, #{interface := Interface} = Row, Granted) ->
    Name = name(View, Row),
    #{name => Name,
      windows => Interface =:= ?ERX_SERVICE_WINDOWS,
      row => template_row(Granted, fun(Service) -> Service =:= Index end, Name)}.

package(View, #{flags := Flags, sha256 := Sha256} = Row) ->
    #{name => name(View, Row), sha256 => Sha256, enabled => Flags band ?ERX_MF_PACKAGE_ENABLED =/= 0}.

%% The reader bounds the development key's table to one row.
development([]) ->
    none;
development([#{key := Key}]) ->
    Key.

names(View, Rows) ->
    [name(View, Row) || Row <- Rows].

%% A row's name, a reference into the string table.
name(View, #{name := Reference}) ->
    checked(erx_manifest:string(View, Reference)).

rows(View, Table) ->
    lists:reverse(checked(erx_manifest:fold(View, Table, fun(Row, Acc) -> [Row | Acc] end, []))).

checked({ok, Value}) -> Value;
checked({error, Error}) -> throw({?MODULE, Error}).
