%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the command shell's `date` (docs/design-time.md,
%% "Setting the clock by hand"): erx_cmd_date:parse/1 over argument lists
%% of up to four binaries of up to 32 bytes, half of them operands built
%% of digit pairs and an optional `.SS` and the rest random bytes biased
%% toward digits, dots, `+` and `-`. Whatever arrives, parse/1 never
%% raises; an accepted time operand has an even count of 2 to 12 digits,
%% at most one `.` followed by two digits, and each field within
%% FreeBSD's bound (date.c, setthetime), checked here against the
%% operand's own text; its time at fixed current times, written as
%% `%Y%m%d%H%M.%S` and parsed again, names the same time; and format/2
%% writes every generated format at every generated time without
%% raising. The seed comes from make check-fuzz.

-module(erx_cmd_date_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(NS, 1000000000).
%% Current times: the epoch, 2026-11-16 15:30:45.5 and 2116-01-01, in ns.
-define(NOWS, [0, 1794843045500000000, 4607798400000000000]).
%% FreeBSD's bounds on the fields, from the right: MM, HH, dd, mm.
-define(BOUNDS, [59, 23, 31, 12]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(args()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Args) ->
    format_never_raises(),
    case erx_cmd_date:parse(Args) of
        {ok, {set, Operand, _Format, _Set}} ->
            Text = time_operand(Args),
            well_formed(Text) orelse error({out_of_bounds, Text}),
            [round_trip(Text, Operand, Now) || Now <- ?NOWS],
            accepted;
        {ok, {read, _}} -> read;
        {error, usage} -> refused;
        {error, illegal_time} -> refused
    end.

%% The time operand parse/1 read: the first argument after the flags and
%% a first `+format`.
time_operand(Args) ->
    {ok, _Flags, Operands} = erx_cmd:getopt(Args, "jnu"),
    case Operands of
        [<<$+, _/binary>>, Time | _] -> Time;
        [Time | _] -> Time
    end.

well_formed(Text) ->
    {Digits, Second} = case binary:split(Text, <<".">>) of
                           [D] -> {D, <<"00">>};
                           [D, S] -> {D, S}
                       end,
    all_digits(Digits) andalso all_digits(Second) andalso byte_size(Second) =:= 2
        andalso byte_size(Digits) rem 2 =:= 0 andalso byte_size(Digits) =< 12
        andalso binary_to_integer(Second) =< 61 andalso within_bounds(Digits).

%% The pairs from the right against MM, HH, dd and mm; yy and cc take any two digits.
within_bounds(Digits) ->
    Pairs = lists:reverse([binary_to_integer(P) || <<P:2/binary>> <= Digits]),
    Checked = lists:sublist(Pairs, 4),
    lists:all(fun({Value, Bound}) -> Value =< Bound end, lists:zip(Checked, lists:sublist(?BOUNDS, length(Checked)))).

all_digits(Bin) -> Bin =/= <<>> andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)).

%% A named time in years 0 to 9999 written as a full operand names itself.
round_trip(Text, Operand, Now) ->
    Time = erx_cmd_date:target(Operand, Now),
    Written = erx_cmd_date:format(<<"%Y%m%d%H%M.%S">>, Time),
    case byte_size(Written) of
        15 ->
            {ok, {set, Again, _, _}} = erx_cmd_date:parse([Written]),
            erx_cmd_date:target(Again, Now) =:= Time orelse error({round_trip, Text, Now, Written});
        _ ->
            ok
    end.

format_never_raises() ->
    Format = bytes(rand:uniform(24), <<"%%%%-_0EONn9aAbBcCdDeFgGhHIjklmMprRsStTuUvVwWxXyYzZ+Q">>),
    Time = (rand:uniform(1 bsl 40) - (1 bsl 39)) * ?NS + rand:uniform(?NS) - 1,
    is_binary(erx_cmd_date:format(Format, Time)) orelse error({format, Format, Time}).

args() ->
    Flags = [F || F <- [<<"-j">>, <<"-u">>, <<"-n">>, <<"-x">>], rand:uniform(6) =:= 1],
    Formats = [<<"+%Y">> || rand:uniform(4) =:= 1],
    Rest = [argument() || _ <- lists:seq(1, rand:uniform(3) - 1)],
    lists:sublist(Flags ++ Formats ++ Rest, 4).

argument() ->
    case rand:uniform(2) of
        1 -> operand();
        2 -> bytes(rand:uniform(32) - 1, <<"0123456789012345678901234567890123456789..+-:a ">>)
    end.

%% Digit pairs, mostly in range, and an optional `.SS`.
operand() ->
    Pairs = << <<(pair())/binary>> || _ <- lists:seq(1, rand:uniform(7) - 1) >>,
    case rand:uniform(3) of
        1 -> <<Pairs/binary, $., (pair())/binary>>;
        _ -> Pairs
    end.

pair() ->
    case rand:uniform(4) of
        1 -> iolist_to_binary(io_lib:format("~2..0B", [rand:uniform(100) - 1]));
        _ -> iolist_to_binary(io_lib:format("~2..0B", [rand:uniform(24) - 1]))
    end.

bytes(N, Alphabet) ->
    << <<(binary:at(Alphabet, rand:uniform(byte_size(Alphabet)) - 1))>> || _ <- lists:seq(1, N) >>.
