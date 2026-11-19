%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Whether each NIF that waits on the root service on Fiasco leaves the
%% normal scheduler while it runs. On Fiasco such a call is a round trip
%% to the root's one service thread, which may be busy for seconds with
%% another task's teardown; a NIF on a normal scheduler would hold it,
%% and every process on it, the system domain's watchdog pet among them,
%% for that long. So each runs on a dirty I/O scheduler, and its caller
%% is scheduled out of the normal scheduler and back in around the call,
%% which a running trace sees. A NIF that runs on the normal scheduler
%% is not scheduled out with the NIF as its current function.
%%
%% Each call of calls/0 runs in a process of its own under a running
%% trace, after a yield so that it starts the call with a fresh slice of
%% reductions; partial, the last, is the control, a NIF that answers from
%% the caller's own memory and stays on the normal scheduler.
%%
%% main/0 prints "service nifs: NAME out" for each call whose NIF its
%% caller was scheduled out in and "service nifs: NAME stays" for each
%% other, then halts with 0; a probe that could not run prints its error
%% and halts with 2.
-module(service_nifs_probe).
-export([main/0]).

main() ->
    try [{Name, scheduled_out(Call, Nif)} || {Name, Nif, Call} <- calls()] of
        Results ->
            [io:format("service nifs: ~s ~s~n", [Name, word(Out)]) || {Name, Out} <- Results],
            erlang:halt(0)
    catch
        Class:Reason ->
            io:format("service nifs: no result: ~p:~P~n", [Class, Reason, 20]),
            erlang:halt(2)
    end.

word(true) -> "out";
word(false) -> "stays".

%% {Name, the NIF's {Module, Function, Arity}, the call}.
calls() ->
    {ok, #{offset := Offset}} = erx_clock_nif:read(),
    [{"debug", {erx_log, debug_nif, 1}, fun() -> erx_log:debug(<<"service nifs probe">>) end},
     {"read", {erx_log, read_nif, 1}, fun() -> erx_log:read(0) end},
     {"take", {erx_log, take_nif, 0}, fun() -> erx_log:take() end},
     {"info", {erx_object_info, info_nif, 4}, fun() -> erx_object_info:info(machine, 0, 0) end},
     %% The offset the page holds already; the hosted backend refuses the setter anyway.
     {"set_offset", {erx_clock_nif, set_offset_nif, 1}, fun() -> erx_clock_nif:set_offset(Offset) end},
     {"partial", {erx_object_info, partial_nif, 1}, fun() -> erx_object_info:partial(machine) end}].

%% Whether a process running Call is scheduled out with Nif as its current function.
scheduled_out(Call, Nif) ->
    Probe = self(),
    Worker = spawn(fun() ->
                           receive go -> ok end,
                           erlang:yield(),
                           _ = Call(),
                           Probe ! {done, self()}
                   end),
    1 = erlang:trace(Worker, true, [running]),
    Worker ! go,
    receive {done, Worker} -> ok end,
    Delivered = erlang:trace_delivered(Worker),
    receive {trace_delivered, Worker, Delivered} -> ok end,
    outs(Worker, Nif, false).

%% Whether the trace messages of Worker received so far hold an out at Nif.
outs(Worker, Nif, Seen) ->
    receive
        {trace, Worker, out, Nif} -> outs(Worker, Nif, true);
        {trace, Worker, _, _} -> outs(Worker, Nif, Seen)
    after 0 -> Seen
    end.
