# DMA by devices that are not cache-coherent

A device that is not cache-coherent reads and writes memory without
looking in the CPU's caches. Data the CPU wrote may still sit in a cache
when the device reads, and a stale or dirty cache line may hide or
overwrite what the device wrote. The Raspberry Pi 4's Ethernet controller
(GENET) moves packets only by DMA and is not coherent; its SD controller
(EMMC2) can move blocks by DMA through ADMA2 tables and is not coherent
either. This document says how the device NIF
([design-runtime.md](design-runtime.md#the-device-nif)) keeps the CPU and
such a device in agreement, how it learns the address at which a device
sees memory, which registers the NIF must own so that no driver can aim a
device at memory, and the descriptor forms the NIF drives. It
refines the DMA envelope of
[design-kernel.md](design-kernel.md#dma-and-the-iommu) and the device
NIF; the AArch64 instructions are in
[design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance).

Decisions every reader needs:

* **Memory changes hands in whole granules, and is maintained line by
  line.** Every region of a device's memory, a ring part, an ADMA2 table,
  a pool buffer or a region of the record, starts and ends on a
  cache-writeback granule, and at any moment either the CPU or the device
  is its writer, never both. No writeback ever carries bytes of two
  writers, so no cache operation on one region can touch another's data.
  Maintenance runs over every cache line of a region, stepping by the
  smallest line, since a granule may span several lines.
* **The device acts only on records the trusted side wrote and made
  live.** A form's core describes what it wants, a transfer, a command
  or a chain, by meaning, field values and names of buffers, and never
  writes a device address or a byte the device reads as a structure. The
  sequencer writes each record whole, cleans, and makes the run live with
  one store of its own after the publish barrier. It keeps the
  **ledger**, the one record of what the device holds, and ends a holding
  only on a report the device made. So no address a core computes, no
  half-written record and no buffer a core merely says came back reaches
  the device ([The check](#the-check)).
* **Cache maintenance follows from the handoff, in one place.** A buffer
  passes to the device when a publication hands it over, and comes back
  when a release returns it; one sequencer derives from that change in
  the ledger, and from the records it writes, which regions to clean,
  which to clean and invalidate, which bytes to zero, and the barriers in
  their one valid order. No form names a handoff, issues maintenance or a
  barrier, so none can forget or misplace one. For a coherent device the
  maintenance is empty and the barriers remain.
* **The device writes over zeros.** Every byte of a buffer that passes to
  the device and that the plan does not fill is zeroed first, so a
  completion returns the device's bytes or zeros, never an earlier
  request's, whatever length within its bound the device reports.
* **A device is given device addresses only.** Every address the NIF
  writes to a device is the device's own view of memory the record holds:
  the I/O address `erx_dma_map` gave for a confined device, and for an
  unconfined one the physical address moved through the record's DMA
  range. Each DMA device's record carries whether it is coherent and that
  one range, both read at boot from the device tree the firmware hands
  over ([design-device-tree.md](design-device-tree.md)); a device whose
  range is absent, or whose DMA memory would lie outside it, gets no DMA
  memory, and the NIF refuses a queue whose addresses a descriptor form
  cannot hold.
* **A register is the NIF's when a write to it can aim the device.** The
  NIF owns every register, and every field, through which a write could
  change an address the device uses, how many bytes it moves at an
  address, which descriptors it takes as valid, how it reads them, or how
  it reports the end of a transfer the NIF tracks. Drivers write the
  rest, and a write that would change an owned field is `badarg`. Every
  driver write takes the device lock, so no write, a reset included,
  lands between a check the NIF makes and the write that check guards.
* **A buffer is reused only after the device says it is done.** The NIF
  takes a buffer back only on the device's own report, read in the same
  call: a completion without an error, or the idle report that follows a
  reset the NIF wrote. A reset the driver makes can make the device
  forget a transfer; its queue then waits for a completion that does not
  come, until `negotiate/2`, and no buffer is freed by it.

## Context

**The hardware.** Linux 6.18's tree for the BCM2711, which the build
already fetches (`deps.lock`, `linux-dts`), marks no node `dma-coherent`
(no match under `arch/arm/boot/dts/broadcom/`). GENET,
`/scb/ethernet@7d580000`, sits on `scb`, which has `ranges` and no
`dma-ranges` (`bcm2711.dtsi:545-551, 587-594`), nor has the root above
it, so its device addresses equal the CPU's under the walk of
`erx_dma_ranges` ([design-kernel.md](design-kernel.md#dma-and-the-iommu)),
which follows the Devicetree Specification v0.4, section 2.3.9.
GENET's descriptors are not in memory: 256 per direction, each three
32-bit registers (status, address low, address high), sit in its register
window at `0x2000` for receive and `0x4000` for transmit
(FreeBSD's `if_genetreg.h:116-124, 168-192`), and FreeBSD gives its
buffers DMA tags limited to 40-bit addresses (`if_genet.c:616-619,
641-644`). EMMC2,
`/emmc2bus/mmc@7e340000`, sits on a bus of its own whose `dma-ranges` map
bus address `0xC0000000` to the first GiB of RAM
(`bcm2711.dtsi:418-432`); the tree's comment says the firmware rewrites
that property according to the SoC's revision, keyed on the `emmc2bus`
alias (`bcm2711.dtsi:411-417`), which the board's tree defines
(`bcm2711-rpi.dtsi:14`). The legacy peripherals see the first GiB at
`0xC0000000` too (`bcm2711.dtsi:45`). Linux drives EMMC2 with the
controller's own ADMA2 engine when its capabilities offer it, and FreeBSD
moves EMMC2's data with the SoC's separate DMA controller instead
([facts record](research-sdhci-bcm2711.md#dma-for-a-later-design)).
FreeBSD's driver does not use ADMA2; the descriptor comes from the SD
Host Controller Simplified Specification, version 4.20 ("Host
Controller" below, by section and printed page):

* **The entry.** With 32-bit addressing an entry is 8 bytes: the
  attributes in bits 5:0, a length in bits 31:16, and the data's 32-bit
  address in bits 63:32 (section 1.13.2, figure 1-10, p. 17; section
  1.13.3.1, figure 1-11, p. 18). The attributes are valid (bit 0), end
  (bit 1), interrupt (bit 2) and the action bits Act0, Act1 and Act2
  (bits 3 to 5); Act0 is 0 for every ADMA2 entry, and Act2 1 with Act1 0
  is a transfer, 1 and 1 a link, 0 and 0 or 0 and 1 no operation. An entry
  fetched with valid 0 raises the ADMA error and stops the engine
  (figure 1-10). Bits 15:6 hold the upper ten bits of a 26-bit length
  only when host control 2's ADMA2 length mode is 1; with it 0, as the
  NIF keeps it, they are not part of the length and the form writes them
  0 (section 1.13.3.1, p. 18; section 2.2.25, bit 10, p. 97). The
  controller reads entries, and the specification
  gives it no write to them.
* **The length.** In 16-bit length mode a length field of 1 to `0xFFFF`
  moves that many bytes and 0 moves 65,536 (table 1-12, p. 18), while
  section 1.13.1.3 (p. 16) says an entry moves less than 64 KiB. The two
  agree on every value from 1 to 65,535, so the form writes no entry of
  65,536 bytes or of 0.
* **Alignment.** A data address is a multiple of 4 bytes (section
  1.13.1.3, p. 16). With 32-bit addressing the table starts on a 4-byte
  boundary, since the controller ignores the low two bits of
  `adma_address`, whose upper 32 bits are 0 (section 2.2.31, table 2-42,
  p. 116; section 1.13.2, p. 17). DMA select `10b` in host control 1
  selects 32-bit ADMA2 while host version 4 enable is 0 (section 2.2.11,
  pp. 60-61).
* **Lengths and the block count.** The entries' lengths sum to a multiple
  of the block size, or the transfer may not end until a data timeout
  (section 1.13.1.3, p. 16). With block count enable set, a sum that
  differs from block size times block count, or that the block size does
  not divide, sets the ADMA length mismatch error, bit 2 of the ADMA
  error status register at `0x54`, and raises the ADMA error status
  (section 2.2.30, table 2-41, p. 115; section 2.2.19, bit 9, p. 83).
  The engine stops after the entry with end set, and in ADMA2 mode every
  stop raises transfer complete (section 1.13.3.2, table 1-14, p. 20).
  The specification does not say when the mismatch is detected relative
  to the bytes moved, nor whether transfer complete is raised beside the
  ADMA error; the board pass settles both on the BCM2711.

QEMU 11.1.3's `virt` marks every virtio-mmio node `dma-coherent`
(its tree as `-machine virt,dumpdtb=` writes it, read on 2026-11-12), and
QEMU performs that DMA itself, coherently.

**What Arm says.** The cache type register gives two sizes that differ in
general: the cache-writeback granule, `CWG`, the largest block of memory
that the eviction of one modified cache entry can overwrite, and
`DminLine`, the smallest data cache line of any cache the processor
controls. The Cortex-A72, the Pi 4's CPU, reports 16 words, 64 bytes, for
both (Cortex-A72 TRM r0p3, section 4.3.26, Table 4-40); the architecture
does not make them equal. A data cache instruction by address acts on one
line. A `DMB` orders data cache maintenance like a data access, and one
that is meant to order cache maintenance must order both loads and stores
(Arm, *Learn the architecture: Memory Systems, Ordering, and Barriers*,
102336 version 1.0, section 5, p.13); a `DSB` completes the cache
maintenance issued before it by the CPU that executes it (section 6,
p.14).

**What FreeBSD does.** FreeBSD 15.1's arm64 `busdma`, for a tag that is
not coherent, cleans to the point of coherency before the device reads
(`sys/arm64/arm64/busdma_bounce.c:993-996`), writes back the partial
lines at a buffer's ends and invalidates before the device writes
(`:997-1009, 950-962`), and invalidates after it wrote (`:1010-1013`),
with `DSB SY` after the maintenance that precedes a transfer and before
the CPU reads what one wrote (`:1035-1040, 1113-1118`). Its maintenance
loops step by the data cache line, which it takes from `DminLine`
(`cpufunc_asm.S:54-82`; `identcpu.c:3313-3323`), and it aligns and sizes
a non-coherent buffer to that line (`busdma_bounce.c:282-295`), not to
`CWG`; on the Pi 4's CPU the two are equal. Memory a driver asks to be
coherent on a non-coherent tag it maps uncached (`:515-523`). Its
`mb()`, `rmb()` and `wmb()` are full-system `DMB`s (`atomic.h:51-56`).
The virtio specification makes a device write at least the
length it reports, and notes that a driver that does not know how much
was written must zero the buffer beforehand to avoid leaking data
(Virtio 1.2, sections 2.7.8 and 2.7.8.2).

**The NIF and the pool on Fiasco.** The device NIF runs virtio's split ring
through the sequencer below, with `G` and `L` from the architecture
layer, and with the record's coherence mark, which the root takes from
the firmware's device tree ([design-device-tree.md](design-device-tree.md)):
on QEMU `virt` every given device with DMA memory is marked coherent, so
no maintenance is issued there. Its one lock serialises opens, binding changes and every
queue call, and is held across service calls (`erx_device_nif.c`);
register writes, which are BIFs, take no lock (`erx_device_bif.c`,
`erx_device.c`). The manifest's device record has a DMA mode
and an amount of DMA memory but no coherence mark and no DMA address
range; its only flag is `hostile` (`abi/manifest.txt`, `erx_mf_device` and
`mf_device_flags`). On Fiasco, every device's DMA
memory comes from one contiguous pool the root takes from `sigma0`
at boot, sized for the manifest's devices' memory up to 16 MiB (`liberx/backend/fiasco/vm.c`, `erx_fiasco_vm_init`;
`liberx/backend/fiasco/page_pool.c`, `erx_fiasco_contig_order`), an object is at most 16 MiB
(`abi/erx_abi.txt`, `mem_contiguous_max`) and aligned to a page, its device address is its physical address
less the range's CPU address plus its bus address
(`vm.c`, `erx_fiasco_vm_contiguous_create` and `erx_fiasco_vm_object_dma_addr`),
and the range's `cpu` and `last` are read as physical addresses. Fiasco lets user mode clean and invalidate by address
and read the cache type register
(`fiasco/kernel/src/kern/arm/64/cpu-arm-64.cpp`).

## The construction: handoffs of granules

**The granule and the line.** `G` is the CPU's cache-writeback granule
and `L` its smallest data cache line, both reported by the architecture
layer; where CPUs differ, it reports the largest granule and the smallest
line of any CPU. The NIF reads them once, when it loads. Ownership is
counted in granules, because one writeback can overwrite a whole
granule; maintenance steps by lines, because one maintenance instruction
acts on one line and a granule may hold several.

**Regions and writers.** The memory a device's record holds, the
contiguous object or the window-mapped memory, is divided into regions,
each a whole number of granules starting on a granule boundary:

* the parts of a queue's rings that one side writes: for virtio the
  descriptor table and the available ring, which the CPU writes, and the
  used ring, which the device writes; for ADMA2 the queue's table, which
  the CPU writes;
* each pool buffer: a queue's buffers lie at a stride of the buffer size
  rounded up to `G`;
* each region of the record
  ([design-runtime.md](design-runtime.md#the-device-nif), Regions):
  written by the CPU for the boot and read by the device whenever a
  request names it. No transfer hands a region over, so nothing would
  clean it before the device reads; a region is therefore made only for a
  coherent device, and `region/3` on another is `{error, enotsup}`.

A region's writer is the CPU or the device, and is a function of the
queue's state. A buffer's writer is the device from its post until its
completion, and the CPU otherwise. A ring region's writer is the one the
form names while the queue is installed; from the device's idle report
in `negotiate/2` until the install's last write the device holds nothing
of the queue, and every region of it, the used ring included, is the
CPU's. A region of the record's is always the CPU's. Which state a
buffer and a queue are in is the ledger's
([The ledger](#the-ledger)), which hands a buffer to the device only
through a publication and takes it back only through a release that a
report of the device's own justifies. The CPU
stores only into regions whose writer it is, and never into a buffer
between its post and its completion.

**The three rules.**

1. **Zeroing.** When a buffer passes to the device, every byte of it that
   the plan does not fill with an `out` segment's bytes is set to zero,
   before rule 2's clean. A completion then copies, up to the length the
   device reported, the device's bytes or zeros, never bytes an earlier
   request left there.
2. **Handing over.** When a region passes to the device, for it to read
   or to write, the CPU cleans every line of it to the point of
   coherency. Afterwards no line of the region is dirty in any cache.
3. **Taking back.** Before the CPU reads a region the device may have
   written, after it has read the device's report that the region is
   done, the CPU cleans and invalidates every line of it. Since rule 2
   left none dirty and the CPU stored nothing since, the clean writes
   nothing back; the invalidate discards any line the CPU fetched by
   speculation while the device held the region.

Three barriers complete them:

* the **publish barrier**, after the handing over and before the register
  write that tells the device, so the device sees every store and every
  clean, and no load of a region taken back is still pending when the
  device may write it again;
* the **report barrier**, after the read of the device's report and before
  the taking back and the reads that follow; it orders loads and stores
  both, since a barrier that orders cache maintenance must, so neither a
  maintenance instruction nor a read moves before the report;
* the **completion barrier**, after taking back and before the reads, so
  the invalidates are complete when the CPU reads.

For a coherent device rules 2 and 3 are empty, and with them the
completion barrier; rule 1 and the publish and report barriers stay. The
report barrier is the same for both, so there is one kind of it.

**What disappears.** Each failure a non-coherent device invites is a case
the construction cannot reach, not a case it handles:

| Failure | Why it cannot happen |
| --- | --- |
| the device reads data still in a cache | rule 2 cleans every region before the publish barrier, and the device learns of the region only from the write after it |
| a dirty line is evicted over what the device wrote | rule 2 leaves no dirty line, and the CPU stores nothing into a region the device holds |
| the CPU reads a line it fetched before the device wrote | rule 3 invalidates after the report and before the read |
| the install's zeroed used ring is evicted over the device's first completion | the used ring's writer changes from the CPU to the device at the install, so rule 2 cleans it like a posted buffer |
| maintenance misses a line inside a granule | maintenance steps by `L`, the smallest line, not by `G` |
| maintenance of one region destroys another's data | no granule holds bytes of two regions |
| a driver discards data it did not write | there is no invalidate alone, only clean and invalidate, which loses nothing; on AArch64 user mode cannot invalidate alone anyway |
| a descriptor form forgets a handoff, maintenance or a barrier | forms name none of them; the sequencer derives them from the ledger's change and the records it writes |
| a completion returns an earlier request's bytes | rule 1 zeroed every byte the plan did not fill before the device held the buffer |

## Calls, observations and plans

A descriptor form's core is a pure state machine over the queue's
protocol state: its tags, for ADMA2 whether the queue is idle, armed or
in flight, for the TRB form its slots, queues and command in flight.
Which buffers are free and which records are live it reads from the
ledger ([The ledger](#the-ledger)), which it changes only through the
pure sequencer: the core owns the protocol over the sequencer, which
judges each decision and returns its effects with the next ledger, and
the effect layer applies that output. A queue call
runs in rounds. Each form
supplies one pure **round function** (`erx_device_queue_round` for the
split ring, `erx_device_genet_round` for the register ring, and ADMA2's
beside them), the form's only entry from the effect layer. It takes a
**request**, the call (install, post, complete, and for a form that has
them the idle report and the engine's start) with the record's facts the
form reads (the queue's number, its device base and pool offset, whether
it is ready, a post's pieces, a completion's bounds), the round's number,
the values the call's observations read, and the ledger, which only the
sequencer it calls advances. It
returns either an **observation**, a bounded list of reads it needs, or a
**decision**, a plan and the core's next protocol state, or the call's
end with its status. A
decision that takes buffers back carries the call's **answers**, each a
tag, the bytes the device wrote and how many of the plan's copy steps,
in order, fill them. The effect layer, `erx_device.c`, has one loop for
every form, `run_call`: it asks the round function for round after round,
performs an observation's reads with the maintenance and barrier the
sequencer adds and hands the values to the next round, runs a decision
whole, and gives each answer's bytes to the caller's sink, with the copy
destinations laid end to end inside what the sink made for that answer
and refused before any effect unless the answers cover the copies exactly.
It decides nothing itself, and no caller strings a form's builders
together: which observation follows which, and the state after each
decision, are the round function's, tested on the host. A call ends
within a fixed number of rounds, or the queue breaks. The order of calls
across queues, such as GENET's two directions in a negotiation, is the
device's negotiation's. A form needs at most two observations per call.
virtio's completion and xHCI's are each one **acquisition** of the
structure the device writes in order, which the trusted side performs
([Releases](#releases)); GENET's receive completion reads the producer
index, then the status of each descriptor it covers, at most the queue's
size; GENET's transmit completion reads the consumer index; ADMA2's
reads `interrupt`. A value out of its bound breaks the queue, as a
malformed used entry does.

A plan is a list over a closed set of steps, none of which carries a
device address:

* `record`: a description of one record of a table the CPU writes, which
  the sequencer writes ([Descriptions](#descriptions));
* `fill`: a copy of an `out` segment's bytes into a buffer a `record` of
  the same plan names;
* `control`: a stop or a reset written to an owned register, every field
  of which its table fixes;
* `copy`: bytes of a buffer coming back, up to the length the device
  reported, into a fresh binary.

An observation is a list of `report` steps, each a read of a register
the form's table names, or one `acquire` step, which names a structure
the device writes in order, a used ring or the event ring, and the most
records the call takes from it; where in the structure it reads, and in
what order, are the sequencer's. A decision that takes back also says
how many of the call's reports it consumes.

**The sequencer.** `erx_device_dma_order(context, ledger, plan, reports,
coherent, G, L)`, a pure function, derives from the ledger and the plan
the handoffs, the bytes of every record, and the effects in their one
order, and returns them with the next ledger. A decision that hands over
is a publication ([Publication](#publication)): its holding hands to the
device every region its records name that no holding held, a buffer
posted, and at an install the used ring or the event ring; and every
region it writes, whose writer stays the CPU, passes to the device for
reading. A decision that takes back ends the holdings its reports
release ([Releases](#releases)), and every region no remaining holding
holds comes back: a buffer completed, and after a reset's idle report
every region of the queue. For a publication: the zeroing of rule 1 for
each buffer passing to the device; the fills; the records, each written
whole, an install's zeroing of the rings among them; the clean of every
region passing to the device; then, after a publish barrier, the
activation, a ring field's followed by the clean of its line, and the
doorbell after another publish barrier. For an observation of
registers: the reads, then the report barrier. For an acquisition, in
two phases ([Releases](#releases)): the clean and invalidate of the
lines of the structure's validity and a completion barrier, the
validity's reads, the report barrier; then the clean and invalidate of
the lines of every record the validity covers, a completion barrier,
those records' reads, and the report barrier again. For a decision
that takes back: the clean and invalidate of every region coming back;
the completion barrier; each `copy`; then the records a release derives,
xHCI's `ERDP` at the new consumer position and a disabled slot's cleared
DCBAA entry, each written and cleaned. A call that takes a buffer back
and hands it out again, as the register ring's receive queue does, is a
decision that takes back followed by one that hands over, each against
its own ledger, and so is `negotiate/2` after its idle report: one
decision takes every region of the queue back, the next installs it. So
the install's zeroed rings are clean before the base addresses and the
ready bit are written, and no dirty line of a zeroed used ring is left
for a later clean and invalidate to write over the device's first
completion.

**The check.** `erx_device_dma_check(context, ledger, plan, reports)`
validates every decision and observation before any effect, as
[The check](#the-check) says, with `reports` the values the call's
observations read, which the effect layer keeps. A plan that fails it is
a bug in the core, not an input, and the call is `badarg` with nothing
applied.

## The check

`erx_device_dma_check` verifies a form core's output without trusting
the core, and refuses every plan after which any of three properties
could fail, for every form:

* **Inside the memory.** Every address a device follows, and every byte
  it may move from there, lies inside the record's DMA memory, at a
  record or a buffer meant for it. No IOMMU confines the device
  ([design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel),
  FD12), so an address outside the memory reaches any memory, and one
  between records makes the device take padding or a stale record for a
  live one.
* **One writer.** No region has two writers, and the device writes only
  regions it holds. On a device that is not coherent one writeback
  carrying bytes of two writers loses one writer's bytes, and a device
  that writes a ring or a table it should only read can plant addresses
  there.
* **A queue's own buffers.** A transfer moves bytes only to and from
  buffers posted on its own queue. Behind a USB controller each queue is
  an endpoint of a device that is untrusted, so a transfer that reached
  another queue's buffer would hand one device's bytes to another
  device's driver.

**The trusted side and the core.** The core is trusted to say what it
wants, never where the device reads, when it may read, or what it holds.
Those belong to the NIF's trusted side, the check and the sequencer: two
pure functions over one value that the effect layer keeps and nothing
else changes, the record's **ledger**.

* The core **describes** the records it wants, a transfer, a command or
  a chain, by meaning, field values and names, and writes no byte the
  device reads as a structure ([Descriptions](#descriptions)).
* The check judges a plan's descriptions against the ledger
  ([The rules](#the-rules)).
* The sequencer writes every record the device reads, from the
  descriptions and the layout; makes each run live with one store of its
  own after the publish barrier ([Publication](#publication)); reads the
  structures the device writes in order itself, the validity before the
  records it covers; ends what the device holds only by those reports
  ([Releases](#releases)); and returns the next ledger.

So the order the device sees, which records are live and which buffers
the device holds have one owner, and so does every fact on which a
safe release depends: which reports the device finished writing, and,
for the TRB form, which endpoints a command in flight may still retire
and which ones a command may drop. A core keeps only its protocol: tags,
a queue's states for its answers, the command it is waiting on; what it
needs of the ledger's facts it reads from the ledger.

### The ledger

The ledger is one value per queue record; the TRB form's record is the
whole controller. Its persistent regions are the one exception: the
device record owns one region table, which every ledger of the device
reads and none changes.

| Part | What it says | Made or changed by |
| --- | --- | --- |
| the layout | the record's regions, each holding one structure, with that structure's writer, or a buffer; each table's region, record count and stride | made once at install from the form's layout and the counts read from the device, and checked then: every region whole granules, ascending, disjoint, inside the memory and below the form's address width |
| the positions | for each ring the CPU writes, the next position the sequencer publishes at, with a TRB ring's cycle state there; for each structure the device writes in order, the next position the CPU consumes, with the event ring's cycle state there | publications and releases |
| the holdings | one for each publication the device may still act on: the records it made live, the regions it handed to the device, and the report that ends it | publications begin them, releases end them |
| the persistent regions | the device's regions a region entry may name, each by its name, with its device address and whole length: the device record's one region table, read through a pointer | added to the device's table one at a time, each once, under the device lock, the same region again adding nothing; kept for the boot, a reset included |
| the bindings | the TRB form's: the endpoint each transfer ring is bound to, and while a drop-and-add is in flight an endpoint's old ring and its new one | the publications of the commands that bind, and their completions |
| the command's reach | the TRB form's: the command in flight's reach, its meaning's `reach` mark, and the endpoints it acts on, which it closes to new transfers; each endpoint's **state**, `disabled`, `running`, `stopped` or `halted` | a command's publication records its reach and its completion ends it, its success retiring every live transfer holding on the rings it restarts or unbinds, the ones live there at its publication since the closure admits no post in between; an endpoint's state changes only on what the trusted side did or consumed: an endpoint no ring is bound to is `disabled`; a binding, or the publication of a transfer, sets `running`; a consumed Stop Endpoint or Reset Endpoint success sets `stopped`; a consumed error event that halts it sets `halted` |

A region's writer is derived: the device's while a holding holds it, the
CPU's otherwise. A record is live while a holding holds it. A core reads
the ledger through accessors (which buffers are free, a ring's
positions, a queue's live transfers, whether an endpoint is closed and
its state) and states no writer itself.

**Many tables of one structure, and rings placed in order.** A layout
may hold several tables of one structure, as the TRB form holds one
transfer ring per queue block, and the regions of its tables and pools
may lie in any order, disjoint. Its buffers lie in **pools**, each of
one size and stride, numbered across the layout; a table that
descriptions fill names its pool, the buffers of its binding: virtio's
descriptor table the one pool, a transfer ring its block's, and the
command ring a pool that holds just the input context, so a command's
input-context name is a buffer of the command ring's pool, held while
the command is in flight. A name of a
buffer outside its record's table's pool breaks the bindings rule.
Whether a table **needs a binding** is its structure's, as the formats
mark it (`needs_binding`): a transfer ring needs one and is placed as a
ring, the command ring and virtio's tables do not, and a structure that
needs none lies in one table. A run describes
records of one table: the ring the ledger binds to the endpoint the
publication names, or, for none, the one table of its structure that
needs no binding. A table's stride is the size its structure's records
share, which the generator emits from the formats, and a ring's is also
its link TRB's, since the sequencer writes a link into every ring. A table
is placed free (virtio's descriptors), in order by the sequencer alone
(virtio's available ring), or as a **ring**, whose descriptions take its
next positions: its last record is the sequencer's link, which a run
takes where it reaches it, and where it ends just before it, so the
position never rests there; the cycle state at a position is 1 on the
lap a binding started and toggles with each lap. The room rule asks
every position a run takes, its links included, to be unheld, so a wrap
never reuses a held TRB, and a ring that takes no commands to hold fewer
holdings than its pool has buffers before a run, so a run that names no
buffer, a control transfer without a data stage, still counts against
its pool: a transfer ring's TDs in flight never outnumber its block's
buffers. A ring that takes commands, one whose structure's meanings
have reaches in `abi/formats`, the command ring, holds one command at a
time: the ledger's own fact, set when a command's holding begins and
refused while that holding lives, which no pool's size stands in for. A binding begins only with the holding of the
binding command's publication, which carries at most `ERX_DMA_BINDS_MAX`
bindings, only if its meaning's reach binds. Each is refused unless the
ring needs a binding and is bound to no endpoint, no two of them name
one endpoint or one ring, and the endpoint is bound to no ring or to
one the command drops, a drop-and-add
([design-usb.md](design-usb.md#what-the-dma-check-judges)). Such a ring
holds no record, since it takes no run unbound, and a binding ends only
at a command's consumed success, which retires every transfer on its
ring, or at its own command's failure, while the reach has kept its
endpoint closed. It returns the position to the first record on
a new lap of cycle state 1, and the command's sequence zeroes the ring
and writes its link before the command's activation. A
holding's head, the record its ending report names, is a chain's first
descriptor and a TRB run's last description, the TD's last TRB, which
its success or short packet names; the report's device address names a
record only at the start of one, by the layout's one map from address
to record ([Releases](#releases)).

A region reaches its device's table by the one transition that adds a
persistent region, at the region's making. It refuses, changing
nothing, a name the table already holds with other values, more regions
than a record has, and a length of 0 or one the region entry's length
field cannot hold. A queue reaches a region only through the ledger's
one lookup by name, which gives it only a region that fits it: below the
form's address width and sharing no address with the queue's memory,
which no region entry may point the device into, whichever of the two
was made first. A queue's ledger reads its own device's table alone, so
a region of another device is a name the ledger does not hold, by
construction.

### Descriptions

A `record` step describes one record of a table the CPU writes:

* its **meaning**, one of the closed set its table offers, each a layout
  of `abi/formats` whose `meaning` line names the table's structure, except ADMA2's one meaning, the transfer, which no
  layout holds and the sequencer splits into entries of
  `erx_sdhci_adma2_entry`;
* the values of the meaning's **free** fields, those its layout marks
  `states`, and each reference's length;
* each **reference** as a **name**: a buffer of the table's binding with
  an offset into it, the queue's input context, or an endpoint whose
  bound ring the record points at.

It carries no address, no position and no fixed field, and none of the
fields that give a ring its structure: the selector, the cycle bit, a
link, virtio's `next` and `NEXT`, ADMA2's end attribute, an input
context's add and drop flags. The sequencer derives each: the selector
from the meaning, a fixed field from its mark, an address from its name
and the layout, the rest from where it places the run. ADMA2's table
offers one meaning that describes a whole transfer, its buffer and its
extent in blocks, and the sequencer splits it into the entries, so no
core writes an entry's length, whose encoding 0 moves more than any
entry it could describe ([The ADMA2 table](#the-descriptor-forms)). A record that
carries another, as a command carries its input context, is described
with it in the same plan.

The sequencer also writes, from the layout alone and with no core naming
any part of it, every register record that names a table, at install:
virtio's queue registers, GENET's ring registers and standing
descriptors, xHCI's `DCBAAP`, `CONFIG`, `ERSTSZ`, `ERSTBA`, `ERDP` and
`CRCR`; each count among them is its table's declared count, never its
region's size. It writes ADMA2's `adma_address` at every post, and the
records that tie
tables together (the DCBAA, the scratchpad array, the segment table,
each TRB ring's link), and every activation and doorbell.

A record in memory is written only by its layout's generated encoder, a
meaning's or one of the sequencer's own records'
([What the formats say](#what-the-formats-say)). The header also gives
every layout's fields setters, and none of them writes such a record:
only the sequencer stores into a region that holds a structure, a
chokepoint checked at build, and it stores only records an encoder
built. A record in registers,
GENET's transmit descriptor status word (`TX_DESC_STATUS` in
`hw/svd/genet/genet.svd`), is written as one store of a value built
from zero through the SVD's generated accessors, never read, modified
and written back, so no field the core did not describe keeps a value
from before; its fixed fields are the form's table's
([What each form's tables say](#what-each-forms-tables-say)). The
receive status word, `RX_DESC_STATUS`, is the controller's report of a
received frame: it is read, one load each, for the positions the
receive producer index covers, and never written. A receive hand-back
writes only the receive consumer index, and every descriptor's address
is written once, at install.

A **region entry** is a record the sequencer writes from a region's
name, the `out` segment `{region, R}` of a post
([design-runtime.md](design-runtime.md#the-device-nif), Regions and
Posting), as virtio-gpu's resource backing holds
`erx_virtio_gpu_mem_entry` entries (Virtio 1.2, section 5.7.6):

* **Where it lies.** The entry takes the segment's place among the
  post's `out` segments, inside the buffer the post fills for the device
  to read, at the offset the segments before it end at; the post's
  description reaches it as one length of that buffer. It is a record
  of the buffer, in no table, and no core describes it: the name is the
  whole of its input.
* **What it says.** `R` must be a persistent region the queue's ledger
  holds ([The ledger](#the-ledger)); one of another device, or none, is
  not, and fails the post. The entry's address is that region's device address and its
  length the region's whole length, both derived, its padding fixed at
  0, so the layout has no free place; its encoder refuses a length its
  field cannot hold.
* **Who holds what.** The posted buffer that holds the entry is
  published and released as any buffer is: the publication's holding
  holds it, and its release returns it. The region the entry names is
  no holding's. It is not a region of the queue's layout but one of the
  record's persistent regions ([Regions and
  writers](#the-construction-handoffs-of-granules)), made only on a
  coherent device, kept for the boot and written by the CPU alone; a
  publication neither hands it over nor cleans it, and a release never
  returns it. The ledger's derived writer covers the queue's regions,
  and a persistent region stays the CPU's whatever posts name it.

### Publication

A decision that hands over is one **publication**: the records it
describes, its fills, and its call, which says what the sequencer makes
live. The sequencer:

1. **places** the run: the records of a ring take its next positions, a
   run that reaches a TRB ring's last record before the link taking the
   link with it; virtio's descriptors take free descriptors of the
   table, chained in the plan's order, and its available entry the next
   position; a carried record takes its own table's record;
2. **encodes** every record whole from its description: a record in
   memory through its meaning's generated encoder, the derived fields
   included, and a region entry through its layout's; a record in
   registers, GENET's transmit status word, as one store of a value
   built from zero through the SVD's generated accessors;
3. writes the fills, rule 1's zeros and the records, then cleans every
   region passing to the device, in the order
   [the sequencer](#calls-observations-and-plans) gives;
4. after the publish barrier, writes the **activation**, the one store
   that makes the run live: the run's first TRB's cycle word; virtio's
   available index; GENET's transmit producer index, or its receive
   consumer index when it hands buffers back; `adma_address`, ahead of
   the command `command/2` writes; an install's ready bit, run bit or
   engine enable; then the doorbell, where the form has one;
5. records the holding: the positions and records the run made live,
   every region of the queue's layout its names reach (a region entry's
   persistent region is none of them), and the report that ends it; for a TRB
   command, also its meaning's reach and the endpoints it acts on, which
   it closes until its completion
   ([design-usb.md](design-usb.md#what-the-dma-check-judges)); for a
   command that binds, the bindings its publication carries, each a ring
   and an endpoint the check judged with the rest of it, which the
   holding makes as it begins, so a refused publication binds nothing,
   and keeps as the bindings the command's failure ends, but a failed
   Address Device's, which stays until Disable Slot
   ([design-usb.md](design-usb.md#what-the-dma-check-judges)).

**Nothing of a run is reachable before its activation.** A device
reaches a ring's records only from its own position, and stops at the
first record not yet live: a TRB whose cycle bit is not the ring's cycle
state (xHCI 4.9.2, pp. 170-171), the available entry at the available
index (Virtio 1.2, section 2.7.13.3), the GENET descriptor at the
producer index. Its position is the ledger's next position or behind it,
since every value that sets it is the sequencer's, written from the
ledger: an install's ring addresses, `CRCR`, an endpoint context's
dequeue pointer, Set TR Dequeue's pointer. The sequencer writes a run's
first record with its activation field not yet live and the run's later
records behind it, so no record of a run, whole or half written, is live
before the activation, and no record is rewritten while a holding holds
it.

**Inactive initialisation.** At install, and whenever a TRB ring is
bound to an endpoint, the sequencer zeroes the ring, writes its link and
sets its position to the first record with cycle state 1, so the
controller acts on no zeroed TRB, whose cycle bit is 0, and no zeroed
record needs a meaning. A zeroed virtio descriptor is read only through
a chain an available entry names, and a GENET descriptor only inside its
indexes' window.

**Banked registers.** virtio-mmio's queue registers are banked by
`QueueSel` (Virtio 1.2, section 4.2.2). The install of a queue writes
`QueueSel` with the queue's own number, from the record, then
`QueueNum`, the three ring addresses and `QueueReady` last, in one
decision under the device lock, so every banked write lands in the
queue's own bank.

### Releases

A holding ends only on a report of the device's own, which the effect
layer read in an observation of the same call and keeps unchanged. A
decision that takes back says how many of the call's reports it
consumes, in order from the ledger's consumer position of each structure
the device writes; the sequencer derives the releases from those reports
alone, by the `releases` mark of each report's meaning
([What the formats say](#what-the-formats-say)), and advances the
consumer position. Nothing a core says chooses what
comes back. Its own reading of the same reports decides only its answers
and its states, and a copy reads only a buffer a release of the same
decision returns. A report whose meaning releases a holding but which
names none that is live (a used element naming no live chain's head, an
index past what is live) is refused, and the queue breaks, as a
malformed used entry breaks it. So is a record whose selector names no
meaning of its structure, such as an xHCI Host Controller Event (TRB
type 37), which no meaning of the event ring selects: the sequencer
cannot tell what such a record releases, so it releases nothing and
every holding stays held until the reset's idle report returns it. A
record whose meaning releases nothing, a port event, or whose release
[design-usb.md](design-usb.md#what-the-dma-check-judges) lists as
nothing, a short packet on a data stage, is **passed**: consumed, its
consumer position advanced, ending no holding; a pass is refused for a
record that names a live holding's head, so it never keeps a holding its
report ends. The queue breaks rather than skipping the record, because a skip would
consume a report the design gives no meaning, here the controller's own
error report, an event ring full among them, which
[design-usb.md](design-usb.md#the-trb-ring-form) already treats as
breaking the form.

**A report is a snapshot the trusted side acquired.** A device writes a
record of a ring it fills in more than one store and says only which
store makes the record valid: an xHCI controller that writes an event
TRB in more than one operation writes Dword 3, which holds the cycle
bit, last (xHCI 4.11.3, implementation note "Event TRB Updating",
p. 222), and a virtio device sets a used element's `len` before it
updates the used index that covers it (Virtio 1.2, section 2.7.8.2). A
read of a whole event TRB taken while the controller writes it can join
an old pointer to a new cycle bit, and once the event ring has wrapped
that pointer can name another live transfer. So no core reads such a
ring. Its `acquire` step names the ring and a count, and the sequencer
reads it in two phases: first the **validity**, the used index, or each
event TRB's cycle word from the consumer position on, stopping at the
first whose cycle bit is not the ledger's consumer cycle state, then the
report barrier; then, with the lines of every record the validity covers
cleaned and invalidated again and a completion barrier passed, those
records whole. A record's report is its second-phase snapshot, taken
only of a record the first phase found valid, so a record not yet
written is never read and no report of it can be consumed. The second
phase's clean and invalidate is what makes the snapshot whole when the
first phase's line fill was torn around the device's stores: it drops
that line, and the reload fetches a record whose last store has landed.
That this suffices on AArch64 is unverified. It rests on no load after
a clean and invalidate by address, and the completion barrier that
follows it, being satisfied by a line fill begun before them; the Arm
Architecture Reference Manual's passage on the ordering and completion
of data cache maintenance instructions (DDI 0487 M.d, the edition
[research-erts-host.md](research-erts-host.md) cites) was not read
here, and no local copy is recorded beside the xHCI specification. A
litmus test like those under `test/litmus/` would settle it if herd7's
AArch64 model can state cache maintenance against a non-coherent
observer, which is itself unchecked: a device thread storing a record's
payload and then its validity to memory, a CPU thread loading the
validity, cleaning and invalidating the line, passing the completion
barrier and loading the payload, with new validity and old payload
forbidden. Failing that, a probe on the Raspberry Pi 4's VL805 under a
stress of short transfers compares each second-phase pointer with the
TRB the ledger expects the event to name, and counts the events whose
first-phase and second-phase snapshots differ. A register a
report reads, GENET's indexes or ADMA2's `interrupt`, is one load and
needs no acquisition.

| Form | Report | Release |
| --- | --- | --- |
| split ring | a used element, at the next position below the used index | the holding whose chain's head its `id` names: the chain's descriptors, its available entry and its buffers |
| register ring | the transmit consumer index | the holdings from the consumer position up to the index, at most the number live |
| register ring | the receive producer index | the positions from the consumer position up to the index, at most the ring's size, each with its buffer; the hand-back publishes them again |
| ADMA2 table | `interrupt` with transfer complete set and every error status clear | the one holding |
| TRB ring | an event | as [design-usb.md](design-usb.md#what-the-dma-check-judges) lists |
| every form | the device's idle report after a reset | every holding |

A virtio available entry is released with its chain. Virtio's own rule
is looser: the device reads available entries in order, so one whose
chain came back proves every earlier entry read. Holding the entry with
its chain keeps one kind of release for every form; it costs a post
`{error, full}` only while the chain posted a queue's size of posts
earlier is still outstanding.

### The rules

The check judges a plan against the ledger and the call's reports, in
one pass. A plan passes when every rule holds:

| Rule | What it says | The failure it prevents |
| --- | --- | --- |
| calls | each step is one its call makes, from a closed set of calls: records and fills in a run's publication; in an install's, no record and no fill, only the zeroed rings, the queue registers the layout gives and the ready bit, on a ledger as the idle report left it; a control in a reset, copies in a take-back, reports in an observation | a store while the device may hold what it changes, such as an install zeroing a ring a live chain is on; a copy outside a take-back |
| meanings | each record's meaning is one its table offers, and each free field's value fits its bits | a record the form never builds reaching the device (a link, an indirect table, streams, event data); a value spilling into a neighbouring field, such as a length into the interrupter target |
| names | each name lies in its target: a buffer of the record's binding, the queue's input context, an endpoint with a ring bound to it; no name names a buffer a live holding holds; one publication may name a buffer at several ranges, each inside it, and its holding holds that buffer once | an address outside the memory or between records; a buffer the device holds posted again |
| bindings | a transfer record names only buffers of its own ring's block; only a command whose meaning's reach binds carries bindings, at most `ERX_DMA_BINDS_MAX`, Address Device's EP0 alone and Configure Endpoint's indexes 2 and up, each to a ring bound to no endpoint, no two to one endpoint or one ring, and to an endpoint already bound only when the command drops it | one queue's transfer reaching another's buffer; device A's endpoint run on device B's ring; a binding no command makes, which points the ledger at a ring the controller does not serve |
| lengths | each length lies inside its named buffer from the named offset; an ADMA2 extent is at least one block | a transfer past its buffer; an ADMA2 entry of length 0, which moves 65,536 bytes |
| reach | the TRB form's, judged by the command's meaning's `reach` mark: no transfer is published on an endpoint the command in flight closes, or on a `halted` one; a Stop Endpoint, Reset Endpoint or Set TR Dequeue Pointer names an endpoint that is not `disabled`; a Configure Endpoint that drops an endpoint, alone or with an add, is published only when that endpoint is `stopped`, or `running` with no live transfer; a Disable Slot only when no endpoint of its slot is `running` with a live transfer | a Set TR Dequeue Pointer whose success retires a transfer published after its pointer was fixed, which the controller then runs; a transfer on a ring a binding command in flight may yet unbind; a command the specification leaves undefined in the endpoint's state, a drop on a halted endpoint or on a running one that is not idle (xHCI 4.6.6, p. 117; 4.6.8, p. 132), a Disable Slot with a transfer in progress (4.6.4, p. 109); a transfer on a halted endpoint, whose doorbell the controller disables (4.6.8, p. 128), leaving the ledger's state wrong |
| room | the run fits: as many free positions as it takes, a link it reaches among them; free descriptors and a free available entry; a carried record no holding holds | a live record overwritten, such as a TRB the controller has not fetched or the input context of a command in flight |
| fills | an `out` segment's bytes go only inside a range a record of the plan names, and no two fills share a byte; a region entry's fill is one entry long and names a persistent region the ledger holds | the CPU storing into a buffer the device holds; a later fill overwriting part of an earlier, as one region entry's length written over another's address; the device sent through a region entry to an address outside the device's regions, another device's region among them |
| controls | a control step writes an owned register inside the window, with every field its table fixes for a stop or a reset | a core aiming the device through a register |
| releases | a report is a register its table names, or a snapshot an `acquire` step took of a record its validity covered; a take-back consumes reports from the consumer positions, each releasing what its meaning says, or nothing; every copy reads a buffer released in the same decision, inside it | a buffer reused while the device holds it; a report read twice to release a later holding; a torn record releasing another transfer's holding; a copy of bytes the device still holds |

The check carries no direction. Which ranges the device reads or writes
is the request's meaning, owned by the form: virtio's by each segment's
kind, GENET's by the ring, which the device reads to transmit and writes
on receive, ADMA2's by its command's posted direction, the TRB form's by the
endpoint's direction and a control transfer's setup
([design-usb.md](design-usb.md#the-trb-ring-form)). A fill where the
device writes replaces a store rule 1 would have made as zeros, so a short
completion returns the device's bytes, the post's own fill or zeros.

**How the properties follow.** The device follows only addresses the
sequencer wrote: from the layout at install, or from a name the check
found inside its target, as the start of a record of the target's table,
a buffer and an offset with the length inside, or a region entry's
region. A ring it walks ends
in a link the sequencer wrote, virtio's `next` the sequencer derives
from the chain it placed, and the device acts only on live records, each
written whole from a description the check judged: inside the memory.
The CPU stores only through the sequencer, only into regions no holding
holds besides each run's one activation field; the device writes only
regions a holding handed to it; a structure the CPU writes is never
named as data, since names of data are buffers; and a region passes back
to the CPU only by a release, so only when the device said it was done,
in a record the acquisition found finished, and a command's success
retires only the transfers its publication fixed, on endpoints that took
no new transfer meanwhile: one writer. A transfer record names only buffers of its ring's block, a
ring is bound to one endpoint, and every record that points an endpoint
at a ring points it at the ring bound to it: a queue's own buffers.

**What the argument assumes.** The argument covers every address in a
record: the check never parses the bytes of an `out` segment, which a
core gives as payload. It therefore holds for a device only while no
payload format of that device carries an address the device follows,
or a count that makes the device read further payload bytes as such
addresses. Block, network and input requests, xHCI's data stages and
ADMA2's buffers carry none. virtio-gpu's control requests do: a core
can put any 64-bit value in an `{out, Binary}` segment shaped as a
`erx_virtio_gpu_mem_entry`, or overstate a resource backing's
`nr_entries` so the device reads the bytes after the region entries as
more entries. On a device whose window confines it, what such an address
reaches is bounded by the window; on an unconfined device it reaches any
memory, and for virtio-gpu "every address the device follows came from
a checked name" does not hold. The design makes no guarantee there: on
an unconfined device a payload format of which carries device
addresses, the argument claims nothing for the addresses in its
payloads.

### What the formats say

The marks are members of a `layout` in `abi/formats`, read by
`tools/lib/erx/abi_marks.rb` once `tools/lib/erx/abi_model.rb` has
resolved every type, and each format file declares its structures:

```
target NAME cpu|device        a structure a region may hold, and its writer
layout ...
  meaning TARGET              this layout is a meaning of TARGET's records: every table
                              of that structure offers it
  field NAME TYPE OFFSET device_address
    bits NAME LOW HIGH [shift N] device_address
                              the place holds an address the device follows into memory
  selects PLACE ENUM.MEMBER   this layout is the meaning when the bits hold MEMBER
  fixed PLACE VALUE           the meaning's one value there, which the sequencer writes
  refers PLACE TARGET [length PLACE [unit N]]
                              a reference, given as a name; its length, if any, in units of N bytes
  activates PLACE             the one bit whose value makes the record live
  derived PLACE               a field the sequencer computes from where it places the record
  states PLACE                a value neither the format nor the sequencer gives: a
                              description states it, or on a report the device
  releases PLACE TARGET [when PLACE ENUM.MEMBER...]
                              on a report: the place names the holding it ends, under those codes
```

A `PLACE` is `FIELD`, a field with no `bits` lines, or `FIELD.BITS`, one
bits range of a field; a field with bits is never named whole. A value
of an enum is spelled `ENUM.MEMBER`, and a `fixed` value is a number or
an `@` limit. `device_address` is a word of the place's own `field` or
`bits` line, not a mark, since it says what the place holds in every
layout, marked or not; it never names an address the CPU uses, such as
an ELF segment's or a PCIe BAR's. In a marked layout every place is
claimed by exactly one mark, so a place is free only by a mark: a place
a `states` mark claims, a reference's length, and a release's place and
its `when` place are **free**. Who gives a free place its value follows
from the layout's writer: the free places of a layout a description
states, its `states` places and each reference's length, are the
description's inputs; those of a report, its `states` places and its
release's place and `when` place, are the values the device states,
which the trusted side only reads. A
reference's place, the activation and each derived place are
**placed**: the sequencer supplies them. A device address is placed,
or is a release's place, never free or fixed, and a reference's place
is a device address. `TARGET` is a structure of the mark's own file or,
for a reference, `data`.

**A meaning's writer is its table's.** A layout's `meaning` line names
exactly one structure, and that structure's writer is the layout's. A
layout that is a meaning of a `device` structure is a **report**: the
device writes it, so it has no `refers` or `derived` mark, its free
places are what the device states, and only a report has a `releases`
mark. A `releases` mark names a `cpu` structure, since a holding is
always of records the CPU wrote: the used element releases descriptors
of the descriptor table, an event TRBs of a transfer ring or the
command ring. The port status change event is a report though it
releases nothing, because the event ring is a `device` structure; no
mark of its own decides that. A layout that is a meaning of a `cpu`
structure is one a description states.

**A layout with no `meaning` line is the CPU's.** It is offered by no
table, so no description names it: it is the sequencer's own record (a
link, the DCBAA's, the scratchpad array's and the segment table's
entries, the ADMA2 entry, a region entry), which has no free place, or a
part of a composed record (the input context's slot and endpoint
contexts), described only as part of the record that composes it. It is
never a report: a record the device writes reaches the trusted side only
through the acquisition, which reads only the structures declared
`device` and judges each record it takes by its structure's generated
list of meanings, so no layout outside those lists is ever read as what
the device states.

**What a table offers.** The meanings a table offers are the layouts
whose `meaning` line names its structure; no form lists them again, and
the check's meanings rule reads the generated list. The generator holds
each structure's meanings to what placement and acquisition need:

* they share one size, the table's stride;
* a structure with more than one meaning has a `selects` mark in each,
  on bits at the same offset and range, so, with the rule below, a
  selector value names at most one meaning in any table and a report's release is read under
  the one meaning its selector gives; a structure with one meaning may
  have no selector;
* every meaning of one structure has its `activates` mark on the same
  bit of a field at the same offset and width, or none has one. On a
  `device` structure that bit is the validity the acquisition reads
  first, in that field's one load, before it knows the record's meaning.
  A `device` structure whose meanings have no `activates` mark takes its
  validity from outside the record, as virtio's used ring does from its
  used index, which its form's acquisition reads instead.

**A selector value names one layout of its file.** Each enum member is
selected by at most one layout of the whole format file, a meaning or
not, and so is each value of a place's bits: two layouts that select
on bits at the same offset and range select different values there,
whatever enum or shift spells them, since the record holds the bits
and not the spelling. So the xHCI link TRB, which has no `meaning` line and lies in
every TRB ring, selects a type no meaning of any ring selects, and a
record the device writes with that type names no meaning of the event
ring ([Releases](#releases)).

The generator refuses a mark outside a `wire_le` layout, a
marked layout with a field that is not one unsigned integer or with a
`tail`, whose part the encoder would not write, a report with a
`refers` or `derived` mark, a `releases` mark on a layout that is no
report or naming a structure that is not `cpu`, a `meaning` line naming
other than one structure or one of another file, a structure whose
meanings differ in size, in where their selector lies or in where their
activation lies, a structure of more than one meaning one of which has
no selector, an enum member or a value of the same bits two layouts of the file select, two places of one encoder member name
(`a_b` and `a.b`), a place no mark claims,
a device address a description would state or the format fix, a
reference to a place that is no device address, `device_address` on a
field that has bits or is not one unsigned integer, an unknown target
or one of another file, a `selects` or `when` member outside its enum
or wider than its bits, a `fixed` value wider than its bits or with bits
below the place's shift, a place the layout does not have, an
`activates` mark of more than one bit, a place marked twice and a
second `selects`, `activates` or `releases` mark, each with the line of
the mark or of the place. It numbers the meanings, the layouts with a
`meaning` line and no others, from 1 in the order of their layouts'
names, `ERX_MEANING_<LAYOUT>`, so 0 is no meaning; the sequencer's own
records and the parts of composed records get no number. It
emits each structure's meanings as one list, and emits beside each
marked layout's accessors in `include/erx/abi.h`, except a report's:

```
erx_L_free_t      the free places, which a description states
erx_L_placed_t    the placed places: each reference's address, the activation, each derived place
bool erx_L_encode(erx_L_t *record, const erx_L_free_t *described,
    const erx_L_placed_t *placed)
```

Each input struct has one `uint64_t` member per place, `FIELD` or
`FIELD_BITS`, so a value reaches the encoder whole, and is left out with
its parameter when it would be empty. The encoder compares each input
with its place's maximum and, for a place with a shift, its alignment,
before it stores anything; it returns false, leaving the record
untouched, when a value does not fit, so no value is cut to its low
bits. It writes every byte of the record: the free and placed values,
the selector's member and each fixed value, and zero in every bit the
layout does not name. The encoders fill a host struct of a `wire_le`
layout, so the header asserts that the host is little-endian. A report
has its accessors and no encoder or input structs: nothing the device
states is ever an encoder input, and no description can state it. Since
a layout has one selector, each command the
command ring offers is a layout of its own. Where a record is composed of several layouts at a size
the controller reports, as the input context is of contexts of 32 or 64
bytes (xHCI 6.2.5), the encoder places each at its offset: the
sequencer's one composition of the input context (`erx_dma_input_context`)
encodes the input control, slot and endpoint contexts through their
layouts' encoders, context k at k times the controller's context size
(`HCCPARAMS1.CSZ`), the upper half of a 64-byte context left zero, and
refuses a size other than 32 or 64 and a composition past the buffer
the command names. A command's caller states only the free places, the
slot context's route, speed, root port, TT and hub fields and each
endpoint's type, packet size, burst, interval and service-interval
payload, which the form checks once where the command enters it; the
sequencer derives every other place from the publication: the add
flags from the contexts it writes, so a flag never names a context left
zero, the drop flags from its drops, Context Entries from the slot's
bindings that remain, each dequeue pointer and cycle state from the
ring the publication binds to the endpoint, at the binding's start, or,
for Evaluate Context, from EP0's bound ring at its position, and the
average TRB length from the type, packet and burst. A binding with no
carried context, or a carried context with no such ring, breaks the
publication. The xHCI
file holds the DCBAA's and the scratchpad array's entry layouts, the
endpoint context's `Mult`, `MaxPStreams`, `LSA` and `HID` bits and its
error count of 3, the slot context's exit latency of 0, the
normal and data stage TRBs' immediate-data bit and the event TRBs'
release marks; the slot context's address and slot state and the
endpoint context's state are fixed at 0, the controller's to write,
which software sets to 0 in an input context (xHCI 1.2, Table 6-7,
p. 447; Table 6-8, p. 450); it declares the transfer rings and the
command ring as `cpu` structures, the transfer ring marked
`needs_binding`, and the event ring as a `device` one, the nine commands
as the command ring's meanings (xHCI 1.2, 6.4.3), each with its `reach`
mark (`address`, `configure`, `stop`, `restart`, `disable`, or none for
No Op, Enable Slot and Evaluate Context) and its slot and endpoint
fields derived, the sequencer's from the publication's reach, and the
event TRBs as the event ring's. The virtio file holds the
descriptor's flag bits, the used element's release mark, the
descriptor table as a `cpu` structure and the used ring as a `device`
one, and the region entry `erx_virtio_gpu_mem_entry`, its address and
length derived and its padding fixed. The SDHCI file holds the ADMA2
entry, whose places are all fixed or derived, since the table's one
meaning is the transfer; the bits 15:6 that only 26-bit length mode
reads are named by no range, so the encoder writes them 0, and its
32-bit address refuses a wider value. A record the sequencer writes
from the layout alone has no free place: the DCBAA's, the scratchpad
array's and the segment table's entries and each link's segment pointer
are derived, and the link's other fields fixed.

### What each form's tables say

| Form | What the core describes | What the sequencer writes from the layout | Reports |
| --- | --- | --- | --- |
| split ring | a chain of descriptors, each with its address a buffer and an offset reaching `len`, `WRITE` free and `INDIRECT` fixed clear | the queue's registers, `QueueNum` the descriptor table's count, the rings' addresses as the queue's layout places them (`erx_device_queue.c`); each `next` and `NEXT`; the available ring | an acquisition: the used index, then each used element it covers, whose `id` releases its chain |
| register ring | a transmit position's status word: the length, of its standing buffer; start, end and append-CRC fixed | each descriptor's address, descriptor *k* to buffer *k*, at install; the ring's registers: the descriptor count the ring's size, start, end and the four pointers its first word, its last word and 0, the buffer length the pool's buffer size, the ring enables the form's own ring | the transmit consumer index; the receive producer index and each status word it covers |
| ADMA2 table | one transfer: the buffer and the extent, a count of 512-byte blocks from one to the buffer's | the entries the extent splits into, 64 blocks each and the last the rest, each with its address the buffer's plus its offset, valid set, its action a transfer and interrupt clear; the end attribute on the last; `adma_address`, the table's start | `interrupt` |
| TRB ring | as [design-usb.md](design-usb.md#what-the-dma-check-judges) lists | | |

### What the check carries

The trusted side's concepts and obligations, against a check that
folds a plan's raw stores into each record's end state and judges it:

| | Folded end states | Descriptions and the ledger |
| --- | --- | --- |
| who writes a record the device reads | the core, by raw stores | the sequencer, from the core's description |
| what an address is | the value in a reference field, decoded from the stores | never in a plan: a name the check finds in range, which the sequencer turns into an address |
| where a reference may point | any byte of a region holding its target | the start of a record of its target, or a buffer and an offset |
| indexes the device follows (virtio's `next`, the available heads) | unchecked | derived from the chain the sequencer places |
| a register bank | folded as one record whatever the selector | the selector written from the record, then the bank, in one decision |
| counts the device reads (`QueueNum`, `MaxSlotsEn`, `ERSTSZ`) | bounded by the region | the table's declared count |
| which contexts a command reads | gates read from the stored add flags | the add flags derived from the contexts described |
| zeros | an absent reference, passing where the device cannot follow it | never judged: an inactive record is not acted on |
| partial stores | refused by a whole-record rule | cannot be written |
| the order the device sees | each form's rule, tested by its model harness | the sequencer's one activation after the barrier, for every form |
| who holds a buffer | the core's next state, checked for direction | derived from the ledger's holdings |
| what ends a holding | the core's next state | a report the effect layer read, by its meaning's release |
| when a report is whole | the core's order of reads | the acquisition's: validity, then the records it covers |
| what a command retires | every transfer on its ring at completion | every live holding on the rings its reach restarts or unbinds at its completion, on endpoints it kept closed since its publication, so none published meanwhile |
| binding | a ring to its block's buffers | also an endpoint to its ring |
| region and width checks | every plan | once, on the layout at install |

It adds the ledger, one value with one owner; descriptions and names;
the activation field; the release marks of the report layouts; the
acquisition; and the TRB form's table of what each command's completion
releases, with the command's reach and each endpoint's state. It removes
the fold, address decoding, absent references, gates, the whole-record
rule, three of the four reaches (a fixed count, to the region's end,
none), the stores rule's value classes, the core's writer states and
the direction checks on them, and every form's publication rule with
its model-harness obligation. Placement moves rather than grows: ring
positions, cycle bits, links, `next` fields, the available and producer
indexes, doorbells and the install's register writes leave the four
cores, and the sequencer holds the one copy.

## Device addresses and reach

**The record.** Each DMA device's catalogue entry, and from it the
`given` record its holder reads
([design-fiasco.md](design-fiasco.md#device-records)), carries two
facts the root reads at boot from the device tree the firmware handed
over, with the reader of [design-device-tree.md](design-device-tree.md):

* `coherent`, a flag: set when the device's own node (a PCIe
  function's host bridge node, since the function has none) carries
  `dma-coherent`, the property the Devicetree Specification v0.4
  defines for a device on an architecture whose I/O is not coherent by
  default, with an empty value (section 2.3.10, p. 17); a mark with a
  value makes the facts malformed. Both supported trees mark devices on
  their own nodes: QEMU `virt` each virtio-mmio node, and the BCM2711's
  none. A `dma-noncoherent` on the node says what the default already
  says. Both marks on the node, or either mark on any node above it,
  makes the device's DMA facts absent with the reason `coherence`, so
  the device gets no DMA memory rather than a reading the specification
  does not give: it defines each mark for a device, not for a bus;
* the **DMA range**, `dma_cpu`, `dma_bus` and `dma_last`: the device's
  translation, not a list of memory. The device sees CPU address
  `dma_cpu + x` at bus address `dma_bus + x`, for every CPU address from
  `dma_cpu` through `dma_last`, the last one inclusive so that the whole
  address space can be written. A device with no defining `dma-ranges`
  has `0`, `0` and `2^64 - 1`. The reader computes it with the walk of
  `erx_dma_ranges`
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)), which keeps
  each window of the translation that RAM backs at least in part, whole,
  and the range is absent when no such window remains, or more than one,
  which no supported board's tree gives. Which RAM inside the window
  holds DMA memory is the allocator's question, answered where the
  memory is made (Reach, below).

The reader checks the tree's encoding and containment; it cannot check
that the hardware does what the tree says. A well-formed tree that
states a wrong translation aims the device outside the object, and a
wrong `dma-coherent` suppresses maintenance the device needs. The tree
is the firmware's, and the firmware is trusted as the machine's own
([design.md](design.md#residual-risks), "Closed firmware, and verified
boot only where secure boot is on"), so these are the firmware's
faults, not inputs the reader defends against; a tree the reader can
see is wrong fails safe, one it cannot see is wrong is believed.

No build-time record carries either fact: the manifest says which device
gets how much DMA memory, and the tree says how the device sees it, so
the firmware's rewrite of a range needs no record to agree with it
([design-device-tree.md](design-device-tree.md#open-decisions) keeps the
alternative of a manifest copy as an open decision). The reader's host
tests pin each platform's facts from its build-time tree and fail on a
DMA device whose facts are absent there, so a board tree whose marks or
ranges the reader refuses fails at build time, and the same tree from
the firmware fails safe at boot.

**Addresses.** Every address the NIF writes to a device is the device's
view of memory the record holds, computed by the NIF and never given to
or taken from Erlang. For a confined device it is the I/O address that
`erx_dma_map` gave the memory object in the device's window
([design-kernel.md](design-kernel.md#dma-and-the-iommu)), plus the
offset. For an unconfined device it is `erx_mem_dma_addr(mem, offset)`,
`physical + dma_bus - dma_cpu` for the device the object was made for;
the DMA range concerns only this path. Each descriptor form has an
address width, fixed by its descriptor format: 64 bits for virtio's
split ring, 40 for GENET's register ring, 32 for ADMA2 with 32-bit
descriptors. `queue_create/4` refuses with `{error, erange}`, taking
nothing, a queue any of whose device addresses would reach the width.

**Reach.** The object must lie wholly inside the device's range. On
erXos's kernel, `erx_mem_create_contiguous` allocates from the part of
the device's window that its contiguous pool's RAM backs, the window
found by the same walk over the same tree, so the kernel's range and the
record's are one. On Fiasco the root
makes each device's object from the contiguous pool: the object records
the entry's offset, `dma_bus - dma_cpu`, for `erx_mem_dma_addr`; a device
whose range is absent, or whose object's pages would fall outside it,
gets no DMA memory, and the root prints a line naming the device, its
range and the pool's physical address
([design-fiasco.md](design-fiasco.md#the-pool)). EMMC2 has DMA memory
on both kernels, at the range the firmware wrote for the board's
revision.

**The platforms.**

| Device | Coherent | DMA range | Form, width |
| --- | --- | --- | --- |
| QEMU `virt` virtio-mmio | yes | none: `0`, `0`, `2^64 - 1` | split ring, 64 |
| Pi 4 GENET | no | none: `0`, `0`, `2^64 - 1` | register ring, 40 |
| Pi 4 EMMC2 | no | `0`, `0xC0000000`, `0x3FFFFFFF` in Linux's tree; the firmware writes the board's own | ADMA2, 32 |

With `total_mem=1024` all of the Pi 4's RAM that erXos uses lies in the
first GiB (`config/platforms/raspi4b.json`, `ram_bytes`), inside every
range above.

## Register ownership

**The rule.** A register or a field is owned by the NIF when a write to
it can change an address the device uses, how many bytes the device moves
at an address, which descriptors the device takes as valid, how it reads
a descriptor, or how it reports the end of a transfer the NIF tracks.
The SVD source marks each register `ownedByNif`, and
may instead mark single fields of a register; the generator refuses a
register with neither. A wholly owned register is refused to `write/3`
and `write_field/4`, as now. `write_field/4` refuses an owned field
outright, `badarg`. For a register with an owned field, `write/3` reads
the register and refuses, `badarg`, a value that would change an owned
field from what the register holds, or that writes 1 to a one-to-clear
owned field, which is the write that changes it. A driver keeps its
read, modify and write of a shared register as it is: the owned field
goes back as it was read. A field may be owned only while a transfer is
in flight, marked so in the SVD source; SDHCI's are the only such fields.

**Every driver write takes the device lock.** `write/3` and
`write_field/4` take the device lock that every queue call holds, for
every register, owned field or not. So no driver write lands between a
check a queue call makes and the write that check guards, and the check
of an owned field reads the register under the same lock. The device
lock is held for one queue call or one register write and never across a
service call or a wait, so a register write waits at most for one queue
call; opens and bindings keep a lock of their own.

**Resets.** A software reset is a write like any other, and the rule
classifies it. A reset may return owned fields to their reset values and
stop a transfer. It stays the driver's when every act that makes the
device move data again passes a check the NIF makes, under the lock, that
reads back what the reset changed: then the reset cannot aim the device,
and a transfer it stops leaves its queue waiting for a completion that
does not come, until `negotiate/2`, whose own reset and idle report come
before any buffer is reused. A reset that can change an owned field of an
engine that keeps running across it is owned, since no check stands
between it and the engine's next access.

**virtio-mmio** keeps its list
([design-runtime.md](design-runtime.md#the-device-nif)): status, the
feature selectors and the driver's features, the queue selector, size,
ready bit and doorbell, and the rings' base addresses. Its reset is the
status, already owned.

**GENET** (offsets from FreeBSD's `if_genetreg.h:116-219`). Owned whole: every descriptor's three registers in
both directions; each of the 17 rings' registers in both directions
(producer and consumer index, buffer size and ring size, start and end
address, read and write pointer, and their high halves), from `0xC00`
past each direction's first descriptor and `0x40` apart, for the rings the NIF does
not use as for the one it does; and each direction's ring configuration
and DMA control, which enable rings and the engine. Not owned: DMA status,
burst size, the ring thresholds and timers, interrupt registers, the
receive and transmit buffer controls, the MAC and MDIO. The receive
buffer control's status block and alignment options move where a frame
lands inside a buffer, not how many bytes the engine writes, which the
ring's buffer size bounds; the board pass confirms that bound. GENET's
DMA engine runs between calls, so a reset that reached its ring or
descriptor registers would be owned; its own disable is the owned DMA
control. The UniMAC's software reset and the receive buffer and transmit
flushes (`if_genetreg.h:49-51, 75-77, 96`; FreeBSD's `gen_reset`,
`if_genet.c:488-514`) sit outside the DMA block. FreeBSD makes them
before it disables the engine (`if_genet.c:286-288, 873-875`); Linux makes the
MAC reset with the engine running but the two flushes only after a
confirmed stop, and both drivers rewrite every ring register they use
afterwards, so neither depends on a reset or a flush leaving the DMA
block's registers alone, and no source says whether one does
([GENET facts record](research-genet-bcm2711.md#mac-reset-rx-buffer-flush-and-tx-flush),
[Reinstalling the rings](research-genet-bcm2711.md#reinstalling-the-rings)).
So GENET's DMA is enabled only once the board pass has read every owned
register back unchanged across each of them
([Concurrency](#concurrency)); where one changes, it is marked owned and
moves into `negotiate/2`'s reset, after its confirmed stop, where the
install that follows rewrites the ring's registers.

**SDHCI** (offsets from FreeBSD's `sys/dev/sdhci/sdhci.h:102-325`). Owned whole: `dma_address`
(`0x00`), `adma_address` (`0x58`) and `cmdtm` (`0x0C`), as now. Owned
fields: the DMA select of host control 1 (`control0`, bits 4:3), and the
ADMA2 length mode, host version 4 enable and 64-bit addressing of host
control 2 (`control2`, bits 26, 28 and 29 of the word), each of which
changes where or how the controller reads addresses or descriptors; and
the stop at block gap request and the continue request of block gap
control (`control0`, bits 16 and 17), since a stop makes the controller
raise transfer complete with the block gap event before the transfer
has ended, and a continue resumes DMA into the buffer afterwards (Host
Controller, section 1.13.3.3, p. 20; section 2.2.13, table 2-19,
pp. 65-66). The NIF never requests a stop, so the driver can neither
pause nor abort a DMA transfer except by a reset.
Owned while a DMA transfer is in flight: `blksizecnt` (`0x04`), whose
block size and count bound the bytes the controller moves; in
`interrupt`, the **end statuses**: transfer complete (bit 1), the block
gap event (bit 2) and the error statuses (bits 16 to 31), each cleared
by writing it 1 (section 2.2.18, p. 76; section 2.2.19, p. 82); and in
its status enable `irpt_mask`, the **required enables**: transfer
complete's (bit 1) and the error status enables of bits 16 to 25,
command timeout through ADMA error, each read and write in every
controller with ADMA2 (section 2.2.21, table 2-28, pp. 88-89). A status
reads 0 while its enable is clear (section 2.2.18, p. 76; section
2.2.19, p. 82), so a required enable cleared during a transfer would
hide its end. The block gap event needs no enable among them: it is set
only by a stop (section 2.2.18, bit 2), which the owned stop request
rules out. The two sets differ on purpose. Bit 15 of `interrupt`, the
error summary, is
read only and set whenever any error status is (section 2.2.18, p. 76),
while bit 15 of `irpt_mask` is fixed to 0 (section 2.2.20, table 2-27,
p. 86); and the error enables of bits 26 to 31, tuning, response and the
vendor's, depend on the controller's version and features, so the NIF
requires none of them, and an error they report still breaks the queue.
The form names the fields of each set; their bits come from the SVD
source's field definitions, as every register bit the NIF uses does.
The software resets in `control1` stay the driver's:
every DMA transfer starts at `command/2`, which reads back under the lock
every field it relies on, whatever a reset returned to its reset value,
and a reset that stops the transfer leaves the queue in flight until
`negotiate/2`. The reset of all returns the controller's settings to
their reset values: both FreeBSD and Linux set power, clock and the
interrupt enables again after it
([facts record](research-sdhci-bcm2711.md#reset); FreeBSD's
`sdhci.c:385-404`). Which other fields each reset clears no source read
here lists in full, and the design does not need it to.

## The descriptor forms

Each form is a pure core beside `erx_device_queue` whose round function
returns its observations and decisions. `queue_create/4`, `post/4`, `post_frame/5`,
`complete/2` and `negotiate/2` keep their meaning and their answers for
every form; the record names the form its peripheral uses.

**The split ring (virtio).** As
[design-runtime.md](design-runtime.md#the-device-nif) describes. Its
descriptor table and its available ring are two regions, both written by
the CPU, and its used ring a third, written by the device, each starting
on a granule, so that each ring address the install writes names one
region holding one structure ([The check](#the-check)). Each ring's
start also keeps virtio's own alignment for it (Virtio 1.2, section
2.7), which the layout takes from the `virtq_desc_table_align`,
`virtq_avail_ring_align` and `virtq_used_ring_align` limits of
`abi/formats/virtio.txt`, and a queue memory whose device base is off
any of those alignments is refused. A post fills the
buffers' `out` bytes and describes its chain; the sequencer places the
chain in free descriptors, writes the available entry, and makes the
chain live with the available index, then the doorbell; the
device may take the chain as soon as it sees the available index
(Virtio 1.2, section 2.7.13.3), and the publish barrier before that
index already covers it. A completion observes the used index, then the
used entries it covers, and copies each buffer's bytes up to the length
the device reported.

**The register ring (GENET).** A queue has no ring memory: its rings are
the device's registers, so its pool begins at the queue's first page.
Buffer *i* is descriptor *i*'s for the life of the queue, so the NIF
writes each descriptor's address once, at install, and never again: to
the check its descriptors are a standing table, each bound to its buffer.
The
transmit queue is posted like any queue: `post_frame/5` copies the
prefix and the frame into the buffer of the ledger's next transmit
position and describes that descriptor's status, the length with start,
end and append-CRC fixed by the form; the sequencer writes it, then the
producer index. Its
completion observes the transmit consumer index once, which may advance
by at most the number in flight, and returns each tag with no bytes. The
receive queue is standing: install hands every buffer to the device, and
`complete/2` observes the receive producer index once, the low 16 bits
of its register, whose upper 16 count frames the controller discarded
([GENET facts record](research-genet-bcm2711.md#layout-of-a-dma-block)),
which may advance by at most the queue's size, then each new
descriptor's status once, whose length, bits 31:16, may be at most the
buffer size; it copies that many bytes, then hands the buffer back, the
sequencer writing the consumer index, in the same call, whether or not the driver
will drop the frame, so an errored frame never holds the ring (FreeBSD's
error path does not advance its index, which the record notes as a
stall, [Where the drivers disagree](research-genet-bcm2711.md#where-the-drivers-disagree)).
The length counts everything the controller wrote into the buffer: the
64-byte status block when the driver enables it, the 2-byte alignment
pad when it enables that, and the 4-byte FCS only when the UniMAC's
command register forwards it (CRC forward, bit 6); the driver strips
each it enabled, and writes the command register with CRC forward clear
at its reset, as FreeBSD does, so no FCS is counted
([The receive status word](research-genet-bcm2711.md#the-receive-status-word)).
Each completion carries as its tag the low 16 bits of the descriptor's
status, its flags: start of packet (bit 13), end of packet (bit 14),
and the error bits, overflow (bit 0), CRC error (bit 1), receive error
(bit 2), a frame not a whole number of octets (bit 3) and a length error
(bit 4) (`if_genetreg.h:168-176`; the record, for bits 0, 1, 3 and 4,
whose meanings come from register-field names alone). The driver drops a
frame that lacks start or end of packet or has any of bits 0 to 4 set,
the wider of the two published drivers' rules, since FreeBSD tests only
bit 2 (`if_genet.c:1404-1415`). The status word is the descriptor's
status register when the status block is off (`if_genet.c:1396-1400`),
so the driver needs no status block to see the flags. A receive post is
`badarg`. An index or a length beyond its bound breaks
the queue, as a malformed used entry does.

**The ADMA2 table (SDHCI).** A queue of one buffer and one table, since a
controller moves one command's data at a time; the table's device
address is fixed for the life of the queue. `adma_address` is not: the
controller advances it at every entry it fetches, and the specification
has the table's start written at the beginning of each ADMA2 transfer
(Host Controller, section 2.2.31, table 2-42, p. 116), so every post
writes it. The controller is kept to the transfer it was given by
binding three quantities to one number, the posted extent: the table's
lengths, the controller's block size and count, and the bytes copied
back.

* `post/4` takes one segment, `{out, Binary}` for a write to the card or
  `{in, Length}` for a read, of a positive multiple of 512 bytes no larger
  than the buffer. Its decision describes one transfer, the buffer and
  the extent as a count of blocks, which the check bounds to between one
  and the buffer's blocks; the sequencer splits it into one transfer
  entry with valid set per 64 blocks, 32 KiB, the last one holding the
  rest, interrupt clear on every entry, each entry's address the buffer's
  device address plus the entry's offset. Every entry but the last holds
  64 blocks and the last holds the rest of an extent of at least one
  block, so every entry holds 1 to 64 blocks: no entry's length field is
  0, which would move 65,536 bytes, and none is past the extent. 32 KiB
  is a multiple of the block size and of the 4-byte address unit, and
  lies below both readings of an entry's largest length (Host
  Controller, section 1.13.1.3 and table 1-12), so every entry's length
  and address are ones the specification defines and the lengths sum to
  the extent. A buffer of at most 1 MiB needs at most 32 entries, 256
  bytes of table. The table's end attribute is the sequencer's, set on
  the run's last entry, and the post's activation is its write of the
  table's device address to `adma_address`, after the table's and the
  buffer's cleans and the publish barrier, so
  that a controller that initialises ADMA2 at that write, as the
  specification allows (section 1.13.3.2, implementation note, p. 20),
  finds the table in memory. Whether the BCM2711 fetches at that write,
  which would move the register before `command/2` reads it back, the
  board pass settles. The queue is then **armed**.
* `command/2`, while the queue is armed, issues only a word that enables
  DMA, sets block count enable and data present, has the posted
  direction, and selects multiple blocks exactly when the extent is more
  than one block; before writing it, it reads, under the lock, that the
  DMA select is ADMA2 with 32-bit descriptors, host control 2's owned
  fields and the stop and continue requests are clear, `adma_address`
  holds the table's device address, `blksizecnt` holds a block size of
  512 and the extent's count, every required enable is set, and every
  end status and the error summary read clear. Anything else is
  `badarg`. It writes the word and the queue is **in flight**. While the
  queue is armed or in flight `command/2` issues nothing else, so no
  other command uses the data lines, stops the transfer early or raises a
  completion that is not this transfer's.
* `complete/2` in flight reads `interrupt` once. Any end status but
  transfer complete, or the error summary, alone or with transfer
  complete, breaks the queue: errors win, as in FreeBSD's data interrupt
  handler (`sdhci.c:2250-2265`), the buffer stays posted, `interrupt` is
  left as it is for the driver to read and log, and the queue is
  `{error, broken}` until `negotiate/2`. A block gap event cannot arise,
  since no stop is ever requested; were one read, it would say the
  transfer had not ended, so it breaks the queue like an error rather
  than count as an end. Transfer complete alone takes the extent back,
  copies it for a read, clears transfer complete, returns the queue to
  idle and answers `{ok, [{Tag, Bytes}]}`, the bytes empty for a write.
  None of them: `{ok, []}`.

Transfer complete alone is taken to mean the controller moved the whole
extent. The specification supports it as far as it goes: every stop of
ADMA2 raises transfer complete (table 1-14, p. 20), a stop at a block
gap sets the block gap event with it (section 1.13.3.3, p. 20), which
the owned stop request rules out, and with block count enable set, a
table whose lengths differ from the block count times the block size is
an ADMA error, with the length
mismatch bit set (Host Controller, section 2.2.30, table 2-41, p. 115),
and `command/2` has checked that `blksizecnt` holds the extent's count
before the transfer starts, so the two cannot disagree unless the
controller misreads them. It does not say when a mismatch is detected
or whether transfer complete comes with it; errors win over transfer
complete in `complete/2` whichever way, and the board pass confirms on
the BCM2711 that a transfer whose table and block count disagree
reports the ADMA error before the form is enabled. Were it to end short
anyway, the bytes past what it wrote would be the zeros of rule 1, not
an earlier request's.

Each of these calls writes at most one register, so the driver's spacing
of writes on this controller
([design-storage.md](design-storage.md#the-sd-host-controller)) wraps
each call as it wraps `command/2`.

**Install and reset.** `negotiate/2` is, for every form, the form's reset,
the device's report that it holds no descriptor, then the install, and a
buffer goes back to its pool only through a completion or through it, as
[The reset rule](design-runtime.md#the-device-nif) says:

| Form | Reset the NIF writes | Idle report it reads | Install |
| --- | --- | --- | --- |
| split ring | status 0 | status reads 0 | virtio's initialisation |
| register ring | each direction's DMA control with the engine (bit 0) and every ring's enable (bits 1 to 17) cleared in one write, transmit first (`if_genetreg.h:209-218`; FreeBSD's `gen_dma_disable`, `if_genet.c:593-607`; [GENET facts record](research-genet-bcm2711.md#stopping-the-dma-and-confirming-it-stopped)) | each direction's DMA status, block offset `0x1048`, reads bit 0 set, the block disabled, and bit *n* + 1 set for the ring *n* the form uses, bit 17 for FreeBSD's ring 16 ([The DMA status register](research-genet-bcm2711.md#the-dma-status-register)); the ring bit's meaning is inferred, and the board pass settles it | every descriptor's address; for the one ring the form uses, indexes zero, ring and buffer size, start, end and the four pointers, high halves 0; every receive buffer zeroed and handed; ring configuration and DMA control with the ring's enable; then each direction's engine bit, receive first ([Reinstalling the rings](research-genet-bcm2711.md#reinstalling-the-rings)) |
| ADMA2 table | the software reset for the data lines (FreeBSD's `sdhci.h:200-203`) | the reset bit reads clear | host control 2's owned fields checked clear, the DMA select written to ADMA2 with 32-bit descriptors; `adma_address` is written by each post |

Where the idle report does not yet show, `negotiate/2` returns
`{error, ebusy}` with nothing installed, having written the reset once,
and a later call reads the report again; the driver retries on a timer.
The GENET facts record gives the one published bound on confirming a
stop, 5,000 reads 1 us apart, about 5 ms
([Stopping the DMA](research-genet-bcm2711.md#stopping-the-dma-and-confirming-it-stopped));
the driver's retries are bounded by a multiple of it, after which it
reports the device failed, and the board pass measures how long a stop
takes. The
ADMA2 table's `negotiate/2` makes at most one register write per call
and answers `{error, ebusy}` until its last, so it takes two calls at
least, each spaced. A driver that resets the controller itself calls
`negotiate/2` before its next DMA transfer; until then `command/2`
refuses, since it reads back the fields the reset cleared.

**The TRB ring form (xHCI).** A fourth form, which the USB host
controllers use, is defined with its driver in
[design-usb.md](design-usb.md#the-trb-ring-form) and keeps this design's
rules: its regions each start on a granule and name their one writer,
its scratchpad array written by the CPU and its scratchpad pages by the
controller and never read by the CPU; its core describes TRBs and input
contexts, which the check judges by meaning, and the sequencer writes
those and every DCBAA entry, link and register that names a table; each
transfer ring is bound to one endpoint, and every record that points an
endpoint at a ring names the ring bound to it; each queue has
states and accepts in each only the commands its table lists; its device
and endpoint contexts are built from bounded parameters alone; a post
is made live by its first TRB's cycle word, then the doorbell; its device
contexts are buffers, handed over at the slot's first Address Device and
back when Disable Slot succeeds; its transfer rings are padded, and the
ring's position never rests on a link TRB; its completion knows a
transfer's stages and each queue's stop span; its event ring is bounded;
its address width is read from the controller's `AC64`; and its
`negotiate/2` takes one step a call, answers `{error, ebusy}` until its
last, and opens both of the controller's interrupt gates.

## The architecture layer

Generic code names cache maintenance and barriers only: `erx_dma_clean`
and `erx_dma_clean_inval`, each over an address range and a step, which
issue one instruction at each multiple of the step from the range's start;
the sequencer gives every range with the step `L`, so the choice of step
is made once, in the pure core its host tests cover; the publish barrier, the report
barrier and the completion barrier; `erx_dma_store_wait`, which follows
every register store ([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors));
and `erx_dma_granule` and `erx_dma_line`. Each architecture provides them in its layer
([design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance)); the
hosted build provides the model below. Only `erx_device` calls them in a
runtime, which the `device-dma-maintenance` chokepoint rule checks, and their inline assembly is a listed site of the `inline-asm` rule.

## Concurrency

The device lock serialises every queue call and every driver register
write, so a decision's effects run whole, with no other decision's and
no driver write between them, and every check a call makes under the
lock still holds when the write it guards is made. The ledger is part of
the queue record: the core, the check and the sequencer read it, and
the sequencer advances it, within one call under the lock, and the
effect layer applies the sequencer's output before the lock is released,
so no other call sees the next ledger before its effects have run; a
refused decision leaves it as it was and breaks the queue. Maintenance by address
reaches every cache of the CPUs that share the memory, so one CPU's
maintenance suffices whichever CPUs fetched the lines.

**Moving between CPUs.** The barrier that completes maintenance
completes the maintenance that the CPU executing it issued (Arm 102336,
section 6, p.14), so a thread moved
to another CPU between its maintenance and its barrier needs something
else to complete it. On erXos's kernel, every exit from user mode
completes every outstanding access
([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors)),
which completes the maintenance before the thread runs elsewhere. Fiasco
does not: its exception entry has no such barrier
(`fiasco/kernel/src/kern/arm/64/ivt.S`), and its switch path orders with
`DMB ISH` at most (`fiasco/kernel/src/lib/libk/arm/mem-arm.cpp`).
On Fiasco the condition that makes this safe is instead that no
thread is moved while it makes a device call, and it holds by
construction:

* Fiasco moves a thread only when user mode asks it to, through
  `l4_scheduler_run_thread` (`fiasco/kernel/src/kern/scheduler.cpp`),
  and the backend asks for a started thread only in
  `erx_thread_set_affinity` (`liberx/backend/fiasco/service.c`);
* device calls run only on normal schedulers: the NIF's functions are not
  dirty (`erx_device_nif.c`), and the register calls are BIFs;
* each normal scheduler is pinned to one CPU
  ([design-runtime.md](design-runtime.md#scheduling)), and is moved only
  by its own binding, which ERTS makes from that scheduler's own loop,
  between process runs (`erl_process.c`;
  `erl_cpu_topology.c`), through `sched_setaffinity(0, ...)`
  (`erl_misc_utils.c`), which names the calling thread
  (`musl/src/internal/erxos/syscall.c`).

The one way to break it would be a call that moves a normal scheduler
from another thread, which no code in the runtime makes. Non-coherent
DMA on Fiasco is enabled under that condition, and the board pass
that enables GENET's DMA confirms the reset reads of
[Register ownership](#register-ownership) first.

## Failure behaviour and refusals

Nothing after a decision's check can fail. The answers each call
adds:

| Call | Answer | When |
| --- | --- | --- |
| `queue_create/4` | `{error, erange}` | a device address of the queue would reach the form's width, or the queue passes the object's end |
| `region/3` | `{error, enotsup}` | the device is not coherent |
| `post/4` | `badarg` | a receive post on a standing queue; for ADMA2 not exactly one segment, or a length that is not a positive multiple of 512 or is larger than the buffer |
| `post/4` | `{error, full}` | an ADMA2 queue already armed or in flight |
| `command/2` | `badarg` | while an ADMA2 queue is armed or in flight, any word but the armed transfer's, or that word when any field it reads back differs from what the queue installed and posted; a word enabling DMA without an armed queue |
| `complete/2` | `{ok, []}` | nothing is done yet |
| `complete/2`, `post/4` | `{error, broken}` | the device reported an index or a length beyond its bound, or an ADMA2 transfer reported an error, until `negotiate/2` |
| `negotiate/2` | `{error, ebusy}` | the device's idle report does not show yet, or, for ADMA2, the install has writes left |
| `write/3`, `write_field/4` | `badarg` | a write that would change an owned field; any `write_field/4` of an owned field |
| `post/4`, `complete/2`, `negotiate/2` on the TRB ring form | `{error, halted}`, `{error, full}`, `badarg`, `{error, broken}`, `{error, erange}` | as [design-usb.md](design-usb.md#the-trb-ring-form) lists them: a queue whose state refuses the request, or that the command in flight holds; a transfer on a queue with no free buffer, a command while another is in flight, or one adding a queue when no block of its kind is free; a command or context outside its bounded parameters; an event that fails the form's checks or passes the ring's bound, until `negotiate/2`; memory above the address width `AC64` gives |
| the root at boot | gives the device no DMA memory, with a line naming it | the tree gives the device no single window that RAM backs, marks coherence on a bus above it or both ways on its node, or its DMA memory would lie outside the range |

## Verification

Each test is paired with the seeded fault that shows the code under test
ran.

* **The order.** Host tests of `erx_device_dma_order` over decisions and
  observations of each form, coherent and not, with `L` smaller than `G`:
  every zeroing before the writes, every clean before the publish
  barrier, the barrier before the first publish, every maintenance
  instruction at every line of its region, the report barrier, of the
  kind that orders loads and stores, before every taking back, and every
  taking back and its barrier before every copy; for a coherent device no
  maintenance and the same barriers; for an acquisition, the validity
  read and the report barrier before the covered records' clean and
  invalidate, their completion barrier and their reads, and no record
  read that the validity did not cover. Seeds: a publish moved before the
  clean; the report barrier dropped; the report barrier made loads-only;
  the maintenance stepped by `G`; an acquisition's records read in its
  first phase with their validity; an acquisition that reads one record
  past its validity; an acquisition without its second phase's clean
  and invalidate; each fails its assertion.
* **The non-coherent stand-in.** The hosted stand-in device keeps its DMA
  memory twice, a cache of lines of `L` bytes with dirty bits and the
  memory behind it, and a writeback evicts a whole granule of `G` bytes,
  as a CPU may. The CPU's stores go to the cache; the stand-in device
  reads and writes only the memory; the model's clean writes a dirty line
  back, its clean and invalidate also drops it; and, from a seeded random
  source, it evicts dirty granules and refetches clean lines at arbitrary
  points. The stand-in device may act after any publish, the available
  index as well as the doorbell, as virtio allows. Every form's host
  tests run over it, with `L` equal to `G` and with `L` a quarter of `G`:
  posted bytes reach the device intact, and completed bytes are the
  device's. Seeds: the clean removed, so the device reads stale bytes;
  the taking back removed, so a refetched stale line is copied; the
  buffer stride left unrounded, so an eviction of a neighbour overwrites
  what the device wrote; the maintenance stepped by `G` with `L` smaller,
  so a line inside a granule is missed; the sequencer's derivation of the
  buffers passing to the device removed, so a posted buffer is never
  cleaned; the descriptor table's clean moved after the available index,
  so the stand-in takes a stale chain; each fails a byte comparison.
* **The install.** Over the stand-in, a split-ring queue whose used ring
  holds dirty lines of a former record's values when `negotiate/2` runs,
  so the install's zeroing leaves its own dirty lines: the stand-in
  device writes a completion into the used ring after the ready bit,
  the model evicts and the completion is observed, and the entry read is
  the device's, on every eviction schedule the seeded source draws. Seed:
  the sequencer's handover of a region whose writer changes from the CPU
  to the device restricted to buffers, so the zeroed used ring is never
  cleaned and the observation's clean and invalidate, or an eviction,
  writes zeros over the device's entry, which the completion misses.
* **Zeroing.** Over the stand-in, a device that writes a prefix and
  reports the buffer's whole length: the completion's bytes past the
  prefix are zero, on a buffer that held another request's bytes. Seed:
  the zeroing removed, and the earlier request's bytes appear.
* **The check.** Host tests of `erx_device_dma_check` over each form's
  descriptions, ledgers and reports. Every plan each form's core makes in
  its own harness passes the check; seed: the transfer ring's generated
  list of meanings planted without the setup stage, and that form's
  control transfers are refused. Each rule refuses the failure it exists for, and a seed
  planted in the check, as its `SEEDED` faults are, makes it pass:

  | Plan the check refuses | Seed under which it passes |
  | --- | --- |
  | a command TRB described on a transfer ring; a transfer length one bit wider than its field | the meaning test removed; the width test removed |
  | a buffer index past the ring's block; the input context named by a transfer; an endpoint with no bound ring named by Set TR Dequeue | the range test removed |
  | a normal TRB naming another block's buffer; an endpoint context binding a ring bound to another endpoint | the binding test removed |
  | an offset and a length that pass the buffer's end; an ADMA2 extent of zero blocks | the length test removed; the extent's lower bound removed |
  | a buffer a live holding holds | the holding test removed |
  | a transfer on an endpoint a Set TR Dequeue Pointer in flight closes; a Disable Slot while an endpoint of its slot runs a live transfer, one that took a transfer after its Stop Endpoint succeeded among them; a Configure Endpoint dropping such an endpoint; a drop-and-add of an endpoint whose halting error event was consumed, before any Reset Endpoint | the reach test removed; the state left `stopped` by a transfer's publication; the drop test accepting `halted` as Disable Slot's does |
  | a run longer than the ring's free positions; a command while the input context is held; a chain while its available entry is held | the room test removed |
  | `out` bytes into a buffer no record names, or past the range it names | the fills test removed |
  | two fills sharing a byte of one buffer | the overlap test removed |
  | a region entry's fill shorter than an entry; a region entry naming a region the ledger does not hold | the entry's length test removed; the region lookup taking any region |
  | a region entry naming a region of the device over the queue's own memory | the lookup's test of the queue's memory removed |
  | a control step setting `USBCMD`'s run bit or `QueueReady` | the controls test removed |
  | a completion for transfer A whose copies read B's buffer; a used element consumed a second time; an event consumed past the consumer cycle state | the releases taken from the core's copies; the consumer position test removed |
  | a copy in a publication; a report of a region the CPU writes; a `report` step reading a used or event ring record in place of an acquisition | the calls test removed; the report target test removed; ring memory allowed as a report target |
  | an install whose layout has a region off a granule or past the memory | the layout's granule test removed, with a form planted to lay out an unaligned region |

* **Publication.** Host tests of `erx_device_dma_order` over each form's
  publications: every record, fill and zero written before the cleans,
  the cleans before the publish barrier, the activation after it and the
  doorbell after another; a run's first record written with its
  activation field not yet live and a TRB run's later records, and a
  link it reaches, behind it; the position moved past the link with the
  cycle state toggled; `QueueSel` written before every banked register
  of an install; every count the install writes equal to its table's
  declared count; every address the encoder writes the start of its
  named record, or its buffer's address plus the offset. Seeds: the
  activation written among the records; the first TRB written with its
  cycle bit live; the link left out of a run that reaches it, so the next
  run's first TRB lands on the link; `QueueSel` written after `QueueNum`;
  `QueueNum` taken from the descriptor table's region rather than its
  count; each fails its assertion.
* **The device acts only on what it holds.** Every stand-in and
  controller model, the split ring's, GENET's, ADMA2's and the TRB
  form's, reads the rings and registers after every store of a decision
  and after every eviction the seeded source draws, as its device may,
  and checks every access against the ledger: a record it acts on is
  live, an address it follows is the start of a record of its table or
  inside a buffer a live holding holds, and the endpoint a transfer runs
  on is bound to its ring; the TRB form's model also keeps each
  endpoint's controller state and fails on a command the specification
  leaves undefined in it. Each seed fails that check:
  * the first TRB's cycle word written with the records, and the model
    takes the first TRB while its pointer still names its previous lap's
    buffer, which the CPU holds;
  * a TRB ring initialised with cycle state 0, and the model acts on a
    zeroed TRB;
  * a chain's last descriptor written with `NEXT` set, and the stand-in
    follows `next` into a free descriptor;
  * the install's `QueueSel` left out with another queue selected, and
    the stand-in's bank for the queue keeps base 0, so its first fetch is
    at address 0;
  * `CRCR` written at the command ring's pad, and the model reads a
    record no holding holds;
  * Set TR Dequeue's pointer derived from another endpoint's binding, and
    device A's transfer runs on device B's ring;
  * the releases taken from the core's answers instead of the reports,
    with a core that answers B for A's completion, and the next post
    zeroes B while the model still writes it;
  * the acquisition reading each event TRB whole in its first phase,
    against a model that writes an event's Dwords as separate stores,
    Dword 3 last, over the previous lap's event naming another live
    transfer: the torn snapshot releases that transfer, and the next post
    zeroes its buffer while the model writes it;
  * only the second phase's clean and invalidate removed, the validity
    still read first and every barrier kept, against the stand-in's cache
    filling the event TRB's line in the first phase torn around the
    model's stores, the previous lap's pointer naming another live
    transfer beside the current cycle word: the correct acquisition drops
    that line and reads the event the model finished, while the mutant
    reads the stale pointer, releases that transfer, and the next post
    zeroes its buffer while the model writes it;
  * a core that, after a halting error event is consumed, proposes a
    Configure Endpoint dropping and adding that endpoint, with the drop
    test accepting `halted`: the model takes a drop on a halted endpoint,
    which the specification leaves undefined;
  * the closure removed, so a command in flight closes no endpoint, and a
    core that posts B on the endpoint while its Set TR Dequeue Pointer is
    in flight: the completion retires every live holding on the ring, B
    among them, and returns B's buffer while the model runs B;
  * the ADMA2 split rounding the entry count up once too often, so an
    extent of a multiple of 64 blocks ends in an entry of length 0, and
    the model, reading it as 65,536 bytes, moves past the buffer.
* **The formats' marks.** The generator's tests: a format naming an
  unknown target, a `selects` value outside its enum, a length naming a
  field of another layout and an `activates` mark two bits wide are each
  refused with a line naming the mark. So are a table's writer and its
  offers broken one at a time: a `releases` mark on a meaning of a `cpu`
  structure, a `refers` mark on a meaning of a `device` one, a
  `releases` mark naming a `device` structure, a `meaning` line naming
  two structures, two meanings of one structure of different sizes, two
  that select one member, two with their activation at different
  offsets, one of two meanings with no selector, and a layout with no
  `meaning` line selecting a member a meaning of the same file selects. A
  generated header holds no encoder and no input struct for a report:
  the regression case is the xHCI port status change event, which
  carries no `releases` mark, and whose header has its accessors and no
  `erx_xhci_trb_port_event_encode` or `erx_xhci_trb_port_event_free_t`;
  a host source that calls `erx_xhci_trb_port_event_encode` is kept as a
  test that expects the build to fail. Seeds: the
  target test removed, and the unknown target builds; the writer test
  removed, and the transfer ring's layout with a `releases` mark builds;
  the selector test removed, and two meanings selecting one member build.
* **Ownership and the lock.** Over the stand-in, `write/3` of a GENET
  descriptor address, of `control0` with another DMA select, of `control0`
  setting the stop at block gap request or the continue request, and, while
  an ADMA2 transfer is in flight, of `interrupt` clearing transfer complete
  or an error, of `irpt_mask` clearing a required enable, or of
  `blksizecnt`, is `badarg`, the stop and continue requests in every state;
  the owned fields' neighbours (another bus width, the tuning error's
  enable in flight, and the in-flight writes once the transfer completes)
  are `ok`. A host test runs a driver thread writing
  the reset of all to a stand-in SDHCI, which returns every register to
  zero, against `command/2` on another thread: `command/2` either issues
  with every field as installed or refuses, and the stand-in never sees a
  DMA command with the DMA select or the ADMA address cleared. Seeds: the
  DMA select's mark set to not owned in the SVD source, and the field check
  removed, each lets the DMA select write succeed; the lock removed from
  `write/3`, or the read-back of the DMA select removed from `command/2`,
  and the stand-in records a DMA transfer through address 0.
* **The ADMA2 table's states.** Idle, armed and in flight form a protocol
  state machine, tested exhaustively: every call in every state, with
  transfer complete, the block gap event and an error status each set
  and clear, against the answers above. Over the stand-in, whose device
  writes the buffer some steps after the command and advances
  `adma_address` by 8 at every entry it fetches, `complete/2` straight
  after `command/2` is `{ok, []}` and the buffer is not reused; a transfer
  that reports an error with transfer complete, or the block gap event with
  it, breaks the queue and returns no bytes; a `blksizecnt`
  that differs from the extent makes `command/2` `badarg`; and two
  transfers in a row both move their bytes, each read from the table's
  start. Seeds: the transfer complete test removed from `complete/2`, so
  the stand-in's late write lands in the next transfer's buffer, which a
  byte comparison catches; the error
  test placed after the transfer complete test, so the erroneous
  transfer's bytes are returned; the block gap event left out of the end
  statuses, so that a stand-in that stops at a block gap halfway has half a transfer
  returned as whole; the post's write of
  `adma_address` removed, so the second `command/2` is `badarg`; the
  required enables taken as bits 15 to 31, so that on a stand-in whose
  `irpt_mask` bit 15 reads 0, as the specification fixes it, every
  `command/2` is `badarg`.
* **GENET's receive flags.** Over the stand-in, a frame whose status
  carries a CRC error, and one without end of packet: the completion's
  tag carries the flag, the consumer index advances past both, and the
  driver drops the frame. Seeds: the tag forced to 0, and the driver's
  frame test passes the bad frame; the drop test narrowed to bit 2, as
  FreeBSD's, and the CRC-error frame is delivered.
* **GENET's stop.** Over the stand-in, whose DMA status sets its bits
  some reads after the stop: `negotiate/2` answers `{error, ebusy}` until
  both directions show bit 0 and the ring's bit, and installs nothing
  before. Seed: the idle test reads only the receive direction, and the
  stand-in's transmit engine is still running when the install writes
  its ring.
* **GENET's start and post.** Over the controller model,
  `erx_device_genet_model`, which the hosted stand-in runs too and which
  runs a direction only while its DMA control holds the engine's enable
  and the ring's bit and its ring configuration the ring's enable, and sends a descriptor only when it is a
  whole frame with its append-CRC bit: the start leaves both rings
  running, and every post goes out with its bytes. Seeds: the start
  written without the engine's enable, and the rings never run; a
  descriptor posted without its append-CRC bit, and the controller
  refuses to send the frame without its Ethernet CRC.
* **The forms' completions.** The fuzz target of device ring processing
  covers the register ring's and the ADMA2 table's observations and
  decisions: arbitrary index, status and interrupt values against
  arbitrary queue states, under ASan. Seed: the length bound removed, and
  the copy reads past a buffer.
* **The record.** The reader's host tests over each platform's
  build-time tree pin every DMA device's coherence and range and fail on
  a device whose facts are absent, so a board tree that marks coherence
  on a bus above a DMA device fails there, before any boot; a fixture with
  `dma-coherent` on the parent bus gives the device the status
  `coherence`. The QEMU suite's seeded tree shows a record's coherence
  following the live tree
  ([design-device-tree.md](design-device-tree.md#verification)). Seed:
  the reader takes the coherence of the nearest marked ancestor, and the
  fixture's device reads as coherent.
* **The reach.** A host test of the root's device step over a pool
  placed outside a device's range makes no object and gives the record no
  memory, with the line. Seed: the range test removed, and the object is
  made.
* **On QEMU.** QEMU's DMA is coherent, so no omitted maintenance can fail
  there; the QEMU suites check the coherent path, the zeroing and that
  the barriers changed nothing.
* **On the board.** Before GENET's DMA is enabled, the questions the
  GENET facts record leaves to the board
  ([What only the board can settle](research-genet-bcm2711.md#what-only-the-board-can-settle)):
  every owned GENET register read back unchanged across the UniMAC's
  software reset and each flush; each direction's DMA status read with
  the engine and the ring enabled and disabled, which settles whether
  bit *n* + 1 reports ring *n* disabled; how long a stop takes to
  confirm; and received lengths with CRC forward clear, which show that
  no FCS is counted. Then GENET's traffic, with every frame checked end to end,
  at one CPU and at four, for every Pi 4 board pass; ADMA2 reads and
  writes, each block checked, two transfers in a row among them, which
  shows that `adma_address` still holds the table's start between a post
  and its command, and a transfer whose table and block count
  disagree reporting an ADMA error, at the range the board's firmware
  wrote, which the root's line for EMMC2 records.

## Performance

A 2 KiB buffer is 32 lines of 64 bytes, the line the Pi 4's CPU reports,
and is zeroed where no `out` bytes fill it and cleaned at a post, and
cleaned and invalidated at a completion. Every driver register write
takes the device lock. These costs are on the watch list
([todo-performance.md](todo-performance.md)), measured on the board by
`tools/erx bench` against the same traffic with the maintenance and the
zeroing skipped.

## Alternatives considered

* **Non-cacheable mappings for DMA memory**, as FreeBSD uses for coherent
  allocations on a non-coherent tag (`busdma_bounce.c:515-523`). It needs a memory attribute the
  kernel does not have, since it fixes the attributes at boot to normal
  write-back and two device attributes
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)), and the NIF's
  copies in and out of uncached memory are slow; the handoff rules need
  neither.
* **Each core keeping its ring positions and buffer states, checked
  against a copy.** The check would hold a second copy of every form's
  positions and ownership, fed by the core it checks, and the two must
  agree. With the ledger the cores keep neither, and the one copy is the
  trusted side's.
* **Maintenance or handoffs written into each form.** Each form would have
  to remember its handoffs, cleans, invalidates and barriers; deriving
  them from the queue's change of state makes that list empty.
* **Invalidate before the device writes**, besides after, as FreeBSD
  does (`busdma_bounce.c:997-1009`). A clean suffices, since the CPU
  stores nothing into the region afterwards and the clean and invalidate
  after the transfer discards any stale line; and user mode cannot
  invalidate alone.
* **Trusting each device's reported length instead of zeroing.** virtio
  promises at least the reported length written (section 2.7.8.2), GENET's
  status counts the frame it wrote, and ADMA2 ends at the bound extent;
  but the argument would rest on every form's device keeping its promise
  in every error case, which virtio itself says a device may not know.
  Zeroing makes the property hold whatever the device reports, for a
  cost the watch list measures. It does not stop a malicious device,
  which can read the pool it holds and return anything.
* **The NIF owning the software resets.** Not needed where a check reads
  back what the reset changed before the device moves data again, as
  SDHCI's `command/2` does: every driver write is serialised with the
  NIF's sequences, and a stopped transfer only stalls its queue until
  `negotiate/2`.
* **A reset after every ADMA2 transfer** instead of owning `blksizecnt`,
  the end statuses and the required enables while a transfer is in
  flight. It costs a reset and a spaced write per command, and the
  in-flight fields already keep the driver from hiding or shortening the
  transfer's end.

## Open decisions

1. **The granule when the CPU does not report one.** Recommendation:
   2 KiB rather than the line size FreeBSD aligns to; it costs memory
   only. That 2 KiB
   is the architecture's largest writeback granule is unverified here:
   the Arm Architecture Reference Manual's description of the cache type register's `CWG`
   was not read, and the Cortex-A72 manual gives only its own value; it
   is confirmed before the fallback is built. The line has no such case:
   `DminLine` is always reported.
2. **Who writes the records the device reads.** This design has the
   core describe records and the sequencer write them
   ([Descriptions](#descriptions)). The alternative keeps raw stores of
   ring fields in a plan and has the check fold them into each record's
   end state and judge it as the device will read it. The ledger, the
   releases and the sequencer's own activation are needed either way;
   the raw stores then need, besides: every address resolved to a record
   boundary of its target, virtio's `next` and available heads checked
   as indexes into the descriptor table, `QueueSel` followed through the
   fold, stores outside declared records refused, every count the device
   reads checked against its table, the add flags read as gates whose
   values each command fixes, and the activation field of every stored
   record checked against the ledger's positions. Each of those checks a
   value the sequencer can derive, and the cores keep the placement code
   they would otherwise lose. Recommendation: descriptions, as designed.

## References

* Linux 6.18's device trees (`deps.lock`, `linux-dts`):
  `arch/arm/boot/dts/broadcom/bcm2711.dtsi` and `bcm2711-rpi.dtsi`, read
  as data.
* FreeBSD at the network stack's pin, `975e3605ebb1`:
  `sys/arm64/broadcom/genet/if_genet.c` (SHA-256 `fbf5c90d...`) and
  `if_genetreg.h` (`5af53d30...`), the source of the GENET driver's design.
* FreeBSD 15.1.0 (`release/15.1.0`): `sys/dev/sdhci/sdhci.c` (`4551b7d7...`)
  and `sdhci.h` (`363ed505...`); `sys/arm64/arm64/busdma_bounce.c`
  (`4707aa4e...`), `cpufunc_asm.S` (`b6de008e...`) and `identcpu.c`
  (`ed62337a...`); `sys/arm64/include/atomic.h` (`e65760cd...`).
* The clean-room facts records of the BCM2711's SD controller,
  [research-sdhci-bcm2711.md](research-sdhci-bcm2711.md), and of its
  Ethernet controller, [research-genet-bcm2711.md](research-genet-bcm2711.md).
* SD Association, SD Host Controller Simplified Specification, version
  4.20: sections 1.13.1.3, 1.13.2, 1.13.3.1 to 1.13.3.3, 2.2.11,
  2.2.13, 2.2.18 to 2.2.21, 2.2.25, 2.2.30 and 2.2.31, for ADMA2 and the
  registers the NIF owns (SHA-256 of the PDF read,
  `e430d1d149696580274f876d1cc0624bc9b9dffc4e5a62cd76f1f658f3e6667d`).
* QEMU 11.1.3's `virt` tree, written by `-machine virt,dumpdtb=`.
* Devicetree Specification, release v0.4, sections 2.3.5 and 2.3.8 to
  2.3.11.
* OASIS Virtio 1.2, Committee Specification 01: sections 2.7.8, 2.7.8.2,
  2.7.13.3 and 4.2.2 (the queue registers `QueueSel` selects).
* Intel, xHCI Requirements Specification, revision 1.2, as
  [design-usb.md](design-usb.md#references) records it: sections 4.6.5,
  4.9.2, 5.5.2.3.1, 6.1 and 6.2.5.1, for the publication, the gates and
  the counts the sequencer writes.
* Arm, *Learn the architecture: Memory Systems, Ordering, and Barriers*,
  102336 version 1.0, sections 5 and 6; Arm Cortex-A72 MPCore Processor
  Technical Reference Manual, r0p3, 100095_0003_06, section 4.3.26.
* The Arm Architecture Reference Manual: the cache type register, cache
  maintenance by address, the barriers, and the ordering of cache
  maintenance by address against loads and stores.
