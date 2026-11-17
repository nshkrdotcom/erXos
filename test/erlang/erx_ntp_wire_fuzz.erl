%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the NTP codec (docs/design-time.md, "Verification and
%% testing"): binaries of up to 1 KiB, arbitrary or mutated from seeds the
%% encoder makes (a valid reply, each kiss code, a reply with a MAC, one byte
%% short, a negative root delay), go to erx_ntp_wire:decode/1, and every
%% decoded reply to erx_ntp_sample:check/4 against one fixed outstanding
%% exchange. Properties: nothing raises; a decoded header re-encodes to its 48
%% bytes; a sample answers the exchange's nonce, its timestamps lie from 1970
%% to 2104, and its distance is below clock_distance_max_ns.
-module(erx_ntp_wire_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 50000).
-define(MIN_SAMPLES, ?ROUNDS div 50).
-define(NS, 1000000000).
-define(UNIX_EPOCH, 2208988800).
-define(NONCE, 16#0123456789abcdef).
-define(M1, 5000000000).
-define(M4, 5020000000).
%% 2104-02-07, past the last time a timestamp of era 1 names: 2^32 + 2^31 s from 1900.
-define(END_NS, (16#100000000 + 16#80000000 - ?UNIX_EPOCH) * ?NS).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Seeds = seeds(),
    Verdicts = [round_of(input(Seeds)) || _ <- lists:seq(1, ?ROUNDS)],
    Samples = length([sample || sample <- Verdicts]),
    case Samples >= ?MIN_SAMPLES of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Samples]);
        false -> error({too_few_samples, Samples})
    end.

seeds() ->
    T = (1794873600 + ?UNIX_EPOCH) bsl 32,
    Valid = #{leap => 0, version => 4, mode => 4, stratum => 2, poll => 6, precision => -20,
              root_delay => 16#800, root_dispersion => 16#400, reference_id => <<"GPS", 0>>,
              reference_time => T - (1 bsl 32), originate_time => ?NONCE, receive_time => T,
              transmit_time => T},
    Bytes = erx_ntp_wire:encode(Valid),
    Kisses = [erx_ntp_wire:encode(Valid#{stratum := 0, reference_id := Code})
              || Code <- [<<"DENY">>, <<"RSTR">>, <<"RATE">>, <<"XFOO">>, <<"INIT">>]],
    [Bytes, <<Bytes/binary, 0:32, 0:128>>, binary:part(Bytes, 0, 47),
     erx_ntp_wire:encode(Valid#{root_delay := -4 * 65536}) | Kisses].

input(Seeds) ->
    case rand:uniform(4) of
        1 -> rand:bytes(rand:uniform(1025) - 1);
        _ -> mutate(lists:nth(rand:uniform(length(Seeds)), Seeds))
    end.

%% Up to three bytes of the seed replaced, and sometimes its tail cut.
mutate(Seed) ->
    Mutated = lists:foldl(fun(_, Bytes) -> flip(Bytes) end, Seed, lists:seq(1, rand:uniform(4) - 1)),
    case rand:uniform(8) of
        1 -> binary:part(Mutated, 0, rand:uniform(byte_size(Mutated)) - 1);
        _ -> Mutated
    end.

flip(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Head:At/binary, _, Tail/binary>> = Bytes,
    <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>.

round_of(Bytes) ->
    case try_decode(Bytes) of
        {ok, Reply} ->
            erx_ntp_wire:encode(Reply) =:= binary:part(Bytes, 0, 48) orelse error({reencode, Bytes}),
            sample(try_check(Reply), Reply);
        {error, short} when byte_size(Bytes) < 48 ->
            refused;
        Other ->
            error({decode_answered, Other, Bytes})
    end.

try_decode(Bytes) ->
    try erx_ntp_wire:decode(Bytes)
    catch Class:Reason -> error({decode_raised, Class, Reason, Bytes})
    end.

try_check(Reply) ->
    try erx_ntp_sample:check(Reply, ?NONCE, ?M1, ?M4)
    catch Class:Reason -> error({check_raised, Class, Reason, Reply})
    end.

sample({sample, #{distance := Distance, delay := Delay}}, Reply) ->
    #{originate_time := Originate, receive_time := Receive, transmit_time := Transmit} = Reply,
    Originate =:= ?NONCE orelse error({foreign_nonce_sampled, Reply}),
    [within_range(erx_ntp_wire:time_ns(Stamp)) orelse error({time_out_of_range, Reply})
     || Stamp <- [Receive, Transmit]],
    Delay >= 0 orelse error({negative_delay, Reply}),
    (Distance >= 0 andalso Distance < ?ERX_CLOCK_DISTANCE_MAX_NS) orelse error({distance_out_of_bounds, Reply}),
    sample;
sample({kiss, <<_:32>>}, #{stratum := 0, originate_time := ?NONCE}) ->
    kiss;
sample({drop, _}, _Reply) ->
    dropped;
sample({foreign, _}, _Reply) ->
    foreign;
sample(Other, Reply) ->
    error({unexpected_verdict, Other, Reply}).

within_range(Ns) -> Ns >= 0 andalso Ns < ?END_NS.
