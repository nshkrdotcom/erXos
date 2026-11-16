%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_tests).
-moduledoc """
erx_app over a fixture /app (docs/design-packaging.md, "Verification and
testing"): a directory ERX_APP_CASES names, which test/host/erx_app_test.rb
fills with compiled fixture apps and a fixture release directory, each run in
the code server's interactive mode, which a session's runtime runs.

* `release/ebin` holds `erx_app_clash`, the release's module of that name,
  put on the code path before erx_app runs as a release's are;
* `good/lib/good_app/ebin` an app whose application starts;
* `clash/lib/clash_app/ebin` an app that ships its own `erx_app_clash`, whose
  start calls a function only the app's copy has.
""".

-include_lib("eunit/include/eunit.hrl").

cases() -> os:getenv("ERX_APP_CASES").

record(Start) ->
    record(Start, false).

record(Start, Window) ->
    #{place => {packages, [<<"x.app">>]},
      layout => #{image_offset => 4096, image_length => 4096, tree_offset => 8192,
                  tree_length => 0, salt => <<0:256>>, root_hash => <<0:256>>},
      start => Start, window => Window}.

%% The mount: each case's fixture directory stands for the image at /app, and the
%% mount says it ran. It is handed nothing: erx_ns's process takes the package's place
%% and layout from the record the session's agent keeps. The root is a string, as the
%% session's is.
effects(Root) ->
    Self = self(),
    #{mount => fun() -> Self ! mounted, ok end,
      root => filename:join(cases(), Root),
      type => temporary,
      display => screen,
      start_program => fun(Spec) -> started(Spec, {shutdown, {program_exit, {exited, 0}}}) end}.

%% A start of the program Spec names, which the case's process hears of, by a
%% handler that ends at once with End, as one does once its program has ended.
started(Spec, End) ->
    self() ! {started, Spec},
    {Handler, Monitor} = spawn_monitor(fun() -> exit(End) end),
    {ok, Handler, Monitor, []}.

%% A native app's run of Record over Effects from an empty mailbox: the answer, and
%% what the case's process heard during it, in order.
native(Record, Effects) ->
    _ = heard(),
    Answer = erx_app:run(Record, Effects),
    {Answer, heard()}.

heard() ->
    receive Message -> [Message | heard()] after 0 -> [] end.

%% The release's directory, as a release's are, before the app's; its erx_app_clash
%% is not loaded yet, so the code server's path order alone decides which copy loads.
release_on_path() ->
    true = code:add_patha(filename:join([cases(), "release", "ebin"])).

good_app_starts_from_its_mounted_image_test() ->
    ?assertEqual(ok, erx_app:run(record({applications, [<<"good_app">>]}), effects("good"))),
    ?assertEqual(mounted, receive M -> M after 0 -> none end),
    ?assert(lists:keymember(good_app, 1, application:which_applications())),
    Ebin = filename:join([cases(), "good", "lib", "good_app", "ebin"]),
    %% The app's path comes after every path the release put there.
    ?assertEqual(Ebin, lists:last(code:get_path())),
    ok = application:stop(good_app).

%% A module the app ships under the release's name is never the one the code
%% server finds: the release's stays loaded and only the app fails.
clash_fails_only_the_app_test() ->
    release_on_path(),
    Release = filename:join([cases(), "release", "ebin", "erx_app_clash.beam"]),
    Answer = erx_app:run(record({applications, [<<"clash_app">>]}), effects("clash")),
    ?assertMatch({error, {start, clash_app, _}}, Answer),
    ?assertEqual(Release, code:which(erx_app_clash)),
    ?assertEqual(release, erx_app_clash:which()),
    ?assertNot(lists:keymember(clash_app, 1, application:which_applications())).

refused_mount_ends_with_its_reason_test() ->
    Effects = (effects("good"))#{mount := fun() -> {error, eio} end},
    ?assertEqual({error, {mount, eio}}, erx_app:run(record({applications, [<<"good_app">>]}), Effects)).

%% A native app's program starts from /app once /app is mounted, with its window on
%% the session's default display, and its end is the answer, which ends the session.
native_app_starts_with_its_window_and_ends_with_its_program_test() ->
    Effects = effects("good"),
    Image = list_to_binary(maps:get(root, Effects) ++ "/bin/tiny"),
    {Answer, Heard} = native(record({program, <<"bin/tiny">>, [<<"-v">>]}, true), Effects),
    ?assertEqual({error, {program_exit, {exited, 0}}}, Answer),
    ?assertMatch([mounted, {started, #{image := Image, argv := [Image, <<"-v">>], window := screen}}], Heard).

native_app_without_a_window_test() ->
    {Answer, [mounted, {started, Spec}]} = native(record({program, <<"bin/tiny">>, []}), effects("good")),
    ?assertEqual({error, {program_exit, {exited, 0}}}, Answer),
    ?assertNot(is_map_key(window, Spec)).

%% The handler's own end, a crash or a lost program, ends the session with its reason.
handler_end_is_the_answer_test() ->
    Effects = (effects("good"))#{start_program := fun(Spec) -> started(Spec, program_lost) end},
    ?assertMatch({{error, program_lost}, _}, native(record({program, <<"bin/tiny">>, []}), Effects)).

refused_start_is_the_answer_test() ->
    Effects = (effects("good"))#{start_program := fun(_Spec) -> {error, enodev} end},
    ?assertEqual({{error, {program, enodev}}, [mounted]}, native(record({program, <<"bin/tiny">>, []}, true), Effects)).

%% A window with no default display starts nothing.
window_without_a_display_starts_nothing_test() ->
    Effects = (effects("good"))#{display := none},
    ?assertEqual({{error, {window, no_display}}, [mounted]},
                 native(record({program, <<"bin/tiny">>, []}, true), Effects)).

refused_mount_starts_no_program_test() ->
    Effects = (effects("good"))#{mount := fun() -> {error, eio} end},
    ?assertEqual({{error, {mount, eio}}, []}, native(record({program, <<"bin/tiny">>, []}, true), Effects)).
