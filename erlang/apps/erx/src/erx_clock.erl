%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock).
-moduledoc """
The clock service (docs/design-time.md, "Who does what"), the wall clock's
one authority, in the system domain only: it names itself with
erx_facet:serve(clock, Pid), so the domain service mints each grantee's
clock facet (erx_clock_facet) in front of it, and each facet ends with it.
It is the one caller of erx_clock_nif:set_offset/1, which a chokepoint
check holds (tools/lib/erx/chokepoint_rules/clock.rb).

A facet forwards `{sample, Source, Sample}` or `{set, Source, W}`, Source
the grantee's domain. For each the service reads the time page, takes
erx_clock_core's decision, applies a step through the setter and answers
the facet; it keeps the record that decision leaves and logs each applied
set with the domain that asked for it. kernel's safe supervisor starts it
before the domain service, which reads the name when it mints.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-doc """
Starts the service in the system domain, the erXos runtime whose boot page
names the system domain's id and no system connection; `ignore` in every
other runtime, which serves no clock.
""".
-spec start_link() -> gen_server:start_ret() | ignore.
start_link() ->
    case erlang:system_info(os_type) =:= {unix, erxos} andalso erx_inspector:is_system_runtime() of
        true -> gen_server:start_link(?MODULE, [], []);
        false -> ignore
    end.

-doc false.
init([]) ->
    ok = erx_facet:serve(clock, self()),
    %% The monotonic clock the page's offset is added to, as date reads it.
    {ok, erx_clock_core:new(os:perf_counter(nanosecond))}.

-doc false.
handle_call({sample, Source, Sample}, _From, Record) ->
    request(Sample, Source, Record);
handle_call({set, Source, W}, _From, Record) ->
    request({set, W}, Source, Record);
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
logged(_Request, _Source, _Answer) ->
    ok.
