%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_host).
-behaviour(gen_server).
-moduledoc """
The SDK's stand-in for a display on the development host
(docs/design-packaging.md, "The SDK"), so that an app's host tests check
its frames under stock OTP 29.1.2 without a board or an emulator. While it
runs, registered as `erx_ui_host`, erx_ui:open/1 in the node opens its
window here, as on the default display; the widget server, the schema, the
diff and the renderer are the session's own, and only the window is a
stand-in.

The window is a buffer of `width` by `height` pixels, `x8r8g8b8`, in a
file of its own under the temporary directory. Each present the renderer
makes records the buffer as the frame, which frame/1 answers, and is then
answered as shown, as the display answers it. input/2 hands the renderer
one input record, as the window's input reaches it. One window is open at
a time: a second opens only once the first has closed.

The renderers:

* `lvgl`: the host build of erx-lvgl, whose path the environment variable
  `ERX_LVGL` names, run by erx_ui_lvgl. The program takes the window's
  buffer as descriptor 3, which a port cannot hand it, so Ruby starts it
  with the buffer there, as test/fixtures/erx_lvgl_buffer.rb does. A tree
  with a `present` property ends the UI: the host has no canonical text
  for a presentation yet (TODO.md).
* `erlang`: the Erlang renderer, not built yet; start/1 answers
  `{error, enotsup}`.

stop/1 deletes the buffer and kills the renderer of an open window, which
its widget server takes as `renderer_down`.
""".

-export([start/1, frame/1, input/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Plan 9's channel descriptor of x8r8g8b8 (draw(2)).
-define(X8R8G8B8, 16#68081828).
%% Ruby's part of a start of erx-lvgl: ARGV is the buffer and the program.
-define(WITH_BUFFER, "exec([ARGV[1], ARGV[1]], 3 => File.open(ARGV[0], File::RDWR))").

-type frame() :: {ok, 1..65535, 1..65535, binary()} | none.
-type event() :: {pointer, integer(), integer(), integer()}
               | {key, boolean(), integer(), integer()}
               | {wheel, integer()}.
-export_type([frame/0, event/0]).

-record(host, {width :: 1..65535,
               height :: 1..65535,
               buffer :: file:filename(),
               launch :: {Ruby :: file:filename(), Program :: file:filename()},
               shell :: pid() | none,
               frame :: frame()}).

-doc """
Starts the stand-in display, `width` by `height` pixels, drawn by
`renderer`, `erlang` by default, with the widget toolkit erx_ui started.
`{error, no_lvgl}` when `ERX_LVGL` names no program and `{error, no_ruby}`
when no `ruby` is on the path.
""".
-spec start(#{width := 1..65535, height := 1..65535, renderer => erlang | lvgl}) ->
          {ok, pid()} | {error, term()}.
start(#{width := W, height := H} = Options)
  when is_integer(W), W >= 1, W =< 65535, is_integer(H), H >= 1, H =< 65535 ->
    case {maps:get(renderer, Options, erlang), os:getenv("ERX_LVGL"), os:find_executable("ruby")} of
        {erlang, _, _} -> {error, enotsup};
        {lvgl, false, _} -> {error, no_lvgl};
        {lvgl, _, false} -> {error, no_ruby};
        {lvgl, Program, Ruby} ->
            {ok, _Apps} = application:ensure_all_started(erx_ui),
            gen_server:start({local, ?MODULE}, ?MODULE, {W, H, {Ruby, Program}}, []);
        {_Other, _, _} -> {error, badarg}
    end;
start(_Options) ->
    {error, badarg}.

-doc "The last frame presented, `x8r8g8b8` rows from the top, or `none`.".
-spec frame(pid()) -> frame().
frame(Host) ->
    gen_server:call(Host, frame).

-doc "Hands the open window's renderer one input record.".
-spec input(pid(), event()) -> ok | {error, no_window | badarg}.
input(Host, Event) ->
    gen_server:call(Host, {input, Event}).

-doc "Stops the stand-in display.".
-spec stop(pid()) -> ok.
stop(Host) ->
    gen_server:stop(Host).

init({W, H, Launch}) ->
    process_flag(trap_exit, true),
    Buffer = filename:join(temporary_directory(),
                           "erx_ui_host." ++ os:getpid() ++ "." ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, File} = file:open(Buffer, [write, exclusive, raw, binary]),
    ok = file:change_mode(Buffer, 8#600),
    ok = file:write(File, binary:copy(<<0>>, 4 * W * H)),
    ok = file:close(File),
    {ok, #host{width = W, height = H, buffer = Buffer, launch = Launch, shell = none, frame = none}}.

%% erx_ui:open/1's request for a window here, drawn by the renderer its
%% options name, or by LVGL, the one start/1 accepts: the renderer's
%% module and its options, or `ebusy` while a window is open.
handle_call({window, erlang}, _From, S) ->
    {reply, {error, enotsup}, S};
handle_call({window, lvgl}, _From, #host{shell = Shell} = S) when is_pid(Shell) ->
    {reply, {error, ebusy}, S};
handle_call({window, lvgl}, _From, S) ->
    {reply, {ok, erx_ui_lvgl, lvgl_opts(S)}, S};
%% The renderer's first act, from its own process: it holds the window
%% unless another does.
handle_call({opened, Shell}, _From, #host{shell = none} = S) ->
    monitor(process, Shell),
    {reply, ok, S#host{shell = Shell}};
handle_call({opened, _Shell}, _From, S) ->
    {reply, {error, ebusy}, S};
handle_call(frame, _From, #host{frame = Frame} = S) ->
    {reply, Frame, S};
handle_call({input, _Event}, _From, #host{shell = none} = S) ->
    {reply, {error, no_window}, S};
handle_call({input, Event}, _From, #host{shell = Shell} = S) ->
    case is_event(Event) of
        true -> {reply, erx_ui_lvgl:window(Shell, {input, Event}), S};
        false -> {reply, {error, badarg}, S}
    end.

handle_cast(_Request, S) ->
    {noreply, S}.

%% A present of the window's renderer: the buffer, drawn at W by H, is the
%% frame; the renderer draws nothing more until it is shown.
handle_info({presented, Shell, W, H}, #host{shell = Shell, buffer = Buffer} = S) ->
    Frame = read_frame(W, H, Buffer),
    ok = erx_ui_lvgl:shown(Shell),
    {noreply, S#host{frame = Frame}};
handle_info({'DOWN', _Monitor, process, Shell, _Why}, #host{shell = Shell} = S) ->
    {noreply, S#host{shell = none}};
handle_info(_Message, S) ->
    {noreply, S}.

terminate(_Reason, #host{buffer = Buffer, shell = Shell}) ->
    is_pid(Shell) andalso exit(Shell, kill),
    _ = file:delete(Buffer),
    ok.

%% erx_ui_lvgl's options for a window here. Its funs run in the renderer's
%% process: open/0 claims the window first, so a second open fails there.
lvgl_opts(#host{width = W, height = H, buffer = Buffer, launch = {Ruby, Program}}) ->
    Host = self(),
    Open = fun() ->
                   ok = gen_server:call(Host, {opened, self()}),
                   open_port({spawn_executable, Ruby},
                             [binary, stream, use_stdio, exit_status,
                              {args, ["-e", ?WITH_BUFFER, Buffer, Program]}])
           end,
    Present = fun(0, PresentW, PresentH, _Rects) -> Host ! {presented, self(), PresentW, PresentH}, ok end,
    #{width => W, height => H, chan => ?X8R8G8B8, program => {port, Open}, present => Present,
      present_text => fun(_Type, _Value) -> error(enotsup) end}.

%% A copy of the buffer's first W by H pixels at a stride of W pixels,
%% read `raw`, past the node's file server, so a frame never waits behind
%% the app's own file requests.
read_frame(W, H, Buffer) ->
    {ok, Bytes} = file:read_file(Buffer, [raw]),
    {ok, W, H, binary:part(Bytes, 0, 4 * W * H)}.

is_event({pointer, X, Y, Buttons}) -> is_integer(X) andalso is_integer(Y) andalso is_integer(Buttons);
is_event({key, Down, Code, Rune}) -> is_boolean(Down) andalso is_integer(Code) andalso is_integer(Rune);
is_event({wheel, Steps}) -> is_integer(Steps);
is_event(_Other) -> false.

temporary_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> Directory
    end.
