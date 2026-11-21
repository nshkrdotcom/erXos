%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_srv).
-moduledoc """
The registry's calls (docs/design-bluetooth.md, "The `ble` facet" and "The link's
start"). The registry is the process registered as `erx_gatt_srv`, which maps each
`Conn` to its link, monitors the link and tells the services' handlers of it. Only the
call a link makes at its start is here; the registry's process is in TODO.md (Bluetooth),
and until it runs a link's `join` fails and the link ends.
""".

-export([join/2]).

-doc """
A link joins the registry at its start: the registry maps `Conn` to the calling link,
tells the handlers `connected` at level `open` and not bonded, and answers the table and
the values the handlers last set. It takes `join` and `set` in one order, so every `set`
after the values it answered reaches the link.
""".
-spec join(reference(), #{address := erx_smp_crypto:address()}) ->
          #{table := erx_gatt_db:table(), values := #{erx_gatt_db:key() => binary()}}.
join(Conn, Info) ->
    gen_server:call(?MODULE, {join, Conn, Info}).
