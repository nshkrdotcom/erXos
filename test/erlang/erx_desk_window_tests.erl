%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_window_tests).
-moduledoc """
EUnit cases of a desktop program's window process (docs/design-desktop-programs.md,
"The construction", D9 and the "window: lifetime" row of "Verification and
testing"), and of erx_desk:reload/1.

The window opens its UI on erx_ui_host's stand-in, which this module plays:
a process registered under that name hands erx_ui:open/1 this module as
the renderer, which reports each apply to the test process and whose
reader, linked to the widget server, the test ends to end the UI as a
window closed from the menu does. The window performs its inspections
through an inspector model, a function the test gives it, which reports
each query and its worker to the test and then answers, hangs or
crashes. The core is this module too: it asks two inspections at once,
reports each input to the test, cancels the slow one when the fast one
answers and closes on a failure.
""".
-behaviour(erx_ui_renderer).

-include_lib("eunit/include/eunit.hrl").

-export([start/3, apply/2, stop/1]).
-export([init/1, step/2, view/1]).

-define(WAIT_MS, 5000).

%%% The renderer.

start(_Target, _Server, #{test := Test} = Opts) ->
    Reader = spawn_link(fun() -> receive {end_reader, Why} -> exit(Why) end end),
    Test ! {reader, Reader},
    {ok, Opts}.

apply(Ops, #{test := Test} = State) ->
    Test ! {applied, Ops},
    {ok, State}.

stop(#{test := Test}) ->
    Test ! renderer_stopped,
    ok.

%%% The core.

init(#{test := Test, paths := Paths}) ->
    {Test, [{inspect, Tag, Path} || {Tag, Path} <- lists:enumerate(Paths)]}.

step(Input, Test) ->
    Test ! {input, Input},
    case Input of
        {inspected, 2, _Answer, _Now} -> {Test, [{cancel, 1}]};
        {failed, _Tag, _Reason} -> {Test, [close]};
        _Other -> {Test, []}
    end.

view(_Test) ->
    {label, #{text => <<"probe">>}, []}.

%%% The cases.

window_test_() ->
    {foreach,
     fun() -> {ok, Sup} = erx_ui_sup:start_link(), unlink(Sup), Sup end,
     fun(Sup) ->
             exit(whereis(erx_ui_host), kill),
             exit(Sup, shutdown),
             wait_gone(Sup)
     end,
     [fun closing_a_window_ends_its_workers/0,
      fun a_cancelled_worker_is_killed_and_sends_nothing/0,
      fun a_crashed_worker_fails_its_request/0,
      fun an_answer_carries_the_wall_clock_read_after_it/0,
      fun reload_presents_the_new_view_of_the_kept_state/0,
      fun the_command_opens_a_window_or_says_why_not/0]}.

%% A window with two workers in flight, closed from the menu, ends with
%% `shutdown`, and both workers end with it.
closing_a_window_ends_its_workers() ->
    serve(),
    Window = window(hang(self()), [[one], [two]]),
    Reader = receive {reader, R} -> R after ?WAIT_MS -> error(no_reader) end,
    Workers = [asked([one]), asked([two])],
    Watched = [monitor(process, Pid) || Pid <- [Window | Workers]],
    Reader ! {end_reader, closed},
    [WindowDown | WorkersDown] = [down(Ref) || Ref <- Watched],
    ?assertEqual(shutdown, WindowDown),
    ?assertEqual([shutdown, shutdown], WorkersDown).

%% Cancelling the slow worker when the fast one answers, once the test lets
%% it, kills it, and no
%% input of its request follows.
a_cancelled_worker_is_killed_and_sends_nothing() ->
    serve(),
    Test = self(),
    Hang = hang(Test),
    Window = window(fun(Path, Options) ->
                            case Path of
                                [fast] -> Test ! {asked, Path, self()},
                                          receive go -> {ok, fast} end;
                                [slow] -> Hang(Path, Options)
                            end
                    end, [[slow], [fast]]),
    Slow = asked([slow]),
    Ref = monitor(process, Slow),
    asked([fast]) ! go,
    ?assertMatch({input, {inspected, 2, {ok, fast}, _Now}}, input()),
    ?assertEqual(killed, down(Ref)),
    ?assertEqual(nothing, input_or_nothing()),
    ?assert(is_process_alive(Window)).

%% A worker that crashes, here by an exit the emulator does not log, gives its request's failure, here the core's
%% close: the window closes its UI and ends with `shutdown`.
a_crashed_worker_fails_its_request() ->
    serve(),
    Window = window(fun(Path, _Options) -> exit({crashed, Path}) end, [[one]]),
    Ref = monitor(process, Window),
    ?assertEqual({input, {failed, 1, {crashed, [one]}}}, input()),
    ?assertEqual(shutdown, down(Ref)),
    receive renderer_stopped -> ok after ?WAIT_MS -> error(not_closed) end.

%% An inspection's answer carries the wall clock read after the inspector
%% answered: the model waits, then answers with the wall clock it read,
%% and the answer's reading is no earlier.
an_answer_carries_the_wall_clock_read_after_it() ->
    serve(),
    _Window = window(fun(_Path, _Options) ->
                             timer:sleep(20),
                             {ok, os:system_time(millisecond)}
                     end, [[one]]),
    {input, {inspected, 1, {ok, Answered}, Read}} = input(),
    ?assert(Read >= Answered).

%% erx_desk:reload/1 has each open window of a program present its core's
%% newest view of the state the window holds: the probe ticked before the
%% reload, and the new view keeps that and adds a label.
reload_presents_the_new_view_of_the_kept_state() ->
    serve(),
    {ok, DeskSup} = erx_desk_sup:start_link(),
    unlink(DeskSup),
    try
        load_probe(<<>>),
        ok = erx_desk:open(probe),
        ?assertMatch([{insert, _, 0, 0, column, #{}}, {insert, _, _, 0, label, #{text := <<"start">>}}, commit],
                     applied()),
        ?assertMatch([{set, _, #{text := <<"ticked">>}, []}, commit], applied()),
        load_probe(<<", {label, #{text => <<\"reloaded\">>}, []}">>),
        ok = erx_desk:reload(probe),
        ?assertMatch([{insert, _, _, 1, label, #{text := <<"reloaded">>}}, commit], applied())
    after
        exit(DeskSup, shutdown),
        wait_gone(DeskSup)
    end.

%% The command clock takes no arguments, says `no display` where no
%% display answers, and otherwise returns once one more window is open.
the_command_opens_a_window_or_says_why_not() ->
    {ok, DeskSup} = erx_desk_sup:start_link(),
    unlink(DeskSup),
    try
        ?assertEqual({error, usage}, erx_desk_cmd_clock:run([<<"now">>], #{})),
        ?assertEqual({error, <<"no display">>}, erx_desk_cmd_clock:run([], #{})),
        ?assertEqual([], erx_desk_sup:windows()),
        serve(),
        ?assertEqual(ok, erx_desk_cmd_clock:run([], #{})),
        ?assertEqual(ok, erx_desk_cmd_clock:run([], #{})),
        ?assertMatch([_, _], erx_desk_sup:windows())
    after
        exit(DeskSup, shutdown),
        wait_gone(DeskSup)
    end.

%%% Helpers.

%% erx_ui_host's stand-in for the calling test, which EUnit may run in a
%% process other than the setup's: every window it is asked for is this
%% module's, reporting to the test.
serve() ->
    Test = self(),
    true = register(erx_ui_host, spawn(fun() -> host(Test) end)).

host(Test) ->
    receive
        {'$gen_call', From, {window, _Renderer}} ->
            gen_server:reply(From, {ok, ?MODULE, #{test => Test}}),
            host(Test)
    end.

%% A window of this module's core asking Paths, started by a parent that
%% traps exits, so the window's end does not reach the test.
window(Model, Paths) ->
    Test = self(),
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  Test ! {started, erx_desk_window:start_link(Model, #{core => ?MODULE, label => <<"probe">>,
                                                                         args => #{test => Test, paths => Paths}})},
                  receive after infinity -> ok end
          end),
    receive {started, {ok, Window}} -> Window after ?WAIT_MS -> error(not_started) end.

%% An inspector that never answers, reporting each query and its worker to
%% Test.
hang(Test) ->
    fun(Path, _Options) ->
            Test ! {asked, Path, self()},
            receive after infinity -> ok end
    end.

asked(Path) ->
    receive {asked, Path, Pid} -> Pid after ?WAIT_MS -> error({not_asked, Path}) end.

input() ->
    receive {input, _} = Input -> Input after ?WAIT_MS -> error(no_input) end.

input_or_nothing() ->
    receive {input, _} = Input -> Input after 300 -> nothing end.

applied() ->
    receive {applied, Ops} -> Ops after ?WAIT_MS -> error(no_apply) end.

down(Ref) ->
    receive {'DOWN', Ref, process, _Pid, Reason} -> Reason after ?WAIT_MS -> error(alive) end.

wait_gone(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after ?WAIT_MS -> error({not_gone, Pid}) end.

%% Loads erx_desk_probe_core, a core that ticks once and shows its state,
%% with Extra after the state's label in its view.
load_probe(Extra) ->
    Source = <<"-module(erx_desk_probe_core).\n"
               "-export([init/1, step/2, view/1]).\n"
               "init(#{}) -> {start, [{tick_after, 0}]}.\n"
               "step({tick, _Now}, _State) -> {ticked, []}.\n"
               "view(State) -> {column, #{}, [{label, #{text => atom_to_binary(State)}, []}", Extra/binary, "]}.\n">>,
    File = "erx_desk_probe_core.erl",
    ok = file:write_file(File, Source),
    {ok, Module, Beam} = compile:file(File, [binary, return_errors]),
    code:purge(Module),
    {module, Module} = code:load_binary(Module, File, Beam).
