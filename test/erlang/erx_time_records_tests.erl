%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_time_records_tests).
-moduledoc """
The clock's record, `[time]` (erx_time_records): the time page's state
for each page, the clock service's record as it reports it, absent or
silent, and the record seen by any scope, whole by the whole-machine scope
and without the attributes that name another domain or a server by any
other. test/host/erx_inspector_test.rb
seeds a swap of `boot` and `unset` in erx_clock_core:state/2 and a scoped path list without `[time]`.
""".

-include_lib("eunit/include/eunit.hrl").

%% A build date as a floor, in nanoseconds.
-define(FLOOR, 1_794_787_200_000_000_000).

page(Cold, Offset) -> {ok, #{cold => Cold, offset => Offset, monotonic => 1000}}.

attrs(Read) -> attrs(Read, {ok, sampled()}).

attrs(Read, Service) ->
    {ok, #{kind := clock, path := [time], attrs := Attrs}} = erx_time_records:record(Read, ?FLOOR, Service),
    Attrs.

state(Read) -> maps:get(state, attrs(Read)).

%% The clock service's record after an ntp sample from 192.0.2.1 by domain 7 and a set
%% by domain 3 that stepped the clock, as erx_clock_core keeps it.
sampled() ->
    (erx_clock_core:new(5_000_000_000, ?FLOOR))#{
        excess := positive, sample_at := ?FLOOR + 10, offset_ns := -42, distance_ns := 20_000_000, stratum := 2,
        server := {192, 0, 2, 1}, source := 7, sample_from := {ntp, {192, 0, 2, 1}},
        step_at := ?FLOOR + 20, step_ns := 60_000_000_000, step_source := 3, step_from := root,
        step_error := limit, steps := 1, refused := 2}.

each_page_state_is_shown_test_() ->
    [?_assertEqual({kernel, {ok, unset}}, state(page(true, 0))),
     ?_assertEqual({kernel, {ok, boot}}, state(page(true, 1_700_000_000_000_000_000))),
     ?_assertEqual({kernel, {ok, set}}, state(page(false, 1_700_000_000_000_000_000))),
     ?_assertEqual({kernel, {ok, set}}, state(page(false, 0))),
     ?_assertEqual({kernel, {ok, approximate}}, state(page(false, ?FLOOR))),
     ?_assertEqual({kernel, {ok, set}}, state(page(false, ?FLOOR + 1)))].

a_page_out_of_sequence_is_its_refusal_test() ->
    ?assertEqual({kernel, {error, limit}}, state({error, limit})).

the_services_record_is_shown_test() ->
    Attrs = attrs(page(false, 0)),
    {ok, Keys} = erx_schema:attributes(clock),
    ?assertEqual(lists:sort(Keys), lists:sort(maps:keys(Attrs))),
    ?assertEqual(#{record_since => {ok, 5}, sample_at => {ok, ?FLOOR + 10}, offset_ns => {ok, -42},
                   distance_ns => {ok, 20_000_000}, stratum => {ok, 2}, server => {ok, <<"192.0.2.1">>},
                   source => {ok, 7}, sample_from => {ok, <<"ntp 192.0.2.1">>}, step_at => {ok, ?FLOOR + 20},
                   step_ns => {ok, 60_000_000_000}, step_source => {ok, 3}, step_from => {ok, <<"root">>},
                   step_error => {ok, limit}, steps => {ok, 1}, refused => {ok, 2}},
                 maps:from_list([{Key, Value} || Key := {service, Value} <- Attrs])).

%% The keeper's reading is rtc; what nothing has recorded yet, `none` in the service's
%% record, is shown as unknown, since the schema's types hold no `none`.
an_empty_record_shows_rtc_and_unknowns_test() ->
    Record = (erx_clock_core:new(0, ?FLOOR))#{step_from := rtc},
    Attrs = attrs(page(false, 0), {ok, Record}),
    ?assertEqual({service, {ok, <<"rtc">>}}, maps:get(step_from, Attrs)),
    ?assertEqual({service, {ok, 0}}, maps:get(steps, Attrs)),
    [?assertEqual({Key, {service, unknown}}, {Key, maps:get(Key, Attrs)})
     || Key <- [sample_at, offset_ns, distance_ns, stratum, server, source, sample_from, step_at, step_ns,
                step_source, step_error]].

%% A service that is not running, or does not answer, is shown as such in every
%% attribute it reports; the page's state is still shown.
a_missing_or_silent_service_is_shown_as_such_test_() ->
    [fun() ->
             Attrs = attrs(page(true, 0), Service),
             ?assertEqual({kernel, {ok, unset}}, maps:get(state, Attrs)),
             ?assertEqual([{service, Service}], lists:usort([V || K := V <- Attrs, K =/= state]))
     end || Service <- [{error, unavailable}, {timeout, 500}]].

%% Each attribute that names another domain or the server it sampled, `server`, `source`,
%% `step_source` and the two kinds of source, is the whole-machine scope's alone.
any_scope_reads_the_record_test() ->
    {ok, #{attrs := Attrs} = Record} = erx_time_records:record(page(true, 0), ?FLOOR, {ok, sampled()}),
    ?assertEqual({ok, machine}, erx_inspector:declared_reachable([time], erx_schema:resolve([time]), [5])),
    ?assertEqual(Record#{attrs := maps:without([server, source, sample_from, step_source, step_from], Attrs)},
                 erx_inspector:scoped(Record, machine, [5])),
    ?assertEqual(Record, erx_inspector:scoped(Record, machine, all)).

a_runtime_without_the_nif_is_unsupported_test() ->
    ?assertEqual({error, unsupported}, erx_time_records:collect()).
