%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The system console's login (docs/design-live.md, "The console"): a login session
%% that did not report ready within the machine's boot timeout, as on a machine merely
%% slower than its manifest allows for, is started again within the restart intensity
%% of a start row's default (abi/manifest.txt, start_restarts_default within
%% start_period_default_s), so a later start that comes up is the login's session, and
%% past it the line stays with the system shell after one line saying why. A stand-in
%% registered as erx_domain_srv answers each start of a session from a list, timeout
%% once the list is spent, as the domain service answers a session it stopped at its
%% boot timeout, and tells the test of each.
-module(erx_console_login_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([shell/0]).

login_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun a_login_that_timed_out_comes_up_on_a_later_start/1,
      fun a_timed_out_login_starts_again_within_the_intensity/1]}.

setup() ->
    Domain = spawn(fun() -> receive after infinity -> ok end end),
    true = register(erx_domain_srv, spawn(fun() -> service([{ok, {erx_domain, 7, 'root_1@erxos', Domain}}]) end)),
    Domain.

cleanup(Domain) ->
    %% Each awaited, so the next case's setup finds the names free.
    [begin
         Ref = monitor(process, Pid),
         unlink(Pid),
         exit(Pid, kill),
         receive {'DOWN', Ref, process, Pid, _} -> ok end
     end || Pid <- [whereis(erx_console), whereis(erx_domain_srv), Domain], is_pid(Pid)],
    flush().

%% The first start times out, the second comes up: the login's session is the second's.
a_login_that_timed_out_comes_up_on_a_later_start(_Domain) ->
    ?_test(begin
               ok = start_console(timeout_first),
               ?assertEqual([{start_session, 1}, {start_session, 1}], [next_start(), next_start()]),
               ?assertEqual(none, next_start()),
               ?assertEqual({ok, 7}, erx_console:login_session())
           end).

%% Every start times out: the first start and each restart the intensity allows, then
%% none, and the line says why.
a_timed_out_login_starts_again_within_the_intensity(_Domain) ->
    ?_test(begin
               ok = start_console(always_timeout),
               [?assertEqual({start_session, 1}, next_start()) || _ <- lists:seq(0, ?ERX_START_RESTARTS_DEFAULT)],
               ?assertEqual(none, next_start()),
               ?assert(written(<<"erx_console: the login session did not start: timeout">>)),
               ?assertEqual(none, erx_console:login_session())
           end).

%% The console logs its line's principal in, the stand-in answering as Mode says and
%% telling the calling test of each start.
start_console(Mode) ->
    process_flag(trap_exit, true),
    erx_domain_srv ! {mode, Mode, self()},
    {ok, _Console} = erx_console:start_link(#{role => system, name => erx_console, menu => false,
                                              principal => 1, owner => fun(_Pid) -> 0 end,
                                              driver => driver(self()),
                                              line_owners => fun() -> {ok, []} end,
                                              first_shell => {?MODULE, shell, []}}),
    erx_console:login().

%% The stand-in domain service: in timeout_first, the first start of a session answers
%% timeout and the next each answer of Answers in turn; in always_timeout, every start
%% answers timeout. Once Answers is spent, every start answers timeout.
service(Answers) ->
    receive {mode, Mode, Test} -> serve(Test, Mode, Answers) end.

serve(Test, Mode, Answers) ->
    receive
        {'$gen_call', From, {start_session, Principal, #{console := _}}} ->
            Test ! {start_session, Principal},
            {Answer, Next, Rest} = case {Mode, Answers} of
                                       {timeout_first, _} -> {{error, timeout}, answering, Answers};
                                       {answering, [First | More]} -> {First, answering, More};
                                       {_, _} -> {{error, timeout}, Mode, Answers}
                                   end,
            gen_server:reply(From, Answer),
            serve(Test, Next, Rest);
        {'$gen_call', From, _Request} ->
            gen_server:reply(From, {error, unknown_call}),
            serve(Test, Mode, Answers)
    end.

next_start() ->
    receive {start_session, _} = Start -> Start after 2000 -> none end.

%% Whether the console wrote Text to its line by now.
written(Text) ->
    receive
        {written, Bytes} ->
            binary:match(Bytes, Text) =/= nomatch orelse written(Text)
    after 2000 ->
        false
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.

shell() ->
    spawn_link(fun() -> receive after infinity -> ok end end).

driver(Test) ->
    fun(Console) ->
            Pid = spawn_link(fun Loop() ->
                                     receive
                                         {erx_console_output, From, Bytes} ->
                                             Test ! {written, iolist_to_binary(Bytes)},
                                             Console ! {erx_console_written, From},
                                             Loop()
                                     end
                             end),
            {ok, Pid, false}
    end.
