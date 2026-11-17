%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes).
-moduledoc """
The dashboard's live quotes source (docs/design-quotes.md): the one
effect process around the pure core. The dashboard starts it linked to
itself and shows the boards it sends as `{erx_dashboard_board, Board}`.

At start it starts `ssl` and `inets` and starts the core
(erx_quotes_core) on the source table (erx_quotes_table) with every quote
due. An application that does not start stops it with the reason, which
ends the dashboard's start. Once a second it ticks
the core, carries out the actions the core returns and, on `render`,
sends the dashboard the board of erx_quotes_view when it differs from the
last one sent. A `fetch` is one httpc request, made exactly as
docs/design-quotes.md, "One request", states; its answer is classified
(erx_quotes_http), a redirect within its origin followed within the same
round, and a body read (erx_quotes_extract), and the outcome goes back
to the core. An answer to a request it does not hold is dropped.
""".
-behaviour(gen_server).

-export([start_link/1, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK_MS, 1000).

-type request() :: #{quote := atom(), source := atom(), url := binary(),
                     hops := non_neg_integer()}.
-type state() :: #{dashboard := pid(),
                   core := erx_quotes_core:state(),
                   requests := #{reference() => request()},
                   sent := none | erx_dashboard_view:board(),
                   logged := #{atom() => binary()}}.

-doc "Starts the live source, linked to `Dashboard`, to which it sends its boards.".
-spec start_link(pid()) -> {ok, pid()} | {error, term()}.
start_link(Dashboard) ->
    start_link(Dashboard, erx_quotes_table:table()).

-doc "Starts the live source on the source table `Table` instead of the fixed one.".
-spec start_link(pid(), erx_quotes_table:table()) -> {ok, pid()} | {error, term()}.
start_link(Dashboard, Table) ->
    gen_server:start_link(?MODULE, {Dashboard, Table}, []).

-doc false.
-spec init({pid(), erx_quotes_table:table()}) -> {ok, state()} | {stop, term()}.
init({Dashboard, Table}) ->
    case application:ensure_all_started([ssl, inets]) of
        {ok, _Started} ->
            %% httpc reads the trust store in the caller at the first
            %% request; one that cannot be read stops the source here,
            %% with its reason, instead of at every fetch.
            _ = public_key:cacerts_get(),
            self() ! tick,
            {ok, #{dashboard => Dashboard,
                   core => erx_quotes_core:new(Table, now_ms()),
                   requests => #{}, sent => none, logged => #{}}};
        {error, Reason} ->
            {stop, {quotes_start, Reason}}
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
action(render, #{dashboard := Dashboard, core := Core, sent := Sent, logged := Logged} = State) ->
    Now = now_ms(),
    Logged2 = log_changes(erx_quotes_view:lines(Core, Now), Logged),
    case erx_quotes_view:board(Core, Now) of
        Sent ->
            State#{logged := Logged2};
        Board ->
            Dashboard ! {erx_dashboard_board, Board},
            State#{sent := Board, logged := Logged2}
    end.

%% One log line per change of a quote's line (erx_quotes_view:lines/2),
%% which the QEMU cell display_domain/quotes reads from the serial line.
log_changes(Lines, Logged) ->
    lists:foldl(fun({Name, Line}, Acc) ->
                        case Acc of
                            #{Name := Line} ->
                                Acc;
                            #{} ->
                                logger:notice("quotes: ~ts", [Line]),
                                Acc#{Name => Line}
                        end
                end, Logged, Lines).

%% One request, as docs/design-quotes.md, "One request", states, to the
%% address of the request's source: no name is resolved. httpc connects
%% to the URL with its host replaced by that address; the `host` header
%% and the TLS server name are the URL's host, so the server sees the
%% request it would by name, and the certificate is verified against the
%% system's roots and checked against the host name (ssl_handshake.erl:
%% server_name/3 takes server_name_indication for the name check).
%% Both size limits go in the fourth argument, where httpc reads them. A
%% request httpc refuses at once is answered as if it had failed.
request(#{source := Source, url := Url} = Request,
        #{core := Core, requests := Requests} = State) ->
    #{address := Address} = source_row(Source, Core),
    {Target, Authority, Host} = by_address(Url, Address),
    case httpc:request(get, {Target, [{"host", Authority}, {"user-agent", "erxos-quotes/1"}]},
                       [{timeout, 20000}, {connect_timeout, 10000},
                        {autoredirect, false}, {autoretry, 0},
                        {ssl, httpc:ssl_verify_host_options(true)
                              ++ [{server_name_indication, Host}]}],
                       [{sync, false}, {receiver, self()}, {body_format, binary},
                        {max_header_size, 10240}, {max_body_size, 65536}]) of
        {ok, RequestId} -> State#{requests := Requests#{RequestId => Request}};
        {error, _Reason} = Error -> answered(Request, Error, State)
    end.

%% `Url` with its host replaced by `Address`, the URL's host and port as
%% a `host` header gives them (the port only when it is not https's 443),
%% and its host as a string. Every URL here is the table's or a redirect
%% erx_quotes_http kept within its origin, so it parses with a host.
by_address(Url, Address) ->
    #{host := Host} = Parsed = uri_string:parse(Url),
    Authority = case maps:get(port, Parsed, 443) of
                    443 -> Host;
                    Port -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>
                end,
    Target = uri_string:recompose(Parsed#{host := list_to_binary(inet:ntoa(Address))}),
    {Target, binary_to_list(Authority), binary_to_list(Host)}.

source_row(Source, #{table := #{sources := Sources}}) ->
    maps:get(Source, Sources).

now_ms() ->
    erlang:monotonic_time(millisecond).

%% A factor in [0.8, 1.2), so quotes that failed together retry apart.
jitter() ->
    0.8 + 0.4 * rand:uniform_real().
