%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_line_fs).
-moduledoc """
The line tree (docs/design-bluetooth.md, "The controller's line"): the
`erx_fs` callback module of one line, whose grant's argument is the line's
process, erx_line. The tree has `data` and `ctl` beside nothing else.

* **data** opens for reading, writing or both. A read or a write of at
  least one byte waits for an event, bytes the controller has not sent or a
  driver that has not taken what was written, so the callback hands it to
  the line, its keeper, as `{wait, Line, Request}` (docs/design-files.md,
  "Waiting requests"), and the grant goes on with its other requests
  meanwhile. Offsets are ignored: `data` is a stream.
* **ctl** opens for writing only; an open for reading is refused with
  `eacces`. parse/1 takes `reset`, with at most one trailing newline and at
  most `line_ctl_max` bytes, and refuses anything else with `einval`. A
  reset is handed to the line as a waiting request too.

Opens by create, which a client's `[write]` open sends with `O_TRUNC`, open
the file named and ignore `O_TRUNC`; the tree makes nothing. Every decision
here is a pure function of a node, the open flags or the written bytes; the
line process does every effect.
""".
-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([parse/1]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4, readdir/4,
         statfs/1, clunk/2]).

-type node_() :: root | data | ctl.

-doc """
What one ctl write Bytes asks for: `reset`, with at most one trailing
newline, or `{error, einval}` for any other bytes, an empty write and one
longer than `line_ctl_max` included.
""".
-spec parse(binary()) -> {ok, reset} | {error, einval}.
parse(Bytes) when byte_size(Bytes) > ?ERX_LINE_CTL_MAX -> {error, einval};
parse(?ERX_LINE_CTL_RESET_BYTES) -> {ok, reset};
parse(Bytes) when Bytes =:= <<(?ERX_LINE_CTL_RESET_BYTES)/binary, "\n">> -> {ok, reset};
parse(Bytes) when is_binary(Bytes) -> {error, einval}.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

%% The grant's argument is the line's process, the keeper of the tree's waits.
-doc false.
init(Line) when is_pid(Line) ->
    {ok, Line}.

-doc false.
root(_Line) ->
    {ok, ?ERX_LINE_TREE_BYTES, root, qid(root)}.

-doc false.
walk(root, Name, _Line) ->
    case [File || {File, _} <- ?ERX_LINE_FILE_MEMBERS, atom_to_binary(File) =:= Name] of
        [File] -> {ok, File, qid(File)};
        [] -> {error, enoent}
    end;
walk(_File, _Name, _Line) -> {error, enotdir}.

-doc false.
getattr(root, _Line) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr(data, _Line) -> erx_fs_node:attr(qid(data), file, 8#600);
getattr(ctl, _Line) -> erx_fs_node:attr(qid(ctl), file, 8#200).

-doc false.
open(root, Flags, _Line) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> {ok, erx_fs_node:listing([{qid(File), ?ERX_P9_DT_REG, atom_to_binary(File)}
                                       || {File, _} <- ?ERX_LINE_FILE_MEMBERS])};
        _ -> {error, eisdir}
    end;
open(data, _Flags, _Line) ->
    {ok, data};
open(ctl, Flags, _Line) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        ?ERX_P9_O_WRONLY -> {ok, ctl};
        _ -> {error, eacces}
    end.

-doc false.
read(data, _Offset, 0, _Line) ->
    {ok, <<>>};
read(data, _Offset, Count, Line) ->
    {wait, Line, {read, Count}};
read(ctl, _Offset, _Count, _Line) ->
    {error, eacces};
read({entries, _}, _Offset, _Count, _Line) ->
    {error, eisdir}.

-doc false.
write(data, Offset, <<>>, _Line) ->
    {ok, 0, Offset};
write(data, Offset, Bytes, Line) ->
    {wait, Line, {write, Offset, Bytes}};
write(ctl, Offset, Bytes, Line) ->
    case parse(Bytes) of
        {ok, reset} -> {wait, Line, {reset, Offset, byte_size(Bytes)}};
        {error, einval} = Refused -> Refused
    end;
write(_Handle, _Offset, _Bytes, _Line) ->
    {error, ebadf}.

%% A create of data or ctl opens it (erx_fs_node:open_by_create/4).
-doc false.
make(root, Name, {file, _Mode, Flags}, Line) ->
    case walk(root, Name, Line) of
        {ok, File, Qid} -> erx_fs_node:open_by_create(File, Qid, Flags, fun(F) -> open(File, F, Line) end);
        {error, enoent} -> {error, eacces}
    end;
make(_Dir, _Name, _What, _Line) ->
    {error, eacces}.

-doc false.
readdir(Handle, Offset, Max, _Line) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Line) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk(_Handle, _Line) ->
    ok.

%% A node's qid is fixed, the same in every grant: a file's path is its line_file
%% number (abi/services/line.txt), and the root's is 0, which no file has.
-spec qid(node_()) -> erx_fs:qid().
qid(root) -> {?ERX_P9_QTDIR, 0, 0};
qid(data) -> {0, 0, ?ERX_LINE_FILE_DATA};
qid(ctl) -> {0, 0, ?ERX_LINE_FILE_CTL}.
