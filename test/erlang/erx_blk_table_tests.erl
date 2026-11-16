%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_blk_table, the boot medium's partition table and a window's check
%% (test/host/erx_blk_table_test.rb runs them). The records are built here from the PC
%% partition table's published format, with its offsets written out rather than taken
%% from erx_abi.hrl, so a wrong offset in the ABI file fails these cases; the layout's
%% sectors come from erx_abi.hrl, the layout's one source.

-module(erx_blk_table_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(EXTRA, 4096).
-define(DATA, (?ERX_MEDIUM_DATA_SECTORS_MIN + ?EXTRA)).
-define(CAPACITY, (?ERX_MEDIUM_DATA_START + ?DATA)).

%% A record: 446 bytes the reader ignores, four 16-byte entries, the signature 55 aa.
record(Entries) ->
    Padded = Entries ++ lists:duplicate(4 - length(Entries), {0, 0, 0, 0}),
    <<(binary:copy(<<16#e5>>, 446))/binary,
      << <<Status:8, 16#fe, 16#ff, 16#ff, Type:8, 16#fe, 16#ff, 16#ff, Start:32/little, Count:32/little>>
         || {Status, Type, Start, Count} <- Padded >>/binary,
      16#55, 16#aa>>.

%% The good table of a medium whose data partition has Data sectors, record by record in
%% medium order, each written out from the format: an extended boot record's first entry
%% starts from the record's own sector, and its link from the extended partition's start,
%% spanning the next record and its partition.
table(Data) ->
    End = ?ERX_MEDIUM_DATA_START + Data,
    Extended = ?ERX_MEDIUM_SYSTEM_A_EBR,
    SystemBEnd = ?ERX_MEDIUM_SYSTEM_B_START + ?ERX_MEDIUM_SYSTEM_SECTORS,
    VaultEnd = ?ERX_MEDIUM_VAULT_START + ?ERX_MEDIUM_VAULT_SECTORS,
    [{mbr, [{0, ?ERX_MEDIUM_RECORD_TYPE, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
            {0, ?ERX_MEDIUM_BOOT_TYPE, ?ERX_MEDIUM_BOOT_A_START, ?ERX_MEDIUM_BOOT_SECTORS},
            {0, ?ERX_MEDIUM_BOOT_TYPE, ?ERX_MEDIUM_BOOT_B_START, ?ERX_MEDIUM_BOOT_SECTORS},
            {0, ?ERX_MEDIUM_EXTENDED_TYPE, Extended, End - Extended}]},
     {system_a_ebr, [{0, ?ERX_MEDIUM_SYSTEM_TYPE, ?ERX_MEDIUM_SYSTEM_A_START - ?ERX_MEDIUM_SYSTEM_A_EBR,
                      ?ERX_MEDIUM_SYSTEM_SECTORS},
                     {0, ?ERX_MEDIUM_LINK_TYPE, ?ERX_MEDIUM_SYSTEM_B_EBR - Extended,
                      SystemBEnd - ?ERX_MEDIUM_SYSTEM_B_EBR}]},
     {system_b_ebr, [{0, ?ERX_MEDIUM_SYSTEM_TYPE, ?ERX_MEDIUM_SYSTEM_B_START - ?ERX_MEDIUM_SYSTEM_B_EBR,
                      ?ERX_MEDIUM_SYSTEM_SECTORS},
                     {0, ?ERX_MEDIUM_LINK_TYPE, ?ERX_MEDIUM_VAULT_EBR - Extended, VaultEnd - ?ERX_MEDIUM_VAULT_EBR}]},
     {vault_ebr, [{0, ?ERX_MEDIUM_VAULT_TYPE, ?ERX_MEDIUM_VAULT_START - ?ERX_MEDIUM_VAULT_EBR, ?ERX_MEDIUM_VAULT_SECTORS},
                  {0, ?ERX_MEDIUM_LINK_TYPE, ?ERX_MEDIUM_DATA_EBR - Extended, End - ?ERX_MEDIUM_DATA_EBR}]},
     {data_ebr, [{0, ?ERX_MEDIUM_DATA_TYPE, ?ERX_MEDIUM_DATA_START - ?ERX_MEDIUM_DATA_EBR, Data}]}].

admit(Capacity, Table) ->
    erx_blk_table:admit(Capacity, [record(Entries) || {_Name, Entries} <- Table]).

%% The layout's windows, each partition's under its role in abi/manifest.txt's
%% mf_window_role, but the record partition's, which holds two of those roles' records.
windows(Data) ->
    [{record, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
     {boot_a, ?ERX_MEDIUM_BOOT_A_START, ?ERX_MEDIUM_BOOT_SECTORS},
     {boot_b, ?ERX_MEDIUM_BOOT_B_START, ?ERX_MEDIUM_BOOT_SECTORS},
     {vault, ?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
     {data, ?ERX_MEDIUM_DATA_START, Data}].

-define(SYSTEM_A, {system, ?ERX_MEDIUM_SYSTEM_A_START, ?ERX_MEDIUM_SYSTEM_SECTORS}).
-define(SYSTEM_B, {system, ?ERX_MEDIUM_SYSTEM_B_START, ?ERX_MEDIUM_SYSTEM_SECTORS}).

%% Every layout role but the record partition's, and the system window's, is the name
%% abi/manifest.txt gives a window role.
roles_are_the_manifest_s_test() ->
    {a, System, ok} = erx_blk_table:booted([["boot", "normal", "a"]]),
    Roles = [Role || {Role, _, _} <- windows(?DATA) ++ System, Role =/= record],
    ?assertEqual([], Roles -- [Name || {Name, _Value} <- ?ERX_MF_WINDOW_ROLE_MEMBERS]).

%% PW1, the derivation from the boot words: the one system window lies on the system
%% partition of the slot `-erx_record boot VALUE SLOT` names, and a boot that names no
%% slot, an unknown boot or a runtime given no such words, has none.
booted_test_() ->
    [?_assertEqual({a, [?SYSTEM_A], ok}, erx_blk_table:booted([["console", "pl011"], ["boot", "normal", "a"]])),
     ?_assertEqual({a, [?SYSTEM_A], ok}, erx_blk_table:booted([["boot", "trial", "a"]])),
     ?_assertEqual({b, [?SYSTEM_B], ok}, erx_blk_table:booted([["boot", "normal", "b"]])),
     ?_assertEqual({b, [?SYSTEM_B], ok}, erx_blk_table:booted([["boot", "trial", "b"]])),
     ?_assertEqual({none, [], ok}, erx_blk_table:booted([["boot", "unknown", "none"]])),
     ?_assertEqual({none, [], ok}, erx_blk_table:booted([])),
     ?_assertEqual({none, [], ok}, erx_blk_table:booted([["console", "pl011", "1", "2", "3"]]))].

%% Every pair boot_pair.h refuses, a word too many or too few, two lists, and terms that
%% are not init's arguments: no slot and no window, and the refusal.
booted_refusals_test_() ->
    [?_assertEqual({none, [], {error, bad_boot}}, erx_blk_table:booted(Arguments))
     || Arguments <- [[["boot", "unknown", "a"]], [["boot", "normal", "none"]], [["boot", "normal", "c"]],
                      [["boot", "other", "a"]], [["boot", "normal"]], [["boot"]], [["boot", "normal", "a", "x"]],
                      [["boot", "normal", "a"], ["boot", "normal", "a"]], [["boot", 1, "a"]],
                      not_a_list, <<"boot normal a">>]].

%% The system window is read-only, as an image window is; every layout window is not.
read_only_test_() ->
    [?_assert(erx_blk_table:read_only(system)),
     ?_assert(erx_blk_table:read_only({image, <<"release">>})) |
     [?_assertNot(erx_blk_table:read_only(Role)) || {Role, _, _} <- windows(?DATA)]].

%% The admitted table equals the layout: the five records are read where the layout puts
%% them, and the good table's windows are the layout's partitions.
good_table_is_admitted_test() ->
    ?assertEqual({ok, windows(?DATA)}, admit(?CAPACITY, table(?DATA))).

data_partition_may_end_before_the_medium_test() ->
    ?assertEqual({ok, windows(?ERX_MEDIUM_DATA_SECTORS_MIN)},
                 admit(?CAPACITY, table(?ERX_MEDIUM_DATA_SECTORS_MIN))).

data_partition_past_the_medium_is_refused_test() ->
    ?assertEqual({error, {data_ebr, 1, sectors}}, admit(?CAPACITY, table(?DATA + 1))).

data_partition_below_the_minimum_is_refused_test() ->
    ?assertEqual({error, {data_ebr, 1, sectors}}, admit(?CAPACITY, table(?ERX_MEDIUM_DATA_SECTORS_MIN - 1))).

medium_below_the_layout_is_refused_test() ->
    Small = erx_blk_table:minimum_sectors() - 1,
    ?assertEqual({error, {capacity, Small}}, admit(Small, table(?ERX_MEDIUM_DATA_SECTORS_MIN))),
    ?assertEqual({error, {capacity, nonsense}}, admit(nonsense, table(?DATA))),
    ?assertEqual(ok, erx_blk_table:check_capacity(erx_blk_table:minimum_sectors())).

%% Exactly four extended boot records, at the sectors the layout fixes.
records_are_where_the_layout_puts_them_test() ->
    ?assertEqual([{mbr, 0}, {system_a_ebr, ?ERX_MEDIUM_SYSTEM_A_EBR}, {system_b_ebr, ?ERX_MEDIUM_SYSTEM_B_EBR},
                  {vault_ebr, ?ERX_MEDIUM_VAULT_EBR}, {data_ebr, ?ERX_MEDIUM_DATA_EBR}],
                 erx_blk_table:records()).

%% Every field of every entry, changed alone, is refused with that record, entry and field;
%% the first differing field in status, type, start, sectors order is the one named.
every_field_is_checked_test_() ->
    Good = table(?DATA),
    [?_assertEqual({error, {Name, Index, Field}}, admit(?CAPACITY, change(Good, Name, Index, Field)))
     || {Name, _} <- Good, Index <- [1, 2, 3, 4], Field <- [status, type, start, sectors],
        not (Name =:= data_ebr andalso Index =:= 1 andalso Field =:= sectors)].

change(Table, Name, Index, Field) ->
    Full = padded(proplists:get_value(Name, Table)),
    {Status, Type, Start, Count} = lists:nth(Index, Full),
    Changed = case Field of
                  status -> {16#80, Type, Start, Count};
                  type -> {Status, Type bxor 1, Start, Count};
                  start -> {Status, Type, Start + 1, Count};
                  sectors -> {Status, Type, Start, Count + 1}
              end,
    lists:keyreplace(Name, 1, Table, {Name, lists:sublist(Full, Index - 1) ++ [Changed] ++ lists:nthtail(Index, Full)}).

padded(Entries) -> Entries ++ lists:duplicate(4 - length(Entries), {0, 0, 0, 0}).

%% A fifth chained record is refused: the data partition's record names no next record,
%% and admission follows no chain, so a link there, even one to a well-formed record just
%% past the data partition, is a difference from the layout.
a_fifth_chained_record_is_refused_test() ->
    Good = table(?DATA),
    Fifth = {0, ?ERX_MEDIUM_LINK_TYPE, ?ERX_MEDIUM_DATA_START + ?DATA - ?ERX_MEDIUM_SYSTEM_A_EBR, 2048},
    Linked = lists:keyreplace(data_ebr, 1, Good, {data_ebr, proplists:get_value(data_ebr, Good) ++ [Fifth]}),
    ?assertEqual({error, {data_ebr, 2, type}}, admit(?CAPACITY, Linked)).


%% The longest data partition whose extended partition an MBR entry can still describe is
%% admitted; one sector more makes the extended partition's length wrap in its 32-bit
%% field, and that wrapped length is a difference, not a match.
an_extended_partition_past_32_bits_is_refused_test() ->
    Longest = (1 bsl 32) - 1 - (?ERX_MEDIUM_DATA_START - ?ERX_MEDIUM_SYSTEM_A_EBR),
    Capacity = ?ERX_MEDIUM_DATA_START + Longest + 1,
    ?assertMatch({ok, _}, admit(Capacity, table(Longest))),
    ?assertEqual({error, {mbr, 4, sectors}}, admit(Capacity, table(Longest + 1))).
bad_records_are_refused_test() ->
    [Mbr, SystemA, SystemB, Vault, Data] = [record(Entries) || {_, Entries} <- table(?DATA)],
    Unsigned = <<(binary:part(Vault, 0, 510))/binary, 16#aa, 16#55>>,
    ?assertEqual({error, {vault_ebr, signature}}, erx_blk_table:admit(?CAPACITY, [Mbr, SystemA, SystemB, Unsigned, Data])),
    ?assertEqual({error, {mbr, size}}, erx_blk_table:admit(?CAPACITY, [binary:part(Mbr, 0, 511), SystemA, SystemB, Vault, Data])),
    ?assertEqual({error, {mbr, size}}, erx_blk_table:admit(?CAPACITY, [<<Mbr/binary, 0>>, SystemA, SystemB, Vault, Data])),
    ?assertEqual({error, {system_b_ebr, size}}, erx_blk_table:admit(?CAPACITY, [Mbr, SystemA, <<>>, Vault, Data])),
    ?assertEqual({error, {data_ebr, size}}, erx_blk_table:admit(?CAPACITY, [Mbr, SystemA, SystemB, Vault, not_a_sector])),
    ?assertEqual({error, {mbr, size}}, erx_blk_table:admit(?CAPACITY, [<<>>, SystemA, SystemB, Vault, Data])).

%% The layout itself: records and partitions in medium order, each starting where the one
%% before it ends but for the gaps before the record partition and boot A, each boundary on
%% 1 MiB, every logical partition 1 MiB after its record, a slot's two partitions and its
%% system partition's record 512 MiB, every sector the MBR can address, and the MBR's
%% entries ending where its signature starts.
layout_is_consistent_test() ->
    Spans = [{0, 1}, {?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
             {?ERX_MEDIUM_BOOT_A_START, ?ERX_MEDIUM_BOOT_SECTORS}, {?ERX_MEDIUM_BOOT_B_START, ?ERX_MEDIUM_BOOT_SECTORS},
             {?ERX_MEDIUM_SYSTEM_A_EBR, 2048}, {?ERX_MEDIUM_SYSTEM_A_START, ?ERX_MEDIUM_SYSTEM_SECTORS},
             {?ERX_MEDIUM_SYSTEM_B_EBR, 2048}, {?ERX_MEDIUM_SYSTEM_B_START, ?ERX_MEDIUM_SYSTEM_SECTORS},
             {?ERX_MEDIUM_VAULT_EBR, 2048}, {?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
             {?ERX_MEDIUM_DATA_EBR, 2048}, {?ERX_MEDIUM_DATA_START, ?ERX_MEDIUM_DATA_SECTORS_MIN}],
    Pairs = lists:zip(lists:droplast(Spans), tl(Spans)),
    lists:foreach(fun({{Start, Count}, {Next, _}}) -> ?assert(Start + Count =< Next) end, Pairs),
    lists:foreach(fun({{Start, Count}, {Next, _}}) -> ?assertEqual(Start + Count, Next) end, lists:nthtail(2, Pairs)),
    ?assert(lists:all(fun({Start, _}) -> Start rem 2048 =:= 0 end, tl(Spans))),
    ?assertEqual(512 * 2048, ?ERX_MEDIUM_BOOT_SECTORS + 2048 + ?ERX_MEDIUM_SYSTEM_SECTORS),
    ?assert(?ERX_MEDIUM_DATA_START + ?ERX_MEDIUM_DATA_SECTORS_MIN < 1 bsl 32),
    ?assertEqual(446, ?ERX_MBR_ENTRIES_OFFSET),
    ?assertEqual(510, ?ERX_MBR_SIGNATURE_OFFSET),
    ?assertEqual(?ERX_MBR_SIGNATURE_OFFSET, ?ERX_MBR_ENTRIES_OFFSET + ?ERX_MBR_ENTRIES * ?ERX_MBR_ENTRY_SIZE).

place_test_() ->
    Window = {vault, 1000, 10},
    [?_assertEqual({ok, 1000}, erx_blk_table:place(Window, 0, 1)),
     ?_assertEqual({ok, 1009}, erx_blk_table:place(Window, 9, 1)),
     ?_assertEqual({ok, 1002}, erx_blk_table:place(Window, 2, 8)),
     ?_assertEqual({error, erange}, erx_blk_table:place(Window, 10, 1)),
     ?_assertEqual({error, erange}, erx_blk_table:place(Window, 9, 2)),
     ?_assertEqual({error, erange}, erx_blk_table:place(Window, 1 bsl 70, 1)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, 0, 0)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, -1, 1)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, 0, one)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, 1.0, 1))].
