%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Whether processes on a normal scheduler run while a module is prepared
%% for loading, which erXos's ERTS does on a dirty CPU scheduler
%% (docs/design-runtime.md, edit 76). With one normal scheduler online, a
%% ticker at priority max wakes every millisecond and counts its wakes,
%% while this process prepares ?MODULE_LOADED ?LOADS times. A prepare on
%% the normal scheduler holds it for the whole call, so the ticker counts
%% nothing until the loads end; on a dirty scheduler the ticker runs
%% beside them, as the system domain's watchdog pet must.
%%
%% A module the loader refuses is reported to the caller's group leader, as
%% on a normal scheduler: the report's gl metadata is the caller's.
%%
%% main/0 prints "prepare loading: ms N ticks M", N the loads' elapsed
%% milliseconds and M the ticker's wakes during them, then "prepare loading:
%% report gl G", G caller when the refusal's report names the caller's
%% group leader and the report's gl otherwise, and halts with 0; a probe
%% that could not run prints its error and halts with 2.
-module(prepare_loading_probe).
-export([main/0]).
%% The logger handler that forwards the refusal's report to the probe.
-export([log/2]).

%% The largest module of OTP's applications, about a megabyte of code
%% and literals, so each prepare takes many milliseconds.
-define(MODULE_LOADED, unicode_util).
-define(LOADS, 10).

main() ->
    try {measure(), report_gl()} of
        {{Ms, Ticks}, Gl} ->
            io:format("prepare loading: ms ~b ticks ~b~n", [Ms, Ticks]),
            io:format("prepare loading: report gl ~p~n", [Gl]),
            erlang:halt(0)
    catch
        Class:Reason ->
            io:format("prepare loading: no result: ~p:~P~n", [Class, Reason, 20]),
            erlang:halt(2)
    end.

measure() ->
    {?MODULE_LOADED, Code, _File} = code:get_object_code(?MODULE_LOADED),
    _ = erlang:system_flag(schedulers_online, 1),
    Wakes = atomics:new(1, []),
    Ticker = spawn_opt(fun() -> tick(Wakes) end, [{priority, max}, link]),
    %% A fresh slice of reductions, so the loads below run without this
    %% process being scheduled out between them.
    erlang:yield(),
    Before = atomics:get(Wakes, 1),
    Start = erlang:monotonic_time(millisecond),
    ok = prepare(Code, ?LOADS),
    Ms = erlang:monotonic_time(millisecond) - Start,
    Ticks = atomics:get(Wakes, 1) - Before,
    unlink(Ticker),
    exit(Ticker, kill),
    {Ms, Ticks}.

prepare(_Code, 0) ->
    ok;
prepare(Code, N) ->
    Prepared = erlang:prepare_loading(?MODULE_LOADED, Code),
    true = is_reference(Prepared),
    prepare(Code, N - 1).

tick(Wakes) ->
    receive
    after 1 ->
        atomics:add(Wakes, 1, 1),
        tick(Wakes)
    end.

%% The gl of the report a refused module makes, caller when it is this
%% process's group leader, no_report when none comes.
report_gl() ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{probe => self()}}),
    {error, badfile} = erlang:prepare_loading(prepare_loading_refused, <<"FOR1", 0:32, "BEAM">>),
    Leader = group_leader(),
    receive
        {refusal_gl, Leader} -> caller;
        {refusal_gl, Other} -> Other
    after 5000 -> no_report
    end.

%% Forwards the emulator's reports, the loader's refusal among them.
log(#{meta := #{error_logger := #{emulator := true}} = Meta}, #{config := #{probe := Probe}}) ->
    Probe ! {refusal_gl, maps:get(gl, Meta, none)},
    ok;
log(_Event, _Config) ->
    ok.
