# Chapter 21. The Live Machine

> **Status.** Built: `erx:i/0,1` and `erx:inspect/2`, with a reporter
> and a status on every value, unsupported and partial ones on Fiasco
> included; inspection agents and inspect facets; `/proc` and
> `dmesg`; `erx:source/1` within the caller's runtime; `erx:trace/1`
> over the system domain's processes and the root service's trace
> ring; the host link with `tools/erx load`, `watch`, `files` and
> `web`; the code store, loading into the system domain; the log
> service to the console; the report filter; the crash record on the
> console. Designed: tracing other domains and the frames between
> them; the host link's inspect, trace, source and console commands;
> loading code into other domains, with overlays; refusing code
> outside installed storage; log files under `/var/log`; a crash
> record that survives the reset; domain crash dumps under `/proc`;
> the host's tree mounted in the machine.

**Background needed.** [Chapter 3](03-erlang.md), sections 3.6 and
3.7: two versions of a module, and looking at a running node.
[Chapter 5](05-overview.md): domains, sessions and facets.
[Chapter 9](09-processes.md), section 9.7: the one timeline.
[Chapter 11](11-security.md), section 11.12: the line escape and the
field escape. [Chapter 14](14-files.md), section 14.5.1: `/proc` as
files.

A board in a kiosk answers slowly. Is the network domain starved of
memory? Has a session's process ten thousand messages queued? Is a
driver waiting for an interrupt that never comes? To answer, a
developer must see every layer of one machine at once, and trust that
each number means what it says. A guess shown as a fact sends the
search the wrong way.

On FreeBSD the answer lies in a dozen tools, each with its own view and
format. `ps` and `top` read process state through `sysctl`; `procstat`
shows one process's threads, files and memory; `dtrace` and `ktrace`
trace the kernel and system calls; `dmesg` prints the kernel's message
buffer and `syslogd` writes `/var/log/messages`; `kldload` loads code
into the running kernel; `savecore` keeps a kernel dump for the next
boot. Each does its job, and none knows about the others.
<!-- check: FreeBSD tools and their roles as named here, against the
FreeBSD manual pages ps(1), top(1), procstat(1), dtrace(1), ktrace(1),
dmesg(8), syslogd(8), kldload(8), savecore(8). -->

erXos gives the machine one **inspector**: a service in the system
domain that answers for any part of the machine, from a CPU to one
Erlang process, as a record of attributes. Every attribute carries the
name of who reported it and a status, so an unknown value reads as
unknown. Tracing puts Erlang processes and the root service's events
on one clock. Code compiled on the developer's Mac loads into the
running machine, named by the hash of its bytes. Logs and crash
reports are attributed, escaped, and free of process data.

The chapter covers the inspector (21.1) and its rule never to
fabricate (21.2), tracing (21.3), code from the host (21.4), logs and
crash records (21.5) and attributed text (21.6).

## 21.1 The machine is an object

Genera, the operating system of the Symbolics Lisp machines, let its
user point at anything on the screen and inspect it as a live object,
then change the code behind it while it ran
([chapter 4](04-history.md#43-the-lineage)). erXos takes that idea and
adds the walls Genera lacked: each domain sees only what its facet
allows.

### 21.1.1 Paths and records

Everything the inspector can show has a **path**, a list of segments
that names it the way a file path names a file. `[]` is the machine,
`[cpus, 0]` the first CPU, `[domains, 7]` domain 7, `[domains, 7,
budget]` its budget and `[processes, Pid]` one Erlang process. The
paths, the kinds of record and every attribute with its type are
declared once in `abi/inspection.txt`, from which a Ruby generator
emits the Erlang module `erx_schema` and the host tool's table
([chapter 7](07-one-source.md)).

The answer for a path is an **inspection record**, an Erlang map
([design-live.md, Inspection records](../design-live.md#inspection-records)):

```erlang
-type record() :: #{schema := 1,
                    path := [segment()],
                    kind := atom(),          % machine, cpu, domain, process, ...
                    id := term(),
                    attrs := #{atom() => attr()},
                    children := children()}.

-type attr() :: {reporter(), value()}.
-type value() :: {ok, term()} | {partial, term()} | unknown | unsupported
               | {timeout, Milliseconds :: pos_integer()} | {error, term()}.
```

An attribute is never a bare value: it pairs who reported it with the
value wrapped in a status (section 21.2).

At the Erlang shell, `erx:i()` prints the machine: its record, each
CPU, the system domain's group, budget and threads, and a table of
processes, within 80 columns. `erx:i(Path)` prints one record whole,
and `erx:i(Pid)` is short for `erx:i([processes, Pid])`. Figure 21.1
sketches the layout that `erlang/apps/erx_shell/src/erx_render.erl`
gives a part of the screen.

```text
/  machine
  build          kernel     <build id>
  development    kernel     true
  cpus_online    kernel     <count>
  uptime         kernel     <ns>
/cpus/0  cpu
  idle_time      kernel     [unsupported]
  ready_threads  kernel     [unsupported]
/domains/4/budget  budget
  used           root pool  [partial]
/processes  <count> entries
  pid        state    reductions  queue    name         current
  by         runtime  runtime     runtime  runtime      runtime
  <4.0.0>    waiting  <count>     0        init         init:loop/1
root pool: pages of the root's pool: those handed out, carved budgets'
included, and the pool's total and free; not the kernel's or sigma0's
memory, page tables or mapping records
```

*Figure 21.1. Part of an `erx:i()` screen on Fiasco, with live values
shown in angle brackets. Every value names its reporter, a table names
each column's reporter on its `by` line, and a backend reporter's
scope is printed under the screen.*

The `erx:i/0,1` functions, the inspector behind them
(`erlang/apps/erx/src/erx_inspector.erl`) and the renderer are
**Built**. `erx:inspect(Path, Options)` returns the same record as data
for a program, with a wait of the caller's own; it is **Built** too.

### 21.1.2 Who reported it

A **reporter** is the party that measured or decided a value. There are
three: `kernel`, for what the kernel interface reports about kernel
objects; `service`, for what a system service keeps in its own records,
such as a domain's name and state from the domain service; and
`runtime`, for what a domain's runtime says about its own processes.

The inspector assigns the reporter by where it collected the value,
never by what the value claims. An attribute that came from the kernel
call `erx_object_info` is the kernel's. One that came from a domain's
runtime is `runtime`'s, whatever that runtime wrote in its answer. So a
domain can lie about its own processes, and the record says plainly
that the domain is the one speaking.

A fourth kind comes from how erXos runs on Fiasco. Some values the
kernel interface promises are counted not by Fiasco but by `liberx`'s
Fiasco backend in the root service, in user mode
([chapter 8](08-kernel-interface.md)). A **backend reporter** names
such a component. The root service counts the pages of its own pool,
so the system domain's budget reports `used` under the backend reporter
labelled `root pool`, as `partial`
([design-fiasco.md, Reporting a budget](../design-fiasco.md#reporting-a-budget)).
The schema declares each backend reporter with a label and the scope of
what it sees, and the renderer prints that scope under any screen that
names it, as at the foot of figure 21.1. A backend's count never passes
for the kernel's.

### 21.1.3 How a query travels

Follow one question from a person's session to the answer. Root's
session, a domain of its own, runs an Erlang shell. Its user types
`erx:i([processes, {pid, 7, 85, 0}])` to see process `<7.85.0>` of
domain 7, a driver's domain.

1. **The facet.** `erx:i/1` hands the path to the session's **inspect
   facet**, a process in the system domain that stands for this
   session's right to inspect
   ([chapter 5](05-overview.md#534-a-message-to-a-service-through-a-facet)).
   The session sends a path and options and nothing else. What the
   session may see, its **scope**, lives in the facet, fixed by the
   system domain when it made the facet.
2. **The scope check.** The inspector decides who owns the path before
   it collects anything. A process belongs to the domain its pid
   names, here 7. If 7 lies outside the scope, the answer is
   `{error, scope}`.
3. **The kernel's facts.** The system domain, as the root task, holds
   a handle to every domain's space, group and budget. The inspector
   asks `erx_object_info` about domain 7's objects, and each answer's
   `reported` mask says which fields the backend has with their full
   meaning.
4. **The runtime's facts.** Only domain 7's runtime knows its Erlang
   processes. Each domain but the system domain starts an **inspection
   agent**, `erx_inspect_agent`, at boot. The inspector's worker asks
   it over the domain's connection; the agent runs `process_info/2`
   inside domain 7 and answers with a frame that the system domain's
   funnel checks like any other.
5. **The record.** The worker joins the facts, each tagged with its
   reporter, drops what the scope may not see, and validates the record
   against the schema. The session's shell renders it through the line
   escape.

An agent answers only for its own domain, and an answer that names
another domain is dropped whole, so a lying runtime can describe only
itself (`erlang/apps/erx/src/erx_inspect_agent.erl`). The agent and the
inspect facet are **Built**, and the session-domain QEMU suite reads a
process of root's session through the session's facet
(`tools/lib/erx/session_domain.rb`).

### 21.1.4 Scope

A scope is either `all` or a list of domains, those of the facet's
principal. In a development build, root's session holds a facet of
scope `all`. In a release build no session does, and machine-wide
inspection happens only in the system shell, at a console line marked
secure ([design-live.md, Inspection](../design-live.md#inspection)).

Two rules make scope hard to probe. A path outside the scope and a path
that names nothing get the same answer, `{error, scope}`, so a scoped
caller cannot learn whether a process of another principal exists. And
every attribute has a visibility class in the schema: `any`, `owner` or
`all`. The few `visible any` attributes are those every UNIX user reads
with `uptime` and `top`: the build, the uptime, the CPUs online, total
and free memory, and each CPU's idle time and ready threads. Free
memory and idle time move as other domains run, a side channel erXos
accepts so that every session can show the machine's load.

### 21.1.5 Names travel as data

A record names a process by three numbers, `{pid, 7, 85, 0}`, never by
a live pid. The reason is authority. Sending a pid of the system domain
to another domain **exports** it, which lets the receiver message and
monitor that process
([chapter 3](03-erlang.md#392-distribution-across-a-domains-wall)). A
record of a system process that held its group leader as a live pid
would hand every holder of a broad scope a way into the trusted base. A
triple of numbers hands out nothing, and turning its text back into a
pid makes a name the funnel still refuses.

The schema has no pid, port, reference or fun type, so
`erx_schema:validate_record/1` refuses a record holding one at any
depth, and the inspect service runs it on every answer before it leaves
the system domain. A test plants a live group leader into a record and
checks that the validation refuses it (`test/erlang/erx_inspector_tests.erl`,
`a_live_group_leader_is_refused_test`).

### 21.1.6 From a process to its source

A process record carries the process's current location: module,
function, arity, file and line. `erx:source(Pid)` prints the source
around that line, from the `src` directory beside the module's `ebin`.
It does so only when that is truthful: the loaded code must match the
file by its MD5, the process must not be running old code, and the
line must exist. Otherwise the answer is `{error, unsupported}`, never
a line from another version (`erlang/apps/erx/src/erx_source.erl`).
The release ships no `src` directories, so its own modules answer
`unsupported`; a module under development shows its lines.
`erx:source/1` is **Built** for processes of the caller's own runtime.
The path `[processes, Pid, source]`, which would reach the source of a
process in another domain through the inspector, and `tools/erx
source` on the host, are designed and not built.

## 21.2 Never fabricate

The inspector's one hard rule is that it never shows a value it does
not have. A tool that prints `0` for a figure it could not measure has
told a lie in the shape of a fact.

### 21.2.1 Six statuses

Every value carries one of six statuses:

| Status | Meaning | Rendered as |
| --- | --- | --- |
| `{ok, V}` | V is the value, with the attribute's full meaning | the value |
| `{partial, V}` | V is a count of part of what the attribute means | `[partial]` |
| `unknown` | the reporter could not tell | `[unknown]` |
| `unsupported` | the reporter does not offer this attribute | `[unsupported]` |
| `{timeout, Ms}` | the reporter did not answer within Ms milliseconds | `[timeout Ms]` |
| `{error, Why}` | the collection failed | `[error]` |

The renderer prints every value with its reporter and its status.
The command shell's text commands, which print as FreeBSD's do, print a
value without the status `ok` as `-` or leave it out, never as a bare
number ([design-live.md, Invariants](../design-live.md#invariants), V2).
Each status has its own test in `test/erlang/erx_inspector_tests.erl`.

Waiting has a bound. The inspector's worker waits at most 500 ms for a
domain's agent and lives at most 5,000 ms for a whole query
(`abi/services/inspect.txt`, `inspect_agent_wait` and
`inspect_query_max`). A late agent turns every runtime attribute into
`{timeout, 500}`; the kernel's and the services' attributes in the
same record still show.

### 21.2.2 What Fiasco cannot say

On Fiasco a good part of the record reads as `unsupported`, and that is
the inspector working as designed. The backend sets a bit of a report's
`reported` mask only for a field it has with the attribute's full
meaning, and marks a field it counts only partly in a second mask
([design-fiasco.md, Reporting kernel objects](../design-fiasco.md#reporting-kernel-objects)).
The inspector turns the two masks into statuses:

| Attribute | On Fiasco | Why |
| --- | --- | --- |
| a CPU's `idle_time` | `unsupported` | Fiasco charges each periodic tick to the thread it interrupts, so its idle count bounds idle time neither from below nor from above |
| a CPU's `ready_threads` | `unsupported` | Fiasco does not report it |
| the system domain's group `parked`, `ready` | `ok` | read from the root's own status page |
| another domain's group | every attribute `unsupported` | the group report answers only the root's own group |
| the system domain's budget `used` | `partial`, reporter `root pool` | the root counts its pool's pages, not the kernel's own memory |
| another domain's budget | every attribute `unsupported` | the budget report answers only in the root |

README's
[Current status](../../README.md#current-status) records the same. It
is a limitation of the system on Fiasco: the inspector cannot show how
much of its budget the network domain has spent.

### 21.2.3 `/proc`

[Chapter 14](14-files.md#1451-proc-the-inspector-as-files) showed
`/proc` as files: a read is the query `erx:i/1` would make, through
the same facet, so both forms pass one gate. Two details matter here.

**A file is a snapshot.** Opening a `/proc` file runs one query, and
reads see that answer until the file is closed. A record longer than
64 KiB ends with a line `[partial]`, and a reader holds at most 256
open snapshots, so its tree costs at most 16 MiB of its own domain's
memory ([design-live.md, The /proc tree](../design-live.md#the-proc-tree)).

**A gap is shown, never filled.** `/proc/kernel/log` shows the kernel
log from the oldest line the ring still holds. Where entries of the
sequence are missing, a line `[missing N]` stands in their place.
`dmesg` writes that file, as FreeBSD's prints the message buffer.
`/proc` and `/proc/kernel/log` are **Built**
(`erlang/apps/erx_files/src/erx_procfs.erl`); the session-domain suite
runs `cat /proc/status` and `dmesg` in root's session.

## 21.3 Tracing

`erx:i/1` shows a moment. Some questions need a film: in what order did
the driver's process run, the executor park and the interrupt arrive?

> **Background: how the BEAM traces a process.** Tracing lets a
> running Erlang system report events of chosen processes without
> recompiling or stopping them. A **trace session**, in OTP 29, is a
> handle that holds which processes are traced, for
> which events, and which process receives the trace messages, the
> **tracer**. The flag `running` reports each time a process is
> scheduled in or out; `call` reports calls to chosen functions;
> `send` and `receive` report messages. With a timestamp flag, each
> trace message carries the time the event happened. Several sessions
> can run at once without seeing each other's settings.
> <!-- check: OTP trace sessions (the `trace` module, OTP 27 and later)
> and the flags named, against OTP 29.1.2's documentation. -->

### 21.3.1 Three rows on one clock

A trace in erXos is a merge of **rows**, each a source of events with
its own reporter ([design-live.md, Tracing](../design-live.md#tracing)):

| Row | Reporter | On Fiasco |
| --- | --- | --- |
| `erts` | `runtime` | OTP's `in` and `out` events of the traced processes |
| `backend` | backend reporter `liberx trace` | the root service's trace ring: parks, wakes, interrupt deliveries, task starts and ends |
| `kernel` | `kernel` | one `unsupported` entry |

The `backend` row is the **trace ring** of
[chapter 9](09-processes.md#971-one-timeline): 4,096 records the root
service writes as it carries out parks, wakes and doorbell deliveries,
and as it starts and ends tasks
(`liberx/backend/fiasco/trace.c`). The kernel's own call for its trace,
`erx_trace_read`, is refused on Fiasco, so the `kernel` row shows one
`unsupported` entry under the reporter `kernel`. A row the kernel
reports is shown even when it has nothing, so the reader sees that the
kernel was asked.

`erx:trace(Spec)` starts a trace from a map:

```erlang
erx:trace(#{select => [whereis(erx_hostlink)], kernel => true}).
```

`select` names up to 16 pids or domain ids; `kernel` adds the `backend`
and `kernel` rows, which need a facet of scope `all`. Each entry prints
as one escaped line, ordered by `erx_clock_ns`, the system clock.

### 21.3.2 The merger

Merging sources in time order has one hard case: a source that is
slow. The merger, a pure module (`erlang/apps/erx/src/erx_tracer.erl`),
holds each entry until every source still waited for has shown a later
time, or until the entry is 100 ms old, whichever comes first. A ring
is in time order, so a read shows its latest record; OTP's trace
messages from different schedulers arrive in no order, so a batch
counts only up to what the previous batch showed. A source that stops
answering delays the stream by at most 100 ms. An entry that arrives
after later ones went out is printed at once, marked `late`, never
dropped.

The trace process around the merger
(`erlang/apps/erx/src/erx_trace.erl`) wakes every 10 ms, reads the
rings, feeds the merger and sends what it releases. Two bounds keep a
trace from hurting the machine it observes. The receiver acknowledges
entries, and at most a fixed window of unacknowledged entries is out;
an entry that finds the window shut is counted, and one entry per row
later reports the count. And the trace process has a maximum heap
size, past which ERTS kills it, so a flood ends the trace, not the
system domain. The trace's own processes are spawned untraced, an
erXos change to OTP, so no trace sees its own machinery run.

`erx:trace/1`, the merger and the `erts` and `backend` rows are
**Built**, for the system domain's processes.

### 21.3.3 Across domains

The design traces every domain the facet's scope covers, through that
domain's own runtime. A trace facet starts a **trace relay** in the
traced domain, the tracer OTP sees there. The relay renders each trace
message into plain terms inside the domain, where its atoms live, and
sends the records in batches to the system domain, whose funnel admits
them because they create no atom.

Frames between domains are traced by their receiver. Each runtime's
funnel sees every frame arriving on its lanes, and in a traced domain
it records each frame it accepts or refuses, with the peer taken from
the lane, never from the frame. A conversation is seen at both ends,
each record marked as that domain's report. Figure 21.3 shows a trace
across two domains as the design gives it.

```mermaid
sequenceDiagram
  participant S as shell (system domain)
  participant T as tracer (system domain)
  participant R as trace relay (domain 7)
  participant G as root service ring
  S->>T: erx:trace(#{select => [7], kernel => true})
  T->>R: start relay
  R-->>T: records: in, out (runtime)
  G-->>T: park, irq_deliver, wake (liberx trace)
  T-->>S: one stream by erx_clock_ns
```

*Figure 21.3. A trace across two domains. Each row keeps its own
reporter, and the merger orders them on one clock; the relay in
domain 7 is designed and not built.*

The trace relay, tracing processes of other domains, and frame tracing
are designed and not built. The built trace refuses any domain but the
system domain's with `{error, scope}`
(`erlang/apps/erx/src/erx_trace.erl`, `domains/0`).

## 21.4 Code from the host, named by its hash

A developer edits a module on the Mac and wants it running in the
machine a second later, without a reboot. Erlang already replaces
modules in a running node
([chapter 3](03-erlang.md#361-two-versions-of-a-module)). erXos adds
a link to carry the module, a name for it that cannot be faked, and a
rule for what may enter the trusted base.

> **Background: what a code hash names.** A module's name, `lists`,
> says which module, not which version. Two builds of `lists` share
> the name and may differ in every byte. A **cryptographic hash** such
> as SHA-256 maps any bytes to 32 bytes, so that finding two inputs
> with the same hash is beyond reach. Naming a compiled module by the
> hash of its bytes therefore names one exact version: a copy
> received from anywhere is the right one if its bytes hash to the
> name. A hash gives integrity and
> identity, not trust: it proves the bytes are the ones named, not
> that they are safe to run.

### 21.4.1 The host link

The **host link** connects the host tool, `tools/erx`, to the machine
over a second serial line that belongs to the system domain. Under QEMU
that line is a UNIX socket in the run's own directory, which only its
user can enter ([design-live.md, The host link](../design-live.md#the-host-link)).
`tools/erx boot --hostlink` sets it up. Figure 21.2 shows the parts.

```mermaid
flowchart LR
  subgraph Mac
    W[tools/erx watch] --> C[host link client]
    F[9P client] --> X[tools/erx files]
    X --> C
  end
  C -- "COBS frames over UART 1" --> H[erx_hostlink]
  subgraph M[system domain]
    H --> I[install facet]
    H --> B[files bridge]
    I --> E[erx_code]
    E --> S[code store]
  end
```

*Figure 21.2. The host link. Every request names a facet by its number
in the session's table; the code service checks each module against
its hash before anything is loaded.*

**Frames.** A serial line drops and garbles bytes. Each frame is
encoded with consistent overhead byte stuffing (COBS), which leaves no
zero byte inside it, and ends with a zero, so a receiver finds the next
frame after any damage. A frame carries a stream number, a session
identifier, a sequence number, a target, a body of at most 8,192 bytes
and a CRC-32C ([design-live.md, Host link frames](../design-live.md#host-link-frames)).

**Sessions.** The tool opens a session with a hello carrying a fresh
random nonce. The machine answers with the nonce, a new 128-bit session
identifier and its build identifier; the tool refuses a machine of
another build. The machine ends the previous session, with every facet
it held.

**Authority.** The session's authority is a **facet table**, created
empty with the session and ending with it. A call names its target by
number: 0 is the root, which opens facets, and any other number an
entry of the table. No call names a process, so nothing on the wire
reaches what the session was not given.

**At most once.** A tool that resends a lost call must not load a
module twice. The session keeps a window of the 64 highest call
identifiers, each unseen, executing or answered, with the replies it
can keep. A duplicate of an answered call gets its kept reply, or
`{error, reply_lost}`; a call that would push an executing one out of
the window is answered `{error, busy}` without running.

**Credit.** The machine's serial driver buffers at most 64 KiB, so the
tool sends only within credit, 16 KiB at the start of a session, which
the machine renews as it reads.

The transport trusts its one physical or local peer. CRC detects
corruption and session identifiers reject stale traffic; neither
authenticates anyone. Remote use goes through an authenticated channel
such as SSH, never a bridge of the serial line to a network.

The host link is **Built** (`erlang/apps/erx_uart/src/erx_hostlink.erl`
and the modules beside it), with its framing fuzzed
(`test/erlang/erx_hostlink_frame_fuzz.erl`). Its root opens two facets,
`install` and, in a development build that configures a web domain,
`web`; the files stream is served too. The design's `inspect`,
`trace`, `console` and per-domain `code` facets answer
`{error, unsupported}`: they, and `tools/erx inspect`, `trace`,
`source` and `console` over them, are designed and not built.

### 21.4.2 The code store

Every compiled module is a **blob**, named by the SHA-256 of its bytes,
and a module's version is its blob's hash. A **manifest** maps module
names to hashes. A load has three steps, each a call on the install
facet (`erlang/apps/erx_code/src/erx_code.erl`):

1. **Missing.** The tool computes each module's hash on the Mac and
   asks which hashes the store lacks.
2. **Put.** It sends each missing blob in pieces of 64 KiB, in order.
   The store keeps the blob only when its last byte arrives and the
   bytes hash to the name; a blob one bit off is refused with
   `hash_mismatch` and never stored.
3. **Load.** It sends the manifest. The code service hashes every
   named blob again, so a store whose bytes changed can fail a load but
   never change what is loaded.

The load itself is all or nothing. `code:prepare_loading/1` checks
every module of the manifest, and `code:finish_loading/1` makes the
whole batch current or none of it, the two halves of OTP's
`code:atomic_load/1`. A batch refused only because a module still has
old code is finished again after a purge, as an ordinary load would
purge; any other refusal leaves the old code running.

Naming by hash buys three things. An unchanged module costs no
transfer, which is why the host compiles with `+deterministic`: the
same source gives the same bytes and the same hash
(`tools/lib/erx/code_watch.rb`). The store keeps each module's history,
the hashes loaded and when, which `erx_code:history/2` returns. And a
rollback is a load of an older hash, with no transfer while the store
holds the blob. The store holds 16 MiB; to make room it frees first
the blobs that only older history names, and never a module's current
blob (`erlang/apps/erx_code/src/erx_code_store.erl`).

From the Mac, `tools/erx load FILE...` sends files as one batch, and
`tools/erx watch DIR` polls a source tree every half second, compiles
each changed source with the same `erlc` that built the image, and
loads it. A QEMU check reloads a module 32 times on four CPUs while
workers call it, and checks that no call ran stale code
(`tools/lib/erx/reload_guest.rb`). The code service, its in-memory
store with history, and `load` and `watch` into the system domain are
**Built**.

### 21.4.3 What the design adds

The design takes the same store to every domain and makes it outlive
restarts ([design-live.md, The code store](../design-live.md#the-code-store)):

* **Other domains.** A domain's code facet sends modules to that
  domain's code server; a malformed module fails or crashes only that
  domain.
* **Overlays.** For a domain the domain service restarts when it ends,
  the code service keeps an **overlay**, the manifest of the modules
  loaded into it from outside. A restarted domain loads it before its
  applications start. An overlay made over another release is dropped,
  so old modules never run over a system update.
* **Hot stores.** Each principal's blobs live in a store of its own,
  charged to its budget and kept on the data partition, so one
  principal never learns what another loaded.
* **Installed storage.** The system domain's runtime refuses any
  module outside its release and the code service's arena with
  `{error, not_installed}`
  ([chapter 9](09-processes.md#952-code-by-hash)).

These four are designed and not built. `tools/erx load` and `watch`
take `--domain` with only the system domain's id, 4.

### 21.4.4 Files and the browser

`tools/erx files` relays a UNIX socket on the Mac to the host link's
files stream, so any 9P2000.L client on the host mounts the machine's
trees: in a development build, `proc` and `data`
(`tools/lib/erx/files_relay.rb`,
`erlang/apps/erx_uart/src/erx_hostlink_files.erl`); 9P's own fids are
the handles. It is **Built**. The machine mounting a directory of the
Mac at `/host`, through QEMU's virtio-9p device and a domain of its
own, is designed and not built.

`tools/erx web` shows the machine's records in a browser over the web
facet; [chapter 22](README.md#chapter-22-displays-windows-and-the-web)
describes it.

## 21.5 Logs and crash reports

When something fails, the record of why must reach a person, attributed
and readable, without carrying the secrets of the process that failed.

> **Background: logging and crash dumps.** A **log** is a stream of
> short records, each with a time, a severity and a text, that
> components write as they run; UNIX collects them in `syslogd`, which
> files them under `/var/log`. Erlang's `logger` does the same within
> a node, and OTP's behaviours log a **crash report** when a process
> ends abnormally: its exit reason, its last message and its state. A
> **crash dump** is a larger record written when a whole program or
> kernel dies: its registers, its stack and its memory, kept for a
> developer to read after the restart. Both are written at the worst
> moment, by a system that is already failing.

### 21.5.1 One log service

Every log event of the machine, the kernel's records and every
domain's `logger` events, reaches one service in the system domain,
`erx_syslog` ([design-log.md](../design-log.md)). It stamps each
record, holds each domain to a rate, escapes the text and hands the
line to its consumers. A domain's record renders as one line:

```text
SECONDS.MICROSECONDS LEVEL domain ID principal P NAME: TEXT
```

Everything before `NAME` is the service's own text, ASCII by
construction; the domain's name and the record's text pass through the
line escape. A kernel record keeps the line the kernel's log core
rendered, with its own sequence number, `#SEQ SECONDS.MICROSECONDS
LEVEL TEXT`, so a gap in the numbers shows where kernel records were
lost. No domain's line begins with `#`, so a reader tells the two forms
apart by the first character.

The service, its pure core and its console consumer are **Built**
(`erlang/apps/erx/src/erx_syslog.erl`, `erx_syslog_core.erl`). The
store that appends the lines to `/var/log/messages`, rotates the files
and serves them read-only, so that `tail -f /var/log/messages` and
`grep` work as on UNIX, is designed and not built. There is no log
command and no read operation in the design: the files are the
interface, as Plan 9 would have it.

### 21.5.2 Reports carry no term

OTP's crash reports quote what a process held: `proc_lib`'s report
prints the message queue and the process dictionary, and `gen_server`'s
termination report prints the last message and the whole state
([design-log.md, Reports carry no term](../design-log.md#reports-carry-no-term)).
In a domain whose processes hold a key or a peer's bytes, each of those
is a leak.

The **report filter**, `erx_report`, closes them in one place. Every
event of the runtime passes it, a primary `logger` filter, and it
rewrites each of OTP's reports to names: the process, its registered
name, the error's class, the reason's leading atom and the stack's
functions. It drops every other term. A domain's own events, built
from named fields, pass unchanged.

Every runtime but the system domain's installs the filter at boot,
through an erXos change to OTP's `kernel`, so no domain can forget it.
It never raises on OTP's reports, since `logger` removes a filter that
raises and every later report would then pass whole. The system domain
keeps its reports whole for its operator; a system-domain process that
holds another domain's bytes hides them with `format_status/1`. The filter is
**Built** (`erlang/apps/erx/src/erx_report.erl`); its test crashes the
Bluetooth controller process with the controller's bytes in its
mailbox and checks that no report carries them
(`test/erlang/erx_report_tests.erl`).

### 21.5.3 The crash record

A fault in the system domain ends the machine, since every domain
depends on the root task ([chapter 10](10-domains.md)). On its way
down, the root service writes one **crash record** to the console, a
fixed layout of the ABI file
([design-fiasco.md, The end path](../design-fiasco.md#the-end-path)).
It holds the cause (a fault, a halt or a missed watchdog pet), the
program counter and fault address, the build identifier and the
uptime. It also holds the faulting thread's registers, a backtrace and
the tail of the kernel log, with the slogan ERTS writes before it
stops. The harness reads it from the serial log with
`tools/lib/erx/crash_frame.rb`, which treats every byte as untrusted.
The record is **Built**; the system-domain QEMU suite crashes the
system domain's runtime and reads it
(`tools/lib/erx/qemu_suites/system_domain.rb`).

On Fiasco no memory region survives the reset, so the next boot has
nothing to show. The design keeps the record in such a region where the
platform has one, for the system shell to read at `[kernel, crash]`.
It also gives release builds a **brief form**, with no registers, stack
or log, so that nothing the system domain held survives the reset
([design-system.md, The crash record](../design-system.md#the-crash-record)).
Both are designed and not built; the root always writes the full form
(`liberx/backend/fiasco/end.c`).

A crash of any other domain ends only that domain, whose runtime
writes its dump into the domain's crash area
([chapter 8](08-kernel-interface.md#834-one-request-end-to-end-a-domains-crash-area)).
Reading that dump at `/proc/domains/ID/crash` is designed and not
built.

## 21.6 Attributed text

Text shown under its source's name is **attributed text**: a domain's
name, a log line, a source line from a file a domain supplied. It is
escaped by whatever displays it, as FreeBSD's `ls` escapes odd file
names; a program's own output is not
([chapter 11](11-security.md#11122-what-is-not-escaped)).

Each display has its one escaping function, and the tables of each are
generated from one file, `abi/terminal.txt`
([chapter 11](11-security.md#11121-one-escape-generated-from-one-table)):

| Sink | Escape | Status |
| --- | --- | --- |
| the console's log lines and menus (`erx_console`) | line escape | Built |
| inspection records in the shell (`erx_render`) | line escape | Built |
| trace lines (`erx_trace:line/1`) | line escape, once over the whole line | Built |
| `/proc` files (`erx_procfs`) | field escape | Built |
| the host tool's printer | its Ruby twin of the line escape | Built |
| the host tool's `inspect`, `source` and `trace` output | its Ruby twin | Designed |

The console and the host terminal come first because that is where an
attack lands: bytes a domain chose, printed raw, can rewrite the
operator's screen or make the terminal type input back. The one guest
stream the host tool is designed to pass raw is a console session's
terminal stream, a tty's output, as `ssh` passes a remote shell's.

## 21.7 When parts fail

The live machine is ordinary Erlang code, and its parts fail the
ordinary way: one process ends, and the rest goes on.

* **A slow or dead agent.** After 500 ms every runtime attribute reads
  `{timeout, 500}` and the rest of the record still answers.
* **A query that fails** answers `{error, failed}`; the next query
  gets a new worker.
* **A flooded trace** passes its heap bound and is killed, and its
  receiver sees the end through a monitor. A receiver that stops
  reading costs the trace a counter, never a queue.
* **A ring that refuses a read** shows one `error` entry, and the
  trace goes on with its other sources.
* **A broken host link.** A garbled frame fails its CRC and is
  dropped; the tool resends, and the call window keeps the resend from
  running twice. A new hello ends the old session and its facets.
* **A bad module.** A blob that does not match its hash is never
  stored, and a refused batch leaves every old module running. A
  module that loads and then crashes is ordinary buggy code: its
  supervisor restarts it, and the history holds the hash to load back.
* **A crash of the system domain** resets the machine, with the crash
  record on the console.

## 21.8 Design choices

**One tree, not many tools.** FreeBSD's `sysctl` names, `procfs` files
and `procstat` output are three models of overlapping data, with three
permission rules. erXos keeps one schema, and `erx:i/1`, `/proc` and
the browser are views of it behind one facet. The schema must name
everything; in return a new attribute appears in every view at once,
under one scope check.

**The receiver traces its frames.** A router between domains could
record every frame for all of them, but erXos has no router on a
connection; only the receiver's funnel knows whether a frame was
accepted.

**9P on the host link, not a file protocol of its own.** A file facet
with open, read and write calls would be an erXos protocol that no host
tool mounts. 9P2000.L is already the machine's file protocol, and any
9P client on the Mac mounts it, with its own fids as handles.

**Code by hash, not by name and version number.** A version number is
a claim its writer makes; a hash is a fact anyone can check. With
hashes, the transfer, the deduplication, the history and the integrity
check are the same mechanism.

## Summary

The inspector shows any part of the machine as a record whose every
attribute names its reporter and carries a status. A value the system
cannot measure reads as unknown, partial, unsupported or timed out,
never as a number; on Fiasco that covers each CPU's idle time and
other domains' groups and budgets. A query passes through the caller's
inspect facet, and a path outside its scope answers as one that names
nothing. Records name processes by numbers, so inspecting hands out no
authority. Tracing merges OTP's events and the root service's ring on
one clock, bounded so a trace cannot harm the machine it watches. The
host link carries modules from the Mac at most once per call, and the
code service loads them by hash, all or nothing. Logs are one
attributed, escaped line per record, and crash reports outside the
system domain carry no term.

## Where to read next

* [design-live.md](../design-live.md): the inspection schema, scopes,
  `/proc`, tracing, the host link, the code store and the escapes, with
  each invariant and its test.
* [design-log.md](../design-log.md): the log service, its line, its
  store and the report filter.
* [design-system.md, The crash record](../design-system.md#the-crash-record):
  the two forms of the crash record.
* [design-fiasco.md, Reporting kernel objects](../design-fiasco.md#reporting-kernel-objects)
  and [The trace ring](../design-fiasco.md#the-trace-ring): what the
  root service reports on Fiasco, and why the rest is unsupported.
* `abi/inspection.txt`: every path, kind, attribute and reporter.
* David A. Moon, "Symbolics Architecture", *IEEE Computer* 20(1),
  1987: the Lisp machine whose live, inspectable environment this
  chapter follows. <!-- check: citation details. -->
* Stuart Cheshire and Mary Baker, "Consistent Overhead Byte Stuffing",
  *IEEE/ACM Transactions on Networking* 7(2), 1999: the framing of the
  host link. <!-- check: citation details. -->
