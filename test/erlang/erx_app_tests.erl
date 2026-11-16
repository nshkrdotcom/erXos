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
    #{place => <<"packages/image/x.app">>,
      layout => #{image_offset => 4096, image_length => 4096, tree_offset => 8192,
                  tree_length => 0, salt => <<0:256>>, root_hash => <<0:256>>},
      start => Start}.

%% The mount: each case's fixture directory stands for the image at /app, and the
%% mount says it ran. It is handed nothing: erx_ns's process takes the package's place
%% and layout from the record the session's agent keeps. The root is a string, as the
%% session's is.
effects(Root) ->
    Self = self(),
    #{mount => fun() -> Self ! mounted, ok end,
      root => filename:join(cases(), Root),
      type => temporary}.

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

native_app_is_not_supported_test() ->
    ?assertEqual({error, {not_supported, program}},
                 erx_app:run(record({program, <<"bin/tiny">>, []}), effects("good"))).
