%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devices).
-moduledoc """
The device service's calls for the system domain's own processes: the device
catalogue as the system domain presents it (docs/design-system.md,
"Devices"), what `/dev` and the inspector read, and power/2, the line
service's power requests, which the device service's firmware worker
(erx_firmware_worker) makes. The
catalogue bears no authority. The
domain library's boot view (liberx/system/dom_boot_view.c) builds the
catalogue from the system manifest's placed devices, validates their
placement and gives each device as part of its holder's creation, so this
module validates nothing the view has not, keeps no state and gives nothing:
it hands on the view's catalogue, in the manifest's device order, unchanged.

It also carries the domain service's two calls on the rows held at boot
(docs/design-system.md, "Waiting for a grant", "The rows held at boot"):
held_at_boot/1, which the device service's PCIe process answers, and
domain_ended/2, every end with its origin.
""".

-export([catalogue/0, catalogue/1, power/2, held_at_boot/1, domain_ended/2]).

-include("generated/erx_abi.hrl").

%% How long the domain service waits for the rows held at boot before it holds none.
-define(HELD_AT_BOOT_DEADLINE, 5000).

-doc """
The catalogue, from the domain library, or the library's error where the
system domain has none.
""".
-spec catalogue() -> {ok, [erx_domain_lib:device()]} | erx_domain_lib:error().
catalogue() ->
    catalogue(fun erx_domain_lib:devices/0).

-doc """
The catalogue Devices() answers, unchanged: Devices is erx_domain_lib:devices/0,
or a stand-in for tests.
""".
-spec catalogue(fun(() -> {ok, [erx_domain_lib:device()]} | erx_domain_lib:error())) ->
    {ok, [erx_domain_lib:device()]} | erx_domain_lib:error().
catalogue(Devices) when is_function(Devices, 0) ->
    Devices().

-doc """
Powers the power line of device row Device off or on (docs/design-bluetooth.md,
"The power line"), the line service's request: the device service's firmware
worker makes the device's notification of that phase, the Pi 4 UART0's `bt_off`
or `bt_on`. ok, or {error, Status} naming the kernel call's status, enotsup for
a device with no power line; the call exits past the worker's deadline
(erx_firmware_worker:deadline/0) or when the device
service is down, which the line service takes as a failed reset. The line
service waits the off and on times itself.
""".
-spec power(non_neg_integer(), erx_abi_enums:fw_power_phase()) -> ok | {error, atom()}.
power(Device, Phase) when is_integer(Device), Device >= 0, Device =< 16#ffffffff, ?ERX_IS_FW_POWER_PHASE(Phase) ->
    gen_server:call(erx_devices_pci, {power, Device, Phase}, erx_firmware_worker:deadline()).

-doc """
The rows held at boot among Rows, the configured rows in boot order, and the
fallback beside them (erx_devices_pci_core:held/2), as the device service's
PCIe process answers; {error, Reason} when the call fails or gets no answer
within 5 s, after which the domain service holds nothing.
""".
-spec held_at_boot([non_neg_integer()]) ->
          {ok, [non_neg_integer()], erx_devices_pci_core:fallback()} | {error, term()}.
held_at_boot(Rows) ->
    try gen_server:call(erx_devices_pci, {held_at_boot, Rows}, ?HELD_AT_BOOT_DEADLINE) of
        {Held, Fallback} -> {ok, Held, Fallback}
    catch
        exit:Reason -> {error, Reason}
    end.

-doc """
Domain Id's end, its origin Origin, as the domain service forwards every end
before it starts the domain's next incarnation (erx_devices_pci:domain_ended/3).
""".
-spec domain_ended(pos_integer(), erx_domain_core:origin() | none) -> ok.
domain_ended(Id, Origin) ->
    erx_devices_pci:domain_ended(erx_devices_pci, Id, Origin).
