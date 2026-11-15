%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the session's export's fixed tree (docs/design-files.md, "Narrowing
%% for a program"): erx_session_export's callbacks, called without a grant, for a made-up
%% principal and command list, with stand-ins for the kernel's generator and the
%% session's tty that report to the test; and erx_shell_namespace:commands/1, which
%% names what /bin lists. test/host/erx_session_export_test.rb runs them on stock's
%% emulator.
-module(erx_session_export_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(PRINCIPAL, #{name => <<"alice">>, number => 1001}).
-define(COMMANDS, [<<"ls">>, <<"cat">>, <<"echo">>]).

%% The tree's state, with a generator that answers bytes of 7 and reports each read's
%% size, and a tty that reports each write.
fs() ->
    Test = self(),
    fs(fun(Size) -> Test ! {entropy, Size}, binary:copy(<<7>>, Size) end).

fs(Entropy) ->
    Test = self(),
    init(#{principal => ?PRINCIPAL, commands => ?COMMANDS, entropy => Entropy,
           tty => fun(Bytes) -> Test ! {tty, Bytes}, ok end}).

init(Args) ->
    ok = erx_fs_version:init(),
    {ok, Fs} = erx_session_export:init(Args),
    Fs.

%% The node a path from the root names, walking one name at a time.
walk(Path, Fs) ->
    {ok, Root, _Qid} = root(Fs),
    lists:foldl(fun(Name, {ok, Node, _}) -> erx_session_export:walk(Node, Name, Fs);
                   (_Name, Error) -> Error
                end, {ok, Root, none}, Path).

root(Fs) ->
    {ok, <<"export">>, Root, Qid} = erx_session_export:root(Fs),
    {ok, Root, Qid}.

node_at(Path, Fs) ->
    {ok, Node, _Qid} = walk(Path, Fs),
    Node.

open(Path, Flags, Fs) ->
    erx_session_export:open(node_at(Path, Fs), Flags, Fs).

names(Path, Fs) ->
    {ok, Handle} = open(Path, 0, Fs),
    {ok, Entries} = erx_session_export:readdir(Handle, 0, 256, Fs),
    [Name || {_Qid, _Offset, _Type, Name} <- Entries].

read(Path, Count, Fs) ->
    {ok, Handle} = open(Path, 0, Fs),
    erx_session_export:read(Handle, 0, Count, Fs).

mode(Path, Fs) ->
    {ok, #{mode := Mode}} = erx_session_export:getattr(node_at(Path, Fs), Fs),
    Mode.

messages() ->
    receive {Tag, _} = Message when Tag =:= tty; Tag =:= entropy -> [Message | messages()]
    after 0 -> []
    end.

%% ---------------------------------------------------------------------------
%% The tree
%% ---------------------------------------------------------------------------

the_root_lists_bin_dev_and_etc_test() ->
    Fs = fs(),
    ?assertEqual([<<"bin">>, <<"dev">>, <<"etc">>], names([], Fs)),
    ?assertEqual([<<"null">>, <<"tty">>, <<"urandom">>, <<"zero">>], names([<<"dev">>], Fs)),
    ?assertEqual([<<"group">>, <<"passwd">>], names([<<"etc">>], Fs)).

bin_lists_the_commands_sorted_once_test() ->
    Fs = init(#{principal => ?PRINCIPAL, commands => [<<"ls">>, <<"cat">>, <<"ls">>]}),
    ?assertEqual([<<"cat">>, <<"ls">>], names([<<"bin">>], Fs)).

a_walk_finds_only_the_trees_names_test() ->
    Fs = fs(),
    ?assertEqual({error, enoent}, walk([<<"usr">>], Fs)),
    ?assertEqual({error, enoent}, walk([<<"dev">>, <<"draw">>], Fs)),
    ?assertEqual({error, enoent}, walk([<<"bin">>, <<"rc">>], Fs)),
    ?assertEqual({error, enotdir}, walk([<<"etc">>, <<"passwd">>, <<"x">>], Fs)),
    ?assertEqual({error, enotdir}, walk([<<"dev">>, <<"null">>, <<"x">>], Fs)).

%% Every file's path from the root, the directories first.
dir_paths() ->
    [[<<"bin">>], [<<"dev">>], [<<"etc">>]].

file_paths(Fs) ->
    [[Dir, Name] || [Dir] <- dir_paths(), Name <- names([Dir], Fs)].

qid_at(Path, Fs) ->
    {ok, _Node, Qid} = walk(Path, Fs),
    Qid.

no_two_nodes_share_a_qid_path_test() ->
    Fs = fs(),
    {ok, _Root, RootQid} = root(Fs),
    Qids = [RootQid | [qid_at(Path, Fs) || Path <- dir_paths() ++ file_paths(Fs)]],
    ?assertEqual(length(Qids), length(lists:usort([Path || {_, _, Path} <- Qids]))).

a_directory_has_a_directory_qid_and_a_file_a_file_qid_test() ->
    Fs = fs(),
    {ok, _Root, {RootType, _, _}} = root(Fs),
    ?assertEqual([?ERX_P9_QTDIR || _ <- [root | dir_paths()]],
                 [RootType | [Type || Path <- dir_paths(),
                                      {Type, _, _} <- [qid_at(Path, Fs)]]]),
    ?assertEqual([{Path, 0} || Path <- file_paths(Fs)],
                 [{Path, Type} || Path <- file_paths(Fs), {Type, _, _} <- [qid_at(Path, Fs)]]).

a_walk_and_a_listing_give_one_qid_test() ->
    Fs = fs(),
    {ok, _, Null} = walk([<<"dev">>, <<"null">>], Fs),
    ?assertEqual({ok, null, Null}, walk([<<"dev">>, <<"null">>], Fs)),
    {ok, Dev} = open([<<"dev">>], 0, Fs),
    {ok, Entries} = erx_session_export:readdir(Dev, 0, 256, Fs),
    ?assertEqual({Null, 1, ?ERX_P9_DT_CHR, <<"null">>}, lists:keyfind(<<"null">>, 4, Entries)).

a_grant_started_again_serves_new_files_test() ->
    {ok, _, Before} = walk([<<"etc">>, <<"passwd">>], fs()),
    {ok, _, After} = walk([<<"etc">>, <<"passwd">>], fs()),
    ?assertNotEqual(Before, After).

modes_say_what_each_node_allows_test() ->
    Fs = fs(),
    ?assertEqual(?ERX_P9_S_IFDIR bor 8#555, mode([<<"bin">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFREG bor 8#111, mode([<<"bin">>, <<"ls">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFCHR bor 8#666, mode([<<"dev">>, <<"null">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFCHR bor 8#666, mode([<<"dev">>, <<"tty">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFCHR bor 8#444, mode([<<"dev">>, <<"urandom">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFREG bor 8#444, mode([<<"etc">>, <<"passwd">>], Fs)).

%% ---------------------------------------------------------------------------
%% Opens
%% ---------------------------------------------------------------------------

a_command_never_opens_test() ->
    Fs = fs(),
    [?assertEqual({error, eacces}, open([<<"bin">>, <<"cat">>], Flags, Fs))
     || Flags <- [0, ?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR]].

a_directory_opens_for_reading_only_test() ->
    Fs = fs(),
    ?assertEqual({error, eisdir}, open([<<"etc">>], ?ERX_P9_O_WRONLY, Fs)),
    ?assertEqual({error, eisdir}, open([], ?ERX_P9_O_RDWR, Fs)),
    {ok, Handle} = open([<<"etc">>], 0, Fs),
    ?assertEqual({error, eisdir}, erx_session_export:read(Handle, 0, 10, Fs)).

the_read_only_files_refuse_writing_test() ->
    Fs = fs(),
    [?assertEqual({error, eacces}, open(Path, Flags, Fs))
     || Path <- [[<<"etc">>, <<"passwd">>], [<<"etc">>, <<"group">>],
                 [<<"dev">>, <<"urandom">>]],
        Flags <- [?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR, ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC]].

access_mode_three_is_refused_test() ->
    ?assertEqual({error, einval}, open([<<"dev">>, <<"null">>], ?ERX_P9_O_ACCMODE, fs())).

an_open_allows_only_its_access_test() ->
    Fs = fs(),
    {ok, ReadOnly} = open([<<"dev">>, <<"zero">>], 0, Fs),
    ?assertEqual({error, ebadf}, erx_session_export:write(ReadOnly, 0, <<"x">>, Fs)),
    {ok, WriteOnly} = open([<<"dev">>, <<"zero">>], ?ERX_P9_O_WRONLY, Fs),
    ?assertEqual({error, ebadf}, erx_session_export:read(WriteOnly, 0, 4, Fs)),
    {ok, Both} = open([<<"dev">>, <<"zero">>], ?ERX_P9_O_RDWR, Fs),
    ?assertEqual({ok, 1, 0}, erx_session_export:write(Both, 0, <<"x">>, Fs)),
    ?assertEqual({ok, <<0, 0>>}, erx_session_export:read(Both, 0, 2, Fs)).

%% ---------------------------------------------------------------------------
%% The devices
%% ---------------------------------------------------------------------------

null_reads_empty_and_takes_every_write_test() ->
    Fs = fs(),
    ?assertEqual({ok, <<>>}, read([<<"dev">>, <<"null">>], 4096, Fs)),
    {ok, Null} = open([<<"dev">>, <<"null">>], ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC, Fs),
    ?assertEqual({ok, 5, 100}, erx_session_export:write(Null, 100, <<"hello">>, Fs)),
    ?assertEqual([], messages()).

zero_reads_zeros_test() ->
    Fs = fs(),
    ?assertEqual({ok, binary:copy(<<0>>, 65536)}, read([<<"dev">>, <<"zero">>], 65536, Fs)).

urandom_reads_the_generator_within_its_bound_test() ->
    Fs = fs(),
    ?assertEqual({ok, binary:copy(<<7>>, 600)}, read([<<"dev">>, <<"urandom">>], 600, Fs)),
    ?assertEqual([{entropy, 256}, {entropy, 256}, {entropy, 88}], messages()),
    ?assertEqual({ok, binary:copy(<<7>>, 512)}, read([<<"dev">>, <<"urandom">>], 512, Fs)),
    ?assertEqual([{entropy, 256}, {entropy, 256}], messages()).

a_refused_generator_read_answers_eio_test() ->
    Fs = fs(fun(_Size) -> error({entropy, ebusy}) end),
    ?assertEqual({error, eio}, read([<<"dev">>, <<"urandom">>], 16, Fs)).

tty_takes_writes_unchanged_and_refuses_reads_test() ->
    Fs = fs(),
    {ok, Tty} = open([<<"dev">>, <<"tty">>], ?ERX_P9_O_RDWR, Fs),
    Bytes = <<"\e[1mbold\e[0m\r\n">>,
    ?assertEqual({ok, byte_size(Bytes), 0}, erx_session_export:write(Tty, 0, Bytes, Fs)),
    ?assertEqual([{tty, Bytes}], messages()),
    ?assertEqual({error, enotsup}, erx_session_export:read(Tty, 0, 16, Fs)).

a_write_to_an_ended_tty_fails_alone_test() ->
    Fs = init(#{principal => ?PRINCIPAL, commands => [],
                tty => fun(_Bytes) -> exit(noproc) end}),
    {ok, Tty} = open([<<"dev">>, <<"tty">>], ?ERX_P9_O_WRONLY, Fs),
    ?assertEqual({error, eio}, erx_session_export:write(Tty, 0, <<"x">>, Fs)).

%% ---------------------------------------------------------------------------
%% /etc
%% ---------------------------------------------------------------------------

%% Each line split as musl's getpwent and getgrent split it: by colon, the last field
%% running to the end of the line.
lines(Text) ->
    [binary:split(Line, <<":">>, [global])
     || Line <- binary:split(Text, <<"\n">>, [global, trim])].

passwd_holds_the_principal_and_nobody_test() ->
    {ok, Text} = read([<<"etc">>, <<"passwd">>], 4096, fs()),
    ?assertEqual([[<<"alice">>, <<"*">>, <<"1001">>, <<"1001">>, <<>>, <<"/">>, <<"/bin/rc">>],
                  [<<"nobody">>, <<"*">>, <<"65534">>, <<"65534">>, <<"Unprivileged user">>,
                   <<"/nonexistent">>, <<"/usr/sbin/nologin">>]],
                 lines(Text)).

group_holds_the_principal_and_nobody_test() ->
    {ok, Text} = read([<<"etc">>, <<"group">>], 4096, fs()),
    ?assertEqual([[<<"alice">>, <<"*">>, <<"1001">>, <<>>],
                  [<<"nobody">>, <<"*">>, <<"65534">>, <<>>]],
                 lines(Text)).

a_text_reads_from_any_offset_test() ->
    Fs = fs(),
    {ok, Whole} = read([<<"etc">>, <<"passwd">>], 4096, Fs),
    {ok, Handle} = open([<<"etc">>, <<"passwd">>], 0, Fs),
    ?assertEqual({ok, binary:part(Whole, 6, 3)}, erx_session_export:read(Handle, 6, 3, Fs)),
    ?assertEqual({ok, <<>>}, erx_session_export:read(Handle, byte_size(Whole), 10, Fs)),
    ?assertEqual({ok, <<>>}, erx_session_export:read(Handle, byte_size(Whole) + 10, 10, Fs)).

%% ---------------------------------------------------------------------------
%% Creates
%% ---------------------------------------------------------------------------

a_create_of_a_device_opens_it_test() ->
    Fs = fs(),
    Flags = ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC,
    {ok, _, Qid} = walk([<<"dev">>, <<"null">>], Fs),
    {ok, null, Qid, Null} = erx_session_export:make(dev, <<"null">>, {file, 8#666, Flags}, Fs),
    ?assertEqual({ok, 3, 0}, erx_session_export:write(Null, 0, <<"abc">>, Fs)),
    ?assertEqual({error, eexist},
                 erx_session_export:make(dev, <<"null">>,
                                         {file, 8#666, Flags bor ?ERX_P9_O_EXCL}, Fs)),
    %% A create of urandom opens it as its open would: not for writing.
    ?assertEqual({error, eacces},
                 erx_session_export:make(dev, <<"urandom">>, {file, 8#666, Flags}, Fs)).

no_create_makes_a_name_test() ->
    Fs = fs(),
    File = {file, 8#644, ?ERX_P9_O_WRONLY},
    [?assertEqual({error, eacces}, erx_session_export:make(Dir, Name, What, Fs))
     || {Dir, Name, What} <- [{dev, <<"draw">>, File}, {etc, <<"passwd">>, File},
                              {etc, <<"rc.conf">>, File}, {bin, <<"ls">>, File},
                              {root, <<"tmp">>, {directory, 8#755, self()}},
                              {dev, <<"null">>, {directory, 8#755, self()}}]].

statfs_and_clunk_test() ->
    Fs = fs(),
    {ok, #{type := Type}} = erx_session_export:statfs(Fs),
    ?assertEqual(?ERX_P9_MAGIC_DEVFS, Type),
    {ok, Handle} = open([<<"dev">>, <<"null">>], 0, Fs),
    ?assertEqual(ok, erx_session_export:clunk(Handle, Fs)).

%% ---------------------------------------------------------------------------
%% What /bin lists
%% ---------------------------------------------------------------------------

bin_lists_the_erlang_commands_alone_test() ->
    Command = fun(Name) ->
                      Module = binary_to_atom(<<"erx_cmd_test_", Name/binary>>),
                      {Module, [{erx_command, [binary_to_atom(Name)]}, {erx_usage, "usage"}],
                       [{run, 2}]}
              end,
    {Table, []} = erx_shell_namespace:build([Command(<<"wc">>), Command(<<"cat">>)]),
    {Conflicted, []} = erx_shell_namespace:build(
                         [Command(<<"cat">>), Command(<<"wc">>),
                          {erx_cmd_test_other_wc, [{erx_command, [wc]}, {erx_usage, "usage"}],
                           [{run, 2}]}]),
    %% cd and the job builtins are the runner's, and a conflicting name runs nothing.
    ?assertEqual([<<"cat">>, <<"wc">>], erx_shell_namespace:commands(Table)),
    ?assertEqual([<<"cat">>], erx_shell_namespace:commands(Conflicted)).
