%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_service).
-moduledoc """
The behaviour of one GATT service's handler over the `ble` facet (docs/design-bluetooth.md,
"The client"): a gen_server that attaches to its service through erx_gatt:attach/1 and
turns each event erx_gatt:event/2 admits into a callback of its module.

**Starting.** start_link/3,4 attach, then call `Module:init(Args)`, which answers `{ok,
Values, State}`, and set each characteristic of `Values`, a map from characteristic to
value, before the start answers `{ok, Pid}`. An attach that fails stops the start with
its refusal, `{error, attached}` past the deadline among them, so the app's supervisor
sees a start that failed and restarts it within its intensity. The registry sends the
`connected` events it replays to a new handler straight to it, so they may arrive before
the attach's answer; gen_server reads none of them until init has returned.

**Events.** A write calls `Module:handle_write(Conn, Char, Value, State)`, whose `{Answer,
State}` is the write's reply, sent before the next message is read, so the module sees a
link's next write only once it has answered the last, as the registry hands them out. A
reply the facet refuses, such as `busy`, is dropped: the registry's
`bt_handler_timeout_ms` answers that write. Every other event calls
`Module:handle_event(Event, State)`, answering `{ok, State}`.

**Calls and other messages.** call/2 calls `Module:handle_call(Request, From, State)`,
answering `{reply, Reply, State}`, so another process of the app reaches the service
through its handler, the one process whose effects the registry takes. A message in no
envelope is the handler's own domain's and calls the optional `Module:handle_info(Info,
State)`, answering `{ok, State}`; an enveloped message that is no event of the facet's
owner is dropped.

**The facet's end.** The server monitors the facet and stops with `{facet, Reason}` when
it ends: the Bluetooth domain's restart takes the registry and every attachment, and the
new incarnation mints a new facet, which the supervisor's restart of the handler attaches
through.
""".

-behaviour(gen_server).

-export([start_link/3, start_link/4, call/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-callback init(Args :: term()) -> {ok, Values :: #{atom() => binary()}, State :: term()}.
-callback handle_write(Conn :: reference(), Char :: atom(), Value :: binary(), State :: term()) ->
    {erx_gatt:answer(), State :: term()}.
-callback handle_event(Event :: erx_gatt:event(), State :: term()) -> {ok, State :: term()}.
-callback handle_call(Request :: term(), From :: gen_server:from(), State :: term()) ->
    {reply, Reply :: term(), State :: term()}.
-callback handle_info(Info :: term(), State :: term()) -> {ok, State :: term()}.
-optional_callbacks([handle_info/2]).

-record(handler, {module :: module(), facet :: reference(), origin :: non_neg_integer(), state :: term()}).
%% facet: the monitor of the facet; origin: its owner, whose envelope the events arrive in.

-doc "Starts the handler of `Service`, linked to the caller.".
-spec start_link(atom(), module(), term()) -> gen_server:start_ret().
start_link(Service, Module, Args) ->
    gen_server:start_link(?MODULE, {Service, Module, Args}, []).

-doc "Starts the handler of `Service`, linked to the caller and registered as `Name`.".
-spec start_link(gen_server:server_name(), atom(), module(), term()) -> gen_server:start_ret().
start_link(Name, Service, Module, Args) ->
    gen_server:start_link(Name, ?MODULE, {Service, Module, Args}, []).

-doc "Calls the handler `Server`'s `Module:handle_call/3` with `Request`.".
-spec call(gen_server:server_ref(), term()) -> term().
call(Server, Request) ->
    gen_server:call(Server, {call, Request}, infinity).

-doc false.
init({Service, Module, Args}) ->
    case erx_gatt:facet() of
        none ->
            {stop, not_granted};
        {Facet, Origin} ->
            Monitor = erlang:monitor(process, Facet),
            case erx_gatt:attach(Service) of
                {ok, _Table} ->
                    {ok, Values, State} = Module:init(Args),
                    [ok = erx_gatt:set(Service, Char, Value) || Char := Value <- maps:iterator(Values, ordered)],
                    {ok, #handler{module = Module, facet = Monitor, origin = Origin, state = State}};
                {error, Reason} ->
                    {stop, Reason}
            end
    end.

-doc false.
handle_call({call, Request}, From, #handler{module = Module, state = State} = Handler) ->
    {reply, Reply, Next} = Module:handle_call(Request, From, State),
    {reply, Reply, Handler#handler{state = Next}}.

-doc false.
handle_cast(_Message, Handler) ->
    {noreply, Handler}.

-doc false.
handle_info({'DOWN', Monitor, process, _Facet, Reason}, #handler{facet = Monitor} = Handler) ->
    {stop, {facet, Reason}, Handler};
handle_info({erx_origin, _, _} = Message, #handler{origin = Origin} = Handler) ->
    case erx_gatt:event(Origin, Message) of
        {ok, Event} -> {noreply, event(Event, Handler)};
        unknown -> {noreply, Handler}
    end;
handle_info(Info, #handler{module = Module, state = State} = Handler) ->
    case erlang:function_exported(Module, handle_info, 2) of
        true ->
            {ok, Next} = Module:handle_info(Info, State),
            {noreply, Handler#handler{state = Next}};
        false ->
            {noreply, Handler}
    end.

event({write, Req, Conn, Char, Value}, #handler{module = Module, state = State} = Handler) ->
    {Answer, Next} = Module:handle_write(Conn, Char, Value, State),
    _ = erx_gatt:reply(Req, Answer),
    Handler#handler{state = Next};
event(Event, #handler{module = Module, state = State} = Handler) ->
    {ok, Next} = Module:handle_event(Event, State),
    Handler#handler{state = Next}.
