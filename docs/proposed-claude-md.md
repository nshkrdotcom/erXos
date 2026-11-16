# Proposed CLAUDE.md wording for a first release on Fiasco

[design-fiasco.md](design-fiasco.md) and [plan.md](plan.md)'s R1 put erXos's
first release on Fiasco, with every user feature, and publish what Fiasco
lacks against erXos's kernel as downsides. Several passages of `CLAUDE.md`
say that nothing ships on Fiasco and that no guarantee holds there; they
are no longer true under that plan. This file proposes the smallest edit to
each that makes it true. Nothing here changes `CLAUDE.md` until it is
accepted.

Each entry gives the current text verbatim, the proposed text, and one line
of why.

## Delivery: Development builds

Current:

> * **Development builds** run only trusted code until the security closure
>   milestone of [docs/plan.md](docs/plan.md). Their boot banner says
>   `development build: trusted code only`. Every other rule here applies to
>   them as written, with one exception: a development build may boot a
>   platform whose DMA handover evidence is not yet recorded; the gap is a
>   security residual in `TODO.md` that blocks release. That milestone is reached on erXos's own kernel: the
>   stopgap Fiasco is never hardened, though bugs found in it are fixed as
>   anywhere else.

Proposed:

> * **Development builds** run only trusted code until the security closure
>   of [docs/plan.md](docs/plan.md). Their boot banner says
>   `development build: trusted code only`. Every other rule here applies to
>   them as written, with one exception: a development build may boot a
>   platform whose DMA handover evidence is not yet recorded; the gap is a
>   security residual in `TODO.md` that blocks release. The closure has two
>   forms: R1's on Fiasco and M11's on erXos's own kernel. Fiasco is
>   hardened only as [docs/design-fiasco.md](docs/design-fiasco.md) lists
>   (its release build, its patches, the system-call fuzz campaign and the
>   upstream watch); what it lacks against erXos's kernel is a downside of
>   running on Fiasco, published with the release, not a gap to plug.

Why: the first release reaches a closure on Fiasco, so "reached on erXos's
own kernel" and "never hardened" are no longer true.

## Delivery: Two phases

Current:

> * **Two phases.** Phase 1 of [docs/plan.md](docs/plan.md) brings the
>   system up on a near-stock Fiasco: `liberx`'s Fiasco backend implements
>   the kernel interface over Fiasco's own calls in user mode, the system
>   domain's `liberx` owns every kernel object and serves the other tasks,
>   as L4Re's root task does, and nothing of erXos's kernel semantics is
>   built into Fiasco. Phase 2 builds erXos's kernel with every guarantee.
>   In Phase 1 the properties a kernel enforces are deferred as
>   enforcement, not rewritten: isolation between domains, budgets as
>   guarantees, stops and exit records, bounded kernel paths, the one
>   route from user mode, no panic on a domain's input, and the kernel
>   items of the "by construction" list in Design. The backend refuses a
>   call it cannot implement over Fiasco with `ERX_ENOTSUP`, reports a
>   value it cannot measure as unsupported or partial with its reporter
>   named, and never rebuilds a kernel mechanism in user mode for a
>   property that only erXos's kernel promises. Every rule below still
>   binds the code written in Phase 1: `liberx`, the runtimes, the
>   services, the drivers and the tools follow the untrusted-input,
>   chokepoint, escaping, fuzz-target, generated-ABI and never-fabricate
>   rules as written, and build against the target interfaces of the
>   design documents, so that Phase 2 changes what is behind `liberx` and
>   what the kernel enforces, not what services and runtimes call. Phase
>   1's kernel carries erXos C17 code only as the cores it links
>   (`erx_cores.a`); the kernel stack proof and the kernel-side chokepoints
>   check those cores, and the rest waits for erXos's kernel.

Proposed:

> * **Two phases.** Phase 1 of [docs/plan.md](docs/plan.md) brings the
>   system up on a near-stock Fiasco: `liberx`'s Fiasco backend implements
>   the kernel interface over Fiasco's own calls in user mode, the system
>   domain's `liberx` creates every kernel object and places each in its
>   holder, as L4Re's root task does, and nothing of erXos's kernel
>   semantics is built into Fiasco beyond the few patches
>   [docs/design-fiasco.md](docs/design-fiasco.md) lists. R1, the first
>   release, ships on that Fiasco: the backend uses Fiasco's own
>   capabilities, factories, interrupts and DMA spaces, so isolation
>   between domains and budgets as walls are Fiasco's, and what Fiasco
>   lacks against erXos's kernel is a published downside. Phase 2 builds
>   erXos's kernel with every guarantee and replaces Fiasco.
>   On Fiasco the properties only erXos's kernel enforces are deferred as
>   enforcement, not rewritten: budgets above a wall, CPU grants, bounded
>   stops and exit records from the kernel, bounded kernel paths, the one
>   route from user mode, no panic on a domain's input beyond what the
>   system-call fuzz campaign checks, and the kernel
>   items of the "by construction" list in Design marked as erXos's
>   kernel's. The backend refuses a
>   call it cannot implement over Fiasco with `ERX_ENOTSUP`, reports a
>   value it cannot measure as unsupported or partial with its reporter
>   named, and never rebuilds a kernel mechanism in user mode for a
>   property that only erXos's kernel promises. Every rule below still
>   binds the code written in Phase 1: `liberx`, the runtimes, the
>   services, the drivers and the tools follow the untrusted-input,
>   chokepoint, escaping, fuzz-target, generated-ABI and never-fabricate
>   rules as written, and build against the target interfaces of the
>   design documents, so that Phase 2 changes what is behind `liberx` and
>   what the kernel enforces, not what services and runtimes call. Fiasco
>   carries erXos C17 code only as the cores it links (`erx_cores.a`),
>   the policy of its patches among them; the kernel stack proof and the
>   kernel-side chokepoints check those cores, and the rest waits for
>   erXos's kernel.

Why: on R1 isolation and memory walls are enforced, by Fiasco, so they are
no longer in the deferred list, and the patches and scheduler stages put a
little erXos semantics into Fiasco.

## Delivery: A stopgap promises little

Current:

> * **A stopgap promises little.** Its design commits only to what the
>   milestone using it needs and its tests check: no memory errors, no
>   deadlock, and the results of the calls it offers, for trusted
>   workloads. A call it does not offer fails with `ERX_ENOTSUP`, a value
>   it cannot measure is reported as unsupported or partial with its
>   reporter named, and no weakness of the stopgap is worked around unless
>   the work is cheap or needed for its replacement anyway. Latency bounds,
>   fairness, exact accounting and progress against hostile load belong to
>   the component that replaces it; on the stopgap they are recorded as
>   residuals, not engineered into inherited code. Its reviews check those
>   commitments, not the target design's.

Proposed:

> * **A stopgap promises little.** Its design commits only to what the
>   milestone using it needs and its tests check: no memory errors, no
>   deadlock, and the results of the calls it offers, for trusted
>   workloads. A stopgap a release ships, as R1 ships Fiasco, also
>   commits to what its design's contract promises for untrusted
>   workloads ([docs/design-fiasco.md](docs/design-fiasco.md#contract)),
>   and no more. A call it does not offer fails with `ERX_ENOTSUP`, a value
>   it cannot measure is reported as unsupported or partial with its
>   reporter named, and no weakness of the stopgap is worked around unless
>   the work is cheap or needed for its replacement anyway. Latency bounds,
>   fairness, exact accounting and progress against hostile load belong to
>   the component that replaces it; on the stopgap they are recorded as
>   residuals, or as published downsides for one a release ships, not
>   engineered into inherited code. Its reviews check those
>   commitments, not the target design's.

Why: Fiasco in R1 faces untrusted apps, so its promise for them must be
stated and checked; the rest of the rule stands.

## Delivery: Nothing ships until I say so

Current:

> * **Nothing ships until I say so.** No one deploys erXos with stopgaps in
>   production, so polishing a stopgap is throwaway work, even where untrusted
>   input reaches it. What we need is to know where its gaps are: each is
>   recorded accurately as a residual, and does not have to be fixed.

Proposed:

> * **Nothing ships until I say so.** A release ships only the stopgaps its
>   milestone names: R1 ships on Fiasco, with the others its system still
>   uses. Each such stopgap meets its design's release contract, and every
>   gap beyond it is a published downside or a residual that blocks the
>   release. Every other stopgap stays out of production, so polishing it is
>   throwaway work, even where untrusted input reaches it. What we need is
>   to know where its gaps are: each is recorded accurately as a residual,
>   and does not have to be fixed.

Why: R1 deploys a stopgap kernel (and littlefs and LVGL, if they are still
in use then), so "no one deploys erXos with stopgaps" is no longer true.

## Dependencies: Stopgaps

Current:

> * **Stopgaps.** To reach a working system, any third-party component may be
>   used regardless of license or code quality. It stays until the roadmap
>   replaces it. It is marked `stopgap` in the dependency table and has a
>   `TODO.md` item to replace it. A stopgap under any license other than a
>   permissive one (LGPL included) blocks any distribution outside the
>   project, in source or binary form, until it is replaced. The one
>   exception is the images the website offers (the browser demo and the
>   board cards), each distributed with its source offered.

Proposed:

> * **Stopgaps.** To reach a working system, any third-party component may be
>   used regardless of license or code quality. It stays until the roadmap
>   replaces it. It is marked `stopgap` in the dependency table and has a
>   `TODO.md` item to replace it. A stopgap under any license other than a
>   permissive one (LGPL included) blocks any distribution outside the
>   project, in source or binary form, until it is replaced, or until the
>   parts under that license are out of what is distributed: R1's Fiasco
>   ships only a build whose link closure is permissive, which a release
>   build check proves. The one
>   exception is the images the website offers (the browser demo and the
>   board cards), each distributed with its source offered.

Why: Fiasco is MIT apart from two GPL-2.0 files; with the clean-room header
and the debugger off the shipped kernel is permissive, which the current
text does not allow for.

## Dependencies: Upstream is not tracked

Current:

> * **Code erXos modifies or ships enters the tree as erXos's code.** OTP
>   29.1.2's source (ERTS and the applications erXos ships), musl, the Fiasco
>   fork that serves as the stopgap kernel, littlefs, OpenSSL, ctaes, the
>   BLAKE3, ChaCha20 and SHA-2 cores, libmemdraw, and toybox with `wak`
>   live in the tree, keep their license notices and change by ordinary
>   edits. Upstream is not tracked, so erXos owns their fixes, security fixes
>   included. Each records its origin (repository, release or commit, and the
>   SHA-256 of what was imported) in an `ORIGIN.md` beside it.

Proposed:

> * **Code erXos modifies or ships enters the tree as erXos's code.** OTP
>   29.1.2's source (ERTS and the applications erXos ships), musl, the Fiasco
>   fork that serves as the stopgap kernel and the first release's kernel,
>   littlefs, OpenSSL, ctaes, the
>   BLAKE3, ChaCha20 and SHA-2 cores, libmemdraw, and toybox with `wak`
>   live in the tree, keep their license notices and change by ordinary
>   edits. Upstream is not tracked, so erXos owns their fixes, security fixes
>   included, with one exception: while a release runs on Fiasco, Fiasco's
>   upstream is reviewed monthly for security fixes reachable in erXos's
>   configuration, which are backported as ordinary commits
>   ([docs/design-fiasco.md](docs/design-fiasco.md#upstream-security-fixes)).
>   Each records its origin (repository, release or commit, and the
>   SHA-256 of what was imported) in an `ORIGIN.md` beside it.

Why: a kernel that faces untrusted apps should not lose upstream's security
fixes; the watch is cheap and ends when Fiasco leaves.

## Dependencies: the language exception for the Fiasco fork

Current:

> * **New code is C17, Erlang and Ruby. No Rust, and no new C++.** The one
>   exception is the stopgap Fiasco fork: kernel objects and scheduler hooks
>   that integrate with its C++ may be C++, while the policy and pure state
>   machines behind them are C17, ready to move into erXos's own kernel. The
>   rest:

Proposed:

> * **New code is C17, Erlang and Ruby. No Rust, and no new C++.** The one
>   exception is the stopgap Fiasco fork: kernel objects, scheduler hooks and
>   the patches [docs/design-fiasco.md](docs/design-fiasco.md) lists (the
>   clean-room header that replaces `kobject_rpc.h`, the
>   writable-or-executable check in its map), each integrating with its
>   C++, may be C++, while the policy and pure state machines behind them
>   are C17, ready to move into erXos's own kernel. The rest:

Why: the release's two patches are neither kernel objects nor scheduler
hooks, so the current exception does not cover them.

## Code: The stopgap Fiasco keeps its own style

Current:

> * **The stopgap Fiasco keeps its own style.** Its inherited C++ is exempt
>   from the kernel-construction rules below: the stack proof,
>   `musttail`-only recursion, the chokepoint checks and generated register
>   access. Those rules bind erXos's own kernel and the C17 code erXos adds
>   to the fork.

Proposed:

> * **The stopgap Fiasco keeps its own style.** Its inherited C++, and the
>   C++ of the patches and scheduler stages
>   [docs/design-fiasco.md](docs/design-fiasco.md) lists, are exempt
>   from the kernel-construction rules below: the stack proof,
>   `musttail`-only recursion, the chokepoint checks and generated register
>   access. Those rules bind erXos's own kernel and the C17 code erXos adds
>   to the fork. A release on Fiasco carries those rules' absence as a
>   published downside.

Why: keeps the exemption, names what erXos may add in Fiasco's style, and
says the absence is a downside of a release, not a hidden gap.

## Code: Trust placement

Current:

> * **Trust placement.** Only the kernel runs in kernel mode: erXos's own C
>   microkernel, or until it is written, the modified Fiasco that stands in
>   for it. Every runtime runs in user mode, including the system domain's
>   ERTS, which runs the trusted Erlang system services. Mechanism
>   that every domain's isolation depends on lives in the kernel. The
>   system domain is the root task: a C17 domain library in `liberx` builds
>   and ends domains, Erlang policy in the system domain decides who gets
>   what, and a fault of the system domain resets the machine. A domain's
>   memory, threads and CPU grant depend on nothing outside itself except
>   the kernel; which processes may message it depends on the kernel and on
>   its own runtime's funnel and export table, and on nothing else.

(the rest of the passage is unchanged)

Proposed:

> * **Trust placement.** Only the kernel runs in kernel mode: erXos's own C
>   microkernel, or until it replaces it, the modified Fiasco the first
>   release ships on. Every runtime runs in user mode, including the system
>   domain's ERTS, which runs the trusted Erlang system services. Mechanism
>   that every domain's isolation depends on lives in the kernel; on
>   Fiasco it lives in the kernel and in the system domain's root service,
>   the only creator of kernel objects and the only writer of any object
>   space or page table. The
>   system domain is the root task: a C17 domain library in `liberx` builds
>   and ends domains, Erlang policy in the system domain decides who gets
>   what, and a fault of the system domain resets the machine. A domain's
>   memory, threads and CPU grant depend on nothing outside itself except
>   the kernel, and on Fiasco the root service, where its CPU is a band, a
>   CPU set and a thread limit rather than a grant; which processes may
>   message it depends on the kernel and on its own runtime's funnel and
>   export table, and on nothing else.

Why: on Fiasco every mapping and capability placement is the root's, so the
root service is part of what isolation rests on, and CPU grants do not
exist there.

## Design: the "by construction" items that hold only on erXos's kernel

Each item below keeps its text and gains the marked clause. Items not
listed hold on both kernels as written, in the Fiasco form
[docs/design-fiasco.md](docs/design-fiasco.md) describes.

Current:

> * a stale capability never names a new object: every kernel call reaches
>   objects through one lookup that checks generation, type and rights,
>   and a capability slot retires before its generation wraps;

Proposed:

> * a stale capability never names a new object: every kernel call reaches
>   objects through one lookup that checks generation, type and rights,
>   and a capability slot retires before its generation wraps (erXos's
>   kernel only: on Fiasco a handle used after its holder's own close
>   names that slot's next object, a published downside);

Current:

> * every kernel allocation is charged to a budget carved from its
>   parent's, and an object dies with its budget: deleting a budget
>   deletes everything charged to it at once, as EROS's space banks do,
>   so what must outlive a party is charged to a budget that outlives
>   it; a budget's guarantee is never taken by another budget; beyond
>   its guarantee a budget spends only memory its ancestors have not
>   promised to anyone, up to its cap; and a domain's budgets are
>   walls, whose cap is fixed equal to their guarantee, so a domain is
>   admitted or refused at its own budget alone and takes nothing from
>   another's;

Proposed:

> * every kernel allocation is charged to a budget carved from its
>   parent's, and an object dies with its budget: deleting a budget
>   deletes everything charged to it at once, as EROS's space banks do,
>   so what must outlive a party is charged to a budget that outlives
>   it; a budget's guarantee is never taken by another budget; beyond
>   its guarantee a budget spends only memory its ancestors have not
>   promised to anyone, up to its cap; and a domain's budgets are
>   walls, whose cap is fixed equal to their guarantee, so a domain is
>   admitted or refused at its own budget alone and takes nothing from
>   another's (on Fiasco every budget is a wall, a Fiasco factory for
>   kernel memory and the root's record for user pages, with no cap above
>   a guarantee, and a budget's deletion is the root's walk rather than
>   one destruction);

Current:

> * the kernel, `liberx` and its backends, the runtimes and Erlang agree
>   on the ABI because all of them are generated from `abi/erx_abi.txt`.

Proposed:

> * the kernel, `liberx` and its backends, the runtimes and Erlang agree
>   on the ABI because all of them are generated from `abi/erx_abi.txt`
>   (on Fiasco, everything above the kernel; Fiasco keeps its own ABI,
>   which only the Fiasco backend calls).

Why: these three hold on Fiasco only in part, and saying so where the rule
is written stops a reader from assuming them on a release.

## Code: Chokepoints are build checks, and Kernel stacks are proven

Current:

> * **Kernel stacks are proven.** Every build computes the kernel's
>   worst-case stack depth from each entry point (boot, secondary boot,
>   synchronous exception, interrupt) from per-function stack sizes and the
>   call graph. A frame over the cap, an indirect call without its listed
>   targets, or a cycle through a call not marked `musttail` fails the build.
>   Kernel stacks have guard pages.

Proposed:

> * **Kernel stacks are proven** on erXos's kernel. Every build computes the
>   kernel's worst-case stack depth from each entry point (boot, secondary
>   boot, synchronous exception, interrupt) from per-function stack sizes
>   and the call graph. A frame over the cap, an indirect call without its
>   listed targets, or a cycle through a call not marked `musttail` fails
>   the build. Kernel stacks have guard pages. On Fiasco only the C17
>   cores it links are proven; its thread blocks are measured, never
>   proven, a published downside.

Current (the chokepoint rule's kernel examples):

> kernel allocation goes only through the
>   budget-charging funnel; the kernel executes no FP or SIMD instruction;

Proposed: the same words, with one sentence added after "The design
documents keep the full list.":

> The kernel's chokepoints bind erXos's kernel and the C17 cores linked
> into Fiasco; Fiasco's C++ is exempt, as the Code section says, and a
> release on Fiasco publishes that as a downside.

Why: the two rules read as if they hold for every kernel erXos ships; on
Fiasco they hold for erXos's cores alone.
