%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the session load's reader of its arguments and its standard input,
%% erx_cmd_load:parse/1 and split/2 (docs/design-live.md, "One load, three routes"), run by
%% tools/fuzz/erx_cmd_load.rb. Each round builds arguments from the words a caller could
%% send, valid and not, and checks that parse/1 never raises and accepts a plan only when
%% the reference below does: exactly one target, one form, sizes from 1 within the load
%% bound in all, and a size left out only by the last module. It then cuts random input by
%% random specs and checks that split/2 never raises, that what it answers concatenates to
%% the input, and that it refuses exactly when the input is shorter or longer than the
%% specs take.

-module(erx_cmd_load_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-include("generated/erx_abi.hrl").

-define(BOUND, ?ERX_CODE_LOAD_BYTES_MAX).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), parse_round(args()) =:= accepted]),
    Cut = length([ok || _ <- lists:seq(1, ?ROUNDS), split_round() =:= accepted]),
    case Accepted >= ?ROUNDS div 20 andalso Cut >= ?ROUNDS div 20 of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [2 * ?ROUNDS, Accepted + Cut]);
        false -> error({too_few_accepted, Accepted, Cut})
    end.

%%% parse/1

parse_round(Args) ->
    Got = try erx_cmd_load:parse(Args) catch Class:Reason -> error({raised, Args, Class, Reason}) end,
    case {Got, reference(Args)} of
        {{ok, Plan}, {ok, Plan}} -> accepted;
        {{error, usage}, error} -> refused;
        {_, Expected} -> error({disagrees_with_reference, Args, Got, Expected})
    end.

args() ->
    Targets = pick([[<<"-s">>], [<<"-d">>, word()], [], [<<"-s">>, <<"-s">>], [<<"-s">>, <<"-d">>, word()],
                    [<<"-d">>, <<>>]]),
    Verbose = pick([[], [<<"-v">>]]),
    Modules = pick([specs(), specs(), specs(), files(), specs() ++ files(), []]),
    Targets ++ Verbose ++ Modules.

specs() ->
    lists:append([[<<"-m">>, spec()] || _ <- lists:seq(1, rand:uniform(4))]).

files() ->
    [<<(word())/binary, ".beam">> || _ <- lists:seq(1, rand:uniform(3))].

spec() ->
    pick([word(), <<(word())/binary, ":", (size())/binary>>, <<(word())/binary, ":", (size())/binary>>,
          <<":", (size())/binary>>, <<(word())/binary, ":">>, <<(word())/binary, ":x1">>,
          <<(word())/binary, ":b:", (size())/binary>>]).

size() ->
    integer_to_binary(pick([0, 1, 2, rand:uniform(1000), ?BOUND - 1, ?BOUND, ?BOUND + 1, 999999999,
                            1234567890, -1])).

word() -> pick([<<"a">>, <<"erx_m">>, <<"m@x.y">>, <<"-">>, <<"5">>, <<"net">>]).

%% The plan the design gives Args, or error.
reference(Args) ->
    case erx_cmd:getopt(Args, "sd:vm:") of
        {ok, Flags, Files} ->
            Targets = [F || F <- Flags, F =:= $s orelse element(1, F) =:= $d],
            Specs = [S || {$m, S} <- Flags],
            maybe
                {ok, Target} ?= ref_target(Targets),
                {ok, Source} ?= ref_source(Specs, Files),
                {ok, #{target => Target, verbose => lists:member($v, Flags), source => Source}}
            else
                _ -> error
            end;
        {error, usage} ->
            error
    end.

ref_target([$s]) -> {ok, system};
ref_target([{$d, D}]) when D =/= <<>> -> {ok, {domain, D}};
ref_target(_) -> error.

ref_source([], [_ | _] = Files) -> {ok, {files, Files}};
ref_source([_ | _] = Specs, []) ->
    Parsed = [ref_spec(S) || S <- Specs],
    {Init, [Last]} = lists:split(length(Parsed) - 1, Parsed),
    Sized = [P || {_, N} = P <- Init, is_integer(N)],
    case length(Sized) =:= length(Init) andalso Last =/= error
        andalso lists:sum([N || {_, N} <- Parsed, is_integer(N)]) =< ?BOUND of
        true -> {ok, {input, Parsed}};
        false -> error
    end;
ref_source(_, _) -> error.

ref_spec(Spec) ->
    case string:split(Spec, ":", trailing) of
        [<<>>] -> error;
        [Name] -> {Name, rest};
        [<<>>, _] -> error;
        [Name, Digits] ->
            case re:run(Digits, "^[1-9][0-9]{0,8}$") of
                {match, _} when Digits =/= <<"0">> ->
                    case binary_to_integer(Digits) of
                        0 -> error;
                        N -> {Name, N}
                    end;
                _ -> error
            end
    end.

%%% split/2

split_round() ->
    Specs = [{<<"m", (integer_to_binary(I))/binary>>, rand:uniform(8)} || I <- lists:seq(1, rand:uniform(4))],
    Cut = case rand:uniform(2) of
              1 -> Specs;
              2 -> lists:droplast(Specs) ++ [{element(1, lists:last(Specs)), rest}]
          end,
    Taken = lists:sum([N || {_, N} <- Cut, is_integer(N)]),
    Input = rand:bytes(max(0, Taken + rand:uniform(5) - 3)),
    Got = try erx_cmd_load:split(Cut, Input) catch Class:Reason -> error({raised, Cut, Input, Class, Reason}) end,
    Rest = byte_size(Input) - Taken,
    Fits = case lists:last(Cut) of
               {_, rest} -> Rest >= 1;
               _ -> Rest =:= 0
           end,
    case Got of
        {ok, Modules} when Fits ->
            Input =:= iolist_to_binary([B || {_, B} <- Modules]) orelse error({lost_bytes, Cut, Input, Got}),
            [N =:= byte_size(B) orelse error({wrong_size, Cut, Input, Got}) || {{_, N}, {_, B}} <- lists:zip(Cut, Modules),
                                                                              is_integer(N)],
            accepted;
        {error, {_, Why}} when not Fits, Why =:= short orelse Why =:= long -> refused;
        _ -> error({disagrees_with_reference, Cut, Input, Got})
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
