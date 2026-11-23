%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_target).
-moduledoc """
The code service's state for one target, as a pure state machine (docs/design-live.md,
"The code server", "`erx_code`'s side"). A target is a supervised specification, whose
domains follow one another, or a domain no specification restarts. Each function takes
the target's state and one event and returns the next state and the actions erx_code,
the effect layer, performs in order. The core reads no clock, makes no alias, sends
nothing and calls no service.

**What it holds.** The target's **current domain**, the last one whose code server became
current, with its phase:

* `starting`: its start load is in flight;
* `{confirmed, Revision}`: its runtime reported its start load, of that overlay revision,
  loaded and was told it was taken; `{confirmed, unknown}` for a domain this incarnation
  of erx_code takes as current at its first load, never having sent it a start load;
* `closed`: its start load failed, or a reset stopped it, so it takes no load.

At most one **load** in flight, tied to the one domain its request resolved to. And, for
a supervised specification, its **published overlay**: the modules loaded into its domains
from outside, with the revision of its last publication. A target holds no release: its
specification boots one release while erx_code holds it (docs/design-live.md, "Targets").
Revision 0 is the empty overlay a specification starts with.

**Events.**

* `load/4`, a facet's load into a domain of the target, as the domain service resolved it.
  It is refused `busy` while a load is in flight, when the domain has not reported ready
  with a code server, and when it is not the current domain or the current domain takes
  no load. Then come erx_code's two verdicts, pure functions of its store: the plan's
  `missing` blobs, which neither the store nor the release holds, and, for a supervised
  target, after the candidate overlay (the published overlay with the load's modules over
  it, refused `overlay_full` past the specification's `overlay` limit, which the request
  carries from the domain service's resolution, or `code_modules_max`
  modules), the charge, `no_memory` when the principal's hot store cannot keep the
  candidate's blobs. The first refusal in the order busy, missing, overlay_full,
  no_memory is the answer.
* `started/4`, the domain service's word, `erx_code:started(Id, Target, DomainPid,
  Agent)`, that a domain of a supervised specification has a code server. A repeated
  word for the current domain changes nothing. For another domain it ends a load in
  flight to the last domain with `domain_ended` and sends the start load: the published
  overlay.
* `reset/3`, the operator's way back to the release: the empty overlay published and the
  specification's live domain stopped by its id.
* `received/3`, a message from a domain's code server to the in-flight load's alias, the
  one untrusted input of the protocol: a request for the load's next piece, or the
  load's answer. A message in the envelope of another domain, or naming another alias,
  changes nothing; any other message from the load's domain that names its alias ends
  the load as `invalid`. A message that names no alias, as `alias/1` reads it, cannot be
  told apart from one sent to any other alias, so erx_code hands it to no target, and the
  load's deadline still bounds it.
* `deadline/2` and `domain_down/2`, the load's 30 s timer (`code_load_wait`) and the
  domain pid's `'DOWN'`, end the load as `timeout` and `domain_ended`.

A load serves only the bytes erx_code holds: each event that sends a load is handed the
stored size of each blob of it the store holds, and a piece is cut to that size, never
to the manifest's `Size`. A piece request past a blob's stored end, which is what an
overstated `Size` leads a code server to ask for, or for a blob the store does not
hold, such as one only the release holds, ends the load as `invalid`.

A load ends at its answer, at its domain's end, at its deadline or as `invalid`, exactly
once, and every end retires its alias. Only an `ok` answer publishes: a facet's candidate
then becomes the overlay with a new revision, and a supervised domain is told so with
`{erx_code_published, Alias, Lifeline}`. A failed start load leaves the overlay as it
was and closes its domain: a closed domain, and a domain other than the current one
once the current one is known, take no facet's load, which is refused `busy` even when
the domain service reports it ready.

**Actions**, which erx_code performs in order:

* `{reply, From, Reply}`: answer a facet's load or reset;
* `{send, Agent, Message}`: send a load or a word of publication to a code server;
* `{serve, Agent, Alias, Hash, Offset, Length}`: send the code server
  `{erx_code_piece, Alias, Hash, Offset, Bytes}`, those bytes of the stored blob;
* `{begin_load, Alias, DomainPid, Hashes}`: monitor the domain pid, start the alias's
  `code_load_wait` timer, and keep every blob of `Hashes` in the store until the load
  ends;
* `{end_load, Alias}`: deactivate the alias, cancel its timer, remove the domain pid's
  monitor and let go of the load's blobs;
* `{unalias, Alias}`: deactivate an alias an event was handed but no load took;
* `{stop_domain, DomainId}`: stop that domain through the domain service;
* `{log, Record}`: write one log record naming the target.
""".

-export([new/1, load/4, started/4, reset/3, received/3, deadline/2, domain_down/2]).

-export([candidate/2, overlay/1, current/1, in_flight/1, alias/1]).
-export_type([state/0, action/0, domain/0, manifest/0, overlay/0]).

-include("generated/erx_abi.hrl").

-type hash() :: <<_:256>>.
-type name() :: binary().
-type domain_id() :: non_neg_integer().
-type revision() :: non_neg_integer().
-type manifest() :: [{name(), hash(), pos_integer()}].
-type from() :: term().
-type load_reply() :: {ok, revision() | none} | {error, term()}.
%% The stored size of each blob of a load that erx_code's store holds.
-type stored() :: #{hash() => pos_integer()}.

-doc """
A domain as the domain service reports it: for a load, the resolution of its request;
for `started/4`, the domain whose code server reported (`ready` is then irrelevant).
""".
-type domain() :: #{id := domain_id(), pid := pid(), agent := pid() | none, ready := boolean()}.

-type overlay() :: {revision(), manifest()}.

-type action() :: {reply, from(), load_reply()}
                | {send, pid(), {erx_code_load, reference(), manifest()}
                                | {erx_code_published, reference(), pid()}}
                | {serve, pid(), reference(), hash(), non_neg_integer(), pos_integer()}
                | {begin_load, reference(), pid(), [hash()]}
                | {end_load, reference()}
                | {unalias, reference()}
                | {stop_domain, domain_id()}
                | {log, {start_load_failed, revision(), term()}}.

%% The published overlay: its revision and its modules.
-record(overlay, {revision = 0 :: revision(), modules = [] :: manifest()}).

%% Where a load's pieces stand: the blob being fetched with its size and the offset of its
%% next piece (none before the first), and the manifest entries after it, any of which the
%% code server may fetch next once that blob is complete. A blob's size is its stored size.
-record(cursor, {blob = none :: none | {hash(), pos_integer(), non_neg_integer()},
                 rest :: manifest()}).

%% The load in flight. Its kind says who waits on it: a facet's load, with the candidate
%% overlay a supervised target publishes on its ok (none for a domain no specification
%% restarts), or a start load, with the revision it carries.
-record(load, {alias :: reference(), domain :: domain_id(), agent :: pid(),
               kind :: {facet, from(), #overlay{} | none} | {start, revision()},
               manifest :: manifest(), stored :: stored(), cursor :: #cursor{}}).

-record(target, {lifeline :: pid(),
                 overlay :: #overlay{} | none,
                 current = none :: none | {domain_id(), starting | {confirmed, revision() | unknown}
                                                       | closed},
                 load = none :: none | #load{}}).

-opaque state() :: #target{}.

-doc """
A target's first state. `supervised` is true for a supervised specification's target,
whose domains carry the `supervised` flag in their boot information and so start with
its published overlay, and false for a domain no specification restarts, which has no
overlay. `Lifeline` is erx_code's lifeline, the process a code server monitors once it
keeps published code.
""".
-spec new(#{lifeline := pid(), supervised := boolean()}) -> state().
new(#{lifeline := Lifeline, supervised := true}) ->
    #target{lifeline = Lifeline, overlay = #overlay{}};
new(#{lifeline := Lifeline, supervised := false}) ->
    #target{lifeline = Lifeline, overlay = none}.

-doc """
A facet's load into `Domain`, with `Alias`, an alias erx_code made for it, and erx_code's
two verdicts. The plan: `Missing`, the hashes of the manifest that neither the store nor
the domain's release holds, and `Stored`, the stored size of each blob of the manifest
the store holds. The charge: `no_memory` when the principal's hot store cannot keep the
blobs of a supervised target's candidate overlay, else `ok`. `overlay_limit` is the
specification's `overlay` limit in bytes, from the domain service's resolution. A domain
no specification restarts has no candidate, and neither its charge nor its limit is read.
""".
-spec load(from(), reference(), #{domain := domain(), manifest := manifest(),
                                  missing := [hash()], stored := stored(),
                                  charge := ok | no_memory,
                                  overlay_limit := non_neg_integer()}, state()) ->
          {state(), [action()]}.
load(From, Alias, #{domain := Domain, manifest := Manifest, stored := Stored} = Request, T) ->
    case admit(Request, T) of
        {ok, Candidate} ->
            #{id := Id, pid := Pid, agent := Agent} = Domain,
            Current = case T#target.current of
                          none -> {Id, {confirmed, unknown}};
                          Held -> Held
                      end,
            send_load(Alias, Id, Pid, Agent, {facet, From, Candidate}, {Manifest, Stored},
                      T#target{current = Current});
        {error, Why} ->
            {T, [{unalias, Alias}, {reply, From, {error, Why}}]}
    end.

%% Every refusal of a facet's load, in the design's order (busy, missing, overlay_full,
%% no_memory), or the candidate overlay a supervised target publishes on the load's ok.
admit(_, #target{load = #load{}}) ->
    {error, busy};
admit(#{domain := #{ready := false}}, _) ->
    {error, busy};
admit(#{domain := #{agent := none}}, _) ->
    {error, busy};
admit(#{domain := #{id := Id}, manifest := Manifest, missing := Missing, charge := Charge,
        overlay_limit := Limit}, #target{current = Current, overlay = Overlay} = T) ->
    Takes = case Current of
                none -> true;
                {Id, {confirmed, _}} -> true;
                _ -> false
            end,
    Modules = candidate(Manifest, T),
    if
        not Takes -> {error, busy};
        Missing =/= [] -> {error, {missing, Missing}};
        Modules =:= none -> {ok, none};
        true -> charged(Modules, Limit, Charge, Overlay#overlay{modules = Modules})
    end.

charged(Modules, Limit, Charge, Candidate) ->
    Bytes = lists:sum([Size || {_, _, Size} <- Modules]),
    Full = Bytes > Limit orelse length(Modules) > ?ERX_CODE_MODULES_MAX,
    if
        Full -> {error, overlay_full};
        Charge =:= no_memory -> {error, no_memory};
        true -> {ok, Candidate}
    end.

-doc """
The modules of the candidate overlay a facet's load of `Manifest` forms: the published
overlay with the load's modules over it, or `none` for a domain no specification
restarts, which has no overlay. erx_code computes the charge over these modules' blobs,
and `load/4` publishes them on the load's `ok`, so both use this one computation.
""".
-spec candidate(manifest(), state()) -> manifest() | none.
candidate(_, #target{overlay = none}) ->
    none;
candidate(Manifest, #target{overlay = #overlay{modules = Published}}) ->
    Loaded = [Name || {Name, _, _} <- Manifest],
    [Entry || {Name, _, _} = Entry <- Published, not lists:member(Name, Loaded)] ++ Manifest.

-doc """
The domain service's word that `Domain` of the specification has a code server: the
start of the specification's next domain, which ends a load in flight to the last one,
and its start load, sent with `Alias`; `Stored` is the stored size of each blob of the
published overlay the store holds. A repeated word for the current domain changes
nothing. Only a supervised target has domains that start: a domain no specification
restarts has no overlay and no start load, and this function has no clause for it.
""".
-spec started(reference(), domain(), stored(), state()) -> {state(), [action()]}.
started(Alias, #{id := Id}, _, #target{current = {Id, _}} = T) ->
    {T, [{unalias, Alias}]};
started(Alias, #{id := Id, pid := Pid, agent := Agent}, Stored, #target{overlay = #overlay{}} = T0) ->
    {T1, Ended} = end_load({error, domain_ended}, T0),
    #overlay{revision = Revision, modules = Modules} = T1#target.overlay,
    {T2, Sent} = send_load(Alias, Id, Pid, Agent, {start, Revision}, {Modules, Stored},
                           T1#target{current = {Id, starting}}),
    {T2, Ended ++ Sent}.

send_load(Alias, Id, Pid, Agent, Kind, {Manifest, Stored}, T) ->
    Load = #load{alias = Alias, domain = Id, agent = Agent, kind = Kind, manifest = Manifest,
                 stored = Stored, cursor = #cursor{rest = Manifest}},
    {T#target{load = Load},
     [{begin_load, Alias, Pid, [Hash || {_, Hash, _} <- Manifest]},
      {send, Agent, {erx_code_load, Alias, Manifest}}]}.

-doc """
A reset of the specification: the empty overlay published, and `Live`, the
specification's live domain as the domain service resolved it, stopped by its id.
""".
-spec reset(from(), domain_id() | none, state()) -> {state(), [action()]}.
reset(From, _, #target{overlay = none} = T) ->
    {T, [{reply, From, {error, no_overlay}}]};
reset(From, _, #target{load = #load{}} = T) ->
    {T, [{reply, From, {error, busy}}]};
reset(From, Live, #target{overlay = #overlay{revision = Revision}} = T) ->
    Published = Revision + 1,
    {Current, Stop} = case {Live, T#target.current} of
                          {none, Held} -> {Held, []};
                          {Live, {Live, _}} -> {{Live, closed}, [{stop_domain, Live}]};
                          {Live, Held} -> {Held, [{stop_domain, Live}]}
                      end,
    {T#target{overlay = #overlay{revision = Published}, current = Current},
     Stop ++ [{reply, From, {ok, Published}}]}.

-doc """
The routing key of a message a code server sent to an alias of erx_code: the alias it
names, so erx_code hands it to the target whose load holds that alias. A message that
names none reaches no target.
""".
-spec alias(term()) -> {ok, reference()} | error.
alias(Message) when tuple_size(Message) >= 2, is_reference(element(2, Message)) ->
    {ok, element(2, Message)};
alias(_) ->
    error.

-doc """
`Message`, which arrived in the envelope of domain `Origin`: a piece request or an
answer of the load in flight, read here and nowhere else.
""".
-spec received(domain_id(), term(), state()) -> {state(), [action()]}.
received(Origin, Message, #target{load = #load{alias = Alias, domain = Origin} = Load} = T)
  when tuple_size(Message) >= 2, element(2, Message) =:= Alias ->
    try read(Message, Load) of
        {piece, Hash, Offset, Length, Cursor} ->
            {T#target{load = Load#load{cursor = Cursor}},
             [{serve, Load#load.agent, Alias, Hash, Offset, Length}]};
        {answer, Result} ->
            end_load(Result, T)
    catch
        throw:invalid -> end_load({error, invalid}, T)
    end;
received(_, _, T) ->
    {T, []}.

%% The one reader of a code server's message to the load's alias. It throws invalid for
%% anything the protocol does not allow at this point of the load.
read({erx_code_get, _, Hash, Offset}, #load{} = Load) ->
    next_piece(Hash, Offset, Load);
read({erx_code_loaded, _, ok}, _) ->
    {answer, ok};
read({erx_code_loaded, _, {error, {hash_mismatch, Name}} = Result}, #load{manifest = Manifest}) ->
    named(Name, Manifest),
    {answer, Result};
read({erx_code_loaded, _, {error, {not_loaded, [_ | _] = Failed}} = Result},
     #load{manifest = Manifest}) ->
    refusals(Failed, length(Manifest), Manifest),
    {answer, Result};
read(_, _) ->
    throw(invalid).

%% A request is valid only for the next piece in manifest order: the next offset of the
%% blob being fetched, or offset 0 of a later blob once that one is complete. Serving
%% only that piece serves each piece of a load at most once.
next_piece(Hash, Offset, #load{cursor = #cursor{blob = {Hash, Size, Offset}} = Cursor})
  when Offset < Size ->
    piece(Hash, Size, Offset, Cursor);
next_piece(Hash, 0, #load{cursor = #cursor{blob = Blob, rest = Rest}, stored = Stored}) ->
    case Blob of
        {_, Whole, Whole} -> ok;
        none -> ok;
        _ -> throw(invalid)
    end,
    case lists:dropwhile(fun({_, Listed, _}) -> Listed =/= Hash end, Rest) of
        [{_, Hash, _} | Later] -> piece(Hash, stored_size(Hash, Stored), 0, #cursor{rest = Later});
        [] -> throw(invalid)
    end;
next_piece(_, _, _) ->
    throw(invalid).

stored_size(Hash, Stored) ->
    case Stored of
        #{Hash := Size} -> Size;
        #{} -> throw(invalid)
    end.

piece(Hash, Size, Offset, Cursor) ->
    Length = min(?ERX_CODE_PIECE_MAX, Size - Offset),
    {piece, Hash, Offset, Length, Cursor#cursor{blob = {Hash, Size, Offset + Length}}}.

%% A refusal names only modules of the manifest, each with a reason of
%% code_load_reason, the closed set the answer floors count, and so no more of them
%% than the manifest has; Left bounds the walk, so a long list costs no more than
%% the manifest, and an improper one is refused.
refusals([], _, _) ->
    ok;
refusals([{Name, What} | Failed], Left, Manifest)
  when Left > 0, ?ERX_IS_CODE_LOAD_REASON(What) ->
    named(Name, Manifest),
    refusals(Failed, Left - 1, Manifest);
refusals(_, _, _) ->
    throw(invalid).

named(Name, Manifest) ->
    case lists:keymember(Name, 1, Manifest) of
        true -> ok;
        false -> throw(invalid)
    end.

-doc "The 30 s of the load with `Alias` have passed.".
-spec deadline(reference(), state()) -> {state(), [action()]}.
deadline(Alias, #target{load = #load{alias = Alias}} = T) ->
    end_load({error, timeout}, T);
deadline(_, T) ->
    {T, []}.

-doc "The domain pid of the load with `Alias` has ended.".
-spec domain_down(reference(), state()) -> {state(), [action()]}.
domain_down(Alias, #target{load = #load{alias = Alias}} = T) ->
    end_load({error, domain_ended}, T);
domain_down(_, T) ->
    {T, []}.

%% The one end of a load: its alias retired, then what its outcome means for its kind.
end_load(_, #target{load = none} = T) ->
    {T, []};
end_load(Outcome, #target{load = #load{alias = Alias} = Load} = T0) ->
    T = T0#target{load = none},
    {Next, Actions} = outcome(Outcome, Load, T),
    {Next, [{end_load, Alias} | Actions]}.

outcome(ok, #load{alias = Alias, agent = Agent, kind = {facet, From, #overlay{} = Candidate}},
        #target{overlay = #overlay{revision = Revision}} = T) ->
    Published = Revision + 1,
    {T#target{overlay = Candidate#overlay{revision = Published}},
     [{send, Agent, {erx_code_published, Alias, T#target.lifeline}},
      {reply, From, {ok, Published}}]};
outcome(ok, #load{kind = {facet, From, none}}, T) ->
    {T, [{reply, From, {ok, none}}]};
outcome(ok, #load{alias = Alias, agent = Agent, domain = Id, kind = {start, Revision}}, T) ->
    {T#target{current = {Id, {confirmed, Revision}}},
     [{send, Agent, {erx_code_published, Alias, T#target.lifeline}}]};
outcome({error, _} = Error, #load{kind = {facet, From, _}}, T) ->
    {T, [{reply, From, Error}]};
outcome({error, domain_ended}, #load{domain = Id, kind = {start, _}}, T) ->
    %% The domain has gone; its own end is logged with its reason.
    {T#target{current = {Id, closed}}, []};
outcome(Error, #load{domain = Id, kind = {start, Revision}}, T) ->
    {T#target{current = {Id, closed}}, [{log, {start_load_failed, Revision, Error}}]}.

-doc "The published overlay, or `none` for a domain no specification restarts.".
-spec overlay(state()) -> overlay() | none.
overlay(#target{overlay = none}) -> none;
overlay(#target{overlay = #overlay{revision = Revision, modules = Modules}}) -> {Revision, Modules}.

-doc "The current domain and its phase.".
-spec current(state()) ->
          none | {domain_id(), starting | {confirmed, revision() | unknown} | closed}.
current(#target{current = Current}) -> Current.

-doc "The load in flight: its alias and the domain it was sent to.".
-spec in_flight(state()) -> none | {reference(), domain_id()}.
in_flight(#target{load = none}) -> none;
in_flight(#target{load = #load{alias = Alias, domain = Id}}) -> {Alias, Id}.
