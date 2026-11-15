%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The cases of erx_inflate (docs/design-display.md, "Verification and
%% testing"): differential against stock OTP's zlib, which must accept the
%% same streams and yield the same bytes, over streams deflate writes at
%% every level and strategy and over mutations of them; the output limit;
%% and the header and trailer refusals.
-module(erx_inflate_tests).
-include_lib("eunit/include/eunit.hrl").
-export([agree/1]).

%% Far above anything the corpus inflates to, so the limit never decides.
-define(LIMIT, 1 bsl 24).

%% What each inflater makes of Stream: zlib's uncompress ignores bytes after
%% the stream, which erx_inflate returns.
agree(Stream) ->
    Stock = try zlib:uncompress(Stream) of
                Data -> {ok, Data}
            catch
                error:_ -> error
            end,
    Ours = case erx_inflate:zlib(Stream, ?LIMIT) of
               {ok, Inflated, _Rest} -> {ok, Inflated};
               {error, _Reason} -> error
           end,
    ?assertEqual(Stock, Ours).

corpus() ->
    rand:seed(exsss, {3, 5, 7}),
    Text = iolist_to_binary(lists:duplicate(300, <<"the window system draws what the client sends ">>)),
    Small = << <<(rand:uniform(4) + $a)>> || _ <- lists:seq(1, 70000) >>,
    [<<>>, <<"a">>, Text, Small, rand:bytes(70000), <<0:(100000 * 8)>>,
     binary:copy(<<1, 2, 3>>, 2000), rand:bytes(17)].

compress(Data, Level, Strategy) ->
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, Level, deflated, 15, 8, Strategy),
    Stream = iolist_to_binary(zlib:deflate(Z, Data, finish)),
    ok = zlib:deflateEnd(Z),
    zlib:close(Z),
    Stream.

streams() ->
    [compress(Data, Level, Strategy) || Data <- corpus(), Level <- [0, 1, 6, 9],
                                        Strategy <- [default, filtered, huffman_only, rle]].

differential_test() ->
    lists:foreach(fun agree/1, streams()).

%% Flipped bits, replaced bytes and cut ends: both refuse, or both yield
%% the same bytes.
mutation_test() ->
    rand:seed(exsss, {1, 2, 3}),
    Small = [Stream || Stream <- streams(), byte_size(Stream) < 4000],
    lists:foreach(fun(Stream) ->
                          lists:foreach(fun(_) -> agree(mutate(Stream)) end, lists:seq(1, 60))
                  end, Small).

mutate(Stream) ->
    Size = byte_size(Stream),
    At = rand:uniform(Size) - 1,
    <<Head:At/binary, Byte, Tail/binary>> = Stream,
    case rand:uniform(3) of
        1 -> <<Head/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1))), Tail/binary>>;
        2 -> <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>;
        3 -> Head
    end.

limit_test() ->
    Data = binary:copy(<<"limit">>, 1000),
    Stream = zlib:compress(Data),
    ?assertEqual({ok, Data, <<>>}, erx_inflate:zlib(Stream, byte_size(Data))),
    ?assertEqual({error, limit}, erx_inflate:zlib(Stream, byte_size(Data) - 1)),
    Stored = compress(Data, 0, default),
    ?assertEqual({error, limit}, erx_inflate:zlib(Stored, byte_size(Data) - 1)).

rest_test() ->
    Stream = zlib:compress(<<"abc">>),
    ?assertEqual({ok, <<"abc">>, <<"tail">>}, erx_inflate:zlib(<<Stream/binary, "tail">>, 3)).

stream_refusal_test_() ->
    <<_CMF, _FLG, Body/binary>> = Stream = zlib:compress(<<"abc">>),
    Size = byte_size(Stream) - 4,
    <<Deflate:Size/binary, Adler:32>> = Stream,
    [?_assertEqual({error, truncated}, erx_inflate:zlib(<<>>, 10)),
     ?_assertEqual({error, truncated}, erx_inflate:zlib(Deflate, 10)),
     %% A dictionary, a window of 64 KiB, method 7, and a broken check.
     ?_assertEqual({error, header}, erx_inflate:zlib(<<16#78, 16#bb, Body/binary>>, 10)),
     ?_assertEqual({error, header}, erx_inflate:zlib(<<16#88, 16#1c, Body/binary>>, 10)),
     ?_assertEqual({error, header}, erx_inflate:zlib(<<16#77, 16#09, Body/binary>>, 10)),
     ?_assertEqual({error, header}, erx_inflate:zlib(<<16#78, 16#9d, Body/binary>>, 10)),
     ?_assertEqual({error, check}, erx_inflate:zlib(<<Deflate/binary, (Adler bxor 1):32>>, 10)),
     %% A fixed block whose first code is a copy one byte back.
     ?_assertEqual({error, distance}, erx_inflate:zlib(<<16#78, 16#9c, 16#03, 16#02, 0, 0, 0, 0, 0, 1>>, 10)),
     %% Block type 3.
     ?_assertEqual({error, block}, erx_inflate:zlib(<<16#78, 16#9c, 16#07, 0>>, 10)),
     %% A stored block whose NLEN does not complement LEN.
     ?_assertEqual({error, block}, erx_inflate:zlib(<<16#78, 16#9c, 1, 3, 0, 16#fd, 16#ff, "abc">>, 10))].

%% zlib's rules for code-length sets that leave codes unused, on dynamic
%% blocks written bit by bit, each also against zlib itself: a literal set
%% of one 1-bit code and an empty distance set are read, as is a single
%% 1-bit distance code, through which a copy works and whose unused half is
%% no symbol; a single 2-bit code, an incomplete literal set of 2-bit codes
%% and an over-subscribed set are refused.
incomplete_codes_test_() ->
    Complete = #{97 => 1, 256 => 2, 257 => 2},
    Cases = [{{ok, <<>>}, #{256 => 1}, [0], [{lit, 256}]},
             {{ok, <<"aaaa">>}, Complete, [1], [{lit, 97}, {lit, 257}, {dist, 0}, {lit, 256}]},
             {{error, symbol}, Complete, [1], [{lit, 97}, {lit, 257}, {raw, [1]}]},
             {{error, codes}, Complete, [2], [{lit, 256}]},
             {{error, codes}, #{97 => 2, 256 => 2}, [0], [{lit, 256}]},
             {{error, codes}, Complete, [1, 1, 1], [{lit, 256}]}],
    [?_test(begin
                Stream = dynamic_stream(Lit, Dist, Symbols, Expected),
                agree(Stream),
                ?assertEqual(Expected, case erx_inflate:zlib(Stream, 100) of
                                           {ok, Data, <<>>} -> {ok, Data};
                                           Error -> Error
                                       end)
            end) || {Expected, Lit, Dist, Symbols} <- Cases].

%% A zlib stream of one final dynamic block whose literal and length code
%% has the lengths Lit gives (0 elsewhere) and whose distance code has the
%% lengths Dist; the code-length code gives each of the lengths 0-15 a
%% 4-bit code, which is its own value. Symbols are literals and lengths,
%% distances, or raw bits.
dynamic_stream(Lit, Dist, Symbols, Expected) ->
    Count = max(257, lists:max(maps:keys(Lit)) + 1),
    LitLengths = [maps:get(Symbol, Lit, 0) || Symbol <- lists:seq(0, Count - 1)],
    Order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15],
    LitCodes = canonical(LitLengths),
    DistCodes = canonical(Dist),
    Header = [field(1, 1), field(2, 2), field(Count - 257, 5), field(length(Dist) - 1, 5), field(15, 4),
              [field(if Symbol =< 15 -> 4; true -> 0 end, 3) || Symbol <- Order],
              [code(Length, 4) || Length <- LitLengths ++ Dist]],
    Data = [case Symbol of
                {lit, S} -> maps:get(S, LitCodes);
                {dist, S} -> maps:get(S, DistCodes);
                {raw, Bits} -> Bits
            end || Symbol <- Symbols],
    Bits = lists:flatten([Header, Data]),
    Block = << <<Bit:1>> || Bit <- lists:reverse(Bits ++ lists:duplicate((8 - length(Bits) rem 8) rem 8, 0)) >>,
    %% The bits were written low first: reverse the bytes back into order.
    Bytes = list_to_binary(lists:reverse(binary_to_list(Block))),
    Adler = case Expected of
                {ok, Out} -> erlang:adler32(Out);
                _ -> 1
            end,
    <<16#78, 16#9c, Bytes/binary, Adler:32>>.

%% Value as N bits, low bit first, as deflate writes a field.
field(Value, N) -> [(Value bsr I) band 1 || I <- lists:seq(0, N - 1)].

%% A Huffman code's N bits, high bit first.
code(Value, N) -> [(Value bsr I) band 1 || I <- lists:seq(N - 1, 0, -1)].

%% RFC 1951 3.2.2: each coded symbol's bits.
canonical(Lengths) ->
    Coded = lists:sort([{Length, Symbol} || {Symbol, Length} <- lists:enumerate(0, Lengths), Length > 0]),
    {Codes, _, _} = lists:foldl(fun({Length, Symbol}, {Acc, Next, Previous}) ->
                                        Code = Next bsl (Length - Previous),
                                        {Acc#{Symbol => code(Code, Length)}, Code + 1, Length}
                                end, {#{}, 0, 0}, Coded),
    Codes.
