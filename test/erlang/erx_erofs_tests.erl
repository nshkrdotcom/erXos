%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the EROFS reader, erx_erofs, and its funnel, erx_verity, over the
%% fixture images tools/erofs_fixtures.rb writes with fsimg from the tree
%% test/fixtures/erofs/tree.terms declares (ERX_EROFS_FIXTURES names the directory).
-module(erx_erofs_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([fixture/1, window/1, window/2, open/1, open/2, expected/0, contents/2, owner/1, agrees/2]).

-include_lib("kernel/include/file.hrl").

-define(BLOCK, 4096).
-define(SECTOR, 512).
%% How long a RAM window waits for a request before it ends, so the fuzz target's windows
%% do not pile up.
-define(WINDOW_IDLE, 60000).

%% Fixture helpers, which the fuzz target shares.

fixture(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_EROFS_FIXTURES"), Name ++ ".img")),
    Bytes.

%% A RAM window over Bytes: a process that answers gen_server calls as erx_blk_window
%% does, info with its length in sectors and each read of whole blocks with what
%% Serve(FirstBlock, Blocks, Part) makes of the blocks asked for. Anything else, and a
%% read past the bytes, ends it, as a crashed window would.
window(Bytes) -> window(Bytes, fun(_, _, Part) -> {ok, Part} end).

window(Bytes, Serve) -> spawn(fun() -> serve(Bytes, Serve) end).

serve(Bytes, Serve) ->
    receive
        {'$gen_call', From, info} ->
            gen:reply(From, {ok, #{role => system, sectors => byte_size(Bytes) div ?SECTOR}});
        {'$gen_call', From, {read, Sector, Count}} when Sector rem 8 =:= 0, Count rem 8 =:= 0 ->
            Part = binary:part(Bytes, Sector * ?SECTOR, Count * ?SECTOR),
            gen:reply(From, Serve(Sector div 8, Count div 8, Part))
    after ?WINDOW_IDLE ->
        exit(idle)
    end,
    serve(Bytes, Serve).

%% The funnel open on a RAM window over Bytes.
open(Bytes) -> erx_verity:open(window(Bytes), unchecked).

open(Bytes, Serve) -> erx_verity:open(window(Bytes, Serve), unchecked).

expected() ->
    {ok, Terms} = file:consult(filename:join(os:getenv("ERX_EROFS_FIXTURES"), "tree.terms")),
    Terms.

contents(Size, Seed) -> << <<((I * 7 + Seed) band 255)>> || I <- lists:seq(0, Size - 1) >>.

mount(Name) ->
    {ok, Fs} = erx_erofs:mount(window(fixture(Name)), unchecked, fun(Line) -> self() ! {log, Line} end),
    Fs.

logged() ->
    receive {log, Line} -> Line after 0 -> none end.

%% The tree, through every operation, on each image the reader implements:
%% compact inodes owned by root, and extended inodes whose owner is beyond
%% the 16 bits a compact inode holds.

tree_test_() ->
    [{Name, fun() -> agrees(mount(Name), owner(Name)) end} || Name <- ["compact", "extended"]].

%% The owner of every entry of a fixture image.
owner("extended") -> 70000;
owner(_) -> 0.

agrees(Fs, Owner) ->
    lists:foreach(fun(Entry) -> entry(Fs, Owner, Entry) end, expected()),
    none = logged().

entry(Fs, Owner, {regular, Names, Size, Seed}) ->
    Bytes = contents(Size, Seed),
    ?assertEqual({ok, Bytes}, erx_erofs:read_file(Fs, Names)),
    {ok, #{type := regular, size := Size, mode := 8#644, uid := Owner, gid := Owner, mtime := {0, 0}}} =
        erx_erofs:read_file_info(Fs, Names),
    [?assertEqual(slice(Bytes, Offset, Length), erx_erofs:pread(Fs, Names, Offset, Length))
     || Offset <- [0, 1, 4095, 4096, 3 * 4096 - 1, 3 * 4096, Size - 1, Size, Size + 1],
        Offset >= 0, Length <- [0, 1, 50, 5000, 1 bsl 40]],
    ?assertEqual({lists:duplicate(length(Names) - 1, directory) ++ [other], ok}, erx_erofs:walk(Fs, Names));
entry(Fs, _Owner, {symlink, Names, Target}) ->
    ?assertEqual({ok, Target}, erx_erofs:read_link(Fs, Names)),
    {ok, #{type := symlink}} = erx_erofs:read_file_info(Fs, Names),
    ?assertEqual({error, einval}, erx_erofs:read_file(Fs, Names)),
    ?assertEqual({lists:duplicate(length(Names) - 1, directory) ++ [link], ok},
                 erx_erofs:walk(Fs, Names ++ [<<"after">>]));
entry(Fs, _Owner, {directory, Names, Children}) ->
    ?assertEqual({ok, Children}, erx_erofs:list_dir(Fs, Names)),
    {ok, #{type := directory}} = erx_erofs:read_file_info(Fs, Names),
    ?assertEqual({error, eisdir}, erx_erofs:read_file(Fs, Names)),
    ?assertEqual({error, einval}, erx_erofs:read_link(Fs, Names)),
    ?assertEqual({lists:duplicate(length(Names), directory), ok}, erx_erofs:walk(Fs, Names)).

slice(Bytes, Offset, _) when Offset >= byte_size(Bytes) -> eof;
slice(Bytes, Offset, Length) -> {ok, binary:part(Bytes, Offset, min(Length, byte_size(Bytes) - Offset))}.

walks_end_as_the_resolver_reads_them_test() ->
    Fs = mount("compact"),
    ?assertEqual({[], {error, enoent}}, erx_erofs:walk(Fs, [<<"nope">>])),
    ?assertEqual({[directory], {error, enoent}}, erx_erofs:walk(Fs, [<<"a">>, <<"nope">>])),
    ?assertEqual({[other], {error, enotdir}}, erx_erofs:walk(Fs, [<<"small">>, <<"x">>])),
    ?assertEqual({[directory, directory, link], ok},
                 erx_erofs:walk(Fs, [<<"a">>, <<"b">>, <<"up">>, <<"x">>])),
    ?assertEqual({[], {error, enametoolong}}, erx_erofs:walk(Fs, lists:duplicate(257, <<"a">>))),
    ?assertEqual({[], {error, enametoolong}}, erx_erofs:walk(Fs, [binary:copy(<<"a">>, 256)])),
    ?assertEqual({error, enotdir}, erx_erofs:read_file(Fs, [<<"small">>, <<"x">>])),
    ?assertEqual({error, enoent}, erx_erofs:list_dir(Fs, [<<"many">>, <<"entry-9999">>])),
    ?assertEqual({error, enotdir}, erx_erofs:list_dir(Fs, [<<"small">>])),
    ?assertEqual({error, einval}, erx_erofs:pread(Fs, [<<"small">>], -1, 1)).

%% Refusals at mount, each with its diagnostic.

refused(Bytes) ->
    erx_erofs:mount(window(Bytes), unchecked, fun(_) -> ok end).

compression_is_refused_naming_its_bits_test() ->
    ?assertEqual({error, enotsup, <<"erofs: block 0: incompatible feature bits 0x1 are not implemented">>},
                 refused(fixture("lz4"))).

superblock_test_() ->
    Image = fixture("compact"),
    Patch = fun(At, Byte) -> <<(binary:part(Image, 0, At))/binary, Byte,
                               (binary:part(Image, At + 1, byte_size(Image) - At - 1))/binary>> end,
    [?_assertEqual({error, eio, <<"erofs: block 0: superblock CRC-32C mismatch">>}, refused(Patch(1024 + 64, $x))),
     ?_assertEqual({error, eio, <<"erofs: block 0: superblock CRC-32C mismatch">>}, refused(Patch(4000, 1))),
     ?_assertEqual({error, eio, <<"erofs: block 0: no EROFS magic">>}, refused(Patch(1024, 0))),
     ?_assertEqual({error, enotsup, <<"erofs: block 0: block size 2^14, not 2^12">>}, refused(Patch(1024 + 12, 14))),
     ?_assertEqual({error, eio, <<"erofs: blocks 0+1 failed to read">>}, refused(<<>>))].

%% A block that changes after the mount fails the operation, with a diagnostic, and
%% not its caller.

malformed_blocks_fail_the_operation_test() ->
    Bytes = fixture("compact"),
    Gate = atomics:new(1, []),
    Window = window(Bytes, fun(_, Count, Part) ->
                                      case atomics:get(Gate, 1) of
                                          0 -> {ok, Part};
                                          _ -> {ok, binary:copy(<<255>>, Count * ?BLOCK)}
                                      end
                              end),
    {ok, Fs} = erx_erofs:mount(Window, unchecked, fun(Line) -> self() ! {log, Line} end),
    atomics:put(Gate, 1, 1),
    ?assertEqual({error, eio}, erx_erofs:read_file(Fs, [<<"small">>])),
    <<"erofs: inode 36: unknown format bits 0xFFFF">> = logged(),
    ?assertEqual({[], {error, eio}}, erx_erofs:walk(Fs, [<<"a">>])),
    true = is_binary(logged()).

%% The funnel.

funnel_refuses_what_it_cannot_serve_test() ->
    Bytes = fixture("compact"),
    Blocks = byte_size(Bytes) div ?BLOCK,
    {ok, Image} = open(Bytes),
    {ok, [Block0]} = erx_verity:read(Image, 0, 1),
    ?assertEqual(binary:part(Bytes, 0, ?BLOCK), Block0),
    {ok, All} = erx_verity:read(Image, 0, Blocks),
    ?assertEqual(Bytes, iolist_to_binary(All)),
    {ok, Large} = open(binary:copy(<<0>>, 20 * ?BLOCK)),
    {ok, Sixteen} = erx_verity:read(Large, 4, 16),
    16 = length(Sixteen),
    ?assertEqual({error, eio}, erx_verity:read(Large, 0, 17)),
    ?assertEqual({error, eio}, erx_verity:read(Image, 0, 0)),
    ?assertEqual({error, eio}, erx_verity:read(Image, Blocks, 1)),
    ?assertEqual({error, eio}, erx_verity:read(Image, -1, 1)),
    {ok, Short} = open(Bytes, fun(_, _, Part) -> {ok, binary:part(Part, 0, 100)} end),
    ?assertEqual({error, eio}, erx_verity:read(Short, 0, 1)),
    {ok, Failing} = open(Bytes, fun(_, _, _) -> {error, timeout} end),
    ?assertEqual({error, eio}, erx_verity:read(Failing, 0, 1)),
    {ok, Exiting} = open(Bytes, fun(_, _, _) -> exit(window_down) end),
    ?assertEqual({error, eio}, erx_verity:read(Exiting, 0, 1)),
    ?assertEqual({error, eio}, erx_verity:read(Exiting, 0, 1)).

%% The funnel opens only a window that answers its length, and only unchecked.

funnel_opens_only_a_window_test() ->
    {Gone, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Gone, _} -> ok end,
    ?assertEqual({error, eio}, erx_verity:open(Gone, unchecked)),
    ?assertEqual({error, eio}, erx_verity:open(window(<<>>), {root, <<0:256>>})),
    ?assertEqual({error, eio}, erx_verity:open(not_a_pid, unchecked)),
    Wrong = spawn(fun() -> receive {'$gen_call', From, info} -> gen:reply(From, {ok, #{}}) end end),
    ?assertEqual({error, eio}, erx_verity:open(Wrong, unchecked)),
    ?assertMatch({error, eio, <<"erofs: the window did not answer its length">>},
                 erx_erofs:mount(Gone, unchecked, fun(_) -> ok end)),
    %% A window of 20 blocks and 7 sectors is 20 blocks long.
    {ok, Odd} = open(binary:copy(<<1>>, 20 * ?BLOCK + 7 * ?SECTOR)),
    {ok, _} = erx_verity:read(Odd, 19, 1),
    ?assertEqual({error, eio}, erx_verity:read(Odd, 20, 1)),
    %% The funnel's calls leave nothing in the caller's mailbox.
    ?assertEqual({messages, []}, process_info(self(), messages)).

%% Each block is matched to its request whatever order the window answers in.

funnel_matches_answers_to_requests_test() ->
    Bytes = <<(binary:copy(<<1>>, ?BLOCK))/binary, (binary:copy(<<2>>, ?BLOCK))/binary>>,
    Reversed = spawn(fun() -> reversed(Bytes) end),
    {ok, Image} = erx_verity:open(Reversed, unchecked),
    ?assertEqual({ok, [binary:part(Bytes, 0, ?BLOCK), binary:part(Bytes, ?BLOCK, ?BLOCK)]},
                 erx_verity:read(Image, 0, 2)).

%% A window that answers info, then takes two reads and answers the second first.
reversed(Bytes) ->
    receive {'$gen_call', Info, info} -> gen:reply(Info, {ok, #{sectors => byte_size(Bytes) div ?SECTOR}}) end,
    [{First, S1}, {Second, S2}] = [receive {'$gen_call', From, {read, S, 8}} -> {From, S} end || _ <- [1, 2]],
    gen:reply(Second, {ok, binary:part(Bytes, S2 * ?SECTOR, ?BLOCK)}),
    gen:reply(First, {ok, binary:part(Bytes, S1 * ?SECTOR, ?BLOCK)}).

%% An open file of an image: what file does with it.

open_file_reads_as_stock_test() ->
    Fs = mount("compact"),
    Big = contents(12388, 3),
    {ok, Fd} = erx_erofs_file:open(Fs, [<<"big">>], [read, binary]),
    ?assertEqual({ok, binary:part(Big, 0, 5000)}, file:read(Fd, 5000)),
    ?assertEqual({ok, binary:part(Big, 5000, 7388)}, file:read(Fd, 100000)),
    ?assertEqual(eof, file:read(Fd, 1)),
    ?assertEqual({ok, 12388}, file:position(Fd, eof)),
    ?assertEqual({ok, 12000}, file:position(Fd, {cur, -388})),
    ?assertEqual({ok, binary:part(Big, 12000, 388)}, file:read(Fd, 1000)),
    ?assertEqual({error, einval}, file:position(Fd, {bof, -1})),
    %% Past off_t, as stock OTP answers on the development host: a sum is eoverflow and
    %% an offset that is no off_t badarg, and neither moves the offset.
    ?assertEqual({error, eoverflow}, file:position(Fd, {cur, (1 bsl 63) - 1})),
    ?assertEqual({error, eoverflow}, file:position(Fd, {eof, (1 bsl 63) - 1})),
    ?assertEqual({error, badarg}, file:position(Fd, {bof, 1 bsl 63})),
    ?assertEqual({error, badarg}, file:position(Fd, {cur, -(1 bsl 63) - 1})),
    ?assertEqual({ok, 12388}, file:position(Fd, cur)),
    ?assertEqual({ok, binary:part(Big, 4090, 10)}, file:pread(Fd, 4090, 10)),
    ?assertEqual(eof, file:pread(Fd, 12388, 1)),
    ?assertEqual({error, einval}, file:pread(Fd, -1, 1)),
    ?assertEqual({ok, [binary:part(Big, 0, 2), eof]}, file:pread(Fd, [{0, 2}, {20000, 2}])),
    {ok, #file_info{type = regular, size = 12388, access = read}} = file:read_file_info(Fd, [{time, posix}]),
    ?assertEqual({error, ebadf}, file:write(Fd, <<"x">>)),
    ?assertEqual({error, ebadf}, file:pwrite(Fd, 0, <<"x">>)),
    ?assertEqual({error, einval}, file:truncate(Fd)),
    ?assertEqual({ok, binary:part(Big, 0, 2)}, file:pread(Fd, 0, 2)),
    Self = self(),
    spawn(fun() -> Self ! {other, try file:read(Fd, 1) catch error:Reason -> Reason end} end),
    receive {other, Other} -> ?assertEqual(not_on_controlling_process, Other) end,
    ?assertEqual(ok, file:close(Fd)),
    ?assertEqual({error, einval}, file:close(Fd)),
    ?assertEqual({error, einval}, file:read(Fd, 1)).

open_file_reads_lines_test() ->
    Fs = mount("compact"),
    %% The file holds a "\n" every 256 bytes, so its lines cross blocks and reads.
    {ok, Fd} = erx_erofs_file:open(Fs, [<<"big">>], [read]),
    Big = contents(12388, 3),
    Read = read_lines(Fd, []),
    ?assertEqual(Big, iolist_to_binary(Read)),
    Breaks = length(binary:matches(Big, <<"\n">>)),
    ?assertEqual(Breaks + 1, length(Read)),
    ?assertEqual(eof, file:read_line(Fd)),
    ok = file:close(Fd).

read_lines(Fd, Lines) ->
    case file:read_line(Fd) of
        {ok, Line} -> read_lines(Fd, [Line | Lines]);
        eof -> lists:reverse(Lines)
    end.

open_file_refusals_test() ->
    Fs = mount("compact"),
    ?assertEqual({error, eisdir}, erx_erofs_file:open(Fs, [<<"a">>], [read])),
    ?assertEqual({error, enotsup}, erx_erofs_file:open(Fs, [<<"a">>], [read, directory])),
    ?assertEqual({error, enotdir}, erx_erofs_file:open(Fs, [<<"small">>], [read, directory])),
    ?assertEqual({error, enoent}, erx_erofs_file:open(Fs, [<<"nope">>], [read])),
    ?assertEqual({error, enotdir}, erx_erofs_file:open(Fs, [<<"small">>, <<"x">>], [read])),
    #file_info{type = symlink, access = undefined} = erx_erofs:file_info(Fs, [<<"to-small">>]),
    #file_info{type = directory, access = read, mode = Mode} = erx_erofs:file_info(Fs, [<<"a">>]),
    ?assertEqual(8#040000, Mode band 8#170000).

%% The hash check ------------------------------------------------------------------

%% The funnel over a layout, on images and trees the packer's writer,
%% Erx::AppPackage#verity_tree, made (test/host/erx_erofs_test.rb writes them into the
%% directory ERX_VERITY_CASES names): "levels", 200 distinct blocks under a tree of a
%% one-block top and a two-block lowest level, with a block of 0xFF between the image and
%% the tree; "one", one block and no tree, its block's hash the root; and "erofs", the
%% compact fixture image. Every block must read as the image holds it, and any changed
%% byte of a block, of a tree block on its path or of the root answer eio. "deep", a tree
%% of three levels, is read in parts below.

verity_case(Name) ->
    Dir = os:getenv("ERX_VERITY_CASES"),
    {ok, Cases} = file:consult(filename:join(Dir, "verity.terms")),
    {Name, Layout} = lists:keyfind(Name, 1, Cases),
    {ok, Bytes} = file:read_file(filename:join(Dir, Name ++ ".img")),
    {Bytes, Layout}.

%% Every block of the image Layout places in Bytes, read 16 at a time, joined.
read_image(Bytes, Layout) ->
    case erx_verity:open(window(Bytes), Layout) of
        {ok, Image} -> read_blocks(Image, 0, maps:get(image_length, Layout) div ?BLOCK, []);
        {error, eio} -> {error, eio}
    end.

read_blocks(_Image, Block, Blocks, Read) when Block >= Blocks ->
    {ok, iolist_to_binary(lists:reverse(Read))};
read_blocks(Image, Block, Blocks, Read) ->
    case erx_verity:read(Image, Block, min(?ERX_VERITY_READ_BLOCKS_MAX, Blocks - Block)) of
        {ok, Got} -> read_blocks(Image, Block + length(Got), Blocks, [Got | Read]);
        {error, eio} -> {error, eio}
    end.

read_one(Bytes, Layout, Block) ->
    {ok, Image} = erx_verity:open(window(Bytes), Layout),
    erx_verity:read(Image, Block, 1).

flip_byte(Bytes, Offset) ->
    <<Before:Offset/binary, Byte, After/binary>> = Bytes,
    <<Before/binary, (Byte bxor 16#10), After/binary>>.

verity_good_image_reads_test_() ->
    [{Name, fun() ->
                    {Bytes, #{image_length := Length} = Layout} = verity_case(Name),
                    ?assertEqual({ok, binary:part(Bytes, 0, Length)}, read_image(Bytes, Layout))
            end} || Name <- ["levels", "one", "erofs"]].

verity_flipped_data_block_test() ->
    {Bytes, Layout} = verity_case("levels"),
    Flipped = flip_byte(Bytes, 150 * ?BLOCK + 5),
    ?assertEqual({error, eio}, read_one(Flipped, Layout, 150)),
    ?assertMatch({ok, [_]}, read_one(Flipped, Layout, 149)),
    ?assertEqual({error, eio}, read_image(Flipped, Layout)),
    {One, OneLayout} = verity_case("one"),
    ?assertEqual({error, eio}, read_one(flip_byte(One, 4095), OneLayout, 0)).

%% The tree lies top first: the top block, then the lowest level's two blocks, the second
%% holding the hashes of blocks 128 to 199.
verity_flipped_tree_block_test() ->
    {Bytes, #{tree_offset := Tree} = Layout} = verity_case("levels"),
    Lowest = flip_byte(Bytes, Tree + 2 * ?BLOCK + 7),
    ?assertEqual({error, eio}, read_one(Lowest, Layout, 150)),
    ?assertMatch({ok, [_]}, read_one(Lowest, Layout, 127)),
    Top = flip_byte(Bytes, Tree + 4095),
    ?assertEqual({error, eio}, read_one(Top, Layout, 0)),
    %% A byte of the gap before the tree is no block of the image or the tree.
    ?assertMatch({ok, _}, read_image(flip_byte(Bytes, Tree - 1), Layout)).

verity_wrong_root_test_() ->
    [{Name, fun() ->
                    {Bytes, #{root_hash := <<First, Rest/binary>>} = Layout} = verity_case(Name),
                    Wrong = Layout#{root_hash := <<(First bxor 1), Rest/binary>>},
                    ?assertEqual({error, eio}, read_image(Bytes, Wrong))
            end} || Name <- ["levels", "one", "erofs"]].

%% A read stops at the image's last block, though the window holds the tree past it.
verity_reads_stop_at_the_image_test() ->
    {Bytes, Layout} = verity_case("levels"),
    {ok, Image} = erx_verity:open(window(Bytes), Layout),
    ?assertMatch({ok, [_]}, erx_verity:read(Image, 199, 1)),
    ?assertEqual({error, eio}, erx_verity:read(Image, 200, 1)),
    ?assertEqual({error, eio}, erx_verity:read(Image, 199, 2)).

%% A layout whose tree is not where and as long as erx_verity_tree places it, or that
%% does not fit the window, is refused at open.
verity_refused_layouts_test_() ->
    {Bytes, #{image_length := Length, tree_offset := Tree, tree_length := TreeLength} = Layout} =
        verity_case("levels"),
    Refused = [Layout#{tree_length := TreeLength - ?BLOCK},
               Layout#{tree_length := TreeLength + ?BLOCK},
               Layout#{tree_offset := Tree + ?BLOCK},
               Layout#{tree_offset := Tree + ?SECTOR},
               Layout#{tree_offset := Length - ?BLOCK},
               Layout#{image_length := Length - 1},
               Layout#{image_length := 0},
               Layout#{salt := not_a_binary},
               Layout#{root_hash := <<0:248>>},
               maps:remove(salt, Layout),
               Layout#{image_offset => 0}],
    [?_assertEqual({error, eio}, erx_verity:open(window(Bytes), Bad)) || Bad <- Refused].

%% The reader over a checked image serves the tree as over the image unchecked.
verity_checked_mount_test() ->
    {Bytes, Layout} = verity_case("erofs"),
    {ok, Fs} = erx_erofs:mount(window(Bytes), Layout, fun(Line) -> self() ! {log, Line} end),
    agrees(Fs, owner("compact")).

%% A read whose blocks' hashes lie in both blocks of the lowest level checks each block
%% against its own parent.
verity_read_across_two_tree_blocks_test() ->
    {Bytes, Layout} = verity_case("levels"),
    {ok, Image} = erx_verity:open(window(Bytes), Layout),
    {ok, Got} = erx_verity:read(Image, 120, 16),
    ?assertEqual(binary:part(Bytes, 120 * ?BLOCK, 16 * ?BLOCK), iolist_to_binary(Got)).

%% "deep": 16700 blocks under a tree of three levels, which lie top first: the top at the
%% tree's block 0, the middle level at 1 and 2, the second holding the hashes of the
%% lowest level's blocks 128 to 130, and the lowest level at 3 to 133. Only the tree is
%% stored; the window makes image block I as the writer did, numbered(I).
-define(DEEP_BLOCKS, 16700).

numbered(Block) -> binary:copy(<<Block:32>>, ?BLOCK div 4).

numbered(First, Count) -> {ok, [numbered(Block) || Block <- lists:seq(First, First + Count - 1)]}.

%% A window over the image Data makes, Data(Block) for each block, with Tree after it.
deep_window(Tree, Data) -> spawn(fun() -> deep_serve(Tree, Data) end).

deep_serve(Tree, Data) ->
    receive
        {'$gen_call', From, info} ->
            gen:reply(From, {ok, #{role => system, sectors => (?DEEP_BLOCKS * ?BLOCK + byte_size(Tree)) div ?SECTOR}});
        {'$gen_call', From, {read, Sector, 8}} when Sector rem 8 =:= 0, Sector div 8 < ?DEEP_BLOCKS ->
            gen:reply(From, {ok, Data(Sector div 8)});
        {'$gen_call', From, {read, Sector, 8}} when Sector rem 8 =:= 0 ->
            gen:reply(From, {ok, binary:part(Tree, (Sector div 8 - ?DEEP_BLOCKS) * ?BLOCK, ?BLOCK)})
    after ?WINDOW_IDLE ->
        exit(idle)
    end,
    deep_serve(Tree, Data).

deep_read(Tree, Data, Block, Count) ->
    {_, Layout} = verity_case("deep"),
    {ok, Image} = erx_verity:open(deep_window(Tree, Data), Layout),
    erx_verity:read(Image, Block, Count).

%% Reads at the start, across a block boundary of both lower levels (data blocks 16376 to
%% 16391 hash into the lowest level's blocks 127 and 128, whose hashes lie in the middle
%% level's blocks 0 and 1) and at the end.
verity_three_levels_read_test_() ->
    {Tree, _} = verity_case("deep"),
    [?_assertEqual(numbered(Block, Count), deep_read(Tree, fun numbered/1, Block, Count))
     || {Block, Count} <- [{0, 16}, {16376, 16}, {16684, 16}, {16699, 1}]].

%% A changed byte on block 16600's path, at each level, answers eio for it. Block 16600 is
%% slot 88 of the lowest level's block 129, which is slot 1 of the middle level's block 1,
%% slot 1 of the top. Block 0's path shares only the top block, so it still reads unless
%% the top changed, which no longer matches the root.
verity_three_levels_flipped_test_() ->
    {Tree, _} = verity_case("deep"),
    Data = fun(16600) -> flip_byte(numbered(16600), 9); (Block) -> numbered(Block) end,
    Cases = [{"data", Tree, Data, numbered(0, 1)},
             {"lowest", flip_byte(Tree, (3 + 129) * ?BLOCK + 88 * 32 + 5), fun numbered/1, numbered(0, 1)},
             {"middle", flip_byte(Tree, 2 * ?BLOCK + 32 + 5), fun numbered/1, numbered(0, 1)},
             %% Off the read's slot: the middle block's hash of the lowest level's block 130.
             {"middle block", flip_byte(Tree, 2 * ?BLOCK + 2 * 32 + 5), fun numbered/1, numbered(0, 1)},
             {"top", flip_byte(Tree, 32 + 5), fun numbered/1, {error, eio}}],
    [{Name, fun() ->
                    ?assertEqual({error, eio}, deep_read(Flipped, Serve, 16600, 1)),
                    ?assertEqual(First, deep_read(Flipped, Serve, 0, 1))
            end} || {Name, Flipped, Serve, First} <- Cases].
