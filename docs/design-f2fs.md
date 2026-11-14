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
it is applied, durability and recovery, the cleaner, the interface, the
parsers and their fuzz targets, and the oracles and power-cut tests that
check it all against Linux.
Storage as a whole, the block driver and the partitions are
[design-storage.md](design-storage.md); the file protocol and the
`erx_fs` behaviour are [design-files.md](design-files.md); the ordered
end that freezes storage is [design-system.md](design-system.md#shutting-down).

Decisions every reader of this document needs:

* **The durable view is never overwritten.** At any moment the medium
  holds one *durable view*: the last committed checkpoint and the
  roll-forward chain after it, which is exactly what a mount would
  rebuild. The one allocator never hands out a block that the durable
  view references or that has been live since the last commit, and only
  a commit changes the durable view. Every crash state the facts records
  list follows from this rule and from where the commits sit
  ([The construction](#the-construction)).
* **One process owns a volume, and every decision is a pure step.** The
  volume process holds the volume's state as one value, and every
  request is one step of a pure function from the state to the next
  state and a plan of block writes and flushes. A checkpoint and an
  `fsync` record are each one plan, built and validated whole before a
  block is written. The volume process is the window's only client, so
  the block service's in-order answers order every read and write.
* **A chain never spans a mount.** Recovery is a pure replay in memory.
  A read-only mount serves the replayed state and writes nothing; a
  read-write mount commits it with a checkpoint whose logs start in
  fresh segments, before it admits a single write, so nothing written
  after a mount can join or overwrite the chain it replayed.
* **Linux's format, erXos's rules.** The bytes are Linux v7.3.4's
  format, from the facts records of the clean room. Which features erXos
  reads and writes, when an `fsync` is a record and when a checkpoint,
  and what a mount refuses are erXos's own rules, each stated here with
  its consumer.
* **One representation per kind.** erXos writes regular files and
  directories as blocks, never inline, writes no journals in its
  checkpoints, no compact summaries, no NAT bits, no inline xattrs, no
  in-place updates and no threaded logging. It reads every form Linux
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
* [The cleaner](#the-cleaner)
* [Space accounting and quotas](#space-accounting-and-quotas)
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
* [Open decisions](#open-decisions)
* [Risks](#risks)
* [References](#references)

## Context

### What erXos matches

The behaviour matched is Linux v7.3.4's F2FS driver and f2fs-tools
1.16.0's `mkfs.f2fs` and `fsck.f2fs`, for 4096-byte blocks. Linux ties
the F2FS block size to its page size, and f2fs-tools supports only 4 KiB
blocks ([F 2], [T 85]), so a 4 KiB block is the whole of what any
4 KiB-page Linux mounts. The owner's requirements are that F2FS is the
main file system with tier 1 support, that it supports the Linux format
with full Linux compatibility, roll-forward records written and replayed
included, and that its format facts come only from the sources below.

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
`max_sectors`, 8 sectors on virtio: one 4 KiB block.

No F2FS code exists in the tree. The ABI's layout language cannot state
F2FS's records yet: it refuses a field whose offset is not a multiple of
its size (`tools/lib/erx/abi_model.rb` l.698-705), and F2FS's records are
packed, with a 64-bit `block_count` at offset 36 of the superblock and
32-bit fields at odd offsets in NAT entries, summary entries and dentry
slots ([F 1]).

## Requirements

* **F2-R1.** Every image erXos writes, and every state a power cut can
  leave, passes `fsck.f2fs` and mounts in Linux v7.3.4 at the state erXos
  promised: the last completed checkpoint with every acknowledged `fsync`.
* **F2-R2.** erXos mounts read-write any image Linux v7.3.4 or
  `mkfs.f2fs` 1.16.0 writes with a feature set erXos implements, and
  replays Linux's roll-forward records as Linux would.
* **F2-R3.** An acknowledged `fsync` survives a power cut at any later
  point, including a cut while a mount recovers it.
* **F2-R4.** No file ever shows bytes that were never written to it, after
  any cut: no stale block of another file, no torn metadata accepted.
* **F2-R5.** A read-only mount writes nothing, so a trial boot leaves
  the partition byte for byte as it was.
* **F2-R6.** A crafted image costs at most its own partition and the
  process that parses it: every structure is decoded with checked bounds,
  and every reader has a fuzz target.
* **F2-R7.** Parity with littlefs over the file-semantics corpus, every
  difference a bug fixed, a documented improvement with a test, or a bug
  in littlefs recorded as such.
* **F2-R8.** The volume keeps its own space reserve, so the cleaner can
  always make room, and a full volume answers `enospc` rather than failing.

Non-goals: encryption, compression, casefolding, verity, zoned and
multi-device volumes, block sizes other than 4 KiB, and serving extended
attributes; each is refused or answered as [Scope](#scope-features-and-forms)
says. Converting littlefs volumes is a non-goal too
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
| `INODE_CHKSUM` | W, set at format | detects a corrupt or torn inode block; the commit point of an `fsync` record needs it ([fsync](#fsync)) |
| `SB_CHKSUM` | W, set at format | detects a corrupt superblock copy, so mount takes the other instead of a wrong geometry |
| `LOST_FOUND` | W, not set at format | a directory with no rule a writer must keep; `fsck.f2fs` reconnects unreachable files into it, which on erXos's own volumes would hide an erXos bug from the oracle ([T 76]) |
| `INODE_CRTIME`, `FLEXIBLE_INLINE_XATTR`, `QUOTA_INO`, `PRJQUOTA` | R only | a reader decodes nothing new: the creation time and project id are fields it ignores, the inline xattr size is one input of the inode layout, and quota files are inodes outside the tree. A writer would have to maintain them, so the volume mounts read-only ([Open decisions](#open-decisions), 5) |
| `ENCRYPT`, `COMPRESSION`, `ATOMIC_WRITE` | refused, even read-only | decided in [design-storage.md](design-storage.md#read-write-storage); TODO.md keeps encryption and compression as items |
| `VERITY`, `CASEFOLD` | refused | read-only verified content is EROFS under `erx_verity`; UNIX names are case-sensitive |
| `BLKZONED`, a device list, `DEVICE_ALIAS`, `PACKED_SSA`, `RO` | refused | no zoned or multi-device media; layouts not studied |
| any other bit | refused | unknown |

Beyond the feature word, a mount refuses a block size other than 4096
bytes, a segment other than 512 blocks ([F 3]), and a checkpoint with
`LARGE_NAT_BITMAP` ([F 24]), which only `mkfs.f2fs -i` makes and nothing
needs. A checkpoint with `CP_ERROR` is refused, as Linux refuses it
([F 55]). A volume marked as needing a check (`CP_FSCK` in the
checkpoint, or a non-zero `s_errors` or stop-reason count in the
superblock, [F 12]) mounts as Linux mounts it ([F 56]), with the mark
kept in every checkpoint erXos writes and shown by the inspector: erXos
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
| logging | appending (LFS) only | threaded (SSR) logs' summaries too | appending is correct on its own; a mount moves every log to a fresh segment ([Mount](#read-write-mounts-the-mount-checkpoint)) |
| in-place data updates | never | nothing to read: they leave ordinary blocks | an overwritten block can tear and is visible before any commit ([R 46], [C 11]) |
| superblock | written once, by the format | either valid copy | no run-time superblock write, so no torn superblock and no host-dependent `s_errors` bit order ([F 5]) |
| discards | none | - | the block service has no discard request |
| six logs | hot, warm and cold for nodes and data, by kind | any placement | Linux requires six distinct current segments ([F 55]); the fsync chain must be the warm node log ([R 49]) |

Placement by kind: a directory's dentry blocks go to hot data, a
regular file's data and a symlink's target to warm data, blocks the
cleaner moves to cold data; a directory's direct nodes to hot node, every
other direct node, inode and xattr node to warm node, and indirect nodes
to cold node ([R 30]). Which data log a block lands in matters to no
reader.

## The construction

### The durable view is never overwritten

A power cut returns the volume to what a mount rebuilds from the medium:
the newest valid checkpoint pack, the NAT and SIT copies its version
bitmaps select, and the roll-forward chain that starts at its warm node
log's next block ([R 14-24], [R 49-51]). Call that the **durable view**.
Every main-area block is in one of four states:

* **live**: referenced by the volume's current state, the in-memory SIT
  marking it valid;
* **touched**: live at the last commit, or allocated since it;
* **claimed**: allocated by an operation in flight, not yet live;
* **free**: none of these.

The allocator returns only free blocks. A block that stops being live
stays touched until the next commit, and a commit resets the touched set
to the live set of the state it committed. Every block of the durable
view is live or touched: the checkpoint's blocks were live at the commit,
and every chain block was allocated after it. So **no write ever lands on
a block the durable view references**, and the durable view changes only
at a commit: a checkpoint's last block, or an `fsync` record's marked
inode block. Linux keeps the same rule for blocks within a segment, with
a second valid map per segment ([R 38-39]); erXos makes it the
allocator's only rule, and holds it in two more places:

* at mount, the touched set is the checkpoint's live set **and every
  block the chain walk read**, which Linux's allocator does not know; and
* node ids follow the same rule: a nid whose NAT entry is cleared returns
  to the free pool only at the next commit, as on the path the records
  traced in Linux ([R 25]; whether Linux has another is their open
  question 6).

Three orderings complete the construction, each the plan's to keep, not
a caller's:

1. **An address enters the state only after its block's write is
   answered.** So a block the state references holds what was written to
   it, once the next flush is answered.
2. **A commit block is written only after a flush answered after every
   write it covers.** A checkpoint's last block and a record's marked
   inode block each follow such a flush, and a flush follows each of
   them before the commit is reported. A durable commit block therefore
   implies every block it references is durable and whole.
3. **A block freed before a commit is free only after that commit's
   flush is answered.** Until then the old durable view may still be the
   one on the medium.

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
cache, pinned, and runs the step again from the start against the state
as it is then. The core therefore never waits and never sees a partial
read, and a step is a pure function of its arguments that the host tests
call with every block it needs.

### A chain never spans a mount

A mount replays the chain in memory, through the same core operations a
running volume uses ([Replay](#replay)). A read-only mount stops there and
serves the replayed state. A read-write mount commits the replayed state
with one checkpoint, the **mount checkpoint**, before it admits any
write, and that checkpoint starts every log in a fresh segment: one with
no block live, touched or read by the walk. So:

* a cut during the mount checkpoint leaves the old checkpoint and the
  whole chain exactly as the mount read them, and the next mount recovers
  the same state again (Linux's warm node log resumes at the chain's first
  block, which its recovery checkpoint can overwrite before it commits, so
  a cut there may lose fsynced data in Linux: [R 65], open question 1 of
  part 2);
* every block written after the mount carries the new checkpoint's
  version, so no stale block left by an earlier crash, an unreplayed
  dnode of an inode that never reached the chain, say, can ever be linked
  into a later chain and replayed against a reused nid.

### What disappears

Under these three rules the following need no mechanism of their own:

* the recovery checkpoint's exposure ([R 65], [C 14]): the mount
  checkpoint writes nothing the walk read;
* stale chains on a reused medium or after a crash: after a mount every
  stale block carries an older version than the epoch's, and before the
  first mount the format zeroes the warm node log's first block, as
  `mkfs.f2fs` does ([T 25]);
* a dnode durable before its data ([R 48], [C 10]) and a checkpoint
  covering data still in flight ([R 11], [C 12]): orderings 1 and 2;
* torn in-place data ([C 11]): erXos writes no block in place but the
  checkpoint packs, which alternate, and SSA blocks, which it rewrites
  only for segments whose summary the committed checkpoint does not take
  from the SSA ([Summaries](#segment-summaries));
* a nid reused while a chain still names it: the nid rule above;
* a checkpoint that straddles operations: a checkpoint starts only when
  no mutation is in flight, and mutations that arrive meanwhile wait
  ([Checkpoints](#checkpoints)).

## Processes and ownership

Each volume is an `erx_f2fs_sup` supervisor in the storage domain, under
the domain's supervisor, with two kinds of process:

* **The volume process**, `erx_f2fs_volume`, owns everything: the
  geometry, the committed checkpoint, the NAT and SIT state, the node and
  dentry block cache, the dirty blocks, the six logs, the touched and
  claimed sets, the free nid pool, the orphan set, the epoch's facts
  (below), the holds grants place on nodes, and the outstanding block
  requests with the steps waiting on them. It is the data window's only
  client, it runs the checkpoint timer, and it runs the cleaner as steps
  of its own between requests ([The cleaner](#the-cleaner)). It never
  makes a synchronous call after its start.
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
| `erx_f2fs_core` | the volume state and every operation on it: lookup, create, write, truncate, link, unlink, rename, setattr, readdir, holds; the allocator and the one slot-setting function |
| `erx_f2fs_plan` | the checkpoint plan and the `fsync` record plan, and the decision between them |
| `erx_f2fs_clean` | victim choice and the move step |
| `erx_f2fs_format` | the format plan of a new volume |

### The volume state

The state is one record that `erx_f2fs_core` alone constructs:

* **geometry**, from the superblock: area addresses and segment counts,
  the NAT capacity, the feature word and whether the mount writes;
* **the committed checkpoint**: its version and CRC, flags, the pack it
  sits in, the version bitmaps, and the counts it recorded;
* **the SIT**, whole: per main segment its type, its valid map as a
  bitstring, its touched map, and its age ([F 37]); loaded at mount,
  since allocation and cleaning read every segment;
* **the NAT**, by block: the NAT blocks read so far, cached, and every
  entry changed since the commit, dirty, each `{Ino, Addr, Version}`
  ([F 33]); a NAT block is fetched when a lookup needs it;
* **nodes and dentry blocks**: a cache of clean blocks, bounded, and the
  dirty ones, which stay until a plan writes them; a dirty node or dentry
  block has no address until then;
* **the six logs**: each a segment and the next offset in it; the log
  knows its next block after every allocation, moving to a fresh segment
  when its segment fills, because each node footer names that next block
  ([R 35]);
* **the touched and claimed sets**, and **the free nid pool**: nids whose
  committed NAT entry is empty and that no step has taken since the
  commit ([R 25]);
* **the orphans**: inodes with no link that a hold keeps;
* **the epoch's facts**: per inode, what happened to it since the commit
  (created, recorded, renamed or linked, a node freed), which decide
  whether an `fsync` can be a record;
* **the counters** `valid_block_count`, `valid_node_count` and
  `valid_inode_count`, changed only by the one slot-setting function and
  the one NAT-setting function, and checked against a recount by a
  property test; `free_segment_count` is never kept but computed from the
  SIT a plan writes.

### Allocation

`allocate(State, Log, N)` returns N free blocks of a log, in order, and
the state with them claimed; it fails with `enospc` before changing
anything when the volume cannot take them ([Space](#space-accounting-and-quotas)).
A fresh segment is one whose blocks are all free. A log appends within
its segment, and an appending log's next block and every block after it
in the segment are free, which Linux and `fsck.f2fs` require of a
checkpoint's logs ([F 39], [T 75]).

Every change of a block reference goes through one function,
`set_slot(State, Owner, Index, Address)`, where the owner is a dnode or an
inode's address array and the address one of `NULL_ADDR`, `NEW_ADDR` or
a real address ([F 4]). It clears the old address's valid bit, sets the
new one's, moves the new block from claimed to live, records the new
block's summary entry ([F 46]), adjusts `valid_block_count` by the
slots' weights (a real address or `NEW_ADDR` counts one, `NULL_ADDR`
none; [T 61], [T 75]) and adjusts the inode's `i_blocks`. A real address
that another slot holds, as the block's summary names it and that slot
confirms, is first cleared from that slot, so a block never has two
owners; only replaying a Linux chain meets that case ([R 57]). Writes,
truncates, the cleaner's moves and replay all call it, so the invariants
it keeps are kept everywhere. Node addresses change only
through `set_node(State, Nid, Ino, Address)`, which keeps the NAT entry,
bumps its version when a node is freed ([F 33]) and adjusts the node and
inode counts.

### Inodes

One function, `layout(Volume, InodeBlock)`, answers an inode's
geometry: E, the extra attribute words, from `i_extra_isize` when the
inode has `EXTRA_ATTR`; X, the inline xattr words, from
`i_inline_xattr_size` when the volume has `FLEXIBLE_INLINE_XATTR`, else
50 when the inode has `INLINE_XATTR` or `INLINE_DENTRY`, else 0; and from
them the address array, 923 - E - X words, and the inline area ([F 41],
[F 48]). Every reader and writer of an inode asks it. erXos keeps E and
X of an existing inode unchanged, and gives a new inode E = 3
(`i_extra_isize` 12) on a volume with `INODE_CHKSUM`, E = 1 with
`EXTRA_ATTR` alone and E = 0 without, as `mkfs.f2fs` does ([F 41]), and
X = 0.

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
them. A new inode's `i_generation` is the low 32 bits of the epoch's
checkpoint version; a nid is reused only in a later epoch, so two inodes
erXos makes at one nid never share it.

File blocks map through the address array, two direct nodes, two
indirect and one double indirect node, with the node offsets of [F 53].
A regular file holds at most 920 + 2 x 1018 + 2 x 1018^2 + 1018^3
blocks with E = 3 and X = 0, 4,329,690,873,856 bytes; a write past that
answers `efbig`.

### Directories

Names hash with the TEA directory hash of [F 57], "." and ".." to 0,
and directories are the multi-level hash table of [F 58]: a lookup
searches levels 0 to `i_current_depth` - 1, in each only the blocks of
the name's bucket; an insertion takes the first level whose bucket has a
run of free slots and grows the depth when it opens a level. A new
directory is one dentry block holding "." and ".." in slots 0 and 1,
`i_size` 4096, `i_current_depth` 1 and two links, as the format's root
is ([T 22-23]). A long name takes consecutive slots, with every slot's
bitmap bit set and the following records' `name_len` 0 ([F 60]). An
empty dentry block stays allocated; `i_size` covers the highest block in
use.

A Linux inline directory converts to a block directory in the step that
first changes it: inline slot k becomes slot k of block 0, which is the
one bucket of level 0, so every entry keeps its slot and a `readdir`
offset stays valid across the conversion. An inline regular file or
symlink converts the same way: its bytes become block 0. A readdir
offset is the slot's position, block index times 214 plus the slot, so
entries never move.

Dentry blocks are file blocks of the directory, held dirty in the volume
and written by the next checkpoint, as Linux does ([R 1]).

### Operations

Every operation is one step that validates its whole effect before it
changes anything. The namespace operations (create, mkdir, symlink, link,
unlink, rmdir, rename, setattr) change only dirty nodes and dentry
blocks in memory, and become durable at the next checkpoint. A rename is
one step, so a checkpoint sees it whole or not at all.

**A write** is two steps around its I/O. The first computes the blocks
the write covers, needs the old contents of a partial first or last
block, claims new blocks in the warm data log, and answers a plan that
writes the merged blocks. When every write is answered, the second
installs them with `set_slot`, grows `i_size` and sets the times; if the
volume broke meanwhile the claims die with the state. A truncate frees
slots and nodes through the same functions, with no I/O but the fetch of
the nodes it walks.

**A read** is a lookup step that answers the block addresses of the range
(holes and `NEW_ADDR` read as zeros, [C 12]) and the volume reads them;
the helper's call returns the bytes. The read's addresses come from the
state at its step, and the touched rule keeps them unreused while the read
is queued at the window behind no write to them.

### Segment summaries

Each segment's summary block lives in the SSA at `ssa_blkaddr` plus its
number ([F 45]). For a current data log the summary is in the state and
goes into each checkpoint pack; for a segment a log has left, the
checkpoint after the log left it writes its SSA block. A current node
log's summary goes into the pack only at an unmount checkpoint, as
Linux's rule is, and otherwise a mount rebuilds it from the footers of the
segment's blocks ([F 31], [R 23]). An SSA block is rewritten in place,
and that is safe because only two kinds of segment have their SSA block
written: a segment a log entered fresh, which holds nothing the
committed checkpoint references, and a segment that was a current log
of the committed checkpoint, whose summary a mount takes from the pack
or the footers, never from the SSA. The one reader that can meet a
summary newer than the durable view, replay's stale-owner check,
confirms every owner a summary names against the dnode itself before
acting ([Replay](#replay)).

## Durability

### What is durable when

| Event | Durable at | Through |
| --- | --- | --- |
| a namespace change, a setattr, a write | the next checkpoint, or an `fsync` record of the file when the change is the file's own | the checkpoint's commit; the record's commit |
| an `fsync` of a regular file that a record can express | its record's commit | [fsync](#fsync) |
| any other `fsync` | a checkpoint it waits for | [Checkpoints](#checkpoints) |
| a checkpoint on the durability facet, frozen or not | its commit | [The interface](#the-interface) |

A checkpoint runs at least every 30 s while anything is dirty, when the
dirty nodes and dentry blocks pass a bound of the volume's memory, when
the cleaner needs prefree segments freed, at an `fsync` that a record
cannot express, and on the durability facet. A write the volume answered
is in the next checkpoint whatever its file's state, since the checkpoint
writes every dirty node.

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
   the SSA blocks of segments the logs left. The journals are empty, and
   entries the mounted checkpoint kept in its journals are written to
   their blocks here ([F 47]).
3. **Write the pack body** into the pack the committed checkpoint is not
   in: the header block, the payload blocks that continue the SIT version
   bitmap ([F 23]), the orphan blocks when orphans exist ([F 26]), the
   three normal data summaries of the current data logs, and at an
   unmount checkpoint the three node summaries ([F 20]).
4. **Flush.** Then **write the last block**, the header's copy, and
   **flush** again. The checkpoint is committed when that flush is
   answered: the touched set becomes the live set, prefree segments
   become free, freed nids join the pool, the epoch's facts clear, and the
   checkpoint is reported.

The header carries the new version, one above the committed one, the
counts, the six logs' positions, all `alloc_type` LFS, and the flags:
`CRC_RECOVERY` always, `ORPHAN_PRESENT` exactly when orphan blocks are
written, `UMOUNT` only on a freezing checkpoint, after which no write
follows, and `FSCK` once the volume has met a malformed structure, never
cleared ([R 27]); erXos sets no other flag. The CRC covers the header as
[F 51] says, with `checksum_offset` 4092. `free_segment_count` is counted
from the SIT the plan writes: segments with no valid block that are not a
log's ([T 74]). The orphan list is bounded as Linux bounds it, (512 - 8 -
`cp_payload`) x 1020 inodes ([R 74]); an unlink that would pass it
answers `enospc`.

A failed write or flush in any phase ends the volume process. Until the
last block's flush is answered the committed checkpoint is the one on
the medium, with its chain, so the restart mounts it.

### fsync

An `fsync` of a regular file writes a **record** when the record can
express everything about the file that changed since the commit, and
asks for a checkpoint otherwise. The record is possible when all of these
hold, each a fact the epoch keeps:

* the file has one link and has not been renamed or linked since the
  commit, so its committed entry, or the one recovery recreates from its
  `i_name` and `i_pino`, is its only name ([R 40], [R 56]);
* if the file was created since the commit, its parent directory was not;
* no node of the file was freed since the commit, since a chain can
  replace a dnode but not remove one;
* the volume has `INODE_CHKSUM` and the inode's `i_extra_isize` reaches
  the checksum, so the record's commit point checks itself (below);
* the touched blocks number at most `user_block_count`, so the replayed
  state fits beside the committed one ([R 41]).

Otherwise the `fsync` waits for a checkpoint. Directories, symlinks and
other kinds always do, as in Linux ([R 40]).

**The record's plan** writes, in the warm node log, every dirty direct
node of the file but its inode block, unmarked, and then **flushes**;
then it writes the inode block with the fsync mark, and the dentry mark
when the file was created since the commit and has no record yet in the
epoch ([R 43-44]); then it **flushes** again and answers. Only a file's
last block in a record, its inode block, is marked, which is Linux's
atomic form ([R 45]): recovery
replays a file's chain blocks up to its last marked block and none after,
and the walk ends at the first block missing from the chain. So a record
is replayed whole or not at all.

The two flushes make the record's commit point, the marked inode block,
imply everything it references:

* every data block the record's dnodes name was written, and answered,
  before the first flush (ordering 1), and every dnode of the record was
  written before it, so a durable marked inode block means durable, whole
  data and dnodes;
* the marked block itself can tear; its inode checksum then fails, the
  walk ends there ([Mount](#the-walk)), and the record, whose `fsync` had
  not returned, is not replayed. That is why a record needs
  `INODE_CHKSUM`: on a volume without it a torn inode block cannot be told
  from a whole one, and the `fsync` takes a checkpoint, whose commit block
  carries a CRC.

`fsync`s that arrive while a record is being written join the next one:
the volume writes one record at a time, holding every waiting file's
dnodes in one plan with one inode block marked per file, so a chain is a
sequence of complete records and at most one incomplete one at its end.
An `fsync` that arrives while a checkpoint is in flight waits for it and
is then planned in the new epoch, so no record straddles a commit. The
first flush is left out when no write was answered since the last flush.

Indirect nodes are never in a record; recovery builds the path to a
replayed dnode ([R 57]), and the next checkpoint writes the file's
indirect nodes. A record's blocks are live, and the blocks they replace
stay touched until the commit, so a chain block is never overwritten
before a checkpoint makes it unnecessary.

### The device flushes

The design asks two things of the block service and nothing else: that a
write is answered only once the controller reports it written, and that
a flush is answered only once every write answered before it is durable
on the medium ([design-storage.md](design-storage.md#data-model)). It
needs no forced-unit-access write: where Linux writes a commit block with
a preflush and FUA ([R 8]), erXos writes it after one flush and before
another. On media that do not honour flushes, SD cards among them, no
ordering holds, which [design-storage.md](design-storage.md#invariants)
already records as a residual.

### Freezing

A freezing checkpoint ([design-storage.md](design-storage.md#interfaces))
reaches the volume after `erx_fs` has closed mutation admission and every
owner has finished the writes it admitted. The volume writes an unmount
checkpoint, `UMOUNT` set and node summaries in the pack, and from its
commit answers every mutation `erofs`. A checkpoint without a freeze, the
vault's, is an ordinary checkpoint. Both answer only once their flush is
answered, so the trial's read-only mount and the next normal mount both
find every write the service acknowledged, with an empty chain.

## Mount and recovery

### Mount

A mount is pure until its last step, and reads in this order, each
check failing the mount with `eintegrity` and a log line naming the
structure and the rule, after writing nothing:

1. **The superblock**: both copies, at byte 1024 of blocks 0 and 1
   ([F 7]); a copy is valid under every rule of [F 54], with the
   checksum when `SB_CHKSUM` is set ([F 13]), and erXos's feature sets
   and geometry rules above; the first valid copy wins, and a bad copy
   is logged and left as it is.
2. **The checkpoint pack**: both packs' first and last blocks; a pack is
   valid when both pass their CRC, its total is above 2 and at most 512,
   and both carry the same version; the later version under wrap-around
   comparison wins ([F 22], [R 14-16]); then every check of [F 55] on the
   chosen one, and the bitmaps' bounds: the SIT and NAT version bitmaps
   have exactly the sizes the superblock implies, and they fit the header
   or the payload blocks they occupy ([F 23]), which Linux does not check
   and f2fs_reader does (`checkpoint.rs` l.106-130).
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

The walk is bounded: it takes at most as many steps as the main area has
blocks not valid at the checkpoint, since every chain block was written
after it, and a chain block valid at the checkpoint, or a walk past the
bound, which a loop makes, fails the mount, as `fsck.f2fs` treats both
([T 57]). A read error fails the mount with `eio`. Every block the walk
read, its end included, is the walk's **footprint**.

### Orphan cleanup

When the checkpoint has `ORPHAN_PRESENT`, every listed inode is loaded,
must have no link, and has its blocks, nodes and xattr node freed through
`set_slot` and `set_node`, in memory, before replay, as Linux orders it
([R 75]). An orphan whose inode is not an inode, or has links, fails the
mount.

### Replay

Replay takes the chain's blocks in order and keeps, for each inode, the
blocks up to its last marked block ([R 54-55]):

* **an inode block with the dentry mark** of an inode the checkpoint does
  not have (its NAT entry empty, or the mount fails) creates the inode;
  a chain block of an inode that neither exists nor is created is passed
  over;
* **an inode block** sets the inode's attributes, the ones [R 55] lists,
  and its inline area or address array;
* **the inode's last dentry-marked block** links its `i_name` into
  `i_pino`, which must exist: an entry already naming the inode is kept, an
  entry naming another inode is removed first, that inode becoming an
  orphan if it has no link left ([R 56]);
* **a direct node** replaces the dnode at the same node offset of the
  file, whose offset must match the node already there, allocating the
  path's indirect nodes and nid as needed, and every slot of it goes
  through `set_slot`: a new address that another slot holds, by the
  block's summary confirmed against that slot, is cleared from it first,
  and a new address still valid after that fails the mount ([R 57],
  [R 60]); an xattr node replaces the inode's xattr node.

Every rule of [R 60] that fails recovery fails the mount. Replay changes
only the state; the chain's own blocks and their data become live where
they lie, so the mount checkpoint adopts them without copying.

Replay sees Linux's chains, which may hold inline data, `NEW_ADDR` slots,
several marked blocks per inode and addresses moved between slots, and
erXos's, which hold none of those but the marks; the same functions take
both.

**A failed recovery fails the mount.** Linux instead mounts again without
roll-forward, at the checkpoint, and marks the volume for `fsck.f2fs`
([R 62]): that serves a state without fsynced data as if it were the
volume. erXos writes nothing, and the files stay on the medium for a
repair, as every failed mount of a storage domain leaves them
([design-storage.md](design-storage.md#read-write-storage); [Open
decisions](#open-decisions), 2).

### Read-only mounts

A read-only mount, a trial's or any mount whose features are in R but
not in W, runs every step above in memory and writes nothing: the volume
answers every mutation `erofs`, runs no cleaner and no timer, and its
checkpoint and freeze requests answer at once with nothing to do. It
serves the replayed state, so it shows every acknowledged `fsync`
without writing it. Linux, by contrast, replays and writes even on a
plain `ro` mount of a writable device, and refuses the mount on a
read-only device that has something to replay ([R 69-70]).

### Read-write mounts: the mount checkpoint

A read-write mount, after replay, moves all six logs to fresh segments,
outside every segment the footprint touches, adds the footprint to the
touched set, and writes the mount checkpoint, an ordinary checkpoint of
the replayed state. It is written whether or not anything was replayed,
which also closes the unmount checkpoint's `UMOUNT` and commits orphan
cleanup. Only after its commit does the volume admit a request that
changes anything.

The fresh segments come from the reserve of
[Space](#space-accounting-and-quotas): the allocator never takes the
free segments below the reserved count, eight, and the chain's own
segments were taken within it, so a mount of a volume erXos wrote finds
at least eight free segments outside the footprint. A volume another
writer left with too few, or a replay whose dirty blocks need more than
the free segments hold, mounts read-only instead, with a log line naming
the shortfall.

## The cleaner

The cleaner is steps of the volume process. When free segments fall
below twice the reserved count, the volume runs cleaning steps between
requests; when an allocation would take the free segments below the
reserved count, the request that needs the space waits while cleaning
runs first (foreground cleaning).

* **Victim**: the full segment with the fewest valid blocks, excluding
  the six logs' segments and prefree ones (greedy, [R 84]); segments are
  sections, since the format makes one segment per section.
* **Move**: the step needs the victim's valid blocks and its summary; a
  data block is live when the dnode its summary names still holds its
  address at the summary's index, and a node block when the NAT still
  maps its nid there ([R 80]); each live block is written to a fresh
  block, data to the cold data log and nodes to their own logs, and once
  answered installed with `set_slot` or `set_node`. The victim, empty,
  becomes prefree, and free at the next commit ([R 82]).
* **Freeing**: when foreground cleaning has emptied segments that are
  still prefree, it asks for a checkpoint.

One step moves one victim, at most 512 blocks, so requests run between
steps. Moved file dnodes in the warm node log carry no mark and are passed
over by a walk ([R 47]). Cost-benefit victim choice for background
cleaning ([R 84]) is left for a measurement to ask for
([Performance](#performance)).

## Space accounting and quotas

The volume's space is the checkpoint's `user_block_count`: main-area
blocks less the overprovisioned segments ([F 21]). A step that would take
`valid_block_count` past it answers `enospc` before it changes anything,
as does one that needs more nodes than the NAT has free nids. The
overprovisioned segments are the cleaner's room: with valid blocks at
most `user_block_count`, the invalid and free blocks together always
fill the overprovisioned segments, so a greedy victim always has room to
give. The reserved segments, a part of them, are kept free for the
cleaner's and the mount checkpoint's moves.

Per-principal quotas on the data partition are M10's
([plan.md](plan.md#m10-users-without-a-container-runtime),
[design-storage.md](design-storage.md#read-write-storage)), and F2FS
offers nothing for them until then: no principal's usage is counted. How
F2FS will count it is [Open decisions](#open-decisions), 4.

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
  ([design-storage.md](design-storage.md#read-write-storage)), and the
  version is the file's `data_version`, drawn from the domain's counter
  at every change ([design-files.md](design-files.md#identity-and-version)).
  An inode Linux made carries Linux's generation, which can equal the one
  erXos gives a later inode at that nid only where 32 bits coincide.
* **Holds.** `walk` holds the node it answers for the calling grant, in
  the same step, and `forget` and a grant's end release it; an open holds
  its file. An inode that loses its last link while held becomes an
  orphan, and is freed when its last hold goes, so an unlinked open file
  stays readable and a power cut leaves it to orphan cleanup ([R 72]).
* **`statfs`** answers the ABI's F2FS type, F2FS's magic `0xF2F52010`
  ([F 9]), block size 4096,
  the user blocks and the free ones, and the nids free in the NAT.
* **Errors.** `enoent`, `eexist`, `enotempty`, `enotdir`, `eisdir`,
  `enametoolong` past 255 bytes, `efbig`, `emlink` at 2^32 - 1 links,
  `enospc` ([Space](#space-accounting-and-quotas), the orphan bound),
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
  free and prefree segments, the orphans, the dirty bound, and the last
  mount's recovery: chain length, records replayed, orphans freed and the
  mount checkpoint's version.

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
language gains a packed wire storage whose fields may sit at any byte
offset and are read and written only by bit-syntax matching in Erlang;
splitting each misaligned field into byte-aligned pieces, as the EROFS
spec splits one 64-bit nid into two words, would spread hand-made
arithmetic over some forty fields ([Open decisions](#open-decisions),
7).

**The codec.** `erx_f2fs_codec` alone turns blocks into records and back.
Each decoder takes one block, checks its length, matches the generated
layout and checks every value it reads against its bounds before
anything uses it. Sequences (NAT entries, SIT entries, summary entries,
orphan numbers, dentry slots, xattr entries) are read through a cursor
over the block, never by computed offsets; a count read from the medium
(`entry_count`, the journals' counts, `name_len`, `i_namelen`,
`i_extra_isize`, `cp_pack_total_block_count`, the bitmap sizes) is checked
against the room it claims before the cursor moves. The codec follows
the rules Linux enforces on reads ([F 42], [F 60], [T 92]) and adds the
bounds Linux leaves out: the version bitmaps' room and the journals and
orphan counts against their blocks. A failed decode is one
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
starts from blocks of the oracle's images and erXos's own, with the
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
volume, every block that must hold given bytes, zeros included, and the
installation's medium writer runs it on the host's stock OTP and places
them through `Erx::DataVolume`, for the data partition and the vault's.
It is the same Erlang the guest runs, so the format has one
implementation.

* **Geometry.** Blocks of 4096 bytes, segments of 512, one segment per
  section and per zone; segment 0 at block 512 of the partition, so the
  first 2 MiB hold the two superblocks, as `mkfs.f2fs` places it
  ([T 11]); the checkpoint area 2 segments; the SIT and NAT copies sized
  as [T 12] gives, the SIT bitmap moving to payload blocks when it passes
  3836 bytes ([F 23]); the SSA one block per main segment and one more,
  in whole segments ([F 17]). The reserve:
  8 reserved segments, the six logs' and two more, and overprovisioning
  of the larger of 10 segments and 2 % of the main area; `user_block_count`
  is the main area less the overprovisioned segments. These satisfy every
  check of [F 55] and [T 47-48], and the smallest partition they allow is
  44 MiB, as for `mkfs.f2fs` ([T 17]); the vault's 64 MiB and the data
  partition's 128 MiB at least ([abi/medium.txt](../abi/medium.txt)) are
  above it. The minimum follows from the reserve: the six logs' segments
  and eight free ones in the main area, and one more than the
  overprovisioned segments.
* **Contents.** Features `EXTRA_ATTR`, `INODE_CHKSUM` and `SB_CHKSUM`;
  the root directory, nid 3, in the hot node log's first block and its
  dentry block in the hot data log's; NAT block 0 with nids 1 and 2 at
  address 1, as `fsck.f2fs` requires, and nid 3 ([T 26], [T 73]); the
  SIT's first copy with the two used blocks and the six logs' types; the
  first copy of every other SIT and NAT block, zeros; the warm node log's first
  block, zeros ([T 25]); pack 1 an unmount checkpoint with normal
  summaries, and pack 2 zeros, which fails its CRC; the superblocks, last.
  The version is an odd 31-bit number the caller passes, random for an
  installation and fixed for a test; the UUID and the times likewise.
* A cut format leaves no superblock, so the volume does not mount and the
  installation runs again.

## Replacing littlefs

The seam is the `erx_fs` callback module and the storage domain's
supervisor: `erx_storage_sup`'s data child changes from `erx_lfs_sup` to
`erx_f2fs_sup`, the release adds the `erx_f2fs` application, and the
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
| the mount's checks or replay fail | `erx_f2fs_mount` | the medium as it was; nothing written | none on erXos; the partition is repaired with `fsck.f2fs` elsewhere | `eintegrity`; the storage domain stays ended after its restarts, never formatted |
| the volume is full | the step's space check | everything | the cleaner, when invalid blocks can be reclaimed | `enospc` |
| the volume process crashes | its supervisor | the durable view | as for a failed write | as for a failed write |

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

No stale block reaches a client (F2-R4): a data block is read only at an
address the state holds, which holds only addresses whose writes were
answered, and the touched rule keeps a block from reuse while any
durable view or queued read can reach it. `NEW_ADDR` slots and holes
read as zeros.

The oracle guest runs Linux and f2fs-tools, GPL tools, in QEMU without a
network device; `fsck.f2fs` reads an orphan count without bounding it
(open question Q7 of part 3), so it only ever runs there, on images
attached read-only or as snapshots. Everything the guest prints is
untrusted: the host parses it with bounded matching and prints it only
through the host terminal's escaping function.

## Verification

### The crash states as the oracle

Each crash state of part 2 becomes a row erXos must meet, in its own
mount and in Linux's, and the power-cut harness checks every state it
makes against the row it belongs to:

| # | Cut during or after | erXos's mount | Linux's mount of the same image |
| --- | --- | --- | --- |
| E1 ([C 1]) | writes, with no `fsync` or checkpoint | the committed checkpoint, with its chain | the same |
| E2 ([C 2], [C 3]) | a checkpoint before its first flush | the committed checkpoint and chain; the new NAT and SIT copies unselected | the same |
| E3 ([C 4], [C 5]) | a checkpoint's last block, absent or torn | the committed checkpoint; whole: the new one | the same |
| E4 ([C 6]) | after the last block, before its flush is answered | either checkpoint, both intact: nothing freed was reused | the same |
| E5 ([C 7]) | a record before its second flush answered | earlier records replayed; this one whole or not at all | the same |
| E6 ([C 8], [C 9]) | after a record's `fsync` returned | the record replayed; a new file's entry recreated | the same |
| E7 ([C 10], [C 11], [C 12]) | data not yet durable | cannot occur: orderings 1 and 2, no in-place writes | - |
| E8 ([C 13]) | a mount's replay | nothing written; the next mount replays the same | the same |
| E9 ([C 14]) | a mount checkpoint before its commit | the old checkpoint and the whole chain; the same recovery again | the same: the mount checkpoint wrote nothing Linux's walk reads |
| E10 ([C 15], [C 16]) | orphans listed by the checkpoint | orphans freed at mount | the same |
| E11 ([C 17]) | an unlink not yet checkpointed | the file back, with its records | the same |
| E12 ([C 18]) | a superblock write | cannot occur after the format | - |
| E13 ([C 19]) | both packs damaged | the mount refused, nothing written | refused |
| E14 | the cleaner's moves before a checkpoint | the committed view; the victim's old copies intact | the same |
| E15 | the format | no superblock, no mount | no mount |

Linux's `ro,norecovery` mount of each state shows the checkpoint alone,
which checks erXos's checkpoints without its chains.

### The power-cut harness

The harness runs the core and the volume process on the host's stock OTP
over a simulated window, which records every write and flush and, for
each prefix of a workload's requests, makes the states a cut can leave:
every write answered before the last answered flush kept, and each later
write kept, lost or torn at a sector boundary. It enumerates every subset
of the unflushed writes kept, up to ten of them, and each such state with
one kept write torn at each of its sector boundaries, and samples beyond
ten. Each
state is mounted by the core, read-only and then read-write, and checked
against a model of the workload: every file whose `fsync` returned holds
exactly what it held then or a later write; every block of every file
holds bytes some write put there or zeros where none did (F2-R4); names
are the committed ones or those an operation in flight could leave; the
counters equal a recount; a second mount after the read-write mount's
checkpoint gives the same tree; and a cut during that mount checkpoint
gives the same tree again (E9). Workloads cover creates, writes of every
size and alignment, truncates, renames, links, unlinks of open files,
`fsync` of new and old files, concurrent `fsync`s, directory growth past
several levels, a volume filled until the cleaner runs, and mounts of
Linux-made images with chains.

| Test | Seeded fault the harness must catch |
| --- | --- |
| a record replays whole or not at all | marking every dnode of a record instead of the last |
| no record's dnode durable before its data | the first flush of a record dropped |
| a cut during the mount checkpoint loses nothing | the warm node log left at the chain's start |
| no stale block after a cut | an address installed before its write is answered |
| freed blocks stay until the commit is durable | prefree segments freed at the last block's write, before its flush |
| a nid is not reused within an epoch | freed nids returned to the pool at once |
| no stale chain after a crash and a mount | the mount checkpoint skipped when nothing was replayed |

A sample of the states, every E-row at least, goes to the oracle guest
too.

### The Linux oracle guest

The guest is built from pinned Debian packages, as the deleted EROFS
guest was (`tools/lib/erx/linux_guest.rb` before `6574015d`): a kernel
with `f2fs.ko`, f2fs-tools 1.16.0 with its libraries, and busybox, run
under QEMU without a network device, with a deadline and its serial log.
Its kernel must be the Linux version the facts records read, v7.3.4, or
the facts the design rests on are re-checked by probes on the version it
runs ([Open decisions](#open-decisions), 3). One boot checks many images,
attached read-only or as snapshots, so Linux's writes never reach the
image under test.

**erXos to Linux.** For each image erXos writes (a fresh format, every
workload's end state and the harness's sampled states): `fsck.f2fs
--dry-run`, with standard input giving "n" to every prompt ([T 40]); the
check passes only with exit status 0 and no line beginning `[ASSERT]`,
`[FIX]` or `[Fail]` and no `Reconnect` line, since `fsck.f2fs` repairs
some faults silently in check mode and exits 0 ([T 41]); then a mount
with recovery and a listing (names, modes, links, sizes, SHA-256 of
every file) that must equal erXos's own replayed tree; then a
`ro,norecovery` mount whose listing must equal erXos's checkpoint tree;
and `fsck.f2fs -l`, whose superblock and checkpoint fields must equal
erXos's decode ([T 79]).

**Linux to erXos.** The guest formats scratch disks with `mkfs.f2fs`
(default options, which set no feature at all [T 6], and `-O
extra_attr,inode_checksum,sb_checksum`, and one per read-only feature),
copies in a tree the host declares (inline and block files and
directories, sparse files reaching the double indirect node, hard links,
symlinks of both forms, device nodes and FIFOs, directories several
hash levels deep), and unmounts; erXos must read the tree back equal.
Then the guest writes and `fsync`s, and is killed: erXos's replay of
Linux's chain must give the tree Linux's own remount of a copy gives.
Then erXos writes to each image and Linux checks it as above, so every
image travels both ways. The images are made on demand and cached in the
build tree, keyed by the pins and the tree's declaration, never
committed.

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

### Unit tests

Each pairs a passing case with a seeded fault that must fail it:

| Test | Seeded fault |
| --- | --- |
| the dentry hash of names of 0 to 255 bytes, against the hashes in the oracle images | the length word built from the chunk's own length instead of the bytes left |
| the inode checksum against Linux-made inodes | the footer left out of the checksum |
| the CRC against Linux-made superblocks and checkpoints | zlib's inversions kept |
| the inode layout for every E and X of [F 48]'s table | the reserved word before inline data dropped |
| the record decision over every combination of the epoch's facts | the rename fact ignored |
| `set_slot` keeps one owner per block and the counters | the stale owner not cleared |
| the format plan passes the mount checks at sizes from 44 MiB to 64 GiB | overprovisioning below the reserve |
| a read-only mount writes nothing, over a window that fails every write | a read-only mount that writes its mount checkpoint |
| the walk on a looped chain fails within its bound | the bound removed |

## Performance

What to measure, with `tools/erx bench fs` on QEMU under HVF against
littlefs, and on the Pi 4's SD card at M12; each suspected cost is on the
watch list ([todo-performance.md](todo-performance.md)):

* `fsync` latency: two flushes per record, against Linux's one preflush
  and FUA write;
* small writes without a buffer: a write of less than a block rewrites
  the whole block out of place, so a stream of short appends rewrites its
  last block each time;
* the volume process carries every block request and its answer, at 4 KiB
  per request on virtio;
* checkpoint cost: whole NAT and SIT blocks for every changed entry, with
  no journals, and a checkpoint per timer tick while anything is dirty;
* mount time: the whole SIT, the current node segments' footers when the
  pack has no node summaries, the walk, and orphan cleanup;
* the cleaner's overhead at high utilisation with greedy choice alone,
  and the 2 % overprovisioning;
* memory: the SIT, about 150 bytes a segment, 4.6 MiB for 64 GiB, and
  the dirty bound.

## Alternatives considered

* **Every `fsync` a checkpoint** (the research record's proposal).
  Simpler, but against the owner's requirement that erXos writes
  roll-forward records, and a checkpoint per `fsync` writes NAT, SIT and a
  pack each time.
* **Linux's default `fsync`**, every dnode marked and one flush. Rejected:
  a reordering medium can make a dnode durable before its data
  ([R 48]), and a partly durable record replays partly; the atomic form
  with a flush before the marked block costs one more flush and removes
  both.
* **Recovery that writes as it replays, as Linux's does after replay.**
  Rejected for the mount checkpoint in fresh segments, which makes a cut
  during recovery harmless.
* **A mount mode without roll-forward**, as `norecovery`. Rejected: a
  read-only mount that replays in memory writes nothing either, and shows
  the acknowledged `fsync`s; one mount path serves both.
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

## Stages

M13 brings F2FS on QEMU as 1b-H ([plan.md](plan.md#m13-erxoss-f2fs)),
in stages that each end in tests of their own:

1. **The format's facts and the reader**: `abi/formats/f2fs.txt` and the
   layout language's packed storage, `erx_f2fs_codec` with its fuzz
   targets, and the oracle guest making Linux images.
2. **Read-only mounts**, with the walk and replay in memory, of every
   Linux image the guest makes, clean and with chains; erXos's trees
   equal Linux's.
3. **The format and read-write mounts with checkpoints**: every
   namespace and data operation, the mount checkpoint, orphans; every
   image passes `fsck.f2fs` and Linux lists it equal.
4. **`fsync` records and the power-cut harness**, with every crash state
   checked in erXos and in the guest.
5. **The cleaner**, under churn to high utilisation.
6. **Parity and the switch**: the file-semantics corpus against littlefs
   and Linux, gate G13, then the seam's change and littlefs's deletion.

The estimate is about 7,500 lines of Erlang, 1,500 of Ruby and 3,000 of
tests.

## Open decisions

1. **The trial's mount.** M13's accepted scope says a trial mounts F2FS
   "without recovery, as Linux's `norecovery` mounts it". This design
   gives F2FS one mount path: read-only mounts, a trial's included,
   replay in memory and write nothing. After the freezing checkpoint the
   chain is empty, so the trial sees the same files either way; the
   difference is that a read-only mount after an unordered end shows the
   acknowledged `fsync`s. Recommendation: accept the one path, and read
   M13's criterion as "a read-only mount writes nothing", which the plan
   rows below say.
2. **A recovery that fails.** Refuse the mount and write nothing
   (recommended), or mount at the checkpoint without the chain and mark
   the volume for `fsck.f2fs`, as Linux does, which keeps `/data`
   available but serves a state missing acknowledged `fsync`s as if it
   were whole.
3. **The oracle guest's kernel.** The facts records read Linux v7.3.4;
   the research record's candidate is Debian 13's 6.12.107 kernel.
   Recommendation: pin a Debian kernel package built from v7.3.4 if
   snapshot.debian.org has one, else the nearest 7.3 release, and record
   the probes that re-check [F 54-56] and [R 49-62] on it.
4. **Per-principal quotas, at M10.** Linux's project quotas
   (`PRJQUOTA` and `QUOTA_INO`, each inode tagged with its principal's
   project id, usage kept in quota files that each checkpoint writes, so
   Linux keeps it too), which needs a fourth facts record on the quota
   file's format and on Linux's quota handling at checkpoint and
   recovery; or a count of each principal's blocks rebuilt at every
   mount by reading every inode, which needs no new format and costs
   mount time. Recommendation: project quotas, with the facts record
   written when M10 starts; the feature set changes then, and the
   partitions are created afresh.
5. **Read-only acceptance of layout-neutral features.** Accept
   `INODE_CRTIME`, `FLEXIBLE_INLINE_XATTR`, `QUOTA_INO` and `PRJQUOTA`
   read-only, one oracle image each (recommended, for images Linux
   distributions and Android tools make), or refuse them until a consumer
   asks.
6. **Who formats on the host.** erXos's own format plan on the host's
   stock OTP (recommended: one implementation of the format), or F2FS in
   fsimg, which would be a second implementation and need the clean
   room's facts too.
7. **The ABI's packed layouts.** Extend the layout language with a packed
   wire storage for on-disk formats (recommended), or declare F2FS's
   misaligned fields as byte-aligned pieces as the EROFS dirent does.

## Risks

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| A fact in the records is wrong, or differs on the guest's kernel | medium | an image Linux rejects or misreads | every image both ways through the oracle; probes for each open question of the records |
| A Linux chain shape the records do not describe | low | a replay that fails the mount | the mount fails safely; the oracle's dirty Linux images exercise replay |
| SD cards that ignore flushes | medium | any ordering lost on the Pi | recorded with the block driver's residual; the Pi's half of G13 measures it |
| Two flushes per `fsync` too slow | medium | commit latency at G13 | the measurement decides; the record's form is Linux's and stays |
| The clean room is challenged | low | high | facts only through separate writers; implementers read only this document, the records and permissive sources; a legal review before any distribution, as [design-storage.md](design-storage.md#read-write-storage) requires |

## References

* The F2FS facts records, parts 1 to 3, and the research record
  `~/erxos-scratch/notes/research-f2fs.md` (2026-11-14, SHA-256
  `5a2d7523ec6459ffaeaaca8712b5b2c213c1e0fe56c6181ae9f2d6050a536d21`),
  with their sources' versions and hashes.
* Fuchsia `src/storage/f2fs_reader`, commit
  `6478165d12ab3164d09b3e81551ff692427b5038`: `superblock.rs`,
  `checkpoint.rs`, `README.md`.
* Lee, Sim, Hwang, Cho, "F2FS: A New File System for Flash Storage",
  FAST '15, the model the format serves.
* [design-storage.md](design-storage.md), [design-files.md](design-files.md),
  [design-system.md](design-system.md#shutting-down),
  [plan.md](plan.md#m13-erxoss-f2fs).
