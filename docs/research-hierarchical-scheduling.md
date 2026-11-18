# Research record: hierarchical scheduling and the kernel-runtime contract

A point-in-time report of the research behind erXos's two-level scheduling.
It covers every reference of the architecture proposal of 29 October 2026
(v0.2), read in full wherever a copy could be obtained, and the related work
its readers judged important; a hands-on check of Fiasco under HVF and TCG;
and a count of Fiasco's compiled size. For each source it records the
edition read, the ideas erXos adopts and rejects and why, and the numbers
with their conditions. It then sets the mechanisms side by side, maps the
sources onto the experiments of
[design-scheduler.md](design-scheduler.md#performance) and
[design-domains.md](design-domains.md#performance), proposes further
experiments, checks the factual claims of the user's critique of two-level
scheduling, and lists corrections to the proposal's references. The
decisions that use it are in [design-scheduler.md](design-scheduler.md),
[design-kernel.md](design-kernel.md), [design-domains.md](design-domains.md),
[design-runtime.md](design-runtime.md) and [design-system.md](design-system.md).
Findings here are never edited in place; a re-check gets a new record.

**Trimmed record.** This copy keeps the summary, the method, the two
per-paper notes other documents cite, and every section from
"Kernel-runtime interfaces" on, except the check of the user's critique
and the corrections to the proposal's references. The full record, with
the per-paper notes on every reference, the related work, the critique
and the corrections, is `~/erxos-history/docs-archive/research-hierarchical-scheduling.md`, history commit `e38149b`.

**Date:** 2026-10-29: sources obtained and read; Fiasco built, booted and
measured. The record was compiled from the readers' extracts on 2026-10-30;
the items marked *(checked)* were re-read that day in the same downloaded
copies, and the size count was re-run on the same build with identical
totals.
**Host:** Apple M4 Max, 16 cores (12 performance, 4 efficiency), 64 GiB;
macOS 27.0.1 (26A434), Darwin 27.0.0.
**Tools:** `pdftotext` (poppler 26.10.0, the host's installed version) for
text renderings; `shasum -a 256`; Ruby 4.0.7 for the size count; for the
Fiasco check, QEMU 11.1.2 (Homebrew, machine `virt-11.1`), `aarch64-elf-gcc`
16.2.0, `aarch64-elf-binutils` 2.47 and GNU make 4.4.1, with the full list
under [Fiasco under HVF](#fiasco-under-hvf).
**Sources:** the entries below, all accessed 2026-10-29. Local copies are
under `~/erxos-scratch/papers/` (`a/`, `b/`, and figure renders in
`b-render/`), `~/erxos-scratch/borrow/rootserver/l4/` (Fiasco and L4Re
clones and saved L4Re web pages, cloned and saved on 2026-10-29) and
`~/erxos-scratch/src/otp_src_29.1.2/`. The SHA-256 of every download is in
`~/erxos-scratch/papers/a-manifest.sha256` (130 entries) or in the readers'
extracts; each entry below gives the first 16 hex digits of its primary
copy. Downloads were treated as untrusted data: nothing in them was run
except the Fiasco and L4Re builds and boots described under
[Fiasco under HVF](#fiasco-under-hvf).
**Method:** [Method](#method).

## Summary

* **Coverage.** The proposal lists 25 links. Nineteen papers and documents
  were read in full, from the linked copy or an equivalent one (open copies
  for the two IEEE links). The Fiasco and scheduling-constraints
  repositories were read at the files their entries name. The Nemesis link
  is an index page; three Nemesis papers were read instead. The L4Re
  architecture pages on scheduling, IPC and memory were "Under
  Construction". The L4Re Scheduler and vCPU API pages were read through
  the headers they are generated from. More than 60 further sources
  (papers, theses, manuals, mailing-list posts and source trees) were
  read; the most important are under "Related work" in the full record.
* **One shape recurs.** Every system that kept a two-level scheduler
  working keeps an interrupted continuation where it stopped and lets the
  runtime learn of events at its own safe points: Psyche's masked software
  interrupts, Nemesis' resume slot, Barrelfish's disabled save area,
  Akaros's disabled notifications, the Fiasco vCPU's disabled state,
  Tessellation's cleared tick flag. erXos takes the limiting case: every
  preemption is transparent and there are no upcalls at all
  ([Kernel-runtime interfaces](#kernel-runtime-interfaces)).
* **Lost wakeups are prevented by construction, not by care.** Level-valued
  state plus a park that can fail appears in Akaros ("yield can fail"),
  Barrelfish (the yield predicate), Arachne (a CAS on a wakeup word), ghOSt
  (sequence-checked commits) and Nemesis (event counts). erXos's
  `erx_park` compares two epochs under a lock.
* **Lock-holder preemption is mitigated everywhere and solved nowhere.**
  Solaris and Linux keep a bounded deferral of preemption; Linux grants
  5 µs by default and at most 50 µs. erXos's default grace is that maximum,
  and no source measures how long ERTS holds its locks
  ([Lock-holder preemption](#lock-holder-preemption)).
* **Work done for others is paid by the donor** in CPU inheritance
  scheduling, Credo, seL4's passive servers and Nemesis; Resource
  Containers add a passable charge handle but no access control. erXos
  combines call donation, charge words held as capabilities, and a payer
  fallback that seL4's authors criticise in L4 timeslice donation
  ([Hierarchy and flattening](#hierarchy-and-flattening)).
* **Negative evidence.** Every two-level thread system that was abandoned
  was a general-purpose thread library for arbitrary C code (POSIX threads,
  or Win32 threads in Windows); the stated reasons are complexity, poor
  multiprocessor scaling and missing real-time support (NetBSD), an M:N
  library "never developed to its full potential" (FreeBSD), a 1:1 library
  that was simpler and sufficient (Solaris), and a kernel scheduler fast
  enough to make the motivation moot (NPTL)
  ([Negative evidence](#negative-evidence)).
* **Fiasco under HVF.** An EL1 build of Fiasco (snapshot 26.09.0 and commit
  `50bbe8a9`) boots unmodified on the M4 under HVF with Apple's vGIC, on 4
  and 8 CPUs. A null system call costs 29.3 ns and a vCPU round trip 140.4
  to 141.2 ns (median, FPU enabled). The default EL2 build hangs under
  HVF, and Fiasco has no MSIs there for lack of GICv2m code
  ([Fiasco under HVF](#fiasco-under-hvf)).
* **Fiasco's size.** The EL1 build compiles 66,837 nonblank lines of
  preprocessed C++, 28% of it the kernel debugger and trace buffer
  ([Fiasco sizes](#fiasco-sizes)).
* **The three dispatch models.** The literature predicts that a kernel
  thread per lightweight process loses on spawn and exit (28 times in the
  one measurement), on memory by the stack each thread needs, and on
  switches by about 3 to 16 times on the hardware measured, none of it the
  M4; that runtime grants pay mainly under oversubscription and lock
  contention; and that without either, plain one-to-one scheduling of
  executors matches grants when domains do not share CPUs
  ([The three models compared](#the-three-models-compared)).
* **The user's critique** holds up: of its 24 factual claims, 18 are
  supported by the sources read, 4 partly, none is contradicted, and 2
  cannot be checked from what was read; its 4 judgements agree with the
  sources
  ("The user's critique, claim by claim" in the full record).

## Method

* **Readers.** On 2026-10-29 three readers worked from one brief and saved
  extracts with pointers, kept in `~/erxos-scratch/design-hier/` as
  `report-helperA.txt`, `report-helperB.txt` and `report-a2c6357a.txt`:
  * helper A read the L4, Fiasco and seL4 papers and the scheduling
    constraints code itself, added the Fiasco vCPU paper, and merged three
    forks: Composite, Fluke and Mach; ghOSt, Syrup, `sched_ext`, Concord and
    Shinjuku; JX, SPIN, Singularity and Inferno;
  * helper B read Psyche, scheduler activations and Barrelfish (with
    Barrelfish's source) itself, and merged forks for Lithe, Akaros and
    Tessellation, for the negative evidence, and for Arachne, Shenango and
    Caladan;
  * a third reader extracted Converse, CPU inheritance scheduling, Nemesis,
    hierarchical SFQ and Resource Containers, with file hashes.

  Helper A spot-checked about 40 of its forks' numbers and helper B about
  30 quotes and numbers against the text files; all matched. Where two
  extracts overlap, this record follows the one with the more precise
  pointer and notes disagreements.
* **Reading.** "Read in full" means every page of the named copy.
  Pointers `file:line` refer to the text renderings beside each PDF in the
  entry's directory (`.txt`; `.raw.txt` in reading order; `.layout.txt` for
  tables; `sched_act.squeezed.txt` with normalised whitespace); "p." is a
  printed page, "PDF p." a page index, and Fig. and Table the source's own
  numbering. Converse's text layer is unusable and was read from page
  images; the text layers of Hand, Banga et al. and Ford and Susarla drop
  the µ sign, and their units were confirmed on page images.
* **Kinds of number.** A *measured* number names who measured it, how and
  where; a *cited* number gives its source, pointer and platform; an
  *estimate* names its method. *(reading)* marks a value read off a graph,
  *(inferred)* a conclusion drawn from the cited evidence, and
  **unverified** a claim no source read for this record confirms. Numbers
  from different platforms are given with their platform and never
  compared without saying so; HVF and TCG numbers are never compared.
* **Checks for this record**, made on 2026-10-30 in the downloaded copies
  and marked *(checked)* where used:
  * the SHA-256 of 35 primary copies, all equal to the values in the
    manifest or the extracts except one garbled value in an extract
    (below);
  * Rasiukevicius's statement and date, the NetBSD 5.0 announcement and
    change list, Williams on critical-section recovery, preallocated LWPs
    and signals, the FreeBSD 7.0 announcement, the `UPDATING` entry and
    commit messages of the KSE removal, `kse(2)`, Wemm's mail, the Solaris
    white paper on preemption control, Linux's `rseq.rst`, the Windows UMS
    page, Zijlstra's UMCG mail, Turner's slides and the NPTL paper;
  * Stoess's overhead figures, the vCPU paper's passages on preemption and
    on one budget for two threads, Table 5 of the flattening paper, three
    critiques in the seL4 paper, Concord's IPI and polling costs, the 2.4 ms
    upcall path of scheduler activations, Arachne's 10 ms revocation, Fluke's
    Tables 6 and 7, and Hohmuth and Härtig on Fiasco's thread descriptors;
  * the title pages of the two Akaros theses, OTP 29.1.2's `erl_cmd.md` on
    scheduler counts and binding, the saved L4Re pages, and the `l4sys`
    scheduler and vCPU headers at `l4re-core` `e2e2d5af`;
  * Converse's printed page 25 (on a page image), Rhoden's two rules for
    memory the kernel shares with user space, the seL4 paper's statement
    that its kernel is non-preemptible, and the Solaris white paper's
    remark on user-level context switching;
  * the size count of [Fiasco sizes](#fiasco-sizes), re-run.
* **Corrections to the extracts.**
  * The third extract printed a garbled SHA-256 for the Nemesis paper's
    `paper.html`. The manifest and a recomputation agree on
    `ae24148f4dedc1ad39aeba657652d76d23077bc660f039836d6fa5e634d5e664`.
  * Helper A's summary of Fluke's latency table omits the interrupt model
    with one preemption point: 18.7 µs average and 1,272 µs maximum
    (`fluke-osdi99/lepreau.layout.txt:730-734`) *(checked)*.
  * Helper B's "wrong thesis in the prompt" concerns the readers' brief, not
    the proposal, whose Akaros link and label are right
    ("Corrections to the proposal's references" in the full record).

## The proposal's references

The per-paper notes on the proposal's references and on the related work
are in the full record (`~/erxos-history/docs-archive/research-hierarchical-scheduling.md`, history commit `e38149b`). The two that other documents cite
are kept here.

### L4Re/Fiasco source

* **Edition.** The proposal links <https://github.com/L4Re/fiasco>. What
  was read and built is the clone of <https://github.com/kernkonzept/fiasco>
  at commit `50bbe8a9` (2026-10-14, still the head on 2026-10-29), cloned
  2026-10-29, and the Fiasco tree of the L4Re snapshot 26.09.0 (published
  2026-09-27; archive SHA-256 `6c24687b22e1fca1`, matching the published
  `SHA256SUM`). Whether the proposal's URL serves the same history was not
  checked. The two trees differ in 58 `diff -rq` entries, and a snapshot
  user land does not boot a `50bbe8a9` kernel
  ([Fiasco under HVF](#fiasco-under-hvf)). The files named below were read
  by helper A and by the earlier root-server evaluation
  (`~/erxos-scratch/draft/research-results/root-server-evaluation.md`,
  2026-10-29), whose pointers marked checked there were re-read.
* **Mechanism, scheduling.** Each `Context` embeds one scheduling context
  (`src/kern/context.cpp:394-395, 665-666`) with a fixed priority from 1 to
  255 and a quantum (`sched_context-fixed_prio.cpp`); per-CPU ready queues
  by priority run round robin within a level (`ready_queue_fp.cpp`); the tick
  is `CONFIG_SCHED_GRANULARITY` (1,000 µs) and the default slice 10 ticks
  (`Kconfig:366-381`; the measured build has
  `CONFIG_SCHED_DEF_TIME_SLICE=10`, and its kernel debugger shows
  "timeslice: 10000 us" *(checked)*). A slice that expires only requeues
  its thread (`timeslice_timeout.cpp:34-49`). The IPC direct switch keeps
  the sender's scheduling context when the sender waits for the reply
  (`thread-ipc.cpp:762-779`), but `schedule_switch_to_locked` installs the
  chosen thread's own context (`context.cpp:1148-1163`), so a donation
  lapses at the next scheduling decision. Time is charged to the executing
  `Context` (`context.cpp:1126-1139, 1292`). Helping lives on in
  `switch_exec_helping` (`context.cpp:1243-1260`) and `Switch_lock`;
  `Pi_mutex` is enabled by default (`CONFIG_PRIO_INHERIT`). Other CPUs are
  reached through cross-CPU requests.
* **Adopted.** Per-CPU fixed-priority ready queues with round robin within
  a level (erXos has 64 urgency levels); cross-CPU requests that keep
  per-CPU structures free of locks; IPC timeslice donation, made to last
  until the reply in the stopgap; the `Ram_quota` hierarchy as the
  stopgap's budgets (design-kernel.md, The current implementation).
* **Rejected** for erXos's own kernel: a kernel stack per thread, a
  preemptible kernel and helping locks
  ([Kernel execution models](#kernel-execution-models)); the mapping
  database; read-copy-update reclamation (design-kernel.md, No grace
  periods).
* **Numbers.** Measured on the M4 under HVF by the Fiasco check: null system
  call 29.3 ns, vCPU round trip 140 to 141 ns
  ([Fiasco under HVF](#fiasco-under-hvf)); size
  ([Fiasco sizes](#fiasco-sizes)). Cited from
  <https://l4re.org/performance.html> through the root-server evaluation
  (checked there): one-way IPC within a task, between tasks, and a system
  call cost 247, 384 and 138 cycles on a
  Cortex-A76 at EL1, and 562, 691 and 230 on a Cortex-A53. The repository
  had 936 commits in the year to 2026-10-29 (root-server evaluation).

### Scheduling constraints (RTAS 2026)

* **Edition.** M. Lumme, M. Roitzsch and A. Lackorzyński, "Scheduling
  Constraints: A Universal OS Mechanism for Managing Shared Resources",
  IEEE RTAS 2026, Saint-Malo, DOI 10.1109/RTAS68450.2026.00042. The
  proposal's IEEE page (<https://ieeexplore.ieee.org/document/11558383/>)
  returned an empty response; the open camera-ready linked from L4Re's
  research page, `os.inf.tu-dresden.de/papers/rtas2026-l4re-sched-constraints.pdf`
  (PDF eXpress 2026-03-30, 14 pages), was read in full, figure values from
  220-dpi renders (`b/l4re-rtas26/`, `f0b4cdc741ebb257`). Accessed
  2026-10-29.
* **Mechanism.** A scheduling constraint is a kernel object holding one
  boolean. A thread runs only while every constraint attached to it is
  true (conjunction; disjunction showed "significant overheads"). The
  check happens in `schedule()`: a candidate whose constraints fail is
  removed from the ready queue and registered on the failing constraint,
  and setting the constraint true requeues every registered thread. At
  each context switch the outgoing thread's constraints are deactivated and
  the incoming thread's activated, so a budget constraint saves its
  remainder and re-arms its timer. Donation and helping carry the donor's
  whole constraint set. Constraints whose last capability is gone become
  quiescent and "still enforce their condition", and a restarted manager
  can take them over. Priorities stay a thread attribute: "We also
  considered subsuming thread priorities into the SC mechanism, but
  ultimately decided not to."
* **Adopted.** Conjunctive caps along the group path: a thread runs only
  while every group on its payer's path has quota (invariant S5). Lazy
  throttling with a list per group and CPU. Fail-closed enforcement that
  outlives the policy holder. Priority kept apart from budget (urgency and
  quota). Grants changed only by the policy, which alone holds `CONFIGURE`.
* **Rejected.** Booleans set by user-level servers as the budget mechanism
  (the paper keeps its own budget and bandwidth servers in the kernel and
  notes "deadlocks are still possible for resource servers in userspace");
  CPU masks supplied by the caller; disjunction.
* **Numbers** (cited; Raspberry Pi 4, four Cortex-A72 at 1.5 GHz, a
  development kernel used for relative numbers):
  * Fig. 3, IPC round trip in cycles: the text gives about 981 within one
    CPU and address space, 1,255 across address spaces and 7,486 across
    CPUs, "agnostic to SCX size";
  * Fig. 4, context switch in cycles for 0, 1, 2, 4, 8, 16, 32 and 64
    constraints per thread, one address space: 796, 828, 861, 935, 1,070,
    1,332, 1,775, 2,738; one constraint adds 32 cycles in one address space
    and 37 across two (readings);
  * Table II, run time normalised to the baseline: 1.000039 (pi), 1.000800
    (a Linux virtual machine), 1.030476 (producer-consumer), 1.053397
    (OpenMP);
  * Fig. 5, cost of flipping a constraint against affected cores 1 to 4:
    asynchronous 633, 1,409, 1,713, 2,006 cycles; synchronous 633, 2,917,
    3,639, 4,228 (readings);
  * a critical task kept its deadlines while a best-effort task used up to
    60% of the CPU under budgets in a 10 ms period.

## Kernel-runtime interfaces

The proposal requires that "the runtime must preserve an interrupted
continuation until a safe point", and that "timer preemption must not
recursively invoke ERTS during GC or a critical section". Every interface
below answers two questions: where an interrupted continuation goes, and
what keeps the runtime from being entered while it is inside its scheduler,
its collector or a critical section.

| System | The interrupted continuation | Entry during a critical section is avoided by | Events while the runtime is busy | Lost-wakeup guard |
| --- | --- | --- | --- | --- |
| Psyche | the kernel resumes the VP in place | masking software interrupts; a warning before the quantum ends | queued by importance behind a "queued" flag, drained by a call | the queued flag |
| Scheduler activations | saved by the kernel and handed to the runtime by an upcall on a new activation; never resumed directly | recovery: the upcall finishes the preempted critical section in a copy | combined into one upcall | as many running activations as processors |
| Nemesis | resume slot while the activation bit is clear; activation slot and an upcall while it is set | clearing the bit around critical sections; `rfa()` re-enables and switches atomically | event counts and a FIFO of endpoint indices | counts "never lose events" |
| Barrelfish | resumed in place from the disabled area when disabled or inside the critical PC range; else the enabled area and a Run upcall | the `disabled` word and the PC range | delivery counters and `haswork` | the yield predicate |
| L4Re vCPU (Fiasco `50bbe8a9`) | resumed in place: an expired slice only requeues the thread | events disabled in the state word | a sticky pending flag, checked on enable | the pending flag |
| Akaros | the vcore context restarts where it stopped while notifications are disabled; else the user-thread context is saved and a notification raised | `notif_disabled` | `notif_pending` and mailboxes | "yield can fail" |
| Lithe | no preemption between runtimes; the operating system's preemption of the underlying threads is not handled (`lithe-pldi2010.raw.txt:583-590`) | cooperation | not applicable | `unblock` records and never resumes |
| Converse | no preemption | handlers run to completion | not applicable | a wake only when "acceptable" (p. 25) *(checked)* |
| Tessellation PULSE | saved to user space with `TICKS_ENABLED` cleared; interrupted scheduler contexts finish before continuations are handed over | the flag | an adaptation flag | persistent endpoints |
| erXos | always resumed in place; no runtime code runs at a preemption (invariant S1) | nothing to avoid: the kernel has no entry point into a runtime; a `defer` count postpones slice-end and quota preemption by a bounded grace | bits ORed into the control area's `events` word | `erx_park` compares the group and slot epochs under the park lock (invariant S2) |

**What the systems share.** Whenever a runtime cannot accept control, its
continuation stays where the kernel saved it; the runtime learns of events
through state it reads when it chooses; and a park or yield checks that
state and fails if it changed. **Where they differ** is whether the runtime
is ever entered asynchronously. Psyche, scheduler activations, Nemesis,
Barrelfish, the vCPU and Akaros all enter it, and each needs machinery so
that the entry never lands inside a critical section: a mask, a recovery
scheme, a bit with two slots, a PC range, or a disabled flag. erXos removes
the asynchronous entry, so the proposal's requirement holds by construction
and none of that machinery exists. The price is that a runtime learns of a
preemption only from its status words, and an event for a busy runtime
waits for its next safe point (experiment X5 below).

**Why ERTS needs no upcall.** ERTS switches processes only at reduction
checks, so the registers of an interrupted scheduler are of no use to it.
Its executors never block outside their domain, so "activation blocked"
cannot happen. What remains to tell it (wakeups, inbox records, capacity
changes, yield requests) is level-valued and fits in words it reads at its
safe points; ERTS already sleeps with a compare-and-swap protocol on its
scheduler flags (`erl_process.c:3086-3117`).

**What upcalls cost.** A vCPU round trip costs 140 ns on the M4 under HVF,
about 4.5 times a trap with an address-space switch (31 ns), both measured
([Fiasco under HVF](#fiasco-under-hvf)). Vectoring every preemption to a
user-level scheduler cost 1.4 to 2.1 µs per level on a 3 GHz Pentium D
(Stoess), and scheduler activations' prototype took 2.4 ms per kernel
signal-wait on the Firefly. A polled word cost Concord 1 to 1.5% where
interrupt-driven preemption cost Shinjuku about 12% at a 5 µs quantum, and
the two are roughly equal at about 25 µs (x86, cited). erXos's slices are
milliseconds, so its case for polled requests is safety, not cost
(inferred).

**Shared pages are an attack surface.** Barrelfish's kernel, as read by
helper B, restores state from user-writable memory, double-fetches `SPSR`
and asserts on re-read shared words. Akaros's rules are "I never have the
kernel operate in a loop controlled completely by the user" and "any
kernel locking strategy needs to use memory that is not user-writable"
(`EECS-2014-223.txt:3057-3058, 4344`) *(checked)*. erXos keeps saved
registers in kernel memory, reads the runtime-written words (urgency,
`defer`, charge) once per decision through its shared-area accessors, and
validates every value it loads (design-kernel.md, invariant K7).

**Faults inside the runtime's critical code** are undefined in Nemesis, kill
the process in Akaros, and make a Barrelfish domain unrunnable after two.
erXos commits memory before use and never pages to storage, so a fault the
kernel cannot resolve from a reserve ends the domain
(design-scheduler.md, Executor class enforcement).

**Taken.** Resume in place for every preemption; level-valued events read at
safe points; a park that fails when the state it observed has changed;
kernel-written status words (Psyche's magic page, Akaros's read-only page,
Barrelfish's published running dispatcher); no interrupt for a running
receiver (TN-009). **Rejected.** Every form of upcall: scheduler
activations' upcalls with state, Nemesis' activation bit and slots,
Barrelfish's Run upcall and PC range, vCPU event upcalls, Akaros's
notification upcalls and its event-delivery option matrix.

## Hierarchy and flattening

The proposal asks for "one CPU-resource authority with composable
second-level schedulers". The sources fall into three families:
hierarchies of schedulers, one kernel scheduler with several budgets per
client ("flattening"), and accounting principals.

| Source | Shape | Enforced by | Cost (platform) |
| --- | --- | --- | --- |
| Stoess 2007 | user-level schedulers; preemption IPC up the hierarchy | the scheduler threads; no kernel budgets | 1.4 to 2.1 µs per level; 7.8% at a 2 ms tick (Pentium D 3 GHz) |
| CPU inheritance 1996 | scheduler threads donate the CPU | the donating threads | dispatch 8.0 µs at the root, 24.4 µs at 8 levels (Pentium 100 MHz) |
| HSFQ 1996 | weighted SFQ tree in the kernel, any leaf scheduler | the kernel | depths 0 to 30 within 0.2% of throughput (SPARCstation 10) |
| Composite 2008 | scheduler components; kernel accounting | the components | thread switch 529 cycles, 688 through a scheduler, 976 with accounting (Pentium 4) |
| Flattening 2012 | several scheduling contexts per vCPU, switched by the guest | kernel budgets at global priorities | 795 cycles paravirtualised, 5,863 fully virtualised, per switch (Phenom 2.1 GHz) |
| Scheduling constraints 2026 | conjunctive objects attached to threads | the kernel | +32 to 37 cycles per context switch with one constraint, 1,070 cycles at eight (Cortex-A72, readings) |
| seL4 MCS 2018 | capabilities with sporadic budgets; donation to passive servers | the kernel | schedule +38 to 45%, call +1 to 21% |
| Temporal capabilities 2017 | non-replenished, delegable budgets with quality vectors | the kernel | delegation 786 cycles average (Core i7 2.8 GHz) |
| Resource containers 1999 | principals apart from domains; bindings | the kernel, over seconds | rebinding 1.04 µs (Alpha 500 MHz) |
| Nemesis 1995-1996 | Atropos per scheduling domain; services in the client | the kernel's EDF | reschedule 1.37 µs (Alpha 21064) |
| erXos | one kernel scheduler over a tree of groups whose quotas, cpusets and ceilings are intersected along the path; bands as child groups | the kernel, at every decision, at every level | a path walk of at most eight groups; a budget of 150 ns per pick or enqueue with a path of four, and an estimate of 30 to 80 ns per pick |

**A hierarchy of limits, not of schedulers.** Hierarchies of schedulers pay
per level and per event and leave isolation to the schedulers' honesty
(Stoess, CPU inheritance). erXos's tree is a hierarchy of limits evaluated
by one scheduler, the same flattening that the scheduling constraints
perform with conjunction: every group on a payer's path is charged and
checked (invariants S4 and S5). The only second level is the runtime, and
the kernel never calls it. seL4's objection that hierarchical delegation
suffers "algorithmic utilisation loss" concerns nested reservations with
guarantees; erXos's quotas are caps without admission control, so the
objection applies only if guaranteed reservations are ever added
(inferred).

**Bands.** Lackorzyński et al. show task sets that no single budget per
client can schedule and that several budgets at different global
priorities can. erXos realises this as child groups of a runtime's group,
one per band, named in the executor's charge word (design-scheduler.md,
Charge words). The priority stays apart from the budget, as both the
scheduling constraints and seL4 keep it.

**Accounting on behalf of others.**

* *Synchronous calls.* The donor pays: CPU inheritance ("charging T1 rather
  than T0 would allow the accounting system to be subverted"), Credo, seL4's
  passive servers, Parmer's thread migration. Stock Fiasco's donation lapses
  at the next scheduling decision (`context.cpp:1148-1163`); erXos fixes
  the server's payer when the call is delivered and holds it until the
  reply.
* *Asynchronous work.* Resource Containers rebind a thread to the client's
  principal per request, with no access control; temporal capabilities
  carry finite slices with requests. erXos's charge words name a donated
  group that the client's policy carved from the client's grant and handed
  over with only the `CHARGE` right.
* *Per-client bindings in servers.* Nemesis lets a server attach QoS
  parameters per binding (`TR376.utf8.txt:3543-3555`); erXos creates one
  donated group per binding.

**When the payer runs out.** erXos lets a server whose caller's payer is
exhausted continue on its own grant and counts the fallback; a charge word
that names an exhausted group falls back the same way (design-scheduler.md,
Payer and urgency resolution). Lyons et al. criticise exactly this in L4
timeslice donation ("the server will run on its own time slice"), and
bandwidth inheritance for the opposite reason ("make the waiting client
pay for another client's contract violation"). Their answer is a timeout
fault to a handler, which costs 1.13 to 23.3 µs depending on the action
and platform (cited). How much a client can make a server spend this way
(inferred from the design's rules): the fallback is resolved at every
decision, so it ends when the client's next period begins; meanwhile the
client's own threads are throttled, and each has at most one call
outstanding. Per period the server spends on the client's behalf at most
the work of those outstanding calls, and at most the rest of the period on
each server thread that serves one. For charge words the bound is what the
grant's ingress allowance admits (design-domains.md, Facets). Experiment
X2 measures it.

**Several CPUs.** A budget shared by several CPUs is unsolved in the L4
family as read: seL4 and temporal capabilities are per core, NOVA refuses
donation across CPUs, and the scheduling-constraints artifact arms one
timer per budget. erXos keeps one pool per period and lets each CPU draw
local slices of at most 1 ms, so a group's usage per period exceeds its
quota by at most one draw quantum per CPU (invariant S4). Linux's CFS
bandwidth control is a similar design, but it was not read for this record
(**unverified**).

**Replenishment.** erXos refills a group's pool once per period, at the first
draw after the period begins, and carries debts forward. seL4 uses sporadic
servers, and the scheduling constraints offer a deferrable server. A budget
refilled at period boundaries can be spent at the end of one period and again
at the start of the next, so a window of one period that straddles a boundary
can hold twice the quota (inferred from the design's rules); invariant S4
bounds only aligned periods. Experiment X3 measures what a victim sees.

**Taken.** Conjunctive caps along the path (scheduling constraints);
admission and grant changes held by the policy (seL4, Tessellation);
donor-pays call donation held until the reply (CPU inheritance, Credo,
seL4); capability-held charge handles (Resource Containers with the access
control they lacked); bands (flattening); per-CPU accounting (seL4).
**Rejected.** User-level scheduler hierarchies with an event per level
(Stoess, CPU inheritance); weights (HSFQ) and deadlines (Atropos, seL4)
until an experiment shows quotas and round robin within a level fall short
(design-scheduler.md, Alternatives considered); importing the
scheduling-constraints artifact.

## Lock-holder preemption

When the kernel preempts an executor that holds one of its runtime's locks,
the runtime's other executors spin or wait for a thread that is not
running. Every two-level system read meets this problem.

| Approach | Source | Bound on the delay | What remains |
| --- | --- | --- | --- |
| a warning before the quantum ends | Psyche: 3 ms of a 100 ms quantum in the experiment | set by the user up to a kernel maximum | best effort: "inopportune preemption is still possible" |
| recovery: finish the preempted critical section | scheduler activations; NetBSD; Mach | until the section ends | a descriptor update in every spinlock operation "undesirably adds overhead in the common case" (`williams.raw.txt:640-647`); two stopped contexts can deadlock (Rhoden) |
| a "don't preempt me" flag with a "you owe me" reply | Solaris since 2.6 (`schedctl`) | not stated in the white paper | the holder must yield when told, or lose the privilege |
| a time-slice extension | Linux `rseq` | default and minimum 5 µs, at most 50 µs, enforced by a timer | raising the default "can/will affect the minimum scheduling latency" |
| cooperative release, then force | Arachne | 10 ms | stranded threads without the arbiter |
| a deferral counter over scheduler, RCU and spinlocks | Shenango | not stated | "A malicious kthread could refuse to park" is not mitigated |
| a warning a few microseconds ahead | Caladan | a few µs | not stated |
| no preemption while an application lock is held | Concord | a lock counter | trusts cooperation |
| locks that advertise their holder, and a directed switch to it | Akaros | not applicable | about 16 cycles more per lock |
| a request for slack inside a critical section; gang scheduling | Barrelfish (HotPar 2010) | not stated | not measured for lock holders |
| restartable sequences and helping | Composite | not applicable | no atomicity across CPUs |
| deferred preemption | erXos | a grace of 50 µs by default, clamped to 5 to 1,000 µs, only for slice ends and quota exhaustion; overruns counted and repaid from the next period | urgency preemption stays immediate; collection and NIFs are not deferred sections |

**The evidence for mitigation.** Under periodic 10 ms preemption of two
vcores, plain MCS lock throughput fell to 0 and holder-aware locks kept
about 250 locks per ms (Akaros, Xeon). Psyche's warning cut completion from
40.1 to 16.0 s at multiprogramming level 2 and from 61.6 to 23.8 s at level
3, and helped only once work generation was decentralised. Oblivious
time-slicing stranded Arachne's user threads for milliseconds.

**erXos's choice** follows Solaris and Linux: a count the runtime raises
around its critical sections, a yield request, and a grace bounded by a
kernel timer. It needs no recovery code and costs the runtime two stores and
a load per critical section (design-runtime.md, Performance, an estimate).
The default grace is Linux's maximum, 50 µs, on the estimate that ERTS's
critical sections are longer than those Linux's extension targets. Linux's
own default is 5 µs, which is also its minimum, and its documentation asks
that "any proposed changes to this default ... come with a selftest and
rseq-slice-hist.py output that shows the new value has merrit"
(`linux-mainline-syscalls/rseq.rst`) *(checked)*. No source read measures
how long ERTS holds its run-queue, process or carrier locks; E-S3 does.
Two limits follow from the design (inferred): a wake of a more urgent
thread (the router, a driver) still preempts a lock holder at once, and
status words are what let the other executors avoid spinning on it
(experiment X6).

## Negative evidence

| System | What was abandoned, and when | Stated reasons | What survived |
| --- | --- | --- | --- |
| NetBSD | scheduler activations in `libpthread`, replaced by 1:1 when the newlock2 branch merged on 2007-02-09, which "replaces the existing SA threads model with a 1:1 threading model" (`changes-5.0.html:789`), first released in 5.0 *(checked)* | "The SA implementation was complicated, scaled poorly on multiprocessor systems and had no support for real-time applications" (Rasiukevicius, 4 May 2009, `netbsd_5_scheduling_apis.raw.txt:12-13`) *(checked)*; SA "restricts any instance of a threaded application to a single CPU" (Doran, `netbsd-newlock2-mail/0001.html:30-39`) | a compatibility layer: the 5.0 changes add "compatibility support for the Scheduler Activations" and builds for NetBSD 2, 3 and 4 chroots *(checked)* |
| FreeBSD | KSE and `libkse`: `libthr` became the default in 7.0 (announced 27 February 2008) and kernel KSE was removed on 2008-03-12 (`UPDATING` entry 20080312) *(checked)* | "the M:N approach taken by the kse library was never developed to its full potential" (Roberson's commit 6617724c5fb1); 1:1 is "Easier to write, easier to maintain, easier to understand, easier to debug, and *good enough*", while KSE threads "are almost certainly more efficient at runtime, but we've got to get to the 'running' point first" (Wemm, freebsd-arch, 3 April 2003) *(checked)* | nothing |
| Solaris | the M:N library: Solaris 8 added an alternate 1:1 library and Solaris 9 made 1:1 the default (white paper, ©2004 Sun) | "The 1:1 implementation was simpler to develop, and its code paths were generally more efficient"; of the two-tier advantages, user-level synchronisation "has proven to be significant, but the second advantage has not. Building a user-level scheduler that works well in tandem with the kernel's scheduler is a significant challenge" (raw text 349-359) *(checked)* | preemption control |
| Windows | user-mode scheduling: "As of Windows 11, user-mode scheduling is not supported", and it "is not available on Arm64" (`user-mode-scheduling.md:12, 19`) *(checked)*; Microsoft's own Concurrency Runtime stopped using it in Visual Studio 2013 (`concurrency-namespace-enums.md:229`) *(checked)* | none found in a primary source | nothing |
| Linux UMCG and SwitchTo | never merged: the mainline v7.3 system-call table has no such call (`syscall_64.tbl`) | Zijlstra: "these patches do *NOT* support the very thing this all started with, namely block + wakeup notifications ... the whole uaccess stuff is horrific" *(checked)*; Turner (LPC 2013): operations "must be commutative", "Requiring a re-entrant (asynchronous) user-scheduler entry classically hard; prefer a synchronous programming model" *(checked)* | `rseq` time-slice extension; Google's fibers use only cooperative features |
| Linux NPTL | the M:N candidates, in favour of 1:1 (Drepper and Molnar, 21 February 2005) | two schedulers that do not collaborate; register copying too costly; the O(1) scheduler made the motivation moot; signals "hard, a lot of code" (`nptl-design.raw.txt:238-251`) *(checked)* | starting and stopping 100,000 threads fell from 15 minutes to 2 s (520) |

**Stated against inferred.** The quotations above are the reasons the
implementers gave. Williams adds, for NetBSD, that N:M systems "are more
complicated than either of the other models, and can be more difficult to
develop, debug, and use effectively" (`williams.raw.txt:136-147`), that a
spare LWP had to be "pre-allocated and cached" so that a blocking upcall
could not recurse into the sleep path (562-566), and that POSIX signals
needed their own cooperation between kernel and library (352-367)
*(checked)*. `kse(2)` states the race that two schedulers create: the
switch of `km_curthread` "must be atomic with the loading of the context
of the new thread" (the FreeBSD 7.2 manual page,
`freebsd-kse-man/kse.2-7.2.html`) *(checked)*. The common factor is
inferred, not stated: every abandoned system was a general-purpose thread
library for arbitrary C code (POSIX threads, or Win32 threads in Windows),
whose kernel and library jointly owned each thread's state and blocking,
and for POSIX its signals. The NetBSD 5.0 announcement credits its gains
to the 1:1 library together with "new kernel synchronization primitives,
kernel preemption, a rewritten scheduler implementation" *(checked)*, so
no abandonment was an isolated comparison of M:N and 1:1. The scheduler
activations prototype took 2.4 ms per kernel signal-wait, and no source
read reports a measured win of cheap user-level switching large enough to
outweigh the complexity: Solaris found it "hard to support the idea that
user-level context switching is orders of magnitude faster than going via
the kernel" (raw text 1133) *(checked)*, and Klues found Lithe beat the
best static tuning by 2.3 to 10%.

**Why erXos's situation differs.** ERTS is one trusted runtime that already
multiplexes millions of processes over a few threads and scales on SMP; its
processes have no POSIX identity, signals or per-thread priority; it
switches only at reduction-counted safe points; and erXos's executors are
ordinary threads that are never entered asynchronously and never block
outside their domain. That removes the upcall re-entrancy, the replacement
activations, the signal layer and the joint ownership of thread state that
the implementers name.

**What still applies.** Lock-holder preemption
([Lock-holder preemption](#lock-holder-preemption)). Choosing how many
executors to run (Solaris, Arachne): capacity advice. Observability: Turner
argued for 1:1 partly because tools can see every thread, so the inspector
must show lightweight processes as first-class. A contract that grows:
keep it small and its state machines checked exhaustively. Foreign runtimes
resist: Akaros's Go port took 1.5 years and kept a pthread emulation layer,
which matters when erXos hosts runtimes other than ERTS.

## Identity and lifecycle

The proposal states the requirement in three sentences, quoted verbatim
from its v0.2 text:

* "Logical process: global, generation-safe identity, owner domain,
  lifecycle/supervisor, messaging endpoint and resource attribution."
* "The common PID/anchor registry belongs to trusted erXos services, backed
  by kernel domain/native-object identities, without a kernel TCB or
  syscall for every lightweight spawn. PID ranges and lifecycle events can
  be delegated and batched. PIDs express identity; capabilities
  independently express authority."
* "An Erlang resource manager allocates policy-level rights and budgets; a
  small guardian retains the authority to restart the system runtime and
  reclaim domains."

| Source | What names a process | What grants authority over it | What happens when its holder dies |
| --- | --- | --- | --- |
| Psyche | a name the VP writes into shared memory; "new processes can be created simply by inventing new names"; the kernel tracks only call chains across domains | probabilistic keys (rejected for erXos) | a trap that claims a departed process is an error |
| Resource containers | the protection domain names the process; a separate container names the principal that pays | holding the container's descriptor; no access-control model ("space does not permit a discussion") | not addressed |
| Singularity | a sealed process | channel endpoints, owned by one process at a time | killed without its cooperation; its frames are unwound; exchange-heap blocks record their owner and are reclaimed in the background; peers see the failure when they receive |
| JX | 64-bit domain ids never reused, checked with the pointer | portals | aborting a call sets a flag the service checks at a safe point; reference counts across domains miss cycles |
| SPIN | a strand has no kernel state beyond its name | type-safe guards on handlers | default handlers |
| Inferno | a process with its own namespace | the namespace: what is not in it cannot be reached | not addressed |
| Akaros | a many-core process with vcores; no kernel thread per user thread | not covered by the extracts | not covered by the extracts, except that a hard page fault in vcore context kills the whole process |
| Tessellation | a cell, a performance-isolated container | the allocation broker's one privileged call | not addressed |
| Mach migrating threads | a thread that spans tasks as a chain of activations | ports | terminating a middle activation splits the thread: the server side finishes with an alert, the client side gets an error |
| erXos | a pid whose creation field is its owner's domain id, never reused while the machine runs | an import held in the router, written only by delivery, spawning and attenuating grants | one death notice to every domain, after everything the dead domain sent; each runtime fires its own links and monitors to that domain's processes |

**What erXos does** (design-domains.md). A runtime runs as an incarnation of
the machine's one node with its domain id as the node's creation, so its
pids are unique on the machine by construction and it allocates them from
its own process table with no call to anyone: the proposal's "PID ranges
... delegated" become one range per domain, the domain id, delegated once
at creation. A domain may signal another domain's process only through an
import, so a pid names and never authorises, as the proposal asks; the
import table lives in the router, a native service, not in the kernel. A
domain speaks only for its own processes, because every frame names its
sending process and the router checks that the pid carries the sender's
domain id. The proposal's batched "lifecycle events" become one death
notice per domain, ordered after the dead domain's frames; the guardian
learns of every end through the fault endpoint and tells the router first.
Stopping a domain never needs its runtime, while killing a process goes to
its runtime under a deadline, after which policy may stop the domain. The
resource manager is Erlang in the system domain, and the guardian keeps the
authority to restart the router and the system domain (design-system.md).

**What the sources contribute.** Psyche shows that the kernel need know a
process only when it crosses a domain, which erXos takes further: the
router, not the kernel, sees crossings. Resource Containers separate the
principal that pays from the domain that protects, which is erXos's split
between groups and spaces. Singularity and Mach show death without the dying
party's cooperation, each peer learning of it when it next uses the broken
channel or call; E-D3 measures how fast erXos's notices reach every linked
process. JX's never-reused ids correspond to erXos's
domain ids, and its finding that reference counts across domains miss
cycles is a reason to keep imports as records in the router rather than as
counted references (inferred; the design gives facets, not this, as its
reason for irrevocable imports). Hand's revocation by deadline, then
kill, has the shape of erXos's kill deadline.

## Kernel execution models

**Fluke** (B. Ford, M. Hibler, J. Lepreau, R. McGrath and P. Tullmann,
"Interface and Execution Models in the Fluke Kernel", OSDI 1999, 16 pages,
`b/fluke-osdi99/`, `21d22d163ce8cdec`, read in full) offers both models in
one kernel. Its API is atomic: "no thread is ever in the middle of any
system call"; a long-blocking state is itself an entry point, and the kernel
updates a thread's parameter registers in place. It names two
requirements: promptness, so that another thread can always get or set a
thread's complete state, and correctness, so that extracting, destroying,
recreating and restoring a thread is indistinguishable from leaving it
alone. Numbers (cited; 200 MHz Pentium Pro):

* of 107 calls, 8 are trivial, 68 short, 8 long and 23 multi-stage; a
  restart costs 2 to 8% of the operation;
* Table 6, latency of a 1 ms periodic high-priority kernel thread, average
  and maximum µs (the text layer drops the µ sign): process model without
  preemption 28.9 and 7,430; with one preemption point on the IPC copy path
  18.0 and 1,200; fully preemptible 5.14 and 19.6; interrupt model without
  preemption 30.4 and 7,356; with the preemption point 18.7 and 1,272
  (`lepreau.layout.txt:730-734`) *(checked)*;
* Table 5: full preemptibility costs 20% on the kernel-intensive flukeperf
  and 5% on gcc; the interrupt model runs flukeperf 6% faster than the
  process model, because a thread that restarts saves no kernel register
  state;
* Table 7, thread memory: FreeBSD 8,832 bytes and Linux 6,491 in the process
  model; Mach 4,474 in the process model and 690 in the interrupt model;
  Fluke's interrupt model 300. The paper adds that much of the reduction
  "can also be achieved in process-model kernels simply by structuring" them
  with small stacks *(checked)*.

**Mach migrating threads** (B. Ford and J. Lepreau, "Evolving Mach 3.0 to a
Migrating Thread Model", USENIX Winter 1994, pp. 97-114, `b/ford-usenix94/`,
`c5a26bb71e3264a5`, read in full) splits Mach's thread into a schedulable
thread and per-task activations; a migrating RPC takes an activation from
the server's pool and "never involves the scheduler". Terminating a middle
activation splits the thread. What broke was user-level threading inside
servers: incoming threads "are not interchangeable" and must return on the
kernel thread they came in on. Null-RPC kernel instructions fell from 1,128
to 213 and cycles from 2,318 to 648 on a 67 MHz PA-RISC (cited). erXos takes
split-on-terminate and accounting that follows the caller, and rejects
migrating foreign threads into runtime domains, whose executors cannot host
them.

**seL4**, as read for this record in the MCS paper, "is non-preemptible
(save for explicit preemption points in a few long-running operations)"
(`scheduling-context-capabilities.txt:432-433`, citing Klein et al. 2009)
and checks on entry, except on the IPC fast path, that a thread has enough
budget to complete its operation, so every queued thread can leave the
kernel (476-486) *(checked)*. That seL4 runs on one kernel stack per CPU
and restarts an operation preempted at one of those points is the design
documents' characterisation, citing Klein et al. and the seL4 manual,
neither of which was read for this record (**unverified** here).

**Fiasco** uses the process model: its thread descriptors contain "a kernel
stack, areas for saving CPU registers" (`hohmuth.txt:380-385`) *(checked)*;
the kernel is preemptible and its critical sections never sleep
(`hohmuth.txt:255-262`); a thread that wants a busy lock lends its CPU to the
holder (helping locks, `switch_exec_helping` and `Switch_lock` at `50bbe8a9`);
and `Pi_mutex` adds priority inheritance. In the measured build, the locking
group is 3,922 lines, of which `pi_mutex.cpp` is 1,336, `rcupdate.cpp` 518,
`switch_lock.cpp` 466, `cpu_call.cpp` 341 and `helping_lock.cpp` 118 ([Fiasco
sizes](#fiasco-sizes)). NOVA's authors warn that helping and donation chains
are themselves an attack surface ("a long donation or helping chain").

**Why erXos's own kernel uses one kernel stack per CPU.** The design gives
four reasons (design-kernel.md, Execution model and locking, and
Alternatives considered, The process model), each with support in the
sources:

1. a stopped thread's whole state is its record, so it can be read, copied
   or destroyed at any time, which is Fluke's promptness and correctness;
2. a kernel that is never preempted needs no helping locks and no priority
   inheritance inside itself, which Fiasco needs because it is preemptible;
3. a thread costs a record, not a stack (Fluke's Table 7), although Fluke
   notes that small stacks recover much of the difference;
4. the stack proof covers one stack per CPU instead of one per thread.

The cost is latency bounded by the longest non-preemptible stretch. The
design states that restartable calls "give the same latency with less
mechanism". Fluke measured 7.4 ms worst cases in both models without
preemption points, 1.2 to 1.3 ms with one point on the IPC copy path, and
19.6 µs only in the fully preemptible process model, which cost 5 to 20%
of throughput. erXos bounds every part of a call at 50 µs under HVF by
restarting long calls, which is the interrupt model with many preemption
points. Its latency matches a preemptible kernel's only where every part
is as short as that kernel's non-preemptible sections, and the 50 µs
budget is unmeasured; Fluke's 2 to 8% restart cost suggests what
restarting costs (inferred).

## Fiasco under HVF

A hands-on check run on 2026-10-29 from 22:05 to 23:00 PDT, recorded in
full in `~/erxos-scratch/draft/research-results/fiasco-hvf-check.md`.

* **Host.** The primary host above; Xcode 27.1 (27A9275). The host was
  shared: one-minute load averages were 12 to 65 during the measurements.
* **Tools.** QEMU 11.1.2 (Homebrew, `virt-11.1`); `aarch64-elf-gcc` 16.2.0;
  `aarch64-elf-binutils` 2.47; GNU make 4.4.1, gawk 5.4.1, bash 5.3.20,
  findutils 4.11.0, gnu-sed 4.9, coreutils 9.12, dtc 1.8.1, u-boot-tools
  2026.10; Apple clang 21.0.0 as host compiler; Ruby 4.0.7 for the harness.
* **Sources.** The L4Re snapshot 26.09.0 (published 2026-09-27; SHA-256
  `6c24687b22e1fca1`, matching the published `SHA256SUM`); Fiasco
  `50bbe8a9`; `l4re-core` `e2e2d5af`; `mk` `22cc26e5`, `bootstrap`
  `a4f4ad18`, `hello` `0513c99b`, `drivers-frst` `6459d709` and `libfdt`
  `5756062b` as GitHub archives whose hashes were recorded.
* **Method.** Every guest ran under a Ruby harness: QEMU with standard input
  closed, `-no-reboot`, no display or monitor, the serial port on a UNIX
  socket, each serial line timestamped with the host's monotonic clock,
  scripted keystrokes, a hard deadline, and the guest killed with `SIGTERM`
  then `SIGKILL` on every exit path. The main HVF configuration was
  `-accel hvf -cpu host -M virt,gic-version=3 -smp 4 -m 1024`.

**Boot results.**

| Kernel | Accelerator and interrupt controller | CPUs | Result |
| --- | --- | --- | --- |
| snapshot, EL1 (`CONFIG_CPU_VIRT` off), generic device-tree platform | TCG `cortex-a57`, QEMU's GICv3 | 4 | boots to `hello`; ITS found |
| the same | HVF `-cpu host`, Apple's vGIC | 4 and 8 | boots to `hello`; no LPIs; kernel debugger on all CPUs; threads migrate across all 8 CPUs; `ex_vcpu` runs |
| the same | HVF with QEMU's GICv3 (`kernel-irqchip=off`) | 4 | boots; LPIs and ITS found |
| snapshot, EL1, Fiasco's QEMU `virt` platform | TCG and HVF | 4 | boots; under HVF its fixed ITS address is never touched because `GICD_TYPER.LPIS` is 0 |
| snapshot, EL2 (the guide's default) | TCG with `virtualization=on` | 4 | boots |
| snapshot, EL2 | HVF with nested virtualisation | 1 and 4 | the kernel initialises and the first user thread never runs |
| `50bbe8a9`, EL1, with the snapshot's user land | TCG and HVF | 4 | `bootstrap` assertion: the kernel info page layouts differ (`arch_cpuinfo[67]` in the snapshot, `[23]` on GitHub) |
| `50bbe8a9`, EL1, with a user land from GitHub heads | TCG, and HVF with Apple's vGIC | 4 | boots to `hello` |

**Findings.**

* **Timer.** Fiasco reads `CNTFRQ_EL0` as 24 MHz under HVF and 62.5 MHz under
  TCG with `cortex-a57`, and runs a 1 kHz periodic tick. Under HVF, 59
  intervals of `hello`'s one-second sleep averaged 1.000797 s by the host's
  clock.
* **Interrupts.** The timer PPI, a device SPI (PL011 receive, INTID 33) and
  SGIs all arrive through Apple's vGIC, which reports 1,024 interrupt IDs
  and no LPIs. Fiasco has no GICv2m code, so it has no MSIs under Apple's
  vGIC (inferred: PCI devices would need INTx or a GICv2m driver); no MSI
  was delivered in any configuration (**unverified**).
* **EL2 under HVF.** The only page fault is at instruction address `0x400`,
  the lower-EL synchronous vector offset with `VBAR_EL1` at 0, although
  Fiasco runs user threads with `HCR_EL2.TGE` set. The record infers that
  Hypervisor.framework's nested EL2, which is nVHE only, does not honour
  `TGE=1` with `E2H=0`; `ESR_EL1` and `ELR_EL1` were not read
  (**unverified**).
* **Snapshot and GitHub differ.** `diff -rq` lists 58 entries between the
  snapshot's Fiasco and `50bbe8a9` and 143 between the user lands; a kernel
  and its user land must come from one tree.
* **Build.** Fiasco needed no change. L4Re's user land needed one line in
  `l4/tool/Makefile` to skip `elf-patcher`, which includes `<elf.h>` and
  `<endian.h>` that macOS lacks and which nothing invokes. The kernel built
  in 23 s and the whole user land in 7 min 44 s, with no compiler warnings in
  the kernel.
* **QEMU.** QEMU 11.1.2 kept running after `SIGALRM` and stopped on
  `SIGTERM`, so `perl -e 'alarm shift; exec @ARGV'` is no deadline for a
  guest. Under HVF, `-cpu cortex-a57` aborts QEMU before the guest starts;
  HVF guests use `-cpu host`.

**The vCPU round trip.** A benchmark (`vcpu_rt`, C on L4Re's C API) resumes
a vCPU into a user task whose only code is `svc #0; b 1b`, takes the
exception upcall, steps the PC and resumes again: two kernel entries, two
exits and two address-space switches per round. The counter is
`CNTVCT_EL0` read at EL0 after an `isb` (41.67 ns per tick); each run is
10,000 warm-up rounds and 1,000,000 timed rounds, also split into 1,000
batches whose means give the percentiles; the vCPU thread was pinned to
CPU 1 of 4. The erXos probe of [research-baselines.md](research-baselines.md)
ran interleaved on the same host (`-smp 1`, interrupts off). Values in ns
per round, four runs at a one-minute load average of 12 to 13:

| Path on the M4 under HVF | Crossings | Address-space switches | Measured |
| --- | --- | --- | --- |
| erXos probe: EL0 `svc` to an EL1 handler and back (`svc_min`) | 1 | 0 | 22.0 to 22.9 |
| erXos probe: the same with a `TTBR0` switch (`svc_asid`) | 1 | 1 | 30.6 to 32.1 |
| Fiasco null system call (a thread-control IPC the kernel rejects early) | 1 | 0 | 29.3 median; 29.4 to 30.0 mean |
| vCPU round trip, user task's FPU enabled | 2 | 2 | 140.4 to 141.2 median; 142.5 to 143.7 mean; p99 161.9 to 201.4 |
| vCPU round trip, user task's FPU disabled (Fiasco's default) | 2 | 2 | 180.5 to 183.7 median |

* The round trip costs about 4.5 times the probe's crossing with an
  address-space switch, and about 79 ns more than two such crossings
  (inferred by subtraction; the probe's handler does no kernel work).
* Disabling the user task's FPU adds about 40 ns per round; the record
  guesses that writes to `CPACR_EL1` trap to the host under HVF
  (**unverified**).
* At one-minute load averages of 40 to 54, the snapshot kernel and
  `50bbe8a9` were indistinguishable (FPU enabled: run medians 139.9 to 159.0
  and 137.0 to 159.5 ns); absolute numbers rose 5 to 10% with load, as did
  the probe's.
* Under TCG the null system call took 846 ns and the round trip 11.7 µs
  (FPU enabled); TCG is not a performance reference.

L4Re's `ipcbench` and `syscallbench` (load 44) count in Hypervisor.framework's
emulated cycle counter. Every total was a multiple of 128, so the record
reads the counter as advancing 128 per 24 MHz tick, a nominal 3.072 GHz
(inferred). On that reading:

| Benchmark | Emulated cycles | ns at 3.072 GHz (inferred) |
| --- | --- | --- |
| IPC within one address space, one way | 158 | 51 |
| IPC between two address spaces, one way | 273 | 89 |
| system call, one core | 101 | 33 |
| system call, four cores in parallel | 90 to 95 | 29 to 31 |

The 33 ns system call agrees with the 29.4 to 30.0 ns measured directly for
the same operation, which supports the reading.

**Not verified by the check.** MSI delivery of any kind; interrupt latency
from a timer deadline to its handler; one-shot and tickless timers; runs
longer than 60 s; the cause of the EL2 hang and of the FPU premium; a page
fault answered by a flexpage on resume; ERTS as an L4Re program; behaviour
under `-icount`; whether a full `ham sync` builds on macOS.

**What it means for the design.** The stopgap is viable under HVF when built
for EL1, and the design builds it that way (design-kernel.md, The current
implementation). Devices under Apple's vGIC need ordinary interrupts
(virtio-mmio) until a GICv2m driver exists. Dispatch through a vCPU costs
4.5 times a crossing with an address-space switch, which supports keeping
executors as plain threads. Accounting on the stopgap runs at Fiasco's 1 ms
tick.

## Fiasco sizes

**Method.** Two Ruby scripts of the design agent,
`~/erxos-scratch/design-hier/tools/attrib.rb` and `categorize.rb`, read the
preprocessed sources of the EL1 build used above
(`~/erxos-scratch/fiasco-hvf/build/fiasco-snap-el1/auto/*.cc` and `*.h`,
snapshot 26.09.0). `attrib.rb` attributes each nonblank line to the
original source file named by the nearest preceding `#line` directive and
skips lines attributed to generated files; `categorize.rb` assigns each
original file to the first subsystem whose file-name pattern it matches.
The build's configuration: the generic device-tree platform,
`CONFIG_SCHED_FIXED_PRIO`, `CONFIG_SCHED_GRANULARITY=1000`,
`CONFIG_SCHED_DEF_TIME_SLICE=10`, `CONFIG_PRIO_INHERIT`,
`CONFIG_PERFORMANCE`, `CONFIG_NDEBUG`, `CONFIG_JDB` with logging and gzip,
`CONFIG_MP_MAX_CPUS=8`, without `CONFIG_CPU_VIRT` or the one-shot timer
*(checked)*. Measured by the design agent on 2026-10-29 and re-run for this
record on 2026-10-30 with Ruby 4.0.7, with identical results: 331 source
files, 66,837 lines.

| Subsystem | Lines | Share | Largest files |
| --- | --- | --- | --- |
| kernel debugger (JDB) and trace buffer | 18,749 | 28.1% | |
| memory: mapping database, map and unmap, spaces, page tables, kernel allocators | 11,666 | 17.5% | `mapdb.cpp` 1,378; `task.cpp` 1,193; `map_util.cpp` 872; `ptab_base.cpp` 710; `kmem_alloc.cpp` 669 |
| context switch and thread core (context, thread, FPU, vCPU) | 7,793 | 11.7% | |
| interrupts: IRQ objects, ICU, GICv2 and v3, ITS, MSI | 5,560 | 8.3% | |
| boot, CPU bring-up, platform, PSCI, device tree, ACPI, UART | 5,525 | 8.3% | |
| IPC: send, receive, gates, reply capabilities, buffers | 4,288 | 6.4% | |
| locking, cross-CPU calls, RCU, helping, priority-inheritance mutex | 3,922 | 5.9% | `pi_mutex.cpp` 1,336; `rcupdate.cpp` 518; `switch_lock.cpp` 466; `cpu_call.cpp` 341 |
| kernel objects, capabilities, factory, quotas | 3,280 | 4.9% | |
| scheduling: scheduling contexts, ready queues, timeouts, ticks | 2,575 | 3.9% | `timeout.cpp` 433; `sched_context-fixed_prio.cpp` 278; `scheduler.cpp` 181; `ready_queue_fp.cpp` 138 |
| support libraries (libk, minimal libc, libfdt) | 2,400 | 3.6% | |
| other | 1,079 | 1.6% | |
| total | 66,837 | | |

**Caveats.** The grouping is by file-name patterns, first match wins, so it
is approximate: the generic-timer driver counts as scheduling, and files no
pattern matches, such as `context-arm-64.cpp`, fall into "other". Inline
assembly counts with the C++; assembly files are not counted, and the arm64
ones whose objects the build contains hold about 780 nonblank lines (`ivt.S`
344, `tramp-mp.S` 284, `kip-time.S` 95, `crt0.S` 18, and `setjmp` and
`longjmp` 40; matched by object name, inferred). Whether Fiasco's
preprocessor emits any line twice was not checked. The figures describe one
configuration; the whole `src/kern` tree for every architecture holds about
134,000 lines (root-server evaluation).

**Against the design's estimate** (inferred). design-kernel.md estimates
erXos's kernel at about 25,000 lines of C17 "from the measured sizes of
Fiasco's corresponding subsystems less its kernel debugger, mapping
database and helping locks". Removing the debugger and trace buffer
(18,749 lines), the mapping-database family (`mapdb.cpp`,
`mapping_tree.cpp`, `kobject_mapdb.cpp`, `mapping.cpp` and the three
`map_util` files, 3,380) and the helping and priority-inheritance locks
(`switch_lock.cpp`, `helping_lock.cpp` and `pi_mutex.cpp`, 1,920) leaves
about 42,800 lines. Reaching 25,000 needs a further reduction of about 40%
that the design does not itemise.

## The three models compared

The user's other conversation proposed comparing three ways to run
lightweight processes on the same Fiasco base: **native-only**, in which
every executor is an ordinary thread scheduled one to one with no group
features (the design's configuration C0); **runtime grants**, the same
threads in groups with quotas, cooperation features and donation (C1 to
C3); and **per-process kernel dispatch**, a kernel thread per lightweight
process. The design measures the first two against each other as E-S1, the
ladder, and all three as E-S2, the dispatch models
(design-scheduler.md, Performance). This section states what the
literature predicts; every prediction is an inference from the cited
evidence, and the numbers come from other platforms unless marked M4.

| Question | Native-only (C0) | Runtime grants (C1 to C3) | Per-process kernel dispatch | Evidence |
| --- | --- | --- | --- | --- |
| a message between processes of one domain (W1) | inside ERTS; the kernel only for waking a parked executor | the same | a kernel IPC or notification per message and a kernel switch per process switch | user against kernel switch: 51 against 550 µs (Psyche, 1991), Signal-Wait 37 against 441 µs (scheduler activations), 51 against 335 cycles (vCPU paper, 2010), 172 to 221 against 465 to 812 ns (Akaros, 2014); Turner: a ring-0 round trip under 50 ns, with the cost in "the complexity of the scheduling decision", SwitchTo 179 against futex 2,905 ns; M4: a trap 22 to 31 ns, Fiasco IPC 51 and 89 ns one way (converted, inferred), an ERTS round trip 410 to 1,734 ns on the host (two runs, OTP 28.4.2) |
| spawn, exit, memory per process | ERTS's | ERTS's | a kernel object, a stack and a handle per process | Null Fork 34 against 948 µs (scheduler activations); an ERTS process is 327 words (`eff_guide_processes.md:29`, OTP 29.1.2); a kernel thread's kernel state 300 to 8,832 bytes (Fluke, Table 7); ERTS gives its scheduler threads stacks of 20 to 8,192 kilowords, 128 by default (`erl_cmd.md:1271-1273`) |
| isolation from a spinning domain (W5) | round robin within an urgency level, and cpusets | quotas cap the spinner per period | needs group caps as well, since a spinner can create threads | scheduling constraints and seL4 MCS isolate with kernel budgets; Stoess's Fig. 8 shows a kernel scheduler that ignores a guest's needs cutting throughput by 84% |
| oversubscription and lock holders (W4, W6) | stranding and lock-holder preemption | capacity advice, deferral and status words | no runtime run queues, but ETS and process locks remain user-level locks | MCS lock throughput fell to 0 and holder-aware locks kept 250 per ms (Akaros); Psyche's warning gave 2.5 times at multiprogramming level 2; activations doubled N-body speedup (1.29 to 2.45); 512 pthreads took 221 s on 32 Linux cores where 512 user threads took 72 s on 31 Akaros cores (Table 7.1) |
| priority across domains (W7) | none | donation, charge words, receive boost | the kernel sees every process's priority and can donate per call | seL4 and Credo donate per call; flattening enforces a few bands without an object per process |
| cost of the mechanism | none | +32 to 37 cycles per switch for one constraint and 0.004 to 5.3% run time (scheduling constraints, Cortex-A72); 1 to 1.5% for a polled word (Concord) | a kernel entry per block, wake and switch | as cited |

**Predictions** (inferred):

* **Per-process kernel dispatch loses on spawn and exit** by the one
  measured factor, 28 times (Null Fork, on the Firefly), and **on memory**
  by as much as the stack each thread needs exceeds an ERTS process's 327
  words (2,616 bytes on a 64-bit machine): a 16 KiB stack is about 6
  times, and ERTS's smallest scheduler stack, 20 kilowords, about 60 times;
  the kernel record adds 300 to 8,832 bytes (Fluke's range). On messaging
  and switching the sources measured kernel paths about 3 to 16 times
  slower than user-level ones. On the M4 a trap costs 22 to 31 ns and a
  Fiasco IPC 51 to 89 ns one way, small beside an ERTS round trip of 410 to
  1,734 ns on the host, so what decides is the cost Turner names, the
  scheduling decision and the wake, which no source measures on the M4;
  the record makes no numeric prediction for it. Per-process dispatch's
  one advantage, that the kernel sees every process's priority, is
  available at band granularity without it (flattening).
* **Native-only matches runtime grants** when domains do not share CPUs:
  Klues found user-level threading itself to be the dominant gain and
  composition worth only 2.3 to 10%, and the scheduling constraints cost
  under 6% in every workload measured. With the policy's capacity rule
  keeping each CPU's capacities within one CPU, the steady state is that
  case.
* **Runtime grants pay under oversubscription and contention**: up to about
  two times in the older measurements of parallel jobs sharing processors
  (scheduler activations, Psyche), and as isolation when a neighbour spins
  (quotas). Donation pays only in the cross-domain inversion of W7.
* **The decisive arms** are W4 to W7 under oversubscription; W1 to W3
  measure what the mechanism costs when it is not needed.

**Gaps in E-S2 as written.** Spawn and memory at 10^5 and 10^6 processes,
where kernel threads meet their budgets first; and an arm in which the
per-process kernel threads sit in a capped group, so that isolation is
compared like for like.

## Experiments: sources and predictions

The design's experiments, the sources that motivate each, the readers'
experiment identifiers it absorbs (from the extracts), and what the sources
predict. Predictions are inferences.

| Experiment | Motivating sources (extract ids) | What the sources predict |
| --- | --- | --- |
| **E-S1**, the ladder C0 to C3 | Stoess (A1-X1, A1-X2); scheduler activations Table V (SA2); Psyche's warning (P1); Arachne's stranding; Akaros's lock benchmark; the overheads of the scheduling constraints and seL4 MCS; Concord (C-E8); ghOSt's decision-latency ladder (C-E2); Klues on Lithe; helper B's E10 | C1 costs tens of cycles per switch; C2 pays only when groups share CPUs or a runtime oversubscribes; C3 pays for cross-domain inversion; with disjoint cpusets C0 and C3 differ by a few percent |
| **E-S2**, dispatch models | Psyche; scheduler activations Table IV; the vCPU paper; Akaros; Turner; Singularity; the Solaris white paper; Slite; Mach; Fluke Table 7 (E-SING-3) | per-process dispatch loses on spawn and exit (28 times in the one measurement) and on memory by a stack per process; on switches by about 3 to 16 times on older hardware, by an unknown factor on the M4 |
| **E-S3**, critical sections | Linux `rseq` (5 µs default, 50 µs maximum); Solaris; Psyche's 3 ms warning; Arachne's 10 ms; Caladan's few microseconds; Concord, whose preemptions miss a 5 µs quantum by a standard deviation of 0.29 µs on average and 1.8 µs at most (Table 1; C-E8); HSFQ's longest quantum (H2); Tessellation's bounded flag regions; JX's collector stalls (E-JX-3) | no source measures ERTS; Linux's default serves short sections |
| **E-S4**, wake latency | Barrelfish TN-009 (BF2); ghOSt's remote schedule (1,772 ns end to end); Shinjuku's interrupt costs (C-E10); NOVA's staggered wakeups; Syrup's late binding (C-E5); Nemesis' sends as hints (N3) | an interrupt-driven wake costs 1 to 2 µs on x86; the cost of an SGI under HVF is unknown, so the 2 to 20 µs estimate stands untested |
| **E-S5**, accounting | CPU inheritance (C1); Resource Containers (R1; a rebinding costs 1.04 µs); seL4 donation (A4-X1); Credo; Parmer (B-E8); Nemesis' crosstalk | the error is bounded by the accounting quantum: one 1 ms tick on the stopgap, the one-shot timer on erXos's kernel; a rebinding call costs a kernel entry where a charge word costs a store |
| **E-S6**, lock holders | Rhoden's lock benchmark (helper B's E5); Psyche; Williams; scheduler activations' recovery; Concord (C-E9); restartable sequences (B-E2, E-SPIN-3) | mitigation pays most under oversubscription |
| **E-S7**, quota accuracy | scheduling-constraint budgets (A3-X1); seL4's sporadic servers; Resource Containers, accurate only over tens of seconds (R2); Nemesis' jitter at 122 µs granularity | on the stopgap the error bound is one 1 ms tick per CPU per period, so the 1 ms period, or any quota near 1 ms per period, cannot be measured meaningfully there |
| **E-S8**, inversion | seL4's passive servers and ceiling protocol; CPU inheritance; Resource Containers; Nemesis' per-client bindings; temporal capabilities' cosDist (B-E3); HSFQ's unsolved inversion across classes; the user's critique, risk B | donation removes the inversion except the first period's delay; cosDist sustained about 70,000 messages per second at any Dom0 budget (reading), evidence that a request can carry its donor |
| **E-S9**, capacity | scheduler activations (SA2); OTP's warning on binding; ERTS's CPU-quota default; Solaris and Arachne on choosing the number of threads; Shenango's and Caladan's congestion signals (S1) | capacity advice recovers much of the oversubscription loss; ERTS already limits schedulers online under a detected CPU quota (`erl_cmd.md:903-905`) |
| **E-S10**, blocking refusal | scheduler activations' blocked activations; Williams' preallocated LWPs; Akaros's asynchronous system calls; Inferno's `release` and `acquire`; Singularity | no source counts blocking NIFs in OTP |
| **E-D1**, messaging cost | Barrelfish's LRPC (270 to 774 ns); Nemesis' null RPC (30 µs); Singularity's channels; JX's portal calls; Converse's queueing (9 to 15 µs); Fiasco's IPC on the M4 | four kernel calls of about 30 ns are a small part of the 3 µs budget; copies, the funnel and wakes dominate |
| **E-D2**, router scale | ghOSt's global agent (1.5 to 2.52 million decisions per second); Syrup's policy cost (under 2,000 cycles); Shenango's IOKernel | 2 million frames per second per executor leaves 500 ns per frame |
| **E-D3**, death and kill | Mach's split on terminate (E11); Fluke's promptness (E9, E10); Singularity's unwinding (E-SING-4); JX's abort flags; Hand's revocation deadline; Tessellation | death observed without the dying party's help: a broken call fails at its caller (Mach) and a peer sees the failure at its next receive (Singularity); seL4's kill timeout handler, a related action, takes 4.36 to 22.1 µs (cited) |
| **E-D4**, receivers that stop draining | none: no source read for this record studies a send pool shared by one sender's destinations | no prediction from the sources |

## Further experiments

Ideas the research suggests that the design does not list. Each runs under
HVF for numbers and under TCG for correctness only, never compared.

* **X1, pinned executors on shared CPUs.**
  * *Hypothesis.* Pinning every executor, the adapter's default, costs little
    while the policy keeps each CPU's capacities within one CPU, and much
    when cpusets overlap.
  * *Method.* E-S9's four ERTS domains on eight CPUs with overlapping
    cpusets, executors pinned and unpinned (placed only at wake), with and
    without capacity advice. The adapter pins dirty CPU schedulers by the
    same rule as normal ones, so dirty CPU scheduler `i` shares a CPU with
    normal scheduler `i` (inferred from design-runtime.md, Scheduling); one
    arm runs CPU-bound dirty NIFs.
  * *Measurement.* Throughput, p99 latency, run-queue lengths and executor
    ready time.
  * *Decision.* Whether the adapter pins by default, and whether the policy
    must keep the cpusets of pinned runtimes disjoint. OTP warns that
    binding when other processes also bind "can sometimes be severe"
    (`erl_cmd.md:1066-1073`).
* **X2, the payer fallback against a hostile client.**
  * *Hypothesis.* A client whose payer is exhausted makes a server spend,
    per period, at most the work of its outstanding calls (one per client
    thread), and at most the rest of the period on each server thread
    serving one.
  * *Method.* A native server under call donation; a client with many
    threads, a tiny quota and long requests; an honest second client; and
    an ERTS service behind a facet serving a client whose donated group is
    exhausted.
  * *Measurement.* Server time spent through fallback per period; the
    honest client's latency; fallback counts.
  * *Decision.* Keep the fallback, fail the call with a status, or send a
    timeout fault to a handler that may extend or abort, as seL4 does
    ([Hierarchy and flattening](#hierarchy-and-flattening)).
* **X3, bursts at period boundaries and stranded local quota.**
  * *Hypothesis.* A capped group can spend nearly twice its quota in one
    period's worth of time straddling a boundary; and quota drawn into the
    local slices of CPUs where the group no longer runs throttles its busy
    CPUs while the pool's quota sits elsewhere.
  * *Method.* A group capped at 30% with bursty threads on four CPUs, timed
    to period boundaries, beside a victim measuring latency; a variant whose
    threads move between CPUs.
  * *Measurement.* Usage in sliding windows of one period; the victim's
    p99; throttles while other CPUs hold unused local quota.
  * *Decision.* Periodic or sporadic replenishment; returning local quota
    when a CPU idles; the draw quantum.
* **X4, ready workers beside idle CPUs.**
  * *Hypothesis.* With no load balancer, a worker preempted on a busy CPU can
    stay ready while another CPU it may use is idle.
  * *Method.* Native programs with CPU-bound workers that urgent wakeups
    preempt.
  * *Measurement.* Time each worker spends ready while an allowed CPU idles;
    throughput against a variant in which an idle CPU pulls a ready worker.
  * *Decision.* Whether idle CPUs pull ready workers; executors keep relying
    on ERTS's own stealing. Turner's slides leave balancing "to the
    load-balancer" (`lpc2013-user-threading.txt:317`), and in `sched_ext` a
    CPU whose local queue is empty takes work from the global queue before
    it idles (`sched-ext.txt:226-233`).
* **X5, notice latency for a busy domain.**
  * *Hypothesis.* An inbox bit set for a domain whose executors are all
    running is taken within one reduction slice in the common case, with a
    tail set by long BIFs, NIFs and collections.
  * *Method.* A domain with every executor busy receives frames; the router
    timestamps each signal and the adapter each drain.
  * *Measurement.* The signal-to-drain distribution, by what the executor
    was running.
  * *Decision.* Whether an urgent frame needs a yield request posted to a
    running executor of the receiving group. Sources: Barrelfish TN-009,
    HSFQ's delay bound, Caladan's 2X rule.
* **X6, lock holders preempted by urgent wakeups.**
  * *Hypothesis.* Router and driver wakeups preempt executors that hold ERTS
    locks often enough to matter under message load, because deferral does
    not apply to urgency preemption.
  * *Method.* W2 and W4 with the router sharing CPUs with executors.
  * *Measurement.* Urgency preemptions per second that hit an executor with
    `defer` raised; the other executors' spin and futex time.
  * *Decision.* Whether a short grace (Linux's 5 µs, for example) also covers
    urgency preemption below some level, or the router gets CPUs of its own.
* **X7, thread progress under oversubscription.**
  * *Hypothesis.* A preempted executor delays ERTS's thread progress, and
    with it deferred deallocation and code loading, for its whole runtime,
    because a running but preempted managed thread has not confirmed.
  * *Method.* W4 with code loading and allocation-heavy work.
  * *Measurement.* Intervals between thread-progress values; memory held
    for deferred deallocation; code-loading latency; with and without
    capacity advice and status words.
  * *Decision.* Whether capacity advice suffices or a group needs
    co-scheduling for runtime-wide barriers, which the design excludes on
    SMT grounds only. Sources: Barrelfish's dispatcher groups for
    stop-the-world collection (HotPar 2010) and phase-locked gang scheduling
    (Peter's thesis).
* **X8, timer reprogramming under HVF.**
  * *Hypothesis.* Writing `CNTV_CVAL_EL0` and `CNTV_CTL_EL0` is cheap under
    HVF, so a one-shot timer reprogrammed at most decisions is affordable.
  * *Method.* The erXos probe with a loop of compare-register writes.
  * *Measurement.* Nanoseconds per write and per write-and-read pair.
  * *Decision.* Whether erXos's kernel skips reprogramming when the earliest
    deadline is unchanged. seL4's schedule path costs 38 to 45% more with
    MCS, which its authors attribute to reading and reprogramming the timer
    and to sporadic replenishment, and a switch without reprogramming was
    "almost 70% faster" with temporal capabilities.
* **X9, cancelling nested calls.**
  * *Hypothesis.* When a caller's deadline passes while its server is itself
    in a call, the inner server keeps charging the abandoned caller's payer
    until it replies.
  * *Method.* A chain of three native servers; expire the outer deadline;
    kill each party in turn.
  * *Measurement.* Time charged to the original payer after its deadline;
    leaked references; replies failing with `ERX_ENOCALLER`.
  * *Decision.* Whether a cancellation propagates down the chain, as Mach's
    alerts do, or inner calls keep the payer until they return.

## Points where the sources bear on the design

Points of tension between the sources and the design documents as they
stood when this record was compiled; each names the passage concerned.

* **The payer fallback** (design-scheduler.md, Call donation, and Payer and
  urgency resolution). A server whose caller's payer runs out continues on
  its own grant, and so does an executor whose charge word names an
  exhausted group. Lyons et al. criticise exactly this behaviour of L4
  timeslice donation, and offer a timeout fault to a handler instead;
  temporal capabilities carry finite slices with each request. The
  fallback keeps servers from stalling, at the cost of letting a client
  consume the server's grant within a bound (X2).
* **The 50 µs grace** (design-scheduler.md, Deferred preemption). It is Linux's
  maximum; Linux's default and minimum is 5 µs, and its documentation
  requires evidence to raise the default. No source measures ERTS's lock
  hold times (E-S3), and urgency preemption is never deferred (X6).
* **No load balancer** (design-scheduler.md, Requirements, and Placement and
  affinity). Executors are balanced by ERTS's stealing, but native workers
  are placed only at wake; Turner left balancing to the kernel's balancer,
  and in `sched_ext` an idle CPU pulls from a global queue (X4).
* **Gang scheduling excluded on SMT grounds alone** (design-scheduler.md,
  Requirements). Barrelfish co-schedules a runtime's dispatchers for
  stop-the-world collection, and ERTS's thread progress waits for every
  running managed thread (X7).
* **Pinning by default** (design-runtime.md, Scheduling). OTP warns that
  binding when other processes bind can carry a "sometimes severe" penalty;
  the design relies on the capacity rule to keep pinned executors apart
  (X1).
* **Replenishment at period boundaries** (design-scheduler.md, Charging and
  quota). seL4 uses sporadic servers; a budget refilled per period allows up
  to twice the quota in a window that straddles a boundary (inferred, X3).
* **E-S7's 1 ms arms on the stopgap** (design-scheduler.md, Performance). With
  accounting at a 1 ms tick, a 1 ms period or a quota near 1 ms per period
  is below the stopgap's resolution (inferred).
* **The kernel's size estimate** (design-kernel.md, Requirements). The
  measured sizes less the debugger, the mapping database and the helping
  locks leave about 42,800 lines, not about 25,000
  ([Fiasco sizes](#fiasco-sizes)).
* **seL4 as precedent for the event model** (design-kernel.md, Context, and
  Execution model and locking). The MCS paper confirms that seL4's kernel
  is non-preemptible with preemption points in a few long operations; no
  source read for this record establishes its single kernel stack or that
  its preempted operations restart.
* **Equal latency from restartable calls** (design-kernel.md, Alternatives
  considered, The process model). The design says restartable calls "give
  the same latency with less mechanism". In Fluke only the fully
  preemptible process model reached a 19.6 µs worst case, against 1.2 ms
  or more with a preemption point on one path, so the claim holds only as
  far as every part of every call is as short as a preemptible kernel's
  non-preemptible sections; the 50 µs part bound is a budget, not a
  measurement ([Kernel execution models](#kernel-execution-models)).
* **History in the scheduler's Context section** (design-scheduler.md).
  "NetBSD shipped them in 2.0" is unverified and "KSE was removed in 8.0" is
  inferred (U4, U10).
* **Fiasco's IPC in nanoseconds** (design-kernel.md, Performance;
  design-scheduler.md, Alternatives considered). The 51 and 89 ns figures
  rest on an inferred conversion of an emulated cycle counter. The cost
  model of design-scheduler.md says so; design-kernel.md's Performance
  table and the "measured cost" of design-scheduler.md's case against a
  kernel thread per lightweight process do not.
* **The vCPU among upcall interfaces** (design-scheduler.md, Alternatives
  considered). In Fiasco `50bbe8a9` a vCPU's preemption is transparent and
  only enabled events are upcalled; the rejection rests on cost and on
  needing no event upcalls, which the measurements support.
* **Akaros's preemption notices** (design-scheduler.md, Alternatives
  considered, Core allocation). Klues and Rhoden disagree on whether Akaros
  notifies before it preempts.

## Unverified items

* The venue and usual title of the vCPU paper; Syrup's page range; the
  default of ghOSt's `runnable_timeout`; the proceedings pages of CPU
  inheritance scheduling; whether the Converse PDF differs from the IPPS
  version; whether the Inferno reprint differs from the original.
* The release year of NetBSD 2.0 and its shipping of scheduler activations;
  the month of NetBSD 5.0; the release year of FreeBSD 8.0; the content of
  `libthr(3)`; a primary statement of why Windows UMS was removed.
* Helper A's readings of the scheduling-constraints code (untested), in
  particular the inverted bandwidth timeout.
* Helper B's readings of Barrelfish's kernel (untested).
* Every value marked *(reading)*.
* In the Fiasco check: MSI delivery, interrupt latency, the cause of the EL2
  hang and of the FPU premium, and the unit of the emulated cycle counter.
* Whether `github.com/L4Re/fiasco` and `github.com/kernkonzept/fiasco` share
  history; Linux's CFS bandwidth control as a precedent for erXos's pool and
  local slices (not read).
* seL4's single kernel stack, and that its preempted operations restart
  (the MCS paper states only that the kernel is non-preemptible with
  preemption points).
* Whether another thread can shorten a running ERTS process's reduction
  budget, which a polled yield request would need (helper A).

## Local copies

| Group | Directory | Contents |
| --- | --- | --- |
| helper B and the third reader | `~/erxos-scratch/papers/a/` | Psyche, scheduler activations, Barrelfish (with the library source at `06a9f547`), Lithe, Converse, CPU inheritance, Nemesis, Akaros, Tessellation, HSFQ, Resource Containers, Arachne, Shenango, Caladan, and the negative evidence; SHA-256 in `papers/a-manifest.sha256` |
| helper A and its forks | `~/erxos-scratch/papers/b/` | the L4, Fiasco and seL4 papers, the scheduling-constraints repository, Composite (with source at `d3b9d9f2`), Fluke, Mach, ghOSt (with `ghost-userspace` at `9ca0a1fb`), Syrup, `sched_ext` (with Linux v7.3 source), Concord, Shinjuku, JX, SPIN, Singularity, Inferno (with source at `36616fe5`); SHA-256 in `report-helperA.txt`, section 6 |
| figure renders | `~/erxos-scratch/papers/b-render/`, `papers/b/_render/` | page images of graphs and tables |
| L4Re | `~/erxos-scratch/borrow/rootserver/l4/` | the Fiasco and `l4re-core` clones and the saved L4Re pages |
| the Fiasco check | `~/erxos-scratch/fiasco-hvf/` | sources, builds, harness, logs and every guest's serial log |
| extracts and notes | `~/erxos-scratch/design-hier/` | the three extracts, the design agent's notes and the size tools |
