%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_input_stream).
-moduledoc """
One input number's stream (docs/design-usb.md, "HID reaches the display"):
the process behind one file, `hidN`, of the USB domain's input tree, which
holds the bytes written to the number and is the keeper of every read of
the file that waits for them. `erx_usb_input_tree` is the tree; its reads
come here as waiting requests.

**The occupant.** At most one process, a HID function, occupies the number
at a time (`occupy/2`), and only it writes records (`write/2`). The stream
monitors it, and when it ends, for any reason, the stream appends `release`
to the file itself, so the file carries `release` before any record of the
next occupant and no path by which a function ends has to remember it.
A number is free when it has no occupant and its buffer holds less than one
read's worth; one whose occupant has ended but whose end the stream has
not yet taken is free too, since `occupy/2` takes that end first, so the
`release` is in the buffer before the new occupant is.

**Backpressure.** The buffer holds at most one read's worth of bytes,
`p9_io_max`, the most one read of the file protocol takes. A write that
fits is taken at once; one that does not waits, its caller with it, until
reads have made room, so a display that stops reading stops the function
and its device waits with its reports. The occupant has at most one write
waiting, since `write/2` is a call. The `release` an end appends is taken
whatever the buffer holds, and a number whose buffer is full is not free,
so the buffer passes the bound by at most that one record.

**Waiting requests** (docs/design-files.md, "Serving: the `erx_fs`
behaviour", "Waiting requests"). The tree hands one kind here,
`{read, Count}`, a read of the file, Count at least one record's size:
answered at once from the buffer when it holds records, with as many whole
records as Count holds and the buffer has, so no read ends inside a record;
otherwise it waits, and the reads waiting are served in the order they
arrived as records come. Every write and every `release` is whole records,
so the buffer always is too. A read waiting is answered `eintr` by the set
at its flush or its fid's clunk. Offsets are ignored: the file is a stream,
and it never ends while the stream lives.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-export([start_link/0, occupy/2, write/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([request/0]).

%% The tree's term for what a waiting request asks.
-type request() :: {read, Count :: pos_integer()}.

-record(stream, {%% The occupant and the stream's monitor of it, or none.
                 occupant = none :: none | {pid(), reference()},
                 %% The bytes written and not yet read, in order.
                 buffer = <<>> :: binary(),
                 %% The occupant's write that did not fit: its caller and bytes.
                 pending = none :: none | {gen_server:from(), binary()},
                 waits = erx_fs_waits:new() :: erx_fs_waits:waits()}).

-doc "Starts a stream with no occupant and an empty buffer, linked to the caller.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-doc """
Makes Pid the occupant of Stream's number if the number is free, `taken`
otherwise. The stream monitors Pid from then on, and appends `release`
when it ends.
""".
-spec occupy(pid(), pid()) -> ok | taken.
occupy(Stream, Pid) when is_pid(Pid) ->
    gen_server:call(Stream, {occupy, Pid}, infinity).

-doc """
Writes Records to Stream's file, in order, and returns once the stream has
taken them, which waits while the buffer has no room for them. Only the
occupant writes; any other caller gets `{error, not_occupant}`. The records
are encoded here, in the caller, so a record outside `record()`'s bounds,
or records past one read's worth, which could never fit, end the writer
and never the stream.
""".
-spec write(pid(), [erx_input_codec:record()]) -> ok | {error, not_occupant}.
write(Stream, Records) ->
    Bytes = << <<(erx_input_codec:encode(Record))/binary>> || Record <- Records >>,
    byte_size(Bytes) =< ?ERX_P9_IO_MAX orelse erlang:error(badarg, [Stream, Records]),
    gen_server:call(Stream, {write, Bytes}, infinity).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

-doc false.
init([]) ->
    {ok, #stream{}}.

-doc false.
handle_call({occupy, Pid}, _From, S0) ->
    S = take_ended(S0),
    case free(S) of
        true -> {reply, ok, S#stream{occupant = {Pid, erlang:monitor(process, Pid)}}};
        false -> {reply, taken, S}
    end;
handle_call({write, Bytes}, {Pid, _} = From, #stream{occupant = {Pid, _}, pending = none} = S) ->
    {noreply, offer(From, Bytes, S)};
handle_call({write, _Bytes}, _From, S) ->
    {reply, {error, not_occupant}, S}.

-doc false.
handle_cast(_Request, S) ->
    {noreply, S}.

-doc false.
handle_info(?ERX_FS_WAIT(Wait, {read, _Count} = Read), #stream{waits = Waits} = S) ->
    {noreply, serve(S#stream{waits = erx_fs_waits:hold(?ERX_FS_WAIT(Wait, Read), Waits)})};
handle_info({'DOWN', Monitor, process, _, _}, #stream{occupant = {_, Monitor}} = S) ->
    {noreply, ended(S)};
handle_info(Message, #stream{waits = Waits} = S) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Settled} -> {noreply, S#stream{waits = Settled}};
        {dropped, Dropped} -> {noreply, S#stream{waits = Dropped}};
%% No {begun, ...}: the stream answers a read in the step it serves
%% it and begins none, so a flush never finds one begun.
        %% A late message of a monitor or alias already released.
        unknown -> {noreply, S}
    end.

%% ---------------------------------------------------------------------------
%% The occupant
%% ---------------------------------------------------------------------------

free(#stream{occupant = none, buffer = Buffer}) -> byte_size(Buffer) < ?ERX_P9_IO_MAX;
free(#stream{}) -> false.

%% An occupant that has ended has a 'DOWN' on its way, which the runtime
%% delivers for every monitor of a process that ends; it is taken here, so the
%% release is in the buffer before the next occupant can write.
take_ended(#stream{occupant = {Pid, Monitor}} = S) ->
    case erlang:is_process_alive(Pid) of
        true -> S;
        false -> receive {'DOWN', Monitor, process, Pid, _} -> ended(S) end
    end;
take_ended(S) ->
    S.

%% The occupant has ended: its write waiting, if any, has no caller left and
%% is dropped, and release follows what it wrote.
ended(#stream{buffer = Buffer} = S) ->
    Release = erx_input_codec:encode(release),
    serve(S#stream{occupant = none, pending = none, buffer = <<Buffer/binary, Release/binary>>}).

%% ---------------------------------------------------------------------------
%% Writes and reads
%% ---------------------------------------------------------------------------

%% The occupant's write: taken now if it fits, else held until reads make room.
offer(From, Bytes, #stream{buffer = Buffer} = S)
  when byte_size(Buffer) + byte_size(Bytes) =< ?ERX_P9_IO_MAX ->
    gen_server:reply(From, ok),
    serve(S#stream{buffer = <<Buffer/binary, Bytes/binary>>});
offer(From, Bytes, S) ->
    S#stream{pending = {From, Bytes}}.

%% Answers the waiting reads in their order, each with the whole records its
%% count holds, while the buffer holds records, then takes the write waiting
%% if the room the reads made fits it.
serve(#stream{buffer = Buffer, waits = Waits} = S) when Buffer =/= <<>> ->
    case [{Wait, Count} || {Wait, {read, Count}, waiting} <- erx_fs_waits:list(Waits)] of
        [{Wait, Count} | _] ->
            Size = min(Count - Count rem erx_input_codec:size(), byte_size(Buffer)),
            <<Taken:Size/binary, Rest/binary>> = Buffer,
            serve(S#stream{buffer = Rest, waits = erx_fs_waits:answer(Wait, {ok, Taken}, Waits)});
        [] ->
            retry(S)
    end;
serve(S) ->
    retry(S).

retry(#stream{pending = {From, Bytes}, buffer = Buffer} = S)
  when byte_size(Buffer) + byte_size(Bytes) =< ?ERX_P9_IO_MAX ->
    offer(From, Bytes, S#stream{pending = none});
retry(S) ->
    S.
