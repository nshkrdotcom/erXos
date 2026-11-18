%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_medium).
-moduledoc """
The packages as storage holds them (docs/design-packaging.md, "Where a
package lies"), the medium erx_pkg_io reads and deletes through, and only
erx_pkg_io calls it.

* **Installed packages** lie in `installed/` of the data partition's
  `packages/` directory, which the storage domain serves as the files
  service `packages`; the system domain reaches it through its grant,
  rooted at `packages/` and mounted at its place, `/packages`
  (erx_ns:packages_place/0, which erx_domain_srv mounts), so they lie at
  `/packages/installed`, where an app's own grant roots, and every
  request goes through the system domain's
  file client, erx_file_remote, in erx_pkg_io's own process. While the
  grant is not in place the path is the root's and the directory absent,
  which the listing answers as `{error, absent}`.
* **The image's packages** lie at `apps/NAME.app` in the booted slot's
  system partition, which the storage domain serves read-only as the
  `system` tree, rooted at `apps/` (erx_storage_system). The system domain
  reads each through its grant of the `system` facet (erx_facets:file_grant/2),
  walked by name with the file client, erx_file_remote, as erx_ns walks the
  record's place, so no path of the namespace and nothing of the partition
  outside `apps/` is reached. While the grant is not in place every read
  answers `{error, enoent}`.

Every answer is one of the erx_pkg_io callbacks' contract: a positioned
read at or past the end of a file reads no bytes, as pread(2) does, and
every failure is the file client's reason.
""".
-behaviour(erx_pkg_io).

-export([list/1, size/2, pread/4, delete/1]).

-include_lib("kernel/include/file.hrl").

-doc """
At most `Max` entries of `packages/installed/` and whether it holds more;
`{error, absent}` while the packages grant is not in place.
""".
-spec list(pos_integer()) -> {ok, [binary()], boolean()} | {error, atom()}.
list(Max) ->
    case prim_file:list_dir_all(installed()) of
        {ok, Names} -> {ok, [name(Name) || Name <- lists:sublist(Names, Max)], length(Names) > Max};
        {error, enoent} -> {error, absent};
        {error, _} = Error -> Error
    end.

-doc "The length of a package, which must be a regular file.".
-spec size(erx_pkg_io:place(), binary()) -> {ok, non_neg_integer()} | {error, atom()}.
size(Place, File) ->
    case info(Place, path(Place, File)) of
        {ok, #file_info{type = regular, size = Size}} -> {ok, Size};
        {ok, #file_info{}} -> {error, einval};
        {error, _} = Error -> Error
    end.

-doc "At most `Size` bytes of a package from `Offset`; none at or past its end.".
-spec pread(erx_pkg_io:place(), binary(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary()} | {error, atom()}.
pread(Place, File, Offset, Size) ->
    case opened(Place, path(Place, File)) of
        {ok, Fd} ->
            try file:pread(Fd, Offset, Size) of
                {ok, Bytes} -> {ok, Bytes};
                eof -> {ok, <<>>};
                {error, _} = Error -> Error
            after
                file:close(Fd)
            end;
        {error, _} = Error ->
            Error
    end.

-doc "Delete an entry of `packages/installed/`.".
-spec delete(binary()) -> ok | {error, atom()}.
delete(File) ->
    file:delete(path(installed, File), [raw]).

%% A file name is one entry of its directory, never a path: erx_pkg_io names
%% only entries the listing gave or the manifest's package rows name, and a
%% name of any other form fails to match.
path(Place, File) when File =/= <<>>, File =/= <<".">>, File =/= <<"..">> ->
    nomatch = binary:match(File, [<<"/">>, <<0>>]),
    place(Place, File).

%% An installed package's path in the namespace, and an image package's name in
%% the system tree, whose root is the partition's apps/.
place(installed, File) -> <<(installed())/binary, $/, File/binary>>;
place(system, File) -> File.

%% installed/ of the packages tree, where the system domain mounts it.
installed() ->
    {Packages, _Options} = erx_ns:packages_place(),
    <<Packages/binary, "/installed">>.

%% The #file_info{} of an installed package at its path, or of an image package
%% of that name on the system grant.
info(installed, Path) ->
    file:read_file_info(Path, [raw]);
info(system, Name) ->
    on_system(fun(Grant) -> found(erx_file_remote:read_file_info(Grant, {target, [Name]}, true)) end).

%% The package opened to read, a descriptor file:pread/3 and file:close/1 take.
opened(installed, Path) ->
    file:open(Path, [read, raw, binary]);
opened(system, Name) ->
    on_system(fun(Grant) -> found(erx_file_remote:open(Grant, {target, [Name]}, [read, binary])) end).

%% The file client's answer for a name on the tree. A walk that failed answers its
%% error, a missing name enoent; the tree serves no link, so a walk that passed and
%% would follow one is einval.
found(#file_info{} = Info) -> {ok, Info};
found({ok, _} = Opened) -> Opened;
found({error, _} = Error) -> Error;
found({resume, _, {_Kinds, {error, _} = Error}}) -> Error;
found({resume, _, {_Kinds, ok}}) -> {error, einval}.

%% Act on the system domain's read-only grant of the system tree, or enoent while
%% its facet registry holds none.
on_system(Act) ->
    case erx_facets:file_grant(system, ro) of
        {ok, Grant} -> Act(Grant);
        {error, _} = Error -> Error
    end.

%% The file client gives a name it can decode as characters, and one it
%% cannot as its bytes.
name(Name) when is_binary(Name) -> Name;
name(Name) -> unicode:characters_to_binary(Name).
