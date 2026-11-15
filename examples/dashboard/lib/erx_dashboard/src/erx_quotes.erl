%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes).
-moduledoc """
The dashboard's live quotes source, the full kiosk's (docs/design-quotes.md):
the one effect process around the pure core. The basic kiosk never starts
it; a release starts it by setting the application's `source` value to
erx_quotes and `quotes_table` to the source table's path, by default
`/app/share/quotes.config` (erx_dashboard_source).

At start it reads and validates the table (erx_quotes_config), starts
`ssl` and `inets`, and starts the core (erx_quotes_core) with every quote
due. A table it refuses, or an application that does not start, stops it
with the reason, which ends the dashboard's start. Once a second it ticks
the core, carries out the actions the core returns and, on `render`,
sends the dashboard the board of erx_quotes_view when it differs from the
last one sent. A `fetch` is one httpc request, made exactly as
docs/design-quotes.md, "One request", states; its answer is classified
(erx_quotes_http), a redirect within its origin followed within the same
round, and a body read (erx_quotes_extract), and the outcome goes back
to the core. An answer to a request it does not hold is dropped.
""".
-behaviour(erx_dashboard_source).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK_MS, 1000).
-define(DEFAULT_TABLE, "/app/share/quotes.config").

-type request() :: #{quote := atom(), source := atom(), url := binary(),
                     hops := non_neg_integer()}.
-type state() :: #{dashboard := pid(),
                   core := erx_quotes_core:state(),
                   requests := #{reference() => request()},
                   sent := none | erx_dashboard_source:board()}.

-doc "Starts the live source, linked to `Dashboard`, to which it sends its boards.".
-spec start_link(pid()) -> {ok, pid()} | {error, term()}.
start_link(Dashboard) ->
    gen_server:start_link(?MODULE, Dashboard, []).

-doc false.
-spec init(pid()) -> {ok, state()} | {stop, term()}.
init(Dashboard) ->
    Path = application:get_env(erx_dashboard, quotes_table, ?DEFAULT_TABLE),
    case erx_quotes_config:read(Path) of
        {ok, Table} ->
            case application:ensure_all_started([ssl, inets]) of
                {ok, _Started} ->
                    %% httpc reads the trust store in the caller at the first
                    %% request; one that cannot be read stops the source here,
                    %% with its reason, instead of at every fetch.
                    _ = public_key:cacerts_get(),
                    self() ! tick,
                    {ok, #{dashboard => Dashboard,
                           core => erx_quotes_core:new(Table, now_ms()),
                           requests => #{}, sent => none}};
                {error, Reason} ->
                    {stop, {quotes_start, Reason}}
            end;
        {error, Reason} ->
            {stop, {quotes_table, Reason}}
    end.

-doc false.
handle_call(Request, _From, State) ->
    {reply, {error, {unknown, Request}}, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
handle_info(tick, #{core := Core} = State) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, carry_out(erx_quotes_core:tick(Core, now_ms(), jitter()), State)};
handle_info({http, {RequestId, Result}}, #{requests := Requests} = State) ->
    case maps:take(RequestId, Requests) of
        {Request, Left} -> {noreply, answered(Request, Result, State#{requests := Left})};
        error -> {noreply, State}
    end;
handle_info(_Other, State) ->
    {noreply, State}.

answered(#{quote := Quote, source := Source, url := Url, hops := Hops} = Request,
         Result, #{core := Core} = State) ->
    case erx_quotes_http:classify(Result, Url, Hops, os:system_time(second)) of
        {follow, Next} ->
            request(Request#{url := Next, hops := Hops + 1}, State);
        {body, Body} ->
            Outcome = case erx_quotes_extract:value(source_row(Source, Core), Body) of
                          {ok, Price, Change} -> {value, Price, Change};
                          {error, bad_data} -> {error, bad_data, none}
                      end,
            outcome(Quote, Outcome, State);
        {error, Reason, RetryAfter} ->
            outcome(Quote, {error, Reason, RetryAfter}, State)
    end.

outcome(Quote, Outcome, #{core := Core} = State) ->
    carry_out(erx_quotes_core:outcome(Core, Quote, Outcome, now_ms(), jitter()), State).

carry_out({Core, Actions}, State) ->
    lists:foldl(fun action/2, State#{core := Core}, Actions).

action({fetch, Quote, Source, Url}, State) ->
    request(#{quote => Quote, source => Source, url => Url, hops => 0}, State);
action(render, #{dashboard := Dashboard, core := Core, sent := Sent} = State) ->
    case erx_quotes_view:board(Core, now_ms()) of
        Sent ->
            State;
        Board ->
            Dashboard ! {erx_dashboard_board, Board},
            State#{sent := Board}
    end.

%% One request, as docs/design-quotes.md, "One request", states: no TLS
%% option, so httpc takes the system's defaults, and both size limits in
%% the fourth argument, where httpc reads them. A request httpc refuses
%% at once is answered as if it had failed.
request(#{url := Url} = Request, #{requests := Requests} = State) ->
    case httpc:request(get, {Url, [{"user-agent", "erxos-quotes/1"}]},
                       [{timeout, 20000}, {connect_timeout, 10000},
                        {autoredirect, false}, {autoretry, 0}],
                       [{sync, false}, {receiver, self()}, {body_format, binary},
                        {max_header_size, 10240}, {max_body_size, 65536}]) of
        {ok, RequestId} -> State#{requests := Requests#{RequestId => Request}};
        {error, _Reason} = Error -> answered(Request, Error, State)
    end.

source_row(Source, #{table := #{sources := Sources}}) ->
    maps:get(Source, Sources).

now_ms() ->
    erlang:monotonic_time(millisecond).

%% A factor in [0.8, 1.2), so quotes that failed together retry apart.
jitter() ->
    0.8 + 0.4 * rand:uniform_real().
