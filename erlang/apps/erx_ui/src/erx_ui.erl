%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui).
-moduledoc """
The widget toolkit's client library (docs/design-display.md, "The widget
server" and "Choosing a display"). An application opens a UI, hands it
trees and closes it; the UI's widget server, erx_ui_server, runs under the
toolkit's supervisor erx_ui_sup in the application's own runtime and sends
the opener `{ui, Window, Term, Detail}` for each event its tree takes and
`{ui_down, Window, Reason}` when the UI ends other than by close/1.

`Window` is the reference of the monitor the opener holds on the server,
so a server that is killed outright leaves the opener that monitor's
`'DOWN'`. The opener's process dictionary maps it to the server, under
`{erx_ui, Window}`: a UI is its opener's, as its events are, and tree/2
and close/1 work from the opener.

open/1 chooses the display and the renderer by choose/2. While
erx_ui_host, the SDK's stand-in for a display on the development host
(docs/design-packaging.md, "The SDK"), runs in the node under that name,
it is the default display unless the environment's `display` names one
the domain holds, LVGL is the default renderer unless the environment's
`ui_renderer` names one, and the window comes from the host. On a display
the domain holds, the server opens its own target, a window made with the
server as its holder: for the LVGL renderer a window with no buffer of its
own (`buffer => none`), since its program draws in a range its handler
lends (docs/design-display.md, "Erlang clients"). The Erlang renderer and
the web line are not built yet, so `erlang` on a display, and `web`,
answer `{error, enotsup}`. start/1 starts a UI on a target its caller
made; it is the entry of the tests, the renderers' harnesses and the
host's window.
""".

-export([open/1, tree/2, close/1]).
-export([choose/2, start/1]).

-include("generated/erx_abi.hrl").

-type window() :: reference().
-type renderer() :: erlang | lvgl.
-export_type([window/0, renderer/0]).

-doc """
Opens a UI on the display that `Options`' `display` names, or the default
display, the environment variable `display`, drawn by the renderer that
`Options`' `renderer` names, or the one `ui_renderer` names, or `erlang`,
in a window titled by `Options`' `label`, a binary, when it is given.
`{error, no_display}` when the name is unset or names no display the
domain holds; otherwise the refusal of the window's open, as
`{window, Reason}`, or `renderer_down` for a renderer that did not start.
""".
-spec open(map()) -> {ok, window()} | {error, term()}.
open(Options) when is_map(Options) ->
    Caps = erx:caps(),
    Host = whereis(erx_ui_host),
    Env = #{display => default_display(os:getenv(binary_to_list(?ERX_DISPLAY_KEY_BYTES)), Host, Caps),
            ui_renderer => host_renderer(os:getenv("ui_renderer"), Host)},
    case choose(Options, Env) of
        {ok, web, _Renderer} -> {error, enotsup};
        {ok, erx_ui_host, Renderer} when is_pid(Host) -> on_host(Host, Renderer);
        {ok, Display, Renderer} -> on_display(Display, Renderer, label(Options), Caps);
        {error, _Why} = Refused -> Refused
    end;
open(_Options) ->
    {error, badarg}.

-doc "Hands the UI a tree: `ok`, or `{error, Reason}` with the UI unchanged.".
-spec tree(window(), term()) -> ok | {error, term()}.
tree(Window, Tree) ->
    case get({?MODULE, Window}) of
        undefined ->
            {error, closed};
        Server ->
            try erx_ui_server:tree(Server, Tree)
            catch exit:{_Why, {gen_server, call, _}} -> {error, closed}
            end
    end.

-doc "Ends the UI and its window; the opener is sent nothing more of it.".
-spec close(window()) -> ok.
close(Window) ->
    case erase({?MODULE, Window}) of
        undefined ->
            ok;
        Server ->
            demonitor(Window, [flush]),
            try erx_ui_server:close(Server)
            catch exit:{_Why, {gen_server, call, _}} -> ok
            end,
            %% A UI that ended before the close may have sent its ui_down.
            receive {ui_down, Window, _} -> ok after 0 -> ok end
    end.

-doc """
The display and renderer `Options` choose, given the environment's
`display` and `ui_renderer` (each a string, or `false` when unset): the
display's name, the atom `web` for the web line, and the renderer. A name
is matched against the atoms that exist, so no name makes an atom; a
`renderer` option other than `erlang` and `lvgl` is `badarg`, and an
environment value other than theirs names none.
""".
-spec choose(map(), #{display := string() | false, ui_renderer := string() | false}) ->
          {ok, atom(), renderer()} | {error, no_display | badarg}.
choose(Options, #{display := DefaultDisplay, ui_renderer := DefaultRenderer}) ->
    Display = case Options of
                  #{display := Name} -> Name;
                  #{} -> existing_atom(DefaultDisplay)
              end,
    Renderer = case Options of
                   #{renderer := Named} -> Named;
                   #{} -> env_renderer(DefaultRenderer)
               end,
    if
        Renderer =/= erlang, Renderer =/= lvgl -> {error, badarg};
        not is_atom(Display) -> {error, badarg};
        Display =:= undefined -> {error, no_display};
        true -> {ok, Display, Renderer}
    end.

-doc """
Starts a UI for the caller, drawn by `renderer`, a module of the
erx_ui_renderer behaviour, started with `opts`, on `target`: one its
caller made, the entry of the tests, the renderers' harnesses and
erx_ui_host's window, or a display the server opens a window on
(erx_ui_server:target()), open/1's.
""".
-spec start(#{renderer := module(), target := erx_ui_server:target(), opts := map()}) ->
          {ok, window()} | {error, term()}.
start(#{renderer := Renderer, target := Target, opts := Opts}) ->
    Spec = #{opener => self(), renderer => Renderer, target => Target, opts => Opts},
    case erx_ui_sup:start_server(Spec) of
        {ok, Server} ->
            Window = monitor(process, Server),
            try erx_ui_server:opened(Server, Window) of
                ok ->
                    put({?MODULE, Window}, Server),
                    {ok, Window}
            catch
                exit:{Why, {gen_server, call, _}} ->
                    demonitor(Window, [flush]),
                    {error, Why}
            end;
        {error, {shutdown, Why}} ->
            {error, Why};
        {error, _Why} = Failed ->
            Failed
    end.

%% The default display: the environment's `display` when it names a display
%% the domain holds, else erx_ui_host while it runs, else the environment's
%% `display`, which then names none.
default_display(Named, Host, Caps) ->
    case is_map_key(existing_atom(Named), Caps) orelse Host =:= undefined of
        true -> Named;
        false -> "erx_ui_host"
    end.

%% The default renderer: the environment's `ui_renderer`, or else LVGL
%% while erx_ui_host runs, the one renderer it draws with.
host_renderer(false, Host) when is_pid(Host) -> "lvgl";
host_renderer(Named, _Host) -> Named.

%% A window of erx_ui_host, drawn by Renderer: the host answers the
%% renderer's module and its options, or refuses. A host that ends before
%% it answers is no display.
on_host(Host, Renderer) ->
    try gen_server:call(Host, {window, Renderer}) of
        {ok, Module, Opts} -> start(#{renderer => Module, target => {window, Host}, opts => Opts});
        {error, _Why} = Refused -> Refused
    catch exit:{_Why, {gen_server, call, _}} -> {error, no_display}
    end.

%% A display the domain holds: the LVGL renderer in a window the server
%% opens with no buffer of its own.
on_display(_Display, _Renderer, badarg, _Caps) ->
    {error, badarg};
on_display(Display, _Renderer, _Label, Caps) when not is_map_key(Display, Caps) ->
    {error, no_display};
on_display(Display, lvgl, Label, _Caps) ->
    start(#{renderer => erx_ui_lvgl, target => {display, Display, #{buffer => none}, Label}, opts => #{}});
on_display(_Display, erlang, _Label, _Caps) ->
    {error, enotsup}.

label(#{label := Label}) when is_binary(Label) -> Label;
label(#{label := _NotABinary}) -> badarg;
label(#{}) -> none.

existing_atom(false) -> undefined;
existing_atom(Name) ->
    try list_to_existing_atom(Name)
    catch error:badarg -> undefined
    end.

env_renderer("lvgl") -> lvgl;
env_renderer(_ErlangOrUnset) -> erlang.
