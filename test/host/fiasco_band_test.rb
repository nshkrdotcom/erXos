# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# The Fiasco backend's bands, on the host (docs/design-fiasco.md, "Bands"): the
# driver test/fixtures/fiasco_band_driver.c prints the priority table, the bands
# a domain's space and a sub-space take, and the decoder's word count of
# domain_space_create, and each seed below must change what it prints.
class FiascoBandTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  BAND = 'liberx/backend/fiasco/band.c'
  WIRE = 'liberx/backend/fiasco/service_wire.c'
  DRIVER = 'test/fixtures/fiasco_band_driver.c'
  EINVAL = -1

  # The bands: none 0, driver 1, interactive 2, app 3, and the root's system 4 and watchdog 5.
  REFUSED = "#{EINVAL} domain=0 band=0 space_band=0 cpuset=0".freeze
  EXPECTED = [
    'priorities 255 4 3 2 1 0',
    'domain driver 0 domain=0 band=1 space_band=1 cpuset=0xc',
    'domain session 0 domain=0 band=2 space_band=3 cpuset=0xc',
    'domain app 0 domain=0 band=3 space_band=3 cpuset=0xc',
    *%w[band_zero band_past space_band_zero space_band_past].map { |name| "domain #{name} #{REFUSED}" },
    'space of_session 0 domain=7 band=3 space_band=0 cpuset=0',
    'wire exact kind=3 status=0',
    "wire short kind=2 status=#{EINVAL}",
    "wire long kind=2 status=#{EINVAL}"
  ].freeze

  # name => [core, original, replacement]: the faults design-fiasco.md's verification
  # rows name, planted in the pure core the root service decides by.
  MUTANTS = {
"a space takes its creator's own band" => [BAND, '.band = creator->space_band', '.band = creator->band'],
'a space names its own domain row' => [BAND, '.domain = creator_domain', '.domain = 0'],
'a band outside the enum is taken' => [BAND, 'erx_band_name(request->band) == NULL || ', ''],
'a sub-space band outside the enum is taken' => [BAND, ' || erx_band_name(request->space_band) == NULL', ''],
'the domain create has no word count' => [WIRE, "\tcase ERX_FIASCO_CALL_DOMAIN_SPACE_CREATE:\n", ''],
'a request longer than its layout is taken' => [WIRE, 'input->words != expected', 'input->words < expected']
  }.freeze

  def setup = @directory = Dir.mktmpdir('erx-fiasco-band-')

  def teardown = FileUtils.remove_entry(@directory)

  def test_the_driver_prints_the_bands
    assert_equal EXPECTED, run_driver(build(cores, name: 'driver'))
  end

  MUTANTS.each do |name, (core, original, replacement)|
    define_method("test_seed_#{name.tr(" '", '__')}") do
      source = File.read(File.join(ROOT, core))
      assert_equal 1, source.scan(original).size, 'the seed no longer applies'
      seeded = File.join(@directory, File.basename(core))
      File.write(seeded, source.sub(original) { replacement })
      # A seed may leave a parameter unused, which is no fault of the driver's.
      sources = cores.map { |path| path.end_with?(core) ? seeded : path }
      lines = run_driver(build(sources, name: 'seeded', flags: %w[-Wno-unused-parameter]))
      refute_equal EXPECTED, lines, "#{name}: the driver saw nothing"
    end
  end

  private

  def cores = [BAND, WIRE].map { |core| File.join(ROOT, core) }

  def build(sources, name:, flags: [])
    output = File.join(@directory, name)
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                                  '-O1', '-g', *flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'),
                                  '-I', ROOT, *sources, File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def run_driver(driver)
    log, status = Open3.capture2e(driver, stdin_data: '')
    assert status.success?, log
    log.lines(chomp: true)
  end
end
