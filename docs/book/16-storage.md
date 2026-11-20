# Chapter 16. Storage and Updates

> **Status.** **Built:** a storage domain serves `/data` from littlefs
> over the virtio block driver on QEMU and the SD card driver on the
> Raspberry Pi 4; killing the block driver in the middle of a transfer
> ends the domain, its restart mounts `/data` again, and every file
> synced before the kill is there. The medium's layout of two slots,
> the vault's partition and the data partition, the boot-selection
> record the packer writes, and the QEMU harness that reads it and boots
> the slot it names are built. The build writes each slot's system
> partition as an EROFS image with a dm-verity hash tree, and the EROFS
> reader in every runtime reads only blocks that pass the tree. The
> pure FAT reader that finds root's login keys on the card is built.
> The F2FS codec and mount core are built and tested on the host.
> **Designed:** the `system` tree serving packages from the system
> partition, the slot writer, updates with a trial boot and a commit,
> the reset count, per-user trees of `/data`, the vault's storage
> domain, the FAT server for removable media, and erXos's F2FS as a
> mounted file system with its power-cut harness.

**Background needed.** [Chapter 1](01-operating-systems.md) (block
devices, file systems, journals), [chapter 10](10-domains.md)
(domains and how one ends), [chapter 11](11-security.md) (facets and
file grants), and the outlines of chapters
[14](README.md#chapter-14-files-namespaces-and-service-trees) and
[15](README.md#chapter-15-devices-and-drivers) (file servers and
drivers).

A Raspberry Pi in a kiosk loses power whenever someone trips over the
cable or the building's power fails. A cut may land in the middle of
an update copying a new system onto the card. The machine must come
back every time, with every file it promised to keep and a system
that boots, from an SD card that promises little about power cuts and
whose every byte may have been changed by someone holding it.

FreeBSD meets these needs with familiar tools. UFS with soft updates, or
ZFS, keeps a file system consistent across a crash. `freebsd-update`
replaces system files in place, and ZFS boot environments let an
administrator keep the old system as a snapshot to boot if the new one
fails. `nextboot` boots a different kernel once and falls back on the
next reboot. <!-- check: FreeBSD nextboot(8) one-shot semantics; boot
environments via bectl(8) --> All of this runs in the kernel, so a bug
in a file system's parser is a kernel bug, and a crafted disk image is
an attack on the kernel.

erXos runs storage as services in Erlang domains of their own. The
system itself is a read-only image whose every block is checked
against a hash before anything parses it; the files that change live
on a separate data partition, behind a file system in its own domain;
and an update writes a complete second copy of the system and boots
it once on trial, so the copy that runs is never written. A bug in a
file system ends a domain, never the machine.

Sections 16.1 to 16.6 cover storage as a service, the read-only
system, littlefs under `/data`, the F2FS design, removable media and
the SD controller, and updates through two slots; failures and design
choices follow.

> **Background: partitions and the SD card.** A disk is one long row
> of numbered blocks (chapter 1, section 1.6.1). A **partition** is a
> range of those blocks set aside for one use, listed in a partition
> table at the start of the disk. The oldest table, the master boot
> record, has four entries; one of them may point to an extended
> partition holding more. An SD card is flash memory behind a small
> controller. Flash cannot overwrite a page in place: it erases a
> large region, the **erase unit** (often 1 MiB or more on a card),
> and then writes pages into it. Each region survives a limited number
> of erases. The card's controller hides this by keeping a table from
> the block numbers the computer uses to the pages that hold them, its
> flash translation layer. That table is the card's secret, and a
> power cut while the controller updates it can damage blocks the
> computer never wrote.
> <!-- check: typical SD erase unit sizes; FTL corruption on power loss is a known risk, not a guarantee -->

## 16.1 Storage as a service

A bug in the code that reads a disk ends one domain in erXos, which
restarts while the rest of the machine runs on. Every part of storage,
from the driver to the file system, runs in an Erlang domain, behind
facets like any other service ([design-storage.md,
Overview](../design-storage.md#overview)).

### 16.1.1 The medium and its partitions

The medium has the same layout on every machine, and one file,
`abi/medium.txt`, says where every partition lies. The packer, the QEMU
harness and the driver all take their numbers from it (chapter 7).
Figure 16.1 shows the layout.

```mermaid
flowchart LR
    rec[record partition<br/>FAT16, ERXOS] --> bootA[boot A<br/>FAT32]
    bootA --> bootB[boot B<br/>FAT32]
    bootB --> sysA[system A<br/>EROFS + hash tree]
    sysA --> sysB[system B<br/>EROFS + hash tree]
    sysB --> vault[vault's partition]
    vault --> data[data partition<br/>littlefs]
```

*Figure 16.1. The medium's partitions, in order. A slot is a boot
partition and a system partition; the record names which slot boots.
Only the data partition grows to fill the card.*

A **slot** is a pair of partitions: a boot partition, the FAT32 volume
the firmware reads, holding the kernel and the boot image, and a system
partition, holding the system's read-only files. There are two slots, A
and B. The **record partition**, first on the medium, is a small FAT16
volume labelled `ERXOS` that holds the boot-selection record (section
16.6) and the files a user adds before the first boot, such as root's
`authorized_keys`. The vault's partition holds the sealed key files of
the vault (chapter 11, section
[11.11.2](11-security.md#11112-the-vault)), and the data partition, the
last, holds `/data`. Every boundary falls on a 1 MiB line, the erase
unit the layout assumes. The layout is built: `make pack
PLATFORM=raspi4b` writes it to a card image and the QEMU disk image has
it too.

### 16.1.2 Partition windows

A file system in erXos never holds the disk. It holds a **partition
window**: an Erlang process of the block driver that serves one
partition's sectors, numbered from zero, and nothing beyond them.
(Chapter 8's "window", the root service's view of RAM, is a different
thing.) The window checks every request against its range, refuses a
write if it is read-only, and passes what is left to the driver. A file
system that asks for a sector past its partition's end gets `erange`.

Who holds which window is a fact of the system manifest, not of code.
The development manifest, `config/manifest/qemu-virt-development.txt`,
declares each one:

```text
window data
  holder @domain.storage
  device "/virtio_mmio@a003e00"
  role data
  partition 0
  rights read,write
  image none
```

The storage domain also holds the record partition read-only, for
root's login keys. The block driver starts the windows from these
rows at boot; they are built.

The block driver, `erlang/apps/erx_blk`, is a few processes in the
storage domain: a device process that talks to the
controller through the device NIF (chapter 15), a partition process
that reads the partition table, and the windows it starts. One module,
`erx_blk_write`, is the only one that builds a write request for the
device; a build check refuses any other module that posts one to the
device (`tools/lib/erx/chokepoint_rules/device.rb`). Section 16.6
explains why that one path matters.

### 16.1.3 What a failure ends

The storage domain's supervisors restart nothing. `erx_blk_sup` and
`erx_storage_sup` give every child the permanent restart type and a
restart intensity of zero (chapter 3, section
[3.3.4](03-erlang.md#334-supervisors)), so the end of any child ends
the supervisor, the application, and with it the whole storage domain.
The domain service then restarts the domain, at most five times in
600 seconds, as the manifest's row for it says.

Erlang's habit is to restart only the process that failed. The reason
for ending more is the disk's write cache. A restarted
driver resets the controller, and nothing promises that a reset keeps
what the device's cache held. A file system that carried on over the
new driver could believe a write was safe that the reset threw away.
So each window binds itself to the first device process it reaches and
answers `eio` to everything once that process is gone, even if a new
one runs. The file system breaks at its next request, the domain ends,
and the restarted domain mounts the volume afresh from what the medium
holds.

The `driver_domains` QEMU suite runs that event
(`tools/lib/erx/qemu_suites/driver_domains.rb`):

1. The guest writes files to `/data`, syncing some, and keeps a
   transfer running.
2. The suite kills the block driver in the storage domain while the
   transfer runs.
3. littlefs's next block request gets `eio` from the window; the
   volume is broken, and littlefs, its supervisors and the storage
   domain end.
4. Meanwhile `/data` answers `eio` in root's session, and a file
   opened before the restart must be opened again.
5. The domain service restarts the domain. The driver resets the
   device, and the domain reports ready only once littlefs has mounted
   the volume.
6. The suite reads `/data` again: every synced file is present, each
   kept file cut at a sync.

This is built. Root's session does not fail; it sees a pause in
`/data`.

## 16.2 Read-only system images

The files of the running system are never written by the system that
runs them. Each slot's system partition is a read-only file system
image, built once on the developer's machine, followed by a hash tree
that lets any reader prove each block is the one the build wrote.

> **Background: hash trees.** A cryptographic hash such as SHA-256
> turns any block of bytes into 32 bytes, and no one can find a
> second block with the same hash. To check a whole disk image block
> by block, hash every block, then hash the list of hashes in blocks,
> and so on until one hash is left, the **root hash**. This is a
> Merkle tree. To check one block, a reader needs the block, the tree
> blocks on its path up, and the root hash; if the root hash is
> trusted, so is the block. Linux's dm-verity uses such a tree to
> check a read-only partition as it is read, and Android uses it for
> its system partition.
> <!-- check: dm-verity origin in Linux and use on Android -->

### 16.2.1 EROFS and its tree

The system partition holds an EROFS image. EROFS, the Enhanced Read-Only
File System, was written for Linux to hold phone system images: it has
no free-space map, no journal and nothing that changes, so a reader has
little to get wrong. <!-- check: EROFS origin (Huawei, Linux 4.19
staging, 2018) --> The tree after it is dm-verity's format, version 1,
with SHA-256 and 4 KiB blocks, so each tree block holds 128 hashes
(`otp/erts/preloaded/src/erx_verity_tree.erl`). The image's manifest,
inside the slot's boot image, records the root hash, the tree's offset
and its salt. The firmware loads the boot image from the boot partition,
so the root hash does not pass through the partition it checks.

The packer builds both, with fsimg, a tool outside the tree, and
records the tree in the manifest's `system_image` row. This is built.

### 16.2.2 Every block checked before it is parsed

The EROFS reader, `erx_erofs`, is Erlang, preloaded in every runtime
beside `prim_file`, so every domain can read an EROFS image without
loading anything first. It never reads the medium itself. Every block
comes through `erx_verity`, the hash-checking reader, and `erx_verity`
hands back a block only once it matches the tree ([design-storage.md,
Reading EROFS images](../design-storage.md#reading-erofs-images)).
Figure 16.3 traces one read.

```mermaid
sequenceDiagram
    participant R as EROFS reader
    participant V as erx_verity
    participant W as partition window
    R->>V: read(Image, Block, Count)
    V->>W: read data and tree blocks
    W-->>V: bytes
    V->>V: SHA-256 each block, up to the root hash
    alt every hash matches
        V-->>R: the blocks
    else any hash differs
        V-->>R: {error, eio}
    end
```

*Figure 16.3. An EROFS read checked against the hash tree. The reader
sees bytes only after they have matched; a changed block never reaches
its parser.*

The check runs in the calling process, in Erlang, with the runtime's
SHA-256 built-in, and caches verified tree blocks. The reader decodes
every structure by binary matching with checked bounds, for the images
that did not pass a tree: those its fuzz target,
`test/erlang/erx_erofs_fuzz.erl`, feeds it.

Flip one byte of a directory block in the system partition. Its hash
no longer matches the tree, so the read answers `eio`; the reader
fails that one operation and logs the image and block, and the process
that asked carries on. A host test does this to a fixture
partition (`test/erlang/erx_storage_system_tests.erl`), and a second
changes files and rebuilds the tree to match: every read still answers
`eio`, because the root hash comes from the boot image.

### 16.2.3 The `system` tree, and every reader checks for itself

In the design, the storage domain serves the booted slot's system
partition as the **`system` tree**, read-only, through
`erx_storage_system`, and its `apps/` directory holds the packages that
come with the system image ([design-storage.md, The `system`
tree](../design-storage.md#the-system-tree)). A **package** is an app's
one `.app` file: a signed header, an EROFS image of the app's files and
that image's own hash tree (chapter
[23](README.md#chapter-23-apps-and-packages)). A domain that runs an app
reads the package through the tree and checks every block against the
package's own tree, a second time, in its own memory. So a storage
domain can refuse to hand over a file, but it cannot change what a
reader accepts.

`erx_storage_system` is built and tested on the host, and the
`medium_boot` QEMU suite reads a system release file from the partition
through the hash-checking reader on a guest. The `system` tree as a
service is designed and not built: the partition holds no `apps/`,
so a booted system serves an empty tree to no one, and packages
travel in the boot image.

Nothing at boot needs the tree: every domain's code lies in the boot
image (chapter 10, section
[10.8.2](10-domains.md#1082-creating-a-domain)), so a broken system
partition costs packages, never the boot.

## 16.3 littlefs in the storage domain

`/data` is served by littlefs, a small file system from the embedded
world. Its README states its goals: it "is designed to handle random
power failures", gives "strong copy-on-write guarantees", and keeps RAM
use "strictly bounded" as the file system grows (littlefs README,
v2.11.3). It also spreads writes so no region wears out first. erXos
imports littlefs v2.11.3 into `littlefs/`, and the storage domain runs
it as a NIF (chapter 3), C code inside the domain's runtime
([design-stopgap.md, littlefs in the storage
domain](../design-stopgap.md#littlefs-in-the-storage-domain)).

> **Background: how a file system survives a cut.** A file system
> changes several blocks for one operation: the file's data, its size,
> the directory that names it, the map of free space. A cut between
> those writes leaves them disagreeing. Three answers exist. A
> **journal** writes a note of the whole change first and replays it
> after a crash (chapter 1, section 1.6.4). **Copy-on-write** never
> overwrites a live block: it writes new copies and then switches one
> pointer, so a cut leaves the old version or the new. A
> **log-structured** file system writes everything as an append-only
> log and cleans old segments later, which suits flash, where writing
> in place is expensive anyway. littlefs is copy-on-write with small
> logs for metadata; F2FS is log-structured.

### 16.3.1 The owner, the worker and one block request

A NIF that waits for the disk cannot run on a normal scheduler, so
littlefs runs on a dirty I/O scheduler, one of ERTS's threads for long
C calls. But littlefs's block reads and writes must reach the window,
an Erlang process, and a process stuck in a dirty NIF cannot receive
messages. Two processes share the work, in `erx_lfs`:

* the **owner** takes every client request, one at a time, and never
  blocks;
* the **worker** alone calls littlefs, one operation at a time.

When littlefs needs a block, its C callback posts `{erx_lfs_block, Op,
Sector, Count, Req}` to the owner and waits. The owner sends the request
to the window and, on the answer, calls `erx_littlefs:complete/2`, a
short normal NIF that wakes the callback. An operation waits only for
the owner, which waits for nothing, so no cycle of waits can form.

### 16.3.2 What reaches it, and what its failure ends

Two kinds of untrusted input reach littlefs. The partition's bytes
reach it through littlefs's own bounds checks and checksums, and a
fuzz target, `tools/fuzz/lfs_image_fuzz.c`, feeds it crafted images
under the NIF's own configuration. A client's paths, sizes and offsets
reach it through the NIF's argument decoding, which bounds each before
littlefs sees it. A mount that fails never formats the partition.

Any block failure breaks the volume and, as section 16.1.3 traced,
ends the storage domain; a littlefs assertion aborts the runtime with
the same result. A partition that fails at every mount leaves the
domain down once its five restarts are spent. Durability is plain: a
file synced before a cut is there after it, and a write not yet synced
may be lost.

Running C as a NIF has a cost. A memory error in littlefs that
crashes the runtime ends the domain, but one a crafted partition could
steer reaches everything the runtime holds: every file of the volume
and the block driver itself. This is a limitation of the
system. The design places littlefs in a sub-space port of the
storage domain (chapter 13, section
[13.1](13-native-programs.md#131-a-program-is-a-port)), holding only
its channel and a data area, so that a fault ends only the port. That
placement is designed and not built.

### 16.3.3 Who reaches `/data`

The volume is the files service `data`, and its `packages/` directory is
a second service, `packages`, where installed apps lie (chapter
[23](README.md#chapter-23-apps-and-packages)). For each grantee the
storage domain starts a grant of the tree, a process that admits only
that domain's requests (chapter 11, section
[11.6](11-security.md#116-facets-authority-over-services)). A `packages`
grant reaches nothing outside `packages/`. The system domain and root's
session each hold a `data` grant over all of `/data`, read and write.
Both services are built. Per-user trees, `/root` for root and
`/home/NAME` for every other user through a `home` service, are designed
and not built.

## 16.4 erXos's F2FS

The design gives the data and vault partitions F2FS, the Flash-Friendly
File System Samsung wrote for Linux (Lee and others, 2015), implemented
afresh in Erlang ([design-f2fs.md](../design-f2fs.md)). It writes
Linux's on-disk format, so Linux can mount and check what erXos writes,
and erXos can mount what Linux writes. No Linux code enters the tree:
the implementation works from a record of the format written in other
words by separate writers, a clean room. erXos's F2FS as a mounted file
system is designed and not built. Two pure parts are built and tested on
the host: the codec in `erlang/apps/erx_f2fs/src/erx_f2fs_codec.erl`,
which reads a volume's on-disk structures, and the mount core, which
picks the superblock copy and checkpoint and decides the mount mode. The
codec has a fuzz target, `test/erlang/erx_f2fs_fuzz.erl`.

### 16.4.1 The durable view is never overwritten

F2FS commits its state in **checkpoints**: a checkpoint names the
tables that say which blocks are in use. Between two checkpoints, an
`fsync` of one file appends a **roll-forward record** to a chain that
the next mount replays. What a mount rebuilds after a cut, the last
checkpoint and its chain, the design calls the **durable view**, and
its one rule is that no write ever lands on a block the durable view
references
([design-f2fs.md, The construction](../design-f2fs.md#the-construction)).

The allocator holds this rule by itself. A block that stops being used
stays "touched" until the next checkpoint commits, and the allocator
hands out only blocks that are neither in use nor touched. Four
orderings complete it, among them that an address enters the state only
after its block's write is answered, and that a commit block follows a
flush covering every write before it. With these, stale chains, torn
records and blocks freed too early cannot arise from erXos's writes, and
need no code of their own.

### 16.4.2 One process owns a volume

The volume's whole state is one Erlang value, held by one process.
Every request is one step of a pure function:

```text
step(State, Request) -> {State1, Reply, Plan}
```

A plan is a list of phases, each a set of block writes followed by a
flush, or a set of reads ([design-f2fs.md, One process owns a
volume](../design-f2fs.md#one-process-owns-a-volume)). The volume
process carries the plan out against the window. A step that needs a
block it does not hold answers `{need, Addresses}`; the process reads
them and runs the step again from the start. So the core never waits,
and a host test can call any step with exactly the blocks it needs:
chapter 6's pattern of a pure decision that returns a plan.

### 16.4.3 Crash states as the oracle

The F2FS design lists every state a power cut can leave, row by row, and
says what erXos's mount and Linux's mount of the same image must show
for each ([design-f2fs.md, The crash states as the
oracle](../design-f2fs.md#the-crash-states-as-the-oracle)). A cut during
a checkpoint's last block, for example, must leave either the old
checkpoint with its chain or the new one, whole, and never a mixture.
The table says what correct means before any code is written.

The **power-cut harness** makes those states. It runs the core over a
test window that records every write, and after each step of a workload
makes every state a cut could leave: each write since the last answered
flush kept, lost or torn at a sector boundary, every combination up to
ten writes and samples beyond. Each state is mounted and checked: every
file holds bytes some write put there, or zeros, and a second mount
gives the same tree. Each property has a seeded fault the harness must
catch, such as a record's first flush dropped ([design-f2fs.md, The
power-cut harness](../design-f2fs.md#the-power-cut-harness)). The
harness is designed and not built.

## 16.5 Removable media and the SD controller

### 16.5.1 FAT

FAT is the file system every camera and every other computer can
read, which is why the record partition is FAT16: a user writes
`authorized_keys` to the `ERXOS` volume from a laptop before the first
boot. The storage domain reads it with `erx_fat_read`, a pure core
that finds one file in the root directory by its long name
(`erlang/apps/erx_storage/src/erx_fat_read.erl`). It admits the boot
sector only if it lays the volume out as `abi/medium.txt` says, reads
exactly the clusters the file's size needs, and refuses a chain that
loops or leaves the data area, so whatever the card holds, the read is
bounded. It holds no device: it reads sectors through a function it is
handed. This reader and its fuzz target are built.

The design adds the **FAT server**, `erx_fat`, which serves a whole FAT
partition as files, in a storage domain of its own that holds only that
partition's window ([design-storage.md, Removable media:
FAT](../design-storage.md#removable-media-fat)). It reads FAT12, FAT16
and FAT32 with long names, matches names without regard to case as
Windows does, and reports files as mode `0644`, since FAT has no owners.
The FAT server is designed and not built.

### 16.5.2 The SD host controller

On the Raspberry Pi 4, the card sits behind an SD host controller with
the standard register set, and `erx_blk_sd` drives it in Erlang
([design-storage.md, The SD host
controller](../design-storage.md#the-sd-host-controller)). It moves data
by programmed I/O through the controller's data port, at default speed
and 3.3 V. `erx_blk_write` builds every read, write and status command,
and one table lists the identification commands, so one table and one
module decide what reaches the card. The driver and its fuzz target,
`test/erlang/erx_blk_sd_fuzz.erl`, are built; on a 4 GB board `/data`
survives a power cycle. Moving data by DMA through the controller's
descriptor tables is designed and not built.

## 16.6 Updates through two slots

An update that overwrites the running system can be cut halfway and
leave nothing that boots, so erXos never writes the slot it runs
from. It writes the other slot, the **spare**, boots it once as a **trial**,
and makes it the committed slot only if the trial is healthy. The
record that chooses the slot is built; the rest of the update path is
designed and not built.

### 16.6.1 The boot-selection record

The whole state of an update is one 512-byte sector: the
**boot-selection record**, the file `autoboot.txt` of the record
partition. The Raspberry Pi's firmware reads it to choose a slot, and
every platform uses the same bytes. While slot A is committed it reads:

```text
[all]
tryboot_a_b=1
boot_partition=2
[tryboot]
boot_partition=3
```

Partition 2 is boot A and partition 3 boot B. When the system asks for a
trial, it sets the firmware's one-shot `tryboot` flag and resets; the
firmware boots partition 3 under the `[tryboot]` section, and clears the
flag, so the boot after that returns to partition 2 unless something
rewrote the record. Raspberry Pi's documentation of `config.txt` says
the flag is "automatically cleared" after use. While B is committed the
two numbers swap.

The record has exactly two encodings of the same length, so a commit
rewrites one sector and never the file's directory entry
([design-platforms.md, Slots and the boot-selection
record](../design-platforms.md#slots-and-the-boot-selection-record)). A
sector that is neither allows no write; the record sits alone in its
erase unit. The packer writes it, committing slot A, and the QEMU
harness plays the firmware: it reads the record, parses the slot it
names, and boots it (`tools/lib/erx/boot_record.rb`, with a fuzz
target). These are built.

Figure 16.2 shows the states the record and the boot together allow.

```mermaid
stateDiagram-v2
    [*] --> normalC
    normalC: normal(C), spare written
    trialS: trial(S), one boot
    committed: normal(S)
    normalC --> trialS: spare checks whole, trial requested
    trialS --> committed: healthy, record rewritten to S
    trialS --> normalC: fault, hang, cut or not healthy
    committed --> [*]
```

*Figure 16.2. The boot-selection record as a state machine. Every
failure from the trial state leads back to the committed slot, because
only a healthy trial rewrites the record.*

### 16.6.2 The slot writer decides from facts it reads

In the design, one small domain, the **slot writer**, holds the only
writable windows on the slots and the record
([design-storage.md, System updates](../design-storage.md#system-updates)).
Before every write it reads two facts for itself: the record, from the
medium, and the **boot value**, which slot the firmware booted and
whether as a trial. One pure function over the two decides what it
allows:

| Boot value and record | The slot writer allows | The update service |
| --- | --- | --- |
| `normal(C)`, record names C | writes to the spare's two partitions | writes the system image, the boot image, then the spare's manifest last; checks the spare whole; asks for a trial |
| `trial(S)`, record names C | one commit, rewriting the record to name S | once the trial is healthy, asks for the commit, then a reset |
| anything else | nothing | nothing |

No row lets a normal boot rewrite the record or any boot write its
own slot. A firmware that falls back to the spare and boots it
normally while the record names C matches no row, and nothing is
written.

Nothing records an update's progress. Whether the spare is complete is
checked, at each boot and after each write, against the update
manifest the update writes last. A spare cut short in either partition
has no manifest that matches it, so it is never tried, and the next
install writes it again. The facts on the medium are the only state.

The slot writer, the update service and the commit are designed and not
built. The boot value is built: it reaches the storage domain's runtime
as the boot record `-erx_record boot VALUE SLOT`, and the block driver
uses it to start a window on the booted slot's system partition alone.

### 16.6.3 A trial writes nothing but the record

A failed trial must leave nothing to undo. So, in the design, on a trial
boot the block driver's one write path, `erx_blk_write`, refuses every
write except to the record and the reset count, and every file system
mounts read-only. With one write path, kept by a build check, the rule
holds whatever the storage services and the system domain do. The trial
rule is designed and not built: `erx_blk_write` does not apply it.

### 16.6.4 Hangs, faults and the reset count

A trial must end in a boot of the committed slot whatever goes wrong.
On Fiasco every end of the machine nobody ordered, a fault of the
system domain, a missed watchdog pet or a failed boot, is a reset
([design-fiasco.md, The end path](../design-fiasco.md#the-end-path)).
After a trial the firmware's flag is spent, so that reset boots the
committed slot. The root service's watchdog thread resets the machine
when the system domain's runtime stops petting it, and on the
Raspberry Pi 4 it also arms the hardware watchdog with a 4 s timeout,
so a hang of Fiasco or of the root service resets the board
([design-fiasco.md, The watchdog](../design-fiasco.md#the-watchdog)).
Both watchdogs are built. A hang in the firmware's own stage, before
that thread starts, is not covered and needs a power cycle. Making the
trial request itself is designed and not built: `erx_machine_end`
refuses `ERX_END_TRIAL`, so no trial is ever asked for.

The design adds a **reset count** in a sector of its own beside the
record: the number of boots in a row that ended unordered. It rises
early in every boot and is cleared at an ordered end or a successful
login. A count past three makes the system boot its rescue
configuration, the console and a login with no network and no user
domain. The reset count is designed and not built.

## 16.7 What fails, and what it reaches

| Failure | What ends | What the user sees |
| --- | --- | --- |
| A bug or assertion in littlefs | the storage domain, then restarted | `/data` answers `eio` for a moment; open files must be reopened |
| A block driver crash | the storage domain, then restarted | the same; files synced before it are kept |
| A crafted data partition | the storage domain, at every restart | `/data` stays unavailable; the partition is never formatted |
| A changed block of a system partition | the one read | `eio` on that file; the machine boots, since nothing at boot reads the partition |
| A trial that faults or hangs (designed) | the trial boot | the committed system boots again |

None of this covers the card itself. Every rule here assumes a medium
that writes a sector whole and honours a flush, and an SD card
promises neither.

## 16.8 Design choices

**Erlang for file systems and the driver.** A file system in Erlang
cannot write outside its own heap, and its crash is a process exit that
a supervisor sees. The per-byte work, SHA-256 and checksums, stays in C
built-ins. The cost is speed. littlefs, in C, is the exception, and its
memory errors are the limitation section 16.3.2 states.

**Restart the domain, not the driver.** Restarting the driver alone
would let a file system trust writes a device reset discarded. Ending
the domain cannot misreport durability, and the domain service
already does it.

**Checks where the data is used.** Trusting the storage domain to
check hashes for everyone would save a second hash of each package
block; checking in every reader makes a storage domain that can
withhold a file but never forge one.

**Two slots, not an update in place.** `freebsd-update` replaces files
in a running system; a cut halfway leaves a mixture. Two slots double
the space the system takes on the card, in return for a running slot
that is never written and a fallback that needs no repair.

**No recorded progress.** A note saying "spare complete" would
have to be right after every cut. Checking the spare against a
manifest written last makes the note unnecessary.

## Summary

Storage in erXos is Erlang services in their own domains. A file
system reaches the medium only through partition windows the system
manifest assigns. When the driver or littlefs fails, the storage domain
ends and restarts, and every file synced before the failure is kept. The
system's files sit on a read-only EROFS image whose every block is
checked against a hash tree before it is parsed, with the root hash
taken from the boot image. littlefs holds `/data` as a NIF in the
storage domain, and its memory errors reach that domain's runtime.
F2FS in Erlang, with a pure core and crash states as its oracle, is
the designed file system for `/data`; its codec and mount core are
built. Updates write the spare slot, try it once and commit only from
a healthy trial, with the boot-selection record as the only state; the
record's layout is built, and the trial and commit are designed.

## Where to read next

* [design-storage.md](../design-storage.md): the medium, the block
  driver, the EROFS reader, the `system` tree, FAT, the SD controller
  and updates, with every invariant and its test.
* [design-stopgap.md, littlefs in the storage domain](../design-stopgap.md#littlefs-in-the-storage-domain):
  the owner and worker, the failure path and the tests.
* [design-f2fs.md](../design-f2fs.md): erXos's F2FS, its construction,
  crash states and power-cut harness.
* [design-platforms.md, Slots and the boot-selection record](../design-platforms.md#slots-and-the-boot-selection-record):
  the record on each platform, and trial requests.
* [design-fiasco.md, The end path](../design-fiasco.md#the-end-path):
  how every end of the machine becomes a reset.
* Changman Lee, Dongho Sim, Joo-Young Hwang and Sangyeun Cho, "F2FS: A
  New File System for Flash Storage", USENIX FAST, 2015: the design of
  F2FS. <!-- check: authors and venue -->
* littlefs project, README of littlefs v2.11.3,
  <https://github.com/littlefs-project/littlefs>: littlefs's goals.
* Raspberry Pi Ltd, "config.txt" documentation, sections on
  `autoboot.txt` and `tryboot`,
  <https://www.raspberrypi.com/documentation/computers/config_txt.html>:
  the firmware's A/B boot.
* Ralph Merkle, "A Digital Signature Based on a Conventional Encryption
  Function", CRYPTO, 1987: the hash tree.
  <!-- check: citation -->
