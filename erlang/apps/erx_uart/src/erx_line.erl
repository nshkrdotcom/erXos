%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_line).
-moduledoc """
The line's process (docs/design-bluetooth.md, "The controller's line"):
the one owner of a line tree's receive buffer and of its driver, and the
keeper of every request of the tree that waits for an event. `erx_line_fs`
is the tree; its callbacks hand this process what cannot finish at once.

**The driver** speaks the console driver's messages (erx_console): the
line sends it `{erx_console_output, Ref, Bytes}` and hears
`{erx_console_written, Ref}` once they are written, and
`{erx_console_input, Bytes}` as bytes arrive. The line starts it with the
function it was started with and is linked to it, trapping exits, so the
line's end ends the driver. A driver that does not start, or ends outside a
reset (a broken virtio queue, a device gone), leaves the line **broken with
no driver**: reads and writes of `data` answer `eio` until a reset starts a
fresh one, and the line itself lives on, so a device that is absent or keeps
failing restarts nothing above it.

**Waiting requests** (docs/design-files.md, "Serving: the `erx_fs`
behaviour", "Waiting requests"). The tree hands three kinds here, each the
tree's own term, and this process holds them in one `erx_fs_waits` set and
answers each once through it:

* `{read, Count}`, a read of `data`: answered at once from the buffer when
  it holds bytes, at least one and at most Count of them, and `eio` while
  the line is broken or a reset runs; otherwise it waits, and the reads
  waiting are served in the order they arrived as bytes come.
* `{write, Offset, Bytes}`, a write of `data`: begun when it is handed to
  the driver, one write at a time, and answered with its count once the
  driver has written it.
* `{reset, Offset, Count}`, a `reset` written to `ctl`: begun at its first
  step and answered when its last is done.

A reset begins as soon as it arrives, unless another runs, ahead of every
write: its first step, ending the driver, is what ends a write the device
holds. Every write sent before it, the one in flight and those waiting, and
every read waiting answer `eio`, since no byte of the last bring-up
survives a reset; requests sent after it wait for it. Writes begin one at a
time in the order they arrived. A request waiting, not begun, is answered
`eintr` by the set at its flush or its fid's clunk; a begun one when its
effect ends.

**A reset** runs the steps of "A reset" for a platform with no power line:
it ends the driver, if any, and waits for its end, so no byte the old driver
read is taken after it (one process's messages arrive before its end), then
empties the buffer, clears the broken mark and starts the driver again; a
driver that does not start answers the reset `eio` and leaves the line broken
with no driver.

**The tree's grants** (erx_fs_grants) the line starts and is linked to,
so the end of either ends the other and its supervisor restarts both. No
service serves them: docs/todo-bluetooth.md, "the line's service side".

**The buffer** holds at most `line_rx_max` bytes. Input that would pass it
marks the line broken: the buffer is dropped and every read answers `eio`
until the next reset. Input that arrives while broken or during a reset is
dropped.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-export_type([request/0, start/0]).

%% The tree's term for what a waiting request asks.
-type request() :: {read, Count :: pos_integer()}
                 | {write, Offset :: non_neg_integer(), Bytes :: binary()}
                 | {reset, Offset :: non_neg_integer(), Count :: pos_integer()}.
%% Starts the line's driver for Line, linked to the caller, the line, whose end a
%% reset waits for through that link, or answers why it did not start.
-type start() :: fun((Line :: pid()) -> {ok, pid()} | {error, term()}).

-record(line, {start :: start(),
               %% The tree's grants, linked: the end of either ends the other.
               grants :: pid(),
               %% The driver, or none from a reset's first step to its last and
               %% while the line is broken with no driver.
               driver :: pid() | none,
               rx = <<>> :: binary(),
               broken = false :: boolean(),
               %% The write handed to the driver: its wait, the reference the
               %% driver's written answer carries, and the answer it then gets.
               writing = none :: none | {erx_fs_waits:wait(), reference(), term()},
               %% The reset begun: its wait, its answer and the driver it is ending.
               reset = none :: none | {erx_fs_waits:wait(), term(), pid()},
               waits = erx_fs_waits:new() :: erx_fs_waits:waits()}).

-doc """
Starts a line whose driver Start starts, linked to the caller. Its heap,
shared binaries included, covers the buffer and one full grant's requests
in flight, each at most `line_rx_max` bytes, so neither can grow past it.
""".
-spec start_link(start()) -> {ok, pid()}.
start_link(Start) when is_function(Start, 1) ->
    Words = (erx_fs_grant:in_flight_max() + 2) * ?ERX_LINE_RX_MAX div erlang:system_info(wordsize),
    Heap = #{size => Words + 65536, kill => true, include_shared_binaries => true},
    gen_server:start_link(?MODULE, Start, [{spawn_opt, [{max_heap_size, Heap}]}]).

-doc false.
init(Start) ->
    process_flag(trap_exit, true),
    {ok, Grants} = erx_fs_grants:start_link(erx_line_fs, self()),
    {ok, started(Start(self()), #line{start = Start, grants = Grants, driver = none})}.

-doc false.
handle_call(_Request, _From, L) ->
    {reply, {error, einval}, L}.

-doc false.
handle_cast(_Request, L) ->
    {noreply, L}.

-doc """
What a crash report or `sys:get_status/1` shows of the line (docs/design-log.md,
"Reports carry no term"). The buffer, the waiting writes and the bytes of a message are
the controller's traffic, which carries keys, so each key shows as a size or not at all:

* `state`: the buffer's size, the marks, and the requests waiting with a write's
  bytes counted;
* `message`: a request or input of the line's own protocol with its bytes counted,
  any other message (an exit's reason, say) as `hidden`;
* `log`: empty;
* `reason`: its leading atom (erx_report:reason_name/1);
* any other key: `hidden`.

`sys:get_state/1`, `sys:trace/2` and `sys:log/2` are not reports and show the state whole,
to the system domain's code only.
""".
format_status(Status) ->
    erx_report:status(Status, #{state => fun state/1, message => fun message/1}).

state(#line{rx = Rx, broken = Broken, driver = Driver, reset = Reset, waits = Waits}) ->
    #{rx_bytes => byte_size(Rx), broken => Broken, driver => Driver,
      resetting => Reset =/= none,
      requests => [{Wait, shown_request(Request), State}
                   || {Wait, Request, State} <- erx_fs_waits:list(Waits)]};
state(_State) ->
    hidden.

message(?ERX_FS_WAIT(Wait, Request)) ->
    ?ERX_FS_WAIT(Wait, shown_request(Request));
message({erx_console_input, Bytes}) when is_binary(Bytes) ->
    {erx_console_input, byte_size(Bytes)};
message(_Message) ->
    hidden.

%% A request() with a write's bytes counted; a term of no kind of request() is hidden.
shown_request({write, Offset, Bytes}) when is_binary(Bytes) -> {write, Offset, byte_size(Bytes)};
shown_request({read, _Count} = Read) -> Read;
shown_request({reset, _Offset, _Count} = Reset) -> Reset;
shown_request(_Request) -> hidden.

%% Every message is one event; after it, whatever may begin begins (pump/1), so
%% no event can leave a write or a reset waiting that the state lets run.
-doc false.
handle_info({'EXIT', Grants, Reason}, #line{grants = Grants} = L) ->
    {stop, {grants_ended, erx_report:reason_name(Reason)}, L};
handle_info(Message, L) ->
    {noreply, pump(event(Message, L))}.

event(?ERX_FS_WAIT(Wait, Request), L) ->
    take(Wait, Request, L);
event({erx_console_input, Bytes}, L) ->
    input(Bytes, L);
event({erx_console_written, Ref}, #line{writing = {Wait, Ref, Written}} = L) ->
    answer(Wait, Written, L#line{writing = none});
event({'EXIT', Old, _}, #line{reset = {_, _, Old}} = L) ->
    finish_reset(L);
event({'EXIT', Driver, _}, #line{driver = Driver} = L) when Driver =/= none ->
    no_driver(L);
event(Message, #line{waits = Waits} = L) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Settled} -> L#line{waits = Settled};
        %% A begun request, the write in flight or the reset, is answered
        %% when its effect ends.
        {begun, _Wait, _Request, Flushing} -> L#line{waits = Flushing};
        {dropped, Dropped} -> L#line{waits = Dropped};
        %% A late answer of a driver a reset ended, or another process's end.
        unknown -> L
    end.

%% Waiting requests ----------------------------------------------------------

take(Wait, {read, _Count} = Read, #line{reset = Reset, broken = Broken} = L)
  when Reset =/= none; Broken ->
    refuse(Wait, Read, {error, eio}, L);
take(Wait, {read, _Count} = Read, L) ->
    serve(hold(Wait, Read, L));
take(Wait, {write, _Offset, _Bytes} = Write, L) ->
    hold(Wait, Write, L);
take(Wait, {reset, _Offset, _Count} = Reset, L) ->
    hold(Wait, Reset, L).

hold(Wait, Request, #line{waits = Waits} = L) ->
    L#line{waits = erx_fs_waits:hold(?ERX_FS_WAIT(Wait, Request), Waits)}.

%% A request answered in the step that takes it, through the set as every answer is.
refuse(Wait, Request, Refused, L) ->
    answer(Wait, Refused, hold(Wait, Request, L)).

answer(Wait, Result, #line{waits = Waits} = L) ->
    L#line{waits = erx_fs_waits:answer(Wait, Result, Waits)}.

answer_all(Waits, Result, L) ->
    lists:foldl(fun(Wait, Acc) -> answer(Wait, Result, Acc) end, L, Waits).

%% The requests still waiting, in the order they arrived.
waiting(#line{waits = Waits}) ->
    [{Wait, Request} || {Wait, Request, waiting} <- erx_fs_waits:list(Waits)].

readers(L) ->
    [{Wait, Count} || {Wait, {read, Count}} <- waiting(L)].

%% Reads ---------------------------------------------------------------------

%% Bytes from the driver: kept, then given to the waiting reads in their order.
input(_Bytes, #line{reset = Reset, broken = Broken} = L) when Reset =/= none; Broken ->
    L;
input(Bytes, #line{rx = Rx} = L) when byte_size(Rx) + byte_size(Bytes) > ?ERX_LINE_RX_MAX ->
    answer_all([Wait || {Wait, _} <- readers(L)], {error, eio}, L#line{rx = <<>>, broken = true});
input(Bytes, #line{rx = Rx} = L) ->
    serve(L#line{rx = <<Rx/binary, Bytes/binary>>}).

serve(#line{rx = <<>>} = L) ->
    L;
serve(#line{rx = Rx} = L) ->
    case readers(L) of
        [{Wait, Count} | _] ->
            Size = min(Count, byte_size(Rx)),
            <<Taken:Size/binary, Rest/binary>> = Rx,
            serve(answer(Wait, {ok, Taken}, L#line{rx = Rest}));
        [] ->
            L
    end.

%% Writes and resets ---------------------------------------------------------

%% Begins what may begin: the oldest waiting reset unless one runs, which goes
%% ahead of every write; else the oldest waiting write unless a reset runs or a
%% write is in flight.
pump(#line{reset = none} = L) ->
    case [{Wait, {ok, Count, Offset}} || {Wait, {reset, Offset, Count}} <- waiting(L)] of
        [{Reset, Done} | _] -> begin_reset(Reset, Done, L);
        [] -> begin_write(L)
    end;
pump(L) ->
    L.

begin_write(#line{writing = none, driver = none} = L) ->
    answer_all([Wait || {Wait, {write, _Offset, _Bytes}} <- waiting(L)], {error, eio}, L);
begin_write(#line{writing = none, driver = Driver, waits = Waits} = L) ->
    case [{Wait, Offset, Bytes} || {Wait, {write, Offset, Bytes}} <- waiting(L)] of
        [{Wait, Offset, Bytes} | _] ->
            Ref = make_ref(),
            Driver ! {erx_console_output, Ref, Bytes},
            L#line{writing = {Wait, Ref, {ok, byte_size(Bytes), Offset}},
                   waits = erx_fs_waits:began(Wait, Waits)};
        [] ->
            L
    end;
begin_write(L) ->
    L.

%% Step 1: the driver ends. Every write sent before the reset answers eio, the one
%% the driver holds and those still waiting, since no byte of the last bring-up
%% survives a reset, and so does every read waiting; writes sent after it wait
%% for it. The rest follows the driver's end, in finish_reset/1, at once when the
%% line had no driver, after which whatever may begin next begins too.
begin_reset(Reset, Done, #line{driver = Driver, waits = Waits} = L) ->
    {Before, _} = lists:splitwith(fun({Wait, _}) -> Wait =/= Reset end, waiting(L)),
    Ended = [Wait || {Wait, Request} <- Before, element(1, Request) =:= write] ++
            [Wait || {Wait, _Count} <- readers(L)] ++
            in_flight(L),
    Begun = answer_all(Ended, {error, eio},
                       L#line{driver = none, writing = none, reset = {Reset, Done, Driver},
                              waits = erx_fs_waits:began(Reset, Waits)}),
    case Driver of
        none -> pump(finish_reset(Begun));
        _ -> exit(Driver, kill), Begun
    end.

%% Step 3, once the old driver has ended, which its own messages came before, so
%% none of them is taken: the buffer is emptied, the broken mark cleared and the
%% driver started afresh, whose start programs the UART without waiting
%% (docs/design-bluetooth.md, "A reset"). Then the reset answers, eio when the
%% fresh driver did not start, which leaves the line broken with no driver.
finish_reset(#line{reset = {Reset, Done, _Old}, start = Start} = L) ->
    case Start(self()) of
        {ok, Fresh} ->
            answer(Reset, Done, L#line{driver = Fresh, rx = <<>>, broken = false, reset = none});
        {error, _Reason} ->
            answer(Reset, {error, eio}, no_driver(L#line{reset = none}))
    end.

%% The line's driver as Start answered at the line's start.
started({ok, Driver}, L) -> L#line{driver = Driver};
started({error, _Reason}, L) -> no_driver(L).

%% The line broken with no driver: the buffer is dropped and the reads and writes
%% waiting answer eio, as every later one does until a reset starts a driver.
no_driver(L) ->
    Waiting = [Wait || {Wait, Request} <- waiting(L), element(1, Request) =/= reset] ++ in_flight(L),
    answer_all(Waiting, {error, eio}, L#line{driver = none, writing = none, rx = <<>>, broken = true}).

in_flight(#line{writing = none}) -> [];
in_flight(#line{writing = {Wait, _Ref, _Written}}) -> [Wait].
