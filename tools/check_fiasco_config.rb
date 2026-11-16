#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Checks the stopgap kernel's resolved configuration (globalconfig.out) against
# the fork's rules (tools/lib/erx/fiasco_config.rb). `tools/erx build fiasco`
# runs the same check after every configuration step, and `tools/erx build
# release-kernel` with the release rules; this script checks a file by hand,
# by default the build's own one of the kernel of the kind --kind names
# (development unless it says release).

require 'optparse'
require_relative 'lib/erx/runner'
require_relative 'lib/erx/build_kind'
require_relative 'lib/erx/fiasco'

root = File.expand_path('..', __dir__)
kind = Erx::BuildKind::DEVELOPMENT
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/check_fiasco_config.rb [--kind development|release] [RESOLVED_CONFIG]'
  flags.on('--kind KIND', Erx::BuildKind::ALL, 'The build kind of the kernel') { |value| kind = value }
  flags.on('--help') { puts flags; exit 0 }
end
begin
  parser.parse!
  raise OptionParser::NeedlessArgument, ARGV.drop(1).join(' ') if ARGV.size > 1
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
end
path = ARGV.first || File.join(Erx::Fiasco.kernel_directory(root: root, kind: kind), 'globalconfig.out')
begin
  Erx::FiascoConfig.check(path, kind: kind)
  Erx::Terminal.puts("#{path}: the stopgap #{kind} kernel configuration follows the fork's rules")
rescue Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
end
