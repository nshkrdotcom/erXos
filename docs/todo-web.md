# TODO: Web client and host link

Open work on the web client and the host tool's web server. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Stopgap replacements

* [Medium] web, the connection side of the line (`erlang/apps/erx_web/src/erx_web_conn.erl`, `perform/2`;
  `erlang/apps/erx_web/src/erx_web_relay_conn.erl`, `remember/2`): `erx_web_conn` is documented as a pure state
  machine but `perform/2` calls the line, monitors and sends; move it to a driver module of its own. The relay
  connection keeps a second map from view pid to view beside the core's, filled outside the core, and its close
  is an `exit(normal)` inside a closure; have the core own the lookup by pid (`update_from`, `ended_from`, `down`
  inputs) and make the close an explicit clause. `perform/2` also takes any pid the line answers as a view;
  require the line's domain (`erx:owner/1`).
* [Medium] `erlang/apps/erx_web_line/src/erx_web_value.erl`, [Values](design-web.md#values): a huge integer's
  `leading/1` (a power of ten and a bignum division) costs 110-160 ms for the largest bignum and is charged only
  its 4 KiB print, so about 15 of them fit one projection, about 2 s of the session's CPU per update (13 copies
  measured at 1.5 s). Charge the work, or reuse one `10^Dropped` per byte length within a projection, and time
  15 separate huge integers in `erx_web_value_tests`.
* [Medium] `erlang/apps/erx_web_line/src/erx_web_value.erl`: a printed map's copy is rebuilt with `maps:from_list`, so
  its print order can differ from the term's: a map of more than 32 keys cut to 32 or fewer prints sorted where
  the term prints in hash order, and a huge integer key shortened by `leading/1` can sort before a smaller key.
  Copy a map as its pairs in the term's own print order, with a property test comparing the copy's print with
  the term's.
* [Low] `abi/protocols/web.txt`, [URLs](design-web.md#urls): `web_segment_max` (256) bounds a path segment,
  which is an encoded `/proc` entry name, while `erx_procfs_core` admits names of up to 765 encoded bytes (255 bytes,
  each `%XX`); so an entry whose encoded name is longer than 256 bytes has no route or link in the client
  (`web/src/routes.ts`), and the browser cannot open it. Raise the bound to the longest encoded name, or state the
  limit in the design.
* [Medium] `config/manifest/qemu-virt-development.txt`, the web domain's row: its 24 MiB and its grant, 150
  mcpu, are estimates, and so are the development manifest's `root_memory` and the system
  principal's memory that make room for it; no boot-time or memory figure has been recorded for a boot with the
  web domain. Measure the domain with `Footprint` at rest and with the host tool's four connections open, the
  boot's time to the shell before and after the web domain (`tools/erx bench`), and size the row and
  `root_memory` from the figures.
* [Medium] `erlang/apps/erx_web/src/erx_web_conn.erl`, W8 in [Requirements](design-web.md#requirements): a
  browser's `event` messages have no flow control. Each becomes one message to the UI's renderer, so a hostile
  browser can fill the renderer's mailbox as fast as its connection carries bytes, while W8 bounds what one
  browser makes the machine hold. Bound the events in flight per UI view (the renderer acknowledges each, and
  the core drops an event while one is unacknowledged, or keeps a small credit), in the design first.
* [Low] `abi/protocols/web.txt`, [The protocol](design-web.md#the-protocol): an `event`'s and an update's
  `ui_record` is any ui.txt record of its length; each consumer must run ui.txt's reader on it. Calling the
  generated event reader inside the codec would make "an accepted event is an event" hold by construction.
* [Low] `abi/protocols/web.txt`, [Interfaces](design-web.md#interfaces): the fixed response headers and each
  file kind's content type, and the header table generated for Erlang and Ruby, are not declared yet. The host
  tool's front end holds their one copy (`Erx::Web::Http::SECURITY` in `tools/lib/erx/web_http.rb`,
  `Erx::Web::Inventory::TYPES` in `tools/lib/erx/web_inventory.rb`); declare them before `erx_web_cowboy` writes a
  header, and generate both front ends' tables.
* [Medium] `tools/lib/erx/web_server.rb`, [The host tool's front end](design-web.md#the-host-tools-front-end):
  every call on the web facet (`connect`, `data`, `close`, and `open`'s hello) is a blocking `HostlinkClient#call`
  inside the one select loop, so a slow or rebooting machine stalls every connection for up to the call's 10 s
  (files, pings, the other WebSockets), and each browser message costs one host-link round trip during which the
  others wait. Send calls with `send_call`, match replies by id in the loop, and keep a pending-connect state per
  upgrade (the 101 goes out on the `connect` reply), so the loop never waits on the machine by construction. The
  same change removes the casts a call collects waiting up to 1 s for the next select.
* [Low] `tools/lib/erx/web_server.rb`: when the host link's socket itself ends (QEMU exited), every later upgrade
  fails with `Relay::Down` and prints a line, and the server serves files and 503 forever; exit with a diagnostic
  on the socket's end, or reconnect to `--socket PATH`, and rate-limit the line.
* [Low] `tools/lib/erx/web_http.rb`, `Http.file`: every file but `index.html` is sent `immutable`, on the
  design's rule that `make web` names each `<stem>-<first 16 hex digits of its SHA-256>`, which `Inventory` does
  not check; check it there, or send `no-store` for a name without the hash. A refusal of a request that carried bytes
  after its head (a 405 for a POST with a body) closes with unread input, so the kernel's reset may cost the
  client the answer; shut down writing and drain briefly before closing.
* [Medium] `web/src/connection.ts`, [Failure handling](design-web.md#failure-handling-diagnostics-and-debuggability):
  a view the machine ends `closed` is not reopened, as the design's recovery says, until the socket drops; view
  numbers are fixed per target, so a reopen needs a per-connection counter of numbers, and a rule for which end
  reasons reopen and how often, so a view that crashes at once is not reopened at the network's pace.
* [Medium] `web/src/connection.ts`, W7: the browser sees no ping, and a record view is silent while its record does
  not change, so a half-open socket (a laptop's sleep, a dropped NAT entry) shows the last record as current with no
  "stale since"; the network front end needs a heartbeat the client sees and a client timer that ends the socket.
* [Low] `web/src/connection.ts`, [Failure handling](design-web.md#failure-handling-diagnostics-and-debuggability):
  after `bye protocol` the design says the client reloads; the core reconnects, and a welcome resets its delay, so a
  disagreement on a rule reconnects every second. An update whose body is not the target's kind (`entries` for a
  `path`) is handed to the page, which ignores it and never asks again; check the kind in the core and close.
* [Low] `web/src/record.tsx`, [The client](design-web.md#the-client): the record view has no unit column, and
  its presentations are text, not links; they need the inspection schema's units in the generated tables and the
  routes of presentations served by views.
* [Low] `tools/lib/erx/web_build.rb`, [The client](design-web.md#the-client): the bundle's notices file
  holds esbuild's legal comments, and React's say only that the MIT license is "found in the LICENSE file", which
  the bundle does not carry; add each bundled package's LICENSE text from the store before the client's files are
  distributed, by the web domain's release or the website's demo image.
* [Low] `web/test/browser`, W6 and W7: the client has no trace page and no view but the home record, so the URL
  test can only find that no form opens a trace, and the stale test covers one view; extend both as the views land
  (a reconnect with the trace page open, every open view marked stale, a ring overrun's gap).
* [Medium] `tools/lib/erx/web_build.rb`, `build`: esbuild and tsc resolve a bare import through any `node_modules`
  above the stage (the worktree, the home directory), so an import of a package missing from `web/package.json`
  can bundle an unpinned package found there. Run esbuild with `--metafile` and refuse any input outside the
  stage's `src/` and the lockfile's packages under `build/web-modules/node_modules/.pnpm/`.
* [Low] `web/test`'s install tests (`test/host/web_build_test.rb`): they install offline from `build/web-store`, which
  pnpm 12 allows only while its per-user `lockfile-verified.jsonl` holds a pass for the lockfile (an online fetch by
  the same user writes it); on a host or user without it they fail with `ERR_PNPM_NO_OFFLINE_META`. Use
  `trust-lockfile` in the tests' installs or install them online.
* [Low] `tools/lib/erx/web_build.rb`: the stage copies untracked files of `web/` (a stale `out/` whose files
  `build` would publish); stage only tracked sources and have esbuild write outside the stage. Two builds in one tree share `build/web-stage` and
  `build/web.next`; take a lock as `Generated` does.
* [Low] `docs/design-web.md`, Dependencies: React 19 ships no types, so the views' `.tsx` need `@types/react`
  and `@types/react-dom` (MIT, DefinitelyTyped) for `tsc --noEmit`; list them beside React when it lands.

## Bugs by subsystem

* [Medium] host link trees, `erlang/apps/erx_uart/src/erx_hostlink_files.erl`
  (`tree_grant/3`): the link serves any grant entry of the system domain's table whose tree a
  configuration's `files_trees` names, so with the own mounts a configuration that names
  `machine` or `apps` would hand the host the right to end the machine as root and to start
  and stop apps. No default names them (`default_trees/1`); make the served set an explicit
  list of trees designed for the host, or refuse those two.
* [Medium] security, host-link session identifiers
  (`erlang/apps/erx_uart/src/erx_hostlink.erl`, `entropy/0`): a session
  identifier is `rand:bytes/1` under the seed `rand` takes from the time and
  the node, which the design accepts only in trusted development modes. Draw
  it from `erx_bytes:entropy/1`
  ([design-runtime.md](design-runtime.md#per-byte-primitives)), which
  takes the generator's bytes through `erx_entropy_take`.
* [Medium] security residual, host link's 9P bridge
  (`erlang/apps/erx_uart/src/erx_hostlink_files.erl`, `tree_grant/3`):
  the bridge uses the system domain's own grants and its tags bound, 64,
  equals a grant's whole 64 requests in flight, so a host that keeps 32
  slow reads and their flushes at the `data` grant makes that grant refuse
  the system domain's own processes with `emfile`; a grant of the bridge's
  own, or a per-grant cap below 64, closes it.

## Security residuals

* [Medium] Web view scope, root's session through the host link's `web` facet
  (`erlang/apps/erx_uart/src/erx_hostlink_web.erl`, `erlang/apps/erx_web_line/src/erx_web_line.erl`;
  [design-web.md's Security](design-web.md#security)): once the host link's `web` facet holds root's
  session's line, every view a browser opens reads at scope `all`, so a browser reaches the machine-wide paths
  (`/proc/kernel`, `/proc/cpus`, the kernel log, the machine record's `all` attributes), as the session's own
  `/proc` does: the system domain's query worker answers each of them through the session's inspect facet, at
  that facet's scope.
  Development builds run trusted code only. The wide scope is accepted; narrowing it to root's own
  domains, or removing it, changes design-live.md ("Scopes"), design-web.md (W1) and design-domains.md
  (property 9) with it, and needs a test that a browser's view of `/proc/kernel` ends `scope`. The
  system domain asks for a session's web line with `erx_domain:line/4`, and today only the host link's `web`
  facet (`erx_hostlink_web`) does, for root's development session: the network login (`erx_web_login`) must not
  hand its sessions' lines the same scope. The facet the session item under Bugs mints, taken by `erx:cap(inspect)`,
  is the better source of the scope. Not yet consistent at `all` in a
  session's runtime: `[domains, 4, threads]` through `entries/2` is gated only on the domain, not on the runtime
  (`erx_inspector:collects_domain/2` covers `collect/2` alone), and `/proc/cpus` answers a partial empty
  listing where Fiasco refuses a task's `erx_object_info`, which `erx_kernel_records:listing/6` should
  answer `unsupported`.

* [Medium] Host link, the web facet's casts (`erlang/apps/erx_uart/src/erx_hostlink_web.erl`,
  `erx_hostlink.erl`): each `{web, C, Bytes}` the web domain sends the facet becomes a `facet_cast` to the host
  link's process, which queues it for the host outside the output bound that holds back input (`OUTPUT_BACKLOG`),
  so a compromised web domain can grow the system domain's memory by sending faster than the host link drains
  (the facet's and the host link's queues have no heap limit), until the system domain runs out of memory,
  which resets the machine. Phase 1 runs trusted code only (M11). Count casts against the same output bound,
  dropping or ending the facet when it is full, with a host test that floods the facet.

