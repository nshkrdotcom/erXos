%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_firmware_worker).
-moduledoc """
The device service's firmware request worker (docs/design-system.md,
"Firmware requests"): the one caller of erx_domain_lib:firmware/2, a dirty
I/O NIF that waits in the kernel up to the request's 1 s deadline, so the
device service's process, which queues the requests, never waits there.

The process that starts the worker (start_link/1), erx_devices_pci, is
linked to it, so the end of either ends the other and their supervisor
restarts both. That process keeps the one queue of requests not yet
answered, in arrival order, and hands the worker the next (request/2) only after the
last one's answer, `{firmware_answered, Worker, Request, Answer}`, so one
request is in the kernel at a time (erx_devices_pci_core:firmware/3,
firmware_answered/3). A request names what it asks of the library as
erx_domain_lib:firmware/2 takes it: a host bridge's notification, from the
PCIe domain's `pci_bus:firmware/1`, or a power line's phase, from the line
service's erx_devices:power/2 (docs/design-bluetooth.md, "The power line").
The library offers each only to its own kind of device row.
""".

-export([start_link/1, request/2, deadline/0]).
-export_type([request/0]).

-doc "A request: its caller, and the device row and request erx_domain_lib:firmware/2 takes.".
-type request() :: {From :: term(), {Device :: non_neg_integer(),
                                      bridge | {power, erx_abi_enums:fw_power_phase()}}}.

-doc """
Starts the worker, linked to the calling process, to which it sends each
answer; Lib is the domain library's module (erx_domain_lib, or a host test's
stand-in).
""".
-spec start_link(module()) -> pid().
start_link(Lib) ->
    Service = self(),
    spawn_link(fun() -> loop(Service, Lib) end).

-doc "Hands Worker one request; the caller hands the next only after this one's answer.".
-spec request(pid(), request()) -> ok.
request(Worker, Request) ->
    Worker ! {firmware, Request},
    ok.

-doc """
How long a caller of the system domain may wait for its request's answer, in
milliseconds: the request of each other caller queued ahead of it, one each,
and its own, each at most 1 s in the kernel (docs/design-system.md, "Firmware
requests").
""".
-spec deadline() -> pos_integer().
deadline() -> 5000.

loop(Service, Lib) ->
    receive
        {firmware, {_From, {Device, Asked}} = Request} ->
            Service ! {firmware_answered, self(), Request, Lib:firmware(Device, Asked)},
            loop(Service, Lib)
    end.
