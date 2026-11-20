%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_apply).
-moduledoc """
The effect layer of the planner (docs/design-pcie.md, "The plan",
"Applying a plan"): it reads a function's snapshot through its bridge
driver, plans with erx_pcie_plan, and makes each stage's writes, holding
to one rule: a stage is confirmed before the next begins. After a
stage's writes it reads the snapshot again, parses it, and goes on only
when the function reads as the stage's state, so a disable that did not
take is seen before any data moves under it, and data that did not take
before any switch is raised. It is the one caller of
erx_pcie_plan:plan/2.

The answers:

* `ok`: the function reads as its target, with no write when it already
  did;
* `{error, gone}`: a read found the function absent, unparsable or with
  another identity, and nothing more was written; or a stage did not
  take and the descent to quiet that followed it did;
* `{error, stuck}`: a stage did not take, and neither did the descent
  that followed it; the function is left as it reads, the field logged;
* `{error, route}` and `{error, reset}`: the planner's refusals, made
  before any write.

Each step that ends an operation early throws `{erx_pcie_apply, Reason,
Driver}`, with the driver's state its accesses left, and each exported
function catches it once (answered/1). An access that answers
`link_down` exits the caller with `link_down`, since the PCIe domain's
restart is the bridge's recovery; whatever part of the plan was made,
the next start decides from what it reads.

A driver is `{Module, State}`, an erx_pcie_bridge module and its state;
each call answers the driver's state after its accesses.
""".

-export([apply/3, start/3, quiet/2]).
-export_type([driver/0, result/0]).

-include("generated/erx_abi.hrl").

-doc "A bridge driver: its erx_pcie_bridge module and its state.".
-type driver() :: {module(), term()}.

-doc "What applying a target or the descent to quiet answers.".
-type result() :: ok | {error, gone | stuck | erx_pcie_plan:reason()}.

-doc "Takes the function at Place to Target, a stage at a time, each confirmed by a readback.".
-spec apply(erx_pcie:place(), erx_pcie_plan:target(), driver()) -> {result(), driver()}.
apply(Place, Target, Driver) ->
    answered(fun() ->
                     {Read, Next} = read(Place, Driver),
                     Stages = planned(erx_pcie_plan:plan(Read, Target), Next),
                     {ok, stages(Place, Stages, Next)}
             end).

-doc """
The start's rule (docs/design-pcie.md, "The plan"): takes the function
at Place to Target when it reads as Target, and otherwise to the same
target in mode `off`; `{ok, true}` when the start kept it at Target.
""".
-spec start(erx_pcie:place(), erx_pcie_plan:function_target(), driver()) ->
          {{ok, boolean()} | {error, gone | stuck | erx_pcie_plan:reason()}, driver()}.
start(Place, Target, Driver) ->
    answered(fun() ->
                     {Read, Next} = read(Place, Driver),
                     Chosen = erx_pcie_plan:start_target(Read, Target),
                     Stages = planned(erx_pcie_plan:plan(Read, Chosen), Next),
                     Started = stages(Place, Stages, Next),
                     {{ok, Chosen =:= Target}, Started}
             end).

-doc "Lowers the function at Place to quiet, every switch at its lowest, by the same rule.".
-spec quiet(erx_pcie:place(), driver()) -> {result(), driver()}.
quiet(Place, Driver) ->
    answered(fun() ->
                     {Read, Next} = read(Place, Driver),
                     {ok, descend(Place, Read, Next)}
             end).

%% The one route of a refusal: the operation's answer and the driver's state.
answered(Operation) ->
    try
        Operation()
    catch
        throw:{?MODULE, Reason, Driver} -> {{error, Reason}, Driver}
    end.

planned({ok, Stages}, _Driver) -> Stages;
planned({error, Reason}, Driver) -> throw({?MODULE, Reason, Driver}).

%% The plan's stages; a stage whose readback does not read as its state
%% ends the plan with the descent to quiet from that readback, which
%% answers gone when it takes.
stages(Place, Stages, Driver) ->
    case run(Place, Stages, Driver) of
        {taken, Next} ->
            Next;
        {{differs, Field, Read}, Next} ->
            logger:warning("pcie: ~p: ~p did not take", [Place, Field]),
            throw({?MODULE, gone, descend(Place, Read, Next)})
    end.

%% The descent from Read: the driver when the function then reads quiet,
%% stuck when a disable did not take.
descend(Place, Read, Driver) ->
    {ok, Stages} = erx_pcie_plan:quiet(Read),
    case run(Place, Stages, Driver) of
        {taken, Next} ->
            Next;
        {{differs, Field, _Read}, Next} ->
            logger:warning("pcie: ~p: ~p did not lower; left as it reads", [Place, Field]),
            throw({?MODULE, stuck, Next})
    end.

%% Each stage in turn, its writes and then the readback that confirms
%% it, until one does not take; a readback with another identity is gone.
run(_Place, [], Driver) ->
    {taken, Driver};
run(Place, [#{writes := Writes, state := State} | Stages], Driver) ->
    Written = lists:foldl(fun({Offset, Width, Value}, D) -> write(Place, Offset, Width, Value, D) end,
                          Driver, Writes),
    {Read, Next} = read(Place, Written),
    case erx_pcie_plan:differs(Read, State) of
        none -> run(Place, Stages, Next);
        identity -> throw({?MODULE, gone, Next});
        Field -> {{differs, Field, Read}, Next}
    end.

%% The function's 256-byte snapshot, parsed; one that is absent or does
%% not parse is gone.
read(Place, Driver) ->
    {Snapshot, Next} = words(Place, 0, Driver, []),
    case erx_pcie_cfg:parse(Snapshot) of
        {ok, Read} -> {Read, Next};
        {error, _} -> throw({?MODULE, gone, Next})
    end.

words(_Place, ?ERX_PCIE_CONFIG_SIZE, Driver, Words) ->
    {<< <<Word:32/little>> || Word <- lists:reverse(Words) >>, Driver};
words(Place, Offset, {Module, State}, Words) ->
    case Module:access({read, Place, Offset, 4}, State) of
        {{ok, Word}, Next} -> words(Place, Offset + 4, {Module, Next}, [Word | Words]);
        {{error, absent}, Next} -> throw({?MODULE, gone, {Module, Next}});
        {{error, link_down}, _Next} -> exit(link_down)
    end.

%% A write to an absent function is dropped; the readback that follows
%% finds it gone.
write(Place, Offset, Width, Value, {Module, State}) ->
    case Module:access({write, Place, Offset, Width, Value}, State) of
        {ok, Next} -> {Module, Next};
        {{error, absent}, Next} -> {Module, Next};
        {{error, link_down}, _Next} -> exit(link_down)
    end.
