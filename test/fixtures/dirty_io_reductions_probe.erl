%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The reductions a dirty I/O call charges its caller, which erXos's ERTS
%% takes from the call's elapsed time as it does on a dirty CPU scheduler
%% (docs/design-runtime.md, NIFs and blocking). Each case makes one call
%% through erts_debug's dirty I/O test BIF, which runs on a dirty I/O
%% scheduler through the same loop as a dirty NIF:
%%
%%   sleep  a call that sleeps in the kernel for ?CALL_MS;
%%   busy   a call that polls the clock for ?CALL_MS;
%%   idle   a short call after the dirty I/O schedulers sat idle for
%%          ?IDLE_MS, whose idle time is not the call's.
%%
%% main/0 prints one line per case, "dirty io reductions: CASE N" with N
%% the caller's reductions across the call, and halts with 0; a case that
%% could not be run prints its error and halts with 2.
-module(dirty_io_reductions_probe).
-export([main/0]).

-define(CALL_MS, 100).
-define(IDLE_MS, 500).

main() ->
    try [{sleep, charged({wait, ?CALL_MS})},
         {busy, charged({busy_wait, ?CALL_MS})},
         {idle, idle()}] of
        Results ->
            [io:format("dirty io reductions: ~s ~b~n", [Case, N]) || {Case, N} <- Results],
            erlang:halt(0)
    catch
        Class:Reason ->
            io:format("dirty io reductions: no result: ~p:~P~n", [Class, Reason, 20]),
            erlang:halt(2)
    end.

idle() ->
    timer:sleep(?IDLE_MS),
    charged({scheduler, type}).

%% The caller's reductions across one dirty I/O test call.
charged({Op, Arg}) ->
    {reductions, Before} = process_info(self(), reductions),
    _ = erts_debug:dirty_io(Op, Arg),
    {reductions, After} = process_info(self(), reductions),
    After - Before.
