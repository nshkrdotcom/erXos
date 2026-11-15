%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_lvgl).
-behaviour(gen_statem).
-behaviour(erx_ui_renderer).
-moduledoc """
The LVGL renderer (docs/design-display.md, "The widget server"), a module
of the erx_ui_renderer behaviour: the process that runs the program
erx-lvgl over its two pipes and performs what erx_ui_lvgl_core decides.
It writes the core's records to the program's standard input, reads the
program's damage reports and events with erx_ui_wire:read/1, presents a
report through the window, answers an apply, hands the widget server each
hit, and ends, abnormally, when the core stops the program, which the
widget server it is linked to takes as `renderer_down`. It decides nothing
itself: every judgement is the core's.

start/3 links the process to the widget server and ignores its target:
until the window stack binds a window's size, channel and presents, the
options carry them. The options:

* `width`, `height` and `chan`: the window's size and channel.
* `program`: how the program starts, with the window's buffer as its
  descriptor 3.
  - `{handler, Spec, Peer, Bytes}` on erXos: the session starts it as any
    program (docs/design-programs.md, "The handler"),
    with erx_prog_handler:start/1 and `Spec`, a spec of that function
    without its descriptors: this process makes the two pipes and names
    their ends as descriptors 0 and 1, and the handler lends the program
    a buffer of `Bytes` in the pixel area shared with the display domain
    `Peer` as descriptor 3. The program's output is read by a reader, a
    process linked to this one that holds the read end, which a session
    process hands it with erx_pipe_srv:inherit/2 (docs/design-pipes.md,
    "The session's pipe NIF"). It reads with erx_pipe_srv:read/3 and
    sends each read on, as a port sends its data, and ends at the end of
    the output.
  - `{port, Open}` on the host: `Open` starts the program and returns its
    port, opened `binary`, `stream` and `exit_status`;
    test/fixtures/erx_lvgl_buffer.rb hands it a file as the buffer.
* `present`: presents rectangles of the buffer, at its offset in the
  pixel area (0 on the host, whose buffer is a file of its own) and drawn
  at a width and height, through the window. The display's answer comes
  back as shown/1.
* `present_text`: the canonical text of a `present` property
  (erx_ui_wire:present()).

The shell takes the window's input and resizes, window/2 and resize/3,
only while erx_ui_lvgl_core:reads_window/1 holds: in any other state they
stay queued, postponed, until the open report is answered, so the core
holds at most one apply's operations. stop/1 stops the program and ends
the shell without consulting the core, so the program's end then is no
fault. A fault ends the shell, and with it an apply/2 that waits. An
apply that comes while a report is open returns once the report is
answered, so the process that answers the window's presents must not be
the one waiting in apply/2.

start/3 waits at most ?START_MS for the program's start, the pipes, the
buffer's lend and the handler's answer included; past it the shell is
killed, and with it what the start made, and start/3 raises
`{badmatch, {error, timeout}}`, as it raises any refusal.

On erXos a write waits at most ?WRITE_MS for room in the program's input,
erx_pipe_srv:write/3's timeout, so a program that stops reading is a
fault (`stalled`) and no call waits on it longer. A write that finds the
program gone is dropped, and the program's end, its exit status or the
loss of its pipes, stops the program as the core says. On the host a
program that stops reading its input blocks the shell in port_command/2,
and with it every call (a residual, TODO.md).
""".

-export([start/3, apply/2, stop/1, window/2, resize/3, shown/1]).
-export([init/1, callback_mode/0, handle_event/4]).

%% How long start/3 waits for the shell's init, the program's start.
-define(START_MS, 30000).
%% How long a write waits for room in the program's input before the
%% program counts as stalled.
-define(WRITE_MS, 10000).
%% The most a reader reads of the program's output at once.
-define(READ_BYTES, 4096).

-type program() :: {handler, Spec :: map(), Peer :: pos_integer(), Bytes :: pos_integer()}
                 | {port, Open :: fun(() -> port())}.

%% A running program: its port, or on erXos its handler and the handler's
%% monitor, the write end of its input and the reader of its output.
-type running() :: {port, port()}
                 | {piped, #{handler := pid(), watch := reference(), input := term(), reader := pid()}}.

-type opts() :: #{width := 1..65535, height := 1..65535, chan := 0..16#ffffffff,
                  program := program(),
                  present := fun((non_neg_integer(), 1..65535, 1..65535, [erx_ui_lvgl_core:rect(), ...]) -> ok),
                  present_text := erx_ui_wire:present()}.

-doc "Starts the renderer of a window and its program, linked to the widget server, the caller.".
-spec start(erx_ui_renderer:target(), pid(), opts()) -> {ok, pid()}.
start(_Target, Server, Opts) ->
    {ok, _Shell} = gen_statem:start_link(?MODULE, Opts#{ui => Server}, [{timeout, ?START_MS}]).

-doc "Applies a tree's operations; returns once they are written to the program.".
-spec apply([erx_ui_model:diff_op()], pid()) -> {ok, pid()}.
apply(Ops, Shell) ->
    ok = gen_statem:call(Shell, {apply, Ops}, infinity),
    {ok, Shell}.

-doc "The window's next input record, or a repaint of the whole window.".
-spec window(pid(), {input, term()} | repaint) -> ok.
window(Shell, Record) ->
    gen_statem:cast(Shell, {window, Record}).

-doc "The window's new size.".
-spec resize(pid(), 1..65535, 1..65535) -> ok.
resize(Shell, Width, Height) ->
    gen_statem:cast(Shell, {resize, Width, Height}).

-doc "The display's answer to the last present: the buffer's rectangles are shown.".
-spec shown(pid()) -> ok.
shown(Shell) ->
    gen_statem:cast(Shell, shown).

-doc "Stops the program and ends the renderer; the program's end is then no fault.".
-spec stop(pid()) -> ok.
stop(Shell) ->
    gen_statem:call(Shell, close, infinity).

%% The state is erx_ui_lvgl_core:reads_window/1 of the core: `reading` or
%% `holding`, so the window's records are postponed exactly while the core
%% would hold them. The data holds the core, the running program, its
%% buffer's offset and the bytes of its output not yet a whole record.
callback_mode() -> handle_event_function.

init(#{width := W, height := H, chan := Chan, program := Program} = Opts) ->
    %% The death of the port or the reader (a write that found the program
    %% gone fails the port with epipe; a lost pipe fails the reader's read)
    %% reaches the core as `lost`.
    process_flag(trap_exit, true),
    case run(Program) of
        {ok, Running, Offset} ->
            {Core, Actions} = erx_ui_lvgl_core:start(W, H, Chan),
            Data = maps:merge(maps:with([present, present_text, ui, chan], Opts),
                              #{core => Core, program => Running, offset => Offset, unread => <<>>}),
            {ok, reading, Data, [{next_event, internal, {started, Actions}}]};
        {error, Reason} ->
            {stop, {shutdown, {renderer_down, {start, Reason}}}}
    end.

handle_event(internal, {started, Actions}, _State, Data) ->
    performed(Actions, Data);
handle_event({call, From}, {apply, Ops}, _State, Data) ->
    step({apply, Ops, From}, Data);
handle_event(cast, {window, _Record}, holding, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event(cast, {window, Record}, reading, Data) ->
    step({window, Record}, Data);
handle_event(cast, {resize, _W, _H}, holding, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event(cast, {resize, W, H}, reading, #{chan := Chan} = Data) ->
    step({resize, W, H, Chan}, Data);
handle_event(cast, shown, _State, Data) ->
    step(shown, Data);
handle_event(info, {Port, {data, Bytes}}, _State, #{program := {port, Port}} = Data) ->
    output(more(Bytes, Data));
handle_event(info, {Reader, {data, Bytes}}, _State, #{program := {piped, #{reader := Reader}}} = Data) ->
    output(more(Bytes, Data));
handle_event(info, {Port, {exit_status, Status}}, _State, #{program := {port, Port}} = Data) ->
    step({exit, Status}, Data);
handle_event(info, {erx_prog_exit, Handler, Status}, _State, #{program := {piped, #{handler := Handler}}} = Data) ->
    step({exit, Status}, Data);
handle_event(info, {'DOWN', Watch, process, _Handler, _Reason}, _State,
             #{program := {piped, #{watch := Watch}}} = Data) ->
    %% A handler that ends without telling of the program's end, which
    %% it does when it read none. Its reason may hold the program's
    %% spec and frames, so the log names only the handler.
    step({lost, handler}, Data);
handle_event(info, {'EXIT', Reader, normal}, _State, #{program := {piped, #{reader := Reader}}}) ->
    %% The reader read the end of the output; the program's end follows.
    keep_state_and_data;
handle_event(info, {'EXIT', Reader, Reason}, _State, #{program := {piped, #{reader := Reader}}} = Data) ->
    step({lost, {reader, Reason}}, Data);
handle_event(info, {'EXIT', Port, Reason}, _State, #{program := {port, Port}} = Data) ->
    step({lost, Reason}, Data);
handle_event(info, {erx_pipe_ready, _Pipe, _End}, _State, _Data) ->
    %% A doorbell of the input's write end that rang after the write that
    %% waited on it returned.
    keep_state_and_data;
handle_event(info, {pipe_report, _Report}, _State, _Data) ->
    %% The pipe server's report on the input's write end, applied to the
    %% end already.
    keep_state_and_data;
handle_event(info, {pipe_server_lost, _End}, _State, _Data) ->
    %% A later write fails with epipe, and the reader's read with eio.
    keep_state_and_data;
handle_event({call, From}, close, _State, #{program := Running}) ->
    close(Running),
    {stop_and_reply, normal, [{reply, From, ok}]}.

more(Bytes, #{unread := Unread} = Data) ->
    Data#{unread := <<Unread/binary, Bytes/binary>>}.

%% Each whole record of the program's output, in order, through the core.
output(#{unread := Unread} = Data) ->
    case erx_ui_wire:read(Unread) of
        {ok, Report, Rest} ->
            case step(Report, Data#{unread := Rest}) of
                {next_state, _State, Data1} -> output(Data1);
                Stop -> Stop
            end;
        more ->
            {next_state, state_of(Data), Data};
        {error, Reason} ->
            step({refused, Reason}, Data)
    end.

%% One event through the core: its actions performed and the state it
%% leaves, or the program stopped and the UI ended.
step(Event, #{core := Core} = Data) ->
    case erx_ui_lvgl_core:step(Event, Core) of
        {ok, Core1, Actions} -> performed(Actions, Data#{core := Core1});
        {stop, Reason} -> down(Reason, Data)
    end.

%% The actions performed in order, or, at a write that failed, the rest
%% dropped and the core told of the failure.
performed(Actions, Data) ->
    case perform(Actions, Data) of
        ok -> {next_state, state_of(Data), Data};
        {failed, Event} -> step(Event, Data)
    end.

state_of(#{core := Core}) ->
    case erx_ui_lvgl_core:reads_window(Core) of
        true -> reading;
        false -> holding
    end.

perform([], _Data) ->
    ok;
perform([Action | Rest], Data) ->
    case perform_one(Action, Data) of
        ok -> perform(Rest, Data);
        {failed, _Event} = Failed -> Failed
    end.

perform_one({write, Records}, #{program := Running, present_text := Text}) ->
    write(Running, [erx_ui_wire:encode(Record, Text) || Record <- Records]);
perform_one({present, W, H, Rects}, #{present := Present, offset := Offset}) ->
    ok = Present(Offset, W, H, Rects);
perform_one({reply, From}, _Data) ->
    gen_statem:reply(From, ok);
perform_one({hit, Node, Event, Value}, #{ui := Ui}) ->
    Ui ! {ui_hit, Node, Event, Value},
    ok.

%% The core stopped the program: the reason, which names a fault's kind
%% and never the program's bytes, goes to the log, and the shell's
%% abnormal end ends the UI.
down(Reason, #{program := Running}) ->
    logger:warning("erx_ui_lvgl: erx-lvgl stopped: ~p", [Reason]),
    close(Running),
    {stop, {shutdown, {renderer_down, Reason}}}.

%% The program --------------------------------------------------------------

%% Starts the program: `{ok, Running, Offset}`, the running program and
%% its buffer's offset, or the
%% start's refusal. A refusal stops this process, and with it go what the
%% start made: the pipe ends it holds, the reader linked to it, and the
%% program, which its handler stops when its starter ends.
-spec run(program()) -> {ok, running(), non_neg_integer()} | {error, term()}.
run({port, Open}) ->
    {ok, {port, Open()}, 0};
run({handler, Spec, Peer, Bytes}) ->
    maybe
        {ok, InRead, InWrite} ?= erx_pipe_srv:pipe(),
        {ok, OutRead, OutWrite} ?= erx_pipe_srv:pipe(),
        Fds = [{0, {pipe, InRead}}, {1, {pipe, OutWrite}}, {3, {buffer, Peer, Bytes}}],
        {ok, Handler, [{3, Offset}]} ?= erx_prog_handler:start(Spec#{fds => Fds}),
        Watch = monitor(process, Handler),
        ok = erx_pipe_srv:close(InRead),
        ok = erx_pipe_srv:close(OutWrite),
        Reader = spawn_link(fun reader/0),
        {ok, ReaderEnd} ?= erx_pipe_srv:inherit(OutRead, Reader),
        Reader ! {read, self(), ReaderEnd},
        ok = erx_pipe_srv:close(OutRead),
        {ok, {piped, #{handler => Handler, watch => Watch, input => InWrite, reader => Reader}}, Offset}
    end.

%% The reader: takes its end of the program's output, then sends each read
%% to the shell until the output ends; a lost pipe ends it abnormally.
reader() ->
    receive {read, Shell, End} -> relay(Shell, End) end.

relay(Shell, End) ->
    case erx_pipe_srv:read(End, ?READ_BYTES, infinity) of
        Bytes when is_binary(Bytes) ->
            Shell ! {self(), {data, Bytes}},
            relay(Shell, End);
        eof ->
            ok;
        {error, Reason} ->
            exit({read, Reason})
    end.

%% Writes to the program's input: `ok`, or the core's event for a write
%% that failed. On the host a write to a program that is gone is dropped,
%% and the port's exit follows; on erXos it is `{lost, epipe}`, also for
%% a program that closed its input and runs on, and one that finds no
%% room within ?WRITE_MS is `stalled`.
-spec write(running(), iodata()) -> ok | {failed, erx_ui_lvgl_core:event()}.
write({port, Port}, Bytes) ->
    try port_command(Port, Bytes) catch error:badarg -> true end,
    ok;
write({piped, #{input := InWrite}}, Bytes) ->
    case erx_pipe_srv:write(InWrite, Bytes, ?WRITE_MS) of
        ok -> ok;
        {error, epipe} -> {failed, {lost, epipe}};
        {error, timeout} -> {failed, stalled}
    end.

%% Stops the program, which may have ended already. On erXos the handler
%% stops it and the reader goes with it; the input's write end closes
%% with this process.
-spec close(running()) -> true.
close({port, Port}) ->
    try port_close(Port) catch error:badarg -> true end;
close({piped, #{handler := Handler, reader := Reader}}) ->
    ok = erx_prog_handler:stop(Handler),
    unlink(Reader),
    exit(Reader, kill).
