%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_line_app).
-moduledoc """
The SSH line application: a session's line to the SSH domain, erx_ssh_line,
and nothing else. The session's boot script starts it, so the line is up
before init's ready report, and the application names the line as
`ssh_line` among the report's provides (erx_facet:provide/2): the domain
service keeps it for erx_domain:line/3, which hands it to the SSH domain
whose login started the session (docs/design-ssh.md, "Sessions, ttys and
shells"). The line is the application's one process, and the boot script
starts the application permanent, so the line and the session domain end
together. A runtime that reports nothing takes the name and passes it on to
no one.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, Line} = erx_ssh_line:start_link(#{}),
    ok = erx_facet:provide(ssh_line, Line),
    {ok, Line}.

stop(_State) ->
    ok.
