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

The record's keys are the attributes the clock service reports at
`/proc/time/status` (docs/design-time.md, "What /proc shows"), but
`state`, the page's own, and `excess`, the sign of the last held sample's
offset beyond 128 ms.
""".

-export([new/1, decide/4, applied/3]).
-export_type([request/0, source/0, clock_record/0, step/0, answer/0]).

-define(NS_PER_S, 1000000000).
%% Offsets of 128 ms and less are held; offsets of 1000 s and more refused.
-define(HOLD_NS, 128000000).
-define(PANIC_NS, (1000 * ?NS_PER_S)).
%% The floor, 2026-11-16 00:00:00 UTC, the date of the system release's source,
%% raised when a release is made: no sample sets the clock before it (RFC 8633,
%% section 5.2).
-define(FLOOR_NS, (1794787200 * ?NS_PER_S)).

-type request() :: {sample, W :: non_neg_integer(), Distance :: non_neg_integer(), Stratum :: 1..15,
                    Server :: inet:ip4_address()}
                 | {set, W :: non_neg_integer()}.
%% The domain whose facet sent the request, from the facet, never the request.
-type source() :: pos_integer().
-type sign() :: positive | negative.
-type clock_record() :: #{record_since := non_neg_integer(), excess := none | sign(),
                    sample_at := none | integer(), offset_ns := none | integer(),
                    distance_ns := none | non_neg_integer(), stratum := none | 1..15,
                    server := none | inet:ip4_address(), source := none | source(),
                    step_at := none | integer(), step_ns := none | integer(), step_source := none | source(),
                    step_error := none | erx_clock_nif:status(), steps := non_neg_integer(),
                    refused := non_neg_integer()}.
%% A step the service applies: the wall offset to store, its size from the page's
%% offset, the wall time the clock reads once it is applied, and who asked for it.
-type step() :: #{offset := non_neg_integer(), step_ns := integer(), at := integer(), source := source()}.
-type answer() :: {ok, {stepped, integer()} | held | {refused, floor | panic}}
                | {error, erx_clock_nif:status()}.

-doc "The record of a service started at monotonic time Monotonic, in nanoseconds: nothing sampled or stepped yet.".
-spec new(non_neg_integer()) -> clock_record().
new(Monotonic) ->
    #{record_since => Monotonic div ?NS_PER_S, excess => none,
      sample_at => none, offset_ns => none, distance_ns => none, stratum => none, server => none, source => none,
      step_at => none, step_ns => none, step_source => none, step_error => none, steps => 0, refused => 0}.

-doc """
The next action for Request from Source, with Page the time page read when it
arrived: an answer, or a step for the service to apply and give to applied/3.
""".
-spec decide(request(), source(), erx_clock_nif:page(), clock_record()) ->
          {answer, answer(), clock_record()} | {step, step(), clock_record()}.
decide({set, W}, Source, Page, Record) ->
    {step, step(W, Source, Page), Record#{excess := none}};
decide({sample, W, Distance, Stratum, Server}, Source, #{offset := C, cold := Cold, monotonic := M} = Page,
       Record) ->
    D = W - C,
    Sampled = Record#{sample_at := M + C, offset_ns := D, distance_ns := Distance, stratum := Stratum,
                      server := Server, source := Source},
    case row(M + W, Cold, D, maps:get(excess, Record)) of
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
row(Wall, _Cold, _D, _Excess) when Wall < ?FLOOR_NS -> {refuse, floor};
row(_Wall, true, _D, _Excess) -> step;
row(_Wall, false, D, _Excess) when abs(D) =< ?HOLD_NS -> {hold, none};
row(_Wall, false, D, Excess) when abs(D) < ?PANIC_NS ->
    case sign(D) of
        Excess -> step;
        Sign -> {hold, Sign}
    end;
row(_Wall, false, _D, _Excess) -> {refuse, panic}.

sign(D) when D > 0 -> positive;
sign(_D) -> negative.

%% A step to wall offset W from the page's, which reads M + W once it is applied.
step(W, Source, #{offset := C, monotonic := M}) ->
    #{offset => W, step_ns => W - C, at => M + W, source => Source}.
