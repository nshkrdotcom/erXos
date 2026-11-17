%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock).
-moduledoc """
The clock service (docs/design-time.md, "Who does what"), the wall clock's
one authority, in the system domain only, registered as erx_clock. Its
supervisor, erx_clock_sup (erx_service_sup), is the server of the `clock`
interface (erx_facet:serve/2), so the domain service mints each grantee's
clock facet (erx_clock_facet) in front of the supervisor, and each facet
outlives the service's restarts, finding erx_clock by its name at each
request. It is the one caller of
erx_clock_nif:set_offset/1, which a chokepoint check holds
(tools/lib/erx/chokepoint_rules/clock.rb).

When it starts on a clock that reads before the build's date, the floor
of erx_clock_core, it sets the clock to that date, `approximate`, so
certificate checks work before anyone sets the time.

A facet forwards `{sample, Source, Sample}` or `{set, Source, W}`, Source
the grantee's domain, and the wall-clock keeper of this domain sends
`{rtc, Source, Wall}` once at boot, a real-time clock's reading, Source
this domain (docs/design-time.md, "The real-time clock at boot"). For each the service reads the time page, takes
erx_clock_core's decision, applies a step through the setter and answers
the facet; it keeps the record that decision leaves and logs each applied
set with the domain that asked for it. kernel_safe_sup starts erx_clock_sup
before the domain service, which reads the server when it mints.

The collector of `[time]` in this domain asks it for its record (record/1,
erx_time_records); no facet forwards that question.
""".
-behaviour(gen_server).

-export([start_link/0, record/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-doc "Starts the service, registered as erx_clock; erx_clock_sup runs it, in the system domain only.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
The service's record, erx_clock_core's, waiting at most Wait milliseconds;
exits as gen_server:call/3 does when the service is not running or does not
answer in time.
""".
-spec record(pos_integer()) -> {ok, erx_clock_core:clock_record()}.
record(Wait) ->
    gen_server:call(?MODULE, record, Wait).

-doc false.
init([]) ->
    Floor = start_at_floor(erx_build:facts()),
    %% The monotonic clock the page's offset is added to, as date reads it.
    {ok, erx_clock_core:new(os:perf_counter(nanosecond), Floor)}.

%% A clock that reads before the build's date when the service starts, as every
%% boot without a real-time clock does, starts at it, approximate
%% (docs/design-time.md, "The approximate start"). A restart finds the page
%% approximate or set and leaves it. Answers the floor, which a build without
%% a date leaves 0: no floor and no start, which is worth a line.
start_at_floor(Facts) ->
    Floor = erx_clock_core:build_floor(Facts),
    case Floor of
        0 -> logger:warning("erx_clock: the build facts give no date (~0p): no floor", [Facts]);
        _ -> ok
    end,
    case erx_clock_nif:read() of
        {ok, Page} -> apply_start(erx_clock_core:start(Page, Floor));
        {error, limit} -> ok
    end,
    Floor.

apply_start({step, W}) ->
    Date = calendar:system_time_to_rfc3339(W, [{unit, nanosecond}, {offset, "Z"}]),
    case erx_clock_nif:set_offset(W) of
        ok -> logger:notice("erx_clock: clock not set, started at the build date ~s, approximate", [Date]);
        {error, Status} -> logger:warning("erx_clock: starting at the build date ~s refused: ~p", [Date, Status])
    end;
apply_start(none) ->
    ok.

-doc false.
handle_call({sample, Source, Sample}, _From, Record) ->
    request(Sample, Source, Record);
handle_call({set, Source, W}, _From, Record) ->
    request({set, W}, Source, Record);
handle_call({rtc, Source, Wall}, _From, Record) when is_integer(Wall), Wall >= 0 ->
    request({rtc, Wall}, Source, Record);
handle_call(record, _From, Record) ->
    {reply, {ok, Record}, Record};
handle_call(_Request, _From, Record) ->
    {reply, {error, badarg}, Record}.

-doc false.
handle_cast(_Cast, Record) ->
    {noreply, Record}.

request(Request, Source, Record) ->
    case erx_clock_nif:read() of
        {ok, Page} ->
            {Answer, Record1} = decided(erx_clock_core:decide(Request, Source, Page, Record)),
            logged(Request, Source, Answer),
            {reply, Answer, Record1};
        {error, limit} ->
            {reply, {error, limit}, Record}
    end.

decided({answer, Answer, Record}) ->
    {Answer, Record};
decided({step, #{offset := W} = Step, Record}) ->
    erx_clock_core:applied(erx_clock_nif:set_offset(W), Step, Record).

%% A set is the operator's word, so its line names who said it, as FreeBSD's date
%% logs "date set by" its user (bin/date/date.c).
logged({set, _W}, Source, {ok, {stepped, StepNs}}) ->
    logger:notice("erx_clock: clock set by domain ~b, stepped ~b ns", [Source, StepNs]);
logged({rtc, Wall}, _Source, Answer) ->
    Date = calendar:system_time_to_rfc3339(Wall, [{unit, nanosecond}, {offset, "Z"}]),
    logger:notice("erx_clock: the real-time clock reads ~s: ~0p", [Date, Answer]);
logged(_Request, _Source, _Answer) ->
    ok.
