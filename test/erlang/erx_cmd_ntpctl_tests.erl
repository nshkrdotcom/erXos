%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the command shell's `ntpctl` (docs/design-time.md, "Setting
%% the clock from a server once"): the forms it takes and those it refuses, the
%% sample `ntpctl step` takes from ntpd's record and its refusals when ntpd is
%% not running or has no sample, the line every step writes, and `-s` over
%% /proc/ntp, plainly refused while the node answers no value.

-module(erx_cmd_ntpctl_tests).

-include_lib("eunit/include/eunit.hrl").

parse_test_() ->
    Parse = fun erx_cmd_ntpctl:parse/1,
    [?_assertEqual({ok, {step, ntpd}}, Parse([<<"step">>])),
     ?_assertEqual({ok, {step, [<<"192.0.2.1">>, <<"pool.example">>]}},
                   Parse([<<"step">>, <<"192.0.2.1">>, <<"pool.example">>])),
     ?_assertMatch({ok, {step, [_, _, _, _, _, _, _, _]}}, Parse([<<"step">> | lists:duplicate(8, <<"a">>)])),
     ?_assertEqual({ok, {show, status}}, Parse([<<"-s">>, <<"status">>])),
     ?_assertEqual({ok, {show, peers}}, Parse([<<"-s">>, <<"peers">>])),
     ?_assertEqual({ok, {show, peers}}, Parse([<<"-speers">>]))].

usage_test_() ->
    Usage = fun(Args) -> ?_assertEqual({error, usage}, erx_cmd_ntpctl:parse(Args)) end,
    [Usage([]),
     Usage([<<"steps">>]),
     Usage([<<"192.0.2.1">>]),
     Usage([<<"-s">>]),
     %% OpenBSD's other modifiers, and its abbreviations, which erXos does not offer.
     Usage([<<"-s">>, <<"all">>]),
     Usage([<<"-s">>, <<"Sensors">>]),
     Usage([<<"-s">>, <<"s">>]),
     Usage([<<"-s">>, <<"status">>, <<"peers">>]),
     Usage([<<"-x">>, <<"status">>]),
     Usage([<<"step">> | lists:duplicate(9, <<"a">>)]),
     Usage([<<"step">>, <<>>]),
     Usage([<<"step">>, binary:copy(<<"a">>, 254)]),
     Usage([<<"step">>, <<"a b">>]),
     Usage([<<"step">>, <<"a", 27, "[2J">>]),
     %% A word that looks like a flag is no host name, so it never becomes a server
     %% to step from (RFC 1123's labels neither start nor end with a hyphen).
     Usage([<<"step">>, <<"-q">>, <<"pool.example">>]),
     Usage([<<"step">>, <<"--">>]),
     Usage([<<"step">>, <<"a-">>])].

%% ntpd's row as /proc/apps/ntpd answers it, in State.
app(State) ->
    {ok, #{path => [apps, <<"ntpd">>], kind => app, id => <<"ntpd">>, children => [],
           attrs => #{state => {service, {ok, State}}}}}.

%% /proc/time's record with the given attributes of the clock service.
time(Attrs) ->
    {ok, #{path => [time], kind => clock, id => time, children => [],
           attrs => #{Key => {service, Value} || Key := Value <- Attrs}}}.

%% The monotonic time ntpctl reads; ntpd's sample in /proc/time is 12.9 s before it.
-define(NOW, 100_000_000_000).

sampled() -> sampled(hold).

%% ntpd's sample, with the clock service's Verdict.
sampled(Verdict) ->
    time(#{sample_wall_offset_ns => {ok, 1_794_873_600_000_000_000}, sample_from => {ok, <<"ntp 192.0.2.7">>},
           server => {ok, <<"192.0.2.7">>}, sample_verdict => {ok, Verdict},
           sample_monotonic_ns => {ok, ?NOW - 12_900_000_000}}).

with({ok, #{attrs := Attrs} = Record}, Key, Value) -> {ok, Record#{attrs := Attrs#{Key => {service, Value}}}}.

without({ok, #{attrs := Attrs} = Record}, Key) -> {ok, Record#{attrs := maps:remove(Key, Attrs)}}.

ntpd_sample_test_() ->
    Sample = fun(App, Time) -> erx_cmd_ntpctl:ntpd_sample(App, Time, ?NOW) end,
    Taken = fun(Verdict) -> {ok, 1_794_873_600_000_000_000, {ntpd, <<"192.0.2.7">>, Verdict, 12_900_000_000}} end,
    [%% A sample the clock service held, stepped to or refused as panic is applied, with
     %% its verdict and its age.
     ?_assertEqual(Taken(hold), Sample(app(running), sampled(hold))),
     ?_assertEqual(Taken(step), Sample(app(running), sampled(step))),
     ?_assertEqual(Taken(panic), Sample(app(running), sampled(panic))),
     %% One refused as floor, a time before the build date, is not: setting it would take
     %% the clock below the floor the service holds ntpd to.
     ?_assertEqual({error, <<"ntpd's sample of 192.0.2.7 is before the build date (refused as floor); nothing set">>},
                   Sample(app(running), sampled(floor))),
     %% The verdict and the sample's time are read as the offset is: one that holds no
     %% value is written as its status, and the sample is not applied.
     ?_assertEqual({error, <<"/proc/time: unknown">>}, Sample(app(running), with(sampled(), sample_verdict, unknown))),
     ?_assertEqual({error, <<"/proc/time: sample_monotonic_ns not visible">>},
                   Sample(app(running), without(sampled(), sample_monotonic_ns))),
     %% ntpd not running: a row whose state says so.
     ?_assertEqual({error, <<"ntpd is not running">>}, Sample(app(stopped), sampled())),
     ?_assertEqual({error, <<"ntpd is not running">>}, Sample(app(down), sampled())),
     %% A row that cannot be read is no row saying ntpd is not running: its status is written.
     ?_assertEqual({error, <<"/proc/apps/ntpd: scope">>}, Sample({error, scope}, sampled())),
     ?_assertEqual({error, <<"/proc/apps/ntpd: failed">>}, Sample({error, failed}, sampled())),
     ?_assertEqual({error, <<"/proc/apps/ntpd: timeout">>},
                   Sample({ok, #{attrs => #{state => {service, {timeout, 500}}}}}, sampled())),
     ?_assertEqual({error, <<"/proc/apps/ntpd: state not visible">>}, Sample({ok, #{attrs => #{}}}, sampled())),
     %% Running, but nothing sampled since the clock service started.
     ?_assertEqual({error, <<"ntpd has no sample">>},
                   Sample(app(running), time(#{sample_wall_offset_ns => unknown, sample_from => unknown}))),
     %% The record cannot be read: the node, or its attributes, answer no value.
     ?_assertEqual({error, <<"/proc/time: unavailable">>},
                   Sample(app(running), time(#{sample_wall_offset_ns => {error, unavailable},
                                               sample_from => {error, unavailable}}))),
     ?_assertEqual({error, <<"/proc/time: timeout">>},
                   Sample(app(running), time(#{sample_wall_offset_ns => {timeout, 500}, sample_from => {timeout, 500}}))),
     ?_assertEqual({error, <<"/proc/time: unsupported">>}, Sample(app(running), {error, unsupported})),
     %% A scope that does not see who sent the sample cannot name it.
     ?_assertEqual({error, <<"/proc/time: server not visible">>},
                   Sample(app(running), time(#{sample_wall_offset_ns => {ok, 5},
                                               sample_from => {ok, <<"ntp 192.0.2.7">>}}))),
     %% A last sample of another kind of source is not ntpd's.
     ?_assertEqual({error, <<"ntpd has no sample">>},
                   Sample(app(running), time(#{sample_wall_offset_ns => {ok, 5}, sample_from => {ok, <<"ptp">>},
                                               server => {ok, <<"192.0.2.7">>}})))].

stepped_test_() ->
    Line = fun(StepNs, Source) -> iolist_to_binary(erx_cmd_ntpctl:stepped(StepNs, Source)) end,
    [%% ntpd's sample names the clock service's verdict and its age in whole seconds.
     ?_assertEqual(<<"ntpctl: stepped +1234.567 s from ntpd's sample of 162.159.200.1 (refused as panic, 12 s old)\n">>,
                   Line(1_234_567_890_123, {ntpd, <<"162.159.200.1">>, panic, 12_900_000_000})),
     ?_assertEqual(<<"ntpctl: stepped +2.310 s from ntpd's sample of 162.159.200.1 (held, 0 s old)\n">>,
                   Line(2_310_999_999, {ntpd, <<"162.159.200.1">>, hold, 999_999_999})),
     ?_assertEqual(<<"ntpctl: stepped +0.000 s from ntpd's sample of 162.159.200.1 (accepted, 64 s old)\n">>,
                   Line(0, {ntpd, <<"162.159.200.1">>, step, 64_000_000_000})),
     ?_assertEqual(<<"ntpctl: stepped -0.001 s from 192.0.2.10\n">>, Line(-1_500_000, {server, <<"192.0.2.10">>})),
     ?_assertEqual(<<"ntpctl: stepped +0.000 s from 192.0.2.10\n">>, Line(0, {server, <<"192.0.2.10">>})),
     %% A step that cuts to zero carries no sign of its own.
     ?_assertEqual(<<"ntpctl: stepped +0.000 s from 192.0.2.10\n">>, Line(-400_000, {server, <<"192.0.2.10">>})),
     ?_assertEqual(<<"ntpctl: stepped +1234.567 s from 192.0.2.10\n">>,
                   Line(1_234_567_890_123, {server, <<"192.0.2.10">>}))].

%% /proc/ntp's record with every attribute Value.
ntp_all(Value) ->
    {ok, Keys} = erx_schema:attributes(ntp),
    {ok, #{path => [ntp], kind => ntp, id => ntp, children => [],
           attrs => #{Key => {runtime, Value} || Key <- Keys}}}.

ntp(Values) ->
    {ok, Record = #{attrs := Attrs}} = ntp_all(unknown),
    {ok, Record#{attrs := maps:merge(Attrs, #{Key => {runtime, {ok, V}} || Key := V <- Values})}}.

show_test_() ->
    Show = fun(Which, Answer) ->
                   case erx_cmd_ntpctl:show(Which, Answer) of
                       {ok, Text} -> {ok, iolist_to_binary(Text)};
                       Refused -> Refused
                   end
           end,
    Running = ntp(#{servers => [<<"pool.example">>], addresses => [<<"192.0.2.7">>, <<"192.0.2.8">>],
                    denied => [<<"192.0.2.9">>], last => <<"192.0.2.7 sample">>, interval_s => 64,
                    resolve_wait_s => 15, samples => 3, dropped => 1, kisses => 0, silent => 2}),
    [%% While nothing routes /proc/ntp to ntpd's session, every attribute is unsupported.
     ?_assertEqual({error, <<"/proc/ntp: unsupported">>}, Show(status, ntp_all(unsupported))),
     ?_assertEqual({error, <<"/proc/ntp: unsupported">>}, Show(peers, ntp_all(unsupported))),
     ?_assertEqual({error, <<"ntpd is not running">>}, Show(status, ntp_all({error, unavailable}))),
     ?_assertEqual({error, <<"/proc/ntp: timeout">>}, Show(status, ntp_all({timeout, 500}))),
     ?_assertEqual({error, <<"/proc/ntp: scope">>}, Show(status, {error, scope})),
     ?_assertEqual({ok, <<"servers pool.example\nlast 192.0.2.7 sample\ninterval 64 s, resolve wait 15 s\n"
                          "3 samples, 1 dropped, 0 kisses, 2 silent\n">>},
                   Show(status, Running)),
     ?_assertEqual({ok, <<"192.0.2.7 current\n192.0.2.8\n192.0.2.9 denied\n">>}, Show(peers, Running)),
     %% Before ntpd's first exchange its counts and last answer are unknown, shown as such.
     ?_assertEqual({ok, <<"servers pool.example\nlast [unknown]\ninterval 64 s, resolve wait 15 s\n"
                          "[unknown] samples, [unknown] dropped, [unknown] kisses, [unknown] silent\n">>},
                   Show(status, ntp(#{servers => [<<"pool.example">>], addresses => [], denied => [],
                                      interval_s => 64, resolve_wait_s => 15})))].
