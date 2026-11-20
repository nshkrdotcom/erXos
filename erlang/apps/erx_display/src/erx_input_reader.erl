%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_input_reader).
-moduledoc """
The display's reader of an input device file another domain serves
(docs/design-display.md, "The display device"; docs/design-usb.md, "HID
reaches the display"): one process for each file of a granted input
tree, the input router's source of that file's records, as a driver is
of its device's.

start_tree/1 starts one reader, linked to the caller, for each file the
tree of a granted files facet holds, and refuses a tree that lists more
than `input_tree_files_max` files, so the router's sources stay bounded.
It lists the tree in the caller's process, so the caller waits on the
serving domain until it answers or the grant ends. A reader ends with
reason `normal`, so its link never ends the caller, and a caller that
ends with reason `normal` leaves its readers running.

Each reader opens its file through the grant, read-only, and then reads it
one read at a time, of at most the file protocol's 64 KiB: it puts the
bytes of a record the last read ended inside before what this read gave,
decodes them with `erx_input_codec:decode/1`, which holds each record to
the bounds of `record()` and drops and counts one outside them; routes
each record with `erx_winfs:input/2`, which returns once the router has
stepped it; and only then reads again. So the reader has one read
outstanding, what the serving domain sends faster than the router routes
waits in that domain, and the display holds at most one read of it.

A reader ends when its file ends or an open or a read fails, with one
line in the kernel log that counts the records it dropped, a record the
file ended inside among them; the router, which monitors each source,
then sends an up for every key it held and forgets its buttons and
touches. It does not open the file again: a new grant of the tree starts
new readers.

Everything a read gives is untrusted. The decoder bounds every record and
never raises on any bytes; a file's name, which the serving domain wrote,
names the reader's device to the router, after the facet's name, and in
the log, which escapes it.
""".

-export([start_tree/1, start_link/2]).
-export_type([opener/0]).

-include("generated/erx_abi.hrl").

%% The most one read asks for: the file protocol's transfer unit
%% (docs/design-files.md, "The file protocol").
-define(READ_MAX, 65536).

-doc """
How a reader reaches its file: called once, in the reader, it opens the
file and answers the function that makes each read, which answers what
file:read/2 does. start_tree/1 makes one over a grant; a test passes a
model of the file.
""".
-type opener() :: fun(() -> {ok, fun(() -> {ok, binary()} | eof | {error, term()})} | {error, term()}).

-doc """
One reader, linked to the caller, for each file at the root of the tree of
the files facet `Facet` that the domain holds, each named `Facet/File` to
the router. `{error, Reason}`, and no reader, when the domain holds no such
facet, its tree cannot be listed, or it lists more than
`input_tree_files_max` files (`too_many_files`).
""".
-spec start_tree(atom()) -> {ok, [pid()]} | {error, term()}.
start_tree(Facet) ->
    maybe
        {ok, Grant} ?= erx_facets:file_grant(Facet, ro),
        {ok, Names} ?= listing(erx_file_remote:list_dir(Grant, {target, []})),
        Prefix = <<(atom_to_binary(Facet))/binary, $/>>,
        {ok, [start_link(<<Prefix/binary, Name/binary>>, opener(Grant, Name)) || Name <- Names]}
    end.

listing({ok, Names}) when length(Names) > ?ERX_INPUT_TREE_FILES_MAX -> {error, too_many_files};
listing({ok, _Names} = Listed) -> Listed;
listing({resume, _, _}) -> {error, einval};
listing({error, _} = Error) -> Error.

-doc """
A reader, linked to the caller, that routes the records the file `Opener`
reaches holds, under the device name `Device`.
""".
-spec start_link(binary(), opener()) -> pid().
start_link(Device, Opener) ->
    proc_lib:spawn_link(fun() -> run(Device, Opener) end).

%% The opener of the file Name at the root of Grant's tree.
opener(Grant, Name) ->
    fun() ->
            case erx_file_remote:open(Grant, {target, [Name]}, [read, binary]) of
                {ok, Fd} -> {ok, fun() -> file:read(Fd, ?READ_MAX) end};
                {resume, _, _} -> {error, einval};
                {error, _} = Error -> Error
            end
    end.

run(Device, Opener) ->
    case Opener() of
        {ok, Read} -> read(Device, Read, <<>>, 0);
        {error, Reason} -> log(Device, "not opened: ~0p", [Reason])
    end.

%% One read, its whole records routed in order, and the bytes after the last
%% whole one kept for the next read; the reader's end at the file's end or a
%% failed read, where a record the file ended inside counts as dropped.
read(Device, Read, Partial, Dropped) ->
    case Read() of
        {ok, Bytes} ->
            {Records, NewlyDropped, Rest} = erx_input_codec:decode(<<Partial/binary, Bytes/binary>>),
            lists:foreach(fun(Record) -> erx_winfs:input(Device, Record) end, Records),
            read(Device, Read, Rest, Dropped + NewlyDropped);
        eof ->
            log(Device, "ended; ~b records dropped", [dropped(Partial, Dropped)]);
        {error, Reason} ->
            log(Device, "read failed: ~0p; ~b records dropped", [Reason, dropped(Partial, Dropped)])
    end.

dropped(<<>>, Dropped) -> Dropped;
dropped(_Partial, Dropped) -> Dropped + 1.

%% One line of the kernel log, in pieces when the file's name makes it long.
log(Device, Format, Arguments) ->
    _ = erx_log:debug_text(["erx_input_reader: ", Device, " ", io_lib:format(Format, Arguments)]),
    ok.
