%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The report filter, erx_report (docs/design-log.md, "Reports carry no term"): a crash of
%% the Bluetooth controller process with the controller's bytes in its mailbox, logged by
%% OTP's own code, and reports of each kind OTP's behaviours make, built here.
-module(erx_report_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

%% What the controller's reader would send: an event's bytes, chosen to be found.
-define(BYTES, <<4, 16#0E, "SECRET-CONTROLLER-BYTES">>).
-define(MARK, <<"SECRET-CONTROLLER-BYTES">>).

%% The capturing handler: every event that passed the primary filters, to the test.
log(Event, #{config := #{to := To}}) ->
    To ! {logged, Event},
    ok.

%% The controller process crashes on the send to its reader, which is not running, with
%% the reader's bytes queued behind the message it is handling. Unfiltered, proc_lib's
%% crash report prints that queue; filtered, no event carries the bytes.
controller_crash_unfiltered_carries_the_bytes_test() ->
    Events = controller_crash(),
    ?assert(lists:any(fun carries_mark/1, Events)).

controller_crash_reports_carry_no_term_test() ->
    ok = logger:add_primary_filter(erx_report, {fun erx_report:filter/2, []}),
    try
        Events = controller_crash(),
        ?assertEqual([], lists:filter(fun carries_mark/1, Events)),
        [Crash] = [R || #{msg := {report, #{label := {proc_lib, crash}} = R}} <- Events],
        ?assertMatch(#{name := erx_bt_hci, class := error, reason := badarg, process := _}, Crash),
        ?assertEqual(#{}, maps:without([label, process, name, class, reason, stack], Crash)),
        [Terminate] = [R || #{msg := {report, #{label := {gen_server, terminate}} = R}} <- Events],
        ?assertMatch(#{name := erx_bt_hci, reason := badarg, stack := [_ | _]}, Terminate)
    after
        ok = logger:remove_primary_filter(erx_report)
    end.

%% gen_statem's termination report: the top frame's arguments are the state and the
%% event, and the report holds the queue, the postponed events and the data.
statem_report_keeps_names_test() ->
    Report = #{label => {gen_statem, terminate}, name => erx_gen_tcp, queue => [?BYTES], postponed => [?BYTES],
               state => {connected, ?BYTES}, log => [?BYTES], callback_mode => state_functions,
               reason => {error, function_clause, [{erx_tcp_core, step, [?BYTES, #{data => ?BYTES}], [{line, 7}]},
                                                    {gen_statem, loop_state_callback, 11, [{file, "gen_statem.erl"}]}]}},
    ?assertEqual(#{label => {gen_statem, terminate}, name => erx_gen_tcp, process => self(), class => error,
                   reason => function_clause, stack => [{erx_tcp_core, step, 2}, {gen_statem, loop_state_callback, 11}]},
                 summary(Report, #{domain => [otp]})).

%% gen_server's report of a message it has no clause for quotes the message.
unhandled_message_report_keeps_names_test() ->
    Report = #{label => {gen_server, no_handle_info}, name => erx_bt_hci, module => erx_bt_hci, message => ?BYTES},
    ?assertEqual(#{label => {gen_server, no_handle_info}, name => erx_bt_hci, process => self()},
                 summary(Report, #{domain => [otp]})).

%% A supervisor's report of a child that ended: the offender holds its start arguments, and
%% the exit reason {Reason, Stack} the frames' arguments.
supervisor_report_keeps_names_test() ->
    Report = #{label => {supervisor, child_terminated},
               report => [{supervisor, {local, erx_bt_sup}}, {errorContext, child_terminated},
                          {reason, {{badmatch, ?BYTES}, [{erx_bt_link, handle, [?BYTES], []}]}},
                          {offender, [{pid, self()}, {id, link}, {mfargs, {erx_bt_link, start_link, [?BYTES]}}]}]},
    ?assertEqual(#{label => {supervisor, child_terminated}, name => erx_bt_sup, process => self(),
                   reason => badmatch, stack => [{erx_bt_link, handle, 1}]},
                 summary(Report, #{domain => [otp, sasl]})).

%% A format string's arguments, the emulator's error for a plain process, and metadata a
%% process set are dropped; the domain's own events pass as they are.
text_and_metadata_are_dropped_test() ->
    Meta = #{domain => [otp], pid => self(), time => 1, mfa => {m, f, 1}, file => "m.erl", line => 2,
             secret => ?BYTES, report_cb => fun(_) -> {"~p", [?BYTES]} end},
    #{msg := {report, Summary}, meta := Kept} =
        erx_report:filter(#{level => error, msg => {"~p", [?BYTES]}, meta => Meta}, []),
    ?assertEqual(#{process => self()}, Summary),
    ?assertEqual(#{domain => [otp], pid => self(), time => 1, mfa => {m, f, 1}}, Kept),
    Emulator = #{error_logger => #{emulator => true, tag => error}, pid => self(), time => 1},
    ?assertMatch(#{msg := {report, #{process := _}}, meta := #{pid := _, time := 1}},
                 erx_report:filter(#{level => error, msg => {"~p", [?BYTES]}, meta => Emulator}, [])),
    ?assertEqual(ignore, erx_report:filter(#{level => info, msg => {string, ?BYTES}, meta => #{pid => self()}}, [])).

%% Odd shapes give fewer facts, never a raise, which would remove the filter.
odd_shapes_do_not_raise_test() ->
    Odd = [#{label => <<"x">>, report => [a | b], reason => {}},
           #{report => [[{error_info, {error, x, [{m, f, [a | b], []}, {m, g, -1, []}, x | y]}}] | z]},
           #{reason => {{}, [{m, f, 1, []}]}, name => {global, ?BYTES}, supervisor => {self(), ?BYTES}}],
    [?assertEqual(nomatch, binary:match(term_to_binary(summary(R, #{domain => [otp]})), ?MARK)) || R <- Odd],
    ?assertEqual(#{process => self(), stack => [], class => error, reason => x},
                 summary(lists:nth(2, Odd), #{domain => [otp]})),
    ?assertMatch(#{msg := {report, #{}}}, erx_report:filter(#{level => error, msg => {report, [a | b]},
                                                              meta => #{domain => [otp | x]}}, [])).

%% Helpers.

summary(Report, Meta) ->
    #{msg := {report, Summary}} = erx_report:filter(#{level => error, msg => {report, Report},
                                                      meta => Meta#{pid => self()}}, []),
    Summary.

%% Starts erx_bt_hci with a stand-in for the store and the test as its writer, queues the
%% reader's bytes behind the writer's line_ready, and returns the events its crash logs.
%% The default handler is off meanwhile, so EUnit's output shows no report.
controller_crash() ->
    {ok, #{module := Default} = Shown} = logger:get_handler_config(default),
    ok = logger:remove_handler(default),
    ok = logger:add_handler(capture, ?MODULE, #{config => #{to => self()}}),
    Store = spawn(fun store/0),
    true = register(erx_bt_store, Store),
    true = register(erx_bt_line_tx, self()),
    try
        {ok, Hci} = gen_server:start({local, erx_bt_hci}, erx_bt_hci, [], []),
        Monitor = monitor(process, Hci),
        true = erlang:suspend_process(Hci),
        Hci ! {erx_bt_line_tx, line_ready},
        Hci ! {erx_bt_line_rx, ?BYTES},
        true = erlang:resume_process(Hci),
        receive {'DOWN', Monitor, process, Hci, _} -> ok after 5000 -> error(no_crash) end,
        events([{gen_server, terminate}, {proc_lib, crash}], [])
    after
        unregister(erx_bt_line_tx),
        unregister(erx_bt_store),
        exit(Store, kill),
        ok = logger:remove_handler(capture),
        ok = logger:add_handler(default, Default, Shown)
    end.

store() ->
    receive
        {'$gen_call', From, address} -> gen:reply(From, <<16#C0, 1, 2, 3, 4, 5>>), store()
    end.

%% The events logged until each label has been seen.
events([], Events) ->
    lists:reverse(Events);
events(Labels, Events) ->
    receive
        {logged, #{msg := {report, #{label := Label}}} = Event} -> events(Labels -- [Label], [Event | Events]);
        {logged, Event} -> events(Labels, [Event | Events])
    after 5000 ->
        error({not_logged, Labels})
    end.

%% The bytes in the event's terms or in the line the default formatter makes of it.
carries_mark(Event) ->
    Line = unicode:characters_to_binary(logger_formatter:format(Event, #{single_line => true})),
    binary:match(term_to_binary(Event), ?MARK) =/= nomatch orelse binary:match(Line, ?MARK) =/= nomatch.

%% Status -------------------------------------------------------------------------

%% A module's format_status/1 names the keys it shows: the others are hidden, the log, the
%% queue and the postponed events are empty, and a reason is its leading atom.
status_shows_only_what_the_views_name_test() ->
    Secret = <<"STATUS-SECRET">>,
    Status = erx_report:status(
               #{state => {Secret, 1}, message => {Secret, 2}, queue => [Secret], postponed => [Secret],
                 log => [Secret], reason => {badarg, Secret}, other => Secret},
               #{state => fun({_, N}) -> N end}),
    ?assertEqual(#{state => 1, message => hidden, queue => [], postponed => [], log => [],
                   reason => badarg, other => hidden}, Status).

%% The reason and the log are not the module's to show: a view named for them is ignored.
the_reason_and_the_log_are_not_the_modules_to_show_test() ->
    Status = erx_report:status(#{log => [a, b], reason => {badarg, x}},
                               #{log => fun length/1, reason => keep}),
    ?assertEqual(#{log => [], reason => badarg}, Status).
