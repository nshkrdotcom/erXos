%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Interpreted receives (erl_eval, which matches each queued message inside
%% prim_eval:'receive'/2) whose match runs code of its own: a module load
%% through the code server, or a guard call through the evaluator's
%% non-local function handler. Edits 77 and 78 of docs/design-runtime.md.
%%
%% The rounds: the binary pattern calls eval_bits, deleted beforehand, so
%% error_handler loads it through the code server, a receive of its own,
%% and code:ensure_loaded/1 then collects the heap. The message being
%% matched is still queued in a fragment of its own (the receiver's queue is
%% off heap), and the match holds its terms on the stack while that
%% collection runs. The guard fails, so the message stays queued, and a
%% compiled receive must then get it back intact.
%%
%% The cases: each runs one receiver and checks what the interpreted receive
%% returns and what a compiled drain finds left in the queue afterwards.
%%   order      skip, then a probe whose binary match loads eval_bits: the
%%              receive takes the probe and leaves skip.
%%   taken      a, then a probe whose guard handler takes the probe itself:
%%              the receive finds nothing and leaves a.
%%   thrown     a, then b, whose guard handler throws: a compiled receive
%%              afterwards gets a.
%%   nested     early, then a probe whose guard handler runs an interpreted
%%              receive for early: the nested receive sees early.
%%   timer      a receive with after 50 woken by a message whose guard
%%              handler burns 100 ms of reductions: it takes the message.
%%   expired    the same with a message the guard refuses: the receive
%%              times out once the match returns, leaving the message.
%%
%% main/0 prints one line for the rounds and one per case, and halts with 0
%% when all are right, with 1 when one is wrong, and with 2 when the rounds
%% could not be run. A forwarded message may also end the runtime with a
%% signal.
-module(eval_receive_probe).
-export([main/0]).

-define(ROUNDS, 20).
-define(ROUND_MS, 10000).
-define(RECEIVE,
        "receive {probe, <<\"x\", _/binary>>, _, _} when Never -> matched "
        "after 0 -> unmatched end.").
-define(CASES, [order, taken, thrown, nested, timer, expired]).

main() ->
    Rounds = rounds(),
    Cases = [run_case(Case) || Case <- ?CASES],
    erlang:halt(case lists:all(fun(Ok) -> Ok end, [Rounds | Cases]) of
                    true -> 0;
                    false -> 1
                end).

rounds() ->
    try [run_round(N) || N <- lists:seq(1, ?ROUNDS)] of
        Results ->
            case [Bad || Bad <- Results, Bad =/= intact] of
                [] ->
                    io:format("eval receive probe: ~b rounds, message intact~n", [?ROUNDS]),
                    true;
                Bad ->
                    io:format("eval receive probe: ~P~n", [Bad, 20]),
                    false
            end
    catch
        Class:Reason ->
            io:format("eval receive probe: no result: ~p:~P~n", [Class, Reason, 20]),
            erlang:halt(2)
    end.

%% One receiver, one message: intact, {not_intact, Got}, or a failure.
run_round(N) ->
    Exprs = parse(?RECEIVE),
    Message = {probe, <<"x", (integer_to_binary(N))/binary>>,
               lists:seq(1, 16), {N, make_ref()}},
    Parent = self(),
    unload_eval_bits(),
    {Receiver, Monitor} =
        spawn_opt(fun() -> receiver(Parent, Exprs, Message) end,
                  [monitor, {message_queue_data, off_heap}]),
    Receiver ! Message,
    Receiver ! go,
    receive
        {Receiver, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Receiver, Reason} ->
            error({receiver_down, Reason})
    after ?ROUND_MS ->
        error(round_timeout)
    end.

%% Waits until the message is queued behind nothing, matches it in erl_eval
%% (loading eval_bits on the way), then takes it with a compiled receive.
receiver(Parent, Exprs, Expected) ->
    receive go -> ok end,
    {value, unmatched, _} =
        erl_eval:exprs(Exprs, erl_eval:add_binding('Never', false, erl_eval:new_bindings())),
    true = erlang:module_loaded(eval_bits),
    Got = receive Any -> Any after 0 -> nothing end,
    Parent ! {self(), case Got =:= Expected of
                          true -> intact;
                          false -> {not_intact, Got}
                      end}.

%% Runs one case in a receiver of its own and prints its line: true when
%% the receiver's result is the expected one.
run_case(Case) ->
    Parent = self(),
    {Receiver, Monitor} =
        spawn_opt(fun() -> Parent ! {self(), case_result(Case)} end,
                  [monitor, {message_queue_data, off_heap}]),
    Got = receive
              {Receiver, Result} -> Result;
              {'DOWN', Monitor, process, Receiver, Reason} -> {down, Reason}
          after ?ROUND_MS ->
              exit(Receiver, kill),
              timeout
          end,
    erlang:demonitor(Monitor, [flush]),
    Ok = Got =:= expected(Case),
    io:format("eval receive case ~p: ~s~n",
              [Case, case Ok of
                         true -> "ok";
                         false -> io_lib:format("wrong ~P", [Got, 20])
                     end]),
    Ok.

expected(order) -> {matched, [skip]};
expected(taken) -> {unmatched, [a]};
expected(thrown) -> {{thrown, boom}, a};
expected(nested) -> {matched, got_early, []};
expected(timer) -> {a, []};
expected(expired) -> {t, [{x}]}.

%% Runs in the receiver: what its interpreted receive returned, with what
%% a compiled receive finds afterwards.
case_result(order) ->
    unload_eval_bits(),
    self() ! skip,
    self() ! {probe, <<"x1">>},
    Result = eval("receive {probe, <<\"x\", _/binary>>} -> matched "
                  "after 0 -> unmatched end.", none),
    {Result, drain()};
case_result(taken) ->
    self() ! a,
    self() ! {probe, 1},
    Handler = fun({erlang, is_tuple} = Call, Args) ->
                      case get(taken) of
                          undefined -> put(taken, receive {probe, _} = M -> M end);
                          _ -> ok
                      end,
                      apply_call(Call, Args)
              end,
    Result = eval("receive {probe, _} = M when erlang:is_tuple(M) -> matched "
                  "after 0 -> unmatched end.", Handler),
    {Result, drain()};
case_result(thrown) ->
    self() ! a,
    self() ! b,
    Handler = fun({erlang, is_atom}, [b]) -> throw(boom);
                 (Call, Args) -> apply_call(Call, Args)
              end,
    Result = try eval("receive b = X when erlang:is_atom(X) -> X "
                      "after 0 -> none end.", Handler)
             catch throw:Thrown -> {thrown, Thrown}
             end,
    {Result, receive First -> First after 0 -> none end};
case_result(nested) ->
    self() ! early,
    self() ! {probe, 1},
    Handler = fun({erlang, is_tuple} = Call, Args) ->
                      case get(nested) of
                          undefined ->
                              put(nested, eval("receive early -> got_early "
                                               "after 0 -> no_early end.", none));
                          _ -> ok
                      end,
                      apply_call(Call, Args)
              end,
    Result = eval("receive {probe, _} = M when erlang:is_tuple(M) -> matched "
                  "after 0 -> unmatched end.", Handler),
    {Result, get(nested), drain()};
case_result(timer) -> burned_receive(a);
case_result(expired) -> burned_receive({x}).

%% A receive with after 50, woken after 10 ms by Message, whose guard handler
%% burns 100 ms.
burned_receive(Message) ->
    Self = self(),
    _ = spawn(fun() -> receive after 10 -> Self ! Message end end),
    Handler = fun({erlang, is_atom} = Call, Args) ->
                      burn(erlang:monotonic_time(millisecond) + 100),
                      apply_call(Call, Args)
              end,
    Result = eval("receive X when erlang:is_atom(X) -> X after 50 -> t end.", Handler),
    {Result, drain()}.

eval(String, none) ->
    {value, Value, _} = erl_eval:exprs(parse(String), erl_eval:new_bindings()),
    Value;
eval(String, Handler) ->
    {value, Value, _} = erl_eval:exprs(parse(String), erl_eval:new_bindings(),
                                       none, {value, Handler}),
    Value.

parse(String) ->
    {ok, Tokens, _} = erl_scan:string(String),
    {ok, Exprs} = erl_parse:parse_exprs(Tokens),
    Exprs.

apply_call({Module, Function}, Args) -> apply(Module, Function, Args).

%% Spends reductions, not sleep, so the process is scheduled out and back
%% many times before Deadline.
burn(Deadline) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ok;
        false -> burn(Deadline)
    end.

drain() ->
    receive Any -> [Any | drain()] after 0 -> [] end.

%% eval_bits is gone, so the next interpreted binary match loads it.
unload_eval_bits() ->
    _ = code:purge(eval_bits),
    _ = code:delete(eval_bits),
    _ = code:purge(eval_bits),
    false = erlang:module_loaded(eval_bits),
    ok.
