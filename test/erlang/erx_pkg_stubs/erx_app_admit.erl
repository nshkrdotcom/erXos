%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_admit).
-moduledoc """
A stub of admission (docs/design-packaging.md, "Admission") for erx_pkg's
tests: it admits every header but those whose app name the manifest term,
`#{refuse := Names}`, lists, which it refuses as of another ABI.
""".
-export([admit/3]).

admit(#{header := #{name := Name}}, #{refuse := Refused}, _Registry) ->
    case lists:member(Name, Refused) of
        true -> {error, {abi, 1, 2}};
        false -> {ok, {admitted, Name}}
    end.
