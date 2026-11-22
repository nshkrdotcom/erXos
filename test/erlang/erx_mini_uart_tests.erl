%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_mini_uart:count_overrun/2, the driver's one decision on what a read
%% of LSR says of receive overruns: whether it counts one, and which counts it logs.
%% test/host/erx_mini_uart_test.rb runs them on stock's emulator.

-module(erx_mini_uart_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_mini_uart.hrl").

-define(READY, ?ERX_HW_MINI_UART_LSR_DATA_READY_MASK).
-define(OVERRUN, ?ERX_HW_MINI_UART_LSR_RX_OVERRUN_MASK).
-define(TX, (?ERX_HW_MINI_UART_LSR_TX_EMPTY_MASK bor ?ERX_HW_MINI_UART_LSR_TX_IDLE_MASK)).

%% A read without the overrun bit counts nothing, whatever else LSR says.
no_overrun_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual({5, false}, erx_mini_uart:count_overrun(Lsr, 5)) end,
                  [0, ?READY, ?TX, ?READY bor ?TX]).

%% The read clears the bit, so the read that shows it counts it, with or without a byte
%% behind it and whether the send side or the receive side read it.
overrun_counts_whatever_else_lsr_says_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual({1, true}, erx_mini_uart:count_overrun(Lsr, 0)) end,
                  [?OVERRUN, ?OVERRUN bor ?READY, ?OVERRUN bor ?TX, ?OVERRUN bor ?READY bor ?TX]).

%% The first overrun and each doubling of the count are logged, no others.
logged_counts_test() ->
    {_, Logged} = lists:foldl(fun(_, {Seen, Acc}) ->
                                      case erx_mini_uart:count_overrun(?OVERRUN, Seen) of
                                          {N, true} -> {N, [N | Acc]};
                                          {N, false} -> {N, Acc}
                                      end
                              end, {0, []}, lists:seq(1, 300)),
    ?assertEqual([1, 2, 4, 8, 16, 32, 64, 128, 256], lists:reverse(Logged)).
