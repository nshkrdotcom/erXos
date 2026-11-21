%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_fs_tree).
-moduledoc """
The Bluetooth domain's control tree (docs/design-bluetooth.md, "The pairing window"):
the `erx_fs` callback module whose grant's argument is the file service, `erx_bt_fs`,
which keeps the window and the tree's waiting reads. The tree holds `pair`.

`pair` opens for reading and writing, and each open is a window: the callback asks the
file service, which answers `ebusy` while another window is open or the pairing a
closed one took has no outcome, and `eio` while the store is `unknown` after its read.
The first write, parsed by `erx_bt_window:parse/1`, is the window's mode; a read waits
for the window's next line as a waiting request the file service keeps
(docs/design-files.md, "Waiting requests"), and reads the end of the file once the
lines have ended. Offsets are ignored: `pair` is a stream. Clunking the open closes the
window, and withdraws a pairing it took that the link still runs.

Every callback answers at once: a call of the file service, which answers without
waiting for an event, or a read handed to it.
""".
-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4, readdir/4,
         statfs/1, clunk/2]).

-define(TREE, <<"bt">>).
-define(PAIR, <<"pair">>).

-doc false.
init(Fs) when is_pid(Fs) ->
    {ok, Fs}.

-doc false.
root(_Fs) ->
    {ok, ?TREE, root, qid(root)}.

-doc false.
walk(root, ?PAIR, _Fs) -> {ok, pair, qid(pair)};
walk(root, _Name, _Fs) -> {error, enoent};
walk(pair, _Name, _Fs) -> {error, enotdir}.

-doc false.
getattr(root, _Fs) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr(pair, _Fs) -> erx_fs_node:attr(qid(pair), file, 8#600).

%% The opener writes its mode and reads the window's lines through the one open.
-doc false.
open(root, Flags, _Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> {ok, erx_fs_node:listing([{qid(pair), ?ERX_P9_DT_REG, ?PAIR}])};
        _ -> {error, eisdir}
    end;
open(pair, Flags, Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        ?ERX_P9_O_RDWR ->
            case gen_server:call(Fs, {open, self()}) of
                {ok, Id} -> {ok, {pair, Id}};
                {error, _} = Refused -> Refused
            end;
        _ ->
            {error, eacces}
    end.

-doc false.
read({pair, Id}, _Offset, Count, Fs) ->
    {wait, Fs, {read, Id, Count}};
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
write({pair, Id}, Offset, Bytes, Fs) ->
    case erx_bt_window:parse(Bytes) of
        {ok, Mode} ->
            case gen_server:call(Fs, {write, Id, Mode}) of
                ok -> {ok, byte_size(Bytes), Offset};
                {error, _} = Refused -> Refused
            end;
        {error, einval} = Refused ->
            Refused
    end;
write(_Handle, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

%% A create of pair opens it (erx_fs_node:open_by_create/4); the tree makes nothing.
-doc false.
make(root, ?PAIR, {file, _Mode, Flags}, Fs) ->
    erx_fs_node:open_by_create(pair, qid(pair), Flags, fun(F) -> open(pair, F, Fs) end);
make(_Dir, _Name, _What, _Fs) ->
    {error, eacces}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk({pair, Id}, Fs) ->
    gen_server:call(Fs, {clunk, Id});
clunk(_Handle, _Fs) ->
    ok.

%% A node's qid is fixed, the same in every grant; the root's path is 0, pair's 1.
-spec qid(root | pair) -> erx_fs:qid().
qid(root) -> {?ERX_P9_QTDIR, 0, 0};
qid(pair) -> {0, 0, 1}.
