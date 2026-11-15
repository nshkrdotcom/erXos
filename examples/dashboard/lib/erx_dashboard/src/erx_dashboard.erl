%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard).
-moduledoc """
The dashboard's one effect process: it owns the window and feeds the
pure view (erx_dashboard_view) the wall clock and the last board its
quotes source sent (erx_dashboard_source). It is a kiosk's application
in the sense of docs/design-display.md, "Kiosks and glasses": it opens
its UI with `erx_ui:open(#{renderer => lvgl})`, and when the UI ends its
supervisor starts it again, with a new window.

At start it starts the source the application's `source` value names
and asks for its window. A refused open is asked again every ?RETRY_MS,
since the session's display or pixel area may not be ready yet; each
refusal unlike the one before is logged as `erx_dashboard: refused
Reason`. Once a minute, on the minute, and whenever a board comes, it
computes the tree and hands it to the UI if it differs from the one
shown. The first tree a window takes is logged as `erx_dashboard:
shown`. The tree takes no input, so the UI's events are dropped.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2,
         handle_info/2]).

-define(RETRY_MS, 1000).

-type state() :: #{window := none | erx_ui:window(),
                   board := none | erx_dashboard_source:board(),
                   shown := none | erx_ui_model:tree(),
                   refused := none | term()}.

-doc "Starts the dashboard's process, registered as erx_dashboard.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
-spec init([]) -> {ok, state(), {continue, open}}.
init([]) ->
    {ok, Source} = application:get_env(erx_dashboard, source),
    case Source:start_link(self()) of
        {ok, _Pid} -> ok;
        ignore -> ok
    end,
    next_tick(),
    {ok, #{window => none, board => none, shown => none, refused => none},
     {continue, open}}.

-doc false.
handle_continue(open, State) ->
    open(State).

-doc false.
handle_call(Request, _From, State) ->
    {reply, {error, {unknown, Request}}, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
handle_info(open, State) ->
    open(State);
handle_info(tick, State) ->
    next_tick(),
    render(State);
handle_info({erx_dashboard_board, Board}, State) ->
    render(State#{board := Board});
handle_info({ui, Window, _Term, _Detail}, #{window := Window} = State) ->
    {noreply, State};
handle_info({ui_down, Window, Reason}, #{window := Window} = State) ->
    {stop, {ui_down, Reason}, State};
handle_info({'DOWN', Window, process, _Server, Reason},
            #{window := Window} = State) ->
    {stop, {ui_down, Reason}, State}.

open(#{refused := Last} = State) ->
    case erx_ui:open(#{renderer => lvgl, label => <<"dashboard">>}) of
        {ok, Window} ->
            render(State#{window := Window, refused := none});
        {error, Reason} ->
            case Reason of
                Last -> ok;
                _New -> logger:notice("erx_dashboard: refused ~0p", [Reason])
            end,
            erlang:send_after(?RETRY_MS, self(), open),
            {noreply, State#{refused := Reason}}
    end.

render(#{window := none} = State) ->
    {noreply, State};
render(#{window := Window, board := Board, shown := Shown} = State) ->
    Model = #{time => calendar:universal_time(), board => Board},
    case erx_dashboard_view:tree(Model) of
        Shown ->
            {noreply, State};
        Tree ->
            case erx_ui:tree(Window, Tree) of
                ok ->
                    case Shown of
                        none -> logger:notice("erx_dashboard: shown");
                        _Before -> ok
                    end,
                    {noreply, State#{shown := Tree}};
                {error, Reason} ->
                    {stop, {tree, Reason}, State}
            end
    end.

%% The next tick, at the start of the next wall-clock minute, when the
%% clock it shows changes.
next_tick() ->
    Ms = erlang:system_time(millisecond),
    erlang:send_after(60000 - Ms rem 60000, self(), tick).
