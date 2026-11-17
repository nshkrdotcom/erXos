%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntp_exchange).
-moduledoc """
One SNTPv4 client exchange (docs/design-time.md, "Checks on a reply"), the
one route by which root's `ntpdate` and ntpd ask a server for the time.

exchange/3 connects the caller's socket, which is the exchange's own, to
the address and port 123, sends a request whose transmit timestamp is a
64-bit nonce from kernel entropy, and waits for the reply until its
deadline. A datagram that does not decode, or fails the nonce, mode or
version check, is not this exchange's answer: it is passed over and the
wait goes on to the same deadline, so a forged datagram cannot cut the
exchange short. The first answer ends the exchange with erx_ntp_sample's
verdict on it; a connect or send that fails, or no answer by the
deadline, is `{error, Reason}`.

classify/4 is the pure decision over one datagram.
""".

-export([exchange/3, classify/4]).
-export_type([outcome/0]).

-doc """
What one exchange ends in: its sample with the clock's wall offset read when
the reply came, a reply that is no sample, or no reply.
""".
-type outcome() :: {sample, erx_ntp_sample:sample(), integer()}
                 | {kiss, <<_:32>>} | {drop, erx_ntp_sample:drop()} | {error, term()}.

-define(NTP_PORT, 123).
-define(NONCE_BYTES, 8).

-doc "One exchange with Address over Socket, waiting at most TimeoutMs for the answer.".
-spec exchange(gen_udp:socket(), inet:ip4_address(), pos_integer()) -> outcome().
exchange(Socket, Address, TimeoutMs) ->
    Nonce = binary:decode_unsigned(erx_bytes:entropy(?NONCE_BYTES)),
    maybe
        ok ?= gen_udp:connect(Socket, Address, ?NTP_PORT),
        M1 = os:perf_counter(nanosecond),
        ok ?= gen_udp:send(Socket, erx_ntp_wire:request(Nonce)),
        await(Socket, Nonce, M1, M1 + TimeoutMs * 1000000)
    end.

-doc """
One datagram's meaning to the exchange of Nonce sent at M1 and answered at
M4: `foreign` when it does not decode or is not this exchange's answer, and
the wait goes on; otherwise erx_ntp_sample's verdict on it.
""".
-spec classify(binary(), erx_ntp_wire:timestamp(), integer(), integer()) ->
          foreign | erx_ntp_sample:verdict().
classify(Bytes, Nonce, M1, M4) ->
    case erx_ntp_wire:decode(Bytes) of
        {ok, Reply} ->
            case erx_ntp_sample:check(Reply, Nonce, M1, M4) of
                {foreign, _} -> foreign;
                Verdict -> Verdict
            end;
        {error, short} ->
            foreign
    end.

%% The exchange's answer: foreign datagrams are passed over, and the wait never goes
%% past Deadline, however many arrive.
await(Socket, Nonce, M1, Deadline) ->
    case Deadline - os:perf_counter(nanosecond) of
        Left when Left =< 0 ->
            {error, timeout};
        Left ->
            case gen_udp:recv(Socket, 0, Left div 1000000) of
                {ok, {_Address, _Port, Bytes}} ->
                    M4 = os:perf_counter(nanosecond),
                    WallOffset = os:system_time(nanosecond) - os:perf_counter(nanosecond),
                    case classify(Bytes, Nonce, M1, M4) of
                        foreign -> await(Socket, Nonce, M1, Deadline);
                        {sample, Sample} -> {sample, Sample, WallOffset};
                        NoSample -> NoSample
                    end;
                {error, _} = Error ->
                    Error
            end
    end.
