%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The patch reader's cases (docs/design-bluetooth.md, "Host tests of the cores",
%% erx_bt_patch): the records of a synthetic patch come back in file order, and a file
%% with a truncated last record or a foreign opcode is refused whole.
-module(erx_bt_patch_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WRITE_RAM, 16#FC4C).
-define(LAUNCH_RAM, 16#FC4E).

record(Opcode, Payload) -> <<Opcode:16/little, (byte_size(Payload)), Payload/binary>>.

synthetic() ->
    [{?WRITE_RAM, <<16#00, 16#00, 16#20, 16#00, 1, 2, 3>>},
     {?WRITE_RAM, binary:copy(<<16#A5>>, 255)},
     {?WRITE_RAM, <<>>},
     {?LAUNCH_RAM, <<16#FF, 16#FF, 16#FF, 16#FF>>}].

file(Records) -> iolist_to_binary([record(Opcode, Payload) || {Opcode, Payload} <- Records]).

records_replay_in_order_test() ->
    ?assertEqual({ok, synthetic()}, erx_bt_patch:parse(file(synthetic()))).

truncated_last_record_is_refused_whole_test() ->
    Whole = file(synthetic()),
    [?assertMatch({error, {truncated, _}}, erx_bt_patch:parse(binary:part(Whole, 0, byte_size(Whole) - Cut)))
     || Cut <- [1, 2, 4, 5, 6]].

record_longer_than_the_bytes_left_is_refused_test() ->
    Short = <<?WRITE_RAM:16/little, 10, 1, 2, 3>>,
    ?assertEqual({error, {truncated, 3}}, erx_bt_patch:parse(<<(record(?WRITE_RAM, <<>>))/binary, Short/binary>>)).

foreign_opcode_is_refused_whole_test() ->
    Foreign = file([hd(synthetic()), {16#FC2E, <<>>}, lists:last(synthetic())]),
    ?assertEqual({error, {foreign_opcode, 10, 16#FC2E}}, erx_bt_patch:parse(Foreign)).

empty_file_is_refused_test() ->
    ?assertEqual({error, empty}, erx_bt_patch:parse(<<>>)).

lone_opcode_byte_is_truncated_test() ->
    ?assertEqual({error, {truncated, 0}}, erx_bt_patch:parse(<<16#4C>>)).
