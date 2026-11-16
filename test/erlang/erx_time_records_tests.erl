%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_time_records_tests).
-moduledoc """
The clock's record, `[time]` (erx_time_records): the time page's state
for each page, the service's attributes unsupported, and the record seen
by any scope, whole by the whole-machine scope and without `server` and
`source`, another domain's facts, by any other. test/host/erx_inspector_test.rb
seeds a swap of `boot` and `unset` in erx_clock_core:state/2 and a scoped path list without `[time]`.
""".

-include_lib("eunit/include/eunit.hrl").

%% A build date as a floor, in nanoseconds.
-define(FLOOR, 1_794_787_200_000_000_000).

page(Cold, Offset) -> {ok, #{cold => Cold, offset => Offset, monotonic => 1000}}.

attrs(Read) ->
    {ok, #{kind := clock, path := [time], attrs := Attrs}} = erx_time_records:record(Read, ?FLOOR),
    Attrs.

state(Read) -> maps:get(state, attrs(Read)).

each_page_state_is_shown_test_() ->
    [?_assertEqual({kernel, {ok, unset}}, state(page(true, 0))),
     ?_assertEqual({kernel, {ok, boot}}, state(page(true, 1_700_000_000_000_000_000))),
     ?_assertEqual({kernel, {ok, set}}, state(page(false, 1_700_000_000_000_000_000))),
     ?_assertEqual({kernel, {ok, set}}, state(page(false, 0))),
     ?_assertEqual({kernel, {ok, approximate}}, state(page(false, ?FLOOR))),
     ?_assertEqual({kernel, {ok, set}}, state(page(false, ?FLOOR + 1)))].

a_page_out_of_sequence_is_its_refusal_test() ->
    ?assertEqual({kernel, {error, limit}}, state({error, limit})).

the_services_attributes_are_unsupported_test() ->
    Attrs = attrs(page(true, 0)),
    {ok, Keys} = erx_schema:attributes(clock),
    ?assertEqual(lists:sort(Keys), lists:sort(maps:keys(Attrs))),
    ?assertEqual([{service, unsupported}], lists:usort([V || K := V <- Attrs, K =/= state])).

any_scope_reads_the_record_test() ->
    {ok, #{attrs := Attrs} = Record} = erx_time_records:record(page(true, 0), ?FLOOR),
    ?assertEqual({ok, machine}, erx_inspector:declared_reachable([time], erx_schema:resolve([time]), [5])),
    ?assertEqual(Record#{attrs := maps:without([server, source], Attrs)},
                 erx_inspector:scoped(Record, machine, [5])),
    ?assertEqual(Record, erx_inspector:scoped(Record, machine, all)).

a_runtime_without_the_nif_is_unsupported_test() ->
    ?assertEqual({error, unsupported}, erx_time_records:collect()).
