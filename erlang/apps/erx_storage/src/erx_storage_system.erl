%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_storage_system).
-moduledoc """
The `system` tree (docs/design-storage.md, "The `system` tree"): the read-only
`erx_fs` backend over the EROFS reader, `erx_erofs`, with which the storage
domain that serves `system` serves the booted slot's system partition.

* **Mounting.** mount/1 mounts the image the `system` window holds, read-only
  on the booted slot's system partition (erx_blk_service), with the layout
  of this domain's `-erx_record system_image` record: the image from the
  partition's byte 0 and its dm-verity tree's offset, length, salt and root
  hash, which the domain library wrote from the manifest the booted boot
  image holds (docs/design-stopgap.md, "The booted slot"). Both forms take
  the record words and read the layout through their one reader,
  erx_device_record:system_image/1, so no caller can hand the mount a
  layout, a root hash or `unchecked`: every block the reader parses, the
  directories included, matched the root hash the boot image pins before
  it is parsed (E1), and a partition changed under a rebuilt tree answers
  `eio`. A record that is absent or refused, an image the reader refuses,
  and an image whose `apps/` is not a directory leave the tree `none`; the
  reason goes to the log once.
* **Serving.** Each grant is `erx_fs:start_link(?MODULE, Tree, Rights)` on
  the one tree mount/1 answers, which never changes, so a grant reads the
  image in its own processes and grants share nothing but the window. The
  tree roots at the partition's `apps/`: a node is the list of names below
  it, and every operation asks the reader for `apps/` and those names, so
  no request reaches a file outside it (`..` is the grant's, which stays at
  the root). The tree serves directories and regular files, all the packer
  writes there; any other kind answers `enotsup`. There is no writing
  callback, so every grant of the tree, an `rw` one included, refuses each
  writing operation with `erofs` before any callback (F5).

Every answer is the reader's: an error it gives reaches the client as it
is, a block that did not match its tree as `eio`. A grant of a `none` tree
attaches, answers statfs and clunks, and answers every walk, getattr and
open `eio`, so it reaches no file.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([mount/1, mount/3, log/1]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4,
         statfs/1, clunk/2, read_mode/0]).
-export_type([tree/0]).

%% The tree's name, which attach's Aname names, and the directory of the partition
%% it roots at.
-define(TREE, <<"system">>).
-define(APPS, <<"apps">>).

-doc "The mounted partition and the qid of its `apps/`, or `none` when no image is served.".
-opaque tree() :: {erofs, erx_erofs:fs(), erx_fs:qid()} | none.

%% A node: the names from the tree's root, apps/, to it.
-type node_() :: [binary()].

-doc """
Mounts the image of the `system` window `Window` with the layout of this
domain's `system_image` record, logging to the kernel log.
""".
-spec mount(pid()) -> tree().
mount(Window) ->
    mount(Window, erx_device_record:records(), fun ?MODULE:log/1).

-doc """
Mounts the image of `Window` with the layout of the `system_image` record
among `Records`, boot records as erx_device_record:records/0 returns them,
or answers `none` for a refused record, an image the reader refuses or one
whose `apps/` is not a directory, the reason handed to `Log`.
""".
-spec mount(pid(), [[string()]], fun((binary()) -> term())) -> tree().
mount(Window, Records, Log) ->
    case erx_device_record:system_image(Records) of
        {ok, Layout} ->
            mounted(erx_erofs:mount(Window, Layout, Log), Log);
        {error, {bad_device_record, Reason}} ->
            _ = Log(iolist_to_binary(["no system tree: ", Reason])),
            none
    end.

mounted({ok, Fs}, Log) ->
    case erx_erofs:read_file_info(Fs, [?APPS]) of
        {ok, #{type := directory} = Info} ->
            {erofs, Fs, qid(Info)};
        _ ->
            _ = Log(<<"no system tree: the image has no apps directory">>),
            none
    end;
mounted({error, _Posix, Diagnostic}, Log) ->
    _ = Log(Diagnostic),
    none.

%% The kernel log line of a refused mount or a failed operation, which runs in the
%% process that read the image: a fun of an exported function, so a reload of this
%% module leaves the tree's log working.
-doc false.
-spec log(binary()) -> term().
log(Diagnostic) ->
    erx_log:debug(["erx_storage_system: ", Diagnostic]).

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(Tree) ->
    {ok, Tree}.

%% A tree with no image still roots a grant, whose every walk, getattr and open
%% answers eio.
-doc false.
root({erofs, _Fs, Qid}) -> {ok, ?TREE, [], Qid};
root(none) -> {ok, ?TREE, [], {?ERX_P9_QTDIR, 0, 0}}.

%% The reader would walk a directory's own `.` and `..` entries; `..` is the grant's,
%% and neither names anything below the node.
-doc false.
walk(_Dir, Name, _Tree) when Name =:= <<".">>; Name =:= <<"..">> ->
    {error, enoent};
walk(Dir, Name, Tree) ->
    Node = Dir ++ [Name],
    case info(Node, Tree) of
        {ok, Info} -> {ok, Node, qid(Info)};
        {error, _} = Error -> Error
    end.

-doc false.
getattr(Node, Tree) ->
    case info(Node, Tree) of
        {ok, Info} -> attr(Info);
        {error, _} = Error -> Error
    end.

%% A directory's open takes its listing; a file's names the file, which each read
%% reads from the image. The grant opens no fid for writing.
-doc false.
open(Node, _Flags, Tree) ->
    case info(Node, Tree) of
        {ok, #{type := directory}} -> listing(Node, Tree);
        {ok, #{type := regular}} -> {ok, {file, Node}};
        {error, _} = Error -> Error
    end.

%% A handle is made only by open/3 on a mounted tree, which info/2 answers.
-doc false.
read({file, Node}, Offset, Count, {erofs, Fs, _}) ->
    case erx_erofs:pread(Fs, apps(Node), Offset, Count) of
        eof -> {ok, <<>>};
        Answer -> Answer
    end;
read({entries, _}, _Offset, _Count, _Tree) ->
    {error, eisdir}.

-doc false.
readdir(Handle, Offset, Max, _Tree) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Tree) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_EROFS).

-doc false.
clunk(_Handle, _Tree) ->
    ok.

-doc false.
read_mode() -> helper.

%% ---------------------------------------------------------------------------
%% Nodes
%% ---------------------------------------------------------------------------

%% What the reader answers of Node, a directory or a regular file; eio for a tree with
%% no image.
-spec info(node_(), tree()) -> {ok, erx_erofs:info()} | {error, file:posix()}.
info(Node, {erofs, Fs, _}) ->
    case erx_erofs:read_file_info(Fs, apps(Node)) of
        {ok, #{type := symlink}} -> {error, enotsup};
        Answer -> Answer
    end;
info(_Node, none) ->
    {error, eio}.

apps(Node) -> [?APPS | Node].

%% The open of directory Dir: its entries, each with its qid and type.
listing(Dir, {erofs, Fs, _} = Tree) ->
    case erx_erofs:list_dir(Fs, apps(Dir)) of
        {ok, Names} -> entries(Dir, Names, Tree, []);
        {error, _} = Error -> Error
    end.

entries(_Dir, [], _Tree, Entries) ->
    {ok, erx_fs_node:listing(lists:reverse(Entries))};
entries(Dir, [Name | Names], Tree, Entries) ->
    case info(Dir ++ [Name], Tree) of
        {ok, #{type := Type} = Info} ->
            entries(Dir, Names, Tree, [{qid(Info), dirent_type(Type), Name} | Entries]);
        {error, _} = Error ->
            Error
    end.

%% A node's qid: its inode number, version 0, since the image never changes.
qid(#{type := directory, inode := Inode}) -> {?ERX_P9_QTDIR, 0, Inode};
qid(#{type := regular, inode := Inode}) -> {0, 0, Inode}.

dirent_type(directory) -> ?ERX_P9_DT_DIR;
dirent_type(regular) -> ?ERX_P9_DT_REG.

%% What getattr shows: the inode's mode, owner, links, size and time, every time the
%% image's modification time, as the format keeps no other.
attr(#{type := Type, mode := Mode, size := Size, nlink := Nlink, uid := Uid, gid := Gid,
       mtime := {Seconds, Nanoseconds}} = Info) ->
    {ok, Attr} = erx_fs_node:attr(qid(Info), kind(Type), Mode band 8#7777),
    {ok, Attr#{size := Size, nlink := Nlink, uid := Uid, gid := Gid, blocks := (Size + 511) div 512,
               atime_sec := Seconds, atime_nsec := Nanoseconds, mtime_sec := Seconds,
               mtime_nsec := Nanoseconds, ctime_sec := Seconds, ctime_nsec := Nanoseconds}}.

kind(directory) -> dir;
kind(regular) -> file.
