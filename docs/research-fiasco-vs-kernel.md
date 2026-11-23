# How far can Fiasco be improved toward erXos's own kernel?

Date: 2026-11-22. Tree: `/Users/stas/erxos`, master at `8a9870deb`. Read-only
investigation: nothing built, run or fetched. `jdb_object.cpp` and Fiasco's
original `kobject_rpc.h` were not opened.

## What was read, and what was not

* `CLAUDE.md`; `docs/design-fiasco.md` (the contract, the downsides table
  `:770-821`, the scheduler stages `:823-886`, the hostile-case table,
  Handles/Memory and budgets/IPC gates/Passing a handle, Risks);
  `docs/design-kernel.md` Context, Requirements (`:225-245`), the invariant
  table's first rows and the lineage summary; `docs/plan.md` rows for Track K
  (`:171`, `:1806-1830`), M7 (`:1928-1960`), the gates and the stopgap table.
* Fiasco source, by range: `obj_space_types.cpp`, `obj_space_phys_util.cpp`,
  `ram_quota.cpp`, `scheduler.cpp`, `sched_context*.cpp` (sizes and head),
  `mapdb.cpp:625-645`, `map_util.cpp` (grep), `task.cpp:865-940`,
  `arm/thread-arm.cpp:700-740`, `thread_object.cpp` (grep), `Kconfig`.
* **Not read in full**: `design-kernel.md` (9,409 lines), `design-scheduler.md`,
  `todo-fiasco.md`, `todo-kernel.md`, `research-kernel-bases.md`. Where a row
  depends on them I rely on the downsides table's own wording.
* **Every size below is my estimate** from the size of the Fiasco files a change
  would touch and of comparable existing code. None was prototyped. Treat them
  as unverified, good to a factor of two at best. The scheduler stage sizes are
  the design's own (`design-fiasco.md:854-866`), which it also marks unverified.

## The one observation that organizes everything

The downsides table mixes three different kinds of gap:

1. **Gaps in Fiasco's kernel** (no generation in a slot, no speculation
   barrier, fixed-priority scheduling only, quotas that are flat walls). These
   can be patched in the fork, and most are small and contained.
2. **Gaps of the construction, not of Fiasco** ("the root creates and places"):
   erXos's memory objects, budgets over user pages, handles, spaces with
   parents, exit records, copies and image maps live in the root service, in
   user mode, on one thread. That is the L4Re shape (Fiasco plus `moe`), as
   `design-fiasco.md:2336` says. These rows close either by **improving the
   root service** (compatible with Fiasco; it is how L4 systems are built) or
   by **moving the mechanism into the kernel** (which replaces Fiasco's memory
   model: flexpages, the mapping database, user-level pagers, `sigma0`). The
   second is the rewrite.
3. **Gaps of how the code is built** (FD24: stack proof, `musttail`, the
   chokepoints, generated register access, "by construction"). No patch gives
   these to 43,000 to 67,000 preprocessed lines of C++
   (`design-kernel.md:230-233`); what Fiasco can get instead is evidence:
   fuzzing, audits, a measured or analysed stack bound.

So "how hard is it to improve Fiasco" has a cheap answer for kind 1, a
"depends where you put it" answer for kind 2, and "you cannot, you can only
accumulate evidence" for kind 3.

Classes used below: **A** cheap (under about 500 lines, contained);
**B** big but compatible with Fiasco's approach; **C** against Fiasco's
approach (closing it in the kernel is a rewrite of the memory model, the object
lifetime model or the code base); **H** hardware or platform, the same on
either kernel; **N** not worth closing.

## Table of rows

| Row | Gap | Where it would close | Size (unverified) | Class | Matters? |
| --- | --- | --- | --- | --- | --- |
| FD1 | closed IRQ handle reaches the slot's next object; `cap_limit`; no wake of queued threads | generation in Fiasco's slot and selector | 150-300 C++ + backend | A | low: spurious ring or early unmask of the holder's own objects |
| FD2 | thread ids carry no generation | root's thread table and handles | 200-500 backend | A | low |
| FD3 | gates carry no messages or capabilities | backend: handles as Fiasco caps, or root-mediated messages | 1,000-3,000 | B | none in 0.2 (no consumer); later for native servers across domains |
| FD4 | a refused pass is partial | root: plan then apply | 200-400 | A | low; fully "moves nothing" needs pre-reserved kernel memory |
| FD5 | object dies with its creator's task; only creator destroys; no destroy of a started thread | root records and policy | 300-800 | A/B | low-medium |
| FD6 | `erx_object_info` partial | root, plus small Fiasco read-outs (quota in use, thread time) | 100-300 | A | low; improves the inspector |
| FD7 | no lazy commit | root as pager (Fiasco's way) or kernel memory objects | 500-1,000 in root | N (C in kernel) | none: no code depends on it |
| FD8 | W and X through two mappings; root and `sigma0` RWX | root's range table refuses the pair; `sigma0`/root image mapped by segment | 300-700 | A, residue C | medium: the root's window stays writable over everything |
| FD9 | no growth, paged objects, copy-on-write, store tracking | root as pager, or kernel memory objects | 2,000-5,000 in root | B in root, C in kernel | high after 0.2: Track Q (`fork`, shared file mappings, large mmap) |
| FD10 | image map checks; file hash not checked | root | 300-600 | A/B | medium (integrity) |
| FD11 | copies and listings run in the root | only kernel memory objects close it | - | C / N | low: a cost, counted under FD17 |
| FD12 | DMA unconfined | Fiasco already has SMMUv2/v3 and DMA spaces; 0.2's platforms have no IOMMU | backend rows only | H | high, but the hardware decides, on either kernel |
| FD13 | no carve, route, move; ack checks no right | root tables; a rights check in `irq.cpp` | 50 (ack) to 800 | A | none in 0.2 |
| FD14 | limits besides the budget (128 threads, object and mapping limits) | raise table sizes; the rest is the root's cost per object | small | A, residue C | low |
| FD15 | no CPU grants; bands only | stage 5, a scheduler variant over `kernel/sched/sched.c` | 1,500-3,000 | B | high for hostile or multi-tenant use (M10, the hostile CPU cases) |
| FD16 | no cooperation ladder | stages 1-4 | 550-1,250 | A/B | performance only; measure first |
| FD17 | every service call on the root's one thread at the root's band | root: worker threads at the caller's band, tables locked | 1,500-4,000, concurrency risk | B, residue C | medium-high: denial of service by request floods |
| FD18 | executor rule in `liberx` only | - | - | N | none: self-harm |
| FD19 | no thread stop, read, write; start only a space's first thread | backend over Fiasco's `ex_regs` (`thread_object.cpp:715`) | 300-800 | A/B | medium: the debugger |
| FD20 | exit records from the root, unbounded under load | a small kernel notifier; the bound needs FD17 and a bounded teardown | 200-500, bound not reachable | B, bound C | medium: supervision latency under attack |
| FD21 | pause by gate, not a whole-space hold | a task-wide suspend in Fiasco | 200-400 | B | low: `fork` and job control work |
| FD22 | umtx within a task only | a new kernel object keyed by frame | 400-800 | B | low: process-shared mutexes |
| FD23 | vCPU upcall subset | backend (Fiasco's vCPU is the model) | 500-1,000 | A/B | low-medium: signal timing |
| FD24 | construction rules: stack proof, `musttail`, chokepoints, generated registers and ABI, K7, K12, K13 | cannot be patched in; evidence only (fuzz, audit, stack analysis tooling) | 1,000-3,000 Ruby + audits; never "by construction" | C | the core of M11's "every guarantee" |
| FD25 | walls only; no caps, borrowing, exact `used` | root: the existing budget core for user pages; Fiasco: `Ram_quota` (164 lines) replaced or read out | 600-1,500 | B | medium: apps refused while memory is free |
| FD26 | trace ring, entropy, log, watchdog at the root's level | Fiasco watchdog thread; kernel trace buffer | 300-800 | A/B | low-medium: a kernel hang before the root's thread |
| FD27 | time page at a fixed address | - | - | N | none |
| FD28 | startup proof | packer and root; independent of Fiasco's kernel | host work | B (not Fiasco) | medium for M9/M11 properties |
| FD29 | board items: early watchdog, crash region, sealing | Fiasco boot arms the watchdog; the rest is M12 | 50-150 + M12 | A / H | medium on boards |
| FD30 | a join race in the root's own table | a bug; fix it | 50-100 | A | low; no domain sees it |
| FD31 | a client spends a server's band | stage 5 plus admission | with FD15 | B | medium-high, with FD15 |
| FD32 | no branch-predictor hardening on AArch64 | entry and switch patch (`arm/64/ivt.S`, 397 lines) | 100-300 | A | high on the Pi 4's Cortex-A72 for untrusted apps |
| FD33 | a device's fault may end the wrong task or the machine | the SError patch is in; the rest is audit and fault tests | audit | A/B | open decision; medium |
| FD34 | a map replacement leaves the range unmapped between steps | backend: Fiasco's map already handles overmapping (`map_util.cpp:541`) | 100-300, unverified | A | medium: module code swap |

## Row notes

Only what the table cannot carry.

**FD1.** Fiasco's slot is `Obj::Entry`: a pointer word with two rights bits and
a flags word of which 24 bits are padding (`obj_space_types.cpp:46-63,
84-87`). The object index is 20 bits (`obj_space_phys_util.cpp:127`), so a
64-bit selector has room for a generation. The check goes in the one lookup
(`Obj_space_phys::lookup_local`, `obj_space_phys_util.cpp:372`). This fits
Fiasco: one field, one comparison, at Fiasco's own chokepoint. Risk: the
selector format is Fiasco's ABI to `sigma0` and `bootstrap`, so generation 0
would have to mean "unchecked" for them; unverified. Whether Fiasco wakes
threads queued on a deleted IRQ or semaphore was not read.

**FD3.** Fiasco has exactly this mechanism (`ipc_gate.cpp`, 598 lines;
`Thread::transfer_msg_items`, `thread-ipc.cpp:1203`). The gap exists because
an erXos handle is an entry of the root's table, not a Fiasco capability, so
Fiasco's IPC cannot move one. Closing it means either undoing "a handle is not
a slot" for the kinds that pass, or letting the root carry messages. Neither is
against Fiasco; both rework the backend. No consumer needs it in 0.2
(`design-fiasco.md:2333-2336`).

**FD7, FD9, FD11.** These are the memory-model rows. erXos's kernel has memory
objects with no user-level pager, "so no fault waits on another domain"
(`design-kernel.md` lineage summary). Fiasco's native answer to lazy commit,
growth and copy-on-write is the opposite: a pager in user mode, as `moe`'s
dataspaces do. On Fiasco the compatible route is the root as pager, which makes
every such fault wait on the root's thread (FD17). Putting memory objects in
Fiasco's kernel would replace flexpage mapping and the mapping database
(`mapdb.cpp` 1,334, `map_util.cpp` 961, `mapping_tree.cpp` 370 lines) and make
`sigma0` pointless. That is the clearest "against the whole Fiasco approach"
item, and FD9 is the one of the three with a real consumer (Track Q).

**FD8.** Because the root is the only mapper, its range table already sees
every mapping of every object; refusing "writable here, executable there" for
an object without the JIT flag is a check in the root's plan, not a kernel
change. `sigma0` handing out RAM read-write-execute
(`l4re-core/sigma0/server/src/memmap.cc:96,125`, cited by the design, not
re-read) and the root's image are fixable by mapping by segment. What cannot
close: the root reaches every page writable through its window, by
construction. Device writes are FD12.

**FD12.** Fiasco ships SMMU drivers (`kern/arm/iommu-arm-smmuv3.cpp`, 2,804
lines; SMMUv2 beside it) and DMA spaces. The Pi 4 and QEMU `virt` as 0.2
configures them have no IOMMU, so the downside is the hardware's and erXos's
kernel would publish the same one there. On a platform with an SMMU, Fiasco is
ahead: erXos's kernel has to write that driver.

**FD15, FD31 (CPU grants).** Fiasco's scheduler is a compile-time variant
(`Kconfig:327-349`); two alternative variants already exist in the tree
(`sched_context-wfq.cpp` 190, `sched_context-fp_wfq.cpp` 356,
`ready_queue_wfq.cpp` 224 lines), which shows the seam is real. The design's
stage 5 is 1,500 to 3,000 lines with the policy in `kernel/sched/sched.c`
(676 lines today). The hard part is not Fiasco: it is charging a group tree
across CPUs, the same protocol erXos's own kernel must get right. I am unsure
whether "a group's threads in any space" fits a per-thread `Sched_context`
without touching `context.cpp` (2,949 lines) more widely than the estimate
assumes.

**FD17.** The design accepts it for 0.2. A multi-threaded root (a worker per
domain or per CPU, at the caller's band) is ordinary L4Re practice, but every
root table then needs a lock discipline the backend's 13,755 lines were not
written for. It removes the cross-domain denial of service; it does not make
calls run "on the caller's own thread, charged to its own group".

**FD24 and the kernel-only construction properties.**

| Property | Fiasco today | What can be had on Fiasco |
| --- | --- | --- |
| Stack proof | 8 KiB thread block (`config_tcbsize.h:6`), measured by a watermark; a recursion the source itself flags as unbounded-in-principle (`mapdb.cpp:634`, "XXX Recursion"); 145 `virtual` declarations in `kern/*.cpp` | a whole-program stack analysis with listed indirect targets is tooling (my guess 1,000-3,000 lines of Ruby plus annotations); it would be an analysed bound resting on the compiler's devirtualization, weaker than the proof. Unverified that the existing stack tool extends to C++ |
| `musttail`-only recursion | not a rule of the code | follows from the analysis: find the cycles, bound or remove them; few are expected |
| Chokepoint checks | none of erXos's | some rules can be checked from outside (system-register instructions, FP in the kernel, allocation through the quota funnel); the rest assume erXos's module structure |
| Generated register access, generated ABI | hand-written | rewriting Fiasco's architecture layer; not worth it. Fiasco's ABI is hidden behind `liberx` anyway |
| No panic on a domain's input (K12) | 87 `panic(` and 472 `assert` sites in `kern/*.cpp`, `kern/arm` and `kern/arm/64` (my grep; many are boot-time; a release build selects `NDEBUG`, `Kconfig:619,663`) | the fuzz campaign plus an audit of each object's invoke path; evidence, never construction |
| Once-only reads (K7) | Fiasco is UTCB-centred; user-address access is rare (`mem_space-user.cpp`, `arm/thread-arm-hyp.cpp:378`) | an audit of about twenty object types; fix what it finds |
| One route from user mode | not checked here; with the debugger off I expect the system call, exceptions and interrupts only (unverified) | an audit |
| Bounded kernel paths (K13) | a preemptible kernel with helping locks; long operations drop the CPU lock (`task.cpp:877,933`, `kobject.cpp:229`) | measurement; no bound stated by the code |
| Budgets as walls | already Fiasco's model: a child factory's whole limit is charged to its parent (`factory.cpp:81-86` per the design; `Ram_quota`, `ram_quota.cpp:66-90`) | nothing to do; the gap is caps above guarantees (FD25) |
| CPU grants | none | stage 5 |
| Bounded stops and kernel exit records | the root's teardown | a notifier is small; the bound is not reachable while the root does the teardown |

These properties are why FD24 is class C: "improving Fiasco until it gives
them" means rewriting it under erXos's rules, which is erXos's kernel. What
Fiasco can offer in their place is a decade of use, the fuzz campaign and the
upstream security watch.

**FD25.** User pages are already the root's records, so caps above guarantees
and borrowing for user pages are the existing C17 budget core
(`kernel/core/budget.c`, 993 lines) used by the root instead of the wall-only
record. Kernel memory is Fiasco's `Ram_quota`, a 164-line class with a
two-call interface (`alloc`, `free`) and a lock-free compare-and-swap; making
it elastic means charging up a tree without a lock, the risky part. Exact
`used` for kernel memory is a read-out of `Ram_quota::current()`
(`ram_quota.cpp:61`). CPU time per thread already exists
(`thread_object.cpp:768-797`), so "CPU use per domain: unsupported" (FD15's
report) is also cheap to fill.

**FD32.** Confirmed: no SMCCC workaround call, branch-history clearing or
barrier under `kern/arm` (grep), and the barrier options are AMD64-only
(`Kconfig:478-487`). The patch is small. Unverified: whether the Pi 4's
firmware implements the SMCCC workaround call the patch would rely on.

**FD34.** `map_util.cpp:541` flushes an interfering mapping when one is
overmapped, so a single map call may replace the mapping without the
backend's unmap step. Whether another CPU can observe the range unmapped
inside that one call was not checked.

## Overall

**Cheap (A), about 2,500 to 6,000 lines in total:** FD1, FD2, FD4, FD6, most
of FD8, FD10, FD13, FD14's limits, FD19, FD23, FD29's early watchdog, FD30,
FD32, FD33's audit, FD34. These are ordinary fixes. Several are in the root
service, not in Fiasco.

**Big but compatible (B), about 9,000 to 23,000 lines:** the scheduler stages
(2,050 to 4,250 by the design's figures) which close FD15, FD16 and FD31;
elastic budgets (FD25); a concurrent root (FD17); copy-on-write and paged
objects through a root pager (FD9); message gates (FD3); cross-space umtx
(FD22); a whole-space hold (FD21); an exit notifier (FD20); the kernel-level
trace and watchdog (FD26); and the stack analysis and audits that stand in for
FD24.

**Against Fiasco's approach (C):**

* memory objects in the kernel with no pager (FD7, FD9 done erXos's way, FD11,
  FD34 planned whole, K4's ceilings and K8 in full);
* no root tables at all (the residue of FD14, FD17, FD20's bound, FD30);
* the construction rules (FD24): the stack proof, the chokepoints, generated
  access, "by construction" for K7, K12, K13.

**Size compared with erXos's kernel.** The plan puts the kernel at 25,000 to
40,000 lines of C17 plus under 2,000 of assembly per architecture
(`plan.md:171`, `design-kernel.md:228-239`). `kernel/core` and `kernel/sched`
hold 12,335 lines today, host-only cores; there is no architecture layer
beyond two files and no `erx` backend in `liberx`. So perhaps 15,000 to 30,000
lines remain, and they are the hard ones: the execution model, SMP, the
architecture layer, each board's bring-up, and then the hardening Fiasco
already has. The A and B lists for Fiasco total roughly 12,000 to 29,000
lines. **The two are the same order of size.** They differ in shape:

* Fiasco improvements land one at a time, each shippable, each removing a row.
  The kernel delivers nothing to users until GK3's parity.
* Fiasco improvements never reach class C. The kernel does, and drops the
  13,755-line backend, the root's tables and the upstream watch.
* Staying on Fiasco means owning security fixes for a C++ kernel of 230,873
  source lines across architectures (43,000 to 67,000 preprocessed for
  AArch64) indefinitely.
* Fiasco brings working SMP, GIC, board support and SMMU drivers. The kernel
  has to re-earn each.

## Recommendation

**Improve Fiasco to a stated point, then decide; do not start the full Track K
(GK2) until then, and keep the C17 cores going.** This matches the lead's
position, and the evidence supports it:

1. Nothing in class A or B is "so complex it goes against the whole Fiasco
   approach". Most of what users or apps would notice (CPU grants, elastic
   budgets, speculation hardening, debugger support, stale handles, W^X across
   mappings) is there.
2. The C17 cores are not wasted either way: they link into Fiasco as
   `erx_cores.a` (the budget core in the root, the scheduler core under stage
   5) and are the kernel's cores if it is built. Keep the pilot; it also keeps
   the calibration GK1 wants.
3. The class C items are few and specific, and each has a question that can be
   answered by measurement before committing to a kernel.

**The stated point** (my proposal): 0.2 shipped; the class A list done;
FD32's patch in; stage 5 landed or shown not to fit; elastic budgets in the
root; and Track Q's first consumer (copy-on-write `fork` or a file-backed
mapping) built through a root pager and measured.

**Evidence that would turn the decision toward erXos's kernel:**

* the root pager's fault latency or the root's one thread is a measured
  problem for Track Q's workloads, and a concurrent root does not fix it: that
  is the memory model, and it is class C;
* stage 5 does not fit as a scheduler variant and spreads through
  `context.cpp`;
* the system-call fuzz campaign or the upstream watch keeps finding
  domain-reachable defects in Fiasco, so "evidence instead of construction" is
  not holding;
* a release needs to *claim* the construction properties (a proof, an audit
  requirement, an external commitment), which Fiasco cannot give at any price;
* the class B work on Fiasco passes roughly half the kernel's remaining
  estimate with the class C list still unacceptable.

**Evidence that would keep erXos on Fiasco indefinitely:** the fuzz campaign
stays quiet, the root pager is fast enough, stage 5 fits, and no consumer asks
for more than "isolation rests on Fiasco and the root's decoder".

## Where I am unsure

* All sizes; none was prototyped, and I did not read `design-kernel.md` or
  `design-scheduler.md` in full, so a row's erXos-side promise is taken from
  the downsides table.
* Whether a generation fits Fiasco's selector without disturbing `sigma0` and
  `bootstrap` (FD1).
* Whether stage 5's group tree fits a per-thread `Sched_context`.
* Whether a root pager contradicts a requirement I did not read ("no fault
  waits on another domain" is stated as a reason for the departure; how much
  erXos depends on it is the real question for FD9).
* The remaining-kernel figure (15,000 to 30,000 lines): the 12,335 existing
  lines include boot, device-tree, log and packing cores that may not all count
  toward the 25,000 to 40,000.
* Release-build assertion behaviour, the Pi 4 firmware's SMCCC support, Fiasco's
  handling of interrupt storms, and atomicity of an overmap were not verified.
