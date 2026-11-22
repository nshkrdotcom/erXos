%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devices_pci_core).
-moduledoc """
The decisions of the device service's PCIe process (docs/design-pcie.md,
"Facets", "The catalogue and gives", "Concurrency"), pure functions over
what the domain library answers: every host bridge's catalogue,
erx_domain_lib:pci_bridges/0, and the device catalogue,
erx_domain_lib:devices/0, whose `pci` rows carry their place and setting.

**`targets`** answers each bridge's `erx_pcie_bridge` record, the records
of its layouts and every `pci` row's setting by its place, read from the
library alone, so the PCIe domain starts from what the library holds.

**The answer to `report`** hands each bridge the report's records whose
`bridge` is its row (reports/2), so a record naming a bridge the library
does not hold reaches no intake, and lowers to `off` every `pci` row whose
function the catalogue, as the intake left it, does not keep, and every
one the start turned off (lowered/3). The first rule reads the library's
catalogue alone: one with no layout, one its latest report did not list
with its layout (`confirmed`), and one that report did not find `ready`,
so a report the intake refused whole, which leaves every layout of its
bridge unconfirmed, and a function the walk left unreported past
`pcie_functions_max` are lowered whatever the start says it kept. The
second keeps the library's setting the function's own when the start
found it disturbed and turned it off with its record unchanged. A
setting above `off` stays only on a function the library could give now
and the start left at it.

**The phases** ("Concurrency"): `between`, when no incarnation's report has
been answered since the last answered one ended; `{synced, Id, Facet}`, once
incarnation Id's report was answered and Facet is its `pcie`; and `down`,
5 s in `between`. A holder's request waits `between`, is handled `synced`
and is answered `{error, unavailable}` `down` (request/3). Its place is
matched against the grantee's own rows alone. Two orders keep the library
from saying more than a function was asked for: a lowering (a holder's end,
holder_ended/2, and the first step of a `reset`) is written to the library
before it is sent, and a raise (`open`, `master`) only on the enumerator's
`ok` (pcie_answer/4), so a timed-out raise is never written. A call the
incarnation's end failed waits again, for the next answered incarnation.

**After a restart** the process cannot learn from a facet's presence
whether a report was answered, so it reads the library's `answered`
(resume/2): an incarnation a bridge records as answered that still holds
the bridge is waited for with `await_grant`, and its facet begins `synced`
(resumed/5) with every `pci` row the library holds at `off` sent `off`,
since a holder's end forwarded while the process restarted reached no
one. With none, the process begins `between`.

The functions return actions for the process to perform in order:
`{mode, Index, Mode}`, erx_domain_lib:pci_mode/2; `{pcie, Facet, Call,
Then}`, a `pcie` call whose answer goes to pcie_answer(Then, Answer);
`{reply, From, Answer}`; `{arm_down, Since}`, the 5 s timer of the
`between` that Since's end began, which a later `between` does not take;
and `{firmware, Request}`, a `firmware` request handed to the firmware
worker, which answers it with the request it was handed.

**`firmware`** requests queue in arrival order (firmware/3), a bridge row
the library does not hold refused, and the worker is handed the next only
after the last one's answer (firmware_answered/3), which must answer the
first request queued, so one request is in the kernel at a time (docs/design-system.md, "Firmware requests").
While a request is in flight a `report` waits for its answer
(report_waits/1).
""".

-export([targets/2, reports/2, unlisted/2, lowered/3, settings/1]).
-export([request/3, pcie_answer/4, holder_ended/2, answered/4, incarnation_ended/2, down_timer/3,
         resume/2, resumed/5]).
-export([firmware/3, firmware_answered/3, report_waits/1]).
-export_type([place/0, phase/0, request/0, action/0, then/0, firmware_request/0]).

-doc "A function by its host bridge's device row and its place, as erx_domain_lib:pci_place() spells it.".
-type place() :: erx_domain_lib:pci_place().

-doc """
Whether a PCIe incarnation's report was answered, and its `pcie` facet if
so; `between` names the incarnation whose end began it, or `start` for the
process's own start.
""".
-type phase() :: {between, Since :: pos_integer() | start} | down | {synced, Id :: pos_integer(), Facet :: term()}.

-doc "A holder's `pci` request, as its facet forwarded it with the grantee it was minted for.".
-type request() :: #{from := term(), grantee := pos_integer(),
                     operation := {open | master | reset, place()}}.

-doc """
What a `pcie` call's answer completes: a raise to write and answer; a reset,
which leaves the function `decoding` (docs/design-pcie.md, "Who programs
what, and when"), so its ok raises the library to `decoding` for the
driver's `master` after it; or a lowering.
""".
-type then() :: {raise, request(), Index :: non_neg_integer(), decoding | mastering}
              | {reset, request(), Index :: non_neg_integer()} | lowering.

-type pcie_call() :: {set, place(), erx_abi_layout:erx_pcie_setting()} | {reset, place()}.

-doc "An effect for the device service's PCIe process to perform, in order.".
-type action() :: {mode, Index :: non_neg_integer(), erx_abi_enums:pcie_mode()}
                | {pcie, Facet :: term(), pcie_call(), then()}
                | {reply, From :: term(), term()}
                | {arm_down, pos_integer() | start}
                | {firmware, firmware_request()}.

-doc "A `pci_bus:firmware/1` request: its caller and the bridge row it names.".
-type firmware_request() :: {From :: term(), Bridge :: non_neg_integer()}.

%% A function as the PCIe domain's start reports it, its record and whether
%% the start kept it at its setting; the enumerator owns the type.
-type reported() :: erx_pcie_enumerator:reported().

-doc """
The answer to `targets`: each bridge's record and its layouts' records, in
the library's order, and every `pci` row's setting by its place.
""".
-spec targets([erx_domain_lib:pci_catalogue()], [erx_domain_lib:device()]) ->
          {ok, [erx_abi_layout:erx_pcie_bridge()], [erx_abi_layout:erx_pcie_function()],
           #{place() => erx_abi_layout:erx_pcie_setting()}}.
targets(Catalogues, Devices) ->
    {ok, [Bridge || #{bridge := Bridge} <- Catalogues],
     [Record || #{layouts := Layouts} <- Catalogues, #{record := Record} <- Layouts],
     settings(Devices)}.

-doc """
The report split for the library's intake: each held bridge's row with the
report's records whose `bridge` is that row, in report order, a bridge the
report has none for included, since an empty report leaves its layouts
unconfirmed; and the records naming a bridge the library does not hold,
which no intake takes.
""".
-spec reports([reported()], [erx_domain_lib:pci_catalogue()]) ->
          {[{non_neg_integer(), [erx_abi_layout:erx_pcie_function()]}], Unheld :: [erx_abi_layout:erx_pcie_function()]}.
reports(Reported, Catalogues) ->
    Held = held_bridges(Catalogues),
    Records = [Record || #{record := Record} <- Reported],
    {[{Index, [R || #{bridge := B} = R <- Records, B =:= Index]} || Index <- Held],
     [R || #{bridge := B} = R <- Records, not lists:member(B, Held)]}.

-doc "The report's records at a place no `pci` row names, which stay off.".
-spec unlisted([reported()], [erx_domain_lib:device()]) -> [erx_abi_layout:erx_pcie_function()].
unlisted(Reported, Devices) ->
    Places = settings(Devices),
    [Record || #{record := Record} <- Reported, not is_map_key(place(Record), Places)].

-doc """
Every `pci` row to lower, by device row: one whose function the
catalogues do not keep, with no layout at its place, on a bridge marked
`firmware_lost`, or with a layout the latest report did not confirm or did
not find `ready`; and one whose function the start reports it did not keep
at its setting, which it left off.
""".
-spec lowered([erx_domain_lib:pci_catalogue()], [erx_domain_lib:device()], [reported()]) -> [non_neg_integer()].
lowered(Catalogues, Devices, Reported) ->
    Kept = #{place(Record) => kept
             || #{layouts := Layouts, firmware_lost := false} <- Catalogues,
                #{record := Record, confirmed := true, state := ready} <- Layouts},
    Off = #{place(Record) => off || #{record := Record, kept := false} <- Reported},
    [Index || #{index := Index, place := Place} <- Devices, Place =/= none,
              not is_map_key(Place, Kept) orelse is_map_key(Place, Off)].

-doc """
A `firmware` request over Queue, the requests not yet answered, the first
of them in the firmware worker (docs/design-system.md, "Firmware
requests"): `{error, not_held}` for a bridge row the library does not hold
for the PCIe domain; otherwise queued, and handed to the worker at once
when nothing was queued.
""".
-spec firmware(firmware_request(), [firmware_request()], [erx_domain_lib:pci_catalogue()]) ->
          {[firmware_request()], [action()]}.
firmware({From, Bridge} = Request, Queue, Catalogues) ->
    case {lists:member(Bridge, held_bridges(Catalogues)), Queue} of
        {false, _} -> {Queue, [{reply, From, {error, not_held}}]};
        {true, []} -> {[Request], [{firmware, Request}]};
        {true, _} -> {Queue ++ [Request], []}
    end.

-doc """
The worker's Answer to Request, the first request of Queue, which no other
answer matches: replied to its caller, and the next request, if any,
handed to the worker.
""".
-spec firmware_answered(firmware_request(), term(), [firmware_request(), ...]) ->
          {[firmware_request()], [action()]}.
firmware_answered({From, _Bridge} = Request, Answer, [Request | Rest]) ->
    Next = case Rest of
               [] -> [];
               [Waiting | _] -> [{firmware, Waiting}]
           end,
    {Rest, [{reply, From, Answer} | Next]}.

-doc """
Whether a `report` waits, over Queue, the firmware requests not yet
answered (docs/design-fiasco.md, "The firmware request"). The library
marks a bridge whose notification timed out `firmware_lost` only after
the request returns, so until its answer the bridge may look usable to
the intake. A report waits for any request in flight, not only one on a
bridge it names, since it hands every held bridge an intake (reports/2).
""".
-spec report_waits([firmware_request()]) -> boolean().
report_waits([_InFlight | _]) -> true;
report_waits([]) -> false.

%% The bridge rows the library holds, every one the PCIe domain's, since only it
%% holds a bridge's unit (docs/design-pcie.md, "The manifest").
held_bridges(Catalogues) ->
    [Index || #{bridge := #{index := Index}} <- Catalogues].

-doc "Every `pci` row's setting by its place.".
-spec settings([erx_domain_lib:device()]) -> #{place() => erx_abi_layout:erx_pcie_setting()}.
settings(Devices) ->
    #{Place => Setting || #{place := Place, setting := Setting} <- Devices, Place =/= none}.

-doc """
A holder's request in Phase over the device catalogue: wait `between`,
`{error, unavailable}` `down`, and `synced` its actions. A place no row of
the grantee names is `{error, not_held}`; `master` while the library's
mode is `off` is `{error, order}`. The facet's decoder has held the
request to request()'s shape.
""".
-spec request(request(), phase(), [erx_domain_lib:device()]) -> wait | [action()].
request(_Request, {between, _}, _Devices) ->
    wait;
request(#{from := From}, down, _Devices) ->
    [{reply, From, {error, unavailable}}];
request(#{from := From, operation := {Operation, Place}} = Request, {synced, _, Facet}, Devices) ->
    case held_row(Request, Devices) of
        #{index := Index, setting := Setting} -> handled(Operation, Request, {Index, Place, Setting}, Facet);
        none -> [{reply, From, {error, not_held}}]
    end.

%% The grantee's own row at the request's place, or none.
held_row(#{grantee := Grantee, operation := {_, Place}}, Devices) ->
    case [Row || #{holder := Holder, place := At} = Row <- Devices,
                 Holder =:= Grantee, At =:= Place, At =/= none] of
        [Row] -> Row;
        [] -> none
    end.

handled(open, Request, {Index, Place, Setting}, Facet) ->
    [{pcie, Facet, {set, Place, Setting#{mode := decoding}}, {raise, Request, Index, decoding}}];
handled(master, #{from := From}, {_, _, #{mode := off}}, _Facet) ->
    [{reply, From, {error, order}}];
handled(master, Request, {Index, Place, Setting}, Facet) ->
    [{pcie, Facet, {set, Place, Setting#{mode := mastering}}, {raise, Request, Index, mastering}}];
handled(reset, Request, {Index, Place, _Setting}, Facet) ->
    [{mode, Index, off}, {pcie, Facet, {reset, Place}, {reset, Request, Index}}].

-doc """
The actions a `pcie` answer completes in Phase over the device catalogue,
and the request to wait again, or none. Answer is `ended` when the call
failed because the incarnation ended, `timeout` past its 2 s deadline, or
the enumerator's. A call `ended` failed is handled again at once in a
later `synced`, and waits otherwise. A raise, and a reset's `decoding`, is
written only on `ok` and only while the requester still holds the row, so
the library never says more than a living holder was answered.
""".
-spec pcie_answer(then(), ok | {ok, flr | none} | {error, term()} | ended | timeout, phase(),
                  [erx_domain_lib:device()]) -> {[action()], request() | none}.
pcie_answer(lowering, _Answer, _Phase, _Devices) ->
    {[], none};
pcie_answer(Then, ended, {synced, _, _} = Phase, Devices) ->
    {request(request_of(Then), Phase, Devices), none};
pcie_answer(Then, ended, _Phase, _Devices) ->
    {[], request_of(Then)};
pcie_answer(Then, timeout, _Phase, _Devices) ->
    {[{reply, from(Then), {error, unavailable}}], none};
pcie_answer({raise, #{from := From} = Request, Index, Mode}, ok, _Phase, Devices) ->
    {raised(Request, Index, Mode, Devices) ++ [{reply, From, ok}], none};
pcie_answer({reset, #{from := From} = Request, Index}, {ok, Kind}, _Phase, Devices) ->
    {raised(Request, Index, decoding, Devices) ++ [{reply, From, {ok, Kind}}], none};
pcie_answer(Then, Answer, _Phase, _Devices) ->
    {[{reply, from(Then), Answer}], none}.

raised(Request, Index, Mode, Devices) ->
    case held_row(Request, Devices) of
        #{index := Index} -> [{mode, Index, Mode}];
        _ -> []
    end.

request_of({raise, Request, _, _}) -> Request;
request_of({reset, Request, _}) -> Request.

from(Then) -> maps:get(from, request_of(Then)).

-doc """
A holder's end: each `pci` row it held, as the process recorded it at the
give, lowered to `off` in the library, its route staying the give's, and
sent after only with an answered incarnation; otherwise the next start's
`targets` or `report` carries it.
""".
-spec holder_ended([erx_domain_lib:device()], phase()) -> [action()].
holder_ended(Rows, Phase) ->
    Lowered = [{Index, Place, Setting#{mode := off}}
               || #{index := Index, place := Place, setting := Setting} <- Rows],
    [{mode, Index, off} || {Index, _, _} <- Lowered] ++
        case Phase of
            {synced, _, Facet} -> [{pcie, Facet, {set, Place, Off}, lowering} || {_, Place, Off} <- Lowered];
            _ -> []
        end.

-doc "Incarnation Id's report answered with Facet: synced, and every waiting request handled in order.".
-spec answered(pos_integer(), term(), [request()], [erx_domain_lib:device()]) -> {phase(), [action()]}.
answered(Id, Facet, Waiting, Devices) ->
    Phase = {synced, Id, Facet},
    {Phase, lists:append([request(Request, Phase, Devices) || Request <- Waiting])}.

-doc """
How a restarted process begins, from the library's catalogues and device
catalogue: `{await, D}` when a bridge records incarnation D as answered and
D holds that bridge's device row; `between` otherwise. Domain ids are never
reused in a boot, so an ended incarnation's `answered` names no holder.
""".
-spec resume([erx_domain_lib:pci_catalogue()], [erx_domain_lib:device()]) -> {await, pos_integer()} | between.
resume(Catalogues, Devices) ->
    Holders = #{Index => Holder || #{index := Index, holder := Holder} <- Devices},
    case [D || #{bridge := #{index := Bridge}, answered := D} <- Catalogues,
               is_integer(D), maps:get(Bridge, Holders, none) =:= D] of
        [D | _] -> {await, D};
        [] -> between
    end.

-doc """
A restarted process's wait for answered incarnation Id answered with Facet,
in Phase: `synced`, every `pci` row the library holds at `off` sent `off`,
then every waiting request handled in order. A Phase already `synced`, by a
later incarnation's answered report, stays, and handles them.
""".
-spec resumed(pos_integer(), term(), phase(), [request()], [erx_domain_lib:device()]) -> {phase(), [action()]}.
resumed(_Id, _Facet, {synced, _, _} = Phase, Waiting, Devices) ->
    {Phase, lists:append([request(Request, Phase, Devices) || Request <- Waiting])};
resumed(Id, Facet, _Phase, Waiting, Devices) ->
    {Synced, Handled} = answered(Id, Facet, Waiting, Devices),
    {Synced, [{pcie, Facet, {set, Place, Setting}, lowering}
              || #{place := Place, setting := #{mode := off} = Setting} <- Devices, Place =/= none] ++ Handled}.

-doc "Incarnation Id's end: `between`, with its 5 s timer armed, if Id is the answered one.".
-spec incarnation_ended(pos_integer(), phase()) -> {phase(), [action()]}.
incarnation_ended(Id, {synced, Id, _}) -> {{between, Id}, [{arm_down, Id}]};
incarnation_ended(_Id, Phase) -> {Phase, []}.

-doc """
The 5 s timer Since's `between` armed: `down` if that `between` still
holds, every waiting request answered `{error, unavailable}`.
""".
-spec down_timer(pos_integer() | start, phase(), [request()]) -> {phase(), [action()]}.
down_timer(Since, {between, Since}, Waiting) ->
    {down, [{reply, From, {error, unavailable}} || #{from := From} <- Waiting]};
down_timer(_Since, Phase, _Waiting) ->
    {Phase, []}.

place(#{bridge := Bridge, bus := Bus, device := Device, function := Function}) ->
    {Bridge, Bus, Device, Function}.
