%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_enumerator).
-moduledoc """
The PCIe domain's enumerator (docs/design-pcie.md, "The PCIe domain",
"Processes", "Facets"), registered under its module's name below
erx_pcie_sup, which ends the domain at any crash of it, so the domain's
restart is the recovery.

**The start.** The enumerator asks the device service for its targets
over `pci_bus`, `{ok, Bridges, Layouts, Settings}`: each bridge's record,
the layouts the library holds for its functions and every function's
setting. For each bridge it opens the bridge's driver and walks: a
bridge with no layouts gets a placing walk, after which its functions'
records are placed (erx_pcie_place) and become its layouts, and each
root port it numbered gets its window opened over them. Then each
function with a layout gets the start's target of its layout and setting
(erx_pcie_apply:start/3), or `off` with route `none` when its
record differs from its layout; one that no longer reads with its layout's
identity, and one at a place with no layout, is lowered to quiet and
reported `unplaced` from what it reads; a later walk's function is
reported as it reads, with its layout's BAR sizes and addresses, so the
library's intake sees any change. A function the bridge driver holds
back is reported `not_ready`. It then reports every function it
found to the device service, `{report, Functions}`, each its record and
whether the start kept it at its setting, and applies each setting the
answer carries that differs from its target's. Only then does it serve.

**Serving** (`pcie`, each request erx_pcie_facet admits forwarded here):
`{set, Key, Setting}` takes a function to its
layout and Setting, turning it off when the mastering rule refuses
Setting, and `{reset, Key}` is the function-level reset of
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

-behaviour(gen_server).

-export([start_link/0, start_link/1, set/3, reset/2]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).
-export_type([edge/0, key/0, reported/0]).

-include("generated/erx_abi.hrl").

-doc "A function by its bridge's device row and its place.".
-type key() :: {Bridge :: non_neg_integer(), Bus :: 0..255, Device :: 0..31, Function :: 0..7}.

-doc "A function as the start reports it: its record, and whether the start kept it at its setting.".
-type reported() :: #{record := erx_abi_layout:erx_pcie_function(), kept := boolean()}.

-doc "What the enumerator reaches: the pci_bus facet, each bridge's driver, and time.".
-type edge() :: #{bus := fun((term()) -> term()),
                  open := fun((erx_abi_layout:erx_pcie_bridge()) -> {ok, erx_pcie_apply:driver()} | {error, term()}),
                  sleep := fun((non_neg_integer()) -> ok)}.

%% Each peripheral of role configuration (include/erx/device_kinds.h) and
%% the bridge driver module that starts over its record; `none` for the
%% BCM2711's bridge, which has its core (erx_pcie_bcm2711_core) and no
%% driver module (TODO.md, "the start's leftovers").
-define(BRIDGE_DRIVERS, #{pci_ecam => erx_pcie_ecam, bcm2711_pcie => none}).

-define(FLR_POLL_MS, 100).
-define(FLR_POLLS, 10).
-define(FLR_WAIT_MS, 100).
%% The longest wait for a pci_bus answer: the answer to report waits for the
%% system domain's pcie grant, whose operation the domain service's mint core
%% abandons after 10 s (erx_domain_mints), and a firmware request has a 1 s
%% deadline, so twice the mint core's deadline is never reached by a
%% device service that answers.
-define(BUS_TIMEOUT_MS, 20000).

-doc "Starts the domain's enumerator over its own edge, registered under the module's name.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    Edge = #{bus => fun bus/1, open => fun open/1, sleep => fun timer:sleep/1},
    gen_server:start_link({local, ?MODULE}, ?MODULE, Edge, []).

-doc "Starts an enumerator over Edge, unregistered, as the host tests run it; it starts its bridges before it serves.".
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
    %% A changed function is held at off: an answer or a set for it finds no layout.
    Started = [start_bridge(Bridge, Layouts, Settings, Edge) || Bridge <- Bridges],
    {ok, Answered} = Bus({report, lists:append([Reports || #{reports := Reports} <- Started])}),
    State = #{edge => Edge,
              drivers => maps:from_list([{Index, Driver} || #{index := Index, driver := Driver} <- Started]),
              layouts => maps:from_list([{key(L), L} || #{held := Held} <- Started, L <- Held]),
              settings => maps:merge(Settings, maps:from_list([{K, off()} || #{changed := C} <- Started, K <- C]))},
    {noreply, maps:fold(fun answered/3, State, Answered)}.

handle_call({set, Key, Setting}, _From, State) ->
    {Result, Next} = served(fun() -> {ok, take(Key, Setting, State)} end),
    {reply, Result, Next};
handle_call({reset, Key}, _From, State) ->
    {Result, Next} = served(fun() -> function_reset(Key, State) end),
    {reply, Result, Next};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% --- The start ---------------------------------------------------------------

%% One bridge's start: its driver, the layouts it holds for serving, and
%% the report of every function it found. A bridge whose driver does not
%% open has none of them.
start_bridge(#{index := Index} = Bridge, Layouts, Settings, #{open := Open}) ->
    case Open(Bridge) of
        {ok, Driver} ->
            {Starts, Held, Walked} = starts(Bridge, [L || #{bridge := B} = L <- Layouts, B =:= Index], Driver),
            {Reports, Started} = lists:mapfoldl(fun(S, D) -> start_function(S, Settings, D) end, Walked, Starts),
            #{index => Index, driver => Started, held => Held, reports => Reports,
              changed => [key(R) || #{record := R, changed := true} <- Starts]};
        {error, Reason} ->
            logger:error("pcie: bridge ~b not started: ~p", [Index, Reason]),
            #{index => Index, held => [], reports => [], changed => []}
    end.

%% The walk of a bridge and what each function it found starts from, a
%% start(): the record to report, the target layout, what the walk read,
%% and whether the record differs from its layout. A bridge with no
%% layouts gets a placing walk, after which its functions' records are
%% placed, each its own target, and its root ports' windows opened over
%% them; a later walk's function is started against its stored layout and
%% reported as it reads. Answers the starts, the layouts held for serving,
%% which leave out every changed one, and the driver.
starts(#{index := Index} = Bridge, [], Driver) ->
    {#{found := Found, root_ports := RootPorts}, Walked} = walk(Bridge, placing, [], Driver),
    Addresses = erx_pcie_place:layout(Bridge, Found),
    Starts = [placing_start(Index, F, Addresses) || F <- Found],
    Records = [R || #{record := R} <- Starts],
    Opened = lists:foldl(fun(#{place := Place, buses := Buses}, D) ->
                                 {_, Next} = root_port(Place, Buses, Records, D),
                                 Next
                         end, Walked, [R || #{applied := ok} = R <- RootPorts]),
    {Starts, [R || R <- Records, drivable(R)], Opened};
starts(#{index := Index} = Bridge, Own, Driver) ->
    {#{found := Found}, Walked} = walk(Bridge, later, Own, Driver),
    ByPlace = maps:from_list([{place(L), L} || L <- Own]),
    Starts = [later_start(Index, F, ByPlace) || F <- Found],
    Changed = [place(R) || #{record := R, changed := true} <- Starts],
    {Starts, [L || L <- Own, drivable(L), not lists:member(place(L), Changed)], Walked}.

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

placing_start(Index, #{outcome := Outcome} = Found, Addresses) ->
    Record = case Outcome of
                 {read, _, _} -> erx_pcie_report:placed(Index, Found, Addresses);
                 {unplaced, _, _} -> erx_pcie_report:read(Index, Found, unplaced);
                 {State, _} -> erx_pcie_report:identity(Index, Found, State)
             end,
    #{record => Record, target => Record, found => Found, changed => false}.

%% A function a later walk read whole at a drivable layout's place is
%% started against that layout and reported as it reads; a layout the
%% placing walk left unplaced, malformed or unsupported keeps that state,
%% and an unplaced one is lowered to quiet. One at a place with no layout
%% is unplaced.
later_start(Index, #{place := Place, outcome := Outcome} = Found, ByPlace) ->
    Record = case {Outcome, maps:find(Place, ByPlace)} of
                 {{read, _, _}, {ok, Layout}} ->
                     case drivable(Layout) of
                         true -> erx_pcie_report:later(Index, Found, Layout);
                         false -> Layout
                     end;
                 {{read, _, _}, error} -> erx_pcie_report:read(Index, Found, unplaced);
                 {{unplaced, _, _}, _} -> erx_pcie_report:read(Index, Found, unplaced);
                 {{State, _}, _} -> erx_pcie_report:identity(Index, Found, State)
             end,
    Target = maps:get(Place, ByPlace, Record),
    #{record => Record, target => Target, found => Found,
      changed => maps:remove(state, Record) =/= maps:remove(state, Target)}.

%% A function's start: a ready one to the start's target of its layout and
%% setting, which its bridge may then hold back; an unplaced one quiet; a
%% malformed or unsupported one as the walk left it. A ready one whose
%% record differs from its layout where the planner's identity does not
%% look (its subsystem, class, revision, pin or capabilities) starts at
%% off with route none whatever its setting, so no route it no longer
%% fits can refuse the lowering, and is reported not kept: the intake leaves it
%% unconfirmed, so it must not go on decoding or mastering for a holder
%% ("Failure handling and restart"); the enumerator holds no layout for it until its
%% next start, so neither the answer nor set nor reset raises it. A ready
%% one that no longer reads with
%% its layout's identity is lowered to quiet and reported unplaced from
%% what the walk read, so the intake does not confirm its layout.
start_function(#{record := #{state := ready} = Record, target := Layout, found := Found, changed := Changed},
               Settings, {Module, _} = Driver) ->
    Setting = case Changed of
                  false -> maps:get(key(Record), Settings, off());
                  true -> off()
              end,
    case erx_pcie_apply:start(place(Record), {function, Layout, Setting}, Driver) of
        {{ok, AtSetting}, {_, Started}} ->
            Kept = AtSetting andalso not Changed,
            case Module:ready(Record, Started) of
                {ok, Ready} -> {#{record => Record, kept => Kept}, {Module, Ready}};
                {not_ready, Held} -> {#{record => Record#{state := not_ready}, kept => false}, {Module, Held}}
            end;
        {{error, gone}, Next} ->
            {_, Quiet} = erx_pcie_apply:quiet(place(Record), Next),
            {#{record => erx_pcie_report:read(maps:get(bridge, Record), Found, unplaced), kept => false}, Quiet};
        {{error, Reason}, Next} ->
            logger:warning("pcie: ~p: start: ~p", [key(Record), Reason]),
            {#{record => Record, kept => false}, Next}
    end;
start_function(#{record := #{state := unplaced} = Record}, _Settings, Driver) ->
    {_, Next} = erx_pcie_apply:quiet(place(Record), Driver),
    {#{record => Record, kept => false}, Next};
start_function(#{record := Record}, _Settings, Driver) ->
    {#{record => Record, kept => false}, Driver}.

%% An answered setting that differs from the target the start applied.
answered(Key, Setting, #{settings := Settings} = State) ->
    case maps:get(Key, Settings, off()) of
        Setting ->
            State#{settings := Settings#{Key => Setting}};
        _ ->
            {Result, Next} = served(fun() -> {ok, take(Key, Setting, State)} end),
            Result =:= ok orelse logger:warning("pcie: ~p: setting: ~p", [Key, Result]),
            Next
    end.

%% --- Serving -----------------------------------------------------------------

%% The one route of a refusal: each step that ends an operation early
%% throws {erx_pcie_enumerator, Reason, State}, with the state its accesses left, and
%% each operation's entry catches it here.
served(Operation) ->
    try
        Operation()
    catch
        throw:{?MODULE, Reason, State} -> {{error, Reason}, State}
    end.

%% Takes the function Key names to its layout and Setting, and records the
%% setting. A target the mastering rule refuses turns the function off
%% ("Failure handling and restart"), and a failure of that is the answer.
take(Key, Setting, State) ->
    Layout = layout(Key, State),
    {Result, Driver} = erx_pcie_apply:apply(place(Layout), {function, Layout, Setting}, driver(Key, State)),
    Next = keep_driver(Key, Driver, State),
    case Result of
        ok -> Next#{settings := (maps:get(settings, Next))#{Key => Setting}};
        {error, reset} -> throw({?MODULE, reset, take(Key, Setting#{mode := off}, Next)});
        {error, Reason} -> throw({?MODULE, Reason, Next})
    end.

%% The function-level reset of "The plan": off, the reset where the
%% layout offers it, then decoding.
function_reset(Key, State) ->
    Setting = maps:get(Key, maps:get(settings, State), off()),
    Off = take(Key, Setting#{mode := off}, State),
    {How, Reset} = flr(layout(Key, Off), Off),
    {{ok, How}, take(Key, Setting#{mode := decoding}, Reset)}.

%% The reset itself, where the layout's Express flags offer it.
flr(#{express_offset := At, express_flags := Flags} = Layout, #{edge := #{sleep := Sleep}} = State) ->
    case At =/= 0 andalso lists:member(flr, Flags) of
        false ->
            {none, State};
        true ->
            Key = key(Layout),
            {Module, Driver} = driver(Key, State),
            {Answer, Next} = initiate(place(Layout), At, ?FLR_POLLS, Module, Driver, Sleep),
            Kept = keep_driver(Key, {Module, Next}, State),
            case Answer of
                ok -> {flr, Kept};
                {error, Reason} -> throw({?MODULE, Reason, Kept})
            end
    end.

%% Pending transactions polled until clear, then the reset initiated and
%% its wait. The plan to decoding that follows reads the function again
%% and answers gone for one without its identity.
initiate(Place, At, Polls, Module, S0, Sleep) ->
    case Module:access({read, Place, At + ?ERX_PCIE_EXPRESS_DEVICE_STATUS, 2}, S0) of
        {{ok, 16#ffff}, S1} ->
            {{error, gone}, S1};
        {{ok, Word}, S1} when Word band ?ERX_PCIE_EXPRESS_DEVICE_STATUS_PENDING =:= 0 ->
            case Module:access({read, Place, At + ?ERX_PCIE_EXPRESS_DEVICE_CONTROL, 2}, S1) of
                {{ok, Control}, S2} ->
                    S3 = case Module:access({write, Place, At + ?ERX_PCIE_EXPRESS_DEVICE_CONTROL, 2,
                                             Control bor ?ERX_PCIE_EXPRESS_DEVICE_CONTROL_FLR}, S2) of
                             {{error, link_down}, _} -> exit(link_down);
                             {_, Written} -> Written
                         end,
                    Sleep(?FLR_WAIT_MS),
                    {ok, S3};
                {{error, absent}, S2} ->
                    {{error, gone}, S2};
                {{error, link_down}, _} ->
                    exit(link_down)
            end;
        {{ok, _Pending}, S1} when Polls > 0 ->
            Sleep(?FLR_POLL_MS),
            initiate(Place, At, Polls - 1, Module, S1, Sleep);
        {{ok, _Pending}, S1} ->
            {{error, busy}, S1};
        {{error, absent}, S1} ->
            {{error, gone}, S1};
        {{error, link_down}, _} ->
            exit(link_down)
    end.

%% The layout Key names, and the driver of its bridge; unknown for a key
%% the enumerator holds no layout or driver for.
layout(Key, #{layouts := Layouts} = State) ->
    case maps:find(Key, Layouts) of
        {ok, Layout} -> Layout;
        error -> throw({?MODULE, unknown, State})
    end.

driver({Index, _, _, _}, #{drivers := Drivers} = State) ->
    case maps:find(Index, Drivers) of
        {ok, Driver} -> Driver;
        error -> throw({?MODULE, unknown, State})
    end.

keep_driver({Index, _, _, _}, Driver, #{drivers := Drivers} = State) ->
    State#{drivers := Drivers#{Index := Driver}}.

%% --- The domain's edge -------------------------------------------------------

%% The pci_bus facet on the target: one call to the facet erx:cap/1 finds,
%% answered when the device service answers, or {error, no_facet} when the
%% domain holds none. A facet whose server has ended, or an answer later
%% than ?BUS_TIMEOUT_MS, exits the call, and so ends the domain.
bus(Request) ->
    case erx:cap(pci_bus) of
        Facet when is_pid(Facet) -> gen_server:call(Facet, Request, ?BUS_TIMEOUT_MS);
        undefined -> {error, no_facet}
    end.

%% A bridge's driver on the target ("The bridge seam"): the device record of
%% role `configuration` whose INDEX is the bridge's manifest device row,
%% opened, and the driver module its peripheral names started over it. A
%% bridge with no such record, or whose peripheral has no driver module,
%% opens nothing, and the start, which logs the reason, reports none of
%% its functions.
open(#{index := Index} = Bridge) ->
    case configuration(Index, maps:keys(?BRIDGE_DRIVERS), []) of
        {ok, Peripheral, Spec} -> start_driver(maps:get(Peripheral, ?BRIDGE_DRIVERS), Bridge, Spec);
        {error, _} = Error -> Error
    end.

%% The one device record of role configuration, of one of Peripherals,
%% whose INDEX is Index; a record that does not parse refuses them all.
configuration(Index, [Peripheral | Rest], Found) ->
    case erx_device_record:find(configuration, Peripheral) of
        {ok, Specs} -> configuration(Index, Rest, [{Peripheral, S} || #{index := I} = S <- Specs, I =:= Index] ++ Found);
        {error, _} = Error -> Error
    end;
configuration(_Index, [], [{Peripheral, Spec}]) ->
    {ok, Peripheral, Spec};
configuration(_Index, [], []) ->
    {error, no_configuration_record};
configuration(_Index, [], [_, _ | _]) ->
    {error, two_configuration_records}.

start_driver(none, _Bridge, _Spec) ->
    {error, no_driver_module};
start_driver(Module, Bridge, Spec) ->
    case erx_device:open(Spec) of
        {ok, Device} -> started(Module, Module:start(Bridge, Device));
        {error, Reason} -> {error, {open, Reason}}
    end.

started(Module, {ok, State}) -> {ok, {Module, State}};
started(_Module, {error, _} = Error) -> Error.

%% --- Records -----------------------------------------------------------------

%% A layout the enumerator drives: one its placing walk found ready, or
%% that its bridge held back. Only these are started, set or reset, so no
%% plan turns decoding on over a BAR placement left at address 0.
drivable(#{state := State}) -> State =:= ready orelse State =:= not_ready.

key(#{bridge := Bridge, bus := Bus, device := Device, function := Function}) -> {Bridge, Bus, Device, Function}.

place(#{bus := Bus, device := Device, function := Function}) -> {Bus, Device, Function}.

off() -> #{mode => off, route => none, message => #{address => 0, data => 0}}.
