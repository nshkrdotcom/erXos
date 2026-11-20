%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_facets).
-moduledoc """
The domain's facet registry (docs/design-system.md, "Facets a configured
domain serves"): every facet the domain holds, by name, as facet/0 states
it. This module is the registry's one owner: it alone reads and writes the
persistent term that holds it, so the shape of a facet is known here and
nowhere else, and the build's `facet-registry` chokepoint refuses the term's
key in any other module.

install/1 is the one writer. The domain's connection agent (erx_connections)
calls it, and in the system domain, whose registry is local, the domain
service (erx_domain_srv) does; the `facet-registry-writers` chokepoint
refuses any other caller.

The readers read the registry at use:

* find/1 and pids/0 answer `erx:cap/1` and `erx:caps/0`;
* table/1 puts the grant beneath each facet's entry of a namespace table at
  each resolution, so a re-grant serves the next lookup;
* file_grant/2,3 is the one maker of a file client's handle on a files facet's
  grant. A caller that keeps the handle, as an image mount keeps the grant
  it opened its file on, keeps that grant until it lets it go.

No reader gives an entry or a handle more rights than the facet's grant
carries.

It is preloaded beside prim_file and erx_path, since every resolution of a
path reads it, the code loader's included.
""".

-export([find/1, pids/0, install/1, is_facet/1, files/2, table/1, file_grant/2, file_grant/3]).
-export_type([facet/0]).

-include("generated/erx_abi.hrl").

%% The registry's persistent term, which no other module names.
-define(REGISTRY, {erx, facets}).

-doc """
A facet as the registry holds it: its pid, or for a facet of a files service
its pid with its grant's rights, as the manifest's facet row states them
(files/2), the rights table/1 puts beneath each entry of the facet
(docs/design-files.md, "Rights beneath an entry").
""".
-type facet() :: pid() | {pid(), erx_abi_enums:files_rights()}.

-doc """
The pid of the facet named `Name` that the domain holds, or `undefined` when
it holds none of that name. A facet whose server ended is a dead pid until
the server's next incarnation installs another.
""".
-spec find(atom()) -> pid() | undefined.
find(Name) ->
    case registry() of
        #{Name := Facet} -> pid(Facet);
        #{} -> undefined
    end.

-doc "The pid of every facet the domain holds, by name, each as find/1 answers it.".
-spec pids() -> #{atom() => pid()}.
pids() ->
    #{Name => pid(Facet) || Name := Facet <- registry()}.

-doc """
Installs each of `Facets` under its name, replacing an older facet of the
name and keeping every other. The caller is the registry's writer in its
domain, the one process whose installations are serialized, so none is lost
to another write that read the registry before it.
""".
-spec install(#{atom() => facet()}) -> ok.
install(Facets) ->
    persistent_term:put(?REGISTRY, maps:merge(registry(), Facets)).

-doc """
Whether `Term` is a facet as the system domain sends it: a pid, or a pid with
a member of `files_rights`. The connection agent installs nothing else.
""".
-spec is_facet(term()) -> boolean().
is_facet({Pid, Rights}) -> is_pid(Pid) andalso lists:keymember(Rights, 1, ?ERX_FILES_RIGHTS_MEMBERS);
is_facet(Facet) -> is_pid(Facet).

-doc """
The facet of the files service grant `Pid` that serves `Rights`, the rights of
its facet row, which the domain service takes from the manifest and no reply
of the server's sets.
""".
-spec files(pid(), erx_abi_enums:files_rights()) -> facet().
files(Pid, Rights) ->
    {Pid, Rights}.

-doc """
The namespace table a resolution walks, made from `Mounts` as it starts. For
each entry whose provider is `{facet, Name, Tree}`, binds of one included:

* when the registry holds a files facet for `Name`, the entry is on its
  grant, provider `{grant, Pid, Tree}`, with the lesser of the rights its
  mount asked and those the facet carries (erx_path:lesser/2);
* otherwise, or when the two rights have no lesser, the entry is `ended`,
  which answers `eio`.

So a facet entry's rights never exceed its grant's, as an EROFS entry's and a
grant pid's do. A facet's mount names the facet, never a pid, so a re-grant
serves the next lookup and nothing has to follow the registry. Every other
entry is as `Mounts` holds it.
""".
-spec table(erx_path:table()) -> erx_path:table().
table(Mounts) ->
    Registry = registry(),
    [case Entry of
         #{provider := {facet, Name, Tree}, rights := Asked} ->
             case Registry of
                 #{Name := {Pid, Rights}} when is_pid(Pid) ->
                     on_grant(Entry, Pid, Tree, erx_path:lesser(Asked, Rights));
                 _ ->
                     Entry#{provider := ended}
             end;
         #{} ->
             Entry
     end || Entry <- Mounts].

%% A facet's entry on the grant Pid with Rights, or ended for rights erx_path:lesser/2
%% does not order.
on_grant(Entry, _Pid, _Tree, none) -> Entry#{provider := ended};
on_grant(Entry, Pid, Tree, Rights) -> Entry#{provider := {grant, Pid, Tree}, rights := Rights}.

-doc """
A file client's handle on the grant of the files facet `Name`, read-only, on
the tree of the facet's name, for a mount or a read of rights `Rights`: `ro`
through a grant of any rights, and `rx`, a program image's, only through an
`rx` grant, which writes nothing (F5, F6). `{error, eacces}` for an `rx` use
of any other grant, and `{error, enoent}` when the registry holds no files
facet of the name. So no handle carries more than its grant's rights.
""".
-spec file_grant(atom(), ro | rx) -> {ok, {pid(), binary(), ro}} | {error, eacces | enoent}.
file_grant(Name, Rights) ->
    file_grant(Name, Rights, atom_to_binary(Name)).

-doc """
The handle file_grant/2 makes, on the tree named `Tree` instead of the
facet's name: for a facet of an interface whose tree has one name whatever
the service is called, as an input tree's is `input_tree`
(abi/services/input.txt).
""".
-spec file_grant(atom(), ro | rx, binary()) -> {ok, {pid(), binary(), ro}} | {error, eacces | enoent}.
file_grant(Name, Rights, Tree) ->
    case registry() of
        #{Name := {Pid, Granted}}
          when is_pid(Pid), (Rights =:= ro orelse (Rights =:= rx andalso Granted =:= rx)) ->
            {ok, {Pid, Tree, ro}};
        #{Name := {Pid, _Granted}} when is_pid(Pid) ->
            {error, eacces};
        #{} ->
            {error, enoent}
    end.

registry() ->
    persistent_term:get(?REGISTRY, #{}).

-spec pid(facet()) -> pid().
pid({Pid, _Rights}) -> Pid;
pid(Pid) -> Pid.
