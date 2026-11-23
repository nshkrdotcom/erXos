# Benchmarks: where erXos stands and when it slips

erXos has measured its runtime against stock OTP since gate G3, and nothing
below it: no number says how long a request to the root service takes, how
late a timed park returns, how a CPU is shared among spinning threads, or
what a page commit costs. The late interrupt of the Raspberry Pi 4's console
was found by chance, by a diagnostic probe written after bytes were lost
([design-fiasco.md, Urgency](design-fiasco.md#urgency), "The evidence").
This document designs the benchmark system: what a benchmark is, the one
clock every interval is read from, the record every run leaves in the
history repository, the rule that compares two records, the three limits
that fail a gate, the other systems erXos is measured against on the same
board, and the first five benchmarks.

Decisions every reader needs:

* **A result is a record, and the record says what it can be compared
  with.** Every run of `tools/erx bench` writes one record: a JSON manifest
  with each operation's status and summary, bounded histograms beside it,
  and the logs of its boots. The record separates where the run happened
  (the *environment*: machine, accelerator, CPU count, operating system)
  from what ran (the *subject*: source revision, image, compiler, flags,
  manifest). Two records are compared only when their environments are
  equal, so a TCG number is never set against a native one and no tool has
  to remember not to.
* **Every interval is two reads of one clock.** In a guest that clock is
  the architecture's system counter, which `erx_clock_ns`, ERTS's monotonic
  time and the trace ring's stamps all read; on the host it is the host's
  monotonic clock; at the Raspberry Pi 4's pins it is the logic analyser's
  sample clock. No interval is computed from two clocks.
* **Thresholds are advisory, three excepted.** A comparison says `same`,
  `slower`, `faster` or `inconclusive`; inconclusive is never a pass. Once
  calibrated by three recorded runs, exactly three limits fail a gate: on
  the Raspberry Pi 4, every receipt of the console's line within 0.7 ms
  with no receive overrun, and every receipt of the SD controller's line
  within 1 ms; everywhere, no lost wake. A benchmark that sees its operation
  return a wrong answer fails as any test does; that is not a threshold.
* **Results live in the history repository, never in the tree.** The one
  record writer puts a run under
  `~/erxos-history/bench/<environment>/<run>/` and refuses a destination
  inside the erXos tree.
* **The landing gate measures; it does not judge speed.** A `bench` QEMU
  suite runs the five benchmarks' short forms in about a minute, in boots
  the gate can reuse, and reports each against the newest recorded
  baseline. Only the three limits, wrong answers and a benchmark that did
  not run fail it.
* **Other systems run on the same board.** Stock L4Re, FreeBSD and Linux
  boot on the same Raspberry Pi 4, with the same firmware settings, and run
  the counterpart of each operation: L4Re's own IPC benchmark, and for
  FreeBSD and Linux one portable C program, `bench/peer/erx_peer_bench.c`,
  compiled on the board by the system's own compiler. Linux is the best
  case on the board; FreeBSD is the behaviour erXos matches.

## Context

### The problem

Three facts from the tree set the scope.

* **The costs that hurt are below the runtime.** On the Raspberry Pi 4 the
  probe found Fiasco's own path under 10 us and the rest of a 0.6 to 6 ms
  delay with the console driver's ERTS scheduler awake but not running,
  behind other threads of its priority on its CPU; the mini UART's FIFO
  holds 0.7 ms of input, so pasted bytes were lost
  ([design-fiasco.md, Urgency](design-fiasco.md#urgency), "The evidence";
  history repository `pi4/2026-11-22-irq-probe/`). None of the existing
  benchmarks would have shown it: they time Erlang workloads in batches
  ([What the existing tools do](#what-the-existing-tools-do)).
* **Designs already promise numbers nobody can produce.** The Fiasco
  design decides whether to carry its branch-predictor patch by timing the
  null request on the board, ten runs a build
  ([design-fiasco.md, The release's Fiasco build](design-fiasco.md#the-releases-fiasco-build),
  FD32); gate G5 needs `xdomain-pingpong` and `xdomain-throughput`
  ([design-domains.md, Performance](design-domains.md#performance)); the
  watch list names about twenty-five workloads that `tools/erx bench` refuses as
  unknown ([todo-performance.md](todo-performance.md)); and CLAUDE.md asks
  every change to the boot path, kernel entry, scheduler, IPC, domain
  creation or cross-domain messaging for before and after numbers.
* **There is no history.** The records that exist were written by hand
  into the history repository (`bench/g3/2026-11-06/`, `bench/g5/2026-11-09/`,
  `pi4/2026-11-22-irq-probe/`), each in its own shape, so no tool can say
  whether a new number is worse than an old one.

### Consumers

| Consumer | What it needs from this design |
| --- | --- |
| FD32, the branch-predictor patch ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)) | `nullcall`'s root round trip on the Raspberry Pi 4, two release builds, ten runs each, judged by the spread of medians |
| The Raspberry Pi 4's interrupt measurement ([design-fiasco.md, Verification](design-fiasco.md#verification)) | the console and SD receipts per load cell, recorded and judged against 0.7 ms and 1 ms |
| Gates G3, G5, G8, G9, GK3, GP and G6 ([plan.md](plan.md#decision-gates)) | the same benchmarks on QEMU under HVF, Fiasco's numbers as the baseline erXos's kernel is later held to |
| The scheduler's E-S1 to E-S10 and the domains' E-D1 to E-D4 ([design-scheduler.md](design-scheduler.md#performance), [design-domains.md](design-domains.md#performance)) | named workloads with distributions, not batch means |
| The watch list ([todo-performance.md](todo-performance.md)) | a recorded number to settle each item |
| CLAUDE.md, "Latency is UX" | the before and after of a change, with host, accelerator, QEMU version, compiler, flags, workload and baseline |

### The published numbers erXos is set against

These are the numbers a fair comparison can use, read on 2026-11-23 from
the sources in [References](#references). Each is a check on our own setup
before it is a target: erXos runs the same benchmark on its own board
(L4Re's), or the row stays context.

| System | Hardware | Operation | Number | Fair against erXos because |
| --- | --- | --- | --- | --- |
| L4Re, Fiasco without virtualization support | Raspberry Pi 4, Cortex-A72 | IPC between two tasks, same core | 702 cycles | same board, same kernel family and privilege level: erXos's Fiasco is also built without virtualization support (`CONFIG_CPU_VIRT` off, `config/fiasco/kernel.defconfig`); L4Re's rows also used its benchmarking build, which erXos's is not |
| the same | the same | IPC between two threads of one task | 505 cycles | the same |
| the same | the same | null system call | 305 cycles | the same |
| L4Re, Fiasco with virtualization support | the same | IPC between tasks; null call | 1,600; 567 cycles | context only: the build erXos does not use, which the page says the A72 makes much slower |
| seL4, default configuration | Jetson TX1, Cortex-A57, 1.9 GHz | call; reply (each one way) | 419; 431 cycles | context only: a similar core, another board, and means with deviations |
| seL4 | the same | notification; interrupt to a user handler | 1,083; 882 cycles | context only |
| Linux with PREEMPT_RT, 64-bit | Raspberry Pi 4 | worst wake lateness under a kernel build | about 230 to 270 us | context only: single runs read by hand, maxima only, a load erXos would have to imitate |

L4Re's page does not say whether "a single IPC" is one way or a round
trip, or the clock it ran at; both are why erXos reproduces it on its own
board rather than divides by it. No published Arm number exists for
cross-core IPC, page faults, mapping, thread or process creation, pipes or
the 99th percentile of a Pi 4 wake; erXos measures those on FreeBSD and
Linux itself.

## What the existing tools do

`tools/erx bench NAME` dispatches by a chain of name tests in `tools/erx`
(`self.bench`) to one runner per benchmark:

| Name | Runner | What it times |
| --- | --- | --- |
| `otp-pingpong`, `otp-ring`, `otp-spawn`, `otp-switch` | `tools/lib/erx/bench.rb`, workload `bench/erx_otp_bench.erl` | stock OTP on the host, one scheduler; nanoseconds per operation as the mean of each of seven batches |
| `g3` | `bench_g3.rb`, `bench_guest.rb` | the same four inside an erXos guest, typed into its shell, against stock OTP; the footprint; boot to the shell |
| `boot` | `bench_boot.rb` | host-clock times from QEMU's start to four boot checkpoints |
| `g5` | `bench_g5.rb` | interpreter against BeamAsm domains on one workload |
| `bytes` | `bench_bytes.rb` | the network primitives of `erx_bytes` |
| `web` | `bench_web.rb` | a record view's round trip over the host tool's web front end |
| `net-freebsd` | `net_bench.rb`, `net_bench_freebsd.rb` | `erx_net` against lwIP on the FreeBSD x86-64 test host |

`BenchMeasurement` (`bench_measurement.rb`) checks that a measurement says
the workload, sizes and flavour asked for and holds one positive finite time
per sample, and never echoes a guest's text. The QEMU suites hold the
nearest thing to latency tests: `native_irq` rings a software IRQ object
when it sees an executor parked, across CPUs where there are several
(`test/guest/native_irq/guest.c`), and `native_task` holds the band case
and a quantum case whose median turn must lie within 250 to 4,000 us around
a 1 ms slice (`test/guest/native_task/guest.c`, `case_band`,
`case_quantum`). The root's trace ring stamps parks, wakes and IRQ
deliveries with `erx_clock_ns`
([design-fiasco.md, The trace ring](design-fiasco.md#the-trace-ring)). The
stamps the interrupt probe took at Fiasco's interrupt entry exist only on
the diagnostic branch `uart-irq-probe`, which is marked not to land.

Three defects follow from each runner owning its own output and its own
idea of a comparison:

* **`g3` sets TCG against native.** `BenchG3.report` computes the guest
  over stock ratio for whichever accelerator the plan names, `tcg`
  included, though the stock side runs natively and CLAUDE.md forbids the
  comparison; the class's own comment says only that TCG and HVF are never
  compared with each other.
* **`otp-switch` does not measure a switch.** Its two processes call
  `erlang:yield()` in loops, and the module counts two switches per yield
  (`operations(switch, Yields) -> 2 * Yields`) without observing that the
  other process ran in between.
* **Results are written into the tree.** Every runner writes its report
  under `build/bench` and its boots under `build/qemu`
  (`OutputDirectory.prepare` in `bench.rb`, `bench_g3.rb`, `bench_boot.rb`,
  `bench_bytes.rb`, `bench_g5.rb`, `bench_web.rb`; `net-freebsd` defaults
  to `build/bench/net-freebsd-STAMP`), where a clean build deletes them and
  no other worktree or host sees them, and `docs/design.md` lists `bench/`
  as holding "recorded results".

Below the tools, what erXos can be asked on Fiasco bounds what a benchmark
can time: `erx_ipc_call`, `erx_ipc_send`, `erx_ipc_reply`,
`erx_ipc_reply_wait` and `erx_thread_set_urgency` answer `ERX_ENOTSUP`
(`liberx/backend/core/refused.c`); `erx_mem_child` makes an eager copy
(`liberx/backend/fiasco/service_stubs.c`); a doorbell's trigger is the
holder's own `l4_irq_trigger` and makes no request (`erx_irq_trigger`, the
same file). Fiasco's timeouts and slices are driven by a periodic 1 ms tick
in erXos's configuration
([design-fiasco.md, Scheduling](design-fiasco.md#scheduling), "The
quantum"); whether a timed park can end only at a tick is unverified, and
the `wake` benchmark is what shows it.

## The construction

The design has one record type and pure functions over it. A benchmark
produces samples; everything after that (summaries, percentiles, statuses,
comparisons, gate verdicts, side-by-side tables) is computed from records
by one Ruby module, `Erx::BenchRecord`, and its comparison,
`Erx::BenchCompare`, so no runner decides for itself what a number means.

### A benchmark

A benchmark is a file, `tools/lib/erx/benches/NAME.rb`, as a QEMU suite is
([design-build.md, What the gates run](design-build.md#what-the-gates-run)).
It declares:

* its **operations**, each an exact act with a start and an end on one
  clock, and what a correct result of the act is (a status, a reply, a
  count);
* its **profile** per operation (below), with only the parameters that
  differ from the profile's defaults;
* the **environments** it runs in, and for each the image and the guest
  program that run it;
* the **load cells** it runs under, each a named background (idle, a
  spinner on the same CPU, a neighbour domain's loop);
* its **counterparts** on the other systems
  ([Other systems](#other-systems-on-the-same-raspberry-pi-4)), each with
  one line saying what differs.

`tools/erx bench NAME` finds the file by its name; the chain of name tests
in `tools/erx` goes, and the existing runners become the `run` of their
declarations. A name a design document gives and no file declares is
refused as unknown, as it is today.

A guest reports each operation as one line on its console, `BENCH`
followed by one JSON object of at most 64 KiB, in counter ticks: the
benchmark, the operation, the load cell, the CPU placement, the clock and
its frequency, the status, the sample count, the batch size, the
histogram, the exact maximum and minimum, the sixteen largest samples with
their sequence numbers, and the counts of lost, early and missed events.
`BenchMeasurement` grows into the one validator of these lines; it checks
every field's type and bound, refuses a line whole with a reason that
never quotes it, and is fuzzed
([Verification](#verification)).

### The histogram

A guest does not send raw samples: on the Raspberry Pi 4 its console runs
at 115,200 baud, about 11 KiB a second, so 100,000 samples of one
operation would take a minute to send. It sends a histogram whose buckets
are powers of two split into 64 equal parts, so a bucket is at most 1/64
(1.6%) of its lower bound wide, finer than any advisory threshold. Each
non-empty bucket is sent as its own bounds and count, so the reader
needs no formula: the C library of the guests (`test/guest/bench/`) and
the Erlang one (`bench/erx_bench_hist.erl`) each build their histogram,
and neither has to agree with the other bit for bit. A percentile is
reported as the upper bound of the bucket it falls in, so it never claims
an operation was faster than it was. An expensive operation with at most
1,000 samples also sends its raw samples.

### The one clock

Every interval a record holds is the difference of two reads of one clock,
and the record names the clock:

| Clock | Read by | Used for |
| --- | --- | --- |
| `counter` | `erx_fiasco_counter`, the one read of the architecture's system counter in an erXos program; `erx_clock_ns`, ERTS's monotonic time and the trace ring's stamps all derive from it | every interval inside a guest |
| `host` | the host's monotonic clock | what only the host sees: QEMU's start to a boot checkpoint, a web round trip |
| `analyser` | the logic analyser's sample clock | an edge on one pin of the Raspberry Pi 4 to an edge on another |
| `instructions` | `counter` in deterministic mode, where QEMU's clock counts executed instructions (`-icount shift=0`, `tools/lib/erx/qemu.rb`) | instruction work, with no noise |

A guest's samples are in ticks; nanoseconds are derived when the record is
read, from the frequency the run recorded. Cycles are a unit, not a clock:
a number in cycles is a counter interval times the CPU frequency that the
same run measured, and is `unknown` where the run could not measure it.

**Calibration.** Each run of a guest benchmark first measures its clock,
in under a second, and records:

* the counter's frequency, from its frequency register (24 MHz under HVF
  and 62.5 MHz under TCG on the primary host,
  [research-baselines.md](research-baselines.md#exception-and-address-space-switch-costs));
* the smallest increment two reads observe, and the median cost of a read,
  from 10,000 back-to-back pairs;
* for each pair of CPUs a cross-CPU operation uses, the bound on their
  counters' offset: two threads, one on each CPU, pass a token through
  shared memory 1,000 times with no kernel call, each stamping on receipt;
  with zero offset every stamp lies between the two around it, and the
  bound is the largest violation seen, or one tick if none;
* the rounding of a timed wait (`erx_fiasco_time_wait_us` rounds a
  deadline up to the microsecond, `liberx/backend/fiasco/time_table.c`),
  so lateness under a microsecond is recorded as unresolvable;
* on the Raspberry Pi 4, the CPU's cycles per counter tick over one second
  where its cycle counter is readable in user mode (`CONFIG_PERF_CNT_USER`
  is set; that the board allows the read is unverified), and otherwise
  `unknown`.

A one-way interval across CPUs is reported with its offset bound beside
it. An operation timed across CPUs whose bound exceeds a tenth of the
operation's median reports `unsupported: counters across CPUs not
consistent enough`, and the round trip, timed on one CPU, stays. A round
trip is never halved into a one-way number.

**Short operations.** An operation whose warm-up median is under 100
ticks is timed in batches: the smallest power of two of operations that
spans 100 ticks. The record states the batch size, and its percentiles
are of batch means; they are never called per-operation tails. A sample
is never corrected by subtracting the read cost; the cost is recorded
beside it.

### Profiles

A profile fixes how an operation is sampled and what its summary may
claim. Its two sizes are the landing form, run at the landing gate, and
the full form, run at the gates that name the benchmark and on demand.
The sizes are starting values, to be revised by the first calibration
runs.

| Profile | Sampling | Landing form | Full form | Summary |
| --- | --- | --- | --- | --- |
| **fast** | warm-up, then each operation timed alone | 1,000 warm-up, 10,000 samples, one run | 1,000 warm-up, 100,000 samples, five runs | histogram, percentiles the count allows, minimum, maximum |
| **expensive** | 10 warm-up operations, or none for a cold start, then each timed | 10 and 100, one run | 10 and 1,000, five runs | median and maximum, the raw samples, percentiles the count allows |
| **periodic** | absolute deadlines every period P; each period's lateness is its return less its deadline | P = 1 ms for 5 s | P = 1 ms for 300 s | the lateness histogram; early returns, missed periods and lost wakes counted |
| **sustained** | after a 2 s warm-up, windows of fixed length, each counting work done | three 1 s windows | five 10 s windows | each window's rate, and their minimum, median and maximum |

Two rules hold in every profile, so no benchmark declares them:

* **A percentile is reported only when at least ten samples lie above
  it**: the median needs 20 samples, the 99th percentile 1,000, the
  99.9th 10,000. Below that the record says `unsupported: too few
  samples` for it.
* **A periodic deadline never moves.** Deadline k is the first deadline
  plus k periods, whatever happened before it, so a stall shows as missed
  periods and lateness and is not absorbed into the schedule, as
  cyclictest's absolute mode does. A return before its deadline is
  counted as early, which is a wrong answer.

### Environments

An environment is where a run happened. Its name is derived, never
written by hand, and carries no host name:

| Kind | Name | Holds | Compared with |
| --- | --- | --- | --- |
| QEMU `virt` under HVF | `qemu-hvf-<model>-<n>cpu`, `<model>` the host's hardware model | the development numbers and the landing gate | itself; side by side with `host` |
| QEMU `virt` under TCG | `qemu-tcg-<model>-<n>cpu` | functional runs on hosts without HVF | itself only |
| deterministic mode | `qemu-det` | instruction work of one CPU, the same on every host | itself only |
| the Raspberry Pi 4 | `pi4-4gb-<system>`, `<system>` one of `erxos`, `l4re`, `freebsd`, `linux` | the native numbers and the three limits | itself; side by side with the other systems on the board |
| the host | `host-<model>` | stock OTP natively | side by side with `qemu-hvf` |

QEMU's `raspi4b` model is not an environment: it runs only under TCG, and
its numbers describe the model. Under HVF, a guest's CPU affinity does not
pin the host thread that runs it, and macOS has no way to; the record
keeps the host's load average before and after.

### The record

One run is one invocation of `tools/erx bench`: one or more boots of one
subject in one environment. Its directory is
`<history>/bench/<environment>/<run>/`, where `<history>` is
`ERX_BENCH_HISTORY` or `~/erxos-history`, and `<run>` is the UTC time,
the source revision's first twelve hex digits and `-dirty` when the tree
was:

```
run.json                     the manifest
<benchmark>/<operation>.json the histogram, largest samples, raw samples if few
boot-<n>.serial.log          each boot's console
boot-<n>.qemu.log            each boot's QEMU output
compare.json                 a comparison made against this run, if any
```

`run.json` holds, as CLAUDE.md requires and the comparison needs:

| Group | Fields |
| --- | --- |
| environment | kind, machine model, CPU count, memory, operating system and its version, accelerator, QEMU version and machine type, firmware files' SHA-256 on a board |
| subject | source revision and whether the tree was dirty, image SHA-256, every workload source's SHA-256, compiler version, the complete compile and link flags, the system manifest, runtime flavour and scheduler flags, the Fiasco configuration |
| run | date, the tool's revision, what started it (`landing`, `milestone`, `gate G5`, `manual`), the host's load before and after, a board's temperature and throttle state at the start and end where readable, `reused_from` for a reused boot |
| clock | the calibration above |
| operations | per operation: benchmark, operation, load cell, placement, profile and its sizes, status and reason, sample count, batch size, the summary the profile allows, lost, early and missed counts, and the path of its histogram file |
| baseline | for a run that was compared: the baseline run's path |

An operation's status is one of:

| Status | Meaning | Summary |
| --- | --- | --- |
| `measured` | every sample asked for was taken and every result was correct | in full |
| `partial` | fewer samples than asked, with the reason (a deadline, a load that ended) | from the samples taken, labelled partial |
| `timed_out` | the guest's deadline passed before the operation reported | none |
| `unsupported` | the call answered `ERX_ENOTSUP`, the environment lacks what the operation needs (a second CPU, a readable cycle counter), or calibration refused it; the reporter is named | none |
| `failed` | a result was wrong: a lost wake, an early return, a reply with the wrong status | the samples before the failure, and the failure |
| `rejected` | the guest's line failed validation | none, and the reason |
| `not_run` | expected and never reported | none |

A file is at most 1 MiB, a log at most 64 MiB, and a run directory is
created exclusively, never over another. Records are never edited; a
number changes by a new run. A record of an older format is refused with
a diagnostic, never read.

**Where records are written.** `Erx::BenchRecord.write` is the only
writer. It resolves the destination, refuses one inside the erXos tree it
runs from (by real path), and refuses to write when the history root does
not exist, rather than falling back anywhere. Scratch work (images being
built, the boot directories QEMU writes into) stays under `build/` and is
deleted; what is kept is copied into the record. The tool commits nothing
and deletes nothing in the history repository: a run is kept by
committing it there by hand, and an uncommitted run is scratch.

### Comparison

`BenchCompare` is a pure function of records. It compares one statistic
(the median, 99th and 99.9th percentiles, the maximum, or a sustained
rate) of one operation between a **baseline**, at least three runs, and a
**candidate**.

* **Comparable.** The two sides must have equal environments, operations,
  load cells, placements and profiles. Anything else is refused with what
  differs. The one exception is the side-by-side table, which sets
  `qemu-hvf` beside `host` for G3 and one board's systems beside each
  other, and gives no verdict.
* **The noise band.** The band of a statistic is the range of its values
  across the baseline's runs, widened by one histogram bucket. It is the
  rule FD32 already states for its decision, "within the spread of the
  unpatched build's medians across its runs", applied to every
  statistic, so FD32 is a use of this rule and not a second one.
* **The verdict.** `same` when every candidate run lies within the band;
  `slower` when at least two of three candidate runs lie above it and the
  candidates' median exceeds the baseline's by more than the advisory
  threshold; `faster` the mirror; `inconclusive` otherwise. A sustained
  rate's direction is reversed. Deterministic mode's band has no width,
  so any difference there is a real change of instruction work.
* **Inconclusive is not a pass.** A comparison is inconclusive when the
  baseline has fewer than three runs, when either side's operation is not
  `measured`, when either host's load average exceeded half its CPUs (a
  starting value, revised with the thresholds), or when the verdict above
  is mixed. A change that CLAUDE.md requires
  numbers for has not supplied them while its comparison is
  inconclusive.
* **Maxima and misses stand apart.** A maximum, a missed period or a lost
  wake is reported in every comparison even when every percentile is
  `same`.

**Paired runs.** On a shared host, a baseline recorded last week and a
candidate run today differ by everything else the host did. Only a paired
comparison can say `slower` or `faster`: `tools/erx bench NAME --paired
--image-a BASE --image-b CAND` boots the two images alternately, three
times each (A B A B A B), on one host in one session, and compares them by
the rule above. The developer builds the two images; the tool builds
nothing. A comparison with a recorded baseline and one candidate run, as
the landing gate makes, can say only `same` or `outside the band`, the
second meaning that a paired run is needed.

**Advisory thresholds.** The thresholds below are starting values. After
the first three runs of an unchanged subject in an environment, each
becomes the larger of its starting value and the spread those runs
showed, recorded with the runs. They never fail a gate.

| Environment | Median | 99th percentile | 99.9th percentile |
| --- | --- | --- | --- |
| the Raspberry Pi 4 | 5% | 10% | 20% |
| QEMU under HVF | 10% | 20% | 30% |
| deterministic mode | any change | not reported | not reported |

### The three limits

Exactly three limits fail a gate, each becoming hard once three runs of it
are recorded in its environment; until then each is reported as the
others are:

| Limit | Measured by | Where it fails |
| --- | --- | --- |
| **No lost wake.** A thread woken while parked returns `ERX_OK`; a wake whose park ends with `ERX_ETIMEDOUT` instead, or never ends, is lost | the `wake` benchmark's handshake operations, and every operation that wakes | every environment, every gate the `bench` suite runs at |
| **The console's line within 0.7 ms**, with no receive FIFO overrun and no refused line | the Raspberry Pi 4's interrupt measurement, in the cells [design-fiasco.md](design-fiasco.md#verification) names as passing | a board's record; a milestone or release that ships on the Raspberry Pi 4 is not reached while its build's latest record fails it |
| **The SD controller's line within 1 ms** | the same measurement | the same |

The two board limits keep the definition the Fiasco design gives them,
from Fiasco's interrupt entry to the driver's process, each cell's longest
receipt recorded. How that entry is stamped in a build that is not a
diagnostic one is [an open decision](#open-decisions); until it is
settled, a board record holds the receipt from the first user-mode stamp
on the path, and the two limits read `partial: no kernel entry stamp`
rather than pass.

## The gates

| Tier | What runs | Time | What fails it |
| --- | --- | --- | --- |
| **Landing**, with the QEMU suites a change touches | `tools/erx check-qemu --suite bench`: the five benchmarks' landing forms in three boots, the native bench image under HVF and in deterministic mode and the development image under HVF | about a minute, measured by the suite and recorded; the landing forms shrink if it grows past that | a lost wake, a wrong answer, a benchmark that did not run (`timed_out`, `not_run`) |
| **Milestone** | `make check-qemu` runs the `bench` suite fresh, as every suite | the same | the same |
| **Plan gates and on demand** | `tools/erx bench NAME --profile full`, `--paired`, and the Raspberry Pi 4's runs by hand | minutes to hours | the board limits, for the milestones that ship on the board |

That the native guests boot in deterministic mode as the production
image does is unverified; the deterministic cells join the suite when
the native bench image does.

The `bench` suite is an ordinary QEMU suite
(`tools/lib/erx/qemu_suites/bench.rb`): its cells are its benchmarks, each
`passed`, `failed`, `timed_out`, `partial` or `not_run` by the rules of
[design-build.md, What the gates run](design-build.md#what-the-gates-run),
and it declares no offload, so its cells never move to a TCG host. It
runs a change's suite when the change touches what CLAUDE.md's "Latency is
UX" lists, which is how such a change brings its numbers. Its report
prints each operation's summary and its comparison with the newest
committed run of the same environment whose source revision is an
ancestor of the candidate's, with no dirty tree; without one, the
comparison is `inconclusive: no baseline`, which does not fail the suite.

The suite's boots go through the gate's store of passing boots
([design-build.md, Reusing passing boots](design-build.md#reusing-passing-boots)),
whose key holds the image, QEMU's arguments, QEMU itself and the tools'
code. An unchanged image costs nothing: the stored log is judged again and
its numbers are the measurement of those inputs on that host, so the
report names the run that measured them and the writer adds no record. A
store belongs to one host, so a reused measurement is always this host's.

Two runs on one host disturb each other. The gate runs its suites one
after another, and the record keeps the host's load; another worktree's
gate running meanwhile shows as load, and makes the comparison
inconclusive rather than wrong.

## Other systems on the same Raspberry Pi 4

A comparison across systems is only as fair as its board. Every system
runs on the same 4 GB Raspberry Pi 4, in the same case and cooling, from
the same power supply, with the same `config.txt` frequency settings, and
starts each run after a minute idle. Each record keeps the firmware files'
SHA-256 (each system's image ships its own copy), and the temperature and
throttle state where the system can read them; a difference is recorded,
not corrected.

| System | Version | How it boots | What it runs |
| --- | --- | --- | --- |
| erXos | the subject | netboot (`tools/erx netboot`) | the bench images |
| L4Re | a pinned L4Re snapshot of the Fiasco revision erXos's fork came from, built by its own build system, without virtualization support as erXos's fork is | netboot, as erXos's Fiasco does | L4Re's own IPC benchmark (`github.com/l4re/ipcbench`), fetched pinned; first in L4Re's published configuration, which must reproduce the page's 505, 702 and 305 cycles within a tenth before any comparison is trusted, then in the configuration erXos's fork uses |
| FreeBSD | 15.1-RELEASE's image for the Raspberry Pi, the release erXos's commands are compared with in the oracle guest ([design.md](design.md#testing-and-the-oracle)); that it boots this board is unverified | its own SD card | `erx_peer_bench` |
| Linux | Raspberry Pi OS Lite, 64-bit, pinned, with the vendor's stock kernel; its real-time kernel as a second row for `wake` only, if the image offers one (unverified) | its own SD card | `erx_peer_bench` |

Each image is fetched by the fetch step at a pinned URL and SHA-256, and
written to its own card; nothing from it enters the tree, and nothing of
it runs on the host. A system's frequency governor is set to hold the
configured frequency, and how each system is told so is checked on the
board.

`bench/peer/erx_peer_bench.c` is one C17 file under erXos's license that
FreeBSD and Linux compile on the board with their own compiler; the record
keeps the compiler's version and flags. It runs the POSIX counterpart of
each operation and prints the same `BENCH` lines, so one reader imports
all four systems. It reads the system counter directly where the system
lets user mode read it (unverified on both; recorded as clock `counter`),
and otherwise `CLOCK_MONOTONIC` (recorded as such). It pins threads with
`cpuset_setaffinity` on FreeBSD and `sched_setaffinity` on Linux, the one
place it differs by system.

A run on the board writes its console to a file through the host's serial
adapter, and `tools/erx bench import --env pi4-4gb-SYSTEM LOG [--capture
FILE]` turns the log, and the analyser's capture, into a record. L4Re's
benchmark prints its own format; its importer keeps only what it prints,
so its rows are `partial: mean only` where it gives a mean.

**Counterparts.** Each declaration names, per operation, what the other
systems run, and the side-by-side table prints that line with the numbers:

| erXos operation | L4Re | FreeBSD and Linux | What differs |
| --- | --- | --- | --- |
| `nullcall.kernel` | the null system call | `getppid` | a POSIX call does a little work |
| `nullcall.root-cross-space` | IPC between two tasks | an 8-byte round trip over a pipe between two processes | erXos's number adds the root service's receive, decode and reply to Fiasco's IPC |
| `vm.commit`, `vm.touch`, `vm.protect`, `vm.decommit`, `vm.map` | none | `mmap` of anonymous memory, the first write to each page, `mprotect`, `madvise` freeing pages, `mmap` of a shared memory object | erXos's calls are requests to the root service on Fiasco |
| `wake.park-deadline` | none | `clock_nanosleep` with an absolute deadline, period 1 ms | the systems' timer resolution |
| `wake.wake-cross-cpu` | none | a thread blocked on a condition variable woken from another CPU | the wait primitive |
| `wake.gpio-edge` | none | a process blocked on a GPIO line's event, writing a second line (FreeBSD's `gpioc` events, Linux's GPIO character device; FreeBSD's support on this board is unverified) | all four on the analyser's clock |
| `sched.share-equal` | none | the same spinners, pinned, at the default priority | the scheduler |
| `xdomain.rtt`, `xdomain.throughput` | none | a 64-byte round trip and a 512 KiB stream over a UNIX-domain socket | a socket is not a connection between domains |

seL4's published numbers stay context: seL4 is not among the systems
approved to boot on the board.

### The interrupt probe

The probe that found the late interrupt timed a path from inside it. Its
complement times the same kind of path from outside, on the analyser's
clock, and so sees what no stamp can: the hardware's delay before the
kernel runs, and an edge the system missed.

The analyser, a Glasgow, drives one spare header GPIO into the board, the
*stimulus*, and watches a second, the *response*; the console's GPIO 14
and 15 and the JTAG pins 22 to 27 are not used. A responder on the board
waits for the stimulus's edge and sets the response. The interval from a
stimulus edge to its response edge is one sample of `wake.gpio-edge`, on
the analyser's clock, for every system alike. Two responders run on
erXos: a native holder task, as `native_irq`'s holder is, which times the
kernel and the native path, and a `high` Erlang process attached to the
GPIO bank's line through `erx_irq_line`, which times the path the console
driver's process takes. Both need the GPIO unit's page and line 145, which
the development manifest places in the system domain
([design-header-io.md](design-header-io.md#placement-units-and-domains));
whether the system domain's runtime can reach that page through the
device NIF is unverified, and if it cannot, the Erlang responder waits for
the GPIO driver. The stimulus comes at random intervals of 2 to 20 ms, so
it is never in step with the 1 ms tick, and each of the Fiasco design's
six load cells runs with it. A stimulus edge with no response edge
before the next stimulus is a lost event.

## The first five benchmarks

IPC, the scheduler and memory come first. The order follows the failures
each catches, most damaging first. Every one runs in the
landing form at the landing gate, and in the full form at the gates that
name it.

### 1. `wake`: how late a waiting thread runs

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `park-deadline` | an executor of the root's group parks with deadline k, the first plus k periods, and stamps its return | `ERX_ETIMEDOUT`, not before its deadline | periodic, on the root service's CPU and on another |
| `wake-same-cpu`, `wake-cross-cpu` | thread B parks with a deadline 1 s away; thread A, on B's CPU or another, sees B parked (`native_irq`'s handshake), stamps, calls `erx_executor_wake` for B's slot, and blocks; B stamps its return | B's park returns `ERX_OK`; a return of `ERX_ETIMEDOUT` is a lost wake | fast |
| `trigger-take` | a thread stamps and fires a doorbell bound to the root's group with `erx_irq_trigger`; the parked executor's take returns its label and it stamps | the label the bind gave, once per fire | fast, same CPU and across CPUs |
| `erlang-timer` | in the development image, a process at `normal` and one at `high` each take a timer with an absolute deadline every millisecond (`erlang:start_timer/4` with `{abs, true}`) and stamp its message's receipt | one message per deadline, none before it | periodic |
| `gpio-edge` | the analyser's stimulus edge to the responder's response edge | a response for every stimulus | periodic, the Raspberry Pi 4 only |

Load cells: idle; a spinner of a test task in the app band on the waiting
thread's CPU; on the board, the six cells of
[design-fiasco.md, Verification](design-fiasco.md#verification).

**What it catches.** A lost wake, the one limit that holds everywhere; a
wake that waits behind other work at its level, the late interrupt; a
timed wait that ends only at the next tick; and a doorbell path that grows
a request to the root, which `trigger-take` shows as a jump of one root
round trip. `trigger-take` under HVF, on one CPU and across CPUs, settles
the watch list's item on a doorbell from ring to wake.

**What it needs.** A native bench guest, `test/guest/native_bench/`,
whose root reuses `native_irq`'s park handshake and holder, and launches
`native_task`'s program (`test/guest/native_task/program.c`) in new modes
for its spinners and callers; the guest C library of
`test/guest/bench/` (calibration, histogram, the `BENCH` line); an
Erlang module `bench/erx_wake_bench.erl` typed into the development
image's shell as `g3` types its beam; the responders and the analyser's
importer for `gpio-edge`; and a build of the native bench image for the
Raspberry Pi 4, since the native guests are built for QEMU `virt`'s
platform (`Platform.development`).

### 2. `sched`: how a CPU is shared

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `share-equal` | N spinners (N = 2 and 4) of one test task in the app band, pinned to one CPU that is not the root service's; each reads the counter in a loop and keeps its own count of iterations and its longest gap between two reads, and writes them at each window's end through the test task's console write | every spinner reports each window | sustained |
| `share-tasks` | one spinner in task A and four in task B, both in the app band, on one CPU | the same | sustained |
| `band-work` | the root's thread, at its band's base, does a fixed piece of work alone and beside app-band spinners on its CPU, as `native_task`'s band case does; the operation is the work's time | the work finishes | expensive |

A window's summary is each thread's share of the iterations, the ratio of
the smallest share to the largest, each thread's longest gap, and the
number of gaps longer than twenty loop periods, which are the turns it
lost. With N threads at one level and a 1 ms slice, the longest gap is
about N - 1 slices. `share-tasks` shows that Fiasco shares among threads,
not domains: task A gets about a fifth, the limitation
[design-fiasco.md, Bands](design-fiasco.md#bands) records, measured and
not judged.

**What it catches.** A slice that reverts to Fiasco's 10 ms default (the
gap grows tenfold), a thread starved at its level, and a band that no
longer protects the work above it.

**What it needs.** `native_task` program modes for the recording spinner;
the native bench guest of `wake`.

### 3. `nullcall`: what asking for nothing costs

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `root-same-space` | a thread of the root stamps, sends the root service a request its decoder refuses (a call whose request has more than one word, sent with only the caller's word), and stamps the reply | `ERX_EINVAL` from the decoder | fast, on the service's CPU and on another |
| `root-cross-space` | the same from a thread of a test task | the same | fast, the same placements |
| `kernel` | the cheapest call Fiasco answers alone, chosen from Fiasco's source when the guest is written and named in the record (a candidate is the invocation of an empty capability slot) | the error Fiasco gives that call | fast |

The request needs no new call in the root service. The decoder refuses a
request whose word count matches no layout before any body runs
(`erx_fiasco_wire_decode`, `liberx/backend/fiasco/service_wire.c`), and
answers it through the same receive and reply as every request
(`service_message`, `liberx/backend/fiasco/service.c`): the fixed cost of
the root service, measured on the path every call takes, with nothing
added for a benchmark to keep secure. On erXos's kernel, `kernel` is its
null call, the one the speculation mitigations are priced by
([design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)),
and the root operations go, since there is no root service.

**What it catches.** Growth of the decoder or the dispatch, a mitigation
added to every entry, and Fiasco's IPC slowing under a configuration
change. On the board it is FD32's decision: two release builds with and
without the patch, ten full runs each, judged `same` or not by the
comparison's median band. Beside L4Re's IPC between two tasks on the same
board, it shows what the root service adds to Fiasco.

**What it needs.** A `native_task` program mode that makes the request in
a loop; the native bench guest.

### 4. `vm`: what memory costs

Each operation is timed from the root and from a test task, on Fiasco
both requests to the root service:

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `reserve`, `release` | `erx_vm_reserve` of 1 page and of 512 pages; then `erx_vm_release` of it | `ERX_OK`; the free page count unchanged after the release | fast for 1 page, expensive for 512 |
| `commit`, `decommit` | `erx_vm_commit` of 1, 64 and 512 reserved pages; then `erx_vm_decommit` | `ERX_OK`; the pages read zero after the commit, checked outside the timing | the same |
| `touch` | the first write to each page of a 64-page commit, one sample per page | the write completes; the record says whether the commit had mapped the pages already | fast |
| `protect` | `erx_space_protect` of 1 and 64 committed pages to read-only and back | `ERX_OK` | fast |
| `map` | `erx_mem_create` of 64 pages, `erx_vm_map` of it at reserved addresses of the caller's own space, then `erx_vm_release` of the range and `erx_cap_close` of the object, each timed | `ERX_OK` throughout | expensive |
| `mem-child` | `erx_mem_child` of a 64-page object | `ERX_OK`; the record says it is an eager copy on Fiasco | expensive |

**What it catches.** A commit or a protect whose plan walks more than it
should (the watch list's 65,500 probes of the loader's window is one), a
page charged or zeroed twice, and the cost the root as pager adds over a
kernel's map. Its counterparts on FreeBSD and Linux are anonymous
`mmap`, first touch, `mprotect` and freeing.

**What it needs.** A `native_task` program mode for the calls; a test
task budget large enough for 512 pages; the native bench guest.

### 5. `xdomain`: one message, one domain to another

This is E-D1 of [design-domains.md](design-domains.md#performance), under
its two names:

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `local-rtt` | two processes of one domain: `{echo, B}`, B a 64-byte binary, answered `{echo, B}` | the reply equals the request | fast |
| `xdomain-pingpong` (`busy`, `parked`) | the same across a connection, to `erx_echo_test`'s facet in another domain, which answers `{echo, Term}` with `{echo, Term}`; busy keeps a spinning process in each runtime so no executor parks, parked lets both park between messages | the same | fast |
| `xdomain-throughput` | 512 KiB binaries sent through the facet, each sixteenth acknowledged, at the image's default lane size | every acknowledgement arrives, in order | sustained |

The record keeps each frame's encoded size. Its budgets are the domains
design's: 1 us for a busy round trip under HVF, 2 GB/s for 512 KiB
binaries. Lane sizes of 16 KiB and 1 MiB are G5's runs of the full form,
from manifest variants.

**What it catches.** A funnel or lane change that adds a copy or a pass,
a wake added to the busy path, and head-of-line blocking that a large
frame causes a small one.

**What it needs.** An Erlang module `bench/erx_xdomain_bench.erl`; a test
image built from the `system_domain` suite's, which boots `erx_echo_test`
in one domain and grants its facet to a peer and to the system principal's
session (`tools/lib/erx/system_domain_regrant.rb`); the client runs in a
domain the facet is granted to, which this image must give it. No new
facet: the echo service is the test-only one that exists.

### Next

`lifecycle` follows, with E-D3's `domain-lifecycle` and GP's `spawn`:
`spawn_monitor` to `DOWN`, a program's spawn to its `main`, a domain's
creation to its ready report, and its stop to the last death and the
pool's pages back, stamped by the trace ring's `space_start` and
`space_end` records and the requester's clock. File and pipe I/O come
with their owning gates.

## Fixing the existing tools

* **`g3` under TCG reports the guest alone.** `BenchG3.report` asks
  `BenchCompare` for the ratio, and `BenchCompare` refuses TCG against
  native, so the TCG report holds the guest's numbers and, per workload,
  `not comparable: TCG against native`. Under HVF the ratio stays, as the
  side-by-side table G3 needs. [plan.md](plan.md), gate G3, says so.
* **`otp-switch` observes its switches.** Before each yield a process
  writes its own index into a shared `atomics` cell; after the yield it
  reads the cell, and a cell holding the other's index means the other ran:
  one switch observed. The measurement's operations are the switches
  observed, its time per observed switch, and a run in which fewer than
  99% of yields switched is `failed: yields did not alternate`. The
  scheduler budget it serves, a process switch within 1.2 times stock OTP
  ([design.md, Performance](design.md#performance)), then has a number
  that means what it says.
* **Every runner writes through `BenchRecord`.** The `OutputDirectory`
  calls under `build/bench` go, each runner's report becomes a record,
  `net-freebsd`'s `--out` default becomes the history root, and `build/`
  keeps only scratch. The boot benchmark's host-clock checkpoints keep
  their clock, named `host`.

## Concurrency and failure

A guest that hangs is ended at its benchmark's deadline, its QEMU killed
with every child; each operation that reported keeps its status and each
that did not is `timed_out`. The record is written however the run ended,
so a failure leaves evidence. A guest's line that fails validation makes
its operation `rejected` and the run goes on. A failed boot in a paired
run makes that pair's verdict `inconclusive`, never a pass.

Two runs never share a run directory: the writer creates it exclusively,
and a second writer for the same name fails. The reader of the history
repository takes no lock and needs none: it reads only committed runs as
baselines, and a run directory is complete once its `run.json` is written,
last, by rename.

A cross-CPU operation is timed only after its calibration bounded the
counters' offset; with no bound, it reports `unsupported` and its round
trip stays. In deterministic mode every operation runs on one CPU, so the
cross-CPU operations are `unsupported` there.

## Refusals and error results

| Case | Result |
| --- | --- |
| `tools/erx bench NAME` for a name no file declares | refused: `unknown benchmark NAME` |
| an environment the benchmark does not declare | refused, naming the environments it declares |
| a destination inside the erXos tree, or a history root that does not exist | refused before anything runs |
| a comparison of records whose environments, operations, load cells, placements or profiles differ | refused, naming the first difference |
| a comparison of TCG or deterministic records with any other kind | refused: `TCG numbers are not compared with HVF or native numbers` |
| a record that does not parse, or of an older format | refused with the file and the reason |
| a baseline with fewer than three runs, or none | the comparison is `inconclusive`, not an error |
| `--paired` without two images | refused |
| an operation whose call answers `ERX_ENOTSUP` | the operation is `unsupported`, reported by the backend |

## Verification

The tools' cores are pure and tested on the host; each test below pairs a
passing case with the seeded fault that proves the code under test ran.

| Test | Passing case | Seeded failure that must fail it |
| --- | --- | --- |
| the writer's destination | a record under a temporary history root is written; one under the tree is refused | the real-path check removed: the write under `build/` succeeds and the test fails |
| comparability | a TCG record against a native one is refused, and `g3`'s TCG report holds no ratio | the kind check dropped: the report shows a ratio |
| the percentile rule | 999 samples give a 99th percentile and no 99.9th | the bound written as "more than nine": the 99.9th appears |
| the verdict | three baseline runs and three candidates: within the band is `same`, two of three above it by more than the threshold `slower`, one of three `inconclusive` | one of three accepted as `slower` |
| the noise band and FD32 | ten runs a side with candidate medians inside the spread are `same` | the band taken from the baseline's minimum alone |
| the histogram (C and Erlang, on the host) | samples spread over twenty octaves each land in a bucket whose bounds contain them and whose width is at most 1/64 of its lower bound | an off-by-one in the sub-bucket index: a sample lands outside its bucket |
| the `BENCH` line reader | a fuzz target over the line validator, with the guests' own lines as seeds, runs its budget clean | a removed bound on the histogram's length: the fuzzer finds the overrun |
| a periodic deadline | a guest loop with a 5 ms stall injected at period 100 reports at least four missed periods and a maximum lateness of at least 5 ms | the next deadline taken from the return: the stall shows as one late period |
| a lost wake | the `wake` handshake under its normal path reports `measured` and no loss | the wake sent to another slot: B's park times out and the cell is `failed` |
| an early return | `park-deadline` reports no early return | the deadline passed to the park 1 ms early: every period counts as early and the cell is `failed` |
| `otp-switch` | two yielders on one scheduler observe nearly every yield as a switch | the yield removed: no switch observed, the measurement `failed` |
| `nullcall` | the decoder's refusal answers `ERX_EINVAL` | a request with the call's full word count: it reaches a body, the status differs and the operation is `failed` |
| the cross-CPU clock | a host test feeding stamps with a 50-tick offset reports `unsupported` for one-way operations | the bound check skipped: a one-way number is reported |

Each benchmark also proves on its environment that it sees what it
exists for. These run once when the benchmark lands and again whenever its
guest changes, and each must change the benchmark's verdict:

| Benchmark | Seeded failure | What must change |
| --- | --- | --- |
| `wake` | the doorbell trigger stub made to send a root request, the Fiasco design's own seed for its direct doorbell case | `trigger-take`'s median rises by about one `nullcall.root` round trip |
| `wake` | a 1 ms spin added to `erx_fiasco_time_wait_us`'s caller | `park-deadline`'s median lateness rises past 1 ms |
| `sched` | the root giving a thread its task row's slice, the quantum case's seed | `share-equal`'s longest gap grows about tenfold |
| `nullcall` | a 1 us spin in the decoder's refusal | the median rises by about 1 us |
| `vm` | the commit body zeroing each page twice | `commit` of 512 pages slower |
| `xdomain` | a 16 KiB lane in the manifest | `xdomain-throughput` lower |
| the board limits | the four seeds of [design-fiasco.md, Verification](design-fiasco.md#verification) | the console or SD receipts pass their limit in the cell that seed names |

A seed that leaves its verdict `same` means the benchmark did not measure
what it claims, and it does not land.

## Alternatives considered

* **Keep raw samples and compute everything on the host.** The simplest
  record, and the one the board's 115,200-baud console cannot carry. The
  histograms carry their own bounds, so the host still holds no formula.
* **A test-only null request in the root service.** It would add a call
  to secure and to keep out of release builds, for a dispatch that costs
  one switch case more than the refusal the decoder already gives.
* **Hard thresholds on every number.** On a shared Mac they would fail on
  the host's noise, and teach everyone to rerun until green. Three limits
  carry a promise; the rest inform.
* **Compare each run with the previous one.** Without a band from several
  runs a difference cannot be told from noise; without pairing, a change
  cannot be told from the host's drift.
* **A benchmark framework apart from the suites.** The QEMU gate already
  has cells, statuses, deadlines, reuse and discovery from files; the
  `bench` suite uses them and adds only the record.
* **cyclictest, lmbench and stress-ng on FreeBSD and Linux.** They are
  GPL and measure their own operations; one small program of erXos's own,
  on all three systems, compares like with like and needs no clean room.

## Open decisions

1. **How Fiasco's interrupt entry is stamped for the two board limits.**
   The limits are defined from Fiasco's interrupt entry, and only the
   diagnostic branch stamps it. Either a development-only Fiasco patch,
   listed in [design-fiasco.md](design-fiasco.md), writes the counter at
   entry for each line into a page the root reads and turns into a trace
   ring record, or the limits start at the first user-mode stamp and the
   analyser's `gpio-edge` bounds the kernel's part separately.
   **Recommendation:** the patch, kept out of release builds: it keeps
   the definition already accepted, gives one timeline from entry to the
   driver on one clock, and goes with Fiasco when erXos's kernel, whose
   rings record interrupts, replaces it.
2. **The analyser's stimulus.** If no stock Glasgow applet drives random
   edges on one pin while capturing two, the probe needs a small applet,
   which is Python, out of the tree. **Recommendation:** check the stock
   applets on the board's Glasgow first; ask for Python only if none
   fits.
3. **The two pins.** **Recommendation:** GPIO 20 as the stimulus and
   GPIO 21 as the response, header pins 38 and 40, both plain GPIO in the
   header map and next to each other.
4. **Which benchmark is fifth.** `vm` or `lifecycle`: memory is one of
   the three costs these benchmarks exist to show, while `lifecycle`'s
   consumers, E-D3 and gate GP, come later in the plan.
   **Recommendation:** `vm` fifth, `lifecycle` next.
5. **The full forms at the milestone gate.** CLAUDE.md's milestone gate
   runs the `bench` suite's landing forms through `make check-qemu`. The
   full forms of the five under HVF and in deterministic mode would take
   an estimated 20 to 30 minutes more. **Recommendation:** add
   `tools/erx bench --profile full` to the milestone gate, so every
   milestone leaves a baseline with tails.
6. **Linux's best case.** **Recommendation:** the vendor's stock kernel
   for every row, and its real-time kernel as a second row for `wake`
   only, since the published Pi 4 latencies are of a real-time kernel.

## References

Fetched on 2026-11-23 into `~/erxos-scratch/src-osbench/` and read as
data; nothing fetched was run.

| Source | File | SHA-256 |
| --- | --- | --- |
| L4Re, "Performance Overview", `https://l4re.org/_sources/performance.rst` | `l4re/performance.rst` | `561c3f5cb58e4a3422f4bc96be24b49306b99a5139ce17cb0445e1cdf15d4a1f` |
| seL4 performance page, `https://sel4.systems/performance.html`, generated for sel4bench-manifest `35c22e17` | `sel4/perf2.html` | `0f90d3eb72218f9d802683f2b570a1d518de0614d16768af534ed3f070b89a2f` |
| sel4bench's benchmark sets, `https://docs.sel4.systems/projects/sel4bench/` | `sel4bench/docs.html` | `73d21d088c3022edefccb7f514a53e093e842d55364f81f51f3b85a2a555a144` |
| sel4bench's IPC benchmark, BSD-2-Clause, `apps/ipc/src/main.c` | `sel4bench/ipc_main.c` | `364ab7c13f0e5c625794ad38010dbf66dbaddfe1c609e7847cbb348356545aee` |
| F. P. Schmidt, linux-rt-users, 2022-06-01, cyclictest maxima on the Raspberry Pi 4 | `linuxrt/spinics25944.html` | `5b5a91969f6898e5b486c46d9d838f7973ff148d6e8585224d13a7f77134783c` |
| Trustworthy Systems, comparative L4 IPC performance | `ts/comp.html` | `695e0dcdad8444b9ce6b80169fcae2e0bcb96f10643af320e3ed09928d2c15c4` |

In the tree: [design-fiasco.md](design-fiasco.md) (Urgency, Bands, The
trace ring, Measurements, Verification), [design-build.md](design-build.md)
(What the gates run, Reusing passing boots),
[design-domains.md](design-domains.md#performance),
[design-scheduler.md](design-scheduler.md#performance),
[design-header-io.md](design-header-io.md), and
[research-baselines.md](research-baselines.md).
