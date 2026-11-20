%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_enumerator).
-moduledoc """
The PCIe domain's one process, the enumerator (docs/design-pcie.md, "The
PCIe domain", "Facets"), and the erx_pcie application that runs it, with
no supervisor below it: any crash of the enumerator ends the application
and so the domain, whose restart is the recovery.

**The start.** The enumerator asks the device service for its targets
over `pci_bus`, `{ok, Bridges, Layouts, Settings}`: each bridge's record,
the layouts the library holds for its functions and every function's
setting. For each bridge it opens the bridge's driver and walks: a
bridge with no layouts gets a placing walk, after which its functions'
records are placed (erx_pcie_place) and become its layouts, and each
root port it numbered gets its window opened over them. Then each
function with a layout gets the start's target of its layout and setting
(erx_pcie_apply:start/3); one that no longer reads with its layout's
identity, and one at a place with no layout, is lowered to quiet and
reported `unplaced` from what it reads. A function the bridge driver
holds back is reported `not_ready`. It then reports every function it
found to the device service, `{report, Functions}`, each its record and
whether the start kept it at its setting, and applies each setting the
answer carries that differs from its target's. Only then does it serve.

**Serving** (`pcie`): `{set, Key, Setting}` takes a function to its
layout and Setting, and `{reset, Key}` is the function-level reset of
"The plan": `off`, then, where the function offers the reset, pending
transactions polled every 100 ms for at most 1000 ms, the reset
initiated, 100 ms and a read that must find the function with its
identity, then `decoding`. Key is the function's bridge, as its record's
`bridge` names it, and its place.

**The edge.** The start and the server reach the world only through the
edge's functions, so the whole process runs on the host over a model
bridge and a model device service: `bus`, one request to `pci_bus`;
`open`, a bridge's driver from its record; `sleep`, a wait in
milliseconds. An access that answers `link_down` exits the process.
""".

-behaviour(application).
-behaviour(gen_server).

-export([start/2, stop/1]).
-export([start_link/1, set/3, reset/2]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).
-export_type([edge/0, key/0, reported/0]).

-include("generated/erx_abi.hrl").

-doc "A function by its bridge's device row and its place.".
-type key() :: {Bridge :: non_neg_integer(), Bus :: 0..255, Device :: 0..31, Function :: 0..7}.

-doc "A function as the start reports it: its record, and whether the start kept it at its setting.".
-type reported() :: #{record := erx_abi_layout:erx_pcie_function(), kept := boolean()}.

-doc "What the enumerator reaches: the pci_bus facet, each bridge's driver, and time.".
-type edge() :: #{bus := fun((term()) -> term()),
                  open := fun((erx_abi_layout:erx_pcie_bridge()) -> {ok, erx_pcie_apply:driver()} | {error, atom()}),
                  sleep := fun((non_neg_integer()) -> ok)}.

-define(FLR_POLL_MS, 100).
-define(FLR_POLLS, 10).
-define(FLR_WAIT_MS, 100).

-doc "The application's start: the enumerator over the domain's own edge.".
start(_Type, _Args) ->
    start_link(#{bus => fun bus/1, open => fun open/1, sleep => fun timer:sleep/1}).

stop(_State) ->
    ok.

-doc "Starts the enumerator over Edge; it starts its bridges before it serves.".
-spec start_link(edge()) -> {ok, pid()}.
start_link(Edge) ->
    gen_server:start_link(?MODULE, Edge, []).

-doc "Takes the function Key names to its layout and Setting.".
-spec set(pid(), key(), erx_abi_layout:erx_pcie_setting()) -> ok | {error, atom()}.
set(Enumerator, Key, Setting) ->
    gen_server:call(Enumerator, {set, Key, Setting}, infinity).

-doc "The function-level reset of the function Key names, or `none` where it offers none.".
-spec reset(pid(), key()) -> {ok, flr | none} | {error, atom()}.
reset(Enumerator, Key) ->
    gen_server:call(Enumerator, {reset, Key}, infinity).

init(Edge) ->
    {ok, #{edge => Edge}, {continue, start}}.

handle_continue(start, #{edge := #{bus := Bus} = Edge}) ->
    {ok, Bridges, Layouts, Settings} = Bus(targets),
    Started = [start_bridge(Bridge, Layouts, Settings, Edge) || Bridge <- Bridges],
    Reported = lists:append([Reports || {_Index, _Driver, _Layouts, Reports} <- Started]),
    {ok, Answered} = Bus({report, Reported}),
    State = #{edge => Edge,
              drivers => maps:from_list([{Index, Driver} || {Index, Driver, _, _} <- Started, Driver =/= none]),
              layouts => maps:from_list([{key(L), L} || {_, _, Own, _} <- Started, L <- Own]),
              settings => Settings},
    {noreply, maps:fold(fun answered/3, State, Answered)}.

handle_call({set, Key, Setting}, _From, State) ->
    {Result, Next} = target(Key, Setting, State),
    {reply, Result, Next};
handle_call({reset, Key}, _From, State) ->
    {Result, Next} = function_reset(Key, State),
    {reply, Result, Next};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% --- The start ---------------------------------------------------------------

%% One bridge's start: its driver, and the record of every function it found.
start_bridge(#{index := Index} = Bridge, Layouts, Settings, #{open := Open}) ->
    case Open(Bridge) of
        {ok, Driver} ->
            Own = [L || #{bridge := B} = L <- Layouts, B =:= Index],
            Kind = case Own of
                       [] -> placing;
                       _ -> later
                   end,
            {#{found := Found, root_ports := RootPorts}, Walked} = walk(Bridge, Kind, Own, Driver),
            {Records, Placed} = records(Kind, Index, Bridge, Found, Own, RootPorts, Walked),
            {Reports, Started} = lists:mapfoldl(fun(R, D) -> start_function(R, Settings, D) end,
                                                Placed, Records),
            Held = case Kind of
                       placing -> [R || {R, _} <- Records, drivable(R)];
                       later -> [L || L <- Own, drivable(L)]
                   end,
            {Index, Started, Held, Reports};
        {error, Reason} ->
            logger:error("pcie: bridge ~b not started: ~p", [Index, Reason]),
            {Index, none, [], []}
    end.

%% The walk run to its end; each root port it numbers gets its target from
%% the layouts the walk starts with, closed at a placing walk.
walk(Bridge, Kind, Layouts, Driver) ->
    drive(erx_pcie_walk:start(Bridge, Kind), Layouts, Driver).

drive({_Walk, [{stop, {done, Result}}]}, _Layouts, Driver) ->
    {Result, Driver};
drive({_Walk, [{stop, link_down}]}, _Layouts, _Driver) ->
    exit(link_down);
drive({Walk, [{access, Access}]}, Layouts, {Module, State}) ->
    {Answer, Next} = Module:access(Access, State),
    drive(erx_pcie_walk:step(Answer, Walk), Layouts, {Module, Next});
drive({Walk, [{root_port, Place, _Read, Buses}]}, Layouts, Driver) ->
    {Answer, Next} = root_port(Place, Buses, Layouts, Driver),
    drive(erx_pcie_walk:step(Answer, Walk), Layouts, Next).

root_port(Place, #{secondary_bus := Secondary} = Buses, Layouts, Driver) ->
    Window = erx_pcie_place:root_port_window(Secondary, Layouts),
    erx_pcie_apply:apply(Place, {root_port, #{buses => Buses, window => Window}}, Driver).

%% The records of what a walk found. A placing walk's are placed, and its
%% root ports' windows opened over them; a later walk's function keeps its
%% layout, decided at its start.
records(placing, Index, Bridge, Found, _Own, RootPorts, Driver) ->
    Addresses = erx_pcie_place:layout(Bridge, Found),
    Records = [{placing_record(Index, F, Addresses), F} || F <- Found],
    Opened = lists:foldl(fun(#{place := Place, buses := Buses}, D) ->
                                 {_, Next} = root_port(Place, Buses, [R || {R, _} <- Records], D),
                                 Next
                         end, Driver, [R || #{applied := ok} = R <- RootPorts]),
    {Records, Opened};
records(later, Index, _Bridge, Found, Own, _RootPorts, Driver) ->
    ByPlace = maps:from_list([{place(L), L} || L <- Own]),
    {[{later_record(Index, F, ByPlace), F} || F <- Found], Driver}.

placing_record(Index, #{outcome := Outcome} = Found, Addresses) ->
    case Outcome of
        {read, _, _} -> erx_pcie_report:placed(Index, Found, Addresses);
        {unplaced, _, _} -> erx_pcie_report:read(Index, Found, unplaced);
        {State, _} -> erx_pcie_report:identity(Index, Found, State)
    end.

%% A function a later walk read whole is its layout, to be confirmed at its
%% start, when the placing walk could drive it; a layout the placing walk
%% left unplaced, malformed or unsupported keeps that state, and an
%% unplaced one is lowered to quiet. One at a place with no layout is
%% unplaced.
later_record(Index, #{place := Place, outcome := Outcome} = Found, ByPlace) ->
    case {Outcome, maps:find(Place, ByPlace)} of
        {{read, _, _}, {ok, Layout}} ->
            case drivable(Layout) of
                true -> Layout#{state := ready};
                false -> Layout
            end;
        {{read, _, _}, error} -> erx_pcie_report:read(Index, Found, unplaced);
        {{unplaced, _, _}, _} -> erx_pcie_report:read(Index, Found, unplaced);
        {{State, _}, _} -> erx_pcie_report:identity(Index, Found, State)
    end.

%% A function's start: a ready one to the start's target of its layout and
%% setting, which its bridge may then hold back; an unplaced one quiet; a
%% malformed or unsupported one as the walk left it. A ready one that no
%% longer reads with its layout's identity is lowered to quiet and
%% reported unplaced from what the walk read, so the intake does not
%% confirm its layout.
start_function({#{state := ready} = Record, Found}, Settings, {Module, _} = Driver) ->
    Setting = maps:get(key(Record), Settings, off()),
    case erx_pcie_apply:start(place(Record), {function, Record, Setting}, Driver) of
        {{ok, Kept}, {_, Started}} ->
            case Module:ready(Record, Started) of
                {ok, Ready} -> {#{record => Record, kept => Kept}, {Module, Ready}};
                {not_ready, Held} -> {#{record => Record#{state := not_ready}, kept => false}, {Module, Held}}
            end;
        {{{error, gone}, _}, Next} ->
            {_, Quiet} = erx_pcie_apply:quiet(place(Record), Next),
            {#{record => erx_pcie_report:read(maps:get(bridge, Record), Found, unplaced), kept => false}, Quiet};
        {{{error, Reason}, _}, Next} ->
            logger:warning("pcie: ~p: start: ~p", [key(Record), Reason]),
            {#{record => Record, kept => false}, Next}
    end;
start_function({#{state := unplaced} = Record, _Found}, _Settings, Driver) ->
    {_, Next} = erx_pcie_apply:quiet(place(Record), Driver),
    {#{record => Record, kept => false}, Next};
start_function({Record, _Found}, _Settings, Driver) ->
    {#{record => Record, kept => false}, Driver}.

%% An answered setting that differs from the target the start applied.
answered(Key, Setting, #{settings := Settings} = State) ->
    case maps:get(Key, Settings, off()) of
        Setting ->
            State#{settings := Settings#{Key => Setting}};
        _ ->
            {Result, Next} = target(Key, Setting, State),
            Result =:= ok orelse logger:warning("pcie: ~p: setting: ~p", [Key, Result]),
            Next
    end.

%% --- Serving -----------------------------------------------------------------

target(Key, Setting, #{layouts := Layouts} = State) ->
    case maps:find(Key, Layouts) of
        {ok, Layout} ->
            with_driver(Key, State, fun(Driver) ->
                                            erx_pcie_apply:apply(place(Layout), {function, Layout, Setting}, Driver)
                                    end,
                        fun(ok, S) -> S#{settings := maps:put(Key, Setting, maps:get(settings, S))};
                           (_, S) -> S
                        end);
        error ->
            {{error, unknown}, State}
    end.

function_reset(Key, #{layouts := Layouts, settings := Settings} = State) ->
    case maps:find(Key, Layouts) of
        error ->
            {{error, unknown}, State};
        {ok, Layout} ->
            Setting = maps:get(Key, Settings, off()),
            case target(Key, Setting#{mode := off}, State) of
                {ok, Off} ->
                    {Reset, Flr} = flr(Layout, Off),
                    case Reset of
                        {ok, _} ->
                            case target(Key, Setting#{mode := decoding}, Flr) of
                                {ok, Decoding} -> {Reset, Decoding};
                                Failed -> Failed
                            end;
                        _ ->
                            {Reset, Flr}
                    end;
                Failed ->
                    Failed
            end
    end.

%% The reset itself, where the layout's Express flags offer it.
flr(#{express_offset := At, express_flags := Flags} = Layout, State) ->
    case At =/= 0 andalso lists:member(flr, Flags) of
        false ->
            {{ok, none}, State};
        true ->
            Key = key(Layout),
            Place = place(Layout),
            with_driver(Key, State,
                        fun(Driver) -> initiate(Place, At, ?FLR_POLLS, Driver, maps:get(edge, State)) end,
                        fun(_, S) -> S end)
    end.

initiate(Place, At, Polls, {Module, S0}, #{sleep := Sleep} = Edge) ->
    {Status, S1} = Module:access({read, Place, At + ?ERX_PCIE_EXPRESS_DEVICE_STATUS, 2}, S0),
    case Status of
        {ok, 16#ffff} ->
            {{error, gone}, {Module, S1}};
        {ok, Word} when Word band ?ERX_PCIE_EXPRESS_DEVICE_STATUS_PENDING =:= 0 ->
            case Module:access({read, Place, At + ?ERX_PCIE_EXPRESS_DEVICE_CONTROL, 2}, S1) of
                {{ok, Control}, S2} ->
                    {_, S3} = Module:access({write, Place, At + ?ERX_PCIE_EXPRESS_DEVICE_CONTROL, 2,
                                             Control bor ?ERX_PCIE_EXPRESS_DEVICE_CONTROL_FLR}, S2),
                    Sleep(?FLR_WAIT_MS),
                    %% The plan to decoding that follows reads the function
                    %% again and answers gone for one without its identity.
                    {{ok, flr}, {Module, S3}};
                {{error, absent}, S2} ->
                    {{error, gone}, {Module, S2}};
                {{error, link_down}, _} ->
                    exit(link_down)
            end;
        {ok, _Pending} when Polls > 0 ->
            Sleep(?FLR_POLL_MS),
            initiate(Place, At, Polls - 1, {Module, S1}, Edge);
        {ok, _Pending} ->
            {{error, busy}, {Module, S1}};
        {error, absent} ->
            {{error, gone}, {Module, S1}};
        {error, link_down} ->
            exit(link_down)
    end.

%% Runs Act over the driver of Key's bridge, keeping the driver's new
%% state, and Then over the state with Act's result.
with_driver({Index, _, _, _}, #{drivers := Drivers} = State, Act, Then) ->
    case maps:find(Index, Drivers) of
        {ok, Driver} ->
            {Result, Next} = Act(Driver),
            {Result, Then(Result, State#{drivers := Drivers#{Index := Next}})};
        error ->
            {{error, unknown}, State}
    end.

%% --- The domain's edge -------------------------------------------------------

%% The pci_bus facet on the target: no system manifest names a pci_bus
%% service, so the domain has no facet to call and its start ends here
%% (TODO.md, "the start's other side").
bus(_Request) ->
    {error, no_facet}.

%% A bridge's driver on the target. The device NIF has no access to a
%% configuration window at a computed offset, and a given record does not
%% name its manifest device row, so no bridge opens there (TODO.md).
open(#{index := Index}) ->
    logger:error("pcie: bridge ~b: no configuration-space access", [Index]),
    {error, unsupported}.

%% --- Records -----------------------------------------------------------------

%% A layout the enumerator drives: one its placing walk found ready, or
%% that its bridge held back. Only these are started, set or reset, so no
%% plan turns decoding on over a BAR placement left at address 0.
drivable(#{state := State}) -> State =:= ready orelse State =:= not_ready.

key(#{bridge := Bridge, bus := Bus, device := Device, function := Function}) -> {Bridge, Bus, Device, Function}.

place(#{bus := Bus, device := Device, function := Function}) -> {Bus, Device, Function}.

off() -> #{mode => off, route => none, message => #{address => 0, data => 0}}.
