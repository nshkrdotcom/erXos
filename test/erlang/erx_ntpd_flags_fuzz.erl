%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Fuzz target of ntpd's start flags reader, erx_ntp_core:servers/1
%% (docs/design-time.md, "Verification and testing", erx_ntpd_flags_fuzz):
%% arbitrary binaries of up to 2 KiB, biased toward letters, digits, dots,
%% hyphens and spaces and toward mutations of valid lists. Properties: nothing
%% raises; an accepted list has 1 to 8 entries, each an IPv4 literal or a
%% name of 1 to 253 bytes in labels of 1 to 63 letters, digits and hyphens.
%% tools/fuzz/erx_ntpd_flags.rb runs it and its seeded faults.
-module(erx_ntpd_flags_fuzz).
-export([run/1]).

-define(ROUNDS, 100000).
-define(MIN_ACCEPTED, ?ROUNDS div 100).
-define(ALPHABET, <<"abz09-.  ">>).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Seeds = [<<"pool.ntp.org">>, <<"10.0.2.100 ntp.example.net">>, <<"a b c d e f g h">>,
             name253(), <<(binary:copy(<<"a">>, 63))/binary, ".org">>],
    Accepted = length([ok || ok <- [round_of(input(Seeds)) || _ <- lists:seq(1, ?ROUNDS)]]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% A name of exactly 253 bytes in four labels: one byte more passes the bound.
name253() ->
    Label = binary:copy(<<"a">>, 63),
    <<Label/binary, ".", Label/binary, ".", Label/binary, ".", (binary:copy(<<"b">>, 61))/binary>>.

input(Seeds) ->
    case rand:uniform(4) of
        1 -> rand:bytes(rand:uniform(2049) - 1);
        2 -> << <<(binary:at(?ALPHABET, rand:uniform(byte_size(?ALPHABET)) - 1))>>
                || _ <- lists:seq(1, rand:uniform(300) - 1) >>;
        _ -> mutate(lists:nth(rand:uniform(length(Seeds)), Seeds))
    end.

%% A seed grown by a byte of the alphabet, cut short, or with a byte changed.
mutate(Seed) ->
    Byte = binary:at(?ALPHABET, rand:uniform(byte_size(?ALPHABET)) - 1),
    case rand:uniform(3) of
        1 -> <<Seed/binary, Byte>>;
        2 -> binary:part(Seed, 0, rand:uniform(byte_size(Seed)) - 1);
        3 -> At = rand:uniform(byte_size(Seed)) - 1,
             <<Head:At/binary, _, Tail/binary>> = Seed,
             <<Head/binary, Byte, Tail/binary>>
    end.

round_of(Flags) ->
    case try erx_ntp_core:servers(Flags) catch Class:Raised -> error({servers_raised, Class, Raised, Flags}) end of
        {ok, Entries} ->
            (length(Entries) >= 1 andalso length(Entries) =< 8) orelse error({entry_count, Flags}),
            lists:all(fun valid/1, Entries) orelse error({entry_out_of_rule, Flags}),
            ok;
        {error, Reason} when Reason =:= no_servers; Reason =:= bad_flags ->
            refused
    end.

valid(Entry) ->
    case inet:parse_ipv4strict_address(binary_to_list(Entry)) of
        {ok, _} -> true;
        {error, _} ->
            byte_size(Entry) >= 1 andalso byte_size(Entry) =< 253 andalso
                lists:all(fun(Label) -> byte_size(Label) >= 1 andalso byte_size(Label) =< 63 andalso
                                            re:run(Label, <<"^[A-Za-z0-9-]+$">>) =/= nomatch
                          end, binary:split(Entry, <<".">>, [global]))
    end.
