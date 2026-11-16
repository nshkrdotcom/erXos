# The system partition and the `system` tree

The work that brings the code to the target design of
[design-storage.md](design-storage.md#the-system-tree): each slot is a
boot partition and a read-only EROFS system partition, the storage domain
serves the booted slot's system partition as the `system` tree, every
package is a self-checking file there read through a grant, and the boot
image holds what the manifest names to run and no package. Index:
[TODO.md](../TODO.md), Major initiatives.

## Build

Each item lands with its tests, each passing case beside a seeded fault
that proves the code under test ran.

* [High] storage, the `system` tree (`erlang/apps/erx_storage`): the
  packer writes the partition's hash tree after its image, the image's
  packages at `apps/NAME.app`, and refuses an image and tree larger than
  the partition (`tools/lib/erx/release_medium.rb`); what remains is the
  update writing the tree and the manifest with the partition, which
  waits on the slot writer (the update item below). Test: a
  QEMU test that reads a multi-block package file through the grant;
  seeded: a write through the grant, which must answer `erofs` before any
  callback, and a flipped bit in the partition's directory, which must
  answer `eio` before the reader parses it.
* [High] files, the rest of the file-backed EROFS mount (`erx_ns`,
  `erx_verity`; design-files.md, "Building, binding and mounting"). The
  `app` source exists: `erx_ns`'s process takes the place and layout from
  the record the agent holds (`erx_connections:app_held/0`), walks the
  names on the facet's grant to a fid it owns, opens it with
  `erx_verity:open_file/3` and clunks the fid once no entry holds it; its
  rights are `ro` or `rx`, `rw` refused with `einval`. What remains: the
  `{header, Path}` source (only for a file reached through the `apps`
  grant, its header read by `erx_verity:header/1`); `rx` only through an
  `rx` grant, `eacces` otherwise, which waits on the security residual
  "files, the app mount's rights" in TODO.md; a deadline on the file
  source's exchanges and a clunk that does not wait, since `erx_ns`'s
  process, and every change and read queued behind it, waits without
  bound on a file server that stops answering; each mount's files
  keyed by a tree of its own; the image check needing `rx` on the entry
  and on the grant beneath it (design-files.md, "Rights beneath an
  entry"); and a record that names an image package's file on the
  `system` grant, which waits on the `system` tree item above. Test: the
  package mounts' host test of design-packaging.md and F6's `/x` test;
  seeded: a mount that takes its rights from its options, which mounts a
  file of `/apps` `rx`; a mount bounded only by its grant's rights, which
  mounts it `rw`; a `header` mount judged by the path rather than the
  fid's grant, which mounts a session-written `/tmp` file once `/tmp` is
  bound at `/apps`; an image check that reads the entry's rights alone,
  which runs a file written under an `rx` mount of `data`.
* [High] packaging, uploads apart from installed packages (`erx_pkg_io`,
  `erx_lfs`, property 19): the `packages` tree's `new/` and `installed/`,
  an upload's `tmp.K` in `new/` renamed into `installed/`, the recovery
  removing `new/tmp.K` by name and listing `installed/`, and the
  storage service's `tree installed`, which roots the app template's
  `packages` grant at `installed/`, with property 19 letting only the
  derived row carry it, and property 19 deriving that row `rights rx`
  rather than the `ro` that `app_facets` (`tools/lib/erx/manifest.rb`)
  derives today, the two together so no `rx` grant reaches `new/`. The stopgap's `packages` mint roots every grant
  at `packages/` (design-stopgap.md, the storage domain), so an app's
  grant reaches an upload in progress until this lands. Test: the
  package mounts' row, a walk of `new` and of `../new/tmp.K` through the
  app's grant during an upload answering `enoent`; seeded: the app's
  grant rooted at `packages/`, which walks to `tmp.K`; and a manifest
  test that the template's derived `packages` row is `rx`.
* [High] build, the boot image rule (`tools/lib/erx/production_image.rb`):
  a packer check that every file of the boot image is an artifact a
  manifest row names by its role (the kernel, the root, the system release
  with the manifest, each configured domain's and session template's
  runtime image and release, the system domain's own runtime image, the
  shared-code image `runtimes/emu.code` when `shared_code_image` is true,
  and each partial-boot program's image), and
  that no file of any slice begins with the package container's magic,
  failing with the file and the rule named; and that the system partition's
  image fits its partition. Test: the check on the production image, with and without a shared-code image;
  seeded: one package file added to a domain release, and a file no row
  names.
* [High] apps, one flat `/apps` (`erx_pkg_io`, `erx_pkg_plan`): image
  packages listed at `/apps/NAME.app`, read-only, a create of an image
  package's name answering `erofs`; an installed package whose name a
  system update gave to the image shadowed, kept on the data partition,
  listed as `.NAME.app`, shown `shadowed` at `[packages, Name, shadowed]`
  of `/proc/packages`, removable
  there, and its data purged through `remove_app` with every other
  signer's of the name but `image`; nothing written on a trial boot
  ([design-packaging.md](design-packaging.md#boot-and-recovery)). Test: the
  recovery over a directory holding such a package, on a normal and on a
  trial boot, and `ls /apps` on a kiosk image showing the image's package,
  read-only; seeded: the shadow check dropped, which lists the name twice.
* [High] update, the slot writer and the update for two partitions
  (the slot writer and update service are not yet built; the TLA+ model
  and the host's exhaustive model of
  [design-storage.md](design-storage.md#verification-and-testing)): writes to the spare's boot and system partitions by
  name, the manifest binding both images' hashes, the check of the spare
  over both, and the model rerun with a power cut after every write of each
  partition (U1, U3, U5). Test: the model; seeded: a check that covers the
  boot partition alone, which the model must catch.
* [Medium] storage, deletions (`erlang/apps/erx_blk/src/erx_blk_image.erl`,
  `erx_blk_service.erl` `image_windows/1`, the `{image, Name}` role of
  `erx_blk_table` (`read_only/1`), `abi/manifest.txt`'s
  `verified_image` window role, the `images` and `extents` tables, the
  `image` declaration and the window's `image` field, `erofs_unchecked`,
  `SLOT_IMAGES_START` and `image_extents` in `release_medium.rb`, and the
  slot's `release.erofs` copy): delete them. Until then a boot with a
  slot logs `erx_blk_service: no image is served: the manifest: enoent` in
  the block device's holder, since `image_windows/1` reads a manifest its namespace does not
  hold. The release copy's only readers are the `SLOT_IMAGES_START` cases
  of `test/host/release_medium_test.rb` and `test/host/boot_partition_test.rb`,
  which move to reading the system partition's image, as the medium boot's
  `image_checkpoints` does.

## Residuals

* [Medium] apps, installing over `scp` ([design-ssh.md](design-ssh.md), the
  `apps` tree): copying `NAME.app` into `/apps` with OpenSSH's `scp` and
  running it is untested; whether OpenSSH sets the file's attributes after
  its close, which the `apps` tree's close-time install would then have to
  answer without undoing the install, is unverified. Test it once the SSH
  server's file transfer reaches `/apps`.
* [Medium] storage, the Raspberry Pi 4 with the new table: the
  bootloader's documentation (design-storage.md, References) says it boots
  only a FAT partition named by its number, counted from 1, but nothing read
  says how it treats four logical partitions behind entry 4; the board's
  manual checklist boots a card with the new table, A and B, before the
  layout lands.
* [Medium] storage, availability of the kiosk: the kiosk and every app
  wait on the storage domain that serves `system`, which in the default
  configuration also serves the data partition; a crash of it stops every
  app until it restarts. Measured by the boot-to-first-frame item of
  [todo-performance.md](todo-performance.md).
