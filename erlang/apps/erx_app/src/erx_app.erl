%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app).
-moduledoc """
An app's session (docs/design-packaging.md, "Starting an app"): the application
that the app template's `-eval` starts, which asks for the app's record (erx:app/0),
answered once the session's namespace is in place, then mounts the package's image
at `/app` and starts what the package declares.

For an Erlang app it puts each `/app/lib/*/ebin` at the end of the code path,
after the release's, so a module the app ships under a name the release already
uses is never the one the code server finds, and starts each declared
application, permanent, so a declared application's end ends the session and
the start row's keeper starts it again.

For a native app it starts the package's program, `/app/` and the record's path,
which the package reader admits only as plain names, so it names a file of the
image and nothing outside it, with erx_prog_handler:start/1. This process is the
program's starter: the program's namespace is the session's, and when the
record's `window` holds, the spec's `window` names the session's default
display, the environment's `display`, so the handler opens the program's window
and binds its `/dev/draw`, `/dev/kbd`, `/dev/mouse` and `/dev/wctl`. The
handler's monitor is the one report of the program's end, which ends this
process: with `{program_exit, Status}` when the program ended, and with the
handler's own reason otherwise. The starter's end stops the program, so the
program never outlives the session.

erx_app's process acknowledges its start first and only then mounts and starts
the app, so an app that names erx_app, or depends on it, finds it started
rather than waiting on its own start. The process holds nothing; erx_app is
permanent, so its end, with the first step's failure or the program's end as
its reason, ends the session.
""".
-behaviour(application).

-export([start/2, stop/1]).
-export([run/2, init/1]).
-export_type([effects/0]).

-include("generated/erx_abi.hrl").

-doc """
The effects run/2 performs: the mount of `/app`, where the mounted image lies,
the start type of the declared applications, the session's default display,
`none` when it has none, and the program's start. The application passes its
own (effects/0): permanent, so a declared application's end ends the session,
and erx_prog_handler:start/1; a host test passes a mount over a fixture
directory, `temporary`, so a failed start ends only the case, and a start that
reports what it was asked.
""".
-type effects() :: #{mount := fun(() -> ok | {error, term()}),
                     root := string(),
                     type := permanent | temporary,
                     display := atom() | none,
                     start_program := fun((map()) -> {ok, pid(), reference(), list()}
                                                         | {error, atom()})}.

start(_Type, _Args) ->
    proc_lib:start_link(?MODULE, init, [self()]).

stop(_State) ->
    ok.

-doc false.
init(Parent) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    {ok, Record} = erx:app(),
    case run(Record, effects()) of
        ok -> receive after infinity -> ok end;
        {error, Reason} -> exit(Reason)
    end.

-doc """
Mounts the package of `Record` at `/app` and starts what it declares, through
`Effects`. The first step that fails is the answer. An Erlang app's answer is
`ok` once its applications have started; a native app's comes once its
program has ended, as `{error, {program_exit, Status}}`, or once its handler
has ended for another reason, as `{error, Reason}`.
""".
-spec run(erx:app_record(), effects()) -> ok | {error, term()}.
run(Record, Effects) ->
    try
        start_app(Record, Effects)
    catch
        throw:{erx_app, Reason} -> {error, Reason}
    end.

%% The session's own effects: the package's image mounted read and execute at /app,
%% and the app's paths under it. The mount names the session's own package, `app`:
%% erx_ns's process takes the file's place and layout from the record the session's
%% agent keeps, so nothing this process passes chooses what /app holds.
effects() ->
    #{mount => fun() -> erx_ns:mount({erofs, app}, <<"/app">>, [rx]) end,
      root => "/app",
      type => permanent,
      display => default_display(os:getenv(binary_to_list(?ERX_DISPLAY_KEY_BYTES))),
      start_program => fun erx_prog_handler:start/1}.

%% The session's default display, which its planning names in its environment,
%% as the atom the domain's grant of it already made; none when the environment
%% names no display, as for a session planned without one, or names one no atom
%% stands for.
default_display(false) ->
    none;
default_display(Name) ->
    try list_to_existing_atom(Name)
    catch error:badarg -> none
    end.

start_app(#{start := {applications, Names}}, #{root := Root, type := Type} = Effects) ->
    mount(Effects),
    lists:foreach(fun add_path/1, ebins(Root)),
    lists:foreach(fun(Name) -> start_application(binary_to_atom(Name), Type) end, Names);
start_app(#{start := {program, Program, Args}, window := Window},
          #{root := Root, start_program := Start} = Effects) ->
    mount(Effects),
    Image = iolist_to_binary([Root, $/, Program]),
    Spec = #{image => Image, argv => [Image | Args], env => [], cwd => <<"/">>,
             spawn => false, sigmask => [], sigignore => [], umask => 8#022},
    Windowed = window(Window, Spec, Effects),
    case Start(Windowed) of
        {ok, _Handler, Monitor, _Offsets} -> ended(Monitor);
        {error, Errno} -> fail({program, Errno})
    end.

mount(#{mount := Mount}) ->
    case Mount() of
        ok -> logger:notice("erx_app: mounted /app");
        {error, Reason} -> fail({mount, Reason})
    end.

%% A program with a window has it on the session's default display.
window(false, Spec, _Effects) -> Spec;
window(true, _Spec, #{display := none}) -> fail({window, no_display});
window(true, Spec, #{display := Display}) -> Spec#{window => Display}.

%% The program's end, which the handler's monitor alone reports. It never returns:
%% a native app's end, an exit with status 0 too, is always its session's end.
ended(Monitor) ->
    receive
        {'DOWN', Monitor, process, _Handler, {shutdown, {program_exit, Status}}} ->
            fail({program_exit, Status});
        {'DOWN', Monitor, process, _Handler, Reason} ->
            fail(Reason)
    end.

%% Each lib/*/ebin under Root, sorted, so the code path the app adds does not
%% depend on the order the directory lists.
ebins(Root) ->
    lists:sort(filelib:wildcard(filename:join([Root, "lib", "*", "ebin"]))).

add_path(Ebin) ->
    case code:add_pathz(Ebin) of
        true -> ok;
        {error, Reason} -> fail({path, Ebin, Reason})
    end.

start_application(App, Type) ->
    case application:ensure_all_started(App, Type) of
        {ok, _Started} -> ok;
        {error, Reason} -> fail({start, App, Reason})
    end.

fail(Reason) ->
    throw({erx_app, Reason}).
