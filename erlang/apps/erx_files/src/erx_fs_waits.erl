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

The requests are kept in one table keyed by alias. Beside it, each grant
with a request held has its monitor and the set of its aliases in the
table, so whether a grant still has a request held is read from that set,
not counted.
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

%% held: every request the keeper holds, by alias. grants: for each grant
%% with a request in held, its monitor and the aliases of its requests
%% there. next_arrival: the arrival number the next request takes.
-record(waits, {held = #{} :: #{reference() => #held{}},
                grants = #{} :: #{pid() => {reference(), #{reference() => []}}},
                next_arrival = 0 :: non_neg_integer()}).

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
     #waits{held = Held, grants = Grants, next_arrival = Arrival} = Waits)
  when is_pid(Grant), is_reference(Alias) ->
    Entry = #held{wait = Wait, request = Request, arrival = Arrival, state = waiting},
    {Monitor, Aliases} = case Grants of
                             #{Grant := Known} -> Known;
                             #{} -> {erlang:monitor(process, Grant), #{}}
                         end,
    Waits#waits{held = Held#{Alias => Entry},
                grants = Grants#{Grant => {Monitor, Aliases#{Alias => []}}},
                next_arrival = Arrival + 1}.

-doc """
Marks a request begun, before the keeper starts its effect: from then a
flush waits for the keeper's answer, which says what the effect did. The
request must be one `list/1` shows waiting in the same step of the keeper;
any other fails with `badmatch`, since a keeper that begins an effect for a
request it no longer holds has lost track of its own requests.
""".
-spec began(wait(), waits()) -> waits().
began({_, Alias} = Wait, #waits{held = Held} = Waits) ->
    #{Alias := #held{wait = Wait, state = waiting} = Entry} = Held,
    Waits#waits{held = Held#{Alias := Entry#held{state = begun}}}.

-doc """
Answers a request with `Result`, one of the tree callback's own answers
other than a wait, and forgets it. A request the set no longer holds, one
flushed or dropped meanwhile, is not answered.
""".
-spec answer(wait(), term(), waits()) -> waits().
answer({_, Alias} = Wait, Result, #waits{held = Held} = Waits) ->
    case Held of
        #{Alias := #held{wait = Wait}} ->
            erlang:send(Alias, {erx_fs_answer, Alias, Result}),
            forget(Wait, Waits);
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
          {flushed, waits()} | {begun, wait(), term(), waits()}
        | {dropped, waits()} | unknown.
info({erx_fs_flush, {_, Alias} = Wait}, #waits{held = Held} = Waits) ->
    case Held of
        #{Alias := #held{wait = Wait, state = waiting}} ->
            {flushed, answer(Wait, {error, eintr}, Waits)};
        #{Alias := #held{wait = Wait, state = begun, request = Request} = Entry} ->
            Flushing = Entry#held{state = flushing},
            {begun, Wait, Request, Waits#waits{held = Held#{Alias := Flushing}}};
        #{} ->
            {flushed, Waits}
    end;
info({'DOWN', Monitor, process, Grant, _}, #waits{held = Held, grants = Grants} = Waits) ->
    case Grants of
        #{Grant := {Monitor, Aliases}} ->
            {dropped, Waits#waits{held = maps:without(maps:keys(Aliases), Held),
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

%% Forgets one held request, and releases its grant's monitor with the
%% grant's last request there.
forget({Grant, Alias}, #waits{held = Held, grants = Grants} = Waits) ->
    #{Grant := {Monitor, Aliases0}} = Grants,
    Aliases = maps:remove(Alias, Aliases0),
    Grants1 = case map_size(Aliases) of
                  0 ->
                      erlang:demonitor(Monitor, [flush]),
                      maps:remove(Grant, Grants);
                  _ ->
                      Grants#{Grant := {Monitor, Aliases}}
              end,
    Waits#waits{held = maps:remove(Alias, Held), grants = Grants1}.

%% A flushing request is begun to the keeper, which holds its flush.
shown(flushing) -> begun;
shown(State) -> State.
