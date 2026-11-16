%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_files_core).
-moduledoc """
The core of files, the desktop's folder browser
(docs/design-desktop-programs.md, "files"): a pure state machine that
the window process, erx_desk_window, drives. step/2 takes one input and
answers the next state and the effects to perform; view/1 answers the
widget tree of a state. The core reads no file, clock or process: every
read is an effect whose answer comes back as an input.

**A listing.** The current folder is read in two steps, a `list` of its
names and then a `stat` of the names of the page shown, at most a list's
256 items. The names kept are those that can name an entry (not empty,
`.` or `..`, and holding no `/` or NUL), sorted byte for byte; names
that start with `.` are left out unless the toolbar's toggle shows them.
Each listing the core takes in, a refresh, a new folder or the toggle,
advances its generation.

**Acting by index.** The core keeps each item's raw name; the tree holds
only its shown text, which the renderer draws through the line escape
(design-display's G5). Every action names its item by its index in the
page, and the list node's key and every event term of the list carry the
listing's generation and page. The widget server drops an event on the
list of a replaced listing, and the core drops one whose key is not the
listing it shows, which an event the server fired just before the core
moved on is. An index the core acts on therefore always indexes the page
it shows. The path and sidebar buttons carry the folder they open.

**Lanes.** Each request in flight waits in one of three lanes: `folder`
(the current folder's list and its page's stat), `open` (the read of an
opened item, with the item's path) and `root` (the sidebar's list and
stat of the namespace's root). A lane holds one tag; starting a request
in a busy lane cancels the one it replaces, and an answer whose tag no
lane holds is dropped, so a slow answer for a folder the person has left
changes nothing. A new listing, page or selection cancels the read.

**Opening** a folder makes it the current folder. Opening anything else
reads at most its first 16 KiB; a read answered `eisdir`, a link to a
folder or an item whose information has not arrived, opens the folder
instead. The bytes read are text when they are valid UTF-8 with no NUL,
except that a character cut short at the end of a read that filled the
16 KiB, and that more bytes could complete, is dropped; a file of
exactly 16 KiB counts as cut, since telling it apart would take a
further read. Text shows as a preview of at most 200 lines; anything
else shows its information and that the desktop has no viewer for it.

**Bounds.** Every text in the tree is cut, at a character boundary, to
its property's bound in erx_ui_schema: a list item's or a shown name's
with an ellipsis in the middle, so both ends stay visible, and a preview
line at its end. Bytes that are not UTF-8 in a name show as U+FFFD, so a
tree is valid whatever the input. The toolbar shows the root's button
and the last 16 folders of the path, so its children stay within the
schema's bound however deep the folder. No name becomes an atom.
""".

-include_lib("kernel/include/file.hrl").

-export([init/1, step/2, view/1, kind/3, text/2]).
-export_type([state/0, input/0, effect/0, kind/0]).

%% The most bytes an opened file is read for, and the most lines its
%% preview shows (docs/design-desktop-programs.md, "What it reads and does"
%% and "Names and contents are untrusted").
-define(READ_MAX, 16384).
-define(PREVIEW_LINES, 200).
%% The most path buttons after the root's: a deeper folder shows its last
%% ones, after an ellipsis.
-define(PATH_BUTTONS, 16).
-define(ELLIPSIS, <<16#2026/utf8>>).
%% The kinds a name's suffix gives, the first that matches.
-define(SUFFIXES,
        [{<<".app">>, package}, {<<".png">>, picture},
         {<<".txt">>, text}, {<<".md">>, text}, {<<".log">>, text}, {<<".conf">>, text}, {<<".erl">>, text},
         {<<".hrl">>, text}, {<<".c">>, text}, {<<".h">>, text}, {<<".rb">>, text}, {<<".sh">>, text},
         {<<".rc">>, text}]).

-type tag() :: non_neg_integer().
-type lane() :: folder | open | root.
-type info() :: #file_info{} | {error, term()}.

-doc "What an item is, guessed from its information and its name.".
-type kind() :: folder | link | program | package | picture | text | system | document.

-doc """
An input: an event of the tree (`Event` the term view/1 set for it,
`Detail` the toolkit's `click`, or `{change, V}` or `{submit, V}` with
the state value of a list or checkbox), a worker's answer tagged with
its request, a worker that ended without answering, or the answer of a
`snarf`. Names are binaries; a `stat` answer holds
`file:read_link_info(Path, [{time, posix}])`'s result for each name
asked, in order; a `read` answer is `file:read/2`'s, and a read of a
folder answers `{error, eisdir}`.
""".
-type input() :: {ui, Window :: term(), Event :: term(), Detail :: term()}
               | {listed, tag(), {ok, [binary()]} | {error, term()}}
               | {stated, tag(), [{ok, #file_info{}} | {error, term()}]}
               | {read, tag(), {ok, binary()} | eof | {error, term()}}
               | {failed, tag(), Reason :: term()}
               | {snarfed, ok | {error, term()}}.

-doc "An effect, from design-desktop-programs' closed set.".
-type effect() :: {list, tag(), Dir :: binary()}
                | {stat, tag(), Dir :: binary(), Names :: [binary()]}
                | {read, tag(), Path :: binary(), Bytes :: pos_integer()}
                | {snarf, Bytes :: binary()}
                | {cancel, tag()}.

%% A listing: being read, refused with a text, or its kept names, sorted,
%% with the page shown and that page's information as it arrives.
-type listing() :: loading
                 | {failed, Text :: [binary()]}
                 | #{all := [binary()], names := tuple(), page := non_neg_integer(),
                     infos := loading | tuple()}.

%% What the info section shows below the selected item's information.
-type pane() :: info | opening | {preview, Lines :: [binary()]} | no_viewer | {error, Text :: binary()}.

-record(files, {
    dir :: binary(),
    back = [] :: [binary()],
    forward = [] :: [binary()],
    hidden = false :: boolean(),
    snarf :: boolean(),
    generation = 0 :: non_neg_integer(),
    listing = loading :: listing(),
    selected = none :: none | non_neg_integer(),
    pane = info :: pane(),
    sidebar = [] :: [binary()],
    root_names = [] :: [binary()],
    %% Each lane's tag, with what its answer needs: the opened item's path.
    lanes = #{} :: #{lane() => {tag(), Path :: binary() | none}},
    next_tag = 0 :: tag()}).

-opaque state() :: #files{}.

%%% The machine

-doc """
The state of a window opened on folder `Dir`, an absolute path, and the
first effects: the folder's listing and the root's, for the sidebar.
`Snarf` says whether the session's display grant carries `snarf`.
""".
-spec init(#{dir := binary(), snarf := boolean()}) -> {state(), [effect()]}.
init(#{dir := Dir, snarf := Snarf}) when is_binary(Dir), is_boolean(Snarf) ->
    Folder = folder_of(resolved(components(Dir))),
    {S1, E1} = request(folder, {list, Folder}, #files{dir = Folder, snarf = Snarf}),
    {S2, E2} = request(root, {list, <<"/">>}, S1),
    {S2, E1 ++ E2}.

-doc "The next state and the effects to perform after `Input`.".
-spec step(input(), state()) -> {state(), [effect()]}.
step({ui, _Window, Event, Detail}, S) ->
    event(Event, Detail, S);
step({snarfed, _Result}, S) ->
    {S, []};
step({Answer, Tag, Result}, S) when Answer =:= listed; Answer =:= stated; Answer =:= read;
                                    Answer =:= failed ->
    case [{Lane, Path} || Lane := {T, Path} <- S#files.lanes, T =:= Tag] of
        [{Lane, Path}] -> answer(Lane, {Answer, Result}, Path, S#files{lanes = maps:remove(Lane, S#files.lanes)});
        [] -> {S, []}
    end.

%% The tree's events, each term the one view/1 sets. A list's event names
%% the listing and page it was chosen in, and is dropped for another.
event({select, Key}, {change, Index}, S) ->
    case current(Key, S) of
        true -> select(Index, S);
        false -> {S, []}
    end;
event({open, Key}, {submit, Index}, S) ->
    case current(Key, S) of
        true -> open(Index, S);
        false -> {S, []}
    end;
event(back, _, #files{back = [Dir | Back], forward = Forward} = S) ->
    listing(Dir, S#files{back = Back, forward = [S#files.dir | Forward]});
event(forward, _, #files{forward = [Dir | Forward], back = Back} = S) ->
    listing(Dir, S#files{forward = Forward, back = [S#files.dir | Back]});
event({go, Dir}, _, S) ->
    go(Dir, S);
event(refresh, _, S) ->
    listing(S#files.dir, S);
event(hidden, {change, Shown}, #files{listing = #{all := All}} = S) ->
    taken_in(All, S#files{hidden = Shown});
event(hidden, {change, Shown}, S) ->
    {S#files{hidden = Shown}, []};
event({page, Step}, _, #files{listing = #{names := Names, page := Page} = L} = S) ->
    To = Page + Step,
    case To >= 0 andalso To < pages(tuple_size(Names)) of
        true -> page(L#{page := To}, S);
        false -> {S, []}
    end;
event(copy_path, _, #files{snarf = true, selected = Index} = S) when Index =/= none ->
    {S, [{snarf, path(Index, S)}]};
event(_Event, _Detail, S) ->
    {S, []}.

%% A lane's answer, its tag already taken off the lane; Path is the opened
%% item's for the open lane.
answer(folder, {listed, {ok, Names}}, none, S) ->
    taken_in(Names, S);
answer(folder, {stated, Results}, none, #files{listing = #{} = L} = S) ->
    {S#files{listing = L#{infos := list_to_tuple([stated(R) || R <- Results])}}, []};
answer(folder, {failed, Reason}, none, #files{listing = #{names := Names, page := Page} = L} = S) ->
    Failed = [{error, Reason} || _ <- page_names(Names, Page)],
    {S#files{listing = L#{infos := list_to_tuple(Failed)}}, []};
answer(folder, {failed, killed}, none, S) ->
    Text = [<<"This folder is too large to show here">>, <<"Use ls to read it">>],
    {advanced(S#files{listing = {failed, Text}}), []};
answer(folder, {Refused, Reason}, none, S) when Refused =:= listed; Refused =:= failed ->
    {advanced(S#files{listing = {failed, [reason(Reason)]}}), []};
answer(open, {read, {error, eisdir}}, Path, S) ->
    go(Path, S);
answer(open, {read, eof}, Path, S) ->
    answer(open, {read, {ok, <<>>}}, Path, S);
answer(open, {read, {ok, Bytes}}, _Path, S) ->
    Pane = case text(Bytes, byte_size(Bytes) >= ?READ_MAX) of
               {true, Text} -> {preview, preview(Text)};
               false -> no_viewer
           end,
    {S#files{pane = Pane}, []};
answer(open, {_Refused, Reason}, _Path, S) ->
    {S#files{pane = {error, reason(Reason)}}, []};
answer(root, {listed, {ok, Names}}, none, S) ->
    Kept = lists:sublist(kept(Names, false), max_items()),
    request(root, {stat, <<"/">>, Kept}, S#files{root_names = Kept});
answer(root, {stated, Results}, none, #files{root_names = Names} = S) ->
    Folders = [N || {N, {ok, #file_info{type = directory}}} <- lists:zip(Names, Results, trim)],
    {S#files{sidebar = Folders, root_names = []}, []};
answer(root, _Refused, none, S) ->
    {S#files{root_names = []}, []}.

stated({ok, Info}) -> Info;
stated({error, _} = Refused) -> Refused.

%% Whether Key names the listing and page shown.
current(Key, #files{listing = #{page := Page}, generation = G}) -> Key =:= listing_key(G, Page);
current(_Key, _S) -> false.

%% Makes Dir the current folder, the one left pushed on the back history.
go(Dir, #files{dir = Dir} = S) ->
    listing(Dir, S);
go(Dir, S) ->
    listing(Dir, S#files{back = [S#files.dir | S#files.back], forward = []}).

%% Reads folder Dir as the current one.
listing(Dir, S) ->
    {S1, Cancelled} = unselected(S#files{dir = Dir, listing = loading}),
    {S2, Listed} = request(folder, {list, Dir}, advanced(S1)),
    {S2, Cancelled ++ Listed}.

%% Takes in a listing's names: a new generation on its first page.
taken_in(Names, S) ->
    page(#{all => Names, names => list_to_tuple(kept(Names, S#files.hidden)), page => 0, infos => loading},
         advanced(S)).

%% Shows page L of the listing and asks the information of its names; an
%% empty page has all of it.
page(#{names := Names, page := Page} = L, S) ->
    {S1, Cancelled} = unselected(S),
    case page_names(Names, Page) of
        [] ->
            {S1#files{listing = L#{infos := {}}}, Cancelled};
        Shown ->
            {S2, Stat} = request(folder, {stat, S#files.dir, Shown}, S1#files{listing = L#{infos := loading}}),
            {S2, Cancelled ++ Stat}
    end.

select(Index, #files{selected = Index} = S) ->
    {S, []};
select(Index, S) ->
    {S1, Cancelled} = unselected(S),
    {S1#files{selected = Index}, Cancelled}.

%% Clears the selection and cancels the read of the item it opened.
unselected(S) ->
    cancel(open, S#files{selected = none, pane = info}).

%% Opens the item at Index of the page shown.
open(Index, #files{listing = #{infos := Infos}} = S) ->
    Path = path(Index, S),
    case info(Index, Infos) of
        #file_info{type = directory} ->
            go(Path, S);
        _FileLinkOrUnknown ->
            {S1, Cancelled} = select(Index, S),
            {S2, Read} = request(open, {read, Path, ?READ_MAX}, S1#files{pane = opening}),
            {S2, Cancelled ++ Read}
    end.

%% Puts a request in its lane, cancelling the one it replaces.
request(Lane, Request, #files{next_tag = Tag} = S) ->
    {S1, Cancelled} = cancel(Lane, S),
    {Effect, Path} = case Request of
                         {list, Dir} -> {{list, Tag, Dir}, none};
                         {stat, Dir, Names} -> {{stat, Tag, Dir, Names}, none};
                         {read, Path1, Bytes} -> {{read, Tag, Path1, Bytes}, Path1}
                     end,
    {S1#files{lanes = (S1#files.lanes)#{Lane => {Tag, Path}}, next_tag = Tag + 1}, Cancelled ++ [Effect]}.

cancel(Lane, #files{lanes = Lanes} = S) ->
    case maps:take(Lane, Lanes) of
        {{Tag, _Path}, Rest} -> {S#files{lanes = Rest}, [{cancel, Tag}]};
        error -> {S, []}
    end.

advanced(#files{generation = G} = S) -> S#files{generation = G + 1}.

reason(killed) ->
    <<"The file server did not answer in time">>;
reason(Reason) when is_atom(Reason) ->
    case file:format_error(Reason) of
        "unknown POSIX error" ++ _ -> atom_to_binary(Reason);
        Text -> unicode:characters_to_binary(Text)
    end;
reason(_Reason) ->
    <<"The file server failed">>.

%%% Pure decisions

-doc """
The kind of the item `Name` of folder `Dir`, from its information when it
has arrived and else from its name alone: a directory, a symbolic link or
a file with an execute bit by its information, then a package, a picture
or text by its name's suffix, anything under `/proc`, and the rest.
""".
-spec kind(Dir :: binary(), Name :: binary(), info() | loading) -> kind().
kind(_Dir, _Name, #file_info{type = directory}) -> folder;
kind(_Dir, _Name, #file_info{type = symlink}) -> link;
kind(_Dir, _Name, #file_info{type = regular, mode = Mode}) when Mode band 8#111 =/= 0 -> program;
kind(Dir, Name, _Info) -> by_name(Dir, Name).

by_name(Dir, Name) ->
    Ends = fun({Suffix, _Kind}) ->
                   byte_size(Name) > byte_size(Suffix)
                       andalso binary:longest_common_suffix([Name, Suffix]) =:= byte_size(Suffix)
           end,
    case lists:search(Ends, ?SUFFIXES) of
        {value, {_Suffix, Kind}} -> Kind;
        false when Dir =:= <<"/proc">> -> system;
        false ->
            case Dir of
                <<"/proc/", _/binary>> -> system;
                _ -> document
            end
    end.

-doc """
The text test: `{true, Text}` when `Bytes`, an opened file's first bytes,
are text, and `false` otherwise. Text is valid UTF-8 with no NUL; when
`Cut`, the read stopped at its limit, and a character cut short at the
end that more bytes could complete is dropped from `Text` rather than
counted as malformed.
""".
-spec text(binary(), Cut :: boolean()) -> {true, binary()} | false.
text(Bytes, Cut) ->
    Read = binary:part(Bytes, 0, min(byte_size(Bytes), ?READ_MAX)),
    case unicode:characters_to_binary(Read) of
        Text when is_binary(Text) -> no_nul(Text);
        {incomplete, Text, Short} when Cut -> completes(Short) andalso no_nul(Text);
        _Malformed -> false
    end.

no_nul(Text) ->
    case binary:match(Text, <<0>>) of
        nomatch -> {true, Text};
        _ -> false
    end.

%% Whether the start of a character, Short, is one that some continuation
%% bytes complete: one of the lowest or the highest continuation bytes does
%% if any do, since each lead byte's range of second bytes is contiguous.
completes(<<Lead, _/binary>> = Short) ->
    Length = if Lead >= 16#F0 -> 4; Lead >= 16#E0 -> 3; true -> 2 end,
    Pad = Length - byte_size(Short),
    lists:any(fun(Byte) -> is_binary(unicode:characters_to_binary(<<Short/binary, (binary:copy(<<Byte>>, Pad))/binary>>)) end,
              [16#80, 16#BF]).

%% A preview's lines: at most 200, each cut to a text property's bound.
preview(Text) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    Whole = case lists:last(Lines) of
                <<>> -> lists:droplast(Lines);
                _ -> Lines
            end,
    [cut_end(Line, caption_max()) || Line <- lists:sublist(Whole, ?PREVIEW_LINES)].

%% The names of a listing kept: those that can name an entry, without the
%% hidden ones unless Hidden, sorted byte for byte.
kept(Names, Hidden) ->
    lists:sort([N || N <- Names, entry_name(N), Hidden orelse binary:first(N) =/= $.]).

entry_name(<<>>) -> false;
entry_name(<<".">>) -> false;
entry_name(<<"..">>) -> false;
entry_name(Name) -> binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch.

pages(0) -> 1;
pages(Count) -> (Count + max_items() - 1) div max_items().

%% The index in the listing of the first item of Page.
offset(Page) -> Page * max_items().

page_names(Names, Page) ->
    Offset = offset(Page),
    [element(I, Names) || I <- lists:seq(Offset + 1, min(Offset + max_items(), tuple_size(Names)))].

%% The raw name and path of the item at Index of the page shown.
name(Index, #files{listing = #{names := Names, page := Page}}) ->
    element(offset(Page) + Index + 1, Names).

path(Index, S) -> join(S#files.dir, name(Index, S)).

info(Index, Infos) when Index < tuple_size(Infos) -> element(Index + 1, Infos);
info(_Index, _Loading) -> loading.

join(<<"/">>, Name) -> <<"/", Name/binary>>;
join(Dir, Name) -> <<Dir/binary, "/", Name/binary>>.

%% The folders of an absolute path from the root, and the path of a list
%% of folders.
components(Dir) -> [C || C <- binary:split(Dir, <<"/">>, [global]), C =/= <<>>].

%% The folders of a path with `.` dropped and each `..` taking the folder
%% before it, as the namespace resolves them.
resolved(Folders) ->
    lists:reverse(lists:foldl(fun(<<".">>, Kept) -> Kept;
                                 (<<"..">>, []) -> [];
                                 (<<"..">>, [_Last | Kept]) -> Kept;
                                 (Folder, Kept) -> [Folder | Kept]
                              end, [], Folders)).

folder_of([]) -> <<"/">>;
folder_of(Folders) -> iolist_to_binary([[<<"/">>, C] || C <- Folders]).

%%% Shown text

%% The schema's bounds: a list's items and a list item's bytes, and a
%% text property's bytes.
max_items() ->
    #{type := {list, _Item, Max, _None}} = erx_ui_schema:property(items),
    Max.

item_max() ->
    #{type := {list, {text, Max}, _ListMax, _None}} = erx_ui_schema:property(items),
    Max.

caption_max() ->
    #{type := {text, Max}} = erx_ui_schema:property(text),
    Max.

%% A name as the tree shows it: valid UTF-8, cut to a list item's bound
%% with the middle replaced by an ellipsis.
shown(Name) ->
    cut_middle(valid_utf8(Name), item_max()).

cut_middle(Text, Max) when byte_size(Text) =< Max ->
    Text;
cut_middle(Text, Max) ->
    Room = Max - byte_size(?ELLIPSIS),
    Head = cut_end(Text, Room div 2),
    Tail = cut_start(Text, Room - Room div 2),
    <<Head/binary, (?ELLIPSIS)/binary, Tail/binary>>.

%% The longest prefix, or suffix, of UTF-8 Text of at most Max bytes that
%% ends, or starts, at a character boundary.
cut_end(Text, Max) when byte_size(Text) =< Max -> Text;
cut_end(Text, Max) -> binary:part(Text, 0, boundary(Text, Max, -1)).

cut_start(Text, Max) when byte_size(Text) =< Max -> Text;
cut_start(Text, Max) ->
    At = boundary(Text, byte_size(Text) - Max, 1),
    binary:part(Text, At, byte_size(Text) - At).

%% The first offset from At, stepping by Step, where no continuation byte
%% starts: at most three steps in valid UTF-8.
boundary(Text, At, Step) when At > 0, At < byte_size(Text) ->
    case binary:at(Text, At) band 16#C0 of
        16#80 -> boundary(Text, At + Step, Step);
        _ -> At
    end;
boundary(_Text, At, _Step) ->
    At.

%% Bytes with each malformed sequence replaced by U+FFFD.
valid_utf8(Bytes) -> valid_utf8(Bytes, <<>>).

valid_utf8(Bytes, Acc) ->
    case unicode:characters_to_binary(Bytes) of
        Valid when is_binary(Valid) ->
            <<Acc/binary, Valid/binary>>;
        {_Malformed, Good, <<_, Rest/binary>>} ->
            valid_utf8(Rest, <<Acc/binary, Good/binary, 16#FFFD/utf8>>)
    end.

%%% The tree

-doc "The widget tree of state `S`.".
-spec view(state()) -> erx_ui_schema:tree().
view(S) ->
    {column, #{},
     [toolbar(S),
      {row, #{weight => 1},
       [{column, #{width => 160}, [button(shown(N), {go, join(<<"/">>, N)}, true) || N <- S#files.sidebar]},
        {column, #{weight => 1}, items(S)},
        {column, #{width => 240}, details(S)}]}]}.

toolbar(#files{dir = Dir} = S) ->
    {row, #{},
     [button(<<"<">>, back, S#files.back =/= [], #{name => <<"Back">>}),
      button(<<">">>, forward, S#files.forward =/= [], #{name => <<"Forward">>})]
     ++ path_buttons(components(Dir))
     ++ [{spacer, #{weight => 1}, []},
         {checkbox, #{text => <<"Hidden files">>, checked => S#files.hidden, on_change => hidden}, []},
         button(<<"Refresh">>, refresh, true),
         button(<<"Copy path">>, copy_path, S#files.snarf andalso S#files.selected =/= none)]}.

%% The root's button and one per folder, the last ?PATH_BUTTONS of them,
%% each opening its folder.
path_buttons(Folders) ->
    Prefixes = [lists:sublist(Folders, Depth) || Depth <- lists:seq(1, length(Folders))],
    Kept = lists:nthtail(max(0, length(Prefixes) - ?PATH_BUTTONS), Prefixes),
    Elided = [{label, #{text => ?ELLIPSIS}, []} || length(Kept) < length(Prefixes)],
    [button(<<"/">>, {go, <<"/">>}, true) | Elided]
        ++ [button(shown(lists:last(P)), {go, folder_of(P)}, true) || P <- Kept].

button(Text, Event, Enabled) -> button(Text, Event, Enabled, #{}).
button(Text, Event, Enabled, Props) -> {button, Props#{text => Text, on_click => Event, enabled => Enabled}, []}.

label(Text) -> {label, #{text => Text}, []}.

items(#files{listing = loading}) ->
    [label(<<"Loading">>)];
items(#files{listing = {failed, Text}}) ->
    [label(T) || T <- Text];
items(#files{listing = #{names := Names, page := Page, infos := Infos}, generation = G} = S) ->
    Key = listing_key(G, Page),
    Selected = case S#files.selected of
                   none -> #{};
                   Index -> #{selected => Index}
               end,
    List = Selected#{key => Key, items => [shown(N) || N <- page_names(Names, Page)],
                     on_change => {select, Key}, on_submit => {open, Key}, weight => 1},
    [{list, List, []}, footer(tuple_size(Names), Page, Infos)].

%% The list node's key: a new node for every listing and page.
listing_key(Generation, Page) ->
    iolist_to_binary(io_lib:format("listing ~b ~b", [Generation, Page])).

footer(_Count, _Page, loading) ->
    label(<<"Loading">>);
footer(Count, Page, _Infos) ->
    case pages(Count) of
        1 ->
            label(count(Count, <<" item">>));
        _ ->
            First = offset(Page) + 1,
            Last = min(First + max_items() - 1, Count),
            {row, #{},
             [button(<<"Previous">>, {page, -1}, Page > 0),
              label(iolist_to_binary([<<"Items ">>, thousands(First), <<" to ">>, thousands(Last),
                                      <<" of ">>, thousands(Count)])),
              button(<<"Next">>, {page, 1}, Last < Count)]}
    end.

count(1, Noun) -> <<"1", Noun/binary>>;
count(N, Noun) -> iolist_to_binary([thousands(N), Noun, <<"s">>]).

details(#files{selected = none}) ->
    [];
details(#files{listing = #{infos := Infos}, dir = Dir, selected = Index} = S) ->
    Name = name(Index, S),
    Info = info(Index, Infos),
    [label(shown(Name)), label(kind_text(kind(Dir, Name, Info))) | information(Info)] ++ pane(S#files.pane).

information(#file_info{size = Size, mtime = Mtime} = Info) ->
    [label(count(Size, <<" byte">>)) || is_integer(Size), Size >= 0, Size < 1 bsl 64]
        ++ [label(modified(Mtime)) || is_integer(Mtime), Mtime >= 0, Mtime < 1 bsl 40]
        ++ [label(mode(Info))];
information(loading) ->
    [label(<<"Loading">>)];
information({error, Reason}) ->
    [label(reason(Reason))].

pane({preview, Lines}) ->
    [{scroll, #{weight => 1}, [{column, #{}, [label(L) || L <- Lines]}]}];
pane(no_viewer) ->
    [label(<<"The desktop has no viewer for this file">>)];
pane(opening) ->
    [label(<<"Opening">>)];
pane({error, Text}) ->
    [label(Text)];
pane(info) ->
    [].

kind_text(folder) -> <<"Folder">>;
kind_text(link) -> <<"Link">>;
kind_text(program) -> <<"Program">>;
kind_text(package) -> <<"Package">>;
kind_text(picture) -> <<"Picture">>;
kind_text(text) -> <<"Text">>;
kind_text(system) -> <<"System file">>;
kind_text(document) -> <<"Document">>.

%% A modification time, in POSIX seconds, as the UTC date and minute.
modified(Seconds) ->
    {{Y, Mo, D}, {H, Mi, _}} = calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(io_lib:format("Modified ~4..0b-~2..0b-~2..0b ~2..0b:~2..0b UTC", [Y, Mo, D, H, Mi])).

%% The mode as ls writes it: the type, then read, write and execute for
%% the owner, the group and others.
mode(#file_info{type = Type, mode = Mode}) ->
    T = case Type of
            directory -> $d;
            symlink -> $l;
            _ -> $-
        end,
    Bits = [case Mode band (1 bsl B) of
                0 -> $-;
                _ -> element(B rem 3 + 1, {$x, $w, $r})
            end || is_integer(Mode), B <- lists:seq(8, 0, -1)],
    <<T, (list_to_binary(Bits))/binary>>.

%% A count with a comma between each group of three digits.
thousands(N) when N < 1000 -> integer_to_binary(N);
thousands(N) -> iolist_to_binary([thousands(N div 1000), io_lib:format(",~3..0b", [N rem 1000])]).
