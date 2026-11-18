# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'build_kind'
require_relative 'dependency_status'
require_relative 'error'
require_relative 'fiasco_parts'
require_relative 'license_expression'

module Erx
  # The one rule for which licenses the image check (PackProvenance) and the release
  # kernel's check (FiascoProvenance) accept for the files of a closure (docs/design.md,
  # "Licenses and notices"). An input with a permissive grant
  # (LicenseExpression::PERMISSIVE) enters every build. An input under a license that is
  # not permissive enters only where exempt? says: as the input of a row of TABLE, in the
  # build kinds that row names, or as a package of a local test image (PACKAGE_LOCAL), in
  # a development build. Every other input, a stopgap's or a release component's included,
  # must be permissive, so a copyleft file that comes back into a closure, such as another
  # of Fiasco's GPL sources, fails its check however it is registered.
  module LicenseCheck
    # The status of a package of a local test image whose license is not permissive
    # (ImageApps::Plan#status), which a development build accepts under that license, since
    # no published image takes a builder's package.
    PACKAGE_LOCAL = 'package-local'

    # The one example an image carries (docs/design.md's dependency table, status example):
    # Doom's archive, attributed whole under this label by the image build, with the WAD it
    # links, at the path the image build writes it (DoomProgram), relative to the tree. It
    # is the only input that may be registered example (example?).
    EXAMPLE_LABEL = 'doomgeneric libdoom.a'
    EXAMPLE_ARCHIVE = 'build/doom/libdoom.a'
    EXAMPLE_LICENSES = ['GPL-2.0-or-later', 'GPL-2.0-or-later AND BSD-3-Clause'].freeze

    # The cross compiler's freestanding headers that Fiasco's C and C++ include, which
    # FiascoProvenance.gcc_registry registers under labels GCC_LABEL fills.
    GCC_LICENSE = 'GPL-3.0-or-later WITH GCC-exception-3.1'
    GCC_HEADERS = %w[stdarg.h stdbool.h stddef.h].freeze
    GCC_LABEL = 'toolchain/gcc-%<release>s/%<name>s'
    # A GCC release as its include directory and its headers' labels name it.
    GCC_RELEASE = /[0-9][0-9.]{0,31}/
    # Where the build reads such a header: the include directory of its cross gcc's
    # installation, lib/gcc/TARGET/RELEASE/include, outside the tree.
    GCC_HEADER_PATH = %r{\A/(?:[^/]+/)*lib/gcc/[^/]+/(?<release>#{GCC_RELEASE})/include/(?<name>#{Regexp.union(GCC_HEADERS)})\z}

    DEVELOPMENT_ONLY = [BuildKind::DEVELOPMENT].freeze

    # One input a build accepts under a license that is not permissive: the status it is
    # registered under, its label as its record names it, the license expressions it may
    # carry, exactly as recorded, where the build reads it, and the build kinds that accept
    # it. The path is relative to the tree, with the label a literal, or, for a toolchain's
    # files outside it, a Regexp the whole absolute path must match, with the label a format
    # template its named captures fill, so the label always names the file the row accepts.
    Row = Data.define(:status, :label, :licenses, :path, :build_kinds) do
      # Whether this row names the input registered under input_status with input_label and
      # license, read from input_path: relative to the tree within it, absolute outside.
      def names?(input_status:, input_label:, license:, input_path:)
        status == input_status && licenses.include?(license) && label_at(input_path) == input_label
      end

      private

      # The label of the input this row reads from input_path, nil if it reads none there.
      # A Regexp row accepts only a whole match, however its pattern is anchored.
      def label_at(input_path)
        case path
        in String
          label if path == input_path
        in Regexp
          match = path.match(input_path)
          format(label, **match.named_captures(symbolize_names: true)) if match && match[0] == input_path
        end
      end
    end

    # Doom, the example, in 0.1's images with its source offered: the archive the image
    # build writes, which only a development build, as every image of 0.1 is, takes.
    EXAMPLE = Row.new(status: DependencyStatus::EXAMPLE, label: EXAMPLE_LABEL, licenses: EXAMPLE_LICENSES,
                      path: EXAMPLE_ARCHIVE, build_kinds: DEVELOPMENT_ONLY)

    # The closed table of such inputs (docs/design.md, "Licenses and notices"). Fiasco's
    # debugger and its build's GCC headers are release, as docs/design.md's dependency
    # table marks them.
    TABLE = [
      EXAMPLE,
      # GCC's headers: macros and types only, and the GCC Runtime Library Exception 3.1
      # lets code compiled with them be distributed under any terms, so every build takes
      # them, the release kernel's included.
      Row.new(status: DependencyStatus::RELEASE, label: GCC_LABEL, licenses: [GCC_LICENSE].freeze, path: GCC_HEADER_PATH,
              build_kinds: BuildKind::ALL),
      # Fiasco's kernel debugger, carried in development builds by decision, distributed
      # under the website exception with its source offered (CLAUDE.md, Dependencies,
      # stopgaps and release components); the release kernel leaves it out.
      Row.new(status: FiascoParts.status('kernel'), label: 'fiasco/kernel/src/kern/jdb_object.cpp',
              licenses: ['GPL-2.0-only'].freeze, path: "#{FiascoParts::INPUTS}/kernel/src/kern/jdb_object.cpp",
              build_kinds: DEVELOPMENT_ONLY)
    ].freeze

    module_function

    # The label of the GCC header at path, as the table's GCC row derives it: the one
    # source of that label, which FiascoProvenance.gcc_registry registers the header under.
    def gcc_label(path)
      match = GCC_HEADER_PATH.match(path)
      raise Error, "#{path} is not one of GCC's headers in a GCC include directory" unless match

      format(GCC_LABEL, **match.named_captures(symbolize_names: true))
    end

    # Whether a build of build_kind accepts an input under license although license is not
    # permissive: the input registered under status with label, read from path (relative
    # to the tree within it, absolute outside it).
    def exempt?(status:, label:, license:, path:, build_kind:)
      build_kind = BuildKind.fetch(build_kind)
      (status == PACKAGE_LOCAL && BuildKind.development?(build_kind)) ||
        TABLE.any? do |row|
          row.build_kinds.include?(build_kind) &&
            row.names?(input_status: status, input_label: label, license:, input_path: path)
        end
    end

    # The grant a build of build_kind takes from license for the input exempt? describes;
    # raises when it takes none. font_data: true says the license's FONT_DATA_ONLY licenses
    # cover font data in the input (LicenseExpression.select).
    def select(license, status:, label:, path:, build_kind:, font_data: false)
      LicenseExpression.select(license, allow_restricted: exempt?(status:, label:, license:, path:, build_kind:),
                                        font_data:)
    end

    # Whether select takes a grant for an input that holds no font data, as the release
    # kernel's check asks of each source it links.
    def passes?(license, status:, label:, path:, build_kind:)
      LicenseExpression.permissive?(license) || exempt?(status:, label:, license:, path:, build_kind:)
    end

    # Whether the input is the example's archive, the one input the example status may
    # name, whatever build it is in: EXAMPLE's row decides which builds take its license.
    def example?(label:, license:, path:)
      EXAMPLE.names?(input_status: DependencyStatus::EXAMPLE, input_label: label, license:, input_path: path)
    end
  end
end
