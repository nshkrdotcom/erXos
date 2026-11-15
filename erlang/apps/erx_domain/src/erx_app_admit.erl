%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_admit).
-moduledoc """
Admission of an app package (docs/design-packaging.md, "Admission"):
whether a package whose header the file check accepted and authenticated
may become an app of this machine, and with what. `admit/3` is a pure
function of that header, the facts of the manifest it reads and the boot's
registry of app principals, and the first of its six checks that fails is
the answer:

1. the manifest has an `apps` row;
2. the header's ABI version and architecture are the image's, which are
   `ERX_ABI_VERSION` and `ERX_ARCH_MACHINE_ARCH`, the name of the
   `abi/arch/` file the build was generated from;
3. the name is an app name: property 5's reservation rule
   (docs/design-system.md, "Identifiers") applied to it;
4. a name the registry holds keeps its entry, for its own signer only, and
   a new name takes the lowest entry the registry does not hold;
5. the declared memory is at least `ERX_APP_MEMORY_MIN` and at most the
   `apps` row's budget;
6. each need is a service of the `apps` row.

Nothing else is judged: a declaration can only name what the row offers,
so the build's proof over the row is the proof over the app. Admission
reserves nothing and writes nothing; the package process registers the
principal when the package is committed. The packer runs this module on
the host over each package of an image, so one implementation decides at
build and on the machine.
""".

-export([admit/3]).
-export_type([header/0, signer/0, manifest/0, apps/0, service/0,
              registry/0, admitted/0, reason/0]).

-include("generated/erx_abi.hrl").

-doc """
Who vouches for a package: `image` for a package of the image, which the
manifest's `package` row authenticates by its hash; `development` for the
development key; otherwise the name of the `signer` row whose key signed it.
""".
-type signer() :: image | development | binary().

-doc """
The fields of a header that admission reads: those `erx_pkg_header:decode/2`
gives, and the signer the file check named.
""".
-type header() :: #{name := binary(),
                    abi_version := non_neg_integer(),
                    arch := binary(),
                    memory := non_neg_integer(),
                    needs := [binary()],
                    signer := signer(),
                    _ => _}.

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
                                    signer := signer()}}.

-doc """
What an admitted package holds: its principal's entry, which admission
reserves nothing in; the indices of the app template's facet rows its
session keeps, the `packages` row and one row for each need, ascending; and
its start row's display, its one `windows` need if it has exactly one and
`none` otherwise.
""".
-type admitted() :: #{entry := non_neg_integer(),
                      rows := [non_neg_integer()],
                      display := none | binary()}.

-doc "Why a package is refused, each tag the check of the same name.".
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
Admit `Header` against `Manifest` and `Registry`, or refuse it with the
first check that fails.
""".
-spec admit(header(), manifest(), registry()) ->
    {ok, admitted()} | {error, reason()}.
admit(Header, Manifest, Registry) ->
    try
        {ok, admitted(Header, Manifest, Registry)}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

admitted(#{name := Name, signer := Signer, memory := Memory,
           needs := Needs} = Header,
         #{apps := AppsRow} = Manifest, Registry) ->
    #{memory := Budget, max := Max, packages_row := PackagesRow,
      services := Offered} = apps_row(AppsRow),
    check_built_for_image(Header),
    check_app_name(Name, Signer, Manifest),
    Entry = entry(Name, Signer, Max, Registry),
    check_memory(Memory, Budget),
    Kept = kept(Needs, Offered),
    #{entry => Entry,
      rows => lists:sort([PackagesRow | [Row || #{row := Row} <- Kept]]),
      display => display([Service || #{name := Service,
                                       windows := true} <- Kept])}.

apps_row(none) -> refuse(no_apps);
apps_row(#{} = Apps) -> Apps.

check_built_for_image(#{abi_version := Abi, arch := Arch}) ->
    require(Abi =:= ?ERX_ABI_VERSION, {abi, Abi, ?ERX_ABI_VERSION}),
    require(Arch =:= ?ERX_ARCH_MACHINE_ARCH_BYTES,
            {arch, Arch, ?ERX_ARCH_MACHINE_ARCH_BYTES}).

%% An app name is an identifier that stays one with `_` and the digits of
%% the names quota every principal has appended, so every pooled name of
%% its sessions is one; is not of a pooled name's form, so it takes no other
%% principal's; is not root, the prefix of the system principal's session
%% names; and is no name of the manifest, nor, for an installed package, of
%% a package of the image.
check_app_name(Name, Signer, #{reserved := Reserved,
                               packages := ImagePackages}) ->
    Suffix = integer_to_binary(erx_domain_core:names_quota()),
    require(is_identifier(<<Name/binary, $_, Suffix/binary>>)
            andalso not is_pooled(Name)
            andalso Name =/= <<"root">>,
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

%% A pooled name is an identifier, `_` and decimal digits: a name whose
%% part after its last `_` is digits and whose part before it is not empty.
is_pooled(Name) ->
    case binary:matches(Name, <<"_">>) of
        [] ->
            false;
        Matches ->
            {Last, 1} = lists:last(Matches),
            Digits = binary:part(Name, Last + 1, byte_size(Name) - Last - 1),
            Last > 0 andalso Digits =/= <<>>
                andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end,
                                  binary_to_list(Digits))
    end.

%% A name the registry holds keeps its entry, for its own signer only; a new
%% name takes the lowest entry no name holds.
entry(Name, Signer, Max, Registry) ->
    case Registry of
        #{Name := #{entry := Entry, signer := Signer}} ->
            Entry;
        #{Name := _} ->
            refuse({signer_changed, Name});
        #{} ->
            Held = [Entry || #{entry := Entry} <- maps:values(Registry)],
            case lists:seq(0, Max - 1) -- Held of
                [Free | _] -> Free;
                [] -> refuse(apps_full)
            end
    end.

check_memory(Memory, Budget) ->
    require(Memory >= ?ERX_APP_MEMORY_MIN andalso Memory =< Budget,
            {memory, Memory}).

%% The service of each need, once each; a need the row lacks is refused.
kept(Needs, Offered) ->
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
