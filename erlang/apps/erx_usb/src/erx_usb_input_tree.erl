%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_input_tree).
-moduledoc """
The input tree (docs/design-usb.md, "HID reaches the display"): the
`erx_fs` callback module of one controller's input numbers, whose grant's
argument is the controller's places, erx_usb_places_sup. The tree is named
`input` and holds the `usb_input_max` files `hid0` to `hid7` beside nothing
else, the same set for as long as the places live, so a display that
starts one reader for each file it lists has its sources fixed.

The module has no `write/4` and no `make/4`, so every grant of the tree is
read-only whatever its rights (docs/design-files.md, F5): nothing is
written, made or removed. A read of a file takes whole records only
(docs/design-usb.md, "HID reaches the display"): one of at least one byte
whose count holds no record is refused with `einval`, and any other waits for the number's
records, so the callback hands it to the number's stream,
erx_usb_input_stream, its keeper, as `{wait, Stream, {read, Count}}`
(docs/design-files.md, "Waiting requests"), and the grant goes on with its
other requests meanwhile. Offsets are ignored: a file is a stream.

A grant's argument is the streams' pids, which erx_usb_places_sup's
input_tree/1 answers with the supervisor of the grants. The places restart
as one, the tree's grants with the streams, so a grant never holds a
stream that has ended without ending itself.
""".
-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1, clunk/2]).

-define(TREE, <<"input">>).

%% A node: the root, or the file of input number N.
-type node_() :: root | {hid, non_neg_integer()}.

%% The grant's handle: the streams of the numbers, number 0 first.
-type fs() :: tuple().

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
-spec init(fs()) -> {ok, fs()}.
init(Streams) when tuple_size(Streams) =:= ?ERX_USB_INPUT_MAX ->
    {ok, Streams}.

-doc false.
root(_Fs) ->
    {ok, ?TREE, root, qid(root)}.

-doc false.
walk(root, Name, _Fs) ->
    case lists:keyfind(Name, 1, [{name(N), N} || N <- numbers()]) of
        {Name, N} -> {ok, {hid, N}, qid({hid, N})};
        false -> {error, enoent}
    end;
walk(_File, _Name, _Fs) -> {error, enotdir}.

-doc false.
getattr(root, _Fs) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr({hid, _} = File, _Fs) -> erx_fs_node:attr(qid(File), file, 8#444).

-doc false.
open(root, Flags, _Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> {ok, erx_fs_node:listing([{qid({hid, N}), ?ERX_P9_DT_REG, name(N)} || N <- numbers()])};
        _ -> {error, eisdir}
    end;
open({hid, _} = File, _Flags, _Fs) ->
    {ok, File}.

-doc false.
read({hid, _}, _Offset, 0, _Fs) ->
    {ok, <<>>};
read({hid, N}, _Offset, Count, Fs) ->
    case Count < erx_input_codec:size() of
        true -> {error, einval};
        false -> {wait, element(N + 1, Fs), {read, Count}}
    end;
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk(_Handle, _Fs) ->
    ok.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

numbers() -> lists:seq(0, ?ERX_USB_INPUT_MAX - 1).

name(N) -> <<"hid", (integer_to_binary(N))/binary>>.

%% A node's qid is fixed, the same in every grant: a file's path is its number
%% plus one, and the root's is 0, which no file has.
-spec qid(node_()) -> erx_fs:qid().
qid(root) -> {?ERX_P9_QTDIR, 0, 0};
qid({hid, N}) -> {0, 0, N + 1}.
