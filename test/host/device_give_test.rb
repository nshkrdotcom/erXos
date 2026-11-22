# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/device_give'

# What the device_give suite's harness types and expects (tools/lib/erx/device_give.rb).
# Nothing boots here.
class DeviceGiveTest < Minitest::Test
  Suite = Erx::DeviceGive
  ROOT = File.expand_path('../..', __dir__)
  SITE = Erx::Platform.development(ROOT).site_manifest_source(ROOT)

  # The manifest is MediumBoot's with the row staying up, restarting once, and holding the
  # display unit, which the site manifest leaves unplaced, with root_memory grown by the
  # unit's DMA memory.
  def test_the_row_stays_up_restarts_once_and_holds_the_display_unit
    units = Erx::Platform.development(ROOT).record.fetch('units')
    ours = Suite.manifest(SITE, units: units)
    assert ours.end_with?(Suite::DOMAIN_ROW)
    assert_includes ours, "unit display\n  placement \"display\"\n  holder @domain.erts\n"
    assert_match(/^  restarts 1$/, Suite::DOMAIN_ROW)
    refute_includes Suite::DOMAIN_ROW[/^  args "(.*)"$/, 1].split, '-eval'
    assert_equal Erx::MediumBoot::DOMAIN_ROW.lines.size, Suite::DOMAIN_ROW.lines.size
    refute_match(/placement "display"/, SITE)
    root_memory = ->(source) { Erx::Manifest::Edit.value(source, record: 'machine', field: 'root_memory') }
    assert_equal root_memory.call(Erx::MediumBoot.manifest(SITE, row: Suite::DOMAIN_ROW)) + 9_437_184 + 2 * 65_536,
                 root_memory.call(ours)
  end

  # The answer's offset and size are the graphics device's place in its register page, and
  # its role is one whose record the cell's find names.
  def test_the_answer_matches_the_display_unit_of_the_platform_record
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    unit = platform.fetch('units').find { |entry| entry.fetch('key') == 'display' }
    device = unit.fetch('devices').find { |entry| entry.fetch('role') == 'gpu' }
    assert_equal [Suite::OFFSET, Suite::SIZE], [device.fetch('base') % 4096, device.fetch('size')]
    assert_includes Suite::LINE, 'find(gpu,virtio_mmio)'
    # erts takes id 5, the network domain 6 and the storage domain 7 at boot, so the restart takes 8.
    assert_equal "{device_give,5,{1953655158,3584,512,5},8,{1953655158,3584,512,8}}", Suite::ANSWER
    assert_includes Suite::LINE, 'state:=ready,node:=erts@erxos}'
  end

  # The line follows the shell's last checkpoint, and the end is SystemDomain's.
  def test_the_line_follows_the_shell_and_the_runtime_ends
    points = [{ name: 'boot' }.freeze, { name: 'release-shell' }.freeze]
    names = Suite.checkpoints(points).map { |point| point.fetch(:name) }
    assert_equal ['boot', 'release-shell', Erx::ProductionImage::Run::ERLANG_SHELL.fetch(:name),
                  'device-given', 'system-domain-ended'], names
    assert_raises(Erx::Error) { Suite.checkpoints([{ name: 'boot' }.freeze]) }
  end
end
