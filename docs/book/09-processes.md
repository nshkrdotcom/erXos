# Chapter 9. Processes, Runtimes and Two-Level Scheduling

> **Status.** **Built:** ERTS in user mode in every domain, with its
> Erlang processes as the system's one kind of process; Fiasco running
> every thread but the watchdog at one priority; the two classes of
> runtime thread and how they sleep and wake; the table that turns a
> doorbell into work; the system domain on the interpreter, with
> BeamAsm available to other domains; musl under ERTS, with FreeBSD's
> errno and signal numbers; hosted mode on macOS; `ps` over Erlang
> processes; and `erx:trace`. **Designed:** priority bands, CPU sets and
> thread limits; refusing a scheduler thread every other blocking wait;
> refusing code that is not installed; one shared copy of common code;
> native programs in `ps`; and services that admit each client within a
> share of their time.

**Background needed.** [Chapter 8](08-kernel-interface.md) for
`liberx`, the root service, threads and waits;
[section 3.5.2](03-erlang.md#352-schedulers-and-reductions) for
schedulers and reductions.

An Erlang process in the network domain enters an endless loop. On the
same machine the display domain must draw the next frame, and the
storage domain has a write half done. Something must take the processor
from the loop, give it to the others, and give it back. When the
network domain falls idle, its threads must sleep without spending a
cycle and wake when the next packet arrives. A wakeup that comes while
a thread is deciding to sleep must not be lost; a lost one leaves a
packet unread until something else wakes the domain.

FreeBSD meets the first half of this problem with its kernel scheduler,
ULE. ULE keeps a run queue per processor and picks by priority, and a
thread's priority falls the more it has run lately and rises the more
it sleeps. An Erlang system on FreeBSD is one UNIX process, `beam.smp`,
with one scheduler thread per processor. ULE sees those few threads and
nothing of the thousands of Erlang processes inside them; ERTS shares
each thread among its processes by its own rules. The second half,
sleeping without losing a wakeup, ERTS solves for itself with a spin,
then a wait on a pthread condition variable or in `kqueue`.

erXos keeps the two levels and makes them the system's design: Fiasco
schedules threads, and each domain's runtime, ERTS, schedules its
Erlang processes on its own threads. The kernel never calls into a
runtime.

One picture fixes this chapter's words. Take a network domain whose
ERTS has two scheduler threads and one dirty I/O thread, the
helper that runs long C calls
([section 3.5.4](03-erlang.md#354-bifs-nifs-and-ports)).

* The two schedulers are **executors**: threads that run Erlang
  processes in turn and never block except to **park**, that is, to
  sleep until a wakeup.
* The dirty I/O thread is a **worker**: a thread that may block.
* The executors make up the domain's **group** (chapter 8), and each
  holds a **slot** in it, its entry in the group's table, by which
  another executor can wake it by name.
* A packet's arrival rings a **doorbell** bound to the group.
* Every wakeup advances a counter, the **epoch**. An executor reads the
  epoch before it looks for work, and its park returns at once if the
  epoch has moved since, so a wakeup that races with the park cancels
  it.

## 9.1 The Erlang process is the system's process

Ask a FreeBSD machine what is running, and `ps` lists UNIX processes.
Ask erXos, and `ps` lists Erlang processes, because those are the
system's processes. A pid, a mailbox, links and monitors make the unit
of execution and of failure for the whole machine
([design.md, The model](../design.md#the-model)). The kernel has
address spaces and threads but no processes of its own
([section 3.9.1](03-erlang.md#391-every-erlang-process-is-an-operating-system-process)).

### 9.1.1 What a user and a programmer see

Type `ps` at the shell, rc, and it prints FreeBSD's default columns,
`PID TT STAT TIME COMMAND`, one row for each Erlang process of the
runtime the session runs in, which is the system domain's
(`erlang/apps/erx_shell/src/erx_cmd_ps.erl`). Each row is named by the
process's registered name, or the label it set for itself through
OTP's `proc_lib`, or the function it started in. This is **Built**.
The `TIME` and `%CPU` columns print `-`: the runtime does not measure a
process's processor time in a form `ps` reads, and erXos prints "not
known" rather than a guess. Native programs are designed to appear in
the same table, as rows of their own; that is not built.

The same processes appear in the Erlang shell's `erx:i()`, under
`/proc`, and in the inspector
([chapter 21](README.md#chapter-21-the-live-machine)). No second,
hidden kind of process lies beneath them.

An Erlang programmer writes the code they would write on FreeBSD.
erXos checks this by running OTP's test suites for ERTS, `kernel`,
`stdlib` and the compiler on its runtime and on stock OTP 29.1.2, and
comparing the results case by case (`tools/lib/erx/oracle.rb`).

### 9.1.2 Two levels in one picture

Figure 9.1 shows the two schedulers. Fiasco sees threads and picks
which one runs on each processor. Inside each domain, ERTS sees its
Erlang processes and picks which one each executor runs.

```mermaid
flowchart TB
    F[Fiasco: picks a thread for each CPU]
    subgraph D1[network domain]
        E1[executor 1] --> P1[Erlang processes]
        E2[executor 2] --> P2[Erlang processes]
        W1[worker: dirty I/O thread]
    end
    subgraph D2[display domain]
        E3[executor 1] --> P3[Erlang processes]
        W2[worker]
    end
    F --> E1
    F --> E2
    F --> W1
    F --> E3
    F --> W2
```

*Figure 9.1. The two levels. Fiasco schedules threads and knows nothing
of Erlang; each runtime switches among its own processes on its own
executors without entering the kernel.*

The split puts each decision where the information is. ERTS knows which
process holds a lock, which has a message waiting and which runs at
`high` priority; Fiasco knows which thread of which domain is ready on
which processor. A
switch between two Erlang processes needs no kernel entry, and a busy
domain makes a great many of them, which is why the kernel does not.

## 9.2 How Fiasco shares the processors

What keeps one domain from taking all the processor time? On erXos the
answer is Fiasco's fixed-priority scheduler and each domain's place in
it.

### 9.2.1 One priority, round robin

Fiasco gives each thread a priority from 1 to 255 and always runs the
highest-priority ready thread on each processor. Threads of equal
priority take turns, a time slice each
([design-fiasco.md, Scheduling](../design-fiasco.md#scheduling)). In
erXos every thread but one runs at priority 1
(`SERVICE_THREAD_PRIORITY` in `liberx/backend/fiasco/service.c`). The
exception is the root service's watchdog, at 255
(`watchdog_thread.c`), which takes no lock. This is **Built**.

A spinning domain cannot shut the others out, but nothing gives the
display domain precedence either. A patch to erXos's copy of Fiasco
puts a thread that yields behind the others of its priority
([section 8.5.1](08-kernel-interface.md#851-threads)).

Fiasco has no load balancer. A thread stays on the processor where it
was placed until `erx_thread_set_affinity` moves it, and a domain's
threads started with no processor named share one processor
([design-fiasco.md, Scheduling](../design-fiasco.md#scheduling)). ERTS
names no processor for its schedulers. **So a domain's executors share
one processor and take turns on it; they do not run in parallel**,
whatever figure 9.1 suggests. The cost is unmeasured and is on
[the performance watch list](../todo-performance.md).

### 9.2.2 Bands

A **band** is a run of Fiasco priorities given to a domain by its row
in the system manifest; every thread of the domain starts at its band's
priority ([design-fiasco.md, Bands](../design-fiasco.md#bands)). The
design has six bands, one priority each, listed in table 9.1 from the
highest priority down.

| Band | Holds |
| --- | --- |
| 1 | the watchdog, at 255 |
| 2 | the root service |
| 3 | the system domain |
| 4 | driver and device domains |
| 5 | interactive domains: display, web, sessions |
| 6 | apps and programs |

*Table 9.1. The six bands. A domain that spins delays only its own band
and those below it.*

A band orders domains; it does not divide time among them. A spinning
app, in the lowest band, gets what every other thread on its processor
leaves. Inside a band, threads still take turns.

A band measures no share: a driver domain in a busy loop takes its
processor from every interactive domain there, for as long as it
loops. It bounds no latency. And it belongs to a domain, not to a
request. When an app asks the storage service to write a file, the
write runs on the storage domain's threads, at that domain's band, not
at the app's.

Bands are **Designed** and not built.

### 9.2.3 CPU sets and thread limits

A domain's **CPU set** names the processors its threads may run on, and
its **thread limit** caps how many threads it may have across its
tasks. Both come from the same manifest row as the band
([design-fiasco.md, Threads, bands and stops](../design-fiasco.md#threads-bands-and-stops)).
The root creates every thread and hands Fiasco each thread's processor
mask through one call. In the design, one function first narrows the
mask to the domain's CPU set and the processors online. Its result has
a type of its own that only that call takes, so a mask that skipped
the narrowing does not build. A thread past the limit gets
`ERX_ELIMIT`. L4Re's loader, ned, confines its programs to a CPU set
the same way ([ned documentation](https://l4re.org/doc/l4re_servers_ned.html),
"Control scheduling"). CPU sets and thread limits are **Designed** and
not built.

## 9.3 The runtime contract

What may a runtime ask of the kernel, and what must it promise?
[Section 4.2](04-history.md#42-thirty-years-of-two-level-scheduling)
told why two-level schedulers usually failed: the kernel had to call
into the user-level scheduler whenever a thread blocked, at whatever
point it had reached. erXos's contract
([section 4.2.3](04-history.md#423-why-erxos-keeps-two-levels))
removes the cause; this section shows it on Fiasco.

### 9.3.1 Executors and workers

In ERTS the normal and dirty CPU schedulers are executors; the dirty
I/O schedulers, ERTS's helper threads and the thread that waits for
fault records are workers
([design-runtime.md, Scheduling](../design-runtime.md#scheduling)).
The class is fixed at creation: `erx_thread_create` takes it, and an
executor gets its slot then (`liberx/backend/fiasco/thread.c`). ERTS
asks for the class through one option of its thread library that only
`erts_start_schedulers` sets (`otp/erts/include/internal/ethread.h`).

`liberx` refuses a worker what only an executor may do: `erx_park` and
`erx_group_take_ready` answer `ERX_ETYPE` to a thread with no slot
(`liberx/backend/fiasco/park.c`). This is **Built**.

The design also refuses the other direction
([design-scheduler.md, The runtime contract](../design-scheduler.md#the-runtime-contract)).
An executor may make two kinds of blocking call: a park, and a **umtx
wait**, a wait on a word of its domain's private memory, like FreeBSD's
`_umtx_op` ([section 8.5](08-kernel-interface.md#85-threads-waits-gates-and-faults)).
Every other blocking call answers `ERX_EWOULDBLOCK`. That refusal is
**Designed** and not built. It is a rule of `liberx`, not of Fiasco: a
runtime that bypassed `liberx` could block its own executors, which
harms only its own domain.

The umtx wait is allowed because ERTS builds its locks on it, and
forbidding it would mean rewriting ERTS's locking. The word lies in
memory only the domain's own threads touch, so an executor in a umtx
wait waits for a thread of its own domain. Locks are held for a few
instructions, so the wait is usually short; it is long only when
Fiasco has preempted the holder (section 9.3.4). Either way it waits on
its own domain, never on another.

### 9.3.2 The lost wakeup

Every sleeping scheme has the same race. An executor finds no work and
decides to sleep. Between the look and the sleep, a message arrives and
its sender rings the doorbell. The wakeup goes to a thread that is not
asleep, and the executor then sleeps with work waiting. The top half of
figure 9.2 shows it.

The epoch closes the race. The executor reads the epoch *before* it
looks for work and passes the value to the park. Under a lock, the park
compares the current epoch with the value read. If anything advanced it
in between, the park returns at once and the executor looks again. If
not, the executor joins the parked list under the same lock, and any
later wakeup finds it there.

```mermaid
sequenceDiagram
    participant X as executor
    participant P as park record
    participant S as sender
    Note over X,S: without an epoch
    X->>X: look: no work
    S->>P: wake: nobody parked, wake lost
    X->>P: park
    Note over X: asleep with work waiting
    Note over X,S: with an epoch
    X->>P: read epoch = 7
    X->>X: look: no work
    S->>P: wake: epoch 7 -> 8
    X->>P: park(7)
    P-->>X: epoch is 8: return at once
    X->>X: look again: work found
```

*Figure 9.2. Park and wake, drawn for one epoch. The wakeup that falls
between the look and the park advances the epoch, so the park that
would miss it returns at once.*

There are two epochs, because there are two kinds of wakeup. A
doorbell wakes "some executor of the group" and advances the group's
epoch. ERTS also wakes one executor by name, when it puts a process on
a sleeping scheduler's run queue: `erx_executor_wake` advances that
slot's epoch. The park returns at once if either changed
([design-scheduler.md, Park and wake](../design-scheduler.md#park-and-wake)).

### 9.3.3 Park and wake on Fiasco

Fiasco has no park call, so `liberx` builds one from a semaphore per
thread, on which every wait in erXos ends
([section 8.5.2](08-kernel-interface.md#852-waiting-one-semaphore-per-thread)),
and a **dispatcher**, one thread in each task (Fiasco's address space)
that receives the task's doorbell deliveries
([design-fiasco.md, The park protocol](../design-fiasco.md#the-park-protocol)).
The group's **ready list** holds the doorbells that have fired and not
yet been handled. Follow a request into a parked storage domain.

1. A process in a session sends the storage service a request. The
   session's runtime copies the frame into a lane, the one-way ring
   that carries messages between two domains, and rings the lane's
   doorbell
   ([section 8.7.1](08-kernel-interface.md#871-one-path-for-devices-and-peers)).
2. Fiasco delivers the doorbell to the storage domain's dispatcher.
3. The dispatcher takes the park lock and runs the *signal* event: it
   puts the doorbell on the ready list unless it is listed already,
   advances the group's epoch, and takes the longest-parked executor
   off the parked list. It releases the lock and raises that executor's
   semaphore.
4. The executor returns from its wait. At its safe point, between two
   Erlang processes, it takes the ready list with
   `erx_group_take_ready`, which returns each doorbell's label once,
   however often it fired, and dispatches each label
   ([section 9.4.4](#944-the-event-table-readiness-without-file-descriptors)).

One doorbell wakes one executor. When none is parked, a running
executor finds the doorbell at its next safe point.

The protocol's decisions are one pure function,
`erx_backend_park_step` (`liberx/backend/core/park_table.c`), which
takes the park record and an event (a park, a wake, a doorbell, a
timeout, a thread's end and a few more) and returns at most one
semaphore to raise or wait on. It calls no kernel, so host tests drive
it ([section 6.3](06-construction.md#63-functional-core-effects-at-the-edge)). Parking is **Built**. Its cost is one thread switch: a
wakeup of an idle domain goes through the dispatcher, so it takes two
switches where a kernel with a park call would take one.

### 9.3.4 What a runtime does not get

On Fiasco a runtime gets threads, park and wake, and nothing else from
the scheduler
([design-fiasco.md, The scheduler on Fiasco](../design-fiasco.md#the-scheduler-on-fiasco)).

* **No upcall.** The kernel never enters a runtime at a point the
  runtime did not choose. erXos arms Fiasco's one upcall interface, its
  vCPU mode, for no runtime thread; the design arms it only for native
  programs' workers, never an executor
  ([section 8.5.6](08-kernel-interface.md#856-signals-through-vcpu-upcalls)).
* **No urgency.** A runtime cannot change one thread's priority:
  `erx_thread_set_urgency` answers `ERX_ENOTSUP`
  (`liberx/backend/core/refused.c`).
* **No share.** Fiasco charges each thread for its own slices and keeps
  no account per domain
  ([section 5.6.5](05-overview.md#565-shared-services-and-shared-cpu)).
* **No grace period.** Some kernels let a thread that holds a lock run
  a little past the end of its slice, so others do not wait on a
  preempted holder. Fiasco does not: a slice ends where it ends, even
  inside a run-queue lock, and an executor that wants the lock sleeps
  in its umtx wait until the holder runs again.

Each absence buys simplicity: a runtime never entered unexpectedly
needs no code to recover, and a kernel that takes no hints cannot be
misled by a runtime that lies.

## 9.4 ERTS as a parts bin

Why does erXos carry its own ERTS instead of running the stock one on a
compatibility layer? Much of ERTS only adapts it to UNIX, such as its
poll set over file descriptors, and where erXos already has a mechanism
for a job, keeping both would give a reader two models to learn
([section 3.9.5](03-erlang.md#395-erts-as-a-parts-bin)).

### 9.4.1 One mechanism per job

For each job, erXos keeps the better of ERTS's mechanism and its own,
or redesigns it. Table 9.2 shows the scheduling rows.

| Job | Stock ERTS | ERTS on erXos |
| --- | --- | --- |
| choosing which process runs | run queues, priorities, reductions, stealing | kept |
| choosing which thread runs | the host kernel | Fiasco |
| waiting for work | spin, then a thread event or `poll` | `erx_park` with epochs |
| readiness | the poll set over file descriptors | doorbells on the ready list, through the event table |
| timeouts | a timer wheel per scheduler, which files each Erlang timer by when it expires | kept; a park's deadline is the wheel's next expiry |
| long C calls | dirty schedulers | kept: dirty CPU schedulers are executors, dirty I/O ones workers |

*Table 9.2. Scheduling in ERTS, stock and on erXos
([design-runtime.md, One mechanism per job](../design-runtime.md#one-mechanism-per-job)).*

ERTS's scheduler stays whole, because it has run production Erlang
systems for decades. Its sleep and readiness are redone: the poll set
assumes file descriptors, which a domain does not have, and the spin
spends time that another domain at the same priority could have used.

### 9.4.2 The inside of ERTS on erXos

Stock ERTS keeps what it needs from UNIX in one directory, `sys/unix`.
On erXos, ERTS's scheduler, garbage collector, loader and distribution
sit instead on an **adapter**, the directory
`otp/erts/emulator/sys/erxos/`, the only part of ERTS that includes a
`liberx` header
([design-runtime.md, The adapter](../design-runtime.md#the-adapter)).
Figure 9.3 shows the layers.

```mermaid
flowchart TB
    E["Erlang code: OTP, services, drivers"]
    R["ERTS: scheduler, GC, loader, distribution"]
    A["adapter, sys/erxos: park and wake, event table, lane driver, crash area"]
    M["musl: threads, malloc, strings"]
    L["liberx"]
    K["Fiasco, and the root service"]
    E --> R --> A
    A --> L
    R --> M --> L
    L --> K
```

*Figure 9.3. ERTS on erXos. Only the adapter and musl call `liberx`,
and only `liberx` reaches Fiasco or the root service. The lane driver
is the port that carries frames between domains; the crash area is
where a dying runtime leaves its dump (section 9.8).*

ERTS's files outside the adapter carry some seventy numbered edits
([design-runtime.md, The edits outside `sys/erxos`](../design-runtime.md#the-edits-outside-syserxos)).
Two matter here. `scheduler_wait`, the step where a scheduler with
nothing to run spins and then sleeps, parks with `erx_park` instead of
a thread event or the poll set. `wake_scheduler` wakes with
`erx_executor_wake`.

### 9.4.3 The scheduler's sleep, in code

`sched_park`, in `otp/erts/emulator/beam/erl_process.c`, stands where
stock ERTS called `erts_tse_twait`:

```c
/* Answers as erts_tse_twait does: 0 at a wake, which may be spurious, or ETIMEDOUT. */
static int
sched_park(ErtsParkEpochs epochs, Sint64 timeout)
{
    const uint64_t deadline = timeout < 0 ? ERX_WAIT_FOREVER : erx_deadline_after((uint64_t) timeout);

    switch (erx_park(epochs.group, epochs.slot, deadline)) {
    case ERX_OK:
        return 0;
    case ERX_ETIMEDOUT:
        return ETIMEDOUT;
    default:
        erts_exit(ERTS_ABORT_EXIT, "%s:%d: Internal error\n", __FILE__, __LINE__);
        return 0;
    }
}
```

Two things matter. The function answers as the call it replaces did,
so the rest of `scheduler_wait`, its flags and its loop, is ERTS's own.
And the epochs arrive as an argument, `ErtsParkEpochs`, the group's and
the slot's values, which the caller read before it decided to sleep.
The timeout is the next expiry of the scheduler's timer wheel, so a
parked scheduler wakes for its next Erlang timer and no sooner. A dirty
I/O scheduler, which has no slot, keeps ERTS's thread event, a umtx
wait on erXos.

### 9.4.4 The event table: readiness without file descriptors

On FreeBSD, ERTS learns that a socket has data from `kqueue` or `poll`,
which report file descriptors. A domain has none. It has doorbells:
each connection's lane, each device line and each native program's
channel (the pipe between ERTS and the program, chapter 13) has one,
bound to the domain's group with a **label**, a number chosen by the
code that bound it. The ready list returns labels, and the **event
table** says what each names
([design-runtime.md, The event table](../design-runtime.md#the-event-table)).
A label leads to one of three sinks:

* a **connection sink**, a lane from another domain: the lane port's
  input task is scheduled, and a normal scheduler copies the frames out;
* a **port sink**, such as a native program's channel: ERTS's own input
  task for that port is scheduled, so the port's work runs one piece at
  a time, as every port's does;
* a **process sink**, such as a device's interrupt: the term registered
  with the label is sent to an Erlang process, as `{erx_irq, Device,
  Line}` reaches a driver.

A label whose sink has gone is dropped. The table's core,
`otp/erts/emulator/sys/erxos/erx_event_table.c`, knows nothing of ERTS
and calls no kernel, so host tests drive every path; `erx_event.c`
holds its effects. ERTS on erXos runs no poll thread. The event table
is **Built**.

## 9.5 Code: the interpreter, BeamAsm and shared code

Which code a domain may run is a security decision as much as a speed
one. A just-in-time compiler, or JIT, turns a program into machine code
while it runs: it writes code and then runs it, which is what an
attacker who finds a memory bug wants to do. erXos never maps a page
writable and executable through one mapping
([section 6.2.6](06-construction.md#626-a-mapping-that-is-never-writable-and-executable)),
so a JIT writes through one mapping and runs through another.

### 9.5.1 Three runtime images

erXos builds ERTS three ways, listed in table 9.3
([design-runtime.md, BeamAsm](../design-runtime.md#beamasm)).

| Image | What it is | Who runs it |
| --- | --- | --- |
| system image | the interpreter, without BeamAsm, its C++ runtime or OpenSSL | the system domain |
| interpreter image | the same build with OpenSSL | command domains (where a shell command with less authority than its session runs), every domain in deterministic mode, and any domain whose manifest row chooses it |
| BeamAsm image | ERTS with BeamAsm, OTP's JIT | every other domain |

*Table 9.3. The three runtime images.*

Which image a domain runs follows from three facts fixed at boot:
whether it is the system domain, one field of its manifest row, and
whether the machine boots in deterministic mode (`erx.det=1`, a mode
whose runs repeat exactly, in which BeamAsm's output would vary with
addresses and hash order). No domain chooses at run time. Both the
interpreter and BeamAsm are **Built**; the manifests in
`config/manifest/` choose the interpreter for every domain
([section 5.1.3](05-overview.md#513-runtime)).

The system domain interprets because it is the trusted base, and its
image holds no JIT and no C++. OTP's own notes put BeamAsm at "anything from no difference to up to four times as
fast" as the interpreter (OTP 29.1.2,
`erts/emulator/internal_doc/BeamAsm.md`). The system domain gives that
up for a trusted base with no code generator to attack.

In a BeamAsm domain, each block of JIT code is a memory object mapped
twice, once writable for BeamAsm and once executable for the processor,
so one page is writable through one mapping and executable through the
other. Only a domain whose image is marked for JIT gets an address
space that allows such objects
(`otp/erts/emulator/sys/erxos/erx_jit_memory.c`).

### 9.5.2 Code by hash

The system domain's **code service** loads modules into the system
domain's runtime by hash: each module is named with the SHA-256 of its
file, and the service checks the bytes against it before ERTS's loader
reads them. A changed byte fails the load with
`{error, {hash_mismatch, Name}}`
([design-runtime.md, Code in the system domain](../design-runtime.md#code-in-the-system-domain)).
The code service and its check are **Built**
(`erlang/apps/erx_code/src/erx_code.erl`).

The system domain's runtime is designed to accept a module only if its
bytes lie in **installed storage**: the pages of its release, or an
arena only the code service writes. It refuses any other with
`{error, not_installed}`, however the binary travelled. That refusal is
designed and not built.

### 9.5.3 Shared code

Every ERTS domain loads its own copy of `lists`, `gen_server` and the
rest of `kernel` and `stdlib`, charged to its own budget; the design
document measures loaded code at about 10 of the 16 MB the system
domain reports at its shell
([design-shared-code.md](../design-shared-code.md)). The design builds
one read-only image of the common modules into the boot image, and
every interpreter domain maps it at the same addresses, so one copy
serves the machine
([design-shared-code.md, The central construction](../design-shared-code.md#the-central-construction)).
The shared-code image is **Designed** and not built.

## 9.6 The C library seam and hosted mode

ERTS is a C program, and it gets memory, threads and the clock from a
C library.

> **Background: a C library, and musl.** The C library gives a program
> `malloc`, `pthread_create` and the rest of the C standard and POSIX.
> On UNIX most of these end in system calls, such as `malloc` in
> `mmap`. **musl** is a small C library written to be read and ported.

### 9.6.1 One seam

musl 1.2.6 lives in erXos's tree as erXos's code and is the C library
of every runtime and native program. No trap instruction is left in
it. Every place where musl would make a system call lands in one
function, `__erx_syscall`, a switch on musl's Linux system-call names
(`SYS_futex`, `SYS_mmap` and the rest) that carries each call onto
`liberx`; a call it does not handle answers `ENOSYS`
([design-fiasco.md, musl over the backend](../design-fiasco.md#musl-over-the-backend)).

| musl needs | erXos gives |
| --- | --- |
| pages for `malloc` | `erx_vm_reserve`, and `erx_space_protect`, which commits what it makes accessible |
| threads | `erx_thread_create`, `erx_thread_exit` |
| locks and condition variables | umtx waits on private memory |
| clocks | Fiasco's clock for `CLOCK_MONOTONIC`, the root's wall clock for `CLOCK_REALTIME` |
| random bytes | `erx_entropy_take` |

This is **Built**. The design deletes the Linux names, so that a call
not ported fails when the program is linked rather than when it runs
([design-runtime.md, The C library seam](../design-runtime.md#the-c-library-seam));
that deletion is designed and not built. A runtime uses no file
descriptor but standard output and error; native programs get files,
pipes and signals from a POSIX layer over `liberx`
([chapter 13](13-native-programs.md)).

The errno and signal numbers musl returns are FreeBSD's, generated from
one table in the ABI and checked against FreeBSD's own
([section 7.3.1](07-one-source.md#731-tables-that-must-match-someone-elses)),
so a program ported from FreeBSD prints the `errno` a FreeBSD user
expects. This is **Built**.

`pthread_cancel` acts at the target thread's next cancellation point,
as POSIX allows: Fiasco's backend does not stop a thread from outside
(`liberx/backend/core/refused.c`). ERTS never calls it.

### 9.6.2 Hosted mode

A crash inside ERTS on QEMU is slow to debug. **Hosted mode** runs the
same runtime as a macOS process, on `liberx`'s hosted backend, under AddressSanitizer,
the other sanitizers and `lldb`
([design-runtime.md, Hosted mode](../design-runtime.md#hosted-mode)).
It is **Built**. QEMU stays the authority: a test that passes only
hosted is not a pass.

A hosted runtime links macOS's libSystem, not musl: each C library
finds its per-thread data through the one processor register that
points at the current thread, and in a macOS process libSystem owns
it. Above the C library nothing differs, and build checks fail on a
file of `sys/erxos` that names `__APPLE__`, Linux or a backend.

## 9.7 Two schedulers you can watch as one

When a domain is slow, which scheduler is to blame? On FreeBSD, `top`
shows the kernel's view and a program's own tools show its view, rarely
both at once. erXos merges them.

### 9.7.1 One timeline

`erx:trace(Spec)`, typed at the Erlang shell, prints one stream of
events in the order of one clock
([design-live.md, Tracing](../design-live.md#tracing)). From ERTS it
takes OTP's own trace of each time an Erlang process is scheduled in
or out. From the root service it takes the **trace ring**, 4,096
records that `liberx` writes as it carries out parks, wakes and
doorbell deliveries
([design-fiasco.md, The trace ring](../design-fiasco.md#the-trace-ring)).
The trace process merges both in time order
(`erlang/apps/erx/src/erx_trace.erl`). It is **Built**.

So one stream shows an executor of the system domain park, the
dispatcher deliver a doorbell, the executor wake, and the Erlang
process that ran next. Only the root's own threads write the ring, so
a park in another domain does not appear, though that domain's process
events do.

### 9.7.2 A worked example

A file service runs in domain A. Session B runs a build that reads
thousands of small files; session C runs an editor whose user has
pressed save. Each session has a lane into A, and in A a **facet**
process, which receives that session's requests and checks them
([section 7.7](07-one-source.md#77-the-system-manifest-the-machines-configuration-checked);
[design-scheduler.md, A worked example](../design-scheduler.md#a-worked-example)).

1. B's processes send read requests as fast as they can. When B's lane
   is full, B's senders wait inside B's own runtime, so A is asked for
   no more than the lane holds.
2. A's executors run B's facet and the processes that serve B's reads.
   That time is A's, on A's threads: A pays for the work it does for
   B.
3. C rings its doorbell. A's dispatcher lists it and wakes a parked
   executor of A; if every executor is running, one finds it at its
   next safe point.
4. A's ERTS runs C's facet beside B's, sharing A's executors by priority
   and reductions. C's request is decoded within a few of A's
   scheduling rounds, not behind B's whole backlog, because that
   backlog waits in B's lane, not in A's run queues.
5. If all of A's threads are busy, A takes turns on its processor with
   every other ready thread; nothing lends A the time of B or C.

The design adds two parts. Bands order A, B and C by their manifest
rows. And each facet admits its client's requests within a **share**
of reductions per period, so B's facet stops taking requests once B's
share is spent, while C's are taken at once
([design-scheduler.md, Service work](../design-scheduler.md#service-work)).
Both are designed and not built: a facet admits each request whose
operation it lists (`erlang/apps/erx/src/erx_facet.erl`).

## 9.8 What happens when a part fails

Each level fails in its own way, and each failure stays where it
started.

**An Erlang process loops.** Its reductions run out at the end of its
turn, and ERTS runs the next process. Other domains do not see it.

**A NIF loops, or an executor blocks.** C code called from Erlang is
not counted in reductions, and a NIF that waits on a server blocks its
executor. Either way that executor runs no Erlang process until the
call returns, and the domain's other executors steal its queued
processes. Only its own domain is affected. A long C call belongs on a
dirty scheduler, as on stock ERTS
([section 3.5.4](03-erlang.md#354-bifs-nifs-and-ports)).

**A domain spins.** Its threads take turns with every other thread on
their processors, at one priority, so other domains slow down but run.

**An executor dies.** The park protocol's *release* event frees the
slot, advances the group's epoch and wakes the longest-parked
executor, so a wakeup meant for the dead one is not lost with it.

**A domain ends.** Its runtime writes a dump to the domain's crash area
and stops the domain. Every thread of every task ends with it, its
group and park record end with it, and the processes linked to its
processes get exit signals
([design-runtime.md, Crash handling](../design-runtime.md#crash-handling)).

**The machine stalls.** Once a second the watchdog thread, at priority
255, checks that the root service has reported in; a missed report
resets the machine. On the Raspberry Pi 4 it also reloads the hardware
watchdog, so a hang of Fiasco itself ends in a reset
([design-fiasco.md, The watchdog](../design-fiasco.md#the-watchdog)).

## 9.9 Design choices

**Every Erlang process a kernel thread.** The kernel could schedule
each Erlang process itself, as a 1:1 thread library does. But every
spawn would be a request to the root and every switch a kernel entry.
Erlang processes are cheap because they never enter the kernel
([section 4.2.1](04-history.md#421-two-answers-both-tried)).

**Scheduler activations.** The kernel could tell the runtime whenever
one of its threads blocks. That needs the kernel to enter the runtime
at an arbitrary point, and every system that tried it for general C
code gave it up
([section 4.2.2](04-history.md#422-the-common-failure)). ERTS does not
need it, because an Erlang process never blocks its thread: a
`receive` with no message parks the process, and the executor runs
another.

**Shares instead of priorities.** Fiasco could give each domain a
share of processor time, as FreeBSD's `rctl` can cap a jail's CPU use
at a percentage of one core (`rctl(8)`, the `pcpu` resource). That
needs a scheduling class Fiasco does not have, a large change to its
scheduler, accounting and switch path
([design-fiasco.md, The scheduler on Fiasco](../design-fiasco.md#the-scheduler-on-fiasco)).
Bands give an order between domains for one number each; the cost is
that a busy domain in a high band can starve every lower one on its
processors.

**Lending time to a service.** Some kernels let a client donate its
processor time to the server working for it, as seL4's passive servers
run on their callers' time and some L4 kernels donate a time slice
with a call
([research-hierarchical-scheduling.md](../research-hierarchical-scheduling.md)).
erXos does not: a service runs on its own threads, and nothing must
work out who pays. The price is that a saturated service slows all its
clients together
([section 5.6.5](05-overview.md#565-shared-services-and-shared-cpu)).

**Stock ERTS on a POSIX layer.** erXos could give ERTS a full POSIX
emulation and leave ERTS untouched. Every wakeup would then pass
through an emulated `poll`, and erXos would carry two models of
readiness. erXos judges some seventy
numbered edits to ERTS cheaper to maintain than an emulation of the
system ERTS was written for.

## Summary

Every Erlang process is a process of the system. Fiasco runs every
thread but the watchdog at one priority, round robin, and a domain's
executors share one processor; bands, CPU sets and thread limits are
designed. Executors only park, workers may block, and a park against
two epochs cannot lose a wakeup. ERTS keeps its scheduler and replaces
its sleep and readiness with `erx_park` and an event table. The system
domain interprets; musl reaches `liberx` through one function; the
same runtime runs hosted on macOS; and `erx:trace` shows both
schedulers in one timeline.

The scheduler decides which thread runs; the next chapter turns to
where those threads live, the domain, and the wall around it.

## Where to read next

* [design-fiasco.md, The scheduler on Fiasco](../design-fiasco.md#the-scheduler-on-fiasco):
  the scheduler design on Fiasco, the bands and the park protocol.
* [design-scheduler.md](../design-scheduler.md): the full two-level
  design.
* [design-runtime.md](../design-runtime.md): ERTS on erXos, from the
  adapter and the event table to BeamAsm, the C library seam and hosted
  mode.
* [research-hierarchical-scheduling.md](../research-hierarchical-scheduling.md):
  the record of M:N threading and why it was abandoned.
* Thomas Anderson, Brian Bershad, Edward Lazowska and Henry Levy,
  "Scheduler Activations: Effective Kernel Support for the User-Level
  Management of Parallelism", SOSP 1991: the design whose failure the
  runtime contract answers.
* OTP 29.1.2, `erts/emulator/internal_doc/BeamAsm.md`: BeamAsm and its
  speed against the interpreter.
