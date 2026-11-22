%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_virtio_console_core).
-moduledoc """
The transmit side of the virtio-console line driver (docs/design-bluetooth.md,
"The line on QEMU `virt`"), as a pure state machine: which of the writes the
line hands the driver go into which buffers of the transmit queue, and which
write is answered when the device returns its buffers. erx_virtio_console
performs what it decides.

A write's bytes are cut into pieces of at most the queue's buffer size, kept in
the order they arrive, and each piece is posted as one buffer under a tag of
its own, a free entry of the queue, so at most the queue's size are in flight
and a post never finds the queue full. A write is answered once the device has
returned every one of its pieces, and writes are answered in the order they
were handed over, so the line hears `written` for a write only after every
byte before it has gone too.

The device returns buffers in any order it likes (virtio 1.2, section 2.7.8),
so nothing here assumes the order. Which tag a returned buffer carries is not
the device's to say: the device NIF's ring core answers each used element with
the tag of the chain it names and refuses an element that names no chain in
flight (erx_device_virtio_core.h, "complete"), so every tag `returned/2`
receives is one `posts/1` gave out and not yet returned.
""".

-export([new/2, write/3, posts/1, returned/2, idle/1]).

-export_type([state/0, tag/0]).

-type tag() :: non_neg_integer().

-record(core, {piece_max :: pos_integer(),
               %% The queue's entries no posted piece holds.
               free :: [tag()],
               %% The pieces not yet posted, oldest first, each with its write.
               queued = queue:new() :: queue:queue({reference(), binary()}),
               %% The piece each tag in flight carries, by its write.
               flight = #{} :: #{tag() => reference()},
               %% Each write not yet answered, with how many of its pieces the
               %% device has not returned, posted or not.
               left = #{} :: #{reference() => non_neg_integer()},
               %% The writes not yet answered, in the order they were handed over.
               order = queue:new() :: queue:queue(reference())}).

-opaque state() :: #core{}.

-doc """
The transmit side of a queue of Size entries, each buffer PieceMax bytes, with
nothing in flight.
""".
-spec new(pos_integer(), pos_integer()) -> state().
new(Size, PieceMax) when is_integer(Size), Size > 0, is_integer(PieceMax), PieceMax > 0 ->
    #core{piece_max = PieceMax, free = lists:seq(0, Size - 1)}.

-doc """
Takes the write Ref of Bytes. A write of no bytes has nothing for the device to
return, so it is answered as soon as every write before it is: the answers are
the writes now done, in order.
""".
-spec write(reference(), binary(), state()) -> {[reference()], state()}.
write(Ref, Bytes, C = #core{piece_max = Max, queued = Queued, left = Left, order = Order}) ->
    Pieces = pieces(Bytes, Max),
    answered(C#core{queued = lists:foldl(fun(Piece, Q) -> queue:in({Ref, Piece}, Q) end, Queued, Pieces),
                    left = Left#{Ref => length(Pieces)},
                    order = queue:in(Ref, Order)}).

-doc """
The pieces to post now, each under its tag, oldest first: as many as the queue
has free entries.
""".
-spec posts(state()) -> {[{tag(), binary()}], state()}.
posts(C) ->
    posts(C, []).

posts(C = #core{free = [Tag | Free], queued = Queued, flight = Flight}, Acc) ->
    case queue:out(Queued) of
        {{value, {Ref, Piece}}, Rest} ->
            posts(C#core{free = Free, queued = Rest, flight = Flight#{Tag => Ref}}, [{Tag, Piece} | Acc]);
        {empty, _} ->
            {lists:reverse(Acc), C}
    end;
posts(C = #core{free = []}, Acc) ->
    {lists:reverse(Acc), C}.

-doc """
The device has returned the buffers of Tags, each a tag in flight: their entries
are free again, and the answers are the writes now done, in order.
""".
-spec returned([tag()], state()) -> {[reference()], state()}.
returned(Tags, C) ->
    answered(lists:foldl(fun give_back/2, C, Tags)).

give_back(Tag, C = #core{free = Free, flight = Flight, left = Left}) ->
    {Ref, Rest} = maps:take(Tag, Flight),
    C#core{free = [Tag | Free], flight = Rest, left = Left#{Ref := maps:get(Ref, Left) - 1}}.

-doc "Whether no write waits for an answer.".
-spec idle(state()) -> boolean().
idle(#core{order = Order}) ->
    queue:is_empty(Order).

%% The writes at the head of the order whose every piece has come back.
answered(C) ->
    answered(C, []).

answered(C = #core{left = Left, order = Order}, Acc) ->
    case queue:peek(Order) of
        {value, Ref} when map_get(Ref, Left) =:= 0 ->
            answered(C#core{left = maps:remove(Ref, Left), order = queue:drop(Order)}, [Ref | Acc]);
        _ ->
            {lists:reverse(Acc), C}
    end.

pieces(<<>>, _Max) ->
    [];
pieces(Bytes, Max) when byte_size(Bytes) =< Max ->
    [Bytes];
pieces(Bytes, Max) ->
    <<Piece:Max/binary, Rest/binary>> = Bytes,
    [Piece | pieces(Rest, Max)].
