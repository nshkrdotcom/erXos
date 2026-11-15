%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% EUnit cases of erx_desk_files_core, the core of files
%% (docs/design-desktop-programs.md, "files" and "Verification and testing"):
%% kinds and sorting, acting by index (D4), paging, the text test and the
%% preview, and valid trees whatever the input (D5). The core is driven as the
%% window process drives it: each effect is answered by a model of the worker
%% that would perform it, and each tree is read back from view/1.
-module(erx_desk_files_core_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(DIR, <<"/data/logs">>).
-define(READ_MAX, 16384).
%% The node quota erx_ui_server validates a tree under (erx_ui_server.erl, UI_NODES).
-define(UI_NODES, 10000).

%%% Fixtures

file(Size) -> #file_info{type = regular, mode = 8#100644, size = Size, mtime = 1794647520}.
folder() -> #file_info{type = directory, mode = 8#40755, size = 0, mtime = 1794647520}.
link() -> #file_info{type = symlink, mode = 8#120777, size = 4, mtime = 1794647520}.

%% A window opened on Dir whose listing holds Names, each name's
%% information InfoOf(Name), with the effects of the last step.
opened(Dir, Names, InfoOf) ->
    {S0, E0} = erx_desk_files_core:init(#{dir => Dir, snarf => true}),
    [{list, Tag, Dir} | _] = [E || {list, _, _} = E <- E0],
    {S1, E1} = erx_desk_files_core:step({listed, Tag, {ok, Names}}, S0),
    stated(InfoOf, S1, E1).

%% Answers the step's stat effect of the current folder, if it has one.
stated(InfoOf, S, Effects) ->
    case [E || {stat, _, Dir, _} = E <- Effects, Dir =/= <<"/">>] of
        [{stat, Tag, _Dir, Asked}] -> erx_desk_files_core:step({stated, Tag, [stat(InfoOf(N)) || N <- Asked]}, S);
        [] -> {S, Effects}
    end.

files(_Name) -> file(100).

%% A name's information as file:read_link_info/2 answers it.
stat(#file_info{} = Info) -> {ok, Info};
stat({error, _} = Refused) -> Refused.

ui(Event, Detail, S) -> erx_desk_files_core:step({ui, window, Event, Detail}, S).

%% Selects or opens the item at Index of the list shown, as the toolkit
%% reports it: the list's own event term, which names its listing.
choose(select, Index, S) -> ui({select, key(S)}, {change, Index}, S);
choose(open, Index, S) -> ui({open, key(S)}, {submit, Index}, S).

key(S) ->
    [#{key := Key}] = props(list, erx_desk_files_core:view(S)),
    Key.

%% The one effect of Effects that is a Kind.
effect(Kind, Effects) ->
    [E] = [E || E <- Effects, element(1, E) =:= Kind],
    E.

%% The properties of every node of Kind in Tree, in depth-first order.
props(Kind, {Kind, Props, Children}) -> [Props | lists:flatmap(fun(C) -> props(Kind, C) end, Children)];
props(Kind, {_Other, _Props, Children}) -> lists:flatmap(fun(C) -> props(Kind, C) end, Children).

items(S) ->
    [#{items := Items}] = props(list, erx_desk_files_core:view(S)),
    Items.

texts(Kind, S) -> [maps:get(text, P) || P <- props(Kind, erx_desk_files_core:view(S))].

%% Opens the item at Index and answers its read with the first bytes of
%% Contents the read asks for, as the read worker would.
read(Index, Contents, S) ->
    {S1, Effects} = choose(open, Index, S),
    {read, Tag, Path, Bytes} = effect(read, Effects),
    Read = binary:part(Contents, 0, min(Bytes, byte_size(Contents))),
    {S2, []} = erx_desk_files_core:step({read, Tag, {ok, Read}}, S1),
    {Path, Bytes, S2}.

%%% Kinds and sorting

kinds_test() ->
    Proc = <<"/proc/1">>,
    Corpus = [{?DIR, <<"archive">>, folder(), folder},
              {?DIR, <<"archive.app">>, folder(), folder},
              {?DIR, <<"latest">>, link(), link},
              {?DIR, <<"notes.txt">>, link(), link},
              {?DIR, <<"run">>, (file(10))#file_info{mode = 8#100755}, program},
              {?DIR, <<"run.txt">>, (file(10))#file_info{mode = 8#100700}, program},
              {?DIR, <<"run.sh">>, (file(10))#file_info{mode = 8#100001}, program},
              {?DIR, <<"dashboard.app">>, file(10), package},
              {?DIR, <<"logo.png">>, file(10), picture},
              {?DIR, <<"boot.log">>, file(10), text},
              {?DIR, <<"main.c">>, file(10), text},
              {?DIR, <<"erx.h">>, file(10), text},
              {?DIR, <<"rc.conf">>, file(10), text},
              {?DIR, <<"README.md">>, file(10), text},
              {?DIR, <<".png">>, file(10), document},
              {?DIR, <<"core.bin">>, file(10), document},
              {?DIR, <<"boot.LOG">>, file(10), document},
              {?DIR, <<"boot.log">>, loading, text},
              {?DIR, <<"secret">>, {error, eacces}, document},
              {<<"/proc">>, <<"machine">>, file(10), system},
              {Proc, <<"status">>, file(10), system},
              {Proc, <<"trace.log">>, file(10), text},
              {Proc, <<"stack">>, folder(), folder},
              {<<"/procs">>, <<"a">>, file(10), document}],
    [?assertEqual({Dir, Name, Kind}, {Dir, Name, erx_desk_files_core:kind(Dir, Name, Info)})
     || {Dir, Name, Info, Kind} <- Corpus].

sorted_byte_for_byte_test() ->
    Names = [<<"b">>, <<"B">>, <<"a">>, <<"Z">>, <<16#E9/utf8>>, <<".hidden">>, <<"_x">>, <<"10">>, <<"9">>],
    {S, _} = opened(?DIR, Names, fun files/1),
    ?assertEqual([<<"10">>, <<"9">>, <<"B">>, <<"Z">>, <<"_x">>, <<"a">>, <<"b">>, <<16#E9/utf8>>], items(S)),
    Shown = toggled(true, S),
    ?assertEqual(<<".hidden">>, hd(items(Shown))),
    ?assertEqual(items(S), items(toggled(false, Shown))).

%% The window after the hidden-names toggle is set to Checked.
toggled(Checked, S) ->
    {S1, Effects} = ui(hidden, {change, Checked}, S),
    element(1, stated(fun files/1, S1, Effects)).

names_that_name_no_entry_are_left_out_test() ->
    {S0, _} = opened(?DIR, [<<"a">>], fun files/1),
    ?assertEqual([<<"a">>], items(toggled(true, S0))),
    {S2, _} = opened(?DIR, [<<>>, <<".">>, <<"..">>, <<"a/b">>, <<"c", 0, "d">>, <<"e">>], fun files/1),
    ?assertEqual([<<"e">>], items(toggled(true, S2))).

an_empty_folder_shows_no_items_test() ->
    {S, _} = opened(?DIR, [<<".hidden">>], fun files/1),
    ?assertEqual([], items(S)),
    ?assert(lists:member(<<"0 items">>, texts(label, S))),
    ?assertNot(lists:member(<<"Loading">>, texts(label, S))).

%%% D4: every action reaches the item the person chose

%% Names that show alike: an override and the eight characters of its
%% token, and two names longer than a list item that differ only in the
%% middle the cut replaces.
alike() ->
    Long = fun(Middle) -> <<(binary:copy(<<"x">>, 70))/binary, Middle, (binary:copy(<<"y">>, 70))/binary>> end,
    [<<"a", 16#202E/utf8, "b">>, <<"a<U+202E>b">>, Long($1), Long($2)].

names_that_show_alike_open_their_own_files_test() ->
    [Override, Token | _Long] = alike(),
    %% The premises: the line escape shows the override as its token, and
    %% the cut leaves the two long names one shown text.
    ?assertEqual(erx_text:escape_line(Override), erx_text:escape_line(Token)),
    {S, _} = opened(?DIR, alike(), fun files/1),
    Items = items(S),
    ?assertEqual(4, length(Items)),
    ?assertEqual(1, length(lists:usort([erx_text:escape_line(I) || I <- lists:sublist(Items, 2)]))),
    ?assertEqual(1, length(lists:usort(lists:nthtail(2, Items)))),
    Sorted = lists:sort(alike()),
    [?assertEqual({Index, <<?DIR/binary, "/", Name/binary>>},
                  {Index, element(3, effect(read, element(2, choose(open, Index, S))))})
     || {Index, Name} <- lists:enumerate(0, Sorted)],
    %% Copy path hands the raw name's bytes too.
    {Selected, _} = choose(select, 1, S),
    ?assertEqual({snarf, <<?DIR/binary, "/", (lists:nth(2, Sorted))/binary>>},
                 effect(snarf, element(2, ui(copy_path, click, Selected)))).

%% A renderer's event on the list of a listing a refresh replaced is
%% dropped by the widget server's model, since the list's key names the
%% listing's generation.
an_event_on_a_replaced_listing_is_dropped_test() ->
    {S1, _} = opened(?DIR, [<<"a">>, <<"b">>], fun files/1),
    {R1, Next} = erx_ui_model:pair(erx_ui_model:empty(), erx_desk_files_core:view(S1), 1),
    [Old] = list_nodes(R1),
    ?assertMatch({fire, {select, _}, {change, 1}, _}, erx_ui_model:hit(R1, Old, on_change, 1)),
    {S2, E2} = ui(refresh, click, S1),
    {list, Tag, ?DIR} = effect(list, E2),
    {S3, E3} = erx_desk_files_core:step({listed, Tag, {ok, [<<"c">>, <<"d">>]}}, S2),
    {S4, _} = stated(fun files/1, S3, E3),
    {R2, _} = erx_ui_model:pair(R1, erx_desk_files_core:view(S4), Next),
    ?assertEqual(drop, erx_ui_model:hit(R2, Old, on_change, 1)),
    [New] = list_nodes(R2),
    ?assertMatch({fire, {select, _}, {change, 1}, _}, erx_ui_model:hit(R2, New, on_change, 1)).

%% An event the widget server fired on the old list before the window took
%% in the new listing reaches the core, which drops it: after a refresh,
%% after the hidden toggle and after a turned page.
an_event_chosen_in_a_replaced_listing_is_dropped_by_the_core_test() ->
    {S1, _} = opened(?DIR, numbered(300), fun files/1),
    Stale = fun(S) -> [ui({Event, key(S1)}, {Detail, 1}, S) || {Event, Detail} <- [{select, change}, {open, submit}]] end,
    {Refreshed, _} = ui(refresh, click, S1),
    ?assertEqual([{Refreshed, []}, {Refreshed, []}], Stale(Refreshed)),
    Toggled = toggled(true, S1),
    ?assertEqual([{Toggled, []}, {Toggled, []}], Stale(Toggled)),
    {Turned, E} = ui({page, 1}, click, S1),
    {Paged, _} = stated(fun files/1, Turned, E),
    ?assertEqual([{Paged, []}, {Paged, []}], Stale(Paged)).

%% The numbers of a realised tree's lists: the nodes that take a list's
%% index as their on_change state.
list_nodes(Realised) ->
    [N || N <- lists:sort(maps:keys(Realised)), N =/= 0,
          case erx_ui_model:hit(Realised, N, on_change, 0) of
              {fire, _Term, _Detail, _Realised} -> true;
              _KeptOrDropped -> false
          end].

%%% Paging

numbered(Count) -> [iolist_to_binary(io_lib:format("n~4..0b", [I])) || I <- lists:seq(0, Count - 1)].

a_large_folder_pages_by_256_test() ->
    Names = numbered(1204),
    {S0, E0} = erx_desk_files_core:init(#{dir => ?DIR, snarf => false}),
    [{list, Tag, ?DIR} | _] = [E || {list, _, _} = E <- E0],
    {S1, E1} = erx_desk_files_core:step({listed, Tag, {ok, lists:reverse(Names)}}, S0),
    {stat, _, ?DIR, First} = effect(stat, E1),
    ?assertEqual(lists:sublist(Names, 256), First),
    {S2, _} = stated(fun files/1, S1, E1),
    ?assertEqual([<<"Items 1 to 256 of 1,204">>], [T || T <- texts(label, S2), binary:match(T, <<"Items">>) =/= nomatch]),
    {S3, E3} = ui({page, 1}, click, S2),
    {S4, _} = stated(fun files/1, S3, E3),
    {S5, E5} = ui({page, 1}, click, S4),
    {stat, _, ?DIR, Third} = effect(stat, E5),
    ?assertEqual(lists:sublist(Names, 513, 256), Third),
    {S6, _} = stated(fun files/1, S5, E5),
    ?assertEqual(lists:sublist(Names, 513, 256), items(S6)),
    ?assert(lists:member(<<"Items 513 to 768 of 1,204">>, texts(label, S6))),
    {read, _, Path, ?READ_MAX} = effect(read, element(2, choose(open, 5, S6))),
    ?assertEqual(<<?DIR/binary, "/n0517">>, Path),
    %% The last page holds the rest, and next stops there.
    {S7, E7} = ui({page, 1}, click, S6),
    {S8, E8} = ui({page, 1}, click, element(1, stated(fun files/1, S7, E7))),
    {stat, _, ?DIR, Last} = effect(stat, E8),
    ?assertEqual(lists:nthtail(1024, Names), Last),
    {S9, _} = stated(fun files/1, S8, E8),
    ?assertEqual({S9, []}, ui({page, 1}, click, S9)).

an_answer_for_a_page_left_is_dropped_test() ->
    {S0, E0} = erx_desk_files_core:init(#{dir => ?DIR, snarf => false}),
    [{list, Tag, ?DIR} | _] = [E || {list, _, _} = E <- E0],
    {S1, E1} = erx_desk_files_core:step({listed, Tag, {ok, numbered(300)}}, S0),
    {stat, Old, ?DIR, _} = effect(stat, E1),
    {S2, E2} = ui({page, 1}, click, S1),
    ?assert(lists:member({cancel, Old}, E2)),
    ?assertEqual({S2, []}, erx_desk_files_core:step({stated, Old, [file(1) || _ <- lists:seq(1, 256)]}, S2)).

%%% The text test and the preview

the_text_test_test() ->
    Text = binary:copy(<<"boot ok\n">>, 2000),
    ?assertEqual(false, erx_desk_files_core:text(<<"abc", 0, "def">>, false)),
    Bad = <<(binary:part(Text, 0, 10000))/binary, 16#FF, (binary:part(Text, 10001, 5999))/binary>>,
    ?assertEqual(false, erx_desk_files_core:text(Bad, false)),
    ?assertEqual({true, Text}, erx_desk_files_core:text(Text, false)),
    ?assertEqual(false, erx_desk_files_core:text(<<"a", 16#ED, 16#A0, 16#80>>, false)),
    ?assertEqual(false, erx_desk_files_core:text(<<"a", 16#C0, 16#80>>, false)),
    %% A cut read drops a short character more bytes complete, and no other.
    ?assertEqual({true, <<"a">>}, erx_desk_files_core:text(<<"a", 16#E2, 16#80>>, true)),
    ?assertEqual({true, <<"a">>}, erx_desk_files_core:text(<<"a", 16#F4, 16#8F>>, true)),
    ?assertEqual(false, erx_desk_files_core:text(<<"a", 16#E2, 16#80>>, false)),
    [?assertEqual({Short, false}, {Short, erx_desk_files_core:text(<<"a", Short/binary>>, true)})
     || Short <- [<<16#C0>>, <<16#ED, 16#A0>>, <<16#F4, 16#90>>, <<16#F0, 16#8F>>]].

%% A text longer than 16 KiB whose 16,384th byte begins a three-byte
%% character is text, and its preview ends before that character.
a_character_cut_by_the_read_limit_is_dropped_test() ->
    Line = fun(Byte, Length) -> <<(binary:copy(<<Byte>>, Length - 1))/binary, "\n">> end,
    Head = <<(binary:copy(Line($x, 1024), 15))/binary, (Line($y, 1020))/binary>>,
    File = <<Head/binary, "abc", 16#2026/utf8, "tail\n">>,
    ?assertEqual(?READ_MAX - 1, byte_size(Head) + 3),
    {S, _} = opened(?DIR, [<<"long.log">>], fun files/1),
    {_Path, ?READ_MAX, S1} = read(0, File, S),
    Labels = texts(label, S1),
    ?assert(lists:member(<<"abc">>, Labels)),
    ?assertNot(lists:any(fun(L) -> binary:match(L, <<16#2026/utf8>>) =/= nomatch end, Labels)).

a_file_read_whole_that_ends_short_is_not_text_test() ->
    File = <<(binary:copy(<<"a">>, 99))/binary, 16#C3>>,
    {S, _} = opened(?DIR, [<<"short.txt">>], fun files/1),
    {_Path, _, S1} = read(0, File, S),
    ?assert(lists:member(<<"The desktop has no viewer for this file">>, texts(label, S1))).

a_large_file_reads_at_most_16_kib_test() ->
    File = binary:copy(<<"0123456789abcde\n">>, 65536),
    {S, _} = opened(?DIR, [<<"big.log">>], fun files/1),
    {_Path, Bytes, S1} = read(0, File, S),
    ?assertEqual(?READ_MAX, Bytes),
    Lines = [T || T <- texts(label, S1), T =:= <<"0123456789abcde">>],
    ?assertEqual(200, length(Lines)).

a_link_to_a_folder_opens_it_test() ->
    {S, _} = opened(?DIR, [<<"latest">>], fun(_) -> link() end),
    {S1, E1} = choose(open, 0, S),
    {read, Tag, Path, _} = effect(read, E1),
    {_S2, E2} = erx_desk_files_core:step({read, Tag, {error, eisdir}}, S1),
    ?assertMatch({list, _Tag, Path}, effect(list, E2)).

a_folder_too_large_keeps_the_history_test() ->
    {S, _} = opened(?DIR, [<<"big">>], fun(_) -> folder() end),
    {S1, E1} = choose(open, 0, S),
    {list, Tag, Big} = effect(list, E1),
    ?assertEqual(<<?DIR/binary, "/big">>, Big),
    {S2, []} = erx_desk_files_core:step({failed, Tag, killed}, S1),
    ?assert(lists:member(<<"This folder is too large to show here">>, texts(label, S2))),
    {_S3, E3} = ui(back, click, S2),
    ?assertMatch({list, _, ?DIR}, effect(list, E3)).

%%% D5: every tree a core builds is valid, whatever the input

valid_trees_whatever_the_input_test_() ->
    {timeout, 120, fun() ->
        rand:seed(exsss, {8, 19, 5}),
        lists:foreach(fun(Round) -> walk(Round) end, lists:seq(1, 150))
    end}.

%% One random walk: a window on a random folder, its root and folder
%% listings, then random events and answers, each tree validated. Every
%% effect is answered in order, a cancelled request's too, so the core also
%% meets answers it no longer waits for.
walk(Round) ->
    Dir = iolist_to_binary([[<<"/">>, name()] || _ <- lists:seq(1, rand:uniform(24))]),
    {S0, E0} = erx_desk_files_core:init(#{dir => Dir, snarf => rand:uniform(2) =:= 1}),
    lists:foldl(fun(_, {S, Queue}) ->
                        valid(Round, S),
                        act(S, Queue)
                end, {S0, E0}, lists:seq(1, 24)).

valid(Round, S) ->
    Tree = erx_desk_files_core:view(S),
    ?assertEqual({Round, ok}, {Round, erx_ui_schema:validate(Tree, ?UI_NODES)}).

%% Answers the first effect waiting, or now and then, and always when none
%% is waiting, takes a random event, so events also arrive while requests
%% are in flight.
act(S, Queue) ->
    case {[E || E <- Queue, element(1, E) =/= cancel, element(1, E) =/= snarf], rand:uniform(4)} of
        {[Effect | Rest], Draw} when Draw > 1 ->
            {S1, Effects} = erx_desk_files_core:step(answer(Effect), S),
            {S1, Rest ++ Effects};
        {Waiting, _Draw} ->
            {S1, Effects} = event(S),
            {S1, Waiting ++ Effects}
    end.

answer({list, Tag, _Dir}) ->
    case rand:uniform(8) of
        1 -> {failed, Tag, killed};
        2 -> {listed, Tag, {error, enoent}};
        _ -> {listed, Tag, {ok, [name() || _ <- lists:seq(1, rand:uniform(600) - 1)]}}
    end;
answer({stat, Tag, _Dir, Names}) ->
    {stated, Tag, [stat(info()) || _ <- Names]};
answer({read, Tag, _Path, Bytes}) ->
    case rand:uniform(8) of
        1 -> {read, Tag, eof};
        2 -> {failed, Tag, killed};
        _ -> {read, Tag, {ok, contents(Bytes)}}
    end.

%% A random event of the tree shown: a button's, the toggle's, or the
%% list's under its own key or, now and then, the key of an earlier
%% listing, at an index that may lie past the page shown, as an event
%% fired just before a listing changed would.
event(S) ->
    Tree = erx_desk_files_core:view(S),
    Clicks = [{Event, click} || #{on_click := Event} <- props(button, Tree)],
    Toggle = {hidden, {change, rand:uniform(2) =:= 1}},
    Lists = case props(list, Tree) of
                [#{key := Key, items := Items}] ->
                    Chosen = case rand:uniform(4) of
                                 1 -> <<"listing 0 0">>;
                                 _ -> Key
                             end,
                    Index = rand:uniform(max(length(Items), 1)) - 1,
                    [{{select, Chosen}, {change, Index}}, {{open, Chosen}, {submit, Index}}];
                [] ->
                    []
            end,
    Choices = [Toggle | Lists ++ Lists ++ Clicks],
    {Event, Detail} = lists:nth(rand:uniform(length(Choices)), Choices),
    ui(Event, Detail, S).

%% A name of 1 to 255 bytes: printable text, controls, overrides,
%% characters of two to four bytes, and now and then a byte that is not
%% UTF-8.
name() ->
    Pieces = [<<"a">>, <<".">>, <<"~">>, <<"\t">>, <<27>>, <<16#202E/utf8>>, <<16#E9/utf8>>, <<16#2026/utf8>>,
              <<16#1F600/utf8>>, <<16#FF>>, <<16#80>>, <<"long name ">>],
    Target = rand:uniform(255),
    fill(Pieces, Target, <<>>).

fill(_Pieces, Target, Acc) when byte_size(Acc) >= Target -> binary:part(Acc, 0, Target);
fill(Pieces, Target, Acc) -> fill(Pieces, Target, <<Acc/binary, (lists:nth(rand:uniform(length(Pieces)), Pieces))/binary>>).

info() ->
    case rand:uniform(6) of
        1 -> folder();
        2 -> link();
        3 -> {error, eacces};
        _ -> #file_info{type = regular, mode = rand:uniform(8#7777), size = rand:uniform(1 bsl 40),
                        mtime = rand:uniform(1 bsl 36) - (1 bsl 35)}
    end.

%% A file's first bytes: valid text with long and many lines, or bytes
%% that are not text, at most Bytes.
contents(Bytes) ->
    Line = binary:copy(<<16#E9/utf8, "x", 7>>, rand:uniform(3000)),
    Text = case rand:uniform(3) of
               1 -> binary:copy(<<"x\n">>, 9000);
               2 -> binary:copy(<<Line/binary, "\n">>, 20);
               3 -> crypto_free_random(rand:uniform(20000))
           end,
    binary:part(Text, 0, min(Bytes, byte_size(Text))).

crypto_free_random(N) -> list_to_binary([rand:uniform(256) - 1 || _ <- lists:seq(1, N)]).

%% Selecting another item while a file is read cancels the read, and its
%% late answer changes nothing.
a_selection_during_a_read_cancels_it_test() ->
    {S, _} = opened(?DIR, [<<"a.log">>, <<"b.log">>], fun files/1),
    {S1, E1} = choose(open, 0, S),
    {read, Tag, _, _} = effect(read, E1),
    {S2, E2} = choose(select, 1, S1),
    ?assertEqual([{cancel, Tag}], E2),
    ?assertEqual({S2, []}, erx_desk_files_core:step({read, Tag, {ok, <<"late">>}}, S2)).
