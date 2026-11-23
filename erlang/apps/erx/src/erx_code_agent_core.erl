%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_agent_core).

-moduledoc """
The decisions of a domain's code server, erx_code_agent (docs/design-live.md, "The code
server"), as a pure state machine: `step/2` takes the core and one event and returns the
next core and the effects to apply, in order. The server process applies them and feeds
back what they produce; nothing here reads the runtime, a clock or a mailbox.

The server takes one load at a time, in four steps, all before the load's deadline:

1. Plan. The server's edge marks each module of the manifest `current` (its current
   code already has the hash), `{release, Bytes}` (its release lists the hash) or
   `fetch`, and hands the plan over with `{take, Alias, Plan, Deadline}`. Current modules
   stay out of the batch.
2. Fetch. Blob after blob in manifest order, piece after piece from offset 0, asking
   for the next piece only once the previous one arrived, so `erx_code` never has more
   than one piece queued here. A blob whose bytes, once `Size` have arrived, are not
   `Size` long or do not hash to `Hash` answers `{error, {hash_mismatch, Name}}` and
   loads nothing; a release's bytes are checked the same way.
3. Load. The whole batch, through `{load_batch, Batch}`, whose result comes back as
   `{loaded, Result}` and is the answer.
4. Keep, in a supervised domain after `ok` only: the server waits for the word of
   publication, `{published, Alias, Lifeline}`. When it comes the load is done, and if
   the manifest named any module the server monitors the lifeline, once for the domain's
   life, and exits `{erx_code, down}` when it ends. If the deadline comes first the
   server exits `{erx_code, unpublished}`. A refusal loaded nothing, and a domain no
   specification restarts has no overlay to keep in step with, so either is done at its
   answer.

A deadline before the batch is loaded abandons the load: no answer, no bytes kept, and
`erx_code`, whose own deadline started earlier, has already ended it.

In a supervised domain the first load is the start load and the server has not yet
returned from its start: the start load's confirmation is `started`, and a refusal of it
ends the server, and so the domain, with `{start_load, Result}`. A start load abandoned
at its deadline leaves the server waiting, as one that never came does, for the
domain's boot timeout. Any other domain is `started` at once.

Messages from `erx_code` are the trusted base's; the core takes a piece or a word of
publication only for the load in flight, at the cursor, and reports any other as
`dropped`, which the edge counts.
""".

-export([new/1, step/2, idle/1, deadline/1, lifeline/1, monitoring/2, floor_check/2]).
-export_type([core/0, event/0, effect/0, plan/0, limits/0]).

-type name() :: binary().
-type hash() :: <<_:256>>.
-type source() :: current | {release, binary()} | fetch.
-doc "The manifest in order, each module marked by where its bytes come from.".
-type plan() :: [{name(), hash(), pos_integer(), source()}].

-type event() :: {take, reference(), plan(), integer()}
               | {piece, reference(), hash(), non_neg_integer(), binary()}
               | {loaded, erx_code_batch:result()}
               | {published, reference(), pid()}
               | timeout
               | {down, reference()}.

-type effect() :: {send, reference(), term()}
                | {load_batch, [erx_code_batch:module_bytes()]}
                | {monitor, pid()}
                | started
                | dropped
                | {exit, term()}.

%% A load in flight: its alias and deadline, whether its manifest named any module, the
%% blobs still to fetch in manifest order, the one being fetched with its pieces so far
%% (newest first) and its next offset, and the batch, in manifest order, newest first.
-record(load, {alias :: reference(),
               deadline :: integer(),
               named :: boolean(),
               queue = [] :: [{name(), hash(), pos_integer()}],
               fetching = none :: none | {name(), hash(), pos_integer(), non_neg_integer(), [binary()]},
               batch = [] :: [erx_code_batch:module_bytes()],
               step = fetch :: fetch | load | keep}).

%% supervised: the domain's boot information's flag; phase: start until the server has
%% returned from its start; lifeline: the monitor on erx_code's lifeline, once taken.
-record(core, {supervised :: boolean(),
               phase :: start | running,
               load = none :: none | #load{},
               lifeline = none :: none | reference()}).

-opaque core() :: #core{}.

-doc """
The limits the funnel applies to a frame into this runtime, as `erx:limits/0` reports
them, or `unknown` where this runtime cannot read them.
""".
-type limits() :: #{max_frame := non_neg_integer(), max_message_heap := non_neg_integer(),
                    funnel_depth := non_neg_integer(), atom() => term()}
                | unknown.

-doc """
A server of a domain whose boot information carries `supervised`, or not, and the effects
of its start: a supervised one waits for its start load, any other is started at once.
""".
-spec new(boolean()) -> {core(), [effect()]}.
new(true) -> {#core{supervised = true, phase = start}, []};
new(false) -> {#core{supervised = false, phase = running}, [started]}.

-doc "Whether the server can take a load: none is in flight.".
-spec idle(core()) -> boolean().
idle(#core{load = Load}) -> Load =:= none.

-doc "The monotonic millisecond by which the load in flight must be done, or `infinity`.".
-spec deadline(core()) -> integer() | infinity.
deadline(#core{load = none}) -> infinity;
deadline(#core{load = #load{deadline = Deadline}}) -> Deadline.

-doc "The monitor on erx_code's lifeline, or `none` before the first published module.".
-spec lifeline(core()) -> reference() | none.
lifeline(#core{lifeline = Lifeline}) -> Lifeline.

-doc "Records the monitor the edge took for a `{monitor, Lifeline}` effect.".
-spec monitoring(core(), reference()) -> core().
monitoring(#core{lifeline = none} = Core, Monitor) -> Core#core{lifeline = Monitor}.

-doc """
Compares the runtime's limits with the code protocol's floors into a domain: `ok`, the
first limit below its floor with its value, or `unknown` when the runtime cannot report
its limits. Floors names each limit the protocol sets a floor on.
""".
-spec floor_check(limits(), #{atom() => non_neg_integer()}) ->
          ok | unknown | {below, atom(), non_neg_integer(), non_neg_integer()}.
floor_check(unknown, _Floors) ->
    unknown;
floor_check(Limits, Floors) ->
    Below = [{below, Limit, maps:get(Limit, Limits), Floor}
             || Limit := Floor <- maps:iterator(Floors, ordered), maps:get(Limit, Limits) < Floor],
    case Below of
        [] -> ok;
        [First | _] -> First
    end.

-doc "The next core and the effects of one event.".
-spec step(core(), event()) -> {core(), [effect()]}.
step(#core{load = none} = Core, {take, Alias, Plan, Deadline}) ->
    plan(Core, Alias, Plan, Deadline);
step(#core{load = #load{alias = Alias, step = fetch,
                        fetching = {Name, Hash, Size, Offset, Pieces}} = Load} = Core,
     {piece, Alias, Hash, Offset, Bytes}) ->
    Got = Offset + byte_size(Bytes),
    case Got >= Size of
        true -> blob(Core, Load#load{fetching = none}, Name, Hash, Size,
                     iolist_to_binary(lists:reverse([Bytes | Pieces])));
        false -> {Core#core{load = Load#load{fetching = {Name, Hash, Size, Got, [Bytes | Pieces]}}},
                  [{send, Alias, {erx_code_get, Alias, Hash, Got}}]}
    end;
step(#core{load = #load{step = load} = Load} = Core, {loaded, Result}) ->
    answered(Core, Load, Result);
step(#core{load = #load{alias = Alias, step = keep, named = Named}} = Core, {published, Alias, Lifeline}) ->
    Monitor = [{monitor, Lifeline} || Named, Core#core.lifeline =:= none],
    done(Core, Monitor);
step(#core{load = #load{step = keep}}, timeout) ->
    {exit_core(), [{exit, {erx_code, unpublished}}]};
step(#core{load = #load{}} = Core, timeout) ->
    %% Abandoned before its batch loaded: no answer, no bytes kept.
    {Core#core{load = none}, []};
step(#core{lifeline = Monitor}, {down, Monitor}) when is_reference(Monitor) ->
    {exit_core(), [{exit, {erx_code, down}}]};
step(Core, _Event) ->
    {Core, [dropped]}.

%% Step 1: current modules stay out; a release's bytes join the batch once checked; the
%% rest are fetched in manifest order.
plan(Core, Alias, Plan, Deadline) ->
    Load = #load{alias = Alias, deadline = Deadline, named = Plan =/= []},
    try lists:foldl(fun planned/2, Load, Plan) of
        Planned -> next_blob(Core, Planned#load{queue = lists:reverse(Planned#load.queue)})
    catch
        throw:{hash_mismatch, Name} -> answered(Core, Load, {error, {hash_mismatch, Name}})
    end.

planned({_Name, _Hash, _Size, current}, Load) ->
    Load;
planned({Name, Hash, Size, {release, Bytes}}, #load{batch = Batch} = Load) ->
    case checked(Hash, Size, Bytes) of
        true -> Load#load{batch = [{Name, Hash, Bytes} | Batch]};
        false -> throw({hash_mismatch, Name})
    end;
planned({Name, Hash, Size, fetch}, #load{queue = Queue, batch = Batch} = Load) ->
    %% A placeholder holds the blob's place in the batch until its bytes arrive.
    Load#load{queue = [{Name, Hash, Size} | Queue], batch = [{Name, Hash, fetch} | Batch]}.

%% Step 2: ask for the next blob's first piece, or load the batch once every blob is in.
next_blob(Core, #load{queue = [{Name, Hash, Size} | Rest], alias = Alias} = Load) ->
    {Core#core{load = Load#load{queue = Rest, fetching = {Name, Hash, Size, 0, []}}},
     [{send, Alias, {erx_code_get, Alias, Hash, 0}}]};
next_blob(Core, #load{queue = [], batch = Batch} = Load) ->
    {Core#core{load = Load#load{step = load}}, [{load_batch, lists:reverse(Batch)}]}.

blob(Core, Load, Name, Hash, Size, Bytes) ->
    case checked(Hash, Size, Bytes) of
        true -> next_blob(Core, Load#load{batch = arrived(Name, Hash, Bytes, Load#load.batch)});
        false -> answered(Core, Load, {error, {hash_mismatch, Name}})
    end.

arrived(Name, Hash, Bytes, Batch) ->
    lists:keyreplace(Name, 1, Batch, {Name, Hash, Bytes}).

checked(Hash, Size, Bytes) ->
    byte_size(Bytes) =:= Size andalso erx_bytes:sha256(Bytes) =:= Hash.

%% Step 3's answer, and step 4's start in a supervised domain after ok.
answered(#core{supervised = true} = Core, #load{alias = Alias} = Load, ok) ->
    {Core#core{load = Load#load{step = keep, queue = [], batch = []}},
     [{send, Alias, {erx_code_loaded, Alias, ok}}]};
answered(#core{phase = start}, #load{alias = Alias}, Error) when Error =/= ok ->
    {exit_core(), [{send, Alias, {erx_code_loaded, Alias, Error}}, {exit, {start_load, Error}}]};
answered(Core, #load{alias = Alias}, Result) ->
    done(Core, [{send, Alias, {erx_code_loaded, Alias, Result}}]).

done(#core{phase = start} = Core, Effects) ->
    {Core#core{load = none, phase = running}, Effects ++ [started]};
done(Core, Effects) ->
    {Core#core{load = none}, Effects}.

%% The core after an exit effect, which the edge never steps again.
exit_core() ->
    #core{supervised = false, phase = running}.
