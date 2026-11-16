# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/image_record'

# An image's build record (Erx::ImageRecord): what the image build writes beside
# image.boot, and the website's check of it, which takes only a record of this
# image, of the linked commit with no changes, of a configuration that is not a
# local test image's, and with no package.
class ImageRecordTest < Minitest::Test
  ImageRecord = Erx::ImageRecord
  COMMIT = '0123456789abcdef0123456789abcdef01234567'
  REVISION = Erx::SourceRevision::Revision.new(count: 42, hash: COMMIT[0, 12], commit: COMMIT, dirty: false,
                                               committed_at: Time.at(1_794_160_931).utc)
  FACTS = Erx::BuildFacts::Facts.new(revision: REVISION.to_s, date: 1_794_160_931,
                                     configuration: 'qemu-virt/development', kernel: 'fiasco-50bbe8a98119')
  PACKAGE = { 'path' => 'apps/doom.app', 'sha256' => 'd' * 64 }.freeze

  # Writes an image and its record into a directory of their own, and yields the
  # image's path and SHA-256.
  def with_image(revision: REVISION, facts: FACTS, packages: [])
    Dir.mktmpdir('erx-image-record-') do |directory|
      image = File.join(directory, ImageRecord::IMAGE)
      File.binwrite(image, "erXos image\0" * 100)
      ImageRecord.write(image:, revision:, facts:, packages:)
      yield image, Digest::SHA256.file(image).hexdigest
    end
  end

  def record_bytes(image) = File.binread(ImageRecord.path(image))

  def test_the_record_names_the_image_its_commit_its_facts_and_its_packages
    with_image(packages: [PACKAGE]) do |image, sha256|
      assert_equal({ 'version' => 1, 'kind' => 'image',
                     'artifact' => { 'path' => 'image.boot', 'sha256' => sha256 },
                     'source' => { 'commit' => COMMIT, 'dirty' => false },
                     'build_facts' => { 'revision' => 'n42-0123456789ab', 'date' => '1794160931',
                                        'configuration' => 'qemu-virt/development', 'kernel' => 'fiasco-50bbe8a98119' },
                     'packages' => [PACKAGE] }, JSON.parse(record_bytes(image)))
    end
  end

  def test_the_website_takes_a_record_of_this_image_and_commit
    with_image do |image, sha256|
      record = ImageRecord.check(record_bytes(image), sha256:, commit: COMMIT)
      assert_equal 'qemu-virt/development', record.dig('build_facts', 'configuration')
    end
  end

  # The facts are the ones the image's build-facts file holds, so a local test image's
  # record says local as uname -i on the machine does.
  def test_a_local_test_images_record_is_refused
    local = FACTS.with(configuration: Erx::BuildFacts.configuration(platform: 'qemu-virt', build_kind: 'development',
                                                                     local: true))
    with_image(facts: local) do |image, sha256|
      error = assert_raises(Erx::Error) { ImageRecord.check(record_bytes(image), sha256:, commit: COMMIT) }
      assert_match(%r{qemu-virt/development-local.*local test image}, error.message)
    end
  end

  def test_an_image_that_carries_a_package_is_refused
    with_image(packages: [PACKAGE]) do |image, sha256|
      error = assert_raises(Erx::Error) { ImageRecord.check(record_bytes(image), sha256:, commit: COMMIT) }
      assert_match(/package/, error.message)
    end
  end

  # One digit of the SHA-256 off is the record of another image.
  def test_a_record_of_another_image_is_refused
    with_image do |image, sha256|
      other = sha256.sub(/\A./) { |digit| digit == '0' ? '1' : '0' }
      error = assert_raises(Erx::Error) { ImageRecord.check(record_bytes(image), sha256: other, commit: COMMIT) }
      assert_match(/not of this image/, error.message)
    end
  end

  def test_a_record_of_another_commit_or_a_changed_tree_or_no_checkout_is_refused
    other = COMMIT.sub(/\A./) { |digit| digit == '0' ? '1' : '0' }
    { 'another commit' => REVISION.with(commit: other), 'a changed tree' => REVISION.with(dirty: true),
      'no checkout' => nil }.each do |fault, revision|
      with_image(revision:) do |image, sha256|
        assert_raises(Erx::Error, fault) { ImageRecord.check(record_bytes(image), sha256:, commit: COMMIT) }
      end
    end
  end

  # A record hand-made or damaged: each malformed shape is refused with an Erx::Error,
  # never a crash, and a configuration of the wrong shape is not echoed.
  def test_a_malformed_record_is_refused
    with_image do |image, sha256|
      good = JSON.parse(record_bytes(image))
      ['{', '[]', '"image"', JSON.generate(good.merge('build_facts' => [])),
       JSON.generate(good.merge('build_facts' => { 'configuration' => 7 })),
       JSON.generate(good.merge('build_facts' => { 'configuration' => "qemu-virt/\e]8;;x" })),
       JSON.generate(good.merge('build_facts' => {})), JSON.generate(good.merge('packages' => nil)),
       JSON.generate(good.except('packages')), JSON.generate(good.merge('version' => 2)),
       JSON.generate(good.merge('kind' => 'assembled')), ' ' * (ImageRecord::MAX_BYTES + 1)].each do |bytes|
        error = assert_raises(Erx::Error, bytes[0, 80]) { ImageRecord.check(bytes, sha256:, commit: COMMIT) }
        refute_includes error.message, "\e"
      end
    end
  end
end
