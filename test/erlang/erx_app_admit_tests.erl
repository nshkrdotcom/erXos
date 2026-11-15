%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_admit_tests).
-moduledoc """
EUnit cases of admission, `erx_app_admit` (docs/design-packaging.md,
"Admission"). The package files come from test/host/erx_app_admit_test.rb,
which writes them through the ABI codec into the directory `ERX_ADMIT_CASES`
names: each case's first bytes in NAME.bin, and cases.term,
`{Name, Length, Signer, Context, Expected}` for each. A case decodes its file
through `erx_pkg_header:decode/2`, names the signer the file check would,
and admits the header against the manifest and registry `Context` names.
""".

-include_lib("eunit/include/eunit.hrl").

-define(MIB, 1048576).

admission_test_() ->
    Directory = os:getenv("ERX_ADMIT_CASES"),
    {ok, Cases} = file:consult(filename:join(Directory, "cases.term")),
    [{Name, fun() -> check_case(Directory, Name, Length, Signer, Context, Expected) end}
     || {Name, Length, Signer, Context, Expected} <- Cases].

check_case(Directory, Name, Length, Signer, Context, Expected) ->
    {ok, Bytes} = file:read_file(filename:join(Directory, Name ++ ".bin")),
    {ok, Decoded} = erx_pkg_header:decode(Length, Bytes),
    Header = Decoded#{signer => Signer},
    ?assertEqual(Expected, erx_app_admit:admit(Header, manifest(Context), registry(Context))).

%% The facts of a manifest whose apps row offers two windows services and
%% one data service to at most four apps sharing 128 MiB, and whose image
%% carries the package kiosk. The row indices are those
%% test/host/erx_app_admit_test.rb names: packages 7, display 8, data 9 and
%% panel 10. Its system principal is system, as the shipped manifests'.
manifest(no_apps) ->
    (manifest(base))#{apps := none};
manifest(_) ->
    #{apps => #{memory => 128 * ?MIB, max => 4, packages_row => 7,
                services => [#{name => <<"display">>, windows => true, row => 8},
                             #{name => <<"data">>, windows => false, row => 9},
                             #{name => <<"panel">>, windows => true, row => 10}]},
      reserved => [<<"system">>, <<"alice">>, <<"storage">>, <<"display">>,
                   <<"data">>, <<"panel">>, <<"net">>, <<"files">>],
      packages => [<<"kiosk">>]}.

%% The boot's app principals: clock and chess, installed by the signer
%% vendor, in entries 0 and 2, so a new name takes entry 1; and, when full,
%% every entry held.
registry(full) ->
    maps:merge(registry(base),
               #{<<"kiosk">> => #{entry => 1, signer => image},
                 <<"notes">> => #{entry => 3, signer => development}});
registry(_) ->
    #{<<"clock">> => #{entry => 0, signer => <<"vendor">>},
      <<"chess">> => #{entry => 2, signer => <<"vendor">>}}.
