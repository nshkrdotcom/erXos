%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The record volume's reader, erx_fat_read:root_file/3 (docs/design-storage.md,
%% "The record volume's one reader", and docs/design-ssh.md, "Verification"), over
%% the volumes test/fixtures/fat_record_volume.rb writes into ERX_FAT_VOLUMES: NAME.img,
%% an image of the whole record partition, and, for each volume whose file reads,
%% NAME.file, the bytes the reader must answer.

-module(erx_fat_read_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NAME, <<"authorized_keys">>).
-define(MAX, 16384).

path(Volume, Extension) -> filename:join(os:getenv("ERX_FAT_VOLUMES"), Volume ++ Extension).

%% A sector of the image, as the window's read answers it; a sector past the image
%% fails, as the window refuses one past the partition.
reader(Volume) ->
    {ok, Image} = file:read_file(path(Volume, ".img")),
    fun(Sector) when (Sector + 1) * 512 =< byte_size(Image) -> {ok, binary:part(Image, Sector * 512, 512)};
       (_Sector) -> {error, outside}
    end.

read(Volume) -> erx_fat_read:root_file(reader(Volume), ?NAME, ?MAX).

contents(Volume) ->
    {ok, Bytes} = file:read_file(path(Volume, ".file")),
    Bytes.

the_file_is_found_by_its_long_name_across_its_chain_test() ->
    ?assertEqual({ok, contents("found")}, read("found")).

the_long_name_is_compared_without_regard_to_case_test() ->
    ?assertEqual({ok, contents("upper")}, read("upper")),
    ?assertEqual({ok, contents("found")},
                 erx_fat_read:root_file(reader("found"), <<"Authorized_Keys">>, ?MAX)).

the_slack_of_the_last_cluster_is_not_answered_test() ->
    Contents = contents("slack"),
    ?assertEqual(100, byte_size(Contents)),
    ?assertEqual({ok, Contents}, read("slack")).

a_file_of_32_clusters_is_read_and_one_byte_more_is_refused_test() ->
    ?assertEqual({ok, contents("full")}, read("full")),
    ?assertEqual({error, too_long}, read("too_long")).

an_empty_file_reads_no_cluster_test() ->
    ?assertEqual({ok, <<>>}, read("empty")).

the_first_cluster_past_the_region_and_the_last_cluster_are_read_test() ->
    ?assertEqual({ok, contents("first_free")}, read("first_free")),
    ?assertEqual({ok, contents("last_cluster")}, read("last_cluster")).

no_file_of_that_name_is_not_found_test() ->
    ?assertEqual({error, not_found}, read("absent")),
    ?assertEqual({error, not_found}, read("pub")).

a_deleted_entry_is_not_found_test() ->
    ?assertEqual({error, not_found}, read("deleted")),
    ?assertEqual({error, not_found}, read("deleted_short")).

a_directory_or_a_label_of_that_name_is_not_found_test() ->
    ?assertEqual({error, not_found}, read("directory")),
    ?assertEqual({error, not_found}, read("label")).

a_long_name_whose_checksum_does_not_match_its_short_entry_is_not_found_test() ->
    ?assertEqual({error, not_found}, read("checksum")).

a_chain_into_the_records_region_is_refused_test() ->
    [?assertEqual({error, in_record_region}, read(Volume))
     || Volume <- ["region_record", "region_beside", "region_last"]].

a_chain_that_leaves_the_data_area_is_refused_test() ->
    [?assertEqual({error, does_not_read}, read(Volume))
     || Volume <- ["link_past_the_data_area", "link_free", "first_cluster_zero"]].

a_chain_that_loops_or_ends_early_is_refused_test() ->
    [?assertEqual({error, does_not_read}, read(Volume)) || Volume <- ["loop", "seen_twice", "short_chain"]].

a_long_name_across_two_sectors_is_found_test() ->
    ?assertEqual({ok, contents("straddle")}, read("straddle")).

a_long_name_out_of_order_is_not_found_test() ->
    ?assertEqual({error, not_found}, read("out_of_order")).

a_volume_not_laid_out_as_the_record_partition_is_refused_test() ->
    [?assertEqual({error, not_its_volume}, read(Volume))
     || Volume <- ["reserved_before_the_count", "data_not_at_the_record", "two_sector_clusters",
                   "large_sectors", "past_the_partition", "small_fat", "blank"]].

a_failed_sector_read_ends_the_reader_test() ->
    Read = reader("found"),
    ?assertEqual({error, read_failed}, erx_fat_read:root_file(fun(_) -> {error, eio} end, ?NAME, ?MAX)),
    ?assertEqual({error, read_failed},
                 erx_fat_read:root_file(fun(0) -> Read(0); (_) -> {error, eio} end, ?NAME, ?MAX)).

a_short_sector_is_a_failed_read_test() ->
    Read = reader("found"),
    ?assertEqual({error, read_failed},
                 erx_fat_read:root_file(fun(S) -> {ok, Bytes} = Read(S), {ok, binary:part(Bytes, 0, 511)} end,
                                        ?NAME, ?MAX)).

the_answer_is_its_own_copy_test() ->
    {ok, Bytes} = read("slack"),
    ?assertEqual(100, binary:referenced_byte_size(Bytes)).
