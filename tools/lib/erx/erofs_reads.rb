# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'erlang_text'

module Erx
  # The chokepoint of invariant E1 (docs/design-storage.md, "Reading EROFS images"):
  # the EROFS reader reaches an image's blocks only through erx_verity:read/3, the
  # funnel that checks each block against the image's hash tree, nothing else
  # reaches the window behind it, and only erx_storage_system opens an image in it.
  #
  # erx_verity's opaque handle holds the image's window, and erx_erofs:mount/2 takes
  # only that handle, so the rule keeps every module but the mounter from opening
  # one, every other module from naming erx_verity, and the reader's calls on the
  # funnel and on BIFs that reach no state. It reads the Erlang sources that can enter
  # a release, as ErlangText reads them, and refuses:
  #
  # * outside erx_verity.erl, any naming of erx_verity, a call, a quoted atom, a
  #   string or a record of the handle's name, except:
  #   * the call erx_verity:open( in MOUNTERS, erx_storage_system alone, which opens
  #     the `system` window with its layout;
  #   * in the reader's modules, the call erx_verity:read( (or its name,
  #     erx_verity:read/3) and the type erx_verity:image(;
  # * in the reader's modules, a remote call or fun M:F/A on a module outside
  #   READER_MODULES, a remote call through a variable or a macro, and a call of apply.
  #
  # So erx_ns, which mounts a handle its caller opened, opens none, and no release
  # module opens a window unchecked.
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
    MOUNTERS = [SYSTEM].freeze
    NAMED = /(?<![A-Za-z0-9_@])'?erx_verity'?(?![A-Za-z0-9_@])/
    READER_USE = /\A'?erx_verity'?\s*:\s*'?(?:read'?\s*[(\/]|image'?\s*\()/
    MOUNTER_USE = /\A'?erx_verity'?\s*:\s*'?open'?\s*\(/
    # A remote call or a fun M:F/A, its module a name, a variable or a macro.
    REMOTE = /(?<![A-Za-z0-9_@])(?<module>\??[A-Za-z_][A-Za-z0-9_@]*)\s*:\s*[a-z][A-Za-z0-9_@]*\s*[(\/]/
    APPLY = /(?<![A-Za-z0-9_@:])apply\s*\(/

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
        names(path, code) + reader_calls(path, atoms)
      end
    end

    def names(path, code)
      return [] if path == FUNNEL

      code.to_enum(:scan, NAMED).filter_map do
        offset = Regexp.last_match.begin(0)
        next if READER_USE.match?(code[offset..]) && READERS.include?(path)
        next if MOUNTER_USE.match?(code[offset..]) && MOUNTERS.include?(path)

        Violation.new(path: path, line: line_of(code, offset),
                      detail: "only #{FUNNEL} names erx_verity, but for the mounters' call erx_verity:open( " \
                              "and the reader's erx_verity:read/3 and type erx_verity:image()")
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
