%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntp_exchange).
-moduledoc """
Asking NTP servers for the time (docs/design-time.md, "Server list" and
"Checks on a reply"): the one route by which ntpd and root's `ntpctl step
HOST` name, resolve and ask a server.

servers/1 is the server-list rule both apply to the names they are given:
one to 8 names, each a host name by the resolver's rule, erx_inet:host_name/1:
labels of 1 to 63 letters, digits and hyphens that neither start nor end
with a hyphen, 253 bytes in all, and no trailing dot. A dotted-decimal IPv4
literal is a host name by that rule, and no flag is one.
addresses/1 resolves one
such name: a literal is its address, and a name gives the first four
addresses the session's resolver answers, in DNS order, or none.

ask/1 makes one SNTPv4 client exchange with an address over a UDP socket
of its own, opened for the exchange and closed after it. exchange/3
connects that socket to the address and port 123, sends a request whose
transmit timestamp is a 64-bit nonce from kernel entropy, and waits 2 s
for the reply. A datagram that does not decode, or fails the nonce, mode
or version check, is not this exchange's answer: it is passed over and
the wait goes on to the same deadline, so a forged datagram cannot cut the
exchange short. The first answer ends the exchange with erx_ntp_sample's
verdict on it; a socket that cannot be opened, a connect or send that
fails, or no answer by the deadline, is `{error, Reason}`.

classify/4 is the pure decision over one datagram.
""".

-export([servers/1, addresses/1, ask/1]).
-export([classify/4]).
-export_type([outcome/0]).

-doc "What one exchange ends in: its sample, a reply that is no sample, or no reply.".
-type outcome() :: {sample, erx_ntp_sample:sample()}
                 | {kiss, <<_:32>>} | {drop, erx_ntp_sample:drop()} | {error, term()}.

-define(MAX_SERVERS, 8).
%% The addresses of one name that are asked, as DNS orders them.
-define(ADDRESSES_PER_NAME, 4).
%% How long one resolution waits for DNS, and one exchange for its reply.
-define(RESOLVE_MS, 10000).
-define(EXCHANGE_MS, 2000).
-define(NTP_PORT, 123).
-define(NONCE_BYTES, 8).

-doc "Whether Names is a server list: 1 to 8 names, each a host name or dotted-decimal IPv4 literal.".
-spec servers([binary()]) -> boolean().
servers(Names) ->
    Names =/= [] andalso length(Names) =< ?MAX_SERVERS
        andalso lists:all(fun erx_inet:host_name/1, Names).

-doc """
The addresses server Name stands for: its own, for an IPv4 literal, or the
first four the resolver answers for a name, in DNS order; none when it
answers none.
""".
-spec addresses(binary()) -> [inet:ip4_address()].
addresses(Name) ->
    String = binary_to_list(Name),
    case inet:parse_ipv4strict_address(String) of
        {ok, Address} ->
            [Address];
        {error, _} ->
            case inet:getaddrs(String, inet, ?RESOLVE_MS) of
                {ok, Addresses} -> lists:sublist(Addresses, ?ADDRESSES_PER_NAME);
                {error, _} -> []
            end
    end.

-doc "One exchange with Address over a socket of its own.".
-spec ask(inet:ip4_address()) -> outcome().
ask(Address) ->
    case gen_udp:open(0, [binary, {active, false}]) of
        {ok, Socket} ->
            try exchange(Socket, Address, ?EXCHANGE_MS) after gen_udp:close(Socket) end;
        {error, _} = Error ->
            Error
    end.

%% One exchange with Address over Socket, waiting at most TimeoutMs for the answer.
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
                    case classify(Bytes, Nonce, M1, M4) of
                        foreign -> await(Socket, Nonce, M1, Deadline);
                        Answer -> Answer
                    end;
                {error, _} = Error ->
                    Error
            end
    end.
