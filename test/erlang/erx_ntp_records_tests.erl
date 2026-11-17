%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntp_records_tests).
-moduledoc """
ntpd's record, `[ntp]` (erx_ntp_records): its session's status as the
runtime reports it, unknown before the first exchange, each attribute
`{error, unavailable}` while no ntpd runs here and timed out when ntpd
does not answer, and the path the whole-machine scope's alone.
""".

-include_lib("eunit/include/eunit.hrl").

attrs(Status) ->
    {ok, #{kind := ntp, path := [ntp], attrs := Attrs}} = erx_ntp_records:record(Status),
    maps:from_list([{Key, Value} || Key := {runtime, Value} <- Attrs]).

status(Last, Counts) ->
    {ok, Counts#{servers => [<<"pool.ntp.org">>], addresses => [{192, 0, 2, 7}], denied => [{10, 0, 2, 100}],
                 interval_s => 128, resolve_wait_s => 15, last => Last}}.

a_running_session_is_shown_test() ->
    Counts = #{samples => 3, dropped => 1, kisses => 1, silent => 2},
    ?assertEqual(#{servers => {ok, [<<"pool.ntp.org">>]}, addresses => {ok, [<<"192.0.2.7">>]},
                   denied => {ok, [<<"10.0.2.100">>]}, last => {ok, <<"192.0.2.7 sample">>},
                   interval_s => {ok, 128}, resolve_wait_s => {ok, 15}, samples => {ok, 3}, dropped => {ok, 1},
                   kisses => {ok, 1}, silent => {ok, 2}},
                 attrs(status({{192, 0, 2, 7}, sample}, Counts))).

nothing_exchanged_is_unknown_test() ->
    Unknown = #{samples => unknown, dropped => unknown, kisses => unknown, silent => unknown},
    Attrs = attrs(status(unknown, Unknown)),
    ?assertEqual([unknown], lists:usort([maps:get(Key, Attrs) || Key <- [last, samples, dropped, kisses, silent]])),
    ?assertEqual({ok, 128}, maps:get(interval_s, Attrs)).

a_missing_or_silent_session_is_shown_as_such_test_() ->
    [?_assertEqual([Missed], lists:usort(maps:values(attrs(Missed)))) || Missed <- [{error, unavailable}, {timeout, 500}]].

only_the_whole_machine_reads_it_test() ->
    ?assertEqual({ok, machine}, erx_inspector:declared_reachable([ntp], erx_schema:resolve([ntp]), all)),
    ?assertEqual(error, erx_inspector:declared_reachable([ntp], erx_schema:resolve([ntp]), [5])).

no_ntpd_here_is_unavailable_test() ->
    ?assertMatch({ok, #{attrs := #{last := {runtime, {error, unavailable}}}}}, erx_ntp_records:collect()).
