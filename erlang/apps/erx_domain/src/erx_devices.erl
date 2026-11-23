%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devices).
-moduledoc """
The device service's calls for the system domain's own processes: the device
catalogue as the system domain presents it (docs/design-system.md,
"Devices"), what `/dev` and the inspector read, and power/2, the line
service's power requests, which erx_devices_pci's firmware worker makes. The
catalogue bears no authority. The
domain library's boot view (liberx/system/dom_boot_view.c) builds the
catalogue from the system manifest's placed devices, validates their
placement and gives each device as part of its holder's creation, so this
module validates nothing the view has not, keeps no state and gives nothing:
it hands on the view's catalogue, in the manifest's device order, unchanged.
""".

-export([catalogue/0, catalogue/1, power/2]).

%% How long a power request may take: the request of each other caller queued ahead of it
%% at the firmware worker, one each, and its own, each at most 1 s in the kernel
%% (docs/design-system.md, "Firmware requests").
-define(POWER_DEADLINE, 5000).

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
or `bt_on`. ok, or {error, Status} naming the kernel call's status, or einval for
a host bridge's row; the call exits past its deadline or when the device
service is down, which the line service takes as a failed reset. The line
service waits the off and on times itself.
""".
-spec power(non_neg_integer(), off | on) -> ok | {error, atom()}.
power(Device, Phase) when is_integer(Device), Device >= 0, Device =< 16#ffffffff, (Phase =:= off orelse Phase =:= on) ->
    gen_server:call(erx_devices_pci, {power, Device, Phase}, ?POWER_DEADLINE).
