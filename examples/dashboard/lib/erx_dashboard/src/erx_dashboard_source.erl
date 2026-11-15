%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_source).
-moduledoc """
The seam between the dashboard and where its quotes come from: the
behaviour a quotes source implements and the board it hands the
dashboard. The dashboard knows nothing of a source but this module, so
the offline sample (erx_dashboard_sample) and a source that fetches
quotes over HTTPS (docs/design-quotes.md) are interchangeable by the
application's `source` environment value alone.

A source is started by the dashboard's process with start_link/1 and
sends that process

    {erx_dashboard_board, Board}

each time its board changes; the dashboard shows the last board it got.
A source that has nothing more to send after its first board answers
`ignore`; one that keeps working answers `{ok, Pid}` with a process
linked to the dashboard, so the two restart together.

A board is the source's credit, the line the screen shows under the
panel's title to say where the numbers come from, and its quotes in the
order the screen lists them. A quote's price is in its own currency and
its change is the percent change the source reports, each a number the
source computed; the dashboard formats both and shows no text of a
source's but its symbol, name and credit. A source hands only boards it
has checked: `decimals` within 0 to 8, symbols unique, and texts valid
UTF-8 within the widget format's bounds; the view checks nothing again.
A board carries no fetch time, so a live source that can go stale needs
the per-quote value and age of docs/design-quotes.md first.
""".

-export_type([board/0, quote/0]).

-type quote() :: #{symbol := binary(),
                   name := binary(),
                   price := number(),
                   change := number(),
                   decimals := 0..8}.
-type board() :: #{credit := binary(), quotes := [quote()]}.

-callback start_link(Dashboard :: pid()) -> {ok, pid()} | ignore.
