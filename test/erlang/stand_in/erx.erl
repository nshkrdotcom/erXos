%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A host stand-in for erx's facet lookup: cap/1 answers the pid a test put under
%% {erx, Name} in persistent_term, or undefined, as a domain holding no such facet.
-module(erx).

-export([cap/1]).

cap(Name) when is_atom(Name) ->
    persistent_term:get({?MODULE, Name}, undefined).
