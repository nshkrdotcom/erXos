%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The window system on stock OTP (test/host/erx_winfs_test.rb): erx_winfs under the
%% single policy, its grants started as erx_fs grants of this domain, erx_window, and
%% erx_screen over a driver model, with erx_memdraw's NIF built for the host and a
%% stand-in pixel area (test/display/erx_area_stand_in.c). A client is the test,
%% speaking the file protocol to its grant as erx_file_remote does.
%%
%% G1: under the single policy the session's first window is shown and every other
%% window hidden, a hidden window's kbd receives nothing and its wctl show is refused,
%% and when the shown window ends, by its holder's end or its directory's removal, the
%% session's next oldest is shown. G3: against a driver that never answers, many wctl
%% writes and window makes and removes leave the window system and the screen
%% responsive, the screen's mailbox drained and its frame the one it started with, and
%% the screen's end answers a held present EIO. G6: a one-pixel present pushes one
%% rectangle of one pixel, and a change that shows nothing new pushes nothing.

-module(erx_winfs_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([info/1, export/3]).

%% Plan 9's XRGB32: CHAN4(CIgnore, 8, CRed, 8, CGreen, 8, CBlue, 8).
-define(XRGB32, 16#68081828).
-define(WIDTH, 8).
-define(HEIGHT, 4).
-define(DRIVER, erx_winfs_test_driver).
-define(SYSTEM, 1).
%% The display's service, as the display domain's display variable names it.
-define(SERVICE, screen).
-define(SESSION, 10).
-define(OTHER, 20).
-define(NOFID, 16#ffffffff).
-define(AT_REMOVEDIR, 16#200).
-define(O_RDONLY, 0).
-define(O_WRONLY, 1).
-define(O_RDWR, 2).
-define(WAIT, 5000).
-define(QUIET, 300).

%% Fixtures ------------------------------------------------------------------

-doc false.
info(Driver) ->
    gen_server:call(Driver, info).

%% The export table's stand-in: a grant of this domain exports itself to no one.
-doc false.
export(_Grant, _Rights, _Peer) ->
    ok.

%% A driver model registered as ?DRIVER over a screen image of its own: it tells the
%% test each flush and answers it, or, as `never`, answers none.
driver(Mode) ->
    Test = self(),
    {ok, Screen} = erx_memdraw:alloc(?XRGB32, {0, 0, ?WIDTH, ?HEIGHT}, {0, 0, ?WIDTH, ?HEIGHT},
                                     false, 16#000000ff),
    Info = #{width => ?WIDTH, height => ?HEIGHT, chan => <<"x8r8g8b8">>, screen => Screen,
             partial => true, direct => false},
    Pid = spawn(fun() -> serve(Test, Info, Mode) end),
    true = register(?DRIVER, Pid),
    {Pid, Screen}.

serve(Test, Info, Mode) ->
    receive
        {'$gen_call', From, info} ->
            gen_server:reply(From, Info);
        {'$gen_call', From, {flush, Rects, _Image}} ->
            Test ! {flushed, Rects},
            ok = case Mode of
                     answer -> gen_server:reply(From, ok);
                     never -> ok
                 end
    end,
    serve(Test, Info, Mode).

%% The window system, then the screen over the driver model, as erx_fb_sup starts them.
start(Mode) ->
    _ = [kill(Pid) || Name <- [erx_screen, erx_winfs, ?DRIVER], Pid <- [whereis(Name)], is_pid(Pid)],
    ok = forget_flushes(),
    Test = self(),
    {Driver, Image} = driver(Mode),
    {ok, Winfs} = erx_winfs:start_link(#{service => ?SERVICE, system => ?SYSTEM, exports => ?MODULE,
                                         minted => fun(Tag, Reply) -> Test ! {minted, Tag, Reply} end,
                                         area => fun area_of/1, clients => own, provide => false,
                                         policy => {erx_wm_single, #{}}}),
    {ok, Screen} = erx_screen:start_link({?MODULE, ?DRIVER}),
    true = unlink(Winfs),
    true = unlink(Screen),
    #{driver => Driver, image => Image, winfs => Winfs, screen => Screen}.

stop(#{driver := Driver, winfs := Winfs, screen := Screen}) ->
    _ = [kill(P) || P <- [Screen, Winfs, Driver]],
    _ = [persistent_term:erase(K) || {{?MODULE, _, _} = K, _} <- persistent_term:get()],
    ok.

kill(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

%% A writable stand-in pixel area of one page for Grantee, and an image over its buffer
%% of the screen's size, through which the test draws as the client would.
give_area(Grantee) ->
    {ok, Area, _Page} = erx_memdraw:test_area(16384, write),
    persistent_term:put({?MODULE, area, Grantee}, {ok, Area, 16384}),
    {ok, Image} = erx_memdraw:wrap(Area, 0, {0, 0, ?WIDTH, ?HEIGHT}, ?XRGB32),
    Image.

area_of(Grantee) ->
    persistent_term:get({?MODULE, area, Grantee}, {error, none}).

%% A mint of Grantee's grant, and the grant attached as fid 1.
mint(Grantee, Limits) ->
    Tag = erlang:unique_integer([positive]),
    erx_winfs ! {erx_origin, ?SYSTEM, {erx_facet_mint, Tag, ?SERVICE, Grantee, root, Limits}},
    Grant = receive {minted, Tag, {ok, G}} -> G after ?WAIT -> error(no_mint) end,
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, <<"windows">>, 0}),
    Grant.

call(Grant, Request) ->
    call(Grant, self(), Request).

call(Grant, Owner, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, Owner, Request},
    receive {erx_9p, Alias, Reply} -> Reply
    after ?WAIT -> error({no_reply, Request})
    end.

%% Request sent from a process of its own, whose reply reaches the test as
%% {answered, Tag, Reply}.
call_async(Grant, Request) ->
    Test = self(),
    Tag = make_ref(),
    spawn(fun() -> Test ! {answered, Tag, call(Grant, Test, Request)} end),
    Tag.

answered(Tag) ->
    receive {answered, Tag, Reply} -> Reply after ?WAIT -> error(no_answer) end.

unanswered(Tag) ->
    receive {answered, Tag, Reply} -> error({answered, Reply}) after ?QUIET -> ok end.

mkdir(Grant, Name) ->
    call(Grant, {mkdir, 1, Name, 8#755, 0}).

%% Opens window Name's File as Fid.
open(Grant, Fid, Name, File, Flags) ->
    {ok, _} = call(Grant, {walk, 1, Fid, [Name, File]}),
    ok = element(1, call(Grant, {lopen, Fid, Flags})),
    Fid.

read(Grant, Fid) ->
    call(Grant, {read, Fid, 0, 4096}).

write(Grant, Fid, Data) ->
    call(Grant, {write, Fid, 0, Data}).

state(Grant, Fid) ->
    {ok, Text} = read(Grant, Fid),
    lists:last(binary:split(string:trim(Text), <<" ">>, [global, trim_all])).

%% A keyboard driver's record of KEY_A going down, evdev code 30.
key_a() ->
    erx_winfs:input(<<"kbd">>, {key, down, 30}).

flushed() ->
    receive {flushed, Rects} -> Rects after ?WAIT -> error(no_flush) end.

no_flush() ->
    receive {flushed, Rects} -> error({flushed, Rects}) after ?QUIET -> ok end.

%% Flushes a test before this one left in the mailbox.
forget_flushes() ->
    receive {flushed, _} -> forget_flushes() after 0 -> ok end.

drain_flushes() ->
    receive {flushed, _} -> drain_flushes() after ?QUIET -> ok end.

%% G1 ------------------------------------------------------------------------

the_single_policy_shows_the_sessions_oldest_window_test_() ->
    {timeout, 60, fun single_policy/0}.

single_policy() ->
    World = start(answer),
    Session = mint(?SESSION, #{session => true, windows => 2}),
    Other = mint(?OTHER, #{windows => 2}),
    Holder = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = call(Session, Holder, {mkdir, 1, <<"first">>, 8#755, 0}),
    {ok, _} = mkdir(Session, <<"second">>),
    {ok, _} = mkdir(Other, <<"x">>),
    ?assertEqual({error, eexist}, mkdir(Other, <<"x">>)),
    {ok, _} = mkdir(Other, <<"y">>),
    ?assertEqual({error, edquot}, mkdir(Other, <<"z">>)),
    %% An existing name is found before the quota, as FreeBSD's mkdir finds it.
    ?assertEqual({error, eexist}, mkdir(Other, <<"x">>)),
    First = open(Session, 2, <<"first">>, <<"wctl">>, ?O_RDWR),
    Second = open(Session, 3, <<"second">>, <<"wctl">>, ?O_RDWR),
    OtherWctl = open(Other, 2, <<"x">>, <<"wctl">>, ?O_RDWR),
    ?assertEqual(<<"visible">>, state(Session, First)),
    ?assertEqual(<<"hidden">>, state(Session, Second)),
    ?assertEqual(<<"hidden">>, state(Other, OtherWctl)),
    ?assertEqual({error, einval}, write(Session, Second, <<"unhide\n">>)),
    ?assertEqual({error, einval}, write(Other, OtherWctl, <<"unhide\n">>)),
    %% Typing reaches the shown window alone.
    FirstKbd = open(Session, 4, <<"first">>, <<"kbd">>, ?O_RDONLY),
    SecondKbd = open(Session, 5, <<"second">>, <<"kbd">>, ?O_RDONLY),
    HiddenRead = call_async(Session, {read, SecondKbd, 0, 64}),
    OtherKbd = call_async(Other, {read, open(Other, 3, <<"x">>, <<"kbd">>, ?O_RDONLY), 0, 64}),
    ok = key_a(),
    ?assertEqual({ok, <<"ka", 0>>}, read(Session, FirstKbd)),
    ?assertEqual({ok, <<"ca", 0>>}, read(Session, FirstKbd)),
    ok = unanswered(HiddenRead),
    ok = unanswered(OtherKbd),
    {ok, _} = call(Session, {walk, 1, 6, [<<"first">>, <<"mouse">>]}),
    ?assertEqual({error, eacces}, call(Session, {lopen, 6, ?O_RDWR})),
    %% The holder's end ends the shown window; the session's next oldest is shown.
    Holder ! stop,
    ok = shown_soon(Session, Second),
    {ok, _} = mkdir(Session, <<"third">>),
    Third = open(Session, 7, <<"third">>, <<"wctl">>, ?O_RDWR),
    ?assertEqual(<<"hidden">>, state(Session, Third)),
    ok = call(Session, {unlinkat, 1, <<"second">>, ?AT_REMOVEDIR}),
    ok = shown_soon(Session, Third),
    ?assertEqual({error, eio}, read(Session, Second)),
    %% The hidden read of the removed window ends with it.
    ?assertEqual({error, eio}, answered(HiddenRead)),
    stop(World).

shown_soon(Grant, Fid) ->
    shown_soon(Grant, Fid, 50).

shown_soon(_Grant, _Fid, 0) ->
    error(never_shown);
shown_soon(Grant, Fid, Tries) ->
    case state(Grant, Fid) of
        <<"visible">> -> ok;
        _ -> timer:sleep(20), shown_soon(Grant, Fid, Tries - 1)
    end.

%% G3 ------------------------------------------------------------------------

a_driver_that_never_answers_blocks_neither_winfs_nor_the_screen_test_() ->
    {timeout, 120, fun never_answers/0}.

never_answers() ->
    World = #{screen := Screen} = start(never),
    ?assertMatch([_ | _], flushed()),
    _ = give_area(?SESSION),
    Session = mint(?SESSION, #{session => true, windows => 2}),
    {ok, _} = mkdir(Session, <<"w">>),
    Wctl = open(Session, 2, <<"w">>, <<"wctl">>, ?O_RDWR),
    Ctl = open(Session, 3, <<"w">>, <<"ctl">>, ?O_RDWR),
    lists:foreach(fun(_) ->
                          {error, einval} = write(Session, Wctl, <<"move -minx 1 -miny 1\n">>)
                  end, lists:seq(1, 50000)),
    lists:foreach(fun(_) ->
                          {ok, _} = mkdir(Session, <<"t">>),
                          ok = call(Session, {unlinkat, 1, <<"t">>, ?AT_REMOVEDIR})
                  end, lists:seq(1, 25000)),
    %% Both answer, the screen has taken every layout, and the frame it started with is
    %% the only one the driver has seen.
    {ok, [_]} = call(Session, {walk, 1, 4, [<<"w">>]}),
    _ = sys:get_state(Screen, ?WAIT),
    ?assertEqual({message_queue_len, 0}, process_info(Screen, message_queue_len)),
    ok = no_flush(),
    %% A present held behind the frame is answered EIO when the screen ends.
    Held = call_async(Session, {write, Ctl, 0, <<"present 0 8 4\n">>}),
    ok = unanswered(Held),
    kill(Screen),
    ?assertEqual({error, eio}, answered(Held)),
    stop(World#{screen := spawn(fun() -> ok end)}).

%% G6 ------------------------------------------------------------------------

pushes_follow_what_changed_test_() ->
    {timeout, 60, fun push_counts/0}.

push_counts() ->
    World = #{image := Screen} = start(answer),
    drain_flushes(),
    Buffer = give_area(?SESSION),
    Session = mint(?SESSION, #{session => true}),
    {ok, _} = mkdir(Session, <<"w">>),
    drain_flushes(),
    Ctl = open(Session, 2, <<"w">>, <<"ctl">>, ?O_RDWR),
    ?assertEqual({ok, <<"x8r8g8b8\n">>}, read(Session, Ctl)),
    {ok, _} = erx_memdraw:load(Buffer, {0, 0, 1, 1}, <<16#11, 16#22, 16#33, 0>>),
    ?assertMatch({ok, _, _}, write(Session, Ctl, <<"present 0 8 4 0 0 1 1\n">>)),
    ?assertEqual([{0, 0, 1, 1}], flushed()),
    ok = no_flush(),
    {ok, <<16#11, 16#22, 16#33, _, Next:3/binary, _/binary>>} =
        erx_memdraw:read(Screen, {0, 0, 2, 1}),
    <<R, G, B, _>> = <<(erx_screen:background()):32>>,
    ?assertEqual(<<B, G, R>>, Next),
    %% A window that is made hidden, and its present, show nothing new.
    _ = give_area(?OTHER),
    Other = mint(?OTHER, #{}),
    {ok, _} = mkdir(Other, <<"x">>),
    OtherCtl = open(Other, 2, <<"x">>, <<"ctl">>, ?O_RDWR),
    ?assertMatch({ok, _, _}, write(Other, OtherCtl, <<"present 0 8 4\n">>)),
    ok = no_flush(),
    %% A present past the area's end, or at an offset that is not whole pages, is
    %% refused and shows nothing.
    ?assertEqual({error, einval}, write(Session, Ctl, <<"present 16384 8 4\n">>)),
    ?assertEqual({error, einval}, write(Session, Ctl, <<"present 4 8 4\n">>)),
    ?assertEqual({error, einval}, write(Session, Ctl, <<"present 0 16384 16384\n">>)),
    ok = no_flush(),
    stop(World).

%% A grant without a pixel area is refused ENXIO, and a malformed line EINVAL.
presents_without_an_area_are_refused_test() ->
    World = start(answer),
    Grant = mint(?OTHER, #{}),
    {ok, _} = mkdir(Grant, <<"w">>),
    Ctl = open(Grant, 2, <<"w">>, <<"ctl">>, ?O_RDWR),
    ?assertEqual({error, enxio}, write(Grant, Ctl, <<"present 0 8 4\n">>)),
    ?assertEqual({error, einval}, write(Grant, Ctl, <<"present\n">>)),
    Label = open(Grant, 3, <<"w">>, <<"label">>, ?O_RDWR),
    ?assertMatch({ok, _, _}, write(Grant, Label, <<"term">>)),
    ?assertEqual({ok, <<"term">>}, read(Grant, Label)),
    ?assertEqual({error, einval}, call(Grant, {write, Label, 1, <<"x">>})),
    stop(World).

%% The mint grants requests of the display's service alone: one carrying the configured
%% name is granted, and one of another service, the windows interface's name among them,
%% is unknown.
mints_are_of_the_configured_service_test() ->
    Mint = fun(Service) -> {erx_origin, ?SYSTEM, {erx_facet_mint, 7, Service, ?SESSION, root, #{}}} end,
    ?assertEqual({grant, 7, ?SESSION, #{}}, erx_winfs:mint_request(?SYSTEM, ?SERVICE, Mint(?SERVICE))),
    ?assertEqual(unknown, erx_winfs:mint_request(?SYSTEM, ?SERVICE, Mint(windows))),
    ?assertEqual(unknown, erx_winfs:mint_request(?SYSTEM, ?SERVICE, Mint(display))).

%% A mint of another service reaches the running window system and is dropped: no grant
%% is minted for it, and the next mint of the configured service is.
a_running_window_system_drops_another_service_s_mint_test() ->
    World = start(answer),
    erx_winfs ! {erx_origin, ?SYSTEM, {erx_facet_mint, 1, windows, ?SESSION, root, #{}}},
    _ = mint(?SESSION, #{}),
    receive {minted, 1, Reply} -> error({minted_another_service, Reply}) after 0 -> ok end,
    stop(World).

%% erx_fb_sup starts the window system for the service the display variable names, and
%% none, refusing, when the variable is unset, empty or longer than a service name.
the_display_variable_names_the_window_system_s_service_test() ->
    ?assertMatch([#{id := erx_winfs, start := {erx_winfs, start_link, [screen, {erx_wm_single, #{}}]}}],
                 erx_fb_sup:winfs("screen", "single")),
    ?assertEqual([], erx_fb_sup:winfs(false, "single")),
    ?assertEqual([], erx_fb_sup:winfs("", "single")),
    ?assertEqual([], erx_fb_sup:winfs(lists:duplicate(64, $a), "single")).

%% erx_fb_sup maps each mf_display_policy member to its window manager and nothing else,
%% so a policy with no window manager fails its start instead of running another policy's.
the_window_system_has_no_policy_beyond_its_window_managers_test() ->
    ?assertMatch([#{start := {erx_winfs, start_link, [screen, {erx_wm_rio, #{}}]}}],
                 erx_fb_sup:winfs("screen", "rio")),
    ?assertError(function_clause, erx_fb_sup:winfs("screen", "tiled")).

%% Started as the display domain's, the window system names itself the mint of the
%% configured service, the name every mint request of it carries.
the_window_system_provides_the_configured_service_test() ->
    _ = [kill(Pid) || Pid <- [whereis(erx_winfs)], is_pid(Pid)],
    _ = persistent_term:erase({erx, provides}),
    {ok, Winfs} = erx_winfs:start_link(#{service => ?SERVICE, system => ?SYSTEM, exports => ?MODULE,
                                         minted => fun(_Tag, _Reply) -> ok end, area => fun area_of/1,
                                         clients => own, provide => true, policy => {erx_wm_single, #{}}}),
    true = unlink(Winfs),
    ?assertEqual(#{?SERVICE => Winfs}, persistent_term:get({erx, provides})),
    kill(Winfs),
    _ = persistent_term:erase({erx, provides}),
    ok.

%% The window tree is a made tree (erx_fs_node): every attribute valid, a directory
%% with two links and a file with one, the made trees' statfs, a directory that opens
%% for reading only, and a listing that is what the directory's open took, so a window
%% made after the open is listed only by the next open.
the_window_tree_answers_as_the_made_trees_do_test_() ->
    {timeout, 60, fun made_tree/0}.

made_tree() ->
    World = start(answer),
    Session = mint(?SESSION, #{session => true, windows => 2}),
    Root = 1,
    {ok, _} = mkdir(Session, <<"first">>),
    Before = open_root(Session, 2),
    {ok, _} = mkdir(Session, <<"second">>),
    ?assertEqual([{1, <<"first">>}], listed(Session, Before, 0)),
    After = open_root(Session, 3),
    ?assertEqual([{1, <<"first">>}, {2, <<"second">>}], listed(Session, After, 0)),
    ?assertEqual([{2, <<"second">>}], listed(Session, After, 1)),
    {ok, _} = call(Session, {walk, Root, 4, []}),
    ?assertEqual({error, eisdir}, call(Session, {lopen, 4, ?O_RDWR})),
    {ok, Dir} = call(Session, {getattr, Root, 0}),
    ?assertMatch(#{nlink := 2, uid := 0, size := 0}, Dir),
    ?assertEqual(?ERX_P9_S_IFDIR bor 8#700, maps:get(mode, Dir)),
    Mouse = 5,
    {ok, _} = call(Session, {walk, Root, Mouse, [<<"first">>, <<"mouse">>]}),
    {ok, File} = call(Session, {getattr, Mouse, 0}),
    ?assertMatch(#{nlink := 1}, File),
    ?assertEqual(?ERX_P9_S_IFREG bor 8#400, maps:get(mode, File)),
    ?assertEqual(maps:get(valid, File), maps:get(valid, Dir)),
    ?assertNotEqual(0, maps:get(valid, Dir) band ?ERX_P9_GETATTR_MASK_UID),
    ?assertMatch({ok, #{type := ?ERX_P9_MAGIC_RAMFS, bsize := ?ERX_PAGE_SIZE}}, call(Session, {statfs, Root})),
    stop(World).

%% Opens the client's directory for reading as Fid.
open_root(Grant, Fid) ->
    {ok, _} = call(Grant, {walk, 1, Fid, []}),
    ok = element(1, call(Grant, {lopen, Fid, ?O_RDONLY})),
    Fid.

%% The offsets and names of Fid's listing from Offset.
listed(Grant, Fid, Offset) ->
    {ok, Entries} = call(Grant, {readdir, Fid, Offset, 4096}),
    [{At, Name} || {_, At, _, Name} <- Entries].

%% The clipboard ---------------------------------------------------------------

%% Opens the root's clipboard as Fid.
open_clipboard(Grant, Fid, Flags) ->
    {ok, _} = call(Grant, {walk, 1, Fid, [<<"clipboard">>]}),
    ok = element(1, call(Grant, {lopen, Fid, Flags})),
    Fid.

%% The names the grant's root lists from Offset, through a new open of it as Fid.
names(Grant, Fid, Offset) ->
    [Name || {_At, Name} <- listed(Grant, open_root(Grant, Fid), Offset)].

%% What one grant writes to /clipboard every grant whose limits carry clipboard reads back, from
%% any offset. Each write lands at its offset, which its answer names, so writes in turn
%% on one fid follow each other; a write at an offset replaces the bytes there, and one
%% of no bytes changes nothing.
clipboard_is_shared_by_the_grants_that_carry_it_test() ->
    World = start(answer),
    Copier = mint(?SESSION, #{clipboard => true}),
    Paster = mint(?OTHER, #{clipboard => true}),
    Copy = open_clipboard(Copier, 2, ?O_RDWR),
    Paste = open_clipboard(Paster, 2, ?O_RDONLY),
    ?assertEqual({ok, <<>>}, read(Paster, Paste)),
    ?assertEqual({ok, 5, 0}, write(Copier, Copy, <<"hello">>)),
    ?assertEqual({ok, 6, 5}, call(Copier, {write, Copy, 5, <<" world">>})),
    ?assertEqual({ok, <<"hello world">>}, read(Paster, Paste)),
    ?assertEqual({ok, <<"llo">>}, call(Paster, {read, Paste, 2, 3})),
    ?assertEqual({ok, <<>>}, call(Paster, {read, Paste, 99, 4096})),
    ?assertEqual({ok, 1, 1}, call(Copier, {write, Copy, 1, <<"a">>})),
    ?assertEqual({ok, 0, 99}, call(Copier, {write, Copy, 99, <<>>})),
    ?assertEqual({ok, <<"hallo world">>}, read(Paster, Paste)),
    stop(World).

%% An open for writing with O_TRUNC empties the clipboard, through lopen or through
%% lcreate, which opens it as an open with O_CREAT does; one for reading leaves it.
%% O_APPEND, access mode 3 and an exclusive create are refused.
clipboard_opens_test() ->
    World = start(answer),
    Grant = mint(?SESSION, #{clipboard => true}),
    Clipboard = open_clipboard(Grant, 2, ?O_RDWR),
    {ok, _, _} = write(Grant, Clipboard, <<"text">>),
    _ = open_clipboard(Grant, 3, ?O_RDONLY bor ?ERX_P9_O_TRUNC),
    ?assertEqual({ok, <<"text">>}, read(Grant, Clipboard)),
    _ = open_clipboard(Grant, 4, ?O_WRONLY bor ?ERX_P9_O_TRUNC),
    ?assertEqual({ok, <<>>}, read(Grant, Clipboard)),
    {ok, _, _} = write(Grant, Clipboard, <<"text">>),
    {ok, _} = call(Grant, {walk, 1, 5, []}),
    ?assertMatch({ok, _, _}, call(Grant, {lcreate, 5, <<"clipboard">>, ?O_WRONLY bor ?ERX_P9_O_TRUNC, 8#666, 0})),
    ?assertEqual({ok, <<>>}, read(Grant, Clipboard)),
    ?assertEqual({ok, 2, 0}, write(Grant, 5, <<"hi">>)),
    ?assertEqual({ok, <<"hi">>}, read(Grant, Clipboard)),
    {ok, _} = call(Grant, {walk, 1, 6, []}),
    ?assertEqual({error, eexist},
                 call(Grant, {lcreate, 6, <<"clipboard">>, ?O_WRONLY bor ?ERX_P9_O_EXCL, 8#666, 0})),
    {ok, _} = call(Grant, {walk, 1, 7, [<<"clipboard">>]}),
    ?assertEqual({error, einval}, call(Grant, {lopen, 7, ?O_WRONLY bor ?ERX_P9_O_APPEND})),
    ?assertEqual({error, einval}, call(Grant, {lopen, 7, 3 bor ?ERX_P9_O_TRUNC})),
    ?assertEqual({ok, <<"hi">>}, read(Grant, Clipboard)),
    stop(World).

%% A grant without clipboard has no /clipboard to walk to, list or create; under either grant
%% clipboard is the tree's own name, which no mkdir takes and no remove ends, and a listing
%% read on from the clipboard's entry goes on with the windows.
clipboard_is_the_tree_s_own_name_test() ->
    World = start(answer),
    With = mint(?SESSION, #{clipboard => true, windows => 2}),
    Without = mint(?OTHER, #{windows => 2}),
    {ok, _} = mkdir(With, <<"w">>),
    {ok, _} = mkdir(Without, <<"w">>),
    ?assertEqual({error, enoent}, call(Without, {walk, 1, 2, [<<"clipboard">>]})),
    ?assertEqual([<<"w">>], names(Without, 2, 0)),
    ?assertEqual([<<"clipboard">>, <<"w">>], names(With, 2, 0)),
    ?assertEqual([<<"w">>], names(With, 3, 1)),
    {ok, _} = call(Without, {walk, 1, 3, []}),
    ?assertEqual({error, eperm}, call(Without, {lcreate, 3, <<"clipboard">>, ?O_WRONLY, 8#666, 0})),
    ?assertEqual({error, eexist}, mkdir(With, <<"clipboard">>)),
    ?assertEqual({error, eexist}, mkdir(Without, <<"clipboard">>)),
    ?assertEqual({error, eperm}, call(With, {unlinkat, 1, <<"clipboard">>, 0})),
    ?assertEqual({error, enotdir}, call(With, {unlinkat, 1, <<"clipboard">>, ?AT_REMOVEDIR})),
    %% It is a regular file of one link, readable and writable by its owner.
    {ok, _} = call(With, {walk, 1, 4, [<<"clipboard">>]}),
    {ok, Attr} = call(With, {getattr, 4, 0}),
    ?assertMatch(#{nlink := 1}, Attr),
    ?assertEqual(?ERX_P9_S_IFREG bor 8#600, maps:get(mode, Attr)),
    stop(World).

%% The clipboard holds ERX_WINDOWS_CLIPBOARD_BYTES and no more: a client's write that would
%% take it past that is refused whole with EFBIG, whatever its offset, and leaves the
%% clipboard as it was.
clipboard_is_bounded_test_() ->
    {timeout, 60, fun clipboard_bound/0}.

clipboard_bound() ->
    World = start(answer),
    Grant = mint(?SESSION, #{clipboard => true}),
    Clipboard = open_clipboard(Grant, 2, ?O_RDWR),
    Bound = ?ERX_WINDOWS_CLIPBOARD_BYTES,
    Chunk = 32768,
    Full = Bound div Chunk,
    lists:foreach(fun(N) ->
                          ?assertEqual({ok, Chunk, N * Chunk},
                                       call(Grant, {write, Clipboard, N * Chunk, binary:copy(<<N>>, Chunk)}))
                  end, lists:seq(0, Full - 1)),
    Last = Full - 1,
    ?assertEqual({error, efbig}, call(Grant, {write, Clipboard, Bound, <<"x">>})),
    ?assertEqual({error, efbig}, call(Grant, {write, Clipboard, Bound - 1, <<"xy">>})),
    ?assertEqual({error, efbig}, call(Grant, {write, Clipboard, 1 bsl 63, <<"x">>})),
    ?assertEqual({ok, <<Last, Last>>}, call(Grant, {read, Clipboard, Bound - 2, 4096})),
    ?assertEqual({ok, 1, Bound - 1}, call(Grant, {write, Clipboard, Bound - 1, <<"z">>})),
    ?assertEqual({ok, <<Last, "z">>}, call(Grant, {read, Clipboard, Bound - 2, 4096})),
    %% A mint whose clipboard is not a boolean is refused.
    Tag = erlang:unique_integer([positive]),
    erx_winfs ! {erx_origin, ?SYSTEM, {erx_facet_mint, Tag, ?SERVICE, ?OTHER, root, #{clipboard => 1}}},
    ?assertEqual({error, einval}, receive {minted, Tag, Reply} -> Reply after ?WAIT -> no_mint end),
    stop(World).

%% Writers on several grants at once lose nothing: each write is applied whole, so every
%% writer's bytes at its own offset are there when all have answered.
concurrent_clipboard_writers_lose_nothing_test_() ->
    {timeout, 60, fun concurrent_writers/0}.

concurrent_writers() ->
    World = start(answer),
    Grants = [mint(?SESSION + K, #{clipboard => true}) || K <- lists:seq(0, 3)],
    Size = 512,
    Writers = 64,
    Tags = [begin
                Grant = lists:nth(K rem 4 + 1, Grants),
                Fid = open_clipboard(Grant, K + 2, ?O_WRONLY),
                call_async(Grant, {write, Fid, K * Size, binary:copy(<<K>>, Size)})
            end || K <- lists:seq(0, Writers - 1)],
    ?assertEqual(lists:duplicate(Writers, ok), [element(1, answered(Tag)) || Tag <- Tags]),
    Read = open_clipboard(hd(Grants), Writers + 2, ?O_RDONLY),
    Expected = << <<(binary:copy(<<K>>, Size))/binary>> || K <- lists:seq(0, Writers - 1) >>,
    ?assertEqual(Expected, read_all(hd(Grants), Read, 0)),
    stop(World).

read_all(Grant, Fid, Offset) ->
    case call(Grant, {read, Fid, Offset, 8192}) of
        {ok, <<>>} -> <<>>;
        {ok, Bytes} -> <<Bytes/binary, (read_all(Grant, Fid, Offset + byte_size(Bytes)))/binary>>
    end.
