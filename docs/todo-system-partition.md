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

* [High] storage, the `system` tree (`erlang/apps/erx_storage`,
  `tools/lib/erx/manifest.rb` property 19):
  the packer and fsimg writing
  the partition's hash tree after its image and refusing an image and
  tree larger than the partition, and the update
  writing the tree and the manifest with the partition; property 19 deriving the
  `system` rows, the system domain's and the app template's, `ro` and `rx`,
  and the `apps` row's `system_facet` (a field of `erx_mf_apps`, which
  `boot_app_grants` in `liberx/system/dom_boot_view.c` and
  `erx_pkg_manifest` read beside `packages_facet`). Test: a
  QEMU test that reads a multi-block package file through the grant;
  seeded: a write through the grant, which must answer `erofs` before any
  callback, and a flipped bit in the partition's directory, which must
  answer `eio` before the reader parses it.
* [High] files, the file-backed EROFS mount (`erx_ns`, `erx_verity`):
  `erx_ns:mount({erofs, Source}, To, Options)` as the one EROFS mount,
  `Source` `app` (the place and layout of the app's record) or
  `{header, Path}` (only for a file reached through the `apps` grant,
  its header read by `erx_verity:header/1`), no form taking a layout,
  `erx_ns`'s process owning the fid, the mount's rights `ro` or `rx`
  (`rw` refused with `einval`), `rx` only through an `rx` grant, so only
  through the app template's `rx` `packages` and `system` grants, and
  each mount's files keyed by a tree of its own; the image check needing
  `rx` on the entry and on the grant beneath it (design-files.md, "Rights
  beneath an entry"); `erx_ns.erl` has only `{erofs, Image}`, an image its caller opened, which goes, and `erx_ns` joins `Erx::ErofsReads`'s `MOUNTERS`. Test: the
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
  derived row carry it. The stopgap's `packages` mint roots every grant
  at `packages/` (design-stopgap.md, the storage domain), so an app's
  grant reaches an upload in progress until this lands. Test: the
  package mounts' row, a walk of `new` and of `../new/tmp.K` through the
  app's grant during an upload answering `enoent`; seeded: the app's
  grant rooted at `packages/`, which walks to `tmp.K`.
* [High] apps, packages out of the boot image (`tools/lib/erx/production_image.rb`
  `package_entries`, `erlang/apps/erx_starter/src/erx_pkg_medium.erl`
  `place(system, ..)`, `erx_principal`): the packer writes each image package
  to `apps/NAME.app` in the slot's system partition; the package process
  reads image packages' headers through the `system` grant; the app's
  record names `NAME.app` on the `system` grant. Test: `ls /apps` on a kiosk image
  shows the image's package, read-only; seeded: the package left in the
  boot image, which the packer check below must refuse.
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
  trial boot; seeded: the shadow check dropped, which lists the name twice.
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
  slot's `release.erofs` copy): delete them. The release copy's only readers
  are tests of the mechanism being deleted: `image_checkpoints` in
  `tools/lib/erx/medium_boot.rb` (checked by `test/host/medium_boot_test.rb`),
  which reads `lists.beam` from `/images/release`, and the
  `SLOT_IMAGES_START` cases of `test/host/release_medium_test.rb` and
  `test/host/boot_partition_test.rb`. Each moves to the `system` tree: the
  medium boot reads a package file through the storage domain's grant, and
  the medium tests read the system partition's image.

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
