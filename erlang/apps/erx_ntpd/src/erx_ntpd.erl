%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntpd).
-moduledoc """
ntpd, the network time client (docs/design-time.md, "The client"): the
application its session's `-eval` starts, permanent, and its one process,
the thin effect layer around erx_ntp_core.

At start it reads its server list from `ERX_START_FLAGS` once. Empty
flags, or flags that break the server-list rule, fail the start with
`no_servers` or `bad_flags` after a log line saying so, which ends the
session; the start table's intensity then leaves the row down. Otherwise it
performs what erx_ntp_core asks, one action at a time, for as long as the
session runs: it resolves the names through the session's resolver, makes
each exchange over a socket of its own (erx_ntp_exchange), sends each sample
to the clock service through the session's `clock` facet, which decides
whether to step, and waits. Network that is not up yet is no special case:
the resolution or the exchange fails and the schedule's backoff asks again.

Every answer of the clock service other than a held sample is logged; the
service itself logs the steps it makes and the samples it refuses. A server
address is written as integers, so no text of a server reaches the log.
""".
-behaviour(application).

-export([start/2, stop/1]).
-export([init/1]).

%% How long one exchange waits for its reply, one resolution for DNS, and one
%% sample for the clock service's answer.
-define(EXCHANGE_MS, 2000).
-define(RESOLVE_MS, 10000).
-define(CLOCK_MS, 10000).
%% The addresses of one name that are used, as DNS orders them.
-define(ADDRESSES_PER_NAME, 4).

start(_Type, _Args) ->
    proc_lib:start_link(?MODULE, init, [self()]).

stop(_State) ->
    ok.

-doc false.
init(Parent) ->
    case erx_ntp_core:servers(flags()) of
        {ok, Names} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            {Action, State} = erx_ntp_core:start(Names),
            loop(Action, State);
        {error, Reason} ->
            logger:error("ntpd: ~ts", [reason_text(Reason)]),
            proc_lib:init_fail(Parent, {error, Reason}, {exit, normal})
    end.

flags() ->
    case os:getenv("ERX_START_FLAGS") of
        false -> <<>>;
        Flags -> list_to_binary(Flags)
    end.

reason_text(no_servers) -> "no servers";
reason_text(bad_flags) -> "bad flags".

loop(Action, State) ->
    {Next, State1} = erx_ntp_core:step(perform(Action), State),
    loop(Next, State1).

perform({resolve, Names}) ->
    {resolved, lists:append([addresses(Name) || Name <- Names])};
perform({exchange, Address, _Kind}) ->
    {exchanged, exchange(Address)};
perform({submit, Sample, Address}) ->
    Answer = submit(erx_ntp_core:request(Sample, Address)),
    report(Answer, Address),
    {clock, Answer};
perform({wait, Ms}) ->
    receive after Ms -> woke end.

addresses(Name) ->
    String = binary_to_list(Name),
    case inet:parse_ipv4strict_address(String) of
        {ok, Address} ->
            [Address];
        {error, _} ->
            case inet:getaddrs(String, inet, ?RESOLVE_MS) of
                {ok, Addresses} -> lists:sublist(Addresses, ?ADDRESSES_PER_NAME);
                {error, _} -> []
            end
    end.

%% A socket that cannot be opened is no reply: the schedule asks again later.
exchange(Address) ->
    case gen_udp:open(0, [binary, {active, false}]) of
        {ok, Socket} ->
            try erx_ntp_exchange:exchange(Socket, Address, ?EXCHANGE_MS) of
                {sample, Sample, _WallOffset} -> {sample, Sample};
                Other -> Other
            after
                gen_udp:close(Socket)
            end;
        {error, _} = Error ->
            Error
    end.

%% A facet that has ended was sent nothing; one that ends or stays silent past
%% the wait may or may not have applied the step, which the next sample finds
%% out from the page (docs/design-time.md, "Concurrency and failure").
submit(Request) ->
    case erx:cap(clock) of
        Facet when is_pid(Facet) ->
            try gen_server:call(Facet, Request, ?CLOCK_MS)
            catch
                exit:{noproc, _} -> {error, unavailable};
                exit:_ -> {error, failed}
            end;
        undefined ->
            {error, no_facet}
    end.

report({ok, held}, _Address) ->
    ok;
report({ok, {stepped, StepNs}}, Address) ->
    logger:notice("ntpd: stepped by ~b ns from ~ts", [StepNs, inet:ntoa(Address)]);
report({ok, {refused, Why}}, Address) ->
    logger:warning("ntpd: sample from ~ts refused: ~p", [inet:ntoa(Address), Why]);
report({error, Reason}, Address) ->
    logger:warning("ntpd: sample from ~ts not taken: ~p", [inet:ntoa(Address), Reason]).
