%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_app).
-moduledoc "The session application: the session's /data, /apps and /machine and its supervisor (erx_session_sup).".
-behaviour(application).

-export([start/2, stop/1]).

%% Each facet the session holds or its template is granted that has a place in the
%% namespace (erx_ns:mount_facets/1), mounted before the application starts its
%% supervisor. /data only for a session whose template the manifest grants data, which
%% the ready answer names (erx:granted/0) before the application starts: the storage
%% domain's tree through the session's data facet, which each lookup reads afresh, so a
%% grant installed later or re-granted after the storage domain restarts needs no
%% remount. A session without the grant has no /data mount and finds the root's empty
%% /data directory (docs/design-files.md, "A facet's mount").
%%
%% /apps, the start service's tree (docs/design-apps.md, "Interfaces"), and /machine,
%% the domain service's machine tree (docs/design-system.md, "A session's request"),
%% only for a session whose template the manifest grants them: their grants are in the
%% ready answer, before the application starts (erx:caps/0), and a session without one
%% has no such path at all.
start(_Type, _Args) ->
    ok = erx_ns:mount_facets(lists:usort(erx:granted() ++ maps:keys(erx:caps()))),
    erx_session_sup:start_link().

stop(_State) ->
    ok.
