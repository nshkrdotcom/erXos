%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_virtio_console:format_status/1: a crash report of the Bluetooth line's
%% driver shows no byte of the controller's traffic, which carries keys during pairing
%% (docs/design-bluetooth.md, "Security"), whether the bytes sit in the reason, the last
%% message, the log or the core the state holds. The driver runs in the system domain,
%% where no report filter runs (docs/design-log.md, "Reports carry no term").
%% test/host/erx_virtio_console_test.rb runs them on stock's emulator.

-module(erx_virtio_console_tests).
-include_lib("eunit/include/eunit.hrl").

-define(MARKER, <<"MARKER-KEY-0123456789">>).

%% The driver's #state{} is private to it, so this tuple spells its layout: dev, irq, rx,
%% tx, owner and a core holding a write of the marker. A field added to the record makes
%% the state view answer hidden, which the second case notices.
state() ->
    {_Done, Core} = erx_virtio_console_core:write(make_ref(), ?MARKER, erx_virtio_console_core:new(16, 4096)),
    {state, 1, irq, 2, 3, self(), Core}.

status(Message) ->
    erx_virtio_console:format_status(
      #{reason => {badmatch, ?MARKER}, state => state(), message => Message,
        log => [{in, {erx_console_output, make_ref(), ?MARKER}}]}).

%% The keys whose value still holds the marker.
leaking(Status) ->
    [Key || Key := Value <- Status, binary:match(term_to_binary(Value), ?MARKER) =/= nomatch].

format_status_shows_no_byte_of_the_traffic_test() ->
    Status = status({erx_console_output, make_ref(), ?MARKER}),
    ?assertEqual([], leaking(Status)),
    ?assertMatch(#{reason := badmatch, log := []}, Status).

%% The views keep what is not traffic: the state's handles and owner, and a write's length.
format_status_keeps_the_state_and_the_writes_length_test() ->
    Size = byte_size(?MARKER),
    #{state := State, message := Message} = status({erx_console_output, make_ref(), ?MARKER}),
    ?assertMatch({state, 1, irq, 2, 3, _, redacted}, State),
    ?assertMatch({erx_console_output, _, Size}, Message).

%% The views are total: a write of an iolist and a state of another shape are hidden, not
%% a raise, which would leave gen_server's report with the raw reason and message.
format_status_hides_what_the_views_do_not_know_test() ->
    Status = erx_virtio_console:format_status(
               #{state => {other, ?MARKER}, message => {erx_console_output, make_ref(), [?MARKER]}}),
    ?assertEqual(#{state => hidden, message => hidden}, Status).
