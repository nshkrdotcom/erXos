# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'app_package'
require_relative 'boot_record'
require_relative 'bounded_file'
require_relative 'data_volume'
require_relative 'erofs_image'
require_relative 'error'
require_relative 'medium_image'

module Erx
  # The packer's disk image for QEMU (docs/plan.md, M6): a medium laid out by the ABI
  # file's medium layout (MediumImage) whose slot A holds a production image's bootable
  # file in its boot partition and the release's EROFS image in its system partition,
  # which fsimg writes from the system release's files at the paths the boot image's
  # archive gives them (ProductionImage::Built#release), followed by the image's dm-verity
  # tree (system_partition). The boot-selection record
  # commits slot A (BootRecord.sector), and the rest of its partition, slot B and the
  # vault's partition hold zeros. The data partition holds a fresh littlefs volume (DataVolume): writing a
  # medium is installation, the one step that formats /data, since the guest's mount
  # never does.
  module ReleaseMedium
    NAME = 'medium.img'
    EROFS = 'release.erofs'
    IMAGE = 'release'
    SECTOR_BYTES = MediumImage::SECTOR_BYTES
    # Where a slot's EROFS images start, in bytes from the start of the slot's system
    # partition, and the boundary each starts on (docs/design-storage.md, System updates).
    # A fixed start makes every image's extent a function of the images alone, so the
    # boot image can record the extents before it is packed.
    SLOT_IMAGES_START = 0
    SLOT_IMAGE_ALIGNMENT = 1 << 20

    # A host file a slot holds: its name in the slot's plan, its path and its length,
    # measured once.
    SlotFile = Data.define(:name, :path, :length)
    # Where a slot file lies: bytes from the start of the slot's partition that holds it,
    # the boot partition for the bootable file and the system partition for an image, in
    # the shape of the manifest's erx_mf_extent.
    Extent = Data.define(:file, :slot_offset)
    # A slot's contents: the bootable file's extent and each EROFS image's, in order.
    SlotPlan = Data.define(:boot, :images)
    # The booted slot's system partition (docs/design-stopgap.md, "The booted slot"): the
    # release's EROFS image at its Extent, from the partition's start, and its dm-verity
    # tree (AppPackage.image_tree), whose whole blocks start where the image ends.
    SystemPartition = Data.define(:image, :tree) do
      def tree_offset = image.slot_offset + image.file.length
    end
    # The medium as written: its path, the EROFS image's path beside it, its data
    # partition's length, slot A's plan and the data partition's fresh volume
    # (DataVolume.format). A boot of the image boots it with a medium as its disk: this
    # one, or one made by fresh, so that the storage domain serves /data.
    Written = Data.define(:path, :erofs, :data_sectors, :slot, :volume) do
      # A fresh copy of the medium in directory, as written, for a boot that may write
      # its medium; returns its path.
      def fresh(directory:) = ReleaseMedium.medium(slot, directory: directory, data_sectors: data_sectors, volume: volume)
    end

    module_function

    # Where a slot holds the bootable file boot and the EROFS images, each a SlotFile: the
    # bootable file in the boot partition at the sector the layout fixes
    # (medium_slot_boot_start) and the images where image_extents places them. A bootable
    # file that leaves the boot partition is refused.
    def slot_plan(boot:, images:)
      boot_offset = MediumImage.constant('slot_boot_start') * SECTOR_BYTES
      boot_bytes = MediumImage.constant('boot_sectors') * SECTOR_BYTES
      unless boot.length.is_a?(Integer) && boot.length.positive? && boot_offset + boot.length <= boot_bytes
        raise Error, "the bootable file must be at most #{boot_bytes - boot_offset} bytes"
      end

      SlotPlan.new(boot: Extent.new(file: boot, slot_offset: boot_offset), images: image_extents(images))
    end

    # Where a slot's system partition holds the EROFS images, each a SlotFile: from
    # SLOT_IMAGES_START, each at the next SLOT_IMAGE_ALIGNMENT boundary after the one
    # before, so the places depend on the images alone. An image that is not whole
    # sectors or that leaves the partition, and a repeated name, are refused.
    def image_extents(images)
      raise Error, 'a slot names each image once' unless images.map(&:name).uniq.size == images.size

      system_bytes = MediumImage.constant('system_sectors') * SECTOR_BYTES
      images.each_with_object([]) do |image, placed|
        start = placed.empty? ? SLOT_IMAGES_START : align(placed.last.slot_offset + placed.last.file.length)
        unless image.length.is_a?(Integer) && image.length.positive? && (image.length % SECTOR_BYTES).zero?
          raise Error, "the image #{image.name} is not a positive whole number of sectors"
        end
        raise Error, "the image #{image.name} leaves its slot" if start + image.length > system_bytes

        placed << Extent.new(file: image, slot_offset: start)
      end.freeze
    end

    # Writes the system release's EROFS image, EROFS in directory, from entries, the
    # release's entries (ProductionImage::Built#release); the file holds the image alone.
    # Returns its path and the artifacts the packer hands the manifest check: the image
    # under the name the manifest's input names, with its one extent in the slot and the
    # tree the system partition holds after it, its offset from the partition's start, its
    # length, and its salt and root hash in lowercase hex.
    def image(entries:, directory:, runner:)
      path = ErofsImage.new(runner: runner).write(files: files(entries), name: IMAGE, output: File.join(directory, EROFS))
      system = system_partition(path)
      extents = [{ 'slot_offset' => system.image.slot_offset, 'length' => system.image.file.length }]
      tree = { 'offset' => system.tree_offset, 'length' => system.tree.bytes.bytesize,
               'salt' => system.tree.salt.unpack1('H*'), 'root_hash' => system.tree.root_hash.unpack1('H*') }
      [path, { IMAGE => { 'kind' => 'erofs_image', 'extents' => extents, 'tree' => tree } }]
    end

    # The system partition of the release's EROFS image at path: the image where
    # image_extent places it and the tree over its bytes. An image and tree that leave the
    # partition are refused.
    def system_partition(path)
      extent = image_extent(path)
      system_bytes = MediumImage.constant('system_sectors') * SECTOR_BYTES
      partition = SystemPartition.new(image: extent, tree: AppPackage.image_tree(BoundedFile.read(path, maximum: system_bytes)))
      raise Error, "the image #{IMAGE} and its tree leave their slot" if partition.tree_offset + partition.tree.bytes.bytesize > system_bytes

      partition
    end

    # The pieces of the system partition of the EROFS image at path, by sector from the
    # medium's start for a partition starting at sector start: the image, then its tree
    # when the image is more than one block and so has one. Both medium writers place the
    # partition through this function.
    def system_pieces(path, start:)
      system = system_partition(path)
      image = { start + (system.image.slot_offset / SECTOR_BYTES) => MediumImage::FilePiece.new(path: path, length: system.image.file.length) }
      tree = system.tree.bytes.empty? ? {} : { start + (system.tree_offset / SECTOR_BYTES) => system.tree.bytes }
      image.merge(tree)
    end

    # Where a slot holds the system release's EROFS image at path, the slot's one image:
    # its Extent, as image_extents places it.
    def image_extent(path) = image_extents([slot_file(IMAGE, path)]).fetch(0)

    # The EROFS image's files: each release entry's archive path, mapped to its built file.
    def files(entries)
      paths = entries.map { |entry| entry.fetch('path') }
      raise Error, 'the release names a path twice' unless paths.uniq.size == paths.size

      entries.to_h { |entry| [entry.fetch('path'), entry.fetch('artifact')] }
    end

    # Writes the medium into directory, which holds the build of built, whose EROFS image
    # the build wrote (ProductionImage::Built#erofs), with volume, a fresh volume of
    # data_sectors' partition (DataVolume.format), in its data partition.
    def write(built:, directory:, volume:, data_sectors: MediumImage.constant('data_sectors_min'))
      plan = slot_plan(boot: slot_file('boot', built.single), images: [slot_file(IMAGE, built.erofs)])
      Written.new(path: medium(plan, directory: directory, data_sectors: data_sectors, volume: volume), erofs: built.erofs,
                  data_sectors: data_sectors, slot: plan, volume: volume)
    end

    # Writes the medium, NAME in directory, whose slot A holds plan's files, the bootable
    # file in boot A and the one image in system A as its system partition
    # (system_pieces), whose boot-selection record commits slot A and whose data partition
    # holds volume; returns its path. A boot that may write its medium takes a fresh one
    # from the plan and volume of the release medium written once.
    def medium(plan, directory:, data_sectors:, volume:)
      raise Error, 'a release medium holds one image' unless plan.images.size == 1

      boot = plan.boot
      pieces = { MediumImage.constant('boot_a_start') + (boot.slot_offset / SECTOR_BYTES) =>
                   MediumImage::FilePiece.new(path: boot.file.path, length: boot.file.length),
                 **system_pieces(plan.images.fetch(0).file.path, start: MediumImage.constant('system_a_start')) }
      pieces[BootRecord::RECORD_OFFSET / SECTOR_BYTES] = BootRecord.sector(:a)
      pieces.merge!(DataVolume.pieces(volume))
      MediumImage.create(directory: directory, name: NAME, data_sectors: data_sectors, pieces: pieces)
    end

    def slot_file(name, path) = SlotFile.new(name: name, path: path, length: File.size(path))

    def align(offset) = (offset + SLOT_IMAGE_ALIGNMENT - 1) / SLOT_IMAGE_ALIGNMENT * SLOT_IMAGE_ALIGNMENT
    private_class_method :slot_file, :align
  end
end
