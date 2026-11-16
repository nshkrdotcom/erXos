%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_window).
-moduledoc """
One window (docs/design-display.md, "The window process" and "The window
tree"): it serves the window's `ctl`, `mouse`, `kbd` and `label` files to
the tree's callbacks in `erx_winfs`, holds the window's pending input and
its last present, and is told its rectangle and state by `erx_winfs`.

**Waiting requests.** A read of `mouse` or `kbd` and a write of `ctl` wait
for an event, a record or a present, so the tree's callback hands them
here (docs/design-files.md, "Serving: the `erx_fs` behaviour", "Waiting
requests"), and this process is their keeper: it holds them in one
`erx_fs_waits` set, the window's only record of them, and answers each
once through it. The readers of a file and the writes still to present
are the set's requests of that kind in the order they arrived. A flush or
a clunk of a request not yet answered reaches the set, which answers a
read, or a write not yet presented, `EINTR`; a write whose present is in
flight is answered when the present is. The other files' reads and writes
are calls answered at once.

**ctl.** A read answers the display's channel descriptor. A write is one
`present` line, read by `erx_winctl:parse/1` and checked against the
client's pixel area: the offset a multiple of the page size, and the
buffer's bytes, `erx_chan:bytes(width, height, depth)`, ending at or
before the area's end.
Erlang's integers do not overflow, so the sums are exact whatever the
line's numbers. A line outside the grammar or the checks is `EINVAL`, a
grant without an area `ENXIO`, and neither is shown.

**Presents.** At most one is in flight to `erx_screen`, through
`erx_screen:present_request/2`, which returns at once; the write that
asked for it is marked begun and held until the answer, so the window
still takes input. On `ok` the buffer becomes the last present and the
write is answered; the screen's refusal answers the write with it, and
the screen's end with `EIO`. A write that arrives while one is in flight
waits behind it. A
request to present again (`{erx_screen, present_again}`) presents the last
buffer whole, as if the client had, with no write to answer: it waits for
the present in flight to be answered, goes before waiting writes, and does
nothing while there is no last buffer.

**Input.** A pointer event is a 49-byte `mouse` record
`m%11d %11d %11d %11d `, x, y, buttons and milliseconds. A key's down
is a `kbd` record `k` and its up a `K`, each followed by the set of
runes held, in UTF-8, and a NUL: the unshifted runes of the keys whose
downs the window received and whose ups it has not, with the modifiers
held on the display, the event's `Mods`. A down or a repeat that types a
rune is then a `c` record, the rune and a NUL. A wheel step is not
encoded here. Each queue holds at most 4 KiB of
records; past that the oldest is dropped and counted. A change of the
window's size sets `resized`, which the next `mouse` read answers with an
`r` record at the last pointer position. A read takes one record, waits
for one when there is none, and is `EINVAL`, leaving the record, when its
count cannot hold the one it would take.

**label.** Read at any offset; a write replaces the label, and one at a
nonzero offset is `EINVAL`, which is erXos's choice: the label is one
line written whole.
""".

-behaviour(gen_server).

-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% A queue of records, its bytes and its count of dropped records.
-record(records, {queue = queue:new() :: queue:queue(binary()),
                  bytes = 0 :: non_neg_integer(),
                  dropped = 0 :: non_neg_integer()}).

-record(window, {id :: pos_integer(),
                 chan :: binary(),
                 depth :: pos_integer(),
                 area :: none | {term(), pos_integer()},
                 rect = none :: none | erx_wm:rect(),
                 state = hidden :: shown | hidden,
                 label = <<>> :: binary(),
                 %% The last present's buffer, or none.
                 buffer = none :: none | map(),
                 resized = false :: boolean(),
                 pointer = {0, 0, 0, 0} :: {integer(), integer(), integer(), integer()},
                 mouse = #records{} :: #records{},
                 kbd = #records{} :: #records{},
                 %% The unshifted rune of each key whose down the window received and
                 %% whose up it has not, or none for a key that has none.
                 keys = #{} :: #{non_neg_integer() => erx_wm:rune() | none},
                 %% The requests the window keeps (erx_fs_waits), each its own term: a
                 %% {read, mouse | kbd, Count}, or a ctl write checked into
                 %% {present, Present, Written}, Written the answer its write takes once
                 %% presented. A request refused in the step that takes it is held as it
                 %% came, for that step only.
                 waits = erx_fs_waits:new() :: erx_fs_waits:waits(),
                 %% The present in flight, its buffer and whose write it answers: the
                 %% begun write's request and its answer, or again. They are copied out of
                 %% the set, since a write whose grant has ended is dropped from it while
                 %% its present still makes the buffer the last one.
                 in_flight = none :: none | {gen_server:request_id(), map(),
                                             again | {erx_fs_waits:wait(), {ok, non_neg_integer(), non_neg_integer()}}},
                 again = false :: boolean()}).

-doc """
Starts window Id's process, linked to the caller, `erx_winfs`: Chan is the
display's channel descriptor and Depth its bits a pixel, Area the client's
pixel area and its bytes, or none.
""".
-spec start_link(#{id := pos_integer(), chan := binary(), depth := pos_integer(),
                   area := none | {term(), pos_integer()}}) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-doc false.
init(#{id := Id, chan := Chan, depth := Depth, area := Area}) ->
    {ok, #window{id = Id, chan = Chan, depth = Depth, area = Area}}.

-doc false.
handle_call({read, ctl, Offset, Count}, _From, #window{chan = Chan} = W) ->
    {reply, slice(<<Chan/binary, "\n">>, Offset, Count), W};
handle_call({read, wctl, Offset, Count}, _From, #window{rect = Rect, state = State} = W) ->
    Text = erx_wctl:format(case Rect of none -> {0, 0, 0, 0}; _ -> Rect end, State =:= shown, State),
    {reply, slice(Text, Offset, Count), W};
handle_call({read, label, Offset, Count}, _From, #window{label = Label} = W) ->
    {reply, slice(Label, Offset, Count), W};
handle_call({write, label, 0, Label}, _From, W) when is_binary(Label) ->
    {reply, ok, W#window{label = Label}};
handle_call(_Request, _From, W) ->
    {reply, {error, einval}, W}.

-doc false.
handle_cast({placed, Rect, State}, #window{rect = Old, resized = Resized} = W) ->
    Changed = Old =/= none andalso extent(Old) =/= extent(Rect),
    {noreply, serve(W#window{rect = Rect, state = State, resized = Resized orelse Changed})};
handle_cast({input, #{event := Event, at := At}}, W) ->
    {noreply, serve(encode(Event, At, W))};
handle_cast(_Request, W) ->
    {noreply, W}.

-doc false.
handle_info(?ERX_FS_WAIT(Wait, Request), W) ->
    {noreply, take(Wait, Request, W)};
handle_info({erx_screen, present_again}, #window{buffer = none} = W) ->
    {noreply, W};
handle_info({erx_screen, present_again}, W) ->
    {noreply, pump(W#window{again = true})};
handle_info(Message, #window{waits = Waits} = W) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Settled} -> {noreply, W#window{waits = Settled}};
        %% The one begun request is the write whose present is in flight, which the
        %% present's answer settles.
        {begun, _Wait, _Request, Flushing} -> {noreply, W#window{waits = Flushing}};
        {dropped, Dropped} -> {noreply, W#window{waits = Dropped}};
        unknown -> {noreply, screen_answer(Message, W)}
    end.

%% Waiting requests ------------------------------------------------------------

%% A request the tree's callback handed here: a read waits for a record and a checked
%% ctl write for its present; either is answered at once when it cannot wait. A mouse
%% record is one size, so a mouse read too short for it is refused here; a kbd record's
%% size varies with the keys held, so serve_records/2 measures the one a read takes.
take(Wait, {read, mouse, Count}, W) when Count < ?ERX_WINDOWS_MOUSE_RECORD ->
    refuse(Wait, {read, mouse, Count}, {error, einval}, W);
take(Wait, {read, File, _Count} = Read, W) when File =:= mouse; File =:= kbd ->
    serve(hold(Wait, Read, W));
take(Wait, {write, ctl, Offset, Line}, W) ->
    case check(Line, W) of
        {ok, Present} ->
            pump(hold(Wait, {present, Present, {ok, byte_size(Line), Offset}}, W));
        {error, Reason} = Refused ->
            _ = erx_log:debug(["erx_window ", integer_to_binary(W#window.id),
                               ": present refused: ", atom_to_binary(Reason)]),
            refuse(Wait, {write, ctl, Offset, Line}, Refused, W)
    end.

hold(Wait, Request, #window{waits = Waits} = W) ->
    W#window{waits = erx_fs_waits:hold(?ERX_FS_WAIT(Wait, Request), Waits)}.

%% A request answered in the step that takes it, through the set as every answer is.
refuse(Wait, Request, Refused, W) ->
    answer(Wait, Refused, hold(Wait, Request, W)).

answer(Wait, Result, #window{waits = Waits} = W) ->
    W#window{waits = erx_fs_waits:answer(Wait, Result, Waits)}.

%% The reads of File still waiting, each with its count, and the checked ctl writes,
%% each in the order it arrived.
readers(File, #window{waits = Waits}) ->
    [{Wait, Count} || {Wait, {read, Of, Count}, waiting} <- erx_fs_waits:list(Waits),
                      Of =:= File].

writes(#window{waits = Waits}) ->
    [{Wait, Present, Written} || {Wait, {present, Present, Written}, waiting} <- erx_fs_waits:list(Waits)].

%% ctl -----------------------------------------------------------------------

check(Line, #window{area = Area, depth = Depth}) ->
    case {erx_winctl:parse(Line), Area} of
        {{error, einval}, _} -> {error, einval};
        {{ok, _}, none} -> {error, enxio};
        {{ok, #{offset := Offset, width := Width, height := Height} = Present}, {_, Bytes}} ->
            Extent = erx_chan:bytes(Width, Height, Depth),
            case Offset rem ?ERX_PAGE_SIZE =:= 0 andalso Offset + Extent =< Bytes of
                true -> {ok, Present};
                false -> {error, einval}
            end
    end.

%% Sends the next present when none is in flight: a deferred present-again first,
%% then the oldest waiting write, marked begun before it is sent. A screen that
%% cannot be reached answers eio.
pump(#window{in_flight = none, again = true, buffer = Buffer} = W) when Buffer =/= none ->
    send(again, Buffer#{rects => []}, W#window{again = false});
pump(#window{in_flight = none, waits = Waits} = W) ->
    case writes(W) of
        [{Wait, Present, Written} | _] ->
            send({Wait, Written}, Present, W#window{waits = erx_fs_waits:began(Wait, Waits)});
        [] ->
            W#window{again = false}
    end;
pump(W) ->
    W.

send(Who, Present, #window{id = Id, area = {Area, _}} = W) ->
    case erx_screen:present_request(Id, Present#{area => Area}) of
        {ok, Request} ->
            W#window{in_flight = {Request, Present, Who}};
        {error, eio} = Refused ->
            pump(answer_write(Who, Refused, W))
    end.

%% The screen's answer to the present in flight; any other message is not the window's.
screen_answer(Message, #window{in_flight = {Request, Present, Who}} = W) ->
    case gen_server:check_response(Message, Request) of
        no_reply ->
            W;
        {reply, ok} ->
            pump(answer_write(Who, ok, W#window{in_flight = none, buffer = maps:without([rects], Present)}));
        {reply, {error, _} = Refused} ->
            pump(answer_write(Who, Refused, W#window{in_flight = none}));
        {error, {_Reason, _Screen}} ->
            pump(answer_write(Who, {error, eio}, W#window{in_flight = none}))
    end;
screen_answer(_Message, W) ->
    W.

%% A present's answer to the write that asked for it, which a present-again has not.
answer_write(again, _Reply, W) -> W;
answer_write({Wait, Written}, ok, W) -> answer(Wait, Written, W);
answer_write({Wait, _Written}, Refused, W) -> answer(Wait, Refused, W).

%% Input ---------------------------------------------------------------------

encode({pointer, X, Y, Buttons}, At, #window{mouse = Mouse} = W)
  when is_integer(X), is_integer(Y), is_integer(Buttons), is_integer(At) ->
    Msec = abs(At) rem 16#80000000,
    W#window{mouse = push(record($m, {X, Y, Buttons, Msec}), Mouse), pointer = {X, Y, Buttons, Msec}};
encode({key, down, Code, Typed, Unshifted, Mods}, _At, #window{keys = Keys} = W) ->
    Held = W#window{keys = Keys#{Code => Unshifted}},
    typed(Typed, held_record($k, Mods, Held));
encode({key, repeat, _Code, Typed, _Unshifted, _Mods}, _At, W) ->
    typed(Typed, W);
encode({key, up, Code, _Typed, _Unshifted, Mods}, _At, #window{keys = Keys} = W) ->
    held_record($K, Mods, W#window{keys = maps:remove(Code, Keys)});
encode(_Event, _At, W) ->
    W.

%% A k or K record: the runes of the keys held for the window with the modifiers held
%% on the display, each once, in UTF-8.
held_record(Kind, Mods, #window{keys = Keys, kbd = Kbd} = W) ->
    Runes = lists:usort([Rune || Rune <- maps:values(Keys), Rune =/= none] ++ Mods),
    W#window{kbd = push(<<Kind, (unicode:characters_to_binary(Runes))/binary, 0>>, Kbd)}.

typed(none, W) -> W;
typed(Rune, #window{kbd = Kbd} = W) -> W#window{kbd = push(<<$c, Rune/utf8, 0>>, Kbd)}.

record(Kind, {X, Y, Buttons, Msec}) ->
    W = ?ERX_WINDOWS_FIELD,
    iolist_to_binary(io_lib:format("~c~*B ~*B ~*B ~*B ", [Kind, W, X, W, Y, W, Buttons, W, Msec])).

push(Record, #records{queue = Queue, bytes = Bytes, dropped = Dropped} = Records) ->
    Size = byte_size(Record),
    case Bytes + Size > ?ERX_WINDOWS_QUEUE_BYTES of
        true ->
            {{value, Oldest}, Rest} = queue:out(Queue),
            push(Record, Records#records{queue = Rest, bytes = Bytes - byte_size(Oldest),
                                         dropped = Dropped + 1});
        false ->
            Records#records{queue = queue:in(Record, Queue), bytes = Bytes + Size}
    end.

%% Answers waiting readers while records are pending; a mouse reader takes the
%% resize record before any queued one.
serve(#window{resized = true, pointer = Pointer} = W) ->
    case readers(mouse, W) of
        [{Wait, _Count} | _] -> serve(answer(Wait, {ok, record($r, Pointer)}, W#window{resized = false}));
        [] -> serve_records(kbd, serve_records(mouse, W))
    end;
serve(W) ->
    serve_records(kbd, serve_records(mouse, W)).

%% The oldest reader of File takes the record at the head of its queue when its count
%% holds it, and otherwise fails with einval and leaves the record for the next read.
serve_records(File, W) ->
    #records{queue = Queue, bytes = Bytes} = Records = queue_of(File, W),
    case {queue:out(Queue), readers(File, W)} of
        {{{value, Record}, Rest}, [{Wait, Count} | _]} when byte_size(Record) =< Count ->
            Taken = Records#records{queue = Rest, bytes = Bytes - byte_size(Record)},
            serve_records(File, answer(Wait, {ok, Record}, with_queue(File, Taken, W)));
        {{{value, _Record}, _Rest}, [{Wait, _Count} | _]} ->
            serve_records(File, answer(Wait, {error, einval}, W));
        _ ->
            W
    end.

queue_of(mouse, #window{mouse = Mouse}) -> Mouse;
queue_of(kbd, #window{kbd = Kbd}) -> Kbd.

with_queue(mouse, Mouse, W) -> W#window{mouse = Mouse};
with_queue(kbd, Kbd, W) -> W#window{kbd = Kbd}.

%% Text files ----------------------------------------------------------------

slice(Text, Offset, _Count) when Offset >= byte_size(Text) ->
    {ok, <<>>};
slice(Text, Offset, Count) ->
    {ok, binary:part(Text, Offset, min(Count, byte_size(Text) - Offset))}.

extent({X0, Y0, X1, Y1}) -> {X1 - X0, Y1 - Y0}.
