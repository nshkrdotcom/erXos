# TODO: Network

Open work on the network stack (`erx_net`), WiFi and HTTPS clients. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [High] network, the fast path
  ([docs/design-network-stack.md](design-network-stack.md#the-fast-path)): one connection over
  the FreeBSD test host's tap sends at 890 Mbit/s and receives at 1,143, against lwIP's 6,537 and 6,809 on the
  same tap, held there by the connection's per-segment step. The targets are two thirds of
  lwIP's bulk throughput each way over the same medium, and for request-reply a third of
  lwIP's rate at no more than three times its CPU per transaction. Each package lands with
  the FreeBSD bulk and request-reply numbers before and after it, and the HVF numbers when it
  changes erXos's code; the gains are estimates from the profile, to be replaced by those
  numbers:
  1. the benchmarks, `tools/erx bench net-freebsd` (bulk and request-reply on the FreeBSD test host, erx_net and
     lwIP, with its counters' hook: the interface's `runs`, `run_frames`, `units`,
     `unit_segments` and `frames_dropped` totals, reported unsupported until it keeps them)
     are in the tree; what remains is the bulk and request-reply benchmarks under HVF,
     which need a TCP peer on QEMU's medium (the Linux oracle guest is not built yet); no
     gain, it fixes the baseline;
     * [Medium] the bulk and request-reply benchmarks under HVF: no TCP peer on QEMU's
       medium yet (the Linux oracle guest is not built; the harness's virtio-net hub carries
       raw frames to a Ruby harness, and slirp's guest forward carries the `net_device`
       suite's TCP to a Ruby echo server over one host stream, and its host forward one
       connection from the harness to the guest's listener, which check the guest's TCP
       but are no benchmark peer), and `bench/erx_net_bench.erl` has to be loaded into the guest shell as
       `BenchGuest` loads its module. The Linux-guest baseline stays unsupported until then.
     * [Medium] `erx_net_if_core` counters: the map keeps only counters that were
       incremented, so "kept, zero" reads as "unsupported" in `tools/erx bench net-freebsd`.
       The packages that add `runs`, `run_frames`, `units`, `unit_segments` and
       `frames_dropped` must make `admin(counters)` return every counter they keep, zeros
       included; the fast-path check is `--require-fast-path` until then and becomes the
       default (`docs/design-network-stack.md`, "Benchmarks and targets") once they exist.
     * [Medium] `net_bench_freebsd.rb`'s remote lock: a stale lock's takeover is check then
       act (two runners can both take it); an interrupted run releases it while its remote
       peer and client live on to their own deadlines; `run_deadline` leaves out the ssh kill
       grace, the conditions' remote calls and erlc and rsync, so a slow live run can be judged
       stale. FreeBSD `lockf(1)` held from one ssh for the whole run would remove all three.
     * [Low] `net_bench_freebsd.rb`: lwIP's source trees on the FreeBSD test host are not hash-checked per run;
       erlc, git and rsync run without a deadline; the peer's start is a fixed wait, not a ready line; the stacks' repeats
       run in blocks, not interleaved; the p99 is the nearest rank plus one in both
       clients; bulk send differs between the clients (nodelay and 64 KiB against Nagle and
       32 KiB), as the report's conditions state.
  2. one step per mailbox and a batch on every hop are in the tree; on the FreeBSD test host (median of 3,
     against the baseline) bulk receive went from 1,160 to 1,850 Mbit/s, while bulk send
     (903 to 900) and request-reply (64 B 15,661 to 15,521 txn/s, 1 KiB 14,574 to 15,132,
     64 B x16 81,376 to 78,159) did not move: the send side waits for the lean step
     (raw data: ~/erxos-history net-bench-freebsd-fast-p2-2026-11-09, commit d5bcd46);
  3. the lean step: `#tcb{}` split from `#tcb_conf{}`, header prediction finishing its two
     cases, the header template, the send log of runs with its extension rule: the
     connection's time per segment from 12.3 us to 3 to 4 us, and throughput about 1.3 to
     1.5 times until the driver binds;
     * the send log of runs and header prediction's finished cases are in the tree, and
       `erx_tcp_wire:add_options/1` writes a run's two option layouts (none, `NOP NOP TS`)
       directly instead of through `tcp_addoptions`' fold, which output, the frame layer and
       `encode/3` each ran for every segment. The `#tcb{}`/`#tcb_conf{}` split remains, and
       so does the header template itself, the IP and TCP headers with their options encoded
       once per connection: its full gain comes with the runs and the cut, when the frame
       layer writes no header bytes per run. Before them it would save per segment only the
       IP header's build (`erx_net_frame:output/6`'s map, `erx_ip4:output/4`'s checks and
       encoding) and the pseudo-header sum, which no measurement backs yet; measure a hack
       that skips them for a don't-fragment segment that fits the MTU before building the
       template ahead of the cut.
     * [Medium] `erx_tcp_input_ack_tests` (header prediction's property): its generator
       never sends in-order data larger than the receive space, so a header prediction
       that takes such data is not caught there; the precondition's seeded fault is the
       closed owner instead. Add data sizes past `rcv_space` to the generator.
  4. the tap transport, `erx_tap` and its NIF, replacing `erx_net_tap` and the pipe's
     `port` end, landed (against package 2's tree, the FreeBSD test host, median of 3): bulk send 900 to
     1,040 Mbit/s, bulk recv 1,850 to 1,837, rr 64 B 15,521 to 16,150 txn/s, 1 KiB 15,132
     to 17,596, 64 B x16 78,159 to 89,986. Its one-call receive batches exposed a stall in
     `erx_tcp:settle/3` (a waiting writer moved in after output), fixed with it (raw data:
     ~/erxos-history net-bench-freebsd-fast-p4-fix-2026-11-09, commit d5bcd46);
  5. checksums in the copy
     ([design-network-stack.md](design-network-stack.md#checksums-in-the-copy)), built as part of the fast path, since the cut and the merge rest
     on it. The receive half is in the tree: `erx_inet_copy_sum` in `erx_inet_csum.c`, whose
     two-words-a-step loop `erx_inet_sum` shares and whose loads an empty assembly statement
     keeps single, with its harness cases, mutants and the `inet_csum` fuzz target's copy
     case; `erx_net_sum`; the sum argument of the decoders above IP; `erx_net_input`'s `{frame, Bytes, Sum}`, checked
     against the unsummed path by its EUnit cases and its fuzz target; and the tap NIF's
     `{sum, S, Frame}`. On the FreeBSD test host (median of 5, min-max) the receive half first
     cost bulk receive 1,907 (1,876-1,973) to 1,837 (1,823-1,877) Mbit/s; with the wide loop
     and the IPv4 header not read again it is 1,936 (1,926-1,968), bulk send 1,164 to 1,150
     and rr 64 B 16,927 to 17,110 txn/s, within their spreads (raw data:
     ~/erxos-history net-bench-freebsd-fast-p5b-2026-11-10, commit ea64849). The send half
     is in the tree for the tap: `erx_tcp_wire:encode/4`; `erx_net_frame`'s
     `{csum, Start, Field, Packet}`, with `finish/1` and `finishable/2`, the loopback's
     packets finished by `link/3`; `link_info`'s `finish`, written into the interface row;
     the tap NIF finishing a delayed frame in its `writev`; and the pipe's `process` end in
     its offload mode, which finishes with `finish/1` and hands frames up with their sum.
     On the FreeBSD test host (median of 5, min-max, against master the same hour) bulk send
     went from 1,151 (1,138-1,182) to 1,163 (1,146-1,206) Mbit/s, bulk receive 1,913 to 1,926
     and rr 64 B 16,619 to 16,941 txn/s, all within their spreads, where a hack that summed
     each sent segment twice had cost 2 to 4 percent (raw data: ~/erxos-history
     net-bench-freebsd-fast-p5c-2026-11-10). What remains is the other media:
     `erx_device:complete/3` and `post_frame/5`'s delayed frames, and `erx_virtio_net` on them with its start line
     naming the finisher; until then it declares `finish` `none` and drops a delayed frame.
     The netmap NIF takes the same core when it is built;
     * [Medium] `erx_net_input_fuzz`: its frames carry no Ethernet padding and its UDP lengths
       always fill the IP payload, so `erx_net_sum:span/4`'s bytes after the packet and
       `erx_udp_wire`'s datagram sum are checked only by EUnit cases
       (`erx_net_input_tests`' network sum cases and their seeds); pad some frames and cut some
       datagrams short, with the judge tolerating both.
  6. runs on send, toward 4.4 Gbit/s. Output's run rule is in the tree: `erx_tcp_output`
     sends whole segments of new data as one run in one pass, an outgoing segment with
     `seg`, and `erx_tcp_output:segments/1` cuts it into the segments per-segment output
     sends, which `erx_net_frame:tcp/3` encodes one by one; `output/3` with runs off is
     the oracle of the differential case and its seeded faults. On the FreeBSD test host (median of 5, min-max, against master the same hour) bulk send went from 1,141 (1,138-1,163) to 1,225 (1,216-1,238) Mbit/s, bulk receive 1,914 to 1,913, rr 64 B 16,596 (15,999-17,719) to 15,905 (15,779-16,266) txn/s and 64 B x16 90,075 to 89,739, within their spreads (raw data: ~/erxos-history net-bench-freebsd-fast-p6-2026-11-10, commit 87ecd53). The frame layer's runs are in the tree too: `erx_net_frame`'s `#run{}`
     over the template `template/2` builds and the connection caches (`tcp/4`), `cut/1` as
     the Erlang reference, judged against the run's segments encoded one by one,
     `run_tail/2`, the credits counting a run's frames (`frames/1`, `units/1`), and the
     driver's partial take `{ok, N}`. On the FreeBSD test host (median of 5, min-max,
     two rounds interleaved with master) the frame layer's runs took bulk send from 1,233
     (1,218-1,247) and 1,246 (1,239-1,264) to 1,434 (1,428-1,531) and 1,431 (1,421-1,476)
     Mbit/s, bulk receive and both request-reply workloads within their spreads (raw data:
     ~/erxos-history net-bench-freebsd-fast-p6b-2026-11-10, commit f706d25). The cut in C
     is in the tree too: `c_src/erx_tcp_cut.c` with its `tcp_cut` fuzz target, and the tap
     NIF's `send/2` cutting a run straight into one `writev` a frame, judged against
     `cut/1`. On the same host (median of 5, min-max, two rounds interleaved with master
     65589436) it took bulk send from 1,979 (1,931-2,287) and 1,982 (1,955-2,003) to 2,485
     (2,456-2,498) and 2,461 (2,376-2,521) Mbit/s; bulk receive (medians 3,558 to 3,647
     Mbit/s in all four rounds), rr 64 B (14,894 to 15,094 txn/s) and 64 B x16 (86,775 to
     87,474) stayed within their spreads (raw data: ~/erxos-history
     net-bench-freebsd-fast-p6c-2026-11-10, commit 83f7a0a). What remains:
     * [Low] the 64-binary run bound is two hand-kept constants, `RUN_PIECES` in
       `erx_net_frame.hrl` and `ERX_TCP_CUT_PIECES_MAX` in `erx_tcp_cut.h`; make it one
       fact (the NIF reports it at load), and fold output's `run` and `frames` fields into
       one `frames :: none | pos_integer()`;
     * [Low] the `tcp_cut` fuzz oracle checks each checksum by the frame's whole sum, so a
       field written as 0x0000 where 0xffff belongs passes it (the tap's byte-for-byte
       test against `cut/1` catches it); and the cut's seeded faults are listed twice, in
       `test/host/erx_tap_test.rb` and `erx_net_bytes_test.rb`;
     * `erx_device:post_frame/5` in the erXos device NIF and `erx_virtio_net` on it,
       with package 5's `erx_device:complete/3` and its delayed frames;
     * the interface's `runs` and `run_frames` counters, and design test 2's remaining
       parts: the property over event sequences with IPv6 and window scaling among its
       states (the single-pass differential has neither), the explorer's runs, and the
       seed that starts a run's RTT probe at its last frame;
     * [Low] condition 5 refuses a run while ECE is owed, though every frame would carry
       it and the ECN state would not change, so a congestion episode sends per segment;
  7. the merge on receive: receive toward 4.4 Gbit/s, and a sender's ACKs cut by the merged
     units' length. `erx_bytes:tcp_merge/1` with `tcp_merge_limit/0` is in the tree
     (`c_src/erx_tcp_merge.c`, the portable NIF and erXos's BIF, judged against
     `erx_tcp_merge_model` by the network primitives' probe and EUnit cases, with its
     `tcp_merge` fuzz target), and so is the driver's cut of every batch to that limit. So is
     TCP's side: `erx_tcp:merged/3` makes a unit's one segment, whose payload
     (`erx_tcp_payload`) stays in pieces through trimming, reassembly and the receive queue,
     each piece held, costed and copied out on its own, with its count handed to
     `cc_ack_received`; `erx_tcp_merged_tests` checks it against per-segment input (the
     design's test 5) and the TCP explorer's `merged` dimension in every state. What remains
     is the interface: merging each batch before it classifies (the loopback input left out),
     classifying a unit by its first frame, verifying its first and last, checking that the
     last names the first's flow and that `length(Payload) =< N =< 256`, and handing on the
     segment `erx_tcp:merged/3` makes; credit by segments; and the copy check, with the tests
     7, 8 and 12 of the fast path's design, the `net_device` bursts and the input fuzz target
     reaching merged units;
  6. runs on send: output's run rule, `erx_tcp_cut.c`, `erx_device:post_frame/5`, runs in
     the tap and netmap NIFs, and `erx_net_frame:cut/1` as the reference: send toward
     4.4 Gbit/s;
  7. the merge on receive is in the tree: the interface merges each batch
     (`erx_bytes:tcp_merge/1`), classifies a unit by its first frame, charges its N segments to
     the connection's credit, verifies its first and last frames and hands on the segment
     `erx_tcp:merged/3` makes; bulk receive on the FreeBSD test host went from 1,883 to 3,605
     Mbit/s (33 segments per unit) and bulk send from 1,148 to 1,438 (the peer's ACKs, 11 per
     unit). What remains of it: the design's test 11 (packet scripts through the pipe's
     offload mode, the merge's visible behaviour against FreeBSD); a unit no connection owns
     is taken as its last frame, which answers a closed port as FreeBSD does but would hand a
     listener the last frame's sequence number where FreeBSD's syncache takes the first's
     (latent while no listener key exists: hand the syncache the merged segment, whose
     ACK and sequence number are the first frame's); the credit a merged item takes
     back is read in two places (`erx_net_input:units/1`, `erx_tcp_conn:units/1`), which
     `{items, If, Items, Units}` would make one; a unit that finds less than N units of room
     is dropped whole where unmerged frames would deliver the first R, a cliff to measure
     under load; drop counters count a unit once, not its N frames; and request-reply with
     16 connections lost about 2% (89,306 to 87,513 transactions in 10 s), to profile;
  8. netmap with runs and merged batches, over VALE against lwIP over VALE;
  9. request-reply: the driver-to-interface hop and scheduler placement measured, and what
     their profiles name changed, toward the request-reply target;
  10. device finishing, on `VIRTIO_NET_F_CSUM` with `HOST_TSO4` and `HOST_TSO6` together, an
     extension, once a harness medium offers the three bits.
  Packages 6 and 7 build on the designs of the netmap transport and the socket process, whose
  push carries `{data, [binary()]}`, at most 64 binaries and one piece in all. Package 4 also
  ends the tap helper's items under Bugs by subsystem.

## Stopgap replacements

* [Medium] `erlang/apps/erx_net/erxos/erx_virtio_net.erl`, `erlang/apps/erx_blk`: no test runs a real driver under a hostile device. `test/integration/runtime_device_test.rb` breaks a hosted stand-in's queue under a driver written in the test, so the drivers' own broken-queue path (`error({virtio_net, broken, rx})`), its supervision and restart, and that the crash ends only the driver process (the network driver; the block driver's crash ends the storage domain) are unchecked; plan.md's 1b-E exit criterion asks for it under QEMU. Running `erx_virtio_net` over a virtio stand-in hosted, or a hostile model device under QEMU, would settle it.
* [Medium] network, `erx_net_admit` ([design-network-stack.md](design-network-stack.md#the-grants-contract)):
  generate the admission path of grants and sockets from `abi/services/net.txt`. The module is
  hand-written with the generated module's exact signature, since no generator over `abi/services`
  emits an Erlang admission module.

## Bugs by subsystem

* [Medium] network, Pi 4 Ethernet MDIO (`erlang/apps/erx_net/erxos/erx_mdio.erl`): `poll/3` decides
  each poll of the command register, up to 1,000 polls 10 us apart as FreeBSD does (`if_genet.c:1669,
  1684-1692`), but an Erlang timer cannot sleep 10 us, so `erx_genet` spins on the monotonic clock between
  polls, holding its scheduler for at most the bound, 10 ms, per operation: a link poll each second makes
  two or three. Measure it on the board; if it shows, run the loop in the device NIF, as the SD
  controller's command register is.
* [Low] network, Pi 4 Ethernet PHY (`erlang/apps/erx_net/erxos/erx_phy_c22.erl`): autonegotiation is
  started once after the reset and never restarted, where FreeBSD restarts it while no link comes up
  (`brgphy.c:356-383`), so a negotiation that sticks leaves the link down until the driver restarts.
  Restart it every few link polls without a link if the board shows a stuck negotiation.
* [Medium] network, `erx_net_erxos` mint loop (`mint/2`, `count/2`, `mint_one/2`,
  `mint_counts/0`): no host test drives the loop itself. The tests cover
  `erx_net_admit:mint/2` and `erx_net:mint_grant/4`, but not that the loop answers a
  system-grantee refusal and a `noconnection` through `erx_facet:minted/2`, counts refused
  and unknown messages under the right keys, and answers `counts`. Move the loop's decision
  into a pure function returning the reply and the next counts, and test it, or run the loop
  on the host with stand-ins for `erx_facet`, `erx_connections` and `erx_kernel_records`.
* [Medium] network, `erx_net_grant:init/1` (design-network-stack, "The grant"): only
  `erx_net_admit:mint/2` refuses the system domain as a grantee; `erx_net:mint_grant/4` and
  the grant's own export check nothing about it, and the property holds because the mint is
  the only caller and `erx_connections:connection/1` answers `noconnection` for the system
  domain. Refuse a system-domain grantee in `init/1` before the export, so the grant is
  never exported there whoever calls, and keep the admit refusal for its count.
* [Low] network, `erx_net_erxos` mint: a grant start that crashes after the export answers
  `{error, {Reason, Stack}}` to the domain service unchanged, so the network domain's
  internal terms (its `Limits` among them) reach the system domain's refusal log. Map any
  answer other than `{error, atom()}` to a fixed `{error, start_failed}`.
* [Low] design-network-stack, "The grant" (with design-system, `connection_lost`): a grant
  ends with its connection, and the domain service grants a domain again only when either
  domain restarts, but a connection can end while both domains live (`malformed`,
  `no_memory`, `disconnect`). State whether the two domains are introduced and granted
  again then, or the client keeps a dead `net` facet until a restart.
* [Medium] network, SYN-RECEIVED output (`erx_tcp`, `erx_tcp_output`): every step ends
  in output, and output in SYN-RECEIVED carries SYN and ACK, as FreeBSD's does
  (`tcp_output.c:432-443`, `:700-702`); FreeBSD calls `tcp_output` there only for a
  segment, a timer that fired or a user request. An accepted connection steps nothing
  before its completing segment, but a step in SYN-RECEIVED that FreeBSD would not
  follow with output still sends the peer the SYN-ACK again: in a simultaneous open, the
  grant's answers to the buffers `tcp_mss` rounds at the SYN (FreeBSD reserves them
  inside `tcp_do_segment`, `tcp_input.c:3935`, `:3968`), and a clock hint that fires no
  timer; after a raise in an accepted connection's completing step, counted by
  `guarded/2`, the hint alike. Making it hold by construction: let output resend a SYN
  in SYN-RECEIVED only after the retransmission timer rewound `snd_nxt`.
* [High] network, `erx_net_client` (`erx_gen_tcp`; design-network-stack, "The socket
  process"): the TCP socket process lacks parts of the design.
  Still missing:
  `monitor/1`, which `inet:monitor/1` calls, so `ssl:listen` ends in `undef` (its session cache and ticket
  tracker monitor the listening socket; traced from source, not run);
  the packet modes `http`, `http_bin`, `httph`, `httph_bin`, `asn1`, `cdr`, `sunrm`, `fcgi` and
  `tpkt` (erx_net_packet frames 1, 2, 4 and `line`; the http modes need the core to keep
  whether the request line was read, as gen_tcp_socket's `recv_httph`), `line_delimiter`, and the
  `exit_on_close` and `show_econnreset` options, the schema-generated request validators, the session template's `grant` key
  naming its `grant/0` once the grant is in another domain, and the connection's link to
  its socket process (erx_tcp_conn monitors its owner instead, so only a listen and an
  accept expose their socket processes to the network domain with `send` and `link`;
  `erx_inet`'s `expose_opener/2` must name `tcp_connect` in the same change that makes the
  connection link, or a cross-domain connect ends at the link's `noproc`).
  The calls the socket process forwards (`sockname`, `peername`, `getopts`, `shutdown`) wait
  for the connection's reply with no deadline of their own, and within one domain a socket
  protocol message proves its sender only by its pid field. Differences from stock at
  the end: a setopts with forwarded options whose own options took
  effect answers `{error, closed}` when the connection closes under it (stock: `ok`);
  `{active, 0}` or a count that stays at or below 0 fails waiting recvs `einval` though the
  socket stays passive; only the first waiting recv gets a passive error's reason, the rest
  `closed` (stock's `async_error_am_all` gives all the reason); and re-arming after a recv
  met the end answers `{error, closed}` where stock sends `{tcp_closed, S}`. `listen/2` and
  `connect/4` answer `{error, einval}` for an option stock takes and the backend does not,
  and for an `ip`, `ifaddr` or `port` value inet's parser takes and inet_tcp then refuses
  (`{ip, foo}`, `{port, 70000}`), where stock raises `badarg`; stock's `connect/4` also turns
  every `einval` of its backend into `badarg` (gen_tcp.erl:595), so erx_gen_tcp's connect
  should raise `badarg` for each. A `setopts` that names one option twice keeps the last
  value, where stock's inet driver keeps the first for `mode` (`[binary, list]` leaves a socket
  binary on stock); `listen/2` and `connect/4` keep the last on both.
  The listening socket (`erx_gen_tcp`, `erx_gen_tcp_core`): it is a `listening` state of the
  connection's `#core{}`, so a listener core can hold connection fields and its protocol is
  spread over the connection's helpers; give it its own record and step sharing only the
  requests-in-flight helpers. A listening socket with `{active, N}`, `N =< 0`, sends no
  `{tcp_passive, L}` and hands that count to its accepted sockets, where stock goes passive at
  once. `opening` answers calls `einval` and drops pushes, where the design postpones calls and
  stops with `econnaborted`. An accept's socket process is started before the core decides,
  and `{hand_over, ...}` is taken from any local caller, not only the starter.
  `controlling_process/2` to a dead process is refused before anything moves, where stock
  forwards the queued messages to it and answers `badarg` (a documented difference without its
  test yet); a new owner that dies between the two calls is answered `ok`, then closes the
  socket. Not yet tested: no socket process survives an accept timeout, a close with accepts
  waiting or an accept caller's death; a hand-over to an ended socket process; the owner's
  exit mid-transfer.
  The socket process's monitor of its socket and its plain sends may suspend it behind a busy
  lane, where the design says it never makes a monitor or call towards the network domain once
  it holds its socket (no `erx_sock_out`, no `{async_dist, false}`).
* [Medium] network (the client side of `net`; design-domains, "Floors from a protocol"):
  the socket protocol's floors are not generated from `abi/services/net.txt` (the client keeps copies:
  `?ACCEPT_REASONS`, `listener_option/1`, `?IS_TIMEOUT`, the 64 in flight; a request the network
  side refuses goes unanswered, so its client call hangs), and no client
  checks them at run time. The manifest check holds each `net` grantee's `max_frame` to
  `net_max_frame_min` (property 15), a limit set by hand in that file; nothing checks the
  serving domain's `max_frame` against it at build, as design-domains says the manifest
  check does, nor `max_message_heap` or `funnel_depth`. Generate the floors from the operation schema with
  the send-credit change, check them on the client before each call, and replace the
  hand-set limit with the generated `max_frame` floor.
* [Medium] network, `erx_net` and `erx_net_client` (`erx_udp_sock`, `erx_icmp_sock`,
  `erx_gen_udp_core`; design-network-stack, "Credit"): datagram memory is not bounded as
  the design says. A datagram socket's receive queue in the network domain is bounded in
  datagrams (`limit`, 64 by default; an echo socket's 16), not in bytes up to its receive
  buffer, so one socket may hold 64 datagrams of 65,527 bytes, about 4 MiB, of the network
  domain's memory. On the owner's side the credit charges a datagram `max(1, size)`, which
  bounds bytes but not memory: a peer sending 131,072 empty datagrams to a passive socket
  whose owner does not read makes its socket process hold about 14 words each, some 14 MiB,
  against the design's "at most the target per socket". Charge a fixed overhead per
  datagram on both sides, as FreeBSD's `sb_mbcnt` charges `MSIZE` per mbuf, bound the
  network side's queue by that cost at its receive buffer, and state the cost in the
  design's credit paragraph.
* [Medium] network, `erx_net_client` (`erx_sock_admit:result/2`; design-network-stack,
  "Untrusted input"): each request kind's closed list of errors is a hand-written copy of
  what the network side's paths (`erx_net_frame:path/3`, `udp/5`, `echo/5`, `erx_net_tx`)
  can return, and the `erx_net_admit` fuzz target checks it against a second copy, so an
  error missing from both closes the socket as a protocol break where stock answers the
  error (a broadcast send's `eacces` did). Have each network-side socket map its errors
  into the closed list at its one reply site, total over the specs it calls, or generate
  both from `abi/services/net.txt` with the request validators.
* [Low] network, `erx_net` and `erx_net_client` (`erx_udp_sock`, `erx_icmp_sock`,
  `erx_gen_udp`): the datagram and echo sockets and the datagram socket process count
  unknown and refused messages, but nothing reads the counts: no `counts` call or
  inspector view shows them. `erx_net_admit` also still admits up to 64 `udp_open`
  options, which the grant refuses unless the list is empty.
* [High] network and domains, the envelope (design-domains, "Risks and open questions"):
  every message from another domain arrives as `{erx_origin, D, Msg}`. A TCP socket's
  messages reach its owner through its socket process, which takes the envelope off, so
  only `gen_udp`'s active-mode deliveries remain wrapped for an owner outside the network
  domain (the `erx_gen_udp` item above).

* [Low] network, `erx_tcp_conn` (`perform({deliver, _})`): the receive queue
  counts payload bytes only, not the binary and list cell each queued
  segment costs, which `erx_tcp_reass` counts as `PIECE_OVERHEAD`. A peer
  sending one-byte in-order segments to a connection whose owner reads
  slowly, or to a waiting recv, makes its queue cost about 40 bytes of heap
  per byte, a few MiB per connection, where FreeBSD bounds the same with
  the mbuf limit `sb_mbmax`. Count the overhead against the receive buffer,
  or join small payloads as they are queued.
* [Low] network, docs/design-network-stack.md ("Framing", step 3 of the output pass): "past
  SYN-RECEIVED" should read "once a SYN has been received" (`TCPS_HAVERCVDSYN`), as the code
  does; FreeBSD's connect also returns the first EHOSTUNREACH (`tcp_usrreq.c:540`), which
  the stack does not.

* [Medium] erx_net TCP explorer (`test/erlang/erx_tcp_explore.erl`): the sack run requires only
  hits a connection without SACK also gives. Add a property that judges a scoreboard hole (a
  hole is retransmitted before new data, say) and require it; a hole first appears at depth 4,
  past the landing depth of 3, so run sack at depth 4 in landing mode (about +0.5 s) or require
  it in `full` mode only. The model's `loss_dropped/3` reads from the connection whether
  `snd_wl1`/`snd_wl2` moved on a duplicate ACK rather than modelling the loss module's drop.
* [Low] erx_net TCP output (`erx_tcp_output`): a FIN-only range the send log marks lost at
  `snd_una` (NewReno, with only a separately sent FIN outstanding) waits for the RTO,
  since the FIN is resent only when `snd_nxt == snd_una`; FreeBSD moves `snd_nxt` to the
  acknowledgement first. And `enobufs/3` sizes the window with no SACK blocks where
  `tcp_maxseg` counts `rcv_numsacks`.
* [Medium] network, `erx_net_sup:with_loopback/1`: a configured `lo0` entry stands whole, transport
  included, where FreeBSD always creates `lo0` as a loopback and `ifconfig_lo0` sets only its
  addresses. `lo0` over another transport leaves no link `none` (every own address `enetunreach`),
  `lo0` with `ip4 => dhcp` fails `erx_net_if_core:new/1` with `function_clause`, and a binary name
  `<<"lo0">>` adds a second `lo0`. Take only a static `ip4` and `ingress` from a configured `lo0`,
  refuse the rest at `start_link` with a named error, and test it.
* [Low] network, `erx_net_loop:transmit/2`: it raises on a zone whose bytes are not iodata where
  its doc says `malformed`; drop a bad list as `malformed`.
* [Low] erx_net TCP ICMP (`erx_tcp_icmp`, `erx_tcp_input:tcp_mss`): an MTU a too-big
  report gives in SYN-SENT lowers the MSS until the SYN-ACK, which recomputes it from the
  path, so the first full-size segment is lost again; FreeBSD keeps it in the host cache
  (`tcp_hc_updatemtu`), which `erx_tcp_hostcache` will hold.
* [Low] erx_net TCP ICMP (`erx_tcp_icmp`): reports are sized by `#tcb.family`; check how a
  connection to an IPv4-mapped IPv6 address is represented, since FreeBSD sizes such a
  connection's headers as IPv4 (`inp_vflag`).
* [Low] erx_net TCP input (`erx_tcp_input`, `data`): the D-SACK block of a duplicate
  is recorded in the `data` stage, so it is lost when the segment ends earlier (the loss
  module's `drop`, CLOSING or LAST-ACK ending); FreeBSD records it in its trim.
  Recording it in `trim` needs the reassembly ranges held before the segment there.
* [Low] erx_net TCP core (`erx_tcp:respond/5`): it sets no ECE
  (`tcp_ecn_output_established`) on keepalives and challenge ACKs.
* [Low] erx_net TCP timers (`erx_tcp_timer`): path MTU black-hole detection, which the
  design says is translated (off by default, `tcp_pmtud_blackhole_detect`), is not.

* [Medium] network build checks, `tools/lib/erx/net_checks.rb` (seq-wrap, atoms): the checks scan text
  with a regex copy of Erlang's lexer and a list of literal spellings, so they miss the idiomatic wrap
  `<<D:32/signed>> = <<(A - B):32>>`, a mask defined by a macro in a non-TCP header and used in a TCP
  module, and an escaped quoted atom such as `'list\_to_atom'`. Tokenize with stock OTP's `erl_scan`
  (integer and `bsl` tokens by value, atoms after unescaping; ErlangText could share it), flag `:32`
  bit-syntax segments outside `erx_tcp_seq` and `erx_tcp_wire`, and consider refusing `file:consult`,
  `erl_scan`, `erl_parse` and `io:read` in erx_net too. The lifted-segment record remains the real guard.
* [Low] network, `erx_tcp_input:dropwithreset` and the connect path: only the link-cast half of
  `tcp_dropwithreset` is translated; its IP checks (`tcp_input.c:3452-3472`) are left to the rule
  that no connection has a multicast or broadcast foreign address, which FreeBSD enforces in
  `tcp_usr_connect` and erx_net does not yet (a connect to 224.0.0.1 is not refused). Refuse it at
  connect and say so in the comment.
* [Low] network, `erx_nd6_rtr:deprecation/2`: it also clears `deprecated` on a tentative address,
  which `nd6_timer` never reaches (`nd6.c:1041` is its final branch), and clears it at the RA's
  refresh rather than the next timer; name both as departures in the module documentation.
* [Medium] network, `erx_net_input`: looped multicast is checked against the loopback interface's
  `groups`, not the carried zone's interface, and a socket's `report` item holds the quote's raw
  addresses although the socket was found by its zoned key.
  Decide it when the interface process carries looped multicast.
* [Low] network, `erx_tcp:signal_state(rto_err, ...)` (review of P20d): undoing a spurious
  timeout rewrites the send log (`timeout_undone`) and moves `snd_nxt` to `snd_max` behind the
  loss module's back, so a module with per-range state would be stale after it. Route the undo
  through the loss module (a cause of `rewind/4` or a sibling callback) before a second module.
* [Low] network, `erx_net_input` provenance: NOTICE-freebsd's entry lacks `sys/netinet/tcp_subr.c`
  (`tcp_ctlinput`), which the design names as a source; and check whether `udp_common_ctlinput`
  looks up with `INPLOOKUP_WILDCARD`, which the design says it does not.
* [Medium] network, `erlang/apps/erx_net/src/erx_nd6_rtr.erl`: the interface process must call
  `select_router/2` after every step that can change the router list or a router's reachability, and diff
  `addresses/1` and `routes/1` to republish, where FreeBSD reselects inside `defrtrlist_update`; until it
  does, a default route through a router that left the list is missing. When the interface process is
  written, pass erx_nd6's reachability into `ra/4`, `tick/2` and `dad_done/3`, select inside, and emit
  `{routes, Rows}` and `{addresses, Rows}` actions only on a change, so it holds by construction.
* [Medium] network, `erx_tcp_loss_dupack` (`prr/5`): in SACK recovery PRR measures the pipe after
  the acknowledgement, where FreeBSD's `tcp_do_prr_ack` computes `tcp_compute_pipe` with
  `snd_una` not yet advanced and sets `snd_cwnd = pipe - del_data + sndcnt`; whether that pipe
  already leaves out the bytes this acknowledgement newly SACKed (and so whether FreeBSD
  subtracts them twice) depends on `tcp_sack_doack`, which erXos does not read. Settle it from a
  FreeBSD 15.1 run: a SACK recovery in which one acknowledgement advances `snd_una` by A bytes
  and newly SACKs S bytes, once with the pipe above `ssthresh` and once below, recording
  `tcpi_snd_cwnd` (TCP_INFO) or the segments sent in reply, and compare with `pipe_after +
  sndcnt` and `pipe_after - S + sndcnt`, for both the window and the `pipe >= ssthresh` choice.
* [Medium] network, `erx_tcp_loss_dupack` (`episode/3`, `ended/2`): where a recovery episode
  ends is decided twice, by the connection (`erx_tcp_input` `end_recovery`, `erx_tcp`
  `signal_state`) and again by the module from the acknowledgement and its own `pending`
  value, and episodes it did not begin are inferred from the flags. Today the two agree; make
  it hold by construction with an episode number in `#ccv` that every entry and exit bumps, and
  record the one departure it brings (ECN's signal on the acknowledgement that ends recovery
  would start fresh counters, where FreeBSD carries them).
* [Low] network, `erx_tcp_loss_dupack` (`prr/5`): in the recorded departure where a partial
  acknowledgement without SACK blocks takes PRR's path, a scoreboard without holes credits
  `maxseg` delivered per acknowledgement, so a peer splitting one segment's acknowledgement
  front-loads PRR's sending (bounded by ssthresh); credit `min(maxseg, ack - snd_una)` there.
* [Low] network, `erx_ip6_wire` (`options/4`): a router alert whose length is wrong but which
  runs past its header is dropped silently, where FreeBSD's `ip6_process_hopopts` checks only
  that 4 bytes remain and answers with a parameter problem; a second departure in which ICMPv6
  error a packet draws, missing from the module's documentation, and the fuzz judge shares it.
* [Low] network, `erx_icmp6_wire` (`error_code/2`): as in FreeBSD, an incoming parameter problem of code 3
  (RFC 7112's incomplete header chain) is refused as `bad_code`, though `erx_ip6_wire` reports code 3 for
  erx_ip6 to send; decide with erx_icmp6 whether to accept it.
* [Medium] network, `erx_net_sup` (link restarts): the driver's one-second hold paces every end of a
  driver that ran, but not a transport whose `init` fails at a restart (the start fails and OTP retries
  at once, so a persistent failure, such as a `udp` end's vanished local address, ends the interfaces
  supervisor and then the stack), nor an `erx_net_if` or `erx_dhcp4` crashing past its link
  supervisor's intensity (reachable from a peer only through a crash bug). An `erx_tap` restart meets
  this too: FreeBSD's tap opens once, and an armed descriptor of the ended driver closes only when
  ERTS's poll set lets go of it, so the new `init` may find the device busy (`ebusy`); not yet seen
  on the FreeBSD test host. Pacing every link start in `start_link_sup/1`, not each way a driver ends, would close all
  three.
* [Medium] network, `erx_tap` (`fd => N`): every restart of the driver adopts the integer N
  again, so once N's holder closes it (an OTP socket closes with its controlling process), the
  next descriptor the node opens under that number (a connection, a file) is adopted, made
  non-blocking and written frames to. Adopt once into a resource a long-lived process owns and
  give each driver start a copy of that, or record `st_dev`/`st_ino` at the first adoption and
  refuse a restart whose descriptor differs.
* [Medium] network, `erx_tap_nif` (`adopt/2`): the copy shares its open file's flags, so any
  holder that clears `O_NONBLOCK` (OTP's `socket:close` does) makes the next `recv`/`send` block a
  normal scheduler. Check `F_GETFL` at each call and fail with `{error, blocking}`, or poll with a
  zero timeout before each read and write. Also refuse a descriptor not open for reading and
  writing at adoption.
* [Low] network tests, `erx_tap_tests:owner_end_closes_the_descriptor_test`: under load the
  FIFO's reader is still blocked 2 s after the owner's `DOWN` (`{expected, eof}, {value,
  blocked}`): seen under a host load near 20, and once in a full `make check`, while
  `test_tap_transport_and_nif` passed five runs out of five alone. The owner's exit sends the
  test's `DOWN` and runs the handle's down callback in one walk of its monitors
  (`erts_proc_exit_handle_monitor`, `otp/erts/emulator/beam/erl_process.c`, which calls
  `erts_fire_nif_monitor` in `erl_nif.c`), so `DOWN` can arrive first; an armed descriptor is
  closed only by the stop callback, which `ERL_NIF_SELECT_STOP` may schedule for later. Wait on
  the close itself, or bound the reader by the case's own timeout rather than a fixed 2 s,
  since an `eof` that comes at all comes at once.
* [Low] network, `erx_tap` (unprivileged runs): the privileged opener that hands the node a tap
  descriptor over `SCM_RIGHTS` ([design-network-stack.md](design-network-stack.md), "The tap
  transport") is not built; it must hand the descriptor over close-on-exec, so no port program
  inherits it.
* [Low] network, `erx_net_sup`: a far end or device that stays dead logs a supervisor report about
  once a second per interface for as long as it stays dead; the log, not the stack, should fold
  repeated reports.
* [Low] network, `erx_net_driver` over `erx_virtio_net`: a device that stops completing transmits
  ends nothing; its backlog fills, senders are refused and the link stays stuck. FreeBSD's vtnet(4)
  reinitialises the interface when its transmit watchdog (`vtnet_watchdog`) expires after 5 seconds;
  a driver whose backlog has waited on `writable` that long could end, so that its restart resets
  the device.
* [Medium] network, name resolution (`erlang/apps/erx_net_client/src/erx_gen_tcp.erl`,
  `otp/lib/kernel/src/inet_res.erl`): a reply with the TC bit set makes `inet_res` ask again over
  TCP with `{packet, 2}`, which `erx_gen_tcp` refuses (it takes only `{packet, raw}`), so a name whose
  answer does not fit in 512 bytes fails to resolve. Give the connection `{packet, 2}` framing, or
  have `erx_gen_tcp` frame the two-byte length itself, and test a truncated reply against a name
  server on the host.
* [Medium] network, edit 62 (`otp/lib/kernel/src/inet_dns.erl`, `decode_data/3`): the fix's test (`inet_dns_tests`) calls
  `inet_dns:decode/1`, and the `dns` fuzz target reaches a formatless type only when a flip lands
  on a type or class field, and it calls `inet_dns:decode/1` where `inet_res` calls `decode_reply/3`.
  Make the test decode through `decode_reply/3` as well, and have the fuzz target call `decode_reply/3` with a matching query.
* [Medium] network, effect layer (E1, `erx_net_if`, `erx_udp_sock`, `erx_net_tables`): the first
  package runs ARP, ICMP echo, DHCP and UDP only. Not yet: `erx_net_vclock` and `erx_net_script` (the virtual clock is refused at
  start); grants, `erx_net_admit` and `erx_net_client` (`erx_udp_sock` has a
  provisional `gen_udp`-shaped interface); the listener, IPv6, reassembly and redirect paths of
  `erx_net_if_core` (counted `unsupported`); an `erx_net` application module and its `env` keys
  (the stack starts with `erx_net_sup:start_link/1`); the credit limits are fixed defines, not
  application keys; a datagram socket's credit counts datagrams, not bytes of its receive
  buffer. Build checks still to add: the clock chokepoint's `receive ... after` rule (its calls are
  checked: `net_checks.rb`'s `clock`, which allows `erx_net_driver` and `erx_genet` whole where the design
  names only the driver's hold and the MDIO and PHY waits), `erx_net_bind` as the only demultiplexing inserter,
  `erx_net_if` as the only configuration writer and `erx_net_credit` as the only batch sender.
  With IPv6 interface addresses, `lo0` takes `::1/128` and `fe80::1%lo0` as it comes up, as
  FreeBSD's `in6_ifattach` gives them (`in6_ifattach.c:541-543`, `:816-823`); `erx_net_sup`
  gives `lo0` 127.0.0.1/8 alone.
* [Medium] network, the cookie keys' rotation (`erlang/apps/erx_net/src/erx_net_tables.erl`'s
  `{erx_net_clock, hint}`): each hint rotates the keys and arms the next, so a stray or repeated hint would
  start a second chain and rotate twice as often, halving how long a cookie is accepted. Keep the reseed
  deadline in the owner's state and rotate only once `now/0` reaches it, with a test of the deadline armed,
  and take the lifetime from `erx_tcp_syncache`'s `SYNCOOKIE_LIFETIME` instead of a second define.
* [Medium] network, virtio-net transport (`erlang/apps/erx_net/erxos/erx_virtio_net.erl`): what the
  first package leaves. No host tests of its pure functions (`frame/3`, `mtu/2`, `lladdr/2`,
  `link_state/2`, `segments/1`, `erx_net_app:interfaces/1`): export them under `TEST` or move
  them to a pure module of `src/`'s, and test them with EUnit. Checksum offload, which the
  design asks for, is not negotiated. UDP echo is not tested on QEMU: it needs an echo service
  in the guest. No build check that only `erxos/` names erXos's own modules (`erx_device`,
  `erx_device_record`, `erx_log`, design-network-stack.md, "Two places, four seams"), with its
  seeded violation.
* [Low] network, virtio-net transport, small points: the manifest check accepts a network device held
  by any domain, not only the system domain or the network domain; `VIRTIO_NET_F_MTU` is
  negotiated even when the device's MTU is above 1,500, the most the receive buffers hold: the
  transport clamps the MTU and drops longer frames as `too_long`, but should not take the feature; a multicast or zero device MAC is
  taken as the interface's address; `refill/2`'s `{ok, T}` match after a completion batch ends
  the driver with a badmatch rather than a named reason; the harness (`net_device.rb`) does not
  check the IP and ICMP checksums of the guest's replies; `free_port` can race another process
  for the port it found, and `Link#await` takes a frame from any local sender; `Link#send`
  shadows `Object#send`; `tx_limit` is the queue size although a frame takes up to four
  descriptors, so `full` comes before the credit runs out; `init/1` turns any exception into
  `ignore`, a programming error included; the interrupt status bits are written by hand, as in
  `erx_blk`, not generated from `abi/formats/virtio.txt`; `erx_net_if` has no `format_status/1`
  that keeps queued packets out of a crash report, as `erx_net_driver` has.
* [Low] network, socket starts (`erx_net_grant` act/3, `erx_udp_sock`, `erx_icmp_sock`, `erx_tcp_conn`): a socket's
  start that crashes in init/1 answers the grantee `{error, {Reason, Stacktrace}}`, so internal terms cross to the
  client domain before `erx_sock_admit` refuses them; map any start failure but the socket's own refusals to
  `badarg` in the grant. The three also refuse with `{stop, Reason}` from init/1, which logs a crash report a
  client can repeat at will; return `{error, Reason}` as `erx_tcp_listen` does.
* [Medium] network, TCP effect layer (E2, `erx_tcp_conn`, `erx_net_grant`, `erx_gen_tcp`): active
  opens over IPv4 only. The interface's syncache answers SYNs and completes handshakes over IPv4
(`erx_net_if_core`), and each completed handshake starts its connection (`erx_tcp_conn:accept/1`),
which its grant adopts and which queues itself on its listener; the grant's `tcp_listen` starts the listener
(`erx_tcp_listen`), which claims its key by an explicit bind within the ports `erx_net_grant_core:bind_ports/3`
derives from the `ports`, `listen` and `addresses` limits, and rewrites its entry at a `setopts` of `nodelay`;
`erx_gen_tcp`'s `listen/2` and `accept/2` reach it through the listening socket's process.
Missing: pausing, since the grant has no account to pause a
listener for; and the QEMU case. The core's exploration runs at one end per run, the landing gate's bound; its
two-end run, `explore(#{ends => 2})`, tens of millions of states, belongs to the milestone gate, on the remote
development host that runs the 4-CPU gate cells, but nothing runs it yet, so a core bug that needs two ends, such as one in the order of a
handing call's socket process exit and its connection's, is not yet looked for. Also, an ICMP error quoting a SYN-ACK reaches the core as `unsupported` rather than
  `erx_tcp_syncache:unreach/3`. A SYN-ACK whose route leaves by another interface is counted `other_interface` and
  never sent, as the closed-port RST already is.
  Not yet: a SYN reinjected from
  TIME-WAIT (E3, counted `reinject`); the grant's limits other than `sockets` and `buffers`, and its account
  (`erx_net_grant_core` holds only the sockets and their buffer reservations); receive-buffer autosizing (`tcp_do_autorcvbuf`, a
  `reserve_buffer` for the receive side like the send side's); `exit_on_close` (a socket whose peer closed
  stays open until its owner closes it), the packet modes,
  every option but `binary`, `list`, `mode`, `active` and `nodelay`; the
  connection's credit limit and buffer sizes are fixed defines, not application keys.
* [Low] network, `erx_gen_udp`: `inet:getstat/1,2` of a datagram socket raises `undef`, since
  `erx_gen_udp` exports no `getstat/2`; the socket process would count each datagram as one
  delivery, as `erx_gen_tcp_core` counts pushes and sends
  ([design-network-stack.md](design-network-stack.md#options), **Statistics**).
* [Medium] network, `erx_tcp_conn` (`guarded/2`): a raising step must end the connection
  ([design-network-stack.md](design-network-stack.md#decisions), 15): from its
  state before the event, with a RST, `{error, econnaborted}` to its socket process and an exit with
  the exception, for a batch of drained messages as for one. `guarded/2` instead counts the raise
  and goes on with the state it had, after the effects of the step may already have run, and a raise
  outside a segment step crashes the process with no RST. Since the connection steps every
  queued `{items, ...}` together, a raise discards the whole batch, up to the credit's 256
  segments, so a segment that trips the bug once per batch stalls the connection. Change both, with a regression test that
  plants a raise in the step and checks the RST and the error the owner sees.
* [Medium] network, `erx_tcp_conn` (E2 review): a refused or timed-out connect in active mode still
  sends `tcp_error` and `tcp_closed` for a socket the caller never got; calls after `close` are
  served (a `recv` waits until the connection ends) where stock answers `{error, closed}`; a RST
  surfaces as `econnreset` where stock's `show_econnreset` false gives `closed`; the crash report's
  `reason` and queued messages can hold peer bytes despite `format_status`; a `recv` timeout past
  `send_after`'s range crashes the connection; `erx_tcp:answer_send` keeps filling the buffer after
  `snd_closed`; steps continue after `finish`; `watch_holder` runs after the claim, so a kill
  between them strands the entry; port exhaustion answers `eaddrinuse` where the design says
  `eaddrnotavail`. The socket's flags (`eof`, `ended`, `told`, `finished`, `connect`, owner `none`)
  want one closed phase value.
* [Medium] network, `erx_net_if` (`owned/4`): an interface that dies between reserving a holder's
  unit and the batch's end (a raise outside a frame's step, or its link supervisor's shutdown)
  leaves those units counted on credits that outlive it; trap exits and release the batch, or
  send each item at its reservation. A sender killed between `reserve` and `!` in
  `erx_net_credit:hand/4` leaks its units the same way.
* [Low] network, `erx_net_pipe` (`udp` end): any local user can send from the peer's loopback
  address and port, and strangers spend the `{active, 64}` window; a development host's
  residual.
* [Low] network, `erx_dhcp4`: a link that comes back up restarts the client from INIT with a
  fresh core, not INIT-REBOOT as the design's "The driver" says; the interface keeps the old
  lease until the new `configure` replaces it. INIT-REBOOT within one run needs only the core's
  last lease, not the stored state the item below waits for.
* [Low] network, `erx_dhcp4_core`: an ARP probe of the offered address before using it, and a
  DECLINE when another host answers (RFC 2131 4.4.1, RFC 5227), behind a setting of the
  interface's `dhcp` mode, off by default as in `dhclient`. Today the address is announced with a
  gratuitous ARP and a conflict is only reported by erx_arp. Part of the first host network package.
* [Low] network, `erx_dhcp4_core`: INIT-REBOOT (RFC 2131 3.2, 4.4.2), asking again for the last
  lease's address after a restart. It needs the lease kept across boots, as `dhclient` keeps
  /var/db/dhclient.leases. Part of the first host network package.
* [Low] network, `erx_dhcp4_wire_fuzz`: the fuzz target has no field oracle: pkt has no DHCP
  decoder, so its judge reads the options itself (joined bytes, and its own reading of options 15
  and 121) instead.
* [Medium] network, `erx_icmp_sock` (`erlang/apps/erx_net/src/erx_icmp_sock.erl`): no host case drives it:
  the 17th waiting reply dropped and counted by the interface, the identifier released on `close/1` and on
  the owner's end, `eaddrinuse` when every identifier is held, the `recv` deadline. Nor does one drive
  `erx_net:interfaces/0`'s conversion (IPv6 rows, `gateway => none`) and an interface ending while asked.
  Its waiter, deadline and credit-take code copies `erx_udp_sock`'s; one receive-queue module for both
  removes the second copy.
* [Medium] network and shell, ICMP errors to ping: an unreachable, time-exceeded or parameter-problem
  error quoting one of ping's echo requests is dropped as `no_socket` (`erx_net_input`, `quoted/4`), so
  ping prints nothing where FreeBSD's `pr_pack` prints `NN bytes from X: Destination Host Unreachable`
  and the like. Route an ICMP quote by its `{icmp_echo, inet, Ident}` key to the socket and print it.
* [Low] cross-domain call admission, written twice (`erx:call_from/3` in `erlang/apps/erx/src/erx.erl`, which erx_facet and erx_session_line ask; `erx_net_admit:request/2` in `erlang/apps/erx_net/src/erx_net_admit.erl`, over its own `domain/1`): N12 of [design-network-stack.md](design-network-stack.md#requirements) keeps `erx_net/src` from naming erx, so the network grant cannot ask `erx:call_from/3`, and a change to the rule is two edits. One source needs a choice: the runtime seam (`erx_net_runtime`) answering the check, the operation schema's generator emitting both, or N12 relaxed for this one function.

## Security residuals

* [Medium] network time, unauthenticated ([design-time.md](design-time.md#security)): the NTP server
  ntpd uses, or anyone on the path to it, sets the wall clock to any time after the release's floor date at a
  cold start and then walks it by up to 1000 s every two polls, and can forge `DENY`; certificate validity
  checks follow the clock. Root's `ntpctl step` sets through `set`: the server it takes the time from, or anyone
  on the path, sets any time, below the floor too when root names the server and past the floor from ntpd's
  sample, and the set then holds it against ntpd for the boot (design-time.md, decision 7,
  published). Network Time Security (RFC 8633 section 4.3) is the remedy, with a design of its own.
* [Medium] WiFi's key holder before its release placement, development
  builds only ([design-wifi.md](design-wifi.md#where-the-holder-runs)):
  the holder runs as a process of the WiFi domain, so the networks'
  PMKs and SAE PTs are in the domain that parses the air, and they sit
  unsealed in the `keys` file of the WiFi domain's own tree on the
  data volume, `wifi/`, readable by root's session, which holds the
  whole volume, and from a copy of the medium; a break of the WiFi
  domain can also write that file, so enroll a network, and a `pending`
  Transition Disable mark is lost with the domain's restart. No
  passphrase enters the domain: `wlankey` derives in the session. It
  blocks release. The vault's purpose closes it
  ([design-wifi.md](design-wifi.md#decisions), 1), and the
  release manifest check refuses a `wifi` row without `wpa_key` or with
  `wpa_admin`.
* [Medium] WiFi, SAE not constant-time throughout
  ([design-wifi.md](design-wifi.md#security)): `crypto:sae_pt/3`,
  `sae_commit/5` and `sae_key/5` multiply in constant time, but their
  point additions, negation, scalar sum and SWU map use OpenSSL's general
  `EC_POINT_add` and BIGNUM routines, whose time and branches depend on
  the values (`openssl/crypto/ec/ecp_smpl.c:702-721`); the per-exchange
  steps answer the peer, who can time them over the air. It blocks
  release. The fix is inside the three functions, over the P-256
  method's own field and point routines (`ecp_nistz256.c:110, 250-252`).
* [Medium] erx_net TCP input (`erx_tcp_input:dropafterack`): an out-of-window segment that
  knows only the four-tuple draws an ACK with no rate limit, as in FreeBSD
  (`tcp_input.c:3384-3395`), so a blind sender gets one ACK per segment it sends. Decide
  whether these ACKs share the challenge-ACK limit (`erx_tcp:challenge_ack/3`); RFC 5961
  section 10 leaves it open.

* [Medium] network, `erlang/apps/erx_net/src/erx_lltable.erl` (`room/1`): a learnt sender takes
  only free room, but an on-link sender whose spoofed packets draw a reply (an echo request, a
  segment to a closed port) makes this host resolve each source through `lookup_or_create/3`,
  which evicts the oldest unresolved entry (the default router's pending resolution among them),
  else in ARP a resolved neighbour in use, since only an entry in `verify` is ever hinted. And
  with the table full of learnt entries, this host's own resolutions push each other out, and a
  reply arriving after its entry went is no longer learnt. Ranking published entries never used
  ahead of this host's unresolved ones when making room, and an `erx_nd6` regression test beside
  `erx_arp_tests:learnt_sender_evicts_nothing_test/0`, are the next step; the gain is mainly for
  IPv6, as an on-link attacker can already overwrite ARP entries.

* [Low] network, `erlang/apps/erx_net/src/erx_nd6_rtr.erl`: an on-link sender that passes the hop-limit
  rule and fills the prefix list first with 16 autonomous prefixes of infinite valid lifetime holds the list
  until reboot, since only an advertisement of the same prefix shortens its addresses' lifetimes; later
  prefixes are ignored and counted. The design accepts that the lists can be filled first (requirement N4);
  RA Guard on the switch or a per-sender share of the list would bound it.
* [Medium] network, `erx_net_if_core` and `erx_lltable` (`docs/design-network-stack.md`, Residuals,
  "Resolution is shared between clients"): a client sending to many unresolved on-link addresses makes the
  interface hold up to 16 packets for each and, once the neighbour table's 1,024 entries are full, evict
  other clients' entries in resolution; the sender credit bounds only the rate of hand-overs. Bound it per
  grant: tag each hand-over with its grant, count the entries each grant's packets started, and drop a
  grant's hand-overs past a cap as lost frames.
* [Medium] network, grant limits (`abi/services/net.txt`, `erx_net_grant_core:new/1`): a net facet row's
  `sockets` and `buffers` are each bounded per grant, but nothing sums the grants' buffers, stated or default,
  against the network domain's memory (36 MiB on development.txt beside 16 MiB a grant by default), so grantees
  that fill their grants can exhaust it and restart the domain for all of them. And the grant and the mint
  (`erx_net_admit:mint/2`) read the limits, `ports` and `listen` among them, by atoms written by hand, falling
  back to the default for a missing key, so a parameter renamed in net.txt alone widens every row that states
  it to the default; and the least unprivileged port, 1024, is written both in `erx_net_grant_core`'s default
  and in net.txt's `net_unprivileged_port`, which the manifest check reads (`check_net_ports`). Sum the buffers per serving domain in
  net_grant, as property 18 sums pixel areas, and generate the key names and the port for Erlang from the
  ABI; the grant's portable modules include no ABI header, so the erXos runtime (`erx_net_erxos`) would
  hand them over.
* [Medium] network, sockets (`erlang/apps/erx_net/src/erx_net_grant.erl`, `erx_net_bind`,
  `erx_net_input:udp/3`): a socket bound to a specific address and a port takes that address's
  datagrams from a socket another domain bound to `any` on the same port, since input tries the
  specific binding first and the bind asks nothing of who holds the wildcard one; FreeBSD's
  `in_pcbbind_setup` refuses such a bind with `EADDRINUSE` when the wildcard socket belongs to
  another user. And within its `sockets` limit, 1,024 by default and at most 4,096, a grant can still hold a large share of the
  ephemeral ports or of the ICMP echo identifiers. Refuse a specific bind over another grant's
  wildcard one, as FreeBSD does across users.
* [Low] network, TCP TIME-WAIT (`erx_tcp_conn`, configured/1): a configuration change that
  leaves no path to the peer keeps the old path and its `loopback` flag, so a connection
  between two of the machine's own addresses whose address is then deleted still takes the
  20 ms TIME-WAIT, where FreeBSD's `in_localip` would now answer false and give 2MSL. Clear
  the flag when the path cannot be rebuilt. No remote peer can cause it.
* [Low] erx_net TCP ICMP and TIME-WAIT, inherited from FreeBSD: one forged too-big report
  that guesses a sequence number in flight (odds of the flight over 2^32) lowers the MSS for
  good, down to 216, and a sender stepping the MTU down by one byte per report forces a
  resend of the flight each time (RFC 5927 section 7 suggests further checks); a blind SYN
  with an older timestamp still recycles TIME-WAIT about half the time, as FreeBSD ORs
  RFC 6191's timestamp rule with the sequence rule; and a sender that knows the sequence
  numbers keeps TIME-WAIT alive with retransmitted FINs, as long as it keeps sending them
  (`erx_tcp_icmp`, `erx_tcp_timewait`).
* [Medium] erx_net TCP TIME-WAIT, the grant's `time_wait` limit (`erx_net_grant_core`,
  `erx_tcp_conn`): a connection in TIME-WAIT whose socket process is gone gives its buffers
  and its place among the grant's sockets back, and the `time_wait` limit that would bound
  such connections is not built, so a client that opens and closes connections first holds
  one TIME-WAIT process of the network domain's for each, 2MSL long, without bound. The
  limit is the design's ("TIME-WAIT", 4,096 by default): count TIME-WAIT connections in the
  grant's core and let a close past the limit skip TIME-WAIT.

* [Low] network, the portable `erx_bytes:siphash24/2` (`erlang/apps/erx_net/c_src/erx_bytes_nif.c`):
  a key at a bit offset is copied by `enif_inspect_binary` into a temporary block that ERTS
  frees without erasing, and the NIF API offers neither a way to erase it nor one to read the
  key in place. erXos's BIF erases its copy. The key term itself, in the caller's heap, is no
  more erased than any Erlang term, so the fix belongs with how keys are held in Erlang.


## Planned features

* [Low] network, a crash of a socket core's shell (`erlang/apps/erx_net_client/src/erx_gen_tcp.erl` and
  `erx_gen_udp.erl`): `format_status/1` redacts the `#data{}`, but a crash's stack trace never passes
  through it. A shell that ends on an action `perform/3` does not know, on a `{stop, Reason}` that is
  not the last action, or on a crash inside the core's `step/2`, logs a `function_clause` or `badmatch`
  whose top frame carries the remaining actions or the event and the whole `#data{}` or core, with the
  peer's bytes held or in flight: in gen_statem's termination report, whose stack trace it logs
  outside `format_status/1`, and in proc_lib's crash report, which also logs the mailbox (queued
  `erx_net` pushes) and the process dictionary. The exit reason `{function_clause, Stacktrace}` also
  reaches the shell's monitors and a waiting caller. Only a bug of a core reaches it. Fix: a logger
  filter in the client's domain that rewrites such reports to names, classes and arities, as the WiFi
  design's `erx_wifi_report` does (docs/design-wifi.md, "Security"); the Bluetooth domain's filter
  takes the same shape.

* [Medium] WiFi, the vault purpose for network keys
  ([design-wifi.md](design-wifi.md#credentials)): design-system.md
  does not yet list the vault purpose `{wpa, Service}`, with facet
  `wpa_key` for the WiFi domain and `wpa_admin` for the administrator's
  session template, taking the seven operations of design-wifi
  Credentials and kept as a sealed section of the machine's file. Add it
  to design-system.md#the-vault when the WiFi holder is built.
* [Medium] WiFi, who may enroll a network over Bluetooth
  ([design-bluetooth.md](design-bluetooth.md),
  [design-wifi.md](design-wifi.md#credentials)): design-wifi grants
  `wpa_admin` only to root's session template and keeps every passphrase
  in the session that typed it, while Bluetooth provisioning has the
  passphrase typed on a phone and handed on by a provisioning app.
  Decide with the provisioning design: name that app's template as a
  second `wpa_admin` grantee and state the passphrase path, or route
  provisioning through root's session.
* [Medium] WiFi supplicant cores (`erlang/apps/erx_wifi`, `erx_wpa_kdf`, `erx_wpa_key`;
  [design-wifi.md](design-wifi.md#the-supplicant)), left by the first slice:
  - the bytes the MIC covers have no independent oracle: a recorded message 3 from hostapd
    (a capture, or one built by hostapd's own code on the host) checked through `decode`,
    `mic_input` and `check_mic`, with a seeded fault; wpa_supplicant 2.12's tarball carries
    no such frame (its hwsim tests are not in it);
  - `build/4` takes an untyped `map()`: a caller that leaves out a key gets a `function_clause`
    whose arguments carry the KCK; a map type per message kind lets Dialyzer catch it;
  - the MIC input ends at the key data, while wpa_supplicant covers the whole EAPOL body
    (`wpa.c:4005`); a body longer than its key data fails the MIC (safe, but not
    wpa_supplicant's behavior);
  - whether a second RSN element in message 3 is allowed is checked against the standard (the
    codec refuses it);
  - the codec reads no Transition Disable KDE (the Wi-Fi Alliance's OUI, `wpa_common.h:155`),
    so `erx_wifi_join` reports no `{transition_disable, SSID}` ("The 4-way handshake"), and
    Verification's property and seed for it wait with it;
  - `erx_wifi_join` takes the station's own RSN element and RSNXE in the `join` request; nothing
    builds them from the candidate's AKM and PMF yet, which wants the RSN element's layout in
    `abi/formats/ieee80211.txt`;
  - SAE's secret half is not built: the key holder (`erx_wpa_holder` over `erx_wpa_arith`),
    `wlankey`'s hashed values (`erx_wpa_secret`) and `crypto`'s `sae_pt/3`, `sae_commit/5`
    and `sae_key/5` ("OTP's `crypto`: SAE's arithmetic"). `erx_sae`'s tests stand on
    `test/erlang/erx_sae_peer.erl`, whose arithmetic on Erlang integers matches Annex J.10's
    vectors; the holder's cases and seeds of Verification (the element not negated,
    `sae_key/5`'s `badarg` escaping, a keyseed salted with zeros whatever the list, the
    entropy seam's scalar of 1) and the recorded hostapd exchange wait for them. The call
    that performs a request to the holder belongs to the station's process;
  - `erx_sae` takes a password identifier in `new/1`, but `erx_wifi_join` passes none, since
    the choice's candidate does not carry the identifier the holder's names report;
  - SAE's `keying` state: no join-level case drives a holder's `bad_element` through
    `erx_wifi_join`, whose `sae_step/4` keeps the exchange a drop returns (reverting it to
    `{drop, Check}` fails no test), and the exploration's check that a counted drop changes
    nothing but `counts` would fail on that answer; and a drop carries no deadline, so a
    deadline met in `keying` followed by `bad_element` leaves no resend of the commit before
    the exchange's end, which the station's ordering of the holder's answers keeps from
    happening;
  - the join's state holds SAE's KCK while the exchange runs, so the station's process must
    keep it out of crash reports, `sys` and `/proc`, the first through the report filter
    `erx_report` its domain takes at boot;
  - the join's exploration derives an SAE join's PTK from its fixed PMK, not from the
    exchange's, which `erx_sae_tests` checks the holder and the access point agree on;
  - `erx_wifi_join`'s review left: the join is one map with `_ => _` whose association
    fields exist only after `join`, so Dialyzer cannot catch a missing one (a record or a
    map type per phase would); message 3's checks are spread over `eapol/4`, `message/5`,
    `protected_key_data/3` and `message_3/5` rather than one named sequence in the design's
    order; `{disconnect, Ref, Reason}` carries the machine's own reason, which wants one
    mapping to 802.11 reason codes ("RSN element different"); group message 2 goes out
    before the install it answers, as message 4 does, which the design's group paragraph
    does not state; `step/3` fails on an event kind outside the table, a contract the
    station's process must keep;
  - the join's exploration: no property says that once the access point has message 4 and
    every install is confirmed the port is open without another frame (liveness always
    starts a new handshake); the end of a rekey is not checked against the chip's
    confirmed slots as the port's opening is; the seed that removes `eapol`'s `open` cell
    is caught by liveness, not as an edge never taken, since the edge list is read from
    the seeded table;
  - hand-copied facts: `-type akm()` repeats the `ieee80211_akm` enum (the generator could
    emit a type per enum), and the 64- and 48-bit widths of the RSC, IPN and unwrap
    semiblock are written beside their layout counts.

* [Low] WiFi station's choice (`erx_wifi_choose`;
  [design-wifi.md](design-wifi.md#choosing-a-network)), left by its first slice:
  - the BSS record carries no group management cipher, so a PMF BSS that offers
    BIP-GMAC-256 rather than BIP-CMAC-128 is admitted and then fails its join; admission
    could refuse it `cipher_unsupported` once the scan's element parser reads that field;
  - the blocks a view holds must have every key filled in: `erx_wpa_conf` fills a parsed
    block over `erx_wifi_choose:default_block/0`, the one statement of the defaults, and
    a block without `priority` or `ieee80211w` is not refused by the choice itself;
  - the generated-view property counts none of the cases it reaches (picks, `bss` and
    `secret_failed` holds, SSIDs marked by the names), so a generator change that stops
    reaching one goes unnoticed.

* [Medium] network, the effect layer ([design-network-stack.md](design-network-stack.md#the-effect-layer)):
  the pure core is in `erlang/apps/erx_net/src`; the effect layer is not
  written. In order, host first: `erx_net_credit`, `erx_net_clock`,
  `erx_net_if_core`, `erx_net_driver` with `erx_net_pipe` and
  `erx_net_loop`, `erx_net_runtime` with `erx_net_local`, the processes,
  then `erx_net_vclock`, `erx_net_script`, `erx_net_impair` and
  `erx_net_relay` in the app's `test/`; `erx_virtio_net` and `erx_net_erxos`, which run in the
  network domain. Three things to confirm on
  the FreeBSD test host before its runs: that the test user can open `/dev/tapN` (a devfs rule) and
  the tap comes up on open (`net.link.tap.up_on_open`), that the bridge
  can put two jails behind separate tap devices for the relay's FreeBSD
  baseline, and that a stock OTP 29.1.2 builds there for the stack's
  host runs (29.1.1 is installed).
* [Low] network, the checks of `erx_bytes:inet_csum/2`'s starting sum, `siphash24/2`'s key and
  `inet_csum_update/3`'s binaries are written twice in C, in erXos's BIFs
  (`otp/erts/emulator/nifs/erxos/erx_bytes_bif.c`) and in the portable NIFs
  (`erlang/apps/erx_net/c_src/erx_bytes_nif.c`); the iodata walk has one copy. The shared probe
  (`test/fixtures/erx_net_bytes_probe.erl`) judges both, but a check its contract cases do not
  cover could make the builds disagree. Give the scalar checks one copy as pure helpers in
  `c_src` that both term layers call.
* [Medium] network, `erx_net` as a package of its own (N12 of
  [design-network-stack.md](design-network-stack.md#requirements)):
  lay `erlang/apps/erx_net` out by seam (`src/`, `erxos/`, `portable/`,
  `c_src/`, `test/`); move the stack's tests, fuzz targets and explorer
  from `test/erlang`, and the harnesses of `c_src/`'s cores from
  `test/fixtures`, into the app's `test/`, runnable on stock OTP from the
  app alone; drop `erx` from `erx_net.app.src`'s applications; put erXos's license notice beside `NOTICE-freebsd`; create
  `erlang/apps/erx_net_client`; and add the build check of N12, which
  covers `c_src/`'s `#include` lines too, with its seeded violation.
* [Medium] network, name resolution (`erlang/apps/erx_net/src/erx_net_if_core.erl`, `erx_net_grant`): the
  grant's `resolver` answer holds only what DHCP leases gave. Add static name servers and a search list to an
  interface's configuration, as rc.conf's resolver settings and `resolvconf` give FreeBSD, merged ahead of
  the leases' within the same limits, and router advertisements' RDNSS and DNSSL (RFC 8106) once IPv6's
  configuration runs.
* [Low] network, `erx_gen_udp` and `erx_gen_tcp` (`erlang/apps/erx_net_client/src`): where stock OTP 29.1.2
  takes `{ip, any}` and `{ip, loopback}` as a local address, the backends pass them to the socket's options,
  which refuse them with `einval`; and an IPv6 address given to `connect` or `send` on an IPv4 socket answers
  `einval` where stock answers `eafnosupport`. Take both local forms and answer `eafnosupport`, with a case
  each against stock's answers.
* [Low] network, `erx_gen_udp` (`erlang/apps/erx_net_client/src/erx_gen_udp.erl`): stock `inet` and
  `gen_udp` dispatch `setopts/2`, `getopts/2`, `peername/1` and `send/5` to the backend, which exports none
  of them, so `inet:setopts(S, [{active, once}])` on an `erx` socket raises `undef` in the caller, and
  `send/3` with a sockaddr map raises `function_clause`. Answer `{error, enotsup}` as
  `controlling_process/2` does, and `einval` for `send/3`'s other shapes, with a case each.
* [Low] network, `erx_gen_udp` (`erlang/apps/erx_net_client/src/erx_gen_udp.erl`, `erx_gen_udp_core`): a
  datagram socket keeps only `mode` and `active`, so `gen_udp:open(0, [{buffer, N}])`, `setopts` and `getopts` of
  `buffer` answer `{error, einval}`, where stock OTP 29.1.2 takes it (its default 9216, shown by `getopts`) and its
  `setopts` also takes `packet` and `packet_size`. Keep `buffer` with the meaning stock's driver gives it for a
  datagram, with a case against stock's answers.
* [Low] network, `erx_net` and `erx_net_client` (the socket protocol; design-network-stack, "Message sizes"): the
  protocol's bounds are written in each module that uses them: the 64 MiB credit bound in `erx_net_admit`,
  `erx_tcp_conn`, `erx_udp_sock`, `erx_icmp_sock` and `erx_gen_tcp_core`, the 64 KiB piece and the pieces of a push
  in `erx_net_admit`, `erx_sock_admit`, `erx_tcp_conn`, `erx_tcp_reass` and `erx_gen_tcp_core`. Give them one source: state them in
  `abi/services/net.txt` and generate a header both applications include, as the build's include flags already
  let one application include another's headers.
* [Low] network, edit 63 (`otp/lib/kernel/src/inet_db.erl`, `erx_rand_range/1`): `error:undef` stands for
  "stock OTP", so an erXos node whose `erx_bytes` failed its `on_load` would go back to the counter's
  guessable query IDs silently. Decide erXos by `os:type() =:= {unix, erxos}`, as `inet_config.erl` does,
  and raise on erXos for `undef` as for any failed read.
* [Low] network, `erx_udp_sock` (`erlang/apps/erx_net/src/erx_udp_sock.erl`, `from_peer/2`): an ICMP report
  passes the connected socket's peer filter and holds receive credit until a `recv` drops it, so a host that
  knows the port can fill the socket's 64 units between queries; drop reports on arrival, since the socket
  never delivers them.
* [Low] network, name resolution (`erlang/apps/erx_net_client/src/erx_inet.erl`): `erx_net_client` starts the
  resolver loader on every node whose `grant` key is set, a node outside erXos that sets it to
  `{erx_net, local_grant, []}` beside erx_net included, where it empties `resolv_conf` and replaces the host's
  name servers with the stack's leases'. Start the loader only where the grant is the node's resolver: on
  erXos, or where an `erx_net_client` key asks for it.
* [Medium] network, edit 54's rest (`otp/lib/kernel/src/inet.erl`,
  [design-runtime.md](design-runtime.md)): `inet:getifaddrs/0` and `inet:gethostname/0` take the
  `inet` backend's path, which `inet_backend/0` maps `erx` to, and answer from ERTS's own calls rather than
  ask the domain's network grant. Add the grant operations and the `erx` clauses, with tests on the host.
* [Low] network, `erlang/apps/erx_net/NOTICE-freebsd` and `erx_net_frame`'s header: they
  name `arpresolve_addr` of `sys/netinet/if_ether.c`, which neither the release nor the pin
  has; the broadcast and multicast link addresses `link_addr/2` translates are
  `ether_resolve_addr` of `sys/net/if_ethersubr.c` with the `ETHER_MAP_*` macros of
  `sys/netinet/if_ether.h`. Fix the entry and the module's FreeBSD headers to match.
* [Low] network, the interface's own frames on transmit
  ([design-network-stack.md](design-network-stack.md#residuals)):
  ARP and neighbour-discovery answers, RSTs and SYN-ACKs share the
  driver's transmit credit with clients' data, so a sender that keeps it
  full delays resolution and handshakes. A small share of the credit
  reserved for the interface's own frames would bound it.
* [Medium] network, `docs/design-network-stack.md`: the design does not yet
  settle sockets with several holders, which [design.md](design.md#networking)
  leaves to it; settle them before the POSIX socket protocol's code.
* [Low] WiFi, a release front end cannot read the verdicts
  ([design-wifi.md](design-wifi.md#control-and-inspection)): the
  verdicts, the saved networks and the failure reasons are `visible
  all`, and in a release build no session has the machine-wide scope
  ([design-live.md](design-live.md#inspection)), so a front end in
  root's session offers a passphrase for every protected network and
  cannot say which are saved or why a join failed; the system shell
  reads them. An inspection scope for the holder of a service's
  administrative facet would close it, a change to design-live.md's
  scopes.
