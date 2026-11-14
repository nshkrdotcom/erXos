%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_packet).
-moduledoc """
The packet framing of a TCP socket process (docs/design-network-stack.md, "The socket
process"): a pure function from the bytes a socket holds to its next packet, as stock's
inet driver frames the stream for `{packet, 1 | 2 | 4 | line}`, and the header a send in
a length mode gets. The bytes are the peer's, so the framing is ERTS's own
erlang:decode_packet/3 with the socket's limits, and its one error, a packet over
`packet_size`, is `emsgsize`, as stock's is.

A line is looked for in the first `buffer` bytes only, since stock's driver reads a line
into a buffer of that size: one that does not end there is cut at it, and one longer
than `longest`, its newline included, is `emsgsize`. A length mode's packet may be up to
`longest` bytes. `longest` is the socket's `packet_size` as erx_gen_tcp_core bounds it,
never 0.

A packet that needs more bytes is `{more, Wait}`, `Wait` what can change the answer, so
the caller frames again only then: a length mode's `{length, N}`, nothing until `N` bytes
are held; a line's `{line, N}`, nothing until a newline arrives or `N` bytes are held,
enough to cut the line at the buffer or find it too long.
""".

-export([decode/3, arrived/2, encode/2]).

-export_type([type/0, limits/0, wait/0]).

-doc "A framed packet mode: a length header of 1, 2 or 4 bytes, or a line.".
-type type() :: 1 | 2 | 4 | line.

-doc "The longest packet the socket takes and its `buffer`.".
-type limits() :: #{longest := pos_integer(), buffer := pos_integer()}.

-doc "What a packet in progress waits for: see the module's documentation.".
-type wait() :: {length | line, pos_integer()}.

-doc """
The first packet of `Bytes` and the bytes after it; or `{more, Wait}` while it needs more
bytes; or `{error, emsgsize}` for a packet longer than `longest`.
""".
-spec decode(type(), binary(), limits()) -> {ok, binary(), binary()} | {more, wait()} | {error, emsgsize}.
decode(line, Bytes, #{longest := Longest, buffer := Buffer}) ->
    Window = binary:part(Bytes, 0, min(byte_size(Bytes), Buffer)),
    case erlang:decode_packet(line, Window, [{packet_size, Longest}, {line_length, Buffer}]) of
        {ok, Line, _} -> {ok, Line, binary:part(Bytes, byte_size(Line), byte_size(Bytes) - byte_size(Line))};
        {more, _} -> {more, {line, min(Buffer, Longest + 1)}};
        {error, _} -> {error, emsgsize}
    end;
decode(Header, Bytes, #{longest := Longest}) ->
    case erlang:decode_packet(Header, Bytes, [{packet_size, Longest}]) of
        {ok, Packet, Rest} -> {ok, Packet, Rest};
        {more, undefined} -> {more, {length, byte_size(Bytes) + 1}};
        {more, Needed} -> {more, {length, Needed}};
        {error, _} -> {error, emsgsize}
    end.

-doc """
`Wait` once `Pieces` arrive: `none` when a waiting line's newline is among them, since the
line can be framed then; `Wait` otherwise. So each piece is looked at once, as it arrives.
""".
-spec arrived(wait(), [binary()]) -> wait() | none.
arrived({line, _} = Wait, Pieces) ->
    case lists:any(fun(Piece) -> binary:match(Piece, <<"\n">>) =/= nomatch end, Pieces) of
        true -> none;
        false -> Wait
    end;
arrived({length, _} = Wait, _Pieces) ->
    Wait.

-doc """
`Data` as a send in `Type` puts it on the stream: after a header of its length in a
length mode, the length's low bits as stock writes them; unchanged in line mode.
""".
-spec encode(type(), binary()) -> binary().
encode(line, Data) ->
    Data;
encode(Header, Data) ->
    <<(byte_size(Data)):(Header * 8), Data/binary>>.
