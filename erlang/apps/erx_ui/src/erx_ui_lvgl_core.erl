%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_lvgl_core).
-moduledoc """
The decisions of the LVGL renderer, erx_ui_lvgl, about the two pipes it
shares with the program erx-lvgl (docs/design-display.md, "The widget
server"): what it writes to the program, when it presents the window's
buffer, and when the program has broken the protocol. A pure state
machine: step/2 takes the renderer's state and one event and returns the
next state and the actions erx_ui_lvgl performs, in order, the last
`{stop, Reason}` when the program is to be stopped. A stop comes alone.

The program draws a frame into the window's buffer and reports it with
one `damage` record that names the width and height it drew at and the
rectangles it drew. Until that report is answered with `presented` the
program draws nothing. So the renderer is either `idle`, with no report
open, or `open`, presenting one report; in both it knows the size of the
last `screen` record it wrote, the only size whose stride the buffer's
rows have.

* A report read while idle is judged at its own size. When that is the
  last screen record's size, the renderer presents its rectangles at that
  width and height, each turned from the program's corner, width and
  height into the window's half-open `{X0, Y0, X1, Y1}`
  (erx_win_core:rect()), and is open until the display answers the present
  (`shown`); then it writes `presented`. A report of another size was
  drawn before the program read a later screen record, at a stride the
  buffer no longer has: it is presented as nothing and answered at once.
* While a report is open the renderer writes the program nothing but a
  resize's `screen` record, at once, and at the answer `presented`: the
  operations of a tree (whose apply is answered only then) and the
  window's input and repaint records wait in order and follow the
  `presented`. A screen record changes no pixel, so the open report is
  still shown at the size it was judged at, clipped by the display as a
  present for a stale size is; the screen record invalidates the
  program's whole screen, so its next report covers the new size.
* A report read while one is open, a record the reader refuses, the
  program's exit, the loss of its pipes, and a write the program leaves
  without room past erx_ui_lvgl's deadline stop the program (erx_ui_lvgl
  ends the UI with `{ui_down, Window, renderer_down}`).
* An event the program reports is passed to the widget server as a hit,
  in any state.
* A resize's `screen` record is the window's new size clipped to the
  buffer's extent, the size the renderer started at, which is the size
  the program's buffer was allocated at, as erx_win:resized/1 clips an
  image (docs/design-display.md, "Erlang clients"): a screen past the
  buffer would have the program draw past its mapping, which it refuses.
  A window shrunk to nothing is a screen of one pixel.

input/2 turns the window's `mouse` and `kbd` records into the `input`
records of the program's protocol: a pointer at its position in the
window, its first three buttons, and a typed rune as a key down and up.
The keys held, which a typed rune already carries, and the wheel's
buttons make none.

erx_ui_lvgl reads the window's `mouse` and `kbd` only while
reads_window/1 says so, which is while idle, so what waits is at most
the operations of one apply and the records of the reads that were in
flight when the report arrived; a resize comes as the `r` record of a
`mouse` read, so one that arrives while a report is open came from such
a read. A second apply before the
first is answered, and a `shown` with no report open, are the caller's
bugs, raised as errors.
""".

-export([start/3, step/2, size/1, reads_window/1, input/2]).
-export_type([state/0, event/0, action/0, stop_reason/0, exit_status/0]).

-type size() :: {Width :: 1..65535, Height :: 1..65535}.
-type token() :: term().
-type held() :: erx_ui_model:diff_op() | {input, term()} | repaint.

-doc """
The renderer's state: the buffer's extent, which no screen record passes,
and its phase. `Size` is the last screen record written. An open report
holds the records that wait for its answer, newest first, and the token
of the apply whose operations are among them, or `none`.
""".
-opaque state() :: {Extent :: size(), phase()}.
-type phase() :: {idle, size()}
               | {open, size(), Held :: [held()], Waiter :: token() | none}.

-doc """
What happens to the renderer. `apply` and `window` come from the widget
server and the window, `resize` from the window, `damage`, `event` and
`refused` from the generated reader of the program's output, `shown`
from the display's answer to a present, `exit` from the program's
end, its exit status as the port or the program's handler gives it,
`lost` from the end of its pipes without an exit status, such as a write
that found the program gone, and `stalled` from a write the program
left without room until its deadline.
""".
-type event() :: {apply, [erx_ui_model:diff_op()], token()}
               | {window, {input, term()} | repaint}
               | {resize, integer(), integer(), Chan :: 0..16#ffffffff}
               | {damage, 0..65535, 0..65535, [erx_ui_wire:rect(), ...]}
               | {event, erx_ui_model:node_id(), atom(), term()}
               | shown
               | {refused, term()}
               | {exit, exit_status()}
               | {lost, term()}
               | stalled.

-doc """
What erx_ui_lvgl does: write records to the program's standard input,
present rectangles of the window's buffer drawn at a width and height,
answer an apply by its token, hand the widget server a hit as
`{ui_hit, Node, Event, Value}`, or stop the program, always the last.
""".
-type action() :: {write, [erx_ui_wire:wire_record()]}
                | {present, 1..65535, 1..65535, [erx_win_core:rect(), ...]}
                | {reply, token()}
                | {hit, erx_ui_model:node_id(), atom(), term()}
                | {stop, stop_reason()}.

-doc "Why the program is stopped, for the log; the UI ends as `renderer_down`.".
-type stop_reason() :: report_before_presented | {refused, term()} | {exit, exit_status()}
                     | {lost, term()} | stalled.

-doc "A port's exit status on the host, or the program's end as its handler reports it on erXos.".
-type exit_status() :: non_neg_integer() | {exited, 0..255} | {signaled, atom()}.

-doc """
The renderer of a window of `Width` by `Height` in channel `Chan`, whose
buffer was allocated at that size, and the screen record it writes
first, before any other record.
""".
-spec start(1..65535, 1..65535, 0..16#ffffffff) -> {state(), [action()]}.
start(Width, Height, Chan) ->
    {{{Width, Height}, {idle, {Width, Height}}}, [{write, [{screen, Width, Height, Chan}]}]}.

-doc "The size of the last screen record written.".
-spec size(state()) -> size().
size({_Extent, {idle, Size}}) -> Size;
size({_Extent, {open, Size, _Held, _Waiter}}) -> Size.

-doc "Whether erx_ui_lvgl may read the window's next input: only while no report is open.".
-spec reads_window(state()) -> boolean().
reads_window({_Extent, {idle, _Size}}) -> true;
reads_window({_Extent, {open, _Size, _Held, _Waiter}}) -> false.

-doc """
The `input` records of a window's `mouse` or `kbd` record, for a window
whose rectangle begins at `{X0, Y0}`: a pointer's position is made
relative to the window and held to the record's range.
""".
-spec input(erx_win_core:pointer() | erx_win_core:key(), {integer(), integer()}) ->
          [{input, term()}].
input({mouse, X, Y, Buttons, _Msec}, {X0, Y0}) ->
    [{input, {pointer, coordinate(X - X0), coordinate(Y - Y0), Buttons band 2#111}}];
input({typed, Rune}, _Origin) ->
    [{input, {key, down, 0, Rune}}, {input, {key, up, 0, Rune}}];
input({Held, _Keys}, _Origin) when Held =:= down; Held =:= up ->
    [];
input({resized, _X, _Y, _Buttons, _Msec}, _Origin) ->
    [].

-doc """
The next state and the actions for `Event`, in order; the last is
`{stop, Reason}` when the program broke the protocol or ended.
""".
-spec step(event(), state()) -> {state(), [action()]}.
step({resize, W, H, Chan}, {{EW, EH} = Extent, Phase}) ->
    {Width, Height} = Size = {clipped(W, EW), clipped(H, EH)},
    {{Extent, resized(Phase, Size)}, [{write, [{screen, Width, Height, Chan}]}]};
step(Event, {Extent, Phase}) ->
    {Phase1, Actions} = phase(Event, Phase),
    {{Extent, Phase1}, Actions}.

phase({damage, W, H, Rects}, {idle, {W, H}} = Idle) ->
    {open(Idle), [{present, W, H, [half_open(Rect) || Rect <- Rects]}]};
phase({damage, _W, _H, _Rects}, {idle, _Size} = Idle) ->
    {Idle, [{write, [presented]}]};
phase({damage, _W, _H, _Rects}, {open, _, _, _} = Open) ->
    {Open, [{stop, report_before_presented}]};
phase(shown, {open, Size, Held, Waiter}) ->
    {{idle, Size}, [{write, [presented | lists:reverse(Held)]} | reply(Waiter)]};
phase(shown, {idle, _Size}) ->
    error(no_present_open);
phase({apply, Ops, Token}, {idle, _Size} = Idle) ->
    {Idle, [{write, Ops}, {reply, Token}]};
phase({apply, Ops, Token}, {open, Size, Held, none}) ->
    {{open, Size, lists:reverse(Ops, Held), Token}, []};
phase({apply, _Ops, _Token}, {open, _Size, _Held, _Waiter}) ->
    error(apply_in_flight);
phase({window, Record}, {idle, _Size} = Idle) ->
    {Idle, [{write, [Record]}]};
phase({window, Record}, {open, Size, Held, Waiter}) ->
    {{open, Size, [Record | Held], Waiter}, []};
phase({event, Node, Name, Value}, Phase) ->
    {Phase, [{hit, Node, Name, Value}]};
phase({refused, Reason}, Phase) ->
    {Phase, [{stop, {refused, Reason}}]};
phase({exit, Status}, Phase) ->
    {Phase, [{stop, {exit, Status}}]};
phase({lost, Reason}, Phase) ->
    {Phase, [{stop, {lost, Reason}}]};
phase(stalled, Phase) ->
    {Phase, [{stop, stalled}]}.

open({idle, Size}) -> {open, Size, [], none}.

%% A side of the window clipped to the buffer's, and never below one pixel.
clipped(Side, Extent) -> max(1, min(Side, Extent)).

coordinate(C) -> max(0, min(C, 16#ffff)).

resized({idle, _Old}, Size) -> {idle, Size};
resized({open, _Old, Held, Waiter}, Size) -> {open, Size, Held, Waiter}.

%% A report's rectangle, its corner, width and height (erx_ui_wire:rect()),
%% as the window presents it: half-open, {X0, Y0, X1, Y1}.
half_open({X, Y, Width, Height}) -> {X, Y, X + Width, Y + Height}.

reply(none) -> [];
reply(Token) -> [{reply, Token}].
