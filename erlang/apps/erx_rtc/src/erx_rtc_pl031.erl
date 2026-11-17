%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_rtc_pl031).
-moduledoc """
The Arm PrimeCell RTC PL031's driver and, in the system domain, the
wall-clock keeper (docs/design-time.md, "The real-time clock at boot").
At boot it reads the data register, RTCDR, once: the count of seconds
the clock holds, which QEMU `virt` starts at the host's time (Arm DDI
0224C, section 3.3, "Data Register, RTCDR": a 32-bit read-only register
whose reads return the clock's current value). It sends the reading to
the clock service as `{rtc, Source, Wall}`, Wall in nanoseconds and
Source this domain, and erx_clock_core decides it: a reading at or past
the build's date steps a clock that is `unset` or `approximate`, and any
other reading changes nothing.

It never writes the clock: the hardware description it reads through,
hw/svd/pl031, names RTCDR alone, so erx_device has no other register of
the device to reach. start_link/1 does its one read and answers
`ignore`, so its supervisor keeps no process for it. A record erx_device
refuses, or a clock service that does not answer, is logged and leaves
the clock as the start left it, since the system can run without the
reading.
""".

-export([start_link/1]).

-define(NS_PER_S, 1000000000).
%% How long the keeper waits for the clock service's answer.
-define(CLOCK_WAIT_MS, 10000).

-doc "Reads the PL031 of Spec once, a device record of erx_device_record, and hands the reading to erx_clock.".
-spec start_link(erx_device_record:spec()) -> ignore.
start_link(#{path := Path} = Spec) ->
    try read(Spec) of
        {ok, Seconds} -> keep(Path, Seconds);
        {error, Reason} -> logger:warning("erx_rtc_pl031: ~ts refused: ~0p", [Path, Reason])
    catch
        Class:Error -> logger:warning("erx_rtc_pl031: ~ts not read: ~0p:~0p", [Path, Class, Error])
    end,
    ignore.

%% RTCDR's count, read once; a device that does not answer as a PL031 raises, which
%% start_link/1 logs.
read(Spec) ->
    case erx_device:open(Spec) of
        {ok, Device} -> {ok, erx_device:read(Device, dr)};
        {error, _Reason} = Refused -> Refused
    end.

keep(Path, Seconds) ->
    Request = {rtc, erx_kernel_records:system_domain(), Seconds * ?NS_PER_S},
    try gen_server:call(erx_clock, Request, ?CLOCK_WAIT_MS) of
        Answer -> logger:info("erx_rtc_pl031: ~ts reads ~b s: ~0p", [Path, Seconds, Answer])
    catch
        exit:Reason -> logger:warning("erx_rtc_pl031: ~ts reads ~b s; the clock service: ~0p", [Path, Seconds, Reason])
    end.
