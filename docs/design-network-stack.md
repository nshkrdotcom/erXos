# erXos's TCP/IP stack

The network service runs erXos's own TCP/IP stack, written in Erlang, in
the network domain ([design.md](design.md#networking)). This document is
the stack's design: which process owns which state, how a packet travels
from the network driver to a socket's owner and back, how the protocols'
decisions are taken from FreeBSD, what a domain may do with its grant of
the service, what Erlang programs and POSIX programs see, and how the
stack is checked against FreeBSD's behaviour and stock OTP's.

Decisions every reader needs:

* **FreeBSD's decisions, translated; not its structure.** Every protocol
  decision comes from FreeBSD's default TCP stack, the function block
  named "freebsd", with CUBIC as the default congestion control, at the
  pinned commit `975e3605ebb1` of FreeBSD 16.0-CURRENT (`main-n285245`),
  the kernel the FreeBSD test host runs. The translation was read from
  FreeBSD 15.1 (tag `release/15.1.0-p6`, commit
  `95719d8a895bf8170851e9844d9b4092b1d2b6fe`); of what FreeBSD changed
  between that release and the pin, the changes the wire or an
  interoperating peer can see and the fixes of real bugs are ported, and
  nothing is re-translated to match the pin line by line. The line
  references in this document are to `release/15.1.0-p6`. Each Erlang
  function that translates a FreeBSD
  decision names the FreeBSD function it comes from. FreeBSD's locks,
  mbufs, epochs, virtual-stack indirection, sysctl registration and
  BlackBox logging are not translated: the construction below leaves them
  nothing to do. Where FreeBSD offers a knob, the stack does what
  FreeBSD's default does, unless this document states a departure and its
  reason.
* **One owner for each piece of state, one pure step for each owner.**
  Five kinds of process own all of the stack's state: an interface
  process per network interface, a connection process per TCP
  connection, a listener per listening socket, a datagram socket per UDP
  socket, and a grant process per client domain. Each decides by a pure
  function `step(Event, State, Context) -> {State, Actions}` and then
  performs the actions. Nothing else writes that state.
* **A socket is two processes, one on each side of the lane.** In the
  network domain the connection process holds the TCP state, and the
  interface process hands it segments, one local message per batch of
  frames. In the program's own domain a socket process, the shape of
  stock OTP's `gen_tcp_socket`, presents the stream as `gen_tcp` does:
  active modes, packet framing, `recv`. The socket process alone talks to
  the connection and alone sends the program the socket's messages, so
  stock `receive {tcp, S, Data}` code works in every domain. There is no
  process per layer.
* **Deadlines, not timers.** A connection's timers are deadlines in its
  state, as FreeBSD 15 keeps them and as every protocol core keeps them
  ([design.md](design.md#drivers-and-dma), "Deadlines in state"), and the process holds one Erlang timer at the earliest. A timer message is a hint to look at the clock, never
  an event in itself, so a late, early or duplicate one changes nothing.
* **Every packet queue is credited.** A process that hands packets to
  another does so only against a credit the receiver published. Every
  queue between the driver, the interface process and the sockets is
  bounded, and a refused hand-over is a drop counted where it happens.
* **Sequence numbers are plain integers.** A connection keeps sequence
  numbers and timestamps unwrapped, as unbounded integers, so ordinary
  `<` and `+` are correct everywhere in the protocol code. The only
  modular arithmetic is the conversion at the wire, in one module.
* **A domain's grant is a process of the network domain.** It is the
  domain's facet of the network service, holds the domain's limits and
  creates its sockets. Each socket acts for that domain alone and charges
  its work, on requests and on packets alike, to the grant's account.
* **Loss detection and congestion control are behaviours from the
  start,** `erx_tcp_loss` and `erx_tcp_cc`, mirroring FreeBSD's function
  block and its `struct cc_algo`, over one record of sent data that
  serves both FreeBSD's RFC 6675 recovery and RACK-TLP. The default
  stack is the reference; RACK-TLP and BBR are
  left for later, each a module behind these seams.
* **A run is the unit of TCP work, and C does only work that rides on
  bytes.** Output emits runs, segments that share one header, and the
  copy into each medium cuts a run into frames as it copies; the
  interface merges each received batch's in-order segments of one flow
  before it classifies them. A segment is a run of one, and the step it
  pays alone is lean
  ([The fast path](#the-fast-path)). Besides
  the cut and the merge, C does the Internet checksum and the SipHash
  keyed hash, per-byte primitives of the runtime. Every TCP decision is
  Erlang's; whether one needs native code is measured on this stack, on
  erXos's kernel.
* **The stack is an ordinary OTP application.** `erx_net` runs
  unchanged on stock OTP 29.1.2, outside erXos as well as on a
  development host, exchanging Ethernet frames through a pipe driver with
  real peers or with a test, under the real clock or a virtual one. Four
  seams separate it from erXos: the driver's transport, the clock with
  the entropy source, the per-byte primitives and the runtime's calls for
  grants. Each has an erXos implementation and a portable one, chosen by
  configuration, and the stack's own modules name neither
  ([The effect layer](#the-effect-layer)).

## Context

### What the stack matches

Three things fix the stack's behaviour.

* **The protocols, as FreeBSD implements them at the pin.** The stack
  takes FreeBSD's as its reference and translates its logic to Erlang,
  so its problems are not discovered from scratch: FreeBSD's decisions,
  not its structure, against one pinned tree ([Decisions](#decisions),
  9).
  FreeBSD's networking code is BSD-licensed, maintained, tested by
  FreeBSD's own TCP test suite, and is the UNIX that erXos follows where
  UNIX systems differ (CLAUDE.md, principle 5).
* **The Erlang API, as stock OTP 29.1.2 behaves.** `gen_tcp`, `gen_udp`
  and `inet` behave as stock does, as OTP's own suites check, run on
  erXos and on stock and compared case by case
  ([design-runtime.md](design-runtime.md#erlang-visible-behaviour)).
* **erXos's architecture.** The stack runs in the network domain, every
  connection is a process, per-packet work is Erlang and per-byte work is
  C, a received frame is copied once out of its device buffer, traffic
  that names no client spends a finite per-interface budget, and work for
  a client is bounded by that client's facet and lane
  ([design.md](design.md#networking)).

### Why FreeBSD's default stack

FreeBSD 15.1 builds three TCP stacks. The default, named "freebsd"
(`sys/netinet/tcp_subr.c:351-352`, installed as the default at
`tcp_subr.c:365`), has `tcp_default_output` (`tcp_output.c:186`) as its
output routine and `tcp_do_segment` (`tcp_input.c:1511`) as its segment
handler. Its default congestion control is CUBIC (`cc/cc.c:80-83`). RACK
and BBR are built as modules that a GENERIC kernel does not load; both
depend on the high-precision timer system (`tcp_stacks/rack.c:24671`,
`tcp_stacks/bbr.c:14824`), and each replaces the whole input and output
path rather than plugging into the default stack. BBR is Netflix's port
of BBR version 1.

By `wc -l` at the pinned commit, the default stack's core (`tcp_input.c`,
`tcp_output.c`, `tcp_subr.c`, `tcp_usrreq.c`, `tcp_syncache.c`,
`tcp_sack.c`, `tcp_reass.c`, `tcp_timer.c`, `tcp_timewait.c`,
`tcp_seq.h`) is 20,770 lines and its congestion control 2,081, while RACK,
BBR and the timer system they share, `tcp_hpts.c`, are 41,634.

The default stack is the reference: it is the stack FreeBSD runs and
FreeBSD's TCP test suite checks, its congestion-control seam is small,
and RACK and BBR are each a second TCP implementation that needs the
high-precision timer system and its own input path before it sends a
byte. Most of the default stack's volume is locking, mbuf handling,
sysctls, logging and kernel plumbing; what is translated is its
decisions. RACK is deferred: the default stack is the
reference, and RACK-TLP and BBR come later behind its seams. RACK-TLP
(RFC 8985) is then a loss-detection module over the send log, read from
`rack.c` for its logic and needing nothing outside its module; BBR is a
congestion-control module, which also needs pacing in output. Neither is
part of the stack this document designs
([Loss detection and congestion control](#loss-detection-and-congestion-control)).

### What a naive Erlang stack gets wrong

The aloha stack (github.com/yamt/aloha, commit `0aa96f14`, BSD-2-Clause)
was assessed as a base and rejected. Its faults are a checklist of what an
Erlang stack gets wrong when it starts from the RFC state diagram, and
each row names what in this design removes the fault.

| Fault in aloha | What prevents it here |
| --- | --- |
| one malformed frame crashes the interface process, which runs unsupervised | total decoders proved by fuzzing; the driver parses no frame; a raising step in the interface process drops the frame and keeps the state ([Concurrency and failure](#concurrency-and-failure)) |
| initial sequence number 0 | RFC 6528 in `erx_tcp_isn`, from FreeBSD's `tcp_new_isn` |
| any in-window RST resets the connection | RFC 5961 checks, from `tcp_input.c`, unconditional |
| a process per SYN, never expired | the syncache in the interface process, bounded, with SYN cookies ([Connection setup](#connection-setup)) |
| `rcv_nxt = Seq + 1` without wrapping; window arithmetic across the wrap | unwrapped sequence numbers ([The construction](#the-construction)) |
| any ACK overwrites the send window | the SND.WL1/SND.WL2 rule, translated |
| no congestion control, go-back-N, dropped out-of-order data | the default stack's loss detection, CUBIC, the reassembly queue |
| wall-clock RTT samples | the monotonic clock, passed to pure functions as an argument |
| a payload copied four times on transmit, checksum in Erlang | headers and payload kept apart until the device NIF's one copy, which also computes the checksum ([Checksums in the copy](#checksums-in-the-copy)) |
| unbounded neighbour cache and pending queue, unsolicited replies accepted | bounded neighbour tables in the interface process, FreeBSD's acceptance rules |

### What the stack stands on

The stack is two layers in one application, `erx_net`: the pure core,
the modules marked P in [Modules](#modules), which decide, and the
effect layer, the processes marked E, which read inputs, call the core's
steps and carry out their actions. Beneath them:

* **The per-byte primitives** `erx_bytes:inet_csum/2`,
  `inet_csum_update/3` and `siphash24/2`, BIFs of erXos's ERTS over
  portable C, and `erx_bytes:entropy/1`, Erlang's one entry to the
  kernel's generator, `erx_entropy_read`
  ([design-runtime.md](design-runtime.md#per-byte-primitives),
  [design.md](design.md#decisions)). Their C is `erx_net`'s own, in its
  `c_src/`. Outside erXos, the module of the same name in `erx_net`'s
  `portable/` directory loads that same C as a NIF library, and
  `entropy/1` there is the host's generator
  ([Two places, four seams](#two-places-four-seams)).
* **The device NIF**: `erx_device:post/4` takes one to four binary
  segments of one request and copies them into a pool buffer, and
  `erx_device:complete/2` returns up to 64 KiB of completed buffers as
  fresh binaries per call
  ([design-runtime.md](design-runtime.md#the-device-nif));
  `post_frame/5`, the network's form of posting, cuts a run into frames
  and finishes their checksums, and a delayed frame's, in that copy, and
  `complete/3` computes each frame's network sum in it
  ([Checksums in the copy](#checksums-in-the-copy)).
* **OTP's dispatch on module sockets.** `gen_tcp`, `gen_udp` and `inet`
  dispatch every call on a socket of the form `{'$inet', Module, Handle}`
  to `Module` (the `module_socket` macro, `otp/lib/kernel/src/gen_tcp.erl:261`
  and `otp/lib/kernel/src/inet.erl:469`), and `inet:gen_tcp_module/1` and
  `inet:gen_udp_module/1` choose the module from the `inet_backend`
  setting (`inet.erl:3289-3300`, `inet.erl:3409-3420`).
* **The runtime drops OTP's `socket` and `net` NIFs**
  ([design-runtime.md](design-runtime.md)), so in the network domain
  and in every client domain this stack is the only network
  implementation.

## Requirements

* **N1. Behaviour.** On the wire, the stack behaves as FreeBSD's
  default stack at the pin with its default settings, except where this
  document states a departure. The aim is a stack that interoperates as
  FreeBSD's does, not one equivalent to it line by line: every
  difference found by the oracles is a bug, a documented departure with
  a test, a FreeBSD bug recorded as such, or, since the oracle host
  tracks -CURRENT, a change FreeBSD made after the pin, recorded with its
  commit ([Decisions](#decisions), 9).
* **N2. API.** `gen_tcp`, `gen_udp` and `inet` behave as stock OTP 29.1.2
  on the host, as OTP's suites check; a POSIX program's sockets behave as
  on FreeBSD within the POSIX layer's tiers.
* **N3. Every connection is a process** of the network domain, which the
  inspector shows and the tracer can follow.
* **N4. Hostile packets.** No packet, sequence of packets or rate of
  packets crashes an interface, grows memory without a bound, creates an
  atom, or makes the stack do more than fail or drop traffic
  ([design.md](design.md#threat-model), the network peer's row).
* **N5. Bounded per client.** What one domain can make the network domain
  hold or spend is bounded by its grant; traffic that names no client
  spends a finite per-interface budget, and control traffic keeps making
  progress while excess is dropped, up to the frame rate one interface
  process can decode ([Residuals](#residuals)).
* **N6. Failure is local.** A malformed frame never kills an interface; a
  failed connection ends alone; a failed interface ends no connection; a
  network domain killed under load restarts, ending only its connections.
* **N7. Few hops, few copies.** A received segment reaches its connection
  through two local messages per batch, and a transmitted one reaches the
  driver through one; inside the network domain a frame is copied once on
  receive and once on transmit, both in the device NIF, and those copies
  compute the Internet checksum, so each byte of a TCP segment is read
  once on each path ([Checksums in the copy](#checksums-in-the-copy)). A
  delivery takes one local message more, in the owner's domain, from the
  socket process to the owner, and a call one local round trip, to the
  socket process; a stream's bytes cross between the domains with no
  reply in either direction.
* **N8. Functional core.** Every protocol decision is a pure function,
  tested on the host, and protocol state machines are explored
  exhaustively over an abstract alphabet to a stated depth.
* **N9. Seams.** Loss detection and congestion control are replaceable
  per connection without touching the connection's other code.
* **N10. Provenance.** Every module that translates FreeBSD code carries
  the FreeBSD files' copyright notices and license, and names the
  functions it translates, at the pinned commit.
* **N11. Testable on a host.** Every module of `erx_net` but the erXos
  implementations of its seams runs unchanged on stock OTP 29.1.2 on a
  development host, the processes included, so the whole stack is tested
  there against real peers and packet scripts before and beside the
  network domain on QEMU.
* **N12. Usable without erXos.** `erx_net` is an ordinary OTP
  application, with its own app file, that runs on stock OTP outside
  erXos, needing only `kernel` and `stdlib`, and outside erXos `crypto`
  for its portable entropy source; the client
  backends are a second such application, `erx_net_client`. What is
  erXos's is the erXos implementation of each seam, chosen by
  configuration, and no other module names it
  ([Two places, four seams](#two-places-four-seams)). `erlang/apps/erx_net`
  is self-contained, so that it can be released on its own: its license
  notices, erXos's and `NOTICE-freebsd`, and its host tests are inside
  the app directory, the tests run on stock OTP from the app alone, and
  nothing in its source refers to a path elsewhere in the erXos tree.

## The construction

The stack rests on four rules. Each removes a class of mechanism that
FreeBSD or a naive Erlang stack needs, and the rest of the document
follows from them.

### One owner, one step

Every piece of protocol state belongs to exactly one process:

| Owner | Process | State it owns |
| --- | --- | --- |
| an interface | `erx_net_if`, one per network interface | its addresses, its neighbour cache (ARP and IPv6 neighbour discovery) and the packets waiting on it, its routers and prefixes, its IP reassembly queues, its share of the syncache, its rate limiters |
| a TCP connection | `erx_tcp_conn` | the connection's control block (FreeBSD's `struct tcpcb`), its send and receive buffers, its reassembly queue, its socket process and the credit that process granted |
| a listening socket | `erx_tcp_listen` | its socket process, its accept credit, the connections queued for `accept`, each on a unit of that credit, and its waiting `accept` requests ([The listener](#the-listener)) |
| a UDP socket | `erx_udp_sock` | its receive queue, its options, its socket process and the credit that process granted |
| an ICMP echo socket | `erx_icmp_sock` | its echo identifier, its queue of echo replies, its owner |
| a socket as a program sees it | the socket process, `erx_gen_tcp` or `erx_gen_udp`, in the owner's domain ([The socket process](#the-socket-process)) | its owner, its active mode and presentation options, the bytes or datagrams it holds, the credit it granted, its requests in flight |
| a client domain's grant | `erx_net_grant` | the domain's limits, its account, its sockets' buffer reservations |

Each owner is a loop around one pure function of its kind:

```erlang
step(Event, State, Context) -> {State, [Action]}
```

`Context` carries everything from outside the process the decision needs:
the current monotonic time, the credit the transmit path offers, the
path's MTU and whether it has a route ([Framing](#framing)). The function reads no
clock, no ETS table, no process and no entropy source; it returns the
next state and a list of actions from a closed vocabulary (transmit
these frames, deliver these bytes, reply to this caller, end). The loop
reads the context, calls the step, performs the actions in order and
arms its one timer. The step
never sends, so an exception inside it leaves the state exactly as it was
before the event.

**Random values are state, not context.** Several decisions need random
values: the IPv4 identification of a non-atomic datagram and the IPv6
fragment identification, the starting point of the ephemeral port
search, an active open's IPv6 flow label, the delays and nonces of
neighbour discovery, duplicate address detection and MLD reports, the
reachable time, the jitter of the ICMP and RST rate limits, temporary
interface identifiers, and the DHCP client's transaction id and
retransmission jitter. FreeBSD calls `arc4random` at each of these
points. The stack instead keeps a random generator in the state of every
owner, a pure value of `erx_net_rand`:

```erlang
-opaque gen().                    % {Key :: <<_:128>>, Counter}
new(<<_:128>>) -> gen().
bytes(N, gen()) -> {binary(), gen()}.
uniform(Range, gen()) -> {0..Range-1, gen()}.
split(gen()) -> {Child :: gen(), gen()}.
```

Block `I` of a generator's stream is `erx_bytes:siphash24(Key,
<<(Counter + I):64>>)`, eight bytes, and every draw advances the counter
past the blocks it used, so no block is given twice. `uniform/2` reduces
one block modulo `Range`, a bias below `Range / 2^64`. `split/1` takes
the parent's next two blocks, 16 bytes, as the child's key and advances
the parent's counter past them: the child is `new/1` of those bytes, its
counter starting at zero, and no block of the parent's stream is both
drawn and used as a key, so no two children share a key. The stream is SipHash-2-4
used as a keyed pseudorandom function over a counter: its outputs reveal
neither the key nor later outputs, and it rests on the same assumption as
the initial sequence numbers and SYN cookies, which already depend on
SipHash keeping its key secret. A generator past 2^64 blocks raises,
which no owner reaches. OTP's `rand` is not used: its algorithms are
not cryptographic, and an observer of a few outputs can predict the
rest.

A step draws from the generator in its state and returns the advanced
generator with the rest of its state. So no step needs a random value it
was not given, and the context needs no random bytes: a draw never runs
out, a step that raises leaves the generator as it was, and a step's
result is a function of its event, state and context alone. A test fixes
a key and gets the same stream on every run; the host runners of the
packet scripts and the explorer do.

The keys come from the entropy source at the edge. Every owner a
supervisor starts (an interface process, a grant, `erx_dhcp4`) draws its
16-byte key with `erx_net_clock:entropy/1` in its initialisation. In the
network domain that is `erx_bytes:entropy/1`, the domain's one call into
the kernel's generator (`erx_entropy_read`,
[design-kernel.md](design-kernel.md#interrupts-time-and-entropy)); in a
virtual-time test run it is the test clock's seeded generator
([The clock](#the-clock)). Every owner the stack spawns (a connection, a
listener, a datagram socket) receives in its initial state a child split
from its spawner's generator, so a connection costs no kernel call for
its randomness, and a key seen in one owner's state predicts nothing of
its parent's or another owner's. `erx_net_tables` draws the stack-wide
secrets, for initial sequence numbers, timestamp offsets and SYN
cookies, from the same call. A failed read raises in the owner's
initialisation, so a process that cannot draw its key does not start,
as ERTS refuses to start without its reference key
([design-runtime.md](design-runtime.md#unguessable-references)), and no
owner falls back to another source; its supervisor restarts it. On
erXos's kernel the generator is ready before any domain runs, so a read
fails only on Fiasco, when its backend cannot reach its generator
service. In
deterministic mode the kernel's generator is fixed, so the whole stack's
random values repeat from boot to boot.

Because no state has two writers, there are no locks, no reference counts
and no epochs: a connection's end is its process's exit, and a pid that
names a dead process names nothing ([design-domains.md](design-domains.md#invariants), D1).
Other processes read only what an owner publishes in an ETS table: the
demultiplexing entries, each held by one socket, and the interfaces,
addresses, routes and neighbour entries, each written by its interface
([What owners publish](#what-owners-publish)).

### Deadlines, not timers

FreeBSD 15 keeps an array of deadlines in each control block and one
callout set at the earliest of them (`tcp_timer_next`, `tcp_timer_enter`
and `tcp_timer_activate`, `tcp_timer.c:854-935`). The stack keeps the same
shape. A connection's state holds its deadlines (retransmission or
persist, keepalive, delayed ACK, 2MSL, which also ends FIN-WAIT-2, and
whatever the loss-detection module asks for);
`erx_tcp:next_deadline/1` returns the earliest. After
every step the process makes sure one hint is armed no later than that
deadline, through `erx_net_clock:arm/1` ([The clock](#the-clock)): it
arms one when none is outstanding or the deadline is earlier than the
outstanding one, and otherwise leaves the outstanding one, which may then
arrive early. When a hint arrives, the process calls `step({expired, Now}, ...)`,
which runs every deadline at or before `Now` and does nothing for the
rest.

A timer message carries no meaning of its own, so there is nothing to
cancel and no stale message to recognise: restarting the retransmission
timer on an ACK is a field update, and a timer that fires early is a
look at the clock that finds nothing due. FreeBSD's rule that the
retransmission and persist timers are never both armed becomes a type:
`send_timer :: none | {rexmt, Deadline} | {persist, Deadline}`. The
count of timeouts in a row, `t_rxtshift`, is a field of its own,
`rxtshift`, since FreeBSD keeps it when the timer stops on an ACK and
resets it only on an RTT sample, an undone spurious timeout or the end
of persist.
The interface process keeps its deadlines (neighbour retries, reassembly
lifetimes, syncache retransmissions, router and prefix lifetimes) the
same way.

### Credited queues

ERTS bounds no mailbox, and a stack under attack is a set of mailboxes
that someone else fills. So no stack process hands packets to another
except through `erx_net_credit`:

* The receiver creates an `atomics` counter (for a connection the
  interface starts, the interface creates it) and publishes it with its pid:
  the driver in its interface record, a connection or socket in its
  demultiplexing entry, and an interface two counters in its interface
  record, one for its driver's batches and one for what senders hand it.
* A sender adds the units it is about to send (frames, segments or
  bytes, as the receiver chose) with `atomics:add_get/3`. If the result
  exceeds the receiver's limit, it subtracts them again and does not send.
* The receiver subtracts the units of each message it takes. A receiver
  that takes several queued messages into one step subtracts their units
  once the step is done, so the counter bounds what waits and what it
  steps together, and the batch never exceeds the limit
  ([One step per mailbox](#one-step-per-mailbox)).
* A sender that reserved units it does not send, for a frame it then
  drops or a hand-over it abandons, subtracts them again.

Every queue between driver, interface and socket is therefore bounded by
construction, and a full queue drops at the sender, which counts the drop
by reason. Only a sender killed between its reservation and its send
leaves units it never sent: an interface process on a socket's counter, a
connection on the driver's, and either of them on a listener's accept
credit before the connection's notice reaches the listener
([The listener](#the-listener)). Each such death strands at most one
hand-over, a counter is made anew when its receiver restarts, and nothing
in the network domain kills a connection or an interface process except a
fault or a test ([Residuals](#residuals)).

For TCP the transmit credit is an input of the step: when the
driver's credit runs out mid-output, the step does what `tcp_output` does
on `ENOBUFS` (`tcp_output.c:1690-1693`): it sets the congestion window to
one segment and leaves the retransmission timer to recover.

The same rule bounds what a remote peer can queue at a connection: a
connection that falls behind fills its credit, and the interface drops
further segments for it, which the peer's congestion control sees as
loss.

The rule crosses the lane unchanged, except that an `atomics` counter
cannot be shared between domains: a socket pushes to its socket process
only within the credit that process granted it by message, counted in
bytes for a connection and for a datagram socket alike
([The socket process](#the-socket-process)). So what a socket's owner
does not read waits in the socket, inside its receive buffer or queue,
and never in a mailbox.

### Packets become checked records once; sequence numbers are integers

A frame is decoded exactly once, in the interface process, by a chain of
total decoders, one per layer, each returning `{ok, Record, Rest}` or
`{error, Reason}` and never raising. Each decoder checks its lengths
against the layer that contains it, so no protocol code ever sees an
unchecked length or a raw header. Fields are integers and binaries;
protocol numbers are compared with macros, and the only atoms a decoder
returns are its own error reasons, a closed set.

A decoder whose layer carries a checksum checks the checksum first and
then decodes; there is no decoder that skips it. The Ethernet, ARP and
IPv6 decoders have no checksum to check. The IPv4 decoder checks the
header checksum, whose cost does not grow with the frame, before it
reads any other field but the version and header length. FreeBSD's
`ip_input` reads the source and destination first, for its RFC 1122
check that no loopback address arrives on the wire
(`ip_input.c:516-524`), and checks the header checksum next
(`:526-544`), so a frame with a loopback address and a bad header
checksum is counted as a bad address there and as a bad checksum here: a
departure in a counter, with nothing on the wire changed. The TCP, UDP
and ICMPv6 decoders take the pseudo-header's partial sum and check the
sum over the whole segment, datagram or message; the ICMPv4 decoder
checks the sum over the message alone, as RFC 792 defines it and
`icmp_input` computes it (`ip_icmp.c:500`), since only ICMPv6 has a
pseudo-header (RFC 4443, section 2.3; `icmp6_input`, `icmp6.c:505`).
Each checks a sum whose cost grows with the message's length. These four
decoders, and ARP's, so that every frame takes one
path, run later than the Ethernet and IP decoders, after the frame has
reserved room at its destination ([Receiving](#receiving)): the layer
above IP is still decoded once, but not until something has room for
it. Until then the frame is a `pending()` value of `erx_net_input`: the
decoded link record, the decoded IP record when the frame has one (an
ARP frame has none), the bytes of the layer above, and the fields that
choose its destination. A
segment, datagram or ICMP record exists only as the result of its
checksumming decoder, so no step can be handed one whose checksum was
not checked; the one exception is an IPv4 UDP datagram that carries no
checksum, which RFC 768 allows. The UDP decoder takes the IP version
and applies the rules that differ by it: over IPv4 the bytes past the
UDP length are cut off and a zero checksum field means none, as in
`udp_input`; over IPv6 the UDP length must equal the payload length and
the checksum field must be nonzero, as in `udp6_input`. The encoders
take the pseudo-header's partial sum with its length field zero and add
the length themselves, since only an encoder knows its segment's length
before it encodes; the length is one 16-bit word of either pseudo-header.

Inside a connection, sequence numbers, acknowledgement numbers, SACK
block edges and timestamps are **unwrapped**: unbounded integers that
count from the initial sequence number without ever wrapping. A
connection would have to move 2^59 bytes before its values left
ERTS's small integers. The conversion lives in `erx_tcp_seq`, which has
two functions:

* `lift(Wire32, Reference)` returns the integer congruent to `Wire32`
  modulo 2^32 that lies nearest `Reference`. A received segment is lifted
  as the first stage of its step: its sequence number against `rcv_nxt`,
  its acknowledgement and SACK blocks against `snd_una`, its timestamp
  value against the last one recorded.
* `wire(Integer)` returns the low 32 bits for encoding.

The lifted segment is a different record from the decoded one, so the
step cannot confuse a wire number with a lifted one. After lifting, the
protocol code uses ordinary comparisons. FreeBSD's `SEQ_LT` family of
macros (`tcp_seq.h`) and the flags that guard against their wrap become
unnecessary: for example `TF2_NO_ISS_CHECK`, which FreeBSD sets once
`snd_una` is far enough past the initial sequence number that a modular
comparison with it means nothing (`tcp_input.c:2416-2441`), stops being
a stored flag. Since `snd_una` never decreases, the condition FreeBSD
latches is a comparison of the state, and the acceptable
acknowledgement's lower bound is FreeBSD's, without a wrap guard:
`snd_una - max_sndwnd` once `snd_una >= iss + (65535 bsl snd_scale)`,
and `max(iss + 1, snd_una - max_sndwnd)` before. So an acknowledgement
of exactly `iss`, possible only once `snd_una - max_sndwnd` has reached
it, is an old acknowledgement here as in FreeBSD, not a challenged one.

Modular comparison is not an order: at a distance of 2^31 two numbers are
each "greater" than the other. Lifting makes the order total, so a
segment whose numbers lie about 2^31 from the connection's can take a
different branch than in FreeBSD. Both outcomes refuse the segment; the
packet scripts and the explorer pin which acknowledgement, if any, the
stack sends ([Verification](#verification)).

### What disappears

| FreeBSD mechanism | Why the stack has none |
| --- | --- |
| `INP_WLOCK`, `INP_RLOCK`, the pcb-info and hash locks, lock-order rules | one owner per control block; shared tables are written by their owners only |
| `NET_EPOCH`, `in_pcbref`/`in_pcbrele`, "returns NULL if the pcb was freed" conventions of `tcp_close` and `tcp_drop` | a connection ends by exiting; a dead pid names nothing |
| callout stop and drain races, `tcp_timer_stop`'s deferred free | deadlines in state; a timer message is a hint |
| mbuf chains, `m_pullup`, `M_PREPEND`, socket-buffer compression | binaries, sub-binaries and lists of them |
| `SEQ_LT` and friends, wrap-guard flags | unwrapped integers |
| `arc4random` called from inside each decision | a generator in each owner's state, drawn from like any other field |
| virtual network stacks (`VNET`) | one stack per network domain |
| sysctl registration | the `erx_net` application's environment, and per-socket options |
| syncache buckets, per-bucket locks and callouts | one bounded table per interface process, one deadline |
| the function-block registry and aliasing (`tcp_subr.c:392-740`) | a closed table of loss and congestion modules |
| BlackBox logging, DTrace probes, `tcp_pcap` | every connection is a process the inspector and tracer see |

## Processes and the packet path

### The process tree

```text
erx_net_sup  (one_for_one, intensity 0: restarts nothing)
 |- erx_net_tables          ETS tables, secrets, port-mapper names;
 |                          monitors each interface, deletes its rows
 |- erx_net_grants  (simple_one_for_one, temporary children)
 |   |- erx_net_grant        one per client domain; traps exits
 |       ~ linked, not supervised: erx_tcp_conn, erx_tcp_listen,
 |         erx_udp_sock, each acting for that grant's domain alone
 |- erx_net_interfaces  (one_for_one)
 |   |- link supervisor per interface, its id the interface's name
 |       |                   (vtnet0 ...), permanent; rest_for_one; a lent
 |       |                   link (wlan0) is temporary, started by its offer
 |       |- the driver       erx_net_driver over its transport: erx_virtio_net or erx_genet,
 |       |                   erx_net_ether for a medium another domain lends,
 |       |                   erx_net_loop for loopback, or erx_net_pipe on a host
 |       |- erx_net_if       the interface process
 |       |- erx_dhcp4        when the interface is configured for DHCP
 |- erx_epmd                the port mapper for exposed domains
 |- the runtime's children  erx_net_runtime:children/1: the node's grant
                            `local`; on erXos also the mints of `net` and of
                            `network_ctl`, the driver-control facet
```

Every child of `erx_net_sup` is permanent, and the supervisor restarts
none: the end of any of them, `erx_net_interfaces` giving up included,
ends the stack, standalone and on erXos alike. On erXos the application
is permanent in the network domain, so the stack's end ends the domain,
and the domain service restarts it, which grants the device and every
client again. A restart at the top would do less well whatever it
restarted: minted grants are temporary and are not made again, so a
restart of the grants' supervisor, or of the tables they subscribed to
in `init`, would leave clients without the network; and a restarted mint
names itself after the domain's ready report, which no report carries,
so the domain would mint nothing more. Ending the stack leaves no list
of which restart destroys which grant to keep right.

`erx_net_tables` owns the shared ETS tables, so a crash of any other
process loses no table. Ordinary failures stay below the top. A driver
restart resets its device
([design-runtime.md](design-runtime.md#the-device-nif)) and restarts its
interface process, which loses only soft state: neighbour entries,
reassembly queues and half-open handshakes, which peers retransmit. The
rows a stopped interface published go with it
([What owners publish](#what-owners-publish)). A driver ends when its
medium does, and is its link supervisor's significant child, so the
whole link ends with it and the interfaces supervisor starts it again;
a driver lives a second at the least, which bounds how fast a dead
medium restarts its link, and the interfaces supervisor's intensity is
set to the most its links reach at that rate ([Ending](#the-driver)).

A link is also what the network domain's driver-control facet,
`network_ctl`, stops, starts and restarts for the system domain
([design-system.md](design-system.md#the-holders-driver-control-facet)).
Its units map the manifest's unit `net` to `{erx_net_interfaces,
Name}`, the link of the interface whose transport drives the domain's
network device, which that transport names after the device as FreeBSD
names a driver's units: `vtnet0` of `erx_virtio_net`, `genet0` of
`erx_genet`. A link another domain lends through `ether`, `wlan0`, is no
unit of the network domain, and `network_ctl` never names it
([design-wifi.md](design-wifi.md#the-ether-interface-and-wlan0)). The
runtime reads the name from the interfaces `children/1` is given, so no
second list of names exists. With no network device or several, `net`
names no link and every request is refused. The link, not its temporary
driver, is the controlled object: a permanent child with a stable id, so
a stop leaves its place and a start builds the driver, the interface and
the DHCP client again in order, touching no grant and not the domain.

Connections, listeners and datagram sockets are never restarted, since a
restarted TCP connection would be a different connection: each is a
`proc_lib` process running the `gen_server` loop, linked to its grant,
so the grant's end ends it and its crash is reported to the grant. The
grant traps exits, so a socket's crash ends only that socket.

### What owners publish

Every table one process writes and another reads is an ETS table of
`erx_net_tables`, so a writer's crash loses no table, and every row has
one writer, the owner of the state it shows:

| Table | Row | Writer | Readers |
| --- | --- | --- | --- |
| `erx_net_ifs` | one per interface: its name and pid, which every other row it writes names; its two credits, for its driver's receive batches and for what senders hand it; its driver's pid and credit; its link (`ethernet`, or `none` for loopback), link-layer address, MTU and `finish`, from the driver's answer to the interface's attach ([The driver](#the-driver)); its IPv6 link MTU and hop limit | the interface | every sender; every interface's view |
| `erx_net_addrs` | an address, with its interface's pid and the place the interface added it in | the interface that owns it | every interface's view; every sender's source choice; the grant's `addresses` check |
| `erx_net_routes` | a route, with its interface's pid | the interface it leaves through | every sender |
| `erx_net_neigh` | a neighbour the transmit path may address, keyed by the interface's pid and the IP address: its link-layer address, `fresh` or `stale`, and a hint count | the interface, from `erx_lltable`'s `publish` and `unpublish` actions | connections and datagram sockets |
| `erx_net_gen` | one counter, the configuration generation | every writer of the first three tables; `erx_net_tables` | every reader of the first three tables |
| `erx_net_demux` | a demultiplexing entry ([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)) | `erx_net_bind`, for the socket that holds it | interfaces, through `classify/2` |
| the secrets | the ISN, timestamp and cookie keys | `erx_net_tables` | interfaces; `erx_net_bind` |

The first three are the stack's configuration, and a writer increments
the configuration generation after each change of its rows. A reader
reads the generation first and the rows after it, through
`erx_net_tables:configuration/0`, and keeps what it builds from them (an
interface's view, a sender's path, the grant's list of local addresses)
with that generation; it reads again when the generation differs. A
reader that raced a writer may build from rows newer than its
generation, and then finds a newer generation at its next read, so every
copy follows a change within one read, and nobody locks. The generation
and a neighbour row's hint count are the only fields with several
writers; like a credit counter, each carries a count and nothing else.

The generation moves only when something a path, a view or a source
choice is built from moves. An address row carries the address's flags,
`deprecated` among them, and no lifetimes: the interface keeps the
preferred and valid deadlines in its own state, sets `deprecated` when
the preferred deadline passes, as `nd6_timer` sets `IN6_IFF_DEPRECATED`
(`nd6.c:984-987`), clears it when an advertisement makes the address
preferred again (`nd6.c:1041`), and deletes the row when the valid
deadline passes. A router advertisement or a DHCP renewal that only
moves deadlines later therefore changes no row, and an on-link sender
repeating advertisements makes no reader rebuild anything. Source
selection reads the flag where `in6_selectsrc` tests
`IFA6_IS_DEPRECATED` against the clock (`in6_src.c:358-361`); the two
differ only by the time the interface takes to act on its own deadline.

**Rows end with their writer.** Every row an interface writes names its
pid, the incarnation that wrote it. `erx_net_tables` monitors each
interface process from its start, as it monitors every grant for its
sockets' entries
([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table));
when the interface stops, however it stops, `erx_net_tables` deletes
every row of the four interface tables that names that pid and
increments the generation. No path built after the generation moves
uses a row of a stopped incarnation, even before that deletion: the
configuration snapshot keeps an address or route row only when its pid
is the one its interface's `erx_net_ifs` row holds, and a transmitter
looks a neighbour up under the pid of the interface its path holds. The
generation moves when the new incarnation writes its `erx_net_ifs` row
or when the deletion runs, whichever comes first; a path built before
that sends as the old incarnation would have, and its hand-overs to the old pid are lost as a dropped
frame is, until its next pass. So no link-layer address an old
incarnation learnt is used beyond one pass of each sender, and a DHCP
lease that ended with its `erx_dhcp4` leaves no address or route behind.
The pid lets the deletion match the old incarnation alone, since the new
one may publish before the old one's monitor message arrives; the
monitor ends the rows of an interface that never comes back.

Nothing else is published. The syncache and its cookies-only state, the
neighbour tables with their held packets, the reassembly queues and the
rate limiters are the interface's own state, which only its own step
reads.

### Receiving

A TCP segment for an established connection whose owner is in client
domain D:

1. **Device to driver.** The device writes a frame into a pool buffer.
   On the driver's interrupt message it calls `erx_device:complete/3`,
   which copies up to 64 KiB of completed frames into fresh binaries:
   the one per-byte copy of the receive path, which also returns each
   frame's network sum ([Checksums in the copy](#checksums-in-the-copy)).
   The driver strips the device's own header (virtio's `virtio_net_hdr`)
   and sends the batch to the interface process in one message, against
   the interface's receive credit ([The driver](#the-driver)). It parses
   nothing else, as sDDF's split of driver and protocol prescribes
   ([design.md](design.md#drivers-and-dma)).
2. **Interface: merge, classify, reserve, verify.** The interface first
   merges the batch: consecutive in-order segments of one flow, by the
   rule of FreeBSD's large receive offload, become one merged segment
   that stands where its first frame stood, passes every step below as
   one frame with its first and last frames verified, and takes one unit
   of its connection's credit for each segment it holds
   ([The fast path](#the-merge)).
   For each frame, a reassembled datagram alike, the interface runs two
   pure functions of `erx_net_input` around one effect. `classify/2`
   decodes the Ethernet and IP layers and looks up the fields that
   choose a destination ([Classifying a frame](#classifying-a-frame)):
   `owned` by sockets, `local` to the interface, or `drop`. An owned
   frame then takes one unit of each destination's credit, and a local
   frame one token of the interface's ingress bucket
   ([Untrusted input](#untrusted-input)); a frame that finds neither is
   dropped and counted. Only a frame that holds its unit or token reaches
   `verify/1`, which runs the decoder of the layer above IP, or ARP's:
   for TCP, UDP, ICMP and ICMPv6 the checksum first, from the frame's
   network sum, then the header and options. A frame that fails gives its
   unit or token back and is dropped. So a frame dropped for want of room
   costs a header decode and one lookup, whoever it names, on every
   transport whose copy sums; on the pipe, whose frames come without a
   sum, each frame costs the read of its bytes ([Residuals](#residuals)).
   Neither credit nor the ingress bucket bounds the checksum work on
   frames that fail it: they are checksummed at the rate the link
   delivers them, as FreeBSD checksums every frame it receives. The
   fields `classify/2` reads are the only ones read before their
   checksum is checked, and they are used for the lookup alone: a local
   frame is answered only from its verified item, so a segment with a bad
   checksum to a closed port draws no RST, as in FreeBSD.

   FreeBSD checks every checksum before its lookup (`tcp_input.c:744-748`
   before `in_pcblookup_mbuf` at `:881`; `udp_input`'s check at
   `udp_usrreq.c:554-586` before its lookup at `:624`). Checking after
   the reservation is a departure in order only: a frame with a bad
   checksum is dropped either way and nothing on the wire differs, but a
   corrupted frame that also found no room is counted as dropped for want
   of room, where FreeBSD counts it as a bad checksum. The order keeps
   the cost the interface process, the classifier for every client,
   spends on each frame it drops for want of room constant
   ([Residuals](#residuals)).
3. **Interface to connection.** The owned items of one batch are grouped
   by destination, and each destination gets one message holding its
   items in arrival order and naming the interface, against its credit.
   The items' payloads are sub-binaries of the frames, a merged
   segment's the list of its frames' payloads, so nothing is copied.
4. **Connection.** The connection takes every items message waiting in
   its mailbox and folds `erx_tcp:step/3` over their segments one at a
   time, a merged segment as one, as FreeBSD processes one segment, or
   one LRO packet, at a time
   ([The fast path](#one-step-per-mailbox)).
   It then sends all frames and runs the steps produced to the driver in
   one message, pushes the in-order data its socket process has credit
   for, in pushes of at most one piece of 64 KiB each
   ([Message sizes](#message-sizes)), replies to its requests and re-arms
   its timer.
5. **Connection to socket process.** The push is
   `{erx_net, Conn, {data, Pieces}}`, `Pieces` the receive queue's
   binaries as they are, a frame on the lane from the network domain to
   D, decoded by D's funnel and delivered as
   `{erx_origin, Net, {erx_net, Conn, {data, Pieces}}}`.
6. **Socket process to owner.** The socket process checks the push and
   presents it as its options say: in active raw mode as one
   `{tcp, Socket, Data}`, its pieces joined into one binary, a local
   message in D ([The socket process](#the-socket-process)).

### Classifying a frame

`erx_net_input` is the receive decision of FreeBSD's `ether_demux`,
`ip_input`, `ip6_input` and the pcb lookups of `tcp_input_with_port`,
`udp_input` and the protocols' ICMP handlers, taken as far as choosing
where a frame goes and no further. Its input is a frame from the driver
with its network sum or none, a looped IP packet with its zone
([Loopback](#loopback)), or a datagram reassembly rebuilt. Its view,
which the interface core rebuilds when the configuration generation
changes, holds the link, every address of the stack with its zone (the
weak end-system model accepts any of them on any interface), the IPv6
groups the interface joined (all-nodes and the solicited-node group of
each of its addresses, tentative ones included), whether it runs DHCP,
and the demultiplexing lookup, the only shared state `classify/2` reads:
`ets:lookup/2` in the interface, a map in the tests and the fuzz target.

**Zones.** Inside the stack an IPv6 address of link-local or
interface-local scope, unicast or multicast, never travels without its
zone: it is the pair of the address and the interface it belongs to, as
FreeBSD embeds the zone in the address itself (`in6_setscope`,
`sa6_embedscope`, `scope6.c:322-352`), and every other address is its
bytes alone. A received packet's addresses take the zone of the
interface it arrived on; a looped packet's take the zone its sender's
path gave it, which the loopback interface carries in front of the
packet as `nd6_output_ifp` hands the loopback interface the original
one (`nd6.c:2226-2229`); the addresses an ICMPv6 error quotes take the
zone of the packet that carries them. The view's address lists, the
demultiplexing keys and a path's destination all hold zoned addresses,
so "is this address ours" and "whose key is this" compare the zone with
the address: two sockets bound to `fe80::1` on port 80 of two interfaces
hold two keys, and a segment from a link-local peer on one interface
never matches a connection made on another. A scoped address given
without its zone is no address of the stack, as FreeBSD's lookup finds
none for it.

A fragment keeps its zone and its frame's link cast through reassembly,
and `erx_ip6_reass` keys a datagram by its zoned source and destination
and its identification, so fragments that arrived in two zones never
join, as FreeBSD's embedded zone keeps them apart in `frag6_input`'s
hash. The rebuilt datagram takes the zone and the link cast of its
fragment at offset 0, as `ip_reass` and `frag6_input` keep that
fragment's packet header; IPv4's zone is always `none`. A datagram
whose lifetime ends returns its first fragment with that fragment's
zone, and only a first fragment that came as a link-layer unicast, since
`icmp6_error` answers none of the others (`icmp6.c:309`); a parameter
problem carries its packet's zone, so the ICMPv6 error either sends goes
back to the zoned source.

Classification runs in three steps:

1. **Link.** On Ethernet, a frame to the interface's address is
   `unicast`, one to the broadcast address `broadcast`, one with the group
   bit `multicast`, and any other is dropped as `other_host`, as
   `ether_input` drops it without promiscuous mode; an EtherType other
   than IPv4, IPv6 and ARP is dropped as `ethertype`. On loopback the
   frame is the IP packet with its zone, `unicast`, its family read from
   the version.
2. **IP.** On an interface configured for DHCP, an IPv4 packet whose
   header decodes, that is not a fragment, and that carries UDP with at
   least a UDP header's 8 bytes to port 68 is `local`, for the DHCP path,
   before any address check. This is the test of `dhclient`'s receive
   filter, which sees every frame ahead of `ip_input` (`dhcp_bpf_filter`,
   `bpf.c:188-251`). That filter tests only the fragment offset, so it
   also passes a first fragment; erXos takes only a whole packet, since a
   DHCP message fits in one frame, and a fragmented one is reassembled
   and classified like any other datagram, without the DHCP path. A
   unicast offer to the address being offered passes it although that
   address is not yet the stack's. Every other packet goes to
   `erx_ip4:input/3` or `erx_ip6:input/4`, whose drop is the verdict; a
   fragment and a parameter problem are `local`. A datagram to an IPv6
   group the interface has not joined, or to any IPv4 group, is dropped
   as `not_member`: the core joins no IPv4 group, and `erx_mcast` adds
   sockets' memberships to the view.
3. **Above IP.** Only the fields the table names are read:

| Datagram | Fields read | Verdict |
| --- | --- | --- |
| TCP | ports | the connection's key: `owned`. Else a listener's key: `local` when both the frame's link cast and its destination's class are `unicast`, else dropped as `bcast_tcp`, as `tcp_input` drops a link-layer broadcast or multicast for a listener (`tcp_input.c:1288`) and a SYN to a broadcast or multicast address before `syncache_add` (`tcp_input.c:1326-1338`), and `tcp_dropwithreset` answers neither when SYN is clear (`:3450-3471`), with one departure: an ACK or RST of a handshake in a link-layer broadcast or multicast frame is dropped too, where FreeBSD's `syncache_expand` and `syncache_chkrst` see it first (`:1081`, `:1175`); the checks there that read the four-tuple alone, a connection to or from itself, a multicast source and the limited broadcast as source (`tcp_input.c:1295-1338`), are the syncache's, on the verified item. Else `local` if it may be answered (a RST), else dropped as `no_reply` |
| UDP | ports | the holders of its keys, most specific first, reduced by `erx_udp:input/3`: `deliver` is `owned` by those sockets, `port_unreach` is `local`, `{drop, no_port}` the verdict |
| ICMP or ICMPv6 error | type; the quoted protocol, addresses and ports | the quoted datagram, which the stack sent, read with its source as the local end: a TCP connection's key or a connected UDP socket's key is `owned`; a TCP listener's key is `local`, for `syncache_unreach`; else dropped as `no_socket`, and a quote the decoder refuses is dropped with its reason |
| ICMP echo or timestamp request, ICMPv6 echo request | type | `local` if it may be answered, else dropped as `no_reply` |
| ICMP redirect; ICMPv6 router and neighbour messages, redirect, MLD query | type | `local` |
| ICMP echo reply | type; the identifier | the key of the echo socket that holds the identifier: `owned`; else dropped as `no_socket`, and a reply shorter than the echo header as `too_short`. `verify/1` checks its checksum and length, so the socket receives only whole replies |
| any other ICMP or ICMPv6 type | type | dropped as `icmp_type` |
| ARP | none | `local` |
| any other protocol | protocol | `local` if it may be answered, for the protocol unreachable `rip_input` sends (`raw_ip.c:410`) or the parameter problem at the next-header byte `rip6_input` sends (`raw_ip6.c:321-324`); else dropped as `no_reply`. IPv6's No Next Header is dropped as `no_next_header`, as `rip6_input` frees it unanswered |

A datagram too short to hold the fields its row reads is dropped as
`too_short` before verification, where FreeBSD's decoder drops it in the
same place under its own counter.

The keys of a datagram from `RemoteAddr:RemotePort` to
`LocalAddr:LocalPort` are, most specific first,
`{tcp, Family, LocalAddr, LocalPort, RemoteAddr, RemotePort}`,
`{tcp_listen, Family, LocalAddr, LocalPort}` and
`{tcp_listen, Family, any, LocalPort}`, and for UDP the same three with
`udp`. An ICMP error's quote finds an owner by the first key alone, as
`tcp_ctlinput` and `udp_common_ctlinput` look up only the full
four-tuple; a TCP quote without one goes to the syncache, as
`tcp_ctlinput` hands it to `syncache_unreach` (`tcp_subr.c:3128-3176`),
but only when a listener's key exists, since only a listener's
handshakes are in the syncache.

**Room.** An owned frame takes one unit of each destination's credit; a
destination without room is skipped and counted, and a frame no
destination took is dropped as `no_room`. Which local frames spend a
token is `erx_net_if_core:charge/3`'s decision, since only the core
holds the neighbour tables: an ARP reply or a neighbour advertisement
whose target the core is resolving is free, and every other local frame
spends one, or is dropped as `no_token`.

**Verification.** `verify/1` is a function of what `classify/2` passed
it alone (the link and IP records, the cast, whether the datagram may be
answered, and the bytes above IP with their sum). Its item is the record
its consumer's step takes ([Events and the step](#events-and-the-step)
for a connection's), and for the interface also the IP record and
whether the datagram may be answered. A frame owned by several sockets
is verified once and its item delivered to each.

**Order within a batch.** The interface classifies, reserves for and
verifies its frames one at a time, and runs the core on a local frame
before it classifies the next, so a key the core inserts, a connection
the syncache completed, and a datagram reassembly completed are seen
from the next frame on; owned items are sent at the end of the batch,
grouped by destination.

**Reinjected segments.** A connection returns with `reinject` every
segment of its batch after the one that ended it, and in TIME-WAIT the
SYN that RFC 6191 lets end it ([TIME-WAIT](#time-wait)), since each is
for a connection that no longer exists. Its loop sends them back to the
interface process that delivered the batch with the connection's own
key, which gives what the segment lacks (the family, the zoned addresses
and the ports), against that interface's sender credit. The interface
treats each as a local frame that has passed `verify/1`: it spends a
token of the ingress bucket, is looked up by the listener keys alone,
since the full key still finds the ended connection until its grant
deletes the entry, and without a listener is answered as a segment to a
closed port, so it may draw a RST under the RST limit, as `tcp_input`
looks each segment up anew and finds the listener or nothing.

### Transmitting

1. **Owner to connection.** `gen_tcp:send/2` in D calls the socket
   process, a local call, which sends the data to the connection in
   pieces of at most 64 KiB, one at a time, each
   `{erx_net, SockProc, {call, N, {send, Piece}}}`
   ([Message sizes](#message-sizes)): a frame on the lane, decoded by the
   network domain's funnel into a binary of the network domain.
2. **Connection.** The step appends the binary to the send buffer, a
   queue of binaries, and runs output. Output emits runs, segments that
   share one header: a run's payload is sub-binaries of the buffer, and
   its header is the connection's template with the values output chose
   and the next hop's link header from its neighbour row
   ([The fast path](#sending)). A
   segment no run can carry, a SYN or a segment with SACK blocks among
   them, is encoded with `erx_net_frame` ([Framing](#framing)), its
   checksum left delayed for the copy when the interface's driver
   finishes checksums, and computed by the sender otherwise
   ([Checksums in the copy](#checksums-in-the-copy)).
3. **Connection to driver.** All runs and frames of the step go to the
   driver in one message against the driver's credit, one unit for each
   frame a run holds, each frame as its header binary and its payload
   sub-binaries.
4. **Driver to device.** The driver posts each run and frame with
   `erx_device:post_frame/5`, which walks a frame's binaries itself and
   cuts a run into frames as it lays each in a pool buffer behind the
   device's header, finishing its checksums and a delayed frame's: the
   one per-byte copy of the transmit path
   ([The fast path](#each-transports-cut)).

### Framing

Every owner that sends IP, a connection, a datagram socket or an
interface, frames through `erx_net_frame`, which translates the
header-building and next-hop parts of `in_pcbladdr`, `ip_output`,
`ip6_output`, `ether_output` and `arpresolve_addr`. It is pure; what it
needs from the published tables reaches it as two values the caller
reads: a path, built from the configuration, and the next hop's
neighbour row.

**The path** is everything about the way to one destination that does
not change from packet to packet, with the configuration generation it
was built at:

* *Interface.* The first of these that applies:
  * A destination that is an address of the stack, compared with its
    zone, leaves through the loopback interface in that zone, as the
    loopback route FreeBSD adds for each address sends it
    (`ifa_maintain_loopback_route`).
  * A multicast destination, or the limited broadcast
    `255.255.255.255`, sent through a named interface (the `via`
    option) leaves through that interface without a route. FreeBSD
    bypasses the route lookup for a multicast with an interface given
    (`ip_output.c:456-470`; `in6_selectif`, `in6_src.c:741-744`), and
    `dhclient` writes its broadcasts through BPF, under IP. A link- or
    interface-local multicast names its interface by its zone, as
    `in6_selectif` takes it from the zone (`in6_src.c:746-755`).
  * Any other destination takes the route lookup, on its zone's
    interface for a zoned one, and no route is `enetunreach`, as
    `in_pcbladdr` refuses (`in_pcb.c:1270`).

  `via` comes from the interface for its own packets, and from a
  socket's multicast interface option (`IP_MULTICAST_IF`,
  `IPV6_MULTICAST_IF`), which applies only to a multicast destination;
  so only the interface sends a limited broadcast without a route, and a
  socket's broadcast takes a route as `ip_output`'s does. The
  interface's DHCP broadcasts, router solicitations, duplicate address
  detection and neighbour solicitations to solicited-node groups,
  advertisements to all-nodes and MLD reports therefore have paths
  before the interface has an address or a route.
* *Next hop and its link address.* The route's gateway, or the
  destination when the route has none or the path took no route. On
  loopback the link header is the zone; a broadcast destination takes
  the broadcast address, and a multicast one its mapped address
  (`ETHER_MAP_IP_MULTICAST`, `if_ether.c:620`, and its IPv6 twin), as
  `arpresolve_addr` gives them; any other unicast next hop is addressed
  by its neighbour row.
* *Source.* The one given, or the one chosen: `erx_in6_src:select/3`
  for IPv6, over the address rows and their `deprecated` flags, and for
  IPv4 the outgoing interface's address whose prefix holds the next hop,
  else the first the interface added, as `in_pcbladdr` takes the route's
  interface address and `if_addrhead` lists addresses in the order they
  were added; no usable address is `eaddrnotavail`. A socket's given
  source is the one `erx_net_bind` checked when it bound, never the
  unspecified address; only the interface gives `0.0.0.0` or `::`, for
  DHCP before it holds a lease, and for duplicate address detection and
  router solicitations before it holds a usable address, as RFC 4862
  and RFC 4861 send them.
* *Header fields.* The driver's and interface's pids and credits from
  the interface's row, and the MTU: for IPv4 the row's MTU, for IPv6 its
  IPv6 link MTU, which is a router advertisement's MTU when that is
  below the interface's and the interface's otherwise (`IN6_LINKMTU`,
  `nd6.h:103-107`). The hop limit, type of service or traffic class and
  flow label come from the caller's options. The hop limit defaults to
  1 for a multicast destination, as `IP_DEFAULT_MULTICAST_TTL` and
  `ip6_defmcasthlim` give it (`in.h:535`, `in6.h:521`); otherwise to the
  interface's for IPv6, which router advertisements set, and to 64 for
  IPv4 (`IPDEFTTL`). Neighbour discovery's messages set 255, as RFC 4861
  requires.
* *Broadcast.* A destination that is an IPv4 broadcast address of the
  outgoing interface, the limited broadcast among them, marks the path
  `broadcast`, as `ip_output` sets `isbroadcast`, and is refused as it
  refuses one (`ip_output.c:661-673`): `eaddrnotavail` on the loopback
  interface, which cannot broadcast, and `eacces` unless the caller's
  `broadcast` option allows it. A socket passes its `broadcast` option
  there (`SO_BROADCAST`, which `ip_output` reads as
  `IP_ALLOWBROADCAST`), a connection never does, and the interface does
  for its own broadcasts. A broadcast packet over the MTU is refused
  with `emsgsize` instead of fragmented.

**Packets and frames.** A packet is the header bytes IP builds and the
payload binaries as they were given, not copied; only a datagram that IP
fragments has its payload joined into one binary first. The IP header
carries a TCP segment's marks: its ECN field in the low bits of the type
of service or traffic class, and don't-fragment as the segment says. A
segment without don't-fragment that is over the MTU is fragmented; one
under don't-fragment is refused with `emsgsize`, as `ip_output` refuses
it, and nothing raises. The rule of [Output](#output) makes that refusal
unreachable for segments sized against the path they are framed on;
were it reached, the pass's frames would be dropped and counted as
`emsgsize`, lost frames that retransmission recovers. An IPv4 datagram
without don't-fragment takes its identification from a generator its
sender owns: a datagram socket's, the interface's, and for a connection
a second generator split from its initial one, since the control
block's generator is the step's. Framing puts the link header in front,
with the path's fixed link address or the row's; with no row, the
packets go to the interface instead (`resolve`).

A multicast whose hop limit is 0 is never handed to a network: a
datagram socket hands its frames only to the loop below, never to the
driver, as `ip_output` and `ip6_output` loop such a datagram but free
the copy for the wire (`ip_output.c:632-643`, `ip6_output.c:921-935`).

A datagram a socket sends through an Ethernet interface to a broadcast
address, or to a multicast address while the socket's multicast loop
option is on, as it is by default (`IP_DEFAULT_MULTICAST_LOOP`,
`in.h:536`; `IPV6_DEFAULT_MULTICAST_LOOP`, `in6.h:522`), is also heard by
the stack itself: the sender hands the same frames to the path's
interface as `{loop, Frames}`, against its sender credit, and the
interface classifies each as a frame from its driver. This is the copy
`ether_output` loops back for every broadcast on a simplex interface
(`if_ethersubr.c:384-404`) and `ip_mloopback` and `ip6_mloopback` loop
for multicast (`ip_output.c:590-600`, `ip6_output.c:884-893`), received
on the interface it was sent through, as theirs is; classification then
drops a copy to a group the interface has not joined, as it drops such
a frame from the wire. Only sockets' datagrams are looped: the interface
writes its DHCP broadcasts as `dhclient` writes them, through BPF, which
loops nothing, and neighbour discovery turns the loop off for its own
messages (`nd6_nbr.c:470`, `:1028`).

**A connection's output pass** reads the published state at fixed
points around its step:

1. When the configuration generation differs from its path's, it reads
   the configuration and builds the path again; a path whose route has
   gone keeps that state with the generation.
2. When the path addresses its next hop by row, it reads that row, keyed
   by the path's interface pid and the next hop.
3. Its step's context holds the path's MTU, the free credit of where the
   frames will go (the driver when the next hop is addressed, the
   interface's sender credit when it has no row), and the route's
   state: `ok`, or `{error, ehostunreach}` when the path has no route,
   `ip_output`'s error for it (`ip_output.c:493`). With that error output
   sends nothing and takes `tcp_output`'s branch for it
   (`tcp_output.c:1709-1716`): the retransmission timer runs as on loss,
   and past SYN-RECEIVED the error is kept as the connection's soft
   error, which its timeout reports in place of `etimedout`.
4. It frames the step's segments and sends the frames to the driver, or
   hands the packets to the interface as `{resolve, NextHop, Src,
   Packets}`, each against the receiver's credit. The step's `reset`
   segments are framed the same way and handed to the path's interface,
   and each `charge_rst` likewise, against its sender credit: the
   interface sends a reset only within its RST limit, resolving its next
   hop as for `resolve`, and counts each charge against that limit.
5. When the row was `stale`, it increments the row's hint count; the
   one transmitter that moves it from 0 sends the interface
   `{hint, NextHop}`, so at most one hint, which carries no packet and
   takes no credit, is in flight for each published row, and the
   interface's next `publish` of the row resets the count. The increment
   never creates a row: on a deleted row it fails, and no hint is due. A
   hint for an entry no longer stale is ignored. In neighbour discovery
   a hint moves a stale entry to DELAY, as `nd6_resolve_slow` does
   (`nd6.c:2424-2425`), which publishes nothing, so no second hint is
   sent until the entry is confirmed, published fresh, or deleted.

A datagram socket does the same per datagram, with a path kept per
destination of a connected socket and built for each destination of an
unconnected one. The interface frames its own packets (ICMP answers,
RSTs, SYN-ACKs, neighbour discovery) over the same configuration copy as
its view, but resolves its next hops in its own tables.

**Resolution.** The interface hands each packet of a `resolve` to ARP or
neighbour discovery, which send it at once when the entry has meanwhile
been resolved and otherwise hold it, at most 16 per neighbour as FreeBSD
holds (`arp_maxhold`, `if_ether.c:114`; `nd6_maxqueuelen`, `nd6.c:125`),
the oldest dropped past that (`lltable_append_entry_queue`). Handing a
packet to the interface counts as sending it, as `ether_output` reports
success for a packet `arpresolve` holds (`if_ethersubr.c:350`), so TCP
recovers a dropped one by retransmission. An ARP entry that is never
answered is deleted with its packets after 20 s (`arpt_down`); a
neighbour-discovery entry returns its oldest packet as `unreachable`,
and the interface sends an ICMPv6 address-unreachable error to that
packet's source, an address of the stack, so the error crosses the
loopback interface in that address's zone and reaches the socket its
quote names, as any ICMP error.

**What senders hand an interface.** Everything a sender hands its
interface, `resolve`, `reset`, `charge_rst`, `loop` and `reinject`, goes
against the interface's sender credit, never its receive credit, so no
amount of sending keeps the driver's receive batches from their room.
What the interface holds for senders is bounded by its neighbour table,
1,024 entries of 16 held packets each, about 25 MB of payload at an MTU
of 1,500 bytes, shared by every client; which client's packets an entry
holds is not counted, a residual ([Residuals](#residuals)).

### Hops and copies

| Path | Local messages | Lane crossings | Copies in the network domain |
| --- | --- | --- | --- |
| receive, TCP segment | driver to interface (per batch), interface to connection (per batch); in the owner's domain, socket process to owner (per delivery) | one per push of up to a piece, and one credit message per half of the socket process's target, in every active mode | one, `erx_device:complete/3`, which also sums the frame |
| transmit, TCP segment | in the owner's domain, caller to socket process and back (per `send` call); connection to driver (per step) | one per piece of a `send`, with no reply, and one send credit message per half of the send buffer acknowledged | one, `post_frame/5`, which cuts runs and finishes checksums as it copies |
| receive, UDP datagram | driver to interface, interface to socket; in the owner's domain, socket process to owner | one per datagram, and one credit message per half of the socket process's target | one |
| ARP, neighbour discovery, ICMP echo, SYN | driver to interface; replies interface to driver | none | one each way |

A lane crossing copies the payload into the lane and out of it, by the
domains design ([design-domains.md](design-domains.md#flow-control)), and
a delivery's payload pieces become one binary once, in the socket
process, where `gen_tcp`'s API needs one. The local hop from the socket
process to the owner copies no payload over 64 bytes, since ERTS passes
a binary that size or larger by reference. The copies of each path on
each medium are counted in
[The fast path](#copies).

### Checksums in the copy

Inside the network domain each byte of a TCP segment is read once on
each path: by the copy between a device's buffer and a binary, which
also computes the segment's Internet checksum. Without it, the interface
process, which classifies for every client, and the connection, one
flow's ceiling, would each read the segment a second time to sum it. The
copy that sums also cuts a run into its frames, so this is part of the
fast path, not a saving judged on its own share
([The fast path](#the-construction-runs);
the measured share is in
[The fast path](#where-a-segments-cost-goes)).

**The construction.** A checksum is a sum of 16-bit words, and a copy
reads every word, so the copy sums what it copies. What it hands over
is a sum, never a verdict, because the copy parses nothing:

* *Receiving*, the copy returns each frame with its **network sum**:
  the RFC 1071 one's-complement sum, folded to 16 bits and not
  complemented, of the frame's bytes from the end of its link header to
  its end. The copy knows only the offset where the sum starts. Each
  layer above derives the sum of the bytes its checksum covers by
  subtracting the sums of the bytes it does not cover: headers its
  decoders read anyway, and the frame's padding. No payload byte is read
  again to check it.
* *Transmitting*, a TCP segment can leave its sender with a **delayed
  checksum**: its checksum field holds the sum of the pseudo-header with
  the segment's length, not complemented, and the frame names the
  offset where the summed range starts and the field's offset within
  it. Whatever copies the frame onto the medium sums the bytes from that
  start to the frame's end, field included, and stores the complement in
  the field. This is FreeBSD's delayed checksum: `tcp_output` sets
  `CSUM_TCP`, with the field's offset in `csum_data` and `in_pseudo` in
  `th_sum`, and `ip_output` finishes it with `in_delayed_cksum` when the
  interface's `if_hwassist` lacks the flag, and `ip_fragment` before it
  cuts. Here the device NIF's copy takes the place of the device.

The stack sees one interface whichever medium is behind it. A received
frame comes with its network sum or without one, and a sent segment is
delayed only when its interface's driver finishes checksums. The driver
states that once, as `finish` in its answer to the interface's attach,
which the interface writes into its row with the MTU, so the value has
one source. `finish` names who finishes a delayed checksum and a run's
cut, since one copy does both
([The fast path](#the-seam)):
`device` when the device does, `copy` when the transport's own copy
does, and `none` when nobody below the sender does, so the frame layer
finishes every checksum and cuts every run itself. It is a fixed
property of the transport, so a driver's restart never changes it:

| Transport | Received frames | `finish` |
| --- | --- | --- |
| `erx_virtio_net` | with their network sum, from `erx_device:complete/3` | `copy`; `device` where the device offers `VIRTIO_NET_F_CSUM` with `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6`, an extension ([Scope](#scope)) |
| `erx_genet` | without a sum, which the interface's merge computes | `none` |
| netmap | with their network sum, from its NIF's copy | `copy` |
| `erx_tap` | with their network sum, summed by its NIF after the kernel's `read` | `copy` |
| `erx_net_pipe` | without a sum, which the interface's merge computes; a test's `process` end may give one | `none`; `copy` in the `process` end's offload mode |
| `erx_net_loop` | IP packets with their zone | `none` |

**The copy's core.** Every copy that sums or finishes calls one C
function, `erx_inet_copy_sum` in `erx_net`'s `c_src/`, linked by erXos's
device NIF and the host transports' NIFs alike
([Two places, four seams](#two-places-four-seams)). Each word of the
source is loaded once and the loaded value is both stored and added, so
the sum is the sum of the bytes in the binary even when a device writes
its buffer again during the copy, which a copy followed by a pass over
the source would not give. Since C would let a compiler load a plain
object twice, each loaded word passes through an empty assembly
statement that hides its value; no test can see a second load, so
review keeps every load of the loop behind it. The core's oracle in its
tests and fuzz target is a model that adds one byte at a time.

**Receiving.** `erx_device:complete/3` is `complete/2`'s bounded copy
that also returns each frame's sum from an even offset past the device
and Ethernet headers. By the time a frame reaches `classify/2` every
Ethernet frame has its sum,
since the merge sums each frame that came without one
([The fast path](#the-merge)); a
reassembled datagram, every loopback packet and a datagram on the DHCP
client's path carry none and are summed in `verify/1` with
`erx_bytes:inet_csum/2`, a read pass with no copy. IPv4 still checks its
header checksum over the header's own bytes, which it reads to decode
anyway; a checked header sums to one's-complement zero, so the packet's
sum is also the sum of the bytes after it. IPv6 subtracts its header and
the extension headers its walk has just read. `erx_net_sum:span/4` then
subtracts the bytes after the upper layer's length, byte-swapping a sum
that starts at an odd offset (RFC 1071, section 2(B)): an Ethernet
frame's padding, at most 26 bytes. A frame whose IP length leaves more
bytes behind it costs a pass over those bytes, never more than summing
the frame.

The decoder above IP checks that the pseudo-header's sum plus the
derived sum is one's-complement zero, or sums the bytes itself when it
was given no sum, and only then makes its record. One's-complement
arithmetic has two zeros, 0 and 16#ffff, and a fold of a positive total
is never 0, so every sum derived from a nonzero sum is in the form the
checks compare with; a frame's network sum is nonzero, since its IP
header's version is. The check stays where
[Receiving](#receiving) puts it, after the frame holds room: for a frame
with a network sum it costs a constant, so such a frame that fails costs
no more than one dropped for want of room, and the work that grows with
a frame's length was spent in the copy, which every frame costs.

**Transmitting.** Framing delays a TCP segment's checksum when the path
interface's row has `finish` other than `none` and IP will not fragment
the segment; the sender sums it otherwise. Finishing sums the field
along with the rest, so both give the same bytes on the wire. Only TCP
segments are delayed: a datagram's checksum is finished by its encoder,
so looped datagrams and every packet on the loopback interface are
already finished. A delayed checksum is finished at each copy and never
stored, and output cuts each segment from the send buffer afresh at each
pass ([Output](#output)), so retransmission needs nothing of its own:
the copy of a pass sums exactly the bytes it sends. The virtio
transport finishes in its copy, `erx_device:post_frame/5`
([design-runtime.md](design-runtime.md#the-device-nif)), or with
`device` through the `virtio_net_hdr`'s `NEEDS_CSUM` flag with
`csum_start` and `csum_offset`, as section 5.1.6.2 of the virtio
specification has a driver ask the device to finish a partial checksum.

**Device offload.** On transmit, `VIRTIO_NET_F_CSUM` lets the device
finish the checksum, so the guest spends nothing on it. It needs no
trust: a device that computes a wrong checksum only makes the peer drop
the segment, and a device can corrupt any frame anyway. It is an
extension rather than the core ([Scope](#scope)), because no medium of
the test harness reaches it: the harness's virtio device sits on a QEMU
hub port, and QEMU is believed to offer `CSUM` and `GUEST_CSUM` only
when the device's backend carries virtio-net headers, as a tap or vhost
backend does, which is unverified against QEMU's source. The device
finishes only together with device segmentation, which needs
`HOST_TSO4` and `HOST_TSO6` as well, since one `finish` names who
finishes both
([The fast path](#device-segmentation)):
a device that offers `VIRTIO_NET_F_CSUM` alone is finished by the copy,
and the device path is tested against the copy on a medium that offers
all three bits. The transport logs which way it finishes at each start
(`finish copy` or `finish device`).

On receive, the stack never negotiates `VIRTIO_NET_F_GUEST_CSUM`.
Without it the device delivers frames with complete checksums
(section 5.1.6.4). With it, a device may set `DATA_VALID`, a claim the
stack would have to take on trust, or `NEEDS_CSUM`, on a frame whose
checksum field holds only the pseudo-header's sum, which the stack
would have to accept unchecked. The copy's network sum makes both
unnecessary at the cost of the additions, so the stack takes no
checksum claim from any device. Netmap and tap give no claim either:
their transports use no virtio-net header. Over a tap device the
kernel's `read` and `writev` make the only copy, so the tap transport's
NIF sums in the same call, reading the bytes once more while they are in
the cache, and no Erlang process reads them
([The tap transport](#the-tap-transport)).

**What the stack believes.** The stack believes one thing: the network
sum a transport of `erx_net` hands up, computed by the stack's own C
over the bytes the binary holds. It believes nothing a device or a
host's kernel says about a checksum. This is safe even against a sum
that is wrong. The Internet checksum detects accidents and authenticates
nothing: whoever can write a frame can write a correct checksum for it.
A wrong sum can make the stack drop a good frame, or keep one whose
bytes changed on the way, and a device can do either by writing bytes.
A wrong sum cannot make a decoder read past what it checked, because
every length is checked against the binary, never against a sum. What
the stack checks for itself is unchanged: every length and offset, and
the IPv4 header checksum over the header's own bytes.

**Concurrency, failure and refusals.** The sum is made in the same NIF
call as the copy and travels with its binary as a value; nothing else
holds it, and no process or message is added. A broken core or a lying
transport makes frames fail their check; they are counted as `bad_sum`,
as a corrupted frame is, and `netadmin` and the inspector show that
count. `complete/3` with an odd offset is `badarg`, and so is
`post_frame/5` with an odd start or field offset, or a field outside the
frame; the transport's own check drops such a frame first as
`malformed`, so only a bug in the transport reaches `badarg`, and only a
bug in framing makes such a frame. A transport whose `finish` is `none`
drops a delayed frame as `malformed`, as every transport drops a frame
shape it does not take.

**Open decision.** *UDP.* Datagrams could be delayed too. That needs RFC
768's rule that a computed zero is sent as 16#ffff in every finisher, and
a device's finisher may not apply it; it also needs the looped frames
finished before they are looped. Recommended: no, until a UDP bulk
workload is measured.

### Loopback

Traffic to the machine's own addresses goes through a loopback interface,
whose driver, `erx_net_loop`, hands each frame it is given back to its
interface process. The loopback interface carries IP packets with no
link header but their zone: the name of the interface that owns the
packet's destination, which the sender's path gives and `classify/2`
gives the packet's addresses
([Classifying a frame](#classifying-a-frame)). Everything else about it
is the same: the same credits, the same interface process, the same step
functions.

`erx_net_sup` always starts the loopback interface, `lo0`, over
`erx_net_loop`, before the interfaces the configuration names, with
127.0.0.1/8. An entry of the configuration named `lo0` gives only its
addresses: a static `ip4`, an address and prefix length with no gateway,
in place of 127.0.0.1/8, and `ingress`. An `lo0` entry with any other
key, a transport among them, or with any other `ip4`, `dhcp` among them,
stops the stack's start, before any process starts, with
`{error, {lo0, Key}}`. `lo0` is the stack's own, not the runtime's: the
runtime's children are given the other interfaces. FreeBSD splits the
same work: the kernel creates `lo0` (`vnet_loif_init`, `if_loop.c`), and
rc gives it 127.0.0.1/8 unless `ifconfig_lo0`, which only sets its
addresses, says otherwise (`network.subr`). With IPv6 interface
addresses it also takes `::1/128` and `fe80::1%lo0`, as `in6_ifattach`
gives them. `lo0` has no link-layer address: `interfaces/0` answers its
`lladdr` as `none`, and `ifconfig` writes it as FreeBSD 15 does, with
the flags `UP,LOOPBACK,RUNNING,MULTICAST,LOWER_UP` and neither an
`ether` nor a `status` line. Each interface's view holds every address
of the stack, so a packet to one of them is the stack's own on whichever
interface it arrives; a packet from or to 127.0.0.0/8 that arrives on
any interface but `lo0` is dropped as `bad_addr`, as RFC 1122 and
`ip_input.c` require.

## The TCP core

### The control block

The control block is one Erlang record, `#tcb{}`, translated from
`struct tcpcb` (`tcp_var.h`). Where FreeBSD keeps a flag word whose
combinations are not all legal, the record keeps a variant that can only
hold the legal ones:

| FreeBSD | `#tcb{}` |
| --- | --- |
| `t_state` | `state`, one of `closed`, `syn_sent`, `syn_received`, `established`, `close_wait`, `fin_wait_1`, `closing`, `last_ack`, `fin_wait_2`, `time_wait` |
| `TF_SENTFIN`, `TF_NEEDFIN` | `fin`: `none`, `queued` or `{sent, Seq}` |
| `TF_REQ_TSTMP`, `TF_RCVD_TSTMP`, `ts_recent`, `ts_recent_age`, `ts_offset` | `ts`: `off`, `{requested, Offset}` before the handshake completes, or `#ts{recent, recent_age, offset}` |
| `TF_REQ_SCALE`, `TF_RCVD_SCALE`, `snd_scale`, `rcv_scale` | `wscale`: `off`, `requested` before the handshake completes (the shift asked for follows from `sb_max`), or `{SndShift, RcvShift}` |
| `TF_SACK_PERMIT` | `sack`: `off`, `requested` or `on` |
| `TF_FASTRECOVERY`, `TF_CONGRECOVERY` | the congestion module's `#ccv{}`: `fast_recovery` and `cong_recovery`, two flags, since all four combinations are legal: an ECN mark at or past the recovery point leaves congestion recovery and keeps fast recovery, and congestion modules read and set them as FreeBSD's do through `CCV(ccv, t_flags)` |
| `snd_recover` | `snd_recover`, an unwrapped integer, which the loss module reads |
| `t_timers[]` | `send_timer` and `#deadlines{}` |
| `t_rxtshift` | `rxtshift`, kept when the send timer stops |
| `snd_una`, `snd_nxt`, `snd_max`, `snd_wl1`, `snd_wl2`, `iss`, `rcv_nxt`, `rcv_adv`, `last_ack_sent`, `irs` | the same names, unwrapped integers |
| `snd_cwnd`, `snd_ssthresh` | the congestion module's `#ccv{}`, as FreeBSD's `struct cc_var` |

Options negotiated in the handshake (MSS, window scaling, timestamps,
SACK, ECN) are set once, when the connection is synchronized, and never
change afterwards. The record keeps what an established connection's
data and acknowledgements change, and holds in one field a second
record, `#tcb_conf{}`, with what only the handshake, an option, a path
change or the owner's requests change, so a stage that updates the
control block copies the small record
([The fast path](#the-control-block-hot-and-cold)).

### Events and the step

```erlang
-type event() ::
      {segments, [segment()]}                % from the interface, in order
    | {user, erx_tcp_user:request()}         % connect, send, recv, close, ...
    | {expired, Now :: integer()}            % a timer hint
    | {icmp, erx_tcp_icmp:report()}          % unreachable, too big
    | {buffer, Kind :: snd | rcv, Bytes :: non_neg_integer() | refused}.

-type action() ::
      {transmit, [outgoing()]}
    | {deliver, iodata()}
    | {notify, eof | closed | {error, atom()} | {ready, [readiness()]}}
    | {reply, gen_server:reply_tag(), term()}
    | {reserve_buffer, snd | rcv, Bytes :: non_neg_integer()}
    | {reset, outgoing()}                    % within the interface's RST limit
    | charge_rst                             % count one RST against that limit
    | {reinject, segment()}
    | finish.
```

A segment carries its decoded header and payload, the ECN field of the
IP header it came in, and the link cast of its frame: the step answers
no segment with a `reset` unless its frame was link unicast, as
`tcp_dropwithreset` sends nothing for a link-layer broadcast or
multicast (`tcp_input.c:3450-3451`). An outgoing segment carries the two
IP header fields TCP decides per segment, as `tcp_output` sets them: the
ECN field, ECT(0) on new data, and don't-fragment, set on IPv4 while
path MTU discovery runs and the maximum segment is above `tcp_minmss`
(`tcp_output.c:1487-1500`) and never on IPv6, where `tcp_output` asks
`ip6_output` for no `IPV6_DONTFRAG`, so a segment over the MTU is
fragmented (`tcp_output.c:1455-1458`, `ip6_output.c:1149-1153`);
framing builds the rest of the IP header from the path.

A RST that answers a segment (`tcp_dropwithreset`) is a `reset` action,
which the interface sends only within its RST rate limit
(`badport_bandlim`). A challenge ACK to a SYN or an ACK, sent or not, is
preceded by `charge_rst`, as `tcp_challenge_ack_check` charges that
limit: the segment would have drawn a RST had it named no connection, so
the limit does not tell a blind sender whether it did. A challenge ACK
to a RST charges nothing, a departure: a RST that names no connection
draws nothing, so FreeBSD's charge tells the sender its RST landed in a
window, the side channel of CVE-2016-5696.

`erx_tcp:step/3` is the only entry. It dispatches the event to the module
that translates the FreeBSD code for it, then runs output, as
`tcp_do_segment` ends by calling `tcp_output` when an ACK or data is due.
The only other entry is `erx_tcp:rcvd/2`, for bytes that left the
receive buffer: FreeBSD's `tcp_usr_rcvd` calls `tcp_output`, and what
output sends because of them is a window update past the receiver's
silly window avoidance (`tcp_output.c:655-692`). The connection process
steps `rcvd` only when output would send: a window update, an owed ACK,
or a segment its last pass held back because the step's credit was spent
(ENOBUFS), as FreeBSD's next read sends it. Otherwise the bytes come off
the control block without a step, adding up against the same advertised
edge, so the window does not stall. The cut of the congestion window
after idle, and data a missing route held back once the route returns,
come at the next step or the retransmission timer.

The user requests are FreeBSD's `pr_usrreqs` for a connected stream:
`connect`, `send`, `rcvd` (so many bytes left the receive buffer, which
reopens the window), `shutdown`, `close` and `abort`. The socket layer's
buffer, the bytes not yet pushed, belongs to the connection process, and
the control block counts them so that the advertised window follows
them; the rest of the socket layer, the owner, the active mode, packet
framing and the bytes pushed but not yet presented, belongs to the
socket process in the owner's domain
([The socket process](#the-socket-process)). A `send` carries no caller
and never waits: it brings bytes the socket process sent within the send
credit the connection granted, which always fit the send buffer, as
`sosend` hands `tcp_usr_send` only what `sbspace` has room for, and the
wait for room is the socket process's. A request that waits carries its
caller, and the step answers it from the state it reaches, after output:
`connect` once the connection is established, and every waiting caller
with the error when the connection ends. A connection that `tcp_close`
ended (FreeBSD's `INP_DROPPED`) is done, which a new control block in
CLOSED is not: the step runs output only for a connection dropped after
it received a SYN, so that output is the RST of `tcp_drop`, then tells
the socket process how it ended and returns `finish`. No stage has to
remember any of this, since it follows from the state.

A buffer grows only through the grant. When `tcp_mss` rounds the buffers
up to whole segments at a SYN the step takes, or autosizing grows the
send buffer, the step returns `{reserve_buffer, Kind, Bytes}` and
changes nothing (a connection made from the syncache starts at its
rounded sizes, which its grant reserves when it adopts it:
[The listener](#the-listener), "An accepted connection's start"); the
connection process asks its grant
([Sockets act for one domain](#sockets-act-for-one-domain)) once it has
performed the step's other actions, and steps the answer: `{buffer,
Kind, Bytes}` sets the buffer, and `{buffer, Kind, refused}`, past the
grant's `buffers` limit, leaves it as it is. Send autosizing is
`tcp_sndbuf_autoscale` (`tcp_output.c:2123-2178`), run once per step
before output, growing the buffer by `tcp_autosndbuf_inc`, 8 KiB, when
the peer's window with a 5/4 fudge covers it, it is 7/8 full, it holds
less than `tcp_autosndbuf_max`, and the send window covers what is not
yet sent. A size past `sb_max_adj`, which `sbreserve`
refuses (`uipc_sockbuf.c:659`), is not asked, and that or the grant's
refusal turns autosizing off for the connection, as FreeBSD clears
`SB_AUTOSIZE` when `sbreserve` fails, so the largest send buffer is
FreeBSD's (about 1.78 MiB) and a connection whose grant is full asks no
more. A refused rounding of `tcp_mss` turns send autosizing off too,
where FreeBSD ignores a failed `sbreserve` there and keeps autosizing
(`tcp_input.c:3903`): so a connection that opens while its grant is full
never autosizes, even once room frees. A growth the grant reserves is a
step of its own, whose output may grow the buffer again, as each round
of `sosend` calls `tcp_output`; the chain ends, since no bytes join the
buffer within it and the buffer stops growing once they are under 7/8
of it.

`tcp_do_segment` is about 2,000 lines that mix state handling, ACK
processing and data delivery. It is split by stage, not ported in order.
A segment's step is a pipeline of named stages, each continuing with
the next, jumping to a named stage, or finishing with its actions, in
the order `tcp_do_segment` takes them, since the order is visible on the
wire (a RST, for example, is judged before the timestamp check):

1. `lift` the segment into the connection's sequence space
   (`tcp_input.c:1511-1629`): a SYN-ACK in SYN-SENT that acknowledges
   what was never sent is answered with a RST, the window scaled and
   the timestamp echo brought back to our clock. FreeBSD also takes
   `t_rcvtime` and reads the segment's ECN here, before any check
   (`tcp_input.c:1566`, `:1592-1595`); the stack does both once the
   segment has passed them all (in `check_ack`, header prediction, or
   `syn_sent` for an acceptable SYN), so a blind segment that knows only
   the four-tuple can neither keep a dead peer's connection from its
   keepalive timeout, as FreeBSD's own comment there warns, nor cut the
   congestion window with ECE, nor make the connection echo CE or stop
   echoing it. TIME-WAIT's segments are `tcp_twcheck`'s
   ([TIME-WAIT](#time-wait)), not the pipeline's.
2. `timestamps`: RFC 7323 section 3.2's presence rules, as
   `tcp_do_segment` applies them before header prediction
   (`tcp_input.c:1692-1729`). On a connection that negotiated timestamps,
   a segment without one is processed normally when it is a RST or, by
   FreeBSD's default `tcp_tolerate_missing_ts` of 1 (`tcp_subr.c:219`),
   always, and is silently dropped only with that setting off; on a
   connection that did not negotiate them, a timestamp on a segment is
   ignored and the segment processed; FreeBSD still records such a
   timestamp as `ts_recent` and checks PAWS against it, the stack's
   later stages do not see it. The stack keeps the default, so the
   stage drops nothing; it is a stage so that the branch is FreeBSD's
   and the packet scripts can pin it.
3. `syn_sent`: the receive window, then the handshake cases of
   `tcp_do_segment`'s switch (`tcp_input.c:1958-2140`): SYN-RECEIVED
   answers an ACK of something other than its SYN with a RST; SYN-SENT
   handles RST, negotiates options and moves to ESTABLISHED or
   SYN-RECEIVED, then jumps to `process_ack` or `step6`, FreeBSD's
   `process_ACK` and `step6`. FreeBSD takes a SYN's options in SYN-SENT
   before it judges the segment (`tcp_input.c:1636-1690`); the stage
   takes them once it has accepted the SYN, so a RST or SYN that
   SYN-SENT drops cannot change what the connection asks for, and on a
   simultaneous open both window shifts apply at once.
4. `check_rst`: RFC 5961 section 3, measured from `last_ack_sent`, the
   last acknowledgement number the connection sent, not from `rcv_nxt`,
   as FreeBSD measures it so that a delayed ACK does not move the
   target (`tcp_input.c:2148-2194`): a RST whose sequence number is
   exactly `last_ack_sent` resets; one elsewhere in the window of
   `rcv_wnd` bytes from `last_ack_sent` gets a challenge ACK; with the
   window closed only the exact match counts.
5. `check_syn`: RFC 5961 section 4: a SYN in a synchronized state gets a
   challenge ACK (`tcp_input.c:2196-2215`), and so does one in
   SYN-RECEIVED at or past `rcv_nxt`: RFC 9293 section 3.10.7.4 treats
   SYN-RECEIVED after an active open as synchronized. FreeBSD lets every
   SYN through in SYN-RECEIVED, where the peer's own SYN again lies
   before `rcv_nxt` and `trim` strips it; a SYN at or past `rcv_nxt`
   names another initial sequence number, and FreeBSD would take its
   data one byte early. FreeBSD also lets that SYN's ECE turn ECN on
   (`tcp_ecn_input_syn_sent`); here a SYN that passed no sequence check
   changes nothing.
6. `paws`: RFC 7323's check against the last timestamp
   (`tcp_input.c:2218`).
7. `trim`: trims the segment to the receive window, as the `todrop`
   blocks do, resets a connection whose owner closed when data arrives,
   and takes `ts_recent` (`tcp_input.c:2247-2389`).
8. `check_ack`: RFC 5961 section 5 and the ghost-ACK check, with the
   lower bound of
   [Packets become checked records once](#packets-become-checked-records-once-sequence-numbers-are-integers)
   (`tcp_input.c:2397-2450`); a segment without ACK goes to `step6` in
   SYN-RECEIVED and is dropped otherwise. A segment that goes on has its
   ECN read here.
9. `ack`: SYN-RECEIVED to ESTABLISHED, which moves `snd_una` past our
   SYN (FreeBSD's `incforsyn` and its `TF_NEEDSYN` block of
   `tcp_input.c:2869` both do so; the control block's `need_syn` remains
   for what a simultaneous open changes elsewhere: output sends the owed
   SYN only with an ACK due, no window update goes before it, and the
   peer's FIN is acknowledged with a delay); an acknowledgement of what
   was never sent dropped with an ACK; the loss module's `ack` callback,
   whose `drop` ends the segment with `snd_una` where the send log put
   it; with nothing new acknowledged, a jump to `step6`, as FreeBSD does.
   `process_ack`, from FreeBSD's `process_ACK` label: the undo of a
   spurious timeout, the RTT sample (which resets the backoff count, as
   the undo and leaving persist do), the retransmission timer, the
   congestion module's `ack_received` with appropriate byte counting,
   the `snd_una` advance, the end of recovery, and the transitions when
   our FIN is acknowledged, TIME-WAIT among them (`tcp_twstart`). A
   timeout is spurious when the acknowledgement echoes a timestamp from
   before the retransmission, whose time output records (`t_badrxtwin`,
   `tcp_output.c:848`), for the retransmission alone, where FreeBSD
   records every segment sent while the backoff is 1, so that an ACK we
   send after it cannot make a real timeout look spurious (RFC 3522); the
   undo also clears the timeout's marks in the send log, so the original
   transmissions count in the pipe again. FreeBSD's other rule, an
   acknowledgement within half an RTT on a connection without
   timestamps, is read only by its header prediction
   (`tcp_input.c:1788`), and the stack's header prediction takes the
   general rule.
10. `step6`, FreeBSD's label: the window update under the SND.WL1/SND.WL2
    rule, then the urgent pointer, processed as FreeBSD does
    (`tcp_input.c:3104`); the urgent byte is held out of band, and
    `gen_tcp`, like stock, has no way to read it. The byte is kept out by
    its sequence number when the bytes are delivered, so the same byte is
    left out whether its segment arrives in order or waits in the
    reassembly queue.
11. `data`: in-order data to the receive buffer, with the delayed-ACK
    decision; out-of-order data to the reassembly queue; the receiver's
    SACK blocks, D-SACK included (`tcp_input.c:3165`), for every segment
    that reaches the stage, so a duplicate trimmed away entirely is
    reported too.
12. `fin`: the FIN transitions to CLOSE-WAIT, CLOSING or TIME-WAIT
    (`tcp_input.c:3319`). The owner learns of the FIN from a
    `{notify, eof}` action, after the `deliver` actions of the data
    before it.

FreeBSD's `drop`, `dropafterack` and `dropwithreset` exits become the
stages' finishing results. A challenge ACK goes out at most 5 times in
1,000 ms per connection, FreeBSD's per-connection limit
(`tcp_send_challenge_ack`, `tcp_subr.c:2213`; `tcp_ack_war_cnt` and
`tcp_ack_war_time_window`, `tcp_subr.c:139-143`), which keeps the side
channel of a global limit closed. A RST for a segment that names no
connection is limited by the interface's band limiter, FreeBSD's
`badport_bandlim`.

FreeBSD's header prediction, the two common cases of an established
connection (a pure ACK for new data and pure in-order data,
`tcp_input.c:1731`), is a stage of its own between `timestamps` and
`syn_sent`, where FreeBSD has it, with FreeBSD's preconditions (an
established connection, the segment at `rcv_nxt` with only ACK set, the
window unchanged, no retransmission in progress, an empty reassembly
queue, the timestamp no older than the last), so it takes the branch
FreeBSD takes. What it does with a segment it takes is what the checks
it skips would set (the receive window, `ts_recent`, ECN) and the
general stages' work from `ack` on, finished in one function for each
case so that the control block is built once
([The fast path](#header-prediction-finishes-its-cases)).
FreeBSD's fast path leaves different state (`snd_wl1` and `rcv_up` after
a pure ACK, `t_dupacks`, the spurious-timeout rule); the stack's leaves
the general stages' state, so each effect has one meaning. It is also
where a native fast path would go, if one is ever measured to be needed
([Where C is used, and what is
measured](#where-c-is-used-and-what-is-measured)). Its decision must not
drift from the checks it skips, so a property test runs the segments
and states it accepts, and their near misses, through the general
stages too and requires the same state and actions ([The TCP core:
exhaustive exploration](#the-tcp-core-exhaustive-exploration)).

### Output

`erx_tcp_output` translates `tcp_default_output` (`tcp_output.c:186`) and
`tcp_setpersist` (`tcp_output.c:1744`): what to send and when, Nagle,
sender and receiver silly-window avoidance, window updates, zero-window
probes, options on each segment (`tcp_addoptions`, `tcp_output.c:1794`),
and, from the loss module, what to retransmit first. It takes the
transmit credit from the context and never emits more frames than the
credit allows, and with the context's `{error, ehostunreach}` sends
nothing ([Framing](#framing)). It sizes segments by `t_maxseg`, as
`tcp_output` does, and takes FreeBSD's branch for a segment the
interface's MTU no longer holds where FreeBSD meets it: `ip_output`
refuses a don't-fragment datagram over the MTU with `EMSGSIZE`, and
`tcp_output` then calls `tcp_mss_update(tp, -1, mtu, ...)` with the
route's MTU and sends again (`tcp_output.c:1694-1709`). Here the
context's `mtu` is the path's, so before it commits a segment, output
asks whether the segment with its IP and TCP headers and options fits it
under don't-fragment; when it does not, output lowers `t_maxseg` by
`tcp_mss_update` with the context's MTU and sizes the segment again. A
lowered MTU, from a DHCP renewal or the configuration, therefore lowers
`t_maxseg` on the next IPv4 segment under don't-fragment that would not
fit, as in FreeBSD, and nothing is sent that IP must refuse; an IPv6
segment carries no don't-fragment
([Events and the step](#events-and-the-step)), so one over a lowered
IPv6 link MTU is fragmented, as `ip6_output` fragments it. Where
per-segment output would send several full segments back to back from
`snd_nxt` under one header, output emits them as one run, which the copy
into the medium cuts into those same frames
([The fast path](#output-makes-runs)).

### Timers

`erx_tcp_timer` translates the expirations of `tcp_timer.c`:
retransmission with FreeBSD's backoff table and its retransmission limit
(`tcp_timer_rexmt`, `tcp_timer.c:554`), persist (`:486`), keepalive with
FreeBSD's defaults of 2 hours idle and 75 s between probes
(`tcp_timer.h:86-87`; `tcp_timer_keep`, `:380`), 2MSL with an MSL of
30 s (`tcp_timer.h:76`; `tcp_timer_2msl`, `:331`), and delayed ACK
(`tcp_timer_delack`, `:309`). Path MTU black-hole detection is
translated and, as in FreeBSD, off by default
(`tcp_pmtud_blackhole_detect`, `tcp_timer.c:170`).

The 2MSL deadline also ends FIN-WAIT-2, as in FreeBSD. When our FIN is
acknowledged and the receive side is already closed, the deadline is set
to the keepalive's maximum idle time, 8 probes 75 s apart, 10 minutes
(`TP_MAXIDLE`, `tcp_timer.h:143`; `tcp_input.c:3040-3046`;
`tcp_usrreq.c:2724-2731`); when it falls due the connection closes if it
has been idle that long and otherwise waits another 75 s
(`tcp_timer.c:361-366`). So a peer that never sends its FIN holds a
connection for 10 minutes, not for keepalive's 2 hours. FreeBSD's faster
recycling at 60 s (`tcp_fast_finwait2_recycle`, `tcp_timer.c:143`;
`tcp_finwait2_timeout`, `tcp_subr.c:1495`) is off by default, and so it
is here.

The time base is `erlang:monotonic_time/1`, read by the process and
passed in the context. The timestamp option's clock is that time in
milliseconds plus a per-connection offset, a keyed hash of the four-tuple
as `tcp_new_ts_offset` computes it (`tcp_subr.c:3443`), on by default in
FreeBSD (`tcp_ts_offset_per_conn`, `tcp_subr.c:224`).

### The send log, SACK and reassembly

The sender's record of what it has sent is one structure,
`erx_tcp_sendlog`: an ordered map from each sent range's first byte to
the sequence number after the range, the segment size it was cut at,
its last transmission time, its transmission count, and whether it is
SACKed, lost or retransmitted during the current recovery (RFC 6675's
octets at or below `HighRxt`, kept per range). Because sequence numbers
are integers, the map is an ordinary `gb_trees` keyed by them. RFC
6675's scoreboard is computed from it, holes, `IsLost`, `NextSeg` and the
pipe included (RFC 6675 section 4), and so is what RACK-TLP needs. FreeBSD
keeps two structures for this, the default stack's hole list
(`tcp_sack.c`) and RACK's sent-segment hash, and never unified them,
which is one reason RACK is a second stack. Here the loss modules read
and mark the one log, and output takes the next range to send from it
(`NextSeg`). The log is written from RFC 6675, not translated from
`tcp_sack.c`.

Two properties hold by construction. A SACK block marks only the
segments it covers whole, a range's segments being its start plus
multiples of its segment size, and splits the range at their boundaries,
so only the segments the sender cut create range boundaries and a peer
cannot split the log into pieces smaller than what was sent
([The fast path](#the-send-log-keeps-runs));
a block covering part of a segment is conservative, the segment stays
unSACKed, and neighbouring SACKed ranges merge, so repeated or wide
blocks cannot grow the log. And the unSACKed ranges marked lost are a
prefix of the unSACKed ranges, since `IsLost` is monotone downwards and
marking lost takes only an end and marks from `snd_una`, so the pipe is a
constant-time sum of byte counters kept by the one function that changes
a range, `(snd_max - snd_una) - sacked - lost + rxt`, as FreeBSD's
`tcp_compute_pipe` computes it (`tcp_input.c:4149`).

The receiver's side, `erx_tcp_sack`, is written from RFC 2018 section 4
and RFC 2883 section 4, not translated from `tcp_sack.c`
([Provenance and notices](#provenance-and-notices) says why). It is a
pure value beside the reassembly queue: the ranges the queue holds above
`rcv_nxt`, taken from it after every segment and ordered most recently
touched first, the range the segment touched leading, and the D-SACK
block, the lowest part of the last duplicate segment that the receiver
already had, reported once and first, with the range that contains it
second. An acknowledgement carries at most four blocks, and the encoder
keeps as many from the front as the other options leave room for.
`erx_tcp_reass` translates `tcp_reass` (`tcp_reass.c:516`): an ordered
map of out-of-order ranges with FreeBSD's overlap trimming and its cap
of 100 queued segments (`tcp_reass_maxqueuelen`, `tcp_reass.c:110`), and
the bytes it holds counted against the receive buffer.

A held payload is counted at the size of the binary it references, not
its own size, since a sub-binary keeps its whole frame alive; a payload
smaller than a quarter of its frame is copied out before it is kept, as
FreeBSD's socket buffers compress small mbufs. So a peer cannot pin many
full frames with one-byte segments.

### Loss detection and congestion control

Two behaviours carry the seams FreeBSD has, with their callbacks taken
from FreeBSD's own interfaces.

`erx_tcp_loss` is the loss-detection part of FreeBSD's function block.
Its callbacks handle an acknowledgement (mark ranges SACKed or lost,
enter or leave recovery, and answer `continue` or `drop`, whether the
rest of the segment is processed); a rewind of sending to `snd_una` when the retransmission
timer expires, the path MTU drops or the window shrinks to zero after
data was sent into it (FreeBSD's `tfb_tcp_mtu_chg`, widened to every
path that moves `snd_nxt` back, so a module never keeps a stale view of
the flight); the window for the output after the last acknowledgement;
and the module's own deadline, such as RACK's reordering timer, and its
expiry.

A loss module never calls the congestion module. Its events are the calls
the connection makes, in order: `{cong_signal, Signal}`,
`{ack_received, dupack}`, stopping the retransmission timer, `TF_ACKNOW`,
and `snd_nxt = snd_max`. `drop` is FreeBSD's `goto drop` after a
duplicate acknowledgement or the entry to recovery. During recovery and
limited transmit the loss module, not the congestion module, sets the
window, as `tcp_input.c` sets `snd_cwnd` around its calls to
`tcp_output`: after each acknowledgement and its events, the connection
asks the module (`allowance`) for a window to send with, measured
against the log's pipe, and one to keep in the congestion state
afterwards, or `none` when the congestion module's window stands. What FreeBSD
counts in `tcp_output` for the loss code (`snd_limited`, PRR's
`prr_out`) is read from the log instead, and NewReno's retransmission
from `snd_una`, which FreeBSD makes by moving `snd_nxt` back, is a range
marked lost that output resends first.

The default module, `erx_tcp_loss_dupack`, translates the default stack's
duplicate-acknowledgement processing in `tcp_do_segment`: three duplicate
ACKs, SACK-based recovery (RFC 6675 section 5, entered on the third
duplicate or on more than `(DupThresh - 1) * SMSS` SACKed bytes), NewReno
partial ACKs when SACK is off (`tcp_newreno_partial_ack`,
`tcp_input.c:4114`; RFC 6582 section 3.2), proportional rate reduction
(`tcp_do_prr_ack`, `tcp_input.c:4026`; RFC 6937 section 3; on by default,
`tcp_do_prr`, `tcp_input.c:162`), limited transmit (`tcp_do_rfc3042`,
`:172`; RFC 3042), and the timeout's choice between resending the holes
and forgetting the SACK information (`tcp_timer_rexmt`; RFC 6675 section
5.1). Where FreeBSD's code is in `tcp_sack.c` the module follows the RFC:
a partial acknowledgement without SACK blocks during SACK recovery takes
PRR's path (RFC 6937), and "new loss" for PRR (RFC 6937 section 3) is bytes
newly marked by `IsLost`. FreeBSD's lost-retransmission detection
(`tcp_do_lrd`) is not built: no RFC specifies it, and its only description
is its code in `tcp_sack.c`, which erXos does not read. It is the only
loss module. RACK-TLP, which is deferred, would be a second one,
`erx_tcp_loss_rack`, implementing RFC 8985 over the same log; BBR would
be a congestion module beside CUBIC, with pacing added to output.

`erx_tcp_cc` is `struct cc_algo` (`cc/cc.h:145-195`), its callbacks and
signals FreeBSD's (`cc/cc.h:119-128`), each a pure function of FreeBSD's
`struct cc_var` as `#ccv{}` and the module's own state. As `cc_var`
holds `cc_data`, the `#ccv{}` holds the module's state and the control
block fields a module reads through `CCV()`; the connection keeps it for
its life and refreshes those inputs before each call. It carries
FreeBSD's two recovery flags, which a module sets as FreeBSD's do and
the connection clears, and from which the loss module's recovery state
is taken. The callers translate `cc_conn_init`, `cc_ack_received`,
`cc_cong_signal` and `cc_post_recovery` (`tcp_input.c:290-516`) and
`cc_after_idle` (`tcp_output.c:174`). `erx_tcp_cc_newreno` and
`erx_tcp_cc_cubic` translate `cc_newreno.c` and `cc_cubic.c`, CUBIC's
fixed-point arithmetic as integer Erlang. The initial window follows
`tcp_compute_initwnd` (`tcp_input.c:4167`), ten segments under RFC 6928's
limits.

A socket chooses its modules by name with the options `{congestion,
Name}` and `{loss, Name}`, FreeBSD's `TCP_CONGESTION` and
`TCP_FUNCTION_BLK`. Names arrive as binaries and are looked up in a fixed
table of the modules the build contains, so no client name becomes an
atom and no module outside the table can be chosen. The defaults, CUBIC
and `dupack`, come from the `erx_net` application's environment.

### Connection setup

**Active open.** `gen_tcp:connect` asks the grant, which checks its
limits, starts the connection process with `proc_lib:start_link/3` and
waits for its initialisation. The connection claims a local port and its
four-tuple through `erx_net_bind`, the one funnel for both
([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)),
receives from that claim its initial sequence number and timestamp
offset, which `erx_net_bind` computes because it holds the secrets,
sends the SYN and acknowledges its start. No connection holds the
secrets, so no connection's state or crash report can show them.
`erx_tcp_isn` translates `tcp_new_isn` (`tcp_subr.c:3521`): a SipHash of
the four-tuple under a secret, plus a clock. FreeBSD's clock is a shared
offset advanced at 1,048,576 a second and by a random amount per
connection, under a lock; the stack's clock is the monotonic time in
microseconds, RFC 6528's own construction, so the function stays pure
and needs no shared counter. The secret is drawn once at the stack's
start, and never reseeded, as FreeBSD's default
`tcp_isn_reseed_interval` of 0 (`tcp_subr.c:286`) leaves it.

**Passive open.** A SYN for a listener is handled in the interface
process, as FreeBSD handles it in the input path, so a SYN flood reaches
no other process and creates no process:

* `erx_tcp_syncache` translates `tcp_syncache.c`: `syncache_add`
  (`:1363`), `syncache_respond` (`:1799`), `syncache_expand` (`:1040`)
  and `syncache_chkrst` (`:615`). Each interface process holds a bounded
  table of half-open connections, 15,360 entries by default, FreeBSD's
  512 buckets of 30 (`tcp_syncache.c:162-163`), with SYN-ACK
  retransmission under FreeBSD's limit and backoff, driven by the
  interface's deadlines.
* Before it looks the SYN up, the syncache drops a SYN to or from
  itself, from or to a multicast address or from the limited broadcast,
  the checks `tcp_input` makes before `syncache_add`
  (`tcp_input.c:1295-1338`) that read the four-tuple alone. A SYN to a
  broadcast or multicast address never reaches it: the listener row of
  [Classifying a frame](#classifying-a-frame) drops it by the class the
  IP layer found for the destination on the receiving interface, so the
  broadcast addresses of that interface (`in_ifnet_broadcast`) are
  tested in one place, the IP layer's.
* SYN cookies are on, as FreeBSD's default (`tcp_syncookies`,
  `tcp_syncache.c:105`): every SYN-ACK's initial sequence number is a
  cookie (`tcp_syncache.c:1726-1729`): 24 bits of a SipHash-2-4 MAC of
  the connection, the window-scale and MSS indexes, the SACK flag and a
  bit naming which of two secrets made it (`syncookie_mac`,
  `tcp_syncache.c:2194`; the layout at `:2154-2163`). The secrets
  alternate, one replaced every 15 s (`SYNCOOKIE_LIFETIME`,
  `tcp_syncache.h:110`; `syncookie_reseed`, `tcp_syncache.c:2419`), so a
  cookie validates for 15 to 30 s. An ACK that matches no entry is
  checked as a cookie only while the table is paused or if it overflowed
  in the last 15 s, as FreeBSD checks only then
  (`tcp_syncache.c:1053-1056`, `:1095-1110`). FreeBSD records the last
  overflow per bucket (`sch_last_overflow`); the stack has one table per
  interface and records it for the table. Since an overflow pauses the
  table, and FreeBSD's pause covers every bucket, the two differ only in
  the second a first 15 s pause ends: there a valid cookie can complete a
  handshake that FreeBSD, whose bucket for it had not overflowed, would
  refuse. The cookie's MAC is required either way. The cookie secrets
  are stack-wide, in `erx_net_tables`, so an ACK that arrives on another
  interface still validates; FreeBSD's MAC also covers the bucket's
  address, which one table has no use for.
* A SYN that finds the table full pauses it, as a full bucket pauses
  FreeBSD's cache (`syncache_insert`, `tcp_syncache.c:367`;
  `syncache_pause`, `:2446`). The table drops every entry, and until the
  pause ends it makes no entry, answers each SYN with a SYN-ACK alone and
  checks every ACK that matches no entry as a cookie. FreeBSD drops the
  full bucket's oldest entry for the new one, but once paused it looks no
  entry up and its timer drops every entry without answering
  (`syncache_timer`, `:485-497`), so dropping them all when the pause
  starts is the same rule with one table for the bucket; the table
  overflows when it holds 15,360 entries, where FreeBSD's first bucket
  fills at 30. A pause lasts 15 s (`TCP_SYNCACHE_PAUSE_TIME`). One that
  starts less than the last pause's own length after that pause ended
  doubles it, up to six times, to 16 minutes
  (`TCP_SYNCACHE_MAX_BACKOFF`); any other lasts 15 s again. The table
  keeps the end of the last pause and its doublings, in whole seconds of
  uptime, and is paused while the uptime is before the end, the test
  `syncache_unpause` makes, so the pause needs no timer; FreeBSD makes
  that test when its callout fires, so its pause can end up to a second
  later. The pause is the interface's, so a flood on one interface
  leaves the others' handshakes their entries. Until a flood fills the
  table, each entry draws up to three SYN-ACK retransmissions to a
  spoofed source; while the pause lasts each SYN is answered once. An
  entry is lost to a flood only as FreeBSD loses it: all at once, when
  the pause starts, after which its handshake completes by its cookie.
* The secrets are context, not state. `erx_net_tables` draws the two
  cookie keys and rotates them every 15 s; the interface process reads
  them, with the timestamp secret, at each SYN or ACK for a listener and
  passes them to the syncache in the step's context. Neither the table
  nor an entry holds a key: an entry keeps its cookie and its timestamp
  offset, and those values alone reach the connection in the
  handshake's result. The secrets value keeps its keys in a closure,
  whose environment a crash report does not print.
* A signed (TCP-MD5) SYN or ACK to a listener is dropped: the SYN and
  an ACK under a cookie as a FreeBSD kernel without TCP-MD5 drops them,
  an ACK for an entry where FreeBSD would complete it. A SYN repeated
  for an entry may withdraw ECN but never grant it (`syncache_add`,
  `tcp_syncache.c:1543-1546`).
* When the handshake completes, the interface process takes one unit of
  the listener's accept credit, the free places of its backlog, spawns the
  connection process with its initial state, the handshake's result and
  the completing segment, and inserts the four-tuple into the
  demultiplexing table before it handles its next frame, so no later
  segment of the connection finds neither the syncache entry nor the
  connection. With no credit left, the interface answers with a RST,
  FreeBSD's default when a completed handshake finds no room
  (`tcp_sc_rst_sock_fail`, `tcp_syncache.c:215`;
  `tcp_input.c:1115-1135`).

Once its grant has adopted it, the connection joins its listener's
queue, and an `accept` takes it from there; closing the listener aborts
every connection still queued, with a RST, as FreeBSD's `soclose` does
([The listener](#the-listener)).

### TIME-WAIT

TIME-WAIT is a state of the connection process, as FreeBSD 15 keeps it a
state of the full control block (`tcp_twstart`, `tcp_timewait.c:148`).
The process hibernates for the 2MSL period, 60 s, or 20 ms when the peer
is one of the machine's own addresses (`tcp_eff_msl`'s `TCPTV_MSL_LOCAL`,
`tcp_timewait.c:115-135`, `tcp_timer.h:77`), so it holds only its
smallest heap. The step's path selects the lifetime: a path to one of
the stack's own addresses is `loopback` (the test of `in_localip` and
`in6_localip`, `in.c:154-166`, `in6.c:1844-1859`), and the step's
context carries that flag to TIME-WAIT. The process rebuilds its path
whenever the configuration has changed before a step, so the lifetime is
decided over the configuration of the step that starts TIME-WAIT, or of
the step whose retransmitted FIN restarts it, as FreeBSD asks at both
(`tcp_timewait.c:184`, `:332`). Until the period ends the connection's
key holds its port against a listen without `reuseaddr` (rule 4 of
**Explicit binds**, in
[Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)),
so a loopback connection's port is free again 20 ms after its TIME-WAIT
starts, as on FreeBSD. `erx_tcp_timewait` keeps FreeBSD's rules
(`tcp_twcheck`, `tcp_timewait.c:197`), and the step hands it every
segment that reaches the connection in TIME-WAIT in place of the
pipeline: a RST is dropped (RFC 1337); a new SYN that RFC 6191 allows, by
a newer timestamp or a higher sequence number, ends the old connection:
the process removes its entry and reinjects the SYN to its interface
process, which looks for a listener as `tcp_twcheck` returning true makes
`tcp_input` do; any other segment without ACK is dropped; a
retransmitted FIN restarts the 2MSL period; and every segment but a bare
duplicate ACK is acknowledged.

A connection in TIME-WAIT whose socket process is gone does not count as
one of its grant's sockets. It counts toward the grant's `time_wait`
limit; past that limit a closing connection skips TIME-WAIT, as FreeBSD
did before 15 when its compressed time-wait zone was full. This is a
departure from 15, which has no limit, made because every TIME-WAIT
process is memory held for one client.

### ICMP and path MTU

The interface process decodes ICMP and ICMPv6 errors and hands each to
the socket its quoted header names, as an owned item. `erx_tcp_icmp`
translates `tcp_ctlinput_with_port` (`tcp_subr.c:3091`): a report whose
quoted sequence number lies outside `snd_una` to `snd_max` is ignored
(RFC 5927); fragmentation-needed and packet-too-big lower the path MTU
through `tcp_mtudisc` (`tcp_subr.c:3594`) and `tcp_mss_update`
(`tcp_input.c:3742`), and only ever lower it, from an MTU raised first to
256 bytes for IPv4 (`tcp_minmss` with its headers, `tcp_next_pmtu`) and
1,280 for IPv6 (`tcp6_next_pmtu`), and the step's output resends the
flight from `snd_una` at the new size; a port unreachable or time exceeded
report in SYN-SENT ends the connection, as `tcp_drop_syn_sent`
(`tcp_subr.c:3559`) does; and every other error is a soft error
(`tcp_notify`, `tcp_subr.c:2580`), ignored for a host unreachable once
established, ending a handshake that has timed out more than three times
after an earlier one, and otherwise reported by the connection's timeout.
The lowered MTU lives in the connection's MSS until the host cache
extension keeps it per destination.

### Defaults kept

| Feature | FreeBSD default | Stack |
| --- | --- | --- |
| syncache and SYN cookies | on (`tcp_syncache.c:105`) | on |
| RFC 5961 | on (`tcp_insecure_syn`, `tcp_insecure_rst`, `tcp_insecure_ack` all 0, `tcp_input.c:197-209`) | always on; no knob |
| RFC 6528 | `tcp_new_isn` | always |
| window scaling and timestamps | on (`tcp_do_rfc1323`, `tcp_subr.c:207`) | on |
| SACK with RFC 6675 recovery | on (`tcp_do_sack`) | on, written from RFC 2018, RFC 2883 and RFC 6675 |
| lost-retransmission detection | on (`tcp_do_lrd`) | not built: no RFC specifies it and its code is in `tcp_sack.c` |
| PRR, limited transmit, IW10 | on (`tcp_input.c:162-178`) | on |
| ECN | 2: accept when the peer asks, never initiate (`tcp_do_ecn`, `tcp_ecn.c:106`) | 2, so a peer that asks for AccECN gets RFC 3168 ECN, as `tcp_ecn_syncache_add` answers it (`tcp_ecn.c:509-537`); like FreeBSD, a SYN-ACK with ECE alone turns ECN on although our SYN did not ask, where RFC 3168 section 6.1.1 would leave it off (`tcp_ecn_input_syn_sent`, `tcp_ecn.c:120`) |
| missing timestamps on a connection that negotiated them | tolerated (`tcp_tolerate_missing_ts`, `tcp_subr.c:219`) | tolerated |
| FIN-WAIT-2 recycling at 60 s | off (`tcp_fast_finwait2_recycle`, `tcp_timer.c:143`) | off |
| delayed ACK | on (`tcp_delack_enabled`, `tcp_input.c:152`) | on |
| buffer autosizing | on (`tcp_do_autosndbuf`, `tcp_output.c:116`; `tcp_do_autorcvbuf`, `tcp_input.c:217`) | on, within the grant's buffer budget |
| CUBIC | default (`cc/cc.c:83`) | default |
| path MTU discovery; black-hole detection | on; off (`tcp_timer.c:170`) | on; off |

## IP, neighbours and UDP

### IPv4 and ARP

`erx_ip4_wire` makes the checks `ip_input` makes before it reads a
packet: version, header length, header checksum and total length, with
the trailing bytes cut at the total length. `erx_ip4` translates the
decisions of `ip_input.c` and `ip_output.c`: the bogus-address checks,
delivery or drop (the
stack forwards nothing), header fields on output, and fragmentation of
datagrams larger than the path MTU. IPv4 options are checked for their
lengths and otherwise skipped, and a packet carrying a source-route
option is dropped, as FreeBSD's defaults drop one that reaches a host
(`ip_dosourceroute` and `ip_acceptsourceroute` both 0,
`ip_options.c:70-80`); skipping the record-route and timestamp options
is a departure visible only in echo replies, which FreeBSD gives the
request's options. `erx_ip4_wire` refuses a packet with a malformed
option, one whose length byte is missing, below 2 or past the header,
and returns the offset of that byte, which `ip_dooptions` makes the
pointer of the parameter problem it answers with (`ip_options.c:132-138`),
so `erx_ip4` can send the same answer after its loopback check.
`erx_ip4` also drops a TCP segment from 0.0.0.0, the check
`tcp_input_with_port` makes (`tcp_input.c:751`): it is the one decision
that sees a segment's IP header before the TCP lookup, and `erx_ip6`
drops one from `::` in the same place (`tcp_input.c:675`).
`erx_ip4_reass` translates `ip_reass.c`, with
FreeBSD's caps on the datagrams in reassembly, the fragments per datagram
and the lifetime of a queue, all charged to the interface. It and
`erx_ip6_reass` share one table, `erx_ip_reass`, a pure value the
interface process keeps per family, with its deadline among the
interface's others. Its caps are FreeBSD's where FreeBSD fixes them: 16
fragments per IPv4 datagram and 64 per IPv6 one (`maxfragsperpacket`,
`ip6_maxfragsperpacket`), and lifetimes of 30 and 60 seconds
(`ipfragttl`, `IPV6_DEFFRAGTTL`). Where FreeBSD derives them from the
machine's mbuf clusters, an interface holds at most 1,024 datagrams,
1,024 fragments and 2 MiB, FreeBSD's values at 32,768 clusters of
2 KiB. A held fragment counts at the size of the binary it keeps alive,
and one under a quarter of that is copied out first, as for
`erx_tcp_reass`; the header kept from a datagram's offset-0 fragment
counts at its length and keeps no frame alive. A fragment that starts a
new datagram past the datagram cap pushes out the
oldest IPv4 datagram (`ipq_reuse`) and is dropped for IPv6
(`frag6_input`). A completed datagram leaves the table as a packet, the
first fragment's headers without fragmentation in front of the whole
data, and passes the codec and the input decisions again, as FreeBSD
requeues it, so the decoder stays the only maker of a received record
and the IPv6 headers after the fragment header are walked as any
others. `erx_icmp4`
translates `ip_icmp.c`: echo replies, but never to a broadcast or
multicast destination, and errors generated within FreeBSD's limit of
200 a second (`icmplim`, `ip_icmp.c:84`), moved by a jitter of up to 16
either way that is drawn again from the interface's generator each time
the limit is reached, as `badport_bandlim` moves it for every limit it
keeps, RSTs to closed ports included (`icmplim_jitter`, `ip_icmp.c:93`;
`icmplim_new_jitter`, `:1107`), so the limit cannot be used to count
which probes reached open ports. The limits are `erx_net_bandlim`'s, a
pure part of the interface's state with one one-second window for each
kind of answer, as `badport_bandlim` keeps them. A timestamp reply
carries the milliseconds since midnight UTC (`iptime`), which the
interface's loop reads from the wall clock and passes in the
context. Redirects are accepted by
FreeBSD's rules, as its defaults accept them (`drop_redirect`,
`ip_icmp.c:128`; `icmp6_rediraccept`, `icmp6.c:125`): each becomes a
host route of the interface with FreeBSD's expiry (`icmp_input`'s
redirect case, `ip_icmp.c:664`; `rib_add_redirect`, `net/route.c:190`;
`icmp6_redirect_input` for IPv6), and the interface holds at most 64
such routes, dropping new redirects past that, a bound FreeBSD does not
have, for the reason the router and prefix lists have theirs
([IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration)).

The identification field follows `ip_fillid` (`ip_id.c:241`): zero on a
datagram with DF set, which RFC 6864 allows and FreeBSD's default
`ip_rfc6864` of 1 does (`ip_id.c:99`), so a TCP connection, which sets
DF for path MTU discovery, sends no identification at all; and a random
value on any other datagram. That is a departure from FreeBSD's default,
a counter shared by every flow (`ip_random_id` 0, `ip_id.c:102`): a
shared counter is state with many writers, and it tells an observer how
much the machine sends to anyone, which an idle scan exploits. The value
is two bytes of the generator of the owner that builds the datagram: a
datagram socket for its datagrams, the interface for its own ICMP
messages. FreeBSD's random mode also refuses a value
among the last 8,192 it gave (`ip_randomid`, `ip_id.c:214`); the stack
keeps no such history, since across owners it would be a table with many
writers and within one it would cost each socket 16 KiB, and a repeated
value matters only between two fragmented datagrams to one destination
within its reassembly lifetime. IPv6 fragment headers carry a random
identification, as `ip6_randomid` gives them (`ip6_output.c:1247`),
drawn the same way.

`erx_arp` translates `if_ether.c`: the entry states, requests retried 5
times (`arp_maxtries`, `if_ether.c:102`), entries kept 20 minutes once
resolved (`arpt_keep`, `if_ether.c:100`), 16 frames held per unresolved
entry, gratuitous ARP and FreeBSD's rules for which replies may create
or update an entry. The table has a bound per interface, 1,024 entries;
past it the oldest unresolved entry is evicted, else the oldest resolved
entry the protocol lets go, and when there is neither, no entry is
made. ARP lets go of any resolved entry no transmitter has hinted in its
last seconds; the IPv6 neighbour cache keeps the same bound and lets go
only of a stale entry no transmitter has hinted (RFC 4861 5.3), keeping
reachable, delay and probe entries. Only an entry this host creates to resolve a neighbour makes room so;
an entry learnt from an unsolicited ARP request or neighbour
solicitation takes only free room and evicts nothing, as FreeBSD's
`lltable` limit, `llt_maxentries`, refuses every new entry once
reached (neither protocol sets it there, so FreeBSD's tables are
unbounded). An on-link sender cycling through spoofed sender
addresses in ARP requests or solicitations therefore pushes out
nothing. One that sends packets drawing a reply (an echo request, a
segment to a closed port) still makes this host resolve each
spoofed source, and those resolutions do make room, a residual
`TODO.md` records. Both tables
are one module, `erx_lltable`, as FreeBSD's `lltable` serves both: a
keyed map ordered by deadline, whose `publish` and `unpublish` actions
for the transmit path follow from each change of an entry, so neither
protocol can change an entry without publishing it. `erx_arp_wire` accepts the two
Ethernet hardware types (`ARPHRD_ETHER` and `ARPHRD_IEEE802`) with 6-byte
addresses and refuses every other. `arpintr` also passes InfiniBand and
FireWire packets on (`if_ether.c:691-720`), and `in_arpinput` drops
those whose address length is not the interface's; so on an Ethernet
interface FreeBSD answers a packet typed FireWire that announces 6-byte
addresses, a hardware type no interface of this stack has, which the
stack refuses.

### IPv6, neighbour discovery and autoconfiguration

`erx_ip6` translates `ip6_input.c`, `ip6_output.c`, `dest6.c` and
`route6.c`: the fixed header with its payload length checked and the
trailing bytes cut, a bounded walk of the extension headers (hop-by-hop
and destination options parsed and skipped by their option types'
rules, routing header type 0 refused as RFC 5095 requires, an unknown
routing type with segments left zero ignored, a zero payload length
and a jumbo payload option dropped silently, as RFC 2675 is gone upstream),
and the first fragment required to hold the whole header chain (RFC
7112). `erx_ip6_reass` translates `frag6.c`, with RFC 5722's rule that an
overlapping fragment discards the whole datagram, and FreeBSD's caps.
`erx_icmp6` translates `icmp6.c`: echo, errors within their rate limit,
packet-too-big. Its limits are `icmp6_ratelimit`'s, one window for each
kind of answer at 100 a second (`icmp6errppslim`, `icmp6.c:2725`) moved
by a jitter of up to 8 either way (`icmp6lim_jitter`), kept in
`erx_net_bandlim` beside the IPv4 limits. As for IPv4, `erx_ip6`
decides once whether a datagram may be answered, and nothing answers a
packet to a multicast address: FreeBSD answers an echo request to a
multicast group, and a parameter problem about an option whose type
asks for one even then (`icmp6_error`, `icmp6.c:268`), which a host
has no reason to do.

A neighbour-discovery message that came in fragments is dropped (RFC
6980), as FreeBSD drops one whose mbuf carries `M_FRAGMENTED`
(`frag6.c:286`; `nd6_nbr.c:146`, `:674`; `nd6_rtr.c:183`, `:384`;
`icmp6.c:2184`). A reassembled packet carries no fragment header, so
the interface tells `erx_ip6` whether reassembly rebuilt the packet it
hands in, and `erx_ip6` drops a router or neighbour message, or a
redirect, that reassembly rebuilt or that carries an atomic fragment
header, before `erx_nd6`, `erx_nd6_rtr` or `erx_icmp6` sees it. The
type it reads is not yet covered by the ICMPv6 checksum, which can only
turn a drop for a bad checksum into this drop.

`erx_nd6` translates `nd6.c` and `nd6_nbr.c`: the neighbour cache's
states with unreachability detection, neighbour solicitations and
advertisements accepted only with a hop limit of 255 (RFC 4861),
and 16 frames held per unresolved neighbour; a solicitation or
advertisement about a tentative address goes to `erx_nd6_dad`, which
translates the detection of `nd6_nbr.c` (RFC 4862 with RFC 7527's
nonces): one probe after the random delay below, a decision one
retransmission interval later, and more probes while only the
interface's own probes come back. Like FreeBSD it decides at the end of
the probes, not at the first answer. The interface stops the detection
of an address it removes and, as RFC 4862 5.4 asks, of every tentative
address when its link goes down, and starts them again when it comes up.
`erx_nd6_rtr` translates `nd6_rtr.c` and `in6_ifattach.c`:
router solicitations, router advertisements, the default-router and
prefix lists with their lifetimes, and stateless address
autoconfiguration (RFC 4862). The interface joins the all-nodes and
solicited-node groups and sends the MLDv2 reports those groups need, so
switches that snoop MLD forward neighbour solicitations; the rest of
multicast is `erx_mcast` ([Scope](#scope)). Redirects are accepted as
for IPv4, by RFC 4861's rules, which `icmp6_redirect_input` checks.

The random values of neighbour discovery are FreeBSD's, drawn from the
interface's generator. The reachable time lies between half and one and
a half times its base, as `ND_COMPUTE_RTIME` bounds it (`nd6.h:196`), and
the stack draws it uniformly over that interval with `uniform/2`.
FreeBSD ANDs a random word with a mask that is not a power of two, which
is not uniform and gives whole seconds: a departure in timing alone,
within FreeBSD's interval. The other values are the delay
of up to one second before a new address's MLD report and duplicate
address detection (`in6_update_ifa_join_mc`, `in6.c:696`;
`in6_broadcast_ifa`, `in6.c:1164`; `MAX_RTR_SOLICITATION_DELAY`,
`nd6.h:179`); and the nonce of each detection probe, RFC 7527's enhanced
detection, which FreeBSD enables by default (`dad_enhanced`,
`nd6_nbr.c:104`; `nd6_dad_ns_output`, `nd6_nbr.c:1587`). A connection
opened over IPv6 takes a random flow label at its start, as FreeBSD's
default `ip6_auto_flowlabel` of 1 gives one (`in6_proto.c:163`;
`in6_pcbconnect`, `in6_pcb.c:516-520`), and a SYN-ACK carries the low 20
bits of its cookie, as `syncache_add` sets them
(`tcp_syncache.c:1730-1737`).

The default-router list holds at most 16 routers and the prefix list at
most 16 prefixes per interface, and each autoconfigured address belongs
to one listed prefix. A router advertisement that would add a router or
a prefix past its bound is ignored for that entry and counted, while
listed entries keep refreshing their lifetimes, so an on-link sender
that fills the lists first can keep later routers out but cannot evict a
router already listed. FreeBSD has no such bound, and RFC 4861 lets a
router's entry live up to 9,000 s, so without one any on-link sender
that passes the hop-limit rule grows the lists at the ingress bucket's
rate; this is a departure for requirement N4, as the TIME-WAIT limit is.

Interface identifiers are RFC 7217's stable, opaque identifiers
(`in6_get_stableifid`, `in6_ifattach.c:342`), by default, where FreeBSD's
default derives them from the MAC address (EUI-64; `ip6_use_stableaddr`
0, `nd6_rtr.c:97`). The identifier is FreeBSD's HMAC-SHA-256 of the
prefix, the interface's name and its duplicate-address-detection
failures, keyed with a secret of the machine where FreeBSD keys it with
the host's UUID, so it is the same on every boot for one network and
unrelated across networks, and no IPv6 address names the hardware
([Decisions](#decisions), 2). The secret is a machine key of 32 random
bytes, which the vault makes at installation and keeps with the
machine's other keys across boots and updates
([design-system.md](design-system.md#the-vault)). As with every key the
vault holds, the key never enters the domain that uses it: the system
domain grants the network domain a key facet whose one purpose is this
identifier, and `erx_nd6_rtr` asks it for the HMAC of each prefix,
interface and failure count, once per address it forms. The message is
FreeBSD's without the host UUID, which is the key here: the prefix's
first 64 bits, the interface's name, the failure count as 8
little-endian bytes and an offset byte, raised and asked again while the
identifier falls in a reserved range (`validate_ifid`). The link-local
address is formed the same way from `fe80::/64`. Router solicitations
follow RFC 4861 section 6.3.7, which FreeBSD leaves to `rtsold`: after a
random delay of up to a second, at most 3, 4 seconds apart, until an
advertisement with a router lifetime arrives. While the vault
answers `unavailable`, as it does without its partition, the interface
forms its addresses from random identifiers for that boot, as RFC
8981's temporary addresses are formed, and logs that it did, so an
address is never derived from the MAC address and is stable whenever the
vault serves.

`erx_in6_src` translates `in6_src.c`, RFC 6724's source address
selection, with the labels of RFC 6724's default policy table, which
FreeBSD's `rc.d/ip6addrctl` installs at boot over the kernel's empty
one, and with public addresses preferred over temporary ones, as
FreeBSD's default `ip6_prefer_tempaddr` of 0 prefers them where RFC 6724
prefers temporary ones. IPv6 sockets are IPv6-only by default, as FreeBSD's
`ip6_v6only` is (`in6_proto.c:169`), and `{ipv6_v6only, false}` admits
IPv4-mapped addresses.

### Addresses and routes

An interface process owns its addresses and the routes learnt on it,
from its static configuration, router advertisements or its DHCP client,
and publishes them as rows of the address and route tables, each row
keyed by the interface. `erx_net_addr` translates the address checks of
`in.c` and `in6.c` (local, broadcast, scope). `erx_net_route` looks up
the longest matching prefix over the published rows, a small table on a
host; it is erXos's own code, since the stack needs nothing of FreeBSD's
forwarding tables. A sender keeps its path, built by `erx_net_frame`
from the rows, with the configuration generation it was built at, and
checks the generation on every output pass
([What owners publish](#what-owners-publish), [Framing](#framing)).

The network domain's configuration names each interface's mode:
`static` with addresses, routes and name servers; `dhcp`, for which the
link supervisor starts `erx_dhcp4`; and whether IPv6 autoconfiguration
runs, which it does by default. `erx_dhcp4_core` is a pure RFC 2131
state machine with RFC 2132's options and RFC 3442's classless static
routes, written from the RFCs with FreeBSD's `dhclient` as the
behavioural reference, over the message codec `erx_dhcp4_wire`, the only
maker of a received DHCP message, which reads the option overload and
translates `dhclient`'s checks of routes and domain names; `erx_dhcp4` is
its process, a child of the link supervisor
([Decisions](#decisions), 3). Its transaction ids and randomised
retransmission delays come from the generator in its state. The
retransmissions of a DISCOVER or of the REQUEST for an offer follow
`dhclient`'s timing, not RFC 2131 section 4.1's 4 seconds doubling to
64: in whole seconds, an exchange starts from an interval of 3 seconds
(`initial_interval`, `sbin/dhclient/clparse.c:83`), each send grows it
by a uniform 0 to twice itself less a second, on average doubling it,
and an interval past 15 seconds (`backoff_cutoff`, `clparse.c:82`) is
drawn again from 7 to 21 seconds (`send_discover`,
`sbin/dhclient/dhclient.c:1381-1396`). The REQUEST uses that rule too,
where `dhclient`'s `send_request` draws again over the grown interval
(`dhclient.c:1602-1606`), so no wait exceeds 21 seconds. While no
server answers, DISCOVERs go on at those waits indefinitely, a
deliberate departure from `dhclient`, which gives up after its
60-second `timeout` (`clparse.c:78`, `dhclient.c:1342-1347`) and
starts again only after its 300-second `retry_interval`
(`clparse.c:81`, `state_panic`, `dhclient.c:1521`): a kiosk whose
router comes up late must get its address within one wait, at most 21
seconds, of the router answering, not up to five minutes later. The
client's fresh start at each link up covers a cable plugged in later,
not a router that answers later over a link already up. After a
NAK the DISCOVER waits an exchange's first wait, 3 to 8 seconds, where
`dhclient` starts again at once (`dhcpnak`, `dhclient.c:1325-1326`). As
`dhclient` does, the client takes the first acceptable offer, sends
nothing until its link is up
(`sbin/dhclient/dhclient.c:466-480`; it waits without the 11 s limit
after which `dhclient` gives up), makes no random wait before its
first DISCOVER, notes each lease it configures in the log as `dhcp: NAME
bound to ADDRESS` (`dhclient` notes each binding, `dhclient.c:921`; a
renewal that changes nothing configures nothing here), counts
a lease shorter than a minute as a minute, and does not probe the
offered address with ARP before using it: the interface announces the
address with a gratuitous ARP when it configures it, and `erx_arp`
reports another host answering for it as a conflict.

DHCP needs to send and receive before the interface has an address,
which FreeBSD's `dhclient` does through BPF. Here it is one fixed path
of the interface process, not a socket, so it needs no exception in
`erx_net_bind`:

* **Sending.** `erx_dhcp4` hands the interface process a DHCP message;
  the interface alone frames it, from `0.0.0.0` or, once bound, from the
  leased address, port 68, to the broadcast address or, when renewing,
  the server's address, port 67. A broadcast takes the path
  `erx_net_frame` gives the limited broadcast on a named interface, which
  needs no route ([Framing](#framing)); a unicast renewal takes an
  ordinary path. No other process can send from `0.0.0.0`.
* **Receiving.** `classify/2` returns an unfragmented UDP datagram to
  port 68 on an interface configured for DHCP as `local`, before any
  address check ([Classifying a frame](#classifying-a-frame));
  once `verify/1` has checked the datagram, the interface gives it to
  its `erx_dhcp4` only
  when its transaction id is the client's outstanding one and its client
  hardware address is the interface's; every other datagram to port 68
  is dropped and counted. These datagrams are unowned traffic and spend
  the interface's ingress bucket.
* **Applying.** A lease is untrusted input: `erx_dhcp4_core` checks every
  option's length and value, and what it applies goes to its own
  interface only, through the interface's own step, as a static
  configuration would: an address and netmask; routes, the classless
  static routes when the server sends them, in which case the router
  option is ignored (RFC 3442), and otherwise a default route to the
  first router; an MTU from option 26, at least 68 and at most the
  device's; and name servers and a search list, from options 6 and 15,
  which the grant's `resolver` operation hands each domain's `inet_db`
  ([Name resolution](#name-resolution)), as `dhclient-script` writes
  resolv.conf's `nameserver` and `search` lines. A route's gateway must
  be reachable on the link, and no route may take the subnet's own
  prefix or a destination inside 0.0.0.0/8, 127.0.0.0/8 or 224.0.0.0/3,
  so a server steers only the traffic RFC 3442 gives it. An ACK counts
  only for the address and server it answers, and a renewal that
  changes nothing configures nothing again.

### UDP

`erx_udp` translates `udp_usrreq.c` and `udp6_usrreq.c`: delivery to
the socket bound most specifically, ICMP errors delivered to a connected
socket, and port unreachable errors within the ICMP limit. A datagram
socket holds received datagrams up to its receive buffer, counted in
bytes, and drops beyond it, as a UDP socket's receive buffer does; it
pushes a datagram whole, only when its socket process's byte credit
covers the datagram's length ([The socket process](#the-socket-process)).
UDP-Lite and encapsulation are not part of the stack, and
multicast delivery is `erx_mcast`'s ([Scope](#scope)).

## The effect layer

The effect layer is the stack's processes: the drivers, the interface
processes, the sockets, the grants, `erx_net_tables` and `erx_dhcp4`.
Each reads its inputs, calls its owner's step and carries out the
actions, and decides nothing a pure function could decide. It is written
once and runs in two places: in the network domain, and on stock OTP
29.1.2 outside erXos, as any OTP application runs. The second place is a
development host, where the stack's interop, impairment and
packet-script tests run without QEMU and as many at once as the host has
cores, and equally any node that wants a TCP/IP stack in Erlang over a
tap device or another medium (N12).

### Two places, four seams

| Seam | erXos's implementation | The portable one | Chosen by |
| --- | --- | --- | --- |
| the medium | the driver's transport `erx_virtio_net` or `erx_genet`, over the device NIF | the transport `erx_net_pipe`, over `gen_udp` or a test process; `erx_tap`, over a tap device; `erx_netmap`, over netmap's rings; `erx_net_ether`, a medium another domain lends, on erXos and on a host alike | each interface's entry in the `interfaces` key |
| the clock and entropy | `erx_net_clock` over ERTS's monotonic clock and `erx_bytes:entropy/1` | the same; in a test run, the virtual clock and its seeded generator | the `clock` key |
| the per-byte primitives | `erx_bytes` of the `erx` application, BIFs of erXos's ERTS, those of the network over the C of `erx_net`'s `c_src/` | `erx_bytes` of `erx_net`'s `portable/` directory: the same C, loaded from `priv/erx_bytes_nif.so`, and `entropy/1` from `crypto:strong_rand_bytes/1` | the build: one of the two modules is present |
| the runtime | `erx_net_erxos`: the request limit of erXos's ERTS, and `erx_facet` to run a grant | `erx_net_local`, in `portable/`: no envelopes, no limits, and a plain loop that runs a grant's callbacks | the `runtime` key |

The runtime's seam is the behaviour `erx_net_runtime`, of three
callbacks. `serve(MaxRequest)` makes the calling process take requests
from other domains, each at most `MaxRequest` in decoded size, the
runtime dropping a larger one before it is queued; on erXos every one
arrives enveloped with its origin. `start_grant(Grantee, Limits)` starts
a grant. `children(Interfaces)` names the runtime's own permanent
children of `erx_net_sup`, started last
([The process tree](#the-process-tree)): the grant `local`, and on erXos
the mints of `net` and `network_ctl`. A grant and every socket call
`serve/1` as they start, and `erx_net:mint_grant/4`
([The grant's contract](#the-grants-contract)) calls `start_grant/2`.

The client side, `erx_net_client`, finds its grant through its own
`grant` key, a `{Module, Function, Args}` called once per socket opened,
which answers `{ok, Grant, Origin}` or `{error, Reason}`. `Origin` is
`local` when the grant's domain is the caller's own, so its messages
arrive bare, and otherwise the domain id their envelope carries. On erXos
the key names `erx_net_client_erxos`, which answers from `erx:cap(net)`
and `erx:owner/1` ([design-domains.md](design-domains.md#erlang-interface));
outside erXos it names `{erx_net, local_grant, []}`, the grant `erx_net`
minted for its own node, with `Origin` `local`. A socket process whose
`Origin` is a domain id sets `trap_exit` and then exports itself to that
domain with `erx:export(SockProc, [send, link], Origin)`, naming both
rights, since `erx:export/3` sets a holder's rights to exactly the list
given and a later encode of the pid widens no holder
([design-domains.md](design-domains.md#exports)); with `link` alone the
socket could link to its socket process and send it nothing. Trapping
exits first means a link exit from that domain can never stop it
([The socket process](#the-socket-process)).

The loopback transport, `erx_net_loop`, is the same in both places.
Nothing else differs: the application, its supervisors, its
configuration keys, its tables and every process module are the same,
and no module asks where it runs. The source is laid out by seam: `src/`
holds the stack, which names no module of erXos's but `erx_bytes`, which
both builds provide; `erxos/` holds the transports `erx_virtio_net` and
`erx_genet` with `erx_genet`'s cores and PHY, and `erx_net_erxos`,
built only into erXos's images; `portable/` holds `erx_bytes`,
`erx_net_local` and the host transports with their NIFs' loaders, built
only outside erXos, so a network domain can never be configured with the
local runtime or a host's medium. A key that names a module the build
does not hold stops the start with `{error, {seam, Key, Module}}`.
`erx_net_local` doing nothing for `serve/1` is correct, not merely
harmless: no message outside erXos comes from another domain, so there
is no envelope and no lane to limit, and the grant's admission needs no
variant of its own ([The grant's contract](#the-grants-contract)).

`c_src/` holds the stack's C: the host transports' NIFs, and the
per-byte primitives (the Internet checksum and SipHash-2-4 cores, the
walk over an iodata argument, and the cut of a run and the merge of
received segments,
[The fast path](#the-fast-path)), each with one
copy. erXos's ERTS compiles the primitives as its `erx_bytes` BIFs;
outside erXos `c_src/Makefile` (POSIX make) builds the same functions as
NIFs against the host's own OTP. Both read terms through the walk's
classify function and share its every limit, so they accept and refuse
the same iodata; each checks a starting sum, a key and the update's
binaries itself, and one probe judges both. Because the NIF API copies a
binary that starts at a bit offset whole before its size is known, the
portable module first refuses an argument of more than twice the walk's
limits, by a bounded Erlang walk that copies nothing, and within those
bounds every refusal is the NIF's; erXos's BIFs check the size before
they copy. The paths run one way:
erXos's tree reaches into `erx_net`, whose C includes only its own
headers and `erl_nif.h`, so the package builds alone on any host with
stock OTP and a C compiler. Copying the C out of ERTS's tree would make a
second copy a release of the package could ship out of step, and leaving
it there would give the package a path into erXos's tree; the source
living in the package that ships it removes both.

The portable `erx_bytes` has no Erlang fallback: when its NIF fails to
load, the code server logs why and every call fails with `undef`, `entropy/1`'s included, and the
stack does not start. So the stack never runs on another implementation
than the one erXos runs, and what a host run measures is the stack.
`entropy/1` outside erXos is `crypto:strong_rand_bytes/1`, with the same
refusals as erXos's; a failure of the host's generator raises and never
returns other bytes.

Faster media are the other extension point: NIF transports behind
`erx_net_driver`, each cutting runs in its copy
([The fast path](#the-seam)), with
nothing above the driver changed for them. `erx_netmap` is one; an
`AF_PACKET` or DPDK transport would come the same way.

### The driver

A driver is one process per interface, `erx_net_driver`, running a
transport, its callback module. `erx_net_driver` holds everything the
credits and the interface need, written once: the attach, the receive
and transmit credits, the backlog and the link state. A transport holds
only its medium.

```erlang
-callback init(Config :: map()) -> {ok, link_info(), T} | ignore | {error, Reason :: term()}.
-callback event(Msg :: term(), T) -> {[event()], T} | {stop, Reason :: term()}.
-callback transmit(erx_net_frame:frame() | erx_net_frame:run(), T) ->
    {ok | {ok, Taken :: pos_integer()} | full | {drop, Reason :: atom()}, T}.

-type link_info() :: #{link := ethernet | none,
                       lladdr := <<_:48>> | none,
                       mtu := 68..65535,
                       state := up | down,
                       tx_limit := pos_integer(),      % frames waiting at the driver
                       finish := copy | device | none}.  % who finishes a delayed checksum and a run's cut
-type event() :: {frames, [rx_frame()]}                % binary(), {sum, S, binary()}, {Zone, binary()}
               | {link, up | down}
               | writable                            % room to transmit again
               | {dropped, Reason :: atom()}.        % too_long, stranger, malformed
```

`event/2` turns a message from the medium into events and any other
message into none; a frame the transport refuses is a `dropped` event,
counted by its reason, and a medium that has ended is `{stop, Reason}`.
The driver registers its pid with `erx_net_tables` under its interface's
name, where the interface, started after it, finds it.

**Attaching.** The interface calls `erx_net_driver:attach(Driver,
RxCredit)` in its initialisation; the driver monitors it and answers
`{ok, link_info(), TxCredit}`. The interface writes its row's driver pid
and credit, link, link-layer address, MTU and `finish` from that answer,
so those fields have one source
([Checksums in the copy](#checksums-in-the-copy)). While no interface is
attached, the driver drops what it receives, counted as `detached`.

**Receiving.** The driver cuts each `{frames, Frames}` event into batches
within the merge's limit, `erx_bytes:tcp_merge_limit/0`: a batch ends at
its 256th frame, or at the frame that brings it to 64 KiB
([The fast path](#the-merge-before-classification)),
and a frame of more than 64 KiB, which no medium's MTU allows, is dropped
as `too_long`. It hands each batch to the interface against the receive
credit, one unit per frame, and drops a refused batch whole as `no_room`.
Since every transport's frames pass this one cut, the interface's merge
never meets more than its limit, whatever a medium gives at once and
whatever a peer floods it with.

**Link changes.** The driver keeps the transport's latest link state and
the last one it told the interface, and while they differ hands the
latest against the receive credit, retrying after each later message and
at a clock hint 10 ms after each refusal. Only the latest state is told,
so a device that flaps its link fills nothing. The interface gives its
`erx_dhcp4` the link's state and each change, which on `up` starts again
from INIT-REBOOT, as `dhclient` does on a link change (`state_reboot`,
`sbin/dhclient/dhclient.c:302-309`), and does nothing else: FreeBSD's
IPv6 does nothing on a link event outside its `EXPERIMENTAL` option
(`nd6_ifnet_link_event`, `nd6_rtr.c:339-351`), and `ether_output` tests
only the interface's administrative and driver flags, not its link
(`if_ethersubr.c:337-339`). The link state is the interface's own state,
shown by `netadmin` and the inspector, not a published row, so a
flapping link moves no configuration generation.

**Transmitting.** A sender hands `{transmit, Frames}` against the
transmit credit, one unit per frame, a run taking one for each frame it
holds. `ok` and `{drop, Reason}` take a frame's units; `{ok, Taken}`
takes the first `Taken` frames of a run and keeps its tail at the head of
the backlog
([The fast path](#each-transports-cut));
`full` keeps that frame and those after it in the backlog, which the next
`writable` event resumes. A unit is taken when its frame leaves the
driver, so the transmit credit bounds the driver's mailbox and its
backlog together. The backlog is kept, rather than a full device queue
dropping the frame, because FreeBSD's drivers queue in front of the
device's ring: a burst longer than the ring is sent late, not lost, and a
TCP sender sees no loss its peer did not cause. The interface's own
frames (ARP and neighbour-discovery answers, RSTs, SYN-ACKs) share the
transmit credit with its clients' data and have no reserved share of it
([Residuals](#residuals)).

**Ending.** A driver ends when its medium is gone, and its link
supervisor starts the whole link again, rather than a driver living on
over nothing: a transport's `{stop, Reason}` ends it with `{shutdown,
Reason}`, an exit signal from a port or socket of its medium (it traps
exits) with `{shutdown, {linked, Reason}}`, and a crash, a virtio
device's broken queue included, as a crash. Once the driver runs, no end
but its supervisor's own stop comes before it has lived a second: a stop
sooner waits out the second still answering, its link told `down`, so
that the interface starting beside it attaches and the link's start
completes, and a crash sooner waits out the rest of the second in
`terminate/2`. The hold is measured on the host's clock, not
[the stack's](#the-clock), since what it paces is the supervisor's. A
link start whose interface or DHCP client fails because the driver ended
under it answers the link as started, and the interfaces supervisor
restarts it like any link whose driver ended, so a driver's end never
fails a link's start, nor the stack's start at boot.

A medium that fails at every start, a tap device that is gone or a
device that breaks its queue at once, therefore restarts its link at
most once a second. The interfaces supervisor's intensity is six
restarts per interface over its 5-second period
(`erx_net_driver:starts_within/1`), which a held link never exceeds: OTP's
supervisor keeps a restart while its whole second is within the period of
the latest one's, so what it counts spans less than six seconds, in which
a held link starts at most six times. So a dead or hostile device, or a far end that never returns, never makes the
supervisor give up and take the stack, and the network domain, down.
What ends a link faster adds to that count: a transport whose `init`
fails at a restart, retried at once since the driver never ran
(`erx_virtio_net` answers `ignore` to every failure of its `init`, so on
erXos its interface is only lost until the next boot), or an interface or
DHCP client crashing past the link supervisor's own intensity. A driver
waiting out its hold delays the stack's own stop by at most the rest of
that second. A device that stops completing transmits ends nothing: its backlog fills, senders
are refused against the transmit credit, and the link stays stuck until
the driver's next end.

| Transport | `link`, `lladdr` | `mtu` | `state` | `tx_limit` | `finish` |
| --- | --- | --- | --- | --- | --- |
| `erx_virtio_net` | `ethernet`; the device's address when it offers `VIRTIO_NET_F_MAC`, else a random locally administered unicast address drawn at `init` with `erx_net_clock:entropy/1`, as the virtio specification (section 5.1.5) asks a driver to generate | the device's `mtu` field when it offers `VIRTIO_NET_F_MTU`, else 1,500 | `VIRTIO_NET_S_LINK_UP` of the status field when the device offers `VIRTIO_NET_F_STATUS`, read again at each configuration-change interrupt; else always `up`, as the specification says to assume | the transmit queue's size | `copy`; `device` where the device offers `VIRTIO_NET_F_CSUM` with `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6`, an extension |
| `erx_genet` | `ethernet`; the device tree's address, which the device record carries, else the one the firmware left in the controller, else a random locally administered unicast address drawn at `init`, in FreeBSD's order (`gen_get_eaddr`, `if_genet.c:446-485`); a group or all-zero address is not used | 1,500 | `down` until the PHY reports the link up, then the PHY's latest report | the transmit ring's size | `none` |
| `erx_net_loop` | `none`, `none` | 16,384, FreeBSD's `LOMTU` (`if_loop.c:80`) | always `up` | configured | `none` |
| `erx_net_pipe` | `ethernet`; the configured address, which must be unicast with the locally administered bit set, else `init` fails with `{error, {lladdr, Addr}}` | configured, default 1,500, from 1,280 to 9,000, else `{error, {mtu, N}}` | `up` from `init`; the far end's end stops the pipe, and the driver tells the interface `down` while it waits out its hold | configured | `none`; `copy` in the `process` end's offload mode |
| `erx_tap` | `ethernet`; the configured address, checked as the pipe's | configured, checked as the pipe's | `up` from `init`; an error of its descriptor ends the medium, and the driver tells the interface `down` while it waits out its hold | configured, default 256 | `copy` |
| `erx_netmap` | `ethernet`; the configured address, which must be unicast | configured, default 1,500, from 1,280 to 9,000 and within the port's buffer with the Ethernet header | `up` from a successful registration; `down` from an `init` whose registration failed, and while the driver waits out its hold | configured, default the transmit ring's slot count | `copy` |
| `erx_net_ether` | `ethernet`; the address the lending domain's offer carries, which must be unicast ([design-wifi.md](design-wifi.md#the-ether-interface-and-wlan0)) | the offer's, from 1,280 to 1,500 | `down` until the lender's first link message, then the latest it sent; the lender's end stops the medium | the transmit credit the lender granted | `none` |

`finish` says who finishes what the stack leaves unfinished, a run's cut
and a delayed checksum: `copy` for a transport whose copy does it,
`device` for a device that cuts and sums (an extension), and `none` for
the pipe and the loop, whose frames the frame layer finishes
([Checksums in the copy](#checksums-in-the-copy),
[The fast path](#the-seam)). The
virtio transport hands each frame and run to `erx_device:post_frame/5`,
which walks a frame's binaries itself, at most 64, cuts a run and
finishes a delayed checksum as it copies, so the transport knows nothing
of a frame's layers; receive completions are summed past the Ethernet
header. The loop transport makes each frame `{Zone, Packet}` into `{Zone,
iolist_to_binary(Packet)}`, the one copy a device makes elsewhere.

**The pipe.** `erx_net_pipe` exchanges Ethernet frames, without their
frame check sequence, one per datagram or Erlang message, with one far
end, `far() :: {udp, Local, Peer} | {process, Pid}` (`Local` and `Peer`
each an address and port), and parses nothing. A
frame longer than the MTU and the Ethernet header is dropped as
`too_long`, and a send the far end cannot take as `refused`.

* **`udp`**, as QEMU's `dgram` network backend carries frames. The
  socket runs `{active, 64}`, so at most 64 datagrams wait in the
  driver's mailbox and the host's socket buffer is the only queue ahead
  of it. A datagram from any address but `Peer` is dropped as
  `stranger`. UDP has no carrier, so the state is always `up`. QEMU's
  user networking on macOS reaches it through a QEMU process that runs no
  machine (`-machine none`), with a `user` and a `dgram` backend on one
  hub.
* **`process`**, a test. The far end is a pid, or a registered name
  looked up at `init`, so a restarted driver finds the far end registered
  since; a `Frame` that is not a binary is dropped as `malformed`, a type
  check and not a parse. A test may also send `{sum, S, Frame}`, with `S`
  an integer from 0 to 16#ffff, handed up as it is, to play a transport that sums as it copies, a lying one
  included ([Checksums in the copy](#checksums-in-the-copy)). The far
  end's end, or a name with nothing registered, stops the pipe. This end
  makes a run deterministic: every frame in flight is a message the test
  can see ([The clock](#the-clock)).

#### The tap transport

`erx_tap` exchanges Ethernet frames with a host's tap device (on FreeBSD
`/dev/tapN`; other systems' are added as needed). It is the medium of the
runs on the FreeBSD test host, lives in `portable/`, so it is never in an
erXos image, runs with the node's own user and privileges, and parses
nothing. The netmap transport's two rules carry it, over a file
descriptor and without shared memory. *The kernel's copy is the only
copy:* each frame is read with one `read` into a fresh binary and written
with one `writev` of its headers and payload binaries, a run cut frame by
frame ([The fast path](#each-transports-cut)),
and each call is bounded (64 frames or 64 KiB read, one run or frame
written). *Each direction has exactly one wake:* the descriptor is armed
with `enif_select`, or the transport has sent itself one `more`, never
both and never neither; a transmit that was not taken whole leaves the
descriptor armed for writing and the backlog waiting for `writable`.

The configuration names exactly one of `device` and `fd`, with `lladdr`,
`mtu` (default 1,500) and `tx_limit` (default 256), checked as the pipe's.
With `device` the transport opens the device by name, read and write,
non-blocking and close-on-exec. With `fd` the transport adopts a descriptor the node already holds: the
NIF checks that it is a non-negative C `int`, takes a close-on-exec copy
with `F_DUPFD_CLOEXEC`, refuses a closed one with `{fd, Fd, {adopt,
ebadf}}`, and makes the copy non-blocking; a failure after the copy
closes the copy. The handle owns only its copy: the node keeps `Fd`,
closing it leaves the copy open, and each start of the driver adopts a
fresh copy of the same `Fd`. The two share one open file,
so the node keeps `Fd` non-blocking while a handle lives (a blocking copy
would stall the scheduler its `read` runs on), and a socket's descriptor
is adopted only while the socket stays open, since OTP's `socket:close/1`
makes it blocking first. Adopting lets the node run unprivileged: a
privileged opener passes the tap's descriptor over a UNIX-domain socket
(`SCM_RIGHTS`) or by inheritance, where a path would need a file system
of descriptors (FreeBSD's `fdescfs`) that other systems lack. The NIF's
handle monitors its owner, the driver, and is `badarg` to any other
process, so it needs no lock.

Each `read` asks for the MTU, the Ethernet header and one byte more, so a
frame shorter than the header is dropped as `malformed` and one that
fills the buffer as `too_long`; each frame kept leaves summed, as `{sum,
S, Frame}` ([Checksums in the copy](#checksums-in-the-copy)), and the
call charges `enif_consume_timeslice` for the bytes it read. A delayed
frame has its bytes up to its checksum field copied to the NIF's scratch,
where the field is finished from the bytes read where they lie, and goes
out in one `writev`. A `write` that takes none of a frame, as FreeBSD's
`tunwrite` returns while the interface is down, or `ENOBUFS`, drops that
frame as `refused`, as a wire loses one. A partial `write`, end of file
on a `read`, and every other error but `EINTR` end the medium, through
one `failed` message for a send, which `transmit/2` cannot stop the
driver from ([The driver](#the-driver)). The driver's mailbox holds at
most one `more`, one message per arm and one `failed`, and the tap's own
queue is the only queue ahead of it, so a flooding peer is bounded as the
`udp` end bounds it. The tap's virtio-net header (`TAPSVNETHDR`) is not
used, so each `read` and `write` is one bare frame.

#### The netmap transport

`erx_netmap` exchanges Ethernet frames with a netmap port: a port of a
VALE software switch such as `vale0:erx`, or a card in netmap mode, on
FreeBSD and on Linux with netmap's module. It is the medium of the
standalone runs that compare the stack with other stacks on one switch
(`pkt-gen`, lwIP over netmap, FreeBSD's stack in a jail whose `epair`
joins the switch in netmap's emulated mode). It parses nothing, reaches
the frames where netmap leaves them, in rings the kernel shares with the
process, through a NIF of its own, and lives in `portable/`. DPDK, which
gives no file descriptor to wait on, would need a different scheduling
answer.

**The construction.** Two rules carry the design.

* *The NIF is a device NIF for a host's rings*
  ([design-runtime.md](design-runtime.md#the-device-nif)). It copies each
  frame once on receive, out of its slot's buffer into a fresh binary,
  and once on transmit, into slots' buffers, a run cut frame by frame; no
  binary aliases the shared memory, and each call is bounded. Nothing in
  the shared memory is trusted: each call reads every field the kernel
  writes once, into a snapshot, and a pure C core, `erx_netmap_ring`,
  turns the snapshot and the sizes to send into a plan of which slots
  hold frames, which are dropped and why, and for each copy an offset and
  length checked to lie inside one buffer of the mapping. The NIF copies
  only what the plan names, complete before the first byte moves.
* *Each direction has exactly one wake.* The descriptor is armed for
  reading, or the transport has sent itself one `more`, never both and
  never neither; the ring had room at the last send, or the descriptor is
  armed for writing and the backlog waits for `writable`; a send that
  leaves frames in the ring unsynced has one `flush` on its way.

The first rule is the memory-safety argument and the second the liveness
and bounds argument; together they remove the list of cases a ring
driver otherwise keeps. A call that cannot keep either rule answers
`{error, Reason}`, and every such answer ends the medium, so no failure
leaves the transport waiting for a wake that will not come. The driver's
mailbox holds at most one of each message the transport causes, so a
burst from a peer cannot fill it.

**Configuration.** `port` is 1 to 63 bytes, the kernel's
`NETMAP_REQ_IFNAMSIZ` less its terminator, each an ASCII letter or digit,
`.`, `_`, `-` or `:`, else `{error, {port, Port}}`: the kernel reads other
bytes as its own syntax (`{` and `}` name a netmap pipe), so such a name
would bind some other port rather than fail. `ring` is below 65,536,
`lladdr` unicast (not necessarily locally administered, since a card
keeps its own), `mtu` 1,280 to 9,000 and with the Ethernet header within
the port's buffer, and `tx_limit` positive, each refused at `init`
otherwise. netmap reports no carrier, so a card's cable is not seen.

**One ring pair per transport.** The transport registers one ring pair,
`NR_REG_ONE_NIC`, so each interface has one descriptor and one ring each
way; a card with several queues is set to one queue pair, or becomes one
interface per pair, the stack's extension of one interface process per
receive queue ([Scope](#scope)). One descriptor over several rings would
put the frames of one flow on whichever transmit ring had room, so a card
could reorder them on the wire, and `poll` reports such a descriptor
writable when any ring has room.

**Opening.** The open runs once at `init`, on a dirty I/O scheduler,
since registration allocates the port's memory. It registers with
`NIOCCTRL` at the `NETMAP_API` of the headers the NIF was built against,
with `NR_EXCLUSIVE`, so the kernel refuses a second registration of the
same rings by any process, and `NR_NO_TX_POLL`, so a wait for reading
does not also sync the transmit ring, and without `NR_ACCEPT_VNET_HDR`,
so every slot holds a bare frame. The fields fixed at registration are
read once and kept in the handle, and the core checks with checked
arithmetic that each ring's header and slots lie inside the mapping,
carry their ring number and direction, number at least 2, and hold the
MTU and Ethernet header. The handle monitors its owner and is `badarg` to
any other process, so it needs no lock.

**Receiving.** A receive syncs the ring, reads `tail` once and checks it
is below the slot count, and reads each slot from the handle's own `head`
towards `tail` once, at most 256. A slot whose buffer lies outside the
mapping, or whose length exceeds the buffer size, breaks the ring, since
these are the kernel's own structure, as a virtio completion naming no
posted buffer breaks a queue. A frame shorter than the Ethernet header is
dropped as `malformed`, one longer than the MTU and the header as
`too_long`, and so is every slot of an `NS_MOREFRAG` chain, which the
handle tracks across calls so a chain split between two is dropped whole.
The plan stops at 64 KiB of frames or 256 slots. Each frame is copied and
summed in one pass ([Checksums in the copy](#checksums-in-the-copy)),
then the new `cur` and then the new `head` are stored with release
ordering, which keeps `head` never past `cur` even when ERTS's poll
thread syncs the ring in the middle. A plan stopped at its limit answers
`more`; otherwise the call arms the descriptor and answers `armed`. The
call charges `enif_consume_timeslice` for what it copied, and `init`
sends itself the first `more`, so frames that arrived before the start
take the same path as every later batch.

**No lost wakeup.** Registering the descriptor with ERTS's poll set polls
it once (kqueue on FreeBSD, `epoll_ctl` on Linux), and netmap answers
that poll from the rings after a sync of its own (`netmap_poll`): a poll
for reading syncs the receive ring, and one for writing syncs the
transmit ring, which with `NR_NO_TX_POLL` is the only poll that does. So
a frame that lands, or a transmit slot the kernel finishes, between a
call's sync and its arm is reported by the arm itself. This rests on
netmap's poll handler, not on anything erXos controls. A switch port's
sync gives back every slot it sends (`netmap_vp_txsync`), so the write
arm meets a real kernel only on a card, and is tested over the fake ring
and on a test host that has one.

**Transmitting.** `transmit/2` drops a loopback frame, which names a
zone, as `malformed`, as every transport does, and once the medium has
failed drops every frame as `refused` without a call. The NIF walks a
frame's iodata itself, at most 64 binaries, counting before it copies;
finishes a delayed checksum as it copies; and cuts a run through the
cut's core
([The fast path](#each-transports-cut)),
so no frame is joined in Erlang or copied twice. `enif_inspect_iovec` is
not used, since OTP lets its vector hold more elements than the bound
given, one more length crossing into C. Sizes and slot indices are
checked as on receive. A ring without room is synced once and planned
again; the NIF then answers `{ok, N}` for the frames placed, `full` for
none, with the descriptor armed for writing in both cases where frames
remain, a drop for a plain frame, or `{error, Reason}`, after which what
was not taken is dropped as `refused` and the transport sends itself one
`failed`. Placed frames leave at the next `flush`, one `NIOCTXSYNC`, so
every frame the driver gives the transport before the flush comes back
leaves in one sync, which the transmit credit bounds; on a switch port
the flush is also the send.

**Scheduling.** Every call but the open runs on a normal scheduler and is
bounded: a receive at 64 KiB, 256 slots and one sync, a send at one run
of at most 65,535 bytes or one frame of at most 9,014 and one sync, a
flush at one sync. A sync never blocks, so a dirty scheduler would buy
nothing. Nothing spins on the ring, which would hold a core and which
netmap cannot use, since `tail` moves only at a sync
([todo-performance.md](todo-performance.md) weighs latency at low rates).

**What the shared memory may hold.** The mapping is shared with the
kernel and with any process that registers a port in the same region; a
host's cards share netmap's global region, which any process that can
open `/dev/netmap` can map. Such a process is as trusted as the node (the
test host gives `/dev/netmap` to the node's user alone), and still every
field is treated as a value that may change at any time and may be wrong:
the fields fixed at registration are read once and checked; `head` and
`cur` are the handle's own, written and never read back; `tail` and each
slot's index, length and flags are read once per call; a buffer is
computed with checked arithmetic from the ring's offset, its signed
64-bit buffer offset and the index, and must end within the mapping; a
length is checked against the buffer size, then the MTU. A frame's bytes
may change while they are copied: the copy is then wrong but within its
bounds, never changes afterwards, and is untrusted like any frame. The C
reads no byte of a frame, error numbers become atoms only from a fixed
table, and no atom is made from the mapping. A peer controls a frame's
bytes, its length, which is checked, and the rate, which costs the driver
one bounded, preemptible call per batch.

**Ending the medium.** Every `{error, Reason}` means the medium has
ended, and `event/2` answers `{stop, {netmap, Reason}}`: a failed sync
(card detached, port gone, descriptor in error), a broken ring and a
failed arm alike, with no list of failures kept. The driver ends as
[The driver](#the-driver) sets out, and the new driver registers the port
again; a switch port starts clean, and a new registration resets a card's
ring. A failed registration is the medium ending too, not a refusal,
because a transport whose `init` fails is not held and is retried at
once: `init` answers with the link `down` and sends itself `failed`, so a
missing card, `/dev/netmap` without permission or a port held by another
process (`ebusy`) restarts the link at most once a second and fails
neither the link's start nor the stack's. The handle closes in one place,
the stop callback of `enif_select`, requested by the owner's monitor or
the resource's destructor; neither leaves a caller behind, so the NIF has
no close call and no closed state. Configuration and build errors refuse
`init`, since restarting cannot fix them: the keys above, `{netmap,
unavailable}` when the NIF library is absent, `{netmap, {api, Kernel,
Built}}` when the kernel's API version differs from the NIF's headers,
and `{mtu, N}` when the port's buffers cannot hold the MTU and header.

**Building.** The NIF builds where `<net/netmap.h>` is found, as a
library of its own, so the per-byte primitives do not depend on netmap;
where it is missing every call answers `{error, unavailable}`, and only
an interface that names this transport is refused. It uses the raw
`NIOCCTRL` request, the kernel's interface on FreeBSD and Linux, not
`libnetmap`. `erx_netmap_ring.c` includes no netmap header, so its tests
and fuzz target run on every host; only `erx_netmap_nif.c` reads or
writes the mapping, with every offset taken from a plan of the core's
([Build checks](#build-checks)).

**Why a NIF, and why a copy.** A port program would keep C out of the
node, but it relays every frame through a pipe with system calls on both
sides, the costs netmap exists to remove, which the comparison would then
measure instead of the stack; and ERTS delivers a port's data as fast as
the program reads it, with no credit ahead of the driver's mailbox. The
NIF keeps to the rule that C does only per-byte work and the per-frame
work riding on it, while every decision about a frame stays in Erlang. A
bug in it takes down the node, which outside erXos is the whole stack, so
its C is small and its decisions are in a pure core under unit tests, a
fuzz target and the sanitizers. Receive copies rather than lending slots
to binaries: the stack keeps sub-binaries of received frames in
reassembly queues and receive buffers while a peer keeps data out of
order, and a netmap ring returns its slots in order, so one held 60-byte
segment would stop the interface's receive for all clients. Swapping a
held slot's buffer for a spare needs a pool, a destructor that returns
spares from any thread, and a copy anyway once the pool is empty: three
new rules where the copy has none. A 1,514-byte copy is expected to be a
small part of the 12.3 us a full-size frame may take at 1 Gb/s
([Where C is used](#where-c-is-used-and-what-is-measured)), an estimate
that the measurement of the transport alone, below, replaces. Transmit
copies too: `NS_INDIRECT` exists
only on switch ports and needs the frame kept alive until the sync, which
`erx_net_driver`'s contract does not give a transport.

**Verification.** The core has C unit tests under `make check` and the
fuzz target `tools/fuzz/netmap_ring_fuzz.c`, which drives it over a fake
mapping built from its input and checks that every planned copy lies
inside one buffer and the mapping, that `head` moves only towards
`tail`, that a receive stays within its bounds, and that no slot of a
chain is planned as a frame. A fake ring held in Erlang (the `nif` key,
in tests only) carries a property test of the one-wake rules (at most
one receive wake in flight, a frame in the ring always has one on its
way, every transmit before a flush leaves in that one sync, and
`writable` comes only from the write arm's message), and driver tests
check that each fake-ring error ends the driver with `{shutdown,
{netmap, Reason}}` no sooner than a second after its start. A run on
the FreeBSD test host, skipped elsewhere with its reason and never
counted as passed, sends single frames at random gaps, about 100,000
empty-ring arms, each through within 100 ms, which checks the
lost-wakeup argument against FreeBSD's `netmap_poll` and ERTS's kqueue. The seeded faults, each of which must
fail its check: in the core, the receive length check removed, the `tail`
check written `<=`, the transmit size check removed; in the fuzz target,
the receive buffer bound removed, the transmit size bound removed, a
chain flag each call starts clear; over the fake ring, a `more` sent
after `armed`, no arm after emptying the ring, `writable` reported at a
flush, a run partly taken answered as whole, `{error, arm}` read as
`armed`, and a failed registration refused at `init`; on the switch, each
slot's length set one short, and a NIF that never arms.

**Measurements.** Two measurements judge the transport itself: the
switch's ceiling (`pkt-gen` to `pkt-gen` on `vale0`), and the transport
alone against `pkt-gen`, with a profile of the share of copies, cut,
binaries and syncs. The comparisons, against FreeBSD's stack in a jail
over the switch with lwIP over netmap (on a small `netif` kept outside
erXos's tree at a pinned commit) and jail-to-jail as baselines, decide
only where the stack's own time goes. Over a tap the limit was the
stack's per-segment work, not the medium
([The fast path](#what-was-measured)),
so this transport alone is not expected to raise TCP throughput much.

**Residuals of the transport.**

* A process that can open `/dev/netmap` can read and write the buffers of
  every port in a shared region, a card's included: netmap's own model.
  The checks keep it from corrupting the node's memory, not from altering
  frames.
* A netmap that reported a descriptor readable while its ring held
  neither frames nor an error would make the driver arm, wake and find
  nothing, again and again, each round preemptible and bounded; not seen,
  and the switch run watches wakes per frame.
* Frames past the receive credit are copied before the driver drops them
  as `no_room`; leaving them in the ring would need the receive credit's
  state across the transport's callbacks, a change that waits for the
  flood numbers ([todo-performance.md](todo-performance.md)).

**Open decision.** *A second jail on the switch,* for the
FreeBSD-to-FreeBSD baseline. It changes the test host's setup, which puts
one jail's `epair` on `vale0`. Recommended: allow it; it is the one
baseline that shows what the switch and the emulated mode cost a kernel
stack, apart from any user-mode stack.

### The interface core

`erx_net_if_core` is the interface process's step. It holds the
sub-cores of the interface's state ([One owner, one step](#one-owner-one-step)):
`erx_arp` and `erx_nd6` over `erx_lltable`, `erx_nd6_dad`, `erx_nd6_rtr`,
the reassembly tables, the syncache, the ICMP and RST limiters of
`erx_net_bandlim`, the ingress bucket, its configuration copy and view,
its generator and its counters, and dispatches each event to the
sub-core it belongs to. Its step takes an event and the time in
microseconds and answers the next core and its actions; `hand` reaches
another stack process only through the pid and credit of its published
row.

A `local` step whose frame is a TCP segment for a listener also carries
the stack's secrets, which the loop reads from `erx_net_tables` for that
frame alone ([Connection setup](#connection-setup)). The step of a
`local` event does what [Receiving](#receiving) gives the interface: the
core decides whether the frame spends a token of the bucket (**Room**, in
[Classifying a frame](#classifying-a-frame)), `erx_net_input:verify/1` checks it,
a failed check gives the token back, and the verified item goes to its
sub-core, all inside the one step, so the bucket has no state outside
the core and nothing to give back after a raise. `publish` carries the
complete set of the interface's rows in `erx_net_ifs`, `erx_net_addrs`
and `erx_net_routes` whenever one of them changes.

**The loop.** `erx_net_if` takes one message at a time:

1. It first reads the configuration generation, and when it differs from
   the core's, steps the snapshot from `erx_net_tables:configuration/0`.
2. A batch `{frames, Driver, Frames}` takes its units from the receive
   credit, and so does every further batch from the driver already in
   the mailbox, up to a link notice, which is stepped after them
   ([Processes and batching](#processes-and-batching));
   a `{loop, Frames}` takes its units from the sender credit. Each frame
   is classified against the view with the `demux` lookup added. An
   `owned` frame reserves a unit of each destination's credit and is
   verified, its item kept for each destination that took it, or its
   units released if it fails. A `local` frame is stepped at once, and
   every reassembled datagram it returns is classified before the next
   frame. A `drop` is counted. At the end of the batches each destination
   gets one message of its items, its units already reserved.
3. Any other handed message takes its units from the sender credit and is
   stepped. Hints, link notices, the `erx_dhcp4` messages and the key
   facet's answer carry no credit: a hint is at most one in flight per
   published row, a link notice took a unit at the driver, and the others
   come from the interface's own link supervisor or its own requests, one
   per step.
4. A clock hint steps expiry.

After each step the loop performs the actions in order: it writes
published rows, new and changed first and deleted last, and then
increments the generation; it asks the key facet of
[IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration)
for an interface identifier, answering `unavailable` itself when the
network domain holds none, as on a host; then it arms the clock at the
core's next deadline. A step that raises is handled as
[What fails and what survives](#what-fails-and-what-survives) says.

**A connection from the syncache.** For `accept`, the loop reserves one
unit of the listener's accept credit. Refused, the core answers with a
RST under its limit ([Connection setup](#connection-setup)). Granted, the
loop makes the connection's receive credit, spawns the connection with
`proc_lib:spawn/3`, so the interface never waits on it, and inserts the
four-tuple through `erx_net_bind` with the new pid and credit before it
takes the next frame. The accept unit is the connection's from then on:
the interface never releases a unit it has handed to a connection, and
sends the listener nothing. The connection's first message is the
interface's verdict on the insertion, `abandon` when the key was already
held or `go`; the interface, not the receiver, makes the receiver's
counter, so the entry exists before the connection runs.

### The listener

A listening socket is an `erx_tcp_listen` process, which its grant
starts and links to, around a pure step, `erx_tcp_listen_core`. It holds
its socket process, its accept credit, the connections queued for
`accept`, the `accept` calls waiting, and the calls whose connection it
has chosen and not yet heard back from. Two rules keep every accepted
connection within a bound.

**A connection joins its listener's queue only once its grant has
adopted it.** From its spawn to its end an accepted connection holds at
least one of two bounded places: a unit of its listener's accept credit,
until it leaves the queue; and one of its grant's sockets with its two
buffers, from its adoption until it ends. Adoption comes before queueing,
so the two overlap, and nothing that happens once it is queued can leave
it holding neither. FreeBSD keeps the same order: a connection reaches
the listen queue as a socket whose buffers `solisten_clone` has already
reserved (`uipc_socket.c:1207`).

**A unit has one holder at a time:** the interface until it spawns the
connection, the connection until its `{queued, Conn}` notice carries the
unit to the listener, and the listener until the connection leaves the
queue, when it takes the unit back. A holder that gives up releases the
unit itself (the connection at `abandon`, at the interface's end before
its verdict and at a refused adoption). So the units in use are the
connections on the queue and on their way to it, and the backlog never
holds more than its limit. A holder killed inside its window strands its
unit, leaving the backlog a place short until the listener ends
(**Stranded credit**, in [Residuals](#residuals)); it holds nothing for a
client, since the dead connection's grant deletes its key. FreeBSD's
`sol_qlen` is the same count (`solisten_enqueue`, `solisten_dequeue`,
`uipc_socket.c:1271`, `:1614`).

**Its limit** is `3 * Backlog div 2 + 1`: FreeBSD refuses a new
connection once `sol_qlen > 3 * sol_qlimit / 2` (`solisten_clone`,
`uipc_socket.c:1032`). `Backlog` is `gen_tcp:listen`'s `{backlog, N}`, 5
by default as on stock (`inet_int.hrl:279`); one below zero or above 128
is taken as 128, as `solisten_proto` clamps it to `somaxconn`
(`uipc_socket.c:1542-1544`; `SOMAXCONN`, `socket.h:434`).

**Its entry** in the demultiplexing table holds, besides its pid and
accept credit, its grant, the grantee's origin, the listener's part of a
SYN-ACK (its receive buffer, offered as the window, and its window
shift) and what an accepted connection inherits. The MSS a SYN-ACK
offers is the connection's: the interface computes it for each SYN-ACK
from its route to the peer with `erx_tcp_mss`'s translation of
`tcp_mssopt`, as `syncache_respond` does (`tcp_syncache.c:1823-1827`), so
a wildcard listener reached over routes of different MTUs offers each
peer its own route's. A connection inherits what `solisten_clone` copies
from the listener (`uipc_socket.c:1183-1186`, `:1207`) and
`syncache_socket` from its TCP flags (`tcp_syncache.c:908-909`): the
congestion and loss modules, `nodelay`, `linger`, the keepalive times,
and the buffer sizes `listen`'s `sndbuf` and `recbuf` set, or FreeBSD's
`tcp_sendspace` and `tcp_recvspace`. The listener holds no buffer itself,
as `solisten_proto` keeps only a listening socket's buffer sizes
(`uipc_socket.c:1509-1526`), so the grant reserves nothing for it. A
`setopts` that changes one of these rewrites the entry with
`erx_net_bind:update/2` before it answers; `update/2` replaces an entry
only while its caller holds the key, keeping pid, credit and grant, and
returns `gone` otherwise, which for a running listener means its grant
has ended, and it then ends with `{shutdown, grant_ended}`. The
interface reads the entry at a SYN and at the completing ACK, so a
connection completing after a `setopts` has the new values, as FreeBSD
copies the listener's current flags when it makes each connection.

**An accepted connection's start.** The connection, spawned by the
interface with the accept unit:

1. traps exits, links to its grant, as every socket does first, and
   monitors the interface;
2. waits for the verdict alone: at `abandon` it releases the unit and
   ends; at the interface's `'DOWN'` it releases the unit and exits with
   `{shutdown, interface_ended}`, its grant deleting any entry inserted
   for it; at `go` it drops the monitor;
3. makes its control block with `erx_tcp_user:accepted/3`, the MSS from
   the peer's offer and the listener's buffer sizes rounded up to whole
   segments, as `syncache_socket` sizes them with `tcp_mss` and runs no
   output (`tcp_syncache.c:938`, `tcp_input.c:3922-3969`), and asks its
   grant to adopt it, `erx_net_grant:adopt/2`, a local call with those
   sizes. The grant counts the caller as one of its sockets, reserves its
   two buffers, as `soreserve` does (`uipc_socket.c:1207`), and answers
   the token every later buffer call names, or, past its `sockets` or
   `buffers` limit, records nothing and answers `{error, emfile}` or
   `{error, enobufs}`. The rounded sizes are the one reservation: a grant
   with room for the listener's sizes but not the rounded ones refuses,
   where FreeBSD ignores the failed `sbreserve` in `tcp_mss`. The socket
   adopted is the caller, so nothing is reserved on the word of a pid in
   a message. Refused, with its grant gone, or with no route to the peer,
   the connection releases the unit and hands its interface
   `{accept_refused, FourTuple, Segment}`, so the interface sends the RST
   FreeBSD sends when `solisten_clone` fails (`uipc_socket.c:1207-1212`,
   `tcp_sc_rst_sock_fail`), deletes its key and ends;
4. links to its listener and sends it `{queued, self()}` under the unit;
   a listener already gone answers the link with `noproc`, met as its
   exit;
5. steps the completing segment and enters its loop **queued**, owned by
   its listener. The completing segment is the control block's first
   event, as `tcp_input` hands it to `tcp_do_segment` straight after
   `syncache_expand` (`tcp_input.c:1081-1160`): every step ends in
   output, and output in SYN-RECEIVED carries SYN and ACK
   (`tcp_output.c:432-443`, `:700-702`), so an earlier step would send
   the peer a second SYN-ACK.

While queued the connection runs as FreeBSD runs a socket on its listen
queue: it acknowledges, takes bytes until the window closes and keeps
its timers, and pushes nothing. Its listener's exit is its `soabort`
(`uipc_socket.c:2012`): it sends a RST, as `tcp_usr_abort`'s `tcp_drop`
does (`tcp_usrreq.c:1265`, `tcp_subr.c:2400-2404`), and ends.

**The messages.** Three messages pass between the listener and its
connections; the listener and its socket process speak the socket
protocol.

| Message | From | To | Meaning |
| --- | --- | --- | --- |
| `{queued, Conn}` | an adopted connection, under its unit | its listener | `Conn` has linked to the listener and holds a unit; the listener queues it |
| `{bind, Listener, SockProc}` | the listener, naming itself | a connection it has taken off its queue | an `accept` takes the connection for `SockProc` |
| `{bound, Conn}` | the connection | its listener | `Conn` has linked to `SockProc` and taken it as its owner |

An `accept` call links the listener to `SockProc` and waits, with its
deadline on the stack's clock; one past the 64 in flight, or naming the
listener's own socket process or grant as `SockProc` (whose unlink would
cut a link the listener ends by), is answered `{error, badarg}` at once
([Requests in flight](#requests-in-flight)). The oldest waiting call and
the oldest queued connection are paired: the listener takes the
connection off the queue, takes its unit back, sends it `bind` and stays
linked to it until the call is answered. `{bound, Conn}` answers the call
`{ok, Conn}` and unlinks both. The exit of a connection being handed
answers its call `{error, econnaborted}`, as FreeBSD's `accept` answers
`ECONNABORTED` for a connection that ended before it was handed out
(`tcp_usrreq.c:734-741`), and is not paired again; the exit of a waiting
call's `SockProc` answers it `{error, econnaborted}` and frees its place;
a deadline answers a waiting call `{error, timeout}`, while a call being
handed has no deadline, since its connection is adopted and answers or
ends. A queued connection's exit removes it and takes its unit back; the
exit of the listener's own socket process or grant ends it. Signals
between two processes arrive in the order sent, and the listener keeps
that order, paused or not (**Pausing**, in
[Sockets act for one domain](#sockets-act-for-one-domain)), so a
connection's notice always precedes its exit. So every call is answered
exactly once while the listener runs, and when it ends its socket process
answers every call it still holds `{error, closed}`; the acceptors' socket
processes, still in `opening`, stop at the listener's exit through their
links.

The listener never waits on a connection, its grant or its socket
process. A queued connection takes `bind` only from its own listener (any
other, or a second, is a programming error that ends it), links to
`SockProc`, takes it as owner, sends `bound`, from then on ignores its
listener's exit, and waits for its socket process's first message
(**Nothing crosses before the first contact**, in
[The socket process](#the-socket-process)), pushing the bytes it took
while queued within that first credit. A `SockProc` already gone answers
the link with `noproc`, which the connection checks before answering: it
then sends no `bound`, sends a RST and ends at once, and the call is
answered `{error, econnaborted}`. It does not close gracefully, since a
close would hold the connection and the listener's call for its FIN's
retransmissions or TIME-WAIT, and a pool of acceptors killed together
would fill the listener's calls in flight for that long. ERTS queues the
`noproc` before `link/1` returns once the process has left its table
(`bif.c`, `link_opt`); a `SockProc` still in its exit phases answers
later, so the call may be answered `{ok, Conn}` for an ending socket
process, whose exit then closes the connection. The listener answers
`accept` only after `bound`, so the connection knows its socket process
before that process can send it anything.

**Its start and its end.** `gen_tcp:listen/2` opens as every socket opens
(**Opening**, in [The socket process](#the-socket-process)). The grant
checks it against its `listen`, `addresses` and `sockets` limits
(`{error, eacces}`, `{error, emfile}`; [The grant](#the-grant)), refuses
an option it does not take with `{error, einval}`, and starts the
listener, which links to the socket process, makes its accept credit and
claims its key by an explicit bind carrying the grant's `ports` narrowed
by `listen`
([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table));
the bind's refusal is the start's answer. The listener takes `backlog`,
`reuseaddr`, `reuseport` and the options a connection inherits; the
socket process keeps the presentation options and starts every
acceptor's socket process with them, as stock's `accept` does
(`gen_tcp_socket.erl:530-543`). The listener ends when its socket
process ends, at its `close`, when its grant ends or when its step
raises; it deletes its key when it ends normally, and its grant
otherwise. It answers `close` only once its key is deleted, so the port
is free when `close` returns, as FreeBSD's `tcp_close` takes the socket
out of the hash before it returns (`in_pcbdrop`, `tcp_subr.c:2555`;
`in_pcbremhash`, `in_pcb.c:1879-1880`). Its exit aborts every queued
connection with a RST, as FreeBSD's `soclose` aborts a closing listener's
queues (`uipc_socket.c:1988-2015`), including one spawned from an entry
read just before, whose grant releases what it reserved.

**Who waits on whom.** The interface waits on no one, and neither does a
running listener. A connection waits on its grant for its adoption, as
for every buffer reservation. The grant waits only for a socket it starts
to finish starting, and a starting listener only on `erx_net_tables` for
its bind, which waits on no one. So no wait closes a cycle.

**Departures from FreeBSD.**

* FreeBSD leaves a connection dropped while queued on the queue until an
  `accept` takes it and fails with `ECONNABORTED` (`tcp_subr.c:2555-2561`,
  `tcp_usrreq.c:734-737`). The listener drops it at its exit, so `accept`
  never answers for a connection its caller cannot have, and a burst of
  resets does not fill the backlog. A program can see this: where
  FreeBSD's `accept` fails, and Linux's returns an already closed socket,
  erXos's goes on waiting for the next connection or its timeout. A
  server that loops on `accept` sees no difference; a program that
  expects one `accept` result per completed handshake sees fewer. Linux's
  side is read from `inet_accept` (`net/ipv4/af_inet.c` at v6.12) by this
  design's review and is unverified here; the differential test of
  [The listener: exploration, the backlog and binds](#the-listener-exploration-the-backlog-and-binds)
  records what stock OTP answers on each host.
* A queued connection is one of its grant's sockets from its adoption,
  and one past the limit is reset at its handshake; FreeBSD counts a
  descriptor only at `accept`, which answers `EMFILE` and leaves the
  connection queued (`kern_accept4`, `uipc_syscalls.c:358-370`). See
  [Decisions](#decisions), 20.
* Two sockets never share one key: `reuseport` on two listeners or two
  bound datagram sockets of one grant, on the same address and port, is
  refused with `{error, eaddrinuse}`, where FreeBSD allows it
  (`in_pcb.c:985-995`). The demultiplexing table maps a key to one
  socket, and nothing the stack serves needs a second holder; `reuseport`
  otherwise acts as `reuseaddr` does (**Explicit binds**, in
  [Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)).

### Credits

`erx_net_credit` is the one module that hands packets between stack
processes, over one `atomics` counter per receiver
([Credited queues](#credited-queues)). A credit is an opaque value of the
counter and its limit, fixed when it is made, so a sender never reads the
limit from anywhere else. `reserve/2` adds units with
`atomics:add_get/3` and, past the limit, subtracts them again and answers
`full`; `hand/4` is `reserve/2` followed by `send/2`; `release/2` returns
units reserved and not sent; `take/2` is the receiver's, for each message
or frame it takes; `free/1` is the room left, which a connection's loop
reads into its step's context. A counter never goes below zero, since
every unit is added before its message is sent.

| Credit | Made by | Unit |
| --- | --- | --- |
| a driver's transmit credit | the driver, at `init` | a frame |
| an interface's receive credit | the interface | a frame of a batch, or a link notice |
| an interface's sender credit | the interface | a handed message |
| a connection's or datagram socket's credit | the socket, or the interface for a connection it starts | a segment, datagram or ICMP report; a merged segment takes one for each segment it holds |
| a listener's accept credit | the listener | a connection on its queue or on its way to it, its limit `3 * Backlog div 2 + 1` ([The listener](#the-listener)) |

The limits are keys of the `erx_net` application's environment, whose
defaults the flood measurements of plan.md's network gates settle, as
they settle the ingress bucket's.

### The clock

`erx_net_clock` is the stack's one source of what differs from one run to
the next: the time, the timers and the random keys. Every process of
`erx_net` reads the time (`now/0`, microseconds), arms its one timer
(`arm/1`, after which the caller gets a hint at or after the deadline)
and draws entropy (`entropy/1`, which raises when the source fails)
through it, and through nothing else.

The clock is chosen once, from the `clock` key, before any process
starts. `monotonic`, the default and the only value the network domain's
configuration sets, is ERTS's monotonic clock, `erlang:send_after/4` at
the deadline rounded up to the millisecond, and `erx_bytes:entropy/1`.
`{virtual, Clock}` is a test's clock process, served by `erx_net_vclock`,
test code packed into no image and no release; where it is absent the
application refuses to start with `{error, {seam, clock,
erx_net_vclock}}`, so a production build cannot run on a virtual clock or
a seeded generator. The virtual clock shares the time through an
`atomics` counter, keeps one deadline per caller (the earliest given)
until it sends that caller's hint, draws entropy from an `erx_net_rand`
generator keyed by the run's seed, and moves only when the test advances
it, setting the new time first and then hinting every caller whose
deadline it reached, in order of deadline and then of arming.

A virtual clock is this simple because a hint is only a hint
([Deadlines, not timers](#deadlines-not-timers)): the clock never cancels
anything, and a hint for a deadline that has since moved finds nothing
due. Every timeout of the stack is a deadline in some owner's state, a
request's `Timeout` included, so nothing waits on a timer the virtual
clock does not see; a local call between stack processes waits with a
monitor and the timeout `infinity`. A build check keeps it so
([Build checks](#build-checks)). Under the virtual clock `erx_net_script`
drives the whole stack through the pipe's `process` end and advances the
clock only when every process of the stack, every socket and the pipe
wait with an empty queue, so a 2MSL wait or a keepalive's two hours take
no time. Each such run has a node of its own with one scheduler
(`+S 1`), and every supervisor starts its children one at a time, so the
processes run, and draw their keys, in the same order every time: a run's
frames on the wire are a function of its script and its seed. Runs
against real peers keep the monotonic clock.

### The grant's contract

What the stack's modules rely on from a grant is fixed here, so neither
the runtime seam nor the facet machinery changes them:

* A grant is an `erx_net_grant` process, minted by
  `erx_net:mint_grant(Grantee, Connection, Limits, Exports)`, the one
  function the network service's introduction of a client calls
  ([The grant](#the-grant)), which starts it through the runtime's
  `start_grant/2`, exported to its grantee and ending with its
  connection. It holds the limits of [The grant](#the-grant) and the
  account of [Sockets act for one domain](#sockets-act-for-one-domain),
  which a pure core, `erx_net_grant_core`, decides over.
* Every message from outside the stack to a grant or a socket passes one
  admission path, `erx_net_admit:request`, before any step sees it. For
  a grant it answers `{ok, Request, From}`, `{refused, shape, From}` or
  `unknown`; for a socket, given also the socket's kind (`tcp`,
  `tcp_listen`, `udp` or `icmp`) and its socket process, `{ok, Body}`,
  `{refused, shape}` or `unknown`.

  A socket takes only its own kind's requests: a datagram socket
  `{send_to, Ip, Port, Data}`, `{send, Data}`, `{connect, Ip, Port}`,
  `sockname` and `close`; an echo socket `{echo_send, Ip, Seq, Ttl,
  Data}` and `close`; a connection those of
  [The socket process](#the-socket-process); a listener `{accept,
  SockProc, Timeout}`, its `SockProc` a pid of the grantee's domain, the
  `setopts` of its options, `sockname` and `close`; and every kind
  `{credit, Bytes}`. A request of another kind is refused for its shape.

  A message wrapped as `{erx_origin, D, Inner}` comes from domain `D`; a
  message without an envelope comes from the receiver's own domain,
  `local` ([design-domains.md](design-domains.md#facets)). The origin
  must be the grantee, and a grant's message must be a call,
  `{'$gen_call', From, Request}`, whose reply goes to the grantee's
  domain: `From` is `{Pid, [alias | Alias]}`, and both `Pid` and `Alias`
  carry the grantee's domain id
  ([design-domains.md](design-domains.md#domain-ids-pids-and-references)),
  since `gen:reply/2` sends to the alias rather than to the pid, as a
  facet requires of its caller
  ([design-domains.md](design-domains.md#facets)); a message without an
  envelope needs only a pid of the grant's node; a socket's must name
  that socket's own socket process as its sender
  ([Sockets act for one domain](#sockets-act-for-one-domain)). A message
  that fails either is `unknown`: dropped and counted, and answered to no
  one, since its reply would go to a party outside the grantee's domain
  or to no socket process of the socket. `Request` must then be a request
  of `abi/services/net.txt`, within the bounds the schema declares for
  each argument ([Message sizes](#message-sizes)); one that is not is
  refused for its shape, answered `{error, badarg}` and counted, as a
  facet refuses. The admitted request comes back with its caller, and the
  caller is the owner of what the request opens: no request names an
  owner of its own, so no request can make a socket serve a process of
  another domain. The stack's own calls of a grant (an accepted
  connection's adoption, a connection's reservation and release of its
  buffers, and the grant's counts) are admitted only without an envelope
  and from a process of the grant's node. The mint has the same path,
  `erx_net_admit:mint/2`, which takes only `{erx_facet_mint, Tag, net,
  Grantee, Principal, Limits}` in the system domain's envelope
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
  and refuses and counts one whose `Grantee` is the system domain's id
  (**The system domain never holds the grant**, in [The grant](#the-grant)).
  `erx_net_admit` is generated from the schema into the app's build
  output, the one generated module `erx_net` needs; an app taken out of
  the tree carries that output with it ([Decisions](#decisions), 10). The grant, under `erx_facet`, reaches
  the same check through the facet's behaviour, and under
  `erx_net_local`'s loop through a call before each callback. Two bounds
  apply, and neither drops a request a correct client sends. The
  runtime's request limit on the receiving process, which `serve/1` sets
  to the grant's `max_request`, the schema's largest request, drops a
  larger message before it is queued. The requests in flight are the
  admission's: the grant's are bounded by its facet's limit in flight,
  past which requests wait in the facet's queue and then in the
  grantee's lane ([design-domains.md](design-domains.md#facets)), and a
  socket's by the socket protocol's 64, which its socket process never
  exceeds ([Requests in flight](#requests-in-flight)).
* A client finds its grant through `erx_net_client`'s `grant` key and
  nothing else: `erx:cap(net)` on erXos, with the origin its messages
  carry ([Two places, four seams](#two-places-four-seams)).
* A socket speaks to its socket process, and to nothing else, in the
  socket protocol of [The socket process](#the-socket-process).

With the local runtime, `erx_net` mints its node's grant with the grantee
`local` at start, and a test harness mints any others the same way. No
message there carries an envelope, so every request from a process of the
node passes the origin check, and the grant's limits, account and
refusals are exactly those of the network domain. Outside erXos there is
therefore no grant that admits by caller: the variant would only
reproduce what `local` already gives.

### Running on a development host

The host harness starts `erx_net` on stock OTP 29.1.2 with its
`interfaces` key naming each interface's transport and configuration
(`{erx_net_pipe, #{far := far(), lladdr := Addr}}`, static addresses or
DHCP), as the network domain's configuration names `erx_virtio_net`,
its `clock` key, and `runtime` set to `erx_net_local`; `erx_net_client`'s
`grant` key is `{erx_net, local_grant, []}`.

Stock's `inet` accepts only `inet` and `socket` as backends
(`inet.erl:3297-3300`), so `{inet_backend, erx}` fails there with
`function_clause`. Host tests therefore open sockets by calling the
backend directly, `erx_gen_tcp:connect/4`, `erx_gen_tcp:listen/2` and
`erx_gen_udp:open/2` with `gen_tcp`'s and `gen_udp`'s arguments. Each
returns `{'$inet', erx_gen_tcp, Pid}` or `{'$inet', erx_gen_udp, Pid}`,
on which every later `gen_tcp`, `gen_udp` and `inet` call dispatches to
the backend as on erXos. On erXos the OTP edit that adds `erx` to
`inet_backend` and makes it the default ([The backend](#the-backend))
is all that changes: the calls into `erx_gen_tcp` are the same.

## The fast path

The stack decides every TCP segment in Erlang, in one pure step over the
connection's control block. This section is its performance design: how
one connection carries bulk data at close to the rate of lwIP, a C stack,
over the same medium, and how a small segment, the unit of request-reply
traffic, costs within two to three times what lwIP spends on it. It
builds on [Checksums in the copy](#checksums-in-the-copy),
[The netmap transport](#the-netmap-transport) and
[The socket process](#the-socket-process).

A *run*, one TCP header, a contiguous range of payload and the segment
size it is cut at, is the unit of TCP work: output emits runs, input
takes them, a segment is a run of one, and everything above the medium's
copy pays once per run. The copy the medium forces anyway cuts a run into
frames byte for byte equal to per-segment output's; the interface merges
received segments by the rule of FreeBSD's large receive offload (LRO,
`tcp_lro.c`) before it classifies; and the step that is left for one
segment is made lean. Every TCP decision stays in pure Erlang functions:
C copies, sums, writes the header values Erlang chose and groups frames by
a fixed rule. Payload is copied only where something outside the stack
forces it.

### What was measured

On the FreeBSD x86-64 test host, on 2026-11-09: FreeBSD 16.0-CURRENT
(GENERIC-NODEBUG), AMD Ryzen Threadripper PRO 5995WX with 128 hardware
threads, native. Stock OTP 29.1.1 (erts 17.1, FreeBSD's port, with the
JIT) at default flags, so 128 schedulers. `erx_net` at f3c91786 with the
per-byte primitives' C loaded as a NIF. Frames went over `/dev/tap1`
through the pipe transport's tap helper, then `bridge0` and an `epair`
into a jail running FreeBSD's own stack. Each transfer moved 512 MiB in
64 KiB sends, received with passive `recv(S, 0)`; figures are the median
of three. The raw data, scripts and profiles are at
`~/erxos-history/net-perf-freebsd-2026-11-09/` (commit `d5bcd46`), and
lwIP's at `~/erxos-history/net-bench-freebsd-lwip-2026-11-09/` (commit
`d5bcd46`): lwIP 2.2.1 with contrib 2.1.0's `tapif`, one thread, the raw
API, `-O2`, a 64 KiB window, over the same tap.

| | `erx_net` | lwIP |
| --- | --- | --- |
| send | 890 Mbit/s | 6,537 Mbit/s |
| receive | 1,143 Mbit/s | 6,809 Mbit/s |
| cost of a 1,448-byte segment | 12.3 us sending and 10.1 us receiving, of the connection process's wall time | 1.5 to 1.6 us of CPU for the whole path, system calls included |
| CPU for 512 MiB | the BEAM's 23.4 s sending (17.9 user, 5.5 system) in 6.2 s, 3.8 cores, with the tap helper's beside it | 0.55 to 0.6 s |
| copies of a payload byte | 4 sending (1 in ERTS, 3 in the kernel); 5 receiving (2 and 3) | 2 each way (1 in user space, 1 in the kernel) |

What the profiles and experiments established:

* **The connection process is the serial stage, and its cost is per
  segment.** A busy wait of 3 us per segment in the connection raised its
  time per segment to 15.4 us and cut sending to 711 Mbit/s, and one of
  6 us to 18.1 us and 604 Mbit/s, where one serial stage predicts 715 and
  598; the same 3 us per frame in the driver cost 3 percent. Caching the
  encoded options gave 14 percent sending and 6 receiving; a 256 KiB send
  buffer changed nothing.
* **The cost has no hot spot.** Per segment the connection makes about
  330 calls and allocates about 1,400 heap words, no function above 4
  percent: acknowledgement input rebuilds the 78-field control block
  about ten times per ACK, output copies it three times per segment,
  every header and its options are encoded afresh, every segment adds a
  `gb_trees` node to the send log, and 0.4 to 0.5 minor collections
  follow.
* **Nothing is batched,** even while the connection's mailbox holds 13
  items on average.
* **Three processes spread over 128 schedulers:** 113 more than 1 percent
  busy, about 15 voluntary context switches per segment, 11 to 24 percent
  of samples in the scheduler loop and its spinning, 8 to 10 percent in
  kernel lock spinning under `munmap`; about four cores for one core of
  Erlang work. It costs efficiency more than throughput: four schedulers
  gave 5 to 7 percent more, one 10 to 15 percent less.
* **Copies do not limit one flow yet:** the kernel's copy functions are
  about 3 percent of samples and run beside the connection. The driver is
  close behind, so they bind once the connection is about 1.5 times
  faster.

### The two targets

1. **Bulk.** One connection's send and its receive, each at least two
   thirds of lwIP's over the same medium: 4.4 Gbit/s each way over the
   FreeBSD test host's tap. At lwIP's rate a segment has about 1.8 us of
   wall time, which every serial stage must meet once its cost is divided
   by the segments it handles at once.
2. **Small segments.** Request-reply over one connection, requests and
   replies of 64 bytes to 1 KiB, at a transaction rate of at least a third
   of lwIP's and CPU per transaction at most three times lwIP's.

### Why the cost is architectural

Removing every measured share from the per-segment step (option
encoding, the send log's tree, the stages' copies of the control block,
the loop, the checksum calls and their collections) brings the step down
perhaps twofold, not the sixfold the gap needs. C stacks pay those costs
once per batch or never: FreeBSD's TCP hands a capable interface one
large segment that the hardware cuts (TCP segmentation offload, TSO,
`tcp_output.c:514-565`) and takes merged segments from LRO; lwIP updates
its control block in place. So the unit of work changes: a step takes and
emits many segments at once, and the work left for a single segment is
cut on its own ([The lean step](#the-lean-step)).

### The construction: runs

#### A run

A run stands for consecutive segments of one connection that differ only
in the sequence number, advancing by the segment size; the IP length and
the two checksums, which follow from each frame's length and bytes; and
PSH and FIN, which only the last frame may carry. Every other header byte
is shared: link header, addresses, type of service or traffic class, flow
label, hop limit, don't-fragment, ports, acknowledgement, window and
options. A run's options are the timestamps option in FreeBSD's layout,
`NOP NOP TS` (`tcp_addoptions`, `tcp_output.c:1794`), or none, with the
same values in every frame because an output pass reads the clock once.
Every frame but the last carries exactly the segment size of payload; the
last carries the rest, or nothing for a pure ACK or a bare FIN.

A run (`#run{}` in `erx_net_frame`) carries the link header, the
connection's template by reference, its header values as integers, the
segment size and the payload as at most 64 binaries of the send buffer.
With its headers it is at most `IP_MAXPACKET`, 65,535 bytes, FreeBSD's
bound on a TSO segment (`tcp_output.c:916-937`, `t_tsomax`); the
64-binary bound is the one the C checks, and the send buffer gives a
range in at most that many binaries, so output ends a run where the range
ends. An IPv4 run always carries don't-fragment, which output sets while
the MSS is above `tcp_minmss` (after `tcp_output.c:1494-1498`), so its
identification is zero by RFC 6864 (`ip_fillid`) and the cut never writes
one. On the way in, a run is a merged segment. In both directions a
segment is a run of one, so the TCP core, the frame layer and the drivers
handle one shape.

#### The cut, in the copy

The cut is a C core, `erx_tcp_cut.c`, linked by the device, netmap and
tap NIFs beside the checksum core. Its plan is complete and checked
before any byte moves ([style.md](style.md#functional-core)). Frame i
carries payload bytes `i * seg` to `min(P, (i + 1) * seg)` and sequence
number `seq + i * seg` modulo 2^32; the cut stores the template with the
frame's values, copies the slice through the checksum core and finishes
the IPv4 header checksum and the TCP checksum, from the pseudo-header's
sum with the frame's own length plus the sum of header and slice as they
are copied. Every frame but the last carries the flags without PSH and
FIN. Where the medium's copy is the kernel's, the core writes only the
headers and sums the slice where it lies, and the kernel gets the headers
and the slice. A frame is written only into room the plan checked.

The template is the stack's own output, and the core checks it anyway,
since C must never act on a malformed one: IPv4 with a 20-byte header,
protocol 6, don't-fragment, offset 0 and identification 0, or IPv6 with
next header 6; a TCP data offset of 5, or of 8 with `01 01 08 0A` at its
first option byte; nothing after the TCP header. The plan refuses,
writing nothing, a link header over 32 bytes, a template that fails those
checks or whose timestamps differ from the run's, a field wider than the
wire's, a zero segment size, more than 64 pieces, or a run over
`IP_MAXPACKET`. Its answer is a `bool`, not a status code: its one
refusal means the stack handed over a run it does not make, which every
NIF answers with `badarg`, and status codes are the generated ABI's
alone.

#### The merge, before classification

The interface merges each batch from its driver before it classifies
anything, with one per-byte primitive, `erx_bytes:tcp_merge/1`: on erXos
linked into ERTS as the other per-byte primitives are, outside erXos a NIF
of the portable build. Its core, `erx_tcp_merge.c`, is a pure state
machine over the frames' bytes. Its rule is FreeBSD's
(`tcp_lro_rx_common`, `tcp_lro.c:1280-1426`; `tcp_lro_condense`,
`:963-1106`), given in full under [The merge](#the-merge). Each output
unit is a frame on its own with its network sum, or
`{merged, N, First, Last, Payload}` with N from 2 to 256, its first and
last frames as they arrived with their sums, and each member's payload as
a sub-binary, in order.

**The merge's limit.** One call takes at most 256 frames, the frames
before its last hold less than 64 KiB and no frame holds more than
64 KiB, so a call reads at most 128 KiB and runs on a normal scheduler.
`erx_bytes:tcp_merge_limit/0` answers the C core's own two constants,
`{256, 65536}`, so no other copy of them exists. The bound holds by
construction at the one place every transport's frames pass:
`erx_net_driver` cuts each event of its transport into batches within
the limit before it hands any to the interface ([The driver](#the-driver)).
Whatever a medium gives at once, no batch of a correct stack exceeds the
limit, and a flood of minimum-size frames costs more batches, never a
refusal by the merge.

The merge writes no header. FreeBSD rewrites the merged packet's first
header with the last segment's acknowledgement, window and timestamps
(`tcp_lro_update_checksum`, `tcp_lro.c:678`, the stores at `:731-740`);
here the interface reads those from the last frame with its own decoder.
So C decides only which frames belong together, and every value TCP acts
on is decoded by Erlang.

### Sending

#### Output makes runs

`erx_tcp_output` chooses what to send by `tcp_default_output`'s rules up
to `send:`. Chosen data can be a run of several frames when: (1) the
connection is synchronized and the segment carries neither SYN nor RST
(`tcp_output.c:558-565`); (2) its bytes are new data at `snd_nxt`, which
is `snd_max`, since a retransmission goes one segment at a time as
FreeBSD's default `tcp_sack_tso` of 0 does (`tcp_sack.c:157`,
`tcp_output.c:561`); (3) no SACK or D-SACK block is to be reported, since
"with TSO the TCP header is the same (except for the sequence number) for
all generated packets" (`tcp_output.c:517-522`), and the stack's
per-segment output would report D-SACK on one segment only; (4) no urgent data lies
ahead and the segment is not a probe or persist transmission; (5) ECN
output changes no state and adds neither CWR nor ECE, so every frame
carries the same codepoint and flags; (6) an IPv4 segment
carries don't-fragment; (7) the windows allow at least two full segments
of `seg`, `t_maxseg` less the options.

The run takes the largest whole number of full segments that the window,
the transmit credit offered, the 65,535-byte bound and the 64-binary bound
allow; one segment goes as a run of one, as FreeBSD gives up TSO when its
fragment bound leaves one (`tcp_output.c:955-962`). The rest is the next
pass's, decided with Nagle and sender silly-window avoidance from the
state after the run, as the per-segment loop decides it. FreeBSD trims a
burst to whole segments unless it empties the send buffer
(`tcp_output.c:940-948`); here the partial last segment is always its own
pass, which gives the per-segment wire.

* **PSH** goes on the frame with the send buffer's last byte (FreeBSD,
  `tcp_output.c:1117-1123`), in a run only ever the last.
* **FIN** goes on the last frame of a run that ends the data, where
  per-segment output puts it. FreeBSD sends a FIN after a TSO burst in a
  segment of its own (`tcp_output.c:965-969`), since it does not trust a
  device to clear FIN on all but the last frame; the stack's own cut does.
* **The credit.** A run of n frames takes n transmit units and is never
  longer than the credit offered; a credit that runs out mid-pass is
  `ENOBUFS` ([Credited queues](#credited-queues)).
* **The MTU** check under don't-fragment is made once, for a full frame.
* **Bursts.** A run leaves as up to 45 frames at a 1,500-byte MTU, as a
  TSO segment does; the stack paces nothing, as FreeBSD's default stack
  paces nothing.

After a run the post-send bookkeeping (`snd_nxt` and `snd_max`, the RTT
probe at its first byte, the send log, the retransmission timer, the owed
and delayed ACKs) runs once, as for one segment of its length, which is
what k per-segment passes leave, since each value is set once or moved to
the end; a property test checks it.

A segment whose header is a run's (conditions 1 and 3 to 6) is a run of
one, retransmissions included, so no steady segment is encoded in
Erlang. A SYN, a RST, a segment with SACK blocks or urgent data, a probe,
an IPv4 segment without don't-fragment and one whose payload lies in more
than 64 binaries are encoded by `erx_tcp_wire` with the delayed checksum.

#### The header template

The connection keeps the template its runs share: the IP and TCP
headers, encoded once from the path and the negotiated options, and built
again only when the path, the ports, the ECN field or the timestamps'
presence change; the path changes only when the configuration generation
moves, so the connection compares it as the same term. The link header
comes from the next hop's neighbour row, which keeps it encoded, at each
output pass. For a transport that cuts nothing, `erx_net_frame:cut/1`
turns a run into the frames per-segment encoding gives; it is the Erlang
reference of the cut, and the differential tests compare the C with it.

#### The send log keeps runs

The send log records a run as one range with its segment size; a range's
segment boundaries are its start plus multiples of `seg`, and its last
segment may be shorter. Three rules keep the log's properties
([The send log, SACK and reassembly](#the-send-log-sack-and-reassembly)):

* **SACK marks whole segments.** A block marks the whole segments of each
  range it reaches, splitting at segment boundaries, and leaves a segment
  it covers in part unmarked. So boundaries are only those the sender
  made, and a peer cannot split the log below them. An acknowledgement
  inside a segment cuts its range there and at that segment's end, so
  every range starts on a boundary.
* **A range keeps its segment size.** When `t_maxseg` changes, after a
  path MTU drop for example, a retransmission is cut at the new size, and
  a block marks only the range's segments it covers whole: output may
  resend bytes the peer holds until a wider block or the cumulative ACK
  covers them, but no byte the peer lacks is ever marked, and the log is
  never split below the boundaries the range was sent with.
* **New data extends the last range** when that range is unmarked, sent
  once, of the same segment size, sent at the same time and ending on a
  full segment. So the log after k per-segment passes of one step equals
  the log after one run.

A run costs one `gb_trees` insert, as one segment does.

#### Each transport's cut

| Transport | Where a run is cut | Copies of a payload byte | Calls |
| --- | --- | --- | --- |
| `erx_virtio_net` (erXos) | the device NIF posts each frame as one request in one pool buffer (the 12-byte `virtio_net_hdr`, then the frame), cut and summed as it copies, until the queue is full | one, into the pool buffer | one NIF call and one doorbell per run |
| `erx_genet` (erXos) | the frame layer, `erx_net_frame:cut/1`; the device NIF copies each frame's pieces, at most four, into one pool buffer | one, into the pool buffer | one NIF call per frame |
| `erx_netmap` (a host) | its NIF plans the slots from one snapshot of the ring, syncs at most once when it is full, and cuts each frame into its slot | one, into the slot | one NIF call per run; one sync per flush |
| `erx_tap` (a host) | its NIF writes each frame's headers to scratch, sums the slice where it lies, and hands the kernel both in one `writev` | one, the kernel's; the payload is read once more to sum it | one NIF call per 64 frames, one system call per frame |
| `erx_net_pipe`, `erx_net_loop` | the frame layer, `erx_net_frame:cut/1` | none of the stack's | Erlang work per frame |

A transport with room for fewer frames than a run holds takes the first
and answers `{ok, N}`; the driver keeps the run's tail (sequence number
advanced, payload starting `N * seg` bytes later) in its backlog with its
transmit credit reserved, so a run never waits whole for room that is
partly there, and a tap, which can fill mid-run after frames that cannot
be taken back, is served as it is. The same calls take a frame that is
not a run as iodata of at most 64 binaries that the C walks itself, so no
transport joins a frame's binaries in Erlang
([design-runtime.md](design-runtime.md#the-device-nif)).

#### Device segmentation

virtio-net's `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6` let the device cut
one request of up to 64 KiB whose `virtio_net_hdr` names `gso_type`,
`hdr_len`, `gso_size`, `csum_start` and `csum_offset` (virtio 1.2,
section 5.1.6.2), as FreeBSD hands a capable interface a `CSUM_TSO`
segment with its `tso_segsz` (`tcp_output.c:1398-1406`); a run maps onto
that header field for field. The device finishes only when it offers
`VIRTIO_NET_F_CSUM`, `HOST_TSO4` and `HOST_TSO6` together, since one
`finish` key names who finishes both a delayed checksum and a run's cut
([The seam](#the-seam)); one that offers checksum offload alone is
finished by the copy. It saves the guest per-frame header work and
descriptors, not the copy, since no binary ever aliases memory a device
can reach (R9 of [design-runtime.md](design-runtime.md#invariants)). It
is an extension ([Scope](#scope)), tested against the copy on a medium
that offers the three bits; its device path needs a transmit queue whose
buffers hold 64 KiB or chain across buffers.

QEMU 11.1.3 on the development host (Homebrew) lists the virtio-net
properties `csum`, `gso`, `host_tso4`, `host_tso6`, `guest_csum`,
`guest_tso4`, `guest_tso6` and `mrg_rxbuf`, each on by default. Whether
the device offers those bits when its peer is a hub port, as the
harness's is (`tools/lib/erx/qemu.rb`), was not checked; QEMU is believed
to clear them when the peer carries no virtio-net header, which a hub
port does not (unverified). The transport logs at each start which
finisher it took, `finish copy` or `finish device`, so every measurement
records its path.

The receive offloads (`GUEST_CSUM`, `GUEST_TSO4`, `GUEST_TSO6`,
`MRG_RXBUF`) are never negotiated: each is a device claim the stack would
have to believe, and the merge does their work on bytes the stack holds.

### Receiving merged segments

#### The merge

A frame is a merge candidate when:

* it is Ethernet II without a VLAN tag, IPv4 or IPv6;
* an IPv4 frame has a 20-byte header (`tcp_lro.c:276`), is not a fragment
  (`:279`), carries protocol 6, and its total length fits the frame, any
  rest being a 60-byte frame's padding; an IPv6 frame has next header 6,
  so no extension header, and a payload length that matches the frame;
* its IPv4 header and TCP checksums are correct, from the frame's network
  sum ([Checksums in the copy](#checksums-in-the-copy)) or one the merge
  computes. FreeBSD merges only frames whose checksums the hardware
  validated (`tcp_lro.c:1303-1313`); the copy's sum stands for the
  hardware here;
* the TCP header has ACK and no flag but PSH (`tcp_lro.c:1006-1014`,
  `:1050-1053`), and a data offset of 5, or of 8 with exactly the
  timestamps option in FreeBSD's layout (`:996-1005`).

A candidate joins the open unit of its flow when:

* **the flow is the same:** link addresses, IP version, addresses, ports,
  header length, type-of-service or traffic-class byte, and the IPv6 flow
  label. FreeBSD compares neither the type-of-service byte nor the link
  addresses (`lro_address_compare`); the stack compares both, so a CE mark
  is never merged away and frames from different neighbours are never one
  unit;
* **it is in order:** its sequence number is the unit's next (`:1065`);
* **the acknowledgement moves forward:** at or past the unit's; past it
  when the frame has no payload; past the first frame's when the first
  has none. FreeBSD ends a unit at a duplicate ACK (`:1068-1070`) and
  merges a pure window update whose window grew (`:1081-1085`); the stack
  merges no pure ACK that does not advance, into a unit or as a first
  frame, since a duplicate's count and a window update each carry a fact
  a unit would hide. FreeBSD merges a data segment whose ACK goes back
  (`:1075-1080`); the stack ends the unit, since a unit's last
  acknowledgement stands for all its members';
* **timestamps move forward:** TSval at or past the unit's
  (`:1054-1063`);
* **the size fits:** the payload stays below `TCP_LRO_LENGTH_MAX`, 65,280
  bytes (`tcp_lro.h:200`, `tcp_lro.c:1032`), so the unit fits one IP
  packet.

FreeBSD's refusal of an unspecified address (`tcp_lro.c:283-286`,
`:333-335`) has no rule here: TCP's own address checks judge such a
unit's first frame as they judge each member.

Up to eight units are open, one per connection, FreeBSD's
`TCP_LRO_ENTRIES` (`tcp_lro.h:41`); a ninth connection's candidate closes
the oldest. A TCP segment of the connection that is not a candidate, or a
candidate that cannot join the connection's unit, first closes that unit, as `tcp_push_and_replace` flushes an entry (`tcp_lro.c:903`),
so a connection's frames keep their order; FreeBSD's flush of every entry
on an unmergeable frame (`:1441`) is not needed when every unit closes at
the end of the batch; such a candidate then opens a new unit. The
connection is read from any TCP segment directly behind IPv4 or IPv6
whose ports are in the frame, a first fragment and a segment behind IPv4
options included. A frame from which no connection can be read (not
TCP, a later fragment, a segment behind IPv6 extension headers) closes no
unit and passes on where it stood; a later frame of its connection may
then pass it, which reassembly takes as reordering. Since every unit
closes at the end of the call, the merge keeps no state and nothing times
out, where FreeBSD keeps entries across calls and flushes them on a timer
(`tcp_lro_flush_inactive`).

Each unit stands in the output where its first frame stood; a unit of one
frame is the very term it came as. The pure ACKs a unit holds are counted
in N alone. Every Ethernet frame leaves the merge with its network sum,
so `verify/1` sums only what never passes it, loopback packets and
reassembled datagrams.

The interface classifies a unit by its first frame. It is owned when its
last frame classifies as a segment of a connection with the same holders;
the interface reserves N segments in each holder's credit, makes the
checks of [What the stack believes](#what-the-stack-believes), and hands
the connection one segment: the first frame's header and flags, as in
FreeBSD's LRO packet, with the last frame's acknowledgement, window and
timestamps, the payload pieces, and N. A unit no connection owns, or one
the table drops, is taken as its last frame alone, which carries the
acknowledgement FreeBSD's merged segment does (`tcp_lro.c:731-740`), so a
closed port answers with the one RST `tcp_dropwithreset` makes for the
LRO packet. Only the Ethernet interface merges. The interface counts
`units` and `unit_segments`, which the benchmarks report as segments per
merged unit.

#### A merged segment in TCP

TCP's segment record carries its payload as a flat list of binaries with
its length and segment count. Trimming, reassembly and delivery work on
pieces, so no stage joins them; a delivery becomes one binary once, in
the socket process. The connection takes a merged segment as FreeBSD's
`tcp_do_segment` takes an LRO packet:

* **The count.** `cc_ack_received` hands congestion control `nsegs` with
  the bytes acknowledged (`tcp_input.c:290-300`, `:1534`), and slow start
  grows the window by the smaller of those bytes and `nsegs` times
  `tcp_abc_l_var` segments (RFC 3465; `cc/cc_cubic.c:218-222`,
  `cc/cc.c:590-594`, `cc/cc_newreno.c:326-330`). The stack passes N.
  FreeBSD's LRO counts only merged data segments
  (`tcp_lro.c:937-960`) and drops merged pure ACKs uncounted
  (`:1088-1091`); the stack counts each merged ACK, so a sender's window
  grows as the separate ACKs would have let it. N counts the data members
  too, as `lro_nsegs` does, so a unit ending in a stretch ACK raises slow
  start's cap for that ACK to N times the limit; the growth is still no
  more than the bytes acknowledged, as FreeBSD's with LRO.
* **The acknowledgement.** `DELAY_ACK` delays only a segment of at most
  `t_maxseg` (`tcp_input.c:511`), so a merged data segment is
  acknowledged at once, as FreeBSD acknowledges an LRO packet and Linux a
  GRO one, which is fewer ACKs than RFC 5681's "at least every second
  full-sized segment" (section 4.2). No ACK names a point inside it: an
  inner boundary would be a guess, and repeating the final value a
  duplicate the sender counts toward loss.
* **Timestamps** are the last segment's, as FreeBSD stores them, for
  `ts_recent` and the round-trip sample.
* **The window** is updated from the first frame's sequence number with
  the last frame's acknowledgement and window, so `snd_wnd` and `snd_wl2`
  end as per-segment frames leave them and `snd_wl1` holds the first
  frame's sequence number. A unit that starts at `snd_wl1` with its
  acknowledgement at `snd_wl2` takes the last window only if it grew, so
  a window shrunk inside it waits for the next segment, as under FreeBSD's
  LRO.

A merged segment gives one round-trip sample, the latest, and loses the
inner acknowledgement values and per-segment `ts_recent` updates; its
TSvals do not decrease, so PAWS judges it by its newest, and an old
duplicate merged in front of fresh segments passes. Each is what FreeBSD
with LRO does.

#### Credit counts segments

A merged segment takes one unit of its connection's credit for each
segment it holds, so the credit still bounds the bytes queued for a
connection by its limit times one frame, merged or not. It is owned
traffic, so it takes no token of the interface's ingress bucket
([Credited queues](#credited-queues)). The interface checks N against
what it can see before it charges it.

### The lean step

Runs divide the step's cost on bulk traffic; a run of one, a request or
a reply, still pays the step alone, so the step itself has to cost a
quarter or less of what it does.

#### Where a segment's cost goes

The connection's samples while sending, by module (tprof, 64 MiB; shares,
since tprof inflates small functions), against the change that removes
each; minor collections, about a tenth of the connection's time, fall
with the allocation:

| Share | Where | Change |
| --- | --- | --- |
| 14.6% | `erx_tcp_output` | a run per pass; output's fast case |
| 12.4% | `erx_tcp_input`, ACKs | header prediction finishes the pure ACK |
| 10.3% | `erx_tcp_wire`, headers and options | the template; runs |
| 9.5% | `lists` (stage lists, folds, `min`) | finished fast paths; actions built once |
| 8.3% + 6.2% | `gb_trees` and `erx_tcp_sendlog` | the send log keeps runs |
| 6.0% | `erx_tcp` | the hot control block |
| 3.9% + 3.1% + 3.4% | `erx_net_frame`, `erx_bytes`, BIFs | the template; the copy sums |
| 3.0% + 2.1% | `erx_tcp_conn`, `erx_net_credit` | one step per mailbox |

#### The control block, hot and cold

Updating a record copies all of it, so a 78-field control block costs 79
words at every stage that changes a field. It splits by one rule: a field
goes into the cold `#tcb_conf{}`, one field of `#tcb{}`, when no step
that sends or takes data on an established connection writes it
(addresses and ports, initial sequence numbers, negotiated options,
`t_maxseg`, the congestion-control and loss-detection modules, buffer
limits, keepalive's parameters, `nodelay`, `linger`, the ending's
errors). The hot `#tcb{}` keeps about 38 fields: sequence variables,
windows, `ts_recent`, estimators, congestion state, send log, buffers,
timers, waiting callers and per-step requests. A stage that changes
nothing returns the record it was given.

#### Header prediction finishes its cases

FreeBSD's header prediction (`tcp_input.c:1731-1950`) applies the effects
of its two common cases itself: a pure ACK of new data, and in-order data
that acknowledges nothing new. The stack takes the same two cases with
FreeBSD's preconditions and finishes each in one function that builds the
next control block once: for the pure ACK `snd_una`, the send buffer's
drop, the send log, the round-trip sample, `cc_ack_received` with the
segment's count, the retransmission timer, `snd_wl2` and the waiting
writer; for in-order data `rcv_nxt`, the delivery, the ACK, `ts_recent`
and the receive window. Each does what the general stages do from `ack`
on, not what FreeBSD's shorter fast path does, which leaves `snd_wl1`,
`rcv_up` and `t_dupacks` differently ([Events and the
step](#events-and-the-step)). So each effect has two implementations and
one meaning: the property test of header prediction runs every segment it
accepts, and its near misses, through the general stages and requires the
same state and actions. The general stages stay for every other segment
and as the oracle. A merged segment takes the fast path under the same
preconditions; a unit that carries data and acknowledges new data at once
is neither case and takes the general stages. Output has the same shape:
in the established steady state (no recovery, an open window, no SACK
information, nothing irregular) one pass decides, makes a run and commits
it with one update of the control block.

#### One step per mailbox

Before it steps an `{items, Interface, Items}` message, the connection
takes every further `{items, _, _}` message already in its mailbox, steps
all their segments as one event in arrival order, and only then takes
their units from its credit. Until then the interface can hand nothing
past the credit's room, so the credit bounds what is stepped together;
taking the units per message would let the interface refill the credit
during the drain, and a drain that keeps pace with its sender would never
end. An idle connection steps each message as it arrives, so the batch
adds no latency. One step ends with one output pass, so ACKs that
per-message steps would send apart leave as one, the acknowledgement
count of FreeBSD with LRO. A step that raises over a batch ends the
connection from its state before the batch
([What fails and what survives](#what-fails-and-what-survives)); the
batch's messages end with it, so draining needs no rule of its own.

The receive queue holds pieces. It copies out a piece smaller than a
quarter of the binary it references (`erx_tcp_conn:compact/1`) and joins
a piece of fewer than 512 bytes to a small newest one, as `sbcompress`
joins small mbufs, so a peer's tiny segments cost their bytes and not a
binary each; no step joins payload otherwise.

#### What the lean step is expected to give

Estimates from the measured shares, to be replaced by measurements: for a
run of one, the connection's work falls from about 330 calls and 1,400
heap words to about 80 calls and 300 words, and its time from 12.3 us to
3 to 4 us. The lean step alone is not enough for the bulk target, and
runs are not enough for the small-segment target; the two together are
the design. On bulk traffic, with runs of about 45 frames and merged units
of 10 to 40 segments, the connection's share per segment falls below
0.5 us, and the limit moves to the copy and the medium's system calls.

### Processes and batching

The processes keep the roles of [The process tree](#the-process-tree),
the merge being the interface's, and no state moves between them.
Framing, cutting, merging and summing are calls in the process that
holds the bytes, and a host's tap device is driven by a NIF the driver
calls, not a relay process.

**Batching.** Every hop carries all its sender holds: the driver one
`{frames, ...}` message per batch within the merge's limit, the
interface one `{items, ...}` message per destination per batch, the
connection one `{transmit, ...}` message per step, holding runs; every
receiver steps everything waiting for it, bounded by its credit. One NIF
call per run or plain frame on every transport with a copy of its own,
one doorbell per call on virtio, one sync per flush on netmap, one
`writev` per frame on tap, which takes one frame per write.

**The scheduler spread.** With runs of about 45 frames and units of about
20 segments, a bulk segment costs under a tenth of a hop where it cost
about two. On erXos the network domain's runtime runs as many schedulers
as its CPU grant allows, at most 32, and by default parks without spinning
([design-runtime.md](design-runtime.md#configuration)). On a host the
stack depends on no scheduler setting; the benchmarks record it and
report CPU per byte at the default and at `+S 4:4`. ERTS's undocumented
run-queue binding (the `scheduler` option of `spawn_opt` and
`process_flag/2`, parsed in `erl_process.c` and `bif.c`) could keep a
driver and its interface on one scheduler, a suspected saving on the
watch list ([todo-performance.md](todo-performance.md)).

**The hop that stays.** A received segment still passes the driver and
the interface: one hop per batch for bulk, one message, about a
microsecond, for request-reply. Classifying in the driver over the
interface's published view, or running the transport inside the
interface, would remove it at the price of the medium's isolation from
the interface's state; the request-reply profile decides, and the
question is on the watch list.

**The socket process's pieces.** A `gen_tcp:send/2` reaches the
connection in pieces of at most 64 KiB ([Message sizes](#message-sizes)),
each one binary in the send buffer, so a run covers at most the end of
one piece and the start of the next. A connection pushes received bytes
within the socket process's credit, at most a piece per push as at most
64 binaries; a merged payload, at most 65,280 bytes, fits a piece. The
socket process hands over a delivery within one piece as a sub-binary
and joins one that spans pieces once, in the owner's domain.

### Copies

Copies of a payload byte, by path and medium:

| Path | Medium | Copies | Total |
| --- | --- | --- | --- |
| send | virtio, erXos | the lane's two, from the owner's domain into the network domain; the cut, into the pool buffer | 3 |
| receive | virtio, erXos | `complete/3`, into a binary; the lane's two, into the owner's domain; the socket process's join when a delivery spans more than one piece | 3 to 4 |
| send | tap, a host | the kernel's write; the payload is read once more to sum it | 1 |
| receive | tap, a host | the kernel's read, summed as it is kept; the join, as on erXos | 1 to 2 |
| send | netmap, a host | the cut, into the slot | 1 |
| receive | netmap, a host | the NIF's copy, into a binary; the join, as on erXos | 1 to 2 |

A payload byte the stack holds is in a binary the owner, the lane or the
medium's copy made, or a sub-binary of one; every other copy is at a
listed site. The source check `net-payload-copy` in `make check`
(`tools/lib/erx/net_checks.rb`, which lists the sites) fails the build on
any copying call in the modules a TCP payload passes through outside
them. The sites keep a few bytes from holding a frame alive (the receive
and reassembly queues' copy of a small piece), make the joins an
interface forces (the socket process's join of held pieces that a
delivery or packet spans; the owner's iodata made into the binary a send
carries), or are a copy a medium makes elsewhere (the pipe's `process`
end, finishing a delayed checksum for a transport that does not, a device
transport joining a frame of more binaries than one request posts, the
loop transport's copy). IP fragmentation and reassembly are outside the
modules it reads. A seeded violation shows the check catches a new site.

### The seam

A driver tells the interface once, at attach, who finishes the frames
the stack leaves unfinished, a delayed checksum and a run's cut: the
`finish` key of [Checksums in the copy](#checksums-in-the-copy), which
covers both, since one copy does both. `copy` means the transport's copy
finishes them, `device` the device (an extension), and `none` nobody
below the stack, so the frame layer cuts runs and finishes checksums
itself. The interface keeps `finish` in its row with the MTU, from the
attach's one answer. Output does not read it: every path gets runs, and
only the frame layer asks who cuts them. A transport's transmit callback
takes a frame or a run and answers `ok`, `{ok, Taken}` for a run partly
taken, `full` or `{drop, Reason}`. `finish` is not configured: each
transport answers it from what its medium offers: `copy` for virtio
(`device` only with the three bits of [Device
segmentation](#device-segmentation)), netmap and tap; `none` for the pipe
(`copy` in its `process` end's offload mode, a test configuration that
cuts through the C core) and the loopback. Receiving has no capability
to state: every transport hands up frames, as `{sum, S, Frame}` when its
copy sums them and as bare frames from the pipe, which the merge sums,
and the interface merges every batch; the loopback, which carries IP
packets with their zone and not Ethernet frames, is never merged.

The [tap transport](#the-tap-transport) is the netmap transport's
construction over a file descriptor, without shared memory, in place of a
port program between the node and the tap. The tap's virtio-net header
(`TAPSVNETHDR`, `sys/net/if_tap.h:58`) is not used; what its offloads
would do across `bridge0` and an `epair` was not checked.

### What the stack believes

* **The cut** reads only the stack's own values, checks all of them,
  refuses a bad run with `badarg`, which only a bug of the stack makes,
  and never reads memory a device can write. A wrong cut makes the peer
  drop frames or receive wrong bytes, and cannot write outside the buffer
  the plan checked.
* **The merge** reads untrusted bytes, frames a device or a host's kernel
  wrote, but only in binaries the copy made, which nothing changes. It
  checks every length against its binary with checked arithmetic, creates
  nothing but tuples, lists and sub-binaries of its input, and decides
  only which frames belong together. The stack believes three claims of
  it: that a unit's middle frames belong to the first frame's flow, in
  order; that each has correct checksums; and that the pieces are their
  payloads. Erlang does not check these per frame, which is the point;
  the merge's model and its fuzz oracle do. A bug in it can deliver wrong
  bytes within the flows it sees, but cannot read outside a binary.
* **What Erlang re-checks.** A unit's first and last frames pass
  `classify/2` and `verify/1` like any frame, and every value TCP acts on
  is decoded from them. The interface checks that
  `length(Payload) =< N =< 256`, that the last frame names the first's
  flow (addresses, zone, link cast, ECN field and ports), that both are
  merge candidates, that the last frame's sequence number is where the
  pieces before it end, and that the pieces plus the first frame's
  headers fit one IP packet, and drops a unit that fails as `malformed`.
  It charges N credit units, so an understated count is still bounded by
  the pieces Erlang sees and an overstated one costs only credit.
  Congestion control reads N only in slow start, where growth never
  exceeds the bytes acknowledged (`cc/cc_cubic.c:218-222`; congestion
  avoidance does not read `nsegs`), so an inflated N cannot inflate the
  window.
* **Device claims.** None is believed: virtio's receive header is never
  read, the receive offloads are never negotiated, and tap and netmap
  give none.
* **A residual of Phase 1.** On Fiasco the virtio driver and the stack
  run in the system domain (plan.md's 1b-G), so a memory error in the
  merge's C is a fault of the system domain and resets the machine.
  Development builds run trusted code only; the residual is in `TODO.md`
  until the network domain holds its device.

### Fast-path concurrency and failure

No process, lock or shared state is added. The cut finishes inside the
driver's NIF call at one run (at most 65,535 bytes, 64 pieces and 45
frames at a 1,500-byte MTU), the merge inside the interface's call at one
batch; both charge reductions for the bytes they read.

* **Receive credit.** The interface takes the units of the batches it
  drained once its pass ends ([Credited queues](#credited-queues)). A
  merge that raised, which only a bug can make, strands no credit: the
  interface drops the batch, counts and logs it, and keeps its state
  ([What fails and what survives](#what-fails-and-what-survives)).
* **A run partly taken** waits in the backlog as its tail, with its
  credit, until the transport's next `writable` event.
* **A medium that ends** drops the backlog, runs included, each frame
  counted; the send log recovers them as losses.
* **A step that raises** over a drained batch ends the connection from its
  state before the batch ([One step per mailbox](#one-step-per-mailbox)).
* **Order.** A flow's segments keep their order through the merge, and a
  unit stands where its first frame arrived; different flows may change
  places, as FreeBSD's LRO flushes them. A connection's runs leave in the
  order output made them, through one driver.

### Fast-path refusals

* The cut's plan refuses what [The cut, in the copy](#the-cut-in-the-copy)
  lists, and the NIFs answer `badarg`; only a bug of the stack reaches it.
* A transport's send answers `{ok, N}` for the first N frames of a run
  taken. The tap NIF drops a run whose first frame, its longest, is over
  the MTU as `too_long` and writes at most 64 of a run's frames a call;
  the device NIF answers `{error, full}` with nothing posted when no entry
  is free and `{error, broken}` as its plain post does; the netmap and tap
  NIFs answer `full` with the descriptor armed, `{drop, malformed}` or
  `{drop, too_long}` for a plain frame, and `{error, Reason}`, which ends
  the medium.
* A transport whose `finish` is `none` drops a run as `malformed` and
  counts it; only a framing bug makes one.
* `erx_bytes:tcp_merge/1` answers `badarg` for a list past its limit or an
  element of another shape; only a bug of the driver's cut reaches the
  first. It refuses no frame: one it cannot merge, or whose checksum
  fails, passes on alone, the second for `verify/1` to drop and count as
  `bad_sum`, so that count has one place.
* The interface drops a merged unit whose count or size fails its checks
  as `malformed`.

### Fast-path verification

Each fast path is checked against a slower reference it must equal: the
C cut against `erx_net_frame:cut/1`, output with runs against output held
to runs of one, merged input against per-segment input, the finished
header-prediction cases against the general stages, and the C merge
against `erx_tcp_merge_model`, an Erlang model written from
`tcp_lro_condense`'s rule as this section states it. The verdicts of
FreeBSD's own stack are the outer oracle. Each test is paired with a
seeded fault it must catch.

#### Tests

* **The cut equals the reference**, through the tap NIF over random runs
  (both IP versions, with and without timestamps, up to 64 pieces with an
  empty one, partial tails, sequence numbers across the wrap). *Seeded
  faults:* a last frame one byte short; timestamps only in the first
  frame; the sequence number not advanced per frame; the TCP checksum
  without the options; the IPv4 header checksum computed before the
  length is stored.
* **Output with runs equals output per segment**, in the core's property
  test and the explorer
  ([The TCP core: exhaustive exploration](#the-tcp-core-exhaustive-exploration)),
  frames, control block and send log alike. *Seeded faults:* a run while
  a D-SACK block is owed; a run not trimmed to whole segments; the RTT
  probe at a run's last frame.
* **The send log's rules**, with `t_maxseg` lowered during recovery.
  *Seeded faults:* a block that splits a segment; extension across
  segment sizes; a block marking a segment it covers in part.
* **The merge equals its model**, unit by unit, through the portable NIF
  and erXos's BIF. *Seeded faults:* a merge across differing type of
  service; a first frame with a bad TCP checksum accepted; a pure ACK
  that does not advance merged.
* **Merged input equals per-segment input**, but for the window case of
  [A merged segment in TCP](#a-merged-segment-in-tcp), and the congestion
  window after a merged slow start is within one segment. *Seeded
  faults:* N not passed to `cc_ack_received`; the window from the first
  frame.
* **Header prediction equals the general stages.** *Seeded fault:* the
  fast pure ACK not restarting the retransmission timer.
* **One step per mailbox:** five queued messages step once and send one
  ACK. *Seeded fault:* the drain stopped after the first message.
* **Credit counts segments:** merged bursts never queue more than the
  credit's worth of frames. *Seeded faults:* one unit per merged segment;
  a unit classified by its last frame.
* **The device NIF**, on the hosted backend's model device. *Seeded
  fault:* a full queue's tail posted from frame 0.
* **The tap NIF**, over a UNIX datagram socket pair, which keeps one frame
  per `read` and `write` as a tap does, and a FIFO for `EAGAIN`. *Seeded
  fault:* `EAGAIN` mid-run answered as all taken.
* **Packet scripts against FreeBSD**
  ([Packet scripts against FreeBSD](#packet-scripts-against-freebsd)) run
  again through the pipe's offload mode, which cuts runs through the C and
  hands the driver a script's frames at once so the merge sees bursts;
  every verdict must equal the plain run's and FreeBSD's, and erXos's
  scripts check one ACK per merged segment echoing the last TSval, and a
  duplicate ACK, a SACK, a FIN and a CE mark each ending a unit. *Seeded
  faults:* the mode's batching or its cut turned off, which leaves the
  units merged or the runs cut at zero, which the runner refuses.
* **The copy check:** an `iolist_to_binary/1` added to `erx_tcp_output`
  fails `make check`.
* **The driver cuts every batch to the merge's limit:** floods of minimum
  and jumbo frames injected at once all reach `classify/2` once. *Seeded
  fault:* the driver's cut removed.

#### Fuzz targets

* **`tcp_cut`:** arbitrary templates, segment sizes and piece lists into
  the plan, and every frame of an accepted plan into a buffer of the
  planned size, under AddressSanitizer. Its oracle decides on its own
  reading whether the plan must accept the run, and re-derives each
  frame's bytes and both checksums; the header-only path followed by the
  slice must give the same frame. *Seeded faults,* each failing on the
  target's seeds: a run one byte over `IP_MAXPACKET` accepted, bytes after
  the TCP header accepted, and the cut test's five faults.
* **`tcp_merge`:** arbitrary batches within the limit, and past it, which
  must be refused, with and without sums, under AddressSanitizer. Its
  oracle checks that each unit's pieces are its members' payloads,
  contiguous, of one flow, each member's checksums correct, and every
  input frame in exactly one unit or on its own. *Seeded fault:* a merge
  across differing ports.
* **`erx_net_input`** (the classifier's target) reaches merged units: a
  burst of one connection's segments with another connection's frames,
  other flags and spoiled payload bytes among them. Every segment
  `verify/1` accepts carries the connection's own bytes at its sequence
  number, a merged one takes as many units as it holds and the last
  frame's acknowledgement, an unowned unit is classified as its last
  frame, and a forged unit (a count below its pieces or past the limit, a
  last frame of another connection, a piece cut short) is dropped as
  `malformed`. *Seeded faults:* the count unchecked, the last frame's
  sequence number unchecked, a unit classified by its last frame.

All run in `make check-fuzz` at the milestone gate.

#### Benchmarks and targets

Every number names the host, operating system, accelerator, QEMU version
where there is one, compiler and flags, workload and baseline, and
reports frames per run, segments per merged unit and frames dropped; a
bulk measurement that shows no runs sent or no units merged fails, so the
number comes from the path under test. `tools/erx bench net-freebsd`
takes the host measurements over tap (`--only` picks workloads).

* **Bulk on the FreeBSD test host.** 512 MiB each way in 64 KiB sends,
  passive `recv(S, 0)`, the median of three, over tap and over a VALE
  port of netmap; throughput, CPU seconds per GiB (the client's own user
  and system time, read just before and after the run so start-up is not
  in it), context switches and the scheduler settings. Baseline: lwIP
  2.2.1 over the same tap
  (`~/erxos-history/net-bench-freebsd-lwip-2026-11-09/`) and over VALE.
  *Target:* two thirds of lwIP's throughput each way, 4.4 Gbit/s over
  tap.
* **Request-reply on the FreeBSD test host.** One connection, 64-byte and
  1 KiB requests and replies, an echo server in the jail, 10 s;
  transactions a second, median and 99th-percentile latency, CPU per
  transaction; and 16 connections at once. Baseline: lwIP's bench program
  in a request-reply mode. *Target:* a third of lwIP's rate, at most three
  times its CPU per transaction.
* **Under HVF.** An erXos guest and the Linux oracle guest on the path of
  plan.md's gate GN-QEMU, with the same workloads; baseline the Linux
  oracle guest at both ends of the same path, since lwIP is the baseline
  on the FreeBSD test host only, where it runs on the same medium. TCG
  numbers are not compared with these.

Each part lands with the host numbers before and after it, and with the
HVF numbers when it changes erXos's code; the order of the parts is in
`TODO.md`. One step per mailbox is judged by the connection's time per
segment, ACKs per received segment and receive throughput; the lean step
by calls, heap words and time per segment for a run of one and the
request-reply rate; the tap transport by CPU per GiB and the driver's
time per frame; runs by frames per run, time per sent segment and send
throughput; the merge by segments per unit, the interface's and the
connection's time per received segment, and receive and sender
throughput; netmap by the same over VALE against lwIP over VALE.

### Fast-path decisions

1. **C does per-frame work inside the copy and the merge,** and no TCP
   decision moves to C. [design.md](design.md#decisions) gives C the work
   done once per byte and Erlang the work done once per packet; the cut
   writes header values Erlang chose inside the copy's per-byte pass, and
   the merge groups frames by a fixed rule. It is taken before gate GK3
   on the FreeBSD evidence: the bottleneck is the number of per-segment
   Erlang steps in one process, which does not depend on the kernel
   below. GK3 still decides whether any TCP decision needs native code.
2. **A tap NIF replaces the tap helper and the pipe's `port` end.**
   Sending, the helper took 11.9 percent of all CPU samples on the
   FreeBSD test host, against 62.7 for the BEAM, and a frame cost three
   system calls and four copies through it, where lwIP runs over the same
   tap with one copy in user space and one in the kernel. The spawn
   driver's 64 KiB read buffer, allocated and freed at every read
   (`ready_input` in `sys_drivers.c`), is the likely, unconfirmed, source
   of the kernel lock spinning under `munmap`.
3. **The device finishes only with `VIRTIO_NET_F_CSUM`, `HOST_TSO4` and
   `HOST_TSO6` together,** since one `finish` key covers a delayed
   checksum and a run's cut ([Device segmentation](#device-segmentation)).

### Fast-path alternatives

* **The lean step alone** gives about twofold, not the sixfold needed.
* **TCP's established path in C** would make two translations of
  FreeBSD's decisions and move protocol decisions into C; runs get most
  of the gain with every decision in Erlang.
* **The merge inside the copy,** laying a unit's payloads end to end in
  each NIF, saves the socket process's join on erXos but puts a parser of
  device-written bytes in the device NIF, needs a snapshot and plan in
  each NIF, and on tap a `readv` layout, since the kernel lands a frame
  before its header is seen. Both choices put a C parser on
  device-written bytes; the merge's reads only immutable binaries, in the
  interface, where a bug cannot reach the device's rings, and is the same
  for every transport. The join it leaves is on the watch list.
* **The merge in Erlang** keeps the per-frame Erlang work it removes.
* **Joining the merged payload in the merge** copies early: a delivery
  spanning several units joins again.
* **Runs for retransmissions:** FreeBSD's default, `tcp_sack_tso` 0,
  sends one segment at a time, and the stack follows its default.
* **Joining small sends in the send buffer,** as `sbcompress` compacts
  mbufs, copies the owner's bytes; the 64-piece bound ends a run instead,
  so many tiny sends make short runs, a cost on the watch list.
* **Receive offload by the device** is a claim the stack would take on
  trust, as the checksum design declines `GUEST_CSUM`.

### Fast-path sources

The FreeBSD line references of this section cite FreeBSD 15.1
(`release/15.1.0-p6`), the release the stack's references cite:
`sys/netinet/tcp_output.c`, `tcp_sack.c`, `tcp_lro.c`, `tcp_lro.h`,
`tcp_input.c`, `cc/cc_cubic.c`, `cc/cc.c`, `cc/cc_newreno.c` and
`sys/net/if_tap.h`. Also: VIRTIO 1.2, section 5.1 (the network device and
`virtio_net_hdr`'s GSO fields, 5.1.6.2); RFC 3465, RFC 5681 section 4.2,
RFC 6864 and RFC 7323; the measurements cited under
[What was measured](#what-was-measured); and
[design-domains.md](design-domains.md#flow-control) for the lane's
copies.

## Modules and provenance

### Modules

The stack is the application `erx_net`, in `erlang/apps/erx_net/`. Pure
modules (P) decide; process modules (E) run the steps and carry out their
actions. Which FreeBSD files and functions each module translates is
recorded once, in each module's header and in
`erlang/apps/erx_net/NOTICE-freebsd`
([Provenance and notices](#provenance-and-notices)).

| Layer | Modules | |
| --- | --- | --- |
| link and neighbours | `erx_net_eth` (Ethernet II), `erx_arp_wire` and `erx_arp`, `erx_lltable` (the neighbour table of ARP and neighbour discovery) | P |
| IPv4 | `erx_ip4_wire`, `erx_ip4`, `erx_ip_reass` (the reassembly table both families share) and `erx_ip4_reass`, `erx_icmp4_wire`, `erx_icmp4`, `erx_net_bandlim` (the rate limits on ICMP and ICMPv6 answers and RSTs, with their jitter) | P |
| IPv6 | `erx_ip6_wire` (with the extension-header walk), `erx_ip6`, `erx_ip6_reass`, `erx_icmp6_wire`, `erx_icmp6`, `erx_nd6`, `erx_nd6_dad`, `erx_nd6_rtr` (neighbour cache; DAD; routers, prefixes, autoconfiguration), `erx_in6_src` (source address selection), `erx_mcast` (IGMPv3 and MLDv2, an extension) | P |
| addresses, routes, sums | `erx_net_addr`, `erx_net_route` (longest-prefix lookup), `erx_net_sum` (one's-complement arithmetic on sums, and `span/4`, [Checksums in the copy](#checksums-in-the-copy)) | P |
| UDP | `erx_udp_wire` (with each IP version's checksum and length rules), `erx_udp` | P |
| TCP | `erx_tcp_wire` (checksum first, and options), `erx_tcp_seq` (lifting), `erx_tcp` (the step), `erx_tcp_input`, `erx_tcp_output`, `erx_tcp_timer`, `erx_tcp_user`, `erx_tcp_sndbuf`, `erx_tcp_payload`, `erx_tcp_rtt`, `erx_tcp_mss`, `erx_tcp_sendlog` (from RFC 6675), `erx_tcp_sack` (from RFC 2018 and RFC 2883), `erx_tcp_reass`, `erx_tcp_loss` and `erx_tcp_loss_dupack`, `erx_tcp_cc`, `erx_tcp_cc_newreno` and `erx_tcp_cc_cubic`, `erx_tcp_ecn`, `erx_tcp_isn`, `erx_tcp_syncache`, `erx_tcp_icmp`, `erx_tcp_timewait`, `erx_tcp_hostcache` (an extension, [Scope](#scope)), `erx_tcp_listen_core` (from `sys/kern/uipc_socket.c`'s listen queue) | P |
| classification and framing | `erx_net_input` (classify a frame against the interface's view; verify it once it holds room), `erx_net_frame` (a destination's path, packets, frames or a hand-over to the interface), `erx_net_bind` (port choice, reuse rules and the claim funnel), `erx_net_if_core` (the interface's step) | P |
| DHCP and the rest of the core | `erx_dhcp4_wire`, `erx_dhcp4_core` (from RFC 2131, 2132, 3396 and 3442, with `sbin/dhclient`'s option checks), `erx_net_rand` (the keyed generator each owner holds), `erx_net_grant_core` | P |
| funnels | `erx_net_credit` (credited hand-over), `erx_net_clock` (the time, the one timer and the entropy of every process), `erx_net_admit` (the admission path, generated from `abi/services/net.txt`) | |
| processes | `erx_net_if`, `erx_tcp_conn`, `erx_tcp_listen`, `erx_udp_sock`, `erx_icmp_sock`, `erx_net_grant`, `erx_net_tables`, `erx_dhcp4`, `erx_epmd`, `erx_net_tx` (the sockets' transmit edge), `erx_net_driver` | E |
| seams | `erx_net_runtime` (the runtime seam's behaviour); erXos's `erx_virtio_net`, `erx_genet` and `erx_net_erxos` (in `erxos/`); the portable `erx_bytes` and `erx_net_local`, and the transports `erx_net_loop`, `erx_net_pipe`, `erx_tap` and `erx_netmap` with their NIF loaders (in `portable/`) | |
| C17 (in `c_src/`) | the per-byte primitives `erx_net_bytes`, `erx_inet_csum`, `erx_siphash`; `erx_tcp_cut` and `erx_tcp_merge` ([The fast path](#the-fast-path)); the host NIFs `erx_tap_nif.c`, `erx_netmap_nif.c` and `erx_netmap_ring.c` (the pure core that plans each netmap call) | |

The packet-script runner `erx_net_script`, the virtual clock, the
impairment schedule `erx_net_impair` and the relay `erx_net_relay` are
test code in `erx_net`'s `test/`, beside the stack's unit tests, fuzz
targets and explorer, all run on stock OTP from the app directory alone
([The stack on a development host](#the-stack-on-a-development-host)).

The client side is the application `erx_net_client`, in
`erlang/apps/erx_net_client/`, which every erXos domain runs beside
`erx` and a node outside erXos runs beside `erx_net`: the socket backends
`erx_gen_tcp` and `erx_gen_udp`, each the stubs `gen_tcp`, `gen_udp` and
`inet` call and the `gen_statem` of its socket process; `erx_gen_icmp`,
the echo socket's backend, which `ping` uses and whose socket process is
`erx_gen_udp`'s, so one `gen_statem` and one core serve every socket that
carries whole datagrams; the pure presentation steps `erx_gen_tcp_core`
and `erx_gen_udp_core`, with `erx_net_packet`, the packet framing;
`erx_sock_admit`, the check of every message the client side takes from
the network domain; `erx_sock_out`, the socket process's one way to send
to its socket ([The socket process](#the-socket-process)); and
`erx_inet`, the one path to the grant and the resolver loader. It depends
on `kernel` and `stdlib` alone, and its calls into erXos go through
`erxos/erx_net_client_erxos`
([Two places, four seams](#two-places-four-seams)).


### Provenance and notices

A module that translates FreeBSD code is a derived work of each FreeBSD
file it translates. Its header carries, after erXos's own notice, a line
`%% FreeBSD: PATH` for each such file, naming it by its path in the source
tree, followed by every copyright line and the license text of that file
at the pinned commit, and its SPDX line names both licenses, such as
`SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause`, so the packer
counts it as third-party for `NOTICES`
([design.md](design.md#licenses-and-notices)). Its `-moduledoc` names the
FreeBSD files and the pinned commit; each function that translates a
FreeBSD function says so in its `-doc`, with the FreeBSD function's name,
so a reviewer compares the two side by side.

`erlang/apps/erx_net/NOTICE-freebsd` records the pinned commit and the
release the translation was read from, the SHA-256 of each one's source
archive, every change ported from between the two with its FreeBSD
commit, and for every module the FreeBSD files and functions it derives
from, as `kernel/NOTICE-fiasco` records the kernel's translation from
Fiasco. A change between the release and the pin is ported when the wire
or an interoperating peer can see it, or when it fixes a real bug;
anything else is left as it was read ([Decisions](#decisions), 9). The
notice and erXos's own license notice are in the app directory, so the
app carries them wherever it goes (N12). The
FreeBSD source is a reference for readers, fetched by hand and not by the
build: the archive is
`https://github.com/freebsd/freebsd-src/archive/<commit>.tar.gz`, checked
against the SHA-256 in the notice. A
build check fails when a module's header names a FreeBSD file that the
notice file does not list for it, or the reverse.

Three files are never translated.
`netinet/in_cksum.c` carries the four-clause BSD license with its
advertising clause (`in_cksum.c:17`); the Internet checksum is erXos's
own per-byte primitive. `netinet/tcp_sack.c` carries, besides the
Regents' notice, NRL's notice with an advertising clause, which erXos
does not take into its tree; the receiver's SACK blocks are written from
RFC 2018 and RFC 2883, and the sender's scoreboard and recovery from RFC
6675, each without reading it. RACK's
`tcp_stacks/tailq_hash.c` and `.h` carry no license header; a RACK module
reads `rack.c` for its logic and builds its records on the send log.

A translation keeps FreeBSD's decision and drops its mechanism. A
reviewer checks each translated function for: the same branches on the
same conditions, in the same order where order is visible on the wire;
constants and defaults taken from FreeBSD by name; and a comment at each
place it departs, citing this document.

## Authority and admission

### Who holds the network device

Only the network domain holds a network device, by the system manifest
and its check ([design-system.md](design-system.md#the-manifest), rule
8). The driver is a process of the network domain, and the stack talks to
it as to any local process. No client domain reaches a driver, an
interface process or a shared table.

A domain that drives a medium the network domain cannot hold, the WiFi
domain with the Raspberry Pi 4's WiFi chip behind the storage domain's
SD controller, lends it through a facet of the network domain's `ether`
interface, one service row per lent interface, named after it. An offer
starts that interface's link, whose driver is a process of the network
domain as every driver is, over the transport `erx_net_ether`; the
lender sees only its own link's frames, credits and offer, and no other
part of the stack ([design-wifi.md](design-wifi.md#the-ether-interface-and-wlan0)).

### The grant

A domain's use of the network is one grant: an `erx_net_grant` process
in the network domain, an instance of the `erx_facet` behaviour bound to
the domain. The network service makes it when the system domain
introduces the network domain to the client, as a storage service makes
its grants ([design-system.md](design-system.md#creating-a-domain)), and
the client's runtime installs it under the name `net`
([design-system.md](design-system.md#granting-a-running-domain)). Its
operations and their bounds are declared in the network service's
operation schema, `abi/services/net.txt`, from which the build generates
the client stubs, the admission path and the request validators
([design-domains.md](design-domains.md#authority)). A domain without the
grant gets `{error, eacces}` from every call that would need it, as
POSIX's `socket` answers a refused protocol.

**Its start and its end.** The mint starts a grant with the grantee's
id and the port of the network domain's connection to the grantee,
which the domain agent's `erx_connections:connection/1` answers once the
peer's entry is up. The grant monitors that port first, then exports
itself to the grantee with `send` alone, and only then does its start
return: the mint never answers with a grant its grantee cannot reach,
and a refused export is the start's refusal, which leaves no grant. The
grant ends with `{shutdown, connection_ended}` when the port ends. The
port lives exactly as long as the connection, and a port monitor is
local and matched by its reference, so no other process can forge the
end, as one can a `{nodedown, Node}` message, and it needs no node
monitor of the distribution. Because the monitor comes before the
export, the connection's end at any moment ends the grant, even when a
newer connection has replaced it by the time of the export, and the
grant's export goes with it
([design-domains.md](design-domains.md#exports), D13). A grant is never
restarted: the domain service grants a domain again only when either
domain restarts.

**The system domain never holds the grant.** The trusted base parses
no network traffic: no socket's stream, push or exit and no answer of
the grant enters the system domain, and whatever in it would need the
network runs in a service domain instead. The manifest's check refuses
a `net` facet granted to the system domain, and the mint refuses the
system domain's id as a grantee
([design-system.md](design-system.md#the-manifest), property 15). The
network utilities, `ifconfig`, `ping` and `host`, therefore run in a
session that holds `net`, root's session at the UART in a development
build, which holds every facet a session can hold
([design-domains.md](design-domains.md#principals-sessions-and-quotas)),
and not in the system shell. So every client of the grant is a domain
whose loss of a message or whose stop harms only itself, and nothing in
the socket protocol has a case for the system domain's queue, which
drops a plain message past `system_queue` and ends the domain at any
other signal past it
([design-domains.md](design-domains.md#flow-control)).

The grant's limits come from the domain's specification within its
principal's policy:

| Limit | Meaning | Default |
| --- | --- | --- |
| `sockets` | sockets open at once, listeners and accepted connections included | 1,024 |
| `buffers` | bytes of send and receive buffer reserved across the grant's sockets; what a socket has pushed to its socket process is the client's own memory and does not count | 16 MiB |
| `time_wait` | connections in TIME-WAIT | 4,096 |
| `ports` | `[{Lo, Hi}]`, inclusive ranges of the local ports the grant may bind explicitly; ports below 1,024 only when listed, as FreeBSD requires privilege for them (`ipport_reservedhigh`, `in_pcb.c:132`). A facet row states it as a set of at most 16 ports, which replaces the default and which the mint takes as one-port ranges; a port below 1,024 is listed by one grant of a network domain alone (property 15 of [design-system.md](design-system.md#the-manifest)) | `[{1024, 65535}]` |
| `listen` | `true`, `false` or `[{Lo, Hi}]`: whether the grant may listen, and on which of its `ports`; a listener's bind may claim the ports both hold. A facet row states it as a set of at most 16 of its `ports`, taken as one-port ranges, or leaves it out for `true`; no row states `false` | `true` |
| `addresses` | `all` or `[Addr]`, `Addr` an address tuple such as `{10, 0, 2, 15}`, the local addresses the grant may bind, a listener's or a datagram socket's; when it is a list, a bind to `any` is refused with `{error, eacces}` | `all` |
| `share` | reductions per period, the facet's share | the policy's |
| `max_request` | the largest decoded request the grant and its sockets take; the runtime drops a larger one before it is queued | fixed, not a policy's: the schema's largest request, which the generator computes |

`erx_net_grant_core:bind_ports/3` turns the three binding limits into
the ports one explicit bind may claim, which the grant hands the bind
([Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)):
`ports` for a datagram socket, `ports` narrowed by `listen` for a
listener, and `{error, eacces}` for a listener when `listen` is `false`
and for either when `addresses` does not hold the local address. A limit
of another shape allows nothing, so a malformed policy fails closed.
A wildcard bind under a list of addresses is refused rather than
narrowed: a FreeBSD jail binds `INADDR_ANY` to its one address when it
has one and otherwise leaves it the wildcard (`prison_local_ip4`,
`in_jail.c:233-240`), filtering what arrives later, while the table maps
a key to one socket and a wildcard key would take every address of the
port from other grants, so a client given addresses names one of them.

Configuring interfaces and reading every client's statistics is a second
facet, `netadmin`, granted to administrators. Reading the interfaces
needs only `net`, as FreeBSD's `ifconfig` shows them to any user:
`erx_net:interfaces/0` is the one read
path for an interface's state: each interface process answers for itself
with its name, link-layer address, MTU, link state, configuration
(static or DHCP), addresses, routes and resolver servers, which
`ifconfig` shows and the resolver reads, and no administrative reader
takes them from the published tables.

### Sockets act for one domain

The grant starts the domain's sockets, except connections accepted on
the domain's listeners, which the interface process starts; every socket
links to its grant and traps exits, so the grant's end reaches it as a
message and it ends, a connection with a RST.

In this document a socket is the network domain's process for it, a
connection, listener or datagram socket. Each serves exactly one socket
process, in the grantee's domain
([The socket process](#the-socket-process)): the one the `connect`,
`listen` or `open` that made it names, or, for an accepted connection,
the one its listener's `accept` request names. It links to that process
before anything else, takes requests from it alone and sends it alone
its pushes and replies, and sends it nothing until it has taken that
process's first message (**Opening**, in
[The socket process](#the-socket-process)); no owner, and no other
process of any domain, is known to it. The link is the one tie between the two in each
direction: the socket takes its socket process's exit as the end of its
socket process, and the socket process takes the socket's exit as the
end of its socket. A socket's pid is encoded only in frames to its socket
process, so the network domain's runtime exports it to the grantee
alone, with `send` only, and no other domain can message it
([design-domains.md](design-domains.md#exports)). A socket receives
messages from other domains wrapped with their origin, as every process
does ([design-domains.md](design-domains.md#the-peer)), and checks each
request as a facet does, through
the admission path generated from the same schema: the request's origin
against the grantee, its operation and arguments against the schema, its
size, and the requests in flight against the socket protocol's limits
([Requests in flight](#requests-in-flight)). The socket process a request names, in
`connect`, `listen` or `open` or in `accept`, must be a
pid of the grantee's domain. Every later request must then name the
socket's own socket process as its sender
(`{erx_net, SockProc, Body}`); one that names any other process is
dropped and counted, as a message that names no socket is. This check
is not an authority boundary: the domain is the unit of authority, and
any process of the grantee's domain may use the socket through its
socket process, as any process of a node may use a stock socket it
knows. What it gives is that nothing reaches a socket around its socket
process, so the ordering of [Ordering](#ordering) holds.

A connection waiting in a listener's queue holds a unit of the
listener's accept credit, which the backlog bounds, and is one of the
grant's sockets from its adoption, when the grant also reserves its
buffers ([The listener](#the-listener)). One the grant cannot count or
give buffers is reset at its handshake, so every connection the network
domain holds for a client is within the client's limits, and `accept`
never answers `{error, emfile}`.

**The grant's account.** Every reduction a socket spends, on its
socket process's requests and on the packets that arrive for it, is charged to
its grant's account, the facet's account of
[design-domains.md](design-domains.md#facets) extended to the processes
the facet starts ([Decisions](#decisions), 1). The grant's own work, on
`connect`, `listen` and the rest, is charged to the same account as any
facet's is. The account is an `atomics` array that the grant creates and
hands each socket at its start: the reductions spent in the current
period, and the period's number. The period and the share are the
facet's.

* **Charging.** A socket reads `process_info(self(), reductions)` before
  and after each step and adds the difference to the account at once, so
  work that has no reply, as packet work has none, is charged as it is
  done.
* **Pausing.** Before it takes its next message, a socket compares the
  account with the share. While the share is spent, the socket sends its
  grant `{paused, self()}` and then takes only its grant's messages, the
  grant's `{resume, Period}` and the grant's `'EXIT'`, by a selective
  receive that names the grant alone. Everything else, the exits of its
  other links included, stays in its mailbox in the order it arrived and
  is taken after the resume in that order, so pausing reorders nothing
  the socket steps: what one process sent it, an exit included, it steps
  in the order sent, which a lane's bytes before its FIN
  (**Ordering**, in [The socket process](#the-socket-process)) and a
  listener's notice before its connection's exit
  ([The listener](#the-listener)) rest on. The grant's exit ends the
  socket without a step, wherever it stands in the mailbox, so taking it
  first loses nothing, and a paused socket whose grant has ended still
  ends. Meanwhile its packet credit fills, its interface drops further
  segments for it, and the peer's congestion control slows; its
  deadlines and the exits of its other links wait too, so a
  retransmission, a keepalive or a close runs at most one period late.
* **The period's turn.** The grant arms the period's one timer. At each
  turn it subtracts the share from the spent count, never below zero, so
  an overrun is carried into the next period as a debt and an unspent
  share is not carried; it increments the period's number and sends
  `{resume, Period}` to every socket that reported itself paused. A
  `{paused, Pid}` that arrives when the account is no longer spent, after
  a turn the socket did not see, is answered with `resume` at once, so no
  socket waits a period for a turn it missed.
* **The overrun.** A socket checks before each step and charges after
  it, so a grant's account exceeds the share by at most one step per
  socket, the grant's `sockets` limit times the costliest step. A step is
  finite: a batch of segments is bounded by the socket's credit, and a
  request by the operation schema's bounds. The debt repays the overrun
  in the next period, as a facet's debt repays its requests in flight.

So every reduction the network domain spends is charged to exactly one
place: a grant's account for work in its sockets, and the network
domain's own grant for the interface processes and the drivers
([Untrusted input](#untrusted-input)).

Buffer space is reserved at the grant: a socket asks its grant, with a
local call, before it grows a buffer by autosizing or by a `sndbuf` or
`recbuf` option, and the grant refuses past its `buffers` limit. Each
call names a token the grant made for that socket alone and handed it
at its start, or in the answer to its adoption, so a reservation is
never charged to a socket on the word of a pid in a message. A
connection the grant starts reserves its initial buffers first and,
refused, is answered `{error, enobufs}`; a connection the interface
process starts reserves them in its adoption, its listener's sizes,
and, refused, ends with a RST, as FreeBSD answers a completed handshake
it cannot give a socket ([The listener](#the-listener)). The grant holds each socket's reservation and
releases it when the socket exits, by whatever means, or earlier, when
a connection reaches TIME-WAIT with its socket process gone: then its
send buffer is empty, since the peer acknowledged our FIN, its receive
queue was dropped with the socket process, and nothing more can be
queued or delivered. FreeBSD keeps a closed socket's `chgsbsize` charge
until `tcp_close` frees it at the end of 2MSL (`tcp_usr_close` holds the
socket by `INP_SOCKREF`, and `tcp_twstart` only calls
`soisdisconnected`, which empties the send buffer but keeps its
reservation); its per-user limit is unlimited by default, so the
charge costs nothing there. A grant's limit is finite, and a client
that makes many short connections would otherwise hold 96 KiB for each
of them for a minute after closing it.

### Ports and the demultiplexing table

The demultiplexing table, `erx_net_demux` in `erx_net_tables`, maps a
key to the socket that receives for it, its entry `#{pid, credit, grant}`:
the holder, the credit a frame for it takes a unit of, and the grant
whose socket the holder is, which every entry names, connections and
datagram sockets included, so that a grant's entries are one match on
`grant`:

* `{tcp, Family, LocalAddr, LocalPort, RemoteAddr, RemotePort}`: a
  connection;
* `{tcp_listen, Family, LocalAddr | any, LocalPort}`: a listener, whose
  entry also holds its grantee and what it passes to the
  connections it accepts ([The listener](#the-listener)), and whose
  credit is its accept credit;
* `{udp, Family, LocalAddr, LocalPort, RemoteAddr, RemotePort}`: a
  connected datagram socket;
* `{udp, Family, LocalAddr | any, LocalPort}`: a bound one.

Lookup goes from the most specific key to the wildcard, as
`in_pcblookup_hash` does ([Classifying a frame](#classifying-a-frame)). Every insertion goes through `erx_net_bind`,
with `ets:insert_new/2`, so a key is held by exactly one socket by
construction and a race between two binders of one key is decided by
ERTS; an explicit bind also runs its conflict check in the same step
(**Explicit binds**, below). The one rewrite is
`erx_net_bind:update/2`, by which a listener rewrites its own entry when
its options change, keeping the pid, credit and grant, so it never
changes who holds a key or what a bind checks. It writes with one
`ets:select_replace/2` whose match specification matches the key's
object only while its holder is the caller
(the object's holder bound to `self()` in its head, its entry's credit and grant to the new entry's in its guard) and whose body is the
key with the caller's new entry, and ETS makes each object's match and replacement
one atomic step (`ets.erl:1864-1870`). The holder is the one fact that
changes when a key changes hands, and no other process has the caller's
pid while the caller runs, so a key its grant's end has deleted is not
brought back and a key deleted and then claimed by another grant's
socket is left as that socket holds it. The condition and the write
being one step of ETS, `update/2` needs no call to `erx_net_tables` and
no ordering against deletions and explicit binds there. A chokepoint check fails the build on any other
insertion into the table or rewrite of an entry.

`erx_net_bind` translates FreeBSD's port rules: ephemeral ports from
10,000 to 65,535, chosen at random (`ipport_firstauto`,
`ipport_lastauto`, `ipport_randomized`, `in_pcb.c:122-136`), with
`in_pcb_lport_dest`'s search for a free four-tuple: a random start, then
each port after it in turn, wrapping at the end of the range, until one
is free or the range is spent (`in_pcb.c:830-842`). The binding socket's
step draws the start from its generator with `uniform/2` and returns it
in its bind action, and the funnel walks the range from there with
`ets:insert_new/2`. A connection's claim checks only its four-tuple,
as `in_pcb_lport_dest` does (`in_pcb.c:843-857`), and so does the
interface's insertion of an accepted connection.

**Explicit binds.** A listener's key and a bound datagram socket's key
are claimed by an explicit bind, whose conflicts depend on keys other
than the one inserted, so its check and its insertion are one step of
one process: `erx_net_bind:bind/2` makes a call to `erx_net_tables`,
the table's owner, which runs both, and two explicit binds are ordered
by their calls. The check is a pure function, `erx_net_bind:avail/2`,
of the request (transport, family, address or `any`, port, `reuseaddr`,
`reuseport`, grant, which the binding socket's entry names, the ports the grant allows this bind, and the
machine's own addresses of the family, which `erx_net_tables` reads from
`erx_net_addrs` without waiting on an interface) and the keys of the
request's transport held on that port, with their entries:
TCP keys, connections' and listeners', for a listener, and UDP keys for
a datagram socket, as FreeBSD checks a bind only within its protocol's
own table, TCP's `V_tcbinfo` (`tcp_usrreq.c:168`) or UDP's `V_udbinfo`
(`udp_usrreq.c:185`). It translates `in_pcbbind_avail`
(`in_pcb.c:912-998`) for unicast addresses, each family on its own,
since an IPv6 socket is IPv6-only:

1. the address must be one of the machine's, or `any` (`:940-956`),
   else `{error, eaddrnotavail}`;
2. the port must be one the request allows, else `{error, eacces}`:
   the grant's `ports`, narrowed by `listen` for a listener, as
   `in_pcbbind_avail` refuses a privileged port to an unprivileged user
   (`:961-964`);
3. a key without a remote end that another grant holds, on the same
   address or with either address `any`, refuses with `{error,
   eaddrinuse}` whatever the reuse options, as a socket of another
   user does (`:966-983`), so one domain never takes a port, or one
   address of it, from under another domain's listener (for a datagram
   socket, another grant's connected keys count too, as there);
4. without `reuseaddr` and `reuseport`, any key on the port whose local
   address is the same, or either of them `any`, refuses, connections
   included, one in TIME-WAIT until its 2MSL period ends
   ([TIME-WAIT](#time-wait)), since `in_pcbbind_setup` then looks up with
   `INPLOOKUP_WILDCARD` (`:1031-1032`) and that lookup matches
   connected sockets (`in_pcblookup_local`, `:2035-2085`);
5. with either option, a key without a remote end on exactly the same
   address refuses (`:2000-2027`), whatever options its holder has.
   FreeBSD lets two holders of `reuseport` share it (`:985-995`); the
   table maps a key to one socket, so erXos refuses the second, and
   `reuseport` acts as `reuseaddr` does (**Departures from FreeBSD**, in
   [The listener](#the-listener)).

Port 0 walks the ephemeral range from a random start, as
`in_pcb_lport` does without a remote end, and takes the first port
`avail/2` allows, so a port the bind chooses passes the same rule 2 as
one the caller names, and a grant whose allowed ports leave no
ephemeral port free is answered `{error, eaddrnotavail}`, as a spent
range is. The grant hands the bind its allowed ports and checks no port
itself, so there is one check of a port, the bind's. A connection's
claim can race an explicit bind of its port under rule 4; either way
the result is a state FreeBSD reaches when the listener binds first,
since a connect never checks listeners.

A socket removes its own entries when it ends normally, each only while
it still holds the key, so a key that a grant's end freed and another
socket claimed is left to that socket. When a socket exits abnormally,
`erx_net_tables`, which watches every holder from the step that
inserted its key (inside the call, for an explicit bind), deletes every
entry whose holder is that pid. When a grant ends, `erx_net_tables`, which
monitors every grant, deletes every entry naming the grant, with one
`ets:select_delete/2` matching the entries' `grant`, so no list of the
grant's sockets takes part and an entry inserted for a socket the grant
has not yet linked or adopted goes too. These
are the only two ways an entry outlives its holder, and `erx_net_tables`
handles both.

## The interface towards Erlang programs

### The backend

erXos's OTP adds a third value to `inet_backend`, `erx`, and makes it the
default: `inet:gen_tcp_module/1` and `inet:gen_udp_module/1`, through
their private two-argument clauses, return `erx_gen_tcp` and
`erx_gen_udp` for it. On stock OTP, where that edit is absent, a host
test calls the backend directly
([Running on a development host](#running-on-a-development-host)). A socket is
`{'$inet', erx_gen_tcp, Pid}` or `{'$inet', erx_gen_udp, Pid}`, where
`Pid` is the socket's socket process, a process of the owner's own domain
([The socket process](#the-socket-process)), so `gen_tcp`, `gen_udp` and
`inet` reach the backend through the dispatch they already have. The
socket process builds that term for every message it sends the owner, so
an owner's `receive {tcp, S, Data}` matches as on stock, in any domain.

Each call on an open socket is a local call to the socket process, which
answers what is its own (presentation, `recv`, `controlling_process`,
`close`, statistics) and sends the rest as one request to its socket. An open is the
socket process's own call to the grant, which takes its caller as the
socket process, so no open request names one (**Opening**, in
[The socket process](#the-socket-process)).

| Call | Answered by the socket process | Request to the network domain | To |
| --- | --- | --- | --- |
| `gen_tcp:connect/3,4` | started by the stub, owned by the caller, which calls the grant | `{tcp_connect, Family, Remote, Port, Opts, Timeout}` | grant |
| `gen_tcp:listen/2` | started by the stub, owned by the caller, which calls the grant | `{tcp_listen, Family, Local, Port, Opts}` | grant |
| `gen_tcp:accept/1,2` | the listener's socket process starts the new connection's, owned by the caller | `{accept, SockProc, Timeout}`, naming the new socket process | listener |
| `gen_tcp:send/2` | forwarded in pieces within the send credit; the caller waits, behind any earlier `send`, until its last byte is sent, at once when its credit covers it | `{send, Piece}` for each piece of up to 64 KiB, in order, within the send credit the connection granted; nothing answers it | connection |
| `gen_tcp:recv/2,3` | from the bytes it holds, waiting until the deadline, behind any earlier `recv` | none; a waiting recv may grant credit | none |
| `gen_tcp:shutdown/2` | forwarded | `{shutdown, How}` | connection |
| `gen_tcp:close/1` | answered `ok`, then the socket process ends, and its exit closes the socket | none; the exit, through their link | socket |
| `gen_tcp:controlling_process/2` | locally, as `gen_tcp_socket` does | none | none |
| `gen_udp:open/1,2` | started by the stub, owned by the caller, which calls the grant | `{udp_open, Family, Local, Port, Opts}` | grant |
| `gen_udp:send/2,3,4,5`, `gen_udp:connect/3` | forwarded; a datagram larger than IP allows is refused here with `{error, emsgsize}` | `{send_to, ...}`, `{connect, ...}` | datagram socket |
| `gen_udp:recv/2,3` | from the datagrams it holds, waiting until the deadline, behind any earlier `recv` | none | none |
| `inet:setopts/2`, `inet:getopts/2` | its own options locally, the rest forwarded ([Options](#options)) | `{setopts, Opts}`, `{getopts, Names}` for the socket's options | socket |
| `inet:peername/1`, `inet:sockname/1`, `inet:port/1` | forwarded | `peername`, `sockname` | socket |
| `inet:getstat/1,2` of a TCP socket | from the counts it keeps ([Options](#options), **Statistics**) | none | none |
| `inet:getifaddrs/0`, `inet:gethostname/0`, `ifconfig` | no socket process: the caller calls the grant through `erx_inet:call/1`, which admits the answer ([Untrusted input](#untrusted-input)); `inet:getifaddrs/0` builds its answer from the interfaces' records | `interfaces`, `hostname` | grant |
| `erx_gen_icmp:open/0`, which `ping` uses | started by the stub, owned by the caller, which calls the grant | `{icmp_open, Family}` | grant |

A socket closes when its owner exits, as a `gen_tcp` socket does: the
socket process monitors its owner. The pushed messages are stock's:
`{tcp, S, Data}`, `{tcp_closed, S}`, `{tcp_error, S, Reason}`,
`{tcp_passive, S}`, `{udp, S, Address, Port, Data}`, `{udp_passive, S}`.
Active modes `true`, `false`, `once` and `N` behave as stock. `{active,
N}` takes `N` from -32768 to 32767 and adds it to the count of a socket
already in `{active, M}`, as stock does (`inet.erl:932-941`,
`gen_tcp_socket.erl:3124-3138`): a sum over 32767 is refused with
`{error, einval}`, and a count that reaches zero or less makes the
socket passive and sends `{tcp_passive, S}` or `{udp_passive, S}`. In
`true` mode, as on stock, only how fast the owner reads limits its
mailbox; what limits the network domain is the socket process's credit.

In passive raw mode `recv(S, 0)` takes what the socket process holds, or
waits for the next push, and `recv(S, Length)` waits for exactly `Length`
bytes, up to stock's 64 MiB (`TCP_MAX_PACKET_SIZE`, inet_drv's
`tcp_recv`). While a recv waits, the socket process grants the credit its
`Length` needs, so its bytes leave the connection's receive buffer and the
window reopens, as FreeBSD's `soreceive` copies them out under
`MSG_WAITALL` and calls `pru_rcvd` before it sleeps; held in the receive
buffer, they would leave a recv near the buffer's size waiting for a last
part that the sender's silly window avoidance sends only as a persist
probe. What a waiting recv holds is the owner's domain's memory, as
stock's is the node's. A recv that times out leaves the bytes held for
the next one, as stock does. A recv still waiting when `setopts` turns
the socket active is answered `{error, einval}`, as a recv of an active
socket is; stock's driver leaves it waiting until its timeout. When the
peer's FIN leaves fewer bytes than a waiting recv asks for, the recv
answers as stock's does (`tcp_recv_closed`): `{error, closed}`, the
bytes discarded, then `{error, enotconn}` for every later recv and
`{error, closed}` for a send. In the connection, as in the reassembly
queue, a payload smaller than a quarter of its frame is copied out as it
is queued, so tiny segments do not keep their frames alive.

The packet modes (`{packet, 1|2|4}`, `line`, `http`, `http_bin` and the
rest) frame the stream in the socket process with
`erlang:decode_packet/3`, where stock frames it in its inet driver, and a
send in a packet mode gets its header there, the length's low bits as
stock writes them. The framing is one pure function,
`erx_net_packet:decode/3`, with the socket's `packet_size` and `buffer`,
as stock's driver frames: a line is looked for in the first `buffer`
bytes and cut there, a packet over `packet_size` (a line's newline
included) ends the stream with `{error, emsgsize}` where the packet would
be, and a partial packet at the end is dropped. With `packet_size` 0 a
length mode's packet is bounded at 64 MiB, the bound of stock's socket
backend (`gen_tcp_socket`'s default `packet_size`), where stock's inet
driver sets none, and a `packet_size` over 64 MiB is bounded at 64 MiB
too: documented differences, since the socket process holds at most
64 MiB. A packet in progress waits for what can change its answer, and
each push is looked at once for a waiting line's newline, so a peer that
sends a line a byte per segment costs time in its bytes, not their
square. A passive `recv(S, Length)` in a packet mode with `Length` other
than 0 is `{error, einval}`, as on stock. `buffer` defaults to the
socket's receive buffer, 64 KiB, and is kept between 1 byte and 64 MiB;
`packet_size` takes 0 to 2^32 - 1. Framing sits where the unpresented
bytes are, so a change of packet mode applies to every byte not yet
presented, as on stock: an HTTP server that reads its headers in
`http_bin` and its body in `raw` gets the body's first bytes in `raw`.
That is ERTS's C parser running on peer data in the owner's domain, as
stock runs it in every node; it has a fuzz target over every mode, and no
client's framing runs in the network domain ([Decisions](#decisions), 6).

Where stock OTP's result depends on the kernel beneath it, and the oracle
runs stock on Linux, the stack gives FreeBSD's result, and each such case
is a documented difference with a test. IPv6-only sockets by default are
one: Linux's default admits IPv4-mapped addresses, FreeBSD's does not.

### The socket process

Every socket is two processes: its socket, the connection, listener or
datagram socket in the network domain, and its socket process, a
`gen_statem` of `erx_gen_tcp` or `erx_gen_udp` in the owner's domain, the
same shape as stock OTP's `gen_tcp_socket` (`gen_tcp_socket.erl:1565`).
The construction is one rule:

**The socket process is the only party that talks to the socket, and the
only party that talks to the owner about it.** Every request reaches the
socket process as a local call and is sent on by it; every reply and push
comes back to it, on the one lane from the network domain to its domain;
and it alone sends the owner the socket's messages, built from checked
parts.

**Where the client half lives.** A socket's client half (its owner,
active mode and framing, the bytes pushed and not yet presented, its
credit and the calls waiting on it) lives in the socket process and
nowhere else. It needs a process of the owner's domain that is neither
the owner nor the socket:

* any process of the domain may call a socket it knows, as on stock, and
  an owner's code serves no calls;
* in active mode the owner's `receive {tcp, S, Data}` must match a
  message made in its own domain, since every message from the network
  domain arrives as `{erx_origin, D, Msg}` and only a protocol's owner
  takes the envelope off (D18 of
  [design-domains.md](design-domains.md#invariants));
* a passive owner, often a `gen_server`, takes whatever reaches its
  mailbox, so pushes may go only to a process that expects them.

The socket cannot hold the client half either: across domains its active
mode would still need a process of the owner's domain to take the
envelope off, a passive `recv` would cross the lane twice instead of being
a local call, and framing would run on a client's peer data in the
network domain ([Decisions](#decisions), 6). So the socket process is
erXos's counterpart of stock's inet port, and its hop is the price of that
port being a process
([Alternatives considered](#alternatives-considered)). The protocol
removes every other message on the data path: no transfer of bytes, in
either direction, is answered, because each side sends bytes only within
credit the other granted (**Credit, both ways**).

The socket protocol is a closed set of shapes, each
`{erx_net, Sender, Body}` with `Sender` the sending pid:

```erlang
%% Socket process to socket.
-type request_body() ::
      {call, N :: non_neg_integer(), Request :: erx_net_admit:request()}
    | {send, Piece :: binary()}             % a connection's bytes, within the
                                            % send credit it granted; never
                                            % answered
    | {credit, Bytes :: pos_integer()}.     % receive credit, for every kind
                                            % of socket

%% Socket to socket process.
-type push_body() ::
      {reply, N :: non_neg_integer(), Result :: term()}
    | {credit, Bytes :: pos_integer()}      % a connection's send credit:
                                            % room in its send buffer
    | {data, [binary()]}                    % in-order bytes, the receive queue's
                                            % pieces as they are: at most 64 binaries
                                            % and at most a piece in all
    | {datagram, inet:ip_address(), inet:port_number(), binary()}
                                            % one whole datagram
    | {echo, inet:ip_address(), Ttl :: 0..255, Seq :: 0..65535, binary()}
                                            % one echo reply, an echo
                                            % socket's only push
    | eof                                   % the peer's FIN, after every byte
    | {error, erx_sock_admit:end_reason()}. % the socket has ended; its last push
```

`N` counts the socket process's calls, so a reply names its call and
calls answer in any order. The socket process never waits for its
socket: it sends a call, keeps the caller's `From` under `N` and goes on
taking pushes and calls, and a `send` waiting for credit waits in the
socket process. So an owner in active mode receives data while its own
`send` waits, as with stock's inet driver, and a `close` or `shutdown`
never waits behind it; two peers that both send before they read would
otherwise deadlock on each other's full windows. Concurrent callers wait
in the socket process, never at the funnel
([Requests in flight](#requests-in-flight)).

**The socket process never suspends.** Its callers and owner wait on it,
so nothing may stop it running, and the one thing that could is its own
traffic to the network domain. Once a domain's queue for a lane has passed
the busy limit, 1 MiB, ERTS suspends a process that sends to that domain
([design-domains.md](design-domains.md#flow-control)), and one that
links to, monitors or demonitors a process there, after queuing the
signal (`link/1`, `monitor/2` and `demonitor/1` pass `no_suspend` 0,
`bif.c:334`, `:909`, `:607`; the send's last phase suspends while the
entry is busy, `dist.c:3824-3842`). A network domain that stops draining
its lane would then freeze every socket process of that client, and one
socket's bulk send would hold up another's `close`. Three rules take every
such site away:

* **It is spawned with `{async_dist, false}`,** whatever its runtime's
  default. ERTS skips the busy check for a process with `async_dist`, so
  its `nosuspend` sends are never refused and its frames pass the busy
  limit (`dist.c:3412-3419`), and `+pad true` gives the flag to every
  process (`erl_init.c:1382`, `erl_process.c:12458`). Every socket process
  is started through `erx_sock_out:start/2`, which passes the option in
  its `spawn_opt`, and no module of the socket process calls
  `process_flag(async_dist, _)`.
* **It sends to its socket only through `erx_sock_out:send/2`,** which
  uses `erlang:send/3` with `[nosuspend, notify]` and answers `ok` once
  the frame is queued or `refused`, queuing nothing, while the queue is
  busy, as stock refuses a `nosuspend` send (`dist.c:3417-3419`). With
  `notify` the runtime then sends `{erx_lane_ready, Node}`, once, when the
  queue stops being busy or the connection ends (edit 67 of
  [design-runtime.md](design-runtime.md#connections-in-erts)). Within one
  domain, `Origin` `local`, the outlet sends plainly: a send within a
  runtime never suspends.
* **It makes no link, monitor or call towards the network domain once it
  holds its socket.** The socket links to it, with the `send` and `link`
  rights the socket process gives the network domain as it starts
  (`expose/2`, [Two places, four seams](#two-places-four-seams)), and it
  traps exits first, so the socket's exit reaches it as a message
  whatever ended the socket, the network domain's end arriving as
  `noconnection`. Its one call towards the network domain is the open,
  before it has a socket whose traffic could wait behind it.

A build check holds all three: only `erx_sock_out` starts a socket
process, and only it sends, links, monitors or calls in the socket
process's modules, none of which sets `async_dist`
([Build checks](#build-checks)), so the property rests on one module.

**What a refusal leaves where.** The pure core answers the next message
to send, or none, from what it holds: a call waiting for a place, receive
credit the half-target rule makes due, or the next piece the waiting
send's credit allows. The shell sends it; on `ok` it keeps the core's new
state and asks again, and on `refused` it keeps the old state, marks the
lane refused and sends nothing more until the notification. So a refused
item stays where items already wait and no queue of refused messages
exists: a refused piece stays in its `send`'s data with its credit
unspent, a refused call stays in the waiting-call queue and takes no place
in flight, and refused receive credit stays a shortfall, so the next grant
carries all of it in one message. While refused, the socket process goes
on presenting data, answering locally, meeting deadlines and stopping
when its owner exits. Nothing is sent twice, a send's bytes go in order
because one send sends at a time, and a `shutdown` is a call offered only
after the bytes of every answered send. An unasked `{erx_lane_ready,
Node}` can come only from its own domain, since a message from another
domain arrives in its envelope; it costs one more attempt.

**What waits for an undrained lane.** The client's queue for the network
domain is bounded as every queue for a peer is (D12 of
[design-domains.md](design-domains.md#invariants)): the busy limit plus
one frame for each process caught between ERTS's busy check, which reads
the flag without the queue's lock (`dist.c:3418`), and its enqueue, which
queues the whole frame (`dist.c:3765-3771`, `:3786`); a send can yield
between the two while it encodes (`bif.c:2479-2481`,
`dist.c:3727-3728`). A socket process is one process, so its share past
the limit is one frame. Everything else waits in the socket process, so a
network domain that stops draining makes a client hold the callers' own
data, their waiting calls and one count of receive credit per socket, and
nothing for its grants or answers: credit is granted only as the lane
takes it, a reply (forged or not) frees a place but the next call still
waits for the lane, and send credit only lets callers' own bytes go as
fast as the lane takes them. While stalled, a `send` that fits its credit
is answered `ok` once its last piece is queued, as FreeBSD answers a
`send` whose bytes are in a send buffer a stalled network never drains; a
waiting `send` meets its `send_timeout`; `close/1` is answered; and the
socket process stops when its owner exits. ERTS takes an exiting process
out of its table and fires its local links and monitors before it sends
any signal to another domain (`erl_process.c:14150-14166`,
`:14370-14373`), so callers and owner see it gone at once and only its
exit signal to the socket waits, behind every frame it sent.

**What a queued piece keeps alive.** ERTS's encoder puts a sub-binary's
whole underlying binary into the frame (`external.c:3974`, `:4204`), so a
queued piece would keep all of its send's binary alive for as long as the
lane stalls. So every piece is a binary of its own size: a piece cut from
a larger binary (by `binary:referenced_byte_size/1`) is copied with
`binary:copy/1`, and iodata is joined a piece at a time, so each byte is
copied at most once. A stalled lane then keeps exactly what the queue
bound counts, whatever the callers sent and however each send ended. The
copy costs one pass over a send cut from larger binaries; the watch list
holds its cost to a bulk send ([todo-performance.md](todo-performance.md)).

**Opening.** Opening is the one exchange outside the socket protocol. The
opener, the process that calls `gen_tcp:connect`, `gen_tcp:listen` or
`gen_udp:open` and the socket's owner, starts the socket process, which
exposes itself to the grant's domain and calls the grant itself, a facet
([design-domains.md](design-domains.md#facets)), through
`erx_inet:open/1`. The request names no process: the grant takes its
caller as the socket process, as it takes the caller of every request as
the owner of what it opens, so no request can name a process of another
domain, or of none, to receive a socket. The grant starts the socket,
which links to its caller before the grant answers. This call may suspend
behind an undrained lane, while its opener waits anyway. The answer,
`{ok, Socket}`, passes `erx_sock_admit` as every message from the network
domain does ([Untrusted input](#untrusted-input)): `Socket` must be a pid
of the grant's own node, so a network domain that names a process of a
third domain is refused with `{error, badarg}`, and every later push check
compares against a pid the network domain owns. A socket process that has
died by then makes the link answer `noproc`, and the socket ends.

**Nothing crosses before the first contact.** The network domain knows
the socket process's pid from the open request on, so it could push or
exit to it before the socket process knows its socket; anything kept for
later would be held outside the credit that bounds every push. So:

* a socket sends its socket process nothing, no push and no credit, until
  it has taken that process's first message, sent only once it holds its
  socket: a connection's or datagram socket's first receive credit, or a
  listener's first `accept`; a socket that ends before then ends by its
  exit alone;
* in `opening` the socket process takes the hand-over and the deaths of
  its owner and of the listener's socket process that started it, and
  postpones only calls of its own domain;
* anything from the network domain in `opening` ends the opening: the
  socket process stops with `econnaborted`, the open answers
  `{error, econnaborted}`, and a living socket takes the exit and closes.
  A correct network domain sends nothing there but the exit of a socket
  that ended before its first contact, which fails as an aborted
  connection does (FreeBSD's `accept` answers `ECONNABORTED`).

The first contact costs a connection's first send one lane round trip
after the open returns; the watch list holds that wait
([todo-performance.md](todo-performance.md)).

**States.** `opening` until it holds its socket (above), or until its
opener stops it on a refused open; `open` for a
connection or datagram socket and `listening` for a listener, taking
every call, push and exit; `closed` once the socket is gone, holding the
bytes and the end not yet shown, which wait for a passive owner's `recv`
(or a `setopts` that makes it active), with `close/1` and the owner's
exit stopping it and every other call answered as stock's closed socket
does; and `{transfer, NewOwner, State}` during `controlling_process/2`.
In every state a message that is no call, push or exit it expects is
dropped and counted. The state is the effect shell's; what is presented, granted and replied
is decided by a pure step, `erx_gen_tcp_core:step(Event, Core) ->
{Core, [Action]}` and its datagram twin, whose actions are messages to
the owner, replies, requests and grants to the socket, and
`{stop, normal}`, always last ([One owner, one step](#one-owner-one-step)).
The core reads no clock; the socket process arms a named `gen_statem`
timeout for each deadline it holds (a waiting recv's, each waiting
send's). The deadlines of `connect` and `accept` are not its own: the
opener passes `connect`'s timeout to the grant, the listener's socket
process passes `accept`'s to the listener, and both run on the stack's
clock. The host runs' virtual clock ([The clock](#the-clock)) does not
reach these timers, so those runs set no recv or send timeout. A timer's
expiry is taken in order behind the pushes already in the mailbox, so a
recv whose deadline passes behind a backlog is answered with those bytes
if they complete it, and otherwise `{error, timeout}`, late by the time
they take, and a send whose deadline passes behind a grant of credit
sends what the grant allows before its deadline is taken; stock's driver
takes its input in order too.

**Ending.** At `eof` with `exit_on_close` true, the default, an active
socket process presents what it holds, then `{tcp_closed, S}`, sends
`close` and moves to `closed`. In passive mode, whether chosen or because
an active count ran out, the end waits for the owner, as in stock's inet
driver, which meets the FIN only when it reads: the socket stays `open`
and its sends go on until a recv that what is held cannot complete is
answered `{error, closed}` (`tcp_recv_closed`), later recvs
`{error, enotconn}`, or the owner turns the socket active and is shown
what is held and `{tcp_closed, S}`. With `exit_on_close` false it stays
`open`, its reads answer as closed and its sends go on.

At `{error, Reason}` or its socket's exit the socket is gone: the socket
process sends `close`, moves to `closed` and answers every call it holds
`{error, closed}`, except the first send waiting for credit (**Send
credit**). An exit from any other process is dropped and counted: only
its socket is linked to it, and a domain that runs the stack itself, a
development host among them, cannot tell the stack's processes from its
own by node, so the exit of a listener that ended between answering an
`accept` and its unlink must not end the accepted socket. In active mode
it presents what it holds, then `{tcp_error, S, Reason}` where stock
shows the reason (`econnreset` only under `show_econnreset`) and
`{tcp_closed, S}`; in passive mode the end waits for the owner and the
first recv that cannot complete gets the error. The owner is shown the
first end only: after `eof` the stream is whole, and a later end means
only that the socket is gone. A socket that exits without a last push, killed or ended
with its domain, is taken as `{error, econnaborted}`; a push after the
socket process has closed is ignored.

**Accepting.** A listener's socket process enters `listening` and sends
nothing until its first `accept`. `gen_tcp:accept/1` (timeout `infinity`)
and `accept/2` call it; it starts a socket process for the caller, owned
by it with the listening socket's presentation options, and sends the
listener `{accept, SockProc, Timeout}`. The listener binds the connection
to that socket process, and the connection links to it, before the
listener answers ([The listener](#the-listener)); the listener's socket
process hands the new one its socket and answers the caller, or on an
error or timeout stops the new socket process and answers the error. The
listener answers every `accept` exactly once, its acceptor's end
included, and its own end answers the rest `{error, closed}`, so an
`accept` whose caller has gone still leaves the calls in flight. Many
callers may accept at once, as ranch's acceptors do, each under its own
`N`. The new connection pushes nothing until its socket process's first
receive credit; one that ends before then stops the new socket process
in `opening`, and the `accept` is answered `{error, econnaborted}`.
`controlling_process/2` moves a listening socket's owner as any socket's;
each accepted socket keeps the owner its `accept` gave it.

**Ordering.** One lane carries everything between a socket and its socket
process, in send order (D9 of
[design-domains.md](design-domains.md#invariants)), the socket's exit
included, and the socket process is the one sender to the owner and the
one replier. So the owner sees the socket's messages and its replies in
the order the socket process made them: nothing is presented after the
reply to `inet:setopts(S, [{active, false}])`, and a push that arrived
before a reply is presented before it. No program holds a socket's pid,
so nothing overtakes the socket process. A connection's bytes, its
`shutdown` and the exit that `close/1` brings travel the same lane in
order, so the bytes of a `send` answered before a `shutdown(S, write)` or
`close/1` reach the send buffer before the FIN: a send is answered only
once its last piece is queued.

**The protocol's owner.** Every push from another domain arrives as
`{erx_origin, D, {erx_net, Socket, Body}}`
([design-domains.md](design-domains.md#the-peer)), and the socket process
alone takes that envelope off, through `erx_sock_admit`, for its own
shapes only, when `D` is the origin its grant's domain was found with
([Two places, four seams](#two-places-four-seams)), `local` meaning bare
messages, and `Socket` is its own socket. A message that fails either
test is dropped and counted as unknown; one from its socket that breaks
the protocol aborts the socket ([Untrusted input](#untrusted-input)). It
is started without `{erx_serve, any}`, so a call from another domain is
an unknown message too, and the stub refuses a socket used from another
domain with `{error, einval}` by comparing nodes. The stack is erXos's own
application, outside D18's source check over OTP's modules, so the
stack's own build check names `erx_sock_admit` and `erx_net_admit` as the
only modules of its two applications that match `erx_origin`
([Build checks](#build-checks)).

**controlling_process.** The owner is known only to the socket process,
so moving a socket is local, as in `gen_tcp_socket`
(`gen_tcp_socket.erl:686-711`, `:1874-1910`): the owner's first call
moves the socket process to `{transfer, NewOwner, State}`; the stub moves
the socket's messages already in the caller's mailbox to the new owner;
the second call switches the owner's monitor and leaves the state, and
what arrived meanwhile is presented in order. During the transfer every
push is admitted, counted against the credit and stepped as in `State`
with presentation held, as in passive mode, so its grants stop when the
target is full; an end, an abort and a send's deadline are taken as in
`State`, and the other calls of its own domain are postponed until the
owner's second call or its exit. Nothing from the network domain is
postponed, so a transfer never finished holds no more than a
passive socket. A new owner of another domain is refused with
`{error, badarg}`, as stock's `port_connect` refuses a process of another
node, so a socket never has an owner outside its socket process's domain.

**The owner's exit, `close/1` and the socket process's exit** end at the
same place. When the owner exits, the socket process stops. At `close/1`
it answers every call it holds as stock's closed socket does, answers
`ok` and stops, so `close/1` never waits for the lane. However the socket
process stops, its socket takes the exit through their link and closes as
`close/1` asks: a connection sends FIN, or RST under a zero `linger`, and
goes on to TIME-WAIT without a caller. When the client's domain ends, the
exit arrives as `noconnection` and the grant's end follows
([What fails and what survives](#what-fails-and-what-survives)). A call
in flight leaves its socket to answer a dead pid, which the funnel drops.
The exit signal travels behind every frame the socket process sent
([design-domains.md](design-domains.md#links-monitors-and-exits)), so
bytes sent within credit reach the send buffer before the FIN; bytes of
sends still waiting for credit go with the socket process, and their
callers get `{error, closed}`.

**Credit, both ways.** Bytes cross between a socket and its socket
process only within credit, in bytes, that the receiving side granted,
and no transfer of bytes is answered. Receive credit flows from the
socket process to its socket, for every kind of socket; send credit from
a connection to its socket process.

**Receive credit.** The socket pushes only within the credit it holds, at
most a piece per push ([Message sizes](#message-sizes)), a datagram whole
and only when the credit covers its cost, and keeps the rest: a
connection in its receive buffer, whose free space is its window, a
datagram socket in its queue up to its receive buffer, past which it
drops and counts, as FreeBSD drops on a full receive buffer. The socket
process keeps what it holds plus the credit outstanding at its target:
its `buffer` option, stock `inet`'s user-level buffer, defaulting to the
socket's receive buffer and for a datagram socket never less than
128 KiB. A waiting `recv(S, Length)`, or a packet whose header announces
more, raises the target to what it needs, up to 64 MiB or `packet_size`;
a partial line needs one byte more than is held, up to the buffer. The
shortfall (target less held less outstanding) is granted when it reaches
half the target, one message per half target received, and at once when
a waiting `recv` or packet in progress needs more than is held and
outstanding, so no recv waits for bytes its socket holds but may not push.

A datagram costs its length in credit, an empty one one byte, on both
sides (`max(1, byte_size(Data))`), so a flood of empty datagrams spends
credit as any other and is held to one credit message per half target,
65,536 empty datagrams by default. Between grants, held plus outstanding
stays above half the target; a datagram socket's 128 KiB floor, twice the
largest UDP payload of 65,527 bytes, makes that enough for any datagram,
so none waits in its socket while the socket process holds nothing. In
passive mode a datagram socket thus holds up to its receive buffer in the
network domain and its socket process up to its target, where stock reads
one datagram per recv from the kernel's buffer: a departure of at most the
target per socket, 128 KiB by default, in the owner's own memory, for the
lane crossing a read per recv would cost. So:

* in `{active, true}` each push is presented at once and credit follows
  the half-target rule; the lane paces the pushes, and the owner's
  mailbox is bounded only by how fast it reads, as on stock;
* in `{active, once}` after one delivery, and in `{active, N}` when the
  count runs out, presentation stops (`{tcp_passive, S}` or
  `{udp_passive, S}` for a count only, as stock); what arrives fills the
  target, grants stop and the connection's window closes, as stock's
  socket stops reading the kernel's buffer. `inet:setopts(S,
  [{active, N}])` is answered locally and presents what is held, so an
  owner that re-arms after every packet, as cowboy may, costs no message
  to the network domain;
* in passive mode a recv is answered from what is held, a local call.

A connection therefore holds at most its receive buffer in the network
domain, whatever its owner does, and its socket process at most its
target, in the owner's own memory.

**Send credit** is the same rule turned round. The connection grants
credit in bytes, room in its send buffer, and the socket process sends
`{send, Piece}` only within it. Three counts decide every grant: the high
watermark, FreeBSD's `sb_hiwat`, which `sndbuf` and autosizing set; the
bytes the send buffer holds; and the credit outstanding, granted and not
yet spent by an arrived piece.

**A buffer never shrinks below what it has promised.** The send buffer's
size, the room its grant reserves, is the larger of the high watermark
and the bytes held plus the credit outstanding. The high watermark rises
only after the grant has reserved the growth
([The TCP core](#the-tcp-core)). A `sndbuf` that shrinks it lowers the
high watermark at once and the size only as the peer acknowledges bytes
and pieces spend credit, each step releasing the difference at the grant.
So credit already granted is neither stranded nor uncharged, and a client
that shrinks a buffer and grows it again escapes no charge. FreeBSD's
`sbreserve` lowers `sb_hiwat` the same way and leaves the bytes already in
the buffer (`uipc_sockbuf.c`); keeping the size for the reservation is
what makes that safe where the grant's limit is finite.

**The grant rule.** The shortfall is the high watermark less the bytes
held and the credit outstanding, when positive. After each step the
connection grants it:

1. when it reaches half the high watermark, so a bulk send costs one
   credit message per half buffer acknowledged, and a fresh connection's
   first push, which follows its socket process's first receive credit,
   grants its whole high watermark;
2. or when no credit is outstanding and no awaited acknowledgement will
   free room, whatever the shortfall: every byte sent is acknowledged
   (`snd_una` equal to `snd_max`), or the peer offers a zero window
   (`snd_wnd` of 0).

The rule is a pure function of the three counts and those two
comparisons. The second clause is its progress rule: the socket process
spends all its credit whenever a send waits, so a connection with none
outstanding may have sends waiting. In an open window, an acknowledgement
or the retransmission timer brings another step, so a waiting send gets
credit when the peer has acknowledged half the buffer or everything,
whichever comes first, or the connection ends. In a zero window FreeBSD's
probe sends a byte past the window that the peer acknowledges without
taking (`tcp_output.c`'s `TF_FORCEDATA`, `erx_tcp_output.erl`), so
`snd_una` stays below `snd_max` until the window opens; the second clause
counts that state as idle. Without it a full buffer behind a zero window,
with `sndbuf` then raised by less than half the buffer, or a peer that
acknowledges a quarter of a full buffer and then closes its window, would
leave room ungranted and a one-byte `send` waiting for room the buffer
has. While credit is outstanding the second clause does not apply, so a
request-reply exchange costs no credit message; its requests cost one per
half buffer they add up to.

The socket process sends a `send` call's data in order through the
outlet, in pieces cut also where its credit ends, waits with the rest for
the next grant or the lane, and answers the caller once the last byte is
queued. So `gen_tcp:send/2` returns once its data is in the socket's send
buffer, as FreeBSD's `send` does, where that buffer spans the
connection's buffer and its socket process's credit. This is FreeBSD's own
division: `sosend` waits in the socket layer until `sbspace` has room and
hands `tcp_usr_send` only what fits, and `tcp_usr_send` never waits
(`uipc_socket.c`, `tcp_usrreq.c`). The socket process is that socket
layer, and send credit is `sbspace` carried across the lane. So:

* a `send` that fits its credit is answered after one local round trip,
  and its bytes cross the lane once, with no reply;
* a bulk send keeps up to a send buffer of pieces in flight, at one credit
  message per half buffer;
* the connection holds no byte beyond its buffer's size, which its
  reservation at the grant covers, and no `send` waits in the network
  domain;
* bytes past the send credit, or after the socket process has sent the
  connection `shutdown` of its write side or `close`, break the protocol:
  the connection counts the break, aborts with a RST and pushes
  `{error, econnaborted}`; only a socket process that breaks the protocol
  meets it;
* a grant that would take the credit outstanding past 2 MiB, more than the
  largest send buffer `sbreserve` allows (`sb_max_adj`, about 1.78 MiB),
  breaks the protocol the other way, and the socket process aborts the
  socket. The check keeps a hostile count from growing without end; the
  outlet, not it, bounds the client's queue;
* bytes that reach a connection that has already ended are dropped with
  it, their `send` answered `ok`: the race of a `write` with a RST on
  FreeBSD, and the owner meets the error at its next call or as the end.

What a waiting `send` meets follows OTP's socket backend,
`gen_tcp_socket`:

* **Its deadline** starts when the socket process takes the call, from
  the `send_timeout` in force then, which also fixes `send_timeout_close`
  and the packet header for that send, as `gen_tcp_socket:send/2` reads
  them once (`gen_tcp_socket.erl:557-582`). A send waiting behind another
  counts from its own call. The deadline is the send's, not the owner's:
  `controlling_process` moves neither, and a deadline that passes during
  a transfer is taken then, in order behind the pushes before it. A
  `setopts` made while a send waits applies from the next send.
* **The deadline passes.** With `send_timeout_close` false the send is
  answered `{error, {timeout, Rest}}`, `Rest` the bytes not yet sent, its
  packet header included when none went. They never reach the
  connection, so the stream holds exactly what was sent before them, and
  the caller can finish a partial packet by sending `Rest`
  in `raw` mode, as OTP's documentation of `gen_tcp:send/2` and its
  `otp_7816` case do (`gen_tcp_misc_SUITE.erl:7887-7911`). With
  `send_timeout_close` true it is answered `{error, timeout}`, and the
  socket process sends `close` behind the bytes already sent and moves to
  `closed` (`gen_tcp_socket.erl:583-618`).
* **The write side is shut.** A send waiting when `shutdown(S, write)` or
  `shutdown(S, read_write)` is made, or called after it, is answered as
  the socket backend answers `EPIPE`: `{error, closed}`, or
  `{error, econnreset}` under `show_econnreset`, and the socket then
  closes (`gen_tcp_socket.erl:932-933`, `:2739-2792`); stock's inet
  driver answers `{error, closed}` and closes too (`tcp_send_error`). No
  byte follows the `shutdown`, so none breaks the protocol.
* **`close/1`.** Every waiting send is answered `{error, closed}`, its
  rest dropped, and the socket process stops; bytes already sent reach
  the send buffer before the FIN.
* **The end.** One send is shown the end's reason, curated as
  `gen_tcp_socket` curates it (`curated_error_reason`,
  `gen_tcp_socket.erl:2777-2792`): a reset, an abort or a broken pipe as
  `econnreset` under `show_econnreset` and `closed` without it, any other
  reason (`etimedout`) as it is. That send is the first waiting; when none
  waits, the reason is kept for the first send after it while the owner
  has not been shown the end, as in the socket backend
  (`econnreset_after_sync_send`, `gen_tcp_misc_SUITE.erl:2242`). Every
  other send is answered `{error, closed}`, as the backend's first writer
  closes the socket (`handle_send_error`, `gen_tcp_socket.erl:2739-2770`)
  and later writers meet `handle_closed` (`:2170-2189`).

**Which stock send this is.** OTP 29.1.2's two `gen_tcp` backends differ.
The inet driver writes what the kernel takes, queues the rest and answers
at once, holding a later sender only past `high_watermark`, and a send it
times out is answered `{error, timeout}` with its data still queued
(`tcp_sendv`, `tcp_inet_send_timeout` in `inet_drv.c`). The socket
backend's send waits until the kernel has taken all of it and returns the
rest at its timeout. erXos matches the socket backend for two reasons. An
`erx` socket is not a port, and OTP's own suites, which
`make check-oracle` compares with stock, expect the socket backend's
results from every socket that is not a port (`otp_7816`,
`gen_tcp_misc_SUITE.erl:7862-7911`; the `econnreset_after_async_send`
cases, `:2862-2918`, expect a 1 MiB send to a peer that does not read to
wait and fail with the reset). And a send answered only once its bytes
are in the send buffer needs no queue beyond it, so `close` and
`shutdown` wait for no bytes ahead of them. A program written for the
inet driver that matches `{error, timeout}` with `send_timeout_close`
false meets `{error, {timeout, Rest}}`, a documented result of
`gen_tcp:send/2` (`gen_tcp.erl:883`): a documented difference with a test.

A datagram socket and an echo socket take no send credit: each send is a
call answered with its outcome, since a datagram's send has an outcome of
its own that FreeBSD's `sendto` returns at once (no route, no source
address, a full transmit queue), while a stream's bytes have no outcome
but the stream's end. Against a reply per piece, send credit trades a
counter on each side, a two-clause grant rule and a reserved size for
the send's reply, the one-send-in-flight rule and the connection's
waiting writer, and puts the waiting where FreeBSD keeps it, in the
socket layer.

**What it costs.** One local message per delivery and a local round trip
per call; a payload of 64 bytes or more crosses that hop by reference.
Across the lane, one message per piece and per push, a receive credit
message per half target, a send credit message per half send buffer
acknowledged (one more when a stalled peer leaves less than half free),
and a socket process per socket, about the size of stock's
`gen_tcp_socket` process, in the owner's domain. A request-reply exchange
costs four local messages and one lane crossing each way; a passive
`recv`, a `setopts` of active mode and `controlling_process` cost no lane
crossing. A refused send costs one `nosuspend` attempt and one
notification. The local hop is measured within one domain
([Alternatives considered](#alternatives-considered)); across domains the
watch list holds the measurement ([todo-performance.md](todo-performance.md)).

**What it needs from the runtime.** Pid exports: the socket's pid
reaches the socket process in the grant's reply, exported with `send` by
appearing in a frame, and the socket process gives the network domain
`[send, link]` on itself with `erx:export/3` before its pid appears in the
open request ([design-domains.md](design-domains.md#exports)); replies
name calls by the integer `N`, and credit is an integer. Calls to the
grant, whose replies go to the caller's alias and reach another domain
only through the four-word references and alias registry of
[design-runtime.md](design-runtime.md#unguessable-references). And the
refusing send with its notification, `erlang:send/3` with
`[nosuspend, notify]`, edit 67 of
[design-runtime.md](design-runtime.md#connections-in-erts), whose refusal
is stock ERTS's and whose notification is the one change.

#### Message sizes

One constant bounds the bytes any socket-protocol message carries: the
**piece**, 64 KiB.

* A push carries at most a piece. A connection pushes credited in-order
  bytes as `{data, Pieces}`, each a flat list of the receive queue's
  binaries as they are, at most 64 and at most a piece in all; the count
  bounds the list's encoding, 5 bytes a binary, so one-byte segments
  cannot grow a push's frame past its piece and header. A datagram is one
  push, since a UDP payload is at most 65,527 bytes.
* A request carries at most a piece: a `send`'s data is cut into pieces
  (**Send credit**). A UDP payload or an echo request's data over 65,507
  bytes, the most an IPv4 datagram carries after its headers, is refused
  with `{error, emsgsize}` before anything is sent. The protocol's bounds,
  which `erx_net_admit` and `erx_sock_admit` check, are 65,527 bytes for a
  datagram, what the UDP length field allows under any IP version, and
  65,507 for an echo's data.
* Every other request and reply is bounded by the operation schema,
  `abi/services/net.txt`: option-list lengths and
  each reply's shape. The socket process checks each request with the
  validators generated from it before sending, and answers one the
  network domain would refuse as it would, so no correct client's request
  is over a limit. Every atom the protocol carries is named by the schema
  and mentioned by `erx_sock_admit`, so none is new to a receiver's atom
  table.

Every socket-protocol frame is therefore at most a piece plus a header
under 1 KiB. The grant's replies are bounded by the same schema; the
largest, an `interfaces` reply of 64 interfaces with 64 IPv6 addresses
each, carries more than 168 KiB in its addresses alone. A frame on a lane
([design-domains.md](design-domains.md#data-model),
[the funnel](design-domains.md#the-funnel)) meets the sender's
`ERX_FRAME_MAX`, 16 MiB, past which the send fails with `system_limit`,
and the receiver's funnel limits, past which the frame is dropped and
counted: `max_frame` on the payload's bytes (1 MiB by default),
`max_message_heap` on the decoded size (8 MiB by default) and
`funnel_depth` on nesting outside tail positions (16,384 by default),
each set by the receiver's own runtime, and, for a message to the grant
or a socket, the grant's `max_request`, which the network domain's
specification names, checked before it is queued. In a domain that holds `net`, and in the
network domain, each is at least the protocol's floor, below.

The decoded-size limits count a binary over 64 bytes as the few words of
its reference (`liberx/erx_etf.c`), so a piece's bytes meet only
`max_frame`, and the schema bounds the rest. A frame is read as its bytes
arrive and never fragmented, so `max_frame` is its only bound on length.

**Every limit has a floor.** A correct frame dropped by any of these
limits does harm: a dropped push loses stream bytes and strands its
credit, so the socket never pushes again; a dropped `{send, Piece}` loses
bytes with no error; a dropped grant reply leaves its caller waiting for
good. So the protocol has one floor per funnel limit, and every receiver
runs at or above all of them. The generator that makes `erx_net_admit`
and `erx_sock_admit` from `abi/services/net.txt` computes the floors from
the schema, as it computes `max_request`: per operation, the largest
frame, decoded size and nesting of any message it carries each way, and
for an open every push and request of the socket it opens, each rounded
up to a power of two; a receiver's floor is the largest over the
operations it takes part in. The generator fails the build when a floor
passes the limit's default, so the schema cannot grow a reply a domain
with default limits would drop. Paging the `interfaces` reply would add a
continuation to the grant and a loop to every caller, for a reply the
default `max_frame` already carries. Each floor is checked where the
receiver's limits are known:

* **a client's, in the client, before anything is sent.** `erx_inet`,
  the one path to the grant, compares the operation's floors with its own
  runtime's `max_frame`, `max_message_heap` and `funnel_depth`, as
  `erx:limits/0` reports them
  ([design-domains.md](design-domains.md#erlang-interface)); with
  `Origin` `local` no frame crosses a funnel. An operation whose floor the
  client does not meet is answered `{error, enobufs}` by `erx_inet` with
  no remote call, and the first such answer per operation logs one line
  naming the operation, the limit, its value and the floor. An open's
  floors cover every push and request of its socket, so no socket exists
  whose pushes its own funnel would drop. A domain configured below a
  floor fails loudly at its first use of what it cannot carry, never with
  the silent hang of a dropped push or reply. The grant checks nothing for
  the client: a client that skips the check drops only its own replies;
* **the network domain's own, in the system manifest.** Its `max_frame`,
  `max_message_heap`, `funnel_depth` and the `max_request` its grants name
  are fields of its specification, and the manifest's build check
  compares each with its floor, so a network domain that would drop a
  correct socket process's frame does not build.

`erx_sock_admit` refuses a push longer than a piece, or of more than 64
binaries, as it refuses one past the credit: the socket is aborted. A
connection holds no byte beyond its send buffer's size, so its
reservation at the grant covers everything its socket process can send
it. A datagram socket's send is a lane round trip per datagram, which the
watch list holds ([todo-performance.md](todo-performance.md)).

#### Requests in flight

A socket process has at most 64 calls in flight to its socket, the
protocol's limit; a connection's bytes are not calls. A call is in flight
once the outlet has queued it. A 65th call, or one the outlet refuses,
waits in the socket process in arrival order until a reply frees a place
and the lane takes it, as stock's port holds a caller while busy; none is
dropped. So the waiting-call queue, not the count of places, holds calls
back from an undrained lane, and an early reply, forged or not, queues
nothing more. Two kinds of call also wait behind their own kind:

* a `send` waits for the `send` before it, so two sends' bytes never
  interleave, as stock's driver takes one send at a time; its deadline
  counts from its own call;
* a passive `recv` waits for the `recv` before it, as `gen_tcp_socket`
  postpones a second one (`gen_tcp_socket.erl:2100-2105`), and a `recv` on
  an active socket answers `{error, einval}`, as there.

Every other call, `shutdown` among them, goes out as soon as it has a
place and the lane takes it, so it never waits behind a send waiting for
credit. A call that waited for a place takes its timeout from when its
request is sent. Of the calls with a timeout only `accept` can wait so,
on a listener with more than 64 concurrent acceptors; this difference
from stock has a test. When the socket ends, every waiting call is
answered as stock's closed socket answers it.

The socket enforces the same limits: past 64 calls in flight it refuses
with `{error, badarg}`, and a connection aborts on bytes past its send
credit, both met only by a socket process that breaks the protocol. What
a client domain can make one socket hold is therefore 64 calls within the
schema's bounds and, for a connection, the bytes of its send credit,
which its send buffer's reservation covers.

### Options

| Options | Where they act |
| --- | --- |
| `nodelay`, `keepalive`, `linger`, `sndbuf`, `recbuf`, `tos`, `tclass`, `priority`, `reuseaddr`, `reuseport`, `ipv6_v6only`, `high_watermark`, `low_watermark`, `{congestion, Name}`, `{loss, Name}`, the `raw` options FreeBSD's `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, `TCP_KEEPCNT` and `TCP_MAXSEG` map to | the socket's state, read by its step |
| `active`, `mode`, `binary`, `list`, `header`, `packet`, `packet_size`, `line_delimiter`, `deliver`, `buffer`, `exit_on_close`, `show_econnreset`, `send_timeout`, `send_timeout_close` | the socket process: how it presents data to its owner, its credit, and how long a `send` waits for send credit |
| `broadcast`, `multicast_*`, `add_membership`, `drop_membership` | `broadcast` acts; the multicast options act through `erx_mcast` ([Scope](#scope)) |
| `fd`, `netns`, `bind_to_device`, other `raw` options | `{error, enotsup}` |

`inet:setopts/2` with options of both kinds sends the socket's to the
socket and applies the socket process's own only once the socket has
accepted the rest, so a refused `setopts` changes nothing;
`inet:getopts/2` answers the socket process's own and asks the socket
for the rest, in the order asked. On a listening socket the socket's
options are the listener's, which pass to the connections it accepts
from then on ([The listener](#the-listener), **Its entry**), and the
socket process's own pass to the socket processes it starts for later
`accept` calls.

**Statistics.** `inet:getstat/1,2` is answered by the socket process
from what it counts, as stock's inet driver counts at its port
(`inet_drv.c`, `inet_input_count` and `inet_output_count`): the socket
process stands where the driver stands, between the owner and the
stream, so the counts are the client half's and need no request. Each
push of data from the connection is one delivery received, as each
read is on stock, and each `send` one delivery sent, counted with its
packet header when the socket process takes it, before the connection
has it, as stock's driver counts a send it queues. From these it
answers `recv_oct`, `recv_cnt`, `recv_max`, `recv_avg`, `send_oct`,
`send_cnt`, `send_max` and `send_avg`, the averages truncated as the
driver reports them, and refuses any name that is no statistic with
`{error, einval}`, as the driver does, on a listening socket as on a connection, and
on a closed socket until its owner closes it. It does not measure
`recv_dvi`, the deviation of the delivery size, or `send_pend`, the
bytes not yet sent, which lie partly in the network domain, and
leaves them out of the answer, as stock's socket backend leaves out
the statistics it does not count (`gen_tcp_socket.erl`,
`getstat_what/2`): a caller that asks for them gets the rest, never a
made-up value. ssh asks for `send_oct` to decide when to rekey
(`ssh_connection_handler.erl`, `check_data_rekeying/2`).

### The `socket` and `net` modules

OTP's `socket` module calls the `prim_socket` NIF, which erXos drops. An
Erlang `prim_socket` takes its place and speaks the same socket protocol
to the network service, a process of it in the client's domain standing
as each socket's socket process, so `socket` and its `gen_tcp_socket`
backend work over the same connection, listener and datagram processes
as `gen_tcp` and `gen_udp`; `net`'s interface and host calls are answered
by the grant. `gen_tcp`, `gen_udp`, `ssl`, `ssh` and distribution do not
use `socket`, so it comes after them
([Decisions](#decisions), 5), and plan.md schedules it.

### Name resolution

`inet_res`, OTP's DNS resolver in Erlang, runs over `gen_udp` in each
domain, through `erx`, the default backend. The grant's `resolver`
operation returns the name servers and search list the network domain
learnt from its static configuration, DHCP (options 6 and 15) or router
advertisements (RFC 8106), within resolv.conf's limits of three name
servers and six domains, and only reads them; `watch_resolver` returns
the same answer and makes its caller the grant's one subscriber, which
`{erx_net_resolver, Grant, Answer}` reaches after each change, so a
reader never displaces the subscriber. In each domain,
`erx_net_client`'s resolver loader, `erx_inet`, watches at start and
again after the grant ends, checks each answer as input from another
domain, and loads it into `inet_db`: the name servers and search list
replace inet_db's, `dns` joins the lookup methods after the hosts file,
and the answer takes the place of resolv.conf, which a domain does not
have. A search domain is checked by the DHCP client's rules: labels of
letters, digits and hyphens that begin and end with a letter or digit
(`res_hnok`), each of 1 to 63 bytes, at most 253 bytes in all, one
trailing dot allowed and dropped; stricter than `res_hnok`, which also
takes an empty label, since `inet_dns` cannot encode one and would fail
the caller's query. A domain that fails the check is dropped and the
rest of the answer loaded. Query IDs are the kernel's random bytes, not
`inet_db`'s counter, in a domain whose release has no `crypto` too
([design-runtime.md](design-runtime.md), edit 63), so an off-path host
must guess both the ID and the source port (RFC 5452). The `host`
command ([design-shell.md](design-shell.md)) asks the same name servers,
or the one it is named.

The check of each answer, the reply to `watch_resolver` through
`erx_inet:call/1` and each change message alike, is `erx_sock_admit`'s,
as for every answer of the grant
([Untrusted input](#untrusted-input)).

### Distribution to other machines

An exposed domain reaches other machines under its own node name over
OTP's own TCP distribution carrier, beside the `erx` carrier that serves
names at this machine's host name
([design-runtime.md](design-runtime.md#connections-in-erts)). Stock
nodes find a node's port through its host's port mapper, epmd. The
network domain runs one, `erx_epmd`, speaking epmd's protocol on port
4369:

* An exposed domain registers through its grant, with the `epmd_module`
  OTP lets a node configure: `register_node` sends the grant
  `{register_node, Port}`, and the grant registers the domain's own node
  name with the port only if the domain holds that listening port. No
  domain registers a name that is not its own.
* `PORT_PLEASE2_REQ` from any peer is answered for registered names;
  `NAMES_REQ` lists only registered names. A registration ends with the
  domain's listening socket, its grant or the domain.
* `ALIVE2_REQ` arriving from the network is refused: registration comes
  only through grants.

The carrier's handshake refuses a remote node that claims a name at this
machine's host name ([design.md](design.md#networking)). A release build
allows only OTP's TLS carrier, `inet_tls_dist`, which authenticates both
nodes by certificate and encrypts; the domain's keys stay in the vault
and are used through a key facet. A development build allows the plain
TCP carrier as well, whose MD5 challenge over a shared cookie
authenticates weakly and encrypts nothing ([Decisions](#decisions), 4).

## The interface towards POSIX programs

A program's socket descriptor names an open of its handler's table, as a
file descriptor does, and the open names the socket's **open-file
description**, a process of the session, as a file's description is
([design-programs.md](design-programs.md#descriptors-and-files)). The
description is the socket's owner at the network service, and the
protocol offers it what POSIX needs:

* `{watch, Events}`: the socket sends one `{ready, S, Events}` when it is
  readable, writable, acceptable or has an error, which the description
  passes on as `{ready, Open, Events}` to the program that asked;
* `{recv_nb, Max}` and `{send_nb, Data}`: they never wait, and answer
  `{error, eagain}` when POSIX's nonblocking call would; a blocking read
  is a watch followed by a nonblocking read, so no request waits in the
  network domain;
* `accept_nb`, `getsockopt` and `setsockopt` in FreeBSD's names, mapped to
  the same options.

A socket belongs to its grant's domain, the session's, not to one
program, and lives until its description closes it or exits. Programs of
one session share a socket as they share any open-file description
(spawn, `fork`, `SCM_RIGHTS` within the session, `exec`), and the network
service sees nothing of that. The description closes the socket when the
last open naming it closes. Moving a socket to another domain is not
offered, since a socket acts for its grant's domain alone.

## Untrusted input

Every packet is hostile. The rules, and where each is enforced:

| Rule | Where |
| --- | --- |
| Every length read from a header is checked against the enclosing layer before use; trailing bytes are cut at the length the header states | each `*_wire` decoder; fuzz targets |
| Decoders are total: `{ok, ...}` or `{error, Reason}`, never an exception | fuzz targets fail on any exception |
| No field a checksum covers is read before the checksum is checked, except the fields that choose a frame's destination, which only the lookup reads; a segment, datagram or ICMP record is made only by its decoder, which checks the checksum first | `erx_net_input`, the `*_wire` decoders; a build check that only the decoders make those records; the fuzz targets' wrong-sum inputs and the interface's gate |
| No checksum claim from a device or a host's kernel is believed: a frame's network sum is computed by `erx_net`'s own C over the bytes its binary holds, each word loaded once, and `VIRTIO_NET_F_GUEST_CSUM` is never negotiated | `erx_inet_copy_sum` and its callers, `erx_virtio_net`'s wanted features; the interface's gate with a lying sum ([Checksums in the copy](#checksums-in-the-copy)) |
| No atom is made from packet data; unknown protocol values stay integers | the codecs; a build check fails on `binary_to_atom`, `list_to_atom` and `binary_to_term` in `erx_net` |
| Sequence-space conversion happens only in `erx_tcp_seq` | a chokepoint check fails on 2^31, 2^32 - 1 or 2^32 written as an integer literal in any base, or a left shift by a literal 31 or 32, in any other TCP module |
| Half-open connections live only in the bounded syncache; overflow is answered statelessly with cookies | `erx_tcp_syncache` |
| A RST resets only at exactly `last_ack_sent`; a SYN in a synchronized state and an out-of-range ACK get rate-limited challenge ACKs | RFC 5961 stages |
| IP identification values reveal nothing: zero on atomic IPv4 datagrams, random otherwise and on IPv6 fragments | `erx_ip4`, `erx_ip6` |
| Random values (identifications, ephemeral ports, flow labels, nonces, delays, limit jitter) come from the owner's `erx_net_rand` generator, keyed from the kernel's entropy generator through `erx_net_clock`; no module of `erx_net` calls `rand`, and only the portable `erx_bytes` calls `crypto` | `erx_net_rand`; a build check |
| Initial sequence numbers are unpredictable (RFC 6528); timestamp clocks are offset per connection | `erx_tcp_isn` |
| ICMP reports act only when their quoted sequence number is in flight | `erx_tcp_icmp` (RFC 5927) |
| Reassembly queues, both IP and TCP, have caps on count, bytes and lifetime; held payloads count at the size they keep alive | reassembly modules |
| Neighbour messages are accepted only by RFC 4861's rules (hop limit 255) and FreeBSD's ARP rules; tables and held packets have bounds | `erx_arp`, `erx_nd6`, `erx_lltable` |
| Router, prefix and redirect entries have per-interface bounds; new entries past them are ignored, listed ones are never evicted | `erx_nd6_rtr`, `erx_net_route` |
| DHCP replies reach only the interface's DHCP client, and only for its outstanding transaction | the interface's DHCP path |
| ICMP errors, RSTs to closed ports and echo replies are rate-limited; no reply to a broadcast or multicast | the interface's limiters |
| Traffic that names no socket spends the interface's budget | the ingress limiter, below |
| Packets queued for any process are bounded | credits |
| Text from packets reaches logs and the inspector only through the sink's escaping function | `erx_log` |
| Ring fields a netmap port shares are read once per call and checked before a byte is copied: offsets and sizes at registration, `tail` and each slot's buffer index and length at each call; every copy lies inside one buffer of the mapping | `erx_netmap_ring`, its tests and fuzz target ([The netmap transport](#the-netmap-transport)) |
| What a virtio device wrote into a receive buffer is cut by its size alone: the device header is skipped unread, a frame shorter than an Ethernet header is `malformed` and one longer than the MTU and its Ethernet header `too_long` | `erx_virtio_net:frames/2` and its fuzz target, `tools/fuzz/erx_virtio_net_frame.rb` |
| A socket takes requests only from its one socket process, and a connection takes bytes only within the send credit it granted | the socket's check of `ReplyTo` after `erx_net_admit`; the connection's count of the send credit outstanding |
| A socket process takes a message from its socket only when it passes `erx_sock_admit`: the origin its grant was found with, its own socket's pid, a shape of the socket protocol, data within the credit outstanding and at most a piece in at most 64 binaries, send credit a positive count that keeps the credit outstanding within 2 MiB, a datagram's address and port well formed, an end reason from the closed list, a reply under an `N` in flight in the reply shape its operation declares | `erx_sock_admit`; its fuzz target |
| No term the network domain chose reaches program code: every push and every answer of the grant passes `erx_sock_admit`, and what an owner or a caller receives is built from its checked parts | `erx_sock_admit`; `erx_gen_tcp_core`, `erx_gen_udp_core`; `erx_inet:call/1`, the one path to the grant |
| A network domain that stops draining its lane makes a client queue for it no more than it would for any peer: the busy limit, plus one frame per sending process | `erx_sock_out`, the socket process's one way to start and to send, which spawns it with `{async_dist, false}` and refuses rather than queue past the busy limit; the build checks that no other site in the socket process's modules sends, links, monitors, calls or sets `async_dist` |
| What a client keeps because of a hostile network domain is bounded by what it granted: nothing before a socket process holds its socket, its target while it is held, during a transfer included, and of each send, the bytes the queue bound counts | the first contact, before which a message from the network domain ends the opening; the transfer's held presentation; every piece a binary of its own size |
| The trusted base parses no network traffic | the manifest check's property 15 and the mint's refusal of the system domain as a grantee |

**A socket process's trust in its socket.** A push from the network
domain is a message from another domain, untrusted as every such message
is. `erx_sock_admit` is generated from the operation schema's reply
types, as `erx_net_admit` is from its requests ([Decisions](#decisions),
10). A message that fails it aborts the socket:
the socket process sends `close`, presents what it held and then the end
as `{error, econnaborted}`, and logs one line naming the socket and the
failed check, never the message; it never raises. Each kind of message
the network domain may send has its own bound: pushes, the credit
outstanding; replies, the 64 calls in flight, each in its declared shape;
send credit, nothing, since it lets the socket process send sooner only
bytes its callers gave it, and a grant past 2 MiB outstanding aborts the
socket; an undrained lane, the busy limit of 1 MiB for the whole client
and one frame past it for each process caught sending (**What waits for
an undrained lane**, in [The socket process](#the-socket-process)), the
rest waiting where it already waits, in callers' sends and the
waiting-call queue; the end, once; anything else is dropped and counted.
A piece still queued when its send is answered keeps alive only its own
bytes. So the network domain can do to a client what a network can: send
bytes within credit, end sockets, answer requests, withhold send credit
(a `send` then waits until its `send_timeout`) and stop draining its
lane. It cannot grow what a socket process holds past its credit, make
the client queue more than the busy limit and a frame per sending
process, put a term of its choosing in an owner's mailbox, or stop a
socket process from running (**The socket process never suspends**, in
[The socket process](#the-socket-process)).

What the socket process has not yet taken is bounded by its runtime's
queue quota (edit 15 of
[design-runtime.md](design-runtime.md#the-edits-outside-syserxos)): past
it the funnel leaves the network domain's next frame in its lane, which
holds back only what the network domain sends that client. A correct
network domain meets the quota only when a socket process falls behind
its pushes, and the lane then pauses until it catches up, losing nothing;
since no process waits in `receive` at its quota
([design-domains.md](design-domains.md#flow-control)), a pause cannot
deadlock. A client domain's processes have a quota only where its runtime
sets `-erx queue_quota`, and which domains do is an open decision
([Open decisions](#open-decisions), 1). Without a quota the funnel
delivers every authorised frame whatever its target already holds, so a
flood that outruns a socket process grows its queue with nothing to stop
it but the client domain's budget, the funnel's gap that `TODO.md`
records.

**Answers from the grant.** The grant's reply to a call reaches its
caller with the envelope already off, since `gen` owns call replies
([design-domains.md](design-domains.md#the-peer), D18), so it would reach
program code as the network domain chose it. Every call to the grant
therefore goes through `erx_inet:call/1`, which finds the grant, refuses
with `{error, enobufs}` an operation whose floors its own runtime does
not meet ([Message sizes](#message-sizes)), calls the grant, passes the
answer through `erx_sock_admit:answer/3` against the reply type the
schema declares for that operation and the grant's node, and returns what
it rebuilt from the checked parts. It waits with the timeout `infinity`,
as every call of the stack does ([Build checks](#build-checks)): the
call's monitor ends the wait when the grant ends, an open's own `Timeout`
is the socket's to enforce, and a network domain that never answers holds
only its caller, as a network that never answers would. The resolver
loader's `watch_resolver` is such a call, retried only when the loader
finds no grant or the grant ends. What it admits:

* an open's `{ok, Socket}`: `Socket` a pid of the grant's node;
* `interfaces`: at most 64 interfaces, each rebuilt from the keys
  `ifconfig` shows and nothing else: a name of 1 to 15 bytes, FreeBSD's
  `IFNAMSIZ`, of letters, digits, `.`, `-` and `_`; a six-byte
  link-layer address; an MTU; the link state; the configuration; and at
  most 64 well-formed addresses with their prefix lengths;
* `hostname`: a name of labels as FreeBSD's `res_hnok` admits;
* `resolver` and `watch_resolver`: a map of at most three IPv4 name
  servers on port 53 and at most six search domains, the check
  `erx_inet:resolver_config/1` makes; each search domain is checked
  alone, and one that fails is dropped and the rest of the answer kept
  ([Name resolution](#name-resolution));
* an error: a reason from the operation's closed list.

The grant's change messages to `erx_inet`'s loader,
`{erx_net_resolver, Grant, Answer}`, arrive in their envelope and pass
the same module, against the grant's origin and the `resolver` reply
type. `erx_inet` exports no grant pid, so no module of `erx_net_client`
reaches the grant another way. An answer that fails the check is the
call's `{error, badarg}` and one log line naming the operation and the
check, never the term; a change message that fails it is dropped, and
the loaded answer stays.

**The ingress limiter.** Owned traffic, a frame that demultiplexes to a
socket, is bounded by that socket's credit and charged to its grant.
Unowned traffic, everything the interface process itself must answer or
hold (SYNs, ARP and neighbour requests, echo requests, fragments, DHCP
replies, RSTs to send), spends a token bucket of the interface, in frames
per second with a burst. Past it, unowned frames are dropped and counted
while owned frames and the replies the interface awaits (ARP and
neighbour advertisements for entries it is resolving) still pass, so
established connections and address resolution keep making progress
under a flood of new-connection traffic. The bucket's rate and burst are
settled by the flood measurements of plan.md's network gates.

**What a flood costs the interface.** Every frame, owned or unowned,
costs the interface process a header decode and one lookup before it is
kept or dropped; only a frame that holds room costs more: its check, a
constant with the network sum, and its decode ([Receiving](#receiving)).
The pipe is the exception: its frames come without a sum, and the merge
sums each before classification, so every frame costs a read of its
bytes. A valid-checksum flood at one client's established connection
costs no more per frame than any minimum-size flood: once the
connection's credit is full, each further frame is decoded, looked up
and dropped, and what the connection takes is charged to its grant. The interface's own cost per frame is spent on the network
domain's grant, whoever the frame names. A frame that holds room and
fails its checksum returns its room, so such checks are bounded by link
capacity alone, each a constant with a network sum
([Checksums in the copy](#checksums-in-the-copy)). Whether one interface
process keeps up with minimum-size frames at line rate is what the
network gates measure; where it cannot, the driver's credit fills and the
driver drops frames for every client alike ([Residuals](#residuals)).

### Residuals

Each of these is a known gap, with the reason it stays:

* **One interface process is a ceiling for all clients.** A line-rate
  flood that the interface process cannot decode as fast as it arrives
  makes the driver drop frames for every client, at the per-frame cost
  above (the pipe's extra read stays, since the pipe is a development and
  test transport, never erXos's medium). One interface process per receive queue, on devices that
  hash flows to several queues ([Scope](#scope)), divides the work. A
  bound per client would need a classifier ahead of the interface
  process, which is what the interface process is.
* **Resolution is shared between clients.** A client that sends to many
  unresolved on-link addresses makes its interface hold up to 16 packets
  for each, send a request for each, and, once the neighbour table is
  full, evict the oldest entries in resolution, other clients' among
  them; the sender credit bounds the rate of its hand-overs and the table
  bounds what is held, but nothing bounds one client's share. A per-grant
  count of the entries each grant's packets started, with a cap past
  which its hand-overs are dropped as lost frames, would bound it; FreeBSD
  has no such bound, and the cost is a grant tag on every hand-over and
  entry. `TODO.md` records it.
* **Stranded credit.** A sender killed between reserving credit and
  sending strands at most one hand-over's units on the receiver's counter
  until the receiver restarts ([Credited queues](#credited-queues)). For
  a listener the sender is the interface between its reservation and the
  connection's spawn, or the accepted connection between its spawn and
  its `{queued, Conn}` notice, and what is stranded is one backlog place
  until the listener ends; the dead connection holds nothing for the
  client, as its grant deletes its key ([The listener](#the-listener)).
  Only a fault or a test kills a connection or an interface process; a
  counter that never drains would need the receiver to reconcile against
  senders it cannot see.
* **The interface's own frames have no reserved transmit share.** ARP
  and neighbour-discovery answers, RSTs and SYN-ACKs take the driver's
  transmit credit as clients' data does, so senders that keep it full
  delay resolution and handshakes until it drains. FreeBSD's send queue
  has no reserved share either; a small share of the transmit credit for
  the interface's own frames would bound it, and `TODO.md` records it.
* **A network domain decides whether an open succeeds and when.** The
  `link` right a socket process exports is held by the network domain,
  not by one process of it, so any of its processes may link to a socket
  process and end its opening, and `connect`'s and `accept`'s deadlines
  run on the stack's clock, so a network domain that never answers holds
  the opener for as long as it waits. Neither makes the client hold
  anything: the opening keeps nothing from the network domain, and the
  opener waits as on any facet that does not answer. The network domain
  serves every socket it opens, so it can deny any of them service
  whatever the client checks; an export to one process of a domain would
  bound who may link, not what the domain may do.

## Concurrency and failure

### Ordering

Segments of one connection pass through one interface process and one
mailbox, in arrival order, and the connection steps through them one at
a time. A socket's replies and pushes to its socket process travel on one
lane in order with its exit, and the socket process alone presents them
to the owner and answers the owner's calls, so the owner sees them in the
order the socket process made them; `inet:setopts(S, [{active, false}])`
and `controlling_process` are local to the owner's domain and need
nothing from the network domain to keep that order
([The socket process](#the-socket-process)). Two binders of one key are
ordered by `ets:insert_new/2`, and two explicit binds by their calls to
`erx_net_tables`. The interface and the driver never send to another
domain, so no client can stall packet input, and a socket's pushes are
bounded by its socket process's credit, so a client that stops reading
stalls only its own sockets.

### What fails and what survives

| Failure | Seen by | What survives | What ends |
| --- | --- | --- | --- |
| a frame that a step cannot handle (a bug: the step raises) | the interface process, which counts and logs the event | the interface's state from before the frame; every connection | the frame |
| the interface process crashes outside a step | its link supervisor; `erx_net_tables`, which deletes the rows that name it | the driver, every connection | the interface's soft state: neighbours, reassembly, half-open handshakes; its published rows, and with its `erx_dhcp4` a DHCP lease, which the restarted client asks for again |
| the driver crashes, or the device breaks its queue | its link supervisor, which ends the link; the interfaces supervisor starts it again, at most once a second while the device keeps failing | every connection; their unacknowledged data is retransmitted | the device's queued frames; the interface process restarts after the driver's reset |
| the driver has no attached interface, between an interface's end and its restart | the driver, which monitors the attached interface | everything | the frames received meanwhile, dropped and counted as `detached` |
| a device's queue is full, or a transport refuses a frame | the driver | everything | nothing while the backlog has room, which the transmit credit bounds; past it senders' hand-overs are refused and counted where they are made |
| a call on a netmap port fails (its registration, a sync or an arm), or its ring breaks | the netmap transport, which ends the driver, whose link the interfaces supervisor starts again | every connection | the link's soft state, as a driver crash; a port that stays unregistrable restarts the link at most once a second ([Ending](#the-driver), [The netmap transport](#the-netmap-transport)) |
| a pipe's far end goes away | the pipe: a `process` end by its monitor, and the tap transport by an error of its descriptor, each ending the driver, whose link the interfaces supervisor starts again; a `udp` end only as refused sends | every connection | the link's soft state, as a driver crash; a far end that stays away restarts the link once a second; TCP retransmits once the far end returns |
| a socket's step raises (a bug) | the socket, which ends itself from its state before the event, then exits with the exception; its grant deletes its entries and logs the exit | everything else | the socket: a connection sends a RST and pushes `{error, econnaborted}`, which its socket process presents as `{tcp_error, S, econnaborted}` and `{tcp_closed, S}`, or as the error of a waiting call |
| a socket is killed or crashes outside a step | its grant, which deletes its entries; its socket process, by their link | everything else | the socket: the peer times out or meets a RST later; the socket process presents the end as `{error, econnaborted}` |
| a socket's owner exits | its socket process, which monitors it and stops | everything else | the socket process; its socket, by their link, closes as `close/1` does: a connection sends FIN, or RST if `linger` is zero |
| a socket process crashes or is killed | its socket, by their link | everything else | the socket, closed as on its owner's exit; the owner's next call gets `{error, closed}`, and in active mode the owner is told nothing, as with stock's `gen_tcp_socket` |
| a listener ends: its socket process ends, its grant ends, or its step raises | its queued connections and its acceptors' socket processes, by their links; its socket process, by theirs | the connections it has handed out | each queued connection, with a RST, its backlog with it; the `accept` calls it has not answered, answered `{error, closed}` by its socket process ([The listener](#the-listener)) |
| a queued connection ends: a peer's RST, a timeout, a raise | its listener, by their link | the listener and the rest of its queue | that connection, whose backlog place is free at once; an `accept` it was chosen for is answered `{error, econnaborted}` |
| a grant refuses an accepted connection's adoption, or has ended | the connection, which releases its accept unit | the listener, which never hears of it | the connection, with FreeBSD's RST for a handshake it cannot give a socket |
| an acceptor's socket process ends while its `accept` waits, or before the connection it is handing takes `bind` | the listener, by their link; in the second case the connection too, which aborts with a RST at the `bind` | everything else | that `accept`, answered `{error, econnaborted}`, which frees its place in flight; the next connection goes to the next caller |
| the interface ends before its verdict on a connection it spawned | the connection, by its monitor, which releases its accept unit | everything else | the connection; its grant deletes any entry inserted for it |
| a socket process's step raises (a bug) | the socket process, which presents the end as `{error, econnaborted}` from its state before the event, then exits with the exception | everything else | the socket process and, by their link, its socket |
| a push breaks the socket protocol | the socket process, through `erx_sock_admit` | everything else | the socket, aborted ([Untrusted input](#untrusted-input)) |
| the grant ends (revocation, its domain ends) | its sockets, by the link: each connection sends RST and exits | other grants | the domain's sockets and registrations; each socket process presents its socket's end |
| a client domain ends | the network domain, by its sockets' links and the grant's end | other domains | that domain's sockets, each with a RST |
| a client stops reading | its socket processes, whose credit runs out | other sockets and domains | nothing: that client's windows close, as TCP's do |
| a peer stops reading | its connection, whose send buffer stays full, so its send credit stops | other sockets and domains; the owner's other calls on the socket | nothing: a `send` waits in the socket process, as a blocking `send` waits on FreeBSD, until its `send_timeout`, and is then answered with the rest it did not send |
| the network domain stops draining a client's lane | that client's frames to it, which wait in the client's runtime up to the busy limit and a frame per sending process; past it the outlet refuses | other domains; the client's socket processes, which never suspend; a client process that calls the grant waits, as on any stalled domain | nothing the network domain did not already hold: sends within credit are answered `ok` once queued, the rest meet their `send_timeout`, and exits of stopped socket processes reach their sockets once the lane drains |
| a socket died and its entries are not yet deleted | nobody: `classify/2` finds the entry and the frame's message goes to a dead pid | everything else | the frames that arrive before its grant deletes the entries, as if dropped; a TCP peer retransmits and meets a RST once the entry is gone |
| the configuration changed during a batch or between output passes | the next batch's view, the next pass's path | everything | nothing: frames classified or framed against the old copy behave as under FreeBSD's epoch, which lets a lookup finish against the table it started on |
| a next hop does not answer resolution | the interface, which holds up to 16 packets for it | everything else | its held packets: dropped after 20 s for ARP, or the oldest returned as an ICMPv6 address-unreachable to the stack's own socket for neighbour discovery ([Framing](#framing)) |
| the interface's MTU drops under a connection | the connection's next output pass, through the context's MTU | the connection | nothing: on IPv4 the next segment under don't-fragment that would not fit lowers `t_maxseg` and is sized again ([Output](#output)); on IPv6 a segment over the MTU is fragmented, as FreeBSD sends it |
| a route goes away under a connection | the connection's next output pass | the connection, which sends nothing until a route returns | the connection, at its retransmission timeout: with `ehostunreach` once it has received a SYN, with `etimedout` in SYN-SENT |
| `erx_net_tables` or a top-level child exceeds its restart intensity | the network domain's supervisor | nothing in the domain | every socket; owners' next calls get `{error, closed}` |

A raising step is caught in three places, and the step's purity makes
the handling complete: the state is exactly as before the event. The interface process drops the frame, keeps its
state and goes on, since a frame is its unit of work and its state serves
many flows; a merge that raises, which only a bug can make once the
driver cuts every batch to the merge's limit, drops its batch the same
way, the batch's receive credit already taken
([The fast path](#fast-path-concurrency-and-failure)).
A socket, and a socket process in the owner's domain, ends itself
properly from its intact state, as the table says, and then exits with
the exception as its reason, since its state is one flow's and a bug in
it is not worth keeping alive. All three record the exception and the
event, a frame's length and its first 128 bytes escaped, in the kernel
log, and count it. The record keeps the stack trace with each frame's
arguments replaced by their count, and a socket's exit reason is the
exception's class and reason alone, so a `function_clause` never carries
the control block into a log. OTP's own reports of the same exits, which
print the mailbox and each frame's arguments, pass the report filter,
`erx_report`, which the network domain takes at boot
([design-log.md](design-log.md#reports-carry-no-term)). A socket's
`format_status` leaves out its buffers, its reassembly queue and its
generator, and a socket process's what it holds, so `sys:get_status`
shows neither a flow's payload nor the generator its sequence numbers and
ports come from. A request reaches the step only after the admission path
has checked its shape against the schema, so a malformed request is
refused there with `{error, badarg}`, as a facet refuses, and never
raises in the step. No other exception is caught. The fuzz targets and
the explorer fail on any exception, so in tested code neither path runs.

### The network domain's own end

A network domain killed under load restarts as any configured domain
does. Its connections end with it: their peers see silence and time out,
or receive RSTs to later segments; clients see their sockets close. No
client domain is affected beyond its sockets.

## Refusals and error results

| Result | When |
| --- | --- |
| `{error, eacces}` | the domain holds no `net` grant; the grant does not allow the port, address or `listen`, a port being checked by the bind (**Explicit binds**, in [Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)) |
| `{error, emfile}` | the grant's `sockets` limit is reached at an open; an accepted connection past it is reset at its handshake instead ([The listener](#the-listener)) |
| `{error, enobufs}` | a buffer reservation exceeds the grant's `buffers` limit; every call of an operation, a socket's open or `interfaces` among them, whose floor for `max_frame`, `max_message_heap` or `funnel_depth` the caller's own runtime is below, answered by the client side before any request is sent ([Message sizes](#message-sizes)) |
| `{error, eaddrinuse}` | the key is held, under FreeBSD's reuse rules, `reuseport` on both included, or another grant holds the port unconnected (**Explicit binds**, in [Ports and the demultiplexing table](#ports-and-the-demultiplexing-table)) |
| `{error, eaddrnotavail}` | the local address is not the machine's, no usable source address leaves through the route's interface, or no ephemeral port is free |
| `{error, econnrefused}` | a RST answered the SYN |
| `{error, etimedout}` | connection setup or retransmission exceeded FreeBSD's limits |
| `{error, enetunreach}` | `connect`, or a datagram sent without a local address, finds no route (`in_pcbladdr`) |
| `{error, ehostunreach}` | a datagram's route has gone (`ip_output`); a synchronized connection's soft error at its timeout; an unreachable report in SYN-SENT |
| `{error, econnreset}` | a RST in a synchronized state, under `show_econnreset` as on stock; under `show_econnreset`, the first `send` waiting when a reset or an abort ends the socket or, when none waits, the first `send` after it, and the first `send` that meets its write side shut, as the socket backend curates them |
| `{error, econnaborted}` | the socket protocol broken either way, and the socket aborted: by the connection, on bytes past its send credit or after its write side's `shutdown` or `close`; by the socket process, on a push that fails `erx_sock_admit`, a grant past 2 MiB among them; a socket that exits without a last push; a connection step that raises; an `accept` whose connection ended after the listener chose it, before its first contact, or whose acceptor's socket process ended while it waited |
| `{error, enoprotoopt}` | an ICMP parameter problem answered the SYN, as FreeBSD's `icmp_errmap` maps it |
| `{error, closed}` | the socket is closed, as on stock; a `recv` that the peer's FIN leaves short, as on stock; a `send` waiting at `close/1`; every `send` waiting behind the one the socket's end or a shut write side is shown to; without `show_econnreset`, each `send` the `econnreset` row lists |
| `{error, enotconn}` | a `recv` after one the peer's FIN left short, or one answered the socket's error, as on stock |
| `{error, timeout}` | an Erlang call's own timeout, as on stock; an `accept` whose timeout passed before a connection was paired with it; a `send` still waiting at its `send_timeout` under `send_timeout_close`, which then closes the socket |
| `{error, {timeout, Rest}}` | a `send` still waiting at its `send_timeout` without `send_timeout_close`; `Rest` is the bytes it did not send, as the socket backend returns them |
| `{error, emsgsize}` | a datagram larger than IP allows, or a packet over `packet_size` |
| `{error, einval}` | an option value out of range; a socket used from a domain other than its socket process's. At `listen` and `connect` an option stock does not know, or a value stock's own parser (`inet:listen_options/2`, `inet:connect_options/2`) refuses, raises `badarg` as on stock instead |
| `{error, not_owner}` | `controlling_process/2` called by a process other than the owner, as on stock |
| `{error, enotsup}` | `fd`, `netns`, `bind_to_device`, unknown `raw` options, SCTP |
| `{error, badarg}` | a request the admission path refuses: wrong origin, schema or size, or past the socket protocol's requests in flight; a grant's answer that fails `erx_sock_admit`, an open's socket of another node among them; `controlling_process/2` to a process of another domain, as stock refuses one of another node |

An interface that cannot start is refused by its driver's `init`, and its
link supervisor fails to start with the reason: `{lladdr, Addr}` for a
pipe's address that is not a locally administered unicast address,
`{mtu, N}` for a pipe's MTU outside 1,280 to 9,000. A virtio device the
transport cannot drive, an empty transport or one the device NIF
refuses, is no interface rather than a fault: its `init` answers
`ignore`, the link supervisor starts nothing and answers `ignore` too,
and the stack starts without it, as the block driver does without a
disk; any refusal but an empty transport's is one line in the kernel log
([The driver](#the-driver)). A netmap transport refuses only what
restarting cannot fix, its configuration and its build (`{netmap,
unavailable}`, `{netmap, {api, Kernel, Built}}`, `{mtu, N}` over the
port's buffers), and takes a port it cannot register as its medium
ending, so its link is held and restarted, at most once a second
([Ending](#the-driver), [The netmap transport](#the-netmap-transport)).
The application refuses to start with `{seam, Key, Module}` when a
configuration key names a seam module the build does not hold
([Two places, four seams](#two-places-four-seams)).

## Where C is used, and what is measured

C does per-byte work, and the per-frame work that rides on a pass over
the bytes, as the design requires ([design.md](design.md#decisions)).

* **The Internet checksum,** `erx_bytes:inet_csum/2`, one of the per-byte
  primitives, over an iolist so headers and payload are summed without
  being joined. It uses the CPU's checksum-friendly instructions where the
  architecture layer has them, with portable C as their oracle. On the
  paths that carry segments it is not a pass of its own: the copy between
  a device's buffer and a binary computes it, through `erx_inet_copy_sum`
  of the same core, and a device that offers checksum offload on transmit
  may finish it instead, an extension
  ([Checksums in the copy](#checksums-in-the-copy), [Scope](#scope)).
  `inet_csum/2` stays for transports that copy nothing in C, for headers,
  and as the oracle of both.
* **SipHash-2-4,** `erx_bytes:siphash24/2`, a primitive this design adds,
  taking a 16-byte key and an iolist, for initial sequence numbers,
  timestamp offsets and SYN cookies, the hash FreeBSD uses for all three,
  and for the stream of `erx_net_rand`. A hash is per-byte work by the
  design's own list, and a SYN flood makes this one per-packet: in Erlang
  its 64-bit arithmetic would leave small integers on every round. It also
  keeps the domain that parses hostile packets from calling OpenSSL,
  which its image maps and nothing there calls
  ([design-crypto.md](design-crypto.md#domains-that-call-no-openssl)).
  RFC 7217's HMAC-SHA-256 is computed by the vault, which holds its key
  ([IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration)).
* **The entropy source,** `erx_bytes:entropy/1`: it returns up to 256
  bytes from `erx_entropy_read` and raises when the read fails, never
  substituting other bytes
  ([design-runtime.md](design-runtime.md#per-byte-primitives)). It is not
  per-byte work but Erlang's entry to the kernel's generator in a domain
  that calls no OpenSSL: the network domain's runtime image maps OpenSSL,
  its release ships no `crypto`, and a build check proves that no module
  of the stack calls `crypto` but the portable `erx_bytes`, which is
  built only outside erXos
  ([Build checks](#build-checks),
  [design-crypto.md](design-crypto.md#domains-that-call-no-openssl)). The
  stack calls it, through `erx_net_clock`, only when an owner starts and
  when `erx_net_tables` draws or rotates a secret
  ([One owner, one step](#one-owner-one-step)).
* **The cut and the merge,** `erx_tcp_cut.c` in each transport's copy
  and `erx_bytes:tcp_merge/1` in the interface: the cut writes the header
  values Erlang chose into each frame of a run as it copies the frame,
  and the merge groups received frames by a fixed rule and decodes
  nothing TCP acts on
  ([The fast path](#the-fast-path)).

Everything else is Erlang. Whether TCP's established path also needs
native code is measured on this stack: a bulk transfer and a
request-response load against line rate at 1 Gb/s (81,274 full-size
frames a second each way, 12.3 us a frame), with the time per frame
broken down by stage: completion, classification, checksum, step,
encoding, posting, the lane crossing and the socket process's hop to the
owner. The measurements on erXos's kernel decide and those on the
Raspberry Pi 4 confirm or reopen the decision; the same measurements on
QEMU on Fiasco are a baseline that decides nothing, since every interrupt
and doorbell there passes the root's one service thread (plan.md's
gates GN-QEMU, GK3 and GN-board). If the established path misses line
rate and the breakdown names a pure function of the core as the cost,
that one function gets a NIF with the same signature, and the Erlang
function stays as its oracle in a differential test over the same
inputs. The process structure does not change.

The network domain's memory is measured as the storage domain's is (the
system manifest's header): the root's pool pages in use with the domain
up, minus those once it has ended. With the network row on BeamAsm (the
development manifest runs it on the interpreter, which holds less) and
the users share's four schedulers and four dirty CPU schedulers, the
domain holds at least 8,463 pages, 33.1 MiB, once DHCP has leased its
address (a lower bound: root's session grows before the last reading),
and 8,603 pages, 33.6 MiB, after root's session has run `ping -c 3` and
echoed 1 MiB over TCP through it (the net_device suite's network-domain
cell on its test manifest: an Apple M3 Max host, HVF, QEMU 11.1.3,
Homebrew clang 23.1.3, one guest CPU, a 768 MiB machine; the baseline is
the pages in use once the domain has ended; raw logs in erxos-history,
`network-domain-footprint-2026-11-11`).

What the domain's lane costs a socket is measured with the net_device
suite's TCP line, through slirp's guest forward to the harness's echo
server, with the stack in the system domain and the lines typed at the
system's Erlang shell (the baseline, commit 1836f6f1e) and with the stack
in the network domain and the lines typed at root's session's, every
socket call crossing the lane (commit c04cfe382); the images differ only
by that move. Over three boots each, a 256 KiB echo took 12 to 16 ms
in-node and 13 to 21 ms across the lane (medians 14 and 18 ms, 17.9 and
13.9 MiB/s each way), and 256 sends of 64 KiB ran at 37.2 to 41.6 MiB/s
in-node and 41.3 to 44.6 MiB/s across the lane (medians 39.6 and 42.8
MiB/s). The sends show no cost of the lane at this rate, which slirp and
Fiasco's device path bound; the echo is too short, timed to the
millisecond, to separate a few milliseconds from noise. These are
numbers on Fiasco and decide nothing: the Fiasco kernel (modified Fiasco),
an Apple M3 Max host at load averages of 7 to 10, HVF, QEMU 11.1.3,
Homebrew clang 23.1.3 with the tree's default flags, BeamAsm, one guest
CPU, a 224 MiB machine (raw logs and the script in erxos-history,
`network-domain-tcp-2026-11-11`).

Costs this design leaves unmeasured are on the performance watch list,
[todo-performance.md](todo-performance.md).

## Verification

FreeBSD is the behavioural reference: its TCP test suite runs as packet
scripts against the stack and against a FreeBSD kernel, and traffic runs
against FreeBSD's own stack. Stock OTP is the reference for the socket
interface, through OTP's suites and scenarios run on both. Pure cores
that are protocol state machines are explored exhaustively; decoders
have fuzz targets judged against references written from the RFCs; the
checksum folded into the copy is checked differentially against the
plain checksum. Every test is paired with a seeded fault: a deliberate
fault, kept as a fixture, that the test must catch, which proves the
code under test ran. The seeded faults are listed with each part.

### Codecs: fuzz targets

One fuzz target per decoder, in `erx_net`'s `test/*_fuzz.erl`, run by
`make check-fuzz`: Ethernet, ARP, IPv4 with options, IPv6 with extension
headers, ICMP, ICMPv6 with neighbour-discovery options, UDP, TCP with
options, DHCP, epmd's requests, and the socket protocol's requests
through the generated validators. `erx_net_client` adds two: the
packet-mode framing (`erx_net_packet:decode/3` and `erx_gen_tcp_core`
over random streams pushed in random pieces within its credit, in every
mode, whose packets must equal a reading of stock's framing written from
ERTS's `packet_get_length`, and the same streams against stock's inet
driver on the host's loopback), and `erx_sock_admit` over random terms
and over well-formed pushes and grant answers with one field changed,
which must accept exactly what a reference judge written from the
protocol's types accepts.

Each target checks that the decoder never raises; that encode then
decode returns the record; that it accepts or refuses as a reference
judge does, a short function written from the RFC's validity rules
alone; and that on frames both accept, its fields agree with an
independent decoder, `pkt` (github.com/msantos/pkt, BSD-3-Clause),
fetched at a pinned commit as a test oracle and kept out of the tree.
Generators bias lengths to the edges (empty, one short, exact, one
long). A target whose decoder checks a checksum sets the correct sum on
most inputs, so the fields behind it are reached, and a wrong one on the
rest, which decoder and judge must both refuse. The IPv6 and ICMPv6
judges read the packet by absolute offsets and state the whole decoded
record and, for a refusal FreeBSD answers with a parameter problem, its
code and pointer, which pkt does not decode.

*Seeded faults:* a decoder that trusts the IPv4 total length without
checking it against the frame, and one that accepts a TCP data offset
below 5, must each fail its target within budget; one that accepts SACK
blocks on a SYN must fail the agreement with the judge; so must an IPv6
decoder that points a routing header's parameter problem at its
segments-left byte, and an ICMPv6 decoder that takes an MTU option
longer than one unit; and an `erx_sock_admit` whose credit check is off
by one, one that admits a push one byte longer than a piece, and one
whose answer check leaves out the node comparison.

### Checksums and random values: the interface's gate and the generators

A host test drives the interface process, through the pipe driver's
`process` end with stand-in sockets: a segment with a correct checksum
is delivered; with one payload bit flipped it is not delivered, is
counted as a bad checksum and leaves the connection's credit as it was;
and sent to a closed port it draws no RST, to a listener no SYN-ACK and
no syncache entry, and leaves the ingress bucket's tokens unchanged, as
FreeBSD drops it silently. *Seeded faults:* a `verify/1` that skips the
checksum; an interface that answers a frame naming no socket from its
pending value before `verify/1` runs, which sends the RST.

The random values are checked over the interface core, a datagram
socket's step, a connection's step through an active open and
`erx_dhcp4_core`, each run from a fixed key over a script that draws
every kind of value the module makes: the same key gives byte-identical
actions; a different key changes each kind of random field and nothing
else (compared with the random fields masked); successive datagram
identifications and detection-probe nonces are the key's successive
draws, computed by the test with `erx_net_rand` alone; and a spawned
owner's generator is `new/1` of the two blocks its spawner's generator
gave at the split, the spawner's next draw the block after them.
*Seeded faults:* an `ip_fillid` that counts instead of drawing; a
sub-core that returns the generator it was given instead of the one it
advanced (a repeated nonce); a step that draws from `rand:uniform/1`,
which the build check below must also refuse; a `split/1` that gives the
child the parent's key and counter.

### The checksum in the copy: differentials and a lying sum

These test [Checksums in the copy](#checksums-in-the-copy). The oracle
throughout is the plain checksum, `erx_inet_sum` in C and
`erx_bytes:inet_csum/2` in Erlang.

* **The core.** `erx_inet_copy_sum` over lengths 0 to 9,014, both
  parities of `offset`, source and destination at every alignment modulo
  8: the destination equals the source and the sum equals `erx_inet_sum`
  over it. The `inet_csum` fuzz target checks the same under
  AddressSanitizer. *Seeded faults:* a loop that leaves out a last odd
  byte, and one that skips the swap at an odd `offset` (the test); a loop
  that reads one word past `length` (the fuzz target).
* **The span.** `erx_net_sum:span/4` over random binaries up to 9,000
  bytes, every even `Start` and every `Length` that fits, must equal the
  plain sum of the part as a one's-complement value. *Seeded fault:* a
  trailer left unswapped at an odd offset.
* **The decoders, two ways.** Each decoder above IP is fuzzed with
  `none` and with the true sum; the results, refusals included, must be
  identical. *Seeded fault:* a TCP decoder that adds the pseudo-header
  twice when given a sum.
* **The encoder, two ways.** `encode/4` with `driver`, finished by an
  Erlang model of the finisher, must equal `encode/4` with `sender`; a
  host transport's NIF running the core over a frame's pieces is checked
  over its fake ring the same way. `post_frame/5` is checked end to end
  below, since the hosted runtime's GENET stand-in finishes no checksums.
  *Seeded fault:* a delayed field without the segment's length.
* **The interface's gate, with a lying transport.** The pipe hands up
  `{sum, S, Frame}`: a correct segment with its true sum is delivered; a
  wrong sum is not, is counted as `bad_sum` and leaves the credit as it
  was; a flipped payload bit handed up with the true sum of the flipped
  bytes is not delivered, since the checksum field no longer matches;
  nor is that segment handed up without a sum. *Seeded faults:* a
  `verify/1` that ignores a given sum and sums the bytes itself (the
  test that shows the sum is used); one that skips the check.
* **End to end.** The network QEMU suite's TCP transfer to the host's
  peer runs through `complete/3` and `post_frame/5`; a wrong sum either
  way stalls it. The transport's start line names `finish copy` or
  `finish device`. On the FreeBSD test host the netmap run through the
  VALE switch to a jail must end with the jail's bad-checksum discards
  (`netstat -s -p tcp`) and the stack's `bad_sum` unchanged. *Seeded
  fault:* a `post_frame/5` that stores the sum uncomplemented.

Three measurements are on the [watch list](todo-performance.md): the
bulk transfer's stage breakdown under HVF, the FreeBSD run over tap and
netmap, and the copy core against a copy followed by a separate sum.

### Classification and framing

The fuzz target of `erx_net_input` generates whole frames (Ethernet and
loopback; IPv4 with options and IPv6 with extension headers and
fragments; TCP, UDP, ICMP and ICMPv6 errors with quotes, echo, neighbour
messages, ARP and other protocols; each cast of link destination), a
random view with link-local addresses in two zones, and a demultiplexing
map keyed mostly from the frame's own fields so lookups hit; on a DHCP
interface it biases IPv4 towards UDP port 68 with malformed options,
foreign destinations and fragments whose payload reads as port 68. It
runs `classify/2` and then `verify/1`, and checks that neither raises
and every verdict and reason is of the closed sets
[Classifying a frame](#classifying-a-frame) lists; that verdict,
destinations and reason agree with a reference judge written from that
section's table alone over `pkt`'s decoding; and that changing the
checksum above IP, or any byte above IP the table does not name, never
changes the verdict and changes `verify/1` only to a drop for its sum.
*Seeded faults:* a UDP lookup by port alone; a TCP segment to a
broadcast destination kept for a listener; a RST flag read to drop a
segment before verification; link-local keys built without the zone;
port 68 taken for DHCP only after the IP decision refused the packet as
`not_ours`, by re-decoding it.

`erx_net_frame`'s tests on fixed configurations check `path/3` (gateway
or destination, longest match across interfaces, loopback for the
stack's own address in its zone, the zone's interface, and the
`enetunreach` and `eaddrnotavail` refusals); the `via` paths of an
unconfigured interface (the DHCP broadcast from `0.0.0.0`, the router
solicitation from `::` to `ff02::2`, the duplicate address detection
solicitation, while a socket's datagram to `255.255.255.255` without a
route is `enetunreach`); hop limit 1 for multicast, the IPv6 link MTU and
source address choice; looped broadcast and multicast and the ICMPv6
error to the interface's own link-local address through loopback; that
every frame decodes back, checksums checked, to the segment with its ECN
field, don't-fragment and identification; that a connection's framed
segments classify at the peer to the same `segment()`; and that an IPv4
connection whose MTU drops from 1,500 to 1,280 mid-transfer sizes its
next segment to it and `tcp/3` never returns `emsgsize`. *Seeded faults:*
a `path/3` that looks a route up for every destination; the interface's
hop limit taken for a multicast; a sender that loops nothing; a loopback
that drops the zone; an output that sizes by `t_maxseg` alone; a path
that addresses the destination although the route has a gateway; an
encoder that writes ECN into the DSCP bits; a multicast mapping that
keeps 24 low bits instead of 23.

With the processes, host tests check the published state: one stale
row seen by two transmitters gives one hint; an interface killed after
publishing leaves no rows once `erx_net_tables` has its monitor message,
while a restarted incarnation keeps its own and never sees the old one's;
a router advertisement that only extends lifetimes moves no generation,
while deprecation does; segments reinjected after a connection ends
reach a listener of the port or draw a limited RST, none for a link
broadcast. *Seeded faults:* a hint loop without the count (two hints);
an increment by `update_counter/4` with a default (a row left behind); a
deletion keyed by interface name (the new incarnation's rows lost); a
`snapshot/3` without the pid check (the old address shown); rows that
carry their deadlines (the generation moves on refresh); a reinjected
segment looked up by its full key (lost to the dead pid).

### Reassembly and buffers: properties against a byte map

`erx_ip4_reass`, `erx_ip6_reass`, `erx_tcp_reass` and the receive buffer
are checked against a model recording every byte position: over random
overlapping, duplicate and out-of-range pieces, the delivered bytes
equal the model's, RFC 5722's discard happens exactly when the model
sees an overlap, and the held bytes never exceed the caps. *Seeded
fault:* a reassembly that accepts overlapping IPv6 fragments.

### The TCP core: exhaustive exploration

`erx_tcp_explore` drives a connection with small buffers and windows,
and a model of its peer, over an abstract alphabet: segments with every
combination of SYN, ACK, FIN and RST, with or without data, at each
sequence position class (below the window, at `rcv_nxt`, inside, at the
right edge, beyond) and acknowledgement class (below
`snd_una - max_sndwnd`, old, at `snd_una`, in flight, at `snd_max`,
beyond), plus user requests (send, recv, close, shutdown, abort) and
expirations. It explores breadth-first, applying every event in every
state, merging states that agree on an abstraction of the control block
(TCP state, FIN state, which send and receive variables are equal, which
deadlines are set, the recovery state) and on how the peer model stands
against the connection (its window's right edge, its SND.WL1/WL2 and
furthest acknowledgement, urgent bytes ahead), until no new abstract
state appears or to depth 8. The whole exploration runs again with
initial sequence numbers just below 2^32, so every class is also crossed
at the wire boundary. On every transition it checks:

* `snd_una =< snd_nxt =< snd_max`, and `rcv_nxt` never decreases;
* no byte is delivered twice, out of order, or beyond what the peer sent;
* no segment is sent beyond the peer's window, except a one-byte window
  probe. The window is the peer model's newest, kept by the SND.WL1/WL2
  rule as FreeBSD's step 6 applies it, counted from the furthest
  acknowledgement taken: FreeBSD takes the window of an acknowledgement
  below `snd_una` as counting from `snd_una` (`tcp_input.c` step 6),
  where RFC 9293 ignores it. The one window the connection may leave
  untaken is that of a segment FreeBSD could count as a duplicate
  acknowledgement before step 6 (`tcp_input.c` 2568-2606);
* a RST resets only at exactly `last_ack_sent`; challenge ACKs never
  exceed their limit;
* an old acknowledgement never changes the send window;
* every state change is one RFC 9293's state diagram allows;
* where header prediction accepts a segment, the general stages give the
  same state and actions;
* an urgent byte taken at `rcv_nxt` with nothing held for reassembly,
  before the peer's FIN, is kept out of the stream (`tcp_pulloutofband`);
* the step never raises.

Dimensions the base alphabet leaves out, each of which would multiply
its size, run as explorations of their own (the base plus that
dimension's segment variants, none of a RST, which is judged before
anything a dimension varies; the abstraction widened by the state it
reads, to depth 5 to 8): **timestamps** (absent, older, equal, newer than
`ts_recent`, negotiated or not, so PAWS is reached in every state; the
clock never reaches `TCP_PAWS_IDLE`, so `ts_recent` is never invalidated
by age);
**ECN** (ECE, CWR, CE); **urgent data** (pointer inside, beyond the
segment, beyond the window; no pointer reaches past `SB_MAX`, so the rule
that drops such an URG is not explored); **SACK** (no block, inside the flight,
beyond `snd_max`, below `snd_una`); **the peer's window** (zero, below
one MSS, full; window scaling; FreeBSD's least MSS, `tcp_minmss`, 216
bytes, larger than the base's buffers, so this dimension's connection
has a send buffer of two such segments and more, and one output pass
sends more than one segment, `sendalot`; MSS and window scale on a
non-SYN; `sndbuf` raised and lowered by a quarter and by half the
buffer, with a stand-in socket process spending its send
credit, so the grant rule meets persist); **ICMP reports**
(fragmentation-needed or packet-too-big and unreachable, quoting
`snd_una`, below it, `snd_max`, and 2^31 past `snd_una`, which a
comparison of wire numbers rather than lifted ones would misplace).
Their added properties: a segment PAWS drops changes no sequence state,
window or `ts_recent`; a report quoting a number outside `snd_una` to
`snd_max` changes nothing; a window probe is sent only while the peer's
window is zero; no state leaves room in the send buffer ungranted while
no credit is outstanding, bytes wait and everything is acknowledged or
the window is zero; buffered bytes plus outstanding credit never pass
the buffer's size; no segment carries more than the MSS; CWR is sent only
after a window reduction (`cc_cong_signal` owes it for `CC_ECN`, `CC_RTO`
and `CC_NDUPACK` alike); and an unnegotiated option, or MSS and window
scale without SYN, changes nothing.

*Seeded faults*, each caught with a named property and the shortest
trace: the window update without the WL1/WL2 rule; a window that never
shrinks; a shrink ignored on a pure acknowledgement at `snd_una`; a
duplicate acknowledgement counted whatever window it offers; an urgent
byte delivered in band; RST accepted anywhere in the window; RST judged
against `rcv_nxt` with an acknowledgement delayed; `rcv_nxt` advanced
without lifting; an ICMP report acted on without its sequence check, or
checked against `snd_max` alone; header prediction that skips the PAWS
precondition; PAWS that never drops an older segment; challenge ACKs
counted past their limit; a grant rule whose second clause asks only
that every byte sent be acknowledged, which a full buffer behind a zero
window, a probe out and `sndbuf` raised by a quarter must leave with
room ungranted.

### The syncache: properties at its boundaries

`erx_tcp_syncache` is pure and is checked with virtual time against
FreeBSD's rules: a cookie validates now and after one secret rotation,
not after two (15 to 30 s); the fields recovered from it (MSS and
window-scale indexes rounded as `tcp_sc_msstab` and `tcp_sc_wstab`
round, SACK permitted) equal the SYN's; a changed MAC bit or another
four-tuple does not validate; an unmatched ACK is checked as a cookie
exactly when the table was paused or overflowed in the last 15 s, at
15 s as FreeBSD's comparison decides; the table never exceeds its bound,
and a SYN that finds it full gets a cookie and no entry, drops every
entry and pauses the table; a pause lasts 15 s, doubled for each pause
that starts within the last one's length after it ended, to at most
960 s. *Seeded faults:* a rotation that drops the previous secret at
once; an overflow window measured with `=<` where FreeBSD uses `<`; a
pause held through the second it ends.

### The listener: exploration, the backlog and binds

**Passive open, explored.** `erx_tcp_listen_core` is explored
exhaustively with a model of the parties around it, each effect a
transition: the interface (reserving a unit, spawning, `go` or
`abandon`, its end), connections (verdict, adoption answered, refused or
met by an ended grant, links answered `noproc`, `{queued, C}`, `bind`,
`{bound, C}`, end or kill between any two), the listener (each message,
exit, deadline, pausing and resuming), acceptors and the listener's
socket process, and the shell's rules about ERTS: signals between two
processes arrive in the order sent, a link to an ended process delivers
its exit at once, and an exit already delivered stays in the mailbox
after an unlink. It runs over
three connections, two acceptors and an accept credit of limit 2, so a
handshake refused at the limit is reached. Three bounds keep it within
the landing gate: at most one end per run (two at the milestone gate)
and one pause; a step no other party can see is folded into the next
one another party can; and the listener's end is a run's last state,
since that no call is answered after it holds by construction. The five
seeded faults below each need at most one end. A state is final when no
party owes a step: what is left is the environment's to choose, an end,
an `accept`, a pause or the clock. In every reachable state: every live connection holds a unit of the accept credit
or is one of its grant's sockets; the units on the counter are those its
holders hold, plus one per holder killed inside its window, and without
a kill the counter is back at zero once every connection has ended or
been handed out, and it never exceeds the limit; every call of the listener's
socket process is answered exactly once and none is left in a final
state; `{ok, C}` comes only after `{bound, C}`, `bind` goes only to an
adopted connection and never twice; no call waits while a connection is
queued and live; a waiting call is answered `{error, timeout}` at its
deadline and not before, a handing call never; calls and connections
pair oldest first; and in a final state while the listener runs, every
call in flight waits on a live acceptor. *Seeded faults:* a connection
that sends its notice before its adoption (first and fourth
properties); a unit also taken back at `{bound, C}` (second); a listener
that drops an ended acceptor's call without a reply (third); a call
paired again after its connection's end (third); a pause that takes the
exits of every link, which queues a dead connection (third or second).

**The backlog and the hand-over, on a development host.** Under virtual
time ([The stack on a development host](#the-stack-on-a-development-host)),
a listener of backlog 1 that does not accept completes two handshakes
and the third's ACK draws a RST, as FreeBSD's does, and the same packet
script draws the same RST from the FreeBSD test host
([Packet scripts against FreeBSD](#packet-scripts-against-freebsd)).
Further cases cover data before `accept`, a queued connection reset by
its peer, closing a listener with connections queued, a grant whose
`buffers` cannot hold another connection, 65 acceptors killed while
waiting, `accept` timeouts, a four-tuple already held at insertion,
options set on a listener reaching accepted sockets, a stale
`erx_net_bind:update/2`, and the MSS offered per interface and after a
route's MTU falls. *Seeded faults:* a credit limit equal to the backlog;
a queued connection that drops its receive queue for want of an owner;
no unit taken back at a queued connection's exit; a queued connection
that ignores its listener's exit; a connection that carries on after a
refused adoption; a listener that drops an ended acceptor's call (the
65th `accept` waits for ever); no timer armed for an `accept`'s
deadline; no release at `abandon`; a listener option applied without
rewriting its entry; `update/2` written with `ets:update_element/3`
(another grant's socket loses its key); the MSS taken from the
listener's entry; the MSS kept with the syncache entry.

**Against stock.** A connection reset before any `accept`, then an
`accept` with a 100 ms timeout, answers `{error, timeout}` on erXos; the
same script runs against stock OTP 29.1.2 on the FreeBSD test host and
in the Linux oracle guest, where the departure of
[The listener](#the-listener) expects a socket whose first `recv`
returns the error. The case is a documented difference: it fails when
erXos's answer changes or when stock's stops differing. *Seeded fault:*
a listener that keeps an ended connection queued. One scenario of
`listen`, `accept` and `controlling_process` runs on stock `gen_tcp`
over the host's loopback and on `erx_gen_tcp` over `lo0`, and every step
must answer the same. A port held only by a loopback connection in
TIME-WAIT is checked against FreeBSD's rule instead
([TIME-WAIT](#time-wait)): a `listen` without `reuseaddr` succeeds once
the 20 ms have passed; stock is compared on FreeBSD only, since on macOS
stock is refused for longer (its `net.inet.tcp.msl` is 15 s; its source
is not read here). *Seeded fault:* every path built with `loopback`
false, under which the `listen` is refused for 60 s.

**Explicit binds.** `erx_net_bind:avail/2` is checked case by case
against the five rules of
[Ports and the demultiplexing table](#ports-and-the-demultiplexing-table),
within one grant and across two, including port 0 within an allowed
range. The cases within one grant also run through stock
`gen_tcp:listen/2` on the FreeBSD test host and must match, except
`reuseport` on both on one address, which FreeBSD allows and erXos
refuses, a documented difference. *Seeded faults:* rule 3 left out;
keys of both transports read; a port-0 walk that skips rule 2.

### The send log, loss and congestion: properties and a FreeBSD oracle

The RFC 6675 scoreboard computed from the send log is checked against
RFC 6675's definitions over a byte map. CUBIC's arithmetic is checked
differentially against FreeBSD's own: the inline functions of
`cc_cubic.h` at the pinned commit, compiled on the host as a test
harness, over random inputs. `erx_tcp_rtt` is checked against RFC 6298's
formulas. *Seeded fault:* CUBIC's `K` with a rounding direction
reversed; the differential must report the first diverging input.

### Packet scripts against FreeBSD

FreeBSD's TCP test suite (github.com/freebsd-net/tcp-testsuite,
BSD-3-Clause, fetched at a pinned commit) is a set of packetdrill
scripts covering every segment type in every TCP state, overlapping
received data, the socket API and ICMP, in IPv4 and IPv6. Two runners
execute it:

* **On FreeBSD.** The FreeBSD x86-64 test host, running FreeBSD
  16.0-CURRENT, runs the scripts with nplab's packetdrill, the version
  the suite names. packetdrill is GPL-2.0, so it is built and run only on
  that host as a test tool, never linked to or shipped with anything of
  erXos's. Each run writes one verdict record per script: the suite's
  commit, the script, its verdict, the kernel's identity as
  `freebsd-version -k` and `uname -v` print it, and packetdrill's
  version. The records are raw run data and live in the separate history
  repository.
* **On erXos.** `erx_net_script`, erXos's own runner in Erlang, reads
  the scripts' language, with no code of packetdrill's, and drives the
  stack under the virtual clock ([The clock](#the-clock)) against the
  pure core and against the whole stack on a development host through
  the pipe driver's `process` end, so the effect layer runs too. The
  whole-stack runs are made twice, the second through the `process`
  end's offload mode, which cuts runs and batches bursts through the C
  of the cut and the merge
  ([The fast path](#tests)).

The oracle is a moving -CURRENT, so a comparison names the kernel it
compares with: every script's verdict on erXos must equal its verdict in
the newest record. A difference is a bug, a documented departure with a
test, a recorded FreeBSD bug, or a change FreeBSD made after the pin
(`975e3605ebb1`), recorded with the FreeBSD commit that made it. A
difference that a change between `release/15.1.0-p6` and the pin
explains is a bug of the port when the wire can see it, since those
changes are ported ([Provenance and notices](#provenance-and-notices)).
A script whose verdict differs between two FreeBSD records is taken as
a change FreeBSD made after the pin until shown otherwise, and is triaged
against the pinned source before any erXos verdict is judged against the
newer record. erXos's own scripts, run by both runners, add the
decisions this document names that the suite does not cover: a RST at
`rcv_nxt` while an acknowledgement is delayed, which FreeBSD answers with
a challenge ACK because it judges against `last_ack_sent`; timestamps
present or absent against the negotiation; an acknowledgement of exactly
`iss` on either side of the old-acknowledgement bound; FIN-WAIT-2 ending
at its idle limit; and segments at the 2^31 sequence distance, which pin
the departure that lifting makes.

*Seeded faults:* the RFC 5961 RST check removed must fail the suite's
RST scripts on erXos; a script edited to expect a wrong window must fail
on both runners, which shows the runner compares fields; and an
interface loop that arms its timer a second after the core's deadline
must fail the retransmission scripts through the pipe but not against
the pure core, which shows those runs check the effect layer's timing.

### The stack on a development host

The host runs of [Running on a development host](#running-on-a-development-host)
take three peers:

* **QEMU's user networking on macOS.** A DHCP lease from slirp through
  the `-machine none` hub, ARP for slirp's gateway, UDP echo and a TCP
  transfer through slirp. *Seeded fault:* an ARP reply with sender and
  target swapped, under which the transfer times out.
* **FreeBSD's jails on the test host.** The stack runs on the host's own
  OTP over a tap device through [the tap transport](#the-tap-transport),
  against vnet jails on a bridge, whose stack is the oracle's own kernel.
  Bulk transfers, many short connections and request-response loads run
  between the stack and a jail through `erx_net_relay`, and the same
  loads between two jails under the same schedule are FreeBSD's
  baseline: the tests check completion, delivered bytes, and
  retransmissions and throughput within stated bounds of the baseline's.
  Each run's record names the kernel. `tools/erx bench net-freebsd`
  reaches the host by the ssh name `--host` or `ERX_NET_BENCH_HOST`
  gives. *Seeded fault:* SACK disabled on erXos must push its
  retransmissions past the bound under a loss schedule where FreeBSD
  recovers with SACK.
* **erXos itself.** Two stacks in one node, through their pipes'
  `process` ends to one `erx_net_relay` under the virtual clock, each
  pair in a node of its own with one scheduler ([The clock](#the-clock)),
  run bulk and short-connection loads under seeded schedules; long waits
  take no time. *Seeded fault:* a receive path that drops out-of-order
  segments must exceed the retransmission bound under reordering.

**The impairment.** `erx_net_relay` forwards frames between two ends (a
pipe-shaped `process` or `udp` end, or a tap device through
`erx_tap_nif`) through `erx_net_impair`, a pure state machine keyed by a
seed with per-mille loss, duplication and reordering and a delay range;
a reordered frame is held an extra delay, so that the frames after it
overtake it.
Each frame's fate is decided in order from an `erx_net_rand` generator,
one split per direction, and released through `erx_net_clock`, so under
the virtual clock a schedule is reproduced exactly and against real peers
the n-th frame's fate is still a function of the seed. A `udp` end is
pinned to its peer and drops strangers, as the pipe's does, so nothing
else on the network can put frames into a run. The same relay sits between a
QEMU guest's `dgram` backend and its peer in
[Traffic against FreeBSD and Linux](#traffic-against-freebsd-and-linux).
*Seeded faults:* a schedule that ignores the seed (two seeds must differ
over a thousand frames); one generator shared between directions (one
direction must not change with the other's traffic).

**The driver and the clock.** A host test drives the pipe driver with a
stand-in interface and checks its bounds: a batch refused by a full
receive credit is dropped whole and counted; a link that flaps while the
credit is full is not told, one that stays down is told once room
returns; the transmit backlog never exceeds the transmit credit's limit;
a flood from a stranger to a `udp` end never puts more than 65 messages
in the driver's queue; a `process` end's non-binary frame is counted as
`malformed`; the driver ends no sooner than a second after its start;
the link restarts to a new far end under a registered name; and a far
end that is never there restarts the link two to four times in 2.5 s
with the supervisors unchanged. A virtual-clock test checks that hints
arrive at or after their deadlines, one deadline per caller after a
million arms, and byte-identical frames from two runs of one script and
seed. *Seeded faults:* a frame's unit taken when its message arrives
(backlog past the limit); every link change queued (credit filled by a
flapping far end); a link notice retried only at later messages (the
silent link never told); a socket opened `{active, true}` (queue bound
exceeded); a `process` end without its type check (the interface
raises); a pipe that reports `down` on its far end's end while the
driver lives (the new far end never answered); a driver that ends at
once, or an interfaces supervisor at OTP's default intensity (the
supervisors end); a link start that fails when its driver crashes under
it (the stack's start fails); a socket arming its own
`erlang:start_timer/3` (the build check and the script's virtual
timing); an interface drawing its key from `erx_bytes:entropy/1`
directly (the build check and the byte-identical run).

**The tap transport.** On the FreeBSD test host, frames of 60, 1,514 and
9,014 bytes cross both ways unchanged, a run is cut into the frames
`erx_net_frame:cut/1` gives, and a destroyed tap ends the medium and the
driver. *Seeded fault:* a `send/2` that answers a run as taken whole when
the device would block before its last frame.

### Traffic against FreeBSD and Linux

Bulk transfers, many short connections and request-response loads run
between an erXos guest on QEMU and a jail of the FreeBSD test host, and
between erXos and the Linux oracle guest, through `erx_net_relay` with a
seeded schedule; for a jail the relay runs on the test host between the
guest's `dgram` backend and a tap device of the jails' bridge. The tests
check completion, delivered bytes, and retransmissions and throughput
within stated bounds of FreeBSD's own under the same schedule. *Seeded
fault:* SACK disabled on erXos, under the host runs' seed.

### The socket process: exploration and two domains

**The core, explored.** `erx_gen_tcp_core` is a protocol state machine
between the owner, the socket process and the socket, explored
exhaustively. The socket is modelled as the bytes its peer has sent and
the receive credit it holds, pushing at most a piece at a time, and as a
send buffer with a high watermark of 3 bytes that grants send credit by
both clauses of **Send credit**'s grant rule; the lane to the socket is a
queue with a busy limit of 2 bytes, whose outlet refuses at the limit and
then owes one notification, and the shell's rule that a refused
`next_out` leaves the core unchanged is part of the model. The alphabet
covers the socket taking from its lane or granting without taking, as a
hostile network domain may; spurious notifications; the peer sending,
acknowledging, closing and opening its window; `eof`, resets and the
socket's exit; `setopts` of each active mode and of `show_econnreset` and
`send_timeout_close`; `recv` and `send` from several callers with
deadlines; `shutdown`, `close`, `controlling_process`, the
owner's exit and out-of-order replies; and, from `opening`, the
hand-over and messages the network domain sends before the socket
process's first message. Depth 10, `buffer` 4, piece 2 bytes, 2 places
for calls. In every reachable state:

* before the hand-over the socket process holds nothing the network
  domain sent, and anything sent before its first message ends the
  opening;
* during a transfer it holds no more than the target, whatever is pushed;
* the bytes owners receive are a prefix of the peer's, each to one owner
  once;
* the socket's bytes are the sends in call order, each whole or short by
  exactly the `Rest` of an `{error, {timeout, Rest}}`, and no byte given
  back reaches the peer;
* no push or piece exceeds a piece, and at most 2 calls are in flight;
* bytes sent never exceed send credit, and the buffer's size is never
  less than its bytes plus credit outstanding; no send waits for credit
  while the grant rule owes one;
* a `send` is answered `ok` only once its last byte is queued; nothing is
  sent after `shutdown` or `close`;
* at the socket's end, the first waiting send (or the first after it) is
  answered `econnreset` exactly when the end is a reset and
  `show_econnreset` is on, `closed` otherwise, and every other send
  `closed`, as stock's socket backend answers;
* nothing is presented after `{active, false}` is answered, nor during a
  transfer; the active count is stock's (`{active, N}` adds `N`;
  `{tcp_passive, S}` exactly at zero or less); the end is presented once,
  after every byte held;
* bytes held plus credit outstanding never exceed the target; no recv
  waits while the socket holds bytes it may not push, no grant is in
  flight and the lane is not refused; every call is answered once, `close/1`
  without waiting for the lane;
* the lane holds no more than the busy limit and one message past it,
  whatever the socket grants, and the socket process is never refused
  with no notification owed.

A run in which the socket grants without taking keeps no send buffer of
its own, so only the lane's bound, the order of sends and the answers to
calls are checked in it.

`erx_gen_udp_core` is explored the same way (datagrams of 1 to 3 bytes,
a floor of 6 for the target), adding that no datagram waits in the
socket while the socket process holds nothing.

*Seeded faults:* a push presented during a transfer (order, two
owners); every push postponed during a transfer, as stock's
`gen_tcp_socket` does (transfer bound); a push postponed in `opening`;
first send credit granted at link, before receive credit (an opening
ended); credit granted again when a push arrives rather than when it is
presented (passive bound); grants only at half the target, never for a
waiting recv; `tcp_passive` before the count's last delivery; a second
caller's piece before the first send's last byte; pieces cut at the
piece but not the credit; a send answered when its first piece goes;
waiting sends left in place at `shutdown`; a timed-out send's rest
dropped, or still sent after the answer; a waiting send answered
`closed` regardless of `show_econnreset`, or every waiting send given the
end's reason; a socket model without the grant rule's second clause; a
call past its places dropped; the active count set rather than added; a
shell that keeps the core's next state on a refusal (a piece lost: only
committing on `ok` keeps it); refused receive credit counted as
outstanding; a refusal ignored (lane bound broken: the refusal is what
bounds it); a lane model that owes no notification; a datagram floor
equal to the largest datagram rather than twice it.

**The connection's side of send credit.** A host test drives a
connection from a stand-in socket process against a peer acknowledging
on a seeded schedule: buffered bytes plus outstanding credit stay within
the size and the grant's reservation equals it, autosizing included; a
fresh connection pushes nothing before its first receive credit; grants
follow the grant rule in the full-buffer, zero-window, probe and raised-
`sndbuf` cases; a lowered `sndbuf` lets credit already taken be spent
without an abort, the reservation falling as it goes; request-reply
costs one credit message per half buffer; bytes past the credit or after
`shutdown` end the connection with a RST and `{error, econnaborted}`; a
stand-in that exits closes with a FIN after its bytes, also while paused.
The grant rule, a pure function, is checked over every state up to 8
bytes. *Seeded faults:* grants when a segment is sent rather than
acknowledged; grants only at half the buffer, never at its start; no
second clause; a second clause asking only that every byte be
acknowledged; a second clause ignoring outstanding credit (one credit
message per exchange); the reservation lowered to a new `sndbuf` at once;
bytes past the credit taken into the buffer; a pause that takes the
exits of every link (the FIN without the bytes waiting in the mailbox).

**What the bench must show.** The network bench
(`bench/erx_net_bench.erl`) runs rr-64 at `+S 1:1` and with default
flags, and bulk send and receive of 512 MiB, against master in
interleaved rounds on the FreeBSD x86-64 test host. It must show the
send's reply and the socket process's schedule gone from rr-64's trace,
one message a transaction fewer than master, CPU per transaction lower
beyond the rounds' spread, and bulk within noise, reproducing within the
spread the figures of the throwaway change whose record
[todo-performance.md](todo-performance.md) cites. On the test host every socket
is in one domain, so the outlet sends plainly and refuses nothing. On QEMU under HVF with
the owner in a test domain, rr-64 and a 64 MiB bulk send are recorded
against master with the lane crossings per transaction (two) and the
outlet's refusals and notifications: with a network domain that keeps
up, refusals occur only while the queue is past the busy limit, each
followed by one notification, and the tail copied is at most the busy
limit and two pieces. The same runs with the bell of
[design-runtime.md](design-runtime.md#connections-in-erts) in place of
the notification are recorded first, so the gain over the bell is a
measured number.

**Two domains on QEMU.** An owner in a test domain beside the network
domain runs stock code unchanged: active-mode receive loops,
`controlling_process` with data in flight, owner exit, socket process
and connection killed, and a passive socket whose owner never reads
(the window closes while the socket process holds no more than its
`buffer`). With `max_frame` at 128 KiB, sends of 1 MiB and 100 MiB, an
8 MiB `recv`, 100 concurrent senders on one socket and 100 acceptors
complete byte for byte, and an `accept` behind 64 waiters times out as
[Requests in flight](#requests-in-flight) documents. A domain whose
`max_frame` (64 KiB, or 1 byte, the least admission allows,
`liberx/system/dom_core.c`) or `max_message_heap` (1 KiB) is below the
floor gets `{error, enobufs}` at once from `connect`, `open` and
`getifaddrs`, no request reaches the grant, and its log names the limit
and the floor; with `max_frame` at the generated floor, `getifaddrs/0`
over 64 interfaces of 64 IPv6 addresses each is answered whole. A third
domain holding the socket term and connection pid sends crafted data
messages, none of whose bytes may reach the owner; another process of the
owner's domain sends the connection a request and a piece, with no
effect. A 100 MiB send to a peer that pauses reading completes with the
send buffer within its watermark. `{packet, 4}` with `send_timeout`
answers `{error, {timeout, Rest}}` and the owner can finish the packet
in `raw` mode, as OTP's `otp_7816` case does; under
`send_timeout_close` the answer is `{error, timeout}` and the peer sees
a close. `show_econnreset` answers as stock's socket backend does, for
one and for two waiting writers. A lying grant's open answer naming a
pid of another domain, and an interface name holding an escape byte,
are each answered `{error, badarg}`. *Seeded faults:* an
`erx_sock_admit` that takes `{erx_origin, _, Inner}` without comparing
the origin (the third domain's bytes reach the owner); a connection that
skips its `ReplyTo` check; a socket process that passes a push on
without taking its envelope off (stock loops wait); a send sent whole,
or all credit pushed in one message (frames past `max_frame`: the 1 MiB
send loses bytes, the 8 MiB recv hangs); `erx_inet` without the floor
comparison, or checking only `max_frame` (the hang the check turns into
an error); a floor generator that ignores the grant's replies; a
timed-out send's `Rest` still sent (a corrupt second packet); an answer
check without the node comparison (the lying grant's open answers
`{ok, S}`).

**A network domain that stops draining.** Test domains stand in for a
hostile network domain. One opens connections whose sockets grant send
credit and are then suspended behind a small `-erx queue_quota`, so the
lane fills: in the owner's domain a timed `send` and `recv` answer
within twice their timeouts, `close/1` returns at once, and the socket
process is gone within a second of the owner's exit; with extra grants
and pushes that the owner consumes, the owner domain's queue for the
network domain stays within the busy limit and a frame per sending
process, and withheld receive credit reaches the socket as one grant
once the lane drains; a timed-out 100 MiB send whose `Rest` the caller
drops leaves no more than the busy limit and a piece of that binary in
the owner's domain. Started with `+pad true`, the owner's socket
processes report `{async_dist, false}` and the queue bound holds. A
second hostile domain, at the open, pushes 10,000 grants and data
messages and 10,000 linked processes that exit: the socket process stops
with `econnaborted` at the first and keeps no state from any (its queue
bounded by the runtime's quota, which the test sets), and the open
answers `{error, econnaborted}`; a half-finished `controlling_process`
under an endless push keeps the socket process within its target and a
waiting `send` meets its deadline. A socket process started in a client
domain is reachable from the grant's domain with `send` and `link`, by
`erx:exports/1`, before its open request is sent. *Seeded faults:* a
socket process without `{async_dist, false}` under `+pad true` (queue
past the bound); messages from the network domain postponed in
`opening`, or every push postponed during a transfer (queue past the
test's bound); an `expose/2` that exports `[link]` alone (never pushed
to); one that exposes before it traps exits (a unit test traces the
start and requires `process_flag(trap_exit, true)` before
`erx:export/3`); an outlet that sends without `nosuspend` (the `send`
and `close` hang); a socket monitored rather than linked from the
network side at take-over (the `close` hangs on a stalled lane); each
refused receive grant kept as its own message (one grant per half
target, not one); no copy of a piece cut from a larger binary (the whole
100 MiB binary held).

**cowboy and ranch.** In the web domain's front end
([design-web.md](design-web.md#the-network-front-end)), cowboy serves
HTTP requests and a WebSocket echo in the web domain over the stack,
with ranch's acceptors and cowboy's own `active_n`, unchanged. *Seeded
fault:* a socket process that never sends `{tcp_passive, S}`, which
stalls cowboy's connections once their count runs out.

### OTP's suites

`make check-oracle` runs OTP 29.1.2's `gen_tcp_api_SUITE`,
`gen_tcp_misc_SUITE`, `gen_tcp_echo_SUITE`, `gen_udp_SUITE` and
`inet_SUITE`, the `socket` suites, and `ssl` and `ssh` over the stack, on
erXos and on stock on the host, and compares them case by case. On erXos
the suites run in a test domain and the stack in the network domain, so
every case crosses a lane through a socket process. An `erx` socket is
not a port, so cases that branch on `is_port/1` take their
socket-backend branch on erXos and their port branch on stock, and
compare as passed against passed: `otp_7816` and the
`econnreset_after_async_send` cases among them, which check the send
results that **Send credit** in [The socket process](#the-socket-process)
chooses. *Seeded faults:* an `inet_backend` default left at `inet` (no
inet driver exists, so the suites fail, which shows they reach
`erx_gen_tcp`); a `controlling_process` that does not move queued socket
messages to the new owner.

### Floods and failure

On QEMU, against the targets of plan.md's network gates: SYN floods,
minimum-size frame floods, fragment floods, connection floods, router
advertisements from many sources, invalid frames, and frames with valid
checksums aimed at one client's established connection, at line rate,
while another client's connection and neighbour resolution keep running.
The tests check bounded memory in the network domain, the other
connection's progress, the flooded client's sockets spending per period
(measured from outside the account) no more than its share plus the
overrun bound, and drop counters by reason. Failure tests kill the
driver, an interface process, a connection, a grant and the whole
network domain under load, and check the survivors of
[Concurrency and failure](#concurrency-and-failure). With the runtime's
queue quota, a test network domain floods the socket process of a client
domain whose runtime sets one with messages of no protocol, unanswered requests and pushes past its
credit: the socket aborts at the first breach, the client's memory stays
within its socket processes' targets and the quota, and a second socket
of the same client still progresses once the flood stops.

*Seeded faults:* the syncache bound removed (memory under the SYN
flood); credits disabled (a connection's mailbox under a junk flood to
its four-tuple); the router-list bound removed (interface memory under
the advertisement flood); the checksum verified before the credit check
(the interface's time per dropped frame); a socket that charges no
reductions (the flooded client past its bound); the client's queue quota
unset (its memory under the flood to its socket process).

### Build checks

Each with a test proving it catches a violation:

* only `erx_tcp_seq` does sequence-space wrap arithmetic;
* only `erx_net_bind` inserts into the demultiplexing table or rewrites
  an entry in it, the latter only by a listener's `update/2`;
* only `erx_net_if` writes the configuration and neighbour tables, the
  hint count's increment by a transmitter and `erx_net_tables`'s
  deletion of a stopped interface's rows excepted;
* only `erx_net_tables` reads the configuration tables, so every reader
  gets them through its `configuration/0` and `snapshot/3`'s pid check;
* only `erx_net_credit` sends packet batches between stack processes;
* only `erx_net_clock` reads a clock or arms a timer in `erx_net`, but
  the driver's hold and the Pi 4 Ethernet's MDIO and PHY waits, which
  pace a supervisor or a device on the host's clock: no other module
  calls `erlang:monotonic_time`, `erlang:system_time`, `os:timestamp`,
  `erlang:start_timer`, `erlang:send_after` or the `timer` module, or
  writes a `receive ... after` with a timeout other than `infinity` or 0,
  and no module of `erx_net` or `erx_net_client` makes a `gen_server`,
  `gen_statem` or `gen` call whose timeout is not the literal
  `infinity`, so the virtual clock sees every wait but a socket
  process's deadlines ([The socket process](#the-socket-process)) and the
  resolver loader's wait before it looks for a grant again, which no
  packet depends on ([Name resolution](#name-resolution));
* in `erx_gen_tcp` and `erx_gen_udp`, no function the socket process's
  `gen_statem` callbacks reach, by `xref`'s call graph, sends, links,
  monitors, demonitors or makes a call but through `erx_sock_out`: its
  `send/2`, the refusing send to the socket; its `local/2`, a plain send
  to the owner or a caller; and its `watch/1`, the owner's monitor. The
  last two refuse a pid of another node, so the socket process reaches
  another domain only through the refusing send; replies are
  `gen_statem`'s own, to callers of its own domain
  ([The socket process](#the-socket-process));
* in `erx_net_client`, only `erx_sock_out:start/2` starts an
  `erx_gen_tcp` or `erx_gen_udp` process, always with
  `{spawn_opt, [{async_dist, false}]}`, and nothing else sets
  `async_dist`, so a socket process is refused at the busy limit in any
  runtime, whatever its `+pad` default;
* in `erx_net`, only `erx_net_admit:mint/2` admits a mint, and it
  refuses the system domain's id as a grantee ([The grant](#the-grant));
* in `erx_net` and `erx_net_client`, only `erx_net_admit` and
  `erx_sock_admit` match a tuple tagged `erx_origin`, so each side of
  the socket protocol takes the envelope off in one place; D18's source
  check ([design.md](design.md#chokepoint-checks)) covers OTP's modules
  and this is that check for the stack's two protocols;
* in `erx_net_client`, only `erx_inet` reads the application's `grant`
  key, so every answer of the grant passes `erx_sock_admit`
  ([Untrusted input](#untrusted-input));
* no module a TCP payload passes through copies or joins it in Erlang
  outside the sites the fast path lists
  ([The fast path](#copies));
* only `erx_gen_tcp` and `erx_gen_udp` build a socket term
  `{'$inet', _, _}`, so no message the network domain sends has the shape
  of a stock socket message;
* a received segment, datagram or ICMP record is constructed only by its
  `*_wire` decoder; that the decoder checks the checksum first is not
  visible to a build check, and the fuzz targets with wrong sums and the
  interface's gate prove it ([Codecs: fuzz targets](#codecs-fuzz-targets));
* no module of `erx_net` calls `rand`, only `portable/erx_bytes` calls
  `crypto`, and only `erx_net_clock` calls `erx_bytes:entropy/1`, so
  every random key passes the clock's seam;
* the modules in `src/` of `erx_net` and `erx_net_client` call only
  `erts`, `kernel`, `stdlib`, their own application and `erx_bytes`; only
  `erxos/` (`erx_virtio_net`, `erx_genet` and its modules, `erx_net_erxos`,
  `erx_net_client_erxos`)
  calls erXos's modules or BIFs; and no include or file name reaches a
  path outside the app directory (N12);
* no `binary_to_atom`, `list_to_atom` or `binary_to_term` in `erx_net`;
* only `erx_netmap` calls `erx_netmap_nif`, and only `erx_netmap_nif.c`
  includes `<net/netmap.h>` or touches netmap's mapping, computing every
  address through the plan types of `erx_netmap_ring`
  ([The netmap transport](#the-netmap-transport));
* every module whose header carries a FreeBSD notice is listed with the
  same files in `NOTICE-freebsd`, and the reverse.

## Scope

The stack this document designs has three parts; plan.md orders their
work.

**The core,** which the sections above describe in full: Ethernet II;
ARP; IPv4 with reassembly, fragmentation on output and ICMP; IPv6 with
extension headers, reassembly, ICMPv6, neighbour discovery, duplicate
address detection, autoconfiguration with RFC 7217 identifiers and the
narrow MLDv2 listener; static configuration and DHCPv4; loopback; UDP;
TCP with the defaults of [Defaults kept](#defaults-kept); runs, their
cut in each transport's copy and the merge of received segments
([The fast path](#the-fast-path)); the grant, its
limits and its account; `gen_tcp`, `gen_udp` and `inet`; the POSIX socket
protocol; the resolver operation; the port mapper; and every test of
[Verification](#verification).

**Extensions,** each a FreeBSD decision translated by the same rules and
behind the same processes, with no change to the core's structure:

* `socket` and `net` over an Erlang `prim_socket`
  ([The `socket` and `net` modules](#the-socket-and-net-modules));
* raw ICMP and ICMPv6 sockets for `ping`, translating the parts of
  `raw_ip.c` and `raw_ip6.c` that `ping` uses: `erx_icmp_sock`, a datagram
  socket of the grant holding one echo identifier's demultiplexing key, so
  `ping`'s identifier filter is the classifier's
  ([Classifying a frame](#classifying-a-frame)) and its credit bounds the
  replies waiting for its owner;
* the device finishing what the copy finishes, a run's cut and a sent
  segment's delayed checksum, where virtio-net offers
  `VIRTIO_NET_F_CSUM` with `VIRTIO_NET_F_HOST_TSO4` and `HOST_TSO6`,
  behind the same requests
  ([Checksums in the copy](#checksums-in-the-copy),
  [The fast path](#device-segmentation));
* one interface process per receive queue on a device that hashes flows
  to several, so each flow still passes through one interface process
  and [Ordering](#ordering) holds;
* the TCP host cache, `erx_tcp_hostcache`, translating
  `tcp_hostcache.c`: a bounded table of path MTU, RTT and congestion
  values per destination, owned and published by one process, read by
  connections at their start and updated by a message from each at its
  end, as FreeBSD does;
* AccECN, FreeBSD's `tcp_do_ecn` modes 3 and 4 in `tcp_ecn.c`, not the
  default, as in FreeBSD;
* ICMP and ICMPv6 redirects, accepted as [IPv4 and ARP](#ipv4-and-arp)
  states;
* 802.1Q VLANs, translating `if_vlan.c`'s tag handling: a VLAN is an
  interface of its own whose driver is its parent's interface process;
* RFC 8981 temporary addresses, beside the stable ones, for outgoing
  connections where a program asks for them;
* multicast, `erx_mcast`, translating `in_mcast.c`, `igmp.c`,
  `in6_mcast.c` and `mld6.c`: group membership per socket, IGMPv3 and
  full MLDv2, and delivery to every member socket, each copy against that
  socket's credit.

**Outside the stack,** later, behind its seams: RACK-TLP as a loss
module; BBR as a congestion module, with pacing in output; DCTCP as a
congestion module over the ECN signal; TCP Fast Open (`tcp_fastopen.c`);
and TCP-MD5 signatures (RFC 2385), whose option `erx_tcp_wire` records so
that the syncache refuses a signed segment as FreeBSD refuses it for a
listener without TCP-MD5 (`syncache_add`, `syncache_expand`). None is
designed here, and none needs a change outside the seams it plugs into,
except pacing, which BBR brings.

## Decisions

These are settled; two questions remain open
([Open decisions](#open-decisions)).

1. **The grant's account covers its sockets.** Every reduction a grant's
   sockets spend, on requests and on packets, is charged to the grant's
   account, and socket processes' requests go straight to the sockets,
   which run the facet's generated admission path
   ([Sockets act for one domain](#sockets-act-for-one-domain)). This extends the
   facet mechanism, whose account otherwise covers the facet's own work
   and the requests it forwards. Routing every socket request through the
   grant costs two more local hops per call and still leaves
   packet-driven work, which has no request, unaccounted.
2. **RFC 7217 stable interface identifiers,** with a secret kept across
   boots as one of the vault's machine keys, used through a key facet so
   that it never enters the network domain
   ([IPv6, neighbour discovery and autoconfiguration](#ipv6-neighbour-discovery-and-autoconfiguration)).
   FreeBSD's default derives SLAAC addresses from the MAC address
   (EUI-64), which lets anyone who sees an IPv6 address track the machine
   across networks; RFC 8064 recommends RFC 7217, and FreeBSD 15
   implements it with the setting off. The departure is made for privacy;
   the identifier is stable only if the secret is, so the secret is kept
   with the machine's other keys, and a fresh installation makes it
   afresh, as it does the SSH host key.
3. **DHCPv4 is part of the core**
   ([Addresses and routes](#addresses-and-routes)), written from RFC 2131
   and RFC 2132 with FreeBSD's `dhclient` as the behavioural reference.
   QEMU's user network and most home networks hand out IPv4 addresses by
   DHCP, so a Raspberry Pi on a LAN needs it.
4. **Remote distribution in release builds runs only over the TLS
   carrier**
   ([Distribution to other machines](#distribution-to-other-machines)).
   OTP's plain TCP carrier authenticates by an MD5 challenge over a shared
   cookie and sends everything unencrypted; the TLS carrier authenticates
   both nodes by certificate and encrypts. Development builds allow both,
   since they run trusted code only.
5. **`socket` comes after `gen_tcp`.** The `socket` module is an
   extension built after `gen_tcp`; without it, `socket` answers
   `enotsup`, a documented difference with a test, and OTP's socket
   suites are expected failures.
   `gen_tcp`, `gen_udp`, `ssl`, `ssh` and distribution do not use
   `socket`, so nothing the system needs waits on it.
6. **Packet modes are framed in the socket process,** in the owner's
   domain, with ERTS's C `decode_packet`, as stock frames them in its
   inet driver ([The backend](#the-backend)). The framing must sit where
   the unpresented bytes are: a socket that pushes ahead within its credit
   has bytes in the socket process that a change of packet mode must
   still frame, as an HTTP server's switch from `http_bin` to `raw` needs.
   The parser gets a fuzz target over every mode offered and runs on peer
   data only in the domain that reads it, so no client's framing runs in
   the network domain.
7. **RACK is deferred.** The default stack is the reference
   ([Why FreeBSD's default stack](#why-freebsds-default-stack)). RACK-TLP
   is a second TCP implementation in FreeBSD, with its own input path and
   the high-precision timer system; the send log keeps it cheap to add as
   a loss module when its value is measured.
8. **The packet-script and interop oracle is FreeBSD 16.** The FreeBSD
   test host, 16.0-CURRENT, and its vnet jails are the oracle for the
   packet scripts and for traffic; the stack keeps no FreeBSD guest. Since
   the host tracks -CURRENT, every verdict record names its kernel
   ([Packet scripts against FreeBSD](#packet-scripts-against-freebsd)).
   QEMU is not installed there, so host runs reach its tap devices through
   the tap transport, on the host's own OTP ([The driver](#the-driver)).
9. **The translation follows FreeBSD 16 at commit `975e3605ebb1`**
   (`main-n285245`), the test host's kernel, for its more recent changes
   and so that the stack and its oracle are one FreeBSD. What was
   translated from `release/15.1.0-p6` is not translated again: the aim
   is a stack that works and interoperates, not one equivalent to FreeBSD
   line by line. Of the changes between the release and the pin, those
   the wire or an interoperating peer can see and the fixes of real bugs
   are ported, each recorded with its FreeBSD commit in `NOTICE-freebsd`
   ([Provenance and notices](#provenance-and-notices)).
10. **`erx_net_admit` is generated from the schema,** from
    `abi/services/net.txt`, so its requests and their bounds have one
    source ([The grant's contract](#the-grants-contract)). Outside erXos a grant runs
    under `erx_net_local`'s loop, which calls the same admission path.
11. **The stack is a package of its own.** The aim: "ideally we'd even
    structure our network stack as a separate package that can be used
    independently from erXos e.g. with tap/tun or
    netmap/dpdk/f-stack/etc/whatever is on linux", and "We might even
    release it separately at some point". The four seams of
    [The effect layer](#the-effect-layer) are where erXos meets the stack,
    so the package costs a portable implementation of each, a source
    layout by seam, a build check, and the client backends in an
    application of their own (N12).
12. **The client backends are an application of their own.**
    `erx_gen_tcp`, `erx_gen_udp` and `erx_inet` live in `erx_net_client`,
    which every domain's image carries beside `erx`, so a client domain
    carries the backends and their socket processes instead of the stack,
    and a release of the package is the two applications.
13. **Every socket has a socket process in its owner's domain,** a
    `gen_statem` of the same shape as stock OTP's `gen_tcp_socket`
    ([The socket process](#the-socket-process)). It alone talks to the
    socket, sending every request and taking every push, takes the
    envelope off each push after checking that it comes from the domain
    the socket was opened against, and gives its owner the stock
    messages. One mailbox and one lane carry everything between a socket
    and its program, so the ordering of replies and deliveries,
    `controlling_process` and the owner's exit follow without a rule of
    their own, and the universal envelope of
    [design-domains.md](design-domains.md#the-peer) keeps no exception.
14. **A domain that holds `net` runs at or above the socket protocol's
    floors** for the three limits the funnel applies to a frame:
    `max_frame`, `max_message_heap` and `funnel_depth`, each computed per
    operation from the protocol's schema, since a dropped push would hang
    its socket for good and a dropped reply its caller. The floors are in
    design-domains' table of limits
    ([design-domains.md](design-domains.md#principals-sessions-and-quotas))
    and bind no other domain; the system domain never holds `net`
    ([The grant](#the-grant)). The client checks its own three values
    before it sends an operation's request and answers an operation it
    could not carry `{error, enobufs}` itself, with one log line
    ([Message sizes](#message-sizes)), so a misconfigured domain fails
    loudly at its first use of what it cannot carry instead of hanging,
    and no refusal travels back through the limit that caused it; the
    network domain's own limits meet the floors through the system
    manifest's check.
15. **A raising connection step ends the connection.** A socket whose
    step raises ends itself from its state before the event, sends a RST,
    pushes `{error, econnaborted}` and exits with the exception
    ([What fails and what survives](#what-fails-and-what-survives)); it
    never counts the raise and goes on, since a bug in one flow's state is
    not worth keeping alive. A step that raises over a batch of drained
    messages ends the connection the same way
    ([The fast path](#one-step-per-mailbox)).
16. **A socket within one domain keeps its socket process.** A path that
    drops it when a grant's grantee is `local` (on a development host and
    wherever `erx_net` runs without erXos, N12) is declined: there the
    connection or datagram socket could hold the client half itself, as
    stock's port does, running `erx_gen_tcp_core` or `erx_gen_udp_core`
    beside its own step. The measurement of
    [the caller holding the socket](#alternatives-considered) bounds the
    gain from above. The cost is a second effect shell
    around each presentation core, the connection carrying the client
    half's duties in one configuration only, and host runs (N11) that
    would not exercise the socket protocol between processes, the shape
    every erXos socket has. In the same runs, with the socket process
    removed and the window update also taken off the step, the connection
    was still 62% of the profile, two steps of about 275 Erlang calls
    each, against 164 for the interface and 69 for the driver, so the
    connection's fixed cost per step is the larger lever, and every
    configuration pays it. The question is reopened only when the hack's
    numbers, measured on a standalone release of `erx_net`, where every
    socket is within one domain, show the gain worth the second
    configuration.
17. **The client half stays Erlang,** not an ERTS object in the owner's
    runtime shaped as stock's inet port. Such an object would remove the
    socket process's hop in every mode and configuration, but it costs a presentation core in C on the path of untrusted pushes, with
    its fuzz target, a new kind of delivery target for the funnel, and a
    C entry on D18's list of protocol owners, where the socket process is
    ordinary Erlang under the existing rules. The question is reopened
    only when a measurement with the owner in another domain on erXos
    shows the owner's side of a socket among the larger costs of a
    transaction, beside the lane crossings and the connection's own
    steps; the watch list holds that measurement
    ([todo-performance.md](todo-performance.md)).
18. **The socket process sends through a refusing send, not past the
    busy limit.** It sends to its socket only with `erlang:send/3` and
    `[nosuspend, notify]`, through `erx_sock_out`; a refused message stays
    where it already waited, and the runtime tells the process when to
    try again ([The socket process](#the-socket-process)). So the client's
    queue for the network domain is the queue every peer gets, the busy
    limit and a frame per sending process (D12 of
    [design-domains.md](design-domains.md#invariants)), whatever the
    network domain grants or pushes, and the property rests on one module
    that a build check makes the only site. The rejected alternative is
    stock OTP's `async_dist` flag with marks: the flag lets a process
    queue past the busy limit without suspending, which keeps it live but
    bounds nothing, and marks bound only what they cover, the stream's
    bytes, by a reference the connection answers as it takes them;
    receive credit messages and the calls that forged replies to a
    predictable `N` let through would each need a bound of its own, and
    each new kind of message another. The refusing send bounds every
    message with the one bound ERTS already keeps and needs none of the
    marks' state (a reference, an offset and a gate in the socket
    process, a count between marks in the connection, two protocol
    messages). It costs one ERTS change, the notification, which the bell
    of [design-runtime.md](design-runtime.md#connections-in-erts) measures
    against first. A build check makes the outlet the only send site in
    the socket process's modules, and the outlet spawns it with
    `{async_dist, false}`, so a runtime's `+pad` default cannot give it
    the flag.
19. **The system domain never holds the grant.** The trusted base parses
    no network traffic: the manifest check refuses a `net` grant to the
    system domain, and whatever there would need the network moves to a
    service domain; root's session holds `net`, so the network utilities
    and root's programs run there ([The grant](#the-grant)). The socket
    protocol therefore meets only an ordinary domain's busy limit on the
    client's side: nothing of a socket ever waits behind `system_queue`,
    where a plain message past it is dropped and any other signal ends
    the destination domain.
20. **A queued connection counts toward `sockets` from its adoption.**
    Its grant counts it in the call that reserves its buffers, so a grant
    at its limit has new connections reset at their handshakes and
    `accept` never answers `emfile` ([The listener](#the-listener)). The
    limit bounds what the network domain holds for a client, and a queued
    connection is held there, with a process and buffers, accepted or
    not; the grant is involved once per connection, and the listener
    never calls it. FreeBSD's way, counting at `accept`, which answers
    `EMFILE` and leaves the connection queued (`kern_accept4`,
    `uipc_syscalls.c:358-370`), would cost a call from the listener to the
    grant at every `accept` and leave a client at its limit holding up to
    `3 * Backlog div 2 + 1` uncounted connections per listener, bounded
    only by `buffers`.

### Open decisions

1. **Which client domains run with a queue quota.** What a socket
   process has not yet taken from a hostile network domain is bounded
   only by its runtime's queue quota ([Untrusted input](#untrusted-input)),
   and design-runtime leaves `-erx queue_quota` unset by default, as
   stock OTP has none. The recommendation: the domain service gives every
   domain it grants `net` a quota of 1 MiB unless its specification names
   one. Only the processes another domain may message have frames to
   count, and in such a domain those are its socket processes,
   `erx_inet`'s loader and the aliases of its calls, so the quota bounds
   exactly what the network domain can reach, and a correct network
   domain meets it only when a socket process falls behind, which pauses
   its lane and loses nothing. The alternatives are a default quota for
   every domain, one rule but a change to design-runtime's default for
   domains that talk to no other service, and a quota each socket process
   sets on itself, which needs a new runtime call.
2. **Whether the bar on the system domain covers `netadmin` too.**
   Decision 19 bars the `net` grant. `netadmin` carries no socket and no
   packet, but its answers, every client's statistics and the interfaces'
   state, are built by the domain that parses the network's traffic, and
   nothing in the system domain configures interfaces, which the network
   domain's manifest arguments set. The recommendation: property 15
   refuses every facet of the network service to the system domain, `net`
   and `netadmin` alike, so the rule reads "the system domain holds
   nothing the network domain serves", and administrators use `netadmin`
   from their sessions. It costs nothing; the alternative keeps
   `netadmin` available to the system shell for an operator whose only
   line is the system shell's.

## Alternatives considered

**Port FreeBSD's structure line by line.** It would keep `tcp_do_segment`
as one function and carry locking and mbuf idioms into code that has
neither. Translating decisions keeps everything the wire can see and
drops the rest.

**aloha as the base.** Its process structure, its effect-mixed
connection code and its codec would all be rewritten, and those are most
of it ([What a naive Erlang stack gets wrong](#what-a-naive-erlang-stack-gets-wrong)).

**RACK first.** RACK is a second TCP implementation of 24,673 lines that
needs the high-precision timer system and its own input path before the
system sends a byte ([Decisions](#decisions), 7).

**A process per layer.** Each layer would add a mailbox trip per packet
and serialise all connections through each layer's process; the
interface process decodes all layers in one pass.

**Deliveries straight to the owner, unwrapped by the runtime.** The
connection would send `{tcp, S, Data}` to the owner itself, and the
peer's envelope (edit 16 of
[design-runtime.md](design-runtime.md#the-edits-outside-syserxos)) would
make an exception for socket messages whose socket pid is of the lane's
domain. It saves the local hop but puts a list of message shapes into the
runtime, gives D18 an exception, and leaves `controlling_process` a round
trip to the network domain.

**A relay for deliveries alone,** with `recv` and `setopts` replies
coming back to the caller directly. Two senders let the owner see later
bytes before earlier ones and a reply to `{active, false}` overtake
deliveries sent before it, and moving the socket to a new owner would
have to coordinate both. One process for everything keeps the order of
one mailbox and one lane.

**Presentation in the connection, the socket process forwarding.** The
connection would keep active modes, framing and `recv` as stock's inet
driver keeps them. Every `setopts` of active mode, every re-arm of
`{active, once}` and every passive `recv` would cross the lane twice, and
a change of packet mode could not reach bytes already pushed. Within one
domain, where nothing crosses a lane, the connection holding the client
half is the sixteenth of the [Decisions](#decisions), declined until
measured.

**The caller holds the socket.** After the connect, the caller would take
the connection over from its socket process, sending its requests and
credit itself and taking the pushes in its own mailbox. A throwaway
change did this for the network bench's request-reply worker alone,
within one domain: on the FreeBSD x86-64 test host, natively on stock OTP
29 (erts 17.1, JIT), `+S 1:1`, rr-64 over the tap transport to a jail,
five interleaved rounds, medians against erXos 07c84450, it measured
16,460 transactions a second against 14,576 (12.9% more) and 46.4 us of
CPU per transaction against 55.7 (16.7% less), with four messages and
about four process schedules fewer per transaction, about 2.3 us each;
bulk send and receive stayed within noise (`~/erxos-history`,
`net-rrhacks-2026-11-10`, commit 4b7dbfb). It cannot keep stock's API: a
second process's `send` or `recv` would find the socket's state in a
process that serves no calls; pushes would reach the owner's mailbox
while it is not in a socket call, where a `gen_server` owner's
`handle_info` takes them; and across domains active mode still needs a
process of the owner's domain that takes the envelope off. Holding the
socket in the caller only while that is safe would make the socket's home
move with what each process does, and no process can move it back out of
an owner that is not in a socket call. The measurement is the upper bound
of removing the socket process within one domain, which the sixteenth of
the [Decisions](#decisions) weighs.

**Sends straight from any caller to the connection,** as OTP's own
`gen_tcp_socket` sends from the caller's process into the socket
(`gen_tcp_socket.erl:557-582`), FreeBSD's split of `so_snd` from
`so_rcv`. A send that does not fit the send buffer would wait in the
network domain, holding a piece there for each sending process, or stop
the connection taking messages and pause the client's whole lane behind
one slow peer; two large sends from two callers would need a lock in the
connection to stay whole; and every caller would monitor the connection
for each call, a control record each way across the lane. Send credit
shared by every process that sends on a connection needs a party that
hands it out and orders the sends, which is the socket process again.

**Framing in the connection.** Since the connection pushes ahead of what
is presented, a change of packet mode would come after the bytes it
should apply to were framed, each `setopts` that changes a packet option
would cross the lane, and `decode_packet` would run in the network domain
on every client's peer data ([Decisions](#decisions), 6).

**Every request through a facet in the system domain.** Two more
crossings per call, and packet work would still be unaccounted. The grant
runs in the network domain, as the storage services' grants run in theirs
([design-files.md](design-files.md)).

**A reply to every piece sent,** the next piece sent only after it. It
costs a lane round trip per piece, one more message on every
request-reply exchange, and a waiting writer in the TCP core that FreeBSD
keeps in its socket layer; send credit answers the same question, whether
the buffer has room, before the bytes leave the owner's domain.

**Queuing past the busy limit** with `async_dist` or a flag of erXos's
own: the protocol would then have to bound what it queues, marks for the
stream's bytes and a bound of its own for every other kind of message
([Decisions](#decisions), 18).

**The socket process monitoring its socket.** A monitor, a link or a
demonitor towards a busy domain suspends its caller after queuing the
signal, so a socket process that made its own would suspend at its start
on a stalled lane. Its socket links to it instead, from the network side:
one link carries both ends.

**The socket process calling the grant.** The open would then be a call
the outlet had to carry, with a monitor of the grant that suspends as
above. The opener makes the call, a plain one that may hold only the
opener, and hands the socket over as an accepting listener's socket
process does.

**Modular sequence arithmetic, checked by types.** An opaque `seq()` type
lets Dialyzer report arithmetic on sequence numbers outside their module,
but not comparisons, which are where wrap bugs live. Lifting removes the
modular comparisons instead of guarding them.

**Random bytes in the context.** The loop cannot know how many bytes a
step needs without a list of which events draw what, a step given too few
would need a rule for running out, and a draw before every step is a
kernel call per segment batch, almost always unused. A generator in the
state never runs out and costs nothing until a step draws.

**An unverified segment type** from `classify/2`, turned verified by
`verify/1`. Every field of it would be readable before its checksum, and
the rule that only the lookup reads them would rest on every reader
remembering it. With the transport header decoded only after the
checksum, there is no such record to read.

**One Erlang timer per FreeBSD timer.** Five timers per connection, each
cancelled and restarted on most ACKs, and a stale-message check for each.
FreeBSD 15 itself moved to one callout over an array of deadlines.

**The syncache in the listener.** A SYN flood would fill the listener's
mailbox, and with cookies computed in the interface for overflow two
places would answer SYNs. FreeBSD handles SYNs in the input path, and so
does the stack.

**Linux as the reference.** Linux's stack is the more common peer and
stays an interoperability oracle, but erXos follows FreeBSD where UNIX
systems differ, and FreeBSD's code can be translated under its license.

**Drop a frame when the device's queue is full.** Every burst longer than
the device's ring would then be loss the sender caused itself, which
FreeBSD's send queue in front of the ring does not have, and TCP would
cut its window for it ([The driver](#the-driver)).

**A QEMU hub for tap devices on the FreeBSD host,** as slirp is reached
on macOS. It needs an emulator on a test host that runs none; the tap
transport is the netmap transport's construction over a file descriptor,
and serves a node outside erXos as well
([The tap transport](#the-tap-transport)).

**A netmap port program, or slots lent to binaries.** A helper relaying
netmap's rings through a pipe adds two copies per frame and an uncredited
mailbox; binaries over ring slots save the receive copy but let one held
segment stop a ring that returns its slots in order
([The netmap transport](#the-netmap-transport)).

**lwIP behind a NIF.** A C stack in the domain that parses hostile
packets, whose numbers would decide nothing about an Erlang stack. The
stack has no stopgap.

**A sum carried with the send buffer.** Output cuts segments at offsets
the owner's writes never chose, and the cut changes from one transmission
of the same bytes to the next; the sum of a partial binary needs a read of
its bytes, so stored sums would still be corrected by reading. Finishing
the checksum at the last copy needs no stored sum and reads each byte
once whatever the cut, as FreeBSD's delayed checksum does
([Checksums in the copy](#checksums-in-the-copy)).

**Device offload alone.** It removes the checksum only where a device
offers it: not on the harness's hub port, not on a netmap port, and not
on every board, leaving two passes elsewhere. The copy's sum works on
every medium copied in C, and offload fits behind the same request.

**A verdict from the copy.** A copy that checked the TCP checksum would
have to find the IP header's length, the protocol and the addresses,
parsing in C what the decoders parse in Erlang. A sum from a fixed
offset needs none of that, and the stack derives every layer's sum from
it.

**Receive offload (`GUEST_CSUM`).** It saves only the additions the copy
makes anyway, and brings frames whose checksum is a claim, or missing,
into a stack that otherwise believes nothing a device says
([Checksums in the copy](#checksums-in-the-copy)).

## References

* FreeBSD src, main commit `975e3605ebb1` (16.0-CURRENT, `main-n285245`),
  the pin; and `release/15.1.0-p6`, commit
  `95719d8a895bf8170851e9844d9b4092b1d2b6fe`, the tree the translation
  and this document's line references were read from: `sys/netinet`,
  `sys/netinet6`, `sys/net`, `sys/netinet/cc`, `sys/netinet/tcp_stacks`,
  and for the listen queue `sys/kern/uipc_socket.c` (SHA-256
  `e178d225e66edd22a8e248c66a5fb9a02de5a337460040afd892bcf15bf6d185`),
  `sys/kern/uipc_syscalls.c` (`8e9649f4bcb55e021986afa3af48b65bb0fa68f5c13e018cb778ff2a3b8ec002`)
  and `sys/sys/socket.h` (`7123131ae818863971cc91c7723a187ba79fc24f8b91384d40c5a2e0b2d60789`);
  at the pin, `uipc_socket.c`
  (`be9f6f6b0751fee819d38ec1c165b82bb39abd25e85970247b341cf0fa0a5ee6`)
  keeps the queue limit (`:1089`) and the accepted socket's
  reservation from its listener's sizes (`soattach`, `:967-970`).
* FreeBSD tcp-testsuite, https://github.com/freebsd-net/tcp-testsuite;
  packetdrill (nplab), https://github.com/nplab/packetdrill.
* N. Cardwell et al., "packetdrill: Scriptable Network Stack Testing,
  from Sockets to Packets", USENIX ATC 2013.
* RFC 9293 (TCP), RFC 5961 (blind in-window attacks), RFC 6528 (initial
  sequence numbers), RFC 7323 (window scaling, timestamps, PAWS), RFC
  2018 and RFC 6675 (SACK and SACK-based recovery), RFC 6937 (PRR), RFC
  3042 (limited transmit), RFC 6928 (initial window), RFC 5681 and RFC
  6582 (congestion control, NewReno), RFC 9438 (CUBIC), RFC 3168 (ECN),
  RFC 6298 (RTO), RFC 1337 and RFC 6191 (TIME-WAIT), RFC 5927 (ICMP
  attacks), RFC 8985 (RACK-TLP).
* RFC 791, RFC 826, RFC 792, RFC 1191, RFC 1071 and RFC 1624 (checksum);
  RFC 8200, RFC 5095, RFC 5722, RFC 7112, RFC 4443, RFC 4861, RFC 4862,
  RFC 3810, RFC 6724, RFC 7217, RFC 8064, RFC 8106, RFC 8201, RFC 8981;
  RFC 6864 (IPv4 identification); RFC 768; RFC 2131 and RFC 2132.
* J.-P. Aumasson and D. J. Bernstein, "SipHash: a fast short-input PRF",
  INDOCRYPT 2012.
* aloha, https://github.com/yamt/aloha, commit `0aa96f14`.
* The research records this design rests on:
  [the mapping of FreeBSD's stack to Erlang](research-freebsd-net-mapping.md)
  and the assessment of aloha, `~/erxos-history/docs-archive/research-aloha.md` (history commit `e38149b`).
* pkt, https://github.com/msantos/pkt.
* Erlang/OTP 29.1.2: `lib/kernel/src/gen_tcp.erl`, `inet.erl`,
  `inet_int.hrl`, `gen_tcp_socket.erl`, `erl_epmd.erl`.
