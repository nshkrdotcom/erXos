%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% An interpreted receive (erl_eval, which matches each queued message
%% inside prim_eval:'receive'/2) whose match loads a module: the binary
%% pattern calls eval_bits, deleted beforehand, so error_handler loads it
%% through the code server, a receive of its own, and code:ensure_loaded/1
%% then collects the heap. The message being matched is still queued in a
%% fragment of its own (the receiver's queue is off heap), and the match
%% holds its terms on the stack while that collection runs. The guard
%% fails, so the message stays queued, and a compiled receive must then get
%% it back intact. A collection that moved the queued message's terms out of
%% its fragment leaves forwarding words there instead.
%%
%% main/0 prints one line and halts with 0 when every round's message came
%% back intact, with 1 when one did not, and with 2 when a round could not
%% be run. A forwarded message may also end the runtime with a signal.
-module(eval_receive_probe).
-export([main/0]).

-define(ROUNDS, 20).
-define(ROUND_MS, 10000).
-define(RECEIVE,
        "receive {probe, <<\"x\", _/binary>>, _, _} when Never -> matched "
        "after 0 -> unmatched end.").

main() ->
    try [run_round(N) || N <- lists:seq(1, ?ROUNDS)] of
        Results ->
            case [Bad || Bad <- Results, Bad =/= intact] of
                [] ->
                    io:format("eval receive probe: ~b rounds, message intact~n", [?ROUNDS]),
                    erlang:halt(0);
                Bad ->
                    io:format("eval receive probe: ~P~n", [Bad, 20]),
                    erlang:halt(1)
            end
    catch
        Class:Reason ->
            io:format("eval receive probe: no result: ~p:~P~n", [Class, Reason, 20]),
            erlang:halt(2)
    end.

%% One receiver, one message: intact, {not_intact, Got}, or a failure.
run_round(N) ->
    {ok, Tokens, _} = erl_scan:string(?RECEIVE),
    {ok, Exprs} = erl_parse:parse_exprs(Tokens),
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

%% eval_bits is gone, so the next interpreted binary match loads it.
unload_eval_bits() ->
    _ = code:purge(eval_bits),
    _ = code:delete(eval_bits),
    _ = code:purge(eval_bits),
    false = erlang:module_loaded(eval_bits),
    ok.
