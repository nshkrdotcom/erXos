%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_walk).
-moduledoc """
The walk of one host bridge (docs/design-pcie.md, "The walk", "Sizing"
and "Root ports") as a pure state machine: each step takes the answer to
the last action and returns the next one, so the enumerator makes every
access and this module decides each from what the last ones answered.

From the bridge's first bus, the root bus, each device's function 0 is
probed for its vendor and header type; absent ends the device, and the
multifunction bit adds functions 1 to 7. Each function is then read
whole, its 256-byte snapshot. A header type the walk does not take
(above 1) is reported `unsupported` from its identity alone, without
parse/1; a snapshot parse/1 refuses is reported `malformed`, with the
field, and gets one write, its command register with memory, I/O and bus
master off and INTx disabled. A type-1 header on the root bus is a root
port: it takes the next bus number in place order as its secondary and
subordinate bus, the action `{root_port, ...}` asks the enumerator to
apply its target, and once that answers `ok` the devices of the bus
below it are probed. A type-1 header below a root port is `unsupported`,
and nothing below it is read.

A placing walk, the one that finds no layouts for its bridge, also sizes
every function's memory BARs and every root port's BARs as FreeBSD's
pci_read_bar does: memory and I/O decoding off, all ones to the BAR (both
halves of a 64-bit BAR before either is read back), the original value
restored, then the command register. A root port whose BAR reads back
nonzero is `unsupported`, with nothing below it read; it is sized before
it is numbered.

Nothing recurses and the topology has two levels, so a walk makes a
bounded number of accesses: at most 32 devices of 8 functions on the
root bus and on each root port's bus, each read once and sized once.
At most `pcie_functions_max` functions are reported; a present function
past the bound is listed in `past_bound` and left as it is. A read that
answers `absent` part way through a function's accesses means the
function is gone, and it is not listed. An answer of `link_down` stops
the walk at once, since its domain's restart is the bridge's recovery.
""".

-export([start/2, step/2]).
-export_type([walk/0, kind/0, action/0, answer/0, buses/0, found/0, outcome/0,
              root_port/0, result/0]).

-include("generated/erx_abi.hrl").

-doc "A placing walk sizes; a later walk does not.".
-type kind() :: placing | later.

-doc "Where a function was found: on the root bus, or below the root port at a place.".
-type parent() :: root | erx_pcie:place().

-doc """
A root port's bus numbers as the walk numbers them, under the names its
configuration read (erx_pcie_cfg:parse/1) and its planner's target
(erx_pcie_plan:root_port()) give them.
""".
-type buses() :: #{primary_bus := 0..255, secondary_bus := 0..255, subordinate_bus := 0..255}.

-doc """
What a reported function was found to be: a function with its read
value and, at a placing walk, the hardware size of each memory BAR that
sized, by BAR index; one with a BAR too large to place; one whose snapshot
or sizing answer was refused, with the field; or one the walk does not
take, with the reason.
""".
-type outcome() :: {read, erx_pcie_cfg:read(), Sizes :: #{0..5 => byte()}}
                 | {unplaced, erx_pcie_cfg:read(), {bar_size, 0..5}}
                 | {malformed, erx_pcie_cfg:reason() | {bar_mask, 0..5}}
                 | {unsupported, header_type | below_root_port | root_port_bar | bus_range}.

-doc "A reported function: its place, where it was found, its identity and its outcome.".
-type found() :: #{place := erx_pcie:place(),
                   parent := parent(),
                   identity := erx_pcie_cfg:identity(),
                   outcome := outcome()}.

-doc """
A root port the walk numbered, with its read value and its buses, and
the enumerator's answer to applying its target; only below one applied
`ok` was anything read.
""".
-type root_port() :: #{place := erx_pcie:place(),
                       read := erx_pcie_cfg:read(),
                       buses := buses(),
                       applied := ok | {error, atom()}}.

-doc """
A finished walk: what it found, in the order the walk met it, which is
place order except that the bus below a root port is walked right after
the root port.
""".
-type result() :: #{found := [found()],
                    root_ports := [root_port()],
                    past_bound := [erx_pcie:place()]}.

-doc """
What the enumerator does next: one configuration access through its
bridge driver; apply a root port's target through `erx_pcie_apply`, from
its place, read value and buses and the bridge's layouts; or stop, with
the walk's result or because the link went down.
""".
-type action() :: {access, erx_pcie_bridge:access()}
                | {root_port, erx_pcie:place(), erx_pcie_cfg:read(), buses()}
                | {stop, {done, result()} | link_down}.

-doc "The answer to the last action: the bridge driver's, or `erx_pcie_apply`'s.".
-type answer() :: erx_pcie_bridge:result() | {error, atom()}.

%% A BAR to size, with its register's original value as the snapshot read
%% it, both halves of a 64-bit BAR, which sizing restores.
-type sized_bar() :: {erx_pcie_cfg:bar(), Original :: 0..16#ffffffffffffffff}.

%% A unit of the walk and the actions it makes; when its actions are done,
%% finished/3 decides from their answers.
-type task() :: {probe, Bus :: 0..255, Device :: 0..31, parent()}
              | {function, erx_pcie:place(), parent()}
              | {past_bound, erx_pcie:place()}
              | {quiet, erx_pcie:place(), Command :: 0..16#ffff}
              | {size_function, erx_pcie:place(), parent(), erx_pcie_cfg:identity(),
                 erx_pcie_cfg:read(), [sized_bar()]}
              | {size_root_port, erx_pcie:place(), erx_pcie_cfg:identity(),
                 erx_pcie_cfg:read(), buses(), [sized_bar()]}
              | {number, erx_pcie:place(), erx_pcie_cfg:read(), buses()}.

-record(walk, {bridge :: erx_abi_layout:erx_pcie_bridge(),
               kind :: kind(),
               %% The tasks still to begin, the next first.
               agenda = [] :: [task()],
               %% The task under way, its actions not yet answered (the
               %% head is the one in flight) and the values its reads
               %% answered, newest first, in the order actions/1 emits them.
               task :: task() | none,
               pending = [] :: [action()],
               values = [] :: [0..16#ffffffff],
               %% The bus number the next root port takes.
               next_bus :: 0..256,
               found = [] :: [found()],
               root_ports = [] :: [root_port()],
               past_bound = [] :: [erx_pcie:place()]}).

-opaque walk() :: #walk{}.

-doc "The walk of a bridge and its first action.".
-spec start(erx_abi_layout:erx_pcie_bridge(), kind()) -> {walk(), [action()]}.
start(#{bus_first := First} = Bridge, Kind) when Kind =:= placing; Kind =:= later ->
    advance(#walk{bridge = Bridge, kind = Kind, task = none, next_bus = First + 1,
                  agenda = probes(First, root)}).

-doc "The walk after the answer to its last action, and its next action.".
-spec step(answer(), walk()) -> {walk(), [action()]}.
step({error, link_down}, Walk) ->
    {Walk, [{stop, link_down}]};
step({error, Reason}, Walk) ->
    finish({error, Reason}, Walk);
step({ok, Value}, #walk{pending = [_Made | Rest], values = Values} = Walk) ->
    continue(Walk#walk{pending = Rest, values = [Value | Values]});
step(ok, #walk{pending = [_Made | Rest]} = Walk) ->
    continue(Walk#walk{pending = Rest}).

%% The task's next action, or, when it has made them all, its decision.
continue(#walk{pending = [], values = Values} = Walk) ->
    finish({ok, lists:reverse(Values)}, Walk);
continue(#walk{pending = [Next | _]} = Walk) ->
    {Walk, [Next]}.

finish(Outcome, #walk{task = Task} = Walk) ->
    advance(finished(Task, Outcome, Walk#walk{task = none, pending = [], values = []})).

%% The next task's first action, or the walk's result when none is left.
advance(#walk{agenda = []} = Walk) ->
    {Walk, [{stop, {done, result(Walk)}}]};
advance(#walk{agenda = [Task | Agenda]} = Walk) ->
    Begun = beyond_bound(Task, Walk),
    [First | _] = Actions = actions(Begun),
    {Walk#walk{agenda = Agenda, task = Begun, pending = Actions}, [First]}.

%% A function past the reporting bound is only checked for presence.
beyond_bound({function, Place, _Parent}, #walk{found = Found})
  when length(Found) >= ?ERX_PCIE_FUNCTIONS_MAX ->
    {past_bound, Place};
beyond_bound(Task, _Walk) ->
    Task.

%% The actions a task makes, never none.
actions({probe, Bus, Device, _Parent}) ->
    Place = {Bus, Device, 0},
    [read(Place, ?ERX_PCIE_CFG_VENDOR, 2), read(Place, ?ERX_PCIE_CFG_HEADER, 1)];
actions({function, Place, _Parent}) ->
    [read(Place, Offset, 4) || Offset <- lists:seq(0, ?ERX_PCIE_CONFIG_SIZE - 4, 4)];
actions({past_bound, Place}) ->
    [read(Place, ?ERX_PCIE_CFG_VENDOR, 2)];
actions({quiet, Place, Command}) ->
    [write(Place, ?ERX_PCIE_CFG_COMMAND, 2, Command)];
actions({size_function, Place, _Parent, _Identity, Read, Bars}) ->
    sizing(Place, Read, Bars);
actions({size_root_port, Place, _Identity, Read, _Buses, Bars}) ->
    sizing(Place, Read, Bars);
actions({number, Place, Read, Buses}) ->
    [{root_port, Place, Read, Buses}].

%% What a task's answers decide: the tasks it adds, the next first, and
%% what it reports.
finished({probe, Bus, Device, Parent}, {ok, [_Vendor, HeaderType]}, Walk) ->
    Functions = case HeaderType band ?ERX_PCIE_HEADER_MULTIFUNCTION of
                    0 -> [0];
                    _ -> lists:seq(0, ?ERX_PCIE_FUNCTION_MAX)
                end,
    push([{function, {Bus, Device, Function}, Parent} || Function <- Functions], Walk);
finished({function, Place, Parent}, {ok, Words}, Walk) ->
    classify(Place, Parent, << <<Word:32/little>> || Word <- Words >>, Walk);
finished({past_bound, Place}, {ok, _Vendor}, #walk{past_bound = Past} = Walk) ->
    Walk#walk{past_bound = [Place | Past]};
finished({size_function, Place, Parent, Identity, Read, Bars}, {ok, Answers}, Walk) ->
    report(Place, Parent, Identity, endpoint_outcome(Read, sizes(Bars, Answers)), Walk);
finished({size_root_port, Place, Identity, Read, Buses, Bars}, {ok, Answers}, Walk) ->
    case [Bar || {Bar, Size} <- sizes(Bars, Answers), Size =/= absent] of
        [] -> push([{number, Place, Read, Buses}], Walk);
        _Implemented -> report(Place, root, Identity, {unsupported, root_port_bar}, Walk)
    end;
finished({number, Place, Read, #{secondary_bus := Bus} = Buses}, Answer, Walk) ->
    Applied = case Answer of
                  {ok, []} -> ok;
                  {error, _Reason} = Error -> Error
              end,
    RootPort = #{place => Place, read => Read, buses => Buses, applied => Applied},
    Numbered = Walk#walk{root_ports = [RootPort | Walk#walk.root_ports]},
    case Applied of
        ok -> push(probes(Bus, Place), Numbered);
        {error, _} -> Numbered
    end;
finished({quiet, _Place, _Command}, _Answer, Walk) ->
    Walk;
%% Anything else is absent part way: the device or function is not there.
finished(_Task, {error, absent}, Walk) ->
    Walk.

%% A function's snapshot decides what it is. A type-1 header on the root
%% bus takes its bus number before anything else is decided, so the bus
%% numbers are a function of the root ports' places alone and every walk
%% gives each root port the same ones, whatever its parse or its BARs.
classify(Place, Parent, Snapshot, Walk) ->
    {ok, #{header_type := Type} = Identity} = erx_pcie_cfg:identity(Snapshot),
    {Buses, Numbered} = take_buses(Place, Parent, Type, Walk),
    case lists:keymember(Type, 2, ?ERX_PCIE_HEADER_MEMBERS) of
        false ->
            report(Place, Parent, Identity, {unsupported, header_type}, Numbered);
        true ->
            parsed(Place, Parent, Identity, Snapshot, Buses, erx_pcie_cfg:parse(Snapshot), Numbered)
    end.

%% The next bus number as a root port's secondary and subordinate bus, for a
%% type-1 header on the root bus; `bus_range` past the bridge's last bus;
%% `none` for any other function.
take_buses({Primary, _, _}, root, ?ERX_PCIE_HEADER_BRIDGE,
           #walk{next_bus = Bus, bridge = #{bus_last := Last}} = Walk) ->
    Buses = case Bus =< Last of
                true -> #{primary_bus => Primary, secondary_bus => Bus, subordinate_bus => Bus};
                false -> bus_range
            end,
    {Buses, Walk#walk{next_bus = Bus + 1}};
take_buses(_Place, _Parent, _Type, Walk) ->
    {none, Walk}.

parsed(Place, Parent, Identity, Snapshot, _Buses, {error, Field}, Walk) ->
    Reported = report(Place, Parent, Identity, {malformed, Field}, Walk),
    push([{quiet, Place, quiet_command(Snapshot)}], Reported);
parsed(Place, Parent, Identity, Snapshot, none, {ok, #{header := normal} = Read}, Walk) ->
    case {Walk#walk.kind, [{Bar, original(Snapshot, Bar)}
                           || #{kind := memory} = Bar <- maps:get(bars, Read)]} of
        {placing, [_ | _] = Bars} ->
            push([{size_function, Place, Parent, Identity, Read, Bars}], Walk);
        _NothingToSize ->
            report(Place, Parent, Identity, {read, Read, #{}}, Walk)
    end;
parsed(Place, root, Identity, _Snapshot, bus_range, {ok, #{header := bridge}}, Walk) ->
    report(Place, root, Identity, {unsupported, bus_range}, Walk);
parsed(Place, root, Identity, Snapshot, Buses, {ok, #{header := bridge} = Read}, Walk) ->
    case {Walk#walk.kind, [{Bar, original(Snapshot, Bar)}
                           || #{kind := Kind} = Bar <- maps:get(bars, Read), Kind =/= absent]} of
        {placing, [_ | _] = Bars} ->
            push([{size_root_port, Place, Identity, Read, Buses, Bars}], Walk);
        _NothingToSize ->
            push([{number, Place, Read, Buses}], Walk)
    end;
parsed(Place, Parent, Identity, _Snapshot, none, {ok, #{header := bridge}}, Walk) ->
    report(Place, Parent, Identity, {unsupported, below_root_port}, Walk).

%% A function's outcome from the sizes of its memory BARs: the first
%% refused answer, in BAR order, decides it.
endpoint_outcome(Read, Sizes) ->
    case [Error || {_Bar, {error, _} = Error} <- Sizes] of
        [] ->
            {read, Read, maps:from_list([{Index, Log2} || {#{index := Index}, {ok, Log2}} <- Sizes])};
        [{error, {bar_mask, _} = Field} | _] ->
            {malformed, Field};
        [{error, {bar_size, _} = Field} | _] ->
            {unplaced, Read, Field}
    end.

%% Each sized BAR with its decoded size, taking the read-back answers in
%% the order sizing/3 made them: a 64-bit BAR's upper register, then its
%% lower.
sizes([], []) ->
    [];
sizes([{#{addr64 := true} = Bar, _Original} | Bars], [Upper, Lower | Answers]) ->
    [{Bar, erx_pcie_cfg:size(Bar, Upper bsl 32 bor Lower)} | sizes(Bars, Answers)];
sizes([{#{addr64 := false} = Bar, _Original} | Bars], [Lower | Answers]) ->
    [{Bar, erx_pcie_cfg:size(Bar, Lower)} | sizes(Bars, Answers)].

%% FreeBSD's pci_read_bar for every BAR at once (sys/dev/pci/pci.c:3180-3222,
%% release/15.1.0): decoding off, then for each BAR all ones written to
%% both halves before either is read back, upper first, and the original
%% words restored, then the command register as it read. FreeBSD turns off
%% only the decoding the BAR uses; turning off both covers every BAR with
%% one write.
sizing(Place, #{command := Command}, Bars) ->
    Off = Command band bnot (?ERX_PCIE_COMMAND_MEMORY bor ?ERX_PCIE_COMMAND_IO),
    [write(Place, ?ERX_PCIE_CFG_COMMAND, 2, Off)]
        ++ lists:append([size_bar(Place, Bar) || Bar <- Bars])
        ++ [write(Place, ?ERX_PCIE_CFG_COMMAND, 2, Command)].

size_bar(Place, {#{index := Index, addr64 := true}, Original}) ->
    Low = bar_register(Index),
    High = Low + 4,
    [write(Place, Low, 4, 16#ffffffff), write(Place, High, 4, 16#ffffffff),
     read(Place, High, 4), read(Place, Low, 4),
     write(Place, Low, 4, Original band 16#ffffffff), write(Place, High, 4, Original bsr 32)];
size_bar(Place, {#{index := Index, addr64 := false}, Original}) ->
    Register = bar_register(Index),
    [write(Place, Register, 4, 16#ffffffff), read(Place, Register, 4),
     write(Place, Register, 4, Original)].

bar_register(Index) -> ?ERX_PCIE_CFG_BARS + 4 * Index.

%% A BAR register's value as the snapshot holds it, both halves of a 64-bit
%% BAR, whose registers parse/1 has found inside the header.
original(Snapshot, #{index := Index, addr64 := Wide}) ->
    Bytes = case Wide of
                true -> 8;
                false -> 4
            end,
    Offset = bar_register(Index),
    <<_:Offset/binary, Value:Bytes/little-unit:8, _/binary>> = Snapshot,
    Value.

%% A refused function's command register with memory, I/O and bus master
%% off and INTx disabled, from the snapshot's command word, which every
%% snapshot holds whatever parse/1 refused.
quiet_command(Snapshot) ->
    Offset = ?ERX_PCIE_CFG_COMMAND,
    <<_:Offset/binary, Command:16/little, _/binary>> = Snapshot,
    Off = ?ERX_PCIE_COMMAND_MEMORY bor ?ERX_PCIE_COMMAND_IO bor ?ERX_PCIE_COMMAND_MASTER,
    (Command band bnot Off) bor ?ERX_PCIE_COMMAND_INTX_DISABLE.

%% The devices of a bus, to be probed in order.
probes(Bus, Parent) ->
    [{probe, Bus, Device, Parent} || Device <- lists:seq(0, ?ERX_PCIE_DEVICE_MAX)].

%% Tasks added before the rest of the agenda, in their order.
push(Tasks, #walk{agenda = Agenda} = Walk) ->
    Walk#walk{agenda = Tasks ++ Agenda}.

report(Place, Parent, Identity, Outcome, #walk{found = Found} = Walk) ->
    Entry = #{place => Place, parent => Parent, identity => Identity, outcome => Outcome},
    Walk#walk{found = [Entry | Found]}.

result(#walk{found = Found, root_ports = RootPorts, past_bound = Past}) ->
    #{found => lists:reverse(Found),
      root_ports => lists:reverse(RootPorts),
      past_bound => lists:reverse(Past)}.

read(Place, Offset, Width) -> {access, {read, Place, Offset, Width}}.
write(Place, Offset, Width, Value) -> {access, {write, Place, Offset, Width, Value}}.
