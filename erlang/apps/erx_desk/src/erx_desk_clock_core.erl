%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_clock_core).
-moduledoc """
clock's core (docs/design-desktop-programs.md, "clock"): when the program
reads the time, what it asks the inspector and what it shows. It is a pure
function of its inputs, with the wall clock an input that each tick and
each inspection's answer carries; the window process (erx_desk_window)
performs its effects.

A tick is a reading. Each tick asks the inspector for `[time]`, whose
`state` says whether the wall clock is `set`, read at `boot` from the
real-time clock, started `approximate` at the build date or `unset`, and
for `[]`, whose `uptime` an unset clock
shows instead of a date, since an unset clock's reading is the time since
boot counted from 1970. The reading is shown once both have answered or
failed; until then the window keeps showing the last one, so a minute
changes the tree once. A tick that comes while the last one's answers
wait cancels them, and an answer whose tag the core does not wait for
changes nothing.

A reading's wall time is the one read after `[time]` answered, which the
answer carries, so the state is read before the wall clock: the state
only moves forward within a boot, and a clock set between the two reads
shows as unset for one more minute, never the time since boot as a set
date. A `[time]` worker that failed gives no such reading, and its
failure's token is shown beside the wall time the tick read.

Each tick also asks for the next: the delay from its own reading to the
start of the next minute, so the timer never drifts across minutes and a
step of the wall clock is shown by the first tick after it. The core keeps
that deadline, the wall time of the next minute's start, and
next_deadline/1 answers it. An early tick, after a step back, is not
dropped: it shows the minute its reading gives.

What clock shows by the state (the design's table): `set` the time and
date; `boot` the same and "from the real-time clock"; `approximate` the
same and "approximate, from the build date"; `unset` `--:--`,
"Clock not set" and the minutes since boot; and a state that is not `ok`
the time and date with the status token beside the zone. Every status
reaches the tree as an `attr()` the widget schema takes: the reporter the
inspector gave, or `kernel`, the reporter abi/inspection.txt declares for
`state` and `uptime`, where the whole query failed; a value that is not a
state or a count is `unknown`. erXos has no time zone setting, so clock
shows UTC and says so.
""".

-export([init/1, step/2, view/1, next_deadline/1]).
-export_type([state/0, input/0, effect/0]).

-define(MINUTE, 60000).
-define(MINUTE_NS, 60000000000).

-type tag() :: non_neg_integer().
-type time() :: non_neg_integer().
-type answer() :: erx_inspector:answer().
-type attr() :: {Reporter :: term(), Value :: term()}.

-doc "An input, as the window process delivers it.".
-type input() :: {tick, Now :: time()}
               | {inspected, tag(), answer(), Read :: time()}
               | {failed, tag(), Reason :: term()}.
-doc "An effect, from design-desktop-programs' closed set.".
-type effect() :: {inspect, tag(), [atom()]}
                | {tick_after, Ms :: non_neg_integer()}
                | {cancel, tag()}.

%% Which record an inspection asks: `[time]` or `[]`.
-type which() :: time | machine.
%% A reading: its wall time (see wall/3) and the answers of its inspections.
-type reading() :: #{now := time(), time := answer(), machine := answer()}.
%% A tick whose inspections wait: its reading so far, `now` the tick's own
%% wall reading until `[time]` answers and that answer's after, and the
%% tags it waits for.
-type pending() :: #{now := time(), waiting := #{tag() => which()},
                     answers := #{which() => answer()}}.

%% tag: the next inspection's tag. shown: the last complete reading.
%% deadline: the wall time of the tick asked for; 0, already due, before
%% the first tick.
-record(clock, {tag = 0 :: tag(),
                shown = none :: none | reading(),
                pending = none :: none | pending(),
                deadline = 0 :: time()}).

-opaque state() :: #clock{}.

-doc "A clock that has read nothing, and its first tick, at once.".
-spec init(#{}) -> {state(), [effect()]}.
init(#{}) ->
    {#clock{}, [{tick_after, 0}]}.

-doc """
The next state and the effects to perform, in order, for Input: a tick
cancels the inspections still waiting, asks for `[time]` and `[]` and for
the next tick; an answer, or a worker's failure as `{error, Reason}`, is
recorded if the tick waits for its tag.
""".
-spec step(input(), state()) -> {state(), [effect()]}.
step({tick, Now}, #clock{tag = Tag, pending = Pending} = State) ->
    Delay = ?MINUTE - Now rem ?MINUTE,
    Cancels = [{cancel, Old} || Old <- maps:keys(waiting(Pending))],
    {State#clock{tag = Tag + 2,
                 pending = #{now => Now, waiting => #{Tag => time, Tag + 1 => machine}, answers => #{}},
                 deadline = Now + Delay},
     Cancels ++ [{inspect, Tag, [time]}, {inspect, Tag + 1, []}, {tick_after, Delay}]};
step({inspected, Tag, Answer, Read}, State) ->
    {answered(Tag, Answer, Read, State), []};
step({failed, Tag, Reason}, State) ->
    {answered(Tag, {error, Reason}, none, State), []}.

-doc "The wall time, in milliseconds, of the tick State has asked for.".
-spec next_deadline(state()) -> time().
next_deadline(#clock{deadline = Deadline}) ->
    Deadline.

-doc "The window's tree for State.".
-spec view(state()) -> erx_ui_schema:tree().
view(#clock{shown = none}) ->
    face(<<"--:--">>, [utc()]);
view(#clock{shown = #{now := Now, time := Time, machine := Machine}}) ->
    case clock_state(attr(Time, state)) of
        unset -> unset_face(Machine);
        boot -> dated(Now, utc(), [label(<<"from the real-time clock">>, caption)]);
        approximate -> dated(Now, utc(), [label(<<"approximate, from the build date">>, caption)]);
        set -> dated(Now, utc(), []);
        {token, Token} -> dated(Now, {row, #{}, [utc(), label(Token, caption)]}, [])
    end.

%%% Readings.

waiting(none) -> #{};
waiting(#{waiting := Waiting}) -> Waiting.

%% Records Answer if the pending tick waits for Tag, and shows the reading
%% once nothing more is waited for. Read, the wall clock read after the
%% answer or `none` for a failed worker, becomes the reading's wall time
%% when the answer is `[time]`'s.
answered(Tag, Answer, Read, #clock{pending = #{now := Ticked, waiting := Waiting, answers := Answers}} = State)
  when is_map_key(Tag, Waiting) ->
    {Which, Rest} = maps:take(Tag, Waiting),
    Got = Answers#{Which => Answer},
    Now = wall(Which, Read, Ticked),
    case map_size(Rest) of
        0 -> State#clock{pending = none, shown = Got#{now => Now}};
        _ -> State#clock{pending = #{now => Now, waiting => Rest, answers => Got}}
    end;
answered(_Tag, _Answer, _Read, State) ->
    State.

%% The reading's wall time: the one read after `[time]` answered, else the
%% one its tick read.
wall(time, Read, _Ticked) when is_integer(Read) -> Read;
wall(_Which, _Read, Ticked) -> Ticked.

%% The attribute Name of a record answer, as {Reporter, Value}; a query
%% that failed is reported under `kernel`, the attribute's declared
%% reporter.
-spec attr(answer(), atom()) -> attr().
attr({ok, #{attrs := #{} = Attrs}}, Name) when is_map_key(Name, Attrs) ->
    case maps:get(Name, Attrs) of
        {_Reporter, _Value} = Attr -> Attr;
        _Other -> {kernel, unknown}
    end;
attr({ok, _Record}, _Name) -> {kernel, unknown};
attr({error, unsupported}, _Name) -> {kernel, unsupported};
attr({error, Reason}, _Name) -> {kernel, {error, Reason}}.

clock_state({_Reporter, {ok, State}})
  when State =:= unset; State =:= boot; State =:= approximate; State =:= set ->
    State;
clock_state({Reporter, Value}) ->
    {token, token(Reporter, Value)}.

%% A status as the tree shows it: a status the widget schema carries kept,
%% any other value unknown.
token(Reporter, unknown) -> {Reporter, unknown};
token(Reporter, unsupported) -> {Reporter, unsupported};
token(Reporter, {timeout, Ms}) when is_integer(Ms), Ms >= 1, Ms =< 16#ffffffff -> {Reporter, {timeout, Ms}};
token(Reporter, {error, Reason}) -> {Reporter, {error, Reason}};
token(Reporter, _Value) -> {Reporter, unknown}.

%%% The tree.

face(Time, Rest) ->
    {column, #{}, [label(Time, display) | Rest]}.

utc() ->
    label(<<"UTC">>, caption).

label(Text, Role) ->
    {label, #{text => Text, role => Role}, []}.

%% The time and date of wall reading Now, the zone line Zone and Extra.
dated(Now, Zone, Extra) ->
    {{Year, Month, Day} = Date, {Hour, Minute, _Second}} =
        calendar:system_time_to_universal_time(Now, millisecond),
    Time = iolist_to_binary(io_lib:format("~2..0B:~2..0B", [Hour, Minute])),
    Shown = iolist_to_binary([weekday(calendar:day_of_the_week(Date)), $\s, integer_to_binary(Day), $\s,
                              month(Month), $\s, integer_to_binary(Year)]),
    face(Time, [label(Shown, body), Zone | Extra]).

%% An unset clock: no time, and the minutes since boot from the machine
%% record's uptime, or that reading's status.
unset_face(Machine) ->
    Since = case attr(Machine, uptime) of
                {_Reporter, {ok, Ns}} when is_integer(Ns), Ns >= 0 -> since(Ns);
                {Reporter, {partial, Ns}} when is_integer(Ns), Ns >= 0 -> {Reporter, {partial, since(Ns)}};
                {Reporter, Value} -> token(Reporter, Value)
            end,
    face(<<"--:--">>, [label(<<"Clock not set">>, body), label(Since, caption)]).

since(Ns) ->
    case Ns div ?MINUTE_NS of
        1 -> <<"1 minute since boot">>;
        Minutes -> <<(integer_to_binary(Minutes))/binary, " minutes since boot">>
    end.

weekday(N) ->
    element(N, {<<"Monday">>, <<"Tuesday">>, <<"Wednesday">>, <<"Thursday">>, <<"Friday">>,
                <<"Saturday">>, <<"Sunday">>}).

month(N) ->
    element(N, {<<"January">>, <<"February">>, <<"March">>, <<"April">>, <<"May">>, <<"June">>,
                <<"July">>, <<"August">>, <<"September">>, <<"October">>, <<"November">>,
                <<"December">>}).
