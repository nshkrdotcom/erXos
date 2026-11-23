%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Test only: a stand-in for erx_dist on stock's emulator, whose owner/1 is a NIF of
%% erXos's runtime. owner/1 answers the domain the test put in the persistent term
%% erx_dist_owner, for every name, so a host test says which domain a facet claims.
-module(erx_dist).
-export([owner/1]).

owner(_Name) ->
    persistent_term:get(erx_dist_owner).
