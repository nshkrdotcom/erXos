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

erx_app's process acknowledges its start first and only then mounts and starts
the app, so an app that names erx_app, or depends on it, finds it started
rather than waiting on its own start. The process holds nothing; erx_app is
permanent, so its end, with the first step's failure as its reason, ends the
session.

A native app's program needs erx_prog_handler's `window` option, which the
handler does not offer; its record ends erx_app with `{not_supported, program}`.
""".
-behaviour(application).

-export([start/2, stop/1]).
-export([run/2, init/1]).
-export_type([app_record/0, effects/0]).

-doc """
The app's record, as the domain service sends it once the session's namespace
is in place (docs/design-packaging.md, "An app's session"): where the package's file lies in the session's namespace,
its header's layout, and what it starts, as its header declares it.
""".
-type app_record() :: #{place := binary(),
                        layout := erx_verity_tree:layout(),
                        start := erx_pkg_header:start()}.

-doc """
The effects run/2 performs: the mount of `/app`, where the mounted image lies,
and the start type of the declared applications. The application passes its
own (effects/0): permanent, so a declared application's end ends the session; a
host test passes a mount over a fixture directory and `temporary`, so a failed
start ends only the case.
""".
-type effects() :: #{mount := fun(() -> ok | {error, term()}),
                     root := string(),
                     type := permanent | temporary}.

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
`Effects`. The first step that fails is the answer.
""".
-spec run(app_record(), effects()) -> ok | {error, term()}.
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
      type => permanent}.

start_app(#{start := {applications, Names}}, #{mount := Mount, root := Root, type := Type}) ->
    case Mount() of
        ok -> ok;
        {error, Reason} -> fail({mount, Reason})
    end,
    lists:foreach(fun add_path/1, ebins(Root)),
    lists:foreach(fun(Name) -> start_application(binary_to_atom(Name), Type) end, Names);
start_app(#{start := {program, _Program, _Args}}, _Effects) ->
    fail({not_supported, program}).

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
