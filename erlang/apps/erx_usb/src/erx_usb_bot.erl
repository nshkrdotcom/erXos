%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bot).
-moduledoc """
The mass-storage function (docs/design-usb.md, "The BOT engine"), the
driver the claim table names for a Bulk-Only interface. The function that
drives one over `erx_usb_bot_core` is not built, so its start fails as
unusable with `enotsup`: the bus takes that end as final, as a FreeBSD
probe that answers ENXIO, so the interface stays unused while its device
stays and the device's other functions run on.
""".

-export([start_link/1]).

-doc "Starts no function: answers `{error, {shutdown, {unusable, enotsup}}}`.".
-spec start_link(erx_usb_bus:start()) -> {error, {shutdown, {unusable, enotsup}}}.
start_link(_Start) ->
    {error, erx_usb_bus_core:unusable(enotsup)}.
