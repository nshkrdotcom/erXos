%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ntpctl).
-moduledoc """
`ntpctl step [server ...]` and `ntpctl -s status|peers`: root's command
for network time (docs/design-time.md, "Setting the clock from a server
once"). The source of a step is chosen by the arguments alone, never by a
fallback from one to the other:

* `ntpctl step server ...` asks the servers named, one SNTP exchange per
  address in order (erx_ntp_exchange:ask/1, the exchange ntpd makes), and
  the first reply that passes erx_ntp_sample's checks gives the wall
  offset W. It needs no ntpd.
* `ntpctl step` takes ntpd's last sample from the clock service's record
  at `/proc/time`, its `sample_wall_offset_ns`, `sample_from`, `server`,
  `sample_verdict` and `sample_monotonic_ns`, while its start-table row
  says it is running (`/proc/apps/ntpd`); when ntpd is not running or has
  sent no sample, it says so and changes nothing, and a record it cannot
  read is written as its status, never as either. A sample the service
  held, stepped to or refused as `panic` is applied; one it refused as
  `floor`, a time before the build's date, is not, so a step from ntpd's
  sample never takes the clock below the floor.

Either way the clock is set through the session's `clock` grant with
`{set, W}`, as `date` sets it (erx_cmd_date:set_clock/2), and the step is
written with what gave it, and for ntpd's sample the service's verdict and
the sample's age:

    ntpctl: stepped +1234.567 s from ntpd's sample of 192.0.2.7 (refused as panic, 12 s old)

`-s status` and `-s peers` write ntpd's own record, `/proc/ntp`, in the
form OpenBSD's ntpctl(8) takes (usr.sbin/ntpd/ntpctl.8), with erXos's
attributes; while that node answers no value, they write its status and
exit 1, and never make one up.

A reply is network input that anyone on the path can forge: erx_ntp_wire
decodes it within its bounds, the nonce and the connected socket keep an
off-path host out, and every name and address written passes the field
escape (erx_text:escape_field/1). parse/1, ntpd_sample/3, stepped/2 and
show/2 are the pure decisions; run/2 reads the inspector, asks the servers,
sets and writes.
""".

-behaviour(erx_cmd).

-erx_command(ntpctl).
-erx_usage("ntpctl step [server ...] | ntpctl -s status | peers").
%% The records come through the session's inspect facet and the exchanges through
%% the network stack's net facet; setting needs `clock` as well, which the set
%% checks itself, so -s runs without it.
-erx_needs([inspect, net]).

-export([run/2]).
-export([parse/1, ntpd_sample/3, stepped/2, show/2]).
-export_type([request/0]).

-doc """
A parsed command line: a step from the servers named or from ntpd's
sample, or a view of ntpd's record.
""".
-type request() :: {step, ntpd | [binary(), ...]} | {show, status | peers}.
%% What gave a step: ntpd's sample from a server, with the clock service's verdict
%% on it, any but `floor`, and its age in nanoseconds, or a server asked directly.
-type source() :: {ntpd, binary(), step | hold | panic, integer()} | {server, binary()}.

-define(NS_PER_MS, 1000000).
-define(NS_PER_S, 1000000000).

-doc false.
run(Args, Ctx) ->
    case parse(Args) of
        {ok, Request} -> carry_out(Request, Ctx);
        {error, usage} = Usage -> Usage
    end.

%%% Decisions

-doc """
The request Args gives: `step` alone, `step` and one to 8 servers by
erx_ntp_exchange:servers/1's rule, or `-s` with `status` or `peers`.
Anything else, OpenBSD's `all`, `Sensors` and abbreviations among it, is
`{error, usage}`.
""".
-spec parse([binary()]) -> {ok, request()} | {error, usage}.
parse([<<"step">>]) ->
    {ok, {step, ntpd}};
parse([<<"step">> | Servers]) ->
    case erx_ntp_exchange:servers(Servers) of
        true -> {ok, {step, Servers}};
        false -> {error, usage}
    end;
parse(Args) ->
    case erx_cmd:getopt(Args, "s:") of
        {ok, [{$s, <<"status">>}], []} -> {ok, {show, status}};
        {ok, [{$s, <<"peers">>}], []} -> {ok, {show, peers}};
        _ -> {error, usage}
    end.

-doc """
ntpd's last sample from App, `/proc/apps/ntpd`'s answer, and Time,
`/proc/time`'s, at monotonic time Now in nanoseconds: its wall offset and
the source the step line names while ntpd's row is running, or the line
saying why it is not applied. A sample the clock service refused as
`floor` is not: setting it would take the clock below the floor the
service holds ntpd to.
""".
-spec ntpd_sample(erx_inspector:answer(), erx_inspector:answer(), integer()) ->
          {ok, non_neg_integer(), source()} | {error, binary()}.
ntpd_sample(App, Time, Now) ->
    maybe
        ok ?= running(App),
        {ok, W} ?= sample(Time),
        {ok, Address} ?= value(Time, server),
        {ok, Verdict} ?= value(Time, sample_verdict),
        {ok, At} ?= value(Time, sample_monotonic_ns),
        applicable(W, Address, Verdict, Now - At)
    end.

%% Only a state that is a value says whether ntpd runs; a row that cannot be read,
%% or whose state is not visible or not known, is written as its status.
running(App) ->
    case read(App, state) of
        {ok, running} -> ok;
        {ok, _State} -> {error, <<"ntpd is not running">>};
        Missed -> {error, missed(<<"/proc/apps/ntpd">>, state, Missed)}
    end.

%% Each sample sets every sample attribute together: sample_wall_offset_ns says
%% whether there is one and sample_from whether it is ntpd's; server, its verdict
%% and its time then hold values too.
sample(Time) ->
    case {read(Time, sample_wall_offset_ns), read(Time, sample_from)} of
        {{ok, W}, {ok, <<"ntp ", _/binary>>}} -> {ok, W};
        {{ok, _}, {ok, _OtherKind}} -> {error, <<"ntpd has no sample">>};
        {{ok, _}, From} -> {error, missed(<<"/proc/time">>, sample_from, From)};
        {unknown, _} -> {error, <<"ntpd has no sample">>};
        {Offset, _} -> {error, missed(<<"/proc/time">>, sample_wall_offset_ns, Offset)}
    end.

%% Attribute Key of /proc/time's answer Time as a value, or the line naming its status.
value(Time, Key) ->
    case read(Time, Key) of
        {ok, _} = Value -> Value;
        Missed -> {error, missed(<<"/proc/time">>, Key, Missed)}
    end.

%% The floor rule a set skips stays with ntpd's sample: one refused as before the
%% build's date is not applied.
applicable(_W, Address, floor, _AgeNs) ->
    {error, iolist_to_binary([<<"ntpd's sample of ">>, erx_text:escape_field(Address),
                              <<" is before the build date (refused as floor); nothing set">>])};
applicable(W, Address, Verdict, AgeNs) ->
    {ok, W, {ntpd, Address, Verdict, AgeNs}}.

%% Attribute Key of an inspector answer: its value or status, the whole answer's
%% error, or `missing` where the caller's scope does not see it.
read({ok, #{attrs := Attrs}}, Key) ->
    case Attrs of
        #{Key := {_Reporter, Value}} -> Value;
        #{} -> missing
    end;
read({error, _} = Error, _Key) ->
    Error.

missed(Path, Key, missing) -> <<Path/binary, ": ", (atom_to_binary(Key))/binary, " not visible">>;
missed(Path, _Key, Status) -> <<Path/binary, ": ", (status(Status))/binary>>.

status({error, Reason}) -> atom_to_binary(Reason);
status({timeout, _Ms}) -> <<"timeout">>;
status({partial, _}) -> <<"partial">>;
status(Status) when is_atom(Status) -> atom_to_binary(Status).

-doc """
The line a step of StepNs nanoseconds from Source writes: the step in
seconds with its sign and three decimals, cut toward zero, and what gave
it, for ntpd's sample with the clock service's verdict and the sample's
age in whole seconds.
""".
-spec stepped(integer(), source()) -> iodata().
stepped(StepNs, Source) ->
    [<<"ntpctl: stepped ">>, seconds(StepNs), <<" s from ">>, source(Source), $\n].

source({ntpd, Address, Verdict, AgeNs}) ->
    [<<"ntpd's sample of ">>, erx_text:escape_field(Address), <<" (">>, verdict(Verdict), <<", ">>,
     integer_to_binary(AgeNs div ?NS_PER_S), <<" s old)">>];
source({server, Address}) -> erx_text:escape_field(Address).

%% What the clock service did with the sample, the row of its Steps table it took.
verdict(step) -> <<"accepted">>;
verdict(hold) -> <<"held">>;
verdict(panic) -> <<"refused as panic">>.

%% The sign is the written number's, so a step that cuts to zero is +0.000.
seconds(Ns) ->
    Ms = abs(Ns) div ?NS_PER_MS,
    Sign = if Ns < 0, Ms > 0 -> $-; true -> $+ end,
    [Sign, integer_to_binary(Ms div 1000), $., io_lib:format("~3..0b", [Ms rem 1000])].

-doc """
What `-s Which` writes from Answer, `/proc/ntp`'s: ntpd's state, or, when
no attribute holds a value, the line saying why, `ntpd is not running` when
each says ntpd is unavailable.
""".
-spec show(status | peers, erx_inspector:answer()) -> {ok, iodata()} | {error, binary()}.
show(_Which, {error, Reason}) ->
    {error, <<"/proc/ntp: ", (atom_to_binary(Reason))/binary>>};
show(Which, {ok, #{attrs := Attrs}}) ->
    Values = [Value || _Key := {_Reporter, Value} <- Attrs],
    case [ok || {ok, _} <- Values] of
        [_ | _] -> {ok, lines(Which, Attrs)};
        [] -> {error, no_value(lists:usort(Values))}
    end.

no_value([{error, unavailable}]) -> <<"ntpd is not running">>;
no_value([Status]) -> <<"/proc/ntp: ", (status(Status))/binary>>;
no_value(_Statuses) -> <<"/proc/ntp: no value">>.

lines(status, Attrs) ->
    T = fun(Key) -> text(maps:get(Key, Attrs)) end,
    [<<"servers ">>, T(servers), <<"\nlast ">>, T(last),
     <<"\ninterval ">>, T(interval_s), <<" s, resolve wait ">>, T(resolve_wait_s),
     <<" s\n">>, T(samples), <<" samples, ">>, T(dropped), <<" dropped, ">>, T(kisses), <<" kisses, ">>,
     T(silent), <<" silent\n">>];
lines(peers, #{addresses := Addresses, denied := Denied}) ->
    [peers(addresses, Addresses, fun(1) -> <<" current">>; (_) -> <<>> end),
     peers(denied, Denied, fun(_) -> <<" denied">> end)].

%% One line an address, the Nth marked Mark(N); a list with no value is one line
%% naming it with its status.
peers(_Key, {_Reporter, {ok, Addresses}}, Mark) ->
    [[erx_text:escape_field(Address), Mark(N), $\n] || {N, Address} <- lists:enumerate(Addresses)];
peers(Key, Attr, _Mark) ->
    [atom_to_binary(Key), $\s, text(Attr), $\n].

%% An attribute's text: a value as itself, a list of names joined by spaces, each
%% through the field escape, and a status as /proc writes it (erx_render:value/1).
text({_Reporter, {ok, Value}}) when is_integer(Value) -> integer_to_binary(Value);
text({_Reporter, {ok, Value}}) when is_binary(Value) -> erx_text:escape_field(Value);
text({_Reporter, {ok, Names}}) when is_list(Names) -> lists:join($\s, [erx_text:escape_field(Name) || Name <- Names]);
text(Attr) -> erx_render:value(Attr).

%%% Effects

carry_out({show, Which}, Ctx) ->
    case show(Which, erx_inspector:inspect([ntp])) of
        {ok, Text} -> erx_cmd:write(Ctx, Text);
        {error, Line} -> fail(Ctx, Line)
    end;
carry_out({step, ntpd}, Ctx) ->
    App = erx_inspector:inspect([apps, <<"ntpd">>]),
    Time = erx_inspector:inspect([time]),
    %% Read after the record, so a sample that arrives meanwhile is no younger than now.
    Now = os:perf_counter(nanosecond),
    case ntpd_sample(App, Time, Now) of
        {ok, W, Source} -> set(Ctx, W, Source);
        {error, Line} -> fail(Ctx, Line)
    end;
carry_out({step, Servers}, Ctx) ->
    case lists:append([addresses(Server, Ctx) || Server <- Servers]) of
        [] -> fail(Ctx, <<"no address to ask">>);
        Addresses -> first_sample(Addresses, Ctx)
    end.

%% The addresses a server operand names, or none after a line saying so.
addresses(Server, Ctx) ->
    case erx_ntp_exchange:addresses(Server) of
        [] -> say(Ctx, [erx_text:escape_field(Server), <<": no address">>]), [];
        Addresses -> Addresses
    end.

%% The first address whose exchange gives a sample decides.
first_sample([], Ctx) ->
    fail(Ctx, <<"no server gave a sample">>);
first_sample([Address | Rest], Ctx) ->
    case erx_ntp_exchange:ask(Address) of
        {sample, #{offset := W}} -> set(Ctx, W, {server, list_to_binary(inet:ntoa(Address))});
        _NoSample -> first_sample(Rest, Ctx)
    end.

set(Ctx, W, Source) ->
    case erx_cmd_date:set_clock(Ctx, W) of
        {ok, StepNs} -> erx_cmd:write(Ctx, stepped(StepNs, Source));
        {error, _} = Refused -> Refused
    end.

say(Ctx, Text) -> erx_cmd:say(Ctx, [<<"ntpctl: ">>, Text, $\n]).

fail(Ctx, Text) ->
    say(Ctx, Text),
    {error, {reported, <<"1">>}}.
