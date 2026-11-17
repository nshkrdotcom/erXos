# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'json'
require 'tmpdir'
require_relative '../../tools/lib/erx/netboot'

# Staging a board's boot files for its firmware's network boot (Erx::Netboot): the set the
# card's build record lists is copied whole and checked before the TFTP root's link swaps
# to it, so the root names one complete build or the one before, never a mix.
class NetbootTest < Minitest::Test
  def setup
    @scratch = Dir.mktmpdir('erx-netboot-test-')
    @root = File.join(@scratch, 'tftp')
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def test_stage_copies_the_listed_set_and_names_the_build
    medium = medium('a', commit: 'c' * 40, dirty: false)
    staged = Erx::Netboot.stage(medium: medium, root: @root)
    assert_equal served, files('a')
    assert_equal ['c' * 40, false], [staged.commit, staged.dirty]
    assert_equal Digest::SHA256.hexdigest(files('a').fetch('kernel8.img')), staged.kernel
    assert_equal File.realpath(staged.directory), File.realpath(@root)
  end

  # A second build replaces the first whole, and the first's directory goes.
  def test_a_second_stage_replaces_the_first
    first = Erx::Netboot.stage(medium: medium('a'), root: @root)
    Erx::Netboot.stage(medium: medium('b'), root: @root)
    assert_equal served, files('b')
    refute File.exist?(first.directory)
    assert_equal [File.basename(@root), File.basename(File.readlink(@root))].sort, siblings.sort
  end

  # A boot directory missing a file the record lists is refused, and the root keeps the
  # build it served.
  def test_an_incomplete_set_is_refused
    Erx::Netboot.stage(medium: medium('a'), root: @root)
    broken = medium('b')
    File.delete(File.join(broken, 'boot', 'overlays', 'uart3.dtbo'))
    error = assert_raises(Erx::Error) { Erx::Netboot.stage(medium: broken, root: @root) }
    assert_match(%r{boot/overlays/uart3\.dtbo, which the build record lists, is missing}, error.message)
    assert_equal served, files('a')
    assert_equal 2, siblings.size
  end

  # A file that changed after the record was written (a pack replacing boot/ meanwhile)
  # fails the copy's check part way through the set; the root still serves the earlier
  # build whole, and the partial copy is gone.
  def test_a_failed_copy_leaves_the_previous_build_whole
    Erx::Netboot.stage(medium: medium('a'), root: @root)
    changed = medium('b')
    File.write(File.join(changed, 'boot', 'start4.elf'), 'another build')
    error = assert_raises(Erx::Error) { Erx::Netboot.stage(medium: changed, root: @root) }
    assert_match(%r{boot/start4\.elf differs from the build record}, error.message)
    assert_equal served, files('a')
    assert_equal 2, siblings.size
  end

  # Something at the root that is not netboot's link is refused and left as it was; a
  # link to a directory netboot did not make is replaced but the directory is kept.
  def test_only_its_own_link_and_directories_are_touched
    Dir.mkdir(@root)
    error = assert_raises(Erx::Error) { Erx::Netboot.stage(medium: medium('a'), root: @root) }
    assert_match(/is not a symbolic link/, error.message)
    assert_equal ['tftp'], siblings

    Dir.rmdir(@root)
    mine = File.join(@scratch, 'tftp.mine')
    Dir.mkdir(mine)
    File.symlink('tftp.mine', @root)
    Erx::Netboot.stage(medium: medium('a'), root: @root)
    assert_equal served, files('a')
    assert File.directory?(mine)
  end

  # A record that lists a name outside the boot partition's layout is refused before
  # anything is copied.
  def test_a_name_outside_the_layout_is_refused
    medium = medium('a')
    path = File.join(medium, 'sdcard.img.receipt.json')
    record = JSON.parse(File.read(path))
    record.fetch('components') << { 'path' => 'boot/../escape', 'sha256' => '0' * 64 }
    File.write(path, JSON.generate(record))
    error = assert_raises(Erx::Error) { Erx::Netboot.stage(medium: medium, root: @root) }
    assert_match(/no file name of the boot partition/, error.message)
    assert_empty siblings
  end

# A medium with no build record, the board's card never packed, is refused by name.
def test_a_missing_record_is_refused
  medium = medium('a')
  File.delete(File.join(medium, 'sdcard.img.receipt.json'))
  error = assert_raises(Erx::Error) { Erx::Netboot.stage(medium: medium, root: @root) }
  assert_match(/no build record .*; pack the board's card first/, error.message)
  assert_empty siblings
end

# A listed file that is a symbolic link is refused even when what it names holds the
# listed bytes: boot/ holds the files the card build wrote, not links to them.
def test_a_symbolic_link_in_the_set_is_refused
  medium = medium('a')
  kernel = File.join(medium, 'boot', 'kernel8.img')
  File.rename(kernel, File.join(@scratch, 'elsewhere'))
  File.symlink(File.join(@scratch, 'elsewhere'), kernel)
  error = assert_raises(Erx::Error) { Erx::Netboot.stage(medium: medium, root: @root) }
  assert_match(%r{boot/kernel8\.img is a symbolic link}, error.message)
  assert_equal ['elsewhere'], siblings
end

# A staged directory an interrupted stage left behind goes with the next stage.
def test_a_leftover_staged_directory_is_removed
  leftover = File.join(@scratch, 'tftp.0123456789abcdef')
  Dir.mkdir(leftover)
  Erx::Netboot.stage(medium: medium('a'), root: @root)
  refute File.exist?(leftover)
  assert_equal 2, siblings.size
end

  private

  # The boot partition's files of build tag, kernel8.img, config.txt and an overlay among
  # them, each holding bytes of its own build.
  def files(tag)
    %w[start4.elf fixup4.dat config.txt kernel8.img bl31.bin bcm2711-rpi-4-b.dtb overlays/uart3.dtbo]
      .to_h { |name| [name, "#{name} of build #{tag}\n"] }
  end

  # A production image's directory for build tag, as the card build leaves it: boot/
  # and the card's build record, written by the card build's own receipt (BootPartition).
  def medium(tag, commit: 'f' * 40, dirty: true)
    directory = File.join(@scratch, tag)
    files(tag).each do |name, bytes|
      path = File.join(directory, 'boot', name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, bytes)
    end
    image = File.join(directory, 'sdcard.img')
    File.write(image, "card #{tag}")
    receipt = Erx::BootPartition.receipt({ 'source' => { 'commit' => commit, 'dirty' => dirty } }, image: image,
                                         files: files(tag).transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
                                         pieces: { 'data.lfs' => '0' * 64 })
    File.write(File.join(directory, 'sdcard.img.receipt.json'), JSON.generate(receipt))
    directory
  end

  # Every file the TFTP root serves, by its name under the root, to its bytes.
  def served
    Dir.glob('**/*', base: "#{@root}/").reject { |name| File.directory?(File.join(@root, name)) }
       .to_h { |name| [name, File.read(File.join(@root, name))] }
  end

  # What lies beside the root: the link and the staged directories, but not the media
  # or the lock file.
  def siblings
    Dir.children(@scratch).reject { |name| %w[a b tftp.lock].include?(name) }
  end
end
