%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_line).
-moduledoc """
The line's process (docs/design-bluetooth.md, "The controller's line"):
the one owner of a line tree's receive buffer and of its driver, and the
keeper of every request of the tree that waits for an event. `erx_line_fs`
is the tree; its callbacks hand this process what cannot finish at once.

**The driver** speaks the console driver's messages (erx_console): the
line sends it `{erx_console_output, Token, Bytes}` and hears
`{erx_console_written, Token}` once they are written, and
`{erx_console_input, Bytes}` as bytes arrive. The line starts it with the
function it was started with, with the grant's flow or with flow `none`, and
is linked to it, trapping exits, so the line's end ends the driver. A driver
that does not start, or ends outside a
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

**A reset** is a power cycle between two fresh starts of the driver, the
five steps of "A reset", each finished before the next:

1. the driver, if any, ends, and the line waits for its end, so no byte the
   old driver read is taken after it (one process's messages arrive before
   its end);
2. the **holding** driver is started with flow `none`, which keeps the
   UART's RTS deasserted, and the buffer is emptied;
3. the power line's off notification is asked of the device service, and
   the off time waited;
4. the on notification is asked, and the on time waited;
5. the holding driver ends, the line waits for its end, and the driver is
   started with the grant's flow; the buffer is emptied, the broken mark
   cleared and the reset answered.

A notification is asked from a process linked to the line, so the line
answers flushes, clunks and reads while the device service's firmware
worker makes it, and each wait is the line's timer. A line whose device has
no power line, as on QEMU `virt`, runs steps 1 and 5 alone. A holding
driver that ends during the power cycle leaves the UART as it programmed
it, so step 5 then has no driver to end.

**A reset that fails**, at a start that does not start or a notification
answered other than `ok`, fails the same way at any step: the line ends the
holding driver, if any, and waits for its end as it waits for every event,
answering flushes, clunks and reads meanwhile, so no driver runs with flow
`none` past the reset; then the line is left broken with no driver, and the
reset answers `eio`, as does every write that arrived during it. The next
reset begins with no driver to stop.

**Decisions and effects.** `erx_line_core` makes every decision above: it
takes each message as an event and returns the next state and the actions
to perform. This module is its edge: it performs those actions (starting a
driver, sending it bytes, ending it, asking for a notification, starting a
timer) through `erx_actions:perform/3`, and serves the grants and the status.

**The tree's grants** (erx_fs_grants) the line starts and is linked to,
so the end of either ends the other and its supervisor restarts both. The
line names them as the system domain's `line` service (erx_facet:serve/2),
so the domain service starts a grant of the tree in each domain the
manifest grants `line` when that domain reports ready. A restart of the
line ends those grants with the old set, and the domain service makes no
new one until the grantee restarts.

**The buffer** holds at most `line_rx_max` bytes. Input that would pass it
marks the line broken: the buffer is dropped and every read answers `eio`
until the next reset. Input that arrives while broken or during a reset is
dropped.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-export_type([request/0, start/0, power/0]).

%% The tree's term for what a waiting request asks.
-type request() :: {read, Count :: pos_integer()}
                 | {write, Offset :: non_neg_integer(), Bytes :: binary()}
                 | {reset, Offset :: non_neg_integer(), Count :: pos_integer()}.
%% Starts the line's driver for Line, linked to the caller, the line, whose end a
%% reset waits for through that link, or answers why it did not start: with flow
%% `none`, holding the UART's RTS deasserted, or with the grant's flow.
-type start() :: fun((Line :: pid(), Flow :: none | grant) -> {ok, pid()} | {error, term()}).
%% The power line of the line's device (docs/design-bluetooth.md, "The power line"): the
%% device service's call that asks for its off or on notification, which answers within
%% the device service's deadline (at most 1 s at its firmware worker, once the worker's
%% earlier requests have run), so a reset ends; and the off and on times in
%% milliseconds. none when the device has no power line.
-type power() :: none
               | #{notify := fun((off | on) -> ok | {error, term()}),
                   off := pos_integer(), on := pos_integer()}.

-record(line, {start :: start(),
               %% The power line's notification call, none for a device without one.
               notify :: none | fun((off | on) -> ok | {error, term()}),
               %% The tree's grants, linked: the end of either ends the other.
               grants :: pid(),
               core :: erx_line_core:core()}).

-doc """
Starts a line whose driver Start starts and whose device's power line is Power, linked
to the caller. Its heap, shared binaries included, covers the buffer and one full
grant's requests in flight, each at most `line_rx_max` bytes, so neither can grow past
it.
""".
-spec start_link(start(), power()) -> {ok, pid()}.
start_link(Start, Power) when is_function(Start, 2) ->
    Words = (erx_fs_grant:in_flight_max() + 2) * ?ERX_LINE_RX_MAX div erlang:system_info(wordsize),
    Heap = #{size => Words + 65536, kill => true, include_shared_binaries => true},
    gen_server:start_link(?MODULE, {Start, Power}, [{spawn_opt, [{max_heap_size, Heap}]}]).

-doc false.
init({Start, Power}) ->
    process_flag(trap_exit, true),
    {ok, Grants} = erx_fs_grants:start_link(erx_line_fs, self()),
    ok = erx_facet:serve(line, Grants),
    {Notify, Times} = case Power of
                          none -> {none, none};
                          #{notify := Call, off := Off, on := On} -> {Call, #{off => Off, on => On}}
                      end,
    {Core, Actions} = erx_line_core:new(Times),
    {ok, perform_all(Actions, #line{start = Start, notify = Notify, grants = Grants, core = Core})}.

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

state(#line{core = Core}) ->
    #{rx := Rx, broken := Broken, driver := Driver, reset := Reset, requests := Requests} =
        erx_line_core:facts(Core),
    #{rx => erx_report:bytes(Rx), broken => Broken, driver => Driver,
      resetting => Reset =/= none,
      requests => [{Wait, shown_request(Request), State}
                   || {Wait, Request, State} <- Requests]};
state(_State) ->
    hidden.

message(?ERX_FS_WAIT(Wait, Request)) ->
    ?ERX_FS_WAIT(Wait, shown_request(Request));
message({erx_console_input, Bytes}) when is_binary(Bytes) ->
    {erx_console_input, erx_report:bytes(Bytes)};
message(_Message) ->
    hidden.

%% A request() with a write's bytes counted; a term of no kind of request() is hidden.
shown_request({write, Offset, Bytes}) when is_binary(Bytes) -> {write, Offset, erx_report:bytes(Bytes)};
shown_request({read, _Count} = Read) -> Read;
shown_request({reset, _Offset, _Count} = Reset) -> Reset;
shown_request(_Request) -> hidden.

%% Every message but the grants' end is one event of the core.
-doc false.
handle_info({'EXIT', Grants, Reason}, #line{grants = Grants} = L) ->
    {stop, {grants_ended, erx_report:reason_name(Reason)}, L};
handle_info(Message, L) ->
    {noreply, step({info, Message}, L)}.

%% Steps the core with one event and performs its actions in order. The core never
%% stops the line, so every step continues.
step(Event, #line{core = Core} = L) ->
    {Next, Actions} = erx_line_core:step(Event, Core),
    perform_all(Actions, L#line{core = Next}).

perform_all(Actions, L) ->
    {continue, Performed} = erx_actions:perform(Actions, fun perform/2, L),
    Performed.

%% A start's answer and a notifier's pid are the core's next event, stepped before any
%% other message is taken. The notifier is linked to the line, so the line's end ends
%% it, and its end carries the answer: a crash of the call ends it with a refusal, never
%% with the call's terms, which no report then shows.
perform({start, Flow}, #line{start = Start} = L) ->
    step({started, Flow, Start(self(), Flow)}, L);
perform({notify, Phase}, #line{notify = Notify} = L) ->
    Notifier = spawn_link(fun() -> exit({notified, try Notify(Phase) catch _:_ -> {error, crashed} end}) end),
    step({notifying, Phase, Notifier}, L);
perform({timer, Ms, Token}, L) ->
    _ = erlang:start_timer(Ms, self(), Token),
    L;
perform({output, Driver, Token, Bytes}, L) ->
    Driver ! {erx_console_output, Token, Bytes},
    L;
perform({kill, Pid}, L) ->
    exit(Pid, kill),
    L.
