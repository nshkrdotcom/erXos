%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the mini UART driver's receive overruns: what a read of LSR says of them,
%% which counts are logged, and when the driver logs one against its drain.
%% test/host/erx_mini_uart_test.rb runs them on stock's emulator.

-module(erx_mini_uart_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_mini_uart.hrl").

%% The logger handler of the order case.
-export([log/2]).

-define(READY, ?ERX_HW_MINI_UART_LSR_DATA_READY_MASK).
-define(OVERRUN, ?ERX_HW_MINI_UART_LSR_RX_OVERRUN_MASK).
-define(TX, (?ERX_HW_MINI_UART_LSR_TX_EMPTY_MASK bor ?ERX_HW_MINI_UART_LSR_TX_IDLE_MASK)).

%% A read without the overrun bit counts nothing, whatever else LSR says.
no_overrun_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual(5, erx_mini_uart:count_overrun(Lsr, 5)) end,
                  [0, ?READY, ?TX, ?READY bor ?TX]).

%% The read clears the bit, so the read that shows it counts it, with or without a byte
%% behind it and whether the send side or the receive side read it.
overrun_counts_whatever_else_lsr_says_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual(1, erx_mini_uart:count_overrun(Lsr, 0)) end,
                  [?OVERRUN, ?OVERRUN bor ?READY, ?OVERRUN bor ?TX, ?OVERRUN bor ?READY bor ?TX]).

%% With one overrun per check, the first and each doubling of the count are logged.
logged_counts_test() ->
    ?assertEqual([1, 2, 4, 8, 16, 32, 64, 128, 256], logged(lists:duplicate(300, 1))).

%% With several per check, a count is logged once it at least doubles the last one
%% logged, so no warning is lost to a count that skipped a power of two.
logged_counts_skip_powers_of_two_test() ->
    ?assertEqual([3, 6, 15, 30], logged([3, 1, 2, 9, 15])),
    ?assertEqual([], logged([0, 0])).

%% The counts to_report/2 logs when each step adds the overruns given to the count.
logged(Steps) ->
    {_, _, Logged} = lists:foldl(fun(Step, {Seen, Reported, Acc}) ->
                                         N = Seen + Step,
                                         case erx_mini_uart:to_report(N, Reported) of
                                             true -> {N, N, [N | Acc]};
                                             false -> {N, Reported, Acc}
                                         end
                                 end, {0, 0, []}, Steps),
    lists:reverse(Logged).

%% A burst that overran the receive FIFO, eight bytes in it and one in the receiver: the
%% driver takes every byte and acknowledges the line before it logs the overrun, so the log
%% call, which formats and writes a line, never stalls a drain with the FIFO filling behind
%% it. The driver runs over a played device (test/erlang/stand_in/erx_device.erl): this
%% process answers its register calls from a model of the FIFO and records them, the
%% console input and the driver's log calls in the order they come.
overrun_is_logged_after_the_drain_and_the_acknowledgement_test() ->
    Self = self(),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => Self}),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        %% The start's drain finds the FIFO empty at its first read of LSR.
        _ = serve(Driver, {[], false}, {read, lsr}, []),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        Events = serve(Driver, {"abcdefghi", true}, logged, []),
        ?assertEqual([{input, <<"abcdefghi">>}], [E || E = {input, _} <- Events]),
        Order = [E || E <- Events, E =:= {read, io} orelse E =:= ack orelse element(1, E) =:= logged],
        {Reads, After} = lists:split(9, Order),
        ?assertEqual(lists:duplicate(9, {read, io}), Reads),
        ?assertMatch([ack, {logged, {_Format, [1]}}], After)
    after
        unlink(Driver),
        exit(Driver, kill),
        logger:remove_handler(?MODULE)
    end.

%% Plays the driver's device and console until the event Until is recorded, and answers the
%% events recorded, oldest first. Fifo is the receive FIFO's bytes and whether a byte was
%% lost to it since LSR was last read. A driver that stops short of Until fails the case.
serve(Driver, Fifo, Until, Events) ->
    receive
        {erx_device, Driver, Call} ->
            {Answer, Next} = answer(Call, Fifo),
            Driver ! {erx_device, Answer},
            recorded(Driver, Next, Until, event(Call), Events);
        {erx_console_input, Bytes} ->
            recorded(Driver, Fifo, Until, {input, Bytes}, Events);
        {logged, Driver, Report} ->
            recorded(Driver, Fifo, Until, {logged, Report}, Events);
        {ack, Driver, _InitAck} ->
            serve(Driver, Fifo, Until, Events)
    after 5000 ->
            error({driver_stopped_short_of, Until, lists:reverse(Events)})
    end.

recorded(Driver, Fifo, Until, Event, Events) ->
    case Event =:= Until orelse (is_tuple(Event) andalso element(1, Event) =:= Until) of
        true -> lists:reverse([Event | Events]);
        false -> serve(Driver, Fifo, Until, [Event | Events])
    end.

event({ack, _Line}) -> ack;
event(Call) -> Call.

answer({read, lsr}, {Bytes, Overrun}) ->
    Ready = case Bytes of [] -> 0; _ -> ?READY end,
    Lost = case Overrun of true -> ?OVERRUN; false -> 0 end,
    {Ready bor Lost bor ?TX, {Bytes, false}};
answer({read, io}, {[Byte | Rest], Overrun}) -> {Byte, {Rest, Overrun}};
answer({field, lsr, data_ready, Word}, Fifo) -> {?ERX_HW_MINI_UART_LSR_DATA_READY_GET(Word), Fifo};
answer({field, lsr, tx_empty, Word}, Fifo) -> {?ERX_HW_MINI_UART_LSR_TX_EMPTY_GET(Word), Fifo};
answer({field, io, data, Word}, Fifo) -> {?ERX_HW_MINI_UART_IO_DATA_GET(Word), Fifo};
answer({write, _Register, _Value}, Fifo) -> {ok, Fifo};
answer({write_field, _Register, _Field, _Value}, Fifo) -> {ok, Fifo};
answer({ack, _Line}, Fifo) -> {ok, Fifo}.

%% The logger handler the order case adds: each event logged, with the process that logged
%% it, sent to the case, which keeps only the driver's.
log(#{msg := Msg, meta := #{pid := Pid}}, #{config := Case}) ->
    Case ! {logged, Pid, Msg}.
