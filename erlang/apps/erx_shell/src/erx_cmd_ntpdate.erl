%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ntpdate).
-moduledoc """
`ntpdate [-4bqu] [-t timeout] server ...`: asks NTP servers for the time
once and sets the clock, as FreeBSD's ntpdate(8) does with `-b`
(usr.sbin/ntp/doc/ntpdate.8 and contrib/ntp/ntpdate/ntpdate.c at
releng/15.1; docs/design-time.md, "Setting the clock from a server once").

Each operand is an IPv4 address or a name, of which the first four
addresses DNS gives are used. The addresses are asked in order, one SNTP
exchange each over a socket of its own, and the first reply that passes
erx_ntp_sample's checks gives the sample. The clock is then set through
the session's `clock` grant with `{set, W}`, as `date` sets it
(erx_cmd_date:set_clock/2), and the step is written as ntpdate writes it:

    ntpdate: step time server 192.0.2.10 offset 1234.567890 sec

`-q` sets nothing and needs no grant; it writes ntpdate's server line,

    server 192.0.2.10, stratum 2, offset 1234.567890, delay 0.01234

`-t` is the wait for each reply in seconds, at most one decimal, 0.2 to
10, 1 by default. `-4`, `-b` and `-u` are accepted and change nothing:
the stack takes IPv4 alone and draws every port at random, and every set
is a step, since erXos does not slew.

A reply is network input that anyone on the path can forge: erx_ntp_wire
decodes it within its bounds, the nonce and the connected socket keep an
off-path host out, and every name and address written passes the field
escape (erx_text:escape_field/1). parse/1 is the pure decision over the
arguments; run/2 resolves, exchanges, sets and writes.
""".

-behaviour(erx_cmd).

-erx_command(ntpdate).
-erx_usage("ntpdate [-4bqu] [-t timeout] server ...").
%% The exchanges go through the network stack, which a session reaches only through its
%% net facet; setting needs `clock` as well, which the set checks itself, so -q runs
%% without it.
-erx_needs([net]).

-export([run/2]).
-export([parse/1, seconds/2]).
-export_type([options/0]).

-doc "A parsed command line: whether only to query, the wait for each reply, the servers.".
-type options() :: #{query := boolean(), timeout_ms := 200..10000, servers := [binary(), ...]}.

-define(MAX_SERVERS, 8).
-define(MAX_NAME, 253).
%% The addresses of one name that are asked, as DNS orders them.
-define(ADDRESSES_PER_NAME, 4).
-define(DEFAULT_TENTHS, 10).
-define(NS, 1000000000).
-define(RESOLVE_MS, 10000).

-doc false.
run(Args, Ctx) ->
    case parse(Args) of
        {ok, Options} -> ntpdate(Options, Ctx);
        {error, usage} = Usage -> Usage
    end.

%%% Parsing

-doc """
The options Args gives, as FreeBSD's ntpdate reads them with getopt(3):
the flags `-4`, `-b`, `-q` and `-u`, `-t timeout`, the last `-t` winning,
and one to eight servers of 1 to 253 bytes. Anything else is `{error,
usage}`.
""".
-spec parse([binary()]) -> {ok, options()} | {error, usage}.
parse(Args) ->
    maybe
        {ok, Flags, Servers} ?= erx_cmd:getopt(Args, "4bqut:"),
        true ?= Servers =/= [] andalso length(Servers) =< ?MAX_SERVERS
            andalso lists:all(fun(S) -> byte_size(S) >= 1 andalso byte_size(S) =< ?MAX_NAME end, Servers),
        {ok, Tenths} ?= timeout(Flags),
        {ok, #{query => lists:member($q, Flags), timeout_ms => Tenths * 100, servers => Servers}}
    else
        _ -> {error, usage}
    end.

%% The last -t's wait in tenths of a second, 2 to 100, or the default.
timeout(Flags) ->
    case [T || {$t, T} <- Flags] of
        [] -> {ok, ?DEFAULT_TENTHS};
        Ts -> tenths(binary:split(lists:last(Ts), <<".">>))
    end.

tenths([Whole]) -> tenths([Whole, <<"0">>]);
tenths([Whole, <<Tenth>>]) when byte_size(Whole) >= 1, byte_size(Whole) =< 2, Tenth >= $0, Tenth =< $9 ->
    Tenths = case digits(Whole) of
                 true -> binary_to_integer(Whole) * 10 + (Tenth - $0);
                 false -> 0
             end,
    case Tenths >= 2 andalso Tenths =< 100 of
        true -> {ok, Tenths};
        false -> error
    end;
tenths(_) -> error.

digits(Bytes) -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bytes)).

-doc """
Nanoseconds Ns as signed seconds with Places decimals, cut toward zero:
a `-` before a negative number and nothing before a positive one.
""".
-spec seconds(integer(), 1..9) -> binary().
seconds(Ns, Places) ->
    Sign = if Ns < 0 -> <<"-">>; true -> <<>> end,
    Unit = pow10(9 - Places),
    Fraction = integer_to_binary((abs(Ns) rem ?NS) div Unit),
    Pad = binary:copy(<<"0">>, Places - byte_size(Fraction)),
    <<Sign/binary, (integer_to_binary(abs(Ns) div ?NS))/binary, $., Pad/binary, Fraction/binary>>.

pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).

%%% Effects

ntpdate(#{servers := Servers} = Options, Ctx) ->
    case lists:append([addresses(Server, Ctx) || Server <- Servers]) of
        [] -> fail(Ctx, <<"no servers can be used, exiting">>);
        Addresses -> first_sample(Addresses, Options, Ctx)
    end.

%% The addresses a server operand names, or none after a line saying so.
addresses(Server, Ctx) ->
    Name = binary_to_list(Server),
    case inet:parse_ipv4strict_address(Name) of
        {ok, Address} ->
            [Address];
        {error, _} ->
            case inet:getaddrs(Name, inet, ?RESOLVE_MS) of
                {ok, [_ | _] = Addresses} -> lists:sublist(Addresses, ?ADDRESSES_PER_NAME);
                _ -> say(Ctx, [<<"Can't find host ">>, erx_text:escape_field(Server)]), []
            end
    end.

%% The first address whose exchange gives a sample decides; a socket that cannot be
%% opened ends the command, since no later address could be asked either.
first_sample([], _Options, Ctx) ->
    fail(Ctx, <<"no server suitable for synchronization found">>);
first_sample([Address | Rest], #{timeout_ms := Timeout} = Options, Ctx) ->
    case gen_udp:open(0, [binary, {active, false}]) of
        {ok, Socket} ->
            Outcome = try erx_ntp_exchange:exchange(Socket, Address, Timeout) after gen_udp:close(Socket) end,
            case Outcome of
                {sample, Sample, WallOffset} -> report_or_set(Address, Sample, WallOffset, Options, Ctx);
                _NoSample -> first_sample(Rest, Options, Ctx)
            end;
        {error, Reason} ->
            erx_cmd:report(Ctx, <<"socket">>, Reason),
            {error, {reported, <<"1">>}}
    end.

%% Under -q, ntpdate's server line and then its step line with the offset from the
%% clock as it read, as FreeBSD's -q writes both; otherwise the set and its step.
report_or_set(Address, #{offset := W, delay := Delay, stratum := Stratum}, WallOffset, #{query := true}, Ctx) ->
    erx_cmd:write(Ctx, [<<"server ">>, address(Address), <<", stratum ">>, integer_to_binary(Stratum),
                        <<", offset ">>, seconds(W - WallOffset, 6), <<", delay ">>, seconds(Delay, 5), $\n]),
    step_line(Ctx, Address, W - WallOffset);
report_or_set(Address, #{offset := W}, _WallOffset, #{query := false}, Ctx) ->
    case erx_cmd_date:set_clock(Ctx, W) of
        {ok, StepNs} -> step_line(Ctx, Address, StepNs);
        {error, _} = Refused -> Refused
    end.

step_line(Ctx, Address, StepNs) ->
    erx_cmd:write(Ctx, [<<"ntpdate: step time server ">>, address(Address), <<" offset ">>,
                        seconds(StepNs, 6), <<" sec\n">>]).

address(Address) -> erx_text:escape_field(list_to_binary(inet:ntoa(Address))).

say(Ctx, Text) -> erx_cmd:say(Ctx, [<<"ntpdate: ">>, Text, $\n]).

fail(Ctx, Text) ->
    say(Ctx, Text),
    {error, {reported, <<"1">>}}.
