%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_hid_desc, the HID report descriptor's parser
%% (docs/design-usb.md, "Fuzz targets"), run by tools/fuzz/erx_hid_desc.rb. Each round
%% parses one descriptor, drawn three ways: items generated with values around every
%% bound, so the bounds themselves are crossed; a fixture descriptor with bytes flipped,
%% inserted or cut; and random bytes. A round fails with a marker the runner looks for:
%% `crash` when parse/1 raises or answers something other than its two shapes, and
%% `out_of_bounds` when an accepted layout breaks a bound the stack relies on, a field
%% outside its report, a field wider than 32 bits, a report longer than the interrupt
%% buffer with its id byte, more than 15 numbered reports or 64 usage ranges a field.
-module(erx_hid_desc_fuzz).

-export([run/1]).

-define(ROUNDS, 30000).
-define(REASONS, [too_long, truncated, push_too_deep, pop_without_push, unbalanced_collection,
                  too_many_usages, too_many_report_ids, bad_report_id, report_count_too_large,
                  field_too_wide, report_too_large, mixed_report_ids]).

run([Seed]) ->
    S = list_to_integer(Seed),
    _ = rand:seed(exsss, {S, S, S}),
    Accepted = lists:foldl(fun(_, N) -> N + fuzz_round(descriptor()) end, 0, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted]).

fuzz_round(Bytes) ->
    Answer = try erx_hid_desc:parse(Bytes)
             catch Class:Reason:Stack -> fail(crash, Bytes, {Class, Reason, Stack})
             end,
    case Answer of
        {ok, Layout} ->
            check(Layout, Bytes),
            1;
        {error, Why} ->
            lists:member(Why, ?REASONS) orelse fail(crash, Bytes, {error, Why}),
            0;
        Other ->
            fail(crash, Bytes, Other)
    end.

fail(Marker, Bytes, Detail) ->
    io:format("~s: ~p~n descriptor ~p~n", [Marker, Detail, Bytes]),
    halt(1).

check(Layout = #{reports := Reports, numbered := Numbered, largest := Largest}, Bytes) ->
    IdByte = case Numbered of true -> 1; false -> 0 end,
    Ids = maps:keys(Reports),
    Sound = Numbered =:= lists:any(fun(Id) -> Id =/= 0 end, Ids)
        andalso not (Numbered andalso lists:member(0, Ids))
        andalso length(Ids) =< 15
        andalso Largest =:= lists:max([0 | [B || _ := #{bytes := B} <- Reports]])
        andalso lists:all(fun(Report) -> sound(Report, IdByte) end, maps:values(Reports)),
    Sound orelse fail(out_of_bounds, Bytes, Layout).

sound(#{fields := Fields, bytes := Bytes}, IdByte) ->
    Bytes >= 1 andalso Bytes + IdByte =< 1024
        andalso lists:all(fun(#{offset := O, size := S, count := C, usages := U}) ->
                                  S >= 1 andalso S =< 32 andalso C >= 1 andalso C =< 2048
                                      andalso O + S * C =< Bytes * 8 andalso length(U) =< 64
                                      andalso lists:all(fun({Lo, Hi}) -> Lo =< Hi end, U)
                          end, Fields).

descriptor() ->
    case rand:uniform(10) of
        N when N =< 6 -> iolist_to_binary(items(rand:uniform(40)));
        N when N =< 9 -> mutated(lists:nth(rand:uniform(3), fixtures()));
        _ -> rand:bytes(rand:uniform(64))
    end.

fixtures() ->
    [erx_hid_desc_tests:boot_keyboard(), erx_hid_desc_tests:boot_mouse(), erx_hid_desc_tests:tablet()].

items(0) -> [];
items(N) -> [item() | items(N - 1)].

%% Report ids are drawn from 1 to 40 in runs, so more than 15 named reports are reached;
%% sizes and counts straddle 32 bits and the 1 KiB report.
item() ->
    case rand:uniform(16) of
        1 -> erx_hid_desc_tests:report_size(pick([0, 1, 3, 7, 8, 16, 31, 32, 33, 40, 64]));
        2 -> erx_hid_desc_tests:report_count(pick([0, 1, 2, 6, 8, 64, 255, 1023, 1024, 1025, 2048, 2049]));
        3 -> erx_hid_desc_tests:report_id(pick([0, 1, 2, 15, 16, 255, 256, rand:uniform(40)]));
        4 -> erx_hid_desc_tests:input(rand:uniform(8) - 1);
        5 -> erx_hid_desc_tests:input(rand:uniform(8) - 1);
        6 -> erx_hid_desc_tests:output(rand:uniform(8) - 1);
        7 -> erx_hid_desc_tests:feature(rand:uniform(8) - 1);
        8 -> erx_hid_desc_tests:usage_page(pick([1, 7, 9, 16#ff00]));
        9 -> erx_hid_desc_tests:usage(rand:uniform(16#3ff) - 1);
        10 -> erx_hid_desc_tests:usage_min(rand:uniform(256) - 1);
        11 -> erx_hid_desc_tests:usage_max(rand:uniform(256) - 1);
        12 -> erx_hid_desc_tests:logical_min(pick([-32768, -127, -1, 0, 1]));
        13 -> erx_hid_desc_tests:logical_max(pick([0, 1, 101, 127, 255, 32767, 65535]));
        14 -> pick([erx_hid_desc_tests:push(), erx_hid_desc_tests:pop()]);
        15 -> pick([erx_hid_desc_tests:collection(1), erx_hid_desc_tests:end_collection()]);
        16 -> [[erx_hid_desc_tests:report_id(rand:uniform(40)), erx_hid_desc_tests:report_size(8),
                erx_hid_desc_tests:report_count(1), erx_hid_desc_tests:input(2)]
               || _ <- lists:seq(1, rand:uniform(20))]
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

mutated(Bytes) ->
    lists:foldl(fun(_, B) -> mutation(B) end, Bytes, lists:seq(1, rand:uniform(4))).

mutation(<<>>) -> rand:bytes(1);
mutation(B) ->
    At = rand:uniform(byte_size(B)) - 1,
    <<Head:At/binary, Byte, Tail/binary>> = B,
    case rand:uniform(3) of
        1 -> <<Head/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1))), Tail/binary>>;
        2 -> <<Head/binary, (rand:bytes(rand:uniform(4)))/binary, Byte, Tail/binary>>;
        3 -> <<Head/binary, Tail/binary>>
    end.
