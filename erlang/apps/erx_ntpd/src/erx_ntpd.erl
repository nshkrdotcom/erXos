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
session runs: it resolves each name through the session's resolver, makes
each exchange over a socket of its own (erx_ntp_exchange:ask/1; a socket that
cannot be opened is no reply), sends each sample
to the clock service through the session's `clock` facet, which decides
whether to step, and waits. Network that is not up yet is no special case:
the resolution or the exchange fails and the schedule's backoff asks again.

Every answer of the clock service other than a held sample is logged; the
service itself logs the steps it makes and the samples it refuses. A server
address is written as integers, so no text of a server reaches the log.

It registers as erx_ntpd and, while it waits, answers status/1, the
collector of `/proc/ntp` in this runtime (erx_ntp_records), with
erx_ntp_core:status/1; a question that comes during a resolution, an
exchange or a sample waits for the next wait.
""".
-behaviour(application).

-export([start/2, stop/1]).
-export([init/1, status/1]).

%% How long one sample waits for the clock service's answer.
-define(CLOCK_MS, 10000).

start(_Type, _Args) ->
    proc_lib:start_link(?MODULE, init, [self()]).

stop(_State) ->
    ok.

-doc false.
init(Parent) ->
    case erx_ntp_core:servers(flags()) of
        {ok, Names} ->
            true = register(?MODULE, self()),
            proc_lib:init_ack(Parent, {ok, self()}),
            {Action, State} = erx_ntp_core:start(Names),
            loop(Action, State);
        {error, Reason} ->
            logger:error("ntpd: ~ts", [reason_text(Reason)]),
            proc_lib:init_fail(Parent, {error, Reason}, {exit, normal})
    end.

-doc """
ntpd's status, erx_ntp_core:status/1 of its run, waiting at most Wait
milliseconds: `{error, unavailable}` when no ntpd runs here and `{timeout,
Wait}` when it does not answer in time.
""".
-spec status(pos_integer()) -> {ok, erx_ntp_core:status()} | {error, unavailable} | {timeout, pos_integer()}.
status(Wait) ->
    Alias = alias([reply]),
    try ?MODULE ! {status, Alias} of
        _ ->
            receive
                {Alias, Status} -> {ok, Status}
            after Wait ->
                unalias(Alias),
                receive {Alias, _Late} -> ok after 0 -> ok end,
                {timeout, Wait}
            end
    catch
        error:badarg ->
            unalias(Alias),
            {error, unavailable}
    end.

flags() ->
    case os:getenv("ERX_START_FLAGS") of
        false -> <<>>;
        Flags -> list_to_binary(Flags)
    end.

reason_text(no_servers) -> "no servers";
reason_text(bad_flags) -> "bad flags".

loop(Action, State) ->
    {Next, State1} = erx_ntp_core:step(perform(Action, State), State),
    loop(Next, State1).

perform({resolve, Name}, _State) ->
    {resolved, erx_ntp_exchange:addresses(Name)};
perform({exchange, Address, _Kind}, _State) ->
    {exchanged, erx_ntp_exchange:ask(Address)};
perform({submit, Sample, Address}, _State) ->
    Answer = submit(erx_ntp_core:request(Sample, Address)),
    report(Answer, Address),
    {clock, Answer};
perform({wait, Ms}, State) ->
    wait(erlang:monotonic_time(millisecond) + Ms, State).

%% Waits until Deadline, answering each status question meanwhile.
wait(Deadline, State) ->
    receive
        {status, Alias} when is_reference(Alias) ->
            Alias ! {Alias, erx_ntp_core:status(State)},
            wait(Deadline, State)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        woke
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
