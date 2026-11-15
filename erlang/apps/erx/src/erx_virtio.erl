%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_virtio).
-moduledoc """
What every virtio-mmio driver checks the same way: whether its transport's first registers
say the device it drives (virtio 1.2, sections 4.2.2.2 and 4.2.3.1.1), the first check a
driver makes once it has opened its device.

The module reaches no device: a driver hands it a fun that reads one of its own device's
registers by name through the device NIF, so the driver applications stay the only code
that names the NIF (the device-callers chokepoint), and the cases run on the host over a
map (test/erlang/erx_virtio_tests.erl).
""".

-export([identify/2]).

-export_type([reason/0]).

-include("generated/erx_abi.hrl").

-doc """
Why a transport is refused: `no_device` for an empty one, or the identification word that
disagreed, with the value read.
""".
-type reason() :: no_device | {magic | version | device_id, non_neg_integer()}.

-doc """
Whether the transport `Read` reads is a virtio-mmio version 2 device of `DeviceId`.

The magic is checked first, then device id 0, an empty transport, then the version and the
device id. A driver must ignore an empty transport without reporting an error (section
4.2.2.2), so it is `no_device` whatever version it reports: QEMU's transports offer the
legacy interface (version 1) unless told otherwise, and an empty one is no device, not a
device of the wrong version. A driver ignores `no_device` with no log line, and logs any
other reason once.
""".
-spec identify(fun((magic | version | device_id) -> non_neg_integer()), pos_integer()) ->
          ok | {error, reason()}.
identify(Read, DeviceId) ->
    Magic = Read(magic),
    Version = Read(version),
    Found = Read(device_id),
    if
        Magic =/= ?ERX_VIRTIO_MMIO_MAGIC -> {error, {magic, Magic}};
        Found =:= 0 -> {error, no_device};
        Version =/= ?ERX_VIRTIO_MMIO_VERSION -> {error, {version, Version}};
        Found =/= DeviceId -> {error, {device_id, Found}};
        true -> ok
    end.
