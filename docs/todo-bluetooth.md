# TODO: Bluetooth

Open work on the Bluetooth host and controller, GATT and the security manager. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Bugs by subsystem

* [Medium] Bluetooth line, held `data` writes (design-bluetooth.md, "The controller's line"): a write the line has
  handed `erx_pl011` while the controller holds CTS off under `rts_cts` flow waits on the device with no deadline, so its
  flush, its fid's clunk and the drain of a grant whose Bluetooth domain ended wait until the line's next `reset`, which
  an idle domain, or one ended past its restart intensity, never sends. Give the driver's write a deadline that ends the
  driver and answers `eio`, or bound it by the controller's 5 s command deadline.
* [Low] bluetooth, one line keeper by construction (`erlang/apps/erx_uart/src/erx_uart_sup.erl` `members/0`):
  `erx_facet:serve/2` replaces an earlier name, so two line keepers would silently leave `line` to the last started. `members/0`
  refuses two line records of one peripheral but takes a pl011 and a virtio_mmio line record together; only `check_line_grants`'
  one-grant limit, the root's record for the granted device alone and `check_serial_devices` keep it to one. Refuse more than one
  line record across both peripherals.
* [Low] bluetooth suite, the domain's memory (`tools/lib/erx/bt_domain.rb` `MEMORY`): 32 MiB is unmeasured. Measure it at rest as
  `PcieDomain`'s memory note does (`MediumBoot::Footprint`) and size the row from that.
* [Low] bluetooth suite, the two unverified QEMU facts (docs/design-bluetooth.md, "Sources"): whether bytes arriving with no
  receive buffer posted are held or dropped, and whether a device reset drops what the chardev holds. A stand-in controller that
  writes before the driver's start and across a `reset` settles them.
* [Low] bluetooth suite, the controllers' log has no size bound (`BtDomain::Controllers`): the DEBUG log records every HCI
  packet until the deadline.

## Security residuals

* [Medium] bluetooth, the line's request clauses (`erlang/apps/erx_uart/src/erx_line.erl`, `take/3`;
  design-bluetooth.md, "The controller's line"): a request of no known kind is a `function_clause`
  crash of the line, whose reason carries the state raw. Fix: a refusal in `take/3` of a request of
  no known kind.
* [Medium] bluetooth, ACL packets on the line at a disconnection (`erlang/apps/erx_bt/src/erx_bt_hci_core.erl`,
  the Disconnection Complete clause of `event/2`; docs/design-bluetooth.md "Commands and data credits"): a
  Disconnection Complete drops the handle's packets still waiting for the writer and its disconnect, but the packet
  the writer holds, and packets written that the controller has not yet read, are already on the line; if the
  controller has given the handle to a new peer by the time it reads them, they reach the new link. (A disconnect
  handed to the writer and unanswered cannot: a connection on its handle ends the controller process.) The link
  slice cannot narrow it: the link's envelope already ties every request to its connection inside the host, and
  below the core an ACL packet carries only its Connection_Handle and flags (Core 6.3 Vol 4 Part E, 5.4.2). The
  window rests on the controller: Part E 5.3 asks it to give a new connection an unused handle, or the least
  recently used, and not to reuse one while anything tied to it may still exist. Narrowing it on the host needs a
  mechanism the design does not name, such as a fence: on H4, where commands and ACL packets share one byte stream,
  the answer to the first command written after a handle's last packet would show the controller has read the packet
  (unverified: HCI orders neither path against the other; a probe settles it), and a connection on the handle before
  that answer ends the controller process. Even that cannot close it, since the controller may give the handle a new
  peer before it reports the connection. Question for the design: rely on Part E 5.3 and check the board's
  controller's handle reuse with a probe, or add such a fence. A cheap narrowing for host-initiated disconnects
  alone: refuse a link's packets once its handle's disconnect is asked.
* [Low] bluetooth, `forget ADDRESS` and the address type (`erx_bt_store`'s `{forget, Address}`, `erx_bt_fs_tree:parse/1`;
  docs/design-bluetooth.md "Bonds and the store"): `ctl` names a bond by its six octets alone, as the `pair` lines
  print it, and the store forgets every bond with them, so a phone that distributed `{random, X}` beside a bond of
  `{public, X}` is forgotten with it, and the operator cannot tell the two apart. Either state that `forget ADDRESS`
  forgets every bond with those octets, or add the type to the `pair` lines and to `ctl`'s grammar.
* [Low] bluetooth, the window's copy of the store's refusal (`erx_bt_window`'s `refusing`, `erx_bt_fs:start_link/0`): when
  `erx_bt_fs` alone restarts, a grant of the old instance that the grants' supervisor has not yet killed can confirm a
  `forget all` after the new instance read `known()`, so `pair` answers `eio` until another `forget` or a store restart
  (safe: a refusal). Closing it by construction: the store sends the window the confirmed `forget`, as it sends
  `{outcome, ...}`, and the window reads `known()` in `init/1` after registering.
* [Medium] bluetooth, the store's development file has no grant (`erx_bt_store:start_link/0`,
  `erx_bt_state_file`; docs/design-bluetooth.md "The Bluetooth domain", the store's grant): the design gives the store a
  files service of its own that the storage domain roots at the data volume's `bt/` and grants to the Bluetooth
  domain alone, as it serves SSH's `ssh_state`, but neither service is built: `abi/manifest.txt` names no
  `bt_state_service` (nor `ssh_state_service`, which design-ssh.md cites), no manifest grants either, and the manifest check does not hold the `bt` row to it. So the store reads the
  application's `state_dir`, by default `/data/bt`, and a domain whose namespace lacks it runs
  `store_unavailable`, without bonds; `get` answers `none` when `/data` exists, so an unmounted volume presented as
  an empty `/data` would read as no bonds. Build both services as one package: the files services, their two `abi/manifest.txt` names, the grants, the check, and the store mounting its grant.
* [Low] bluetooth, a forgotten bond's keys can stay on the development store's medium (`erx_bt_state_file`):
  until the next successful put, a late put that landed below the newest, or a lower file a deletion missed,
  keeps a forgotten bond's keys on the medium (0600, in a 0700 directory), though never read.
* [High] bluetooth, security residual that blocks the release store: the vault's state slot takes no generation
  (docs/design-system.md "State slots"; docs/design-bluetooth.md "Bonds and the store"): the store's seam is
  `put(Generation, Blob)` and `get() -> {ok, Generation, Blob | none}`, so a put cut off by its deadline that
  completes after a later one never wins, but the state slot's `put(Blob)` replaces the blob whatever arrives last,
  which brings a forgotten bond back. Give the slot a generation in design-system.md: a put not strictly above the
  kept generation is refused, and a get reflects every put the domain sent before it.
* [Low] bluetooth, a late put after a store restart rests on the worker's blocking (`erx_bt_store`'s backend
  worker; docs/design-bluetooth.md "Bonds and the store"): that a dying store's worker sends at most one more
  request once the store's exit signal is in its queue holds because the BEAM handles the kill at the worker's next
  receive and its file calls block one at a time, not by construction; an old worker's create and rename both
  after the new store's listing would land above it.
* [Low] bluetooth, the reconnection's Security Request against the specification (`erx_bt_link_core`'s
  `security_request/3`; docs/design-bluetooth.md "Reconnection"): whether sending a Security Request starts the
  Security Manager Timer (Core 6.3 Vol 3 Part H, 3.4) is unread, so the link starts none and a phone that never
  answers is simply left as it is. Read 3.4 and 3.6.7 and pin the request against the Bumble test peer. The
  request is queued droppable, as SMP's other frames are, and never retried, so a queue full of notifications'
  frames at that moment loses it; the design does not say whether it must be kept.
* [Low] bluetooth, the codecs compared with Bumble (`test/host/erx_bt_bumble_test.rb`; docs/design-bluetooth.md
  "Fuzz targets"): the corpus is one hand-written frame per PDU, event and signaling code with its one-octet cut
  and extension, and the 256 ATT opcodes, not the fuzz targets' corpus the design names. The fuzz targets
  (`test/erlang/erx_bt_att_fuzz.erl`, `_smp_`, `_hci_`, `_link_`) make their frames at random inside
  unexported generators and keep no seed files; feeding the comparison from them needs those generators
  exported and seeded the same on both sides.
* [Low] bluetooth, octets past an HCI event's parameters (`erx_hci:event/2`, `return/2`; `test/bt/differences.txt`):
  erx_hci matches each event and bring-up return against its layout whole, so a controller that appends a
  parameter stops the HCI core (`erx_bt_hci_core`) where Bumble ignores it. Core 6.3 Vol 4 Part E, 5.4.4 gives
  each event a specific number of parameters; whether a host must refuse or ignore octets past them was not
  found. Settle it from the specification before the board run, and change erx_hci or the entry's reason.
* [Low] bluetooth, the Bumble environment's packages (`tools/lib/erx/bumble.rb`): only pyee and
  typing_extensions are pinned. `apps/pair.py`, `apps/gatt_dump.py` and `apps/scan.py`, which stages 2 and 4 of
  the hosted suite run, import click; pin its wheel in `deps.lock` and `Bumble::WHEEL_IDS` with the first of them.
* [Low] bluetooth, the GATT declarations' smaller gaps (`Erx::GattDecl`, `erx_gatt_db`): the one level of a
  Client Characteristic Configuration rests on the generator's refusal of `notify` and `indicate` at different
  levels, not on `erx_gatt_db:service()`, which could carry one `subscribe` level instead (the registry's
  `limits()` reads the same `access` map); the names `gap` and `gatt` are written both in `erx_gatt_db` and in
  the generator's `RESERVED_NAMES` (naming the table's own services outside the declarations' lower-case
  names would delete the list, but the bond store's `erx_bt_state:name/1` admits only lower-case names); the
  blocks 0x2800-0x28ff and 0x2900-0x29ff the generator refuses as GATT's attribute types are unverified
  against Assigned Numbers; and a
  characteristic may notify at a weaker level than it is read at (`read authenticated notify open`), which the
  design neither refuses nor states.
* [Low] bluetooth, the ATT server's smaller gaps (`erx_gatt_server`, `erx_gatt_db`, `erx_att`): Execute Write
  joins parts from an empty value, so a client rewriting the tail of an existing value gets Invalid Offset (ATT
  3.4.6.3 measures from the current value); a second `indicate` in flight answers `busy`, which the facet's
  table lists only for notifications, so the link must queue indications or the design list `busy` (a
  reconnection's Service Changed in flight makes a handler's first indication `busy` too); the Bluetooth
  Base UUID in `erx_att:uuid128/1` and in the GATT declarations' generator (`Erx::GattDecl::BASE_UUID`) is
  Bumble's, unverified against Vol 3 Part B 2.5.1, and the case that uses it is circular; the bearer exploration checks response counts but not
  which request a response answers, and the ATT fuzz target runs at security `none` and checks at most one
  answer rather than exactly one.

## Planned features

* [Medium] bluetooth, the line's service side (docs/design-bluetooth.md "The controller's line"): the keeper, `erx_line`,
  serves its tree's grants as the system domain's `line` service (`erx_facet:serve/2`, with its seeded fault in
  `test/host/erx_line_test.rb`), under the development manifest's `service line`, ungranted; the line grant's device is a
  UART or, on QEMU `virt`, `erx_virtio_console` over the line unit's `/virtio_mmio@a000e00`, and the Bluetooth suite runs the
  domain over it against Bumble. Still open: the one name `line` as a generated fact (`abi/services/line.txt`, as
  `packages_service` is in `abi/manifest.txt`; today a literal in the manifest check, the serve call, the facet-names check,
  `check_line_grants` and the grantee's mount `erx_ns:place/1`); the power line's two ends, which `erx_line` and
  `erx_uart_sup` call but nothing provides yet, so every line runs a reset's steps 1 and 5 alone, as on a platform with no
  power line: the off and on times in the line's physical record (`boot_manifest.c` writing them from the power row,
  `erx_device_record` reading them as `power => {Off, On}`), and the device service's `erx_devices:power/2` over
  `erx_domain_lib:device_notify/2` through the firmware worker (docs/design-bluetooth.md "The power line", "Authority");
  the one-grant limit (`check_line_grants` in `tools/lib/erx/manifest.rb`
  accepts at most one `line` facet, since the design leaves open how the one process `erx_facet:serve/2` names reaches the
  tree of each grant when several grants name different UARTs; settle that and lift the limit); the root's names, which still
  say `line_uart` (`boot_manifest.c`) for what is now any line device's row; the driver's played-device cases (add cases over
  `test/erlang/stand_in/erx_device.erl` for input reaching the owner and the buffer posted again, a write answered only after
  its last buffer is back, and a broken queue stopping the driver); and the stage 1 peer (scanner) cases of the design's table.
  The Bluetooth domain and its grant stay out of the development manifest (docs/plan.md).
* [Medium] bluetooth, the line device's record (`liberx/backend/core/boot_manifest.c`, `tools/lib/erx/manifest.rb`
  `check_serial_devices`): the `serial` kind row makes the root write a given record for every placed serial device,
  so rule serial-device-granted refuses an ungranted one by exclusion. Choosing the line's record by the grant's index
  from a line-kinds table (the PL011's and the virtio console's rows), as `line_kind` is chosen, would give an
  ungranted serial device no record and delete the rule, and would put the line's device-to-driver facts in one
  table instead of four (`line_kind`, `erx_uart_sup` `members/0` and `driver/2`, `check_line_device`,
  `physical_paths`). Also: `check_line_device` checks the role only, so a serial or UART row of a compatible no
  kind row has passes and gets no line (refuse a pair that is not a kind row); a serial device on a shared
  interrupt line never binds (no owner is started for it) and is not refused; no `boot_manifest_test.rb` case
  asserts the given `line virtio_mmio` record for a serial grant; the root's names still say `line_uart`.
* [Medium] bluetooth, line groups couple the host link to the line tree at the limits
  (`erlang/apps/erx_uart/src/erx_uart_sup.erl`): each level (top, group, services) allows 3 restarts in 60 s, so a
  line tree's crash loop exhausts its `services` supervisor, whose restart restarts the host link and ends its
  session, and then the group, `erx_uart_sup` and the permanent `erx_uart` stop and the machine resets; and a line
  tree that fails to start (an `erx_pl011` refusal, an attach or open error, `erx_domain_lib:configured/0` failing,
  or a root record `line_grants/1` does not find, which `fresh/2` takes as a bare badmatch) fails `erx_uart`'s start,
  so the host link never comes up to debug it. Decide whether a line tree's failure may end the machine; if not,
  let a line tree's give-up end only that line (a `temporary` child, or a significant child with `auto_shutdown`),
  and fail a line's start with a stated reason that leaves the host link running.
* [Medium] bluetooth, `erx_pl011`'s start effects (`run/3`, `discard/2`): `program/1`'s step lists are tested, but no
  test runs the steps over the device stand-in (`test/erlang/stand_in/erx_device.erl`), so a drain that ignores `RXFE`
  or its bound, or a step sent to the wrong register, passes; trace `keep` against the sequence it replaced and the
  drain's two stops. With it, [Low]: between a line driver's end and its fresh start, through a reset's off wait,
  and after a reset that fails, the UART keeps the old driver's `IMSC`, so a controller's bytes raise a line it shares with the host link with no
  driver to clear them; the old driver could mask it as it ends.
* [Medium] bluetooth, the line keeper's shape (`erlang/apps/erx_uart/src/erx_line.erl`): its decisions and effects
  (the driver's sends, `exit/2`, the answers) are made in the same steps, so its tests are hand-picked cases rather
  than an exhaustive exploration of reads, writes, resets, input, flushes and ends; split it into a pure core that
  returns actions, as `erx_bt_hci_core` is, and explore it. With it: the reset waits for the old driver through the
  link the start makes rather than a monitor it takes, the fresh driver's start blocks the keeper while it programs
  the UART, and the heap bound's slack (`start_link/2`) is a round number, not derived from the grant's largest write.
* [Medium] bluetooth, `erx_bt_sup`'s restart intensity (`erlang/apps/erx_bt/src/erx_bt_sup.erl`;
  docs/design-bluetooth.md "Concurrency" and "Failure handling"): the design gives none, so OTP's default of
  one restart in 5 s applies; a controller group that exhausts its own 5 restarts in 60 s about every 30 s is
  restarted by `erx_bt_sup` each time, and the domain never ends as the failure table says. Making the group
  `significant` with `auto_shutdown => any_significant`, or a chosen intensity, settles it in the design first.
* [High] bluetooth, the `ble` facet's side in other domains (docs/design-bluetooth.md "The `ble` facet",
  "Declarations: `abi/gatt`"; `erlang/apps/erx_bt/src/erx_gatt_srv.erl`'s `facet/4`): the registry takes a
  facet's operations through `facet/4`, with the grant's services and the caller, but no app reaches it.
  Missing: `abi/services/ble.txt`, whose `services` parameter needs a manifest checker (`ble_grant` in
  `tools/lib/erx/manifest.rb`) refusing a service no file declares, one two rows name, two served services of
  one UUID, more than `gatt_services_max`, and advertising data that do not fit; the facet process the
  registry makes when the domain service introduces a grantee, with its mint and an admission module that
  alone takes `{erx_origin, D, Msg}` off and bounds each operation, as `erx_net_admit` does, with its fuzz
  target; the client `erx_gatt`, which takes the events' envelope off, and the `erx_gatt_service` behaviour;
  and the served services read from the manifest's rows, where `erx_bt_sup` serves every declared service.
  `facet/4` trusts the grant and the caller it is passed on every call; the facet should instead be made by
  the registry, which records its grant, so an operation names the facet and the grant check holds by
  construction. Whether a handler in another domain can be monitored from here, or the facet is the party
  the registry monitors, is unverified.
* [Medium] bluetooth, what a handler hears (`erx_gatt_registry`; docs/design-bluetooth.md "The `ble` facet"):
  `write` and `subscribed` name the characteristic without its service, though a handler may handle several
  services whose characteristics share a name; and a handler that attaches while a phone is connected hears
  `connected` but not the link's MTU or its subscriptions, which the registry does not keep, so an app
  restarted mid-connection answers `not_subscribed` until the phone reconnects. Settle both in the design:
  the key in the events, or one service a handler; and what `attach` replays.
* [Medium] bluetooth, a store restart detaches every handler (`erx_bt_sup`; docs/design-bluetooth.md
  "Concurrency"): the tree's order is store, registry, group under `rest_for_one`, so a store crash restarts
  the registry, which loses every attachment, and no handler hears of it. The registry depends on the store
  for nothing; put it first, or tell handlers of a registry restart, in the design's tree.
* [Medium] bluetooth, advertised UUIDs (`erx_bt_hci`'s `config/0`; docs/design-bluetooth.md "Advertising"):
  no GATT table (`erx_gatt_srv:advertised/0`) exists, so no service UUID is advertised; stage 1's advertising
  needs the table's declarations brought forward from stage 2.
