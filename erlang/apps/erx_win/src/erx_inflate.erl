%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inflate).
-moduledoc """
Inflate, in Erlang, for the PNG reader erx_png (docs/design-display.md,
"The widget server"): a zlib stream (RFC 1950) around deflate data (RFC
1951), read from untrusted bytes, so that no NIF, ERTS's `zlib` included,
parses a client's picture.

The stream is a two-byte header, deflate blocks, and the Adler-32 of the
data. The header must name deflate with a window of at most 32 KiB and no
preset dictionary. A block is stored, or coded with the fixed Huffman
codes or with codes its own header describes. Codes are decoded as Mark
Adler's puff does, one bit at a time over the count of codes of each
length; a code-length set that is over-subscribed is refused, and an
incomplete one too unless, as zlib allows, its longest code has one bit,
or it is a distance set with no codes at all. A back-reference may reach
any byte already produced, as zlib's uncompress lets it, and no further.

The output never passes the limit the caller gives: the stream is refused
the moment a literal, a copy or a stored block would take it past. Every
loop reads at least one bit of input for each step, a block header reads
at most 316 code lengths, and decoding one code reads at most 15 bits, so
the work is bounded by the input and the limit, and nothing recurses but
in tail position.
""".
-export([zlib/2]).
-export_type([reason/0]).

-doc """
Why a stream was refused: `header`, a header that is not deflate with a
32 KiB window or less and no dictionary; `block`, a block of the reserved
type or a stored block whose length is not confirmed by its complement;
`codes`, a block's code lengths that describe no usable code; `symbol`, a
code that is no symbol of its set, or one deflate reserves; `distance`, a
back-reference before the first byte; `limit`, output past the caller's
limit; `truncated`, input that ends before the stream does; and `check`, an
Adler-32 that does not match the data.
""".
-type reason() :: header | block | codes | symbol | distance | limit | truncated | check.

%% The input as a bit reader: bits not yet used, low bit first, how many
%% they are, and the bytes after them.
-type reader() :: {Hold :: non_neg_integer(), Have :: non_neg_integer(), binary()}.

%% A Huffman code as puff builds one: the number of codes of each length
%% 1..15, and the symbols in canonical order, shortest code first.
-type code() :: {Counts :: tuple(), Symbols :: tuple()}.

-define(MAX_BITS, 15).

-doc """
The data of the zlib stream at the start of Bytes, at most Limit bytes of
it, and the bytes after the stream; or the reason the stream is refused.
""".
-spec zlib(binary(), non_neg_integer()) -> {ok, Data :: binary(), Rest :: binary()} | {error, reason()}.
zlib(Bytes, Limit) when is_binary(Bytes), is_integer(Limit), Limit >= 0 ->
    try stream(Bytes, Limit) of
        {Data, Rest} -> {ok, Data, Rest}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

fail(Reason) -> throw({?MODULE, Reason}).

%% RFC 1950: CMF names the method, 8, and the window, 2^(CINFO+8); FLG's
%% check bits make the pair a multiple of 31, and its FDICT bit asks for a
%% preset dictionary, which no PNG uses.
stream(<<CMF, FLG, Deflate/binary>>, Limit)
  when CMF band 16#0f =:= 8, CMF bsr 4 =< 7, (CMF * 256 + FLG) rem 31 =:= 0, FLG band 16#20 =:= 0 ->
    {Data, Bits} = blocks({0, 0, Deflate}, <<>>, Limit),
    case align(Bits) of
        <<Adler:32, Rest/binary>> -> check(erlang:adler32(Data) =:= Adler, check), {Data, Rest};
        _ -> fail(truncated)
    end;
stream(<<_, _, _/binary>>, _Limit) ->
    fail(header);
stream(_, _Limit) ->
    fail(truncated).

check(true, _Reason) -> ok;
check(false, Reason) -> fail(Reason).

%% RFC 1951 3.2.3: each block opens with BFINAL and BTYPE.
blocks(Bits0, Out0, Limit) ->
    {Final, Bits1} = bits(1, Bits0),
    {Type, Bits2} = bits(2, Bits1),
    {Out, Bits} = block(Type, Bits2, Out0, Limit),
    case Final of
        1 -> {Out, Bits};
        0 -> blocks(Bits, Out, Limit)
    end.

%% A stored block: from the next byte boundary, LEN, its complement NLEN,
%% and LEN bytes as they are.
block(0, Bits, Out, Limit) ->
    case align(Bits) of
        <<Length:16/little, Complement:16/little, Rest/binary>> ->
            check(Complement =:= Length bxor 16#ffff, block),
            case Rest of
                <<Stored:Length/binary, After/binary>> -> {put(Out, Stored, Limit), {0, 0, After}};
                _ -> fail(truncated)
            end;
        _ ->
            fail(truncated)
    end;
block(1, Bits, Out, Limit) ->
    codes(fixed_literal_code(), fixed_distance_code(), Bits, Out, Limit);
block(2, Bits0, Out, Limit) ->
    {LitCode, DistCode, Bits} = dynamic(Bits0),
    codes(LitCode, DistCode, Bits, Out, Limit);
block(3, _Bits, _Out, _Limit) ->
    fail(block).

%% RFC 1951 3.2.6's fixed codes, in the form huffman/2 builds: literals and
%% lengths 0-143 take 8 bits, 144-255 9, 256-279 7 and 280-287 8; the 32
%% distances take 5 bits each. They are written out rather than built, so
%% that a stream of many short fixed blocks does not build them for each.
fixed_literal_code() ->
    {{0, 0, 0, 0, 0, 0, 24, 152, 112, 0, 0, 0, 0, 0, 0},
     list_to_tuple(lists:seq(256, 279) ++ lists:seq(0, 143) ++ lists:seq(280, 287) ++ lists:seq(144, 255))}.

fixed_distance_code() ->
    {{0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, list_to_tuple(lists:seq(0, 31))}.

%% RFC 1951 3.2.7: HLIT, HDIST and HCLEN, the code-length code's lengths
%% in their fixed order, then the lengths of both codes in one run, coded
%% with it, where a repeat may cross from one code into the other.
dynamic(Bits0) ->
    {HLit, Bits1} = bits(5, Bits0),
    {HDist, Bits2} = bits(5, Bits1),
    {HCLen, Bits3} = bits(4, Bits2),
    NLengths = HLit + 257,
    NDistances = HDist + 1,
    check(NLengths =< 286 andalso NDistances =< 30, codes),
    {Ordered, Bits4} = fields(HCLen + 4, 3, Bits3, []),
    Order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15],
    Placed = maps:from_list(lists:zip(lists:sublist(Order, length(Ordered)), Ordered)),
    CodeLengthCode = huffman([maps:get(Symbol, Placed, 0) || Symbol <- lists:seq(0, 18)], code_lengths),
    {All, Bits} = code_lengths(CodeLengthCode, NLengths + NDistances, Bits4, []),
    {LitLengths, DistLengths} = lists:split(NLengths, All),
    check(lists:nth(257, LitLengths) > 0, codes),
    {huffman(LitLengths, literals), huffman(DistLengths, distances), Bits}.

%% Count fields of Width bits each, in order.
fields(0, _Width, Bits, Acc) ->
    {lists:reverse(Acc), Bits};
fields(Count, Width, Bits0, Acc) ->
    {Value, Bits} = bits(Width, Bits0),
    fields(Count - 1, Width, Bits, [Value | Acc]).

%% Left lengths are still to come; Acc holds those read, the latest first.
%% 16 repeats the latest 3-6 times, 17 and 18 give 3-10 and 11-138 zeros;
%% no repeat may pass the lengths the header counts.
code_lengths(_Code, 0, Bits, Acc) ->
    {lists:reverse(Acc), Bits};
code_lengths(Code, Left, Bits0, Acc) ->
    {Symbol, Bits1} = decode(Code, Bits0),
    {Repeat, Bits} =
        case {Symbol, Acc} of
            {Length, _} when Length < 16 -> {[Length], Bits1};
            {16, [Latest | _]} -> repeat(Latest, 3, 2, Bits1);
            {16, []} -> fail(codes);
            {17, _} -> repeat(0, 3, 3, Bits1);
            {18, _} -> repeat(0, 11, 7, Bits1)
        end,
    Count = length(Repeat),
    check(Count =< Left, codes),
    code_lengths(Code, Left - Count, Bits, Repeat ++ Acc).

repeat(Length, Base, Width, Bits0) ->
    {Extra, Bits} = bits(Width, Bits0),
    {lists:duplicate(Base + Extra, Length), Bits}.

%% Literals, back-references and the end of block, 256, which ends the
%% loop. 286 and 287, which the fixed code has, are reserved, as are
%% distances 30 and 31.
codes(LitCode, DistCode, Bits0, Out, Limit) ->
    case decode(LitCode, Bits0) of
        {Literal, Bits} when Literal < 256 ->
            codes(LitCode, DistCode, Bits, put(Out, <<Literal>>, Limit), Limit);
        {256, Bits} ->
            {Out, Bits};
        {Symbol, Bits1} when Symbol =< 285 ->
            {Length, Bits2} = extra(Symbol - 257, length_bases(), length_extras(), Bits1),
            {Distance, Bits} =
                case decode(DistCode, Bits2) of
                    {DistanceSymbol, Bits3} when DistanceSymbol < 30 ->
                        extra(DistanceSymbol, distance_bases(), distance_extras(), Bits3);
                    _ ->
                        fail(symbol)
                end,
            check(Distance =< byte_size(Out), distance),
            codes(LitCode, DistCode, Bits, put(Out, copy(Out, Distance, Length), Limit), Limit);
        _ ->
            fail(symbol)
    end.

%% RFC 1951 3.2.5: a length or distance is a base and extra bits.
extra(Index, Bases, Extras, Bits0) ->
    {Extra, Bits} = bits(element(Index + 1, Extras), Bits0),
    {element(Index + 1, Bases) + Extra, Bits}.

length_bases() ->
    {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227,
     258}.

length_extras() ->
    {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}.

distance_bases() ->
    {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
     6145, 8193, 12289, 16385, 24577}.

distance_extras() ->
    {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}.

%% Length bytes from Distance bytes before the end of Out; a copy nearer
%% than its length repeats its last Distance bytes, as copying byte by
%% byte would.
copy(Out, Distance, Length) when Length =< Distance ->
    binary:part(Out, byte_size(Out) - Distance, Length);
copy(Out, Distance, Length) ->
    Pattern = binary:part(Out, byte_size(Out) - Distance, Distance),
    binary:part(binary:copy(Pattern, Length div Distance + 1), 0, Length).

%% The one place output grows, and so the one place the limit is checked.
put(Out, Bytes, Limit) ->
    check(byte_size(Out) + byte_size(Bytes) =< Limit, limit),
    <<Out/binary, Bytes/binary>>.

%% The canonical code of Lengths, one length a symbol and 0 for a symbol
%% with no code, as puff's construct builds it. Kind is how zlib's
%% inflate_table judges a set that leaves codes unused.
-spec huffman([0..?MAX_BITS], code_lengths | literals | distances) -> code().
huffman(Lengths, Kind) ->
    Coded = lists:sort([{Length, Symbol} || {Symbol, Length} <- lists:enumerate(0, Lengths), Length > 0]),
    Tally = lists:foldl(fun({Length, _}, Seen) -> maps:update_with(Length, fun(N) -> N + 1 end, 1, Seen) end,
                        #{}, Coded),
    Counts = [maps:get(Length, Tally, 0) || Length <- lists:seq(1, ?MAX_BITS)],
    Longest = lists:max([0 | maps:keys(Tally)]),
    check(usable(unused(Counts), Longest, Kind), codes),
    {list_to_tuple(Counts), list_to_tuple([Symbol || {_, Symbol} <- Coded])}.

%% The codes of ?MAX_BITS bits a set leaves unused, negative when it
%% claims more than there are.
unused(Counts) ->
    lists:foldl(fun(_Count, Left) when Left < 0 -> Left;
                   (Count, Left) -> Left * 2 - Count
                end, 1, Counts).

%% zlib's inflate_table: a set that claims more codes than there are is
%% refused; one that leaves codes unused is refused too, unless its longest
%% code has one bit and it is not the code-length code, or it is a distance
%% set with no codes at all. A code that reaches an unused code is then no
%% symbol (decode/2).
usable(Left, _Longest, _Kind) when Left < 0 -> false;
usable(0, _Longest, _Kind) -> true;
usable(_Left, 0, distances) -> true;
usable(_Left, 1, Kind) -> Kind =/= code_lengths;
usable(_Left, _Longest, _Kind) -> false.

%% One symbol, read a bit at a time, as puff's decode reads it: Code is the
%% bits so far, First the first code of their length and Index the place of
%% its symbol. A code that runs past ?MAX_BITS is no symbol.
-spec decode(code(), reader()) -> {non_neg_integer(), reader()}.
decode({Counts, Symbols}, Bits) ->
    decode(Counts, Symbols, 1, 0, 0, 0, Bits).

decode(_Counts, _Symbols, Length, _Code, _First, _Index, _Bits) when Length > ?MAX_BITS ->
    fail(symbol);
decode(Counts, Symbols, Length, Code0, First, Index, Bits0) ->
    {Bit, Bits} = bits(1, Bits0),
    Code = Code0 bor Bit,
    Count = element(Length, Counts),
    case Code < First + Count of
        true -> {element(Index + Code - First + 1, Symbols), Bits};
        false -> decode(Counts, Symbols, Length + 1, Code bsl 1, (First + Count) bsl 1, Index + Count, Bits)
    end.

%% N bits, the first read in the lowest place, as deflate packs them.
-spec bits(0..16, reader()) -> {non_neg_integer(), reader()}.
bits(N, {Hold, Have, Bytes}) when Have >= N ->
    {Hold band ((1 bsl N) - 1), {Hold bsr N, Have - N, Bytes}};
bits(N, {Hold, Have, <<Byte, Bytes/binary>>}) ->
    bits(N, {Hold bor (Byte bsl Have), Have + 8, Bytes});
bits(_N, _Bits) ->
    fail(truncated).

%% The bytes from the next byte boundary: the bits left of a partly used
%% byte are dropped and whole bytes still held are put back.
align({Hold, Have, Bytes}) ->
    Whole = Have - Have rem 8,
    <<(Hold bsr (Have rem 8)):Whole/little, Bytes/binary>>.
