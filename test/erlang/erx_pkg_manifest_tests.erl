%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_manifest_tests).
-moduledoc """
erx_pkg_manifest:system_config/1 over the manifests test/host/erx_pkg_manifest_test.rb
writes to $ERX_PKG_MANIFEST_FILES: the hand-built bytes of
AbiManifestFixture.packages, the fixture with none of the records, the
development key in a release manifest, two apps rows, and the manifest the
host's check packs.
""".

-include_lib("eunit/include/eunit.hrl").

manifest(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_PKG_MANIFEST_FILES"), Name ++ ".bin")),
    Bytes.

key(Byte) ->
    binary:copy(<<Byte>>, 32).

hand_built_records_test() ->
    ?assertEqual({ok, #{apps => #{memory => 1048576, max => 2, services => []},
                        packages => [#{name => <<"clock">>, sha256 => key(16#ab), enabled => true}],
                        signers => [{<<"ops">>, key(16#cd)}],
                        development => key(7)}},
                 erx_pkg_manifest:system_config(manifest("packages"))).

no_records_test() ->
    ?assertEqual({ok, #{apps => none, packages => [], signers => [], development => none}},
                 erx_pkg_manifest:system_config(manifest("none"))).

%% A release manifest holds no development key, and the apps table holds one row.
refused_test() ->
    ?assertMatch({error, #{reason := inactive, field := <<"root.development_key.count">>}},
                 erx_pkg_manifest:system_config(manifest("release_development"))),
    ?assertMatch({error, #{reason := extent, field := <<"apps">>}},
                 erx_pkg_manifest:system_config(manifest("two_apps"))),
    ?assertMatch({error, _}, erx_pkg_manifest:system_config(<<>>)).

admitted_manifest_test() ->
    ?assertEqual({ok, #{apps => #{memory => 1048576, max => 2, services => [<<"shared">>]},
                        packages => [#{name => <<"clock">>, sha256 => key(16#ab), enabled => true},
                                     #{name => <<"quotes">>, sha256 => key(16#ab), enabled => false}],
                        signers => [{<<"ops">>, key(16#cd)}],
                        development => key(7)}},
                 erx_pkg_manifest:system_config(manifest("admitted"))).
