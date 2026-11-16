%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_date).
-moduledoc """
`date [-jnu] [[[[[cc]yy]mm]dd]HH]MM[.SS] [+format]`: write the wall time,
or set it, as FreeBSD's date(1) does (bin/date/date.c at releng/15.1),
in UTC, the only zone erXos has (docs/design-time.md, "Setting the clock
by hand").

With no time operand the command writes the wall time through the
format, `%+` by default. A time operand names the new time by pairs of
digits read from the left, and the fields it leaves out keep the current
UTC date's values; the named time is set and then written. `-j` writes
the named time without setting it. `-u` is accepted and changes nothing,
since local time is UTC.

Setting needs the session's `clock` grant: the command sends the clock
facet `{set, W}`, the wall offset that makes the clock read the named
time, and a session without the grant refuses with `eperm`, as FreeBSD's
date refuses a user other than the superuser. Reading and `-j` need no
grant, so the command declares no `-erx_needs`.

The decisions are pure: parse/1 takes the arguments to a request,
target/2 takes an operand and the current wall time to the named time,
and format/2 writes a time through a format as FreeBSD's strftime(3)
does in the C locale (lib/libc/stdtime/strftime.c), with date's own
`%N`. run/2 reads the clocks, asks the facet and writes.
""".
-behaviour(erx_cmd).

-erx_command(date).
-erx_usage("date [-jnu] [[[[[cc]yy]mm]dd]HH]MM[.SS] [+format]").

-export([run/2]).
-export([parse/1, target/2, format/2]).
-export_type([request/0, operand/0]).

-doc """
A parsed command line: a reading through a format, or a time operand
with the format and whether to set the clock (false under `-j`).
""".
-type request() :: {read, binary()} | {set, operand(), binary(), boolean()}.

-doc """
The fields a time operand gives: `minute` and `second` always, the
second 0 when the operand has no `.SS`, and the others only when the
operand has them, `year` already resolved from `cc` and `yy`.
""".
-type operand() :: #{year => 0..9999, month => 0..12, day => 0..31, hour => 0..23,
                     minute := 0..59, second := 0..61}.

-define(DEFAULT_FORMAT, <<"%+">>).
-define(NS, 1000000000).
-define(DAY, 86400).
%% How long a set waits for the clock facet's answer.
-define(FACET_WAIT_MS, 10000).

-doc false.
run(Args, Ctx) ->
    case parse(Args) of
        {ok, {read, Format}} ->
            write_time(Ctx, Format, os:system_time(nanosecond));
        {ok, {set, Operand, Format, false}} ->
            write_time(Ctx, Format, target(Operand, os:system_time(nanosecond)));
        {ok, {set, Operand, Format, true}} ->
            set(Ctx, Operand, Format);
        {error, illegal_time} ->
            erx_cmd:say(Ctx, [maps:get(name, Ctx), <<": illegal time format\n">>]),
            {error, usage};
        {error, usage} = Usage ->
            Usage
    end.

%%% Parsing

-doc """
The request command line Args makes, as FreeBSD's date reads it: the
flags `-j`, `-n` and `-u`, of which `-n` and `-u` change nothing, then a `+format` operand, a time operand and a
`+format` operand, each optional and the formats in either place, with
anything after them left unread, as `date.c`'s `main` leaves it. A flag
it does not take is `{error, usage}`; a time operand of the wrong shape,
or one whose field is out of its range, `{error, illegal_time}`.
""".
-spec parse([binary()]) -> {ok, request()} | {error, usage | illegal_time}.
parse(Args) ->
    case erx_cmd:getopt(Args, "jnu") of
        {ok, Flags, Operands} -> operands(Operands, not lists:member($j, Flags));
        {error, usage} = Usage -> Usage
    end.

operands([<<$+, Format/binary>> | Rest], Set) ->
    after_format(Rest, Format, Set);
operands(Rest, Set) ->
    after_format(Rest, ?DEFAULT_FORMAT, Set).

after_format([], Format, _Set) ->
    {ok, {read, Format}};
after_format([Time | Rest], Format0, Set) ->
    Format = case Rest of
                 [<<$+, Later/binary>> | _] -> Later;
                 _ -> Format0
             end,
    case operand(Time) of
        {ok, Operand} -> {ok, {set, Operand, Format, Set}};
        error -> {error, illegal_time}
    end.


-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).

%% A time operand: digits and at most one dot, which exactly two digits
%% follow, the digits an even count of 2 to 12 (date.c, setthetime).
operand(Time) ->
    case binary:split(Time, <<".">>) of
        [Digits] -> fields(Digits, 0);
        [Digits, <<S1, S2>>] when ?IS_DIGIT(S1), ?IS_DIGIT(S2) -> fields(Digits, pair(S1, S2));
        _ -> error
    end.

fields(Digits, Second) ->
    case pairs(Digits, []) of
        {ok, Pairs} when Pairs =/= [], length(Pairs) =< 6, Second =< 61 -> named(Pairs, Second);
        _ -> error
    end.

%% The digits' pairs, the last first.
pairs(<<>>, Pairs) -> {ok, Pairs};
pairs(<<A, B, Rest/binary>>, Pairs) when ?IS_DIGIT(A), ?IS_DIGIT(B) -> pairs(Rest, [pair(A, B) | Pairs]);
pairs(_Odd, _Pairs) -> error.

pair(A, B) -> (A - $0) * 10 + (B - $0).

%% The pairs name the fields from the right: MM always, then HH, dd, mm,
%% yy and cc. A field above its bound is refused, as setthetime refuses it.
named(Pairs, Second) ->
    Named = maps:from_list(lists:zip(lists:sublist([minute, hour, day, month, yy, cc], length(Pairs)), Pairs)),
    Bounds = #{minute => 59, hour => 23, day => 31, month => 12, yy => 99, cc => 99},
    case lists:all(fun({Field, Value}) -> Value =< map_get(Field, Bounds) end, maps:to_list(Named)) of
        true -> {ok, year(maps:without([yy, cc], Named#{second => Second}), Named)};
        false -> error
    end.

%% A year without its century below 69 is in 2000-2068, otherwise in
%% 1969-1999, as setthetime's pivot reads it.
year(Fields, #{cc := Century, yy := Year}) -> Fields#{year => Century * 100 + Year};
year(Fields, #{yy := Year}) when Year < 69 -> Fields#{year => 2000 + Year};
year(Fields, #{yy := Year}) -> Fields#{year => 1900 + Year};
year(Fields, #{}) -> Fields.

%%% The named time

-doc """
The time in nanoseconds since 1970 that Operand names when the wall time
is Now: each field the operand leaves out takes Now's UTC value, but the
second, which the operand always gives, and the nanoseconds are 0. The
fields are normalized as mktime(3) normalizes them, so month 0 is
December of the year before and day 0 the last day of the month before.
""".
-spec target(operand(), integer()) -> integer().
target(Operand, Now) ->
    {{Year0, Month0, Day0}, {Hour0, _, _}} = civil(floor_div(Now, ?NS)),
    #{minute := Minute, second := Second} = Operand,
    Year = maps:get(year, Operand, Year0),
    Month = maps:get(month, Operand, Month0),
    Day = maps:get(day, Operand, Day0),
    Hour = maps:get(hour, Operand, Hour0),
    Days = days(Year + floor_div(Month - 1, 12), floor_mod(Month - 1, 12) + 1, 1) + Day - 1,
    ((Days * ?DAY) + Hour * 3600 + Minute * 60 + Second) * ?NS.

%% Days since 1970-01-01 of a proleptic Gregorian date, and back, for
%% every integer (H. Hinnant's days_from_civil and civil_from_days).
days(Year0, Month, Day) ->
    Year = if Month =< 2 -> Year0 - 1; true -> Year0 end,
    Era = floor_div(Year, 400),
    YearOfEra = Year - Era * 400,
    DayOfYear = (153 * (Month + (if Month > 2 -> -3; true -> 9 end)) + 2) div 5 + Day - 1,
    DayOfEra = YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear,
    Era * 146097 + DayOfEra - 719468.

civil(Seconds) ->
    Days = floor_div(Seconds, ?DAY),
    OfDay = Seconds - Days * ?DAY,
    {date(Days), {OfDay div 3600, OfDay rem 3600 div 60, OfDay rem 60}}.

date(Days0) ->
    Days = Days0 + 719468,
    Era = floor_div(Days, 146097),
    DayOfEra = Days - Era * 146097,
    YearOfEra = (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365,
    DayOfYear = DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100),
    MonthIndex = (5 * DayOfYear + 2) div 153,
    Day = DayOfYear - (153 * MonthIndex + 2) div 5 + 1,
    Month = if MonthIndex < 10 -> MonthIndex + 3; true -> MonthIndex - 9 end,
    {YearOfEra + Era * 400 + (if Month =< 2 -> 1; true -> 0 end), Month, Day}.

floor_div(A, B) -> (A - floor_mod(A, B)) div B.

floor_mod(A, B) -> ((A rem B) + B) rem B.

%%% Formatting

-doc """
Time, in nanoseconds since 1970, written through Format as FreeBSD's
strftime(3) writes it in the C locale and in UTC, after date's own pass
over `%N` (date.c, strftime_ns): `%N` is the nanoseconds in nine digits,
`%nN` in n digits, cut or padded with zeros, and `%-N` in nine, the wall
clock's resolution being a nanosecond. A conversion strftime does not
know is written as its character alone, and a format that ends inside a
conversion as its last character, as strftime.c writes both.
""".
-spec format(binary(), integer()) -> binary().
format(Format, Time) ->
    Seconds = floor_div(Time, ?NS),
    iolist_to_binary(scan(Format, tm(Seconds, Time - Seconds * ?NS))).

%% The broken-down time strftime reads.
tm(Seconds, Nanoseconds) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = civil(Seconds),
    Days = floor_div(Seconds, ?DAY),
    #{year => Year, month => Month, day => Day, hour => Hour, minute => Minute, second => Second,
      yday => Days - days(Year, 1, 1), wday => floor_mod(Days + 4, 7), days => Days,
      seconds => Seconds, nanoseconds => Nanoseconds}.

scan(<<>>, _Tm) -> [];
scan(<<$%, Rest/binary>>, Tm) -> nanoseconds(Rest, Tm);
scan(<<C, Rest/binary>>, Tm) -> [C | scan(Rest, Tm)].

%% date's own pass: %N, %-N and %<digits>N; anything else goes to strftime.
nanoseconds(<<$-, $N, Rest/binary>>, Tm) ->
    [digits(Tm, 9) | scan(Rest, Tm)];
nanoseconds(Spec, Tm) ->
    case width(Spec, 0) of
        {Width, <<$N, Rest/binary>>} -> [digits(Tm, Width) | scan(Rest, Tm)];
        _ -> conversion(Spec, default, none, $%, Tm)
    end.

width(<<D, Rest/binary>>, Width) when ?IS_DIGIT(D), Width < 1000 -> width(Rest, Width * 10 + D - $0);
width(Rest, Width) -> {Width, Rest}.

digits(#{nanoseconds := Ns}, Width) when Width =:= 0; Width =:= 9 -> pad(Ns, 9, $0);
digits(#{nanoseconds := Ns}, Width) when Width > 9 -> [pad(Ns, 9, $0), lists:duplicate(Width - 9, $0)];
digits(#{nanoseconds := Ns}, Width) -> pad(Ns div pow10(9 - Width), Width, $0).

pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).

%% One strftime conversion after its %, with its padding flag (Pad) and
%% its E or O modifier (Alt), each taken once; Last is the character
%% before Spec, which a format ending here writes.
conversion(<<>>, _Pad, _Alt, Last, _Tm) ->
    [Last];
conversion(<<F, Rest/binary>>, default, Alt, _Last, Tm) when F =:= $-; F =:= $_; F =:= $0 ->
    conversion(Rest, pad_flag(F), Alt, F, Tm);
conversion(<<A, Rest/binary>>, Pad, none, _Last, Tm) when A =:= $E; A =:= $O ->
    conversion(Rest, Pad, A, A, Tm);
conversion(<<C, Rest/binary>>, Pad, _Alt, _Last, Tm) ->
    [convert(C, Pad, Tm) | scan(Rest, Tm)].

pad_flag($-) -> less;
pad_flag($_) -> space;
pad_flag($0) -> zero.

convert($A, _, #{wday := W}) -> element(W + 1, weekdays());
convert($a, _, #{wday := W}) -> binary:part(element(W + 1, weekdays()), 0, 3);
convert($B, _, #{month := M}) -> element(M, months());
convert(C, _, #{month := M}) when C =:= $b; C =:= $h -> binary:part(element(M, months()), 0, 3);
convert($C, _, #{year := Y}) -> century(Y);
convert($c, _, Tm) -> scan(<<"%a %b %e %H:%M:%S %Y">>, Tm);
convert($D, _, Tm) -> scan(<<"%m/%d/%y">>, Tm);
convert($d, Pad, #{day := D}) -> number(D, 2, $0, Pad);
convert($e, Pad, #{day := D}) -> number(D, 2, $\s, Pad);
convert($F, _, Tm) -> scan(<<"%Y-%m-%d">>, Tm);
convert($G, _, Tm) -> year4(iso_year(Tm));
convert($g, _, Tm) -> year2(iso_year(Tm));
convert($H, Pad, #{hour := H}) -> number(H, 2, $0, Pad);
convert($I, Pad, #{hour := H}) -> number(twelve(H), 2, $0, Pad);
convert($j, Pad, #{yday := D}) -> number(D + 1, 3, $0, Pad);
convert($k, Pad, #{hour := H}) -> number(H, 2, $\s, Pad);
convert($l, Pad, #{hour := H}) -> number(twelve(H), 2, $\s, Pad);
convert($M, Pad, #{minute := M}) -> number(M, 2, $0, Pad);
convert($m, Pad, #{month := M}) -> number(M, 2, $0, Pad);
convert($n, _, _) -> $\n;
convert($p, _, #{hour := H}) when H >= 12 -> <<"PM">>;
convert($p, _, _) -> <<"AM">>;
convert($R, _, Tm) -> scan(<<"%H:%M">>, Tm);
convert($r, _, Tm) -> scan(<<"%I:%M:%S %p">>, Tm);
convert($S, Pad, #{second := S}) -> number(S, 2, $0, Pad);
convert($s, _, #{seconds := S}) -> integer_to_binary(S);
convert($T, _, Tm) -> scan(<<"%H:%M:%S">>, Tm);
convert($t, _, _) -> $\t;
convert($U, Pad, #{yday := D, wday := W}) -> number((D + 7 - W) div 7, 2, $0, Pad);
convert($u, _, #{wday := 0}) -> $7;
convert($u, _, #{wday := W}) -> integer_to_binary(W);
convert($V, Pad, Tm) -> number(iso_week(Tm), 2, $0, Pad);
convert($v, _, Tm) -> scan(<<"%e-%b-%Y">>, Tm);
convert($W, Pad, #{yday := D, wday := W}) -> number((D + 7 - floor_mod(W - 1, 7)) div 7, 2, $0, Pad);
convert($w, _, #{wday := W}) -> integer_to_binary(W);
convert($X, _, Tm) -> scan(<<"%H:%M:%S">>, Tm);
convert($x, _, Tm) -> scan(<<"%m/%d/%y">>, Tm);
convert($Y, _, #{year := Y}) -> year4(Y);
convert($y, _, #{year := Y}) -> year2(Y);
convert($Z, _, _) -> <<"UTC">>;
convert($z, Pad, _) -> [$+, number(0, 4, $0, Pad)];
convert($+, _, Tm) -> scan(<<"%a %b %e %H:%M:%S %Z %Y">>, Tm);
convert(C, _, _) -> C.

weekdays() -> {<<"Sunday">>, <<"Monday">>, <<"Tuesday">>, <<"Wednesday">>, <<"Thursday">>, <<"Friday">>,
               <<"Saturday">>}.

months() -> {<<"January">>, <<"February">>, <<"March">>, <<"April">>, <<"May">>, <<"June">>, <<"July">>,
             <<"August">>, <<"September">>, <<"October">>, <<"November">>, <<"December">>}.

twelve(H) when H rem 12 =:= 0 -> 12;
twelve(H) -> H rem 12.

%% A number at its conversion's width, padded by its fill unless the
%% flag asks for none (`-`), spaces (`_`) or zeros (`0`).
number(N, _Width, _Fill, less) -> integer_to_binary(N);
number(N, Width, _Fill, space) -> pad(N, Width, $\s);
number(N, Width, _Fill, zero) -> pad(N, Width, $0);
number(N, Width, Fill, default) -> pad(N, Width, Fill).

pad(N, Width, Fill) ->
    Digits = integer_to_binary(N),
    [lists:duplicate(max(0, Width - byte_size(Digits)), Fill), Digits].

%% The year's century and its last two digits, as strftime.c's _yconv
%% splits tm_year and its base of 1900 with C's truncating division.
century(Year) -> element(1, yconv(Year)).

year2(Year) -> element(2, yconv(Year)).

year4(Year) -> [century(Year), year2(Year)].

yconv(Year) ->
    TmYear = Year - 1900,
    Trail = TmYear rem 100,
    {Lead, Last} = carry(TmYear div 100 + 19 + Trail div 100, Trail rem 100),
    Top = if Lead =:= 0, Last < 0 -> <<"-0">>; true -> two_digits(Lead) end,
    {Top, two_digits(abs(Last))}.

carry(Lead, Trail) when Trail < 0, Lead > 0 -> {Lead - 1, Trail + 100};
carry(Lead, Trail) when Lead < 0, Trail > 0 -> {Lead + 1, Trail - 100};
carry(Lead, Trail) -> {Lead, Trail}.

%% printf's %02d.
two_digits(N) when N < 0 -> [$-, integer_to_binary(-N)];
two_digits(N) -> pad(N, 2, $0).

%% ISO 8601's week and its year: the week's Thursday decides the year.
iso_thursday(#{days := Days, wday := W}) -> Days - floor_mod(W - 1, 7) + 3.

iso_year(Tm) -> element(1, date(iso_thursday(Tm))).

iso_week(Tm) -> (iso_thursday(Tm) - days(iso_year(Tm), 1, 1)) div 7 + 1.

%%% Effects

write_time(Ctx, Format, Time) ->
    erx_cmd:write(Ctx, [format(Format, Time), $\n]).

%% A set reads the monotonic clock and the wall time at one moment, and
%% sends the offset that makes the clock read the named time T at M.
set(Ctx, Operand, Format) ->
    case erx_cmd:facet(Ctx, clock) of
        {ok, Facet} ->
            Monotonic = os:perf_counter(nanosecond),
            Time = target(Operand, os:system_time(nanosecond)),
            case request(Facet, {set, Time - Monotonic}) of
                {ok, {stepped, _StepNs}} -> write_time(Ctx, Format, Time);
                {error, Reason} -> refused(Ctx, errno(Reason))
            end;
        {error, no_facet} ->
            refused(Ctx, eperm)
    end.

%% A facet that has already ended was sent nothing; one that ends or
%% stays silent past the wait may or may not have applied the set, as a
%% facet drops a request it refuses without an answer (erx_facet). The
%% system domain's own shell holds the service itself, `local`, which
%% takes no set through this path.
request(Facet, Request) when is_pid(Facet) ->
    try gen_server:call(Facet, Request, ?FACET_WAIT_MS)
    catch
        exit:{noproc, _} -> {error, unavailable};
        exit:_ -> {error, failed}
    end;
request(local, _Request) ->
    {error, unavailable}.

errno(badarg) -> einval;
errno(eperm) -> eperm;
errno(unavailable) -> eagain;
errno(unsupported) -> enotsup;
errno(limit) -> eoverflow;
errno(busy) -> ebusy;
errno(failed) -> eio.

refused(Ctx, Errno) ->
    erx_cmd:report(Ctx, <<"clock_settime">>, Errno),
    {error, {reported, <<"1">>}}.
