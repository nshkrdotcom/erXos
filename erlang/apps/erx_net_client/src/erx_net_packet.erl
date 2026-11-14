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
into a buffer of that size: one that does not end there is cut at it, and one over
`packet_size`, its newline included, is `emsgsize`. A length mode's packet may be up to
`packet_size` bytes; with `packet_size` 0 the bound is 64 MiB, as stock's socket backend
sets it (gen_tcp_socket's default `packet_size`), so a packet never needs more than the
socket process may be granted.
""".

-export([decode/3, encode/2]).

-export_type([type/0, limits/0]).

-doc "A framed packet mode: a length header of 1, 2 or 4 bytes, or a line.".
-type type() :: 1 | 2 | 4 | line.

-doc "The socket's `packet_size` (0 for none) and `buffer`.".
-type limits() :: #{packet_size := non_neg_integer(), buffer := pos_integer()}.

%% The longest packet a length mode takes when `packet_size` is 0, and the most a socket
%% process holds (erx_gen_tcp_core's ?MAX_RECV).
-define(MAX_PACKET, 67108864).

-doc """
The first packet of `Bytes` and the bytes after it; or `{more, Needed}`, `Needed` the
bytes the packet needs at least, all of it once a length header is whole; or `{error,
emsgsize}` for a packet over `packet_size`.
""".
-spec decode(type(), binary(), limits()) -> {ok, binary(), binary()} | {more, pos_integer()} | {error, emsgsize}.
decode(line, Bytes, #{packet_size := Size, buffer := Buffer}) ->
    Window = binary:part(Bytes, 0, min(byte_size(Bytes), Buffer)),
    case erlang:decode_packet(line, Window, [{packet_size, Size}, {line_length, Buffer}]) of
        {ok, Line, _} -> {ok, Line, binary:part(Bytes, byte_size(Line), byte_size(Bytes) - byte_size(Line))};
        {more, _} -> {more, byte_size(Bytes) + 1};
        {error, _} -> {error, emsgsize}
    end;
decode(Header, Bytes, #{packet_size := Size}) ->
    Limit = case Size of
                0 -> ?MAX_PACKET;
                _ -> min(Size, ?MAX_PACKET)
            end,
    case erlang:decode_packet(Header, Bytes, [{packet_size, Limit}]) of
        {ok, Packet, Rest} -> {ok, Packet, Rest};
        {more, undefined} -> {more, byte_size(Bytes) + 1};
        {more, Needed} -> {more, Needed};
        {error, _} -> {error, emsgsize}
    end.

-doc """
`Data` as a send in `Type` puts it on the stream: after a header of its length in a
length mode, the length's low bits as stock writes them; unchanged in line mode.
""".
-spec encode(type(), binary()) -> binary().
encode(line, Data) ->
    Data;
encode(Header, Data) ->
    <<(byte_size(Data)):(Header * 8), Data/binary>>.
