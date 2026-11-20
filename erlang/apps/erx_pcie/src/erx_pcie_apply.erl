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

An access that answers `link_down` exits the caller with `link_down`,
since the PCIe domain's restart is the bridge's recovery; whatever part
of the plan was made, the next start decides from what it reads.

A driver is `{Module, State}`, an erx_pcie_bridge module and its state;
each call answers the driver's state after its accesses.
""".

-export([apply/3, start/3, quiet/2, snapshot/2]).
-export_type([driver/0, result/0]).

-include("generated/erx_abi.hrl").

-doc "A bridge driver: its erx_pcie_bridge module and its state.".
-type driver() :: {module(), term()}.

-doc "What applying a target or the descent to quiet answers.".
-type result() :: ok | {error, gone | stuck | erx_pcie_plan:reason()}.

-doc "Takes the function at Place to Target, a stage at a time, each confirmed by a readback.".
-spec apply(erx_pcie:place(), erx_pcie_plan:target(), driver()) -> {result(), driver()}.
apply(Place, Target, Driver) ->
    case read(Place, Driver) of
        {gone, Next} ->
            {{error, gone}, Next};
        {{ok, Read}, Next} ->
            case erx_pcie_plan:plan(Read, Target) of
                {ok, Stages} -> stages(Place, Stages, Next);
                {error, _} = Refused -> {Refused, Next}
            end
    end.

-doc """
The start's rule (docs/design-pcie.md, "The plan"): takes the function
at Place to Target when it reads as Target, and otherwise to the same
target in mode `off`; `true` beside the answer when the start kept it at
Target.
""".
-spec start(erx_pcie:place(), erx_pcie_plan:function_target(), driver()) -> {{result(), boolean()}, driver()}.
start(Place, Target, Driver) ->
    case read(Place, Driver) of
        {gone, Next} ->
            {{{error, gone}, false}, Next};
        {{ok, Read}, Next} ->
            Chosen = erx_pcie_plan:start_target(Read, Target),
            case erx_pcie_plan:plan(Read, Chosen) of
                {ok, Stages} ->
                    {Result, Applied} = stages(Place, Stages, Next),
                    {{Result, Result =:= ok andalso Chosen =:= Target}, Applied};
                {error, _} = Refused ->
                    {{Refused, false}, Next}
            end
    end.

-doc "Lowers the function at Place to quiet, every switch at its lowest, by the same rule.".
-spec quiet(erx_pcie:place(), driver()) -> {result(), driver()}.
quiet(Place, Driver) ->
    case read(Place, Driver) of
        {gone, Next} -> {{error, gone}, Next};
        {{ok, Read}, Next} -> descend(Place, Read, Next)
    end.

-doc "The function's 256-byte configuration snapshot, or `gone` when a read finds it absent.".
-spec snapshot(erx_pcie:place(), driver()) -> {{ok, binary()} | gone, driver()}.
snapshot(Place, Driver) ->
    words(Place, 0, Driver, []).

%% The plan's stages; a stage whose readback does not read as its state
%% ends the plan with the descent to quiet from that readback.
stages(Place, Stages, Driver) ->
    case run(Place, Stages, Driver) of
        {ok, Next} ->
            {ok, Next};
        {gone, Next} ->
            {{error, gone}, Next};
        {{differs, Field, Read}, Next} ->
            logger:warning("pcie: ~p: ~p did not take", [Place, Field]),
            case descend(Place, Read, Next) of
                {ok, Quiet} -> {{error, gone}, Quiet};
                Other -> Other
            end
    end.

%% The descent from Read: ok when the function then reads quiet, stuck
%% when a disable did not take, gone when the function went.
descend(Place, Read, Driver) ->
    {ok, Stages} = erx_pcie_plan:quiet(Read),
    case run(Place, Stages, Driver) of
        {ok, Next} ->
            {ok, Next};
        {gone, Next} ->
            {{error, gone}, Next};
        {{differs, Field, _Read}, Next} ->
            logger:warning("pcie: ~p: ~p did not lower; left as it reads", [Place, Field]),
            {{error, stuck}, Next}
    end.

%% Each stage in turn, until one does not take.
run(_Place, [], Driver) ->
    {ok, Driver};
run(Place, [#{writes := Writes, state := State} | Stages], Driver) ->
    case confirm(Place, Writes, State, Driver) of
        {taken, Next} -> run(Place, Stages, Next);
        Stopped -> Stopped
    end.

%% One stage: its writes, then the readback that confirms it.
confirm(Place, Writes, State, Driver) ->
    Written = lists:foldl(fun({Offset, Width, Value}, D) -> access({write, Place, Offset, Width, Value}, D) end,
                          Driver, Writes),
    case read(Place, Written) of
        {gone, Next} ->
            {gone, Next};
        {{ok, Read}, Next} ->
            case erx_pcie_plan:differs(Read, State) of
                none -> {taken, Next};
                identity -> {gone, Next};
                Field -> {{differs, Field, Read}, Next}
            end
    end.

%% The function's snapshot, parsed; one that is absent or does not parse is gone.
read(Place, Driver) ->
    case snapshot(Place, Driver) of
        {gone, Next} ->
            {gone, Next};
        {{ok, Snapshot}, Next} ->
            case erx_pcie_cfg:parse(Snapshot) of
                {ok, Read} -> {{ok, Read}, Next};
                {error, _} -> {gone, Next}
            end
    end.

words(_Place, ?ERX_PCIE_CONFIG_SIZE, Driver, Words) ->
    {{ok, << <<Word:32/little>> || Word <- lists:reverse(Words) >>}, Driver};
words(Place, Offset, {Module, State}, Words) ->
    case Module:access({read, Place, Offset, 4}, State) of
        {{ok, Word}, Next} -> words(Place, Offset + 4, {Module, Next}, [Word | Words]);
        {{error, absent}, Next} -> {gone, {Module, Next}};
        {{error, link_down}, _Next} -> exit(link_down)
    end.

access(Access, {Module, State}) ->
    case Module:access(Access, State) of
        {ok, Next} -> {Module, Next};
        {{error, absent}, Next} -> {Module, Next};
        {{error, link_down}, _Next} -> exit(link_down)
    end.
