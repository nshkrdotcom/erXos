%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntp_sample).
-moduledoc """
The checks of one NTP reply and the sample it gives (docs/design-time.md,
"Checks on a reply" and "The construction"), for ntpd's client and root's
`ntpctl step` alike, so both drop a reply for the same reasons.

check/4 takes a reply erx_ntp_wire decoded, the request's nonce and the
monotonic times `M1`, when the request went, and `M4`, when the reply
came, in nanoseconds. Check 1, the address and port, is the connected
socket's: the stack delivers no other datagram to it. The others run in
the design's order and the first that fails names the reply's fate:

2. the originate timestamp is the nonce: `{foreign, nonce}`;
3. mode 4 and the version erx_ntp_wire sends: `{foreign, mode}`.

A reply that fails these is not this exchange's answer, and a caller
waits on for one that is; a reply that passes them answers it. Stratum 0 is a kiss,
`{kiss, Code}`, and nothing else of it is read. Any other reply is a
sample only if

4. its leap indicator is not 3, `{drop, unsynchronized}`;
5. its stratum is 1 to 15, `{drop, stratum}`;
6. its receive and transmit timestamps are non-zero, lie from 1970 on,
   and `t3 >= t2`, `{drop, timestamps}`;
7. its reference timestamp, unless it is zero, which means none, is not later than its
   transmit timestamp, `{drop, reference}`;
8. the delay is not negative, `{drop, delay}`;
9. its distance is below `clock_distance_max_ns`, `{drop, distance}`;
10. the wall offset `W` its timestamps imply is one the time page holds,
    0 to `time_offset_max`, `{drop, timestamps}`: a server time earlier
    than the client's uptime since 1970 implies a negative one.

The sample is the wall offset `W` the server implies against the
monotonic clock, exactly the time page's `wall_offset_ns`, with the
exchange's delay, the distance that bounds its error and the server's
stratum. Times are Erlang integers, so no difference wraps however far
the server is from the client's clock.
""".

-include("generated/erx_abi.hrl").

-export([check/4]).
-export_type([sample/0, verdict/0, drop/0, foreign/0]).

-doc "What a valid reply implies, in nanoseconds.".
-type sample() :: #{offset := integer(), delay := non_neg_integer(),
                    distance := non_neg_integer(), stratum := 1..15}.

-doc "Why a reply was dropped: the first check it failed.".
-type drop() :: unsynchronized | stratum | timestamps | reference | delay | distance.

-doc "Why a datagram is not this exchange's answer.".
-type foreign() :: nonce | mode.

-type verdict() :: {sample, sample()} | {kiss, <<_:32>>} | {drop, drop()} | {foreign, foreign()}.

-define(MODE_SERVER, 4).
-define(LEAP_UNSYNCHRONIZED, 3).

-doc "The verdict on Reply to the request of Nonce sent at M1 and taken at M4.".
-spec check(erx_ntp_wire:packet(), erx_ntp_wire:timestamp(), integer(), integer()) -> verdict().
check(#{originate_time := Originate}, Nonce, _M1, _M4) when Originate =/= Nonce ->
    {foreign, nonce};
check(#{mode := Mode, version := Version} = Reply, _Nonce, M1, M4) ->
    case Mode =:= ?MODE_SERVER andalso Version =:= erx_ntp_wire:version() of
        false -> {foreign, mode};
        true -> answer(Reply, M1, M4)
    end.

%% The verdict on this exchange's answer: a kiss, of which nothing else is read, or the
%% sample that checks 4 to 9 leave.
answer(#{stratum := 0, reference_id := Code}, _M1, _M4) ->
    {kiss, Code};
answer(Reply, M1, M4) ->
    try
        {sample, sample(Reply, M1, M4)}
    catch
        throw:{drop, _} = Drop -> Drop
    end.

%% Checks 4 to 9 of a reply that answers this exchange, throwing the first that fails.
sample(#{leap := Leap, stratum := Stratum, reference_time := Reference, receive_time := Receive,
         transmit_time := Transmit, root_delay := RootDelay, root_dispersion := RootDispersion},
       M1, M4) ->
    require(Leap =/= ?LEAP_UNSYNCHRONIZED, unsynchronized),
    require(Stratum >= 1 andalso Stratum =< 15, stratum),
    require(Receive =/= 0 andalso Transmit =/= 0, timestamps),
    T2 = erx_ntp_wire:time_ns(Receive),
    T3 = erx_ntp_wire:time_ns(Transmit),
    require(T2 >= 0 andalso T3 >= T2, timestamps),
    require(Reference =:= 0 orelse erx_ntp_wire:time_ns(Reference) =< T3, reference),
    Delay = (M4 - M1) - (T3 - T2),
    require(Delay >= 0, delay),
    Distance = (max(erx_ntp_wire:short_ns(RootDelay), 0) + Delay) div 2
        + erx_ntp_wire:short_ns(RootDispersion),
    require(Distance < ?ERX_CLOCK_DISTANCE_MAX_NS, distance),
    W = ((T2 - M1) + (T3 - M4)) div 2,
    require(W >= 0 andalso W =< ?ERX_TIME_OFFSET_MAX, timestamps),
    #{offset => W, delay => Delay, distance => Distance, stratum => Stratum}.

require(true, _Reason) -> ok;
require(false, Reason) -> throw({drop, Reason}).
