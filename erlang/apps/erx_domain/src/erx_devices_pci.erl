%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devices_pci).
-moduledoc """
The device service's PCIe process (docs/design-pcie.md, "Facets",
"Concurrency"): the one process that writes the library's PCIe settings and
calls the PCIe domain's `pcie`, so the settings the library holds and those
sent are written in one order. Every decision is erx_devices_pci_core's;
this module performs the actions it returns, in order, and keeps the state
the core is handed.

**What arrives.** The PCIe domain's `pci_bus` requests and every holder's
`pci` requests, each forwarded by its facet (erx_pci_bus_facet,
erx_pci_facet) with the grantee it was minted for, as `{pci_bus, D,
Operation}` and `{pci, Grantee, Operation}`; and the end of every domain,
which erx_domain_srv forwards as it takes the library's `domain_ended`
(domain_ended/2). A holder's end lowers the rows it held; the end of the
answered PCIe incarnation moves the core to `between`.

**`report`** goes through the library's intake per bridge the library
holds (erx_devices_pci_core:reports/2), every row lowered/3 names is
lowered to `off`, and only then is erx_domain:await_grant(pcie, D) sent,
not waited on; its answer, `{ok, Facet}`, answers the report with every
setting, tells the domain service it has answered
(erx_domain:pci_report_answered/0), which releases its hold at boot, and moves
the core to `synced`; any other answers `{error, unavailable}`.

**The rows a holder held** are those the process read from the library
with that holder (`held`, by holder and then row), recorded at every read
of the catalogue (read/1). A holder's entry goes only when its end
arrives, whatever later reads show, since the library clears a row's
holder at the end before it reports it, and the domain service may start
the holder's next incarnation, which holds the row again, before the
process takes the forwarded end; so the lowering is sent for every row a
living holder could have raised.

**`answered`.** The answer to a report writes the incarnation into the
library (erx_domain_lib:pci_answered/1) before it is sent, so a restarted
process reads which incarnation, if any, its predecessor answered
(erx_devices_pci_core:resume/2). While that incarnation still holds its
bridges, the process sends erx_domain:await_grant(pcie, D) and, on
`{ok, Facet}`, begins `synced` (erx_devices_pci_core:resumed/5); until
then, and on any other answer, it is `between`.

**A `pcie` call** is sent with gen_server:send_request/2 and a 2 s
deadline. The end of the facet before it answered is the end of the
incarnation it was made on; past the deadline the call is abandoned, its
late answer dropped. An answer outside the interface (`ok`, `{ok, flr |
none}`, or `{error, Reason}` with Reason one of the results "Refusals and
error results" names for `pcie`) is taken as `{error, failed}`, the
facet's own answer for a service that failed a request (erx_facet), so no
term of the PCIe domain's reaches a holder.

**`firmware`** (docs/design-system.md, "Firmware requests";
docs/design-pcie.md, "Facets") names a bridge row; one the library does not hold for
the PCIe domain is answered `{error, not_held}`. **`power`**, the line
service's erx_devices:power/2 (docs/design-bluetooth.md, "The power line"),
names a device row and its power line's phase; one naming a host bridge is
answered `{error, einval}`. Every other request is queued, and the
**firmware worker**, a process linked to this one, makes each in turn
through erx_domain_lib:pci_firmware/1 for a bridge, or
erx_domain_lib:device_notify/2 with the phase's row
(erx_devices_pci_core:power_row/1) for a power line, each of which waits in the
kernel, while this process goes on answering every other call. The
library's answer is the reply: `ok`, or `{error, Status}` naming the
kernel call's status. After `etimedout` the library has marked the
bridge `firmware_lost` before it answered, so its intake keeps none of
the bridge's functions for the rest of the boot. The worker's end ends
this process by their link, and their supervisor restarts both. Since
the library marks the bridge only after the request returns, while a
request is in flight this process takes no `report`, which hands every
held bridge an intake: it waits, parked, for the answer
(docs/design-fiasco.md, "The firmware request"). The
worker returns no reductions with its answer (TODO.md, the `erx_facet.erl`
item on admission by measured share).
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1, domain_ended/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% The deadline of a pcie call, past the longest reset (docs/design-pcie.md, "Concurrency").
-define(PCIE_DEADLINE, 2000).
%% How long the core stays between before it goes down.
-define(DOWN_AFTER, 5000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-doc """
Opts names a host test's stand-ins: lib, the domain library's module
(erx_domain_lib by default); await, the function of erx_domain:await_grant/2
(the default); and register, false to start the process unregistered.
""".
-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) ->
    case maps:get(register, Opts, true) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []);
        false -> gen_server:start_link(?MODULE, Opts, [])
    end.

-doc "Domain Id's end, as erx_domain_srv forwards it to Server, the process's name or pid.".
-spec domain_ended(gen_server:server_ref(), pos_integer()) -> ok.
domain_ended(Server, Id) ->
    gen_server:cast(Server, {domain_ended, Id}).

init(Opts) ->
    Lib = maps:get(lib, Opts, erx_domain_lib),
    Service = self(),
    %% Linked, so the end of either ends the other, and their supervisor restarts both.
    Worker = spawn_link(fun() -> firmware_worker(Service, Lib) end),
    State = #{lib => Lib,
              await => maps:get(await, Opts, fun erx_domain:await_grant/2),
              phase => {between, start}, waiting => [], held => #{},
              %% The firmware worker, and the firmware requests not yet answered, the first in it.
              worker => Worker, firmware => [],
              %% The reports held by the firmware request in flight, {D, Reported, From}, in
              %% arrival order.
              parked => [],
              %% Outstanding pcie calls, and await_grant waits, {report, From, D} for a report's
              %% answer or {resume, D} for a restart's, by request id.
              calls => #{}, reports => #{}},
    {Devices, Read} = read(State),
    Armed = act({arm_down, start}, Read),
    {ok, resume(erx_devices_pci_core:resume(catalogues(Lib), Devices), Armed)}.

%% A restarted process waits for the facet of the incarnation its predecessor answered.
resume({await, D}, #{await := Await, reports := Reports} = State) ->
    State#{reports := Reports#{Await(pcie, D) => {resume, D}}};
resume(between, State) ->
    State.

handle_call({pci, Grantee, Operation}, From, #{phase := Phase, waiting := Waiting} = State) ->
    {Devices, Read} = read(State),
    Request = #{from => From, grantee => Grantee, operation => Operation},
    case erx_devices_pci_core:request(Request, Phase, Devices) of
        wait -> {noreply, Read#{waiting := Waiting ++ [Request]}};
        Actions -> {noreply, perform(Actions, Read)}
    end;
handle_call({pci_bus, _D, targets}, _From, #{lib := Lib} = State) ->
    {Devices, Read} = read(State),
    {reply, erx_devices_pci_core:targets(catalogues(Lib), Devices), Read};
handle_call({pci_bus, D, {report, Reported}}, From, State) ->
    {noreply, report_or_park({D, Reported, From}, State)};
handle_call({pci_bus, _D, {firmware, Bridge}}, From, State) ->
    {noreply, firmware({From, {bridge, Bridge}}, State)};
handle_call({power, Device, Phase}, From, State)
  when is_integer(Device), Device >= 0, Device =< 16#ffffffff, (Phase =:= off orelse Phase =:= on) ->
    {noreply, firmware({From, {power, Device, Phase}}, State)}.

handle_cast({domain_ended, Id}, #{phase := Phase, held := Held} = State) ->
    {Rows, Kept} = case maps:take(Id, Held) of
                       {ByIndex, Others} -> {maps:values(ByIndex), Others};
                       error -> {[], Held}
                   end,
    %% The holder's lowerings go on the phase they were decided in, then the phase moves.
    Lowered = perform(erx_devices_pci_core:holder_ended(Rows, Phase), State#{held := Kept}),
    {Next, Ended} = erx_devices_pci_core:incarnation_ended(Id, Phase),
    {noreply, perform(Ended, Lowered#{phase := Next})}.

handle_info({timeout, _Timer, {down, Since}}, #{phase := Phase, waiting := Waiting} = State) ->
    {Next, Actions} = erx_devices_pci_core:down_timer(Since, Phase, Waiting),
    Left = case Next of
               down -> [];
               _ -> Waiting
           end,
    {noreply, perform(Actions, State#{phase := Next, waiting := Left})};
handle_info({timeout, _Timer, {pcie_deadline, ReqId}}, #{calls := Calls} = State) ->
    case Calls of
        #{ReqId := {Then, _Timer2, _Id}} ->
            %% Abandoned: the monitor and the alias go, so a late answer never arrives.
            erlang:demonitor(ReqId, [flush]),
            {noreply, pcie_answered(Then, timeout, State#{calls := maps:remove(ReqId, Calls)})};
        #{} ->
            {noreply, State}
    end;
handle_info({firmware_answered, Worker, Request, Answer},
            #{worker := Worker, firmware := Queue, parked := Parked} = State) ->
    {Left, Actions} = erx_devices_pci_core:firmware_answered(Request, Answer, Queue),
    Answered = perform(Actions, State#{firmware := Left, parked := []}),
    %% Taken again in arrival order; one the next request in flight holds parks again.
    {noreply, lists:foldl(fun report_or_park/2, Answered, Parked)};
handle_info(Message, State) ->
    {noreply, response(Message, State)}.

firmware(Request, #{lib := Lib, firmware := Queue} = State) ->
    {Queued, Actions} = erx_devices_pci_core:firmware(Request, Queue, catalogues(Lib)),
    perform(Actions, State#{firmware := Queued}).

%% The in-flight rule (erx_devices_pci_core:report_waits/1): a report taken while a
%% firmware request is in flight parks until its answer.
report_or_park({D, Reported, From} = Report, #{firmware := Queue, parked := Parked} = State) ->
    case erx_devices_pci_core:report_waits(Queue) of
        true -> State#{parked := Parked ++ [Report]};
        false -> report(D, Reported, From, State)
    end.

%% The answer to a report: the intake per held bridge, the rows lowered, then the
%% wait for the incarnation's pcie facet.
report(D, Reported, From, #{lib := Lib, await := Await, reports := Reports} = State) ->
    {Devices, Read} = read(State),
    {PerBridge, Unheld} = erx_devices_pci_core:reports(Reported, catalogues(Lib)),
    [intake(Lib, Bridge, Records) || {Bridge, Records} <- PerBridge],
    [logger:notice("erx_devices_pci: a PCIe report names bridge ~b, which the library does not hold",
                   [Bridge]) || #{bridge := Bridge} <- Unheld],
    [logger:notice("erx_devices_pci: no pci row names the function at ~0p; it stays off",
                   [{B, Bus, Dev, Fn}])
     || #{bridge := B, bus := Bus, device := Dev, function := Fn} <- erx_devices_pci_core:unlisted(Reported, Devices)],
    Lowered = erx_devices_pci_core:lowered(catalogues(Lib), Devices, Reported),
    Done = perform([{mode, Index, off} || Index <- Lowered], Read),
    Done#{reports := Reports#{Await(pcie, D) => {report, From, D}}}.

intake(Lib, Bridge, Records) ->
    case Lib:pci_report(Bridge, Records) of
        ok -> ok;
        {error, Refusal} ->
            logger:error("erx_devices_pci: the library refused bridge ~b's report whole: ~0p", [Bridge, Refusal])
    end.

%% The answer a message completes: a report's wait for its facet, or a pcie call.
response(Message, #{reports := Reports, calls := Calls} = State) ->
    case {answer(Message, Reports), answer(Message, Calls)} of
        {{ReqId, Answer}, none} -> grant_answered(maps:get(ReqId, Reports), Answer,
                                                  State#{reports := maps:remove(ReqId, Reports)});
        {none, {ReqId, Answer}} ->
            {Then, Timer, Id} = maps:get(ReqId, Calls),
            _ = erlang:cancel_timer(Timer),
            pcie_ended_or_answered(Then, Id, Answer, State#{calls := maps:remove(ReqId, Calls)});
        {none, none} -> State
    end.

%% The request id Message answers among Pending's, and its answer, or none.
answer(Message, Pending) ->
    Answers = [{ReqId, gen_server:check_response(Message, ReqId)} || ReqId := _ <- Pending],
    case [Answered || {_ReqId, Answer} = Answered <- Answers, Answer =/= no_reply] of
        [Answered] -> Answered;
        [] -> none
    end.

grant_answered({resume, D}, {reply, {ok, Facet}}, #{phase := Phase, waiting := Waiting} = State) ->
    {Devices, Read} = read(State),
    {Next, Actions} = erx_devices_pci_core:resumed(D, Facet, Phase, Waiting, Devices),
    perform(Actions, Read#{phase := Next, waiting := []});
grant_answered({resume, D}, Answer, State) ->
    logger:notice("erx_devices_pci: answered PCIe domain ~b is not resumed, its pcie facet: ~0p", [D, Answer]),
    State;
grant_answered({report, From, D}, {reply, {ok, Facet}}, #{lib := Lib, waiting := Waiting, reports := Reports} = State) ->
    {Devices, Read} = read(State),
    %% Written before it is sent, so a restart never misses an answered incarnation.
    case Lib:pci_answered(D) of
        ok -> ok;
        {error, Reason} -> logger:error("erx_devices_pci: the library refused answered ~b: ~0p", [D, Reason])
    end,
    gen_server:reply(From, {ok, erx_devices_pci_core:settings(Devices)}),
    %% The answer releases the domain service's hold at boot (docs/design-pcie.md, "The hold at boot").
    ok = erx_domain:pci_report_answered(),
    {Phase, Actions} = erx_devices_pci_core:answered(D, Facet, Waiting, Devices),
    %% A restart's wait for an earlier incarnation no longer decides the phase.
    Left = maps:filter(fun(_ReqId, Wait) -> element(1, Wait) =/= resume end, Reports),
    perform(Actions, Read#{phase := Phase, waiting := [], reports := Left});
grant_answered({report, From, D}, Answer, State) ->
    logger:error("erx_devices_pci: PCIe domain ~b's report is not answered, its pcie facet: ~0p", [D, Answer]),
    gen_server:reply(From, {error, unavailable}),
    State.

%% A pcie call's end: the facet's end before it answered is the end of incarnation Id.
pcie_ended_or_answered(Then, Id, {error, _Down}, #{phase := Phase} = State) ->
    {Next, Ended} = erx_devices_pci_core:incarnation_ended(Id, Phase),
    pcie_answered(Then, ended, perform(Ended, State#{phase := Next}));
pcie_ended_or_answered(Then, _Id, {reply, Answer}, State) ->
    pcie_answered(Then, interface(Answer), State).

pcie_answered(Then, Answer, #{phase := Phase, waiting := Waiting} = State) ->
    {Devices, Read} = read(State),
    {Actions, Again} = erx_devices_pci_core:pcie_answer(Then, Answer, Phase, Devices),
    perform(Actions, Read#{waiting := Waiting ++ [Request || Request <- [Again], Request =/= none]}).

%% The enumerator's answer as the interface spells it; anything else is a failure.
interface(ok) -> ok;
interface({ok, Kind}) when Kind =:= flr; Kind =:= none -> {ok, Kind};
interface({error, Reason}) when Reason =:= gone; Reason =:= stuck; Reason =:= reset; Reason =:= busy;
                                Reason =:= route; Reason =:= unknown -> {error, Reason};
interface(_Answer) -> {error, failed}.

perform(Actions, State) ->
    lists:foldl(fun act/2, State, Actions).

act({mode, Index, Mode}, #{lib := Lib} = State) ->
    case Lib:pci_mode(Index, Mode) of
        ok -> ok;
        {error, Reason} ->
            logger:error("erx_devices_pci: the library refused mode ~ts for row ~b: ~0p", [Mode, Index, Reason])
    end,
    State;
act({pcie, Facet, Call, Then}, #{phase := Phase, calls := Calls} = State) ->
    ReqId = gen_server:send_request(Facet, Call),
    Timer = erlang:start_timer(?PCIE_DEADLINE, self(), {pcie_deadline, ReqId}),
    State#{calls := Calls#{ReqId => {Then, Timer, incarnation(Phase)}}};
act({reply, From, Answer}, State) ->
    gen_server:reply(From, Answer),
    State;
act({arm_down, Since}, State) ->
    _ = erlang:start_timer(?DOWN_AFTER, self(), {down, Since}),
    State;
act({firmware, Request}, #{worker := Worker} = State) ->
    Worker ! {firmware, Request},
    State.

%% The firmware worker (docs/design-system.md, "Firmware requests"): the one caller
%% of the library's firmware entries, dirty I/O NIFs that wait in the kernel up to
%% the request's 1 s deadline, so the process never waits there. It takes one
%% request, sends its answer with the request, and takes the next.
firmware_worker(Service, Lib) ->
    receive
        {firmware, {_From, Asked} = Request} ->
            Service ! {firmware_answered, self(), Request, library_call(Lib, Asked)},
            firmware_worker(Service, Lib)
    end.

%% The library entry each request names: a bridge's notification, or the row of a
%% power line's phase among its device's notifications.
library_call(Lib, {bridge, Bridge}) -> Lib:pci_firmware(Bridge);
library_call(Lib, {power, Device, Phase}) -> Lib:device_notify(Device, erx_devices_pci_core:power_row(Phase)).

%% The core sends pcie calls only synced, on the answered incarnation's facet.
incarnation({synced, Id, _Facet}) -> Id.

%% The library's device catalogue, and the state with every row a living holder
%% holds recorded in held under that holder, the earlier entries kept until
%% their holder's end.
read(#{lib := Lib, held := Held} = State) ->
    Devices = case Lib:devices() of
                  {ok, Read} -> Read;
                  {error, Reason} ->
                      logger:error("erx_devices_pci: the library's device catalogue is unreadable: ~0p", [Reason]),
                      []
              end,
    Recorded = lists:foldl(fun(#{index := Index, holder := Holder} = Row, ByHolder) ->
                                   maps:update_with(Holder, fun(Rows) -> Rows#{Index => Row} end,
                                                    #{Index => Row}, ByHolder)
                           end, Held,
                           [Row || #{holder := Holder, place := Place} = Row <- Devices,
                                   is_integer(Holder), Place =/= none]),
    {Devices, State#{held := Recorded}}.

catalogues(Lib) ->
    case Lib:pci_bridges() of
        {ok, Catalogues} -> Catalogues;
        {error, Reason} ->
            logger:error("erx_devices_pci: the library's PCIe catalogue is unreadable: ~0p", [Reason]),
            []
    end.
