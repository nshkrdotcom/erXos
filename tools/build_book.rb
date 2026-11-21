#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Builds the book's pages alone, with the shared fonts and tokens, for a
# writer's preview (docs/design-book-site.md, "Where it fits"): no v64, image
# or card. The build is also the book's link check: every link and anchor
# resolves or the build fails, naming the file and line.

require 'optparse'
require 'tmpdir'
require_relative 'lib/erx/book'
require_relative 'lib/erx/runner'
require_relative 'lib/erx/site'

root = File.expand_path('..', __dir__)
options = { out: File.join(root, 'build/book-site'), serve: nil, drafts: false }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/build_book.rb [--out DIR] [--serve PORT] [--drafts]'
  flags.on('--out DIR', 'output directory (default: build/book-site)') { |path| options[:out] = File.expand_path(path) }
  flags.on('--serve PORT', Integer, 'serve the result on 127.0.0.1:PORT') { |port| options[:serve] = port }
  flags.on('--drafts', 'show draft markers as notes instead of refusing them; such a build is never published') do
    options[:drafts] = true
  end
  flags.on('--help') do
    puts flags
    exit 0
  end
end

begin
  parser.parse!
  raise OptionParser::NeedlessArgument, ARGV.join(' ') unless ARGV.empty?
rescue OptionParser::ParseError => error
  warn error.message
  warn parser.banner
  exit 2
end

begin
  runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
  commit = Erx::Site.head(root:, runner:)
  record = Erx::Site.replace(options.fetch(:out)) do |staging|
    plan = Dir.mktmpdir('book-parse-') do |scratch|
      Erx::Book.plan(root:, runner:, commit:, repository: Erx::Site::REPOSITORY, drafts: options.fetch(:drafts), scratch:)
    end
    Erx::Book.write(plan, out: staging)
  end
  puts "Book: #{options.fetch(:out)} (#{record.fetch(:files).size} files, commit #{commit[0, 12]})"
  Erx::Site.serve(dir: options.fetch(:out), port: options.fetch(:serve)) if options[:serve]
rescue Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
rescue Interrupt
  exit 130
end
