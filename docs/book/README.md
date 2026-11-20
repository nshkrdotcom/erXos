# The Design and Implementation of the erXos Operating System

This file is the plan of a book: its title, its readers, the order of
its chapters and, for each chapter, what its sections explain, the
design documents they draw on and the figures they want. The chapters
themselves are written one at a time from this outline, each checked
against the design documents and the tree.

## What the book is

The design documents in [docs/](../) are contracts. Each states one
subsystem's invariants, interfaces, failure paths and tests, precisely
enough that an implementer can build it and a reviewer can check it, and
each assumes the reader already knows the rest of the system. They are
the wrong place to start. The book is the place to start: it tells the
whole system from the beginning, in the order a reader needs it, with
the reason for each choice next to the choice, and with every term
explained where it first appears.

The model is McKusick, Neville-Neil and Watson, *The Design and
Implementation of the FreeBSD Operating System* (2nd edition,
Addison-Wesley, 2014). The book borrows its arc and its manner, not its
text: an opening part of background, then a part on history, goals and
the overall design; then processes, memory, the I/O system,
communication and the operation of the running system; each chapter
opening with the concepts and the terms, then the structures that carry them, then how they behave and
fail.

### Readers

* Programmers who know UNIX, as a user and a little from the inside, and
  want to know what an operating system built around Erlang looks like.
* Erlang programmers who want to know what happens below the runtime when
  every Erlang process is the operating system's process.
* Students and researchers of operating systems, for the design choices:
  a capability microkernel under a language runtime, two-level
  scheduling, drivers as supervised processes, and a system whose
  properties are designed to hold by construction.
* People who will work on erXos, as the reading that comes before the
  design documents.

The book assumes a reader who can program, in any language, and may know
little about operating systems, microkernels or Erlang. It does not
assume C, Erlang, L4, Plan 9 or OTP's internals. Every term is explained
where it first appears: in Part I for the three subjects everything
rests on, and in a Background box at the head of the chapter that first
needs anything more specialised (DMA, TCP, USB, WiFi and the like). The
glossary, Appendix A, lists every such term and points to where it is
explained.

**Reading paths.**

* No background: read in order, from chapter 1.
* Knows operating systems but not microkernels or Erlang: chapters 2 and
  3, then from chapter 4.
* Knows Erlang and OTP but not operating systems: chapters 1 and 2, the
  rest of chapter 3 only for ERTS (section 5), then from chapter 4.
* Knows operating systems and Erlang, new to L4 and capabilities: chapter
  2, then from chapter 4.
* Knows all three: from chapter 4. A term met on the way is linked to its
  chapter or Background box.
* Wants one thread: each chapter's "Background needed" line names what
  it builds on, so the network (chapters 17 to 19), the display (22) or
  startup (24) can be read after the chapters named there.

### Built and target

erXos is a development preview. [0.1](../plan.md#01-the-preview), the
first public preview, is published: a development build on QEMU `virt`
and the Raspberry Pi 4, with the kiosk, SSH to `rc` and Doom. The next
milestone is [0.2](../plan.md#02-the-first-release-on-fiasco), the first
release, on the Fiasco kernel. Phase 2 of the [roadmap](../plan.md)
builds erXos's own kernel and replaces Fiasco.

The design documents describe the target. The book describes both the
target and what runs, and never presents the first as the second. Every
chapter carries a status box, and every passage about something not yet
running says so in its own sentence. The box uses these marks:

| Mark | Meaning |
| --- | --- |
| **Built** | runs in the tree, in a QEMU suite, on the board or in host tests, as [README.md](../../README.md#current-status) "Current status" records it |
| **0.2** | designed, and scheduled for the first release on Fiasco |
| **Phase 2** | designed, and needs erXos's own kernel, or another milestone after 0.2 |
| **Designed** | designed, and not built; the chapter says which milestone of [plan.md](../plan.md) takes it |

A pure core with host tests and nothing that runs it on a guest is
**Built (host)**. The outline's marks are what README.md's "Current
status" and [plan.md](../plan.md) say; the writer of each chapter checks
them again against the tree before writing.

## Preface: why this order

The book follows the FreeBSD book's arc: overview, processes, the I/O
system, communication, system operation. It departs from it in five
places, each because erXos's structure or its readers ask for it.

1. **Background comes first.** The FreeBSD book can assume that its
   reader knows what a kernel, a page table and a system call are. This
   book cannot: its readers include programmers who have never opened an
   operating system and Erlang programmers who have never met a
   microkernel. Part I (chapters 1 to 3) therefore teaches, from the
   ground up and with no erXos in it, the three subjects every later
   chapter leans on: operating systems, microkernels and capabilities,
   and Erlang with OTP. A reader who knows one of them skips its chapter,
   and the reading paths above say which. What only one chapter needs
   (DMA and cache coherence for devices, TCP for the network stack, the
   handshake of WiFi) is not in Part I: it opens that chapter, in a set
   apart Background box, so it is read where it is used. Each chapter
   begins with a "Background needed" line naming the chapters and boxes
   it builds on. The alternatives were worse: an appendix of background
   is not read before the chapters that need it, and boxes alone would
   repeat three large subjects in every chapter.
2. **Method comes early.** Two chapters of Part II (6 and 7) explain how
   erXos is designed before any subsystem is: decisions as pure
   functions and effects at the edge, properties that hold by
   construction instead of by a list of cases, rules of the form "only X
   may do Y" as build checks, and one declared source for every shared
   fact, from which C, Erlang and Ruby are generated. Every later
   chapter uses these ideas (the device DMA plan of chapter 15 is a
   plan validated whole; the kernel calls of chapter 8 are generated),
   so the reader meets them once, with small examples, and then sees
   them recur.
3. **The domain comes before memory.** In FreeBSD the process is the
   unit of both execution and protection. In erXos the Erlang process is
   the unit of execution and failure, and the domain, a group of
   processes behind an address space, is the unit of protection. So
   Part III goes process and scheduler, then domains, then authority and
   security, then memory and budgets, then native programs, which are
   ports of a session and make sense only once domains and authority do.
4. **The user's machine is a part of its own.** The shell, the live
   machine, the display and apps are not utilities on top of the system:
   each is a service built from the pieces of Parts III to V (domains,
   facets, file trees, pure cores), and each shows one of erXos's
   distinctive ideas (UNIX tools over live Erlang state, a machine you
   can inspect while it runs, one interface rendered natively by every
   display). They come after the parts they are built from and before
   system operation.
5. **Checking comes last.** How erXos knows it is right (OTP's own
   suites against stock OTP, musl's tests, fuzz targets, model checking,
   seeded faults, reproducible and deterministic boots) draws on every
   chapter, so it closes Part VII, and an afterword describes the road
   from Fiasco to erXos's own kernel.

Kernel services, which the FreeBSD book gives a chapter of their own,
are chapter 8 here, the kernel interface, because in erXos the kernel's
services are exactly its interface: everything else runs in user mode.

## Conventions

* Every chapter follows the prose guide, [style.md](style.md): its voice,
  the shape of a chapter, background for newcomers, honesty about what is
  built, and the checklist each writer runs before committing.
* Each chapter is a file in this directory, in GitHub Flavored
  Markdown, its figures Mermaid where GitHub renders it and text diagrams
  otherwise, as [Decisions](#decisions) settles. The file name is the
  two-digit chapter number and a short slug, `NN-slug.md`; the afterword
  and the appendices are `afterword.md` and `a-slug.md` to `e-slug.md`.
  The table below is the one list of names.
* A link from one chapter to another is a relative link to the file, with
  a section anchor where the chapter has one (`10-domains.md#103-...`). A
  chapter that is not yet written is linked to its outline section in
  this file (`README.md#chapter-10-domains-a-wall-around-some-processes`),
  and the link changes to the file when the chapter lands.
* Each chapter cites the design documents by relative link and section,
  and the tree by path. It explains; it decides nothing. When a chapter
  and a design document disagree, the design document is right and the
  chapter is fixed.
* Plain language: the concrete file, call or check, and a term explained
  where it first appears and listed in the glossary, Appendix A, with a
  pointer to where it is explained. A term of operating systems,
  microkernels or Erlang is explained in Part I or in the Background box
  of the chapter that first needs it; a chapter never uses such a term
  unexplained, and never assumes that the reader met it elsewhere. UNIX
  in capitals; "license".
* Each chapter opens with a "Background needed" line, naming the earlier
  chapters and boxes it depends on, so a reader can follow one thread
  (the network, say) without reading all that comes before. Its
  "Background boxes" are short titled passages, set apart, that explain
  a concept before the chapter first uses it; the outline lists them.
* Present tense throughout. Whether a thing is built is said in the
  chapter's status box and in the sentence that describes it.

| Chapter | Title | File |
|---|---|---|
| 1 | Operating Systems from the Ground Up | `01-operating-systems.md` |
| 2 | Microkernels and Capabilities | `02-microkernels.md` |
| 3 | Erlang and OTP | `03-erlang.md` |
| 4 | History and Goals | `04-history.md` |
| 5 | Design Overview of erXos | `05-overview.md` |
| 6 | Correct by Construction | `06-construction.md` |
| 7 | One Source for Every Fact | `07-one-source.md` |
| 8 | The Kernel Interface and Its Two Kernels | `08-kernel-interface.md` |
| 9 | Processes, Runtimes and Two-Level Scheduling | `09-processes.md` |
| 10 | Domains: A Wall Around Some Processes | `10-domains.md` |
| 11 | Authority and Security | `11-security.md` |
| 12 | Memory and Budgets | `12-memory.md` |
| 13 | Native Programs, Pipes and POSIX-lite | `13-native-programs.md` |
| 14 | Files, Namespaces and Service Trees | `14-files.md` |
| 15 | Devices and Drivers | `15-devices.md` |
| 16 | Storage and Updates | `16-storage.md` |
| 17 | The Network Stack | `17-network.md` |
| 18 | WiFi | `18-wifi.md` |
| 19 | Bluetooth | `19-bluetooth.md` |
| 20 | The Command Shell and the UNIX Surface | `20-shell.md` |
| 21 | The Live Machine | `21-live-machine.md` |
| 22 | Displays, Windows and the Web | `22-display.md` |
| 23 | Apps and Packages | `23-apps.md` |
| 24 | Startup, Configuration and Shutdown | `24-startup.md` |
| 25 | Checking the System | `25-checking.md` |
| Afterword | The Road to erXos's Own Kernel | `afterword.md` |
| Appendix A | Glossary | `a-glossary.md` |
| Appendix B | Reading the Design Documents | `b-design-documents.md` |
| Appendix C | Building and Booting erXos | `c-building.md` |
| Appendix D | Dependencies and Licenses | `d-dependencies.md` |
| Appendix E | Lineage | `e-lineage.md` |

## Contents

**Part I. Background**

1. [Operating Systems from the Ground Up](#chapter-1-operating-systems-from-the-ground-up)
2. [Microkernels and Capabilities](#chapter-2-microkernels-and-capabilities)
3. [Erlang and OTP](#chapter-3-erlang-and-otp)

**Part II. Overview**

4. [History and Goals](#chapter-4-history-and-goals)
5. [Design Overview of erXos](#chapter-5-design-overview-of-erxos)
6. [Correct by Construction](#chapter-6-correct-by-construction)
7. [One Source for Every Fact](#chapter-7-one-source-for-every-fact)
8. [The Kernel Interface and Its Two Kernels](#chapter-8-the-kernel-interface-and-its-two-kernels)

**Part III. Processes**

9. [Processes, Runtimes and Two-Level Scheduling](#chapter-9-processes-runtimes-and-two-level-scheduling)
10. [Domains: A Wall Around Some Processes](#chapter-10-domains-a-wall-around-some-processes)
11. [Authority and Security](#chapter-11-authority-and-security)
12. [Memory and Budgets](#chapter-12-memory-and-budgets)
13. [Native Programs, Pipes and POSIX-lite](#chapter-13-native-programs-pipes-and-posix-lite)

**Part IV. The I/O System**

14. [Files, Namespaces and Service Trees](#chapter-14-files-namespaces-and-service-trees)
15. [Devices and Drivers](#chapter-15-devices-and-drivers)
16. [Storage and Updates](#chapter-16-storage-and-updates)

**Part V. Communication**

17. [The Network Stack](#chapter-17-the-network-stack)
18. [WiFi](#chapter-18-wifi)
19. [Bluetooth](#chapter-19-bluetooth)

**Part VI. The User's Machine**

20. [The Command Shell and the UNIX Surface](#chapter-20-the-command-shell-and-the-unix-surface)
21. [The Live Machine](#chapter-21-the-live-machine)
22. [Displays, Windows and the Web](#chapter-22-displays-windows-and-the-web)
23. [Apps and Packages](#chapter-23-apps-and-packages)

**Part VII. System Operation**

24. [Startup, Configuration and Shutdown](#chapter-24-startup-configuration-and-shutdown)
25. [Checking the System](#chapter-25-checking-the-system)

**Afterword.** [The Road to erXos's Own Kernel](#afterword-the-road-to-erxoss-own-kernel)

**Appendices.** [A. Glossary](#appendix-a-glossary),
[B. Reading the Design Documents](#appendix-b-reading-the-design-documents),
[C. Building and Booting erXos](#appendix-c-building-and-booting-erxos),
[D. Dependencies and Licenses](#appendix-d-dependencies-and-licenses),
[E. Lineage](#appendix-e-lineage)

About 900 pages in all, at about 400 words a page.

---

## Part I. Background

The three chapters of this part teach what the rest of the book takes for
granted, to a reader who can program and may know little about operating
systems, microkernels or Erlang. They describe systems in general; erXos
appears only where a chapter says that it does. Each is written to be
skipped by a reader who already knows its subject (see the reading
paths in [Readers](#readers)).

### Chapter 1. Operating Systems from the Ground Up

*About 30 pages.* What an operating system is for and how one works:
the kernel, the two modes of the processor, processes, virtual memory,
files, devices and the boundary between a program and the machine.

**Background needed.** None. This is where the book starts; it assumes
only that the reader can program.

**Status.** Background: no mark. Chapters 2 and 3 do the same for
microkernels and for Erlang; the chapters after them say what erXos does.

1. **What an operating system is for.** Sharing one machine among many
   programs, hiding the hardware behind a few simple ideas (a file, a
   process, an address space), and keeping programs from harming each
   other. The kernel, the programs, the libraries and the services, and
   which of them run with what power.
   *Draws on:* [overview.md](../overview.md),
   [design.md, The model](../design.md#the-model).
2. **The processor's two modes, and the way across.** User mode and
   kernel mode, why a program cannot touch the hardware directly, and the
   three ways into the kernel: a system call, an exception such as a page
   fault, and an interrupt. The timer interrupt and preemption. The
   names an architecture gives its modes (AArch64's exception levels) in
   one paragraph. Subsections: 1.2.1 three ways into the kernel; 1.2.2 a
   system call from start to finish; 1.2.3 the timer; 1.2.4 protection
   without modes (language-based safety as the alternative); 1.2.5 the
   modes on AArch64.
   *Draws on:* [design-arch-aarch64.md](../design-arch-aarch64.md).
3. **Processes, threads and scheduling.** What a process and a thread
   are, the context switch, run queues, priorities and fairness, and
   cooperative against preemptive scheduling. Subsections 1.3.1 to 1.3.5
   follow that order; 1.3.6 How a process ends covers exit, reaping and
   what the kernel reclaims.
   *Draws on:* [design-scheduler.md](../design-scheduler.md).
4. **Virtual memory.** Address spaces, pages, page tables and the TLB, a
   page fault walked step by step, demand paging, copy-on-write,
   memory-mapped files, and protection bits including
   writable-or-executable. Subsection 1.4.7 Who pays for memory:
   overcommit, running out of memory, and charging every page to an account.
   *Draws on:* [design-kernel.md](../design-kernel.md).
5. **Devices, interrupts, DMA and caches.** Memory-mapped registers,
   device interrupts and the interrupt controller, drivers, direct memory
   access, why a cache can hide a device's write from the processor and
   what an IOMMU does about a device that writes where it should not.
   Subsection 1.5.6 Finding the devices: device trees and bus
   enumeration.
   *Draws on:* [design-device-dma.md](../design-device-dma.md).
6. **Files and block devices.** The file as the central abstraction, file
   systems on block devices, directories, mounting, and what a path
   names. Subsection 1.6.5 Permissions, and the power of a user.
   *Draws on:* [design-files.md](../design-files.md).
7. **Talking and sharing.** Locks, atomic operations and memory ordering
   in one page; pipes, sockets and messages; shared memory.
   *Draws on:* [design-pipes.md](../design-pipes.md).
8. **From power-on to the first program.** Firmware, a boot loader, the
   kernel and the first user program.
   *Draws on:* [design-platforms.md](../design-platforms.md).
9. **When a part fails.** What a crashing program, a kernel panic and a
   device that writes where it should not each cost in a conventional
   system: where the line between kernel mode and user mode runs decides
   how far a failure reaches, which the later chapters answer. A summary
   (1.10) and where to read next (1.11) close the chapter.

**Background boxes.** None: the chapter is the background.
*Further reading* (the chapter's writer checks each citation): Ritchie and
Thompson, "The UNIX Time-Sharing System" (1974); McKusick, Neville-Neil
and Watson, *The Design and Implementation of the FreeBSD Operating
System*.

**Figures.** 1.1: the layers of a computer, from hardware to a program.
1.2: a system call from a program into the kernel and back. 1.3: a
virtual address translated through a page table. 1.4: a device's DMA
write with and without a cache that is coherent with it.

### Chapter 2. Microkernels and Capabilities

*About 19 pages.* The design family erXos belongs to: a kernel that does
as little as it can, services in user mode, and authority held as
unforgeable references.

**Background needed.** Chapter 1 (kernel and user mode, address spaces,
system calls).

**Status.** Background: no mark. The sentences that say what erXos takes
from L4 and Fiasco are in chapter 8.

1. **Monolithic kernels and microkernels.** What a monolithic kernel
   holds (file systems, network stack, drivers), what a microkernel
   leaves out, and the trade: isolation of a failing driver against the
   cost of crossing between servers. Mach, QNX, MINIX and the L4 family
   as examples.
   *Draws on:* [research-kernel-bases.md](../research-kernel-bases.md).
2. **Inter-process communication.** Synchronous message passing between
   address spaces, the rendezvous, why L4 made it fast, shared memory
   beside it, and a file or network server as a user-mode process that
   clients call.
   *Draws on:* [design-kernel.md](../design-kernel.md).
3. **Capabilities.** An unforgeable reference to an object together with
   the rights to use it; ambient authority (a user id, a path anyone can
   open) against held authority; the confused deputy; delegation,
   rights that only shrink, and revocation. KeyKOS, EROS, seL4, Zircon
   and Capsicum as examples.
   *Draws on:* [research-prior-art.md](../research-prior-art.md).
4. **Security by construction.** What a trusted computing base is, why
   a small one is checkable, and how a design where every access goes
   through a capability makes whole classes of mistake impossible to
   write, which is the idea the rest of the book returns to.
   *Draws on:* [design.md, The model](../design.md#the-model).
5. **The L4 family and Fiasco.** L4 and its descendants, Fiasco and L4Re,
   the root task that creates every kernel object, and why erXos starts
   on Fiasco and later replaces it with its own kernel.
   *Draws on:* [design-fiasco.md](../design-fiasco.md),
   [plan.md, Track K](../plan.md#track-k-erxoss-kernel).
6. **What fails, and what a failure reaches.** A microkernel does not stop
   servers from failing; it changes what a failure reaches, from the whole
   machine to one address space, and what stays unprotected.
7. **Design choices.** The alternatives to a microkernel with
   capabilities (a hardened monolithic kernel, protection by language,
   access lists) and why erXos does not take them. A summary and where
   to read next close the chapter.

**Background boxes.** None: the chapter is the background.
*Further reading* (the chapter's writer checks each citation): Liedtke,
"On micro-kernel construction" (1995); Dennis and Van Horn, "Programming
Semantics for Multiprogrammed Computations" (1966); Saltzer and
Schroeder, "The Protection of Information in Computer Systems" (1975);
Elphinstone and Heiser, "From L3 to seL4: What Have We Learnt in 20
Years of L4 Microkernels?" (2013); Hardy, "The Confused Deputy" (1988);
Shapiro, Smith and Farber, "EROS: A Fast Capability System" (SOSP 1999);
the FreeBSD manual page capsicum(4).

**Figures.** 2.1: a monolithic kernel and a microkernel with servers,
side by side. 2.2: a client calling a server by IPC. 2.3: a capability
as a slot in a table, with its rights. 2.4: the confused deputy with an
access list and with capabilities.

### Chapter 3. Erlang and OTP

*About 25 pages.* Enough Erlang to read the rest of the book: the
language, processes and messages, failure handled by supervisors, OTP's
behaviours, and the virtual machine that runs it.

**Background needed.** Chapter 1 (processes, scheduling); no Erlang.

**Status.** Background: no mark. A reader fluent in Erlang and OTP skips
to section 5, the BEAM and ERTS, which is what erXos takes apart.

1. **The language in a sitting.** Terms (numbers, atoms, tuples, lists,
   maps, binaries), pattern matching, immutable data, functions and
   modules, recursion in place of loops, and the book's notation for
   specs and records.
   *Draws on:* [style.md](../style.md).
2. **Processes and messages.** Lightweight processes, mailboxes,
   `spawn`, `!` and `receive`, selective receive, process identifiers and
   registered names, and why nothing is shared.
   *Draws on:* [design-runtime.md](../design-runtime.md).
3. **Let it crash.** Links and exit signals, monitors, trapping exits,
   supervisors, restart strategies and supervision trees: why a process
   that meets the unexpected stops and its supervisor starts it again.
   *Draws on:* [design-runtime.md](../design-runtime.md).
4. **OTP behaviours.** `gen_server`, `gen_statem`, `supervisor`,
   `application` and releases: a callback module around a generic
   process, and what each behaviour saves the programmer from writing.
   *Draws on:* [design-runtime.md](../design-runtime.md).
5. **The BEAM and ERTS.** Bytecode and the JIT (BeamAsm), one scheduler
   per processor, reductions, a heap and garbage collection per process,
   ports, NIFs and built-in functions, and the atom table.
   *Draws on:* [research-erts-internals.md](../research-erts-internals.md).
6. **Code loading and distribution.** Two versions of a module at once,
   hot code loading, nodes, node names and cookies, and how a message
   crosses between nodes, which chapter 10 reuses across a domain's wall.
   *Draws on:* [design-runtime.md](../design-runtime.md).
7. **Looking at a running system.** Tracing, the shell, and the tools an
   Erlang programmer uses, as the baseline that chapter 21 extends to
   the whole machine.
   *Draws on:* [design-live.md](../design-live.md).
8. **Where the model stops.** What Erlang's isolation does not give on a
   stock system: native code, one shared memory, the atom table, shared
   stores, distribution with a cookie, and CPU time.
9. **How erXos uses these ideas.** Every Erlang process an operating-system
   process; distribution across a domain's wall; supervisors all the way
   down; a functional core with a behaviour at the edge; ERTS as a parts
   bin; hot code loading with a hash; and the chapter's ideas at a
   glance. A summary and where to read next close the chapter.

**Background boxes.** None: the chapter is the background.
*Further reading* (the chapter's writer checks each citation): Armstrong,
"Making Reliable Distributed Systems in the Presence of Software Errors"
(2003); the OTP documentation shipped with the tree.

**Figures.** 3.1: a process, its mailbox, links and monitors. 3.2: a
supervision tree and one restart. 3.3: a `gen_statem` as a state
diagram. 3.4: the BEAM inside one operating-system process: schedulers
on threads, processes on schedulers.

---

## Part II. Overview

### Chapter 4. History and Goals

*About 18 pages.* Why build an operating system around Erlang, what erXos
takes from earlier systems, and how it gets from nothing to a working
machine.

**Background needed.** Chapters 1 to 3, for the terms; a reader who
knows operating systems, microkernels and Erlang starts here.

**Background boxes.** None; each term of Part I is linked to its chapter
at first use.

**Status.** History and goals: no mark. The phases as they stand: 0.1
built and published; 0.2 next; Phase 2 after.

1. **Erlang systems already behave like operating systems.** Millions of
   isolated processes, preemptive scheduling, failure handled by links
   and supervisors, code replaced while running: all of it inside one
   process of another system, which sees none of it. The section states
   the problem erXos starts from: make the Erlang process the system's
   process, and draw hardware protection around groups of processes only
   where trust requires it.
   *Draws on:* [design.md, Context](../design.md#context),
   [overview.md](../overview.md#why-build-an-operating-system-around-erlang).
2. **Thirty years of two-level scheduling.** Scheduler activations, KSE,
   Solaris M:N threads and Windows user-mode scheduling all tried to let a
   user-level scheduler run on kernel threads, and all were abandoned.
   The section explains their common failure (a kernel re-entering user
   code at arbitrary points, for C code that may block anywhere) and the
   two facts that let erXos keep two levels: its runtimes are few and its
   own, and Erlang processes never block a thread.
   *Draws on:* [research-hierarchical-scheduling.md](../research-hierarchical-scheduling.md),
   [design.md, Context](../design.md#context).
3. **The lineage.** L4 and Fiasco for the kernel; EROS's space banks and
   Genode's quotas for resources; Plan 9 and Inferno for namespaces,
   files, the shell and graphics; QNX for UNIX on a microkernel; Genera
   for a machine open to inspection; Singularity, SPIN and JX for systems
   organised around a language; Safe Erlang for pids as capabilities;
   Zircon for no ambient authority; Barrelfish and BOOM for declarative
   description. One paragraph each on what erXos took and what it left.
   Section 4.1.4 adds the earlier attempts to run Erlang below the
   application (Nerves, GRiSP, LING, HydrOS) and the gap they leave.
   *Draws on:* [research-prior-art.md](../research-prior-art.md),
   [README.md, Architecture](../../README.md#architecture).
4. **Goals and non-goals.** The nine functional requirements (run OTP
   applications unmodified, protection, one system, generic runtimes, a
   live machine, Erlang drivers, users, storage and networking, UNIX
   programs where they pay) and the non-functional ones (performance
   within 1.2 times stock ERTS inside a domain, security on equal footing
   with correctness, reproducible images, portability). The non-goals
   matter as much: POSIX is a personality, never the base; no Linux
   binaries; no confidentiality between processes of one domain.
   *Draws on:* [design.md, Requirements](../design.md#requirements).
5. **Five principles.** Erlang wherever practical; erXos owns OTP and
   changes it freely; simplicity; declarative where it simplifies; UNIX
   look and feel, honestly, with no skeuomorphism (nothing wears the name
   or shape of something it is not). The section shows each principle at
   work in one concrete choice that later chapters return to.
   *Draws on:* [design.md, Decisions](../design.md#decisions),
   [overview.md](../overview.md).
6. **A working system first: phases and seams.** Phase 1 brought the
   system up on a near-stock Fiasco behind erXos's own kernel interface;
   0.1 is a preview of that system; 0.2 ships it on Fiasco with every
   user feature and a published list of what Fiasco lacks; Phase 2
   replaces Fiasco with erXos's kernel at parity. The section explains
   why a stopgap is acceptable only behind an interface erXos owns, and
   what a stopgap promises and does not. Subsections: seams, what a
   stopgap promises, release contracts and the downsides table, the
   phases, and why not another order.
   *Draws on:* [plan.md, Overview](../plan.md#overview),
   [design-fiasco.md, Contract](../design-fiasco.md#contract),
   [design-stopgap.md, Release contract](../design-stopgap.md#release-contract).
7. **Where erXos stands.** What 0.1 publishes today, what runs under it,
   and what is designed and not built.
8. **What the approach costs, and how it fails.** A runtime per domain
   costs memory, the system domain is critical, device isolation needs
   hardware, Fiasco is not erXos's kernel, a stopgap fails safely or not
   at all, and the plan can fail at the seam. A summary and where to read
   next close the chapter.

**Figures.** 4.1: a timeline of the systems erXos draws on, with the idea
taken from each, as a text diagram. 4.2: the phases and milestones as a strip, 0.1 marked
published, 0.2 next, Phase 2 after, the seam (the kernel interface)
drawn as a line that stays put while the kernel below it changes.

### Chapter 5. Design Overview of erXos

*About 34 pages.* The whole system in one chapter: seven concepts, what
runs where, and a day in the life of the machine.

**Background needed.** Chapters 1 to 4.

**Background boxes.** Reading a sequence diagram, as the day in the life
uses one. What a boot image, a manifest and a package are, one paragraph
each, before the chapter names them.

**Status.** Mixed; the day in the life is annotated step by step. Built:
the system domain as root task on Fiasco, domains each with its own ERTS,
the command shell, programs and pipes, storage and networking services,
the display. 0.2: principals with domains of their own at login, release
consoles with a login. Phase 2: grants enforced by erXos's kernel.

1. **Seven concepts, each with one owner.** Process, domain, runtime,
   group, budget, capability, principal: what each is, who owns it, and
   why each has exactly one owner. The chapter defines the terms the rest
   of the book uses (executor, connection, lane, funnel, export, facet,
   sub-space, namespace, port) in plain words, as a reader's map.
   *Draws on:* [design.md, The model](../design.md#the-model).
2. **What runs where.** The kernel in kernel mode, and everything else in
   user mode: the system domain (ERTS on the interpreter, the root task),
   Erlang domains, driver domains, and native programs in sub-spaces of a
   session. For each: what it runs, who trusts it, and what happens when
   it fails, from "the domain dies and links fire" to "the machine resets
   after a crash record".
   *Draws on:* [design.md, Overview](../design.md#overview),
   [design.md, Trust placement](../design.md#trust-placement).
3. **A day in the life.** The machine boots, the system domain starts the
   domains the system manifest lists, a user logs in and gets a domain, a
   process sends to a service through a facet, a sandbox domain crashes
   and a link delivers `{domain_down, D, crash}`, and `find /tmp -type f
   | wc -l` runs a native program and an Erlang command in one pipeline.
   Each step names the chapter that explains it and whether it runs in
   0.1.
   *Draws on:* [design.md, Overview](../design.md#overview).
4. **Signature experiences.** What a person can do on erXos that a
   conventional system does not offer: the shell is the operating
   system; the machine is an object; kill a driver mid-transfer and its
   supervisor restarts it; forge a pid and nothing happens; UNIX tools
   over live Erlang state. Each is shown as a short transcript, marked
   built or not.
   *Draws on:* [design.md, Signature experiences](../design.md#signature-experiences),
   [DEMOS.md](../../DEMOS.md).
5. **The decisions every reader needs.** A guided tour of the cross-cutting
   decisions: every runtime in user mode, `liberx` the only issuer of
   kernel calls, every domain a node, pids naming their owner domain,
   budgets as space banks, system code in Erlang, drivers included,
   formats erXos's own from the first day, and no backward compatibility
   during development. Each with its one-line reason.
   *Draws on:* [design.md, Decisions](../design.md#decisions).
6. **Tensions and alternatives.** Where the design pulls against itself
   (performance against isolation, Erlang against C, a familiar surface
   against a different model) and the large alternatives rejected: a
   Linux virtual machine, POSIX as the base, one runtime for the whole
   machine, a verifier instead of hardware protection.
   *Draws on:* [design.md, Tensions](../design.md#tensions),
   [design.md, Alternatives considered](../design.md#alternatives-considered),
   [design.md, Why no verifier](../design.md#why-no-verifier).

**Figures.** 5.1: the layer diagram of [design.md,
Overview](../design.md#overview), redrawn: domains, sub-spaces,
connections, the system domain, the kernel. 5.2: the seven concepts and
their owners as a table-diagram. 5.3: the day in the life as a sequence
diagram, each step tagged with its chapter and status.

### Chapter 6. Correct by Construction

*About 28 pages.* How erXos is designed: properties that hold because the
wrong state cannot be written, not because every case was remembered.

**Background needed.** Chapters 1 to 3 (chapter 1 for DMA and caches,
chapter 3 for Erlang).

**Background boxes.** Pure functions and side effects, with an Erlang
example. Model checking, fuzzing and static checks in a paragraph each.
Why a device's write can bypass a cache, enough for the worked example;
chapter 15 explains it in full.

**Status.** The method is applied throughout the built tree: pure cores
returning `{State, Actions}` with one edge loop, `erx_actions:perform/3`
(Built); the device NIF's round functions and `erx_device_dma_check`
(Built); the chokepoint checks and the stack proof of the C17 cores
(Built, in `make check`). Many "by construction" properties of the
kernel hold in full only on erXos's kernel (Phase 2); on Fiasco each
cites its row of the downsides table.

1. **Open-ended enumeration is the smell.** A correctness argument that
   depends on remembering every caller, path or exception breaks with the
   next caller. The section works through the two questions that replace
   such a list ("what is this list protecting?" and "what would make the
   list empty?") and the three ways out: make the illegal state
   unrepresentable, make the invariant a derived fact nothing can
   destroy, make one funnel the only way to the operation.
   *Draws on:* [design.md, Invariants](../design.md#invariants),
   [design.md, Correct by construction in code](../design.md#correct-by-construction-in-code).
2. **The properties erXos holds by construction.** A tour of the list:
   a stale capability never names a new object; rights only shrink; no
   capability is ever in flight; deleting a budget deletes everything
   charged to it; no mapping is writable and executable at once; a pid
   is a name, not an authority; no process acts on a message from
   another domain that its protocol's owner did not admit. For each, the
   one mechanism that makes it hold, and the chapter that shows it.
   *Draws on:* [design.md, Invariants](../design.md#invariants),
   [design-kernel.md, Invariants](../design-kernel.md#invariants),
   [design-domains.md, Invariants](../design-domains.md#invariants).
3. **Functional core, effects at the edge.** Every decision that can be a
   pure function is one: a state machine that returns the next state and
   a list of actions, a plan validated whole before anything is applied.
   The section shows the shape in Erlang (`{State, Actions}` and the one
   edge loop) and in C (a round function, an observation or a decision,
   one effect loop), and why the opposite shape, a caller stringing
   helpers together in the right order, keeps producing sequencing bugs.
   *Draws on:* [design.md, Functional core, effects at the edge](../design.md#functional-core-effects-at-the-edge),
   [style.md, Functional core](../style.md#functional-core).
4. **A worked example: the device DMA plan.** A preview of chapter 15. A
   driver's C part never pokes a device freely: its pure core produces a
   plan, ordered steps such as "write this value at this offset of this
   region", "publish this register", "copy these bytes back", and one
   function, `erx_device_dma_check`, checks the whole plan, together with
   the queue's state before and after, before anything touches the
   hardware. Every device address stays inside the domain's DMA memory,
   and no region ever has two writers. Cache maintenance and barriers are
   derived from the plan by one sequencer, so no driver can forget one.
   *Draws on:* [design-device-dma.md, Calls, observations and plans](../design-device-dma.md#calls-observations-and-plans).
5. **Only X may do Y: chokepoints as build checks.** A rule such as "only
   the device shim touches a device's registers" or "only `liberx`
   issues kernel calls" is a check that fails the build on a new site,
   and each check has a test that plants a violation and expects the
   failure. The section explains why a type or visibility boundary comes
   first (opaque types, `static` functions, unexported Erlang functions)
   and a chokepoint check covers only what such a boundary cannot say.
   *Draws on:* [design.md, Chokepoint checks](../design.md#chokepoint-checks),
   `tools/lib/erx/chokepoint_rules/`.
6. **Bounded stacks and typed numbers.** The kernel's C recurses only
   through tail calls the compiler must turn into jumps, and each build
   computes the worst-case stack depth from the call graph. Addresses,
   sizes and counts have types that do not convert into each other. The
   section shows how both turn a class of kernel bug into a build
   failure.
   *Draws on:* [design.md, Bounded stacks](../design.md#bounded-stacks),
   [design.md, Typed addresses and counts](../design.md#typed-addresses-and-counts),
   [design-kernel.md, Stack proof](../design-kernel.md#stack-proof).
7. **Seams, not rewrites.** Every third-party component erXos stands on
   (Fiasco, littlefs, LVGL, musl, OTP) sits behind an interface erXos
   owns, so replacing it changes what is behind the interface and nothing
   above it. The section shows the rule at the kernel interface, at the
   storage domain's file server and at the display, and explains what a
   stopgap promises (no memory errors, no deadlock, the results of its
   calls) and what it records instead of fixing.
   *Draws on:* [design.md, Decisions](../design.md#decisions),
   [design-stopgap.md](../design-stopgap.md).

**Figures.** 6.1: a pure core and its effect loop: request in, either
"observe these reads" or "decide: this plan and the next state", the
effect loop performing reads or the checked plan. 6.2: the "by
construction" list as a table of property, mechanism, chapter, and the
Fiasco row that weakens it. 6.3: a chokepoint check with its seeded
violation.

### Chapter 7. One Source for Every Fact

*About 26 pages.* Declarative description in erXos: facts stated once,
and everything that follows from them generated or checked.

**Background needed.** Chapter 6; chapter 3 for Erlang terms.

**Background boxes.** What an application binary interface is and why
two languages must agree on one. Code generation from a specification,
against writing the same table twice. Datalog in a page: facts, rules,
queries. How a chip vendor describes registers (CMSIS-SVD).

**Status.** Built: `abi/erx_abi.txt` and its Ruby generators (C headers,
Erlang modules, Ruby tables); the hardware sources (CMSIS-SVD files and
Arm's machine-readable register data); the inspection schema
(`abi/inspection.txt`); the theme file (`abi/theme.txt`) with its
contrast rules; errno and signal tables with FreeBSD's numbers; the
system manifest and its build-time check, in Ruby. Not adopted: Datalog.
An awklog form of the manifest check is an evaluation the roadmap
schedules, adopted only if it makes the checks clearer; the declarative
operating-system services of BOOM and Dedalus are a research direction,
not a design.

1. **The problem: parallel copies.** Two places that must change
   together become a list of places to update, and the list is an
   enumeration that someone forgets. The section states the rule (every
   decision, table and format has one implementation; C, Erlang and Ruby
   share a table only by generation) and its companion: a fact the build
   can compute is never written by hand and then checked.
   *Draws on:* [design.md, One source for the ABI and the hardware](../design.md#one-source-for-the-abi-and-the-hardware),
   [design-generation.md, Sources and outputs](../design-generation.md#sources-and-outputs).
2. **The ABI file.** Kernel calls with their argument types and rights,
   status codes, limits and every fixed binary layout (rings, reader
   pages, frames, boot information, virtio descriptors) are declared in
   one text file, and Ruby generators produce the kernel's dispatch, the
   C bindings of `liberx` and its backends, the Erlang codecs and the
   host tools' readers. The section walks one declaration from text to
   each generated output, and shows the rules of a good spec: closed
   value sets, derived offsets, strict runs, sorted output.
   *Draws on:* [design-abi.md, Source grammar](../design-abi.md#source-grammar),
   [design-abi.md, A complete declaration example](../design-abi.md#a-complete-declaration-example),
   `abi/erx_abi.txt`.
3. **The hardware has one source too.** Device registers come from
   CMSIS-SVD files and each architecture's system registers from Arm's
   machine-readable data; accessors are generated and no register bit is
   packed by hand. Terminal sequences and keymaps come from their own
   sources the same way.
   *Draws on:* [design-generation.md, Hardware and terminal sources](../design-generation.md#hardware-and-terminal-sources),
   [design-generation.md, Register inputs](../design-generation.md#register-inputs).
4. **The system manifest: the machine's configuration, proved.** One file
   lists every configured domain with its principal, image, budget,
   grant, devices, facets and introductions. The build packs it into the
   boot image and a check refuses a manifest that breaks a property the
   security argument rests on, such as a release build's domain that
   parses hostile input holding a device no IOMMU confines. Each property
   has a test that plants one violation and expects its diagnostic.
   *Draws on:* [design-system.md, The manifest](../design-system.md#the-manifest),
   [design-abi.md, System-manifest representation](../design-abi.md#system-manifest-representation),
   [design-fiasco.md, The Phase 1 manifest check](../design-fiasco.md#the-phase-1-manifest-check).
5. **Declared services and inspection paths.** Every cross-domain facet is
   declared in `abi/services` with the design section that justifies it,
   and every value the system observes is an inspection path declared in
   `abi/inspection.txt`; a build check refuses what the tables do not
   list. The section explains how this turns "no new mechanism without a
   design" into something the build enforces.
   *Draws on:* [design-generation.md, Service interfaces](../design-generation.md#service-interfaces),
   [design-generation.md, Inspection and diagnostics](../design-generation.md#inspection-and-diagnostics).
6. **One theme, three renderers.** The desktop's type roles, spacing,
   radii, shadows and palette are one declaration with contrast rules the
   build checks, and the Erlang, C and TypeScript sides are generated
   from it. A small example of the same idea far from the kernel.
   *Draws on:* [design-desktop-programs.md, The theme: one declaration](../design-desktop-programs.md#the-theme-one-declaration).
7. **Where Datalog fits, and where it does not.** The section separates
   the declarative work that is built (the specs above) from what is
   being evaluated (an awklog form of the manifest's relational rules:
   device ownership, facet targets, boot-order cycles) and what is
   research (declarative services after BOOM and Dedalus, Barrelfish's
   system knowledge base). It explains the rule that decides each case:
   a declarative form is chosen when it turns a property into a checked
   constraint, never where it adds complexity, and exact budget
   arithmetic stays in Ruby because awklog has none.
   *Draws on:* [design-verification.md, Focused tool evaluations](../design-verification.md#focused-tool-evaluations),
   [research-os-ideas.md, Declarative OS services from BOOM and Dedalus](../research-os-ideas.md#declarative-os-services-from-boom-and-dedalus),
   [research-os-ideas.md, Barrelfish and declarative hardware management](../research-os-ideas.md#barrelfish-and-declarative-hardware-management).

**Figures.** 7.1: the generation graph: the ABI file, the hardware
sources, the theme and the inspection schema on the left, the generators
in the middle, every generated header, module and table on the right.
7.2: one declaration and its C, Erlang and Ruby outputs side by side.
7.3: the manifest check as a pipeline: reader, normalized facts,
properties, diagnostics, with one seeded violation traced through.

### Chapter 8. The Kernel Interface and Its Two Kernels

*About 42 pages.* The kernel's services are its interface: objects,
capabilities, threads, memory, IPC and interrupts. Two kernels stand
behind it: Fiasco today, erXos's own kernel in Phase 2.

**Background needed.** Chapters 1 to 3 and 5 to 7; chapter 2 for
capabilities.

**Background boxes.** A capability table recalled from chapter 2 with a
worked lookup. Fiasco, L4Re and the root task in a page. What a
generation count prevents.

**Status.** Built: `liberx`'s Fiasco backend, the hosted backend for
hosted mode, the root service's request decoder and placement code, the
downsides table and its check. 0.2: the Fiasco target (handles as Fiasco
slots, a factory per domain budget, bands, DMA spaces), the release's
Fiasco build and the system-call fuzz campaign. Phase 2: erXos's kernel,
of which host-built C17 cores exist (object store, capability table,
budgets, page funnel) and none boots.

1. **What the kernel knows, and what it does not.** Threads, groups of
   threads, memory, capabilities and interrupts; nothing of Erlang. The
   section explains why the line falls there, what a microkernel buys
   (every runtime and driver in user mode, a small trusted base) and
   what it costs (crossings), with Singularity's measurements of hardware
   crossings as the evidence.
   *Draws on:* [design-kernel.md, Context](../design-kernel.md#context),
   [design-kernel.md, Overview](../design-kernel.md#overview).
2. **Objects and capabilities.** A capability is an object reference with
   rights, held in a slot of a space. Every kernel call reaches its
   objects through one lookup that checks generation, type and rights, so
   a stale capability never names a new object; rights only shrink when a
   capability is duplicated or passed; capabilities pass only at an IPC
   rendezvous, so no queue ever holds one. Each property is shown with
   the data structure that makes it hold.
   *Draws on:* [design-kernel.md, Objects and capabilities](../design-kernel.md#objects-and-capabilities),
   [design-kernel.md, Rights](../design-kernel.md#rights),
   [design-kernel.md, Passing capabilities](../design-kernel.md#passing-capabilities).
3. **Threads, gates, IRQ objects and faults.** The objects a runtime uses
   to run and wait: threads and their faults, IPC gates, IRQ objects that
   serve as doorbells, the user-space mutex (umtx), vCPU upcalls for
   signals. How a fault reaches the right handler, and why the kernel
   never loads or stores through an address a domain supplies.
   *Draws on:* [design-kernel.md, Threads and faults](../design-kernel.md#threads-and-faults),
   [design-kernel.md, IRQ objects](../design-kernel.md#irq-objects),
   [design-kernel.md, vCPU upcalls](../design-kernel.md#vcpu-upcalls).
4. **`liberx`: the one issuer of kernel calls.** Every kernel call in
   every runtime and program goes through `liberx`, whose calls are
   generated from the ABI file; behind it sit backends (Fiasco, hosted,
   and later erXos's kernel) that pass one test set, refusals included.
   A call a backend cannot implement fails with `ERX_ENOTSUP`, and a
   value it cannot measure is reported as unsupported, never invented.
   *Draws on:* [design-runtime.md, liberx](../design-runtime.md#liberx),
   [design-runtime.md, The liberx interface](../design-runtime.md#the-liberx-interface).
5. **erXos on Fiasco.** How the backend implements the interface over
   Fiasco's own capabilities, factories, interrupts and DMA spaces, the
   system domain acting as L4Re's root task does: the only creator of
   kernel objects and the only writer of any object space. The call
   table, and why the backend never rebuilds in user mode a property only
   erXos's kernel promises.
   *Draws on:* [design-fiasco.md, The construction](../design-fiasco.md#the-construction),
   [design-fiasco.md, The call table](../design-fiasco.md#the-call-table).
6. **The downsides table: an honest list.** Every property of erXos's
   kernel that Fiasco does not have is one row, `FD1` to `FD34`, with
   what it weakens, what Fiasco has instead, what a user sees and what
   closes it. The section explains why a single published list beats
   scattered caveats, and walks a few rows (budgets above a wall, CPU
   grants, DMA without an IOMMU).
   *Draws on:* [design-fiasco.md, Downsides against erXos's kernel](../design-fiasco.md#downsides-against-erxoss-kernel),
   [design-fiasco.md, Security on Fiasco](../design-fiasco.md#security-on-fiasco).
7. **erXos's own kernel and its L4 lineage.** A C17 reimplementation of
   Fiasco's proven design, keeping Fiasco's model wherever erXos needs
   nothing else, with every departure recorded with its reason in a
   ledger. The section surveys what it adds (budgets as walls for every
   allocation, CPU grants, bounded kernel paths) and its port contract,
   the one place an architecture enters.
   *Draws on:* [design-kernel.md, L4 lineage](../design-kernel.md#l4-lineage),
   [design-kernel.md, The ledger](../design-kernel.md#the-ledger),
   [design-kernel.md, Port contract](../design-kernel.md#port-contract),
   [design-arch-aarch64.md](../design-arch-aarch64.md).

**Figures.** 8.1: the seam: runtimes and programs above, `liberx` and its
generated calls, three backends below it. 8.2: a capability lookup:
slot, generation, type, rights. 8.3: the downsides table excerpted, with
the column structure explained.

---

## Part III. Processes

### Chapter 9. Processes, Runtimes and Two-Level Scheduling

*About 38 pages.* Every Erlang process is a process of the operating
system; the kernel gives CPU time to runtimes, and each runtime schedules
its own processes.

**Background needed.** Chapters 1 and 3 (scheduling, the BEAM), chapter
8.

**Background boxes.** How a BEAM scheduler runs a process: reductions,
run queues, dirty schedulers. Preemption by the timer interrupt. A C
library and what musl is. Just-in-time compilation and
writable-or-executable memory.

**Status.** Built: ERTS in user mode in every domain, the system domain
on the interpreter, BeamAsm in other domains, the C library seam over
musl, hosted mode. 0.2: priority bands, CPU sets and thread limits from
the manifest on Fiasco. Phase 2: groups with grants (quota per period,
capacity, urgency) enforced by erXos's kernel.

1. **The Erlang process is the system's process.** A pid, a mailbox,
   links and monitors: the unit of execution and failure for the whole
   machine. The section explains what that means for a user (`ps` lists
   Erlang processes and native programs together) and for a programmer
   (OTP applications run unmodified, checked against stock OTP).
   *Draws on:* [design.md, The model](../design.md#the-model),
   [design.md, Requirements](../design.md#requirements).
2. **Groups and grants.** The kernel allocates CPU to groups of threads,
   each with a grant: a quota per period, a set of CPUs, a capacity and
   an urgency band; groups form a tree and no group exceeds its parent.
   The section explains charging, pick and dispatch, and what a grant
   guarantees, and marks which of it runs on Fiasco as bands.
   *Draws on:* [design-scheduler.md, Data model](../design-scheduler.md#data-model),
   [design-scheduler.md, Charging and quota](../design-scheduler.md#charging-and-quota),
   [design-fiasco.md, Bands](../design-fiasco.md#bands).
3. **The runtime contract.** Executors are threads that only park and
   never block; workers may block. A runtime parks an idle executor
   against an epoch, so a wakeup that arrives between its last look and
   its park cancels the park. The kernel never re-enters a runtime, and
   everything a runtime tells the kernel is a hint the kernel bounds:
   the six rules that remove the causes of scheduler activations'
   failure.
   *Draws on:* [design-scheduler.md, Park and wake](../design-scheduler.md#park-and-wake),
   [design-scheduler.md, The runtime contract](../design-scheduler.md#the-runtime-contract),
   [design.md, Decisions](../design.md#decisions).
4. **ERTS as a parts bin.** ERTS is taken apart and recombined for erXos:
   one mechanism per job, the edits outside its `sys/erxos` port, the
   adapter between ERTS and `liberx`, the event table, connections and
   programs inside ERTS, and the three runtime images. The section shows
   why erXos owns its runtime instead of running unmodified ERTS.
   *Draws on:* [design-runtime.md, One mechanism per job](../design-runtime.md#one-mechanism-per-job),
   [design-runtime.md, The adapter](../design-runtime.md#the-adapter).
5. **Code: the interpreter, BeamAsm and shared code.** The system domain
   runs the interpreter and makes no machine code; other domains may run
   BeamAsm, the JIT, in user mode, with no page ever writable and
   executable at once. One image of shared loaded code mapped into every
   domain saves memory (Phase 2's shared-code image is designed and not
   built).
   *Draws on:* [design-runtime.md, BeamAsm](../design-runtime.md#beamasm),
   [design-runtime.md, Code in the system domain](../design-runtime.md#code-in-the-system-domain),
   [design.md, The JIT](../design.md#the-jit),
   [design-shared-code.md, The central construction](../design-shared-code.md#the-central-construction).
6. **The C library seam and hosted mode.** musl, modified, sits under
   ERTS through one seam, with FreeBSD's errno and signal numbers
   generated from the ABI; the same runtime runs as a macOS process on a
   hosted implementation of the kernel interface, under the sanitizers
   and a debugger, for fast iteration.
   *Draws on:* [design-runtime.md, The C library seam](../design-runtime.md#the-c-library-seam),
   [design-runtime.md, Hosted mode](../design-runtime.md#hosted-mode).
7. **Two schedulers you can watch as one.** One timeline shows the
   kernel's decisions beside each runtime's, and a shared service's
   statistics show whose requests its time went to. The worked example
   of the scheduler design closes the chapter.
   *Draws on:* [design-scheduler.md, A worked example](../design-scheduler.md#a-worked-example),
   [design-scheduler.md, Service work](../design-scheduler.md#service-work).

**Figures.** 9.1: the two levels: groups and executors under the kernel,
Erlang processes on executors under each runtime. 9.2: park and wake with
the epoch, as a sequence diagram showing the lost-wakeup race and how the
epoch closes it. 9.3: a group tree with grants. 9.4: the inside of ERTS
on erXos, the adapter and `liberx` beneath it.

### Chapter 10. Domains: A Wall Around Some Processes

*About 42 pages.* The unit of isolation: a domain is an address space
with its own runtime and an Erlang node of its own, and processes in
different domains link, monitor and message each other as Erlang
processes always have.

**Background needed.** Chapters 1, 2 and 8; chapter 9 for runtimes;
chapter 3 for nodes.

**Background boxes.** Address spaces and page tables recalled from
chapter 1. Ring buffers in shared memory and doorbells. What an Erlang
node and the external term format are.

**Status.** Built: domains with their own ERTS, connections and lanes,
the funnel, exports, the origin envelope, links and monitors across
domains, `{domain_down, D, Info}`, the domain service creating and ending
domains. Phase 2: the guarantees that need erXos's kernel, each a row of
the downsides table.

1. **A domain is a node.** Each domain has a node name such as
   `web@erxos`, its own atoms, code, ETS tables and registered names, a
   budget, a group and a connection to the system domain. A pid carries
   its owner domain by construction. The section explains why "Erlang
   distribution inside one machine" is the right first picture, and where
   it differs.
   *Draws on:* [design-domains.md, Domain ids, pids and references](../design-domains.md#domain-ids-pids-and-references),
   [design-domains.md, Atoms, code, ETS and names](../design-domains.md#atoms-code-ets-and-names).
2. **Connections, lanes and doorbells.** Two introduced domains share one
   connection: two lanes, one per direction, each a ring the producer
   alone writes, a reader page the consumer alone writes, and a doorbell.
   The system domain makes every connection and alone can delete it.
   Flow control, introduction and connection down follow.
   *Draws on:* [design-domains.md, Connections](../design-domains.md#connections),
   [design-domains.md, Flow control](../design-domains.md#flow-control),
   [design-domains.md, Introduction and connection down](../design-domains.md#introduction-and-connection-down).
3. **The funnel.** The receiving runtime's one reader of its lanes, a C17
   library in `liberx`, copies a frame out of the ring once, checks its
   structure and its authority against the domain's own export table, and
   only then decodes it. The section shows why copying first matters (a
   peer cannot change bytes between check and use) and how the funnel is
   checked against `binary_to_term/1`.
   *Draws on:* [design-domains.md, The funnel](../design-domains.md#the-funnel),
   [design-domains.md, Frames](../design-domains.md#frames), `liberx/erx_funnel.c`.
4. **Exports: a pid is a name, not an authority.** A domain reaches a
   process of another domain only if that process's own runtime exported
   it, by handing out the pid, by a spawn or explicitly. Forge any pid
   and nothing happens, exactly as if the process were dead. The section
   compares Safe Erlang's capabilities.
   *Draws on:* [design-domains.md, Exports](../design-domains.md#exports),
   [design-domains.md, Authority](../design-domains.md#authority).
5. **The origin envelope.** Every message from another domain arrives as
   `{erx_origin, D, Msg}`, with no flag and no exception, so it never has
   the shape of a local message; only the owner of each protocol (the
   reply path of `gen`, the io protocol, the file client) takes the
   envelope off its own shapes, and `sys` never does. A worked example of
   a property made to hold by construction instead of by a list of
   checks.
   *Draws on:* [design-domains.md, The peer](../design-domains.md#the-peer),
   [design-domains.md, Invariants](../design-domains.md#invariants).
6. **Links, monitors, exits and spawning across a wall.** Erlang's
   semantics kept across domains: links and monitors, exit signals,
   killing a process, spawning into another domain, and a crashed domain
   seen as a dead node. TLA+ models check the lane and the link protocol.
   *Draws on:* [design-domains.md, Links, monitors and exits](../design-domains.md#links-monitors-and-exits),
   [design-domains.md, Spawning](../design-domains.md#spawning),
   [design-domains.md, Domain lifecycle](../design-domains.md#domain-lifecycle).
7. **The system domain and the domain library.** The root task: Erlang
   policy decides who gets what, and a C17 library in `liberx` plans a
   domain whole and creates, inspects and ends it. Ending a domain is one
   operation: destroying its budget.
   *Draws on:* [design-system.md, The root task](../design-system.md#the-root-task),
   [design-system.md, The domain library](../design-system.md#the-domain-library),
   [design-system.md, Creating a domain](../design-system.md#creating-a-domain),
   [design-system.md, Ending a domain](../design-system.md#ending-a-domain).

**Figures.** 10.1: two domains and their connection: rings, reader pages,
doorbells. 10.2: a frame's path through the funnel: copy, check, decode.
10.3: a pid's bits and the export table lookup. 10.4: a sandbox crash from
fault to `{domain_down, D, crash}` at the linked process.

### Chapter 11. Authority and Security

*About 42 pages.* Who may do what, and why: the threat model, trust
placement, facets, principals, keys, cryptography and the closure that
makes a release safe for untrusted code.

**Background needed.** Chapters 2, 8 and 10.

**Background boxes.** Threat models: what an attacker is assumed able to
do. Hashes, public-key signatures and what a key vault protects.
Terminal escape sequences and why raw control characters are an attack.
Branch-predictor side channels in a page.

**Status.** Built: facets and the declared service table, every
development build marked `development build: trusted code only`, OpenSSL
in the runtime images, `erx_report` filtering crash reports. 0.2: the
security closure in its Fiasco form, release consoles with a login,
principals with budgets and quotas. Designed, not built: the vault.
Phase 2: the closure on erXos's kernel.

1. **The threat model.** Untrusted Erlang code, drivers and native
   programs run in domains or sub-spaces that cannot read, write, crash or
   exhaust anything outside what they were granted. The section lists the
   untrusted inputs (everything a domain hands the kernel, every message
   from another domain, everything a device writes, every packet and file
   system image) and what is out of scope (speculative side channels
   within one address space).
   *Draws on:* [design.md, Threat model](../design.md#threat-model),
   [design.md, Residual risks](../design.md#residual-risks).
2. **Trust placement.** Only the kernel runs in kernel mode; mechanism
   every domain's isolation depends on lives in the kernel (on Fiasco
   also in the root service's decoder and placement code). A domain's
   memory, threads and CPU depend on nothing outside itself but the
   kernel. The section explains why the system domain may fault the
   machine and nothing else may.
   *Draws on:* [design.md, Trust placement](../design.md#trust-placement).
3. **Facets: authority as processes.** A facet is a process of the system
   domain that stands for one grant to one domain and acts only for it.
   Every service entry between domains starts at a declared facet, and a
   new need has one of three homes: an inspection path, a file tree its
   owner serves, or a declared protocol. The section explains why that
   rule keeps authority an allow-list.
   *Draws on:* [design-domains.md, Facets](../design-domains.md#facets),
   [design-system.md, Facets a configured domain serves](../design-system.md#facets-a-configured-domain-serves).
4. **Principals, sessions and quotas.** A user is a principal with a
   budget, a group, quotas and sessions; logging in gives a domain with a
   memory quota and a CPU share, with no container runtime. Exhausting
   either ends or slows only that domain.
   *Draws on:* [design-domains.md, Principals, sessions and quotas](../design-domains.md#principals-sessions-and-quotas),
   [design-system.md, Resource policy](../design-system.md#resource-policy).
5. **Machine code and W^X.** No mapping is writable and executable at
   once and the kernel writes no machine code; the right to make code
   follows from the image, and the trusted base makes none. On Fiasco a
   patch to its mapping code gives the first half (FD8).
   *Draws on:* [design.md, Machine code](../design.md#machine-code),
   [design-fiasco.md, Downsides against erXos's kernel](../design-fiasco.md#downsides-against-erxoss-kernel).
6. **Keys, the vault and cryptography.** Keys stay in a vault, sealed per
   principal; a domain authenticates through a key facet that signs one
   protocol's input for one purpose, after Plan 9's factotum. OpenSSL 3.5
   in two of three runtime images, seeding from the kernel's entropy, and
   a small verifier for update signatures.
   *Draws on:* [design-system.md, The vault](../design-system.md#the-vault),
   [design-crypto.md, Three runtime images, and OpenSSL in two of them](../design-crypto.md#three-runtime-images-and-openssl-in-two-of-them).
7. **Text from untrusted sources.** Raw control characters on a terminal
   are an attack on the operator's host, so every sink that shows text
   (the kernel log, a console line, a window, the browser) has one
   escaping function, generated from one table. A program's own output
   is not such text and reaches its tty unchanged, as on UNIX.
   *Draws on:* [design-live.md, Escape rules](../design-live.md#escape-rules),
   [design-generation.md, Escape rules](../design-generation.md#escape-rules).
8. **Development builds and the security closure.** Until the closure,
   every build runs trusted code only and says so at boot. The section
   explains what 0.2's closure on Fiasco consists of (the release's
   Fiasco build, the system-call fuzz campaign, the upstream watch) and
   what a hostile app can still do on Fiasco.
   *Draws on:* [design-fiasco.md, The security closure](../design-fiasco.md#the-security-closure),
   [design-fiasco.md, What a hostile app can do](../design-fiasco.md#what-a-hostile-app-can-do).

**Figures.** 11.1: the trust map: kernel, root service, system domain,
driver domains, other domains, sub-spaces, with arrows for "depends on".
11.2: a facet between a domain and a service. 11.3: the escape function at
each text sink.

### Chapter 12. Memory and Budgets

*About 38 pages.* Every kernel allocation is charged to a budget carved
from its parent's; delete a budget, and everything charged to it goes,
at once.

**Background needed.** Chapters 1 (virtual memory) and 8.

**Background boxes.** Page tables, the TLB and page faults recalled from
chapter 1. Copy-on-write and fork. Space banks, the idea behind budgets.

**Status.** Built: domains in their own spaces, memory objects and
mappings over Fiasco, the root's page accounting as far as the backend
implements it (the chapter's writer checks the range table and pool in
the tree). Built (host): erXos's budget arithmetic and page funnel,
checked by CBMC. 0.2: budgets as walls for kernel memory through a Fiasco
factory per domain budget. Phase 2: every kernel allocation charged to a
budget, by erXos's kernel.

1. **Budgets as space banks.** A budget has a guarantee, memory set aside
   that no other budget can take, and a cap, up to which it spends what
   its ancestors have promised to no one. A domain's budgets are walls,
   cap equal to guarantee, so it is admitted or refused at its own budget
   alone. The section tells EROS's idea and why it makes ending a domain
   one operation.
   *Draws on:* [design-kernel.md, Budgets](../design-kernel.md#budgets),
   [design.md, Resource limits](../design.md#resource-limits).
2. **Own and outer budgets.** Each domain gets two budgets side by side:
   the own budget pays for what the domain alone maps and dies with it;
   the outer budget pays for what other domains map for it, each
   connection through a child budget, and for its crash area. This is how
   what must outlive a party is charged to a budget that outlives it.
   *Draws on:* [design-system.md, Ending a domain](../design-system.md#ending-a-domain).
3. **Spaces, memory objects and mappings.** A mapping never allows more
   than the capability that made it: each keeps a ceiling fixed from that
   capability's rights. Trimming never meets sharing: only private memory
   is freed by range, and each private page is mapped exactly once.
   *Draws on:* [design-kernel.md, Memory](../design-kernel.md#memory),
   [design-kernel.md, Virtual memory](../design-kernel.md#virtual-memory).
4. **Copy-on-write children and sub-spaces.** A child shares only
   immutable pages and reserves every page it may copy when it is
   created; a sub-space a domain creates for code it runs holds only what
   its creator gave it and ends with its creator.
   *Draws on:* [design-kernel.md, Copy-on-write children and copies of spaces](../design-kernel.md#copy-on-write-children-and-copies-of-spaces),
   [design-kernel.md, Creating spaces](../design-kernel.md#creating-spaces).
5. **Deleted memory faults.** Deleting an object invalidates every
   capability to it at once, and memory mapped from it faults from then
   on, so no server maps what a client can delete. The section shows how
   this shapes shared mappings and the session's mapper.
   *Draws on:* [design.md, Decisions](../design.md#decisions),
   [design-files.md, Shared mappings](../design-files.md#shared-mappings).
6. **Memory on Fiasco.** The root's page pool and range table, budgets and
   groups kept as records in the root, and what Fiasco's own kernel memory
   leaves uncharged (FD5, FD14, FD25).
   *Draws on:* [design-fiasco.md, Budgets and the ownership of pages](../design-fiasco.md#budgets-and-the-ownership-of-pages),
   [design-fiasco.md, Memory and budgets](../design-fiasco.md#memory-and-budgets).

**Figures.** 12.1: a budget tree with guarantees and caps, a wall marked.
12.2: own and outer budgets of two connected domains. 12.3: a mapping and
its ceiling.

### Chapter 13. Native Programs, Pipes and POSIX-lite

*About 34 pages.* UNIX programs where they pay: a native program is a
port of its session, running in a sub-space with only what it was
handed.

**Background needed.** Chapters 1, 2, 9, 10 and 12.

**Background boxes.** Executable files (ELF), loaders and linking. What
POSIX is and what a POSIX-like layer promises. Signals, process groups
and job control as a UNIX user knows them. File descriptors and pipes.

**Status.** Built: programs in sub-spaces with a channel and a handler,
pipes in user space, signals and errno with FreeBSD's numbers, toybox
applets, programs in pipelines with Erlang commands. Not built: terminal
input for programs, sockets for programs, the POSIX-lite layer as a
whole (0.2 has the rest of track P on Fiasco).

1. **A program is a port.** To its session's Erlang, a native program is
   a port: owned by a process, linked, closed with its owner, reporting
   `{exit_status, N}`. It runs in a sub-space with no domain id, facet or
   connection; its one way out is its channel.
   *Draws on:* [design-programs.md, A program is a port](../design-programs.md#a-program-is-a-port),
   [design-programs.md, The channel](../design-programs.md#the-channel).
2. **The handler.** Every request a program makes is a message to its
   handler, an Erlang process of the session that serves it with the
   session's authority after checking the program's own table. A program
   starts only what its `/bin` lists, and never runs a file it could
   rewrite.
   *Draws on:* [design-programs.md, The handler](../design-programs.md#the-handler),
   [design-programs.md, What a program can start](../design-programs.md#what-a-program-can-start).
3. **Pipes in user space.** A pipe is a ring in memory that the session's
   pipe server maps into both ends, with IRQ objects as doorbells; end of
   stream follows from who holds the ends, because the session alone
   installs every end and records each holder. Weak-memory litmus tests
   check the pipe's lock under Arm's memory model.
   *Draws on:* [design-pipes.md, The ring](../design-pipes.md#the-ring),
   [design-pipes.md, Ends and their holders](../design-pipes.md#ends-and-their-holders),
   [design-pipes.md, The pipe server](../design-pipes.md#the-pipe-server).
4. **Signals, job control and FreeBSD's numbers.** Signals arrive through
   vCPU upcalls; `kill` is answered by the handler and a program reaches
   only itself; errno and signal numbers are FreeBSD's, generated from the
   ABI's tables.
   *Draws on:* [design-programs.md, Signals in liberx](../design-programs.md#signals-in-liberx),
   [design-programs.md, Signal numbers](../design-programs.md#signal-numbers),
   [design-programs.md, Job control](../design-programs.md#job-control).
5. **The POSIX-lite personality and toybox.** What a recompiled FreeBSD
   program gets (descriptors, files with 64-bit offsets, pipes, signals),
   what it does not, and why full POSIX compliance is not the bar. Toybox
   supplies the applets; the file utilities (`cat`, `ls`, `cp`) are
   Erlang commands instead.
   *Draws on:* [design-programs.md, The POSIX-lite personality](../design-programs.md#the-posix-lite-personality),
   [design-programs.md, toybox](../design-programs.md#toybox).
6. **A second tier toward QNX.** How the program model grows: what a
   program may start, the cost of a program, and the second tier.
   *Draws on:* [design-programs.md, The second tier](../design-programs.md#the-second-tier),
   [design-programs.md, The cost of a program](../design-programs.md#the-cost-of-a-program).

**Figures.** 13.1: a session with two programs in sub-spaces, their
channels, handlers and a pipe between them. 13.2: the life of `find |
wc` from the shell's line to `$status`.

---

## Part IV. The I/O System

### Chapter 14. Files, Namespaces and Service Trees

*About 36 pages.* Plan 9's idea, kept whole: each domain sees files
through its own table of file servers, a path is the visible face of a
capability, and every server speaks 9P2000.L.

**Background needed.** Chapters 1, 2, 10 and 11.

**Background boxes.** The UNIX file model: paths, mounts, descriptors.
Plan 9 in a page: per-process namespaces and 9P. RAM file systems.

**Status.** Built: per-domain namespaces, file servers across domains,
`/tmp` on a RAM file system in Erlang, stream files with keepers,
`/proc` as an inspection tree. Designed: an app's own tree at `/svc/NAME`
(the chapter's writer checks which parts are built).

1. **A path is the face of a capability.** There is no global root: a
   domain's namespace is a private table from paths to grants, and each
   file server roots a grant at its subtree, so a path never reaches a
   server the domain does not hold.
   *Draws on:* [design-files.md, Namespaces](../design-files.md#namespaces),
   [design-files.md, Resolving a path](../design-files.md#resolving-a-path).
2. **One file protocol.** 9P2000.L between domains, its codec fuzzed;
   the `erx_fs` behaviour that every Erlang file server implements; Erlang
   clients through `prim_file` and native clients through `liberx`.
   *Draws on:* [design-files.md, The file protocol](../design-files.md#the-file-protocol),
   [design-files.md, Serving: the `erx_fs` behaviour](../design-files.md#serving-the-erx_fs-behaviour).
3. **Narrowing for a program, and shared mappings.** What a program's
   namespace holds and how its starter narrows it; how a session maps one
   file into two programs with one memory object and writes back only
   the pages the kernel reports stored.
   *Draws on:* [design-files.md, Narrowing for a program](../design-files.md#narrowing-for-a-program),
   [design-files.md, Shared mappings](../design-files.md#shared-mappings).
4. **`/tmp`: a file system in Erlang.** A small, complete file server, as
   the reader's first look at the `erx_fs` behaviour from the inside.
   *Draws on:* [design-tmp.md](../design-tmp.md).
5. **State is a file to read, control is a file to write.** Plan 9's rule
   applied to services: what the system observes is an inspection path
   shown at `/proc`; what an app says about itself or what someone
   commands is a file tree its owner serves, with a `status` to read and
   a `ctl` for one-shot control. No `sysctl`: system values are one
   read-only tree with many views.
   *Draws on:* [design-app-trees.md, The tree](../design-app-trees.md#the-tree),
   [design-app-trees.md, Commanding: `ctl`](../design-app-trees.md#commanding-ctl),
   [design-live.md, The /proc tree](../design-live.md#the-proc-tree).
6. **Familiar only where true.** The section closes with the review
   question every familiar surface faces ("what does this promise that it
   does not do?") applied to `/proc`, `/dev` and `/etc/passwd`.
   *Draws on:* [design-app-trees.md, What FreeBSD does](../design-app-trees.md#what-freebsd-does).

**Figures.** 14.1: two domains' namespaces over the same file servers,
showing what each can and cannot reach. 14.2: a 9P2000.L walk, open and
read between domains. 14.3: an app's `/svc/NAME` tree beside `/proc`.

### Chapter 15. Devices and Drivers

*About 52 pages.* A driver is a supervised Erlang process over a thin
device shim; the shim's C is a functional core whose every plan is
checked before it touches the hardware.

**Background needed.** Chapters 1 (interrupts, DMA, caches), 2, 9 and
10.

**Background boxes.** DMA, cache coherence and IOMMUs, before the DMA
check. Memory-mapped I/O, interrupt controllers and message-signalled
interrupts. PCIe in a page. USB in a page: hubs, descriptors, transfers.
Device trees and firmware. virtio.

**Status.** Built: drivers as Erlang processes (virtio block, net, gpu
and input on QEMU; SD, GENET Ethernet and the firmware framebuffer on the
Pi 4), the device NIF with its round functions and `erx_device_dma_check`,
the device tree reader, the driver supervisor restarting a killed driver.
Built (host): USB's hub and port state machine and decoders, the Pi
header's pin ownership core. 0.2: the PCIe domain and virtio-pci with
MSIs. Phase 2: DMA confined by erXos's kernel through an IOMMU where the
platform has one.

1. **A driver is a process.** Kill the network driver's process
   mid-transfer from the shell; its supervisor restarts it, the device
   is reset, and the shell never notices. The section explains why
   drivers are Erlang (principle 1), what stays in C (the device shim and
   the per-byte primitives) and the driver table that lists every native
   exception with its reason.
   *Draws on:* [design-system.md, Drivers](../design-system.md#drivers),
   [design-system.md, The driver table](../design-system.md#the-driver-table),
   [design.md, Drivers and DMA](../design.md#drivers-and-dma).
2. **The device NIF.** One module, `erx_device`, through which a driver
   reaches registers, descriptors, DMA buffers and interrupts. Its C
   parses nothing a device wrote; each descriptor form (the virtio split
   ring, GENET's register ring, ADMA2 tables) is a pure round function,
   and one effect loop performs reads and checked plans.
   *Draws on:* [design-runtime.md, The device NIF](../design-runtime.md#the-device-nif),
   [design-device-dma.md, The descriptor forms](../design-device-dma.md#the-descriptor-forms).
3. **DMA by devices that are not cache-coherent.** The Pi 4's Ethernet and
   SD controllers read memory without looking in the CPU's caches. Memory
   changes hands in whole cache-writeback granules, and at any moment
   either the CPU or the device is a region's writer, never both; cache
   cleaning, invalidation and barriers follow from that handoff in one
   sequencer; and the device writes over zeros, so a completion never
   returns an earlier request's bytes.
   *Draws on:* [design-device-dma.md, The construction: handoffs of granules](../design-device-dma.md#the-construction-handoffs-of-granules),
   [design-arch-aarch64.md, Cache maintenance](../design-arch-aarch64.md#cache-maintenance).
4. **The plan and its check.** The method at its clearest. A
   descriptor form's core returns either the reads it needs or a decision:
   a plan and the queue's next state. `erx_device_dma_check` checks the
   whole decision before any effect: the state change is one the call
   allows, every write lands in a region the CPU owns, every device
   address and the bytes reachable from it lie inside the domain's DMA
   memory as the device sees it, and every register written is one the
   NIF owns. A plan that fails is a bug in the core, and the call is
   `badarg` with nothing applied. On a platform with no IOMMU, which
   0.2's QEMU `virt` and Raspberry Pi 4 both are, this check is what
   stops a driver bug from aiming a device at kernel memory; the driving
   domain still counts in the trusted base (FD12).
   *Draws on:* [design-device-dma.md, Calls, observations and plans](../design-device-dma.md#calls-observations-and-plans),
   [design-device-dma.md, Device addresses and reach](../design-device-dma.md#device-addresses-and-reach),
   [design-device-dma.md, Register ownership](../design-device-dma.md#register-ownership),
   `otp/erts/emulator/nifs/erxos/erx_device_dma.c`.
5. **Facts the firmware owns.** The device tree the firmware hands over
   is read where it left it: coherence and DMA ranges come from it, and
   a device whose facts are absent or malformed gets no DMA memory rather
   than a guess.
   *Draws on:* [design-device-tree.md](../design-device-tree.md),
   [design-kernel.md, DMA and the IOMMU](../design-kernel.md#dma-and-the-iommu).
6. **Devices that share.** A register page or an interrupt line shared by
   two devices: the unit rule, and the console.
   *Draws on:* [design-shared-devices.md, The unit rule](../design-shared-devices.md#the-unit-rule).
7. **PCIe and USB.** The PCIe domain alone reaches configuration space
   and holds nothing else; its enumerator, in Erlang, plans the bus whole
   (sizing, placement, interrupts) before it writes. USB's construction:
   every port is a hub port, hotplug ends at the controller's domain, a
   device's name dies at once and its hardware is freed only on the
   controller's report.
   *Draws on:* [design-pcie.md, The construction](../design-pcie.md#the-construction),
   [design-pcie.md, The PCIe domain](../design-pcie.md#the-pcie-domain),
   [design-usb.md, The construction](../design-usb.md#the-construction).
8. **The Raspberry Pi 4's own devices.** The 40-pin header (GPIO, I2C,
   SPI, PWM) and the firmware's sensor readings at `/proc/sensors`, as
   examples of small drivers under the same rules.
   *Draws on:* [design-header-io.md](../design-header-io.md),
   [design-board-sensors.md](../design-board-sensors.md).

**Figures.** 15.1: a driver domain: supervisor, driver process, device
NIF, device, interrupts. 15.2: a call through the device NIF: rounds of
observation and decision, the check, the sequencer's maintenance and
barriers, the effects. 15.3: a region's writer passing between CPU and
device across a post and a completion. 15.4: the PCIe domain and the
domains it gives devices to.

### Chapter 16. Storage and Updates

*About 44 pages.* Releases ship as read-only images checked block by
block, data lives in a file system written in Erlang, and an update
leaves a bootable system whatever happens.

**Background needed.** Chapters 1, 14 and 15.

**Background boxes.** Block devices, partitions and the SD card.
File-system design: logs, flash translation and why flash wears (F2FS,
littlefs, EROFS). A/B updates and chains of hashes from boot to system
image.

**Status.** Built: the storage domain serving `/data` from littlefs
over virtio block and the Pi 4's SD card, restarting cleanly after a
driver is killed mid-transfer; the EROFS reader; the build's system
partition with its dm-verity hash tree; FAT for the card's boot volume.
Built (host): the F2FS codec and mount core. 0.2: A/B updates with a
trial boot, the `system` tree, littlefs under its release contract.
After 0.2: erXos's F2FS replacing littlefs (M13).

1. **Storage as a service.** Storage runs in a domain of its own, in
   Erlang, over the block driver; a bug in a file system crashes a
   process, not the machine.
   *Draws on:* [design-storage.md, Overview](../design-storage.md#overview).
2. **Read-only system images.** A slot's system partition is an EROFS
   image with a dm-verity hash tree after it; every block the reader
   parses is checked against the tree's root hash first, and a block
   that does not match reads as an error.
   *Draws on:* [design-storage.md, Reading EROFS images](../design-storage.md#reading-erofs-images),
   [design-storage.md, The `system` tree](../design-storage.md#the-system-tree).
3. **littlefs: a stopgap with a release contract.** Where it runs, what
   it holds, what input reaches it, what its failure ends and which fuzz
   targets cover it: the contract a shipped stopgap commits to, and no
   more.
   *Draws on:* [design-stopgap.md, Release contract](../design-stopgap.md#release-contract).
4. **erXos's F2FS.** The main read-write file system, in Erlang: the
   durable view is never overwritten, one process owns a volume, and
   recovery replays from a checkpoint. Crash states serve as the oracle,
   and a power-cut harness checks them.
   *Draws on:* [design-f2fs.md, The construction](../design-f2fs.md#the-construction),
   [design-f2fs.md, The crash states as the oracle](../design-f2fs.md#the-crash-states-as-the-oracle),
   [design-f2fs.md, The power-cut harness](../design-f2fs.md#the-power-cut-harness).
5. **Removable media and the SD controller.** FAT for removable media and
   the card's boot volume; the SD host controller driver on the Pi 4.
   *Draws on:* [design-storage.md, Removable media: FAT](../design-storage.md#removable-media-fat),
   [design-storage.md, The SD host controller](../design-storage.md#the-sd-host-controller).
6. **Updates through two slots.** An update's whole state is the
   boot-selection record: `normal(C)` boots the committed slot and lets
   the spare be written; `trial(S)` boots the spare once, after which the
   machine returns to C unless S is committed. A spare is bootable only
   if it verifies at boot, so a half-written spare needs no record of its
   own.
   *Draws on:* [design-storage.md, System updates](../design-storage.md#system-updates),
   [design-platforms.md, Slots and the boot-selection record](../design-platforms.md#slots-and-the-boot-selection-record).

**Figures.** 16.1: the card's partitions (record, boot and system slots,
vault, data). 16.2: the boot-selection record as a state machine. 13.3:
an EROFS read checked against the hash tree.

---

## Part V. Communication

### Chapter 17. The Network Stack

*About 50 pages.* FreeBSD's default TCP/IP stack, redesigned as
idiomatic Erlang: matching FreeBSD's observable behaviour is the
acceptance test, and the structure is new.

**Background needed.** Chapters 1, 3, 6 and 15.

**Background boxes.** TCP/IP in one chapter's worth: layers, Ethernet,
ARP, IP, ICMP, UDP, TCP and DNS. How TCP works: windows, retransmission
and congestion control. DHCP and NTP.

**Status.** Built: `erx_net` in a network domain (Ethernet, ARP, IPv4,
IPv6 neighbour discovery, ICMP, UDP, TCP, DHCP) over virtio-net and the
Pi 4's GENET, `ifconfig`, `ping`, `host`, `gen_tcp` in and out, NTP.
Not built: sockets for native programs. The fast path and the stack's
full verification against FreeBSD belong to M14 (the chapter's writer
checks which parts of each have landed).

1. **Why FreeBSD's stack, and why not a translation.** What the stack
   matches, why FreeBSD's default stack and not another, and what a naive
   Erlang stack gets wrong (timers per connection, unbounded queues,
   bytes parsed again at every layer).
   *Draws on:* [design-network-stack.md, Why FreeBSD's default stack](../design-network-stack.md#why-freebsds-default-stack),
   [design-network-stack.md, What a naive Erlang stack gets wrong](../design-network-stack.md#what-a-naive-erlang-stack-gets-wrong).
2. **The construction.** One owner, one step; deadlines, not timers;
   credited queues; packets become checked records once, and sequence
   numbers are integers. Each rule and the class of bug it removes.
   *Draws on:* [design-network-stack.md, The construction](../design-network-stack.md#the-construction).
3. **The packet path.** The process tree, receiving and classifying a
   frame, transmitting, framing, and checksums computed in the copy.
   *Draws on:* [design-network-stack.md, Processes and the packet path](../design-network-stack.md#processes-and-the-packet-path).
4. **The TCP core.** A pure state machine with the control block, events
   and the step; output, timers, the send log with SACK and reassembly,
   loss detection and congestion control; checked by exhaustive
   exploration and by packet scripts run against FreeBSD.
   *Draws on:* [design-network-stack.md, The TCP core](../design-network-stack.md#the-tcp-core),
   [design-network-stack.md, Packet scripts against FreeBSD](../design-network-stack.md#packet-scripts-against-freebsd).
5. **The fast path.** What was measured, why the cost is architectural,
   and the construction that answers it: runs of segments, merged
   receives, batching and the lean step.
   *Draws on:* [design-network-stack.md, The fast path](../design-network-stack.md#the-fast-path).
6. **Sockets act for one domain.** Who holds the network device, the
   grant, ports and the demultiplexing table; the interface towards
   Erlang (`socket`, `gen_tcp`, name resolution) and towards POSIX
   programs; and why the trusted base parses no network traffic.
   *Draws on:* [design-network-stack.md, Authority and admission](../design-network-stack.md#authority-and-admission),
   [design-network-stack.md, Sockets act for one domain](../design-network-stack.md#sockets-act-for-one-domain).
7. **Time from the network.** NTP and the clock service: the approximate
   start, the real-time clock at boot, and who may set the clock.
   *Draws on:* [design-time.md, The construction](../design-time.md#the-construction).

**Figures.** 17.1: the network domain's process tree. 17.2: a received
segment from driver to socket, with the copies counted. 17.3: the TCP
core as state, event, step and actions.

### Chapter 18. WiFi

*About 12 pages.* The Raspberry Pi 4's WiFi chip, driven from Erlang, as
a study in pure protocol cores.

**Background needed.** Chapters 3 and 6 (state machines as pure cores),
chapter 15 (drivers and devices), chapter 17 (the network stack).

**Status.** Built (host): WiFi's join machine, SAE exchange and
EAPOL-Key codec. No radio driver runs on a board.

1. **WiFi on the CYW43455.** What the chip offers, where its firmware is
   trusted and where it is not, and the driver's place beside the network
   stack.
   *Draws on:* [design-wifi.md](../design-wifi.md).
2. **The join machine.** Scanning, authentication, association and the
   states between them as a pure state machine that returns the next
   action.
   *Draws on:* [design-wifi.md](../design-wifi.md).
3. **SAE and the key exchange.** WPA3's password exchange and the
   EAPOL-Key handshake as pure cores, and the keys they leave.
   *Draws on:* [design-wifi.md](../design-wifi.md),
   [research-wifi-iwd.md](../research-wifi-iwd.md).
4. **Testing a radio without a lab.** Host tests of the cores against
   recorded exchanges, and what only a board can tell.
   *Draws on:* [research-wifi-pi4.md](../research-wifi-pi4.md).

**Background boxes.** How WiFi works: access points, networks, scanning,
association and the frames that carry them. WPA2 and WPA3 in one page:
what a pairwise key is and what the four-way handshake proves. Why a
chip's firmware is a trusted blob.

**Figures.** 18.1: the WiFi join machine. 18.2: the key exchange as a
sequence between station and access point.

### Chapter 19. Bluetooth

*About 12 pages.* The Raspberry Pi 4's Bluetooth controller, driven from
Erlang, with Low Energy and the peripheral role first.

**Background needed.** Chapters 3 and 6 (supervised processes, pure
cores), chapter 15 (drivers and devices).

**Status.** Built (host): Bluetooth's HCI codec and controller process
with its line, links and patch reader. No radio driver runs on a board.

1. **Bluetooth Low Energy, peripheral first.** What the role is, what
   erXos offers a phone that connects to it, and what comes later.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md).
2. **The HCI codec.** The commands, events and data packets between host
   and controller, parsed once into checked records.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md).
3. **The controller process.** The line to the chip, links, the patch
   reader that loads the controller's firmware, and the supervision of
   all three.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md).
4. **Testing a radio without a lab.** Host tests of the cores, a Bumble
   test peer, and what only a board can tell.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md),
   [research-wifi-pi4.md](../research-wifi-pi4.md).

**Background boxes.** How Bluetooth Low Energy works: advertising,
connections, roles and the attribute protocol. The host controller
interface: why a host talks to a controller chip over a serial line.

**Figures.** 19.1: the Bluetooth controller process and its line to the
chip. 19.2: advertising, connecting and one attribute read as a sequence.

---

## Part VI. The User's Machine

### Chapter 20. The Command Shell and the UNIX Surface

*About 36 pages.* The system feels like UNIX, as QNX and Plan 9 do,
wherever that is also how it works.

**Background needed.** Chapters 1, 3, 13 and 14.

**Background boxes.** What a shell does: parse, expand, start, connect
with pipes. Terminals, ttys and the line discipline. SSH in a page: keys
and channels. The rc shell of Plan 9.

**Status.** Built: rc written in Erlang with job control, Erlang commands
that follow FreeBSD's output, text pipes, the start table and `service`,
SSH login for root in development builds, ttys per terminal master.
Built (host): the line discipline `erx_tty`. 0.2: the SSH domain with
logins and keys, release consoles with a login. Designed: evi, the
screen editor run as `vi`.

1. **UNIX look and feel, honestly.** What a UNIX user already knows is
   kept wherever it fits; where UNIX systems differ, erXos follows
   FreeBSD; and nothing wears the name or shape of something it is not.
   The section shows the rule deciding concrete cases.
   *Draws on:* [design.md, Decisions](../design.md#decisions),
   [overview.md, Familiar tools in a different foundation](../overview.md#familiar-tools-in-a-different-foundation).
2. **rc in Erlang.** rc's language, the command namespace, pipelines of
   text between Erlang commands and native programs, job control, and
   `erl` one command away.
   *Draws on:* [design-shell.md, The language](../design-shell.md#the-language),
   [design-shell.md, Pipelines](../design-shell.md#pipelines),
   [design-shell.md, Job control](../design-shell.md#job-control).
3. **UNIX tools over live Erlang state.** `ps -o pid,rss,comm | sort -rn
   -k2 | head` lists Erlang processes and programs together in FreeBSD's
   text, `-` where a value is not measured; `grep -r error /proc/domains`
   reads the inspector's state as files. Pipes carry text; records live
   in `erl` and the inspector.
   *Draws on:* [design-shell.md, Text commands](../design-shell.md#text-commands),
   [design.md, Signature experiences](../design.md#signature-experiences).
4. **Ttys and the console.** A terminal is a tty; the line discipline
   after FreeBSD's (cooked editing, signals for the foreground group,
   `termios`) is a pure core; the console's lines and the secure line
   that alone opens the system shell.
   *Draws on:* [design-live.md, The tty](../design-live.md#the-tty),
   [design-live.md, The console](../design-live.md#the-console).
5. **Services as FreeBSD starts them.** The start table says what starts
   without a person, and `service` enables, starts and stops as
   FreeBSD's does.
   *Draws on:* [design-apps.md, The start table](../design-apps.md#the-start-table).
6. **An SSH connection is a line.** SSH logins land on the same kind of
   line as the console: the SSH domain, host keys, login keys, channel
   and algorithm policy.
   *Draws on:* [design-ssh.md, An SSH connection is a line](../design-ssh.md#an-ssh-connection-is-a-line),
   [design-ssh.md, The SSH domain](../design-ssh.md#the-ssh-domain).
7. **evi.** A screen editor as a program of the session, and what it
   shows about the terminal stack.
   *Draws on:* [design-vi.md](../design-vi.md).

**Figures.** 20.1: a pipeline mixing Erlang commands and a native
program. 20.2: a tty between a terminal and a session's shells. 20.3: an
SSH login's path to a shell.

### Chapter 21. The Live Machine

*About 36 pages.* Genera's legacy: one inspector shows CPUs, kernel
objects, domains, budgets and processes as live records, each value
marked with who reported it, and code loads into the running machine.

**Background needed.** Chapters 3, 5, 9 and 11.

**Background boxes.** How the BEAM traces a process. Module identity and
what a code hash names. Logging and crash dumps.

**Status.** Built: `erx:i()`, `erx:source/1`, `erx:trace/1`,
`erx:inspect/2`, `/proc`, the host link with `tools/erx load`, `watch`
and `files`, `tools/erx web`, the system log, crash records, unsupported
and partial values on Fiasco. Designed: one timeline of the kernel's and
the runtimes' scheduling decisions (the chapter's writer checks what
Fiasco reports of it).

1. **The machine is an object.** `erx:i()` shows CPUs, threads, groups,
   domains, budgets and processes; `erx:source(Pid)` opens the line a
   process executes; each value carries its reporter.
   *Draws on:* [design-live.md, Inspection](../design-live.md#inspection),
   [design-live.md, Inspection records](../design-live.md#inspection-records).
2. **Never fabricate.** Unknown, partial, unsupported and timed-out values
   are shown as such, each with a test. On Fiasco, another domain's group
   and budget read as unsupported, and say who could not answer.
   *Draws on:* [design-live.md, The /proc tree](../design-live.md#the-proc-tree),
   [design-fiasco.md, Reporting kernel objects](../design-fiasco.md#reporting-kernel-objects).
3. **Tracing.** Processes, messages between domains and kernel events on
   one timeline.
   *Draws on:* [design-live.md, Tracing](../design-live.md#tracing).
4. **Code from the host, named by its hash.** `tools/erx watch`
   recompiles and hot-loads a module into the running machine; the code
   store names a version by its hash, so sharing and rollback fall out
   and a changed byte fails the load.
   *Draws on:* [design-live.md, Code from the host](../design-live.md#code-from-the-host),
   [design-live.md, The code store](../design-live.md#the-code-store),
   [design-live.md, The host link](../design-live.md#the-host-link).
5. **Logs and crash reports.** The system log renders every record as one
   attributed, escaped line; crash reports carry no term, so a report
   never leaks process state; the kernel's crash record survives to the
   next boot.
   *Draws on:* [design-log.md, Reports carry no term](../design-log.md#reports-carry-no-term),
   [design-system.md, The crash record](../design-system.md#the-crash-record).
6. **Attributed text.** Text from a source carries its source, and every
   sink escapes it; the console and the host terminal are the first
   sinks to protect.
   *Draws on:* [design-live.md, Attributed text](../design-live.md#attributed-text).

**Figures.** 21.1: an `erx:i()` screen with reporters marked. 21.2: the
host link: the Mac, the frames, the machine's code store. 21.3: a trace
timeline across two domains.

### Chapter 22. Displays, Windows and the Web

*About 48 pages.* Windows are files, as in Plan 9's rio; an application
describes its interface as a term, and every display, a screen, a panel
or a browser, renders the same stream of changes in its own idiom.

**Background needed.** Chapters 1, 11, 14 and 15.

**Background boxes.** Framebuffers, pixel formats and compositing. GPUs:
command streams, shaders and their page tables. Event-driven GUI
toolkits and widget trees. A browser as a display: WebSocket and canvas.

**Status.** Built: the window server serving windows as files, Plan 9's
draw protocol, virtio-gpu, virtio-input and the Pi's framebuffer drivers
in Erlang, the kiosk dashboard on QEMU and the Pi 4, `erx-lvgl`, the
theme, Doom as an example program; the website's browser demo running
erXos in an AArch64 emulator compiled to WebAssembly. Built (host): the
rio-style window manager's pure core. Designed: the rest of the
browser client, the desktop session, find and act, graphics hardware
(the chapter's writer places each in plan.md).

1. **Windows are files.** A display serves each window as a directory of
   files; a program finds its window at `/dev/draw` and draws with Plan
   9's draw protocol. A window's pixels are a buffer its client writes,
   and the display composes and interprets nothing.
   *Draws on:* [design-display.md, Windows and the window system](../design-display.md#windows-and-the-window-system),
   [design-display.md, The draw connection](../design-display.md#the-draw-connection).
2. **Input routing and the terminal.** The input router, the terminal
   emulator as a program of its session, and output linked to the values
   behind it, as Genera's dynamic windows did.
   *Draws on:* [design-display.md, The input router](../design-display.md#the-input-router),
   [design-display.md, The terminal](../design-display.md#the-terminal).
3. **One interface, every medium.** An Erlang application never draws:
   it sends a tree that says what the widgets are, what they hold and
   which events they raise, and receives events as messages. A screen
   renders it as pixels, a panel as LVGL widgets, a browser as a web
   page; nothing is mirrored.
   *Draws on:* [design-display.md, Widget trees](../design-display.md#widget-trees),
   [design-web.md, UIs: the browser renderer](../design-web.md#uis-the-browser-renderer).
4. **LVGL inside apps, and its release contract.** LVGL runs as a native
   program confined to a buffer; what it may reach, what its failure
   ends, and what it is fuzzed against.
   *Draws on:* [design-display.md, LVGL's release contract](../design-display.md#lvgls-release-contract).
5. **Kiosks, the desktop and a modern look.** A kiosk is an app on a
   display with the single policy; the desktop's programs, the shared
   theme, coverage masks for corners and shadows, and the rio-style
   window manager.
   *Draws on:* [design-display.md, Kiosks and glasses](../design-display.md#kiosks-and-glasses),
   [design-desktop-programs.md](../design-desktop-programs.md).
6. **Find and act.** The desktop session's palette: routes from a value
   on the screen to an rc line.
   *Draws on:* [design-find-act.md, The construction](../design-find-act.md#the-construction).
7. **erXos in a browser.** The website runs erXos under an AArch64
   emulator compiled to WebAssembly, with a menu of hardware faults the
   emulator makes; and the web client, a browser display speaking the
   same protocol as a screen.
   *Draws on:* [design-web.md, The protocol](../design-web.md#the-protocol),
   [site/README.md](../../site/README.md).
8. **Graphics hardware.** What the design asks of a GPU, and the V3D on
   the Pi 4.
   *Draws on:* [design-display.md, Graphics hardware](../design-display.md#graphics-hardware),
   [research-gpu.md](../research-gpu.md).

**Figures.** 22.1: a window's directory of files. 22.2: one widget tree
rendered three ways: screen, LVGL panel, browser. 22.3: the kiosk on the
Pi 4 (a screenshot). 22.4: the browser demo's layers: page, emulator,
erXos.

### Chapter 23. Apps and Packages

*About 28 pages.* An app is a principal with a session template,
installed at run time as one file with its needs declared and checked.

**Background needed.** Chapters 8, 11, 14 and 22.

**Background boxes.** Package managers and manifests. Declared
permissions in app systems, as on a phone.

**Status.** Built: the start table, `erx-app pack` producing a signed
`.app` file with an EROFS image and a dm-verity tree, packages added to
an image (the kiosk and Doom). 0.2: installing, updating and removing at
run time, an app's own session and tree.

1. **An app is a principal.** It gets a session from a template, its
   own budget and its own grants; a user adds apps without editing the
   board's manifest or rebuilding.
   *Draws on:* [design-apps.md, An app](../design-apps.md#an-app).
2. **One file per app.** The package: a signed header, an EROFS image of
   the app's files and a dm-verity tree; what the declaration names
   (memory, code, the grants it needs).
   *Draws on:* [design-packaging.md, The package](../design-packaging.md#the-package),
   [design-packaging.md, The declaration](../design-packaging.md#the-declaration).
3. **Admission.** How a package's declared needs are judged against the
   `apps` row that bounds them, before it runs.
   *Draws on:* [design-packaging.md, Admission](../design-packaging.md#admission).
4. **Installing, updating and removing.** The package lifetime, boot and
   recovery.
   *Draws on:* [design-packaging.md, Installing, updating and removing](../design-packaging.md#installing-updating-and-removing),
   [design-packaging.md, Boot and recovery](../design-packaging.md#boot-and-recovery).
5. **The SDK.** Building an app outside the tree, running its interface
   on the development host under stock OTP, and two examples: the kiosk
   dashboard and Doom.
   *Draws on:* [design-packaging.md, The SDK](../design-packaging.md#the-sdk),
   [design-packaging.md, Examples](../design-packaging.md#examples).

**Figures.** 23.1: a package's layout. 23.2: from `erx-app pack` to a
running app's session.

---

## Part VII. System Operation

### Chapter 24. Startup, Configuration and Shutdown

*About 38 pages.* From the firmware's handover to a login prompt, from
one system manifest, and back down to a reset.

**Background needed.** Chapters 1, 2, 8, 15 and 16.

**Background boxes.** Booting an AArch64 machine: firmware, boot loader,
exception levels. Initial images and boot archives. Watchdog timers.

**Status.** Built: boot on QEMU `virt` (1 to 8 CPUs, HVF and TCG) and the
Raspberry Pi 4 (QEMU `raspi4b` and a real board), the boot image and
bootable file, the root task starting the manifest's domains, the
watchdog, crash records, `reboot` and `halt`, reproducible images. 0.2:
release consoles, trial boots of an update. Planned: the Raspberry Pi 5.

1. **The bootable file and the boot image.** The one file a loader boots
   (Fiasco's `bootstrap` today, erXos's kernel later) with the boot image
   inside it: an archive of everything the machine starts with, accepted
   from one startup plan that the kernel checks before it starts the root
   task.
   *Draws on:* [design-kernel.md, The bootable file](../design-kernel.md#the-bootable-file),
   [design-kernel.md, The boot image](../design-kernel.md#the-boot-image),
   [design-fiasco.md, Boot handoff](../design-fiasco.md#boot-handoff).
2. **The root task's first steps.** `liberx`'s root-task entry takes the
   root capabilities, builds the system domain and starts ERTS, which
   boots OTP and the system release: the domain service, the device
   service, drivers, storage, the network, the console.
   *Draws on:* [design-system.md, The root task](../design-system.md#the-root-task),
   [design-system.md, Boot](../design-system.md#boot).
3. **The system manifest at boot.** How the manifest proved at build time
   (chapter 7) drives what starts: every configured domain created by the
   domain service, every device given to the domain the manifest names,
   ordering and partial boots.
   *Draws on:* [design-system.md, The manifest](../design-system.md#the-manifest),
   [design-abi.md, Ordering and partial boots](../design-abi.md#ordering-and-partial-boots).
4. **Platforms.** QEMU `virt` under HVF and TCG, the Raspberry Pi 4 on
   Fiasco and its firmware, and the Pi 5 to come; the platform layer that
   keeps ports mechanical. Architecture terms stay in this section and in
   the architecture binding.
   *Draws on:* [design-platforms.md, QEMU virt](../design-platforms.md#qemu-virt),
   [design-platforms.md, Raspberry Pi 4 Model B](../design-platforms.md#raspberry-pi-4-model-b),
   [design-platforms.md, The Raspberry Pi 4 on Fiasco](../design-platforms.md#the-raspberry-pi-4-on-fiasco).
5. **The watchdog, crash records and ending the machine.** The kernel's
   one watchdog, petted by the system domain once the services it lists
   answer; the crash record written before the machine ends and shown at
   the next boot; ordered shutdown, `reboot` and `halt`.
   *Draws on:* [design-kernel.md, The watchdog](../design-kernel.md#the-watchdog),
   [design-system.md, Shutting down](../design-system.md#shutting-down),
   [design-platforms.md, Ending the machine](../design-platforms.md#ending-the-machine).
6. **Trust in the boot.** What the boot trusts, entropy at boot and the
   device secret, and the trial request an update makes of the firmware.
   *Draws on:* [design-platforms.md, Trust in the boot](../design-platforms.md#trust-in-the-boot),
   [design-platforms.md, Entropy sources](../design-platforms.md#entropy-sources).

**Figures.** 24.1: the boot sequence from firmware to login prompt, with
the build-time manifest check drawn beside it. 24.2: the boot image's
layout. 24.3: the watchdog's chain of answers.

### Chapter 25. Checking the System

*About 40 pages.* How erXos knows it is right: answers that come from
outside its own code.

**Background needed.** The whole book; chapters 6 and 7 most.

**Background boxes.** Test oracles and differential testing.
Coverage-guided fuzzing and sanitizers. Model checking (TLA+) and
bounded proofs (CBMC). Reproducible builds.

**Status.** Built: `make check-oracle` against stock OTP 29.1.2 and
musl's `libc-test`; TLA+ models of the lane, connections and links;
herd7 litmus tests; CBMC harnesses of the C17 cores; fuzz targets;
sanitizers; chokepoint checks with seeded violations; the stack proof;
reproducible images and deterministic boots; QEMU suites. Planned: the
TLA+ models of the host link's sessions, the update protocol and the
scheduler's cross-CPU protocol; the kernel interface's conformance
suite.

1. **Agreement with ground truth.** Behaviour that disagrees with an
   independent oracle is a bug until it is explained and pinned by a
   test. OTP's own suites run on erXos and on stock OTP in an isolated
   Linux container, compared case by case; musl's tests run against
   erXos's C library.
   *Draws on:* [design.md, Testing and the oracle](../design.md#testing-and-the-oracle),
   [design-host-oracle.md](../design-host-oracle.md).
2. **Seeded faults.** A check proves itself by failing on a planted
   fault: a removed bound, an off-by-one comparison, a dropped fence. The
   section shows seeds for a chokepoint, a TLA+ model, a litmus test and
   a mutated copy of the Fiasco backend.
   *Draws on:* [README.md, Correctness and testing](../../README.md#correctness-and-testing).
3. **Fuzzing every parser of untrusted input.** Each parser lands with
   its fuzz target: the boot image, executable headers, the funnel, the
   9P codec, the shell's parser, device rings, and more. The section
   explains how a target is built from the same sources for the host.
   *Draws on:* [design-verification.md](../design-verification.md).
4. **Models and bounded proofs.** TLA+ checks protocol models with TLC;
   herd7 checks the lane's wake handshake and the pipe's lock under Arm's
   memory model and RC11; CBMC checks budget arithmetic and capability
   code for every input within stated bounds. What each covers and what
   it does not.
   *Draws on:* [design-verification.md, Models and implementations](../design-verification.md#models-and-implementations),
   [design-verification.md, CBMC harnesses and runner](../design-verification.md#cbmc-harnesses-and-runner).
5. **Exhaustive tests of protocol state machines.** Pure cores built for
   the host and explored exhaustively: the TCP core, the USB hub and port
   machine, the window manager.
   *Draws on:* [design-network-stack.md, The TCP core: exhaustive exploration](../design-network-stack.md#the-tcp-core-exhaustive-exploration).
6. **Determinism and reproducibility.** The same inputs give
   byte-identical boot images; a boot in deterministic mode, under
   single-threaded TCG with instruction counting, gives a byte-identical
   transcript.
   *Draws on:* [design-kernel.md, Deterministic mode](../design-kernel.md#deterministic-mode),
   [design-build.md, Processes and evidence](../design-build.md#processes-and-evidence).
7. **Two tiers of gates.** Every commit passes `make check` and the QEMU
   suites it touches; a milestone passes the oracle, the sanitizers, the
   fuzz budgets, the models and the full QEMU suite. Why iteration speed
   comes first and the slow gates run off the landing path.
   *Draws on:* [design-build.md, What the gates run](../design-build.md#what-the-gates-run).

**Figures.** 25.1: the oracles and what each checks. 25.2: a seeded
fault and the check that catches it. 25.3: the gates as two tiers.

---

## Afterword: The Road to erXos's Own Kernel

*About 10 pages.* Phase 2 builds erXos's kernel with every guarantee,
boots the same boot image and replaces Fiasco at parity over 0.2's
system: every row of the downsides table closes on erXos's kernel alone.
The afterword tells what is already built of it (host-built cores checked
by CBMC and the stack proof), how parity is judged (the replacement run
differentially against Fiasco over the test corpus), and what Fiasco's
departure changes for the reader of each chapter. It closes with the
research directions that are recorded and not designed: causal time
travel, durable actors, confined AI workers, declarative services.

*Draws on:* [plan.md, Track K](../plan.md#track-k-erxoss-kernel),
[plan.md, M7](../plan.md#m7-fiasco-leaves),
[research-os-ideas.md](../research-os-ideas.md).

## Appendix A. Glossary

*About 14 pages.* Every term a newcomer meets, in one line, with a
pointer to the chapter or Background box that explains it. It covers
the terms of operating systems (page table, DMA, interrupt, system
call), of microkernels (capability, IPC, rendezvous, root task), of
Erlang and OTP (supervisor, `gen_server`, link, node), of each
chapter's Background box (TCP window, GATT, ELF, 9P), and erXos's own
(domain, facet, lane, budget, funnel), from
[design.md, The model](../design.md#the-model) and the terms each chapter
introduces. A reader who meets a term before its chapter finds it here,
in alphabetical order, with the chapter to turn to. The first version,
[a-glossary.md](a-glossary.md), lists the terms of chapters 1 to 4; each
later chapter adds its own.

## Appendix B. Reading the Design Documents

*About 8 pages.* A reading order for a reader new to the system, what
each design document is for, the common section layout (context, requirements, construction, invariants, failure,
refusals, verification), how decisions, residuals and the roadmap are
split between design documents, `TODO.md` and `plan.md`, and which
chapter leads into which documents.
*Draws on:* [design.md, Document map](../design.md#document-map).

## Appendix C. Building and Booting erXos

*About 8 pages.* Host setup, fetching pinned sources, the oracle
bootstrap, `make check`, booting in QEMU and making a Raspberry Pi 4
card, and hosted mode.
*Draws on:* [README.md, Getting started](../../README.md#getting-started),
[guide/README.md](../guide/README.md), [design-build.md](../design-build.md).

## Appendix D. Dependencies and Licenses

*About 6 pages.* The dependency table and the four statuses (permanent,
release, stopgap, example), why each third-party component pays for
itself, and how licenses and notices travel with every image.
*Draws on:* [design.md, Dependencies](../design.md#dependencies),
[design.md, Licenses and notices](../design.md#licenses-and-notices).

## Appendix E. Lineage

*About 6 pages.* The systems and papers erXos draws on, each with the
idea taken and the chapter where it appears.
*Draws on:* [research-prior-art.md](../research-prior-art.md),
[design.md, References](../design.md#references).

## Decisions

1. **Where the book sits among the documents.** The book is listed in the
   document roles of [CLAUDE.md](../../CLAUDE.md) and in the document map
   of [design.md](../design.md#document-map) as the reader's introduction:
   it cites the design documents and decides nothing. It sits between
   [overview.md](../overview.md) and the design documents, so a review of
   a design change asks whether a chapter needs the same edit.
2. **How the status boxes stay true.** Each chapter's status box is
   checked against README.md's "Current status" at every milestone (0.2,
   then each Phase 2 milestone), in the same commit as the status list. A
   chapter whose box is stale is a documentation bug.
3. **Figures.** Figures are Mermaid where GitHub renders it (sequence and
   state diagrams) and plain-text diagrams in code blocks otherwise.
   Screenshots appear only for the display. The book keeps no drawing
   tool's source files.
4. **Overview and book.** [overview.md](../overview.md) covers the ground
   of chapters 4 and 5 in short. It stays the short introduction, and
   chapter 4 links it.
5. **The reader without background.** Every chapter is written for a
   reader who can program and has no Erlang, operating-system or
   microkernel background. Part I teaches those three subjects; a chapter
   states the background it needs, explains in a Background box what only
   it uses, and never uses a term of those subjects before one of them
   has explained it. Appendix A lists every such term with its place. A
   chapter that needs the reader to know something Part I and its boxes
   do not give is incomplete.
6. **WiFi and Bluetooth have a chapter each.** They share a board and a
   test approach but no protocol, no core and no design document, so
   chapters 18 and 19 stand apart and each carries its own status box.
