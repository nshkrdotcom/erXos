# erXos on Fiasco

erXos's first release runs on Fiasco, with every user feature, and erXos's own kernel replaces it
later behind the same interface. Fiasco is a kernel target erXos ships on, not only a stand-in for
development: `liberx`'s Fiasco backend uses Fiasco's own mechanisms wherever Fiasco has them, and
what Fiasco does not give is a short list of downsides of running on Fiasco against erXos's kernel,
stated to users, not engineered around.

One construction carries the document: **the root creates and places, Fiasco checks every use.**
The root service is the only creator of kernel objects and the only writer of any task's object
space and page tables. It creates each domain's objects through that domain's own Fiasco factory,
records what it made, and places a capability into the holder's object space at a slot it picks,
with the Fiasco rights that erXos's rights for that holder allow. Every use of a placed object (a
doorbell's trigger, a wait, a semaphore, an interrupt's acknowledgement) is the holder's own Fiasco
invocation of its own slot, which Fiasco checks; the root is not on that path. A handle is the slot
index.

[design-stopgap.md](design-stopgap.md) is the backend's detailed design: its call table, boot
handoff, memory, threads and the rest. This document says what changes in it for a release, why
the result is safe to ship, and what a release on Fiasco promises. Paths of Fiasco's kernel
sources are relative to `fiasco/kernel/src/kern/`; nothing here rests on `kobject_rpc.h` or
`jdb_object.cpp`, which no erXos document or agent reads.

## Contract

The rules, verbatim:

> The reason I'm asking is that kernel takes a lot of time to build and harden, and maybe we can
> ship the first version of OS on Fiasco with all the user features on it before rewriting the
> kernel

> yeah why don't we just use fiasco capabilites and lose generation assurances when we are on
> fiasco vs our own kernel?

> That is why don't we reframe fiasco limits as just downsides of running on fiasco versus ours
> rather than trying to work around these issues?

and, on the scheduler:

> So a first release on Fiasco could ship with the cooperation pieces, and add guaranteed shares
> later as a Fiasco scheduler variant over our own core, or wait for our kernel. -- sounds good.
> I'd defer cooperation pieces too after everything else works. It does not seem urgent and more
> of an optimization

From them:

* **A release on Fiasco promises**, for every domain, trusted or not: isolation of each domain's
  memory and capabilities by Fiasco's address spaces and object spaces; rights that only shrink;
  a deleted object gone for every holder at once; memory budgets as hard walls, user pages and
  kernel memory both; device memory access confined by the IOMMU where the platform has one;
  writable and executable never together in one mapping; the results of
  [the call table](design-stopgap.md#the-call-table) as this document amends them; and the
  user-mode guarantees that do not rest on the kernel (the funnel, the facets, the file servers,
  the vault, image hashes, package signatures), which hold as on erXos's kernel.
* **It does not promise** what [Downsides against erXos's kernel](#downsides-against-erxoss-kernel)
  lists. Each row is a property erXos's kernel has and Fiasco lacks, the consequence a user or an
  app sees, and what closes it. Nothing in this backend rebuilds one of those properties in user
  mode.
* **It patches Fiasco** only where a release needs a property Fiasco lacks and the patch is small
  and contained: [The release's Fiasco build](#the-releases-fiasco-build) lists them.
* **The interface does not move.** Every caller of `liberx` calls the functions generated from
  `abi/erx_abi.txt`. Where a Fiasco release answers a call differently from erXos's kernel,
  [The interface on Fiasco](#the-interface-on-fiasco) says so per call.

## What the code does today

The backend of [design-stopgap.md](design-stopgap.md) mediates every call. The root task holds every
Fiasco capability; another task holds only its gate to the root and its threads' semaphores
([Capabilities in Fiasco's object space](design-stopgap.md#capabilities-in-fiascos-object-space)).
Callers hold handles, indices into a table the root service keeps, each naming a record and its
generation; handles carry no rights. A doorbell's trigger and an interrupt's acknowledgement are
requests to the root, "so a doorbell costs one service round trip at its ringer"
([Interrupts and readiness](design-stopgap.md#interrupts-and-readiness)). Budgets are records with
nothing charged against a cap, and every kernel object comes from the root's own factory, so one
domain can spend kernel memory every other domain needs. Every thread but the watchdog runs at
Fiasco's priority 1 ([Scheduling](design-stopgap.md#scheduling)). Fiasco builds with its debugger on
by default (`src/Kconfig:773-775`), and every kernel build compiles the GPL-2.0 `kobject_rpc.h`,
which `task.cpp`, `ipc_gate.cpp`, `irq.cpp`, `icu_helper.cpp`, `pi_mutex.cpp` and
`arm/smc_user.cpp` include, so no build may be distributed
([design.md](design.md#dependencies)).

## The construction

### Who holds what

No task but the root holds a capability to a task, a factory, a thread or the scheduler, its own
included, so no task can write any object space or page table, its own included. The root holds
one capability with Fiasco's delete right to every object it creates, so no object dies by
reference count before the root deletes it.

| erXos object | Fiasco object | Created by the root through | Placed in the holder with | The holder's own use |
| --- | --- | --- | --- | --- |
| a doorbell, a device line | an IRQ object (`Irq_sender`) | the owning domain's factory | trigger and acknowledgement only: no special right, so `sys_bind` and `sys_detach` refuse (`irq.cpp:1104-1137`); the root alone binds | `l4_irq_trigger`; the line's `l4_irq_unmask` |
| a thread's wait object | a semaphore | the thread's domain's factory | the rights `l4_semaphore_up` and `_down` take | umtx, park and the reaper, as today |
| a task's request gate | an IPC gate bound to the root service | the task's domain's factory | the send right, at `L4_BASE_PAGER_CAP` | every service call and fault, as today |
| a thread | a thread | the domain's factory, started by the root through the scheduler with its domain's band and CPU set | nothing: no task holds a thread capability | none |
| a space (a domain's task, a sub-space) | a task | the domain's factory | nothing | none |
| a budget | a factory for the domain's kernel memory, and the root's page record for its user pages | the parent budget's factory | nothing | none |
| a memory object, a mapping | pages of the root's pool, mapped by flexpage | the root's pool; page tables charged to the task's factory | a mapping at the rights the call allows, never writable and executable | loads and stores |
| a device's DMA window | a DMA space | the device domain's factory | nothing: the root maps pages into it and binds the device's stream to it | the device's own accesses |

So the root's records of what sits in each slot, and of what each task maps, are true by
construction: only the root writes them, and the root writes its record with each write. A Fiasco
map into an occupied slot empties it first (`map_util-objs.cpp:110-114`), so no slot holds two
things.

One object every thread reaches without a slot is itself: Fiasco resolves the special selector to
the calling thread with full rights (`Obj_cap::deref`, `thread_object.cpp:61-73`). A thread can
therefore change its own registers, its own pager and exception handler, and its own vCPU state.
Each of those names other objects only through slots of its own task, which hold nothing but what
the root placed, so the worst a thread does with itself is point its faults at an object that does
not answer them and stop: it harms only its own domain, which the root sees when the thread no
longer answers or its space ends.

### Handles are slots

A handle is the index of a slot in the caller's own object space. The root picks the index when it
places the capability and records, per task and slot, the object, its kind and the erXos rights of
this holder. A service call that names a handle is decoded through that record; a direct use is a
Fiasco invocation of the slot itself.

The root frees a holder's slot only when that holder closes the handle. When an object is
destroyed, Fiasco removes it from every holder's object space, the slots stay reserved, and every
later use answers `ERX_ESTALE`: a direct use gets Fiasco's answer for an empty slot, which the stub
maps to `ERX_ESTALE`, and a service call finds the record marked dead. A handle used after its own
holder closed it names whatever the root places in that slot next. That is the holder's own bug, and
the generation guarantee it loses is the first row of the downsides.

### Rights

erXos's rights per type are recorded by the root per slot, so every service call checks them
exactly; Fiasco's rights on the capability enforce every direct use. A duplicate or a pass
intersects the source's erXos rights with the mask, and maps the capability with the Fiasco rights
those allow, which Fiasco masks again against the source, so rights only shrink twice over. For the
objects domains use directly, Fiasco's bits express what erXos's do: an IRQ object's `BIND` is
Fiasco's special right, and `TRIGGER` is holding the capability at all, since trigger and
acknowledgement take no right (`irq.cpp:1149-1180`). Pass sets are checked by the root at each pass,
and only the root passes.

### Deletion

`erx_object_destroy` is the root's delete through its delete right, after which Fiasco's object
deletion removes the capability from every holder at once; a memory object's destroy unmaps its
pages from every space through Fiasco's mapping database. Ending a domain deletes every object the
root's records charge to its budget, and then its factory, as the root's list walk does today
([Deletion](design-stopgap.md#deletion)).

### Memory and budgets

Each domain budget is a wall at its guarantee, in two parts that Fiasco and the root each hold:

* **Kernel memory** is a Fiasco factory carved from its parent's at the budget's creation, with the
  kernel-memory figure of the domain's manifest row. Fiasco charges the child's whole limit to the
  parent at creation (`factory.cpp:81-86`), so the limits are a hard partition, and charges every
  task's page tables, capability tables and kernel-user pages to the factory the task was created
  from (`space.cpp:69-99`, `obj_space_phys_util.cpp:163,226`). When a domain's factory is spent,
  the root's next creation or map on its behalf fails and the call answers `ERX_ENOMEM`; no other
  domain is touched.
* **User pages** come only from the root's pool, since the root alone maps memory, and are charged
  to the budget's page record, which refuses a charge past the budget's cap. A domain budget's cap
  equals its guarantee.

### Threads, bands and stops

The root creates every thread, so it knows every thread of every task. Each domain's manifest row
names a priority band and a CPU set; the root starts each thread at its band's priority and within
its CPU set through `l4_scheduler_run_thread`, which takes the priority, the quantum and the CPU set
(`scheduler.cpp:63-110`) and checks nothing about the caller beyond its holding the scheduler. The
root counts a domain's threads across its tasks against the domain's thread limit, and a create past
it answers `ERX_ELIMIT`. This is L4Re's own shape: ned gives each program a scheduler proxy that
restricts its threads to a CPU set and to a range of priorities, `prio_offset` to `prio_limit`
([L4Re's ned documentation](https://l4re.org/doc/l4re_servers_ned.html), "Control scheduling",
fetched 2026-11-15, SHA-256 `57b4c33485cf6a8ea404fd4471d4250eb62c2f57268cd5b4f7eb7e5a8eacb06f`).
The scheduler is in [its own section](#the-scheduler-on-fiasco).

The root sets every thread's pager and exception handler to the task's gate. A thread may repoint
its own through the self selector, but only at slots of its own task, so its faults reach the root
or no one, and a thread whose faults reach no one stops itself alone. A whole-space
pause, which `fork`'s copy and job control need
([design-programs.md](design-programs.md)), is the root stopping each thread of the space in turn by
an artificial exception (`L4_THREAD_EX_REGS_TRIGGER_EXCEPTION`, `thread_object.cpp:657`) whose
fault message the root does not answer until the resume, which is how a Fiasco task's manager acts
on its threads; the pause returns once every thread has arrived at the gate.

### Devices

Fiasco carries DMA spaces behind the IOMMU (`dmar_space.cpp`, the QEMU `virt` binding in
`arm/bsp/virt/iommu-arm-smmu-v3-virt.cpp`) and MSIs through its interrupt manager
(`irq_mgr_msi.cpp`). The root creates a DMA space per confined device in the device domain's
factory, maps the device's buffers into it at the addresses `erx_mem_dma_addr` reports, and binds
the device's stream to it; the device reaches nothing else. An MSI is an IRQ object the root binds
at the interrupt manager and places in the driver's domain like any line. A platform with no IOMMU
for a device runs that device unconfined, as on erXos's kernel: a property of the hardware, not of
the kernel, and the manifest check refuses such a device to any domain but the one the manifest
gives it alone.

### What the root still serves

Creation, placement, passing, closing and deletion; every map, protection change and fault of
memory; budgets and groups as records; thread creation, start, affinity and stops; the boot
handoff, the log, entropy, the time page and the watchdog; and the policy of the system domain
above them. As in L4Re, where `moe` serves memory and faults while programs invoke kernel objects
themselves, a domain's steady-state traffic (doorbells, waits, its own memory) does not reach the
root; its setup does.

## The interface on Fiasco

Only the calls whose result differs from erXos's kernel are listed; every other row of the call
table gives erXos's kernel's result on a release.

| Call | On a Fiasco release | erXos's kernel |
| --- | --- | --- |
| any call naming a handle the caller closed | names whatever the root placed in that slot since | `ERX_ESTALE` |
| `erx_budget_create`, `_resize` | a domain budget's cap equals its guarantee; its kernel-memory part is fixed at creation, so a resize changes the user-page part alone and `ERX_ENOTSUP` answers a change of the kernel-memory part | caps above guarantees, borrowing, resize of the whole |
| `erx_object_destroy` of a budget | the root deletes every object charged to it, then its factory | one kernel destruction |
| `erx_group_configure` | grants stored and reported, not enforced; band and CPU set come from the manifest | grants enforced |
| `erx_thread_set_urgency` | `ERX_ENOTSUP`, as on the stopgap (`liberx/backend/core/refused.c`) | the urgency within the group's ceiling |
| `erx_trace_read` | the kernel's ring `ERX_ENOTSUP` | each CPU's kernel ring |
| gate messages and rendezvous passing | `ERX_ENOTSUP`: capabilities move only by the root's `erx_cap_pass` | supported |
| `erx_umtx_wait`, `_wake` on a word shared between spaces | `ERX_ENOTSUP` | across spaces |
| a blocking call from an executor | `ERX_EWOULDBLOCK` from `liberx`'s stub, which the domain's own code can bypass | refused by the kernel's dispatch |

## Downsides against erXos's kernel

Each row is a property of erXos's kernel that a release on Fiasco does not have. The "what would
be lost" column of the [L4 lineage](design-kernel.md#l4-lineage) gives the mechanism; this table gives
what a user or an app sees. Release notes and the user documentation carry it.

| Property on erXos's kernel | On Fiasco | What it means | Closed by |
| --- | --- | --- | --- |
| a stale capability never names another object (K1) | a handle used after its holder's own close names the slot's next object | a bug in a domain's own handle use can act on its own other objects; it reaches nothing it was not given | erXos's kernel |
| budgets with caps above guarantees, borrowing, and every charge returning at once (K3, K32) | every domain budget is a wall at its guarantee; kernel memory is fixed per domain at creation | a program is refused while its session has memory free in another part, or is sized at its largest; an app's elastic budget is its guarantee | erXos's kernel |
| CPU grants to runtime groups, quotas charged up the group tree, own-group charging | per-domain priority bands, CPU sets and thread limits | a domain spinning at its band's top takes its CPUs from every lower band and shares its band round robin in proportion to its threads; CPU use per domain is reported as unsupported; M10's "one runs out of CPU alone" holds between bands, not within one | stage 5 of [the scheduler](#stages-beyond-bands), or erXos's kernel |
| the cooperation ladder: status words, deferred preemption, published urgency, group park in the kernel, capacity advice the kernel stands behind | none in the first release; park and wake through semaphores and a dispatcher thread per task, as today | ERTS behaves as stock BEAM does on a general-purpose kernel: it spins briefly and backs off on a lock whose holder is preempted, and wakes go through one more thread switch | stages 1 to 4, or erXos's kernel |
| a kernel call runs on the caller's own thread and is charged to its own group, so what one domain makes another spend is bounded and declared | setup, faults and every service call run on the root service's one thread, at the root's band | an app flooding the root with requests or faults takes CPU from every lower band on the root's CPU and delays every other domain's setup and faults; isolation of memory and capabilities rests on the root's decoder and placement code as well as on Fiasco | erXos's kernel |
| the executor rule refused by the kernel | refused by `liberx`'s stubs | a runtime that bypasses `liberx` can stall its own executors, harming only itself | erXos's kernel |
| a whole-space hold that every call it started runs out under (K30) | the root stops each thread by an artificial exception | `fork` and job control work; a thread inside a long kernel call stops when that call returns or is cancelled, as Fiasco's exception delivery decides | erXos's kernel |
| a stop's bounded finishing path, exit records from the kernel (K18, K28) | the root ends trees and posts exit records, as today | an exit record arrives when the root's walk completes, with no bound under hostile load | erXos's kernel |
| a kernel built under erXos's construction rules: the stack proof, recursion only through `musttail`, the kernel chokepoint checks, generated register access, a generated kernel ABI, once-only reads of every user-writable field | Fiasco's C++, its 8 KiB thread block measured by the conformance suite's watermark (`kernel/stack_fiasco.txt`), never proven | a Fiasco defect reachable from a domain's capabilities can break isolation; the fuzz campaign and the upstream watch are the defence | erXos's kernel |
| rendezvous passing and gate messages between domains | refused | native servers in other domains are reached through connections only | erXos's kernel |
| umtx across spaces | within a space | no futex in memory shared between programs | erXos's kernel |
| the kernel's trace ring, entropy, watchdog and deterministic mode at the kernel's level (K19, K31) | the root's, in user mode | the inspector's kernel row is unsupported; a Fiasco hang is caught only by the board's hardware watchdog | erXos's kernel |

## The scheduler on Fiasco

The two-level scheduler of [design-scheduler.md](design-scheduler.md) splits cleanly. Its runtime
half, ERTS's own scheduler (L2) and the runtime contract, needs nothing from the kernel beyond
threads, park and wake, and runs on Fiasco unchanged. Its kernel half (L1) maps onto Fiasco as
follows.

| Mechanism of design-scheduler.md | On Fiasco in the first release |
| --- | --- |
| ERTS's run queues, priorities, reductions, stealing (L2) | unchanged |
| park and wake, epochs, the group's ready list ([Park and wake](design-scheduler.md#park-and-wake)) | the backend's park protocol over a semaphore per thread and a dispatcher per task ([The park protocol](design-stopgap.md#the-park-protocol)), unchanged; doorbells are triggered directly |
| urgency per executor ([Urgency resolution](design-scheduler.md#urgency-resolution)) | the thread's Fiasco priority, fixed at its start from its domain's band; `erx_thread_set_urgency` refused |
| ready queues by urgency, round robin within a level | Fiasco's fixed-priority scheduler: priorities 1 to 255, round robin within a level, a quantum per thread (`sched_context-fixed_prio.cpp`) |
| quotas and charging up the group tree ([Charging and quota](design-scheduler.md#charging-and-quota)) | none: Fiasco charges a thread's own scheduling context only |
| deferred preemption ([Deferred preemption](design-scheduler.md#deferred-preemption)) | none |
| status words and capacity ([Status words and capacity](design-scheduler.md#status-words-and-capacity)) | none; capacity is the configured advice in the status page, which nothing in the kernel stands behind |
| executor class enforcement ([Executor class enforcement](design-scheduler.md#executor-class-enforcement)) | `liberx`'s stubs |
| placement and affinity | the CPU set of the domain's band, through `l4_scheduler_run_thread` |

### Bands

A band is a run of Fiasco priorities a domain's threads start in, from its manifest row. The first
release needs one priority per band, since nothing changes a thread's urgency; the bands are, from
the top: the watchdog at 255 as today; the root service; the system domain; the driver and device
domains; interactive domains (the display, web and session domains); and apps and programs, with
background work below them. A spinning domain therefore delays only its own band and those below,
and the system domain, drivers and the display keep running under any app's load.

### Stages beyond bands

Each stage is a contained change to the Fiasco fork, as CLAUDE.md allows for kernel objects and
scheduler hooks that integrate with Fiasco's C++, with the policy in erXos's C17 cores so it moves
into erXos's kernel. The sizes are estimates from the files named and are unverified.

| Stage | What it adds | Where in Fiasco | Estimate |
| --- | --- | --- | --- |
| 1, status words | each executor's state, CPU and preemption count written by Fiasco into a kernel-user page beside the UTCB, as Fiasco places a vCPU state area (`thread_object.cpp:578`) | the switch path (`Context::switch_sched` and `schedule`, `context.cpp:887-986`, of a 2,949-line file) | 150 to 300 lines of C++ |
| 2, deferred preemption | at a slice end with another thread ready, a bounded grace while the executor's `defer` count is raised; never for a higher-priority wake | `Timeslice_timeout::expired` (`timeslice_timeout.cpp:36-48`, a 49-line file) | 50 to 150 lines |
| 3, urgency within a band | a store the runtime makes, read at the thread's next transition, or a scheduler capability bounded to a band | `Scheduler::sys_run` (`scheduler.cpp:63-110`) | 50 to 200 lines |
| 4, group park | the group's ready list and epochs in the kernel, removing the dispatcher's thread switch | a new kernel object beside `Irq_sender` | 300 to 600 lines, with the park core |
| 5, group quotas | charging up the group tree across CPUs, as a new scheduling-context variant beside the fixed-priority one, which Kconfig's scheduler choice selects (`src/Kconfig:330-351`) | the fixed-priority variant is `sched_context-fixed_prio.cpp` (321 lines), `sched_context.cpp` (188) and `ready_queue_fp.cpp` (171); the six variant and queue files total 1,450 lines | 1,500 to 3,000 lines, with its policy in `kernel/sched/sched.c` (676 lines today, the C0 core) |

The first release ships bands alone. The stages follow it in the order 1, 2, 4, 5, once everything
else works, each kept only when its measurement pays, as [plan.md](plan.md)'s M8 keeps each feature
of the ladder. Stage 3 waits for a consumer or for the urgency-change rate of
[todo-performance.md](todo-performance.md) to show that bands alone cost latency. Each stage that
lands removes its row's part of the downsides table.

### Consumers that name grants

No Phase 1b consumer needs a grant enforced to work. Those that name one get, on a release:

* [design-apps.md](design-apps.md) (a hostile app "can spend its session's budget and CPU grant"):
  its memory is held to the budget; its CPU to its band, CPU set and thread limit.
* [design-domains.md](design-domains.md): the hostile runtimes' bounds on CPU grants and on an innocent
  peer's latency report `unsupported`, as on the stopgap, and the band test of
  [Verification](#verification) checks what bands give.
* [design-network-fastpath.md](design-network-fastpath.md): the network domain runs as many
  schedulers as its CPU set has CPUs, at most 32.
* [design-programs.md](design-programs.md) and [design-display.md](design-display.md): a program's
  copy and an application's drawing run on their own domain's threads, in its band.

## Security on Fiasco

### What a hostile app can do

An app is a domain whose code is untrusted. It holds its gate to the root, its threads'
semaphores, the doorbells of its connections, with trigger alone on its peers', and mappings of
its own memory and its connections' rings. With them it can:

* send the root any request: the decoder is the trust boundary, bounds every field and has its
  fuzz target, and a handle the root did not place for this task is `ERX_ESTALE` or `ERX_ETYPE`;
* write anything into its own side of a ring: the receiving funnel checks every frame, as on
  erXos's kernel;
* trigger a peer's doorbell as often as it likes: a fire not yet received is one delivery
  (`irq.cpp:984`, [Interrupts and readiness](design-stopgap.md#interrupts-and-readiness)), so the peer
  pays at most one wake per take;
* spend its own memory and kernel memory to their walls, and fail with `ERX_ENOMEM` there;
* spin every thread it may create at its band's priority, the scheduler row of the downsides;
* send requests and take faults as fast as its threads can, which the root service serves on its
  own thread at the root's band, above the system domain and the drivers: the root's time spent
  on them is taken from every band below it on the root's CPU, and every other domain's setup and
  faults wait behind them, the root-load row of the downsides;
* invoke every slot index of its object space with any arguments, and itself through the special
  selector, reaching only Fiasco's code for the objects placed there, for empty slots and for its
  own threads: this is the surface the fuzz campaign covers.

It cannot reach another domain's memory or objects without a Fiasco defect, create a mapping that
is writable and executable, change any object space or page table, bind or steal a peer's doorbell,
or hold a device unless the manifest gives it one.

### The security closure

The security closure is the point from which a release build may run untrusted code. It has two
forms, one per kernel, and the first release reaches the first.

* **On Fiasco**, within [plan.md](plan.md)'s R1: M11's scope wherever it does not name erXos's
  kernel (the funnel and the services behind it, the vault, image hashes, packages, the host link,
  every user-mode fuzz target at full budget, the sanitizers on host builds, the external review),
  and in place of its kernel half: the release's Fiasco build of the next section; the system-call
  fuzz campaign at its full budget with no open finding; the hostile suites' Fiasco set below; the
  upstream watch current; the IOMMU confining every device it can on the platform, and each
  unconfined device in a domain of its own; and this document's downsides published with the
  release.
* **On erXos's kernel**, M11 as written: every hostile suite in full and every guarantee of
  [design-kernel.md](design-kernel.md).

| Hostile case | Fiasco | erXos's kernel |
| --- | --- | --- |
| frames at every funnel: verdicts, forged senders and names | runs | runs |
| reach into another domain's memory or objects | runs | runs |
| a destroyed object's handle in every holder | runs: `ERX_ESTALE` | runs |
| a handle used after its own close | runs, expecting the next object (the recorded difference) | runs: `ERX_ESTALE` |
| rights only shrink across duplicates and passes; a ringer cannot bind | runs | runs |
| memory and kernel-memory walls, a neighbour unaffected | runs | runs, with borrowing and returns |
| doorbell floods | runs | runs |
| sub-space churn | runs | runs |
| a spinning domain against a higher band's latency | runs | runs as the grant test |
| a request and fault flood against a neighbour's setup and latency | `unsupported` | runs |
| CPU grants and an innocent peer's latency within one band | `unsupported` | runs |
| stops and exit records under hostile load | `unsupported` | runs |
| DMA outside a device's window | runs where the platform has an IOMMU | runs where the platform has an IOMMU |
| the kernel's own call surface fuzzed | Fiasco's invocations | erXos's dispatch |

## The release's Fiasco build

**Configuration.** The release build turns the debugger off, so no `jdb_object.cpp` and no
capstone are compiled, keeps the fixed-priority scheduler, and turns off every option with no
consumer; `tools/lib/erx/fiasco_config.rb`'s check holds the release configuration as it holds the
development one, and a release build that turns the debugger on fails it. Development builds keep
the debugger.

**Patches.** Each is small, contained in the fork, and carries a test with a seeded failure:

* **The clean-room interface header.** An erXos-authored, BSD-2-Clause header replaces
  `kobject_rpc.h` in every build. It is written from what the MIT files that include it call and
  from the IPC layouts of `l4sys` (MIT); no one reads the GPL header to write it, and no agent that
  has read it writes it.
* **Writable or executable.** Fiasco's map refuses a user mapping that would be writable and
  executable at once, so the property stops resting on the root's code alone (an estimate of tens
  of lines, unverified).

Nothing else of erXos's kernel is built into Fiasco for the first release; the scheduler's stages
come after it.

**License.** With the header replaced and the debugger off, the shipped kernel is Fiasco's MIT code
and erXos's BSD-2-Clause additions. `bootstrap` and `sigma0` ship under the link closure their
import records (`fiasco/bootstrap/ORIGIN.md`, `fiasco/l4re-core/ORIGIN.md`), and a release build
check fails if any file compiled or linked into the image's kernel, `bootstrap` or `sigma0` is
recorded with a license that is not permissive; the check counts headers, since `kobject_rpc.h`
is one. The one allowed exception is the cross compiler's `stdarg.h`, `stdbool.h` and `stddef.h`,
GPL-3.0-or-later WITH GCC-exception-3.1 ([design.md](design.md#dependencies)): they define only
macros and types, and the exception lets Target Code that GCC generates with them be conveyed
"under terms of your choice" (`COPYING.RUNTIME`, section 1, of `aarch64-elf-gcc` 16.2.0, SHA-256
`9d6b43ce4d8de0c878bf16b54d8e7a10d9bd42b75178153e3af6a815bdc90f74`), so the check allows exactly
those three files, by name and hash, and only when GCC builds Fiasco. A
release therefore pins the `aarch64-elf-gcc` release that builds Fiasco beside the LLVM release
that builds the rest. Fiasco's notices go into `NOTICES` like every other third-party component's
([design.md](design.md#licenses-and-notices)).

## Upstream security fixes

Fiasco stays erXos's code, changed by ordinary edits, but a release on it tracks upstream for
security: a review of Kernkonzept's `fiasco` repository since the imported commit, monthly,
decides for each commit that touches the kernel whether it fixes a defect reachable in erXos's configuration. A
reachable fix is backported as an ordinary commit with a regression test where Fiasco's own commit
lacks one, and `fiasco/kernel/ORIGIN.md` records the last upstream commit reviewed. A Fiasco
defect found by erXos is fixed in the fork and reported to the address in
`fiasco/l4re-core/SECURITY.md`.

## Verification

**One test set, two kernels.** The function-API set, `test/guest/function_api`, and Track K's
conformance suite run on both, as [design-stopgap.md](design-stopgap.md#verification) says; each case
whose answer differs is one row of [The interface on Fiasco](#the-interface-on-fiasco), and a
difference not listed there is a bug in one backend.

**The system-call fuzz campaign.** A test domain on a release build invokes every slot index of its
object space, the empty ones included, with random operations, words and typed items, from many
threads at once, and checks after each run that the root and a neighbour domain answer and that no
memory outside the domain changed. It runs on QEMU under HVF and TCG at a budget the milestone
gate sets; a crash or hang of Fiasco is a HIGH finding and its input joins the corpus.

Each test below names the seeded failure that proves it ran:

| Test | Passes when | Seeded failure it must catch |
| --- | --- | --- |
| destroyed handle | after a peer's destroy, a holder's trigger and its service call both answer `ERX_ESTALE` | the root frees the holder's slot at the destroy and places a new doorbell there |
| trigger-only doorbell | a ringer's bind of a peer's doorbell answers `ERX_ERIGHTS` | the root places the ringer's capability with Fiasco's special right |
| rights shrink | a duplicate with a narrower mask cannot do what the mask removed, directly or by a service call | the root maps the source's Fiasco rights unmasked |
| delete revokes everywhere | three holders' uses fail after one destroy | the destroy unmaps the root's own slot instead of deleting |
| memory wall | a domain allocating past its budget gets `ERX_ENOMEM` while a neighbour still allocates | the root's page charge skips the cap |
| kernel-memory wall | a domain making doorbells until its factory is spent gets `ERX_ENOMEM`, and the root and a neighbour still create objects | the root creates from its own factory |
| no task capability | a probe of every slot of a domain finds no task, factory, thread or scheduler | the root places the domain's own task capability |
| direct doorbell | a ring and its wake make no request to the root (the root's request count is unchanged) | the trigger stub sends a request |
| band | a domain spinning every thread delays a higher band's echo by no more than one quantum | the spinning domain placed in the higher band |
| thread limit | a create past the domain's limit answers `ERX_ELIMIT` | the count skips a sub-space's threads |
| whole-space pause | a paused space's write counter stops advancing until the resume | the root skips the last thread it created |
| DMA confinement | a device's access outside its window is refused and reported | the whole pool mapped into the DMA space |
| writable or executable | a request for such a mapping fails at Fiasco's map | the patch's check removed |
| release licenses | the release image's link closure is all permissive | a release build with the debugger on |
| the fuzz campaign | it runs its budget clean | a fork build with one bound removed in an IRQ object's bind finds a crash within the budget |

## Measurements

Each is taken with `tools/erx bench` before and after the change, with the host, accelerator,
QEMU version, compiler, flags, workload and baseline recorded as CLAUDE.md requires:

* **a doorbell from ring to wake**, between two domains: a root round trip and a trigger today, a
  direct trigger after;
* **a service round trip**, the null request, to price what stays in the root;
* **a connection's setup** by the domain library: its creations, placements and maps, since they
  move through domain factories;
* **the urgency-change rate**: how often ERTS would change an executor's urgency under the G5
  workloads, which decides stage 3 ([todo-performance.md](todo-performance.md));
* **lock-holder preemption without stage 2**: ERTS's spin time on its own locks with several
  domains on one CPU, which prices stages 1 and 2.

## What erXos's kernel keeps and drops

When erXos's kernel replaces Fiasco (M7 of [plan.md](plan.md)), everything above `liberx` stays:
the interface, the runtimes, the services, the domain library and the system domain's policy, the
function-API set, the conformance and hostile suites, which grow to their full sets, and the bands'
order, which becomes the groups' urgency bases. Dropped: `liberx/backend/fiasco`, the root's
placement records, the clean-room header, the Fiasco patches, the release's Fiasco configuration,
the system-call fuzz harness, the upstream watch, and this document's downsides table. A
scheduler stage built in the fork leaves its C17 policy core to erXos's kernel and drops its C++
hooks.

## Risks

| Risk | Likelihood | Impact | Response |
| --- | --- | --- | --- |
| a Fiasco defect reachable from a domain breaks isolation | medium | high | the fuzz campaign, the upstream watch, every domain holding only what the root placed; a defect found is fixed in the fork and reported |
| QEMU's IOMMU under HVF does not work with Fiasco's binding | unknown | medium | the first package boots it under HVF and TCG; without it, QEMU `virt` devices run unconfined in domains of their own, as on the Pi 4 |
| bands alone give interactive latency worse than users accept | medium | medium | the band test and the latency benchmarks; stages 1 and 2 are the next steps |
| the release configuration drifts from the one tests run | medium | medium | the landing gate boots the release configuration as well as the development one |
| two kernels to maintain while Track K is written | high | medium | Fiasco's part is the backend and a few patches; Track K writes against the same conformance suite |
| users take the downsides for bugs | medium | low | the table ships in the release notes and the user documentation |

## Open decisions

* **Which features are R1's.** "All the user features" is read as everything user-facing in
  [plan.md](plan.md) before M7: users (M10), POSIX's rest (track P), the second tier (track Q), the
  boards' storage and updates (M12), and track D's last parts. Recommendation: R1 is those, with
  each milestone's criteria that need erXos's kernel left at the milestone's kernel part. Track Q
  is the costly one: its copy-on-write children, store tracking and space copy (`erx_mem_child`,
  `erx_mem_dirty`, `erx_space_copy`) are refused by the backend today, and on Fiasco the root would
  serve them as an L4 pager does, by faults it resolves, at a cost not yet estimated.
* **The bands.** Recommendation: the six of [Bands](#bands), fixed in the manifest's schema,
  with no per-domain choice of priority beyond the band.
* **The pause.** The root stopping threads one at a time, as above, or a whole-task pause patched
  into Fiasco (an estimate of 300 to 800 lines, unverified). Recommendation: the root's, since the
  root knows every thread; a patch only if the first package finds Fiasco's exception delivery
  cannot stop a thread blocked in a kernel call.
* **The writable-or-executable patch.** Recommendation: carry it; it is tens of lines and turns a
  property of the root's code into one of the kernel's. Without it the property is a downside row.
* **Elastic budgets.** Walls at the guarantee, as above, or the root running Track K's budget core
  over user pages so that caps above guarantees hold for pages. Recommendation: walls; elasticity
  comes with erXos's kernel.
