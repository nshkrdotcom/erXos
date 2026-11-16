# Stopgaps no other design carries

Each component here is a stopgap: the roadmap replaces it, and CLAUDE.md's rule for what a
stopgap promises binds it. R1 ships littlefs, under [its release contract](#release-contract), whatever M13's gate G13 decides;
a release ships no other stopgap of this document. The kernel the first release runs on,
Fiasco, and `liberx`'s backend over it are [design-fiasco.md](design-fiasco.md)'s, and the
sections of that backend named below are there.

## littlefs in the storage domain

**The port.** Where a storage domain holds the data window, littlefs is that domain's sub-space port, as
[design-storage.md](design-storage.md) places it: a sub-space the storage domain creates, with a channel to it, its block
requests to the storage domain's block service over the channel and its end at the storage domain's fault gate. Each of
those is a row of the Fiasco backend ([Spaces, parents and exit records](design-fiasco.md#spaces-parents-and-exit-records), [Passing a
handle](design-fiasco.md#passing-a-handle), [Fault gates](design-fiasco.md#fault-gates)), so the port and `design-storage.md`'s remount rule run unchanged.
A crash injected into littlefs ends only its port, since a fault ends nothing but its space once its gate's server stops
it. A port that bypasses `liberx` reaches only what the storage domain placed in its space, as any sub-space does ([design-fiasco.md](design-fiasco.md#who-holds-what)).

**The NIF form.** Phase 1 runs littlefs as a NIF behind the `erx_fs` callback module, the seam the design names, in the
domain that holds the data window: the storage domain, which the development manifest configures as an interpreter service
domain with the `block` unit and runs `erx_blk` and `erx_storage` (`erx_lfs_sup` under `erx_storage_sup`). The system
release ships neither application, so a manifest that leaves the `block` unit with the system domain runs no block
driver and serves no `/data`. The Erlang side is the
port's, and only the glue below differs. The storage domain serves the tree as the `data` service, of the `files`
interface, whose facets the manifest grants to the system domain and to root's session template: each grant is
read-write over the whole of `/data`, so every session of root's principal reads and writes all of it, which a
development build's trusted code allows and a release does not ([Release contract](#release-contract)) (property 16 of [design-system.md](design-system.md) holds both ends to the
protocol's frame floor).

A process running a dirty NIF cannot run its receive loop, so two share the work. The **owner** takes clients' requests, one at a time, and never
blocks. The **worker**, linked to it, alone calls the littlefs NIF, on a dirty I/O scheduler, one operation at a time.

littlefs reads and programs whole sectors. Its `erase` returns success with no request, since a block device erases nothing. **One block request**,
from a read, program or sync callback:

1. The callback allocates a NIF resource holding a state word, starting *pending*, a result and a buffer. A program copies its bytes into the buffer.
2. It posts `{erx_lfs_block, Op, Sector, Count, Ref}` to the owner with `enif_send`, where `Ref` is the resource term and `Sector` is `(Block * BlockSize + Off)
   / SectorSize`. If `enif_send` reports the owner dead, it fails at once.
3. It waits on the request's condition variable, under its mutex, until the state leaves *pending* or the deadline passes;
   the mutex and condition variable are musl's, over `erx_umtx_wait` and `erx_umtx_wake`.
4. The owner translates `Op` into the [block service's request](design-storage.md#interfaces): `{read, Sector, Count}`; `{write, Sector, Bytes}`, with
   `Bytes = payload(Ref)`, a short NIF returning the buffer as a binary; or `flush`. It sends with a monitor and a reply tag, remembers the one
   outstanding `{Tag, Ref}`, and returns to its receive. The resource stays private to the owner.
5. On the answer it calls `complete(Ref, Result)`, a short NIF that copies any read bytes into the buffer, stores `ok` or `error`, under the mutex moves the state from
   *pending* to *done*, and signals the condition variable.
6. The callback, on *done*, copies a read's bytes into littlefs's buffer and returns 0, or `LFS_ERR_IO` for `error`.

**No dirty-scheduler deadlock.** Steps 4 and 5 and `erx_device` run on normal schedulers, and interrupts arrive by the dispatcher. One operation holds
one dirty thread, and nothing it waits for needs a second. To keep that true, the owner makes no synchronous call; the owner and driver use no file
operation, and no `logger` handler writes to `/data`; `complete` and `payload` are not dirty NIFs.

**Failure has one answer: the storage domain ends.** Any block failure (an error answer, a request the owner refuses, or a deadline: the callback
moves the state from *pending* to *ended*, and a lost swap means the request is done) breaks the NIF's volume, so the operation and every later one
answer `{error, eio}`. The NIF's flag is the one record of it: the worker reads it (`broken/1`) after each operation and ends when it is set. The
worker's end, the window's, or a mount that fails ends the owner. `erx_lfs_sup` and `erx_storage_sup` restart nothing (their children are permanent
and their restart intensity is 0), so the end escalates to `erx_storage`, a permanent application, and ends the node and the domain. Every queued
request answers `{error, eio}`, and nothing in the domain replays or remounts. The block driver's failures end the domain the same way, whether or
not a request is in flight: `erx_blk_sup` restarts nothing either, so the end of its device or partition process, by a crash or by the shutdown
with which its device process, `erx_blk_virtio`, ends on a broken queue, ends the `erx_blk` application, which is permanent, and the domain; the driver never
restarts on its own under a mounted volume, and a broken queue never resets the device in place, since nothing promises that a reset keeps
writes the device's volatile cache holds and has already answered `ok`. A stop, start or restart through `storage_ctl` is the system domain's, and the supervisor counts no
restart for it, so it does not end the domain itself. Each window of the block service is bound to the device process it first reached
(`erx_blk_window`), calls it by pid and monitors it, and once that process has ended answers `{error, eio}` to every request that would reach
the device, even after a new device process has reset the device: the windows the volume mounted on never vouch for a write across a reset.
So a stop, start or restart breaks the volume at its next block request, which ends the domain, and a
start whose device refuses the reset answers `{error, failed}` and leaves the domain up without a driver until littlefs's next request fails.
The domain service restarts the domain within its row's intensity
(`restarts 5`, `restart_period_s 600`): creation gives it the device again, the driver resets it, and littlefs mounts the volume afresh. The owner
answers its start only once the volume has mounted, so `/data` is mounted, and the domain reports ready, only over a mounted volume, and a mount that
fails fails the domain's boot. A delayed old write cannot race a newer one, since none outlives the domain that issued it, and littlefs's power-loss
design handles the cut. A late `complete` loses its swap and does nothing; the term keeps the buffer alive. `design-storage.md`'s rule, which remounts
once every outstanding request is answered, belongs to the port.

**`/data` for other domains.** The volume is also the files service `data`, which the manifest grants to the system domain and to root's session
([design-files.md](design-files.md)). Its mint, an `erx_storage_mint`, the module of every files service mint of the storage domain, is the third child of `erx_lfs_sup`, after the owner and the local grant, and names
itself the service's mint before the domain reports ready. It takes only a mint request in the system domain's envelope and drops anything else. For
each one it starts an `erx_fs` grant of the volume's tree, read-write, whose client is the grantee's domain id, so the grant takes frames only in that
domain's envelope and with that domain's names. The grant exports itself to the grantee, with `send` alone, before its start returns, so no answer
names a grant the grantee cannot reach; a refused export is the mint's answer, and no grant is left. A grant for any domain but the system domain
monitors this domain's connection to the grantee (`erx_connections:connection/1`) before the export and ends with it: a grantee's restart is a new
domain id over a new connection, and no grant of the old incarnation remains to take its frames. The system domain's grant lives as long as the
storage domain. The grants are temporary children of a supervisor linked to the mint, so a grant's end, by its connection or its heap bound, ends
nothing else, while the volume's end ends the mint and every grant, and the domain's restart answers new mint requests over the new volume. Of the
facet row's limits a grant applies three: `in_flight`, the most requests it holds at once (at most `erx_fs_grant`'s 64); `max_request`, the largest
message size it agrees to at `version`, which it advertises but does not check against each frame (at most 9P's 65,560; a row below 9P's least, 4,096, is refused with `{error, einval}`); and `max_heap_size`,
its process's heap bound in words, shared binaries included. `reductions` and `period_ns` bind no grant, as they bind no facet yet. The grantee's
namespace reads its `data` grant at each lookup, so the mint keeps no record of what it handed out. The volume's `packages/` directory is
the files service `packages` ([design-packaging.md](design-packaging.md#where-a-package-lies)), with a mint of its own beside `data`'s that
works the same way: each of its grants roots at `packages/`, answers `..` there itself, and takes no `.` or `..` as a name, so it reaches
nothing else of the volume, and the mount makes the directory when the volume lacks it. Only a domain the manifest grants `data`
mounts its `data` facet at `/data`, read-write and on the tree `data`, with `erx_ns:mount_facets/1` ([design-files.md](design-files.md), "A
facet's mount"): the system domain's domain service once it has read the manifest, and a session domain as `erx_session` starts
(`erx_session_app`), from the names of its granted facets its ready answer carries. The mount names the facet, never a grant, so every lookup
under `/data` goes to the grant the domain's facet registry holds for `data` at that moment. Before the first grant arrives and while the storage
domain is down, `/data` answers `eio`; once the restarted storage domain's mint has installed a new grant, the next open reaches the volume
again, while a descriptor opened before the restart keeps failing with `eio` and its writer opens the file again. A domain the manifest grants
no `data`, such as every domain of a board with no storage driver, has no `/data` mount, and finds the root's empty, read-only `/data`
directory there.

## Verification

| Case | Seeded failure, and what it shows |
| --- | --- |
| **littlefs**: a file operation under `+SDio 1` with a block read in the callback completes | `complete` made a dirty NIF: the deadline fires |
| littlefs: an injected block error fails that operation as unknown, and the next is `{error, eio}`; the driver killed under load: no later writes reach it, and after a reboot a file synced earlier is there; a littlefs worker killed ends the storage domain, whose restart mounts `/data` afresh with a file written earlier (the driver_domains suite); a block device process killed or shut down ends `erx_blk_sup`, and `storage_ctl`'s stop, start and restart do not (`erx_driver_ctl_tests`, on the host) | the error swallowed: success claimed. The owner resends: a later write is counted. Sync skipped: the file is lost. The driver restarted in place: `erx_blk_sup` outlives the kill |

## Release contract

R1 ships littlefs as the read-write file system of the data partition and of the vault's partition. Beyond what CLAUDE.md's
rule for a stopgap promises, a release commits to this for every domain, trusted or not, and no more; a gap that breaks it
blocks the release, and every other gap is a published downside below. A test marked *new* is written before the
release; the others are [Verification](#verification)'s or the fuzz campaign's.

| Commitment | What a release does | Test, and the seeded failure that proves it ran |
| --- | --- | --- |
| **Placement** | which form R1 ships is [an open decision](#open-decisions); if R1 ships the port, littlefs runs only as the storage domain's sub-space port ([design-storage.md](design-storage.md#read-write-storage)): single-threaded C under `liberx` in a sub-space holding its channel and the data area the storage domain maps into it, and nothing else, and a release manifest has no NIF form; if R1 ships the NIF form, littlefs runs in the storage domain's runtime, with the further downside the open decision names | if the port: *new*: the port's sub-space holds no slot but its channel's and no mapping of another object but its data area (the driver_domains suite reads the port's task with the root's test-only `erx_fiasco_task_placements`, [design-fiasco.md](design-fiasco.md#reporting-kernel-objects), slots and mappings apart); a port given the storage domain's window as well fails it; *new*: the production image's check refuses a release manifest that runs `erx_lfs`'s NIF form; a release manifest with the NIF form fails it |
| **Input** | the partition's bytes are untrusted, read only through littlefs's own bounds checks and checksums, and a mount that fails never writes or formats the partition ([A mount never formats](design-storage.md#read-write-storage)) | `tools/fuzz/lfs_image_fuzz.c`, *new*: built with the configuration of the form R1 ships (geometry, cache and lookahead sizes, name length), runs at its full `check-fuzz` budget under AddressSanitizer with no open finding before the release; *new*: a seeded bound removed from littlefs's directory-entry read makes it report |
| **Requests** | what a client sends through its grant (paths, sizes, offsets, and the order of its operations) is untrusted; it reaches littlefs's C code only through the decoder of the form R1 ships, which bounds every path, size and offset before littlefs sees it: for the port, the port's channel decoder, which is not yet written; for the NIF form, the argument decoding of `otp/erts/emulator/nifs/erxos/erx_littlefs_nif.c`, `get_path` and the size and offset reads beside it. `get_path` bounds a path's length (`ERX_LFS_PATH_MAX`), not a name's; littlefs refuses a name longer than its `name_max` itself. Both forms build littlefs with `erx_lfs_config` of `otp/erts/emulator/nifs/erxos/erx_littlefs.h`, which the image fuzz target already shares | *new*: `tools/fuzz/lfs_request_fuzz.c`, with its seed generator `tools/fuzz/lfs_request_target.rb` beside `lfs_image_target.rb`, drives sequences of operations (open, read, write, seek, truncate, rename, remove, sync, directory reads) through that decoder, the NIF form's under a shim of the `enif_*` calls it makes, into littlefs built with `erx_lfs_config`, over an image the sequence starts from, and runs its full `check-fuzz` budget under AddressSanitizer with no open finding before the release; seeded failure: the decoder's path-length bound removed (for the NIF form, `bin.size >= len` deleted from `get_path`), which AddressSanitizer reports as a write past the path buffer |
| **Failure** | a littlefs crash ends only its port, whose owner's supervisor restarts it once the window has answered the port's outstanding requests, and the port mounts the volume afresh; a block failure ends the storage domain, which the domain service restarts within its row's intensity (`restarts 5`, `restart_period_s 600`), and the restarted domain mounts the volume afresh; until then every request answers `{error, eio}`, nothing replays a request, and nothing resets the device in place ([Verification](#verification), [design-storage.md](design-storage.md)'s failure table); how a crafted image that makes littlefs loop or assert meets this row is [an open decision](#open-decisions) | *new*: the port killed under load: `/data` answers `eio`, then a file written earlier is read after the remount; a port restarted before its outstanding requests are answered fails. *new*: the storage domain ended six times within 600 seconds is restarted five times and then stays down, reported by the domain service; the intensity not applied, so the sixth end is restarted, fails it. The block-failure cases of [Verification](#verification) |
| **Durability** | a file synced before a driver kill or a power cut is present after the reboot; a write not yet synced may be lost | the driver killed under load ([Verification](#verification)); sync skipped loses the file. The power-cut tests of [M6](plan.md#m6-immutable-code-lasting-data) on QEMU and of [1b-I](plan.md#1b-i-the-raspberry-pi-4-on-fiasco) on the Raspberry Pi 4 |
| **Grants** | the data service grants each client one tree rooted at its principal's directory, an app's at `apps/NAME/SIGNER/` and the `packages` service's at `packages/` ([design-storage.md](design-storage.md), "The storage services and the FAT server"; [design-packaging.md](design-packaging.md#where-a-package-lies)); the read-write grant over the whole volume to every session of root's principal is a development build's alone | *new*: a session of a second principal opens a file of the first principal's directory and gets `enoent`; a grant minted at the volume's root fails |
| **Keys** | the vault's files are sealed under keys the storage domain never holds, so a crafted partition or a littlefs defect reveals no key while littlefs runs as the sub-space port; in the NIF form this holds against a crafted partition that only damages files, not against a memory defect, which reaches what the storage domain reaches, the whole machine where it holds an unconfined DMA-capable device ([Open decisions](#open-decisions); [design.md](design.md#residual-risks), "littlefs serves the vault's partition") | *new*: the vault's files read raw from the partition hold no key in the clear; a file written unsealed fails ([design-system.md](design-system.md#the-vault)) |

**Published downsides.** A release states them with its notes:

* a crafted or corrupt partition can end the port or the storage domain, and leaves its files unavailable; a partition that fails
  every mount stays unavailable and is never formatted;
* a defect in littlefs can lose files, a vault key file among them, which leaves that principal's vault `unavailable`; in the
  port form no key is revealed, and in the NIF form a memory defect can reveal every key, as the open decision says;
* any block error, deadline or driver restart ends the storage domain, and `/data` is unavailable until its restart has mounted the
  volume again;
* a memory defect in littlefs that a client's requests can reach would expose every principal's files on the volume, since the
  code that holds the whole data area runs it: the port's sub-space confines littlefs's code, not the data in it. The request fuzz
  target running its full budget clean before the release is the defence, and no grant or principal check stands between such a
  defect and the volume.

## Open decisions

littlefs's protocol stays here while the system domain's form has a manifest that uses it, and `design-storage.md`, whose
target text describes the port, states the placement and links to it.

**Which form R1 ships.** If R1 ships the sub-space port, a memory error in littlefs's C code reaches only the port's sub-space
and the volume it holds, and no key is revealed. The alternative is to ship the NIF form, which works today, with a further
published downside: a littlefs memory error corrupts the storage domain's runtime, which holds every grant of the volume and,
in the default configuration, the block driver and every window on the medium. The block device masters DMA and no device of
R1's platforms is confined ([design-fiasco.md](design-fiasco.md#devices), FD12), so that runtime can read and write all of
memory through it: a littlefs memory error reachable from a crafted partition or a client's requests is then a compromise of
the whole machine, every domain's memory and the vault's live keys included, and the Keys row's "no key is revealed" does not
hold. Only a configuration that moves the block driver out of the storage domain, into a domain that runs no littlefs, would
bound the NIF form to the volume again; no R1 manifest names one, and choosing it would need its own placement test.
Recommendation: ship the port; the port is the target
placement, so the work is not throwaway. Choosing the port adds, before the release, the production image's check that refuses
a release manifest running `erx_lfs`'s NIF form, with a release manifest that keeps the NIF form as its seeded failure
([Release contract](#release-contract), Placement).

**A crafted image that hangs or asserts.** Two known behaviours of littlefs on a damaged partition meet the Failure row
([TODO.md](../TODO.md), storage, littlefs). A directory tail that points back at itself, off the list a mount walks, makes
`lfs_dir_find` and `lfs_dir_read` loop for ever; each turn reads blocks that answer, so no block deadline ends it, and every
request of the volume waits instead of answering `{error, eio}`. littlefs's `LFS_ASSERT`s on disk state stay live, so one
reached from a damaged image aborts the code that runs littlefs: in either R1 form that is the port or the storage domain, not
the machine, but at mount it repeats on every restart. Whether each is a published downside or a residual that blocks the
release is not decided. Recommendation: the loop blocks the release, since it breaks the Failure row's answer, and its fix is
small, because littlefs is erXos's code in the tree: the cycle check a mount runs over the list it walks
(`lfs_tortoise_detectcycles`, `littlefs/lfs.c`) applied to the walks of `lfs_dir_find` and `lfs_dir_read`, which then fail
with `LFS_ERR_CORRUPT`. The assert is a published downside, since it ends only the port or the storage domain, and the restart
intensity then leaves the partition unavailable, which the first downside already states.
