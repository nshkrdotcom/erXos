%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_file_description).
-moduledoc """
An open-file description of a native program's file
(docs/design-programs.md, "Descriptors and files"): a session process
that opens one file for the program's handler and owns it, the file's
offset and status flags with it, and serves the handler's reads, writes
and clunk on it one at a time, in the order sent.

The open resolves the program's path over the program's narrowed
namespace from its working directory, with 9P2000.L's open flags and
create mode as the program gave them (prim_file:erx_open_at/5). Every
answer goes to the handler as a message naming the request's reply slot:
`{erx_file_opened, Slot, {ok, Description} | {error, Errno}}` for the
open, and `{erx_file_done, Slot, Answer}` for a read (`{ok, Bytes}`,
`eof` or `{error, Errno}`), a write (`ok` or `{error, Errno}`) and the
clunk (`ok` or `{error, Errno}`), after which the description ends.

The handler starts it linked, so a crash of the description, a fault of
the session's own code, ends the handler and with it the program. The
description traps exits, so the handler's end, however it comes, closes
the file.
""".

-export([table/0, open/6, read/3, write/3, clunk/2]).

-doc """
The namespace a starter hands its program, before any narrowing: the
runtime's mounts as they stand now (prim_file:erx_mounts/0). A facet's
mount names the facet, never a pid, so each open reaches the grant the
facet registry holds then (erx_path:with_facets/2).
""".
-spec table() -> erx_path:table().
table() ->
    prim_file:erx_mounts().

-doc """
Starts a description that opens `Path` for the calling handler, with the
open's reply slot `Slot`, the program's `Flags` and `Mode` (`none` for an
`lopen`), over `Table` from `Cwd`; its answer follows as a message.
""".
-spec open(non_neg_integer(), binary(), non_neg_integer(), none | non_neg_integer(),
           erx_path:table(), erx_path:place()) -> pid().
open(Slot, Path, Flags, Mode, Table, Cwd) ->
    Handler = self(),
    spawn_link(fun() -> init(Handler, Slot, Path, Flags, Mode, Table, Cwd) end).

-doc "Reads at most `Count` bytes at the description's offset, for reply slot `Slot`.".
-spec read(pid(), non_neg_integer(), pos_integer()) -> ok.
read(Description, Slot, Count) ->
    Description ! {read, Slot, Count},
    ok.

-doc "Writes `Bytes` at the description's offset, for reply slot `Slot`.".
-spec write(pid(), non_neg_integer(), binary()) -> ok.
write(Description, Slot, Bytes) ->
    Description ! {write, Slot, Bytes},
    ok.

-doc "Closes the file once the requests sent before are answered, for reply slot `Slot`.".
-spec clunk(pid(), non_neg_integer()) -> ok.
clunk(Description, Slot) ->
    Description ! {clunk, Slot},
    ok.

init(Handler, Slot, Path, Flags, Mode, Table, Cwd) ->
    process_flag(trap_exit, true),
    Granted = erx_path:with_facets(Table, persistent_term:get({erx, facets}, #{})),
    case prim_file:erx_open_at(Path, Flags, Mode, Granted, Cwd) of
        {ok, File} ->
            Handler ! {erx_file_opened, Slot, {ok, self()}},
            serve(Handler, File);
        {error, Errno} ->
            Handler ! {erx_file_opened, Slot, {error, Errno}}
    end.

serve(Handler, File) ->
    receive
        {read, Slot, Count} ->
            Handler ! {erx_file_done, Slot, file:read(File, Count)},
            serve(Handler, File);
        {write, Slot, Bytes} ->
            Handler ! {erx_file_done, Slot, file:write(File, Bytes)},
            serve(Handler, File);
        {clunk, Slot} ->
            Handler ! {erx_file_done, Slot, file:close(File)};
        {'EXIT', Handler, _} ->
            _ = file:close(File)
    end.
