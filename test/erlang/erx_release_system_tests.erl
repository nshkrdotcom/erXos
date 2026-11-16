%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The booted slot's system partition as the packer writes it, read as its storage
%% domain reads it (docs/design-stopgap.md, "The booted slot"): over a RAM window
%% (erx_erofs_tests:window/1) on the partitions test/host/release_medium_test.rb writes
%% in ERX_RELEASE_SYSTEM, each mounted with erx_erofs:mount/3 under the layout
%% erx_device_record:system_image/1 reads from the words of the `system_image` record,
%% which the test takes from the manifest's row. system.terms names the record's words
%% and each file of the release with the host file holding its bytes.
-module(erx_release_system_tests).

-include_lib("eunit/include/eunit.hrl").

%% The case directory's terms: the record's words and the release's files.
terms() ->
    {ok, Terms} = file:consult(filename:join(os:getenv("ERX_RELEASE_SYSTEM"), "system.terms")),
    maps:from_list(Terms).

%% The partition Name, mounted under the record.
mount(Name) ->
    #{record := Words} = terms(),
    {ok, Layout} = erx_device_record:system_image([Words]),
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_RELEASE_SYSTEM"), Name ++ ".img")),
    erx_erofs:mount(erx_erofs_tests:window(Bytes), Layout, fun(_) -> ok end).

%% Every file of the release reads back through the tree as the host file holds it.
release_files_read_through_the_tree_test() ->
    {ok, Fs} = mount("good"),
    #{files := Files} = terms(),
    [?assertEqual({Path, file:read_file(Source)},
                  {Path, erx_erofs:read_file(Fs, binary:split(list_to_binary(Path), <<"/">>, [global]))})
     || {Path, Source} <- Files].

%% A bit of the tree flipped: the root hash no longer covers the tree, so the first
%% block the mount reads answers eio.
a_flipped_tree_bit_answers_eio_test() ->
    ?assertMatch({error, eio, _}, mount("flipped")).
