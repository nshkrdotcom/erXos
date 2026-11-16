%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_listing_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Over OTP's file module

%% A tree on the host: a directory a with a file x and its hard link y, an
%% empty directory b inside it, an empty file e, and a symlink s to a/x.
host_tree() ->
    Root = filename:absname("listing-tree-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Root),
    ok = file:make_dir(filename:join(Root, "a")),
    ok = file:make_dir(filename:join([Root, "a", "b"])),
    ok = file:write_file(filename:join([Root, "a", "x"]), <<"hello">>),
    ok = file:change_mode(filename:join([Root, "a", "x"]), 8#640),
    ok = file:make_link(filename:join([Root, "a", "x"]), filename:join([Root, "a", "y"])),
    ok = file:write_file(filename:join(Root, "e"), <<>>),
    ok = file:make_symlink("a/x", filename:join(Root, "s")),
    Root.

a_host_tree_lists_every_name_in_path_order_test() ->
    Listing = erx_f2fs_listing:of_tree(erx_f2fs_listing:file_reader(host_tree())),
    ?assertEqual([[], [<<"a">>], [<<"a">>, <<"b">>], [<<"a">>, <<"x">>],
                  [<<"a">>, <<"y">>], [<<"e">>], [<<"s">>]],
                 [Path || {Path, _} <- Listing]).

each_kind_has_its_attributes_test() ->
    Entries = maps:from_list(erx_f2fs_listing:of_tree(erx_f2fs_listing:file_reader(host_tree()))),
    X = [<<"a">>, <<"x">>],
    Hello = crypto:hash(sha256, <<"hello">>),
    ?assertEqual(#{kind => regular, mode => 8#640, links => 2, size => 5,
                   link_class => [X, [<<"a">>, <<"y">>]], sha256 => Hello},
                 maps:get(X, Entries)),
    ?assertEqual(maps:get(X, Entries), maps:get([<<"a">>, <<"y">>], Entries)),
    ?assertMatch(#{kind := symlink, target := <<"a/x">>, links := 1, size := 3,
                   link_class := [[<<"s">>]]},
                 maps:get([<<"s">>], Entries)),
    ?assertMatch(#{kind := directory}, maps:get([<<"a">>, <<"b">>], Entries)),
    ?assertNot(is_map_key(link_class, maps:get([<<"a">>], Entries))).

the_second_depth_adds_the_owner_and_the_times_test() ->
    Reader = erx_f2fs_listing:file_reader(host_tree()),
    [{[], Shallow} | _] = erx_f2fs_listing:of_tree(Reader),
    [{[], Deep} | _] = erx_f2fs_listing:of_tree(Reader, 2),
    ?assertEqual([], [Key || Key <- [uid, gid, atime, mtime, ctime], is_map_key(Key, Shallow)]),
    ?assertEqual(Shallow, maps:without([uid, gid, atime, mtime, ctime], Deep)),
    ?assertMatch(#{uid := Uid, mtime := Mtime} when is_integer(Uid) andalso is_integer(Mtime),
                 Deep).

%%% Over a reader of a tree held as a map

%% A reader of Tree, a map from each path to {Stat, Contents}: a
%% directory's names, a file's bytes or a symlink's target; or to
%% {error, Reason} for a name the reader cannot state.
map_reader(Tree) ->
    Contents = fun(Path) ->
                       case maps:get(Path, Tree) of
                           {error, _} = Error -> Error;
                           {_Stat, Value} -> {ok, Value}
                       end
               end,
    Fold = fun(Path, Fun, Acc) ->
                   case Contents(Path) of
                       {ok, Bytes} -> {ok, Fun(Bytes, Acc)};
                       {error, _} = Error -> Error
                   end
           end,
    #{list => Contents, fold => Fold, read_link => Contents,
      stat => fun(Path) ->
                      case maps:get(Path, Tree) of
                          {error, _} = Error -> Error;
                          {Stat, _Value} -> {ok, Stat}
                      end
              end}.

stat(Kind, Inode) ->
    #{kind => Kind, mode => 8#755, links => 1, inode => Inode, size => 0,
      uid => 0, gid => 0, atime => 0, mtime => 0, ctime => 0}.

%% A directory reached again by its inode is an error and the walk ends.
a_directory_reached_twice_ends_the_walk_test() ->
    Tree = #{[] => {stat(directory, 1), [<<"loop">>]},
             [<<"loop">>] => {stat(directory, 1), [<<"loop">>]}},
    ?assertMatch([{[], #{kind := directory}}, {[<<"loop">>], {error, directory_reached_twice}}],
                 erx_f2fs_listing:of_tree(map_reader(Tree))).

%% An entry the reader refuses is its error, and nothing beneath it is
%% listed; a file whose bytes fail is its error too.
a_refused_entry_hides_what_lies_beneath_test() ->
    Tree = #{[] => {stat(directory, 1), [<<"bad">>, <<"file">>]},
             [<<"bad">>] => {error, {inode, checksum}},
             [<<"file">>] => {error, eio}},
    ?assertEqual([{[], #{kind => directory, mode => 8#755, links => 1, size => 0}},
                  {[<<"bad">>], {error, {inode, checksum}}},
                  {[<<"file">>], {error, eio}}],
                 erx_f2fs_listing:of_tree(map_reader(Tree))).

%% Devices list their numbers; names sharing an inode share the class of
%% every name found sharing it, in path order, whatever order the reader
%% lists them in.
devices_and_link_classes_test() ->
    Device = (stat(character, 7))#{device => {1, 3}},
    Tree = #{[] => {stat(directory, 1), [<<"z">>, <<"m">>, <<"null">>]},
             [<<"z">>] => {stat(fifo, 5), none},
             [<<"m">>] => {stat(fifo, 5), none},
             [<<"null">>] => {Device, none}},
    Listing = erx_f2fs_listing:of_tree(map_reader(Tree)),
    ?assertMatch({_, #{kind := character, device := {1, 3}, link_class := [[<<"null">>]]}},
                 lists:keyfind([<<"null">>], 1, Listing)),
    ?assertEqual([[[<<"m">>], [<<"z">>]], [[<<"m">>], [<<"z">>]]],
                 [Class || {[Name], #{link_class := Class}} <- Listing,
                           Name =:= <<"m">> orelse Name =:= <<"z">>]).

diff_names_each_entry_that_differs_test() ->
    Left = [{[], #{kind => directory}}, {[<<"a">>], #{size => 1}}, {[<<"b">>], #{size => 2}}],
    Right = [{[], #{kind => directory}}, {[<<"a">>], #{size => 3}}, {[<<"c">>], #{size => 2}}],
    ?assertEqual([{[<<"a">>], #{size => 1}, #{size => 3}},
                  {[<<"b">>], #{size => 2}, absent},
                  {[<<"c">>], absent, #{size => 2}}],
                 erx_f2fs_listing:diff(Left, Right)).

%% A name OTP answers as a string comes back as its bytes in the file name
%% encoding; the name here is UTF-8 and in NFC, which macOS keeps.
a_non_ascii_name_lists_as_its_bytes_test() ->
    Root = host_tree(),
    Name = <<16#c3, 16#a9>>,
    ok = file:write_file(filename:join(Root, Name), <<>>),
    Listing = erx_f2fs_listing:of_tree(erx_f2fs_listing:file_reader(Root)),
    ?assertMatch({_, #{kind := regular}}, lists:keyfind([Name], 1, Listing)).

%% The host's /dev/null decodes to the major and minor the test runner read
%% with Ruby's File::Stat, the host's own major() and minor().
a_host_device_decodes_to_major_and_minor_test() ->
    [Major, Minor] = [list_to_integer(Field) || Field <- string:lexemes(os:getenv("ERX_F2FS_DEV_NULL"), " ")],
    #{stat := Stat} = erx_f2fs_listing:file_reader("/dev"),
    ?assertMatch({ok, #{kind := character, device := {Major, Minor}}}, Stat([<<"null">>])).

%% A file's bytes are hashed chunk by chunk: 256 MiB folded in fresh 1 MiB
%% chunks lists in a process whose memory, shared binaries included, is
%% capped at 4 Mi words (32 MiB on a 64-bit emulator).
a_large_file_hashes_in_bounded_memory_test() ->
    Chunk = binary:copy(<<16#5a>>, 1 bsl 20),
    Chunks = 256,
    Tree = #{[] => {stat(directory, 1), [<<"big">>]},
             [<<"big">>] => {(stat(regular, 2))#{size => Chunks bsl 20}, unused}},
    Fold = fun([<<"big">>], Fun, Acc) ->
                   {ok, lists:foldl(fun(_, A) -> Fun(binary:copy(Chunk), A) end, Acc,
                                    lists:seq(1, Chunks))}
           end,
    Reader = (map_reader(Tree))#{fold := Fold},
    Expected = crypto:hash_final(lists:foldl(fun(_, S) -> crypto:hash_update(S, Chunk) end,
                                             crypto:hash_init(sha256), lists:seq(1, Chunks))),
    Self = self(),
    {Pid, Ref} = spawn_opt(fun() -> Self ! {listed, erx_f2fs_listing:of_tree(Reader)} end,
                           [monitor, {max_heap_size, #{size => 4 bsl 20, kill => true,
                                                       error_logger => false,
                                                       include_shared_binaries => true}}]),
    receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason) end,
    receive {listed, Listing} ->
            ?assertMatch({_, #{sha256 := Expected}}, lists:keyfind([<<"big">>], 1, Listing))
    end.

%% The walk goes in path order whatever order a directory lists in, so the
%% later of two paths reaching one directory is the one in error.
the_later_path_to_a_directory_is_reached_twice_test() ->
    Shared = {stat(directory, 2), []},
    Listings = [erx_f2fs_listing:of_tree(map_reader(#{[] => {stat(directory, 1), Names},
                                                       [<<"a">>] => Shared,
                                                       [<<"b">>] => Shared}))
                || Names <- [[<<"a">>, <<"b">>], [<<"b">>, <<"a">>]]],
    ?assertMatch([[{[], _}, {[<<"a">>], #{kind := directory}},
                   {[<<"b">>], {error, directory_reached_twice}}] = Same, Same],
                 Listings).

%% A name a directory lists twice is one entry, duplicate_name, and nothing
%% beneath it is read.
a_name_listed_twice_is_a_duplicate_test() ->
    Tree = #{[] => {stat(directory, 1), [<<"x">>, <<"y">>, <<"x">>]},
             [<<"y">>] => {stat(fifo, 3), none}},
    ?assertMatch([{[], _}, {[<<"x">>], {error, duplicate_name}}, {[<<"y">>], #{kind := fifo}}],
                 erx_f2fs_listing:of_tree(map_reader(Tree))).

%% A name no path can hold is refused before any reader is asked about it:
%% the map reader has no entry for these paths and would fail if asked.
names_no_path_can_hold_are_refused_test() ->
    Bad = [<<>>, <<".">>, <<"..">>, <<"a/b">>, <<"..", "/", "etc">>, <<"n", 0>>],
    Listing = erx_f2fs_listing:of_tree(map_reader(#{[] => {stat(directory, 1), Bad}})),
    ?assertEqual(lists:sort([{[Name], {error, bad_name}} || Name <- Bad]), tl(Listing)).

%% A reader that states no owner or times lists the same at both depths.
owner_and_times_are_optional_test() ->
    Stat = maps:without([uid, gid, atime, mtime, ctime], stat(directory, 1)),
    Reader = map_reader(#{[] => {Stat, []}}),
    ?assertEqual(erx_f2fs_listing:of_tree(Reader), erx_f2fs_listing:of_tree(Reader, 2)).

%% A path one listing holds twice is reported, never hidden by the other.
diff_reports_a_repeated_path_test() ->
    Entry = {[<<"a">>], #{size => 1}},
    ?assertEqual([{[<<"a">>], #{size => 1}, absent}],
                 erx_f2fs_listing:diff([Entry, Entry], [Entry])).

%% A link class is compared over the names both sides state without an
%% error: the entry in error differs, the class of its sibling does not.
diff_cuts_link_classes_to_names_without_errors_test() ->
    X = [<<"x">>],
    Y = [<<"y">>],
    Left = [{X, #{kind => regular, link_class => [X, Y]}},
            {Y, #{kind => regular, link_class => [X, Y]}}],
    Right = [{X, #{kind => regular, link_class => [X]}}, {Y, {error, {inode, checksum}}}],
    ?assertEqual([{Y, #{kind => regular, link_class => [X]}, {error, {inode, checksum}}}],
                 erx_f2fs_listing:diff(Left, Right)).

%% The reader over OTP's file module folds a file in chunks too: a sparse
%% host file of 256 MiB lists under the same cap.
a_sparse_host_file_lists_in_bounded_memory_test() ->
    Root = host_tree(),
    {ok, File} = file:open(filename:join(Root, "sparse"), [write, raw, binary]),
    {ok, _} = file:position(File, 256 bsl 20),
    ok = file:write(File, <<1>>),
    ok = file:close(File),
    Reader = erx_f2fs_listing:file_reader(Root),
    Self = self(),
    {Pid, Ref} = spawn_opt(fun() -> Self ! {listed, erx_f2fs_listing:of_tree(Reader)} end,
                           [monitor, {max_heap_size, #{size => 4 bsl 20, kill => true,
                                                       error_logger => false,
                                                       include_shared_binaries => true}}]),
    receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason) end,
    receive {listed, Listing} ->
            ?assertMatch({_, #{size := 268435457}}, lists:keyfind([<<"sparse">>], 1, Listing))
    end.
