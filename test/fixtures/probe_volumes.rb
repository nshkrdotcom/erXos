# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/fsimg'

# The FAT volumes the probe's host tests and fuzz target read
# (docs/design-drives.md, "Verification"): one of each FAT type fsimg writes, with
# 512-byte clusters, at a size that holds enough clusters for it.
module ProbeVolumes
  ROOT = File.expand_path('../..', __dir__)
  VOLUMES = { 'fat12.img' => ['fat12', 1 << 20], 'fat16.img' => ['fat16', 8 << 20],
              'fat32.img' => ['fat32', 40 << 20] }.freeze

  module_function

  def write(directory)
    Dir.mktmpdir('erx-probe-files') do |files|
      VOLUMES.each do |name, (type, bytes)|
        output, status = Open3.capture2e(Erx::Fsimg.locate(root: ROOT), 'cW', '-f', File.join(directory, name),
                                         '-F', type, '-s', bytes.to_s, '-o', 'cluster=512', '-C', files, '.',
                                         stdin_data: '')
        raise "fsimg failed for #{name}: #{output}" unless status.success?
      end
    end
    directory
  end
end
