%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_line_core).
-moduledoc """
The line keeper's decisions (docs/design-bluetooth.md, "The controller's line"; erx_line's
documentation states the protocol): a state machine from one event to the next state and
the actions erx_line, the edge, performs in order (docs/style.md, "Functional core"). It
reads no clock and starts, sends to and ends no process itself. It holds the buffer, the
marks, the write handed to the driver, the reset in progress and the `erx_fs_waits` set,
whose own effects are its one exception: answering a request sends the answer to its
alias, and holding one monitors its grant.

**Events** are the keeper's messages, each `{info, Message}`, and the results of the two
actions that make a process, which the edge steps as soon as it has performed them, before
it takes another message: `{started, Flow, Result}`, what the driver's start answered, and
`{notifying, Phase, Notifier}`, the process that asks for a notification.

**Actions**:

* `{start, Flow}`: start the driver with flow `none` or `grant`, then step `started`;
* `{notify, Phase}`: ask for the power line's off or on notification from a process
  linked to the line whose end carries the answer, then step `notifying`;
* `{timer, Ms, Token}`: send the line `{timeout, Ref, Token}` after Ms milliseconds;
* `{output, Driver, Token, Bytes}`: hand the driver Bytes to write, through `erx_line`, the one sender of a driver's output message;
* `{kill, Pid}`: end a driver, whose end arrives as its `'EXIT'`.

A write's token is the core's count of the writes it has handed out, so a late answer of a
driver a reset ended matches no later write; a timer's is the reset's wait and its phase.

Every wait for a process's end is an event: no step blocks, so the keeper answers flushes,
clunks and reads while a driver ends.
""".

-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-export([new/1, step/2, facts/1]).

-export_type([core/0, event/0, action/0, power/0, flow/0]).

-type flow() :: none | grant.
-type phase() :: off | on.
%% The power line's off and on times in milliseconds, or none for a device without one.
-type power() :: none | #{off := pos_integer(), on := pos_integer()}.
-type event() :: {info, term()}
               | {started, flow(), {ok, pid()} | {error, term()}}
               | {notifying, phase(), pid()}.
-type action() :: {start, flow()}
                | {notify, phase()}
                | {timer, pos_integer(), {erx_fs_waits:wait(), phase()}}
                | {output, pid(), non_neg_integer(), binary()}
                | {kill, pid()}.

%% A reset begun: its wait, its answer, the holding driver (the one started with flow
%% none, from step 2 until its end, which alone clears it) and the event it waits for:
%%
%% * {stopping, Old}: the old driver's end;
%% * {starting, Flow}: the start's result;
%% * {notifying, Phase, asked | Notifier}: the notifier, then its end;
%% * {waiting, Phase}: the off or on time's timer;
%% * releasing: the holding driver's end, after which the driver starts afresh;
%% * failing: the holding driver's end, after which the reset answers eio.
-record(reset, {wait :: erx_fs_waits:wait(),
                done :: term(),
                holding = none :: pid() | none,
                step :: {stopping, pid() | none}
                      | {starting, flow()}
                      | {notifying, phase(), asked | pid()}
                      | {waiting, phase()}
                      | releasing
                      | failing}).

-record(core, {power :: power(),
               %% The driver, or none from a reset's first step to its last and
               %% while the line is broken with no driver.
               driver = none :: pid() | none,
               rx = <<>> :: binary(),
               broken = false :: boolean(),
               %% The write handed to the driver: its token, its wait, and the
               %% answer it then gets; and the next write's token.
               writing = none :: none | {non_neg_integer(), erx_fs_waits:wait(), term()},
               writes = 0 :: non_neg_integer(),
               reset = none :: none | #reset{},
               waits = erx_fs_waits:new() :: erx_fs_waits:waits()}).

-opaque core() :: #core{}.

-doc "A line with no driver yet, and the action that starts its first.".
-spec new(power()) -> {core(), [action()]}.
new(Power) ->
    {#core{power = Power}, [{start, grant}]}.

-doc """
One event: its own step, then whatever may begin begins, so no event can leave a write or a
reset waiting that the state lets run.
""".
-spec step(event(), core()) -> {core(), [action()]}.
step(Event, C) ->
    {Taken, Actions} = event(Event, C),
    {Next, Begun} = pump(Taken),
    {Next, Actions ++ Begun}.

-doc """
What the core holds, for the keeper's status and the core's tests: the buffer, the marks,
the driver, the write in flight, the reset as `{Wait, Holding, Step}` or `none`, and the
requests as `erx_fs_waits:list/1` shows them.
""".
-spec facts(core()) -> #{atom() => term()}.
facts(#core{rx = Rx, broken = Broken, driver = Driver, writing = Writing, reset = Reset,
            waits = Waits}) ->
    #{rx => Rx, broken => Broken, driver => Driver, writing => Writing,
      reset => case Reset of
                   none -> none;
                   #reset{wait = Wait, holding = Holding, step = Step} -> {Wait, Holding, Step}
               end,
      requests => erx_fs_waits:list(Waits)}.

%% Events --------------------------------------------------------------------

event({info, ?ERX_FS_WAIT(Wait, Request)}, C) ->
    {take(Wait, Request, C), []};
event({info, {erx_console_input, Bytes}}, C) when is_binary(Bytes) ->
    {input(Bytes, C), []};
event({info, {erx_console_written, Token}}, #core{writing = {Token, Wait, Written}} = C) ->
    {answer(Wait, Written, C#core{writing = none}), []};
event({started, grant, Result}, #core{reset = none} = C) ->
    {first(Result, C), []};
event({started, Flow, Result}, #core{reset = #reset{step = {starting, Flow}}} = C) ->
    started(Flow, Result, C);
event({notifying, Phase, Notifier}, #core{reset = #reset{step = {notifying, Phase, asked}} = R} = C) ->
    {C#core{reset = R#reset{step = {notifying, Phase, Notifier}}}, []};
event({info, {'EXIT', Old, _}}, #core{reset = #reset{step = {stopping, Old}}} = C) ->
    stopped(C);
event({info, {'EXIT', Notifier, Answer}}, #core{reset = #reset{step = {notifying, Phase, Notifier}}} = C) ->
    notified(Phase, Answer, C);
event({info, {timeout, _Ref, {Wait, Phase}}}, #core{reset = #reset{wait = Wait, step = {waiting, Phase}}} = C) ->
    waited(Phase, C);
event({info, {'EXIT', Holding, _}}, #core{reset = #reset{holding = Holding} = R} = C) ->
    released(C#core{reset = R#reset{holding = none}});
event({info, {'EXIT', Driver, _}}, #core{driver = Driver} = C) when Driver =/= none ->
    {no_driver(C), []};
event({info, Message}, #core{waits = Waits} = C) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Settled} -> {C#core{waits = Settled}, []};
        %% A begun request, the write in flight or the reset, is answered
        %% when its effect ends.
        {begun, _Wait, _Request, Flushing} -> {C#core{waits = Flushing}, []};
        {dropped, Dropped} -> {C#core{waits = Dropped}, []};
        %% A late answer of a driver a reset ended, a stale timer, or another
        %% process's end.
        unknown -> {C, []}
    end.

%% Waiting requests ----------------------------------------------------------

take(Wait, {read, _Count} = Read, #core{reset = Reset, broken = Broken} = C)
  when Reset =/= none; Broken ->
    refuse(Wait, Read, {error, eio}, C);
take(Wait, {read, _Count} = Read, C) ->
    serve(hold(Wait, Read, C));
take(Wait, {write, _Offset, _Bytes} = Write, C) ->
    hold(Wait, Write, C);
take(Wait, {reset, _Offset, _Count} = Reset, C) ->
    hold(Wait, Reset, C).

hold(Wait, Request, #core{waits = Waits} = C) ->
    C#core{waits = erx_fs_waits:hold(?ERX_FS_WAIT(Wait, Request), Waits)}.

%% A request answered in the step that takes it, through the set as every answer is.
refuse(Wait, Request, Refused, C) ->
    answer(Wait, Refused, hold(Wait, Request, C)).

answer(Wait, Result, #core{waits = Waits} = C) ->
    C#core{waits = erx_fs_waits:answer(Wait, Result, Waits)}.

answer_all(Waits, Result, C) ->
    lists:foldl(fun(Wait, Acc) -> answer(Wait, Result, Acc) end, C, Waits).

%% The requests still waiting, in the order they arrived.
waiting(#core{waits = Waits}) ->
    [{Wait, Request} || {Wait, Request, waiting} <- erx_fs_waits:list(Waits)].

readers(C) ->
    [{Wait, Count} || {Wait, {read, Count}} <- waiting(C)].

%% Reads ---------------------------------------------------------------------

%% Bytes from the driver: kept, then given to the waiting reads in their order.
input(_Bytes, #core{reset = Reset, broken = Broken} = C) when Reset =/= none; Broken ->
    C;
input(Bytes, #core{rx = Rx} = C) when byte_size(Rx) + byte_size(Bytes) > ?ERX_LINE_RX_MAX ->
    answer_all([Wait || {Wait, _} <- readers(C)], {error, eio}, C#core{rx = <<>>, broken = true});
input(Bytes, #core{rx = Rx} = C) ->
    serve(C#core{rx = <<Rx/binary, Bytes/binary>>}).

serve(#core{rx = <<>>} = C) ->
    C;
serve(#core{rx = Rx} = C) ->
    case readers(C) of
        [{Wait, Count} | _] ->
            Size = min(Count, byte_size(Rx)),
            <<Taken:Size/binary, Rest/binary>> = Rx,
            serve(answer(Wait, {ok, Taken}, C#core{rx = Rest}));
        [] ->
            C
    end.

%% Writes and resets ---------------------------------------------------------

%% Begins what may begin: the oldest waiting reset unless one runs, which goes
%% ahead of every write; else the oldest waiting write unless a reset runs or a
%% write is in flight.
pump(#core{reset = none} = C) ->
    case [{Wait, {ok, Count, Offset}} || {Wait, {reset, Offset, Count}} <- waiting(C)] of
        [{Reset, Done} | _] -> begin_reset(Reset, Done, C);
        [] -> begin_write(C)
    end;
pump(C) ->
    {C, []}.

begin_write(#core{writing = none, driver = none} = C) ->
    {answer_all([Wait || {Wait, {write, _Offset, _Bytes}} <- waiting(C)], {error, eio}, C), []};
begin_write(#core{writing = none, driver = Driver, writes = Token, waits = Waits} = C) ->
    case [{Wait, Offset, Bytes} || {Wait, {write, Offset, Bytes}} <- waiting(C)] of
        [{Wait, Offset, Bytes} | _] ->
            {C#core{writing = {Token, Wait, {ok, byte_size(Bytes), Offset}}, writes = Token + 1,
                    waits = erx_fs_waits:began(Wait, Waits)},
             [{output, Driver, Token, Bytes}]};
        [] ->
            {C, []}
    end;
begin_write(C) ->
    {C, []}.

%% Step 1: the driver ends. Every write sent before the reset answers eio, the one
%% the driver holds and those still waiting, since no byte of the last bring-up
%% survives a reset, and so does every read waiting; writes sent after it wait
%% for it. The rest follows the driver's end, in stopped/1, at once when the line
%% had no driver.
begin_reset(Reset, Done, #core{driver = Driver, waits = Waits} = C) ->
    {Before, _} = lists:splitwith(fun({Wait, _}) -> Wait =/= Reset end, waiting(C)),
    Ended = [Wait || {Wait, Request} <- Before, element(1, Request) =:= write] ++
            [Wait || {Wait, _Count} <- readers(C)] ++
            in_flight(C),
    Begun = answer_all(Ended, {error, eio},
                       C#core{driver = none, writing = none,
                              reset = #reset{wait = Reset, done = Done, step = {stopping, Driver}},
                              waits = erx_fs_waits:began(Reset, Waits)}),
    case Driver of
        none -> stopped(Begun);
        _ -> {Begun, [{kill, Driver}]}
    end.

%% Step 2, once the old driver has ended, which its own messages came before, so
%% none of them is taken: the holding driver is started with flow none, which
%% leaves RTS deasserted while the controller powers up. A line with no power line
%% goes on to step 5 at once.
stopped(#core{power = none} = C) ->
    afresh(C);
stopped(C) ->
    starting(none, C).

starting(Flow, #core{reset = R} = C) ->
    {C#core{reset = R#reset{step = {starting, Flow}}}, [{start, Flow}]}.

%% The line's first driver, outside any reset.
first({ok, Driver}, C) -> C#core{driver = Driver};
first(_Refused, C) -> no_driver(C).

%% The holding driver started: the buffer is emptied and step 3 begins. The fresh
%% driver started: step 5 ends; the buffer is emptied, the broken mark cleared and
%% the reset answers. Any other answer of either start fails the reset.
started(none, {ok, Holding}, #core{reset = R} = C) ->
    notify(off, C#core{rx = <<>>, reset = R#reset{holding = Holding}});
started(grant, {ok, Fresh}, #core{reset = #reset{wait = Reset, done = Done}} = C) ->
    {answer(Reset, Done, C#core{driver = Fresh, rx = <<>>, broken = false, reset = none}), []};
started(_Flow, _Refused, C) ->
    failed(C).

%% Steps 3 and 4 begin: the off or the on notification is asked.
notify(Phase, #core{reset = R} = C) ->
    {C#core{reset = R#reset{step = {notifying, Phase, asked}}}, [{notify, Phase}]}.

%% A notification performed starts the timer for the off or the on time; any other
%% end of the notifier fails the reset.
notified(Phase, {notified, ok}, #core{power = Power, reset = #reset{wait = Wait} = R} = C) ->
    {C#core{reset = R#reset{step = {waiting, Phase}}}, [{timer, maps:get(Phase, Power), {Wait, Phase}}]};
notified(_Phase, _Failed, C) ->
    failed(C).

%% The off time passed: step 4 begins. The on time passed: step 5 begins with the
%% holding driver's end (released/1), or at once when it has ended already.
waited(off, C) ->
    notify(on, C);
waited(on, #core{reset = #reset{holding = none}} = C) ->
    afresh(C);
waited(on, #core{reset = #reset{holding = Holding} = R} = C) ->
    {C#core{reset = R#reset{step = releasing}}, [{kill, Holding}]}.

%% The holding driver has ended: step 5 goes on, or the failed reset answers, when
%% the reset was waiting for that end. One that ends earlier leaves the UART as it
%% programmed it, RTS deasserted, and the power cycle goes on.
released(#core{reset = #reset{step = releasing}} = C) ->
    afresh(C);
released(#core{reset = #reset{step = failing}} = C) ->
    {failed_end(C), []};
released(C) ->
    {C, []}.

%% Step 5, once no driver runs: the driver is started with the grant's flow.
afresh(C) ->
    starting(grant, C).

%% A reset that fails, at any step: the holding driver, if any, is ended and the
%% reset waits for its end (released/1), so no driver runs with flow none past the
%% reset and the next one has no driver to stop. The holding field names a driver
%% whose end the core has not taken yet (it is cleared only there), so that end is
%% still to come.
failed(#core{reset = #reset{holding = none}} = C) ->
    {failed_end(C), []};
failed(#core{reset = #reset{holding = Holding} = R} = C) ->
    {C#core{reset = R#reset{step = failing}}, [{kill, Holding}]}.

%% The failed reset's end: the line is left broken with no driver, which answers
%% every write that arrived during the reset eio, and the reset answers eio.
failed_end(#core{reset = #reset{wait = Reset}} = C) ->
    answer(Reset, {error, eio}, no_driver(C#core{reset = none})).

%% The line broken with no driver: the buffer is dropped and the reads and writes
%% waiting answer eio, as every later one does until a reset starts a driver.
no_driver(C) ->
    Waiting = [Wait || {Wait, Request} <- waiting(C), element(1, Request) =/= reset] ++ in_flight(C),
    answer_all(Waiting, {error, eio}, C#core{driver = none, writing = none, rx = <<>>, broken = true}).

in_flight(#core{writing = none}) -> [];
in_flight(#core{writing = {_Token, Wait, _Written}}) -> [Wait].
