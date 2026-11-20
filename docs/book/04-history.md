# Chapter 4. History and Goals

**Background needed.** [Chapter 1](01-operating-systems.md) for
processes, threads, address spaces and system calls;
[chapter 2](02-microkernels.md) for microkernels, L4, Fiasco and
capabilities; [chapter 3](03-erlang.md) for Erlang processes, links,
supervisors and ERTS. A reader who knows all three starts here.

> **Status.** The history, goals and principles carry no mark. erXos
> running on Fiasco behind its own kernel interface, domains with a
> runtime each, the park protocol between executors and Fiasco, and
> budgets as records that end everything charged to them are
> **Built**. Priority bands, per-domain CPU sets and thread limits,
> budgets that refuse a charge past their limit, and `liberx`'s refusal
> to arm an upcall on an executor or to let one block are **Designed**.

An Erlang program on FreeBSD can run hundreds of thousands of
processes, and `ps` lists one of them. That one line is `beam.smp`,
the Erlang runtime system. Inside it, each Erlang process has its own
heap and mailbox, a supervisor restarts it when it crashes, and new
code replaces old code while it runs. FreeBSD sees one process with a
few threads, one address space and one user id.

Joe Armstrong, who designed Erlang, wrote the overlap into his thesis:
"Many of the features which are conventionally provided by an
operating system have moved from the operating system into the
programming language." (Armstrong 2003, section 2.7.) Erlang took over
process creation, scheduling, messaging and recovery. It did not take
over protection: FreeBSD draws that around the whole node. A bug in
native code linked into the runtime can end every process in it, and
the file system beneath is kernel code that no supervisor can restart.

erXos turns this around: the Erlang process becomes the operating
system's process. A small microkernel sits underneath and knows
nothing of Erlang. That kernel is Fiasco, a microkernel of the L4
family, changed by a few patches. Above it, the machine is divided
into domains, each an address space with its own Erlang runtime
([chapter 10](README.md#chapter-10-domains-a-wall-around-some-processes)).
The machine stays one Erlang system, whose processes link and message
one another across domains, and drivers and file systems are Erlang
processes under supervisors.

Sections 4.1 and 4.2 state the problem and the history of its hardest
part, two-level scheduling; 4.3 traces what erXos borrows; 4.4 and 4.5
give its goals and principles; 4.6 says what runs today and 4.7 what
the approach costs.

## 4.1 Erlang systems as operating systems

An Erlang system already does most of what an operating system does
for its programs. erXos asks what a machine looks like when that model
is the machine's own, instead of a guest inside another model.

### 4.1.1 What Erlang already provides

Take a web server written in Erlang, with one process per connection.
Each process has a private heap and can reach another only by sending
a message, copied into the receiver's mailbox. The scheduler counts
reductions, units of work about the size of a function call, so a busy
process cannot starve the rest. A process that crashes sends an exit
signal along its links, and its supervisor starts a fresh one. A new
version of a module loads while the old one runs
([chapter 3](03-erlang.md)).

These are the services a UNIX kernel gives to UNIX processes, and ERTS
gives them to Erlang processes in user mode, without entering the
kernel. Armstrong reported that creating an Erlang process was orders
of magnitude faster than creating a process in most operating systems
of the day (Armstrong 2003). That is why an Erlang system can afford a
process per connection, per request or per device.

### 4.1.2 What the host system does not see

The host operating system draws its boundaries around the runtime, not
inside it, with three consequences.

* **Protection is all or nothing.** OTP's own guidance states that all
  loaded code is trusted and that the runtime has no sandbox
  ([research-prior-art.md, The Erlang runtime](../research-prior-art.md#the-erlang-runtime)).
  Two applications that do not trust each other need two UNIX
  processes, two nodes and a network protocol between them.
* **Accounting stops at the process.** FreeBSD can limit the memory and
  CPU time of `beam.smp`, but not of one application inside it.
* **The services below are a different world.** The file system, the
  network stack and the drivers are kernel code. When a driver fails,
  the kernel panics or the device stops, and no supervisor restarts it.

### 4.1.3 The problem erXos starts from

erXos makes the Erlang process the system's process, and draws
hardware protection around groups of processes only where trust
requires it ([design.md, Context](../design.md#context)). A file
service or a driver is then something to message, inspect and
supervise, like any application component.

Hardware protection still matters, because the runtime that enforces
Erlang's isolation is a large body of native code. A bug in ERTS, in a
native extension, or in the JIT that compiles Erlang to machine code
can break every Erlang process in its address space. A domain is the
wall that stops such a bug. Each domain is also an Erlang node of its
own, so two applications in two domains behave like two applications
on two connected nodes, with differences the design lists and does not
promise to hide ([design.md, Requirements](../design.md#requirements)).

### 4.1.4 Erlang below the application, tried before

Earlier projects ran Erlang closer to the hardware, each with one wall
([research-prior-art.md, Other systems](../research-prior-art.md#other-systems)).

* **Nerves and GRiSP** run an unmodified BEAM over a conventional
  kernel, Linux or the real-time system RTEMS, which keeps the drivers
  and the protection.
* **LING** reimplemented the BEAM to boot with no operating system, as
  a guest of the Xen hypervisor. Its protection boundary is the whole
  virtual machine.
* **HydrOS** ran one BEAM per CPU core over a small kernel, with
  drivers written in Erlang. Its boundaries are cores.

None drew walls between groups of Erlang processes by trust while
keeping the machine one Erlang system. That gap is where erXos starts.

## 4.2 Thirty years of two-level scheduling

If each domain's runtime schedules its own Erlang processes, something
must still schedule the runtimes. In erXos the kernel shares the CPUs
among the threads of every domain, and each runtime switches between
its own processes without asking the kernel. This is **two-level
scheduling**: the kernel at one level, a user-mode scheduler at the
other. Its history is mostly failure.

### 4.2.1 Two answers, both tried

The first answer gives every lightweight thread to the kernel. This
model is called **1:1**, because each user thread is one kernel
thread. Every spawn and every switch then enters the kernel. Erlang
processes are cheap because they never touch the kernel, so for Erlang
this is the cost to avoid.

The second answer is **M:N** threading: a user-level library runs M
lightweight threads on N kernel threads and schedules them itself,
promising cheap switches and parallelism together. NetBSD and FreeBSD
built theirs on **scheduler activations**, a design in which the
kernel calls into the user-level scheduler whenever one of its threads
blocks or is preempted (Anderson and others 1991). Every
general-purpose M:N library was abandoned. NetBSD 5.0 moved to 1:1
threads. FreeBSD replaced its M:N design, KSE, with `libthr`, a 1:1
library, as the default in 7.0. Solaris 9 made its 1:1 library the
default, Linux's NPTL chose 1:1, and Windows dropped its user-mode
scheduling from Windows 11
([research-hierarchical-scheduling.md, Negative evidence](../research-hierarchical-scheduling.md#negative-evidence)).

The developers' stated reasons agree: M:N was harder to write, debug
and maintain, and the cheap switch did not pay for that. Sun's white
paper on Solaris threads said the user-level locks had paid off, but
that a user-level scheduler working well alongside the kernel's had
proved a significant challenge.

### 4.2.2 The common failure

Every abandoned system was a thread library for arbitrary C code,
which can block anywhere: in a system call, on a lock, in a page
fault. Take a thread that calls `read` on a socket with no data. Under
scheduler activations the kernel must tell the user-level scheduler,
so that it can run another thread. That call from the kernel into user
code is an **upcall**, and it arrives at whatever point the program
had reached. If a preempted thread held a lock the scheduler needs,
the scheduler waits for a thread that cannot run until the scheduler
runs it; the scheduler activations paper needed a recovery path for
that case. The research record behind erXos's scheduler draws this
common factor as an inference, not a reason any implementer stated
([research-prior-art.md, Scheduler activations](../research-prior-art.md#scheduler-activations)).

### 4.2.3 Why erXos keeps two levels

erXos differs in the two ways that mattered. Its runtimes are few and
its own: ERTS first, maintained in erXos's tree. And an Erlang process
never blocks the thread that runs it: a receive with no message parks
the process, and the thread runs another. ERTS runs many processes on
a few threads, which erXos calls **executors**. Work that must block
goes to separate helper threads, as ERTS's dirty schedulers do
([chapter 3](03-erlang.md#352-schedulers-and-reductions)).

So erXos keeps both levels, and splits the work between Fiasco and the
runtime along rules that each remove a failure of an earlier system
([design.md, Decisions](../design.md#decisions),
[design-fiasco.md, The scheduler on Fiasco](../design-fiasco.md#the-scheduler-on-fiasco)):

1. **Executors are ordinary threads.** Fiasco preempts and schedules
   them like any other thread.
2. **No upcall reaches an executor.** Fiasco has one upcall, its vCPU
   interface, and erXos uses it only to deliver POSIX signals to a
   native program's worker threads, so the runtime is never entered
   at an unsafe point
   ([design.md, Invariants](../design.md#invariants)). In the design,
   arming it on an executor is refused; that refusal is designed and
   not built.
3. **No wakeup is lost.** A wakeup is a queued event: it advances a
   counter that an executor about to park compares under the same
   lock, so a park that would miss it returns at once, and a running
   executor finds the work at its next safe point
   ([design-fiasco.md, The park protocol](../design-fiasco.md#the-park-protocol)).
4. **Executors never block except to park.** `liberx`, the library
   under every runtime, refuses a thread that is not an executor the
   executors' own calls, parking and taking ready work. In the design
   it also refuses an executor every other kind of wait, with
   `ERX_EWOULDBLOCK`; that refusal is designed and not built.
5. **The kernel decides who runs.** Fiasco's fixed-priority scheduler
   picks the thread; what the runtime says about its own load is
   advice that nothing in the kernel acts on.
6. **No thread lends its CPU time to another.** A service runs a
   client's request on its own threads, so no domain's scheduling
   depends on another's
   ([design.md, Alternatives considered](../design.md#alternatives-considered)).

Fiasco's scheduler has priorities 1 to 255 and runs threads of one
priority round robin, each for a time slice. Every thread runs at
priority 1, except the watchdog at 255
([design-fiasco.md, Scheduling](../design-fiasco.md#scheduling)).
Within its threads, each runtime schedules its own processes with its
own run queues, priorities and reductions.

The design divides the CPUs among domains with three limits, set in
each domain's row of the system configuration: a **band**, the
priority all its threads run at; a set of CPUs its threads may run
on; and a limit on how many threads it may have. There are six bands,
from the watchdog at the top down to apps and programs, so a domain
that spins delays only its own band and those below
([design-fiasco.md, Bands](../design-fiasco.md#bands)). These limits
are designed and not built.

Akaros, a research system, shows what rule 2 avoids. It could take a
core away at any line of code, even under a lock, and then asked the
runtime to run code to handle the loss
([research-prior-art.md, Other systems](../research-prior-art.md#other-systems)).

## 4.3 The lineage

Almost every mechanism in erXos comes from an earlier system. What is
erXos's own is the way they meet: an Erlang process as the system's
process, across address spaces, with Erlang's semantics intact. Four
sources shaped erXos most (sections 4.3.1 to 4.3.4); table 4.1 lists
the others.

| System | Idea | What erXos took |
| --- | --- | --- |
| QNX | a UNIX look over a microkernel | a UNIX surface over services in user mode |
| Genera | one live machine: any object examined, code patched while it runs | the live machine of chapter 21, with walls Genera lacked |
| Inferno | a virtual machine at the center, with no memory protection | the runtime at the center, plus hardware walls |
| Singularity | type-safe processes in one address space | evidence that language safety makes crossings cheap |
| SPIN | kernel extensions in a safe language | a warning: a crashed extension could leave the system inconsistent |
| Midori | Erlang's supervisors as a model for a whole system | the same failure model, found outside Erlang |
| Genode | each session paid from a quota its client donates | memory shares for users |
| Barrelfish | hardware facts as data; a plan kept apart from the register writes | a checked manifest and one ABI file (section 4.5.4) |

*Table 4.1. Systems that each gave erXos one idea
([research-prior-art.md](../research-prior-art.md),
[research-os-ideas.md](../research-os-ideas.md)).*

Singularity's numbers carry the lesson that matters most. Its run-time
safety checks cost under 5 percent (Aiken and others 2006), and
hardware protection crossings 33 to 37.7 percent on a benchmark
dominated by messages (Hunt and Larus 2007). That is why erXos keeps a
domain's Erlang processes in one address space and switches between
them without the kernel. But one address space keeps no secrets.
Speculative execution attacks read data through traces the CPU leaves
when it guesses ahead, and they defeat any software barrier inside one
address space
([research-prior-art.md, Lessons](../research-prior-art.md#lessons)).
So erXos puts hardware walls between domains that do not trust each
other.

### 4.3.1 UNIX and FreeBSD: the surface

UNIX gives erXos its surface: files, processes, pipes of text, a shell
and small tools. Where UNIX systems differ, erXos follows FreeBSD.
musl, the C library under erXos's runtimes, uses FreeBSD's error and
signal numbers. The command shell's `ps`, `ls` and `grep` are Erlang
commands that print FreeBSD's output, and the network stack,
`erx_net`, is an Erlang redesign of FreeBSD's
([README.md, Current status](../../README.md#current-status)).

erXos leaves UNIX's inside. Its kernel is not monolithic, POSIX is not
its base, and a user id grants nothing by itself
([chapter 20](README.md#chapter-20-the-command-shell-and-the-unix-surface)).
QNX showed that a system can look like UNIX over a microkernel. For
erXos, UNIX is how the system looks wherever that is also how it
works.

### 4.3.2 L4 and Fiasco: the kernel

Jochen Liedtke's L4, from 1993, showed that a microkernel can be fast
by keeping only address spaces, threads and fast message passing
([chapter 2](02-microkernels.md#251-from-l3-to-sel4)). Fiasco, a C++
implementation of L4 begun at TU Dresden in 1998, is erXos's kernel
(Elphinstone and Heiser 2013). erXos patches it only where it needs a
property Fiasco lacks and the patch is small
([design-fiasco.md](../design-fiasco.md)).

erXos also takes the shape of L4Re, the user-mode system that usually
runs on Fiasco. In L4Re a root task, the first program the kernel
starts, creates the other programs and hands each its capabilities
([chapter 2](02-microkernels.md#253-the-root-task)). In erXos the root
service of the system domain plays that part: it alone creates kernel
objects and writes any address space's capabilities or page tables.
Even the domain limits of section 4.2.3 follow L4Re: its loader gives
each program a CPU set and a range of priorities
([design-fiasco.md, Threads, bands and stops](../design-fiasco.md#threads-bands-and-stops)).

erXos's own code never calls Fiasco directly. It reaches the kernel
through the **kernel interface**: the calls, rights, status codes and
binary layouts defined in `abi/erx_abi.txt`, which `liberx` offers to
every runtime and service. A call Fiasco cannot carry out fails with
erXos's own status, `ERX_ENOTSUP`, never with a Fiasco error, so no
Fiasco type or number reaches Erlang code or users
([design-fiasco.md, Contract](../design-fiasco.md#contract)).

### 4.3.3 Plan 9: names and files

Plan 9, built at Bell Labs from the late 1980s, reached every resource
through files. Servers present resources as file trees, and one
protocol, 9P, carries every request. Each group of processes assembles
its own view of the tree, its namespace, from the servers it mounts
(Pike and others 1995). Its window system served each window as files, and
its shell was rc.

erXos takes most of this. Each domain resolves paths through its own
namespace, a table from paths to the file servers it was granted, with
no machine-wide root. A path is therefore the visible face of a
capability: a domain with no grant for the storage service has no
`/data`, and no name it can write reaches that server. File servers
speak 9P2000.L, a version of 9P. A display serves each window as a
directory of files, and the command shell speaks rc's language
([chapter 14](README.md#chapter-14-files-namespaces-and-service-trees),
[chapter 22](README.md#chapter-22-displays-windows-and-the-web)).

### 4.3.4 EROS, Safe Erlang and Zircon: authority and payment

A process in erXos acts only on what it was handed, and everything it
creates is paid for by someone. Both ideas come from capability
systems.

In stock Erlang a pid is both a name and an authority: anyone who
knows or forges a pid can send to it, link to it or kill it. Safe
Erlang, a 1999 proposal for running mobile code, called pids "both
forgeable and too powerful" and replaced them with capabilities (Brown
and Sahlin 1999). Zircon, Fuchsia's kernel, gives programs no ambient
authority ([chapter 2](02-microkernels.md#231-authority-in-unix)).
erXos takes both ideas. In its design, a domain reaches another
domain's process only if that process's own runtime exported it, so a
forged pid reaches nothing. Inside a domain, pids keep their stock meaning, because the
domain is the unit of trust
([chapter 11](README.md#chapter-11-authority-and-security)).

Payment comes from EROS
([chapter 2](02-microkernels.md#236-capability-systems-in-practice)).
EROS allocated every object from a **space bank**. Banks formed a
hierarchy, and destroying one destroyed, or handed to its parent,
everything allocated from it and the banks below it (Shapiro, Smith
and Farber 1999). erXos's **budgets** follow that model. The root
service keeps a record of each budget, carved from its parent's, and
charges each object it creates to one. Ending a budget ends everything
charged to it and every budget carved below it, so ending a domain
leaves nothing to chase (`liberx/backend/fiasco/budget.c`).

In the design, each domain's budget is also a wall at its guarantee,
in three parts. Its kernel memory is a Fiasco factory, a kernel object
that creates others, with a fixed limit carved from its parent's;
its user pages are charged to the budget's record, which refuses a
charge past its limit; and what the root service holds on the domain's
behalf is bounded by limits on the domain's threads, objects and
mappings ([design-fiasco.md, Memory and budgets](../design-fiasco.md#memory-and-budgets),
[chapter 12](README.md#chapter-12-memory-and-budgets)). That wall is
designed and not built: a budget records its limit but refuses no
charge, and the inspector reports a domain's budget as unsupported
([README.md, Current status](../../README.md#current-status)).

## 4.4 Goals and non-goals

erXos must run ordinary Erlang applications unchanged, protect them
from one another, and still be one system. The other goals follow from
those three, and the non-goals mark where erXos stops
([design.md, Requirements](../design.md#requirements)).

### 4.4.1 What erXos must do

A **principal** is a user in erXos's sense, an identity with its own
budget, CPU share and quotas
([chapter 11](README.md#chapter-11-authority-and-security)).

| Requirement | What it means |
| --- | --- |
| Run Erlang applications | applications run on OTP 29.1.2 unmodified, with Erlang's semantics, checked against stock OTP |
| Protection | untrusted code cannot read, write, crash or exhaust anything beyond its grant |
| One system | one pid space, message system and view of identity, supervision and inspection across domains; one CPU authority |
| Generic runtimes | the kernel knows no runtime; ERTS runs on a contract another runtime could use |
| A live machine | whoever holds the authority can inspect, trace and change every process, domain and kernel object from a shell |
| Drivers | supervised Erlang processes in domains that hold their devices |
| Users | principals, each with a default domain |
| Storage, updates, networking | storage that survives power cuts, updates that always leave a bootable system, networking to other machines |
| UNIX programs where they pay | a shell with rc's language, toybox's small tools, programs recompiled against a small POSIX layer |

*Table 4.2. What erXos must do.*

Four more requirements say how well.

* **Performance.** Process switch, spawn and messaging inside a domain
  within 1.2 times stock ERTS on the same host; messaging between
  domains an order of magnitude cheaper than Erlang distribution; no
  CPU for an idle domain. These are targets, not measurements.
* **Security on equal footing with correctness.** The party that bears
  the consequences of an input from across a trust boundary checks it,
  with a bound on the work.
* **Reproducibility.** The same inputs give byte-identical boot images.
* **Portability.** QEMU's `virt` machine first, then the Raspberry Pi 4
  and 5. AArch64 is the first architecture, and others are ports, not
  redesigns ([design.md, Portability](../design.md#portability)).

### 4.4.2 What erXos refuses

* **POSIX is not the base.** POSIX is an optional personality for
  native programs. A POSIX base would put UNIX's model of authority, a
  process that holds whatever its user id allows, under every domain.
* **No Linux binaries and no Linux virtual machine.** Stock nodes on a
  Linux-compatible layer would lose the pids, connections and
  supervision that span domains
  ([design.md, Alternatives considered](../design.md#alternatives-considered)).
* **No secrecy inside a domain.** Speculative side channels defeat any
  software barrier inside one address space (section 4.3). Two parties
  that keep secrets from each other belong in two domains.
* **No runtime other than ERTS, and no unmodified ERTS.** The kernel's
  contract leaves room for others, but the design names none, and
  erXos changes ERTS freely (section 4.5.2).

## 4.5 Five principles

Five principles shape every design in erXos, each shown here in one
concrete choice.

### 4.5.1 Erlang wherever practical

As much of the system as is practical is written in Erlang, drivers
included. "Practical" means that no design is complicated, and no
needed performance given up, to keep it in Erlang.

In erXos a **driver** is an Erlang process under a supervisor, over a
thin layer of C, the device shim, that touches the device's registers
and does not interpret the data the device sends. The drivers for
QEMU's virtual display and input devices are Erlang, and so is the
Raspberry Pi's framebuffer driver. One QEMU test kills the virtual
disk's driver in the middle of a transfer, then finds each kept file
cut at a sync, the last moment its data was forced to disk
([README.md, Current status](../../README.md#current-status)).
The kernel, the device shims and per-byte work such as checksums stay
in C ([chapter 15](README.md#chapter-15-devices-and-drivers)).

### 4.5.2 erXos owns OTP

OTP 29.1.2's source lives in erXos's tree and changes by ordinary
edits; erXos does not track upstream. ERTS is a parts bin, taken apart
and recombined wherever that makes the system simpler or faster, and
so is musl. In erXos, ERTS runs in user mode over `liberx`, and its
pids name the domain that owns them.

Owning OTP does not mean drifting from it. OTP's own test suites run
on erXos and on stock OTP, and the results are compared case by case.
Every difference is a bug in erXos, a documented difference with a
test, or an upstream bug recorded as such
([chapter 25](README.md#chapter-25-checking-the-system)).

### 4.5.3 Beauty and simplicity

A small loss of performance is acceptable when it buys a lot of
simplicity. erXos judges simplicity by the model a maintainer must
hold, the concepts, owners and rules a change adds or removes, not by
line count. Its model has seven concepts, each with one owner:
process, domain, runtime, group, budget, capability and principal
([design.md, The model](../design.md#the-model)). Making each domain
an Erlang node shows the principle at work: messaging between domains
needs no new model, because Erlang distribution already says what a
message to another node means.

### 4.5.4 Declarative where it simplifies

Where a description is simpler than code, erXos writes the description
and derives the code from it. The ABI, the binary interface a program
uses to call the kernel, is defined once in `abi/erx_abi.txt`. The
build's ABI generator, written in Ruby like erXos's other host tools,
derives the C headers and the matching Erlang, Ruby and TypeScript, so
no constant is copied by hand. The system's configuration is one
**system manifest**, a file that names every domain the machine runs,
with its budget, its devices and the services it may reach; the build
checks it before making the image
([chapter 7](07-one-source.md#77-the-system-manifest-the-machines-configuration-checked)).

### 4.5.5 UNIX look and feel, honestly

To its users erXos feels like UNIX. Familiar names, commands and
formats stay wherever they fit what the thing is, and nothing wears
the name or shape of something it is not. Designers call that fault
**skeuomorphism**: copying the look of an old object whose function is
gone, like a calendar app drawn as torn paper.

The principle cuts both ways. `ps` prints FreeBSD's columns, because a
process list is a process list, and a value erXos does not measure
shows as `-`, not an invented number
([design.md, Signature experiences](../design.md#signature-experiences)).
But erXos has no `sysctl` command. FreeBSD's `sysctl` is a tree of
values, some to read and some to set. erXos's system values are one
read-only tree, shown by the inspector, `/proc`, the host tool and a
read-only `sysctl(3)` library call. Configuration lives in the system
manifest ([design.md, Decisions](../design.md#decisions)). A
`sysctl` command that refused every write would promise what it does
not do.

## 4.6 What runs today

erXos boots on QEMU's `virt` machine with 1 to 8 CPUs and on a
Raspberry Pi 4, from an SD card. On the Pi 4 the serial console
reaches the command shell, files under `/data` survive a power cycle,
and Ethernet works. A kiosk app shows a clock and live quotes fetched
over HTTPS on the board's screen, and root can log in over SSH with a
key put on the card. Underneath run the system domain, domains with a
runtime each, the inspector and `/proc`, live code loading from the
host, a storage domain over littlefs that restarts after a failure,
and `erx_net`. The POSIX-lite layer, USB, Bluetooth and WiFi drivers
beyond their host-tested parts, and most of the browser client are
designed and not built
([README.md, Current status](../../README.md#current-status)).

## 4.7 What the approach costs, and how it fails

Every choice in this chapter has a price
([overview.md](../overview.md)).

**A runtime per domain costs memory.** Each domain runs its own ERTS,
with its own atoms, code and tables, so ten domains hold ten copies of
the runtime's state. Domains are a tool for trust, not for every
application.

**The system domain is critical.** It decides policy and builds every
other domain, so a fault in it resets the machine
([design.md, Trust placement](../design.md#trust-placement)). A shared
service can also become a bottleneck, so each service limits how much
work any one client can make it do.

**Isolation rests on Fiasco and on the root service.** Fiasco's address
spaces and capability tables keep domains apart, and only the root
service writes them, so a bug in Fiasco or in the root service's
checks of requests could break isolation. That nothing a domain does
can panic the kernel rests on Fiasco's own code and on erXos's fuzzing
of the system calls. That nothing a device does can panic it, and that
a fault ends only the faulting domain, hold as far as Fiasco's code
gives them. Isolation rests too on the CPU's branch predictors, which
guess where code goes next
([design-fiasco.md, Contract](../design-fiasco.md#contract)).

**Device isolation needs hardware.** A device that writes memory
directly can write anywhere, unless an IOMMU, a unit that checks each
device access against a table, confines it. No device on QEMU `virt`
or the Raspberry Pi 4 is behind one, so a bad driver domain can make
its device write anywhere in memory
([design-fiasco.md, Devices](../design-fiasco.md#devices)).

**CPU time is not a share.** Fiasco charges each thread on its own,
with no quota for a domain. Every domain's threads run at one
priority, so a busy domain takes turns on a CPU with every other
thread there. In the design, a domain is held to its
band, its CPU set and its thread limit, so a domain that spins delays
its own band and those below, and gets no fixed fraction of a CPU
([design-fiasco.md, The scheduler on Fiasco](../design-fiasco.md#the-scheduler-on-fiasco)).

**A page can have two faces.** No one mapping is writable and
executable at once, but one page can be writable through one mapping
and executable through another
([design-fiasco.md, Contract](../design-fiasco.md#contract)).

## 4.8 Summary

erXos makes the Erlang process the system's process, draws domains
around groups of processes where trust requires them, and keeps the
machine one Erlang system. Two-level scheduling failed in every
general thread library; it works for erXos because its runtimes are
its own and an Erlang process never blocks its thread. erXos's surface
comes from UNIX and FreeBSD, its kernel and root task from L4, Fiasco
and L4Re, its namespaces from Plan 9, and its authority and payment
from EROS, Safe Erlang and Zircon. It refuses POSIX as a base, Linux
binaries and secrecy inside a domain. It runs on Fiasco, and its own
code reaches the kernel only through its kernel interface, `liberx`.

The next chapter assembles these pieces into one picture: the kernel,
the domains, the system domain and the services, and how a request
travels between them.

## 4.9 Where to read next

* [design.md, Context](../design.md#context),
  [Requirements](../design.md#requirements) and
  [Decisions](../design.md#decisions): the problem, the goals and the
  decisions that span subsystems.
* [design-fiasco.md](../design-fiasco.md): how the system uses Fiasco,
  its scheduler and its budgets.
* [research-hierarchical-scheduling.md](../research-hierarchical-scheduling.md)
  and [research-prior-art.md](../research-prior-art.md): the evidence
  behind sections 4.2 and 4.3.
* Joe Armstrong, *Making reliable distributed systems in the presence
  of software errors*, PhD thesis, KTH, Stockholm, 2003: section 2.3 on
  process creation, section 2.7 for the quotation.
* Thomas Anderson and others, "Scheduler Activations", SOSP 1991, and
  ACM TOCS 10(1), 1992: the classic two-level design.
* Kevin Elphinstone and Gernot Heiser, "From L3 to seL4", SOSP 2013:
  L4's history.
* Rob Pike and others, "Plan 9 from Bell Labs", 1995.
* Jonathan Shapiro, Jonathan Smith and David Farber, "EROS: a fast
  capability system", SOSP 1999, section 5.1: space banks.
* Lawrie Brown and Dan Sahlin, "Extending Erlang for Safe Mobile Code
  Execution", ICICS 1999: pids as capabilities.
* Mark Aiken and others, "Deconstructing Process Isolation", MSPC 2006
  (x86), and Galen Hunt and James Larus, "Singularity: Rethinking the
  Software Stack", ACM SIGOPS OSR, 2007 (WebFiles on an Athlon 64
  3000+): the two costs measured.
