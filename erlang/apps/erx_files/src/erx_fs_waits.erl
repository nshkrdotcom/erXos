%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_waits).
-moduledoc """
A keeper's set of waiting requests (docs/design-files.md, "Serving: the
`erx_fs` behaviour", "Waiting requests").

A read or a write that must wait for an event is handed by the grant that
took it to the tree process that owns the event, its keeper, as
`{erx_fs_wait, Wait, Request}`: `Wait` is `{Grant, Alias}`, the grant's pid
and an alias of the grant's monitor of the keeper that the first message
to it deactivates, and `Request` is the tree's own term for what to do. A
later `{erx_fs_flush, Wait}` from the same grant follows the request.

The keeper keeps the requests in this set and answers them only through
it, so the obligations every keeper shares live here:

* `answer/3` is the one way an answer leaves the set: it sends
  `{erx_fs_answer, Alias, Result}` to the request's alias and forgets the
  request in the same step, so no answered request stays held, and an
  alias takes one answer, so a second is dropped by construction.
* A flush of a request not yet begun is answered `{error, eintr}` by the
  set itself, through `answer/3`. A flush of a begun request goes to the
  keeper once, whose answer when the effect ends settles it; a later flush
  of the same request finds its flush already waiting.
* The set monitors each grant it holds a request of, once, and releases
  the monitor with that grant's last request; the grant's end drops every
  request it sent, waiting or begun, unanswered.

The requests are kept in one table, keyed by alias; beside it the set keeps
each held grant's monitor and its count of requests in the table, which
only `hold/2` and the forgetting of a request change.
""".

-export([new/0, hold/2, began/2, answer/3, info/2, list/1]).

-export_type([waits/0, wait/0]).

-doc "A waiting request's name: the grant that sent it and the alias its answer goes to.".
-type wait() :: {Grant :: pid(), Alias :: reference()}.

%% A held request: what a flush finds it doing is its state. A request is
%% waiting until the keeper begins it; a begun request whose flush the
%% keeper holds is flushing, and stays held until the keeper answers it.
-record(held, {wait :: wait(),
               request :: term(),
               arrival :: non_neg_integer(),
               state :: waiting | begun | flushing}).

%% held: every request the keeper holds, by alias; grants: the monitor of
%% each grant with a request in held, and how many it has there; arrivals:
%% the arrival number the next request takes.
-record(waits, {held = #{} :: #{reference() => #held{}},
                grants = #{} :: #{pid() => {reference(), pos_integer()}},
                arrivals = 0 :: non_neg_integer()}).

-opaque waits() :: #waits{}.

-doc "An empty set.".
-spec new() -> waits().
new() ->
    #waits{}.

-doc """
Holds the request of an `{erx_fs_wait, Wait, Request}` message, and monitors
the grant that sent it unless the set holds a request of that grant already.
""".
-spec hold({erx_fs_wait, wait(), term()}, waits()) -> waits().
hold({erx_fs_wait, {Grant, Alias} = Wait, Request},
     #waits{held = Held, grants = Grants, arrivals = Arrival} = Waits) ->
    Waits#waits{held = Held#{Alias => #held{wait = Wait, request = Request,
                                            arrival = Arrival, state = waiting}},
                grants = monitor_grant(Grant, Grants),
                arrivals = Arrival + 1}.

-doc """
Marks a held request begun, before the keeper starts its effect: from then
a flush waits for the keeper's answer, which says what the effect did.
""".
-spec began(wait(), waits()) -> waits().
began({_, Alias}, #waits{held = Held} = Waits) ->
    #{Alias := #held{state = waiting} = Entry} = Held,
    Waits#waits{held = Held#{Alias := Entry#held{state = begun}}}.

-doc """
Answers a request with `Result`, one of the tree callback's own answers
other than a wait, and forgets it. A request the set no longer holds, one
flushed or dropped meanwhile, is not answered.
""".
-spec answer(wait(), term(), waits()) -> waits().
answer({_, Alias}, Result, #waits{held = Held} = Waits) ->
    case Held of
        #{Alias := Entry} ->
            erlang:send(Alias, {erx_fs_answer, Alias, Result}),
            forget(Alias, Entry, Waits);
        #{} ->
            Waits
    end.

-doc """
Takes a message the keeper received that may be the set's:

* `{flushed, Waits}` for an `{erx_fs_flush, Wait}` the set has settled
  itself: it answered a request not yet begun `{error, eintr}`, or the
  request has been answered already, or its flush already waits;
* `{begun, Wait, Request, Waits}` for the first flush of a begun request,
  which the keeper's answer to it settles, and which a keeper that passed
  the request on to another server flushes there;
* `{dropped, Waits}` for a held grant's `DOWN`: every request it sent is
  forgotten unanswered;
* `unknown` for any other message, which is the keeper's own.
""".
-spec info(term(), waits()) ->
          {flushed, waits()} | {begun, wait(), term(), waits()} | {dropped, waits()} | unknown.
info({erx_fs_flush, {_, Alias} = Wait}, #waits{held = Held} = Waits) ->
    case Held of
        #{Alias := #held{state = waiting}} ->
            {flushed, answer(Wait, {error, eintr}, Waits)};
        #{Alias := #held{state = begun, request = Request} = Entry} ->
            {begun, Wait, Request, Waits#waits{held = Held#{Alias := Entry#held{state = flushing}}}};
        #{} ->
            {flushed, Waits}
    end;
info({'DOWN', Monitor, process, Grant, _}, #waits{held = Held, grants = Grants} = Waits) ->
    case Grants of
        #{Grant := {Monitor, _}} ->
            {dropped, Waits#waits{held = maps:filter(fun(_, #held{wait = {G, _}}) -> G =/= Grant end, Held),
                                  grants = maps:remove(Grant, Grants)}};
        #{} ->
            unknown
    end;
info(_, _) ->
    unknown.

-doc """
The requests the set holds, in the order they arrived, each with whether
the keeper has begun it.
""".
-spec list(waits()) -> [{wait(), Request :: term(), waiting | begun}].
list(#waits{held = Held}) ->
    [{Wait, Request, shown(State)}
     || #held{wait = Wait, request = Request, state = State}
            <- lists:keysort(#held.arrival, maps:values(Held))].

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

monitor_grant(Grant, Grants) ->
    case Grants of
        #{Grant := {Monitor, Count}} -> Grants#{Grant := {Monitor, Count + 1}};
        #{} -> Grants#{Grant => {erlang:monitor(process, Grant), 1}}
    end.

%% Forgets one held request, and its grant's monitor with the grant's last request.
forget(Alias, #held{wait = {Grant, _}}, #waits{held = Held, grants = Grants} = Waits) ->
    Waits#waits{held = maps:remove(Alias, Held),
                grants = case Grants of
                             #{Grant := {Monitor, 1}} ->
                                 erlang:demonitor(Monitor, [flush]),
                                 maps:remove(Grant, Grants);
                             #{Grant := {Monitor, Count}} ->
                                 Grants#{Grant := {Monitor, Count - 1}}
                         end}.

%% A flushing request is begun to the keeper, which holds its flush.
shown(flushing) -> begun;
shown(State) -> State.
