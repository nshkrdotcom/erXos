%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_date_tests).
-moduledoc """
EUnit cases of the command shell's `date` (erx_cmd_date,
docs/design-time.md, "Setting the clock by hand"): every operand form
FreeBSD's date(1) takes, from 2 to 12 digits with and without `.SS`,
against a fixed current time; each field at its bound and one past it;
every malformed shape; the year pivot; mktime(3)'s normalization; the
order of the operands and the flags; each strftime(3) conversion on
fixed times, whose expected text FreeBSD's C locale gives; and the set
path against a facet this module plays, each of its answers, and a
session without one.
""".

-include_lib("eunit/include/eunit.hrl").

-define(NS, 1000000000).
%% 1970-01-01T00:00:00 in calendar's gregorian seconds.
-define(EPOCH, 62167219200).
%% The current time of the operand cases: 2026-11-16 15:30:45.123456789 UTC.
-define(NOW, (ns({{2026, 11, 16}, {15, 30, 45}}) + 123456789)).

ns(DateTime) -> (calendar:datetime_to_gregorian_seconds(DateTime) - ?EPOCH) * ?NS.

%% The time an operand names at ?NOW, as a datetime.
named(Operand) ->
    {ok, {set, Fields, _Format, true}} = erx_cmd_date:parse([Operand]),
    Time = erx_cmd_date:target(Fields, ?NOW),
    0 = Time rem ?NS,
    calendar:gregorian_seconds_to_datetime(Time div ?NS + ?EPOCH).

%%% Operands

forms_test_() ->
    [?_assertEqual(Expected, named(Operand)) || {Operand, Expected} <-
        [{<<"45">>, {{2026, 11, 16}, {15, 45, 0}}},
         {<<"1045">>, {{2026, 11, 16}, {10, 45, 0}}},
         {<<"011045">>, {{2026, 11, 1}, {10, 45, 0}}},
         {<<"12011045">>, {{2026, 12, 1}, {10, 45, 0}}},
         {<<"2512011045">>, {{2025, 12, 1}, {10, 45, 0}}},
         {<<"192512011045">>, {{1925, 12, 1}, {10, 45, 0}}},
         {<<"45.07">>, {{2026, 11, 16}, {15, 45, 7}}},
         {<<"1045.07">>, {{2026, 11, 16}, {10, 45, 7}}},
         {<<"011045.07">>, {{2026, 11, 1}, {10, 45, 7}}},
         {<<"12011045.07">>, {{2026, 12, 1}, {10, 45, 7}}},
         {<<"2512011045.07">>, {{2025, 12, 1}, {10, 45, 7}}},
         {<<"203001011200.59">>, {{2030, 1, 1}, {12, 0, 59}}}]].

%% Each field at its bound passes; one past it is FreeBSD's illegal time format.
bounds_test_() ->
    Passes = [<<"59">>, <<"2359">>, <<"312359">>, <<"12312359">>, <<"9912312359">>, <<"999912312359">>,
              <<"0000">>, <<"1200.61">>, <<"1200.00">>],
    Refused = [<<"60">>, <<"2400">>, <<"322359">>, <<"13312359">>, <<"1200.62">>, <<"1260">>],
    [[?_assertMatch({ok, {set, _, _, true}}, erx_cmd_date:parse([P])) || P <- Passes],
     [?_assertEqual({error, illegal_time}, erx_cmd_date:parse([R])) || R <- Refused]].

shapes_test_() ->
    Twelve = <<"203001011200">>,
    NonDigit = [<<(binary:part(Twelve, 0, I))/binary, $a, (binary:part(Twelve, I + 1, 11 - I))/binary>>
                || I <- lists:seq(0, 11)],
    Odd = [binary:copy(<<"1">>, N) || N <- [1, 3, 5, 7, 9, 11, 13]],
    Other = [<<>>, <<"12001200120012">>, <<"1200.3">>, <<"1200.300">>, <<"1200.3a">>, <<"1200.30.1">>,
             <<"1200..30">>, <<".30">>, <<"1200.">>, <<".">>, <<" 1200">>, <<"12:00">>],
    [?_assertEqual({error, illegal_time}, erx_cmd_date:parse([Bad])) || Bad <- NonDigit ++ Odd ++ Other] ++
    %% A second +format where the time belongs is a time operand, and illegal.
    [?_assertEqual({error, illegal_time}, erx_cmd_date:parse([<<"+%Y">>, <<"+%m">>]))].

pivot_test_() ->
    [?_assertEqual({{2068, 1, 1}, {0, 0, 0}}, named(<<"6801010000">>)),
     ?_assertEqual({{1969, 1, 1}, {0, 0, 0}}, named(<<"6901010000">>)),
     ?_assertEqual({{2000, 1, 1}, {0, 0, 0}}, named(<<"0001010000">>)),
     ?_assertEqual({{1999, 1, 1}, {0, 0, 0}}, named(<<"9901010000">>)),
     ?_assertEqual({{2069, 1, 1}, {0, 0, 0}}, named(<<"206901010000">>))].

%% mktime(3)'s normalization, in a common year (2026) and a leap year (2024).
normalize_test_() ->
    [?_assertEqual({{2025, 12, 1}, {12, 0, 0}}, named(<<"2600011200">>)),
     ?_assertEqual({{2026, 2, 28}, {12, 0, 0}}, named(<<"2603001200">>)),
     ?_assertEqual({{2024, 2, 29}, {12, 0, 0}}, named(<<"2403001200">>)),
     ?_assertEqual({{2026, 3, 1}, {12, 0, 0}}, named(<<"2602291200">>)),
     ?_assertEqual({{2024, 2, 29}, {12, 0, 0}}, named(<<"2402291200">>)),
     ?_assertEqual({{2026, 3, 2}, {12, 0, 0}}, named(<<"2602301200">>)),
     ?_assertEqual({{2024, 3, 1}, {12, 0, 0}}, named(<<"2402301200">>)),
     ?_assertEqual({{2026, 12, 1}, {12, 0, 0}}, named(<<"11311200">>)),
     ?_assertEqual({{2025, 12, 31}, {12, 0, 0}}, named(<<"2601001200">>)),
     ?_assertEqual({{2026, 11, 16}, {12, 1, 0}}, named(<<"1200.60">>)),
     ?_assertEqual({{2026, 11, 16}, {12, 1, 1}}, named(<<"1200.61">>)),
     ?_assertEqual({{2027, 1, 1}, {0, 0, 0}}, named(<<"12312359.60">>))].

operands_test_() ->
    Op = fun(Args) -> erx_cmd_date:parse(Args) end,
    [?_assertEqual({ok, {read, <<"%+">>}}, Op([])),
     ?_assertEqual({ok, {read, <<"%Y">>}}, Op([<<"+%Y">>])),
     ?_assertEqual({ok, {read, <<>>}}, Op([<<"+">>])),
     ?_assertEqual({ok, {read, <<"%+">>}}, Op([<<"-u">>])),
     ?_assertMatch({ok, {set, #{minute := 0, hour := 12}, <<"%Y">>, true}}, Op([<<"+%Y">>, <<"1200">>])),
     ?_assertMatch({ok, {set, _, <<"%m">>, true}}, Op([<<"1200">>, <<"+%m">>])),
     %% A format after the time replaces one before it, as date.c's main reads them.
     ?_assertMatch({ok, {set, _, <<"%m">>, true}}, Op([<<"+%Y">>, <<"1200">>, <<"+%m">>])),
     %% What follows is left unread.
     ?_assertMatch({ok, {set, _, <<"%+">>, true}}, Op([<<"1200">>, <<"later">>])),
     ?_assertMatch({ok, {set, _, <<"%+">>, false}}, Op([<<"-j">>, <<"1200">>])),
     ?_assertMatch({ok, {set, _, <<"%+">>, false}}, Op([<<"-ju">>, <<"1200">>])),
     ?_assertMatch({ok, {set, _, <<"%+">>, false}}, Op([<<"-u">>, <<"-j">>, <<"1200">>])),
     ?_assertMatch({ok, {set, _, <<"%+">>, true}}, Op([<<"--">>, <<"1200">>])),
     ?_assertMatch({ok, {set, _, <<"%+">>, true}}, Op([<<"-n">>, <<"1200">>])),
     [?_assertEqual({error, usage}, Op([Flag, <<"1200">>]))
      || Flag <- [<<"-f">>, <<"-I">>, <<"-R">>, <<"-r">>, <<"-v">>, <<"-z">>, <<"-5">>]]].

%%% Formats

format(Format, DateTime) -> erx_cmd_date:format(Format, ns(DateTime)).

%% Each conversion on fixed times, the text FreeBSD 15.1's strftime(3)
%% writes in the C locale and UTC (lib/libc/stdtime/strftime.c and
%% timelocal.c's _C_time_locale).
conversions_test_() ->
    All = <<"%a %A %b %B %h %c %C %d %D %e %F %G %g %H %I %j %k %l %m %M %p %r %R %s %S %T %u %U %V "
            "%v %w %W %x %X %y %Y %z %Z %+ %%">>,
    [?_assertEqual(<<"Tue Tuesday Feb February Feb Tue Feb 29 00:00:00 2000 20 29 02/29/00 29 2000-02-29 "
                     "2000 00 00 12 060  0 12 02 00 AM 12:00:00 AM 00:00 951782400 00 00:00:00 2 09 09 "
                     "29-Feb-2000 2 09 02/29/00 00:00:00 00 2000 +0000 UTC Tue Feb 29 00:00:00 UTC 2000 %">>,
                   format(All, {{2000, 2, 29}, {0, 0, 0}})),
     ?_assertEqual(<<"Fri Friday Jan January Jan Fri Jan  1 00:00:00 2021 20 01 01/01/21  1 2021-01-01 "
                     "2020 20 00 12 001  0 12 01 00 AM 12:00:00 AM 00:00 1609459200 00 00:00:00 5 00 53 "
                     " 1-Jan-2021 5 00 01/01/21 00:00:00 21 2021 +0000 UTC Fri Jan  1 00:00:00 UTC 2021 %">>,
                   format(All, {{2021, 1, 1}, {0, 0, 0}})),
     ?_assertEqual(<<"Thu Thursday Dec December Dec Thu Dec 31 23:59:59 2026 20 31 12/31/26 31 2026-12-31 "
                     "2026 26 23 11 365 23 11 12 59 PM 11:59:59 PM 23:59 1798761599 59 23:59:59 4 52 53 "
                     "31-Dec-2026 4 52 12/31/26 23:59:59 26 2026 +0000 UTC Thu Dec 31 23:59:59 UTC 2026 %">>,
                   format(All, {{2026, 12, 31}, {23, 59, 59}})),
     %% A Sunday at noon, and a year before 1970.
     ?_assertEqual(<<"Sun 7 0 12 12 PM 47 46">>, format(<<"%a %u %w %H %I %p %U %W">>, {{2026, 11, 22}, {12, 0, 0}})),
     ?_assertEqual(<<"Wed Dec 31 00:00:00 UTC 1969 -86400 1970-W01">>,
                   format(<<"%+ %s %G-W%V">>, {{1969, 12, 31}, {0, 0, 0}})),
     %% Year 0, and the year before it, which month 00 of year 0 normalizes to, as _yconv writes them.
     ?_assertEqual(<<"0000 00 00">>, format(<<"%Y %C %y">>, {{0, 1, 1}, {0, 0, 0}})),
     ?_assertEqual(<<"-001 -0 01 12-01">>,
                   erx_cmd_date:format(<<"%Y %C %y %m-%d">>, before_year_0()))].

before_year_0() ->
    {ok, {set, Fields, _, true}} = erx_cmd_date:parse([<<"000000010000">>]),
    erx_cmd_date:target(Fields, ?NOW).

padding_test_() ->
    Day = {{2026, 3, 5}, {7, 4, 9}},
    [?_assertEqual(<<"5  5 05 05 | 7  7 07 | 64  64 064">>,
                   format(<<"%-d %_d %0d %d | %-H %_H %0H | %-j %_j %0j">>, Day)),
     ?_assertEqual(<<" 5 5 05 |  7 7 07 | +0000 +0 +   0">>,
                   format(<<"%e %-e %0e | %k %-k %0k | %z %-z %_z">>, Day)),
     %% The Y, C and y conversions ignore the flags, as _yconv does.
     ?_assertEqual(<<"2026 20 26">>, format(<<"%-Y %_C %0y">>, Day)),
     %% E and O are taken once and ignored; a second flag or modifier is written as itself.
     ?_assertEqual(<<"26 05 -d Ey _d">>, format(<<"%Ey %Od %--d %EEy %-_d">>, Day))].

edges_test_() ->
    Time = ns({{2026, 3, 5}, {7, 4, 9}}) + 123456789,
    F = fun(Format) -> erx_cmd_date:format(Format, Time) end,
    [?_assertEqual(<<"Q K P">>, F(<<"%Q %K %P">>)),
     ?_assertEqual(<<"%">>, F(<<"%">>)),
     ?_assertEqual(<<"a-">>, F(<<"a%-">>)),
     ?_assertEqual(<<"E">>, F(<<"%E">>)),
     ?_assertEqual(<<"5d">>, F(<<"%5d">>)),
     ?_assertEqual(<<"%N">>, F(<<"%%N">>)),
     ?_assertEqual(<<"\n\t">>, F(<<"%n%t">>)),
     %% date's own %N: nine digits, a width cut or padded, %-N nine.
     ?_assertEqual(<<"123456789 123 123456789000 123456789 123456789 5N">>,
                   F(<<"%N %3N %12N %-N %0N %-5N">>)),
     ?_assertEqual(<<"07:04:09.000000000">>, erx_cmd_date:format(<<"%T.%N">>, ns({{2026, 3, 5}, {7, 4, 9}})))].

%%% Running

run_line(Source, Facets) ->
    {Table, []} = erx_shell_namespace:build(
                    [{erx_cmd_date, erx_cmd_date:module_info(attributes), erx_cmd_date:module_info(exports)}]),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> Facets end}),
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, Done} = erx_shell_eval:run_source(Source, Shell),
    {erx_shell_eval:status(Done), shown(out), shown(err)}.

sink(Stream) ->
    Me = self(),
    {tty, fun(Bytes) -> Me ! {Stream, iolist_to_binary(Bytes)}, ok end}.

shown(Stream) -> shown(Stream, []).

shown(Stream, Acc) ->
    receive {Stream, Bytes} -> shown(Stream, [Acc, Bytes])
    after 0 -> iolist_to_binary(Acc)
    end.

%% A clock facet that answers every call with Answer and reports what it was asked.
facet(Answer) ->
    Test = self(),
    spawn_link(fun() -> serve(Test, Answer) end).

serve(Test, Answer) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {asked, Request},
            gen_server:reply(From, Answer),
            serve(Test, Answer)
    end.

asked() ->
    receive {asked, Request} -> Request after 0 -> none end.

reading_test_() ->
    Now = os:system_time(second),
    [?_assertMatch({<<>>, <<_:3/binary, " ", _:3/binary, " ", _/binary>>, <<>>}, run_line(<<"date">>, #{})),
     ?_assert(abs(binary_to_integer(string:trim(element(2, run_line(<<"date -u +%s">>, #{})))) - Now) =< 5),
     ?_assertEqual({<<>>, <<"203001011200 Tue\n">>, <<>>},
                   run_line(<<"date -j 203001011200 '+%Y%m%d%H%M %a'">>, #{})),
     ?_assertEqual({<<"usage">>, <<>>,
                    <<"date: illegal time format\nusage: date [-jnu] [[[[[cc]yy]mm]dd]HH]MM[.SS] [+format]\n">>},
                   run_line(<<"date 1260">>, #{})),
     ?_assertEqual({<<"usage">>, <<>>, <<"usage: date [-jnu] [[[[[cc]yy]mm]dd]HH]MM[.SS] [+format]\n">>},
                   run_line(<<"date -r 0">>, #{}))].

set_test_() ->
    {inorder,
     [fun() ->
              Facet = facet({ok, {stepped, 1}}),
              Before = os:perf_counter(nanosecond),
              ?assertEqual({<<>>, <<"203001011200.00\n">>, <<>>},
                           run_line(<<"date 203001011200 +%Y%m%d%H%M.%S">>, #{clock => Facet})),
              After = os:perf_counter(nanosecond),
              {set, W} = asked(),
              %% W is the named time less the monotonic clock read for it.
              Named = ns({{2030, 1, 1}, {12, 0, 0}}),
              ?assert(W =< Named - Before andalso W >= Named - After)
      end,
      %% Each answer of the facet gives its errno's text and status 1.
      fun() ->
              [begin
                   {Status, Out, Err} = run_line(<<"date 1200">>, #{clock => facet({error, Reason})}),
                   ?assertEqual({<<"1">>, <<>>}, {Status, Out}),
                   ?assertEqual(<<"date: clock_settime: ", (erx_cmd:format_error(Errno))/binary, "\n">>, Err),
                   {set, _} = asked()
               end || {Reason, Errno} <- [{badarg, einval}, {eperm, eperm}, {unavailable, eagain}, {unsupported, enotsup},
                                          {limit, eoverflow}, {busy, ebusy}, {failed, eio}]]
      end,
      %% A facet that has already ended was sent nothing.
      fun() ->
              Gone = spawn(fun() -> ok end),
              ?assertEqual({<<"1">>, <<>>, <<"date: clock_settime: ", (erx_cmd:format_error(eagain))/binary, "\n">>},
                           run_line(<<"date 1200">>, #{clock => Gone}))
      end,
      %% Without the grant a set is refused before anything is asked, and -j still runs.
      fun() ->
              ?assertEqual({<<"1">>, <<>>, <<"date: clock_settime: ", (erx_cmd:format_error(eperm))/binary, "\n">>},
                           run_line(<<"date 1200">>, #{})),
              ?assertEqual({<<>>, <<"12:00\n">>, <<>>}, run_line(<<"date -j 1200 +%H:%M">>, #{})),
              ?assertEqual(none, asked())
      end]}.
