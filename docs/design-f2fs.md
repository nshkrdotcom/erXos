# erXos's F2FS

erXos's main read-write file system is F2FS, Linux's flash file system,
implemented afresh in Erlang and supported at tier 1. It serves the data
partition and the vault's partition behind the `erx_fs` interface that
littlefs serves today, and it writes and reads Linux's on-disk format: an
image erXos writes passes `fsck.f2fs` and mounts in Linux, Linux replays
the roll-forward records of the files erXos synced, and erXos mounts what
Linux and `mkfs.f2fs` write, replaying Linux's records in turn. This
document is the design: what erXos writes, reads and refuses, the
processes and their state, the pure core that plans every change before
it is applied, durability and recovery, space and the cleaner, the
interface, the parsers and their fuzz targets, and the tests that check
it all: on the host against a reference model and the corpora, and
against Linux in the oracle guests, power cuts included.
Storage as a whole, the block driver and the partitions are
[design-storage.md](design-storage.md); the file protocol and the
`erx_fs` behaviour are [design-files.md](design-files.md); the ordered
end that freezes storage is [design-system.md](design-system.md#shutting-down).

Decisions every reader of this document needs:

* **The durable view is never overwritten.** At any moment the medium
  holds one *durable view*: the last committed checkpoint and the
  roll-forward chain after it, which is exactly what a mount would
  rebuild. The one allocator never hands out a block that was live at
  the last checkpoint or has been allocated since it, and node ids
  follow the same rule. Only a checkpoint's commit releases blocks and
  node ids and ends an allocation epoch; an `fsync` record extends the
  chain and releases nothing. Every crash state the facts records list
  follows from this rule and from where the commit points sit
  ([The construction](#the-construction)).
* **One process owns a volume, and every decision is a pure step.** The
  volume process holds the volume's state as one value, and every
  request is one step of a pure function from the state to the next
  state and a plan of block writes and flushes. A checkpoint and an
  `fsync` record are each one plan, built and validated whole before a
  block is written. The volume process is the window's only client, so
  the block service's in-order answers order every read and write.
* **A record's commit block is written over its own pre-image.** The
  block that makes an `fsync` record durable is first written, before a
  flush, with a footer no checkpoint matches, and then rewritten whole.
  The two differ only inside the block's last sector, so a cut leaves
  one of two whole blocks, and erXos, Linux and `fsck.f2fs` all read the
  same record or none ([fsync](#fsync)).
* **A chain never spans a mount.** Recovery is a pure replay in memory.
  A read-only mount serves the replayed state and writes nothing; a
  read-write mount commits it with the mount checkpoint before it admits
  a single write. That checkpoint writes every node replay changed into
  new blocks, and writes nothing the walk read and no summary the old
  checkpoint needs, so a cut during it recovers the same files again,
  and nothing written after it can join the chain it replayed.
* **Linux's format, erXos's rules.** The bytes are Linux v7.3.4's
  format, from the facts records of the clean room. Which features and
  checkpoint flags erXos reads and writes, when an `fsync` is a record
  and when a checkpoint, and what a mount refuses are erXos's own rules,
  each stated here with its consumer.
* **One representation per kind.** erXos writes regular files and
  directories as blocks, never inline, writes no journals in its
  checkpoints, no compact summaries, no NAT bits, no inline xattrs, no
  in-place data and no threaded logging. It reads every form Linux
  writes by default, and converts an inline file or directory to blocks
  in the step that first changes it.

## Contents

* [Context](#context)
* [Requirements](#requirements)
* [Scope: features and forms](#scope-features-and-forms)
* [The construction](#the-construction)
* [Processes and ownership](#processes-and-ownership)
* [The core](#the-core)
* [Durability](#durability)
* [Mount and recovery](#mount-and-recovery)
* [Space and the cleaner](#space-and-the-cleaner)
* [The interface](#the-interface)
* [Reading the medium](#reading-the-medium)
* [Formatting a volume](#formatting-a-volume)
* [Replacing littlefs](#replacing-littlefs)
* [Failure handling](#failure-handling)
* [Security](#security)
* [Verification](#verification)
* [Performance](#performance)
* [Alternatives considered](#alternatives-considered)
* [Stages](#stages)
* [Risks](#risks)
* [References](#references)

## Context

### What erXos matches

The behaviour matched is Linux v7.3.4's F2FS driver and f2fs-tools
1.16.0's `mkfs.f2fs` and `fsck.f2fs`, for 4096-byte blocks. Linux ties
the F2FS block size to its page size, and f2fs-tools supports only 4 KiB
blocks ([F 2], [T 85]), so a 4 KiB block is the whole of what any
4 KiB-page Linux mounts. The requirements are that F2FS is the main file
system with tier 1 support, that it supports the Linux format with full
Linux compatibility, roll-forward records written and replayed included,
and that its format facts come only from the sources below.

**The clean room.** Linux's F2FS and f2fs-tools are GPL-2.0, and
f2fs-tools' headers are also LGPL-2.1. None of their code, comments or
structure reaches the design or the implementation. What erXos knows of
them comes from three facts records, written by separate facts writers
who read the GPL sources and recorded interface facts in their own words:

* part 1, the on-disk format, 65 facts
  (`~/erxos-scratch/notes/research-f2fs-format.md`, 2026-11-14, SHA-256
  `1017752a5590db51b53650ee587eaa06f4be0378c7beb7b315796bf983b5a717`),
  cited here as [F n];
* part 2, writing, checkpoints and recovery, 85 facts and 20 crash states
  (`research-f2fs-recovery.md`, SHA-256
  `fe95b138e0d549a57b014a95410b245329691903f5de6d22bc6ba494590f94fb`),
  cited as [R n] and its crash states as [C n];
* part 3, what f2fs-tools makes and checks, 94 facts
  (`research-f2fs-tools.md`, SHA-256
  `c58e6dc69876181768cf707c6d573fb754b8351f01cd1bc2adb89d655e4ce9ae`),
  cited as [T n].

Two other sources are allowed. Fuchsia's Rust read-only library
`src/storage/f2fs_reader`, BSD-licensed (each file's header: "Copyright
2025 The Fuchsia Authors ... BSD-style license"), confirms the CRC
(`superblock.rs` l.17-27), the superblock and checkpoint header layouts
(`superblock.rs` l.29-79, `checkpoint.rs` l.26-51), a reader's own
feature mask (`superblock.rs` l.82-96, l.127) and a reader's bound on
the version bitmaps (`superblock.rs` l.155-174, `checkpoint.rs` l.60-61,
l.106-130); the copies read were fetched at Fuchsia commit
`6478165d12ab3164d09b3e81551ff692427b5038` (SHA-256 of `superblock.rs`
`010e4ceabf9b4dae333e0bb6804ecba48a9d02d1afcd1104269691d01429d4c7`, of
`checkpoint.rs`
`34b8661aff896446c9ade8f3b2c0160e18b9b7734e7ed59065c7f3d0f6416bef`). And
black-box runs of Linux and f2fs-tools in the oracle guest settle what
the records leave open. Fuchsia's C++ `src/storage/f2fs` and `fstool` are
not sources: their structure follows Linux's, and fstool's authors cite
GPL material. Where the f2fs_reader README disagrees with the facts
records, the records win: the second superblock is at byte 1024 of block
1, not at byte 2048 ([F 7], [T 21]), and the NAT journal lives in the hot
data log's summary, not in a node segment ([F 28]).

Everything Linux and f2fs-tools are made to do in the oracle guest is
observed as a black box, and their output is untrusted input to the host.

### What the code does today

littlefs 2.11.3 serves the data partition, as a NIF behind the `erx_fs`
callback module `erx_lfs` of the `erx_storage` application
(`erlang/apps/erx_storage/src/erx_lfs.erl`): an owner process takes the
callbacks' requests one at a time, and a worker runs littlefs's
operations, whose block callbacks the owner sends to the data window with
`gen_server:send_request/2`. `fsync` is littlefs's file sync followed by
the window's flush (`erx_lfs.erl` l.244-262). Any block failure ends the
owner, and its supervisors, at a restart intensity of 0, end the storage
domain, whose restart mounts the volume afresh
(`erx_storage_sup.erl`). The installation formats the volume on the host
with `tools/host/lfs_format.c` through `Erx::DataVolume`
(`tools/lib/erx/data_volume.rb`), and the rest of a fresh volume is zeros.
The durability facet's checkpoint and freeze
([design-storage.md](design-storage.md#interfaces)) are specified but not
built in `erx_lfs`.

The block service's window (`erlang/apps/erx_blk/src/erx_blk_window.erl`)
takes `{read, Sector, Count}`, `{write, Sector, Bytes}` and `flush` from
its one client and answers one request at a time, in order. A write is
answered once the controller reports it written; a flush is answered once
every write answered before it is durable on the medium; there is no
forced-unit-access write. The most one request moves is the transport's
`max_sectors`, 8 sectors on virtio: one 4 KiB block. The storage design
assumes a medium that writes a sector atomically and honours a flush
([design-storage.md](design-storage.md#invariants)); this design rests on
those two assumptions and on nothing else about the medium.

F2FS's records are packed, with a 64-bit `block_count` at offset 36 of
the superblock and 32-bit fields at odd offsets in NAT entries, summary
entries and dentry slots ([F 1]), and the ABI's layout language states
them in its packed storage
([design-abi.md](design-abi.md#packed-layouts)).
`abi/formats/f2fs.txt` holds the superblock, the checkpoint header and
the orphan block, and `erx_f2fs_codec`, in the `erx_f2fs` application,
reads those three.

## Requirements

* **F2-R1.** Every image erXos writes, and every state a power cut can
  leave, passes `fsck.f2fs` and mounts in Linux v7.3.4 at the state erXos
  promised: the last completed checkpoint with every acknowledged `fsync`.
* **F2-R2.** erXos mounts read-write any image Linux v7.3.4 or
  `mkfs.f2fs` 1.16.0 writes with features and checkpoint flags erXos
  maintains, one segment per section (`mkfs.f2fs -s 1`, its default), a
  main area of more than 16 segments and room for its mount checkpoint,
  and replays Linux's roll-forward records as Linux would. Any other
  image whose features and flags it can read it mounts read-only.
* **F2-R3.** An acknowledged `fsync` survives a power cut at any later
  point, including a cut while a mount recovers it.
* **F2-R4.** No state erXos's own writes can leave shows a file bytes
  that were never written to it: no stale block of another file, no torn
  metadata accepted. An image Linux wrote shows what Linux's own mount of
  it shows, stale or torn data blocks of Linux's included ([C 10-12]).
* **F2-R5.** A read-only mount writes nothing, so a trial boot leaves
  the partition byte for byte as it was.
* **F2-R6.** A crafted image costs at most its own partition and the
  process that parses it: every structure is decoded with checked bounds,
  every traversal and every table a mount loads is bounded by the
  partition, and every reader has a fuzz target.
* **F2-R7.** Parity with littlefs over the file-semantics corpus, every
  difference a bug fixed, a documented improvement with a test, or a bug
  in littlefs recorded as such.
* **F2-R8.** A checkpoint can always be written, so a freeze and an
  `fsync` never fail for want of room, and a full volume answers
  `enospc` rather than failing.

Non-goals: encryption, compression, casefolding, verity, zoned and
multi-device volumes, block sizes other than 4 KiB, per-principal quotas
before M10 ([Quotas](#quotas)), and serving extended attributes; each is
refused or answered as [Scope](#scope-features-and-forms) says.
Converting littlefs volumes is a non-goal too
([Replacing littlefs](#replacing-littlefs)).

## Scope: features and forms

Linux keeps no mask of the features it supports: it accepts any feature
bit it does not refuse specifically ([F 54], [F 56], [T 86]). erXos's
refusal is its own rule, and it has one construction: two sets of
feature bits, **W**, the features erXos maintains when it writes, and
**R**, a superset, the features it can read. A mount is read-write only
if every bit set in the superblock is in W, read-only if every bit is in
R, and refused otherwise, with a diagnostic naming the bits. So no
feature is half supported: a feature erXos does not maintain never meets
erXos's writer.

| Feature ([F 10]) | erXos | Consumer or reason |
| --- | --- | --- |
| `EXTRA_ATTR` | W, set at format | carries the inode checksum's field |
| `INODE_CHKSUM` | W, set at format | detects a corrupt inode block wherever an inode is read |
| `SB_CHKSUM` | W, set at format | detects a corrupt superblock copy, so mount takes the other instead of a wrong geometry |
| `LOST_FOUND` | W, not set at format | a directory with no rule a writer must keep; `fsck.f2fs` reconnects unreachable files into it, which on erXos's own volumes would hide an erXos bug from the oracle ([T 76]) |
| `INODE_CRTIME`, `FLEXIBLE_INLINE_XATTR`, `QUOTA_INO`, `PRJQUOTA` | R only | images Linux distributions and Android tools make. A reader decodes nothing new: the creation time and project id are fields it ignores, the inline xattr size is one input of the inode layout ([Inodes](#inodes)), and quota files are inodes outside the tree. A writer would have to maintain them, so the volume mounts read-only |
| `ENCRYPT`, `COMPRESSION`, `ATOMIC_WRITE` | refused, even read-only | decided in [design-storage.md](design-storage.md#read-write-storage); TODO.md keeps encryption and compression as items |
| `VERITY`, `CASEFOLD` | refused | read-only verified content is EROFS under `erx_verity`; UNIX names are case-sensitive |
| `BLKZONED`, a device list, `DEVICE_ALIAS`, `PACKED_SSA`, `RO` | refused | no zoned or multi-device media; layouts not studied |
| any other bit | refused | unknown |

The sets carry one dependency: `PRJQUOTA`, `INODE_CHKSUM`,
`FLEXIBLE_INLINE_XATTR` and `INODE_CRTIME` each need `EXTRA_ATTR`, as
Linux's inode reads require and `mkfs.f2fs` enforces ([T 8], [T 92]), so
a superblock with one of them and without `EXTRA_ATTR` is refused.

Checkpoint flags follow the same construction: a closed set of flags a
mount accepts, every other flag refused with a diagnostic naming it.

| Flag ([F 25]) | erXos | Why |
| --- | --- | --- |
| `UMOUNT`, `ORPHAN_PRESENT`, `COMPACT_SUM`, `FASTBOOT`, `CRC_RECOVERY`, `NOCRC_RECOVERY`, `NAT_BITS`, `TRIMMED` | read | layout and recovery flags a reader follows ([R 27], [R 50]); erXos writes `CRC_RECOVERY`, `ORPHAN_PRESENT` and `UMOUNT` as [Checkpoints](#checkpoints) says and clears the rest |
| `FSCK`, `QUOTA_NEED_FSCK` | read, and kept in every checkpoint erXos writes | marks that the volume needs `fsck.f2fs`, which do not stop Linux's mount ([F 56], [T 90]); the inspector shows them |
| `ERROR` | refused | Linux refuses it ([F 55]) |
| `LARGE_NAT_BITMAP` | refused | only `mkfs.f2fs -i` makes it ([F 24]), and nothing needs it |
| `DISABLED`, `DISABLED_QUICK` | refused, even read-only | with checkpointing disabled Linux may overwrite blocks its checkpoint references ([R 24]), and it skips roll-forward for such a volume ([R 71], [F 56]); a Linux mount re-enables checkpointing, after which erXos mounts the volume |
| `RESIZEFS` | refused | a resize in progress, which the facts records do not describe |
| any other bit | refused | unknown |

Beyond the feature word and the flags, a mount refuses a block size
other than 4096 bytes and a segment other than 512 blocks ([F 3]), and
mounts read-only a volume whose main area of 16 segments or fewer leaves
erXos's cleaner no room
([The space a volume offers](#the-space-a-volume-offers)) and a volume
with more than one segment per section
([The cleaner](#the-cleaner)). A
volume marked as needing a check (`FSCK` or `QUOTA_NEED_FSCK`, or a
non-zero `s_errors` or stop-reason count in the superblock, [F 12])
mounts as Linux mounts it ([F 56]), with the mark kept and shown: erXos
checks every structure where it reads it, so a mark adds no check, and
the repair belongs to `fsck.f2fs` on another machine.

What erXos writes, among the forms Linux allows:

| Choice | erXos writes | erXos reads | Why |
| --- | --- | --- | --- |
| file and directory contents | blocks only | inline data and inline dentries too ([F 48]) | Linux writes inline forms by default, so reading needs them; a writer that also produced them would need the growth path from inline to blocks anyway, so writing blocks only is strictly less |
| extended attributes | none; existing ones are carried unchanged | steps over the inline area and the xattr node ([F 62]) | nothing in erXos uses them and littlefs serves none; an inode erXos rewrites keeps its inline xattr bytes and `i_xattr_nid`, and an inode erXos frees frees its xattr node |
| `i_ext`, the largest-extent hint | `len` 0 on every inode written | ignored | Linux seeds its extent cache from `i_ext` without checking it ([F 44]); zero is the one value that is always consistent |
| NAT and SIT journals | empty | read, and their entries written to blocks at the next checkpoint | one rule for where an entry lives |
| data summaries in the pack | normal form, three blocks | compact form too ([F 29]) | one layout; both of Linux's ways of finding normal summaries agree on it ([F 30]) |
| `nat_bits` | never; the flag cleared | ignored | an optimisation Linux uses only with a mount option ([F 27]) |
| logging | appending (LFS) only | threaded (SSR) logs' summaries too | appending is correct on its own; the mount checkpoint moves a log the committed checkpoint marks SSR to a free segment ([The mount checkpoint](#read-write-mounts-the-mount-checkpoint)) |
| in-place data updates | never | nothing to read: they leave ordinary blocks | an overwritten block can tear and is visible before any checkpoint ([R 46], [C 11]) |
| superblock | written once, by the format | either valid copy | no run-time superblock write, so no torn superblock and no host-dependent `s_errors` bit order ([F 5]) |
| discards | none | - | the block service has no discard request |
| six logs | hot, warm and cold for nodes and data, by kind | any placement | Linux requires six distinct current segments ([F 55]); the fsync chain must be the warm node log ([R 49]) |

Placement by kind: a directory's dentry blocks go to hot data, a
regular file's data and a symlink's target to warm data, blocks the
cleaner and the mount checkpoint copy to cold data; a directory's direct
nodes to hot node, every other direct node, inode and xattr node to warm
node, and indirect nodes to cold node ([R 30]). Which data log a block
lands in matters to no reader.

## The construction

### The durable view is never overwritten

A power cut returns the volume to what a mount rebuilds from the medium:
the newest valid checkpoint pack, the NAT and SIT copies its version
bitmaps select, the summaries of its segments, and the roll-forward chain
that starts at its warm node log's next block ([R 14-24], [R 49-51]).
Call that the **durable view**. The time between two checkpoint commits
is an **epoch**. Every main-area block is in one of four states:

* **live**: referenced by the volume's current state, the in-memory SIT
  marking it valid;
* **touched**: live at the last checkpoint's commit, or allocated since
  it;
* **claimed**: allocated by an operation in flight, not yet live;
* **free**: none of these.

The allocator returns only free blocks. A block that stops being live
stays touched for the rest of the epoch, and **only a checkpoint's
commit** resets the touched set, to the live set of the state that
checkpoint committed. Every block of the durable view is live or
touched: the checkpoint's blocks were live at its commit, and every
chain block was allocated after it. So **no write ever lands on a block
the durable view references**. The durable view changes in two ways
only: a checkpoint's commit replaces it, and a record's commit block
extends its chain by a complete record. A record releases nothing, so
the blocks a running volume freed since the checkpoint, whether their
files were synced or not, stay out of reach until the next checkpoint
makes them unnecessary. Linux keeps the same rule for blocks within a
segment, with a second valid map per segment ([R 38-39]); erXos makes it
the allocator's only rule, and holds it in three more places:

* at mount, the touched set is the checkpoint's live set **and every
  block the chain walk read**, which Linux's allocator does not know;
* node ids follow the same rule: a nid whose NAT entry is cleared returns
  to the free pool only at the next checkpoint's commit, as on the path
  the records traced in Linux ([R 25]; whether Linux has another is their
  open question 6);
* summaries are part of the durable view, and an SSA block is written
  only for a segment whose summary the durable view does not read; every
  summary the state changed reaches its SSA block at the next
  checkpoint, unless that checkpoint's pack or footers carry it
  ([Segment summaries](#segment-summaries)).

Four orderings complete the construction, each the plan's to keep, not
a caller's:

1. **An address enters the state only after its block's write is
   answered.** So a block the state references holds what was written to
   it, once the next flush is answered.
2. **A commit block is written only after a flush answered after every
   write it covers.** A checkpoint's last block and a record's commit
   block each follow such a flush, and a flush follows each of them
   before the checkpoint or the `fsync` is reported. A durable commit
   block therefore implies every block it references is durable and
   whole.
3. **A block freed in an epoch is free only after the flush that
   follows the next checkpoint's last block is answered.** Until then
   the old durable view may still be the one on the medium.
4. **A record's commit block is written over its own pre-image**, made
   durable by the flush before it, which differs from it only in the
   footer's `cp_ver` ([fsync](#fsync)). Since a sector is written whole
   or not at all, a cut leaves at that address the pre-image or the
   whole commit block, never a block whose footer matches and whose body
   is stale.

### One process owns a volume

The volume's state is one Erlang value held by one process. Every
request is one step of a pure function, `step(State, Request) -> {State1,
Reply, Plan}`, where a plan is a sequence of phases, each a set of block
writes followed by a flush, or a set of block reads. The volume process
carries the plan out: it sends every read and write to the window
itself, asynchronously, collects the answers, and continues the step
that waited for them. Since the window answers one request at a time in
the order it receives them, and the volume process is its only client, a
read the volume issued before a write is answered before that write
lands, whatever the two touch. No other process reads the medium, so no
reader holds an address the allocator may meanwhile reuse.

A step that needs a block the state does not hold answers `{need,
Addresses}`; the volume process reads them, adds them to the state's
cache, pinned for that step, and runs the step again from the start
against the state as it is then. A pin lasts until the step answers its
plan or fails, and the cache evicts clean blocks no step pins beyond its
bound. The core therefore never waits and never sees a partial read, and
a step is a pure function of its arguments that the host tests call with
every block it needs. Every step needs a bounded number of blocks: an
operation that walks a whole node tree (a truncate, the freeing of a
large file, orphan cleanup) runs as a sequence of steps of at most 64
nodes each.

### A chain never spans a mount

A mount replays the chain in memory, through the same core operations a
running volume uses ([Replay](#replay)). A read-only mount stops there and
serves the replayed state. A read-write mount commits the replayed state
with one checkpoint, the **mount checkpoint**, before it admits any
write. Replay leaves every node it replays or changes dirty and adopts
no chain node block, so the mount checkpoint writes them all into new
blocks, like any checkpoint, and the touched rule keeps those blocks off
the walk's footprint until it commits. So:

* a cut during the mount checkpoint leaves the old checkpoint and the
  whole chain exactly as the mount read them, and the next mount
  recovers the same state again (Linux's warm node log resumes at the
  chain's first block, which its recovery checkpoint can overwrite before
  it commits, so a cut there may lose fsynced data in Linux: [R 65], open
  question 1 of part 2);
* every block written after the mount carries the new checkpoint's
  version, so no stale block left by an earlier crash, an unreplayed
  dnode of an inode that never reached the chain, say, can ever be linked
  into a later chain and replayed against a reused nid.

### What disappears

Under these rules the following need no mechanism of their own:

* the recovery checkpoint's exposure ([R 65], [C 14]): the mount
  checkpoint writes nothing the walk read and no summary the old view
  reads;
* stale chains on a reused medium or after a crash: after a mount every
  stale block carries an older version than the epoch's, and before the
  first mount the format zeroes the warm node log's first block, as
  `mkfs.f2fs` does ([T 25]);
* a dnode durable before its data ([R 48], [C 10]) and a checkpoint
  covering data still in flight ([R 11], [C 12]): orderings 1 and 2;
* a torn commit block of a record, and with it any dependence on how
  Linux treats a chain inode whose checksum fails (open question 4 of
  part 2): ordering 4;
* torn in-place data ([C 11]): erXos writes in place only its checkpoint
  packs, which alternate, the SSA blocks the durable view does not read,
  and a record's commit block over its pre-image;
* storage or a nid released while the checkpoint still needs it: only a
  checkpoint's commit releases anything;
* a checkpoint that straddles operations: a checkpoint starts only when
  no mutation is in flight, and mutations that arrive meanwhile wait
  ([Checkpoints](#checkpoints)).

## Processes and ownership

Each volume is an `erx_f2fs_sup` supervisor in the storage domain, under
the domain's supervisor, with two kinds of process:

* **The volume process**, `erx_f2fs_volume`, owns everything: the
  geometry, the committed checkpoint, the NAT and SIT state, the node and
  dentry block cache, the dirty blocks, the six logs, the touched and
  claimed sets, the free nid pool, the orphan set, the epoch's facts and
  charge (below), the holds grants place on nodes, and the outstanding
  block requests with the steps waiting on them. It is the data window's
  only client, it runs the checkpoint timer, and it runs the cleaner as
  steps of its own between requests ([Space and the
  cleaner](#space-and-the-cleaner)). It never makes a synchronous call
  after its start.
* **The `erx_fs` processes** that run the callback module `erx_f2fs`: one
  grant process per grant and one owner per open file, with their read
  helpers ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
  Each callback is one call to the volume process, and keeps nothing in
  the calling process, as the behaviour requires. The tree's handle is
  the volume process's pid and a reference made at its start.

A grant's requests reach the volume concurrently with every other
grant's; the volume interleaves their block requests. `erx_fs`'s owner
already orders each file's reads, writes and size changes, so the volume
never sees two writes of one file at once.

The volume is linked to its supervisor, which runs at a restart
intensity of 0 as littlefs's does: the end of the volume process, for a
bug, a failed write or a failed flush, ends the storage domain, and the
domain service's restart mounts afresh, which recovers. Every grant and
owner fails its pending call with `eio`. A mount starts only once the
window has answered every request of the volume it replaces; in the
default configuration the window ends with the domain, and
[design-storage.md](design-storage.md#read-write-storage) gives the rule
for a driver in another domain.

## The core

The core is the modules below, every one pure, building for the host and
tested there on stock OTP. The volume process and the callback module are
the only effects.

| Module | Owns |
| --- | --- |
| `erx_f2fs_codec` | every on-disk record's decoder and encoder over the generated layouts, the CRC, the dentry hash, the bitmaps' bit orders; the only module that reads or builds block bytes |
| `erx_f2fs_mount` | choosing the superblock copy and the checkpoint pack, the mount checks, loading the SIT, the chain walk, orphan cleanup and replay; answers the initial state |
| `erx_f2fs_core` | the volume state and every operation on it: lookup, create, write, truncate, link, unlink, rename, setattr, readdir, holds; the allocator, the room rule and the one slot-setting function |
| `erx_f2fs_plan` | the checkpoint plan, the mount checkpoint's copies, the `fsync` record plan and the decision between record and checkpoint, and `need/1`, the free segments the next checkpoint takes |
| `erx_f2fs_clean` | victim choice and the move step |
| `erx_f2fs_format` | the format plan of a new volume |

### The volume state

The state is one record that `erx_f2fs_core` alone constructs:

* **geometry**, from the superblock: area addresses and segment counts,
  the NAT capacity, the feature word and whether the mount writes;
* **the committed checkpoint**: its version and CRC, flags, the pack it
  sits in, the version bitmaps, its six logs' positions, and the counts
  it recorded;
* **the SIT**, whole: per main segment its type, its valid map as a
  bitstring, its touched map, and its age ([F 37]); loaded at mount,
  since allocation and cleaning read every segment;
* **the NAT**, by block: the NAT blocks read so far, cached, and every
  entry changed since the checkpoint, dirty, each `{Ino, Addr, Version}`
  ([F 33]); a NAT block is fetched when a lookup needs it;
* **nodes and dentry blocks**: a cache of clean blocks, bounded, and the
  dirty ones, which stay until a plan writes them; a dirty node or dentry
  block has no address until then;
* **the six logs**: each a segment and the next offset in it; the log
  knows its next block after every allocation, moving to a free segment
  when its segment fills, because each node footer names that next block
  ([R 35]);
* **the unpublished summaries**: the whole summary block of each
  segment whose SSA block does not hold its summary. Those are the
  committed checkpoint's six logs, whose summaries come from its pack or
  are rebuilt from their footers at mount, and every segment in which a
  block has become live since the checkpoint, whose entries `set_slot`
  and `set_node` record ([Segment summaries](#segment-summaries));
* **the touched and claimed sets**, **the free nid pool** (nids whose
  committed NAT entry is empty and that no step has taken since the
  checkpoint, [R 25]), and **the freed generations**: for each nid whose
  inode was freed since the mount and that no inode has taken since, that
  inode's `i_generation` ([Inodes](#inodes));
* **the orphans**: inodes with no link whose freeing has not ended,
  because a hold keeps them or because their nodes are being freed in
  steps, so a checkpoint between those steps lists the inode and a mount
  after a cut frees the rest ([R 75]);
* **the epoch's facts**: per inode, what happened to it since the
  checkpoint (created, recorded, renamed or linked, a node freed), which
  decide whether an `fsync` can be a record;
* **the epoch's charge**: the blocks the next checkpoint, or a mount
  after a cut, would write into the logs ([The room rule](#the-room-rule));
* **the counters** `valid_block_count`, `valid_node_count` and
  `valid_inode_count`, changed only by the one slot-setting function and
  the one NAT-setting function, and checked against a recount by a
  property test; `free_segment_count` is never kept but computed from the
  SIT a plan writes.

### Allocation

`allocate(State, Log, N)` returns N free blocks of a log, in order, and
the state with them claimed. It answers `enospc` before changing anything
when the volume's space cannot take them, and `room` when the room rule
refuses them, after which the volume process cleans or checkpoints, as
that rule says, and runs the step again
([Space and the cleaner](#space-and-the-cleaner)). A free segment is one
whose blocks are all free and that no log holds. A log appends within its
segment, and an appending log's next block and every block after it in
the segment are free, which Linux and `fsck.f2fs` require of a
checkpoint's logs ([F 39], [T 75]).

Every change of a block reference goes through one function,
`set_slot(State, Owner, Index, Address)`, where the owner is a dnode or an
inode's address array and the address one of `NULL_ADDR`, `NEW_ADDR` or
a real address ([F 4]). It clears the old address's valid bit, sets the
new one's, moves the new block from claimed to live, records the new
block's summary entry ([F 46]) in its segment's unpublished summary,
adjusts `valid_block_count` by the
slots' weights (a real address or `NEW_ADDR` counts one, `NULL_ADDR`
none; [T 61], [T 75]) and adjusts the inode's `i_blocks`. A real address
that another slot holds, as the block's summary names it and that slot
confirms, is first cleared from that slot, so a block never has two
owners; only replaying a Linux chain meets that case ([R 57]). Writes,
truncates, the cleaner's moves and replay all call it, so the invariants
it keeps are kept everywhere. Node addresses change only
through `set_node(State, Nid, Ino, Address)`, which keeps the NAT entry,
bumps its version when a node is freed ([F 33]), records a new node
block's summary entry, its nid, in its segment's unpublished summary
([F 46]), and adjusts the node and inode counts.

### Inodes

One function, `layout(Volume, InodeBlock)`, answers an inode's
geometry: E, the extra attribute words, from `i_extra_isize` when the
inode has `EXTRA_ATTR`; X, the inline xattr words, from
`i_inline_xattr_size` when the volume has `FLEXIBLE_INLINE_XATTR`, else
50 when the inode has `INLINE_XATTR` or `INLINE_DENTRY`, else 0; and from
them the address array, 923 - E - X words, and the inline area ([F 41],
[F 48]). Every reader and writer of an inode asks it, so a flexible
inline xattr size moves the address array and the inline area for every
reader at once. erXos keeps E and X of an existing inode unchanged, and
gives a new inode E = 3 (`i_extra_isize` 12) on a volume with
`INODE_CHKSUM`, E = 1 with `EXTRA_ATTR` alone and E = 0 without, as
`mkfs.f2fs` does ([F 41]), and X = 0.

The inode encoder takes the footer as an argument and computes the
inode checksum last, over the whole block with the footer in place
([F 50]): the checksum covers the footer, so a block whose footer changes
after it was sealed cannot be built. It writes the checksum whenever the
volume has `INODE_CHKSUM`, the inode has `EXTRA_ATTR` and
`i_extra_isize` reaches the field, which is when Linux checks it
([T 92]). It writes `i_ext` with `len` 0, `i_name`, `i_namelen` and
`i_pino` at a new inode's link and at every rename of an inode with one
link ([F 40]), and leaves `i_advise`, `i_flags`, `i_gc_failures`,
`i_inline_xattr_size`, the projid and the inline xattr bytes as it found
them.

**A new inode's `i_generation`** is one more, modulo 2^32, than the
generation of the last inode freed at its nid since the mount, which the
state's freed generations keep; at a nid that has held no inode since
the mount it is the low 32 bits of the epoch's checkpoint version. A qid
path must name one file while the storage domain lives
([design-storage.md](design-storage.md#read-write-storage)), which is
one mount. A nid takes at most one new inode an epoch, since a freed nid
returns to the pool only at the next commit, so its generations could
repeat only after 2^32 epochs, and **a mount admits requests for fewer
than 2^32 epochs**: the checkpoint whose version is 2^32 above the
mounted one ends the volume after its commit, as a failed write does,
and the storage domain's restart begins a new life. Within a life no two
inodes at one nid share a generation, whichever writer made the first.
The bound is 49 days at a checkpoint every millisecond, and thousands of
years at the 30-second timer. The freed generations hold one entry per
free nid that held an inode in this mount, dropped when an inode takes
the nid.

File blocks map through the address array, two direct nodes, two
indirect and one double indirect node, with the node offsets of [F 53].
A regular file holds at most 920 + 2 x 1018 + 2 x 1018^2 + 1018^3
blocks with E = 3 and X = 0, 4,329,690,873,856 bytes; a write past that
answers `efbig`.

### Directories

Names hash with the TEA directory hash of [F 57], "." and ".." to 0,
and directories are the multi-level hash table of [F 58], whose geometry
depends on the inode's `i_dir_level`, d: level n has 2^(n+d) buckets
while n + d is below 31, each two blocks. A lookup searches levels 0 to
`i_current_depth` - 1, in each only the blocks of the name's bucket; an
insertion takes the first level whose bucket has a run of free slots and
grows the depth when it opens a level. erXos keeps d of a block
directory as it finds it, and writes d = 0 on every directory it creates
or converts. A new directory is one dentry block holding "." and ".." in
slots 0 and 1, `i_size` 4096, `i_current_depth` 1, `i_dir_level` 0 and
two links, as the format's root is ([T 22-23]). A long name takes
consecutive slots, with every slot's bitmap bit set and the following
records' `name_len` 0 ([F 60]). An empty dentry block stays allocated;
`i_size` covers the highest block in use.

A Linux inline directory converts to a block directory in the step that
first changes it, and the conversion sets its `i_dir_level` to 0. Level 0
is then one bucket of two blocks, so inline slot k becomes slot k of
block 0: every entry sits in the bucket its hash requires, as
`fsck.f2fs` checks ([T 65]), and keeps its slot, so a `readdir` offset
stays valid across the conversion. An inline directory has no dentry
block, so the level it carried constrains nothing it holds. An inline
regular file or symlink converts the same way: its bytes below `i_size`
become block 0, and the rest of the block is zeros. A readdir offset is
the slot's position, block index times 214 plus the slot, so entries
never move.

Dentry blocks are file blocks of the directory, held dirty in the volume
and written by the next checkpoint, as Linux does ([R 1]).

### Operations

Every operation is one step, or for a walk of a whole node tree a
sequence of steps, that validates its whole effect before it changes
anything. The namespace operations (create, mkdir, symlink, link,
unlink, rmdir, rename, setattr) change only dirty nodes and dentry
blocks in memory, and become durable at the next checkpoint. A rename is
one step, so a checkpoint sees it whole or not at all.

**A write** is two steps around its I/O. The first computes the blocks
the write covers, needs the old contents of a partial first or last
block, claims new blocks in the warm data log, and answers a plan that
writes the merged blocks. When every write is answered, the second
installs them with `set_slot`, grows `i_size` and sets the times; if the
volume broke meanwhile the claims die with the state. A write whose
blocks would take more than one free segment runs as several such
pairs, each taking at most one, so no step takes more.

**No byte at or past a file's size is kept or trusted.** A truncate to a
size inside a block it keeps rewrites that block out of place, as a
write does, with zeros from the new size to the block's end, and frees
the slots and nodes past it through the same functions; a truncate to a
block boundary needs no write. A truncate that frees many nodes sets the
size and rewrites that block in its first step, frees at most 64 nodes
in each step after it, and answers after its last, so the file's owner
sends nothing else for the file meanwhile
([Processes and ownership](#processes-and-ownership)). A checkpoint
between its steps commits nodes past the size still mapped, which no
read reaches and `fsck.f2fs` does not check ([T 61]), and a cut there
leaves them mapped.

So erXos relies on nothing past a size, whoever left it there, a cut
truncate of its own or Linux: **a step that raises a file's size over
bytes it does not write first truncates the file to its old size**,
through the same truncate. Such a step is a size raise by `setattr`, or
a write that starts past the block holding the old size; a write that
starts in that block or below it merges zeros, not the old block's
bytes, wherever its block lies at or past the old size. The file's owner
orders its writes and size changes, so nothing maps a slot of the file
between the truncate and the raise. Normally nothing lies past the old
size, and the truncate reads only the path to it, which the raise needs
anyway. So an extension shows zeros, after a restart as before one, as
POSIX and the shared mappings of
[design-files.md](design-files.md#shared-mappings) require.

On every image erXos writes, then, the block holding a file's size has
zeros past the size, and no slot past it is mapped unless a cut fell
between a truncate's steps. Whether Linux relies on either when it
extends a file is unverified; the oracle guest checks both
([The Linux oracle guest](#the-linux-oracle-guest)).

**A read** is a lookup step that answers the block addresses of the range
(holes and `NEW_ADDR` read as zeros, [C 12]) and the volume reads them;
the helper's call returns the bytes. The read's addresses come from the
state at its step, and the touched rule keeps them unreused while the read
is queued at the window behind no write to them.

### Segment summaries

Each segment's summary block lives in the SSA at `ssa_blkaddr` plus its
number ([F 45]). The durable view takes a segment's summary from the
committed pack when the segment is one of the committed checkpoint's data
logs, rebuilds it from the blocks' footers when the segment is one of its
node logs ([F 31], [R 23]), and reads the segment's SSA block otherwise.
Three readers decide by a valid block's summary: replay's stale-owner
check ([R 57]), the cleaner ([R 80]) and `fsck.f2fs` ([T 68]). None of
them decides by the summary of a block that was invalid at the
checkpoint: replay consults a block's summary only while the block is
valid in the replayed state, and a block invalid at the checkpoint
becomes valid only through `set_slot` or `set_node`, which record its
summary in the state. So the durable view reads a segment's SSA block
only when the segment held a valid block at the committed checkpoint and
was not one of its logs, and the summary rule follows:

**An SSA block is written only for a segment that held no valid block at
the committed checkpoint, or was one of its six logs.** Every summary
the state changes lies in such a segment, so the rule costs nothing: a
block becomes live only at an address the allocator gave, in a committed
log's segment or in a free segment a log entered, or at an address
replay adopts, which [Replay](#replay) allows only in the same two
kinds. **Each checkpoint writes the SSA block of every unpublished
summary whose segment is not one of its own logs.** A current data log's
summary goes into the pack instead, and a current node log's into the
pack at an unmount checkpoint, as Linux's rule is; otherwise a mount
rebuilds it from the footers. So after every commit each valid block's
summary is where the new durable view reads it, whether a log left its
segment or replay adopted it in a segment no log enters again
(`fsck.f2fs` checks every one, [T 68]), and only the new checkpoint's
logs keep unpublished summaries.

A mount meets one case the rule refuses: a Linux chain can place a
replayed data block in a segment that held valid blocks at the
checkpoint, a threaded log's ([R 33]), or move a block valid at the
checkpoint to another slot ([R 57]). The mount checkpoint copies such a
block into the cold data log instead of adopting it where it lies
([Replay](#replay)), so the old
segment's SSA block keeps every entry the old checkpoint needs, and the
stale entry it keeps for the block, now invalid, is read by no one.

## Durability

### What is durable when

| Event | Durable at | Through |
| --- | --- | --- |
| a namespace change, a setattr, a write | the next checkpoint, or an `fsync` record of the file when the change is the file's own | the checkpoint's commit; the record's commit block |
| an `fsync` of a regular file that a record can express | its record's commit block | [fsync](#fsync) |
| any other `fsync` | a checkpoint it waits for | [Checkpoints](#checkpoints) |
| a checkpoint on the durability facet, frozen or not | its commit | [The interface](#the-interface) |

An answered `fsync` of a regular file makes durable everything about the
file: its bytes, its size and attributes, and each name it has. A record
carries all of that only when the file's one name is the one a replay
gives it ([fsync](#fsync)); an `fsync` after the file was renamed or
linked, or of a file created in a directory itself new since the
checkpoint, waits for a checkpoint instead, which makes the whole tree
durable as it stands. So `sync; rename(a, b); fsync(b)` leaves `b`, and
no `a`, after any later cut.

A checkpoint runs at least every 30 s while anything is dirty, when the
epoch's charge reaches its bound, when the cleaner needs prefree segments
freed, at an `fsync` that a record cannot express, and on the durability
facet. A write the volume answered is in the next checkpoint whatever its
file's state, since the checkpoint writes every dirty node.

### Checkpoints

A checkpoint starts when no mutation is in flight, and mutations that
arrive meanwhile wait until it commits; reads go on. Its plan, built
whole from the state at its start:

1. **Write the dirty dentry blocks**, allocating each in the hot data log
   and setting the directory's slots, then **the dirty nodes**: direct
   nodes and inodes, then indirect nodes, each allocated in its log with
   its footer completed at allocation: the epoch's `cp_ver` (the
   committed version, with the committed CRC in the upper 32 bits), the
   log's next block, no fsync or dentry mark ([R 35], [R 43]).
2. **Write the NAT blocks** holding a changed entry, each whole, into the
   copy the committed version bitmap does not select, flipping its bit
   ([F 34], [R 3]); **the SIT blocks** the same way ([F 38], [R 4]); and
   **the SSA block of every unpublished summary** whose segment is not
   one of this checkpoint's logs, which the summary rule allows
   ([Segment summaries](#segment-summaries)). The journals are empty, and
   entries the mounted checkpoint kept in its journals are written to
   their blocks here ([F 47]).
3. **Write the pack body** into the pack the committed checkpoint is not
   in: the header block, the payload blocks that continue the SIT version
   bitmap ([F 23]), the orphan blocks when orphans exist ([F 26]), the
   three normal data summaries of the current data logs, and at an
   unmount checkpoint the three node summaries ([F 20]).
4. **Flush.** Then **write the last block**, the header's copy, and
   **flush** again. The checkpoint is committed when that flush is
   answered, and this is the one place anything is released: the touched
   set becomes the live set, prefree segments become free, freed nids
   join the pool, the unpublished summaries become the new logs' alone,
   the epoch's facts and charge clear, the epoch ends, and the checkpoint
   is reported.

The header carries the new version, one above the committed one, the
counts, the six logs' positions, all `alloc_type` LFS, and the flags:
`CRC_RECOVERY` always, `ORPHAN_PRESENT` exactly when orphan blocks are
written, `UMOUNT` only on a freezing checkpoint, after which no write
follows, `FSCK` once the volume has met a malformed structure, never
cleared ([R 27]), and `FSCK` and `QUOTA_NEED_FSCK` when the mounted
checkpoint had them; erXos sets no other flag. The CRC covers the header
as [F 51] says, with `checksum_offset` 4092. `free_segment_count` is
counted from the SIT the plan writes: segments with no valid block that
are not a log's ([T 74]). The orphan list is bounded as Linux bounds it,
(512 - 8 - `cp_payload`) x 1020 inodes ([R 74]); an unlink that would
pass it answers `enospc`.

A failed write or flush in any phase ends the volume process. Until the
last block's flush is answered the committed checkpoint is the one on
the medium, with its chain, so the restart mounts it.

### fsync

An `fsync` of a regular file writes a **record** when the record can
express everything about the file that changed since the checkpoint, and
asks for a checkpoint otherwise. The record is possible when all of these
hold, each a fact the epoch keeps:

* the file has one link and has not been renamed or linked since the
  checkpoint, so its committed entry, or the one recovery recreates from
  its `i_name` and `i_pino`, is its only name ([R 40], [R 56]);
* if the file was created since the checkpoint, its parent directory was
  not;
* no node of the file was freed since the checkpoint, since a chain can
  replace a dnode but not remove one;
* the touched blocks number at most `user_block_count`, so the replayed
  state fits beside the committed one ([R 41]);
* the epoch's charge, with the record's, stays within its bound, so the
  mount checkpoint after a cut fits ([The room rule](#the-room-rule)).

Otherwise the `fsync` waits for a checkpoint. Directories, symlinks and
other kinds always do, as in Linux ([R 40]).

**The record's plan** has two phases, both in the warm node log:

1. Every dirty direct node of the file but its inode block, unmarked, and
   at the address the file's **commit block**, its inode block, will
   take, that block's **pre-image**: the commit block exactly as it will
   be written, with the fsync mark, the dentry mark when the file was
   created since the checkpoint and has no record yet in the epoch
   ([R 43-44]), its `next_blkaddr` and its inode checksum, but with every
   bit of the footer's `cp_ver` inverted, so that it matches the epoch
   under none of the three matching rules ([R 50]). Then a **flush**.
2. The commit block, over its pre-image. Then a **flush**, and the
   `fsync` is answered.

Only a file's last block in a record, its commit block, is marked, which
is Linux's atomic form ([R 45]): recovery replays a file's chain blocks up
to its last marked block and none after, and the walk ends at the first
block whose `cp_ver` does not match. So a record is replayed whole or
not at all, and three facts make every reader agree on which:

* every data block the record's dnodes name was written, and answered,
  before the first flush (ordering 1), and every dnode of the record and
  the pre-image were written before it, so a durable commit block means
  durable, whole data and dnodes;
* the commit block and its pre-image differ only in the eight bytes of
  `cp_ver`, bytes 4084 to 4091 of the block, inside its last sector
  ([F 43]). A write the cut interrupts leaves each sector old or new, so
  the block at that address is the pre-image or the commit block. The
  pre-image ends erXos's walk, Linux's ([R 51]) and `fsck.f2fs`'s
  ([T 57]) before the record, and the commit block is whole. The
  pre-image carries the commit block's checksum, which fails against its
  own footer, but no reader reads it as an inode: no NAT entry names it
  and every walk stops at its footer;
* a torn unmarked dnode of the record lies after every earlier marked
  block of its file, so replay passes it over in erXos and in Linux
  ([R 54-55]), and `fsck.f2fs` collects only marked dnodes ([T 57]).

The record therefore needs no inode checksum to check itself, and a
volume without `INODE_CHKSUM` writes records too.

`fsync`s that arrive while a record is being written join the next one:
the volume writes one record at a time, holding every waiting file's
dnodes and pre-image in one first phase and every commit block in one
second phase, so a chain is a sequence of complete records and at most
one incomplete one at its end. A cut in the second phase may complete one
file's record and not an earlier one's; the walk ends at the first
pre-image, and none of those `fsync`s had returned. An `fsync` that
arrives while a checkpoint is in flight waits for it and is then planned
in the new epoch, so no record straddles a checkpoint.

Indirect nodes are never in a record; recovery builds the path to a
replayed dnode ([R 57]), and the next checkpoint writes the file's
indirect nodes. A record's blocks are live, and the blocks they replace
stay touched until the next checkpoint commits, so a chain block is never
overwritten before a checkpoint makes it unnecessary.

### The device flushes

The design asks two things of the block service and nothing else: that a
write is answered only once the controller reports it written, and that
a flush is answered only once every write answered before it is durable
on the medium ([design-storage.md](design-storage.md#data-model)). It
needs no forced-unit-access write: where Linux writes a commit block with
a preflush and FUA ([R 8]), erXos writes it after one flush and before
another. Of the medium it assumes what the storage design does: a sector
written whole or not at all. On media that do not honour flushes, SD
cards among them, no ordering holds, which
[design-storage.md](design-storage.md#invariants) already records as a
residual.

### Freezing

A freezing checkpoint ([design-storage.md](design-storage.md#interfaces))
reaches the volume after `erx_fs` has closed mutation admission and every
owner has finished the writes it admitted. The volume writes an unmount
checkpoint, `UMOUNT` set and node summaries in the pack, and from its
commit answers every mutation `erofs`. A checkpoint without a freeze, the
vault's, is an ordinary checkpoint. Both answer only once their flush is
answered, so the trial's read-only mount and the next normal mount both
find every write the service acknowledged, with an empty chain. The room
rule keeps a checkpoint possible at every moment, so a freeze never waits
on the cleaner.

## Mount and recovery

### Mount

A mount is pure until its last step, and reads in this order, each
check failing the mount with `eintegrity` and a log line naming the
structure and the rule, after writing nothing:

1. **The superblock**: both copies, at byte 1024 of blocks 0 and 1
   ([F 7]); a copy is valid under every rule of [F 54], with the
   checksum when `SB_CHKSUM` is set ([F 13]), under erXos's feature sets
   and their dependency, and when its `block_count` and the main area's
   end lie within the partition's window, which bounds every table the
   mount loads by the partition itself; the first valid copy wins, and a
   bad copy is logged and left as it is.
2. **The checkpoint pack**: both packs' first and last blocks; a pack is
   valid when both pass their CRC, its total is above 2 and at most 512,
   and both carry the same version; the later version under wrap-around
   comparison wins ([F 22], [R 14-16]); then every check of [F 55] on the
   chosen one, erXos's set of checkpoint flags, and the bitmaps' bounds:
   the SIT and NAT version bitmaps have exactly the sizes the superblock
   implies, and they fit the header or the payload blocks they occupy
   ([F 23]), which Linux does not check and f2fs_reader does
   (`checkpoint.rs` l.106-130).
3. **The pack's contents**: the payload, the orphan blocks (each
   `entry_count` at most 1020, [F 26]), the data summaries in either
   form, the node summaries when the pack has them, the journals within
   their bounds ([F 32]).
4. **The SIT**, whole, from the selected copies with the journal over
   them, and its checks: each count equal to its map's set bits and at
   most 512, each type below 6, node valid blocks equal to
   `valid_node_count`, every log's next block free ([F 39]).
5. **The current node logs' summaries**, from the pack or rebuilt from
   their segments' footers ([F 31]).
6. **The root inode**: a directory with non-zero `i_blocks`, `i_size` and
   links ([F 55]).
7. **The walk**, **orphan cleanup** and **replay**, below.

A read-write mount then writes the mount checkpoint; a read-only mount
serves the state as it is.

**The mount's allowance.** What a mount holds in memory is admitted
against one allowance, a fixed share of the storage domain's memory
grant, counted in bytes. The SIT, whose size the superblock's count of
main segments gives at about 150 bytes a segment, is admitted before
step 4 reads it; the walk admits each block it adds to the footprint,
and replay each block it makes dirty, against what remains. A mount that
would pass the allowance stops there and fails with `enomem`, writing
nothing, with a log line naming the allowance and what passed it. The
storage domain's grant is sized to cover the SIT of each partition it
mounts and a chain erXos writes, whose footprint and replayed nodes the
epoch's charge bounds ([The room rule](#the-room-rule)), so only a Linux
chain, or a medium larger than the grant was sized for, meets the bound.

### The walk

The walk starts at the warm node log's next block of the chosen
checkpoint ([R 49]) and follows each footer's `next_blkaddr`. It ends,
normally, at the first address outside the main area, the first block
whose `cp_ver` does not match the checkpoint, or the first inode block
whose checksum fails on a volume with `INODE_CHKSUM`. A block matches
when its `cp_ver` equals the version with the CRC in the upper 32 bits if
the checkpoint has `CRC_RECOVERY`, the low 32 bits if it has
`NOCRC_RECOVERY`, which `fsck.f2fs` sets, or the plain version otherwise
([R 50], [R 78]).

The checksum rule never meets a chain erXos wrote, whose commit blocks
cannot tear (ordering 4). It meets a chain Linux wrote whose last marked
inode block tore, and there it is erXos's own choice: how Linux treats
such a block was not traced (open question 4 of part 2), and the oracle's
torn-record probes ([The Linux oracle guest](#the-linux-oracle-guest))
record what Linux does. erXos follows Linux where Linux ends the walk or
passes the block over, and keeps ending the walk where Linux would replay
the torn block's addresses, a difference the probes pin as a documented
improvement.

The walk is bounded: it takes at most as many steps as the main area has
blocks not valid at the checkpoint, since every chain block was written
after it, and a chain block valid at the checkpoint, or a walk past the
bound, which a loop makes, fails the mount, as `fsck.f2fs` treats both
([T 57]). A read error fails the mount with `eio`. Every block the walk
read, its end included, is the walk's **footprint**, which the mount's
allowance admits as the walk grows it ([Mount](#mount)).

### Orphan cleanup

When the checkpoint has `ORPHAN_PRESENT`, every listed inode is loaded,
must have no link, and has its blocks, nodes and xattr node freed through
`set_slot` and `set_node`, in memory, before replay, as Linux orders it
([R 75]). An orphan whose inode is not an inode, or has links, fails the
mount.

### Replay

Replay runs in two passes over the chain, as Linux's does ([R 54-55]).
The first finds, for each inode, its last marked block and its last
dentry-marked inode block, and creates every inode a dentry mark names
that the checkpoint does not have (its NAT entry empty, or the mount
fails), so the numbers of new inodes are taken before the second pass
allocates any. A chain block of an inode that neither exists nor is
created is passed over. The second pass takes the chain's blocks in
order and replays, for each inode, the blocks up to its last marked
block:

* **an inode block** sets the inode's attributes, the ones [R 55] lists,
  and its inline area or address array;
* **the inode's last dentry-marked block** links its `i_name` into
  `i_pino`, which must exist: an entry already naming the inode is kept,
  and an entry naming another inode is removed first, that inode being
  freed at once if it has no link left, since no grant holds anything at
  mount ([R 56]);
* **a direct node** replaces the dnode at the same node offset of the
  file, whose offset must match the node already there, allocating the
  path's indirect nodes and their nids from the nids still free, and
  every slot of it goes through `set_slot`: a new address that another
  slot holds, by the block's summary confirmed against that slot, is
  cleared from it first, and a new address still valid after that fails
  the mount ([R 57], [R 60]); an xattr node replaces the inode's xattr
  node under a new nid.

Every rule of [R 60] that fails recovery fails the mount. Replay changes
only the state, and in it the two kinds of block are treated
differently:

* **Nodes are never adopted.** Every node replay sets, creates or
  changes, the replayed dnodes and inodes, the new indirect and xattr
  nodes, and the directories whose entries it changes, is dirty in the
  state with no address, its footer, nid, offset and checksum as the
  state has them, and the mount checkpoint writes each into a new block.
  A chain's node block is never live in the replayed state; it is only in
  the footprint.
* **Data blocks are adopted where the summary rule allows.** A data
  block a replayed slot names is live where it lies when its segment
  held no valid block at the committed checkpoint or was one of its
  logs, as [R 58] adopts it; `set_slot` records its summary, and the
  mount checkpoint writes that segment's SSA block unless the segment is
  one of its own logs, whether or not a log ever enters it again
  ([Segment summaries](#segment-summaries)). Otherwise, which only a
  Linux chain can make, the mount checkpoint copies it: the block is
  read, written to a free block of the cold data log, and installed with
  `set_slot` once its write is answered, before the checkpoint's first
  phase. Its old address is then invalid, and the old segment's SSA block
  is not written.

erXos's own chains need no copy: their data lies in segments its logs
entered free during the epoch, or in the committed warm data log's, and
the mount checkpoint publishes those segments' summaries, which the
checkpoint the cut prevented would have written.
Replay sees Linux's chains, which may hold inline data, `NEW_ADDR` slots,
several marked blocks per inode and addresses moved between slots, and
erXos's, which hold none of those but the marks; the same functions take
both.

Replay's dirty blocks are admitted against the mount's allowance
([Mount](#mount)), which every chain erXos writes fits; a Linux chain
whose replay would pass it fails the mount with `enomem`, writing
nothing.

**A failed recovery fails the mount.** Linux instead mounts again without
roll-forward, at the checkpoint, and marks the volume for `fsck.f2fs`
([R 62]): that serves a state without fsynced data as if it were the
volume. erXos writes nothing, and the files stay on the medium for a
repair, as every failed mount of a storage domain leaves them
([design-storage.md](design-storage.md#read-write-storage)); presenting
the checkpoint after discarding acknowledged records would break F2-R3
for every program that trusted those `fsync`s.

### Read-only mounts

A read-only mount, a trial's or one that a volume's features, size,
sections or room require, runs every step above in memory and writes nothing: the
volume answers every mutation `erofs`, runs no cleaner and no timer, and
its checkpoint and freeze requests answer at once with nothing to do. It
serves the replayed state, so it shows every acknowledged `fsync`
without writing it. Linux, by contrast, replays and writes even on a
plain `ro` mount of a writable device, and refuses the mount on a
read-only device that has something to replay ([R 69-70]).

**A trial's mount replays in memory**, rather than mounting without
recovery as Linux's `norecovery` does: F2FS has one read-only mount, and
no second mount mode exists to build and test. After the freezing
checkpoint that precedes a trial the chain is empty, so the trial sees
the files a mount without recovery would; after an unordered end it
also shows the acknowledged `fsync`s. It writes nothing, so F2-R5 and
the trial's guarantee hold. Linux's `ro,norecovery` mount ([R 67]) stays
the oracle's check of erXos's checkpoints without their chains
([The Linux oracle guest](#the-linux-oracle-guest)).

### Read-write mounts: the mount checkpoint

A read-write mount, after replay, adds the footprint to the touched set
and writes the mount checkpoint, an ordinary checkpoint of the replayed
state, after the copies of [Replay](#replay). It is written whether or
not anything was replayed, which also closes the unmount checkpoint's
`UMOUNT` and commits orphan cleanup. Only after its commit does the
volume admit a request that changes anything.

Each log writes, during the mount checkpoint, only after the last block
of its committed segment that is live or in the footprint, as an
appending log may, and takes a free segment only when no block remains
after that one, or when the committed checkpoint marks the log SSR,
since erXos appends only. So the warm node log resumes past the chain's
end, and a mount with an empty chain, its logs not SSR, takes no free
segment. The mount checkpoint's node blocks carry the committed epoch's
version, as a checkpoint's do, and lie past the chain's end, where the
old view's walk never reaches: that walk stops at the end block, which
is in the footprint and stays as the walk read it.

What the mount checkpoint writes into the logs is bounded by the epoch's
charge the volume carried before the cut, so the room rule that every
erXos volume keeps leaves it the free segments it needs
([The room rule](#the-room-rule)). A volume another writer left whose
mount checkpoint, copies included, does not fit its free segments mounts
read-only instead, with a log line naming the shortfall.

## Space and the cleaner

### The space a volume offers

The volume's space is the checkpoint's `user_block_count` ([F 21]) or
less: erXos counts at most (M - 16) x 512 blocks, where M is the main
area's segments and 16 the overprovisioning the cleaner's argument below
needs. **A volume whose main area has 16 segments or fewer therefore
offers erXos no space and mounts read-only**, with a log line naming M,
as a volume with a feature outside W does
([Scope](#scope-features-and-forms)). `mkfs.f2fs` makes such a volume on
a device of 44 MiB, its smallest, with 14 main segments ([T 17]), up to
just under 50 MiB, by the arithmetic of [T 11-12]. erXos's format
overprovisions at least 16 segments
([Formatting a volume](#formatting-a-volume)), so on its own volumes the
checkpoint's count is never the larger; on a writable volume `mkfs.f2fs` made,
whose overprovisioning can be as little as 10 segments ([T 15],
[T 18]), erXos answers `enospc` up to six segments earlier than Linux
would. A step that would take `valid_block_count` past the space answers
`enospc` before it changes anything, as does one that needs more nodes
than the NAT has free nids.

### The room rule

Space alone does not make a checkpoint possible: a checkpoint writes its
nodes and dentry blocks into the logs, and a log that fills takes a free
segment. Two bounds and one rule keep every checkpoint possible:

* **The epoch's charge** counts what a checkpoint would write into the
  logs: the dirty nodes and dentry blocks, and what the mount checkpoint
  would write after a cut, three blocks for each node block of the chain
  (the node and the two indirect nodes a new path can need) and eight for
  each dentry mark in it (the parent's dentry blocks, nodes and inode
  when its directory grows a level, and the entry and inode of a name it
  replaces). The charge stays within 512 blocks: a step that would pass
  it waits for a checkpoint, and an `fsync` whose record would pass it
  takes a checkpoint instead. So any checkpoint, a running one or a
  mount's after a cut, writes at most 512 blocks into the logs, and no
  log takes more than one free segment for them.
* **`need(State)`**, which the checkpoint planner answers, is the larger
  of the free segments the next checkpoint takes, from the running logs'
  free tails and the blocks the charge puts in each log, and the free
  segments the mount checkpoint of the durable view would take, from the
  committed checkpoint's segments as the running volume has filled them.
  It is at most six, and zero just after a checkpoint commits.
* **The rule**: every step leaves at least `need` free segments, and
  every step but a cleaning step or a checkpoint leaves at least
  `need + 3`, the three a cleaning step may take (the cold data log's and
  two node logs' for the dnodes its moves dirty). A step the rule refuses
  waits while the volume checkpoints, when a checkpoint would free
  segments, or cleans, and answers `enospc` when neither can make room;
  an `fsync` whose record it refuses takes a checkpoint instead.

So a checkpoint always finds its segments, at every moment and after any
cut, since every step leaves `need` and a checkpoint takes at most that
and leaves `need` at zero, and a freeze or an `fsync` never fails for
want of room (F2-R8).

### The cleaner

The cleaner is steps of the volume process. When free segments fall
below `need + 6`, the volume runs cleaning steps between requests; when
the rule refuses a request, the request waits while cleaning runs first
(foreground cleaning).

The cleaner, the room rule and the logs treat a segment as a section, as
erXos's format makes one segment per section. A volume of another
writer with more than one segment per section (`mkfs.f2fs -s` makes
them, and eight of syzkaller's sixteen seeds have two) therefore mounts
read-only, with a log line naming the count, as a volume whose main area
leaves the cleaner no room does ([The space a volume
offers](#the-space-a-volume-offers)); Linux accepts such a volume within
the rules of [F 54].

* **Victim**: the **closed** segment, one that is neither free nor any
  log's, with the fewest valid blocks, whether its log filled it or left
  it part written (greedy, [R 84]); segments are sections, since the
  format makes one segment per section. A prefree segment, closed with no
  valid block, needs no move: a checkpoint frees it.
* **Move**: the step needs the victim's valid blocks and its summary; a
  data block is live when the dnode its summary names still holds its
  address at the summary's index, and a node block when the NAT still
  maps its nid there ([R 80]). Each live data block is written to a free
  block of the cold data log and, once answered, installed with
  `set_slot`, which dirties its dnode; each live node block is marked
  dirty, so the next checkpoint writes it afresh, as Linux's cleaner
  re-dirties nodes ([R 81]). The victim, emptied, becomes prefree, and
  free at the next checkpoint's commit ([R 82]).
* **Freeing**: when cleaning has emptied segments that are still
  prefree, it asks for a checkpoint.

One step moves one victim, at most 512 blocks, so requests run between
steps. Cost-benefit victim choice for background cleaning ([R 84]) is
left for a measurement to ask for ([Performance](#performance)).

**Why a victim exists.** No step but a cleaning step or a checkpoint
takes more than one free segment: a write is split so, and a record's
nodes are held within the charge. So when the rule refuses such a step,
fewer than `need + 4` free segments remain,
at most nine, and the six logs hold six more, so at least M - 15
segments are closed, holding
every valid block outside the logs. Valid blocks number at most
(M - 16) x 512, fewer than M - 15 full segments hold, so some closed
segment has an invalid block, and the greedy victim gains at least one;
the format's 2 % overprovisioning raises that gain to about ten blocks
on large volumes. Each cleaning-and-checkpoint round frees the victim's
segment and writes its valid blocks, and the dnodes their moves dirty,
into the logs' free tails, taking a free segment only when a tail runs
out, so the rounds gain free segments on balance whenever the victims'
valid blocks and dirtied dnodes average less than a segment. That holds
for every pattern but the most fragmented, where each moved data block
dirties a dnode of its own; there the volume answers `enospc` before it
is full, which loses nothing, and the property tests of
[Verification](#unit-and-property-tests) drive every format size to full
churn to measure it.

### Quotas

Per-principal quotas on the data partition are M10's
([plan.md](plan.md#m10-users-without-a-container-runtime),
[design-storage.md](design-storage.md#read-write-storage)), and F2FS
offers nothing for them until then: no principal's usage is counted. The
mechanism, Linux's project quotas or a count rebuilt at each mount, is
chosen once M10's facts record on quota files and its attribution and
reserve contract exist, not here: recounting serves if only erXos
enforces quotas, project quotas if usage must persist across Linux's
mounts. The feature set changes then, and the partitions are created
afresh.

## The interface

F2FS serves the tree littlefs serves, through the same `erx_fs` grants;
nothing above the callback module changes.

* **The callbacks.** `erx_f2fs` implements every callback of `erx_fs`:
  `walk`, `forget`, `getattr`, `open`, `read`, `readdir`, `readlink`,
  `statfs`, `clunk`, `write`, `make`, `setattr`, `unlink`, `rename`,
  `fsync` and `xattr`. `make` keeps files, directories, symlinks and hard
  links, and answers `eperm` for device nodes, as littlefs's does; F2FS
  keeping links and symlinks is a documented improvement over littlefs in
  the parity corpus. `xattr` answers `enotsup`. A device node, FIFO or
  socket Linux made shows in `readdir` and `getattr` and answers `open`
  with `enotsup`. `read_mode` is `helper`.
* **Nodes and identity.** A node is a nid. A qid's path is the nid in the
  low 32 bits and `i_generation` in the high 32
  ([design-storage.md](design-storage.md#read-write-storage)), unique
  while the domain lives by the generation rule of [Inodes](#inodes), and
  the version is the file's `data_version`, drawn from the domain's
  counter at every change
  ([design-files.md](design-files.md#identity-and-version)).
* **Holds.** `walk` holds the node it answers for the calling grant, in
  the same step, and `forget` and a grant's end release it; an open holds
  its file. An inode that loses its last link becomes an orphan and stays
  one until its freeing ends, which starts when its last hold goes, at
  once if none holds it, so an unlinked open file stays readable and a
  power cut, before the freeing or between its steps, leaves it to
  orphan cleanup ([R 72]).
* **`statfs`** answers the ABI's F2FS type, F2FS's magic `0xF2F52010`
  ([F 9]), block size 4096, the volume's space and its free blocks, and
  the nids free in the NAT.
* **Errors.** `enoent`, `eexist`, `enotempty`, `enotdir`, `eisdir`,
  `enametoolong` past 255 bytes, `efbig`, `emlink` at 2^32 - 1 links,
  `enospc` ([Space](#space-and-the-cleaner), the orphan bound),
  `erofs` on a read-only or frozen volume, `eperm` for a device node,
  `enotsup` as above, and `eio` for a block read that failed or a
  structure that failed its checks, with a log line naming the block.
* **The durability facet.** The storage service's handler of
  `checkpoint` and `freeze`
  ([design-storage.md](design-storage.md#interfaces)) calls the volume's
  `checkpoint(Volume, #{freeze := boolean()})`, which answers `ok` once the
  checkpoint's flush is answered, and an error, with the volume ending, if
  a write or flush failed.
* **The inspector.** The volume publishes its state at the storage
  domain's inspection paths: the committed version and flags, the counts,
  free and prefree segments, `need` and the epoch's charge, the orphans,
  and the last mount's recovery: chain length, records replayed, blocks
  copied, orphans freed and the mount checkpoint's version.

## Reading the medium

**One source for the format.** The format's facts are an ABI spec,
`abi/formats/f2fs.txt`: the layouts of the superblock, the checkpoint
header, the orphan block, the NAT and SIT entries, the summary entry and
footer, the journal entries, the inode's fixed part and extra
attributes, the node footer, the dentry slot record and the xattr
header, and the limits: magic, feature bits, checkpoint flags, inline
flags, node offsets, entries per block, sentinels. The Ruby generator
derives every offset and size from the declared widths and checks the
offsets the spec writes against them, as it does for EROFS
(`abi/formats/erofs.txt`). F2FS's records are packed, so the layout
language gains a **packed wire storage**, beside its `wire_le`, `shared`
and `native` storages (`abi_model.rb` l.567), whose fields may sit at any
byte offset and are read and written only by bit-syntax matching in
Erlang. The alignment check stays as it is for every other storage, so a
layout C reads in place can never be packed. Splitting each misaligned
field into byte-aligned pieces, as the EROFS spec splits one 64-bit nid
into two words, would spread hand-made arithmetic over some forty
fields.

**The codec.** `erx_f2fs_codec` alone turns blocks into records and back.
Each decoder takes one block, checks its length, matches the generated
layout and checks every value it reads against its bounds before
anything uses it. Sequences (NAT entries, SIT entries, summary entries,
orphan numbers, dentry slots, xattr entries) are read through a cursor
over the block, never by computed offsets; a count read from the medium
(`entry_count`, the journals' counts, `name_len`, `i_namelen`,
`i_extra_isize`, `cp_pack_total_block_count`, the bitmap sizes) is checked
against the room it claims before the cursor moves. The codec follows
the rules Linux enforces on reads ([F 26], [F 32], [F 42], [F 60],
[T 92]) and adds the bounds Linux leaves out: the version bitmaps' room,
`i_namelen` against its field, and an inline file's `i_size` against its
inline area whatever else the inode holds. A failed decode is one
module-private `throw` caught at the codec's entry, answered as
`{error, {Structure, Rule}}`.

* **The CRC** is `bnot(erlang:crc32(bnot(Seed), Data))` on 32 bits:
  F2FS's CRC-32 has neither zlib's initial nor its final inversion
  ([F 49]), and `erlang:crc32/2` is the per-byte primitive. Its seed is
  the magic `0xF2F52010` for the superblock and the checkpoint, and for
  the inode checksum the CRC of the volume's UUID from all-ones, continued
  over the footer's `ino`, `i_generation`, and the block with zeros in
  place of the checksum ([F 50]). Open question 1 of part 1, whether
  the kernel's routine is the same as f2fs-tools', is settled by the
  oracle images: the checksums erXos computes over checkpoints and
  inodes the Linux kernel wrote must match theirs.
* **Three bit orders** ([F 5]): the SIT valid maps and the version
  bitmaps are first-bit-most-significant, which is Erlang's own bitstring
  order, and the dentry bitmaps and `nat_bits` are
  first-bit-least-significant. The codec turns every bitmap into a
  bitstring in the first order when it decodes and back when it encodes,
  so the core has one bit order and each field's order is stated once, in
  its codec clause. `s_errors`, set in a host's native order, is read only
  as zero or not zero.
* **Dead checksums.** The orphan block's and the summary footer's
  `check_sum` are neither written nor checked by Linux ([F 26], [F 45],
  [F 52]); erXos writes zero and reads them as nothing.
* **`i_extra_isize`** must be a multiple of 4 between 4 and 36 ([F 41]);
  the checksum is checked when it is at least 12 ([F 50]).

**Fuzz targets** land with the readers, in `tools/fuzz/erx_f2fs.rb`,
running `test/erlang/erx_f2fs_fuzz.erl` on the host's stock OTP, one
entry per reader and one for a whole mount: the superblock, the
checkpoint pack, the NAT block and journal, the SIT block and journal,
the inode with its inline area, the dentry block and inline dentries,
and a mount of a mutated image through the walk and replay. Each entry
starts from blocks of the corpora's images ([Corpora](#corpora):
syzkaller's seeds, Fuchsia's image, the Linux-made corpus and, when
fetched, syzbot's) and of erXos's own, with the
checksums fixed up for most mutations so the checks behind them are
reached, and each must fail every malformed input with an error and
never crash, loop or read past its block. Each has seeded faults, as
`tools/fuzz/erx_erofs.rb` has, which the target must fail with the
failure named for them:

| Reader | Seeded fault |
| --- | --- |
| superblock | the area-boundary rule of [F 14] dropped |
| checkpoint | the bitmap's room check removed |
| NAT | the journal's count bound off by one |
| SIT | the count's comparison with the map's set bits dropped |
| inode | `i_extra_isize`'s multiple-of-4 rule dropped |
| dentry | a long name's run allowed past the last slot |
| mount | the walk's step bound removed |

## Formatting a volume

A mount never formats ([design-storage.md](design-storage.md#read-write-storage)).
`erx_f2fs_format:plan(Geometry, Options)` answers the blocks of a new
volume, every block that must hold given bytes, zeros included, in three
phases each ending in a flush. The installation's medium writer runs it
on the host's stock OTP and places the blocks through `Erx::DataVolume`,
for the data partition and the vault's, turning each flush into a sync
of the medium. It is the same Erlang the guest runs, so the format has
one implementation; F2FS in fsimg would be a second, and would need the
clean room's facts too.

* **Geometry.** Blocks of 4096 bytes, segments of 512, one segment per
  section and per zone; segment 0 at block 512 of the partition, so the
  first 2 MiB hold the two superblocks, as `mkfs.f2fs` places it
  ([T 11]); the checkpoint area 2 segments; the SIT and NAT copies sized
  as [T 12] gives, the SIT bitmap moving to payload blocks when it passes
  3836 bytes ([F 23]); the SSA one block per main segment and one more,
  in whole segments ([F 17]). The reserve: `rsvd_segment_count` 8, and
  overprovisioning of the larger of 16 segments and 2 % of the main
  area, rounded up ([Space](#space-and-the-cleaner));
  `user_block_count` is the main area less the overprovisioned segments.
  These satisfy every check of [F 55] and [T 47-48]. The smallest
  partition the format takes has 20 main segments, so that a volume holds
  at least 8 MiB, as `mkfs.f2fs`'s smallest does ([T 17]): 28 segments
  with the superblocks and the metadata, 56 MiB. The vault's 64 MiB and
  the data partition's 128 MiB at least ([abi/medium.txt](../abi/medium.txt))
  are above it.
* **Contents.** Features `EXTRA_ATTR`, `INODE_CHKSUM` and `SB_CHKSUM`;
  the root directory, nid 3, in the hot node log's first block and its
  dentry block in the hot data log's; NAT block 0 with nids 1 and 2 at
  address 1, as `fsck.f2fs` requires, and nid 3 ([T 26], [T 73]); the
  SIT's first copy with the two used blocks and the six logs' types; the
  first copy of every other SIT and NAT block, zeros; the warm node log's
  first block, zeros ([T 25]); pack 1 an unmount checkpoint with normal
  summaries, and pack 2 zeros, which fails its CRC. The version is an
  odd 31-bit number the caller passes, random for an installation and
  fixed for a test; the UUID and the times likewise.
* **Order.** Phase 1 writes zeros over blocks 0 and 1, so no superblock
  an earlier volume left on the medium survives it; phase 2 writes every
  other block above; phase 3 writes the superblock's second copy and then
  its first. Each phase ends in a flush, so a superblock reaches the
  medium only after everything it describes, and a phase starts only
  when the flush before it is answered. A cut in phase 1 finds nothing
  written but blocks 0 and 1, so an earlier volume mounts as it was if
  the cut left one of its superblock copies whole, and otherwise nothing
  mounts. A cut in phase 2 finds blocks 0 and 1 zeros, so nothing
  mounts. A cut in phase 3 finds the volume complete, and each new copy
  the cut kept whole valid, while a torn or lost copy fails its checksum
  ([F 13]), so nothing mounts or the new volume mounts behind one or two
  copies. An installation cut short runs again in every case. Stale
  blocks of an earlier volume elsewhere on the medium are reached by
  nothing: the second NAT and SIT copies are unselected, both packs are
  written, and the walk ends at the zeroed warm node block.

## Replacing littlefs

The seam is the `erx_fs` callback module and the storage domain's
supervisor: `erx_storage_sup`'s data child changes from `erx_lfs_sup` to
`erx_f2fs_sup`, of the `erx_f2fs` application the storage domain's
release carries, and the
medium writer's `DataVolume` runs F2FS's format plan instead of
`lfs-format`. Nothing above `erx_fs` sees the change, and the mount
shows `f2fs` where it showed `littlefs`. At gate G13, which decides the
replacement ([plan.md](plan.md#m13-erxoss-f2fs)), `erx_lfs`, the littlefs
NIF, `littlefs/`, `tools/host/lfs_format.c` and littlefs's dependency row
are deleted.

Nothing littlefs wrote is converted: an installation creates both
partitions afresh, and an update whose storage formats differ from the
running system's is refused
([design-storage.md](design-storage.md#system-updates)). The design needs
nothing more for the move: no reader of littlefs volumes, no format
marker beyond the superblock's magic, which a littlefs volume does not
carry, so a release with F2FS fails the mount of a littlefs partition as
it fails any partition that holds no volume.

## Failure handling

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| power cut at any point | the next mount | the durable view, whole | the mount's replay and mount checkpoint | every acknowledged `fsync` and checkpoint |
| a block write or flush fails | the window's answer | the durable view; claims and dirty state die with the process | the volume ends, the storage domain with it; the domain service restarts it and the mount recovers | `eio` on pending requests; the domain's death record |
| a block read fails | the window's answer | everything | none | `eio` for the operation; a log line |
| a structure fails its checks while serving | the codec | the volume; the operation changed nothing | none; `FSCK` is set in later checkpoints | `eio` for the operation; a log line naming the block |
| the mount's checks or replay fail | `erx_f2fs_mount` | the medium as it was; nothing written | none on erXos; the partition is repaired with `fsck.f2fs`, or mounted once by Linux, elsewhere | `eintegrity`; the storage domain stays ended after its restarts, never formatted |
| the SIT, the footprint or replay passes the mount's allowance | the mount's admission | the medium as it was; nothing written | none on erXos; the chain is replayed by Linux elsewhere, or the grant is resized | `enomem` and a log line naming the allowance; the storage domain stays ended after its restarts, never formatted |
| another writer's volume leaves its mount checkpoint no room, or has a main area of 16 segments or fewer or more than one segment per section | the mount's room check; the space a volume offers; the cleaner | the medium as it was | none | a read-only mount and a log line naming the shortfall |
| the volume is full | the space check | everything | the cleaner, when invalid blocks can be reclaimed | `enospc` |
| the room rule holds a request back | the step's room check | everything | the cleaner and checkpoints | the request waits; `enospc` only when the space check fails or no victim gains |
| the volume process crashes | its supervisor | the durable view | as for a failed write | as for a failed write |
| a mount reaches 2^32 epochs, the qid paths' bound ([Inodes](#inodes)) | the checkpoint planner | the durable view, just committed | the volume ends after the commit, the storage domain with it, and the restart mounts afresh | as for a failed write |

## Security

A data partition is untrusted input ([design-storage.md](design-storage.md#read-write-storage)):
the codec bounds every read, every count is checked against its room,
the walk and every directory and node-tree traversal are bounded by the
volume's own geometry, never by a value only the image states, and an
iteration over a directory follows its node tree, never its `i_size`, so
a sparse directory of huge size costs only the nodes it has. A crafted
image can make the volume process fail, which ends the storage domain,
can serve wrong data from its own partition or damage it, and nothing
more: Erlang code writes nowhere but its own heap, and the volume reaches
nothing but its own window.

**Resource bounds.** What a mount and a running volume hold is bounded by
the partition, never by the image's claims, and admitted against the
storage domain's memory before it is held: the superblock's geometry
must lie within the window, so the SIT, loaded whole at about 150 bytes a
segment, holds at most one entry per 2 MiB of the window, and the
mount's allowance admits the SIT before it is read, and the footprint
and replay's dirty blocks as they grow ([Mount](#mount)); the node,
dentry and NAT caches are bounded and evict clean blocks no step pins; a
pin lives for one step; and every step needs a bounded number of blocks
([One process owns a volume](#one-process-owns-a-volume)). An image that
fails a check fails the mount with `eintegrity`, and one that passes the
allowance with `enomem`; neither writes anything.

No stale block reaches a client from any state erXos's writes leave
(F2-R4): a data block is read only at an address the state holds, which
holds only addresses whose writes were answered, the touched rule keeps a
block from reuse while any durable view or queued read can reach it, a
record's commit block cannot tear into a stale body, and `NEW_ADDR`
slots, holes and bytes past a file's size read as zeros.

The oracle guest and the distribution guest run Linux and f2fs-tools,
GPL tools, in QEMU without a network device; `fsck.f2fs` reads an orphan
count without bounding it (open question Q7 of part 3), so it only ever
runs there, on images attached read-only, as snapshots, or behind a
device-mapper snapshot. Everything a guest prints is untrusted: the host
parses it with bounded matching and prints it only through the host
terminal's escaping function. Every corpus image is hostile, whatever
its source, and `fsck.f2fs` and Linux see one only in a guest booted for
its batch and discarded after it, never in a guest that checks an
image erXos made ([Hostile images](#hostile-images)); erXos's own
bounded readers take them on the host.

## Verification

F2FS is tested mostly on the development host. The core and the volume
process are Erlang and need nothing of erXos but a window, so they run on
the host's stock OTP over a test window backed by a file: a volume there
has any size the format admits, a sparse file holds a multi-TiB volume in
only the blocks written, and a host runs one volume per core. What the
host cannot give comes from beside it: Linux's F2FS and f2fs-tools, in the
pinned oracle guest, which is the exact-version reference, and in the
distribution guest, which runs them at scale and on other kernels; and
erXos's own block path, in the QEMU suites.

### Testing on the host

**One workload, one listing, every reader.** Every host test is made of
the same three parts, and checks one or more of four expectations,
each stated on its own below: the replies, the listings, the crash rows
and the verdicts.

* A **workload** is a list of operations: the `erx_fs` requests
  ([erx_fs.erl](../erlang/apps/erx_files/src/erx_fs.erl)) that make,
  write, read, `setattr`, rename, link, unlink and `fsync`, and three
  more: `sync`, a checkpoint; `remount`; and, in the power-cut harness,
  `cut`. `erx_f2fs_workload` generates one from a seed, a geometry and a
  profile, as plain Erlang terms. A failure reruns from its seed, and
  the generator shrinks it, dropping operations while the failure stays,
  to a shorter workload that still fails.
* An **interpreter**, `erx_f2fs_workload:run/2`, runs a workload against
  one of three backends: the reference model; erXos's F2FS, through the
  `erx_f2fs` callbacks over the test window; and OTP's `file` module
  over a mounted directory, which reaches Linux's F2FS and `tmpfs` in
  the distribution guest. Each client of a workload is a process of its
  own, which reports each request it sends and each reply it gets to the
  run's recorder, and a workload with concurrent clients is checked by
  the rule for concurrent clients below.
* A **listing**, made by `erx_f2fs_listing`, is the canonical, sorted
  description of a tree, built the same way from every reader: the
  model, erXos's mount read-only or read-write, and Linux's mount with
  recovery or `ro,norecovery`. Each name has its kind, mode, link count,
  link class (the names that share an inode), size, symlink target or
  device numbers, and the SHA-256 of its bytes. A second depth adds the
  owner and the times, which the model does not predict, so only two
  readers of one image are compared on it. Extended attributes are
  compared as bytes, by erXos's codec wherever erXos runs: every inode
  erXos rewrote keeps the inline xattr area and the xattr node of the
  image it read.

The four **expectations** are kept apart, and a test states which it
checks:

* **Replies.** Every operation's reply, its error included, is in the
  set the model answers for it, and the bytes every read returns, through
  a handle held open across an unlink or a rename included, are the
  model's. A refused operation leaves the model unchanged, so every later
  reply and listing checks that it changed nothing in the file system
  either.
* **Listings.** The persistent tree, compared as listings, at every
  `sync`, every `remount` and at the end.
* **Crash rows.** The trees a cut may leave, from the model's durable
  state, below, and the rows of
  [The crash states as the oracle](#the-crash-states-as-the-oracle).
* **Verdicts.** How a reader admits an image, mounted read-write,
  mounted read-only or refused with the rule named, and `fsck.f2fs`'s
  result; each reader's verdict is its own observation, and one never
  stands in for another ([Corpora](#corpora)).

An image under test comes from one of five **sources**, and each source
names the expectations it is checked against and the readers that check
it; a new reader or source is a row of this table:

| Source | Expectations | Readers |
| --- | --- | --- |
| a workload run on erXos | the replies; the model's listing at every `sync`, `remount` and at the end; `fsck.f2fs`'s pass rule | erXos read-only and read-write; Linux with recovery and `ro,norecovery`; `fsck.f2fs` |
| a cut of such a run | its crash row; `fsck.f2fs`'s pass rule | the same |
| a workload run on Linux | the replies; the model's listing, and Linux's own listing of the image | erXos read-only, then read-write, then Linux again |
| a corpus image | the verdicts and listings of [Corpora](#corpora) | erXos on the host; `fsck.f2fs` and Linux in a hostile-image guest ([Hostile images](#hostile-images)) |
| a mutation of any of them | erXos's verdict, never a crash ([Reading the medium](#reading-the-medium)) | erXos on the host; a sample to `fsck.f2fs` and Linux in a hostile-image guest |

**The test window.** `erx_f2fs_test_window` answers the window's three
requests, `{read, Sector, Count}`, `{write, Sector, Bytes}` and `flush`,
one at a time and in order, as `erx_blk_window` does, over one of two
backings: a map of blocks, for the small volumes the harness cuts, or a
file read and written with `file:pread/3` and `file:pwrite/3` and flushed
with `file:datasync/1`, for any size. Recording every write and flush,
which the power-cut harness needs, is an option of the same module, so
every host test reaches the volume through one window.

**The reference model.** `erx_f2fs_model` is a pure module that knows
file semantics and nothing of F2FS: inodes with their bytes as a sparse
map, their modes and links, and directories as maps from names to
inodes. Each operation answers its result and the next model; where
POSIX allows more than one error, the model answers the set. For
durability it keeps three things, which are what the crash rows read:

* **the durable tree** D: the tree at the last checkpoint erXos
  committed. A `sync` is one checkpoint, but the volume runs others on
  its own: at an `fsync` a record cannot express, at the epoch's bound,
  for the cleaner and on its timer
  ([What is durable when](#what-is-durable-when)). The erXos backend reads the committed version the volume publishes
  ([The interface](#the-interface)) after every reply, and when it has
  risen, D becomes the model's tree at that point. A checkpoint starts
  with no mutation in flight and holds those that arrive until it
  commits ([Checkpoints](#checkpoints)), so that tree is exactly the
  checkpoint's;
* **the current tree** T, every answered operation applied;
* **the `fsync` states**: for each `fsync` of a file since D, requested
  or answered, the file as it was then, its bytes, size, mode and each
  of its names, and whether it was answered.

A state after a cut must equal a **base**, D or T, with each file that
has `fsync` states since D either as D holds it or as one of those
states, and with the latest answered one or a later one for every file
whose `fsync` was answered. The base is chosen by the checkpoint erXos's
mount of the state reports: D's version means D, the next version means
T, the checkpoint the cut caught after its last block (C5, C6), whose
tree is T because it held every mutation that arrived while it ran; any
other version fails. On base T no `fsync` state applies, since an
`fsync` that arrives during a checkpoint is planned after it. The
`fsync` states carry names, so `sync; rename(a, b); fsync(b); cut` must
leave `b`: a volume that wrote that `fsync` as a record would replay the
file under `a`, which no allowed state holds.

For space it keeps a lower bound on the blocks its tree occupies: the
data blocks, one inode block for each of its inodes, and the direct
nodes each file's mapped ranges need. `enospc` is a pass only when that bound is within the profile's stated
margin of the volume's space
([The space a volume offers](#the-space-a-volume-offers)); earlier, it
fails the test, and after an `enospc` the model is unchanged. The model
is checked as any oracle is: the distribution guest runs every profile
over Linux's F2FS and over `tmpfs`, at the small volumes' byte budgets,
and their replies and listings must equal the model's; a difference is
a model bug, a documented Linux difference with a test, or a Linux bug.

**Geometries.** A geometry is chosen for what it reaches, and there are
two kinds:

* **small volumes**, which a profile may fill: erXos's own format at
  56 MiB, the smallest it takes, and at 128 MiB, the data partition's
  least;
* **large sparse volumes**, which reach the format's address and
  metadata boundaries and are never filled: 64 GiB; the smallest size
  whose SIT version bitmap passes the checkpoint header's 3836 bytes and
  moves to payload blocks ([F 23]), and one segment below it; the
  largest size the format plan admits; and one beyond the mount's
  allowance, which checks the `enomem` refusal.

The format plan computes each exact size, so the list states sizes by
what they reach, not by number. The payload size is a few TiB: one bit
per SIT block of a copy ([F 23]) and 55 entries a SIT block ([F 55])
give a little over 3 TiB, where [T 13] says about twice that, 6.4 TiB;
the plan's computation, checked by the mount and by Linux, settles it.
A large volume costs the host the blocks written and the SIT the mount
holds, about 150 bytes a segment, and the test sets the mount's
allowance to admit it. Every profile has a byte budget, the same at
every geometry, so the backing file and the model's bytes stay as small
on a large volume as on a small one; the near-full profile runs only on
small volumes, where filling is what is tested.

Linux-made volumes come from `mkfs.f2fs` with a feature set chosen for
the code it reaches. The inode layout is where features meet in erXos's
code ([Inodes](#inodes)), so the sets are those that give each layout:
no feature, the default ([T 6]); `EXTRA_ATTR` alone, and with each
feature that raises `i_extra_isize`, `PRJQUOTA` to 8 bytes,
`INODE_CHKSUM` to 12 and `INODE_CRTIME` to 24 ([T 9]);
`FLEXIBLE_INLINE_XATTR`, which sets the inline xattr size ([F 48]); and
the set erXos formats with, `EXTRA_ATTR`, `INODE_CHKSUM` and
`SB_CHKSUM`, with and without `LOST_FOUND`. Beside these, `QUOTA_INO`
alone, whose quota inodes lie outside the tree, and every R feature
together. Each set is made at 128 MiB
and at 64 GiB; the default also at 44 and 49 MiB, which erXos mounts
read-only, and at 50 MiB; and each other option that changes what the
volume holds, as part 3 of the facts records lists them (segments per
section, which erXos mounts read-only; heap allocation; the
cold-file extension list; the volume name; the overprovisioning), once
at 128 MiB with the default features. On the host, the Linux-made
volumes are the fetched corpora's and the oracle guest's
([Corpora](#corpora)); the distribution guest makes and reads its own
inside itself ([The distribution guest](#the-distribution-guest)).

**The matrix is sampled.** A cell is a geometry, a profile and, for a
Linux-made volume, a feature set. Each runner first runs every cell of
its list once, with one seed, and then spends what is left of its budget
on more seeds of cells drawn by the batch's seed. Its report gives each
cell's seeds and run time, so the budgets are set from what the runs
measure; a budget that ends before every cell ran once reports the rest
as not run, which fails the gate, never passes it. The budgets of
[Where each test runs](#where-each-test-runs) are limits the runners
enforce, not measurements.

**Profiles.** A profile weights the generator:

* **general**: every operation, sizes and offsets of every alignment;
* **one file**: random reads, writes, truncates and extensions of one
  file, its bytes checked after every operation, which is the method of
  `fsx` ([POSIX suites](#posix-suites));
* **boundaries**: sizes and offsets at each edge of the node tree, a
  block, the inode's own addresses, a direct node, an indirect node and
  the double indirect node ([Inodes](#inodes));
* **one bucket**: names that erXos's dentry hash puts in one bucket, so
  lookups past a full bucket and a directory's growth by levels are
  reached, and long names of up to 255 bytes;
* **near full**: filling to the margin, deleting every other file and
  rewriting, so the cleaner meets fragmented segments and `enospc` meets
  its bound;
* **chains**: many `fsync`s between checkpoints, for the harness and
  for Linux's replay of erXos's records.

**Concurrent clients.** Clients of a generated workload work on
disjoint subtrees, but they share the volume: its free space, its logs,
its checkpoints and its cleaner. Which client meets `enospc`, which
`fsync`s join one record and where a checkpoint falls depend on the
schedule, so a concurrent run is checked by a rule that holds under any
schedule, not by exact replay. Each client's subtree is its own, so its
replies, its reads and the listings of its subtree at its `sync`s and
at the end follow its own sequence of operations, which the model runs
alone. The generator gives each client a share of the volume's space
and keeps the client within it, so no concurrent run reaches the
margin, and an `enospc` there fails it. What the schedule decides is
checked by what does not depend on it: the image's counters against a
recount, `fsck.f2fs`'s pass rule and Linux's listing. Crash states need
the model's durable tree, which a schedule makes ambiguous, so the
harness's generated workloads are sequential, and its concurrent
`fsync`s are fixed workloads whose expectations say what each order may
give.

**The trace.** Every run records its trace: the seed, geometry and
profile; the SHA-256 of the image it started from; every request with
its client and each reply, in the order the recorder received them; the
committed version after each reply of a sequential run; and, in the
harness, the recorded writes and flushes and each state's selection of
them. A sequential run is reproduced from its seed and its starting
image, the timer's checkpoints aside, which a rerun from the trace
places as `sync`s where the trace shows them. A
concurrent run's failure is rerun from its trace as a sequential
workload, one request at a time in the recorded reply order; if it fails
there it shrinks as any sequential failure does, and if not it is
reported as schedule-dependent, with its trace.

### The crash states as the oracle

Each crash state of part 2 becomes a row erXos must meet, in its own
mount and in Linux's of the same image, and the power-cut harness checks
every state it makes against the row it belongs to. "CP N" is the last
committed checkpoint; "its chain" is the records written since.

| State | Cut during or after | erXos's mount | Linux's mount of the same image | Rests on |
| --- | --- | --- | --- | --- |
| [C 1] | writes, no `fsync` or checkpoint | CP N with its chain: a write lands only on a free block, and every block freed since CP N, across records too, stays touched | the same | the touched rule |
| [C 2] | a checkpoint's node and dentry writes | as C1 | the same | the touched rule |
| [C 3] | a checkpoint's NAT, SIT and SSA writes | as C1: the new NAT and SIT copies unselected, and no SSA block the durable view reads written | the same | shadow copies ([R 20]); the summary rule |
| [C 4] | the new pack before its last block | CP N with its chain: the last block's version does not match | the same | [R 14] |
| [C 5] | the checkpoint's last block | absent or torn: CP N with its chain; whole: CP N+1, everything before it durable | the same | ordering 2 |
| [C 6] | after the last block, before its flush is answered | either checkpoint, each whole: no block or nid freed since CP N was reused | the same | ordering 3; the touched and nid rules |
| [C 7] | a record before its second flush is answered | earlier records replayed; this one whole or not at all: its commit block is its pre-image, which ends the walk, or the whole block | the same: the walk ends at a `cp_ver` mismatch ([R 51], [T 57]), and no torn commit block with a matching footer exists, which the torn-record probes check | ordering 4; sector atomicity |
| [C 8] | after a record's `fsync` returned | the record replayed, then the mount checkpoint | the record replayed, then Linux's recovery checkpoint ([R 63]) | orderings 1 and 2 |
| [C 9] | as C8, for a file created in the epoch | its entry recreated from `i_name` and `i_pino` | the same | the dentry mark; its parent was in CP N |
| [C 10] | data not durable before its marked dnode | cannot arise from erXos's writes: every data block a record names was answered and flushed before its commit block | an image Linux wrote can hold it; erXos replays it as Linux does and shows the same block | orderings 1 and 2 |
| [C 11] | an in-place data update | cannot arise from erXos's writes: no data is written in place | a Linux image can show new or torn bytes in CP N's view; erXos reads them as Linux does | no in-place writes |
| [C 12] | a checkpoint covering data in flight | cannot arise from erXos's writes: no slot holds an address before its write is answered, and erXos writes no `NEW_ADDR` | in a Linux image `NEW_ADDR` reads zeros and other slots their old contents, in erXos as in Linux | ordering 1 |
| [C 13] | replay at mount | nothing written; the next mount replays the same | the same | replay is pure |
| [C 14] | the mount checkpoint | before its commit: CP N with the whole chain, recovered the same way again; after it: CP N+1 with no chain | before the commit the image mounts at CP N with its chain: the mount checkpoint wrote nothing the walk read, no SSA block the old view reads, and its node blocks past the chain's end | the footprint; the summary rule; the copies |
| [C 15] | orphans listed in CP N | freed at mount, before replay | the same | [R 75] |
| [C 16] | an orphan's freeing before the next checkpoint | freed again from CP N's state, whose blocks and nid stayed touched | the same | the touched and nid rules |
| [C 17] | an unlink not yet checkpointed | the file back, with its records | the same | the touched and nid rules |
| [C 18] | a superblock write | cannot arise after the format; a cut format leaves the earlier volume as it was, no valid copy, or the complete new volume | an image whose superblock Linux rewrote keeps one copy whole ([R 13]); erXos takes the first valid one | the format's order |
| [C 19] | both packs damaged | the mount refused, nothing written | refused | [R 16] |
| [C 20] | a mount with records present and roll-forward disabled | no such mount: a read-only mount replays in memory and writes nothing, so it shows the records ([Read-only mounts](#read-only-mounts)) | Linux refuses `norecovery` read-write and mounts CP N alone with `ro,norecovery` ([R 67]), which the oracle uses to check erXos's checkpoints without their chains | - |

Two cut points of erXos's own complete the rows:

| Cut during or after | erXos's mount | Linux's mount of the same image |
| --- | --- | --- |
| the cleaner's moves before a checkpoint | CP N with its chain; the victim's old copies intact, prefree until a checkpoint commits | the same |
| the format | in phase 1, the earlier volume as it was or no valid superblock; in phase 2, no valid superblock; in phase 3, no valid superblock or the complete empty volume | the same |

Walked against the construction, every row holds: C1-C9 and C13-C19 hold
in erXos's mount and in Linux's of the same image; C10-C12 cannot arise
from erXos's writes and are Linux's own results for images Linux wrote,
which the oracle guest's edited images check
([The Linux oracle guest](#the-linux-oracle-guest));
C14 is stronger than Linux's own recovery, which a cut may cost records
([R 65]); and C20 is the mount-policy difference of
[Read-only mounts](#read-only-mounts).

### The power-cut harness

The harness runs the core and the volume process on the host's stock OTP
over the test window with recording on, and, for each prefix of a
workload's requests, makes the states a cut can leave: every write
answered before the last answered flush kept, and each later write kept,
lost or torn at a sector boundary, which covers every order in which the
medium may complete them. It enumerates every subset
of the unflushed writes kept, up to ten of them, and each such state with
one kept write torn at each of its sector boundaries, and samples beyond
ten. Each state is mounted by the core, read-only and then read-write,
and checked against the reference model's crash rule
([Testing on the host](#testing-on-the-host)): the tree is a base with
`fsync` states, every answered `fsync` among them, and since every
allowed tree is made of states the model reached, every block of every
file holds bytes some write put there or zeros where none did (F2-R4);
the counters equal a recount; a second mount after the
read-write mount's checkpoint gives the same tree; and a cut during that
mount checkpoint gives the same tree again (C14). Workloads cover
creates, writes of every size and alignment, truncates to and from
partial blocks, large truncates and unlinks of large files with
checkpoints between their steps, each file extended after the restart
by `setattr` and by a write past a gap, renames, links, unlinks of open
files, `fsync` of new and
old files, concurrent `fsync`s, overwrites of checkpointed files beside
`fsync`s of others, directory growth past several levels, a volume filled
until the cleaner runs, and mounts of Linux-made images with chains,
those whose replay copies blocks included. Beside these fixed workloads,
the harness takes the generator's, under the chains and general profiles
at the small geometries. A state is made from the recorded writes and a
selection of them, so the record and the selection reproduce a failing
state whatever schedule made the writes.

| Test | Seeded fault the harness must catch |
| --- | --- |
| a record replays whole or not at all | marking every dnode of a record instead of the last |
| no record's dnode durable before its data | the first flush of a record dropped |
| a torn commit block never replays | the pre-image left out, so the commit block is written over the block's old contents |
| a record releases nothing | freed blocks and nids returned to the pool at a record's second flush |
| a cut during the mount checkpoint loses nothing | the warm node log resumed at the chain's start |
| a cut during the mount checkpoint replays the same again | a replayed block in a segment valid at the checkpoint adopted, and its SSA block rewritten |
| a cut after a large truncate's checkpointed step, then an extension, reads zeros | the size raise without its truncate |
| no stale block after a cut | an address installed before its write is answered |
| freed blocks stay until the commit is durable | prefree segments freed at the last block's write, before its flush |
| no stale chain after a crash and a mount | the mount checkpoint skipped when nothing was replayed |
| a rename made durable by an `fsync` survives a cut, over generated workloads | the record decision's rename fact ignored, which a generated workload reaches when it renames before an `fsync`: the record replays the file under its old name, which no state the model allows holds |

The distribution guest runs the harness itself and checks its states in
`fsck.f2fs` and in Linux's mount, every state of the fixed workloads and
a sample of the generated ones. The host's harness writes a sample of
its own states, every row of the table above at least, as image files,
which the pinned oracle guest attaches read-only.

### The Linux oracle guest

The guest is built from pinned packages, as the deleted EROFS guest was
(`tools/lib/erx/linux_guest.rb` before `6574015d`): a kernel with
`f2fs.ko`, f2fs-tools 1.16.0 with its libraries, and busybox, run under
QEMU without a network device, with a deadline and its serial log. Its
kernel is Linux v7.3.4 with 4 KiB pages, the version the facts records
read, pinned exactly: a distribution package built from v7.3.4 if one
exists, which is unverified (Ubuntu 26.04's kernel is 7.0.0, by the probe
of [The distribution guest](#the-distribution-guest)), and otherwise
kernel.org's v7.3.4 release at
its pinned SHA-256, built out of the tree by the guest's documented build
step with a pinned configuration. Another kernel would need a baseline
of its own, with the facts re-checked by probes beyond the mount checks
listed here. One boot checks many images, attached read-only or as
snapshots, so Linux's writes never reach the image under test.

**erXos to Linux.** For each image erXos writes (a fresh format, every
workload's end state and the harness's sampled states): `fsck.f2fs
--dry-run`, with standard input giving "n" to every prompt ([T 40]); the
check passes only with exit status 0 and no line beginning `[ASSERT]`,
`[FIX]` or `[Fail]`, no line beginning `[FSCK] fixing` ([T 75]) and no `Reconnect` line, since `fsck.f2fs` repairs
some faults silently in check mode and exits 0 ([T 41]); then a mount
with recovery and a listing (names, modes, links, sizes, SHA-256 of
every file) that must equal erXos's own replayed tree; then a
`ro,norecovery` mount whose listing must equal erXos's checkpoint tree;
and `fsck.f2fs -l`, whose superblock and checkpoint fields must equal
erXos's decode ([T 79]). Each is its own observation and each must
hold, since `fsck.f2fs` and Linux accept different things ([T 89] to
[T 92]): an image `fsck.f2fs` passes and Linux lists otherwise fails,
and so does one Linux lists equal and `fsck.f2fs` faults. One image more: a file erXos wrote whole,
truncated to one byte and checkpointed, which Linux extends to a block
and must read as zeros past the first byte.

**Linux to erXos.** The guest formats scratch disks with `mkfs.f2fs`
(default options, which set no feature at all [T 6], `-O
extra_attr,inode_checksum,sb_checksum`, and each read-only feature alone
and with the others; 50 MiB and more, and one disk of 44 MiB, which
erXos must mount read-only), copies in a tree the host declares (inline and
block files and directories, sparse files reaching the double indirect
node, hard links, symlinks of both forms, device nodes and FIFOs,
directories several hash levels deep, files with inline xattrs beside
inline data), and unmounts; erXos must read the tree back equal. Then the
guest writes and `fsync`s, and is killed, on every image, those with
read-only features included: erXos's replay of Linux's chain must give
the tree Linux's own remount of a copy gives. Then erXos writes to each
writable image and Linux checks it as above, so every image travels both
ways. The images are made on demand and cached in the build tree, keyed
by the pins and the tree's declaration, never committed.

**Probes.** Each settles a fact the design rests on, on the pinned
kernel, and fails the suite when the fact changes:

* **torn records**: an erXos image whose chain ends at a pre-image, and
  the same image with the commit block whole, mount in Linux with the
  record left out and replayed, and pass `fsck.f2fs`; a Linux image whose
  last marked inode block has one stale sector before its footer records
  how Linux treats a chain inode whose checksum fails (open question 4 of
  part 2), and erXos's mount of the same image is pinned against it as
  [The walk](#the-walk) says;
* **checkpoints disabled**: an image Linux leaves with checkpointing
  disabled, killed mid-write, which erXos refuses read-write and
  read-only;
* **a directory level**: a Linux image whose inline directory is edited
  on the host to `i_dir_level` 2, which erXos converts by a create and
  which `fsck.f2fs` then passes, bucket positions included ([T 65]);
* **a stale tail**: a Linux image whose file holds non-zero bytes past
  its size in its last block, which erXos extends, by `setattr` and by a
  write past a gap, and reads as zeros;
* **nodes past a size**: an erXos image cut after a checkpoint between a
  large truncate's steps, whose file Linux then extends past the nodes
  still mapped, recording whether Linux reads zeros there
  ([Operations](#operations), [Risks](#risks));
* **feature dependencies**: a superblock with `INODE_CHKSUM` and without
  `EXTRA_ATTR`, which erXos refuses;
* **Linux's unflushed data** (C10 to C12): states no cut of erXos's
  writes leaves, made by editing a Linux image with a chain on the host
  through erXos's codec: a data block a marked dnode of the chain names
  overwritten with other bytes, as if its write never landed (C10); a
  data block of CP N's view with its first sectors overwritten, a torn
  update in place (C11); and a slot of a checkpointed direct node set to
  `NEW_ADDR` (C12). Data blocks and direct nodes carry no checksum, so
  each edit leaves the image otherwise as Linux wrote it, and erXos's
  read-only mount of each must list what Linux's mount of it lists.

The guest is the reference: F2-R1 and F2-R2 name v7.3.4, so where the
distribution guest's kernel and this one disagree, this one's result
decides whether erXos is at fault.

### The distribution guest

The distribution guest runs Linux's F2FS and f2fs-tools at scale, with
many CPUs and large sparse disks, over a distribution's own kernel. It is
needed because the host has neither, and because f2fs-tools is GPL, so
it runs only as a black box inside a Linux guest. That Homebrew has no
f2fs-tools formula and that Apple's container kernel is built without
F2FS are unverified: no probe record checks them.

**What is known of it.** A probe on 2026-11-14 (record
`~/erxos-scratch/notes/probe-f2fs-host-2026-11-14/README.md`, SHA-256
`e999749a0ec64c7226df1d525602af5639ea4ada400d843bc0d32fef194b4a4f`,
with its logs beside it) booted Ubuntu 26.04.1 LTS's arm64 cloud image
of release 20260927 (SHA-256
`63a93bd5a8d76e33b15ceb5daa3657bd79be804748051ab178e643b0f5da22e7`)
under Lima's VZ driver: its kernel, 7.0.0-34-generic, has F2FS as a
loadable module; f2fs-tools 1.16.0-2build1, the oracle guest's version,
is a package in `universe`; `mkfs.f2fs`, a loop mount, writes,
`fsck.f2fs --dry-run` and `fsck.f2fs -l` all ran; and the device-mapper
targets `snapshot`, `flakey` and `log-writes` load. Booting the same
image under the harness's QEMU with UEFI firmware is unverified.

**One runner for both guests.** The distribution guest is the oracle
guest's runner with another root disk: QEMU under HVF, without a network
device, with a deadline and its serial log, killed when it stops
answering. Its root disk is the cloud image provisioned once by the fetch
step, the only boot with a network: the image by its SHA-256, f2fs-tools
and the build tools by package version, each package's SHA-256 recorded
in `deps.lock`, stock OTP 29.1.2 built from the oracle's pinned
archive, and xfstests' `replay-log`, built from a pinned commit at its
SHA-256; both are built inside the guest, never on the host, and
nobody reads `replay-log`'s source. A run boots a snapshot of the
provisioned disk and fetches nothing.

**Everything runs inside.** The guest runs erXos's F2FS too, on that
OTP over the test window, and the harness and the generator with it, so
an image is written, checked and read back without leaving the guest.
Its one input is a read-only disk the host makes with fsimg, an EROFS
image of the compiled modules, the seeds and the tree declarations; its
one output is the serial log, which carries verdicts, the differing
entries of two listings and the traces of the runs that failed. Its
images never leave it: the host's Linux-made volumes are the fetched
corpora's and the oracle guest's ([Corpora](#corpora)), and a batch
that fails keeps its snapshot, so a later boot of that snapshot finds
the failing images where the log names them. The images live as
sparse files on the guest's own disk, and Linux mounts each through a
device-mapper snapshot over a read-only loop device, so a mount with
recovery writes into the snapshot's own store, never into the image
erXos or the comparison reads. One worker runs per CPU, each with its own
loop and snapshot devices, and each case, an `fsck.f2fs`, a mount and its
listing, has a deadline; a case that passes it is reported timed out,
never passed.

**What a batch runs.**

* **erXos to Linux**: the erXos images of the matrix's cells
  ([Testing on the host](#testing-on-the-host)), and the harness's
  states, through the oracle guest's checks
  ([The Linux oracle guest](#the-linux-oracle-guest)): `fsck.f2fs
  --dry-run` under its pass rule, a mount with recovery whose listing
  equals erXos's replayed tree, an `ro,norecovery` mount whose listing
  equals erXos's checkpoint tree, and `fsck.f2fs -l` against erXos's
  decode.
* **Linux to erXos**: `mkfs.f2fs` with each feature set at its
  geometries ([Testing on the host](#testing-on-the-host)); then Linux
  runs the matrix's workloads through the `file` backend, growing inline
  files and directories past their inline forms, filling the small
  volumes and churning them until Linux's own cleaner runs, and ending
  with
  `fsync`s and a cut, a device-mapper target that drops every write after
  a chosen point (`flakey`; its exact use is settled by probe), so the
  image carries a chain. erXos reads each image read-only and must list
  what Linux lists of a copy; then, where every feature is in W, writes a
  workload into it read-write, and Linux's listing of the result must
  equal the model's. Device nodes and FIFOs, which erXos's `make`
  refuses ([The interface](#the-interface)), come only from the tree the
  oracle guest's declaration copies in; OTP's `file` module makes
  neither, so the guest makes them with `mknod` and `mkfifo`, started
  with an argument vector.
* **The model's own check**: every profile over Linux's F2FS and
  `tmpfs`, at the small volumes' byte budgets.

**Linux's own cuts**, on demand: `log-writes` records the order of
Linux's writes and flushes under a workload, and xfstests' `replay-log`,
pinned and run only inside the guest as a black box, replays the log
onto a snapshot up to a chosen entry. erXos's read-only mount of each
replayed state must list what Linux's mount of the same state lists. A
replay keeps every write before its entry and none after, in the order
the log holds them, so it gives the states a cut of Linux's writes in
that order leaves; it never reorders or tears a write, so it produces no
C10 or C11 state, which the oracle guest's edited images cover instead.
The run names no crash row it reached: its report gives, for each state,
the checkpoint erXos's mount chose and the records it replayed, as the
volume publishes them. erXos has no reader of the log's format.

**Kernels.** A guest row is an image pin, its kernel's version string and
its f2fs-tools package, recorded with every result. Ubuntu 26.04 is the
first row; other distributions whose kernels carry F2FS and that package
f2fs-tools become rows when a probe shows they do. A case that passes on
one kernel and fails on another is reported as a kernel difference, with
both kernels named, and only the pinned guest's result counts against
erXos.

### Hostile images

Every image that neither erXos's own writes nor a guest's own Linux
made, from a declared tree or a workload, is hostile, whatever its
source: syzkaller's seeds, whose trees nobody has verified, Fuchsia's
image and its copy with two bits cleared, syzbot's images, the mutants
of differential fuzzing, and any image derived from one of them,
syzkaller's writable seeds after erXos wrote into them included. A
pinned SHA-256 says which bytes an image is, not that they are safe to
hand a kernel. So `fsck.f2fs` and Linux see a hostile image only in a
**hostile-image guest**: the distribution guest's runner and root disk,
or the oracle guest's, booted for one batch from a fresh snapshot,
given the batch's images as read-only disks, and discarded after it.
Its results are observations of those images alone, kept in the
corpus results: a kernel or `fsck.f2fs` a crafted image subverts can
falsify only its own batch's observations, and never runs in a guest
that certifies an erXos-made image. The guests that check erXos's own
images and the images their own Linux makes boot only from snapshots
no hostile image has reached.

erXos's own parsers meet hostile images on the host, as they are built
to: the codec's bounded decoders, the mount and the fuzz targets run on
the host's stock OTP, under their deadlines and the mount's allowance
([Reading the medium](#reading-the-medium)).

### Corpora

Each corpus is a source in `deps.lock`, fetched by the fetch step into
the build tree by URL and checked by SHA-256, and none is committed. The
two that are redistributable are megabytes of binary images the fetch
step provides just as well. The probe record above lists every hash. A
test whose corpus the fetch step has not provided fails, naming the
source, and never passes by skipping it. The exception is syzbot's
images: their license is unknown, so they are fetched only on an explicit
request into the build tree, by pinned URL and SHA-256, never as a
prerequisite of `make check` or of any gate, and never committed,
redistributed or attached to a report, nor is any image derived from one,
a minimized one included. A test that uses them runs only when they were
fetched.

| Corpus | Pin | License | What it holds |
| --- | --- | --- | --- |
| syzkaller's F2FS seeds | `sys/linux/test/syz_mount_image_f2fs_0` to `_15` and `fscrypt_f2fs`, syzkaller commit `819ebe34df0f1cb61a2c97ced41d03285824b6c1`; each test program embeds its image as `$` and base64 of zlib, which the corpus reader decodes, the decoded image's SHA-256 pinned beside the program's | Apache-2.0, the repository's | 17 images that `mkfs.f2fs` made, 64 and 128 MiB, with `-e cold`, `-a 0` and `-a 1`, `-s 1` and `-s 2`, and features none, `encrypt`, `extra_attr`, or `extra_attr` with `flexible_inline_xattr`, `inode_checksum`, `inode_crtime` and `project_quota`; their trees are syzkaller's, unverified |
| Fuchsia's f2fs_reader image | `src/storage/f2fs_reader/testdata/f2fs.img.zst` at the Fuchsia commit of [Context](#what-erxos-matches), 16,947,630 bytes | BSD-2-Clause, the repository's `LICENSE`; the directory has no license of its own | a 256 MiB image that `scripts/mk_test_img.sh` (BSD) made on Linux with `-O encrypt,verity`: a tree with an inline file, short and 300-byte symlinks, a hard link, a file owned by 999:999, a directory of 2001 entries and one of 2001 made and 2000 removed, a sparse file reaching the double indirect node with xattrs, and encrypted and verity subtrees |
| syzbot's F2FS images | the disk images of syzbot's F2FS reports, each by pinned URL and SHA-256 in a fetch manifest; only the image, never the report's C reproducer | unknown: fetched only on explicit request, never committed or redistributed | images that crashed or hung Linux |
| the Linux-made corpus | made by the oracle guest and cached in the build tree ([The Linux oracle guest](#the-linux-oracle-guest)); the distribution guest's images stay inside it | erXos's | the oracle guest's feature sets, sizes and declared trees, clean and with chains |

Janus, the file-system fuzzer, ships no F2FS seed image at its commit
`58d9e85df86068f9532f28f45a7e2041b32a165c` (its tree holds a fuzzer and
copies of Linux and f2fs-tools, which are GPL and not opened), and no
curated corpus of damaged F2FS images was found.

**Verdicts.** Each corpus image gives three observations, kept apart in
its result, since no one of them stands in for another:

* **`fsck.f2fs`'s**, in a hostile-image guest: its pass rule met, the
  fault lines it printed, or timed out;
* **Linux's**, in the same guest: a mount with recovery, through a
  snapshot, that succeeded with its listing or failed with its log line,
  or timed out, or a kernel that stopped;
* **erXos's**, on the host: read-write, read-only, or refused with the
  rule named, and its listing when it mounts.

`fsck.f2fs` and Linux disagree in both directions ([T 89] to [T 92]):
`fsck.f2fs` passes an `i_extra_isize` up to 3692 that Linux, and erXos's
codec, refuse, and fails the inode checksum of an inode whose
`i_extra_isize` stops short of the field, which Linux reads. So
`fsck.f2fs`'s result decides nothing about erXos's and excuses nothing;
it is recorded beside the others, and a disagreement between it and
Linux is recorded as such. erXos's expectations come from its own rules
and from Linux's mount:

| Case | erXos must |
| --- | --- |
| every image | finish its mount within its deadline, without a crash, a loop or an allocation past its allowance, and write nothing when it refuses or mounts read-only |
| any image | admit it as its own rules say: read-write when every feature is in W, read-only when every one is in R, and otherwise refused naming the bits ([Scope](#scope-features-and-forms)), or refused with `eintegrity` naming a structure and a rule of the codec ([Reading the medium](#reading-the-medium)) |
| Linux mounts it and erXos refuses it | name a rule Linux does not apply: a feature or flag outside R or W, a geometry rule of Scope, or one of the bounds the codec adds to Linux's; any other refusal is a bug until explained |
| Linux refuses it and erXos mounts it | a bug until explained: a read rule of Linux's the codec lacks, which is fixed, or a documented difference with a test |
| both mount it | list what Linux lists, entry by entry; an entry may differ only where erXos answers it with an error naming a structure and a rule, on the terms of a refusal above, and then only that entry and what lies beneath it; every other difference fails, whatever `fsck.f2fs` reports |
| Linux times out or its kernel stops | the first two rows alone; the image is recorded as a Linux finding |

**The fixed corpora's expectations.** syzkaller's seeds without features
or with `extra_attr` alone mount read-write, and take the profiles'
workloads on the host as Linux-made volumes; those with the R features
mount read-only; those with `encrypt`, and `fscrypt_f2fs`, are refused
naming `ENCRYPT`; and the `-s 2` seeds mount read-only with a log line naming the two
segments per section ([The cleaner](#the-cleaner)). Fuchsia's image is refused
naming `ENCRYPT` and `VERITY`; a copy with those two bits cleared, its
superblock checksum fixed if it has one, mounts read-only, and the
subtrees the script made without encryption or verity must list as the
script describes them, which a hand-written listing in the test states.
That check is in the landing slice, and reaches, in an image Linux
wrote, inline data, a large directory with and without its removed
entries, a file with xattrs and the double indirect node.

**Differential fuzzing**, on demand: the fuzz targets' mutants that
erXos mounts go in batches to a hostile-image guest, and each is judged
by the verdicts above.

### POSIX suites

pjdfstest (BSD-2-Clause, in FreeBSD's `contrib/pjdfstest` at commit
`b352368bfbe85aa73840c4b8d161bcffbc242ca3`) checks file-system semantics
through system calls, with FreeBSD's expected results written in each
test. It runs inside erXos, under QEMU, through the POSIX layer, over
`/data` on F2FS and on littlefs, so its results are part of F2-R7's
parity: a failure on both belongs to the POSIX layer or `erx_fs`, one on
F2FS alone to F2FS. It does not run on the host, which has no mount of
erXos's F2FS: a bridge into the host's kernel would be a new mechanism
(see [Alternatives considered](#alternatives-considered)), and the
interpreter already reaches `erx_fs` directly.

`fsx` is not used. FreeBSD's `tools/regression/fsx/fsx.c`, at the same
commit, is under the Apple Public Source License 2.0, not BSD; its
method, random reads, writes and truncates checked against a copy of the
file in memory, is the one-file profile. xfstests and LTP are GPL and
would test only Linux's F2FS.

### Where each test runs

Each test's seeded faults run as those of the EROFS fuzz target do
([tools/fuzz/erx_erofs.rb](../tools/fuzz/erx_erofs.rb)): each is
applied to a copy of the source, and the run must fail with the failure
named for it. A run with a seeded fault stops at its first failure, so a
seed costs little when the check works, and a seed that survives its
whole budget fails the run. The budgets below are limits the runners
enforce, set when they are built and adjusted to what they measure, not
measurements; the host slice's time is measured at every run, and the
slice is cut back when it passes its budget.

The deep runs have no gate of their own: the host runs, the
distribution guest's batch, the oracle guest and the fixed corpora's
hostile-image batch are part of `make check-oracle`, at the milestone
gate, as OTP's suites and `libc-test` are, and `make check-f2fs` runs
them alone, as a focused entry point.

| Test | What it catches | Where | Budget | Seeded fault |
| --- | --- | --- | --- | --- |
| the host slice: the model at 56 MiB and 128 MiB and over syzkaller's writable seeds, a few seeds of each profile; the harness's fixed workloads with up to four unflushed writes; erXos's verdicts of the fixed corpora and Fuchsia's listing | wrong replies, bytes, names, links and sizes; counters off a recount; an early `enospc`; a wrong verdict | `make check`, every landing | 30 s together | a write that spans a direct node's edge maps its second part one slot off; `ENCRYPT` put in R |
| the host runs: every geometry, every profile, many seeds; the harness with up to ten unflushed writes and generated workloads | what the slice catches, at sizes and ages the slice never reaches | `make check-oracle`, the milestone gate, on the host in the background | 2 h | the SIT version bitmap kept in the header past its 3836 bytes, which only the multi-TiB geometry reaches; the space counting the overprovisioned segments twice, which only the near-full profile reaches; the harness's table |
| the fuzz targets, seeded from every corpus | a crash, loop or overread on a malformed block or image | `make check-fuzz`, the milestone gate | its configured budgets | the table of [Reading the medium](#reading-the-medium) |
| the distribution guest's batch | an erXos image Linux or `fsck.f2fs` rejects or reads otherwise; a Linux image erXos reads otherwise; a wrong model | `make check-oracle`, the milestone gate, on a host whose QEMU runs the guest; elsewhere reported unsupported, never passed | 3 h | `i_ext` set at a file's first write to the extent of its blocks and never updated, under a workload that then rewrites part of that range: Linux seeds its extent cache from `i_ext` ([F 44]) and its listing hashes the old bytes there, and `fsck.f2fs` finds the extent disagreeing with the address array ([T 61]); the NAT journal's entries ignored at mount, which only Linux-made images reach; the model allowing a rename onto a non-empty directory |
| the pinned oracle guest | a difference from v7.3.4 exactly | `make check-oracle`, the milestone gate, and on demand | 1 h | its probes, each failing when its fact changes |
| the fixed corpora in a hostile-image guest: syzkaller's seeds, Fuchsia's image and the images derived from them, through `fsck.f2fs` and Linux | an erXos verdict or listing the rules of [Corpora](#corpora) refuse | `make check-oracle`, the milestone gate | 30 min | an erXos error on one entry allowed to excuse a difference on another |
| syzbot's images and differential fuzzing, in a hostile-image guest | a crash on an image that crashed Linux; a listing that differs from Linux's on a mutant both mount | on demand | 1 h | the walk's `cp_ver` comparison dropped |
| other kernels | kernel differences | on demand | as the batch | the batch's |
| Linux's own cuts | a Linux crash state erXos reads otherwise | on demand | 1 h | the walk dropping a chain's last record |
| pjdfstest over F2FS and littlefs | POSIX semantics broken on F2FS alone | the QEMU suite, on demand and at the milestone gate | 20 min | an unlink that leaves the inode's link count unchanged |
| power cuts under QEMU | the block path's ordering | the QEMU suite | as the suite | the block device suite's own |

### Power cuts under QEMU

The block device suite's power cut ([tools/lib/erx/block_device.rb](../tools/lib/erx/block_device.rb))
runs over F2FS: a boot writes and `fsync`s files under `/data` on a
scripted load and prints each `fsync`'s return; the harness kills QEMU at
a chosen line, boots again, and checks that every file whose `fsync`
returned is whole; then the image goes to the oracle guest. Cuts land
before, between and after records, during a checkpoint, and during the
mount checkpoint, by killing QEMU on the mount's log line. A kill of
QEMU keeps what the host's page cache holds, so these runs check the
whole path through the block driver and its flush, and the harness above
checks the reorderings.

### Unit and property tests

Each pairs a passing case with a seeded fault that must fail it:

| Test | Seeded fault |
| --- | --- |
| the dentry hash of names of 0 to 255 bytes, against the hashes in the oracle images | the length word built from the chunk's own length instead of the bytes left |
| the inode checksum against Linux-made inodes | the footer left out of the checksum |
| the CRC against Linux-made superblocks and checkpoints | zlib's inversions kept |
| the inode layout for every E and X of [F 48]'s table, and a flexible inline xattr size | the reserved word before inline data dropped |
| the record decision over every combination of the epoch's facts | the rename fact ignored |
| a pre-image differs from its commit block only in `cp_ver` and matches under none of the three rules | the low 32 bits of `cp_ver` left unchanged |
| `set_slot` keeps one owner per block and the counters | the stale owner not cleared |
| replay leaves every node it touched dirty and no chain node block live | a replayed dnode adopted at its chain address |
| an inline directory with `i_dir_level` 2 converts with every entry in its hash's bucket | the level kept at conversion |
| truncating to one byte and extending reads zeros | the kept block's tail left as it was |
| a `setattr` raise and a write past a gap, over a Linux-made file with a stale tail and a file whose truncate left nodes past its size, read zeros | the truncate to the old size skipped for writes past a gap |
| a large file unlinked and checkpointed between its freeing steps is an orphan in that checkpoint, and a mount frees the rest | the inode dropped from the orphans when its last hold goes |
| a new inode at a reused nid gets a new qid path, the freed inode Linux-made with the generation the epoch would give | the generation taken from the epoch alone |
| a volume one checkpoint below its bound of 2^32 epochs ends after that commit, before admitting a request | the bound removed |
| the mount refuses each refused checkpoint flag and each missing dependency | `DISABLED` accepted |
| the format plan passes the mount checks at sizes from 56 MiB to 64 GiB, and every cut the harness makes of it leaves the earlier volume, no valid superblock or the complete volume | the superblocks written in the second phase |
| `mkfs.f2fs`'s geometries of 44 MiB and 49 MiB mount read-only and of 50 MiB read-write | the main-area bound removed |
| after every commit, the mount checkpoint's included, each valid block's summary, where the new durable view reads it, names its owner, replay's adopted blocks in segments no log enters included | SSA blocks written only for the segments a log left |
| a SIT, a footprint or a replay past the mount's allowance fails the mount with `enomem`, writing nothing | the footprint left out of the allowance |
| a read-only mount writes nothing, over a window that fails every write | a read-only mount that writes its mount checkpoint |
| the walk on a looped chain fails within its bound | the bound removed |
| at every format size, filling to the space and churning keeps `need` covered and the cleaner freeing segments, the fragmented pattern measured | victims restricted to full segments |
| repeated mounts of a busy volume keep the room rule | the mount checkpoint moving every log to a free segment |

## Performance

What to measure, with `tools/erx bench fs` on QEMU under HVF against
littlefs, and on the Pi 4's SD card at M12; each suspected cost is on the
watch list ([todo-performance.md](todo-performance.md)):

* `fsync` latency: two flushes and one block written twice per record,
  against Linux's one preflush and FUA write;
* small writes without a buffer: a write of less than a block rewrites
  the whole block out of place, so a stream of short appends rewrites its
  last block each time;
* the volume process carries every block request and its answer, at 4 KiB
  per request on virtio;
* checkpoint cost: whole NAT and SIT blocks for every changed entry, with
  no journals, a checkpoint per timer tick while anything is dirty, and a
  checkpoint whenever the epoch's charge reaches its 512 blocks;
* mount time: the whole SIT, the current node segments' footers when the
  pack has no node summaries, the walk, orphan cleanup, the mount
  checkpoint's rewrite of every replayed node, and the copies a Linux
  chain can need;
* the cleaner's overhead at high utilisation with greedy choice alone,
  and the overprovisioning;
* memory: the SIT, about 150 bytes a segment, 4.6 MiB for 64 GiB, the
  caches' bounds and the freed generations.

## Alternatives considered

* **Every `fsync` a checkpoint** (the research record's proposal).
  Simpler, but against the requirement that erXos writes roll-forward
  records, and a checkpoint per `fsync` writes NAT, SIT and a pack each
  time.
* **Linux's default `fsync`**, every dnode marked and one flush. Rejected:
  a reordering medium can make a dnode durable before its data
  ([R 48]), and a partly durable record replays partly; the atomic form
  with a flush before the commit block costs one more flush and removes
  both.
* **The inode checksum as the commit block's check**, records allowed
  only on volumes with `INODE_CHKSUM`. Rejected: a tear that keeps the
  new footer over a stale body fails the checksum in erXos, but how Linux
  and `fsck.f2fs` treat that block is unknown, and an end there could
  cost Linux earlier records; the pre-image makes every reader see a
  whole block, for one more block write.
* **Recovery that writes as it replays, as Linux's does after replay,**
  or that adopts the chain's node blocks and rewrites SSA blocks in place,
  as Linux's recovery checkpoint does ([R 58], [R 63]). Rejected: a cut
  then destroys what the next mount needs, the chain or the old owners'
  summaries; rewriting replayed nodes, and copying the rare data block
  whose summary the old checkpoint still needs, makes a cut during
  recovery harmless.
* **Every log moved to a free segment at the mount checkpoint.**
  Rejected: the touched rule already keeps the mount checkpoint off the
  chain, and six moves per mount would strand part-written segments and
  take the free segments the cleaner and later checkpoints need.
* **A mount mode without roll-forward**, as `norecovery`. Rejected: a
  read-only mount that replays in memory writes nothing either, and shows
  the acknowledged `fsync`s; one mount path serves both, a trial's
  included ([Read-only mounts](#read-only-mounts)).
* **Redistributing a converted inline directory's entries over the
  buckets its `i_dir_level` gives.** Rejected for setting the level to 0:
  entries keep their slots, so `readdir` offsets survive the conversion.
* **Read helpers that read the window themselves.** Rejected: a read
  issued by another process can reach the window after a write that
  reused its block; with the volume as the only client, the window's order
  is the volume's.
* **A cleaner process.** Rejected: its every action is the volume's
  state and the volume's I/O, so it would be a loop asking the volume to
  clean.
* **Journals and compact summaries in erXos's checkpoints.** They save a
  few block writes per checkpoint and add a second place every entry may
  live; left for a measurement to ask for.
* **Writing inline data and dentries.** A space saving for small files
  with no consumer, and a second form for every writer path.
* **A write buffer per file** in the volume. Left for the measurement of
  small writes; it would hold acknowledged data in memory until a
  checkpoint or `fsync`, which every flush path would then drain.
* **A volatile-cache disk model under QEMU**, a host process serving the
  disk that drops unflushed writes at a cut. The host harness explores
  the same reorderings exhaustively over the same code, and whether
  virtio's flush reaches the medium is the block driver's test.
* **A Lima VM as the distribution guest.** Lima runs the same cloud image
  with less setup of our own (it makes the cloud-init seed and shares
  directories), but it keeps a network link up for its own agent and
  moves images through its own directory sharing. The oracle guest's
  QEMU runner already gives disks, snapshots, deadlines and no network
  device; the probe used Lima only to learn what the image holds.
* **A bridge from the host's kernel to erXos's F2FS**, a FUSE layer on
  macOS, so POSIX suites run on the host. A new mechanism whose consumer
  is pjdfstest alone, which runs inside erXos instead; the interpreter
  reaches `erx_fs` without one, and the Mac's FUSE layer is a separate
  item of [TODO.md](../TODO.md) for the namespace mount.
* **A reader of `log-writes`' log format**, so the harness enumerates
  subsets of Linux's writes as it does its own. Only Linux's GPL source
  and documentation state the format, so it would need a facts record
  of its own; `replay-log`'s prefixes, run as a black box in the guest,
  and the oracle guest's edited images cover the rows without one.
* **Host and guest splitting the batch**, erXos writing images on the
  host and the guest checking them. Every image would cross into the
  guest as a disk, and Linux's back out as one; running erXos's F2FS
  inside the guest leaves one input disk and the serial log.

## Stages

M13 brings F2FS on QEMU as 1b-H ([plan.md](plan.md#m13-erxoss-f2fs)),
in stages that each end in tests of their own:

1. **The format's facts and the reader**: `abi/formats/f2fs.txt` and the
   layout language's packed wire storage, `erx_f2fs_codec` with its fuzz
   targets, the corpora's fetch, the listing, and the oracle guest making
   Linux images.
2. **Read-only mounts**, with the walk and replay in memory, of every
   Linux image the guest makes and every corpus image, clean and with
   chains, each read-only feature with chains included; erXos's trees
   equal Linux's.
3. **The format and read-write mounts with checkpoints**: every
   namespace and data operation, the room rule, the mount checkpoint with
   its copies, orphans; the test window, the model and the generator over
   every geometry; the distribution guest; every image passes `fsck.f2fs`
   and Linux lists it equal.
4. **`fsync` records and the power-cut harness**, with every crash state
   checked in erXos and in the guests, and the probes.
5. **The cleaner**, under churn to high utilisation at every format size.
6. **Parity and the switch**: the file-semantics corpus and pjdfstest
   against littlefs and Linux, gate G13, then the seam's change and
   littlefs's deletion.

The estimate is about 8,000 lines of Erlang, 2,000 of Ruby and 5,000 of
tests.

## Risks

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| A fact in the records is wrong, or differs on the guest's kernel | medium | an image Linux rejects or misreads | every image both ways through the oracle; probes for each open question of the records the design rests on |
| A Linux chain shape the records do not describe | low | a replay that fails the mount | the mount fails safely; the oracle's dirty Linux images exercise replay |
| Linux, extending a file, reads the nodes a cut left mapped past its size | low | after a cut between a large truncate's steps, the file's old bytes in Linux's extension of it | the nodes-past-a-size probe settles it; if Linux reads them, a large truncate frees from the file's end and lowers the size at each step, so no checkpoint commits a slot past a size |
| A medium that tears within a sector | low | a torn commit block or superblock | the storage design's sector assumption; recorded with the block driver's residual |
| SD cards that ignore flushes | medium | any ordering lost on the Pi | recorded with the block driver's residual; the Pi's half of G13 measures it |
| Two flushes and a pre-image per `fsync` too slow | medium | commit latency at G13 | the measurement decides; group commit across waiting `fsync`s and a forced-unit-access write are the fixes on the table |
| A fragmented volume whose cleaner cannot gain | low | `enospc` before the volume is full | the property tests measure it at every format size; the overprovisioning is the knob |
| The clean room is challenged | low | high | facts only through separate writers; implementers read only this document, the records and permissive sources; a legal review before any distribution, as [design-storage.md](design-storage.md#read-write-storage) requires |
| The reference model is wrong, so the host tests pass a wrong result | medium | a bug every host test agrees on | the model is checked against Linux's F2FS and `tmpfs` over every profile; the guests compare erXos with Linux without the model |
| A distribution kernel's F2FS differs from v7.3.4 | medium | a difference reported as erXos's | every result names its kernel; only the pinned guest's result counts against erXos |

## References

* The F2FS facts records, parts 1 to 3, and the research record
  `~/erxos-scratch/notes/research-f2fs.md` (2026-11-14, SHA-256
  `5a2d7523ec6459ffaeaaca8712b5b2c213c1e0fe56c6181ae9f2d6050a536d21`),
  with their sources' versions and hashes.
* Fuchsia `src/storage/f2fs_reader`, commit
  `6478165d12ab3164d09b3e81551ff692427b5038`: `superblock.rs`,
  `checkpoint.rs`, `README.md`, `testdata/f2fs.img.zst`,
  `scripts/mk_test_img.sh`, and the repository's `LICENSE`.
* The host-testing probe record,
  `~/erxos-scratch/notes/probe-f2fs-host-2026-11-14/README.md`
  (2026-11-14, SHA-256
  `e999749a0ec64c7226df1d525602af5639ea4ada400d843bc0d32fef194b4a4f`),
  with the Ubuntu image, kernel and package versions, the corpora's
  hashes and the license headers read.
* syzkaller, commit `819ebe34df0f1cb61a2c97ced41d03285824b6c1`:
  `sys/linux/test/syz_mount_image_f2fs_*`, `fscrypt_f2fs`, `LICENSE`.
* FreeBSD, commit `b352368bfbe85aa73840c4b8d161bcffbc242ca3`:
  `contrib/pjdfstest/LICENSE` and the header of
  `tools/regression/fsx/fsx.c`.
* Lee, Sim, Hwang, Cho, "F2FS: A New File System for Flash Storage",
  FAST '15, the model the format serves.
* [design-storage.md](design-storage.md), [design-files.md](design-files.md),
  [design-system.md](design-system.md#shutting-down),
  [plan.md](plan.md#m13-erxoss-f2fs).
