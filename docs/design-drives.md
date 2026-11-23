# Drives: every medium, every format

A **drive** is a place that holds at most one medium at a time: a USB
stick, an SD card in a USB reader, or the medium of a block device the
manifest gives to no file system of its own, such as a second virtio
disk. Every drive reaches files by one path. The domain that drives the
medium's transport serves the medium **whole**, as one window, hands
that window out once, and parses none of it. One domain of its own, the
**media domain**, which holds no device, reads the medium's partition
table and mounts each partition, a **volume**, behind one process,
which names the volume's file system from its contents and parses it;
it serves every drive's volumes as files at `/media/diskN/sN`. A release
serves FAT16, FAT32 and EROFS volumes; development builds and test
images serve littlefs volumes too; erXos's F2FS joins as one row of the
same format table. The key idea is that everything a medium's bytes
reach, the table reader, each volume's process and littlefs's C code in
its sub-space, is a child of that medium's supervisor and ends with the
medium's window, and that a window is mounted at most once, so a crafted
medium ends at most its own mounts, no state of one medium reaches the
next, and "any format on any drive" is the product of one drive path and
one format table rather than a matrix of cases.

Decisions every reader needs:

* **A drive serves its medium whole, once.** The USB domain, or the
  domain that drives a block device of the drive role, runs a transport
  and one window covering the medium, and hands that window out through
  the drive's grant once. It reads no table, so nothing a medium holds
  is parsed in a domain that holds a device, and no medium is mounted
  twice, whatever restarts in the media domain.
* **One media domain holds every drive.** It holds no device, no window
  of the boot medium and nothing but the drives' grants, and it serves
  one files service, `media`, which sessions mount at `/media`.
* **Detected, never declared.** The table decides where volumes lie;
  each volume's format is what its own bytes say, by a probe that
  follows FreeBSD's `fstyp`. No manifest row, table type byte or user
  names a format.
* **A volume's failure ends its mount.** Each volume's probe and parser
  run in that volume's own process under a memory bound, and littlefs's
  C in a sub-space with a budget of its own, so a crash, an exhausted
  allowance or a memory error ends only that volume and never costs the
  media domain a restart; a crafted table ends that medium's mounts.
* **Written only when unambiguous.** A volume is written only when one
  format alone claims it, that format is one erXos writes, the medium
  flushes, and the format's own state allows it; otherwise it is
  read-only, and a medium whose flush fails is refused.
* **One finish for eject and for the machine's end.** A volume's last
  request closes it, writes what it holds and flushes, so a write it
  acknowledged survives `eject` and an ordered end on a medium that
  flushes.
* **EROFS from a drive is unauthenticated, and kept apart.** The EROFS
  decoder is shared. The system's images reach it only through
  `erx_erofs:mount/2`, which takes only a hash-checked image; a drive's
  reach it only through the media application's own frontend and block
  source, which only the media domain's release holds. E1 holds for the
  system's own images as it stands.
* **littlefs from a drive is for development and tests, as its port.**
  No release serves it. Where it is served, each littlefs volume has its
  own sub-space that holds its channel and data area alone, and its
  owner checks every block it asks for against the volume and every
  write against the volume's right to be written.

## Context

### What is matched

FreeBSD's partition and file-system detection, from the FreeBSD source
at commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`
([References](#references)):

* **An MBR, or a boot sector.** GEOM's MBR scheme takes sector 0 as a
  table when it ends in `0x55 0xAA` and every entry's status byte is
  `0x00` or `0x80`, unless all four entries are zero and the sector
  holds a plausible BIOS parameter block, a bytes-per-sector field that
  is a power of two from 512 to 4096 and a sectors-per-cluster field
  that is a power of two from 1 to 128, in which case the sector is a
  boot sector and the medium has no table (`g_part_mbr.c:176-191`,
  `:413-469`). It skips an entry of type `0x00` or `0xEE` and one whose
  start or length is 0 (`:505-508`).
* **A GPT.** GEOM's GPT scheme wins over the MBR when sector 0 holds an
  entry of type `0xEE` and sector 1 holds the header's signature, or,
  with no signature there, the medium's last sector does
  (`g_part_gpt.c:861-926`, the `0xEE` test at `:903`, the backup's at
  `:919-926`). It reads both headers, the backup at the sector the
  primary names as its alternate when the primary passed, and at the
  medium's last sector otherwise (`gpt_read_hdr`, `:441-542`, the
  choice at `:454-462`). A header is taken only if its CRC-32 checks,
  its revision is at least `GPT_HDR_REVISION` (`:487`), its usable area
  lies after sector 1 and before the last sector (`:500-504`), and its
  entry array's first and last sectors lie inside the medium and outside
  the usable area (`:512-524`); an entry array only if its CRC-32 checks
  and it is at most 4,096 entries of at most 1,024 bytes (`gpt_read_tbl`,
  `:544-604`; `:150`, `:159`). The primary copy is used unless its array
  failed, when the backup is (`g_part_gpt_read`, `:930-1092`, the
  choice at `:1000-1043`).
* **Integrity.** A table with an entry that starts before the first
  usable sector, ends past the last, ends before it starts, or overlaps
  another entry is refused whole, by default (`g_part.c:143-147`,
  `g_part_check_integrity`, `:325-436`, called at `:2034`).
* **The file system's name.** `fstyp` reports the file system a provider
  holds by trying each format's header in a fixed order, the header at
  the largest offset first, since a volume formatted one way and then
  another may keep the first format's header (`fstyp.c:57-109`). Its FAT
  test is the `0x55 0xAA` signature, or the Raspberry Pi Pico
  bootloader's zero signature behind its jump bytes, and then a non-zero
  16-bit FAT size with `FAT` at the FAT12 and FAT16 type field, or a
  non-zero 32-bit FAT size with `FAT` at FAT32's (`msdosfs.c:48-60`,
  `:77-115`). Its NTFS test is the system id `NTFS    ` at byte 3 of
  sector 0 alone (`ntfs.c:146-147`).
* **`/media`.** FreeBSD's automounter mounts removable media at
  `/media/KEY`, KEY the volume's label or its device name, mounting each
  format by `fstyp`'s name and refusing, with a log line naming it, a
  format it cannot mount (`special_media:7-31`, `:34-69`); the map is
  commented out of the default `auto_master`, with the options
  `nosuid,noatime,autoro` (`auto_master:5`).

erXos keeps the table tests, the whole-table refusal, the probe's order
and its names. It differs where its model differs, each difference
stated where it is made: a volume lies at `/media/diskN/sN`, numbered
as macOS numbers disks and partitions, since `diskN` names a drive
already ([design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers));
a volume's label is shown, not used as a path; links on a drive are not
followed; no extended partition's chain is followed; a GPT is read only
behind its protective entry, and behind one it is the only reading; and
a GPT's usable area must lie apart from every metadata sector the reader
knows, where FreeBSD checks only the array's two ends.

littlefs v2.11.3, the tree's copy (`littlefs/ORIGIN.md`), mounts a
volume only when the superblock's block size equals the configuration's
(`lfs.c:4618-4622`) and its block count equals the configuration's
unless that is 0 (`:4608-4616`). Its specification at the same commit
puts the superblock first in the metadata pair of blocks 0 and 1 and its
name tag first in the pair, so the string `littlefs` lies at byte 8 of
a valid superblock block (`SPEC.md:444-447`); the mount itself finds
the superblock by matching tags, not by offset (`lfs.c:4496-4520`).

### What it builds on

* The block service's transport contract and windows, the write path
  and its trial rule U4, and the deadlines each layer keeps
  ([design-storage.md](design-storage.md#data-model)).
* USB media and their lifetimes: a medium is a fresh reference from its
  unit's readiness to its end, every request carries it, and its block
  service ends with it; drives are places numbered across the machine
  ([design-usb.md](design-usb.md#media-and-drives),
  [design-usb.md](design-usb.md#mass-storage-reaches-the-file-servers)).
* Windows reach their holders as grants of the domain that serves them,
  again after that domain's restart
  ([design-system.md](design-system.md#devices), "Partition windows").
* `erx_fs`, its grants and its keepers, which answer a waiting read or
  write later and answer `eio` when they end, and its freezing
  checkpoint, which closes mutation admission at every grant
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
* The ordered end, which freezes every service on its durability facet
  under one deadline ([design-system.md](design-system.md#shutting-down)).
* A facet's mount, read at each lookup against the facet registry, and
  the resolver's rule that follows no link in a tree it reached through
  `{facets, svc}`
  ([design-files.md](design-files.md#building-binding-and-mounting),
  [design-app-trees.md](design-app-trees.md#links)).
* The `status` and `ctl` files of a tree its owner serves
  ([design-app-trees.md](design-app-trees.md#a-status-line),
  [design-app-trees.md](design-app-trees.md#commanding-ctl)).
* The FAT server's format rules
  ([design-storage.md](design-storage.md#removable-media-fat)); the EROFS reader
  and E1 ([design-storage.md](design-storage.md#reading-erofs-images));
  littlefs's sub-space port and its owner's deadline
  ([design-storage.md](design-storage.md#read-write-storage),
  [design-programs.md](design-programs.md#a-program-is-a-port)), and
  littlefs's stopgap rules
  ([design-stopgap.md](design-stopgap.md#littlefs-on-a-drive)).

## Requirements

* **DR-R1. Any drive, any served format.** Every drive serves FAT16,
  FAT32 and EROFS volumes, and in development builds and test images
  littlefs volumes, on a medium with an MBR, a GPT or no table; every
  other format, FAT12 among them, is named and refused. A new format is
  one row of the format table and a new kind of drive one transport.
* **DR-R2. Confinement.** A crafted volume ends at most its own mount,
  and a crafted table its own medium's: never the media domain, another
  drive's media, the domain that serves its transport, or the boot
  medium's storage. No C parser of a medium runs where it can reach a
  device, a window or another volume. What any code can still reach
  through the kernel, the CPU and a device's DMA is stated in
  [Security](#security).
* **DR-R3. The authenticated path intact.** E1 holds for the system
  partition and every package as it stands: no byte of a drive reaches
  the EROFS decoder in a runtime that mounts a package or serves the
  `system` tree.
* **DR-R4. A medium's state dies with it, and it is mounted once.** No
  process, sub-space or cache holding a medium's state outlives the
  medium's mount; an open file of an ended mount answers `eio`; a medium
  is mounted at most once, and a new medium mounts afresh.
* **DR-R5. Never written by a misreading, never lost by an orderly
  end.** A volume is written only when one format alone claims it,
  erXos writes that format, and the medium flushes; every other volume
  is read-only or refused, with the reason shown. On a medium that
  flushes, every write a volume acknowledged before an `eject` or an
  ordered end that finished is on the medium.
* **DR-R6. Untrusted input.** Every parser of a medium's bytes is
  bounded and has a fuzz target; text a medium supplies reaches a sink
  only through its escape; a link on a drive is never followed.
* **DR-R7. No new mechanism.** Drives reach their files through windows,
  grants, one files service, `erx_fs` keepers and its freeze, the
  littlefs port and a `status` and `ctl` pair, each named here.
* **DR-R8. Authority.** Which domains see which drives is the manifest's
  `media` facet rows' and nothing else's.

Non-goals: FAT12, exFAT, NTFS, ext2, UFS, HFS+, APFS and ISO 9660, each
named by the probe and refused; littlefs volumes in a release; logical
partitions inside an MBR's extended partition; repairing a table or a
volume; media whose blocks are not 512 bytes; booting, updating or
loading code from a drive.

## The construction

### One path from medium to files

```text
 the transport's domain (the USB domain, or a block device's driver domain)
   medium ---> one window, the medium whole ---> drive grant, diskN (once per window)
                                                      |
 the media domain                                     v
   drive process (one per drive; parses nothing)
     on the first walk of diskN after a medium arrives:
       medium supervisor (one per medium; ends when the window ends)
         reader: table (MBR | GPT | none) -> volumes s1..sN, then ends
         one volume process per volume: probe, then mount:
           msdosfs (the FAT server) | erofs | littlefs (owner + port sub-space)
   media tree, /media: each request on a volume goes to its volume process
```

1. **The medium.** The transport's domain runs, for each medium, the
   transport and one window covering every sector of it, and the drive's
   grant answers that window's pid once. That domain reads no sector of
   the medium on its own behalf.
2. **The volumes.** In the media domain, a reader process under the
   medium's supervisor reads the table with `erx_media_table`, a pure
   function of the sectors it asks for, which answers the volumes and
   where each lies, or refuses the table whole
   ([The table](#the-table)), and starts one volume process for each
   volume.
3. **The formats.** Each volume process reads a fixed set of its own
   sectors and names its format with `erx_media_probe`, a pure function
   over them ([The probe](#the-probe)).
4. **The mounts.** A volume whose format the format table serves mounts,
   read-write or read-only by one rule
   ([The writable rule](#the-writable-rule)); one it does not serve
   stays, unmounted, to say why.
5. **The files.** The media tree routes every request on a volume to its
   volume process and serves the rest itself
   ([The media tree](#the-media-tree)).
6. **The finish.** `eject` and the machine's ordered end give each
   volume its last request, which closes it, writes what it holds and
   flushes ([Finishing a volume](#finishing-a-volume)).
7. **The end.** When the medium's window ends, or its mount is finished,
   the drive process ends the medium's supervisor, and with it every
   volume process and every littlefs port; a node a fid holds names its
   volume process, so every later request on it answers `eio`.

### How each requirement follows

* **DR-R1.** Steps 2 to 7 do not depend on the transport: a medium is a
  window, whoever serves it. They do not depend on the format either: a
  volume is a range of sectors and a format name, and the format table
  maps the name to a volume module. FAT, EROFS and littlefs are its
  rows; F2FS is one more ([F2FS](#f2fs-when-it-joins)).
* **DR-R2.** Every byte of the medium is parsed in the media domain,
  which holds no device. The table runs in the medium's reader, each
  volume's probe and format in its own volume process, both under a
  memory bound, and littlefs's C in its own sub-space under a budget of
  its own, whose block requests its owner checks against the volume; the
  medium's supervisor and the volume processes are temporary children,
  so no failure of theirs is counted against any restart intensity, and
  the drive process, which touches no byte of the medium, is the only
  process of a drive the media domain's supervisor restarts. The media
  domain's budget holds every allowance at once
  ([Time and memory](#time-and-memory)).
* **DR-R3.** The decoder's source entry is called only by the
  authenticated frontend and by the media application's frontend, whose
  block source no release but the media domain's holds
  ([EROFS, unauthenticated](#erofs-unauthenticated)).
* **DR-R4.** Step 7: the supervisor is the medium's, so its end takes
  every holder of the medium's state with it, the EROFS block cache and
  the littlefs port included. The grant answers each window once, so no
  mount of a medium follows another of the same medium, after an eject
  or after a restart of the drive process or the media domain, while the
  first one's requests may still be in flight.
* **DR-R5.** The writable rule is the one place that decides writing,
  from the probe's answer, the format, the mount's flush and the
  format's state. The finish is the one way a volume is closed while its
  medium stays, and every request reaches the volume through its
  process, so the finish is its one admission barrier.
* **DR-R6.** The table reader, the probe and each format have fuzz
  targets ([Fuzz targets](#fuzz-targets)); labels and names reach the
  `status` file through the field escape; the resolver follows no link
  in the `media` tree.
* **DR-R7.** [The mechanisms used](#what-it-builds-on) are all
  existing. The names this design adds are a window role, `drive`; one
  service, `media`, with its mount point, its durability facet and its
  place beside `{facets, svc}` in the resolver's no-follow rule; the
  decoder's source entry, `erx_erofs:mount_source/2`; the probe's
  table, `abi/formats/probe.txt`; two limits, `media_volumes_max` and
  `media_volume_bytes`; two statfs types, `msdosfs` and `media`; the
  node argument of `erx_fs`'s `statfs` callback; and the modules of
  `erx_media`.
* **DR-R8.** A session reaches `/media` only through a `media` facet
  the manifest grants it.

### What disappears

* The window row per partition of a drive, its partition number, the
  drive grant's `no_partition`, and the partition process in the USB
  domain: a drive's grant is the medium whole, and the medium's table is
  read where nothing else of value lies.
* The FAT server's own mounting on each walk, its unmount on a window's
  end, and its retry of a refused mount at the next walk: a volume
  process is the mount, and the medium's supervisor ends it.
* A record of mounted media that must survive a restart: the grant hands
  each window out once.
* A placement rule per format: every format runs in its volume's
  process, and the one exception, C, runs in its volume's sub-space.
* The `fat` window role and the exchange partition of the boot medium: a
  medium to exchange files on is a drive, whatever its format.
* The hash-checking reader's `unchecked` mode, which only tests used:
  the tests read images through the media domain's block source, so
  every handle of `erx_verity` has a tree.
* A tree of stable names for media: a volume's label and serial number
  are lines of its drive's `status` file.

## Drives

### A drive and its medium

A drive is a place the manifest names, `diskN`, served by the domain
that drives its medium's transport:

* **A USB drive** is one of the drives the manifest names on a USB
  domain's controllers. A unit's medium, once ready, takes the lowest
  free of them, and frees it when it ends
  ([design-usb.md](design-usb.md#media-and-drives)).
* **A block device's drive** is a block device whose one window row has
  the `drive` role: its medium is the device's, present for as long as
  the device's driver runs. The domain that holds the device runs
  `erx_blk` with that device's transport and serves its medium as the
  drive instead of reading the boot medium's layout. Such a domain holds
  that device and nothing else, so property 9 of
  [design-system.md](design-system.md#the-manifest) holds for an
  unconfined one.

For each medium, the serving domain runs the transport the storage
design defines and one window process whose sectors are the medium's
whole capacity ([design-storage.md](design-storage.md#data-model)),
writable unless the boot is a trial, when the write path refuses every
write to it with `erofs` (U4). The drive's grant, `erx_blk_drive`,
answers one request, `window`: `{ok, Window}`, the pid of the medium's
window, the first time it is asked while that window lives;
`{error, taken}` each later time; and `{error, no_medium}` while the
drive holds none. The grant lives as long as its serving domain, learns
of each window as the medium's block service starts it, and forgets it
when the window ends ([design-usb.md](design-usb.md#concurrency)).
Holding the grant is holding whatever medium the drive holds, whole,
once: a holder that lost the window, by a restart of its own, gets
`taken` until the medium is taken out and put back, so no medium is
mounted twice and no newer mount meets an older one's requests at the
window.

### Manifest rows

A drive is one window row: role `drive`, no partition, the drive's
number in its `drive` field, on the row of a `usb` device or of a
`block` device, and the media domain as its holder. The manifest check
refuses:

* a `drive` window with a partition, or without a drive number; a drive
  number on a window of another role;
* a drive number named twice;
* a `block` device with a `drive` window and any other window;
* a drive window held by a domain other than the media domain, or two
  domains holding drive windows;
* a media domain that holds a unit, a window of any other role, or a
  facet of a storage service;
* a media domain whose budget is below what its volumes can use at once
  ([Time and memory](#time-and-memory));
* more drives on one USB domain's controllers than `usb_drives_max`;
* a `media` facet row with rights `rx`.

The media domain's row allows it sub-spaces, for the littlefs ports,
serves the one service `media`, and gives the system domain its
durability facet ([Finishing a volume](#finishing-a-volume)). The
release check refuses a release other than the media domain's that names
`erx_media`; a media domain's release that names `erx_storage`, whose
`erx_littlefs` loads the NIF, or `erx_blk`, the block driver; and, in a
release build, a media domain's release that names `erx_lfs` or carries
the littlefs port.

## Reading a medium

### The table

`erx_media_table:read(Capacity, Sectors)` is pure: it names the sectors
it needs, sector 0, then a GPT's headers and arrays, and the reader
process reads them through the window and hands them back. Its answer is
`{Scheme, Volumes}`, the scheme `mbr`, `gpt` or `none` and each volume's
number, first sector and length, with the entries it serves not, or
`{refused, Finding}`. Every field is read by binary matching on a
sector of exactly 512 bytes, and every sum is an Erlang integer, so no
crafted field wraps.

1. **An MBR**, as FreeBSD's probe judges one: sector 0 ends in
   `0x55 0xAA` and every status byte is `0x00` or `0x80`, and the four
   entries are not all zero over a sector whose bytes-per-sector and
   sectors-per-cluster fields are plausible. A sector that is not one is
   no table.
2. **A GPT**, when that MBR holds an entry of type `0xEE`. Such a medium
   is read as a GPT or its table is refused: it never falls back to its
   MBR entries or to no table. It has two copies, each a header and its
   entry array. The primary header is read at sector 1, and the backup
   header at the sector the primary names as its alternate when the
   primary passed, and at the medium's last sector otherwise. A header
   passes when it begins with `EFI PART`, its size is 92 to 512 bytes,
   its CRC-32 over that size with its own field zeroed checks, its
   revision is at least FreeBSD's `GPT_HDR_REVISION`, it names the
   sector it was read from as its own and another sector inside the
   medium as its alternate, its usable area's first sector is at most
   its last, and its entry array lies inside the medium, holds at least
   one entry, of at least 128 bytes and a multiple of 8, and is at most
   16 KiB, room for 128 entries of 128 bytes; an array passes when its
   CRC-32 checks. The primary copy is taken when its header and its
   array pass, and the backup otherwise; when neither passes, the table
   is refused, naming the primary's finding. Neither copy is ever
   written. An entry whose type GUID is all zero is unused; each other
   entry is volume N, N its index from 1, with its name, 36 UTF-16 code
   units, and its unique GUID kept for the `status` file.
3. **A GPT's metadata.** The taken copy's usable area must lie apart
   from every sector the reader knows the GPT to occupy: sector 0, both
   headers' sectors, the taken copy's array and, when the other copy's
   header passed, its array. Each array is compared as a range, so an
   array that encloses the usable area is caught, which an array's ends
   alone would miss. A usable area that meets any of them refuses the
   table. An array the reader could not validate is not known to it, and
   nothing is claimed of its sectors.
4. **An MBR's entries**, when none is of type `0xEE`, which only a GPT
   reads: an entry of type `0x00`, and one whose start or length is 0,
   is skipped; one of an extended type, `0x05`, `0x0F` or `0x85`, is
   listed as `extended` and not served, since no chain of extended boot
   records is followed; each other entry is volume N, N its place from 1
   to 4.
5. **No table**: the medium is one volume, number 1, from sector 0 to
   its end, as FreeBSD mounts `da0` itself. A stick's files therefore
   lie at `s1` whether or not its maker wrote a table.
6. **Integrity**, as FreeBSD checks it by default: every entry the
   scheme lists, extended ones included, must run forward, its last
   sector at or after its first, start at or after the first usable
   sector (sector 1 for an MBR, the usable area's first for a GPT), end
   within the medium (for a GPT, within its usable area), and overlap no
   other. One that breaks it refuses the table whole, naming the
   entries. So no two volumes share a sector, whatever order the entries
   come in, no volume covers sector 0, and no GPT volume covers a header
   or a known array.
7. **A bound**: at most `media_volumes_max` volumes are served, 8, the
   first in entry order; the `status` file counts the rest as not
   served.

Volume N is the directory `sN` of its drive's tree. A sector request of
a volume, from any format, is placed by one pure function,
`erx_media_table:place/3`, which adds the volume's first sector and
refuses with `erange` a request that reaches past its length, so no
format reaches a sector outside its volume.

### The probe

`erx_media_probe:format(Read)` runs in the volume's own process and
reads, through the volume's placement, a fixed set of sectors. It
answers the formats whose signature it finds: the first in the order
below that matches, which **selects** the volume's format, and every
other that does. The order is `fstyp`'s, the header at the largest
offset first, with erXos's formats placed by where their headers lie:

| Order | Name | Served | Signature, from |
| --- | --- | --- | --- |
| 1 | `ufs` | no | UFS1 or UFS2 magic in a superblock at 65,536, 8,192, 0 or 262,144 bytes (`sys/ufs/ffs/fs.h:68-76`, `:457-458`) |
| 2 | `cd9660` | no | the volume descriptor's `CD001` at 32,768 bytes (`fstyp/cd9660.c:38-50`) |
| 3 | `hfs+` | no | `H+` or `HX` at 1,024 bytes (`fstyp/hfsplus.c:42`, `:106-112`) |
| 4 | `ext2fs` | no | the ext2 magic in the superblock at 1,024 bytes (`fstyp/ext2fs.c:39-63`) |
| 5 | `f2fs` | when it joins | F2FS's magic at 1,024 bytes (`abi/formats/f2fs.txt`) |
| 6 | `erofs` | yes | EROFS's magic at 1,024 bytes (`abi/formats/erofs.txt`) |
| 7 | `littlefs` | in development builds and test images | `littlefs` at byte 8 of block 0 or of block 1, 4 KiB blocks, where littlefs's specification puts the superblock's name (`SPEC.md:444-447`) |
| 8 | `apfs` | no | `NXSB` in the container superblock at byte 0 (`fstyp/apfs.c:77-93`) |
| 9 | `exfat` | no | `EXFAT   ` as the boot sector's file-system name (`fstyp/exfat.c:333`) |
| 10 | `msdosfs` | FAT16 and FAT32 | `fstyp`'s FAT test (`fstyp/msdosfs.c:48-115`), and the FAT type from the volume's count of clusters |
| 11 | `ntfs` | no | `NTFS    ` as the boot sector's system id (`fstyp/ntfs.c:146-147`) |

The signatures, each with its offset, bytes and source, are the rows of
one checked-in table, `abi/formats/probe.txt`, from which the build
generates the probe's constants. FAT's row is code, since it reads
fields, not one string: the FAT server's boot-sector decoder, which
gives the probe both the test and the type, so the type has one source.
A FAT12 volume is refused by name there: `sN msdosfs`, `sN_fat 12`,
`sN_mount not served FAT12`, since FAT12's entries of a byte and a half
would need a decoder and a write rule of their own. littlefs's row is
the specification's statement, which the host tests check on volumes
formatted, modified, compacted and cut mid-commit
([Host tests](#host-tests)); littlefs's own mount, in its port, stays
the test of whether a volume is one. A volume where none matches is
`unknown`. A volume too short for a signature's sector simply lacks
that signature.

The selected format is the volume's only reading. A volume whose
selected format is not served is refused by that name, as FreeBSD's
automounter refuses a format it has no program for: `s1 exfat`,
`s1_mount not served`. A volume whose selected format fails its mount
is `failed`, and nothing falls through to another format the probe
found: a format that fails its own checks says the bytes are not what
its header claims, and reading them as the next format is the
misreading DR-R5 forbids. Every name the probe found is shown in the
`status` file.

## Volumes

Each volume has one process, `erx_media_volume`, a temporary child of
its medium's supervisor, under the memory bound of
[Time and memory](#time-and-memory). It probes its volume, then holds
its format's state and runs its format's operations one at a time, in
the order they arrive: the FAT server's state, the EROFS reader's mount
and cache, or littlefs's owner and its port. Its process is the
volume's mount: the mount is made when it starts, and ends when it ends.

| Format | Module | Writes | Served by |
| --- | --- | --- | --- |
| `msdosfs` | `erx_fat`, the FAT server ([design-storage.md](design-storage.md#removable-media-fat)) | FAT16 and FAT32 | every build |
| `erofs` | `erx_media_erofs` over the EROFS decoder ([EROFS, unauthenticated](#erofs-unauthenticated)) | never | every build |
| `littlefs` | `erx_lfs`'s owner over the littlefs port ([littlefs, through its port](#littlefs-through-its-port)) | yes | development builds and test images |

### The writable rule

A volume mounts **writable** exactly when all of these hold, and
otherwise **read-only**, naming in its `status` line the first that
does not:

1. its format is one erXos writes on a drive (`format`): FAT16, FAT32 or
   littlefs, not EROFS;
2. the probe found its format alone (`also NAME`), since a medium
   formatted twice may keep the first format's header, and writing the
   wrong one destroys the other's files;
3. its mount's one flush, sent before anything is written, answered `ok`
   (`no flush` when it answered `enotsup`, a medium that cannot flush);
4. its format's own state allows it: a FAT volume's dirty flag is clear
   (`dirty`).

A flush that answers anything else, `eio` or the window's end, **refuses**
the mount, with nothing written: the volume shows `refused` with the
answer, and every request on it answers `eio`. A refusal is not a
read-only mount, since a flush that fails says that this flush failed,
not that the medium cannot flush, and a read-only mount would show a
failing medium as a working one. Each outcome holds until the medium
ends: the medium is mounted once, so a refusal is tried again by taking
the medium out and putting it back, which a failing or departed medium
needs anyway. A grant whose rights are not `rw` refuses every write
before it reaches a volume, whatever the rule decides (F5 of
[design-files.md](design-files.md#invariants)).

### FAT

The FAT server serves one FAT16 or FAT32 volume as the storage design
defines FAT's names, attributes, durability and bounds
([design-storage.md](design-storage.md#removable-media-fat)), with sector reads,
writes and flushes through its volume's placement. Its mount decodes the
boot sector with the decoder the probe used, and shows the type as
`sN_fat`, `16` or `32`. The volume label, from the boot sector or the
root directory's label entry, and the volume serial number are shown as
`sN_label` and `sN_serial`, so a script finds one stick again by them
whatever drive it lands in.

### EROFS, unauthenticated

A drive's EROFS volume is a stranger's image: no hash tree the boot
image pins covers it, and a root hash the medium carries would
authenticate nothing. The media domain reads it unauthenticated, through
the shared decoder and a frontend and block source of its own:

* **The decoder.** `erx_erofs` decodes an image from blocks it reads
  through its mount's source, a function from a block range to the
  blocks or `{error, eio}`, and checks every field it reads, as the
  storage design states. `erx_erofs:mount_source/2` mounts over such a
  function. `erx_erofs:mount/2`, E1's entry, takes only an
  `erx_verity` handle and mounts over that handle's reads; it is the
  decoder's one caller in the system's runtimes.
* **The source.** `erx_media_blocks`, a module of `erx_media`, reads an
  image's 4 KiB blocks, eight sectors each from the volume's start,
  through the volume's placement, with the per-call bound and the
  answer handling of the hash-checking reader and no hash.
* **The frontend.** `erx_media_erofs`, the volume module, mounts the
  volume with `erx_erofs:mount_source/2` over `erx_media_blocks` and
  serves it from its root with the same `erx_fs` callbacks over the
  decoder that serve the `system` tree, one module, `erx_erofs_tree`,
  rooted at `apps/` for the `system` tree and at the image's root for a
  volume. Its reads run in the volume's process, not the client's grant,
  so a structure the decoder cannot decode fails that operation, and
  anything worse ends that volume.
* **The separation.** Two facts keep a drive's bytes from the system's
  runtimes. Placement: the source and the frontend lie in `erx_media`,
  which no release but the media domain's holds (the release check,
  [Manifest rows](#manifest-rows)), and the media domain holds no window
  of the boot medium, so its source never reads a system partition
  (PW1). Calls: only `erx_erofs:mount/2` and `erx_media_erofs` call
  `mount_source/2`, a chokepoint check, since Erlang has no visibility
  between modules short of export; so in the system domain, the
  storage domain that serves `system` and every session that mounts a
  package, every block the decoder reads came through `erx_verity`,
  whose every handle has a tree.

Every structure the decoder reads is checked as the storage design
states, an offset, a size or an inode number outside the image failing
the operation with `eio`; on a drive those checks are the defence they
were written to be, and the reader's fuzz target is the test of it.
**Uncompressed images only.** What the decoder implements is what fsimg
writes: 4 KiB blocks, no incompatible feature, compact and extended
inodes, the plain and inline layouts, no compression. A drive's EROFS
volume is served when it is made that way, an image Linux's
`mkfs.erofs` writes included; whether its default options make one is
unverified, and a black-box run in the Linux oracle guest settles it
([Verification](#verification)). Everything else is refused by name,
and never read as something else:

* **compression**: a superblock that declares a compression feature,
  one of the bits `abi/formats/erofs.txt` names from `erofs_fs.h` as
  compression's, fails the mount with `erofs: compressed images are not
  supported` in `sN_mount`; a compressed inode in an image that declares
  none answers `enotsup` when it is reached, its diagnostic saying the
  same;
* **any other incompatible feature**, another block size, or extended
  superblock slots fail the mount with the bits or the size named, as
  the reader names them now;
* **a chunked inode** answers `enotsup` when it is reached.

Decompression is not part of this design: LZ4, and LZMA, DEFLATE and
Zstandard, the other algorithms EROFS defines, are a later item in
[todo-storage.md](todo-storage.md). LZ4 is also the decompressor the
storage design names for the slots' system images should the media
lack room ([design-storage.md](design-storage.md#data-model)), so one
primitive would serve both; on a drive it would parse a stranger's
compressed bytes in C in the media domain's runtime, where a defect in
it reaches every drive's volumes, which its design must weigh.

The image's label and UUID, from its superblock, are shown as
`sN_label` and `sN_serial`. A drive's EROFS tree serves its links as
links; the resolver does not follow them ([Links and
rights](#links-and-rights)).

### littlefs, through its port

littlefs volumes are served by development builds and test images, so
the drives' tests can mount littlefs sticks; no release serves them, and
a release's probe names a littlefs volume and refuses it as not served
([design-stopgap.md](design-stopgap.md#littlefs-on-a-drive)). littlefs
is C, so where it is served it runs only in its target placement, the
**port**: a sub-space of the media domain for each littlefs volume,
holding its channel and its data area and nothing else, with the shape
of a program and a budget of its own
([design-storage.md](design-storage.md#read-write-storage),
"littlefs, the stopgap"; [design-programs.md](design-programs.md#a-program-is-a-port);
[Time and memory](#time-and-memory)). The volume process is the port's
owner, `erx_lfs`: it sends the volume's operations on the channel and
serves the port's block requests itself, checking each against two
things the volume holds:

* **its sectors**: a request is placed in the volume, and one that
  reaches past it is refused with an error answer;
* **its right to be written**: a program or an erase is answered only
  while the volume is writable, from the moment the writable rule admits
  it, which for littlefs is before its mount since rule 4 is FAT's
  alone, until its finish. On a read-only volume, and after the finish,
  each is refused with an error answer, which littlefs takes as an I/O
  error, so a port whose code a crafted volume has taken over writes
  nothing the volume's mount did not allow.

So:

* a crash, a littlefs assertion or the port's exit ends the port, which
  the owner sees as `{exit_status, N}` and ends with it: the volume is
  `failed`, its requests answer `eio`, and nothing else ends; a port
  that stops answering is ended at its owner's deadline, the same way;
* a memory error that a crafted volume steers reaches the port's
  sub-space, its channel, and through its owner's checks the sectors of
  its own volume, as far as the volume may be written, and the answers
  to its own volume's requests, which the owner decodes as untrusted
  input; it reaches no window, no other volume, no device and no runtime;
* the port ends with its volume's process, which ends with the medium,
  so no littlefs code that read one medium runs when the next arrives.

The port is built with `erx_lfs_config`, the geometry of the data
partition's volumes and of the fuzz targets: 4 KiB blocks, 512-byte
reads and programs, and a block count equal to the volume's length in
blocks. A volume of another geometry fails its mount with littlefs's
own check, shown as `geometry` in `sN_mount`, so no geometry is taken
from the medium at run time and the fuzz targets cover exactly what
mounts. littlefs volumes are read-write: littlefs's copy-on-write
commits leave a removed stick at its last commit, as a power cut does,
which FAT's batches only approach. No drive volume reaches the NIF
form: the media domain's release holds no `erx_littlefs`
([Manifest rows](#manifest-rows)).

### F2FS, when it joins

erXos's F2FS joins as the format table's `f2fs` row once its read path,
the walk, node, directory and replay steps with their fuzz targets, is
built ([design-f2fs.md](design-f2fs.md)). Until then the probe names it
and refuses it. Joining takes:

* **A volume module** that runs F2FS's volume process as the volume's
  process: a volume that fails ends its mount alone, where on the data
  partition it ends the storage domain;
* **read-only first**, with the in-memory replay of a read-only mount
  (F2-R5), and read-write once F2-R1 to F2-R3 hold, under the writable
  rule, since F2FS was made for flash media and the rule is the only
  gate;
* **its mount allowance** taken from `media_volume_bytes`, so a volume
  larger than the allowance admits answers `enomem`, refused by name;
* **qid paths drawn per mount**, as FAT's and littlefs's are, since its
  own 64-bit path does not fit beside the mount's number
  ([Identity](#identity));
* **a finish**, its checkpoint, as every writable format has
  ([Finishing a volume](#finishing-a-volume));
* the clean room's legal review before any distribution, as for the
  data partition.

### Finishing a volume

A volume is closed while its medium stays only by **finish**, a request
of its process that is its last. The process answers every request it
holds or was sent before it, as it answers any; then, for a writable
volume, it writes what it has not yet written, FAT's last batch with its
dirty flag cleared or every open littlefs file synced, and has the
window flush. From then the volume is closed: every later request on it
answers `eio` without reaching its format, and a littlefs owner refuses
its port's programs and erases. The finish answers `ok`, or the first
failure of its writes or its flush. Every request reaches a volume only
through its process, which takes them one at a time, so the finish is
the volume's one admission barrier: a write answered before it is in
what its flush made durable, and none is answered after it.

Two things finish volumes:

* **Eject**, written to a drive's `ctl`: the drive process marks the
  medium `ejecting`, so no walk mounts anything more of it, sends every
  volume of the medium its finish at once, and waits for each answer;
  then it ends the medium's supervisor and marks the medium `ejected`.
  The write answers `ok` when every finish answered `ok`, `eio` when one
  did not or its volume had already ended, the medium being ended
  either way, and `enxio` when the drive holds no mounted medium. Walks
  of the drive, and a second `eject`, wait for it; the second then
  answers `enxio`. The ejected medium is not mounted again, since its
  window was handed out once: taking the stick out and putting it back
  makes a new one. The word promises what macOS's and FreeBSD's ejects
  promise of a stick, that it may be pulled without loss; nothing moves,
  since no command of the SCSI subset ejects a medium
  ([design-usb.md](design-usb.md#the-scsi-subset)).
* **The ordered end.** The media service takes the freezing checkpoint
  on its durability facet, which only the system domain holds, as the
  storage services do ([design-storage.md](design-storage.md#interfaces)):
  `erx_fs` closes mutation admission at every `media` grant and lets
  each finish the writes it admitted
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
  "Freezing"); the media tree then finishes every mounted volume of
  every drive at once and answers when all have; and every later write
  answers `erofs`. It offers no checkpoint without a freeze, which only
  the vault uses. The ordered end's deadline, and its record of each
  outcome, are the coordinator's
  ([design-system.md](design-system.md#shutting-down)); a medium that
  cannot finish within them loses what its volumes had not written, as
  on a power cut, and its FAT volumes show `dirty` at their next mount.
  A trial reads no drive, so the media service's outcome is recorded
  and logged and does not decide between a trial and a reset.

### Time and memory

* **Memory.** Each volume's process, and the medium's reader, runs with
  a `max_heap_size` of `media_volume_bytes`, binaries included. A
  littlefs port's budget is carved from the media domain's with its
  guarantee and its cap both `media_volume_bytes`, so the port draws on
  nothing the runtime or another volume was promised, and a carve the
  media domain cannot promise fails that mount with `enomem`. A process
  past its bound is ended by the runtime, and a port past its budget has
  its allocation refused, which ends that volume alone. The media
  domain's budget holds all of these at once: the manifest check refuses
  a media domain whose budget is below two allowances for each volume
  its drives can mount, `media_volumes_max` for each drive, one for the
  process and one for a port, and one allowance for each drive's
  reader, the runtime's own needs coming above that. So no set of
  crafted volumes exhausts the runtime.
* **Time.** Every operation of an Erlang format does bounded work: each
  loop is bounded by the size of the structure it walks, as the FAT
  server's and the EROFS reader's designs state, and each of its sector
  requests by the window's deadline, 35 s
  ([design-storage.md](design-storage.md#data-model)). littlefs's port
  is C and may spin without asking for a sector, so its owner keeps the
  deadline the storage design gives it, 60 s (`DEADLINE_MS` in
  `erx_lfs.erl`), and ends a port that misses it: the volume is
  `failed timeout`. Until then the port runs in its own group, under
  the media domain's sub-space group, and shares the domain's CPU with
  its runtime and its other volumes. The tree's requests to a volume
  carry no timer of their own: they end when the volume answers or
  ends.

## The media tree

### Paths

The media domain serves the files service `media`, whose grants each
session the manifest grants it mounts at `/media`:

```text
/media/
  disk0/          one directory for each drive the media domain holds
    status        what the drive holds (read)
    ctl           commands (write)
    s1/           volume 1's files, while its medium is mounted
    s2/ ...
  disk1/
```

The root lists every drive the manifest names, whether or not it holds a
medium, so `ls /media` shows the machine's drives. A walk of `diskN`
asks the drive process for the drive's medium; when the drive's grant
answers a window, the drive process starts that medium's supervisor and
waits for the reader to have read the table and started the volume
processes, so the listing that follows names every volume. With no
medium, or once a medium has ended, been ejected or been found `taken`,
`diskN` holds `status` and `ctl` alone. Walking into `sN` waits for that
volume's probe and mount, and reaches its root while it is mounted; a
volume refused, failed or not served answers `eio` there and shows why
in `status`.

Every request on a volume's node goes to its volume process. Reads and
writes are waiting requests whose keeper is the volume process
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"), so a slow medium delays only requests on it; the
other operations, walks, attributes, listings, creates and renames, are
calls the grant waits for as a local file system's grant waits for its
disk, within the volume's bounds ([Time and memory](#time-and-memory)),
so a slow medium delays the other requests of that session's `media`
grant for that long. A call to a volume process that has ended answers
`eio` at once.

### Status

`status` is one attribute a line, `NAME <tab> VALUE`, in the form an
app's `status` file takes, with each value through the field escape
([design-app-trees.md](design-app-trees.md#a-status-line)), so one
parser reads both:

| Name | Value |
| --- | --- |
| `medium` | `none`, `ready`, `ejecting`, `ejected`, `failed`, or `taken`: a medium an earlier drive process or media domain mounted, not mounted again until it is taken out and put back |
| `transport`, `sectors`, `flush` | the transport's name, the medium's capacity, and `yes` or `no` |
| `table` | `mbr`, `gpt`, `none` or `refused FINDING` |
| `sN` | volume N's format, a name of the probe's table or `unknown`; `extended` for an MBR's extended entry |
| `sN_mount` | `rw`; `ro` with the writable rule's reason; `refused` with the flush's answer; `not served`, with `FAT12` for a FAT12 volume; or `failed` with why the volume ended |
| `sN_sectors` | its length |
| `sN_also` | the other formats the probe found |
| `sN_fat` | FAT's type, `12`, `16` or `32` |
| `sN_label`, `sN_serial` | the volume's label and serial number, or a GPT entry's name and unique GUID, as the medium gives them |
| `unserved` | how many volumes past `media_volumes_max` the table lists |

A value the medium supplies, a label, a name or a GUID, is text from an
untrusted source and is escaped as any such text is
([CLAUDE.md](../CLAUDE.md), "Text from untrusted sources").

### Commands

A write to `ctl` is one command, as the `ctl` of an app's tree takes
one ([design-app-trees.md](design-app-trees.md#commanding-ctl)). The one
command is `eject`, compared as bytes, its trailing newline optional,
which finishes the drive's medium
([Finishing a volume](#finishing-a-volume)); any other answers
`einval`.

### Identity

A file's qid path is its volume's mount number, drawn from the media
domain's counter at each mount, in its high 24 bits, and the path its
format gives it within the volume in its low 40: EROFS's inode number,
bounded by the image's length, and FAT's and littlefs's paths drawn per
mount as the storage design draws them
([design-storage.md](design-storage.md#read-write-storage), "File
identity and version"). The root, each `diskN`, `status` and `ctl` take
fixed paths of mount number 0. So no path names two files while the
media domain lives, and a medium mounted again is another set of files.
A mount past the 24 bits' last number fails with `enfile`.

### Links and rights

The resolver follows no link that lies in the `media` tree, as it
follows none in an app's tree: where it would follow one, it answers
`eacces`, as FreeBSD's `nosymfollow` mount does, and an operation on the
link itself acts on it
([design-app-trees.md](design-app-trees.md#links)). The rule belongs to
the provider, `{facet, media, Tree}`, so every bind of `/media` and
every program's table that takes its entries keeps it. A drive is a
stranger's bytes: a link there to `/root/.ssh/authorized_keys` must not
make a copy onto the stick write root's keys. No `media` grant is `rx`,
so nothing runs from a drive; a program on a stick is copied off and
run from where its user may run it.

The tree is one grant over many volumes, so the media tree keeps apart
what the namespace's own `exdev` rule cannot see: a rename or a link
whose two directories lie on two volumes answers `exdev`, the tree
comparing the volume each node names before it asks either volume, as
between two UNIX file systems. A create, remove or rename of an entry of
`/media` or of a drive's directory, a volume's root, `status` and `ctl`
among them, answers `eacces`.

### Mounting it

`erx_ns`'s table of mount points gives `media` the point `/media`, read
at `erx_ns:mount_facets/1`, so a session granted `media` mounts it there
and a session granted none sees the release's empty, read-only `/media`
directory, as for `/data`
([design-files.md](design-files.md#building-binding-and-mounting), "A
facet's mount"). `mount` prints it as `PID:/media on /media (media)`,
the type being the statfs of the tree's root, `media`, while `df` on a
volume's path reads that volume's own: `msdosfs`, `erofs` or
`littlefs`, with its size and free space. That needs `erx_fs`'s
`statfs` callback to take the node the request names, as 9P2000.L's
`Tstatfs` names a fid: a change of the interface every tree
implements, each other tree ignoring the node
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).

## Where each parser runs

| Parser | Runs in | A failure ends | A memory error reaches |
| --- | --- | --- | --- |
| the table (MBR, GPT) | the medium's reader, Erlang | that medium's mounts: `table refused` or `medium failed`, no volume | nothing: Erlang code writes only its own heap |
| the probe | the volume's process, Erlang | that volume | nothing |
| FAT | the volume's process, Erlang | that volume | nothing |
| EROFS | the volume's process, Erlang | that volume | nothing |
| littlefs, in development builds and test images | the volume's port, C, in its own sub-space | that volume | the port's sub-space and channel; its volume's sectors, as far as the volume may be written, and its answers, through its owner's checks; the kernel's call surface and, on Fiasco, the CPU's branch predictors, as any sub-space's code does ([design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel), FD24, FD32) |
| F2FS, when it joins | the volume's process, Erlang | that volume | nothing |

Nothing of a medium is parsed in the USB domain or a block device's
driver domain, which move sectors; the media domain's own code, which
parses nothing of a medium outside these processes, is the only code of
it whose failure the domain's restart intensity counts.

## Concurrency

* **The drive process** takes the tree's requests for its drive and its
  medium's events one at a time. It never reads a sector: it asks the
  drive's grant for the window, monitors the window, starts and ends the
  medium's supervisor, finishes its volumes at an eject, and holds each
  volume's pid and outcome. Two sessions walking a new medium at once
  both wait for the one reading, and the second finds it done.
* **The medium's reader** reads the table, starts the volume processes
  and ends. Each volume process probes and mounts in its own time; a
  walk into a volume still mounting waits for it.
* **Volume processes** run concurrently and share only the window, whose
  requests the serving domain answers one at a time in order. A volume's
  writes reach the window in the order its process makes them; a volume
  that ends leaves its sent requests to complete or fail at the window,
  and no later mount of that window exists to race them, since the grant
  handed it out once.
* **A finish** reaches each volume as a request behind those it holds,
  so the volume completes what it was given first and admits nothing
  after it; a request that arrives after it, or after the medium's end,
  answers `eio`. Each volume finishes on its own, and a write to one
  volume that is still open while another has finished is answered by
  that volume's own finish, never left between two.
* **A medium's end** and a walk cross only in the drive process: the
  window's end is a message to it, and the next walk after it finds no
  medium, or the next one.
* **A restarted drive process**, after a defect of its own, has ended
  its medium's supervisor with it, since the two are linked; the grant
  answers it `taken` for the medium it held, so it shows the medium
  `taken` and mounts the next medium the drive holds. A restarted media
  domain finds every medium present `taken` the same way.

## Failure handling

| Failure | Detected by | What ends | What the user sees |
| --- | --- | --- | --- |
| a table refused | `erx_media_table` | nothing mounts on that medium | `table refused FINDING`; `diskN` holds `status` and `ctl` |
| a format not served, or none found | the probe | that volume is not mounted | `sN NAME`, `sN_mount not served`; `eio` in `sN` |
| the selected format's mount fails: a structure check, its allowance, its geometry | the format's mount | that volume; no other format is tried | `sN_mount failed REASON`; `eio` in `sN` |
| a mount's flush fails | the writable rule | that volume's mount, with nothing written | `sN_mount refused eio`; out and in again to retry |
| a volume's process crashes or passes its memory bound | its supervisor's link, temporary | that volume; its requests answer `eio` | `sN_mount failed`; the drive's other volumes go on |
| a littlefs port exits, asserts, faults, passes its budget or misses its owner's deadline | the owner's `{exit_status, N}`, its allocation's refusal, its deadline | that volume | as above, with `timeout` for the deadline |
| the medium removed, changed or failing | the window's end ([design-usb.md](design-usb.md#media-and-drives)) | the medium's supervisor: every volume and port of it | open files answer `eio`; `diskN` empty but for `status` and `ctl`; the next medium mounts at the next walk |
| a finish whose writes or flush fail | its answer | the medium, as an eject ends it | `eject` answers `eio`; FAT volumes show `dirty` at the next mount |
| a write on a trial boot | the write path (U4) | that write, `erofs` | a FAT write answers `erofs`; a littlefs volume, whose block write failed, ends |
| a FAT volume removed while written | its next mount: the dirty flag | nothing | that volume read-only, `ro dirty`, until repaired on another machine |
| the drive process ends | `erx_media_sup` | that drive's medium mounts | `eio` on its open files; the medium `taken` until it is taken out and put back |
| the media domain ends | the domain service | every drive's mounts | `/media` answers `eio` until the restarted domain's re-grant; open files keep answering `eio`; every medium present `taken` |
| the serving domain ends (the USB domain, a block device's driver domain) | the drive grant's end | that domain's drives' media | as a removal; the restarted domain's drive grants reach the media domain as every window's grant reaches its holder, with fresh windows |

## Refusals and error results

| Call or input | Answer | When |
| --- | --- | --- |
| a drive grant's `window` | `{error, no_medium}`; `{error, taken}` | the drive holds no ready medium; the grant already answered this window |
| `erx_media_table:read/2` | `{refused, Finding}`: `gpt header`, `gpt array`, `gpt metadata`, `past the end`, `overlap`, `backwards`, `before the first usable sector` | the scheme's checks; each finding names the copy or the entries |
| `erx_media_table:place/3` | `{error, erange}` | a request that reaches past its volume |
| a littlefs port's program or erase | an error answer | the volume is read-only or finished |
| a walk into `sN` | `eio` | the volume is not served, failed, refused, finished or ended |
| a write on a read-only volume | `erofs` | the writable rule mounted it read-only |
| a write on a grant that is not `rw` | `erofs` | before any callback (F5) |
| a write after the ordered end's freeze | `erofs` | at the grant (`erx_fs`'s freeze) |
| a rename or link between two volumes | `exdev` | before either volume is asked |
| a write to `ctl` | `einval` | anything but `eject` |
| `eject` | `enxio`; `eio` | no mounted medium; a finish failed or its volume had ended |
| a write to `status` | `eacces` | always |
| a create, remove or rename of an entry of `/media` or `diskN` | `eacces` | always |
| following a link in `/media` | `eacces` | always (nosymfollow) |
| an EROFS volume's mount | `{error, enotsup, Text}`, `Text` `erofs: compressed images are not supported` for a compression feature, and naming the bits or the size otherwise | a compression feature, any other incompatible feature, another block size, extended superblock slots |
| a compressed or chunked EROFS inode | `enotsup` | when it is reached |
| the manifest check | the build fails | each rule of [Manifest rows](#manifest-rows) |
| the release check | the build fails | `erx_media` in another release; `erx_storage` or `erx_blk` in the media domain's; `erx_lfs` or the littlefs port in a release build's media domain |
| the EROFS calls check | the build fails | `erx_erofs:mount_source/2` called by any module but `erx_erofs` and `erx_media_erofs`; an `unchecked` form in `erx_verity` |

## Security

Every byte of a drive is a stranger's, and the design places every
parser of it so that a crafted volume ends at most its own mount and a
crafted table its own medium's, and reaches nothing else of the system
through anything erXos parses. The transport's domain, which holds a
DMA-capable controller, moves sectors and parses none of the medium.
The media domain holds no device and no window of the boot medium, so
neither an Erlang defect in a parser nor littlefs's port reaches a
device, the data partition, the vault or the slots. Erlang parsers fail
processes, not memory, and each runs under its own memory bound inside a
domain sized to hold them all.

Three things lie outside what this design can confine, and qualify every
statement above:

* **littlefs's port**, in the development builds and test images that
  serve littlefs: littlefs's C is confined to a sub-space per volume,
  whose every block request its owner places in that volume and every
  write its owner checks against the volume's right to be written. What
  remains is what any code in a sub-space can do: call the kernel and
  run on the CPU. On Fiasco that is FD24's system-call surface and
  FD32's branch predictors, which a crafted littlefs volume reaches only
  through a memory error in littlefs that it can steer; the image and
  request fuzz targets are the defence, and a release serves no littlefs
  volume.
* **The transport's DMA**: where no IOMMU confines the controller, the
  media domain's sectors pass through a domain that can write any memory
  (FD12), as every medium's do.
* **The hardware**: a device fault the hardware reports too late to
  attribute, and on Fiasco what FD33 leaves open of a device's errors,
  are the platform's, not a drive's.

E1's guarantee is unchanged for what it protects: the system partition
and packages are decoded only after their trees check, in runtimes where
every block the decoder reads came through `erx_verity`. A drive's
EROFS image is decoded unauthenticated, in the media domain, and served
as files no session runs.

A stick can carry names, labels and links chosen to mislead. Names
reach a session as file names, which every sink escapes; labels reach
`status` through the field escape; links are not followed, so a write
through `/media` lands on the stick or fails. A medium with two formats'
headers is never written. Who reads which drives is the manifest's: on
a machine whose sessions all hold `media`, every logged-in user reads
every stick, as on a desktop.

## Verification

Each passing case is paired with a seeded fault that must make it fail,
so a pass shows the code under test ran.

### Host tests

| Test | Seeded fault that must fail it |
| --- | --- |
| `erx_media_table` over written cases of each rule: an MBR with one and with four entries; a FAT boot sector with zero entries and a plausible BPB, read as no table; a boot sector whose status bytes are not 0 or `0x80`, read as no table; entries of type `0x00` and of start or length 0 skipped; an extended entry listed and not served; an entry past the end, one that runs backwards and two overlapping entries, each refusing the table, the overlap in both orders | the status-byte test dropped, so a boot sector with code is read as a table; the overlap check made order-dependent, so the second order passes; the backwards check dropped |
| the GPT cases: a GPT behind its protective entry; a primary that fails its signature, its header CRC, its array CRC and its bounds in turn, each read from the backup at the last sector; a primary that passes with its backup at its alternate sector; both failing, refused and never read as an MBR or as no table; an array of 17 KiB; nine used entries, eight served; a usable area that meets a header, the taken array, the other copy's array, and an array that encloses the usable area, each refused `gpt metadata` | a missing primary signature taken as no GPT, so the medium falls back to no table; the backup read at the primary's alternate sector after a failed primary; the array compared by its ends alone, so the enclosing array passes; the other copy's array left out of the metadata set; the array bound removed |
| the table as a property test: for every MBR and GPT the generator writes, the served volumes lie inside the medium, pairwise apart and apart from every metadata sector, and `place/3` never answers a sector outside its volume | the end check written `<` for `=<` |
| `erx_media_probe` on a seed of each table row; on a FAT32 volume holding EROFS's magic at 1,024 bytes, which selects `erofs` with `msdosfs` also found; on a FAT32 volume whose boot sector's system id is `NTFS    `, which selects `msdosfs` with `ntfs` also found; and on a FAT12 volume fsimg writes, refused `not served FAT12` | the order reversed, so the first volume selects `msdosfs`; `also` dropped; the FAT type left to the mount, so the FAT12 volume is selected and mounted |
| littlefs's signature over volumes the tree's littlefs writes with `erx_lfs_config`: freshly formatted, after many commits, after compactions of the root pair that leave its current superblock in block 1, and cut mid-commit and mounted again, each found by the probe and mounted | the signature read in block 0 alone, so the compacted volume is `unknown` |
| the writable rule over every combination of format, probe answer, flush answer and dirty flag | the `also` condition removed, so the doubly formatted volume mounts writable; every flush answer but `ok` taken as `enotsup` |
| a selected format whose mount fails: the FAT32 volume holding EROFS's magic is `failed` and nothing is written | a fall-through to the next format found, which mounts it as FAT |
| the drive process and the media tree, under `erx_media_sup` against a fake drive grant and window: a medium's mount, a listing, a read; the window's end, after which an open fid answers `eio` and `diskN` lists `status` and `ctl`; a new window, mounted at the next walk; a volume process killed, the others still served; a volume past its memory bound; the drive process killed, after which the grant answers `taken` and the medium is shown `taken`, not mounted | the drive process not monitoring the window, so the open fid reads after the end; a volume process started as a permanent child, so the kill restarts it; the grant answering a window twice, so the restarted drive process mounts the same medium again |
| `eject` over two FAT volumes and a littlefs volume of one medium, with writers on every volume running through it: every write answered `ok` before the eject is on the fake window before its last flush, every write after a volume's finish answers `eio`, and the FAT images pass fsimg's verify | the finish not closing its volume, so a write to an already finished volume is answered `ok` and never flushed; `eject` answering before the last finish's flush |
| the media service's freezing checkpoint with writers on two drives: it answers once every volume has finished, later writes answer `erofs` | the media tree answering the checkpoint before its volumes' finishes |
| `erx_erofs:mount_source/2` over `erx_media_blocks` on fsimg images and on the reader's existing cases, which leave `erx_verity`'s `unchecked` mode; an fsimg image with a compression feature bit set refused with `erofs: compressed images are not supported`, and one with a compressed inode answering `enotsup` there | `erx_media_blocks` reading past its volume, which a fixture image at a partition's start shows; the compression bits taken as any other incompatible bit, so the refusal names bits instead of compression |
| the EROFS calls check: no module but `erx_erofs` and `erx_media_erofs` calls `mount_source/2`; `erx_verity` has no `unchecked` | each with a seeded violation: `erx_ns` calling `mount_source/2`; `unchecked` restored |
| the manifest check's drive rules, its budget rule, and the release check | each rule with a seeded manifest or release that breaks it alone |
| the littlefs owner over a fake port on the host: a block request past the volume refused; a program and an erase during a read-only mount and after the finish refused, and on a writable volume answered; the port's exit, and its silence past the deadline, ending the volume | the placement check removed; the write admission removed, so the read-only volume's fake window receives the program |
| the media tree's statfs and renames: `df` on a FAT volume answers `msdosfs` and its sizes, on the root `media`; a rename between two volumes answers `exdev` with neither volume asked, one inside a volume reaches it | `statfs` answered from the tree for every node; the volume comparison dropped, so the rename reaches the source volume |

### Fuzz targets

Each lands with its parser and builds the same sources for the host:

* `erx_media_table`, MBR and GPT, seeded from the host tests' cases;
* `erx_media_probe`, seeded from one volume of each format;
* the FAT server's decoders, already a target of the storage design;
* the EROFS decoder, through `erx_media_blocks`, the reader's existing
  target moved off `unchecked`;
* littlefs's image target and its request target, built with
  `erx_lfs_config` as now, and the port's channel decoder on each side,
  landing with the port.

### QEMU cases

Each runs in the `usb` suite on QEMU `virt`, over its stick plumbing
(`tools/lib/erx/usb_boot.rb`'s stick, `QemuPlan::Pcie` with a disk,
`Qmp#eject` and `Qmp#device_del`), with the media domain added to the
suite's manifest. The harness writes each stick from a declared tree of
files and keeps the SHA-256 of each; a line at the media domain lists
the volume and reads each file through `/media`, and the case passes
when the names and hashes equal the harness's.

| Case | Seeded fault that must fail it |
| --- | --- |
| a FAT16 and a FAT32 stick on an MBR, a FAT32 stick with no table and a FAT32 stick on a GPT, each listed and read | the no-table rule dropped, so the bare stick shows no volume |
| a FAT12 stick fsimg writes, refused `not served FAT12`, its bytes unchanged | the probe's FAT type dropped, so the stick mounts |
| an EROFS stick, uncompressed, fsimg's | the volume module mounting with `erx_erofs:mount/2`, which no layout opens |
| a littlefs stick of erXos's geometry, written by the harness's littlefs tool, on a development build | the owner's placement check removed, while the port asks for a block past the volume |
| a stick of each refused name (an exFAT, an NTFS and an ext2 signature, each the format's header alone) refused by name, its bytes unchanged | the probe answering `unknown` for every unserved format |
| a FAT32 stick whose boot sector's system id is `NTFS    `: read-only, `ro also ntfs`, its bytes unchanged after a write is refused | the `also` condition removed |
| a FAT32 stick that also holds EROFS's magic at 1,024 bytes: `failed`, its bytes unchanged | a fall-through to the next format found |
| a FAT32 and, on a development build, a littlefs stick written, synced, ejected through `ctl`, read again after the stick is put back; the FAT image passes fsimg's verify after the run | the finish's flush skipped, so the FAT image is dirty |
| a FAT32 stick written without a sync, then the machine ended by an ordered `off`; the stick, read on the host, holds every write and passes fsimg's verify | the media service left out of the ordered end, so the stick is dirty |
| a file open on a stick when QMP ejects its medium: the next read answers `eio`, `ls /media/disk0` shows `status` and `ctl`; the medium put back through QMP mounts again and reads equal | the volume's node naming the drive rather than the volume process, so the old fid reads the new medium |
| `device_del` mid-write, then `device_add`: the stick mounts again, FAT read-only `dirty` | the dirty flag ignored at mount |
| a second virtio disk of the `drive` role, served by a block driver domain of its own, listed and read | the block service reading the boot layout on a `drive` device |

At the milestone gate, images that the FreeBSD oracle guest's
`newfs_msdos` and `gpart`, and the Linux oracle guest's `mkfs.fat`,
`mkfs.erofs` and `sgdisk`, write, each treated as hostile, are read
the same way, and the run records which of `mkfs.erofs`'s outputs the
reader serves and which it refuses by name. Whether `erlang:crc32/1`
computes the GPT's CRC-32 is unverified until those images' tables are
read.

## Alternatives considered

**A window per partition, the table read in the USB domain.** The
storage design's first form: the domain that holds the controller reads
the table and serves each partition as its own window, and each file
server holds one partition. It loses: the table, a stranger's bytes, is
parsed in the one domain that holds a DMA-capable device; the manifest
must name partitions before any medium is seen; and the isolation it
buys between partitions of one stick protects a stranger's volumes from
each other. The whole medium as one window moves the parse out and
deletes the rows.

**One domain per drive, or per medium.** A domain per drive would give
each drive a runtime of its own, and a domain incarnation per medium
would end every state of a medium with its domain. It loses: Erlang
parsers already fail only their processes and littlefs's C is already in
a sub-space per volume, so the extra runtimes buy nothing, and an
incarnation per medium would spend the domain's restart intensity on
every stick pulled out and add a restart to every insertion.

**Probing in the medium's reader.** One process would probe every
volume before any mounts. It loses: a probe defect a volume's bytes
trigger would end its siblings' mounts too, and each volume's process
reads its own sectors anyway.

**Remembering mounted media in the media domain.** A record of the
windows already mounted would have to outlive the drive process and the
media domain both, or be lost at the restart it exists for. The grant,
which lives in the domain that owns the window, answers each window once
and needs no record beyond the window it already holds.

**littlefs's NIF in the media domain.** It loses: an assertion or crash
would end the media domain and every drive's mounts, a stick that fails
at every mount would use up its restarts, and a memory error would reach
every drive it serves and the next medium in its own drive.

**The `unchecked` mode of `erx_verity` for drives.** It loses: the
funnel E1 rests on would carry a form that checks nothing, held apart
only by a rule on who may name it, in every runtime; the storage design
rejected the same exception for the system partition's directory
([design-storage.md](design-storage.md#alternatives-considered)). A
source that only the media domain's release contains needs no exception
in the funnel, and deleting `unchecked` leaves the funnel with none.

**A second kind of source inside the EROFS reader.** The reader would
take either a hash-checked handle or the media domain's, with a clause
for each. It loses to a decoder over a source function: the shared
reader would name an application module that most runtimes do not hold,
and carry an unchecked branch of its own.

**A format declared by the manifest, the table's type byte or the
user.** It loses: the manifest is written before any medium exists,
type bytes are often wrong, and a declaration that disagrees with the
bytes either fails or writes the wrong format; FreeBSD's automounter
asks the bytes.

**Mounting at `/media/LABEL`.** FreeBSD's automounter keys a volume by
its label. It loses here: a label is a stranger's text, two sticks may
share one, and a path that changes with a label breaks scripts in the
same way a drive number would; the label is a `status` line instead.

**Mounting on a medium's arrival rather than at the first walk.** It
would need the drive grant to announce media, a message of its own, and
would parse every medium plugged in whether or not anyone reads it. The
first walk is FreeBSD's automounter's moment too.

**Following an MBR's extended partition.** It would serve logical
partitions, an erXos card's system and data partitions in a USB reader
among them. Not needed for any medium the scope names; a bounded walk of
the chain can be added as the table's next rule.

## Open decisions

None. A release serves FAT16, FAT32 and EROFS volumes from drives;
littlefs volumes are served only by development builds and test images,
and littlefs stays a stopgap; FAT12 is refused by name.

## References

* [design-storage.md](design-storage.md): the block service, windows,
  FAT, EROFS, littlefs's port, the durability facet.
* [design-usb.md](design-usb.md): media, drives, the SCSI subset.
* [design-files.md](design-files.md), [design-app-trees.md](design-app-trees.md):
  `erx_fs`, keepers, its freeze, facet mounts, links, `status` and
  `ctl`.
* [design-system.md](design-system.md#shutting-down): the ordered end.
* [design-stopgap.md](design-stopgap.md#littlefs-on-a-drive): littlefs
  on a drive.
* [design-f2fs.md](design-f2fs.md): F2FS.
* FreeBSD src, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`, read
  from a local clone with `git show`; SHA-256 of each file:
  * `sys/geom/part/g_part_mbr.c`,
    `c26b2a7467a59e46a1253741a603e609035e48e6e0840e4631bfde4432e1f28b`;
  * `sys/geom/part/g_part_gpt.c`,
    `e6aa9bcbf92e0e07cca5f48589dd5c3fbb80b088e9086fc2001a1d5dd45fc42b`;
  * `sys/geom/part/g_part.c`,
    `936eac38d5c7a71f3b9643839972e1871301f600792a9a6b0d41fe76384c85bf`;
  * `sys/ufs/ffs/fs.h`,
    `977d6f15bac9eeccb6512a31d479af91a588bf331ca2f718d1e1c8cfdc70aea1`;
  * `usr.sbin/fstyp/fstyp.c`,
    `5c2eee079cf60baa7af5ad25f5dbff1e7a4be62a8a6cbf418a2197464bac77ac`;
  * `usr.sbin/fstyp/msdosfs.c`,
    `9f8909ef88cfff0800b79ba2c20f7698d811af746771355e3fcc5b964507b48d`;
  * `usr.sbin/fstyp/cd9660.c`,
    `8525db2fe2d22960afab018190a091b470182b02dd916240d7c531863416bf20`;
  * `usr.sbin/fstyp/hfsplus.c`,
    `ad51bb044d91a8477e46220bbdf1f49243960c877ee53f99b93a33c3737ae744`;
  * `usr.sbin/fstyp/ext2fs.c`,
    `f988d57b6786daf121e2110e61be9240d2d7b158ba3d0c48db4cf4dea9d70841`;
  * `usr.sbin/fstyp/apfs.c`,
    `b1552cdf48c878d6655c46e20f38bb6b58c5f7fd95089d0af119011bf80a3319`;
  * `usr.sbin/fstyp/exfat.c`,
    `13077baef8584384c36fd6a76c704450294583a0468a6f79045664525a650ad2`;
  * `usr.sbin/fstyp/ntfs.c`,
    `c6ab3a1a859b3ab9c57ef3100e2e62f920730ab5f757a082c90f20d778cdff69`;
  * `usr.sbin/autofs/autofs/special_media`,
    `b642eab511c6bc5de8c093253a9339b31d04307d0b893717163d87d426e15465`;
  * `usr.sbin/autofs/auto_master`,
    `cc7437b63261d3e3640e4ae0af02be0920a4da7be6ac19fa86ede121fafda509`.
* littlefs v2.11.3, `littlefs/lfs.c` in the tree
  ([littlefs/ORIGIN.md](../littlefs/ORIGIN.md)), and its `SPEC.md` at
  the same commit, `6cb4e86540eca0d9ba62500a298385c9d863c8be`, fetched
  from `https://raw.githubusercontent.com/littlefs-project/littlefs/`,
  SHA-256 `6dd74dfc58ac93589f8e002bb73c0830a59206912cfe8c951c07eb2bd5fccad0`.
