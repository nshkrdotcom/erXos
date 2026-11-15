%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_draw).
-moduledoc """
Plan 9's draw messages for an Erlang client (docs/design-display.md,
"Erlang clients"). `open/1` starts a draw connection, `erx_draw_conn`, on a
window the caller opened with `erx_win:open/2`; the connection ends with
the caller, the window's holder, as the window does.

Each call encodes one message with the generated encoder, `erx_draw_codec`,
into the handle's batch, and the batch goes to the connection as one write
at `flush/1`, at `read/3` and `resized/1`, and whenever the next message
would take it past one write's most, the file protocol's payload of
64 KiB. A call that hands over a batch answers what the connection did
with it, and either failure drops the batch and the call's own message
from `Draw`:

* `{error, Errno, Draw}`: the connection refused the batch and applied
  none of it, and goes on as it was. A message too large for one write is
  refused so, without handing anything over, and only it is dropped. A
  connection that has ended answers `ebadf`.
* `{incomplete, Errno, Draw}`: the connection planned the batch and
  applied it, but an operation of it failed, for want of memory or in a
  present (`erx_draw_conn`, Failures after the plan).

A call that hands over nothing answers `{ok, Draw}`.

Images are named by ids, as draw(3) names them: `alloc/4` takes the next
id the handle has not used, and image 0 is the window's. The calls are the
messages' own fields, with libdraw's conventions where draw(3) leaves a
field to the caller: `draw/6` aligns the source and the mask at the same
point, `line/6` draws square ends with the source aligned with the
destination, a replicated image of `alloc/4` clips nowhere, and `load/4`
sends pixels too many for one write in bands of whole rows, each band a
`y` of its own, as libdraw's `loadimage` does, so a band that fails leaves
the bands before it loaded. `message/2` sends any other message of
`abi/formats/draw.txt` as `erx_draw_codec` writes it.
""".

-export([open/1, open/2, alloc/4, free/2, draw/6, line/6, load/4, message/2, flush/1, read/3, resized/1]).
-export_type([draw/0, options/0, alloc_options/0, result/0]).

-include("generated/erx_abi.hrl").

%% draw(3)'s colour meaning "do not fill", and libdraw's line end Endsquare.
-define(DNOFILL, 16#FFFFFF00).
-define(ENDSQUARE, 0).

-type image_id() :: erx_draw_codec:image_id().
-type point() :: erx_draw_codec:point().
-type rect() :: erx_draw_codec:rect().

-doc "What `open/2` takes: `quota`, the connection's pixel quota in bytes, else 64 MiB.".
-type options() :: #{quota => non_neg_integer()}.
-doc "What `alloc/4` takes: `color`, the RGBA fill, else none, and `repl`, else false.".
-type alloc_options() :: #{color => 0..16#ffffffff, repl => boolean()}.

-doc "A draw connection and the messages not yet handed to it; its fields are this module's.".
-opaque draw() :: #{conn := pid(),
                    batch := [binary()],          % the encoded messages, newest first
                    bytes := non_neg_integer(),   % their size
                    next := pos_integer()}.       % the next image id alloc/4 takes
-doc "A call's answer: the handle, or what failed of a batch it handed over (above).".
-type result() :: {ok, draw()} | {error, atom(), draw()} | {incomplete, atom(), draw()}.

-doc "Starts a draw connection on `Window` with the default quota.".
-spec open(erx_win:window()) -> {ok, draw()} | {error, atom()}.
open(Window) ->
    open(Window, #{}).

-doc """
Starts a draw connection on `Window`, a window the caller opened, that ends
with the caller; `{error, Errno}` as `erx_draw_conn:start/1` answers it.
""".
-spec open(erx_win:window(), options()) -> {ok, draw()} | {error, atom()}.
open(Window, Options) when is_map(Options) ->
    case erx_draw_conn:start((maps:with([quota], Options))#{window => Window}) of
        {ok, Conn} -> {ok, #{conn => Conn, batch => [], bytes => 0, next => 1}};
        {error, _} = Failed -> Failed
    end.

-doc """
`b`: a new image over `R` of channel `Chan`, filled with `color` unless it
is absent, and replicated when `repl` is set; answers its id.
""".
-spec alloc(draw(), rect(), 0..16#ffffffff, alloc_options()) ->
          {ok, image_id(), draw()} | {error, atom(), draw()} | {incomplete, atom(), draw()}.
alloc(#{next := Id} = Draw, R, Chan, Options) when is_map(Options) ->
    Repl = maps:get(repl, Options, false),
    Clipr = case Repl of
                true -> erx_draw_core:plane();
                false -> R
            end,
    Alloc = {alloc, Id, 0, 0, Chan, flag(Repl), R, Clipr, maps:get(color, Options, ?DNOFILL)},
    case message(Draw#{next := Id + 1}, Alloc) of
        {ok, Next} -> {ok, Id, Next};
        {error, _, _} = Refused -> Refused;
        {incomplete, _, _} = Failed -> Failed
    end.

-doc "`f`: frees the image `Id`.".
-spec free(draw(), image_id()) -> result().
free(Draw, Id) ->
    message(Draw, {free, Id}).

-doc "`d`: composes `Src` through `Mask` onto `R` of `Dst`, both aligned with `R`'s corner at `P`.".
-spec draw(draw(), image_id(), rect(), image_id(), image_id(), point()) -> result().
draw(Draw, Dst, R, Src, Mask, P) ->
    message(Draw, {draw, Dst, Src, Mask, R, P, P}).

-doc "`L`: a line from `P0` to `P1`, 1 + 2 * `Thick` wide with square ends, from `Src` where it lies.".
-spec line(draw(), image_id(), point(), point(), non_neg_integer(), image_id()) -> result().
line(Draw, Dst, P0, P1, Thick, Src) ->
    message(Draw, {line, Dst, P0, P1, ?ENDSQUARE, ?ENDSQUARE, Thick, Src, P0}).

-doc """
`y`: replaces the pixels of `R` of the image `Id` with `Pixels`, rows as
draw(3) lays them out, in bands of as many whole rows as one write holds.
""".
-spec load(draw(), image_id(), rect(), binary()) -> result().
load(Draw, Id, {_, Y0, _, Y1} = R, Pixels) ->
    Rows = Y1 - Y0,
    case Rows > 0 andalso byte_size(Pixels) rem Rows =:= 0 of
        true ->
            Row = byte_size(Pixels) div Rows,
            Header = byte_size(erx_draw_codec:encode({load, Id, R, <<>>})),
            messages(Draw, bands(Id, R, Pixels, Row, band_rows(Row, Header)));
        false ->
            %% Pixels that are no whole rows of R: the connection refuses them.
            message(Draw, {load, Id, R, Pixels})
    end.

%% The rows of Row bytes a y of Header bytes carries in one write: at least one,
%% so a row longer than one write goes alone and message/2 refuses it; rows of
%% no bytes go one write's worth of rows at a time.
band_rows(0, _Header) -> ?ERX_P9_IO_MAX;
band_rows(Row, Header) -> max(1, (?ERX_P9_IO_MAX - Header) div Row).

%% The y messages of R's rows, Band rows of Row bytes each at a time.
bands(Id, {_, Y0, _, Y1} = R, Pixels, _Row, Band) when Y1 - Y0 =< Band ->
    [{load, Id, R, Pixels}];
bands(Id, {X0, Y0, X1, Y1}, Pixels, Row, Band) ->
    <<First:(Band * Row)/binary, Rest/binary>> = Pixels,
    [{load, Id, {X0, Y0, X1, Y0 + Band}, First} | bands(Id, {X0, Y0 + Band, X1, Y1}, Rest, Row, Band)].

-doc """
Adds `Msg` to the batch, handing the batch over first when `Msg` would take
it past one write; a message larger than one write is refused with `einval`.
""".
-spec message(draw(), erx_draw_codec:msg()) -> result().
message(#{batch := Batch, bytes := Bytes} = Draw, Msg) ->
    Encoded = erx_draw_codec:encode(Msg),
    Size = byte_size(Encoded),
    if
        Size > ?ERX_P9_IO_MAX ->
            {error, einval, Draw};
        Bytes + Size > ?ERX_P9_IO_MAX ->
            maybe
                {ok, Sent} ?= hand_over(Draw),
                {ok, Sent#{batch := [Encoded], bytes := Size}}
            end;
        true ->
            {ok, Draw#{batch := [Encoded | Batch], bytes := Bytes + Size}}
    end.

%% Each of Msgs in turn, up to the first that fails.
messages(Draw, []) ->
    {ok, Draw};
messages(Draw, [Msg | Rest]) ->
    maybe
        {ok, Next} ?= message(Draw, Msg),
        messages(Next, Rest)
    end.

-doc "`v`: hands the batch over and presents what it changed in the window.".
-spec flush(draw()) -> result().
flush(Draw) ->
    maybe
        {ok, Flushing} ?= message(Draw, flush),
        hand_over(Flushing)
    end.

-doc "`r`: the pixels of `R` of the image `Id`, rows as `load/4` takes them.".
-spec read(draw(), image_id(), rect()) ->
          {ok, binary(), draw()} | {error, atom(), draw()} | {incomplete, atom(), draw()}.
read(#{conn := Conn} = Draw, Id, R) ->
    maybe
        {ok, Reading} ?= message(Draw, {read, Id, R}),
        {ok, Sent} ?= hand_over(Reading),
        case read_all(Conn, []) of
            {ok, Pixels} -> {ok, Pixels, Sent};
            {error, ebadf} -> {error, ebadf, Sent}
        end
    end.

-doc """
After an `r` record of the window's `mouse`: hands the batch over, then has
the connection make image 0 anew at the window's new size.
""".
-spec resized(draw()) -> result().
resized(#{conn := Conn} = Draw) ->
    maybe
        {ok, Sent} ?= hand_over(Draw),
        case erx_draw_conn:resized(Conn) of
            ok -> {ok, Sent};
            {error, Errno} -> {error, Errno, Sent}
        end
    end.

%% The batch as one write, after which the handle holds none.
hand_over(#{batch := []} = Draw) ->
    {ok, Draw};
hand_over(#{conn := Conn, batch := Batch} = Draw) ->
    Empty = Draw#{batch := [], bytes := 0},
    case erx_draw_conn:write(Conn, iolist_to_binary(lists:reverse(Batch))) of
        ok -> {ok, Empty};
        {error, Errno} -> {error, Errno, Empty};
        {incomplete, Errno} -> {incomplete, Errno, Empty}
    end.

%% Every byte the last r left, one read at a time.
read_all(Conn, Parts) ->
    case erx_draw_conn:read(Conn, ?ERX_P9_IO_MAX) of
        {ok, <<>>} -> {ok, iolist_to_binary(lists:reverse(Parts))};
        {ok, Part} -> read_all(Conn, [Part | Parts]);
        {error, ebadf} = Ended -> Ended
    end.

flag(true) -> 1;
flag(false) -> 0.
