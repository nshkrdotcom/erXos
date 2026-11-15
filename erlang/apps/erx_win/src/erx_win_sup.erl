%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_win_sup).
-moduledoc """
The supervisor of `erx_win` in a client domain (docs/design-display.md,
"The pixel area", The allocator is not restarted over an area). Its first
child is the allocator erx_pixels, which is temporary and significant, so
it is never restarted: its end, however it comes, shuts the supervisor down, which ends
the permanent application and the domain with it. A second allocator over
the same areas would hand out ranges that programs still map; the domain's
next start has new connections and new, zeroed areas instead. Its other
children are the domain's draw connections, which `erx_draw_conn:start/1`
adds as temporary children: they draw into buffers the allocator leased
them, so they start after it and end before it.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Pixels = #{id => erx_pixels, start => {erx_pixels, start_link, []},
               restart => temporary, significant => true, shutdown => 5000, type => worker,
               modules => [erx_pixels]},
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant}, [Pixels]}}.
