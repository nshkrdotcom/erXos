# Drives: every medium, every format

A **drive** is a place that holds at most one medium at a time: a USB
stick, an SD card in a USB reader, or the medium of a block device the
manifest gives to no file system of its own, such as a second virtio
disk. Every drive reaches files by one path. The domain that drives the
medium's transport serves the medium **whole**, as one window, and
parses none of it. One domain of its own, the **media domain**, which
holds no device, reads the medium's partition table, names each
partition's file system from its contents, and mounts each partition,
a **volume**, behind one process; it serves every drive's volumes as
files at `/media/diskN/sN`. The formats it serves are FAT12, FAT16 and
FAT32, EROFS and littlefs, and erXos's F2FS joins as one row of the
same table. The key idea is that everything a medium's bytes reach, the
table reader, the probe, each volume's parser and littlefs's C code in
its sub-space, is a child of that medium's supervisor and ends with the
medium's window, so a crafted medium ends at most its own mounts, no
state of one medium reaches the next, and "any format on any drive" is
the product of one drive path and one format table rather than a matrix
of cases.

Decisions every reader needs:

* **A drive serves its medium whole.** The USB domain, or the domain
  that drives a block device of the drive role, runs a transport and one
  window covering the medium, and hands that window out through the
  drive's grant. It reads no table, so nothing a medium holds is parsed
  in a domain that holds a device.
* **One media domain holds every drive.** It holds no device, no window
  of the boot medium and nothing but the drives' grants, and it serves
  one files service, `media`, which sessions mount at `/media`.
* **Detected, never declared.** The table decides where volumes lie;
  each volume's format is what its own bytes say, by a probe that
  follows FreeBSD's `fstyp`. No manifest row, table type byte or user
  names a format.
* **A volume's failure ends its mount.** Each volume's parser runs in
  that volume's own process, littlefs's C in a sub-space of its own, so
  a crash, an exhausted heap or a memory error ends only that volume and
  never costs the media domain a restart.
* **Written only when unambiguous.** A volume is written only when one
  format alone claims it, that format is one erXos writes, the medium
  flushes, and the format's own state allows it; otherwise it is
  read-only, and a medium whose flush fails is refused.
* **EROFS from a drive is unauthenticated, and kept apart.** The media
  domain reads a drive's EROFS volume through an entry of the reader and
  a block source that exist only in its own release, so no runtime that
  mounts a package or serves the `system` tree can make one, and E1
  holds for the system's own images as it stands.
* **littlefs from a drive runs only as its port.** Never as the NIF:
  each littlefs volume has its own sub-space that holds its channel and
  data area alone, and every block it asks for is checked against its
  volume.

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
  entry of type `0xEE` and sector 1 holds the header's signature
  (`g_part_gpt.c:890-915`). A header is taken only if its CRC-32 checks
  and its fields describe a table and a usable area inside the medium
  (`gpt_read_hdr`, `:441-542`), and an entry array only if its CRC-32
  checks and it is at most 4,096 entries of at most 1,024 bytes
  (`gpt_read_tbl`, `:544-604`; `:150`, `:159`). When the primary header
  or its array fails, the backup at the medium's last sector is read
  (`g_part_gpt_read`, `:930-1092`).
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
  `:77-115`).
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
followed; no extended partition's chain is followed; and a GPT is read
only behind its protective entry.

littlefs v2.11.3, the tree's copy (`littlefs/ORIGIN.md`), mounts a
volume only when the superblock's block size equals the configuration's
(`lfs.c:4618-4622`) and its block count equals the configuration's
unless that is 0 (`:4608-4616`).

### What it builds on

* The block service's transport contract and windows, the write path
  and its trial rule U4
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
  write later and answer `eio` when they end
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
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
  littlefs's sub-space port
  ([design-storage.md](design-storage.md#read-write-storage),
  [design-programs.md](design-programs.md#a-program-is-a-port)) and its
  release contract
  ([design-stopgap.md](design-stopgap.md#release-contract)).

## Requirements

* **DR-R1. Any drive, any served format.** Every drive serves FAT12,
  FAT16 and FAT32, EROFS and littlefs volumes, on a medium with an MBR,
  a GPT or no table; a new format is one row of the format table and a
  new kind of drive one transport.
* **DR-R2. Confinement.** A crafted medium ends at most its own volumes'
  mounts: never the media domain, another drive's media, the domain
  that serves its transport, or the boot medium's storage. No C parser
  of a medium runs where it can reach a device, a window or another
  volume.
* **DR-R3. The authenticated path intact.** E1 holds for the system
  partition and every package as it stands: no byte of a drive reaches
  a parser in a runtime that mounts a package or serves the `system`
  tree.
* **DR-R4. A medium's state dies with it.** No process, sub-space or
  cache holding a medium's state outlives the medium; an open file of
  an ended medium answers `eio`, and a new medium mounts afresh.
* **DR-R5. Never written by a misreading.** A volume is written only
  when one format alone claims it, erXos writes that format, and the
  medium flushes; every other volume is read-only or refused, with the
  reason shown.
* **DR-R6. Untrusted input.** Every parser of a medium's bytes is
  bounded and has a fuzz target; text a medium supplies reaches a sink
  only through its escape; a link on a drive is never followed.
* **DR-R7. No new mechanism.** Drives reach their files through windows,
  grants, one files service, `erx_fs` keepers, the littlefs port and a
  `status` and `ctl` pair, each named here.
* **DR-R8. Authority.** Which domains see which drives is the manifest's
  `media` facet rows' and nothing else's.

Non-goals: exFAT, NTFS, ext2, UFS, HFS+, APFS and ISO 9660, each named
by the probe and refused; logical partitions inside an MBR's extended
partition; repairing a table or a volume; media whose blocks are not
512 bytes; booting, updating or loading code from a drive.

## The construction

### One path from medium to files

```text
 the transport's domain (the USB domain, or a block device's driver domain)
   medium ---> one window, the medium whole ---> drive grant, diskN
                                                      |
 the media domain                                     v
   drive process (one per drive; parses nothing)
     on the first walk of diskN after a medium arrives:
       medium supervisor (one per medium; ends when the window ends)
         reader: table (MBR | GPT | none) -> volumes s1..sN -> probe each
         one volume process per served volume:
           msdosfs (the FAT server) | erofs | littlefs (owner + port sub-space)
   media tree, /media: each request on a volume goes to its volume process
```

1. **The medium.** The transport's domain runs, for each medium, the
   transport and one window covering every sector of it, and the drive's
   grant answers that window's pid. That domain reads no sector of the
   medium on its own behalf.
2. **The volumes.** In the media domain, a reader process under the
   medium's supervisor reads the table with `erx_media_table`, a pure
   function of the sectors it asks for, which answers the volumes and
   where each lies, or refuses the table whole
   ([The table](#the-table)).
3. **The formats.** For each volume it reads a fixed set of sectors and
   names the format with `erx_media_probe`, a pure function over them
   ([The probe](#the-probe)).
4. **The mounts.** It starts one volume process for each volume whose
   format the format table serves, which mounts the volume read-write
   or read-only by one rule ([The writable rule](#the-writable-rule)).
5. **The files.** The media tree routes every request on a volume to its
   volume process and serves the rest itself
   ([The media tree](#the-media-tree)).
6. **The end.** When the medium's window ends, the drive process ends
   the medium's supervisor, and with it the reader, every volume process
   and every littlefs port; a node a fid holds names its volume process,
   so every later request on it answers `eio`.

### How each requirement follows

* **DR-R1.** Steps 2 to 5 do not depend on the transport: a medium is a
  window, whoever serves it. They do not depend on the format either: a
  volume is a range of sectors and a format name, and the format table
  maps the name to a volume module. FAT, EROFS and littlefs are its
  rows; F2FS is one more ([F2FS](#f2fs-when-it-joins)).
* **DR-R2.** Every byte of the medium is parsed in the media domain,
  which holds no device. The table and the probe run in the medium's
  reader, each volume's format in its volume process under a heap
  bound, and littlefs's C in its own sub-space, whose block requests
  its owner checks against the volume; the medium's supervisor and the
  volume processes are temporary children, so no failure of theirs is
  counted against any restart intensity, and the drive process, which
  touches no byte of the medium, is the only process of a drive the
  media domain's supervisor restarts.
* **DR-R3.** The unauthenticated EROFS entry and its block source are
  in `erx_media`, the media domain's application, which no other
  release names ([EROFS, unauthenticated](#erofs-unauthenticated)).
* **DR-R4.** Step 6: the supervisor is the medium's, so its end takes
  every holder of the medium's state with it, the EROFS block cache and
  the littlefs port included; volumes mount once per medium, so no mount
  of a medium follows another of the same medium while the first one's
  writes are in flight.
* **DR-R5.** The writable rule is the one place that decides it, from
  the probe's answer, the format, the mount's flush and the format's
  state.
* **DR-R6.** The table reader, the probe and each format have fuzz
  targets ([Fuzz targets](#fuzz-targets)); labels and names reach the
  `status` file through the field escape; the resolver follows no link
  in the `media` tree.
* **DR-R7.** [The mechanisms used](#what-it-builds-on) are all
  existing. The names this design adds are a window role, `drive`; one
  service, `media`, with its mount point and its place beside
  `{facets, svc}` in the resolver's no-follow rule; the reader's second
  entry, `erx_erofs:mount_unauthenticated/2`; the probe's table,
  `abi/formats/probe.txt`; two limits, `media_volumes_max` and
  `media_volume_heap_max`; two statfs types, `msdosfs` and `media`; and
  the modules of `erx_media`.
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
answers one request, `window`: `{ok, Window}` while the drive holds a
medium, the pid of that medium's window, and `{error, no_medium}`
otherwise. The grant lives as long as its serving domain, learns of each
window as the medium's block service starts it, and forgets it when the
window ends ([design-usb.md](design-usb.md#concurrency)). Holding the
grant is holding whatever medium the drive holds, whole.

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
* more drives on one USB domain's controllers than `usb_drives_max`;
* a `media` facet row with rights `rx`.

The media domain's row allows it sub-spaces, for the littlefs ports,
and serves the one service `media`. The release check refuses a release
other than the media domain's that names `erx_media`, and a media
domain's release that names `erx_storage`, whose `erx_littlefs` loads
the NIF, or `erx_blk`, the block driver.

## Reading a medium

### The table

`erx_media_table:read(Capacity, Sectors)` is pure: it names the sectors
it needs, sector 0, then sector 1 and the entry array for a GPT, or the
medium's last sector and its array for the backup, and the reader
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
2. **A GPT**, when the MBR holds an entry of type `0xEE` and sector 1
   begins with `EFI PART`. The primary header is taken when its size is
   92 to 512 bytes, its CRC-32 over that size with its own field zeroed
   checks, its revision is at least FreeBSD's `GPT_HDR_REVISION`, it names sector 1 as its own,
   its usable area and its entry array lie inside the medium and apart
   from each other, its entries are at least 128 bytes and a multiple of
   8, and the array is at most 16 KiB, room for 128 entries of 128 bytes; its array is taken when its CRC-32 checks. When either
   fails, the backup header at the medium's last sector is read by the
   same rules, naming that sector as its own, with its array. Neither is
   ever written. When both fail, the table is refused, naming the
   primary's finding. An entry whose type GUID is all zero is unused;
   each other entry is volume N, N its index from 1, with its name, 36
   UTF-16 code units, and its unique GUID kept for the `status` file.
3. **An MBR's entries**, otherwise: an entry of type `0x00`, and one
   whose start or length is 0, is skipped; one of an extended type,
   `0x05`, `0x0F` or `0x85`, is listed as `extended` and not served,
   since no chain of extended boot records is followed; each other entry
   is volume N, N its place from 1 to 4.
4. **No table**: the medium is one volume, number 1, from sector 0 to
   its end, as FreeBSD mounts `da0` itself. A stick's files therefore
   lie at `s1` whether or not its maker wrote a table.
5. **Integrity**, as FreeBSD checks it by default: every entry the
   scheme lists, extended ones included, must start at or after the
   first usable sector (sector 1 for an MBR), end within the medium, or
   for a GPT within its usable area, and overlap no other. One that
   breaks it refuses the table whole, naming the entries, so a crafted
   table never makes two volumes share a sector, whatever order its
   entries come in. A protective entry is never a volume, so no volume
   covers a GPT's header or array.
6. **A bound**: at most `media_volumes_max` volumes are served, 8, the
   first in entry order; the `status` file counts the rest as not
   served.

Volume N is the directory `sN` of its drive's tree. A sector request of
a volume, from any format, is placed by one pure function,
`erx_media_table:place/3`, which adds the volume's first sector and
refuses with `erange` a request that reaches past its length, so no
format reaches a sector outside its volume.

### The probe

`erx_media_probe:format(Read)` reads, through the volume's placement, a
fixed set of sectors, and answers the formats whose signature it finds:
the first in the order below that matches, and every other that does.
The order is `fstyp`'s, the header at the largest offset first, with
erXos's formats placed by where their headers lie:

| Order | Name | Served | Signature, from |
| --- | --- | --- | --- |
| 1 | `ufs` | no | UFS1 or UFS2 magic in a superblock at 65,536, 8,192, 0 or 262,144 bytes (`sys/ufs/ffs/fs.h:68-76`, `:457-458`) |
| 2 | `cd9660` | no | the volume descriptor's `CD001` at 32,768 bytes (`fstyp/cd9660.c:38-50`) |
| 3 | `hfs+` | no | `H+` or `HX` at 1,024 bytes (`fstyp/hfsplus.c:42`, `:106-112`) |
| 4 | `ext2fs` | no | the ext2 magic in the superblock at 1,024 bytes (`fstyp/ext2fs.c:39-63`) |
| 5 | `f2fs` | when it joins | F2FS's magic at 1,024 bytes (`abi/formats/f2fs.txt`) |
| 6 | `erofs` | yes | EROFS's magic at 1,024 bytes (`abi/formats/erofs.txt`) |
| 7 | `littlefs` | yes | the name `littlefs` in the superblock entry of block 0 or block 1, at the offset littlefs's format writes it |
| 8 | `apfs` | no | `NXSB` in the container superblock at byte 0 (`fstyp/apfs.c:77-93`) |
| 9 | `exfat` | no | `EXFAT   ` as the boot sector's file-system name (`fstyp/exfat.c:333`) |
| 10 | `msdosfs` | yes | `fstyp`'s FAT test (`fstyp/msdosfs.c:48-115`) |
| 11 | `ntfs` | no | `NTFS    ` as the boot sector's system id (`fstyp/ntfs.c:146-147`) |

The signatures, each with its offset, bytes and source, are the rows of
one checked-in table, `abi/formats/probe.txt`, from which the build
generates the probe's constants; FAT's test is code, since it reads
fields, not one string. littlefs's offset is pinned by a seed volume
that `lfs-format` writes, not by reading littlefs's specification. A
volume where none matches is `unknown`. A volume too short for a
signature's sector simply lacks that signature. Every name in the table
is shown in the `status` file, and a volume whose first match is not
served is refused by that name, as FreeBSD's automounter refuses a
format it has no program for: `s1 exfat`, `s1_mount not served`.

The FAT type is not the probe's: the FAT server takes it from the
volume's count of clusters, as the specification defines it, and shows
it ([FAT](#fat)).

## Volumes

Each served volume has one process, `erx_media_volume`, a temporary
child of its medium's supervisor, with a `max_heap_size` of
`media_volume_heap_max` words, binaries included. It holds its format's
state and runs its format's operations one at a time, in the order they
arrive: the FAT server's state, the EROFS reader's mount and cache, or
littlefs's owner and its port. Its process is the volume's mount: the
mount is made when it starts, and ends when it ends.

| Format | Module | Writes |
| --- | --- | --- |
| `msdosfs` | `erx_fat`, the FAT server ([design-storage.md](design-storage.md#removable-media-fat)) | FAT16 and FAT32 |
| `erofs` | `erx_media_erofs` over `erx_erofs` ([EROFS, unauthenticated](#erofs-unauthenticated)) | never |
| `littlefs` | `erx_lfs`'s owner over the littlefs port ([littlefs, through its port](#littlefs-through-its-port)) | yes |

### The writable rule

A volume mounts **writable** exactly when all of these hold, and
otherwise **read-only**, naming in its `status` line the first that
does not:

1. its format is one erXos writes on a drive (`format`): FAT16, FAT32 or
   littlefs, not FAT12 or EROFS;
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
ends: no volume is mounted twice on one medium, so a refusal is tried
again by taking the medium out and putting it back, which a failing or
departed medium needs anyway, and no second mount races the first one's
writes. A grant whose rights are not `rw` refuses every write before it
reaches a volume, whatever the rule decides (F5 of
[design-files.md](design-files.md#invariants)).

### FAT

The FAT server serves one FAT volume as the storage design defines
FAT's names, attributes, durability and bounds
([design-storage.md](design-storage.md#removable-media-fat)), with sector reads,
writes and flushes through its volume's placement. Its mount decodes the
boot sector, takes the type from the count of clusters, and shows it as
`sN_fat` with `12`, `16` or `32`; FAT12 is read-only by rule 1. The
volume label, from the boot sector or the root directory's label entry,
and the volume serial number are shown as `sN_label` and `sN_serial`, so
a script finds one stick again by them whatever drive it lands in.

### EROFS, unauthenticated

A drive's EROFS volume is a stranger's image: no hash tree the boot
image pins covers it, and a root hash the medium carries would
authenticate nothing. The media domain reads it unauthenticated, through
an entry kept apart from E1's path by where its parts exist:

* **The source.** `erx_media_blocks`, a module of `erx_media`, reads an
  image's 4 KiB blocks, eight sectors each from the volume's start,
  through the volume's placement, with the per-call bound and the
  answer handling of the hash-checking reader and no hash; its
  `open/1` takes a volume and answers an opaque handle.
* **The entry.** `erx_erofs:mount_unauthenticated/2` takes only that
  handle and keeps it in the mount as the reader's second kind of
  source; the reader's one block read has a clause for each kind, each
  calling its own module by name. `erx_erofs:mount/2`, E1's entry, takes
  only `erx_verity`'s handle, as it does.
* **The separation.** Only `erx_media_erofs`, the volume module, names
  `mount_unauthenticated` or `erx_media_blocks`, and only the media
  domain's release holds `erx_media` (the release check, [Manifest
  rows](#manifest-rows)). So in the system domain, the storage
  domain that serves `system` and every session that mounts a package,
  no unauthenticated handle can be made: the module that makes one is
  not in their runtimes, and `erx_ns` and `erx_storage_system` open
  only `erx_verity` handles, whose every form has a tree. The media
  domain holds no window of the boot medium, so its source never reads
  a system partition (PW1).
* **Serving.** `erx_media_erofs` serves the image from its root with the
  same `erx_fs` callbacks over the reader that serve the `system` tree,
  one module, `erx_erofs_tree`, rooted at `apps/` for the `system` tree
  and at the image's root for a volume. Its reads run in the volume's
  process, not the client's grant, so a structure the reader cannot
  decode fails that operation, and anything worse ends that volume.

Every structure the reader decodes is checked as the storage design
states, an offset, a size or an inode number outside the image failing
the operation with `eio`; on a drive those checks are the defence they
were written to be, and the reader's fuzz target is the test of it.
**Uncompressed images only.** What the reader implements is what fsimg
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

littlefs is C, so on a drive it runs only in its target placement, the
**port**: a sub-space of the media domain for each littlefs volume,
holding its channel and its data area and nothing else, with the shape
of a program ([design-storage.md](design-storage.md#read-write-storage),
"littlefs, the stopgap"; [design-programs.md](design-programs.md#a-program-is-a-port)).
The volume process is the port's owner, `erx_lfs`: it sends the
volume's operations on the channel and serves the port's block requests
itself, each placed in the volume and refused with an error answer when
it reaches past it. So:

* a crash, a littlefs assertion or the port's exit ends the port, which
  the owner sees as `{exit_status, N}` and ends with it: the volume is
  `failed`, its requests answer `eio`, and nothing else ends;
* a memory error that a crafted volume steers reaches the port's
  sub-space, its channel, and through its owner the sectors of its own
  volume and the answers to its own volume's requests, which the owner
  decodes as untrusted input; it reaches no window, no other volume, no
  device and no runtime;
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
which FAT's batches only approach. The writable rule applies as to FAT.
No drive volume reaches the NIF form: the media domain's release holds
no `erx_littlefs` ([Manifest rows](#manifest-rows)). What a
release commits to for littlefs on a drive is
[design-stopgap.md](design-stopgap.md#littlefs-on-a-drive)'s.

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
* **its mount allowance** taken from `media_volume_heap_max`, so a
  volume larger than the allowance admits answers `enomem`, refused by
  name;
* **qid paths drawn per mount**, as FAT's and littlefs's are, since its
  own 64-bit path does not fit beside the mount's number
  ([Identity](#identity));
* the clean room's legal review before any distribution, as for the
  data partition.

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
answers a window the drive process has not mounted, it starts that
medium's supervisor and waits for the reader to have read the table and
probed each volume, so the listing that follows names every volume. With
no medium, or once a medium has ended, `diskN` holds `status` and `ctl`
alone. Walking into `sN` reaches that volume's root while it is mounted;
a volume refused or not served answers `eio` there and shows why in
`status`.

Every request on a volume's node goes to its volume process. Reads and
writes are waiting requests whose keeper is the volume process
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"), so a slow medium delays only requests on it; the
other operations, walks, attributes, listings, creates and renames, are
calls the grant waits for as a local file system's grant waits for its
disk, within the window's deadlines, so a slow medium delays the other
requests of that session's `media` grant for that long. A call to a
volume process that has ended answers `eio` at once.

### Status

`status` is one attribute a line, `NAME <tab> VALUE`, in the form an
app's `status` file takes, with each value through the field escape
([design-app-trees.md](design-app-trees.md#a-status-line)), so one
parser reads both:

| Name | Value |
| --- | --- |
| `medium` | `none`, `ready`, `ejected` or `failed` |
| `transport`, `sectors`, `flush` | the transport's name, the medium's capacity, and `yes` or `no` |
| `table` | `mbr`, `gpt`, `none` or `refused FINDING` |
| `sN` | volume N's format, a name of the probe's table or `unknown`; `extended` for an MBR's extended entry |
| `sN_mount` | `rw`; `ro` with the writable rule's reason; `refused` with the flush's answer; `not served`; or `failed` with why the volume ended |
| `sN_sectors` | its length |
| `sN_also` | the other formats the probe found |
| `sN_fat` | FAT's type, `12`, `16` or `32` |
| `sN_label`, `sN_serial` | the volume's label and serial number, or a GPT entry's name and unique GUID, as the medium gives them |
| `unserved` | how many volumes past `media_volumes_max` the table lists |

A value the medium supplies, a label, a name or a GUID, is text from an
untrusted source and is escaped as any such text is
([CLAUDE.md](../CLAUDE.md), "Text from untrusted sources").

### Eject

A write to `ctl` is one command, as the `ctl` of an app's tree takes
one ([design-app-trees.md](design-app-trees.md#commanding-ctl)). The one
command is `eject`, compared as bytes, its trailing newline optional;
any other answers `einval`. `eject` finishes every writable volume of
the drive's medium (FAT's last batch and its dirty flag cleared, every
open littlefs file synced) and flushes, then ends the medium's
supervisor and marks the medium `ejected`. The write answers `ok` when
every volume finished, `eio` when one did not, the medium being ended
either way, and `enxio` when the drive holds no mounted medium. An
ejected medium is not mounted again until it ends and a medium arrives:
taking the stick out and putting it back. The word promises what
macOS's and FreeBSD's ejects promise of a stick, that it may be pulled
without loss; nothing moves, since no command of the SCSI subset ejects
a medium ([design-usb.md](design-usb.md#the-scsi-subset)).

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

### Mounting it

`erx_ns`'s table of mount points gives `media` the point `/media`, read
at `erx_ns:mount_facets/1`, so a session granted `media` mounts it there
and a session granted none sees the release's empty, read-only `/media`
directory, as for `/data`
([design-files.md](design-files.md#building-binding-and-mounting), "A
facet's mount"). `mount` prints it as `PID:/media on /media (media)`;
the type is the tree's root's statfs, `media`, while `df` on a volume's
path reads that volume's own statfs: `msdosfs`, `erofs` or `littlefs`.

## Where each parser runs

| Parser | Runs in | A failure ends | A memory error reaches |
| --- | --- | --- | --- |
| the table (MBR, GPT) | the medium's reader, Erlang | that medium's reading: `medium failed`, no volume | nothing: Erlang code writes only its own heap |
| the probe | the medium's reader | the same | nothing |
| FAT | the volume's process, Erlang | that volume | nothing |
| EROFS | the volume's process, Erlang | that volume | nothing |
| littlefs | the volume's port, C, in its own sub-space | that volume | the port's sub-space and channel; its volume's sectors and answers, through its owner's checks; the kernel's call surface and, on Fiasco, the CPU's branch predictors, as any sub-space's code does ([design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel), FD24, FD32) |
| F2FS, when it joins | the volume's process, Erlang | that volume | nothing |

Nothing of a medium is parsed in the USB domain or a block device's
driver domain, which move sectors; the media domain's own code, which
parses nothing of a medium outside these processes, is the only code of
it whose failure the domain's restart intensity counts.

## Concurrency

* **The drive process** takes the tree's requests for its drive and its
  medium's events one at a time. It never reads a sector: it asks the
  drive's grant for the window, monitors the window, starts and ends the
  medium's supervisor, and holds each volume's pid and outcome. Two
  sessions walking a new medium at once both wait for the one reading,
  and the second finds it done.
* **The medium's reader** reads the table and probes the volumes, then
  starts the volume processes and ends. Each volume process mounts in
  its own time; a walk into a volume still mounting waits for it.
* **Volume processes** run concurrently and share only the window, whose
  requests the serving domain answers one at a time in order. A volume's
  writes reach the window in the order its process makes them; a volume
  that ends leaves its sent requests to complete or fail at the window,
  and no later mount of that medium exists to race them.
* **Eject** reaches each writable volume as a request behind those it
  holds, so the volume finishes what it was given first; a request that
  arrives after the medium's end answers `eio`.
* **A medium's end** and a walk cross only in the drive process: the
  window's end is a message to it, and the next walk after it finds no
  medium, or the next one.
* **A restarted drive process**, after a defect of its own, has ended
  its medium's supervisor with it, since the two are linked; its next
  walk mounts the medium afresh, as a new medium, its predecessor's
  requests ahead of the new mount's at the window.

## Failure handling

| Failure | Detected by | What ends | What the user sees |
| --- | --- | --- | --- |
| a table refused | `erx_media_table` | nothing mounts on that medium | `table refused FINDING`; `diskN` holds `status` and `ctl` |
| a format not served, or none found | the probe | that volume is not mounted | `sN NAME`, `sN_mount not served`; `eio` in `sN` |
| a mount's structure check fails, its allowance is exceeded, or its geometry differs | the format's mount | that volume | `sN_mount failed REASON`; `eio` in `sN` |
| a mount's flush fails | the writable rule | that volume's mount, with nothing written | `sN_mount refused eio`; out and in again to retry |
| a volume's process crashes or passes its heap bound | its supervisor's link, temporary | that volume; its requests answer `eio` | `sN_mount failed`; the drive's other volumes go on |
| a littlefs port exits, asserts or faults | the owner's `{exit_status, N}` | that volume | as above |
| the medium removed, changed or failing | the window's end ([design-usb.md](design-usb.md#media-and-drives)) | the medium's supervisor: every volume and port of it | open files answer `eio`; `diskN` empty but for `status` and `ctl`; the next medium mounts at the next walk |
| a write on a trial boot | the write path (U4) | that write, `erofs` | a FAT write answers `erofs`; a littlefs volume, whose block write failed, ends |
| a FAT volume removed while written | its next mount: the dirty flag | nothing | that volume read-only, `ro dirty`, until repaired on another machine |
| the drive process ends | `erx_media_sup` | that drive's medium mounts | `eio` on its open files; the next walk mounts afresh |
| the media domain ends | the domain service | every drive's mounts | `/media` answers `eio` until the restarted domain's re-grant; open files keep answering `eio` |
| the serving domain ends (the USB domain, a block device's driver domain) | the drive grant's end | that domain's drives' media | as a removal; the restarted domain's drive grants reach the media domain as every window's grant reaches its holder |

## Refusals and error results

| Call or input | Answer | When |
| --- | --- | --- |
| a drive grant's `window` | `{error, no_medium}` | the drive holds no ready medium |
| `erx_media_table:read/2` | `{refused, Finding}`: `gpt header`, `gpt array`, `past the end`, `overlap`, `before the first usable sector` | the scheme's checks; each finding names the entries |
| `erx_media_table:place/3` | `{error, erange}` | a request that reaches past its volume |
| a walk into `sN` | `eio` | the volume is not served, failed, refused or ended |
| a write on a read-only volume | `erofs` | the writable rule mounted it read-only |
| a write on a grant that is not `rw` | `erofs` | before any callback (F5) |
| a write to `ctl` | `einval` | anything but `eject` |
| `eject` | `enxio`; `eio` | no mounted medium; a volume did not finish |
| a write to `status` | `eacces` | always |
| a create, remove or rename in `/media` or `diskN` | `eacces` | always |
| following a link in `/media` | `eacces` | always (nosymfollow) |
| `erx_erofs:mount_unauthenticated/2` | `{error, enotsup, Text}`, `Text` `erofs: compressed images are not supported` for a compression feature, and naming the bits or the size otherwise | a compression feature, any other incompatible feature, another block size, extended superblock slots |
| a compressed or chunked EROFS inode | `enotsup` | when it is reached |
| the manifest check | the build fails | each rule of [Manifest rows](#manifest-rows) |
| the release check | the build fails | `erx_media` in another release; `erx_storage` or `erx_blk` in the media domain's |

## Security

Every byte of a drive is a stranger's, and the design places every
parser of it where its worst outcome is the medium's own volumes. The
transport's domain, which holds a DMA-capable controller, moves sectors
and parses none of the medium. The media domain holds no device and no
window of the boot medium, so neither an Erlang defect in a parser nor
the littlefs port reaches a device, the data partition, the vault or the
slots. Erlang parsers fail processes, not memory; littlefs's C is
confined to a sub-space per volume, whose every block request its owner
places in that volume. What remains is what any code in a sub-space can
do: call the kernel and run on the CPU. On Fiasco that is FD24's
system-call surface and FD32's branch predictors, which a crafted
littlefs volume reaches only through a memory error in littlefs that it
can steer; the image and request fuzz targets are the defence, as on
the data partition.

E1's guarantee is unchanged for what it protects: the system partition
and packages are parsed only after their trees check, in runtimes where
no unauthenticated EROFS handle can be made. A drive's EROFS image is
parsed unauthenticated, in the media domain, and served as files no
session runs.

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
| `erx_media_table` over written cases of each rule: an MBR with one and with four entries; a FAT boot sector with zero entries and a plausible BPB, read as no table; a boot sector whose status bytes are not 0 or `0x80`, read as no table; entries of type `0x00` and `0xEE` and of start or length 0 skipped; an extended entry listed and not served; an entry past the end and two overlapping entries, each refusing the table, in both orders; a GPT behind its protective entry, with a primary that fails its header CRC, its array CRC and its bounds in turn, each read from the backup; both failing; an array of 17 KiB; nine used GPT entries, eight served | the status-byte test dropped, so a boot sector with code is read as a table; the protective entry served, so a volume covers the GPT's header; the overlap check made order-dependent, so the second order passes; the backup read at the alternate sector of a failed primary instead of the last sector; the array bound removed |
| the table as a property test: for every MBR and GPT the generator writes, the served volumes lie inside the medium and pairwise apart, and `place/3` never answers a sector outside its volume | the end check written `<` for `=<` |
| `erx_media_probe` on a seed of each table row, and on a FAT32 volume holding EROFS's magic at 1,024 bytes | the order reversed, so the FAT volume is named `msdosfs` alone; `also` dropped |
| the writable rule over every combination of format, probe answer, flush answer and dirty flag | the `also` condition removed, so the doubly formatted volume mounts writable; every flush answer but `ok` taken as `enotsup` |
| the drive process and the media tree, under `erx_media_sup` against a fake drive grant and window: a medium's mount, a listing, a read; the window's end, after which an open fid answers `eio` and `diskN` lists `status` and `ctl`; a new window, mounted at the next walk; `eject` with a FAT volume holding a batch; a volume process killed, the others still served; a volume past its heap bound | the drive process not monitoring the window, so the open fid reads after the end; a volume process started as a permanent child, so the kill restarts it; `eject` answering before the batch's flush |
| `erx_erofs:mount_unauthenticated/2` over `erx_media_blocks` on fsimg images and on the reader's existing cases, which leave `erx_verity`'s `unchecked` mode; an fsimg image with a compression feature bit set refused with `erofs: compressed images are not supported`, and one with a compressed inode answering `enotsup` there | `erx_media_blocks` reading past its volume, which a fixture image at a partition's start shows; the compression bits taken as any other incompatible bit, so the refusal names bits instead of compression |
| `Erx::ErofsReads` extended: no module but `erx_media_erofs` names `mount_unauthenticated` or `erx_media_blocks`; `erx_verity` has no `unchecked` | each with a seeded violation: `erx_ns` calling `mount_unauthenticated`; `erx_storage_system` naming `erx_media_blocks`; `unchecked` restored |
| the manifest check's drive rules and the release check | each rule with a seeded manifest that breaks it alone |
| the littlefs owner over a fake port on the host: a block request past the volume refused; the port's exit ending the volume | the placement check removed |

### Fuzz targets

Each lands with its parser and builds the same sources for the host:

* `erx_media_table`, MBR and GPT, seeded from the host tests' cases;
* `erx_media_probe`, seeded from one volume of each format;
* the FAT server's decoders, already a target of the storage design;
* the EROFS reader, through `erx_media_blocks`, the reader's existing
  target moved off `unchecked`;
* littlefs's image target and its request target, built with
  `erx_lfs_config` as now, and the port's channel decoder on each side,
  landing with the port ([design-stopgap.md](design-stopgap.md#littlefs-on-a-drive)).

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
| a FAT16 and a FAT32 stick on an MBR, a FAT32 stick with no table, a FAT32 stick on a GPT, and a FAT12 stick, each listed and read; FAT12's `status` says `ro format` | the no-table rule dropped, so the bare stick shows no volume |
| an EROFS stick, uncompressed, fsimg's | the volume module mounting with `erx_erofs:mount/2`, which no layout opens |
| a littlefs stick of erXos's geometry, written by the harness's littlefs tool, once the port exists | the owner's placement check removed, while the port asks for a block past the volume |
| a stick of each refused name (an exFAT, an NTFS and an ext2 signature, each the format's header alone) refused by name, its bytes unchanged | the probe answering `unknown` for every unserved format |
| a FAT32 stick that also holds EROFS's magic at 1,024 bytes: read-only, `ro also erofs`, its bytes unchanged after a write is refused | the `also` condition removed |
| a FAT32 and a littlefs stick written, synced, ejected through `ctl`, read again after the stick is put back; the FAT image passes fsimg's verify after the run | the eject's flush skipped, so the FAT image is dirty |
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

1. **Whether a release serves drives, and with which formats.** A
   release that serves drives ships the media domain and, for littlefs,
   the port under [the contract](design-stopgap.md#littlefs-on-a-drive).
   Recommendation: 0.2 serves FAT and EROFS volumes, whose parsers are
   Erlang, and littlefs volumes only once the port's fuzz targets have
   run their budgets clean; until then a release's probe names littlefs
   and refuses it.
2. **littlefs's dependency status.** On a drive littlefs is a format
   media carry, which erXos's F2FS does not replace, so littlefs
   outlives its stopgap role on the data and vault partitions.
   Recommendation: its dependency row becomes `permanent` for drives, in
   the port form, and stays `stopgap` for the data and vault partitions
   until F2FS.
3. **FAT12 images for the tests.** The FAT12 case needs an image writer;
   fsimg writes FAT16 and FAT32 for the medium. Recommendation: fsimg
   gains FAT12; until then the FAT12 case uses the Linux oracle guest's
   `mkfs.fat -F 12` at the milestone gate.

## References

* [design-storage.md](design-storage.md): the block service, windows,
  FAT, EROFS, littlefs's port.
* [design-usb.md](design-usb.md): media, drives, the SCSI subset.
* [design-files.md](design-files.md), [design-app-trees.md](design-app-trees.md):
  `erx_fs`, keepers, facet mounts, links, `status` and `ctl`.
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
  ([littlefs/ORIGIN.md](../littlefs/ORIGIN.md)).
