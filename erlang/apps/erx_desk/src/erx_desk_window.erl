%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_window).
-moduledoc """
A desktop program's window (docs/design-desktop-programs.md, "The
construction"): one process per open window, running the program's core.
It holds no decision: it feeds the core its inputs, performs the effects
the core returns and hands the toolkit the core's tree after every step.

The core is a module with init/1, step/2 and view/1. Its inputs are the
toolkit's `{ui, Window, Term, Detail}`, a worker's answer, and a tick,
`{tick, Now}` with Now the wall clock read when the timer fires. Its
effects form a closed set, each performed here and nowhere else:

* `{inspect, Tag, Path}`: a worker asks the inspector, through the
  function the window was started with (erx:inspect/2 under erx_desk_sup),
  with a timeout of one second, and answers `{inspected, Tag, Result}`;
* `{list, Tag, Dir}`: a worker under a heap cap of 4 MiB lists the folder
  and answers `{listed, Tag, Result}`, each name a binary;
* `{stat, Tag, Dir, Names}`: a worker reads each name's link information
  and answers `{stated, Tag, Results}`;
* `{read, Tag, Path, Bytes}`: a worker reads at most Bytes of the file and
  answers `{read, Tag, Result}`;
* `{tick_after, Ms}`: the timer is set Ms milliseconds on, the one before
  it cancelled; a tick of an earlier timer is dropped;
* `{snarf, Bytes}`: a worker writes `/clipboard` and answers `{snarfed,
  Result}`;
* `{cancel, Tag}`: the worker of Tag is unlinked and killed, so it sends
  nothing;
* `close`: the UI is closed and the process ends.

**Workers and the window's lifetime.** The window traps exits and links
every worker. A worker that answers ends `normal`, and the window ignores
the `'EXIT'` of a pid it no longer counts as in flight; one that ends
otherwise, killed by its heap cap or crashed, becomes `{failed, Tag,
Reason}` (`{snarfed, {error, Reason}}` for a snarf). The window ends with
`shutdown` on a close, on the UI's end and on its supervisor's exit, and
with the reason on a crash or on a tree the toolkit refuses; neither is
`normal`, so every worker still linked, none of which traps exits, ends
with it.

**Reload.** `{erx_desk, reload, Core}`, which erx_desk:reload/1 sends,
makes a window of that core hand the tree the core's newest view/1 makes
of the state the window holds: the window calls its core by module name,
which reaches the newest version loaded.
""".

-export([start_link/2]).
-export([init/3]).

%% How long an inspector query may take, in milliseconds.
-define(INSPECT_TIMEOUT, 1000).
%% The listing worker's heap cap: 524,288 words, 4 MiB on a 64-bit runtime.
-define(LISTING_HEAP, #{size => 524288, kill => true, error_logger => false,
                        include_shared_binaries => true}).
-define(CLIPBOARD, <<"/clipboard">>).

-type inspect() :: fun((Path :: list(), #{timeout := pos_integer()}) -> term()).
-type program() :: #{core := module(), args := term(), label := binary()}.
-export_type([inspect/0, program/0]).

%% parent: the supervisor. ui: the toolkit's window. timer: the timer last
%% started. workers: each worker in flight and the request it answers, a
%% tag or `snarf`.
-record(window, {parent :: pid(),
                 core :: module(),
                 state :: term(),
                 ui :: erx_ui:window(),
                 inspect :: inspect(),
                 timer = none :: none | reference(),
                 workers = #{} :: #{pid() => term()}}).

-doc """
Starts the window of Program, its core started with its args, the UI
opened with its label, and answers once erx_ui:open/1 has: `{ok, Pid}`, or
`{error, Reason}` for a UI that did not open, such as `no_display`.
""".
-spec start_link(inspect(), program()) -> {ok, pid()} | {error, term()}.
start_link(Inspect, #{core := _, args := _, label := _} = Program) ->
    proc_lib:start_link(?MODULE, init, [self(), Inspect, Program]).

-doc false.
init(Parent, Inspect, #{core := Core, args := Args, label := Label}) ->
    process_flag(trap_exit, true),
    {State, Effects} = Core:init(Args),
    case erx_ui:open(#{label => Label}) of
        {ok, Ui} ->
            proc_lib:init_ack({ok, self()}),
            Window = #window{parent = Parent, core = Core, state = State, ui = Ui, inspect = Inspect},
            loop(present(perform(Effects, Window)));
        {error, _Reason} = Refused ->
            proc_lib:init_fail(Refused, {exit, normal})
    end.

loop(#window{parent = Parent, core = Core, ui = Ui, timer = Timer, workers = Workers} = W) ->
    receive
        {ui, Ui, _Term, _Detail} = Input ->
            loop(stepped(Input, W));
        {timeout, Timer, tick} ->
            loop(stepped({tick, os:system_time(millisecond)}, W#window{timer = none}));
        {erx_desk_answer, Pid, Input} when is_map_key(Pid, Workers) ->
            loop(stepped(Input, W#window{workers = maps:remove(Pid, Workers)}));
        {'EXIT', Pid, Reason} when is_map_key(Pid, Workers) ->
            {Request, Rest} = maps:take(Pid, Workers),
            loop(stepped(failed(Request, Reason), W#window{workers = Rest}));
        {ui_down, Ui, _Reason} -> exit(shutdown);
        {'DOWN', Ui, process, _Server, _Reason} -> exit(shutdown);
        {'EXIT', Parent, _Reason} -> exit(shutdown);
        {erx_desk, reload, Core} -> loop(present(W));
        _Stale ->
            %% A tick of an earlier timer, an answer or exit of a worker no
            %% longer in flight, or a reload of another program.
            loop(W)
    end.

failed(snarf, Reason) -> {snarfed, {error, Reason}};
failed(Tag, Reason) -> {failed, Tag, Reason}.

stepped(Input, #window{core = Core, state = State} = W) ->
    {Next, Effects} = Core:step(Input, State),
    present(perform(Effects, W#window{state = Next})).

%% Hands the toolkit the core's tree; a tree it refuses is a bug of the
%% core, and ends the window with the toolkit's reason.
present(#window{core = Core, state = State, ui = Ui} = W) ->
    case erx_ui:tree(Ui, Core:view(State)) of
        ok -> W;
        {error, Reason} -> exit(Reason)
    end.

%%% Effects.

perform(Effects, W) ->
    lists:foldl(fun effect/2, W, Effects).

effect({inspect, Tag, Path}, #window{inspect = Inspect} = W) ->
    worker(Tag, fun() -> {inspected, Tag, Inspect(Path, #{timeout => ?INSPECT_TIMEOUT})} end, [], W);
effect({list, Tag, Dir}, W) ->
    worker(Tag, fun() -> {listed, Tag, listing(file:list_dir_all(Dir))} end,
           [{max_heap_size, ?LISTING_HEAP}], W);
effect({stat, Tag, Dir, Names}, W) ->
    worker(Tag, fun() ->
                        {stated, Tag, [file:read_link_info(filename:join(Dir, Name), [{time, posix}])
                                       || Name <- Names]}
                end, [], W);
effect({read, Tag, Path, Bytes}, W) ->
    worker(Tag, fun() -> {read, Tag, read(Path, Bytes)} end, [], W);
effect({snarf, Bytes}, W) ->
    worker(snarf, fun() -> {snarfed, file:write_file(?CLIPBOARD, Bytes)} end, [], W);
effect({tick_after, Ms}, #window{timer = Timer} = W) ->
    cancel_timer(Timer),
    W#window{timer = erlang:start_timer(Ms, self(), tick)};
effect({cancel, Tag}, #window{workers = Workers} = W) ->
    Cancelled = [Pid || Pid := Request <- Workers, Request =:= Tag],
    [begin unlink(Pid), exit(Pid, kill) end || Pid <- Cancelled],
    W#window{workers = maps:without(Cancelled, Workers)};
effect(close, #window{ui = Ui}) ->
    ok = erx_ui:close(Ui),
    exit(shutdown).

%% A linked worker that sends the window Answer's result and ends.
worker(Request, Answer, Options, #window{workers = Workers} = W) ->
    Window = self(),
    Pid = spawn_opt(fun() -> Window ! {erx_desk_answer, self(), Answer()} end, [link | Options]),
    W#window{workers = Workers#{Pid => Request}}.

cancel_timer(none) -> ok;
cancel_timer(Timer) -> erlang:cancel_timer(Timer, [{async, false}, {info, false}]).

%% A listing's names as binaries: list_dir_all/1 gives a name that decodes
%% as characters, a binary otherwise.
listing({ok, Names}) ->
    {ok, [if
              is_binary(Name) -> Name;
              true -> unicode:characters_to_binary(Name, unicode, file:native_name_encoding())
          end || Name <- Names]};
listing({error, _Reason} = Failed) ->
    Failed.

read(Path, Bytes) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, File} ->
            try file:read(File, Bytes)
            after file:close(File)
            end;
        {error, _Reason} = Failed ->
            Failed
    end.
