%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The decoder of root's authorized_keys, erx_boot_keys (docs/design-ssh.md,
%% "Root's login keys on the medium" and "Verification"): the lines it takes, skips
%% and ignores, each bound at its edge, and the findings it gives. This module writes
%% its own key lines, base64 over a blob it builds (RFC 4251, section 5), so a decoding
%% is checked against an encoder that shares no code with the decoder.

-module(erx_boot_keys_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TYPE, <<"ssh-ed25519">>).

string(Bytes) -> <<(byte_size(Bytes)):32, Bytes/binary>>.

blob(Seed) -> blob(?TYPE, binary:copy(<<Seed>>, 32)).

blob(Name, Key) -> <<(string(Name))/binary, (string(Key))/binary>>.

%% A key line of the blob, without its line feed.
line(Blob) -> <<?TYPE/binary, " ", (base64:encode(Blob))/binary>>.

line(Blob, Comment) -> <<(line(Blob))/binary, " ", Comment/binary>>.

file(Lines) -> iolist_to_binary([[Line, $\n] || Line <- Lines]).

two_keys_among_comments_blank_lines_tabs_and_crlf_give_both_blobs_in_order_test() ->
    File = iolist_to_binary(
             ["# root's keys\r\n",
              "\r\n",
              "\t ", line(blob(1), <<"alice@laptop">>), "\r\n",
              "   \t\n",
              "  # ", line(blob(9)), "\n",
              line(blob(2))]),
    ?assertEqual({ok, [blob(1), blob(2)], []}, erx_boot_keys:decode(File)).

a_hash_line_is_ignored_test() ->
    ?assertEqual({ok, [], []}, erx_boot_keys:decode(file([<<"#", (line(blob(1)))/binary>>]))).

an_empty_file_has_no_keys_test() ->
    ?assertEqual({ok, [], []}, erx_boot_keys:decode(<<>>)).

fields_are_separated_by_runs_of_spaces_and_tabs_test() ->
    File = file([<<"ssh-ed25519 \t \t", (base64:encode(blob(3)))/binary, "\t\t a comment\twith tabs">>]),
    ?assertEqual({ok, [blob(3)], []}, erx_boot_keys:decode(File)).

a_line_of_options_another_type_or_a_certificate_authority_is_skipped_test() ->
    File = file([<<"restrict ", (line(blob(1)))/binary>>,
                 <<"command=\"/bin/true\" ", (line(blob(1)))/binary>>,
                 <<"ssh-rsa ", (base64:encode(blob(1)))/binary>>,
                 <<"cert-authority ", (line(blob(1)))/binary>>,
                 <<"SSH-ED25519 ", (base64:encode(blob(1)))/binary>>,
                 line(blob(4))]),
    ?assertEqual({ok, [blob(4)],
                  [{1, not_a_plain_key}, {2, not_a_plain_key}, {3, not_a_plain_key},
                   {4, not_a_plain_key}, {5, not_a_plain_key}]},
                 erx_boot_keys:decode(File)).

a_key_not_of_68_base64_characters_does_not_decode_test() ->
    Key = base64:encode(blob(5)),
    68 = byte_size(Key),
    Short = binary:part(Key, 0, 67),
    UrlSafe = <<"-", (binary:part(Key, 1, 67))/binary>>,
    Padded = <<(binary:part(Key, 0, 67))/binary, "=">>,
    File = file([<<"ssh-ed25519 ", Short/binary>>,
                 <<"ssh-ed25519 ", Key/binary, "A">>,
                 <<"ssh-ed25519 ", UrlSafe/binary>>,
                 <<"ssh-ed25519 ", Padded/binary>>,
                 <<"ssh-ed25519">>,
                 <<"ssh-ed25519   ">>]),
    ?assertEqual({ok, [], [{N, does_not_decode} || N <- lists:seq(1, 6)]}, erx_boot_keys:decode(File)).

a_key_that_is_not_an_ed25519_blob_does_not_decode_test() ->
    %% Each is 51 bytes, so 68 characters, and differs from a key blob in one field.
    Lines = [line(blob(<<"ssh-ed25518">>, binary:copy(<<1>>, 32))),
             line(<<11:32, "ssh-ed25519", 31:32, 0:256>>),
             line(<<12:32, "ssh-ed25519", 32:32, 0:256>>),
             line(blob(<<"ssh-rsa">>, binary:copy(<<1>>, 36)))],
    ?assertEqual({ok, [], [{N, does_not_decode} || N <- lists:seq(1, 4)]},
                 erx_boot_keys:decode(file(Lines))).

a_skipped_line_leaves_the_others_usable_test() ->
    File = file([<<"no-pty ", (line(blob(1)))/binary>>, line(blob(6)), <<"ssh-ed25519 x">>, line(blob(7))]),
    ?assertEqual({ok, [blob(6), blob(7)], [{1, not_a_plain_key}, {3, does_not_decode}]},
                 erx_boot_keys:decode(File)).

a_carriage_return_is_dropped_only_before_a_line_feed_test() ->
    %% Without its line feed the last line keeps its carriage return, which is then
    %% part of the key field.
    File = <<(line(blob(1)))/binary, "\r\n", (line(blob(2)))/binary, "\r">>,
    ?assertEqual({ok, [blob(1)], [{2, does_not_decode}]}, erx_boot_keys:decode(File)).

a_line_of_1024_bytes_is_taken_and_one_of_1025_is_skipped_test() ->
    Taken = line(blob(1), binary:copy(<<"c">>, 1023 - byte_size(line(blob(1))) - 1)),
    1023 = byte_size(Taken),
    Long = line(blob(2), binary:copy(<<"c">>, 1024 - byte_size(line(blob(2))) - 1)),
    1024 = byte_size(Long),
    ?assertEqual({ok, [blob(1)], [{2, line_too_long}]}, erx_boot_keys:decode(file([Taken, Long]))),
    %% A last line without its line feed is held to the same 1024 bytes.
    ?assertEqual({ok, [blob(1)], []}, erx_boot_keys:decode(Taken)),
    ?assertEqual({ok, [blob(2)], []}, erx_boot_keys:decode(Long)),
    ?assertEqual({ok, [], [{1, line_too_long}]},
                 erx_boot_keys:decode(<<Long/binary, "c">>)).

a_long_comment_line_is_skipped_by_its_length_test() ->
    ?assertEqual({ok, [], [{1, line_too_long}]},
                 erx_boot_keys:decode(file([<<"#", (binary:copy(<<"x">>, 1024))/binary>>]))).

sixteen_keys_are_taken_and_seventeen_refuse_the_file_test() ->
    Sixteen = [blob(Seed) || Seed <- lists:seq(1, 16)],
    ?assertEqual({ok, Sixteen, []}, erx_boot_keys:decode(file([line(Blob) || Blob <- Sixteen]))),
    Seventeen = [line(blob(Seed)) || Seed <- lists:seq(1, 17)],
    ?assertEqual({error, too_many_keys}, erx_boot_keys:decode(file(Seventeen))).

skipped_lines_do_not_count_as_keys_test() ->
    Lines = [line(blob(Seed)) || Seed <- lists:seq(1, 16)] ++ [<<"restrict ", (line(blob(1)))/binary>>],
    ?assertMatch({ok, [_ | _], [{17, not_a_plain_key}]}, erx_boot_keys:decode(file(Lines))).

a_file_of_16_kib_is_read_and_one_byte_more_is_refused_test() ->
    Comment = <<"#", (binary:copy(<<"x">>, 1022))/binary, "\n">>,
    Full = <<(binary:copy(Comment, 15))/binary, (line(blob(1)))/binary, "\n",
             (binary:copy(<<"#">>, 1024 - byte_size(line(blob(1))) - 2))/binary, "\n">>,
    16384 = byte_size(Full),
    ?assertEqual({ok, [blob(1)], []}, erx_boot_keys:decode(Full)),
    ?assertEqual({error, too_long}, erx_boot_keys:decode(<<Full/binary, "\n">>)).

a_blob_is_its_own_copy_test() ->
    {ok, [Blob], []} = erx_boot_keys:decode(file([line(blob(8), binary:copy(<<"c">>, 200))])),
    ?assertEqual(51, binary:referenced_byte_size(Blob)).
