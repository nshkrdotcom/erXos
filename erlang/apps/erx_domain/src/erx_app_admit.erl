%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_admit).
-moduledoc """
Admission of an app package (docs/design-packaging.md, "Admission"):
whether a package whose header the file check accepted and authenticated
may become an app of this machine, and with what. `admit/3` is a pure
function of that header with the signer the file check named, the facts of
the manifest it reads and the boot's registry of app principals, and the
first of its six checks that fails is the answer, each check a function of
the same name:

1. `check_apps`: the manifest has an `apps` row;
2. `check_built_for_image`: the header's ABI version and architecture are
   the image's, which are `ERX_ABI_VERSION` and `ERX_ARCH_MACHINE_ARCH`,
   the name of the `abi/arch/` file the build was generated from;
3. `check_name`: the name is an app name, property 5's reservation rule
   (docs/design-system.md, "Identifiers") applied to it;
4. `check_entry`: a name the registry holds keeps its entry, for its own
   signer only, and a new name takes the lowest entry the registry does
   not hold;
5. `check_memory`: the declared memory is a whole number of pages, at
   least `ERX_APP_MEMORY_MIN` and at most the `apps` row's budget, so the
   domain library's plan of the app's session, which refuses memory that
   is not page-aligned, never meets one admission let in;
6. `check_needs`: each need is a service of the `apps` row.

Nothing else is judged: a declaration can only name what the row offers,
so the build's proof over the row is the proof over the app. Admission
reserves nothing and writes nothing; the package process registers the
principal when the package is committed.
""".

-export([admit/3, entry/4]).
-export_type([manifest/0, apps/0, service/0,
              registry/0, admitted/0, reason/0]).

-include("generated/erx_abi.hrl").

-doc """
A service of the `apps` row: its name, whether it is a `windows` service,
and the index of the app template's facet row that grants it.
""".
-type service() :: #{name := binary(),
                     windows := boolean(),
                     row := non_neg_integer()}.

-doc """
The `apps` row: the budget all apps share, how many apps a boot holds, the
index of the app template's `packages` row, and the services an app may
need.
""".
-type apps() :: #{memory := pos_integer(),
                  max := pos_integer(),
                  packages_row := non_neg_integer(),
                  services := [service()]}.

-doc """
What admission reads of the manifest: its `apps` row, or `none` when it has
none; the names no app may take, those of its principals, configured
domains, services and facet rows; and the names of the image's packages.
""".
-type manifest() :: #{apps := none | apps(),
                      reserved := [binary()],
                      packages := [binary()]}.

-doc "The boot's app principals: each name's entry and signer.".
-type registry() :: #{binary() => #{entry := non_neg_integer(),
                                    signer := erx_pkg_header:authenticator()}}.

-doc """
What an admitted package holds: its principal's entry, which admission
reserves nothing in; the indices of the app template's facet rows its
session keeps, the `packages` row and one row for each need, ascending;
its start row's display, its one `windows` need if it has exactly one and
`none` otherwise; its declared memory, which its sessions' own budgets
hold; and the signer the file check named, which registration records in
the registry for `check_entry` to compare.
""".
-type admitted() :: #{entry := non_neg_integer(),
                      rows := [non_neg_integer()],
                      display := none | binary(),
                      memory := pos_integer(),
                      signer := erx_pkg_header:authenticator()}.

-doc "Why a package is refused, each tag refused by one check of the six.".
-type reason() :: no_apps
                | {abi, Have :: non_neg_integer(), Want :: non_neg_integer()}
                | {arch, Have :: binary(), Want :: binary()}
                | {bad_name, binary()}
                | {name_taken, binary()}
                | {signer_changed, binary()}
                | apps_full
                | {memory, non_neg_integer()}
                | {not_offered, binary()}.

-doc """
Admit `Checked`, the file check's answer, against `Manifest` and
`Registry`, or refuse it with the first check that fails. Of `Checked` it
reads the decoded header and the signer.
""".
-spec admit(erx_pkg_header:checked(), manifest(), registry()) ->
    {ok, admitted()} | {error, reason()}.
admit(Checked, Manifest, Registry) ->
    try
        {ok, admitted(Checked, Manifest, Registry)}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

admitted(#{header := #{name := Name, memory := Memory, needs := Needs} = Header,
           signer := Signer},
         #{apps := AppsRow} = Manifest, Registry) ->
    #{memory := Budget, max := Max, packages_row := PackagesRow,
      services := Offered} = check_apps(AppsRow),
    check_built_for_image(Header),
    check_name(Name, Signer, Manifest),
    Entry = check_entry(Name, Signer, Max, Registry),
    check_memory(Memory, Budget),
    Kept = check_needs(Needs, Offered),
    #{entry => Entry,
      rows => lists:sort([PackagesRow | [Row || #{row := Row} <- Kept]]),
      display => display([Service || #{name := Service,
                                       windows := true} <- Kept]),
      memory => Memory,
      signer => Signer}.

check_apps(none) -> refuse(no_apps);
check_apps(#{} = Apps) -> Apps.

check_built_for_image(#{abi_version := Abi, arch := Arch}) ->
    require(Abi =:= ?ERX_ABI_VERSION, {abi, Abi, ?ERX_ABI_VERSION}),
    require(Arch =:= ?ERX_ARCH_MACHINE_ARCH_BYTES,
            {arch, Arch, ?ERX_ARCH_MACHINE_ARCH_BYTES}).

%% An app name is an identifier that stays one with `_` and the digits of
%% the names quota every principal has appended, so every session name it
%% takes is one; is none that session naming keeps (property 5): not root,
%% whose session names are the system principal's, and not of a session
%% name's form, so it is no principal's session name; and is no name of the
%% manifest, nor, for an installed package, of a package of the image.
check_name(Name, Signer, #{reserved := Reserved, packages := ImagePackages}) ->
    Suffix = integer_to_binary(erx_domain_core:names_quota()),
    require(is_identifier(<<Name/binary, $_, Suffix/binary>>)
            andalso not erx_domain_core:session_reserved(Name),
            {bad_name, Name}),
    Taken = case Signer of
                image -> Reserved;
                _ -> Reserved ++ ImagePackages
            end,
    require(not lists:member(Name, Taken), {name_taken, Name}).

is_identifier(Bin) ->
    case erx_ident:new(Bin) of
        {error, bad_identifier} -> false;
        _ -> true
    end.

check_entry(Name, Signer, Max, Registry) ->
    case entry(Name, Signer, Max, Registry) of
        {ok, Entry} -> Entry;
        {error, Reason} -> refuse(Reason)
    end.

-doc """
The entry of `Max` that `Name`, signed by `Signer`, takes in `Registry`: a
name the registry holds keeps its entry, for its own signer only, and a new
name takes the lowest entry no name holds. Admission and registration
(`erx_principal:register/2`) both decide by it.
""".
-spec entry(binary(), erx_pkg_header:authenticator(), non_neg_integer(), registry()) ->
    {ok, non_neg_integer()} | {error, {signer_changed, binary()} | apps_full}.
entry(Name, Signer, Max, Registry) ->
    case Registry of
        #{Name := #{entry := Entry, signer := Signer}} ->
            {ok, Entry};
        #{Name := _} ->
            {error, {signer_changed, Name}};
        #{} ->
            Held = [Entry || #{entry := Entry} <- maps:values(Registry)],
            case lists:seq(0, Max - 1) -- Held of
                [Free | _] -> {ok, Free};
                [] -> {error, apps_full}
            end
    end.

check_memory(Memory, Budget) ->
    require(Memory rem ?ERX_PAGE_SIZE =:= 0 andalso
                Memory >= ?ERX_APP_MEMORY_MIN andalso Memory =< Budget,
            {memory, Memory}).

%% The service of each need, once each; a need the row lacks is refused.
check_needs(Needs, Offered) ->
    lists:usort([offered(Need, Offered) || Need <- Needs]).

offered(Need, Offered) ->
    case [Service || #{name := Name} = Service <- Offered, Name =:= Need] of
        [Service] -> Service;
        [] -> refuse({not_offered, Need})
    end.

display([Display]) -> Display;
display(_) -> none.

require(true, _Reason) -> ok;
require(false, Reason) -> refuse(Reason).

-spec refuse(reason()) -> no_return().
refuse(Reason) ->
    throw({?MODULE, Reason}).
