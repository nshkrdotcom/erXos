%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntp_wire).
-moduledoc """
The NTP packet codec (docs/design-time.md, "Checks on a reply"): the one
reader of NTP bytes, for ntpd's client and root's `ntpctl` alike. It is
pure and total, and decides nothing about a reply; erx_ntp_sample checks
what it decodes.

A packet is the 48-byte header of RFC 4330 section 4 and RFC 5905
section 7.3: leap indicator, version and mode in the first byte, then
stratum, poll and precision, root delay and root dispersion, the
reference ID and the reference, originate, receive and transmit
timestamps. decode/1 reads the first 48 bytes after one length check and
ignores what follows, extension fields and a MAC included, and keeps
every field as the wire holds it, so encode/1 of what it decoded gives
the same 48 bytes. Root delay is a signed 16.16 number of seconds and root
dispersion an unsigned one; timestamps are 64-bit integers, seconds
since 1900 in the high half and a binary fraction in the low half.
time_ns/1 and short_ns/1 convert them to nanoseconds.
""".

-export([decode/1, encode/1, request/1, version/0, time_ns/1, short_ns/1]).
-export_type([packet/0, timestamp/0]).

-doc "A 64-bit NTP timestamp as the wire holds it.".
-type timestamp() :: 0..16#ffffffffffffffff.

-doc "A header, every field as the wire holds it.".
-type packet() :: #{leap := 0..3, version := 0..7, mode := 0..7, stratum := 0..255,
                    poll := -128..127, precision := -128..127,
                    root_delay := -16#80000000..16#7fffffff, root_dispersion := 0..16#ffffffff,
                    reference_id := <<_:32>>, reference_time := timestamp(), originate_time := timestamp(),
                    receive_time := timestamp(), transmit_time := timestamp()}.

-define(HEADER_BYTES, 48).
-define(NS, 1000000000).
%% Seconds from 1900-01-01, NTP's era 0, to 1970-01-01.
-define(UNIX_EPOCH, 2208988800).
-define(MODE_CLIENT, 3).
-define(VERSION, 4).

-doc """
The header that begins Bytes, or `{error, short}` when Bytes holds fewer
than 48 bytes or is not a binary.
""".
-spec decode(term()) -> {ok, packet()} | {error, short}.
decode(<<Leap:2, Version:3, Mode:3, Stratum:8, Poll:8/signed, Precision:8/signed,
         RootDelay:32/signed, RootDispersion:32, ReferenceId:4/binary, Reference:64,
         Originate:64, Receive:64, Transmit:64, _/binary>>) ->
    {ok, #{leap => Leap, version => Version, mode => Mode, stratum => Stratum, poll => Poll,
           precision => Precision, root_delay => RootDelay, root_dispersion => RootDispersion,
           reference_id => ReferenceId, reference_time => Reference, originate_time => Originate,
           receive_time => Receive, transmit_time => Transmit}};
decode(_) ->
    {error, short}.

-doc "The 48 bytes of a header.".
-spec encode(packet()) -> <<_:384>>.
encode(#{leap := Leap, version := Version, mode := Mode, stratum := Stratum, poll := Poll,
         precision := Precision, root_delay := RootDelay, root_dispersion := RootDispersion,
         reference_id := <<_:32>> = ReferenceId, reference_time := Reference, originate_time := Originate,
         receive_time := Receive, transmit_time := Transmit}) ->
    <<Leap:2, Version:3, Mode:3, Stratum:8, Poll:8/signed, Precision:8/signed,
      RootDelay:32/signed, RootDispersion:32, ReferenceId/binary, Reference:64,
      Originate:64, Receive:64, Transmit:64>>.

-doc """
A client's request: version 4, mode 3, Nonce as the transmit timestamp
and every other field zero, so it says nothing of the client's clock.
""".
-spec request(timestamp()) -> <<_:384>>.
request(Nonce) ->
    encode(#{leap => 0, version => ?VERSION, mode => ?MODE_CLIENT, stratum => 0, poll => 0,
             precision => 0, root_delay => 0, root_dispersion => 0, reference_id => <<0:32>>,
             reference_time => 0, originate_time => 0, receive_time => 0, transmit_time => Nonce}).

-doc "The NTP version a request carries, which its reply must carry too.".
-spec version() -> 4.
version() -> ?VERSION.

-doc """
A timestamp as nanoseconds since 1970, by RFC 4330 section 3's era
convention: with the top bit of its seconds set it lies in 1968-2036,
counted from 1900, and with it clear in 2036-2104, counted from
2036-02-07 06:28:16 UTC. A time in 1968 or 1969 is negative.
""".
-spec time_ns(timestamp()) -> integer().
time_ns(Timestamp) ->
    Seconds = Timestamp bsr 32,
    Era = case Seconds bsr 31 of
              1 -> 0;
              0 -> 1 bsl 32
          end,
    %% bsr binds as loosely as +, so the fraction is shifted on its own.
    (Seconds + Era - ?UNIX_EPOCH) * ?NS + (((Timestamp band 16#ffffffff) * ?NS) bsr 32).

-doc "A 16.16 number of seconds, root delay or dispersion, as nanoseconds.".
-spec short_ns(integer()) -> integer().
short_ns(Short) ->
    (Short * ?NS) div 65536.
