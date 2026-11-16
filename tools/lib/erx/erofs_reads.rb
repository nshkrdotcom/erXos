# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'erlang_text'

module Erx
  # The chokepoint of invariant E1 (docs/design-storage.md, "Reading EROFS images"):
  # the EROFS reader reaches an image's blocks only through erx_verity:read/3, the
  # funnel that checks each block against the image's hash tree, nothing else
  # reaches the window behind it, and only two modules open an image in it.
  #
  # erx_verity's opaque handle holds the image's window, so the rule keeps every other
  # module from naming erx_verity and the reader's calls on the funnel and on BIFs that
  # reach no state. It reads the Erlang sources that can enter a
  # release, as ErlangText reads them, and refuses:
  #
  # * outside erx_verity.erl, any naming of erx_verity, a call, a quoted atom or a
  #   string, except in the reader's modules the call erx_verity:read( (or its
  #   name, erx_verity:read/3), the call erx_verity:open( with which the reader's mount
  #   opens the window, and the types erx_verity:image( and erx_verity:tree(;
  # * in the reader's modules, a remote call or fun M:F/A on a module outside
  #   READER_MODULES, a remote call through a variable or a macro, and apply;
  # * outside MOUNTERS, a call erx_erofs:mount( or a fun erx_erofs:mount/3, the mount
  #   that opens an image in erx_verity: erx_ns's, for the one EROFS file mount, and
  #   erx_storage_system's, for the `system` window;
  # * in the reader's modules, a call erx_verity:open( outside the function mount, a
  #   second one, none, and a call or fun of mount inside a function body, so the
  #   reader opens an image once, in mount/3, which only the mounters call, and the
  #   mount rule above holds the property "only two modules open an image";
  # * outside SYSTEM, a call erx_storage_system:mount( or a fun of it: only its mint
  #   mounts the `system` tree, with the layout mount/1 reads from the module's own
  #   boot record. That the module exports no mount to the release, mount/3 to its
  #   EUnit cases alone, is a fact of its compiled exports, which
  #   test/host/erx_storage_system_test.rb checks.
  #
  # Like the other text rules it catches a slip, not a call built from pieces.
  module ErofsReads
    SCOPE = ErlangText::SCOPE
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    FUNNEL = 'otp/erts/preloaded/src/erx_verity.erl'
    READERS = %w[otp/erts/preloaded/src/erx_erofs.erl].freeze
    # What the reader may call: the funnel, and modules whose functions it uses are
    # BIFs that reach no state outside their arguments.
    READER_MODULES = %w[erx_verity binary maps].freeze
    SYSTEM = 'erlang/apps/erx_storage/src/erx_storage_system.erl'
    MOUNTERS = ['erlang/apps/erx/src/erx_ns.erl', SYSTEM].freeze
    NAMED = /(?<![A-Za-z0-9_@])'?erx_verity'?(?![A-Za-z0-9_@])/
    READER_USE = /\A'?erx_verity'?\s*:\s*'?(?:read'?\s*[(\/]|(?:open|image|tree)'?\s*\()/
    # A remote call or a fun M:F/A, its module a name, a variable or a macro.
    REMOTE = /(?<![A-Za-z0-9_@])(?<module>\??[A-Za-z_][A-Za-z0-9_@]*)\s*:\s*[a-z][A-Za-z0-9_@]*\s*[(\/]/
    APPLY = /(?<![A-Za-z0-9_@:])apply\s*\(/
    MOUNT = /(?<![A-Za-z0-9_@])erx_erofs\s*:\s*mount\s*[(\/]/
    OPEN = /(?<![A-Za-z0-9_@])erx_verity\s*:\s*open\s*\(/
    # A form starts at a line's first column: an attribute, or a function clause's name.
    FORM = /^(?:-|(?<function>[a-z][A-Za-z0-9_@]*)\s*\()/
    SYSTEM_MOUNT = /(?<![A-Za-z0-9_@])erx_storage_system\s*:\s*mount\s*[(\/]/
    # A local use of mount, a call or a fun mount/N, not a remote call of it.
    LOCAL_MOUNT = /(?<![A-Za-z0-9_@:])mount\s*[(\/]/

    Violation = Data.define(:path, :line, :detail) do
      def to_s = "chokepoint erofs-reads: #{path}:#{line}: #{detail}"
    end

    module_function

    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # The violations among files, a map of path to source text.
    def violations(files)
      files.select { |path, _| covers?(path) }.flat_map do |path, text|
        code = ErlangText.code(text)
        atoms = atoms_only(code)
        names(path, code) + reader_calls(path, atoms) + mounts(path, atoms) + opens(path, atoms) +
          system_mount_calls(path, atoms)
      end
    end

    def mounts(path, code)
      return [] if MOUNTERS.include?(path)

      code.to_enum(:scan, MOUNT).map do
        Violation.new(path: path, line: line_of(code, Regexp.last_match.begin(0)),
                      detail: "only #{MOUNTERS.join(' and ')} call erx_erofs:mount/3")
      end
    end

    # The reader's opens: each but the first inside a clause of mount, none at all (at
    # line 1), and each use of mount inside a function body, a call or a fun, through
    # which another function would open an image with arguments of its own.
    def opens(path, code)
      return [] unless READERS.include?(path)

      offsets = code.to_enum(:scan, OPEN).map { Regexp.last_match.begin(0) }
      inside, outside = offsets.partition { |offset| function_at(code, offset) == 'mount' }
      missing = inside.empty? ? [1] : []
      uses = code.to_enum(:scan, LOCAL_MOUNT).filter_map do
        offset = Regexp.last_match.begin(0)
        offset if function_at(code, offset) && code[offset - 1] != "\n"
      end
      lines = [*outside, *inside.drop(1), *uses].map { |offset| line_of(code, offset) }
      detail = 'the reader opens an image once, in mount/3, through erx_verity:open/2, and calls no mount'
      (missing + lines).uniq.sort.map { |line| Violation.new(path: path, line: line, detail: detail) }
    end

    # The function whose clause holds offset, or nil inside an attribute.
    def function_at(code, offset)
      code[0, offset].to_enum(:scan, FORM).map { Regexp.last_match[:function] }.last
    end

    def system_mount_calls(path, code)
      return [] if path == SYSTEM

      code.to_enum(:scan, SYSTEM_MOUNT).map do
        Violation.new(path: path, line: line_of(code, Regexp.last_match.begin(0)),
                      detail: "only #{SYSTEM}'s mint mounts the system tree")
      end
    end

    def names(path, code)
      return [] if path == FUNNEL

      code.to_enum(:scan, NAMED).filter_map do
        offset = Regexp.last_match.begin(0)
        next if READERS.include?(path) && READER_USE.match?(code[offset..])

        Violation.new(path: path, line: line_of(code, offset),
                      detail: "only #{FUNNEL} names erx_verity, but for the reader's erx_verity:read/3 and open/2")
      end
    end

    def reader_calls(path, code)
      return [] unless READERS.include?(path)

      remote = code.to_enum(:scan, REMOTE).filter_map do
        next if READER_MODULES.include?(Regexp.last_match[:module])

        Violation.new(path: path, line: line_of(code, Regexp.last_match.begin(0)),
                      detail: "the reader calls only #{READER_MODULES.join(', ')}")
      end
      applies = code.to_enum(:scan, APPLY).map do
        Violation.new(path: path, line: line_of(code, Regexp.last_match.begin(0)), detail: 'the reader does not apply')
      end
      (remote + applies).sort_by(&:line)
    end

    def line_of(code, offset) = code[0, offset].count("\n") + 1

    # The code with each string and character blanked and each quoted atom unquoted,
    # lines kept, so a remote call reads the same written either way.
    def atoms_only(code)
      code.gsub(ErlangText::LEXEME) do
        lexeme = Regexp.last_match(0)
        lexeme.start_with?("'") ? lexeme[1..-2].gsub(/[^A-Za-z0-9_@\n]/, '_') : lexeme.gsub(/[^\n]/, ' ')
      end
    end
  end
end
