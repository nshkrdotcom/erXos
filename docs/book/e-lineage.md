# Appendix E. Lineage

Almost every mechanism in erXos was first built somewhere else. What
erXos adds is the way the mechanisms meet: an Erlang process as the
operating system's process, across address spaces, with Erlang's
semantics kept. [Chapter 4, section 4.3](04-history.md#43-the-lineage)
tells that story for the four sources that shaped erXos most. This
appendix is the reference list behind it. It gives each system or
paper erXos draws on, the idea taken and the chapter where it appears,
then the systems whose failures erXos was designed to avoid.

The evidence is the project's survey of earlier systems,
[research-prior-art.md](../research-prior-art.md), the other records in
[design.md, References](../design.md#references), and each chapter's
"Where to read next". Section E.8 gives the citations.

## E.1 Erlang and its runtimes

| Source | What erXos took, or the contrast it draws | Where |
| --- | --- | --- |
| Erlang/OTP and Armstrong's thesis (2003) | Isolated processes that share nothing, "let it crash" and supervisors as the whole system's failure model, and restarting, after Gray's study of transient faults (1985) | [Chapter 3](03-erlang.md#33-let-it-crash), [chapter 4](04-history.md#41-erlang-systems-as-operating-systems) |
| ERTS, read as described in The BEAM Book (Stenman and others) | Preemption only at function calls and receives, per-process heaps; the runtime as a parts bin taken apart and recombined | [Chapter 3](03-erlang.md#35-the-beam-and-erts), [chapter 9](09-processes.md#94-erts-as-a-parts-bin) |
| Safe Erlang (Brown and Sahlin 1999) | The diagnosis that a pid is "both forgeable and too powerful"; in erXos's design a pid is a name, and a domain reaches another's process only through an export | [Chapter 4](04-history.md#434-eros-safe-erlang-and-zircon-authority-and-payment), [chapter 10](10-domains.md#104-exports-a-pid-is-a-name-not-an-authority), [chapter 11](11-security.md#115-exports-and-the-funnel-authority-over-processes) |
| Nerves and GRiSP | Erlang over a conventional kernel, Linux or RTEMS; erXos moves the walls inside the Erlang system instead | [Chapter 4](04-history.md#414-erlang-below-the-application-tried-before) |
| LING and HydrOS | Erlang with no operating system beneath it, walled by virtual machine or by CPU core; HydrOS's drivers in Erlang | [Chapter 4](04-history.md#414-erlang-below-the-application-tried-before) |

*Table E.1. Sources in Erlang
([research-prior-art.md, Safe Erlang](../research-prior-art.md#safe-erlang),
[Other systems](../research-prior-art.md#other-systems),
[The Erlang runtime](../research-prior-art.md#the-erlang-runtime)).*

## E.2 UNIX and FreeBSD

Where UNIX systems differ, erXos follows FreeBSD. It keeps FreeBSD's
behavior and redesigns the structure, so most entries here are a
behavior kept and an inside replaced.

| Source | What erXos took, or the contrast it draws | Where |
| --- | --- | --- |
| UNIX | Files, processes, text pipes, a shell and small tools as the surface | [Chapter 4](04-history.md#431-unix-and-freebsd-the-surface), [chapter 20](20-shell.md#201-unix-look-and-feel-honestly) |
| McKusick, Neville-Neil and Watson, *The Design and Implementation of the FreeBSD Operating System* (2014) | The arc and manner of this book; the tty layer that `erx_tty` follows | [README.md](README.md#what-the-book-is), [chapter 20](20-shell.md#204-ttys-and-the-console) |
| FreeBSD's `netinet` | The TCP/IP stack's behavior, redesigned as Erlang processes and pure functions | [Chapter 17](17-network.md#171-why-freebsds-stack) |
| FreeBSD's signal and error numbers | The numbers musl and `liberx` give native programs | [Chapter 13](13-native-programs.md#136-signals-job-control-and-freebsds-numbers) |
| FreeBSD's `syscalls.master` | The precedent for generating system-call tables from one file | [Chapter 7](07-one-source.md#72-the-abi-file) |
| FreeBSD's `rc.conf`, `rc.subr` and `service(8)` | How services are configured and started, kept where it fits | [Chapter 20](20-shell.md#205-starting-services), [chapter 23](23-apps.md) |
| FreeBSD's `pkg` | Packages as archives with a manifest, recorded in a database and installed by scripts that run as root; erXos keeps each app one file, runs nothing at install and has no `pkg` commands | [Chapter 23](23-apps.md#232-one-file-per-app) |
| macOS's `/Applications` | Installing by copying a file into a directory, which `cp NAME.app /apps/` follows | [Chapter 23](23-apps.md) |
| FreeBSD's `loader`, `init` and `rcorder(8)` | The contrast for the boot: erXos boots one archive under one hash instead of a loader reading a file system, and derives the boot order once at build time instead of from `REQUIRE` lines at every boot | [Chapter 24](24-startup.md) |
| FreeBSD's `reboot(8)` | The name, `-p` and `halt` as the same program; the flags for things erXos lacks are usage errors | [Chapter 24](24-startup.md#2462-reboot-traced) |
| Capsicum, FreeBSD's capability mode | The contrast: FreeBSD narrows a process's authority after the fact, and erXos starts a program with none | [Chapter 2](02-microkernels.md#236-capability-systems-in-practice), [chapter 11](11-security.md) |
| FreeBSD's `namei` and `tmpfs` | The path lookup and RAM file system that erXos's resolver and `/tmp` follow | [Chapter 14](14-files.md) |
| Baumann and others, "A fork() in the road" (2019) | The case for starting programs with a spawn call, not `fork` | [Chapter 13](13-native-programs.md#133-starting-a-program) |

*Table E.2. Sources in UNIX and FreeBSD.*

## E.3 Microkernels and capabilities

| Source | What erXos took, or the contrast it draws | Where |
| --- | --- | --- |
| L4 (Liedtke 1993, 1995) | A kernel of address spaces, threads and fast IPC, with everything else in user mode | [Chapter 2](02-microkernels.md#251-from-l3-to-sel4) |
| Fiasco (TU Dresden, from 1998) | The kernel itself, behind erXos's kernel interface, with a few small patches | [Chapter 4](04-history.md#432-l4-and-fiasco-the-kernel), [chapter 8](08-kernel-interface.md) |
| L4Re | A root task that creates every program and hands it its capabilities; its loader ned's CPU sets, the model for each domain's designed CPU set | [Chapter 2](02-microkernels.md#253-the-root-task), [chapter 8](08-kernel-interface.md#83-the-root-service-who-holds-what), [chapter 9](09-processes.md#923-cpu-sets-and-thread-limits) |
| Dennis and Van Horn (1966) | The capability: a reference that carries rights | [Chapter 2](02-microkernels.md#232-a-capability-is-a-reference-with-rights) |
| Saltzer and Schroeder (1975) | Least privilege, economy of mechanism and complete mediation | [Chapter 6](06-construction.md), [chapter 11](11-security.md) |
| Hardy, "The Confused Deputy" (1988) | The problem that facets and minted handles answer | [Chapter 2](02-microkernels.md#234-the-confused-deputy), [chapter 11](11-security.md#116-facets-authority-over-services) |
| KeyKOS and EROS (Shapiro, Smith and Farber 1999) | The space bank, which ends everything it paid for when it ends: erXos's budgets | [Chapter 2](02-microkernels.md#236-capability-systems-in-practice), [chapter 12](12-memory.md#121-budgets-as-space-banks) |
| Zircon, Fuchsia's kernel | Handles with rights that only shrink; no ambient authority | [Chapter 2](02-microkernels.md#236-capability-systems-in-practice), [chapter 10](10-domains.md) |
| Genode | Each session paid from a quota its client donates; erXos's memory shares for users | [Chapter 4](04-history.md#43-the-lineage) |
| MINIX 3 | A reincarnation server that restarts a failed driver, the microkernel form of a supervisor | [Chapter 2](02-microkernels.md#214-mach-qnx-minix-and-l4) |
| QNX | A UNIX look over a microkernel | [Chapter 2](02-microkernels.md#214-mach-qnx-minix-and-l4), [chapter 4](04-history.md#431-unix-and-freebsd-the-surface) |
| seL4 | The alternative not taken: a kernel proved correct (Klein and others 2009); its device driver framework, sDDF, for splitting a driver from its policy | [Chapter 6](06-construction.md), [chapter 15](15-devices.md#1510-design-choices) |

*Table E.3. Sources in microkernels and capability systems
([research-kernel-bases.md](../research-kernel-bases.md),
[research-architecture.md](../research-architecture.md) for Genode).*

## E.4 Plan 9 and Inferno

Plan 9 shaped how erXos's names, files and windows work; how they
look is erXos's own.

| Source | What erXos took, or the contrast it draws | Where |
| --- | --- | --- |
| Plan 9's namespaces and 9P (Pike and others 1993, 1995) | A private table from paths to file servers per domain, and one file protocol, 9P2000.L | [Chapter 14](14-files.md#141-a-path-is-the-face-of-a-capability) |
| Plan 9's file conventions | State is a file to read, control a file to write | [Chapter 14](14-files.md#145-state-is-a-file-to-read-control-is-a-file-to-write) |
| rc, Plan 9's shell (Duff) | The command shell's language | [Chapter 20](20-shell.md#202-rc-in-erlang) |
| 8½ and rio (Pike 1991), and the draw protocol | Each window a directory of files; the draw protocol, executed in the client; the overlapping window policy | [Chapter 22](22-display.md#221-windows-are-files) |
| The plumber | Routes from a value on the screen to an action, in find and act | [Chapter 22](22-display.md#226-find-and-act) |
| factotum (Cox and others 2002) | A key holder that signs or answers but never gives up the key: the vault, and the WiFi key holder | [Chapter 11](11-security.md#1111-keys-the-vault-and-cryptography), [chapter 18](18-wifi.md#183-keys) |
| Inferno (Dorward and others 1997) | A virtual machine at the center; erXos adds hardware walls | [Chapter 4](04-history.md#43-the-lineage) |

*Table E.4. Sources in Plan 9 and Inferno.*

## E.5 Live and language-based systems

| Source | What erXos took, or the contrast it draws | Where |
| --- | --- | --- |
| Genera, the Symbolics Lisp machine environment (Walker and others 1987) | A live machine, every object examinable and code patched as it runs; output bound to its value | [Chapter 21](21-live-machine.md#211-the-machine-is-an-object), [chapter 22](22-display.md#2224-output-that-remembers-its-value) |
| Singularity (Hunt and Larus 2007; Aiken and others 2006) | Evidence that protection crossings, not safety checks, dominate the cost of isolation; hence many processes per address space | [Chapter 4](04-history.md#43-the-lineage), [chapter 8](08-kernel-interface.md#81-what-the-kernel-knows-and-what-it-does-not) |
| Midori (Duffy, blog) | Erlang's supervisors as a whole system's failure model, found outside Erlang | [Chapter 4](04-history.md#43-the-lineage) |
| Barrelfish (Baumann and others 2009) | Hardware facts as data, and a plan kept apart from the register writes: the checked system manifest and the one ABI file | [Chapter 6](06-construction.md), [chapter 7](07-one-source.md#710-where-logic-languages-fit-and-where-they-do-not) |
| BOOM (Berkeley) | Systems as rules over state and events; why a logic language is allowed where it simplifies, though erXos uses no Datalog | [Chapter 7](07-one-source.md#710-where-logic-languages-fit-and-where-they-do-not) |
| Minsky; Bernhardt | "Make illegal states unrepresentable"; "functional core, imperative shell" | [Chapter 6](06-construction.md#63-functional-core-effects-at-the-edge) |

*Table E.5. Sources in live and language-based systems
([research-prior-art.md, Genera](../research-prior-art.md#genera),
[Singularity](../research-prior-art.md#singularity),
[research-os-ideas.md](../research-os-ideas.md)).*

## E.6 Devices, storage, networks and radios

| Source | What erXos took, or the contrast it draws | Where |
| --- | --- | --- |
| OASIS, VIRTIO 1.2 (2022) | The device rings of QEMU's devices | [Chapter 15](15-devices.md) |
| F2FS (Lee and others 2015) | The read-write file system's design, implemented in Erlang | [Chapter 16](16-storage.md#164-erxoss-f2fs) |
| littlefs | The small file system that the storage domain runs as a NIF | [Chapter 16](16-storage.md#163-littlefs-in-the-storage-domain) |
| Merkle's hash tree (1987) | Each block of a read-only system image checked against one root hash | [Chapter 16](16-storage.md#162-read-only-system-images) |
| The Raspberry Pi firmware's `tryboot` | Updates through two slots and a trial boot | [Chapter 16](16-storage.md#166-updates-through-two-slots) |
| OpenBSD's `bwfm(4)` | The WiFi driver's model, the chip's supplicant off | [Chapter 18](18-wifi.md#181-wifi-on-the-cyw43455) |
| Fuchsia's WLAN stack | Policy apart from the state machine, its transitions written once | [Chapter 18](18-wifi.md#182-the-station-three-pure-parts) |
| wpa_supplicant | The states of SAE's public half | [Chapter 18](18-wifi.md#183-keys) |
| Cheshire and Baker, COBS (1999) | The framing of the host link over a serial line | [Chapter 21](21-live-machine.md#214-code-from-the-host-named-by-its-hash) |

*Table E.6. Sources for devices and I/O
([design-wifi.md, Lineage](../design-wifi.md#lineage) holds the full
WiFi table).*

## E.7 Lessons taken as warnings

Each failure or refused mechanism below shaped a rule of erXos.

* **Scheduler activations and M:N threading** (Anderson and others
  1991). Upcalls arrived at any point, and a lock holder preempted by
  an upcall had to be resumed specially before anything else could
  run; NetBSD 5.0 and FreeBSD 7.0 moved to one kernel thread per user
  thread. erXos keeps two levels of scheduling but sends no upcall to
  a thread that runs Erlang processes
  ([chapter 4, section 4.2](04-history.md#42-thirty-years-of-two-level-scheduling),
  [chapter 9](09-processes.md)).
* **Akaros** took a core away at any line, even under a lock. The
  same rule answers it ([chapter 4](04-history.md#423-why-erxos-keeps-two-levels)).
* **Time donation, as in seL4's passive servers.** A client lends its
  CPU time to the server working for it. erXos's services run on their
  own threads, so no domain's scheduling depends on another's
  ([chapter 9](09-processes.md)).
* **SPIN** (Bershad and others 1995). A crashed kernel extension
  could leave the system inconsistent; erXos runs everything but the kernel in user mode
  ([chapter 4](04-history.md#43-the-lineage)).
* **The eBPF verifier.** Proving loaded code safe puts a verifier in
  the trusted base, and its bugs become kernel exploits. erXos runs
  untrusted code behind hardware walls instead
  ([chapter 11](11-security.md#112-trust-placement)).
* **Speculative execution.** One address space keeps no secrets, as
  the V8 team concluded (McIlroy and others 2019). Domains that do
  not trust each other are separate address spaces
  ([chapter 4](04-history.md#43-the-lineage)).
* **Genera's open core.** With no protected kernel, users reached for
  primitives not theirs to touch. erXos adds walls to the live machine ([chapter 21](21-live-machine.md#211-the-machine-is-an-object)).

## E.8 Citations

The works named above, as the tree records them;
[research-prior-art.md](../research-prior-art.md) and the chapters'
"Where to read next" give addresses. A detail no document in the tree
confirms carries a note for the book's checker.

* M. Aiken, M. Fähndrich, C. Hawblitzel, G. Hunt and J. Larus,
  "Deconstructing Process Isolation", MSPC 2006.
* Thomas Anderson, Brian Bershad, Edward Lazowska and Henry Levy,
  "Scheduler Activations: Effective Kernel Support for the User-Level
  Management of Parallelism", SOSP 1991; ACM TOCS 10(1), 1992.
* Joe Armstrong, *Making Reliable Distributed Systems in the Presence
  of Software Errors*, PhD thesis, Royal Institute of Technology,
  Stockholm, 2003.
* Andrew Baumann and others, "The Multikernel: A New OS Architecture
  for Scalable Multicore Systems", SOSP 2009.
* Andrew Baumann, Jonathan Appavoo, Orran Krieger and Timothy Roscoe,
  "A fork() in the road", HotOS 2019.
* Brian Bershad and others, "Extensibility, Safety and Performance in
  the SPIN Operating System", SOSP 1995.
* Lawrie Brown and Dan Sahlin, "Extending Erlang for Safe Mobile Code
  Execution", ICICS 1999, LNCS 1726.
* Stuart Cheshire and Mary Baker, "Consistent Overhead Byte Stuffing",
  *IEEE/ACM Transactions on Networking* 7(2):159-172, 1999.
* Russ Cox, Eric Grosse, Rob Pike, Dave Presotto and Sean Quinlan,
  "Security in Plan 9", USENIX Security 2002.
* Jack Dennis and Earl Van Horn, "Programming Semantics for
  Multiprogrammed Computations", *Communications of the ACM* 9(3),
  1966.
* Sean Dorward and others, "The Inferno Operating System", *Bell Labs
  Technical Journal* 2(1), 1997.
* Tom Duff, "Rc - The Plan 9 Shell".
* J. Duffy, the Midori blog series, 2015 to 2016 (a secondary
  source).
* Kevin Elphinstone and Gernot Heiser, "From L3 to seL4: What Have We
  Learnt in 20 Years of L4 Microkernels?", SOSP 2013.
* Jim Gray, "Why Do Computers Stop and What Can Be Done About It?",
  Tandem Computers Technical Report 85.7, 1985.
* Norm Hardy, "The Confused Deputy (or why capabilities might have been
  invented)", *ACM SIGOPS Operating Systems Review* 22(4), 1988.
* Galen Hunt and James Larus, "Singularity: Rethinking the Software
  Stack", *ACM SIGOPS Operating Systems Review* 41(2), 2007.
* Gerwin Klein and others, "seL4: Formal Verification of an OS
  Kernel", SOSP 2009.
* Changman Lee, Dongho Sim, Joo-Young Hwang and Sangyeun Cho, "F2FS: A
  New File System for Flash Storage", USENIX FAST 2015.
* Jochen Liedtke, "On µ-Kernel Construction", SOSP 1995, which cites
  his 1993 paper on L3.
* R. McIlroy, J. Sevcik, T. Tebbi, B. L. Titzer and T. Verwaest, "Spectre is here to stay", arXiv:1902.05178, 2019.
* Marshall Kirk McKusick, George Neville-Neil and Robert Watson, *The
  Design and Implementation of the FreeBSD Operating System*, 2nd
  edition, Addison-Wesley, 2014.
* Ralph Merkle, "A Digital Signature Based on a Conventional
  Encryption Function", CRYPTO '87, pp. 369-378.
* OASIS, *Virtual I/O Device (VIRTIO) Version 1.2*, 2022.
* Rob Pike, "8½, the Plan 9 Window System", Proceedings of the Summer
  1991 USENIX Conference.
* Rob Pike, Dave Presotto, Sean Dorward, Bob Flandrena, Ken Thompson,
  Howard Trickey and Phil Winterbottom, "Plan 9 from Bell Labs",
  *Computing Systems*, 1995.
* Rob Pike, Dave Presotto, Ken Thompson, Howard Trickey and Phil
  Winterbottom, "The Use of Name Spaces in Plan 9", *Operating Systems
  Review* 27(2), 1993.
* Jerome Saltzer and Michael Schroeder, "The Protection of Information
  in Computer Systems", *Proceedings of the IEEE*, 1975.
* Jonathan Shapiro, Jonathan Smith and David Farber, "EROS: a fast
  capability system", SOSP 1999.
* E. Stenman and others, *The BEAM Book*.
* J. H. Walker, D. A. Moon, D. L. Weinreb and M. McMahon, "The
  Symbolics Genera Programming Environment", *IEEE Software* 4(6),
  1987.
