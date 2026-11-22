%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The driver of the BCM2711's mini UART, the Raspberry Pi 4's console
%% (docs/design-platforms.md, "Raspberry Pi 4 Model B"; hw/svd/mini_uart/mini_uart.svd for
%% the registers). It speaks the driver's messages that erx_console documents to the one
%% process it serves, the console, and passes bytes unchanged both ways, as erx_pl011 does.
%%
%% The firmware pins the core clock the baud rate is divided from and programs the line
%% (`enable_uart=1`), so the driver keeps the divisor, the line control and the receiver
%% and transmitter enables as it finds them, and computes nothing from a clock. Its window
%% is the mini UART's own registers: the auxiliary block's enable register, which also
%% enables the auxiliary SPI controllers on the same page, lies outside it.
%%
%% Receiving: IER's RX_ERRATA bits are set with RXIE, in the belief that the silicon's
%% receive interrupt needs them. The BCM2711's manual prints the receive enable at a
%% different bit than RXIE's, and says nothing of RX_ERRATA, so both are unverified on
%% silicon. The receive interrupt is level, raised while the receive FIFO holds a byte, so
%% one delivery drains the FIFO to empty and the line is acknowledged after it; a byte that
%% arrives during the drain raises the line again. Bytes typed before the driver started
%% are drained once after the interrupt is enabled.
%%
%% Overruns: the receive FIFO holds eight bytes, about 0.7 ms of input at 115200 baud, and
%% the line has no flow control, so a delivery later than that loses the bytes the FIFO
%% had no room for; what was read goes up as read. Every read of LSR, the receive side's
%% and the send side's alike, goes through read_lsr/1, because the read clears RX_OVERRUN:
%% the driver counts each overrun a read shows and logs a warning for the first and for
%% each doubling of the count after it (count_overrun/2), so a flood writes only a few
%% lines to the line it overflows.
%%
%% Sending: one byte whenever the transmit FIFO can take one. A full FIFO waits a
%% millisecond at a time with the receive side still served.

-module(erx_mini_uart).

-export([start_link/1]).
-export([init/1]).
-export([console_records/0, console_uart/1]).
%% Exported for its tests.
-export([count_overrun/2]).

-include("generated/erx_hw_mini_uart.hrl").

%% The spec's one line.
-define(RX_LINE, 0).
-define(FULL_WAIT_MS, 1).

%% The driver's state: its device, its line, the console it serves, and how many reads of
%% LSR have shown an overrun since it started.
-record(driver, {dev :: erx_device:device(),
                 irq :: erx_irq_line:handle(),
                 console :: pid(),
                 overruns = 0 :: non_neg_integer()}).

-spec start_link(Console :: pid()) -> {ok, pid(), Terminal :: boolean()}.
start_link(Console) ->
    proc_lib:start_link(?MODULE, init, [Console]).

-spec init(pid()) -> no_return().
init(Console) ->
    {ok, Dev} = erx_device:open(spec()),
    ok = erx_device:write(Dev, ier, 0),
    {ok, Irq} = erx_irq_line:attach(Dev, ?RX_LINE),
    ok = erx_device:write_field(Dev, ier, rx_errata, 3),
    ok = erx_device:write_field(Dev, ier, rxie, 1),
    proc_lib:init_ack({ok, self(), true}),
    loop(deliver_input(#driver{dev = Dev, irq = Irq, console = Console})).

%% The console's record, for the console to start its line's owner before the driver.
-spec console_records() -> [erx_device:spec()].
console_records() ->
    [spec()].

spec() ->
    case console_uart(erx_device_record:records()) of
        {ok, Spec} -> Spec;
        {error, Reason} -> exit(Reason)
    end.

%% The console's device words, `-erx_record console mini_uart Base Size Line Mark Clock`, which the root
%% writes from the manifest's console row; words after the clock are ignored. Mark is
%% `shared` when another device of the console's unit names its line, as the auxiliary SPI
%% controllers name the mini UART's on the Raspberry Pi 4, which reaches erx_device:open/1
%% as `{shared, Line}`, and `direct` otherwise; any other word refuses the entry. The mini
%% UART's row carries no clock, so Clock is 0.
-spec console_uart([[string()]]) -> {ok, erx_device:spec()} | {error, {atom(), string()}}.
console_uart(Arguments) ->
    case [Words || ["console", "mini_uart" | Words] <- Arguments] of
        [[Base, Size, Line, Mark, Clock | _]] ->
            case {number(Base, 64), number(Size, 64), number(Line, 32), number(Clock, 32), mark(Mark)} of
                {{ok, B}, {ok, S}, {ok, L}, {ok, 0}, {ok, Sharing}} ->
                    {ok, #{peripheral => mini_uart, window => {physical, B, S}, lines => [marked(Sharing, L)]}};
                {{ok, _}, {ok, _}, {ok, _}, {ok, 0}, error} ->
                    {error, {bad_console_uart, "the console's line mark is neither direct nor shared"}};
                {{ok, _}, {ok, _}, {ok, _}, {ok, _}, _} ->
                    {error, {bad_console_uart, "the mini UART's row carries a clock"}};
                _ ->
                    {error, {bad_console_uart, "the console's base, size, line or clock is not a "
                                              "decimal number of its field's width"}}
            end;
        [_] ->
            {error, {bad_console_uart, "the console record has fewer than four numbers and a line mark"}};
        [] ->
            {error, {no_console_uart, "no -erx_record console names this UART"}};
        [_, _ | _] ->
            {error, {bad_console_uart, "more than one console record of this UART"}}
    end.

%% The line's mark word (docs/design-shared-devices.md, "Lines inside a domain"), and the
%% line as erx_device:open/1 takes it.
mark("direct") -> {ok, direct};
mark("shared") -> {ok, shared};
mark(_Word) -> error.

marked(direct, Line) -> Line;
marked(shared, Line) -> {shared, Line}.

%% Digits only, at most as many as the field's largest value has, so no word builds a large
%% integer before the range check.
number(Word, Bits) ->
    Max = (1 bsl Bits) - 1,
    case Word =/= [] andalso length(Word) =< length(integer_to_list(Max))
        andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Word) of
        true ->
            case list_to_integer(Word) of
                Value when Value =< Max -> {ok, Value};
                _ -> error
            end;
        false ->
            error
    end.

loop(S = #driver{dev = Dev, console = Console}) ->
    receive
        {erx_irq, Dev, ?RX_LINE} ->
            loop(take_input(S));
        {erx_console_output, From, Bytes} ->
            Next = send(S, iolist_to_binary(Bytes)),
            Console ! {erx_console_written, From},
            loop(Next);
        _Other ->
            loop(S)
    end.

send(S, <<>>) ->
    S;
send(S0 = #driver{dev = Dev}, Bytes = <<Byte, Rest/binary>>) ->
    {Lsr, S} = read_lsr(S0),
    case erx_device:field(Dev, lsr, tx_empty, Lsr) of
        1 ->
            ok = erx_device:write(Dev, io, Byte),
            send(S, Rest);
        0 ->
            Next = receive
                       {erx_irq, Dev, ?RX_LINE} -> take_input(S)
                   after ?FULL_WAIT_MS -> S
                   end,
            send(Next, Bytes)
    end.

take_input(S = #driver{irq = Irq}) ->
    Next = deliver_input(S),
    ok = erx_irq_line:ack(Irq),
    Next.

deliver_input(S = #driver{console = Console}) ->
    {Bytes, Next} = drain(S, <<>>),
    case Bytes of
        <<>> -> ok;
        _ -> Console ! {erx_console_input, Bytes}
    end,
    Next.

drain(S0 = #driver{dev = Dev}, Bytes) ->
    {Lsr, S} = read_lsr(S0),
    case erx_device:field(Dev, lsr, data_ready, Lsr) of
        0 ->
            {Bytes, S};
        1 ->
            Byte = erx_device:field(Dev, io, data, erx_device:read(Dev, io)),
            drain(S, <<Bytes/binary, Byte>>)
    end.

%% LSR's word, read once, with the overrun it shows counted and, if it is one to report,
%% logged: the read clears RX_OVERRUN, so the overrun is counted here or never.
read_lsr(S = #driver{dev = Dev, overruns = Seen}) ->
    Lsr = erx_device:read(Dev, lsr),
    {Overruns, Report} = count_overrun(Lsr, Seen),
    case Report of
        false -> ok;
        true -> logger:warning("erx_mini_uart: receive FIFO overrun, input lost (~b overruns)",
                               [Overruns])
    end,
    {Lsr, S#driver{overruns = Overruns}}.

%% The overrun count after a read of LSR that returned Lsr, from Seen before it, and
%% whether to log it: the first overrun and each doubling of the count are logged.
-spec count_overrun(non_neg_integer(), non_neg_integer()) -> {non_neg_integer(), boolean()}.
count_overrun(Lsr, Seen) ->
    case ?ERX_HW_MINI_UART_LSR_RX_OVERRUN_GET(Lsr) of
        0 ->
            {Seen, false};
        1 ->
            Overruns = Seen + 1,
            {Overruns, Overruns band (Overruns - 1) =:= 0}
    end.
