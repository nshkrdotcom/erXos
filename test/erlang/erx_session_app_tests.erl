%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the facets a session mounts (erx_session_app:mounts/2): the facets its
%% template is granted and those it holds, each once, but never the packages or system
%% facet, which no session mounts (docs/design-packaging.md, "An app's session").
%% test/host/erx_session_app_test.rb runs them on stock's emulator.
-module(erx_session_app_tests).

-include_lib("eunit/include/eunit.hrl").

an_app_session_mounts_neither_packages_nor_system_test() ->
    ?assertEqual([], erx_session_app:mounts([packages, system], [packages, system])).

granted_and_held_facets_mount_once_each_test() ->
    ?assertEqual([data, machine, start], erx_session_app:mounts([data, start], [start, machine, packages])).
