%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_virtio:identify/2, the check every virtio-mmio driver makes of its
%% transport's first registers, over a reader that answers from a map in place of the
%% device. test/host/erx_virtio_test.rb runs them on stock's emulator.

-module(erx_virtio_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MAGIC, 16#74726976).
-define(BLOCK, 2).
-define(GPU, 16).

%% The transport's three identification words, as erx_device:read/2 would read them.
identify(Magic, Version, DeviceId, Wanted) ->
    Words = #{magic => Magic, version => Version, device_id => DeviceId},
    erx_virtio:identify(fun(Register) -> maps:get(Register, Words) end, Wanted).

the_wanted_device_is_identified_test_() ->
    [?_assertEqual(ok, identify(?MAGIC, 2, ?BLOCK, ?BLOCK)),
     ?_assertEqual(ok, identify(?MAGIC, 2, ?GPU, ?GPU))].

each_refusal_names_the_word_that_disagreed_test_() ->
    [?_assertEqual({error, {magic, 0}}, identify(0, 2, ?BLOCK, ?BLOCK)),
     ?_assertEqual({error, {version, 1}}, identify(?MAGIC, 1, ?GPU, ?GPU)),
     ?_assertEqual({error, {device_id, ?BLOCK}}, identify(?MAGIC, 2, ?BLOCK, ?GPU))].

%% QEMU's empty transport offers the legacy interface unless told otherwise: it is still no
%% device, not a device of the wrong version.
an_empty_transport_is_no_device_whatever_its_version_test_() ->
    [?_assertEqual({error, no_device}, identify(?MAGIC, 2, 0, ?BLOCK)),
     ?_assertEqual({error, no_device}, identify(?MAGIC, 1, 0, ?GPU))].

%% A transport that is not virtio-mmio at all is refused by its magic first, empty or not.
a_wrong_magic_comes_first_test() ->
    ?assertEqual({error, {magic, 0}}, identify(0, 1, 0, ?BLOCK)).
