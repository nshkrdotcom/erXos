%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock_core).
-moduledoc """
The clock service's decisions (docs/design-time.md, "Steps" and "What it
changes"), pure: each takes a request the clock facet admitted, the
domain whose facet sent it, the time page as erx_clock_nif:read/0 read it
when the request arrived, and the service's record, and answers the next
action and the record that follows.

decide/4 answers either `{answer, Answer, Record1}`, the request's answer
with nothing to change, or `{step, Step, Record1}`, a step of the clock to
Step's wall offset, which the service applies through
erx_clock_nif:set_offset/1 and hands back with the setter's status to
applied/3 for the answer and the record.

* A sample, ntpd's `{sample, W, Distance, Stratum, Server}`, takes the
  first row of the Steps table whose condition holds, and every row
  stores it, its time and its source as the last sample.
* A set, the operator's `{set, W}`, steps to W whatever the page's
  coldness, the floor or the distance, and sets `excess` to none, so a
  sample held before it cannot step on one more sample after it; the
  sample attributes are left as they were.
* A real-time clock's reading, the wall-clock keeper's `{rtc, Wall}`
  in the system domain, the wall time the clock read at boot, steps the
  clock to read Wall while the clock is `unset` or `approximate`; a clock
  the boot's own reading gave a time (`boot`) or anything set this boot
  (`set`) keeps it, and a reading before the floor is refused, so it
  never steps the clock below the floor
  (docs/design-time.md, "The real-time clock at boot").

The floor is the build's date, build_floor/1 of its build facts: no sample
sets the clock before it (RFC 8633, section 5.2), and a clock that reads
before it when the service starts, as every boot without a real-time
clock does, starts at it (start/2, docs/design-time.md, "The approximate
start"). state/2 tells such a clock, `approximate`, from one set this
boot, and a sample meets an approximate clock as it meets one the boot
left alone.

The record's keys are the attributes the clock service reports at
`/proc/time/status` (docs/design-time.md, "What /proc shows"), but
`state`, the page's own, `excess`, the sign of the last held sample's
offset beyond 128 ms, and `floor`, the floor the service started with.
""".

-export([build_floor/1, new/2, state/2, start/2, decide/4, applied/3]).
-export_type([sample/0, facet_request/0, request/0, source/0, clock_record/0, step/0, answer/0, floor/0, state/0]).

-define(NS_PER_S, 1000000000).
%% Offsets of 128 ms and less are held; offsets of 1000 s and more refused.
-define(HOLD_NS, 128000000).
-define(PANIC_NS, (1000 * ?NS_PER_S)).

-type sample() :: {sample, W :: non_neg_integer(), Distance :: non_neg_integer(), Stratum :: 1..15,
                   Server :: inet:ip4_address()}.
%% What a domain's clock facet admits (erx_clock_facet:decode/1).
-type facet_request() :: sample() | {set, W :: non_neg_integer()}.
%% A facet's request, or the wall-clock keeper's reading, which no facet admits.
-type request() :: facet_request() | {rtc, Wall :: non_neg_integer()}.
%% The domain whose facet sent the request, from the facet, never the request.
-type source() :: pos_integer().
-type sign() :: positive | negative.
%% The floor in nanoseconds since 1970: the build's date, or 0 where the build
%% did not record it.
-type floor() :: non_neg_integer().
%% The clock's state, a fact of the time page and the floor (state/2).
-type state() :: unset | boot | approximate | set.
-type clock_record() :: #{floor := floor(), record_since := non_neg_integer(), excess := none | sign(),
                    sample_at := none | integer(), offset_ns := none | integer(),
                    distance_ns := none | non_neg_integer(), stratum := none | 1..15,
                    server := none | inet:ip4_address(), source := none | source(),
                    step_at := none | integer(), step_ns := none | integer(), step_source := none | source(),
                    step_error := none | erx_clock_nif:status(), steps := non_neg_integer(),
                    refused := non_neg_integer()}.
%% A step the service applies: the wall offset to store, its size from the page's
%% offset, the wall time the clock reads once it is applied, and who asked for it.
-type step() :: #{offset := non_neg_integer(), step_ns := integer(), at := integer(), source := source()}.
-type answer() :: {ok, {stepped, integer()} | held | {refused, floor | panic | boot | set}}
                | {error, erx_clock_nif:status()}.

-doc """
The floor of a build whose facts are Facts, as erx_build:facts/0 answers
them: the time of its source's commit, in nanoseconds; 0, which refuses
no sample and starts no clock, where the build did not record it.
""".
-spec build_floor({ok, erx_build:facts()} | {error, term()}) -> floor().
build_floor({ok, #{date := Date}}) when is_integer(Date) -> Date * ?NS_PER_S;
build_floor(_Facts) -> 0.

-doc """
The record of a service started at monotonic time Monotonic, in
nanoseconds, with floor Floor: nothing sampled or stepped yet.
""".
-spec new(non_neg_integer(), floor()) -> clock_record().
new(Monotonic, Floor) ->
    #{floor => Floor, record_since => Monotonic div ?NS_PER_S, excess => none,
      sample_at => none, offset_ns => none, distance_ns => none, stratum => none, server => none, source => none,
      step_at => none, step_ns => none, step_source => none, step_error => none, steps => 0, refused => 0}.

-doc """
The clock's state on Page with floor Floor: `unset` while nothing changed
the page this boot and its offset is zero, so wall time is the uptime
counted from 1970-01-01; `boot` while nothing changed it and its offset is
not zero, the boot's own reading; `approximate` while its offset is the
floor, where start/2 puts a clock that read before it, so wall time is the
build's date plus the uptime; `set` once anything else changed it.
""".
-spec state(erx_clock_nif:page(), floor()) -> state().
state(#{cold := true, offset := 0}, _Floor) -> unset;
state(#{cold := true}, _Floor) -> boot;
state(#{cold := false, offset := Floor}, Floor) when Floor > 0 -> approximate;
state(#{cold := false}, _Floor) -> set.

-doc """
The wall offset the service stores when it starts on Page with floor
Floor: the floor, when nothing changed the page this boot and the clock
reads before the floor, so it starts `approximate`; `none` for any other
page, one changed this boot or reading at or past the floor.
""".
-spec start(erx_clock_nif:page(), floor()) -> {step, floor()} | none.
start(#{cold := true, offset := C, monotonic := M}, Floor) when M + C < Floor -> {step, Floor};
start(_Page, _Floor) -> none.

-doc """
The next action for Request from Source, with Page the time page read when it
arrived: an answer, or a step for the service to apply and give to applied/3.
""".
-spec decide(request(), source(), erx_clock_nif:page(), clock_record()) ->
          {answer, answer(), clock_record()} | {step, step(), clock_record()}.
decide({set, W}, Source, Page, Record) ->
    {step, step(W, Source, Page), Record#{excess := none}};
decide({rtc, Wall}, Source, #{monotonic := M} = Page, Record = #{floor := Floor}) ->
    case rtc(Wall, M, state(Page, Floor), Floor) of
        {step, W} -> {step, step(W, Source, Page), Record};
        {refuse, Reason} -> {answer, {ok, {refused, Reason}}, Record}
    end;
decide({sample, W, Distance, Stratum, Server}, Source, #{offset := C, monotonic := M} = Page,
       #{floor := Floor} = Record) ->
    D = W - C,
    Sampled = Record#{sample_at := M + C, offset_ns := D, distance_ns := Distance, stratum := Stratum,
                      server := Server, source := Source},
    %% Cold: nothing but the boot and the start at the floor has changed the page.
    Cold = state(Page, Floor) =/= set,
    case row(M + W, Floor, Cold, D, maps:get(excess, Record)) of
        {refuse, Reason} ->
            {answer, {ok, {refused, Reason}}, Sampled#{excess := none, refused := maps:get(refused, Record) + 1}};
        step ->
            {step, step(W, Source, Page), Sampled#{excess := none}};
        {hold, Excess} ->
            {answer, {ok, held}, Sampled#{excess := Excess}}
    end.

-doc """
The answer to a step and the record after it, from Status, what
erx_clock_nif:set_offset/1 answered for it: an applied step is recorded and
counted; a refused one is recorded as the last step error.
""".
-spec applied(ok | {error, erx_clock_nif:status()}, step(), clock_record()) -> {answer(), clock_record()}.
applied(ok, #{step_ns := StepNs, at := At, source := Source}, #{steps := Steps} = Record) ->
    {{ok, {stepped, StepNs}}, Record#{step_at := At, step_ns := StepNs, step_source := Source, steps := Steps + 1}};
applied({error, Status}, _Step, Record) ->
    {{error, Status}, Record#{step_error := Status}}.

%% The first row of the Steps table whose condition holds, for a sample whose time is
%% Wall and whose offset from the page's is D.
row(Wall, Floor, _Cold, _D, _Excess) when Wall < Floor -> {refuse, floor};
row(_Wall, _Floor, true, _D, _Excess) -> step;
row(_Wall, _Floor, false, D, _Excess) when abs(D) =< ?HOLD_NS -> {hold, none};
row(_Wall, _Floor, false, D, Excess) when abs(D) < ?PANIC_NS ->
    case sign(D) of
        Excess -> step;
        Sign -> {hold, Sign}
    end;
row(_Wall, _Floor, false, _D, _Excess) -> {refuse, panic}.

%% The wall offset that makes the clock read Wall, a real-time clock's reading at boot,
%% at monotonic time M, on a clock in State with floor Floor. Only a clock with no time
%% of its own, `unset` or `approximate`, takes a reading: one that already has a time,
%% a boot's reading (`boot`) or a set (`set`), keeps it, since the reading is a start,
%% not a correction. A reading before the floor, or before the uptime since 1970 where
%% no floor is recorded, is no time the clock may read, so the clock never steps below
%% the floor.
rtc(Wall, M, State, Floor) when State =:= unset; State =:= approximate ->
    case Wall >= Floor andalso Wall >= M of
        true -> {step, Wall - M};
        false -> {refuse, floor}
    end;
rtc(_Wall, _M, State, _Floor) -> {refuse, State}.

sign(D) when D > 0 -> positive;
sign(_D) -> negative.

%% A step to wall offset W from the page's, which reads M + W once it is applied.
step(W, Source, #{offset := C, monotonic := M}) ->
    #{offset => W, step_ns => W - C, at => M + W, source => Source}.
