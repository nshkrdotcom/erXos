# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The git submodules of erXos's tree, read from the tree's .gitmodules, the one list
  # of them. A submodule's role follows from its `update` attribute: `update = none`
  # marks an example, which a clone does not check out and only `tools/erx fetch
  # --example` obtains (ExampleFetch); any other submodule is built into the tree
  # (Lvgl). A submodule's name is the last component of its path.
  class Submodules
    Entry = Data.define(:path, :url, :update) do
      def name = File.basename(path)
      def example? = update == 'none'
    end

EXAMPLES_DIRECTORY = 'examples'
HEADER = /\A\[submodule "(?<name>[^"\s]+)"\]\z/
# A value is a plain word: git's own comment, quote and continuation syntax is
# refused, so a line is never read differently from how git reads it.
SETTING = /\A(?<key>path|url|update)[ \t]*=[ \t]*(?<value>[^\s"#;\\]+)\z/
PATH = %r{\A(?:[^/\s]+/)*[^/\s]+\z}

# Reads the .gitmodules file at path: one section per submodule, whose settings
# are `key = value` lines. A line of any other form fails, so a form this reader
# does not understand is never read wrongly.
def self.read(path)
  sections = []
  File.foreach(path, chomp: true).with_index(1) do |raw, number|
    line = raw.strip
    next if line.empty? || line.start_with?('#', ';')

    if (header = HEADER.match(line))
      sections << { name: header[:name] }
    elsif (setting = SETTING.match(line))
      raise Error, "#{path}:#{number}: a setting before any submodule" if sections.empty?

      sections.last[setting[:key].to_sym] = setting[:value]
    else
      raise Error, "#{path}:#{number}: a line that is neither a submodule header nor a plain setting: #{line.dump}"
    end
  end
  entries = sections.map { |section| entry(path, section) }
  duplicate = entries.map(&:name).tally.find { |_, count| count > 1 }
  raise Error, "#{path}: two submodules are called #{duplicate.first}" if duplicate

  new(entries)
end

# One submodule: its section is named by its path, the path is a relative one
# without `.` or `..`, and it is an example (`update = none`) exactly when it lies
# under examples/, the directory ExampleLists keeps tree code from naming.
def self.entry(file, section)
  missing = %i[path url].reject { |key| section.key?(key) }
  raise Error, "#{file}: submodule #{section[:name]} lacks its #{missing.join(' and ')}" unless missing.empty?

  entry = Entry.new(path: section.fetch(:path), url: section.fetch(:url), update: section[:update])
  raise Error, "#{file}: submodule #{section[:name]} has path #{entry.path}" unless section[:name] == entry.path
  unless entry.path.match?(PATH) && entry.path.split('/').none? { |part| part.match?(/\A\.\.?\z/) }
    raise Error, "#{file}: submodule path #{entry.path} is not a relative path of plain components"
  end
  unless entry.example? == entry.path.start_with?("#{EXAMPLES_DIRECTORY}/")
    raise Error, "#{file}: #{entry.path} is an example exactly when it lies under #{EXAMPLES_DIRECTORY}/ " \
                 'and says `update = none`'
  end
  entry
end
private_class_method :entry

    attr_reader :entries

    def initialize(entries) = (@entries = entries.freeze)

    def paths = entries.map(&:path).freeze
    def examples = Submodules.new(entries.select(&:example?))
    def built_in = Submodules.new(entries.reject(&:example?))

    def names = entries.map(&:name).freeze

    # The submodule called name, or nil.
    def find(name) = entries.find { |entry| entry.name == name }

    # The submodule called name, or a diagnostic that lists the names there are.
    def fetch(name) = find(name) || raise(Error, "unknown submodule #{name}; the submodules are #{names.join(', ')}")

    # The submodules of the tree these tools belong to.
    TREE = read(File.expand_path('../../../.gitmodules', __dir__))
  end
end
