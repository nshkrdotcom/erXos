%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the mini UART driver's receive overruns: what a read of LSR says of them,
%% which counts are logged, when the driver logs one against its drain, and that a long
%% write never starves the receive FIFO.
%% test/host/erx_mini_uart_test.rb runs them on stock's emulator.

-module(erx_mini_uart_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_mini_uart.hrl").

%% The logger handler of the order case.
-export([log/2]).

-define(READY, ?ERX_HW_MINI_UART_LSR_DATA_READY_MASK).
-define(OVERRUN, ?ERX_HW_MINI_UART_LSR_RX_OVERRUN_MASK).
-define(TX, (?ERX_HW_MINI_UART_LSR_TX_EMPTY_MASK bor ?ERX_HW_MINI_UART_LSR_TX_IDLE_MASK)).
%% The receive FIFO's depth.
-define(FIFO_BYTES, 8).

%% A read without the overrun bit counts nothing, whatever else LSR says.
no_overrun_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual(5, erx_mini_uart:count_overrun(Lsr, 5)) end,
                  [0, ?READY, ?TX, ?READY bor ?TX]).

%% The read clears the bit, so the read that shows it counts it, with or without a byte
%% behind it and whether the send side or the receive side read it.
overrun_counts_whatever_else_lsr_says_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual(1, erx_mini_uart:count_overrun(Lsr, 0)) end,
                  [?OVERRUN, ?OVERRUN bor ?READY, ?OVERRUN bor ?TX, ?OVERRUN bor ?READY bor ?TX]).

%% One read of LSR decides both sides: a received byte is drained, and the same read's
%% transmit room decides between writing and waiting, so a drain never stops a write. The
%% overrun bit, counted elsewhere, decides nothing.
send_step_test() ->
    ?assertEqual({drain, write}, erx_mini_uart:send_step(?READY bor ?TX)),
    ?assertEqual({drain, wait}, erx_mini_uart:send_step(?READY bor ?OVERRUN)),
    ?assertEqual({idle, write}, erx_mini_uart:send_step(?TX)),
    ?assertEqual({idle, write}, erx_mini_uart:send_step(?TX bor ?OVERRUN)),
    ?assertEqual({idle, wait}, erx_mini_uart:send_step(0)).

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

%% A burst that overran the receive FIFO, eight bytes in it and one that came after the
%% loss: the driver takes every byte, marks the loss after the eighth, and acknowledges the
%% line before it logs the overrun, so the log call, which formats and writes a line, never stalls a drain with the FIFO filling behind
%% it. The driver runs over a played device (test/erlang/stand_in/erx_device.erl): this
%% process answers its register calls from a model of the FIFO and records them, the
%% console input and the driver's log calls in the order they come.
overrun_is_logged_after_the_drain_and_the_acknowledgement_test() ->
    Self = self(),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => Self}),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        %% The start's drain finds the FIFO empty at its first read of LSR.
        {_, _} = serve(Driver, {[], [], false}, {read, lsr}, []),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Events, _} = serve(Driver, {[], "abcdefghi", true}, logged, []),
        ?assertEqual([{input, <<"abcdefgh", 0, "i">>}], [E || E = {input, _} <- Events]),
        Order = [E || E <- Events, E =:= {read, io} orelse E =:= ack orelse element(1, E) =:= logged],
        {Reads, After} = lists:split(9, Order),
        ?assertEqual(lists:duplicate(9, {read, io}), Reads),
        ?assertMatch([ack, {logged, {_Format, [1]}}], After)
    after
        unlink(Driver),
        exit(Driver, kill),
        logger:remove_handler(?MODULE)
    end.

%% A line typed into a full FIFO: "rm -rf /" filled it, the next byte was lost, and "x\n"
%% arrived during the drain. The marker, a NUL as FreeBSD's uart(4) puts it, follows the
%% eight bytes the FIFO held and comes before the newline, so the damaged line goes up
%% marked and the line editor refuses to run it; a marker at the end of the drain would send
%% "rm -rf /x" out whole.
overrun_mid_line_is_marked_where_the_bytes_were_lost_test() ->
    ?assertEqual(<<"rm -rf /", 0, "x\n">>, delivered({[], "rm -rf /x\n", true})).

%% A FIFO that has not overrun goes up as read, with no marker.
input_without_an_overrun_is_unmarked_test() ->
    ?assertEqual(<<"ls\n">>, delivered({[], "ls\n", false})).

%% The marks a drain keeps, one per overrun not yet marked, each the bytes still to read
%% before its marker: an overrun shown by a read with two bytes of an earlier one still to
%% come is marked after them and again eight bytes after the read that showed it; a FIFO
%% read empty first marks every loss still pending, since no byte that came before them is
%% left in it.
marks_test() ->
    ?assertEqual({<<"a">>, [7]}, erx_mini_uart:received($a, [8])),
    ?assertEqual({<<"h", 0>>, [5]}, erx_mini_uart:received($h, [1, 6])),
    ?assertEqual({<<"z">>, []}, erx_mini_uart:received($z, [])),
    ?assertEqual({<<0, 0>>, []}, erx_mini_uart:received(empty, [3, 8])),
    ?assertEqual({<<>>, []}, erx_mini_uart:received(empty, [])).

%% An overrun the send path's read of LSR shows, which clears the bit before the drain's own
%% reads: the driver keeps it pending, so the drain between two bytes of the send still
%% marks the loss after the eight bytes the FIFO held, before the two that came after it.
overrun_seen_by_a_send_is_marked_test() ->
    Self = self(),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], false}, {read, lsr}, []),
        Driver ! {erx_console_output, Self, "."},
        {Written, _} = serve(Driver, {[], "abcdefghij", true}, written, []),
        ?assertEqual(<<"abcdefgh", 0, "ij">>, << <<B/binary>> || {input, B} <- Written >>)
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% The input one receive interrupt delivers from the FIFO given.
delivered(Fifo) ->
    Self = self(),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], false}, {read, lsr}, []),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Events, _} = serve(Driver, Fifo, ack, []),
        << <<B/binary>> || {input, B} <- Events >>
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% A paste at the rate the driver echoes, one byte arriving on the line for each byte the
%% driver hands the transmitter, while the console's line-long write goes out and no
%% interrupt is delivered: the transmit loop reads LSR before each byte, sees the byte
%% waiting and drains the receive FIFO before writing on, so the FIFO's eight bytes never
%% overflow and every pasted byte reaches the console. With no delivery received, nothing
%% is acknowledged during the write; the interrupt delivered after it takes the byte that
%% came with the last one and is acknowledged once.
receive_is_drained_during_a_long_write_test() ->
    Self = self(),
    Paste = "the quick brown fox jumps over the lazy dog",
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], false}, {read, lsr}, []),
        Driver ! {erx_console_output, Self, lists:duplicate(length(Paste), $.)},
        {Written, Left} = serve(Driver, {Paste, [], false}, written, []),
        ?assertEqual(length(Paste), length([E || E = {write, io, _} <- Written])),
        ?assertEqual([], [E || E = ack <- Written]),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Rest, _} = serve(Driver, Left, ack, []),
        ?assertEqual([ack], [E || E = ack <- Rest]),
        Input = << <<B/binary>> || {input, B} <- Written ++ Rest >>,
        ?assertEqual(list_to_binary(Paste), Input)
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% A device whose DATA_READY never clears: one delivery reads at most four FIFO depths,
%% hands them up and acknowledges the line, so the driver goes on serving its mailbox
%% instead of reading forever.
wedged_receive_is_drained_a_bounded_amount_test() ->
    Self = self(),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], false}, {read, lsr}, []),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Events, _} = serve(Driver, {[], wedged, false}, ack, []),
        ?assertEqual([{input, binary:copy(<<"x">>, 32)}], [E || E = {input, _} <- Events])
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% Plays the driver's device and console until the event Until is recorded, and answers the
%% events recorded, oldest first, with the FIFO as the driver left it. Fifo is
%% {Arriving, Bytes, Overrun}: the bytes still to arrive on the line, one with each byte the
%% driver writes to IO, the receive FIFO's bytes (or `wedged`, a FIFO that always holds an
%% "x"), and whether a byte was lost to it since LSR was last read. A driver that stops
%% short of Until fails the case.
serve(Driver, Fifo, Until, Events) ->
    receive
        {erx_device, Driver, Call} ->
            {Answer, Next} = answer(Call, Fifo),
            Driver ! {erx_device, Answer},
            recorded(Driver, Next, Until, event(Call), Events);
        {erx_console_input, Bytes} ->
            recorded(Driver, Fifo, Until, {input, Bytes}, Events);
        {erx_console_written, _From} ->
            recorded(Driver, Fifo, Until, written, Events);
        {logged, Driver, Report} ->
            recorded(Driver, Fifo, Until, {logged, Report}, Events);
        {ack, Driver, _InitAck} ->
            serve(Driver, Fifo, Until, Events)
    after 5000 ->
            error({driver_stopped_short_of, Until, lists:reverse(Events)})
    end.

recorded(Driver, Fifo, Until, Event, Events) ->
    case Event =:= Until orelse (is_tuple(Event) andalso element(1, Event) =:= Until) of
        true -> {lists:reverse([Event | Events]), Fifo};
        false -> serve(Driver, Fifo, Until, [Event | Events])
    end.

event({ack, _Line}) -> ack;
event(Call) -> Call.

answer({read, lsr}, Wedged = {_, wedged, _}) -> {?READY bor ?TX, Wedged};
answer({read, io}, Wedged = {_, wedged, _}) -> {$x, Wedged};
answer({read, lsr}, {Arriving, Bytes, Overrun}) ->
    Ready = case Bytes of [] -> 0; _ -> ?READY end,
    Lost = case Overrun of true -> ?OVERRUN; false -> 0 end,
    {Ready bor Lost bor ?TX, {Arriving, Bytes, false}};
answer({read, io}, {Arriving, [Byte | Rest], Overrun}) -> {Byte, {Arriving, Rest, Overrun}};
answer({write, io, _Byte}, Fifo) -> {ok, arrive(Fifo)};
answer({write, _Register, _Value}, Fifo) -> {ok, Fifo};
answer({write_field, _Register, _Field, _Value}, Fifo) -> {ok, Fifo};
answer({ack, _Line}, Fifo) -> {ok, Fifo}.

%% The next byte on the line enters the receive FIFO, or is lost to a full one.
arrive({[], Bytes, Overrun}) -> {[], Bytes, Overrun};
arrive({[_Lost | Arriving], Bytes, _Overrun}) when length(Bytes) >= ?FIFO_BYTES ->
    {Arriving, Bytes, true};
arrive({[Byte | Arriving], Bytes, Overrun}) -> {Arriving, Bytes ++ [Byte], Overrun}.

%% The logger handler the order case adds: each event logged, with the process that logged
%% it, sent to the case, which keeps only the driver's.
log(#{msg := Msg, meta := #{pid := Pid}}, #{config := Case}) ->
    Case ! {logged, Pid, Msg}.

%% However many reads show an overrun while no byte is read, the marks stay at most one per
%% place a byte can be: an overrun before any byte is read since the last adds none, and one
%% after a byte adds one, so a device that keeps RX_OVERRUN set cannot grow the driver.
marks_are_bounded_test() ->
    Stuck = lists:foldl(fun(_, Marks) -> erx_mini_uart:add_mark(Marks) end, [], lists:seq(1, 100)),
    ?assertEqual([8], Stuck),
    Read = lists:foldl(fun(_, Marks) ->
                               {_, Left} = erx_mini_uart:received($a, erx_mini_uart:add_mark(Marks)),
                               Left
                       end, [], lists:seq(1, 100)),
    ?assertEqual([1, 2, 3, 4, 5, 6, 7], Read).
