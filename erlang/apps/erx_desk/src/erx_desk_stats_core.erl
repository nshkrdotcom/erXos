%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_stats_core).
-moduledoc """
stats' core (docs/design-desktop-programs.md, "stats"): what the program
asks the inspector, when, and what the answers mean. It is a pure function
of its inputs, with time an input, so its tests feed recorded answers and
ticks; the window process (erx_desk_window) performs its effects.

A sample is one round of inspector queries. It asks `[]`, `[cpus]` and
`[domains]`; the CPU listing's answer asks `[cpus, N]` for each CPU listed,
and the domain listing's asks `[domains, Id]` and its `group`, `budget` and
`connections` for each domain listed. Each query carries a tag of its own,
and an answer whose tag the running sample does not wait for, such as a
duplicate, changes nothing. Once every query has answered, the sample is
complete: its answers become the latest readings, each stamped with the
sample's time, and the core asks for the next tick one period on. So a
tick that comes while a sample waits starts nothing, and a slow inspector
stretches the period instead of piling up queries.

A number is derived from readings (`derived()`): from the reading of one
path, or for a rate from the last reading and the new one, over the time
between them. A reading that is not `ok` or `partial` gives no value, a
gap, and its status as the reason, the worse of two by the order `error`,
`timeout`, `unsupported`, `unknown`; a `partial` reading gives a `partial`
value. A counter that went down gives the gap `reset`, a rate without a
last reading the gap `no_previous`, and a share whose denominator is zero
the gap that names the record's fact: `no_grant`, `no_cap`, `no_total` or
`no_cpus`.

Each measure keeps its latest derived number and a ring of the last 240
samples, oldest first, as the graph draws them. The ring holds only `ok`
values: anything else enters it as `none`, a gap, so an earlier partial
point never looks exact once later readings are `ok`. A share is in tenths
of a percent and enters the ring at most 1000, while its number keeps the
true value; a domain's memory enters the ring in pages, against its cap.

The domains are those the last listing names. A domain gone from a full
listing, or whose own record `[domains, Id]` answers `{error, scope}`
since it ended after the listing, ends its row and its readings, so one
that returns starts afresh; any other path's answer is a reading like
another. A partial listing keeps the rows it does not name, whose numbers
are then `unknown` gaps.

A domain's frames are the `frames` attribute of `[domains, Id,
connections]`, a count of frames accepted on each lane. abi/inspection.txt
declares no such path, and the inspector answers a path it does not
declare `{error, scope}`, so every domain's frames show that error.

Time is a monotonic clock in milliseconds, which each tick carries: a
rate is the growth between two readings over the time between their
samples, and an interval that is not positive gives no value. A session
without an inspect facet answers `no_facet`, and the core samples nothing
more.
""".

-export([init/0, step/2, model/1]).
-export_type([state/0, input/0, effect/0, derived/0, why/0, measure/0, row/0, model/0]).

%% The sampling period, the toolbar's default, in milliseconds.
-define(PERIOD, 1000).
%% The samples a ring holds.
-define(RING, 240).
%% A share of 100 percent, in tenths of a percent.
-define(WHOLE, 1000).

-type tag() :: non_neg_integer().
-type path() :: [atom() | non_neg_integer()].
-type answer() :: erx_inspector:answer().
-type time() :: integer().

-type input() :: {tick, Now :: time()}
               | {inspected, tag(), answer(), Read :: time()}
               | {failed, tag(), Reason :: term()}.
-type effect() :: {inspect, tag(), path()}
                | {tick_after, Ms :: non_neg_integer()}
                | {cancel, tag()}.

%% Why a number has no value: a reading's status, or a fact of the readings.
-type why() :: unknown | unsupported | {timeout, pos_integer()} | {error, term()}
             | reset | no_previous | no_grant | no_cap | no_total | no_cpus.
-type derived() :: {ok, term()} | {partial, term()} | {gap, why()}.
-type measure() :: #{latest := derived(), ring := [non_neg_integer() | none]}.
%% A domain's row. memory's number is a share of cap, its ring the pages
%% spent; cap and guarantee are the graph's maximum and mark.
-type row() :: #{name := derived(), state := derived(), run_queue := derived(),
                 processes := derived(), cpu := measure(), memory := measure(),
                 frames := measure(), cap := derived(), guarantee := derived()}.
%% What the window shows: while sampling, the machine's measures, the
%% domain listing's status, which the domains heading carries, and the rows;
%% memory_bytes is the machine's used and total. A session without an
%% inspect facet shows nothing else.
-type model() :: #{sampling := true,
                   machine := #{cpu => measure(), memory => measure(),
                                load => measure(), memory_bytes => derived()},
                   listing := ok | partial | {gap, why()},
                   domains := [{non_neg_integer(), row()}]}
               | #{sampling := false}.

%% A sample in flight: its time, the paths its queries ask by tag, and the
%% answers so far.
-type sample() :: #{time := time(), waiting := #{tag() => path()},
                    answers := #{path() => answer()}}.

%% sampling: false once the session has shown it has no inspect facet.
%% tag: the next query's tag. readings: the last answer of each path, with
%% the time of its sample.
-record(stats, {sampling = true :: boolean(),
                period = ?PERIOD :: pos_integer(),
                tag = 0 :: tag(),
                sample = none :: none | sample(),
                readings = #{} :: #{path() => {time(), answer()}},
                machine = #{} :: #{atom() => measure() | derived()},
                listing = {gap, unknown} :: derived(),
                domains = #{} :: #{non_neg_integer() => row()}}).

-opaque state() :: #stats{}.

-doc "A core that has sampled nothing, and its first tick, at once.".
-spec init() -> {state(), [effect()]}.
init() ->
    {#stats{}, [{tick_after, 0}]}.

-doc """
The next state and the effects to perform, in order, for Input: a tick
starts a sample unless one is in flight or sampling has stopped; an
answer, or a worker's failure as `{error, Reason}`, is recorded if the
running sample waits for its tag.
""".
-spec step(input(), state()) -> {state(), [effect()]}.
step({tick, Now}, #stats{sampling = true, sample = none} = State) ->
    ask([[], [cpus], [domains]],
        State#stats{sample = #{time => Now, waiting => #{}, answers => #{}}});
step({tick, _Now}, State) ->
    {State, []};
step({inspected, Tag, Answer, _Read}, State) ->
    answered(Tag, Answer, State);
step({failed, Tag, Reason}, State) ->
    answered(Tag, {error, Reason}, State).

-doc "What the window shows of State.".
-spec model(state()) -> model().
model(#stats{sampling = false}) ->
    #{sampling => false};
model(#stats{machine = Machine, listing = Listing, domains = Domains}) ->
    #{sampling => true, machine => Machine,
      listing => listing_status(Listing),
      domains => lists:sort(maps:to_list(Domains))}.

%%% Sampling.

answered(Tag, Answer, #stats{sample = #{waiting := Waiting} = Sample} = State)
  when is_map_key(Tag, Waiting) ->
    Path = maps:get(Tag, Waiting),
    Left = maps:remove(Tag, Waiting),
    case Answer of
        {error, no_facet} ->
            {State#stats{sampling = false, sample = none},
             [{cancel, Other} || Other <- lists:sort(maps:keys(Left))]};
        _ ->
            Answers = maps:put(Path, Answer, maps:get(answers, Sample)),
            Recorded = State#stats{sample = Sample#{waiting := Left,
                                                    answers := Answers}},
            {Asked, Effects} = ask(follow(Path, Answer), Recorded),
            finish(Asked, Effects)
    end;
answered(_Tag, _Answer, State) ->
    {State, []}.

%% The queries an answer leads to: each listed CPU's, and each listed
%% domain's four.
follow([cpus], Answer) ->
    [[cpus, N] || N <- listed(listing(Answer))];
follow([domains], Answer) ->
    [[domains, Id | Tail] || Id <- listed(listing(Answer)),
                             Tail <- [[], [group], [budget], [connections]]];
follow(_Path, _Answer) ->
    [].

%% Tags each of Paths with the next tag and asks it.
ask(Paths, #stats{tag = First, sample = #{waiting := Waiting} = Sample} = State) ->
    Tagged = lists:zip(lists:seq(First, First + length(Paths) - 1), Paths),
    Asked = maps:merge(Waiting, maps:from_list(Tagged)),
    {State#stats{tag = First + length(Paths), sample = Sample#{waiting := Asked}},
     [{inspect, Tag, Path} || {Tag, Path} <- Tagged]}.

%% Completes the sample once nothing is waiting, and asks for the next tick.
finish(#stats{sample = #{waiting := Waiting}} = State, Effects)
  when map_size(Waiting) > 0 ->
    {State, Effects};
finish(#stats{period = Period} = State, Effects) ->
    {complete(State), Effects ++ [{tick_after, Period}]}.

complete(#stats{sample = #{time := Now, answers := Answers}, readings = Last,
                machine = Machine, domains = Rows} = State) ->
    Listing = listing(maps:get([domains], Answers)),
    Ids = domains(Listing, Answers, Rows),
    Fresh = maps:map(fun(_Path, Answer) -> {Now, Answer} end, Answers),
    Readings = maps:filter(fun(Path, _) -> kept(Path, Ids) end,
                           maps:merge(Last, Fresh)),
    Row = fun(Id) -> row(Id, Last, Answers, Now, maps:get(Id, Rows, #{})) end,
    State#stats{sample = none, readings = Readings, listing = Listing,
                machine = machine(Last, Answers, Now, Machine),
                domains = maps:from_list([{Id, Row(Id)} || Id <- Ids])}.

%% The domains with rows after a sample: those the listing names, the rows
%% it does not name kept if it is partial and all of them if it failed, less
%% each whose record answered `{error, scope}` since the listing.
domains({ok, Listed}, Answers, _Rows) ->
    Listed -- ended(Answers);
domains({partial, Listed}, Answers, Rows) ->
    lists:usort(Listed ++ maps:keys(Rows)) -- ended(Answers);
domains({gap, _Why}, _Answers, Rows) ->
    maps:keys(Rows).

ended(Answers) ->
    lists:usort([Id || {[domains, Id], {error, scope}} <- maps:to_list(Answers)]).

kept([domains, Id | _], Ids) -> lists:member(Id, Ids);
kept(_Path, _Ids) -> true.

%%% Derivation.

machine(Last, Answers, Now, Machine) ->
    Cpus = listing(maps:get([cpus], Answers)),
    %% The listing joins each CPU number for its status alone.
    Idle = [increase([cpus, N], idle_time, Last, Answers, Now) || N <- listed(Cpus)],
    Busy = combine(fun([_Listed | Grown]) -> busy(Grown) end, [Cpus | Idle]),
    Ready = [attr([cpus, N], ready_threads, Answers) || N <- listed(Cpus)],
    Load = combine(fun([_Listed | Counts]) -> lists:sum(lists:map(fun total/1, Counts)) end,
                   [Cpus | Ready]),
    Memory = [attr([], memory_total, Answers), attr([], memory_free, Answers)],
    Share = combine(fun([Total, Free]) -> share(Total - Free, Total, no_total) end,
                    Memory),
    #{cpu => measure(Busy, share_point(Busy), maps:get(cpu, Machine, #{})),
      memory => measure(Share, share_point(Share), maps:get(memory, Machine, #{})),
      load => measure(Load, point(Load), maps:get(load, Machine, #{})),
      memory_bytes => combine(fun([Total, Free]) -> {Total - Free, Total} end, Memory)}.

%% The busy share of the CPUs: 1 less their idle time's growth over the
%% time between their readings.
busy([]) ->
    {gap, no_cpus};
busy(Idle) ->
    Grown = lists:sum([Ns || {Ns, _Ms} <- Idle]),
    Period = lists:sum([Ms || {_Ns, Ms} <- Idle]),
    max(0, ?WHOLE - Grown div (Period * 1000)).

row(Id, Last, Answers, Now, Row) ->
    Domain = [domains, Id],
    Group = Domain ++ [group],
    Budget = Domain ++ [budget],
    Used = increase(Group, used_ns, Last, Answers, Now),
    Cpu = combine(fun([{Ns, Ms}, Capacity]) -> grant_share(Ns, Ms, Capacity) end,
                  [Used, attr(Group, capacity_mcpu, Answers)]),
    Cap = attr(Budget, cap, Answers),
    Memory = [attr(Budget, spending, Answers), Cap],
    Share = combine(fun([Spending, Pages]) -> share(Spending, Pages, no_cap) end, Memory),
    Spent = combine(fun([_Spending, 0]) -> {gap, no_cap};
                       ([Spending, _Pages]) -> Spending
                    end, Memory),
    Frames = combine(fun([{Count, Ms}]) -> Count * 1000 div Ms end,
                     [increase(Domain ++ [connections], frames, Last, Answers, Now)]),
    #{name => attr(Domain, name, Answers), state => attr(Domain, state, Answers),
      run_queue => attr(Domain, run_queue, Answers),
      processes => attr(Domain, processes, Answers),
      cpu => measure(Cpu, share_point(Cpu), maps:get(cpu, Row, #{})),
      memory => measure(Share, point(Spent), maps:get(memory, Row, #{})),
      frames => measure(Frames, point(Frames), maps:get(frames, Row, #{})),
      cap => Cap, guarantee => attr(Budget, guarantee, Answers)}.

%% A group's use as a share of its grant of Capacity mCPU, in tenths of a
%% percent: Used ns over Ms ms times Capacity / 1000.
grant_share(_Used, _Ms, 0) -> {gap, no_grant};
grant_share(Used, Ms, Capacity) -> Used div (Ms * Capacity).

share(_Part, 0, Fact) -> {gap, Fact};
share(Part, Whole, _Fact) -> Part * ?WHOLE div Whole.

%% A counter's growth from the last reading of Path to this sample's, with
%% the milliseconds between them. attr/3 reads the last answer from a map
%% of its own.
increase(Path, Name, Last, Answers, Now) ->
    case Last of
        #{Path := {Then, Before}} ->
            combine(fun([Old, New]) -> grown(total(Old), total(New), Now - Then) end,
                    [attr(Path, Name, #{Path => Before}), attr(Path, Name, Answers)]);
        #{} ->
            {gap, no_previous}
    end.

grown(_Old, _New, Ms) when Ms =< 0 -> {gap, no_previous};
grown(Old, New, _Ms) when New < Old -> {gap, reset};
grown(Old, New, Ms) -> {New - Old, Ms}.

%% A count, or a list of counts summed: ready threads by urgency, frames by
%% lane.
total(Counts) when is_list(Counts) -> lists:sum(Counts);
total(Count) -> Count.

%% The value Fun makes of the values of Derived, `partial` if any of them
%% is; the worst reason if any is a gap.
combine(Fun, Derived) ->
    case [Why || {gap, Why} <- Derived] of
        [] ->
            Status = case lists:keymember(partial, 1, Derived) of
                         true -> partial;
                         false -> ok
                     end,
            case Fun([Value || {_Status, Value} <- Derived]) of
                {gap, Why} -> {gap, Why};
                Value -> {Status, Value}
            end;
        Whys ->
            {gap, lists:last(lists:sort(fun(A, B) -> rank(A) =< rank(B) end, Whys))}
    end.

%% The order of the reasons, the worst last: the inspector's statuses above
%% the facts of the readings.
rank({error, _}) -> 7;
rank({timeout, _}) -> 6;
rank(unsupported) -> 5;
rank(unknown) -> 4;
rank(reset) -> 3;
rank(no_previous) -> 2;
rank(no_grant) -> 1;
rank(no_cap) -> 1;
rank(no_total) -> 1;
rank(no_cpus) -> 1.

%%% Readings.

%% The attribute Name of Path's answer among Answers: unknown when the
%% record leaves it out or the sample did not ask for Path.
attr(Path, Name, Answers) ->
    case Answers of
        #{Path := {ok, #{attrs := #{Name := {_Reporter, Value}}}}} -> value(Value);
        #{Path := {ok, _Record}} -> {gap, unknown};
        #{Path := Failure} -> failure(Failure);
        #{} -> {gap, unknown}
    end.

value({ok, Value}) -> {ok, Value};
value({partial, Value}) -> {partial, Value};
value(Status) -> {gap, Status}.

failure({error, unsupported}) -> {gap, unsupported};
failure({error, Reason}) -> {gap, {error, Reason}}.

%% A listing's children as a derived value.
listing({ok, #{children := Children}}) when is_list(Children) -> {ok, Children};
listing({ok, #{children := {partial, Children}}}) -> {partial, Children};
listing({ok, #{children := unknown}}) -> {gap, unknown};
listing(Failure) -> failure(Failure).

listed({gap, _Why}) -> [];
listed({_Status, Children}) -> Children.

listing_status({gap, Why}) -> {gap, Why};
listing_status({Status, _Children}) -> Status.

%%% Rings.

measure(Latest, Point, Measure) ->
    Grown = maps:get(ring, Measure, []) ++ [Point],
    Ring = case length(Grown) > ?RING of
               true -> tl(Grown);
               false -> Grown
           end,
    #{latest => Latest, ring => Ring}.

%% What a derived number puts in its ring: an `ok` value, a share at most
%% 100 percent; anything else a gap.
share_point({ok, Share}) -> min(Share, ?WHOLE);
share_point(_Derived) -> none.

point({ok, Value}) -> Value;
point(_Derived) -> none.
