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
It writes each record with erx_ui_wire:encode/2, which writes every text
through the line escape, so the program shows no text raw (G5).

**On a window.** start/3 over `{window, Window}`, an erx_win window the
widget server opened with no buffer of its own (docs/design-display.md,
"Erlang clients"), with no options, binds the renderer to it: the
window's size and channel come from erx_win:info/1, the program's buffer
is lent at that size from the display's pixel area, each present is
erx_win:present/3 of that buffer, and a present's text is
erx_present:text/2.

This process performs each present itself, waiting for the display's
answer, and then casts itself `shown`, so the events already queued
are taken first. It is never the process waiting in apply/2, which is
the widget server, so an apply that comes while a report is open is
answered once the present is; a refused present stops the program and
ends the UI. No present is made after this process has taken the
handler's `'DOWN'`; one whose report it took before may still name a
range just returned (TODO.md, `erx_ui_lvgl`).

Two readers serve the window's input, each a process linked to this
one, whose end ends them (ended/1) and whose failure stops the program
and so ends the UI as `renderer_down`. Each reads one record of its
file, `mouse` or `kbd`, only once await_reading/1 says this process
takes the window's input, erx_ui_lvgl_core:reads_window/1, so a record
waits in the window's bounded queue, not here, while a report is open.
A reader passes a record on through erx_ui_lvgl_core:input/2 with
window/2; the mouse reader takes an `r` record as a resize, reading the
window's new rectangle with erx_win:resized/1 and passing its size with
resize/3.

The program is `bin/erx-lvgl`, started as a program of the session,
whose command server gives it its pid.

**Over options.** start/3 over any other target takes the window's
size, channel and presents as options, the entry of the tests and the
harnesses. The options:

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

The shell takes the window's input, window/2, only while
erx_ui_lvgl_core:reads_window/1 holds: in any other state it stays
queued, postponed, until the open report is answered, so the core holds
at most one apply's operations. A resize, resize/3, it takes at once in
any state, and the core writes its `screen` record at once (docs/design-display.md,
"The widget server"). stop/1 stops the program and ends
the shell without consulting the core, so the program's end then is no
fault. A fault ends the shell, and with it an apply/2 that waits. An
apply that comes while a report is open returns once the report is
answered, so the process that answers the window's presents, this one
on a window and the harness over options, must not be the one waiting
in apply/2.

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

-export([start/3, apply/2, stop/1, window/2, resize/3, shown/1, await_reading/1]).
-export([init/1, callback_mode/0, handle_event/4, format_status/1]).

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

%% The options: a window to present through and read, bound by start/3,
%% or the harness's `present` function.
-type opts() :: #{width := 1..65535, height := 1..65535, chan := 0..16#ffffffff,
                  program := program(),
                  window => erx_win:window(),
                  present => fun((non_neg_integer(), 1..65535, 1..65535, [erx_win_core:rect(), ...]) -> ok),
                  present_text := erx_ui_wire:present()}.

-doc """
Starts the renderer of a window and its program, linked to the widget
server, the caller: bound to an erx_win window given no options, or
over the options.
""".
-spec start(erx_ui_renderer:target(), pid(), opts() | #{}) -> {ok, pid()}.
start(_Target, Server, #{program := _} = Opts) ->
    shell(Server, Opts);
start({window, Window}, Server, Options) when map_size(Options) =:= 0 ->
    #{peer := Peer, rect := {X0, Y0, X1, Y1}, chan := #{code := Code, depth := Depth}} = erx_win:info(Window),
    %% The buffer is lent at the size the core's extent is: one width and
    %% height for both, so no screen record passes the buffer.
    {Width, Height} = {X1 - X0, Y1 - Y0},
    {ok, Bytes} = erx_win_core:bytes(Width, Height, Depth),
    shell(Server, #{width => Width, height => Height, chan => Code,
                    program => {handler, program_spec(), Peer, Bytes},
                    window => Window, present_text => fun erx_present:text/2}).

shell(Server, Opts) ->
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

-doc "The window's new size, which the core clips to the buffer's.".
-spec resize(pid(), integer(), integer()) -> ok.
resize(Shell, Width, Height) ->
    gen_statem:cast(Shell, {resize, Width, Height}).

-doc "The display's answer to the last present: the buffer's rectangles are shown.".
-spec shown(pid()) -> ok.
shown(Shell) ->
    gen_statem:cast(Shell, shown).

-doc "Returns once the renderer takes the window's input: at once, or when the open report is answered.".
-spec await_reading(pid()) -> ok.
await_reading(Shell) ->
    gen_statem:call(Shell, await_reading, infinity).

-doc "Stops the program and ends the renderer; the program's end is then no fault.".
-spec stop(pid()) -> ok.
stop(Shell) ->
    gen_statem:call(Shell, close, infinity).

%% The state is erx_ui_lvgl_core:reads_window/1 of the core: `reading` or
%% `holding`, so the window's records are postponed exactly while the core
%% would hold them. The data holds the core, the running program, its
%% buffer's offset and the bytes of its output not yet a whole record.
callback_mode() -> handle_event_function.

%% A crash report keeps only the state, `reading` or `holding`: the queue
%% holds an apply's operations, the postponed events the window's keys, the
%% data the tree and the program's unread output, and the reason or the log
%% can name a record. A crash's stack trace does not pass through here, so a
%% clause that fails with application terms as arguments still logs them (a
%% residual, TODO.md).
format_status(Status) ->
    maps:map(fun(state, State) -> State;
                (Key, _Value) when Key =:= queue; Key =:= postponed; Key =:= log -> [];
                (_Key, _Value) -> hidden
             end, Status).

init(#{width := W, height := H, chan := Chan, program := Program} = Opts) ->
    %% The death of the port or the reader (a write that found the program
    %% gone fails the port with epipe; a lost pipe fails the reader's read)
    %% reaches the core as `lost`.
    process_flag(trap_exit, true),
    case run(Program) of
        {ok, Running, Offset} ->
            {Core, Actions} = erx_ui_lvgl_core:start(W, H, Chan),
            Presents = presents(Opts),
            Data = maps:merge(maps:with([present_text, ui, chan], Opts),
                              #{core => Core, program => Running, offset => Offset, unread => <<>>,
                                presents => Presents, readers => readers(Presents)}),
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
handle_event(cast, {resize, W, H}, _State, #{chan := Chan} = Data) ->
    step({resize, W, H, Chan}, Data);
handle_event(cast, shown, _State, Data) ->
    step(shown, Data);
handle_event({call, _From}, await_reading, holding, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event({call, From}, await_reading, reading, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event(info, {Port, {data, Bytes}}, _State, #{program := {port, Port}} = Data) ->
    output(more(Bytes, Data));
handle_event(info, {Reader, {data, Bytes}}, _State, #{program := {piped, #{reader := Reader}}} = Data) ->
    output(more(Bytes, Data));
handle_event(info, {Port, {exit_status, Status}}, _State, #{program := {port, Port}} = Data) ->
    step({exit, Status}, Data);
handle_event(info, {'DOWN', Watch, process, _Handler, {shutdown, {program_exit, Status}}}, _State,
             #{program := {piped, #{watch := Watch}}} = Data) ->
    step({exit, Status}, Data);
handle_event(info, {'DOWN', Watch, process, _Handler, _Reason}, _State,
             #{program := {piped, #{watch := Watch}}} = Data) ->
    %% The handler's own end, with no status read: a crash, or a port
    %% closed with none. Its reason may hold the program's spec and
    %% frames, so the log names only the handler.
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
handle_event(info, {'EXIT', Pid, Reason}, _State, #{readers := Readers} = Data) when is_map_key(Pid, Readers) ->
    %% A window read that failed; the reason names the file and an errno.
    step({lost, Reason}, Data);
handle_event({call, From}, close, _State, Data) ->
    ended(Data),
    {stop_and_reply, normal, [{reply, From, ok}]};
handle_event(info, _Message, _State, _Data) ->
    %% A message of no known shape, such as a stray reply to a window
    %% request, is dropped, so nothing another process sends crashes the
    %% shell and logs its data.
    keep_state_and_data.

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
%% leaves, or, at a stop, the program stopped and the UI ended.
step(Event, #{core := Core} = Data) ->
    {Core1, Actions} = erx_ui_lvgl_core:step(Event, Core),
    performed(Actions, Data#{core := Core1}).

%% The actions performed in order; at a write that failed, the rest
%% dropped and the core told of the failure; at a stop, the program
%% stopped and the UI ended.
performed(Actions, Data) ->
    case perform(Actions, Data) of
        ok -> {next_state, state_of(Data), Data};
        {failed, Event} -> step(Event, Data);
        {stop, Reason} -> down(Reason, Data)
    end.

state_of(#{core := Core}) ->
    case erx_ui_lvgl_core:reads_window(Core) of
        true -> reading;
        false -> holding
    end.

perform([], _Data) ->
    ok;
perform([{stop, Reason}], _Data) ->
    {stop, Reason};
perform([Action | Rest], Data) ->
    case perform_one(Action, Data) of
        ok -> perform(Rest, Data);
        {failed, _Event} = Failed -> Failed
    end.

perform_one({write, Records}, #{program := Running, present_text := Text}) ->
    write(Running, [erx_ui_wire:encode(Record, Text) || Record <- Records]);
perform_one({present, W, H, Rects}, #{presents := {function, Present}, offset := Offset}) ->
    ok = Present(Offset, W, H, Rects);
perform_one({present, W, H, Rects}, #{presents := {window, Window}, offset := Offset}) ->
    case erx_win:present(Window, #{offset => Offset, width => W, height => H}, Rects) of
        ok -> shown(self());
        {error, Reason} -> {failed, {lost, {present, Reason}}}
    end;
perform_one({reply, From}, _Data) ->
    gen_statem:reply(From, ok);
perform_one({hit, Node, Event, Value}, #{ui := Ui}) ->
    Ui ! {ui_hit, Node, Event, Value},
    ok.

%% The core stopped the program: the reason, which names a fault's kind
%% and never the program's bytes, goes to the log, and the shell's
%% abnormal end ends the UI.
down(Reason, Data) ->
    logger:warning("erx_ui_lvgl: erx-lvgl stopped: ~p", [Reason]),
    ended(Data),
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
        {ok, Handler, Watch, [{3, Offset}]} ?= erx_prog_handler:start(Spec#{fds => Fds}),
        ok = erx_pipe_srv:close(InRead),
        ok = erx_pipe_srv:close(OutWrite),
        Reader = spawn_link(fun reader/0),
        {ok, ReaderEnd} ?= erx_pipe_srv:inherit(OutRead, Reader),
        Reader ! {read, self(), ReaderEnd},
        ok = erx_pipe_srv:close(OutRead),
        {ok, {piped, #{handler => Handler, watch => Watch, input => InWrite, reader => Reader}}, Offset}
    end.

%% The window ------------------------------------------------------------------

%% The spec of the program's start, but for its descriptors.
program_spec() ->
    #{image => <<"bin/erx-lvgl">>, argv => [<<"erx-lvgl">>],
      env => [], cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [], umask => 8#022}.

%% Ends the window's readers and stops the program, at each end of this
%% process but a crash, after which the readers end by their links and
%% the handler stops the program when its starter ends.
ended(#{readers := Readers, program := Running}) ->
    lists:foreach(fun(Reader) -> unlink(Reader), exit(Reader, kill) end, maps:keys(Readers)),
    close(Running).

%% How presents are made: through the window, or by the harness's function.
presents(#{window := Window}) -> {window, Window};
presents(#{present := Present}) when is_function(Present, 4) -> {function, Present}.

%% The window's readers, linked to this process, or none without a window.
readers({function, _Present}) ->
    #{};
readers({window, Window}) ->
    Shell = self(),
    maps:from_keys([spawn_link(fun() -> mouse_reader(Window, Shell) end),
                    spawn_link(fun() -> kbd_reader(Window, Shell) end)], reader).

%% The mouse reader: one record at a time while the shell takes input; an
%% `r` record is a resize to the window's new rectangle, whose origin the
%% next pointers are relative to.
mouse_reader(Window, Shell) ->
    ok = await_reading(Shell),
    case erx_win:mouse(Window) of
        {ok, {resized, _X, _Y, _Buttons, _Msec}} ->
            case erx_win:resized(Window) of
                {ok, Resized, none} ->
                    #{rect := {X0, Y0, X1, Y1}} = erx_win:info(Resized),
                    resize(Shell, X1 - X0, Y1 - Y0),
                    mouse_reader(Resized, Shell);
                {error, Reason} ->
                    exit({resized, Reason})
            end;
        {ok, Pointer} ->
            forward_input(Shell, Pointer, Window),
            mouse_reader(Window, Shell);
        {error, Reason} ->
            exit({mouse, Reason})
    end.

kbd_reader(Window, Shell) ->
    ok = await_reading(Shell),
    case erx_win:kbd(Window) of
        {ok, Key} -> forward_input(Shell, Key, Window), kbd_reader(Window, Shell);
        {error, Reason} -> exit({kbd, Reason})
    end.

%% A window record as the program's input records, handed to the shell.
forward_input(Shell, Record, Window) ->
    #{rect := {X0, Y0, _X1, _Y1}} = erx_win:info(Window),
    lists:foreach(fun(Input) -> window(Shell, Input) end, erx_ui_lvgl_core:input(Record, {X0, Y0})).

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
