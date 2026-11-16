# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # erx-raster, the glyph step's rasteriser (docs/design-desktop-programs.md,
  # "Type"): erXos's C17 host program display/raster/erx_raster.c linked with
  # FreeType, built for the development host from the pinned source (deps.lock,
  # id `freetype`) into build/erx-raster, and run as a subprocess by argument
  # vector. No image contains it.
  #
  # Build compiles the FreeType members a TrueType font's outlines need, and
  # erx_raster.c, with this module's own compiler argument vectors; FreeType's
  # scripts and makefiles never run. Program#rasterise runs it on one font at
  # one size and returns what it wrote as a Result.
  module Raster
    SOURCE_ID = 'freetype'
    PROGRAM_SOURCE = 'display/raster/erx_raster.c'
    OUTPUT = 'build/erx-raster'
    STAMP = 'build.json'

    class MissingSource < Error; end
    class MissingBuild < Error; end
    class StaleBuild < Error; end

    # A font's vertical metrics, in its own units: DESCENDER is negative below
    # the baseline.
    Face = Data.define(:units_per_em, :ascender, :descender)
    # One glyph's coverage: ADVANCE in 26.6 pixels, LEFT and TOP the coverage's
    # top-left corner from the pen in pixels, TOP upward, and ROWS its WIDTH-byte
    # rows of coverage from 0 to 255, top first.
    Coverage = Data.define(:advance, :left, :top, :width, :rows)
    # One run: the font's Face and, for each glyph asked for, in order, its
    # Coverage, or nil when the font has no such glyph.
    Result = Data.define(:face, :glyphs)

    module_function

    # The lock entry, read whole and checked by DependencySchema.
    def source_record(root:)
      DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                      .find { |source| source.fetch('id') == SOURCE_ID } ||
        raise(Error, "deps.lock has no #{SOURCE_ID} source")
    end

    # What a build is made from: the FreeType pin, this file and the program's
    # source. A build whose record names anything else is stale.
    def inputs(root:, program: File.join(root, PROGRAM_SOURCE))
      { 'source' => source_record(root: root), 'recipe' => Digest::SHA256.file(__FILE__).hexdigest,
        'program' => Digest::SHA256.file(program).hexdigest }
    end

    # The built erx-raster beneath output_root, refused when it is missing or
    # was built from other inputs than the tree's, so a stale program never runs.
    def locate(root:, output_root: root)
      output = File.join(File.expand_path(output_root), OUTPUT)
      binary = File.join(output, 'erx-raster')
      stamp_path = File.join(output, STAMP)
      unless File.file?(binary) && File.file?(stamp_path)
        raise MissingBuild, "erx-raster is not built: #{binary} is missing; run tools/erx build glyphs"
      end

      stamp = begin
        JsonInput.parse(BoundedFile.read(stamp_path, maximum: 65_536), max_bytes: 65_536,
                        label: 'erx-raster build record')
      rescue JsonInput::Unsupported
        raise
      rescue Error => e
        raise StaleBuild, "erx-raster in #{output} has an unreadable build record (#{e.message}); " \
                          'run tools/erx build glyphs'
      end
      unless stamp.is_a?(Hash) && stamp['inputs'] == inputs(root: root)
        raise StaleBuild, "erx-raster in #{output} was built from other inputs; run tools/erx build glyphs"
      end

      Program.new(path: binary)
    end

    # The bytes erx-raster wrote for COUNT glyphs, read as a Result. The
    # program is erXos's own, so this reads its layout (erx_raster.c's header
    # comment) through a cursor and fails at the first short field, without
    # re-deriving the program's own bounds.
    def parse(bytes, count:)
      cursor = Cursor.new(bytes)
      face = Face.new(units_per_em: cursor.unsigned(2), ascender: cursor.signed(2), descender: cursor.signed(2))
      written = cursor.unsigned(4)
      raise Error, "erx-raster wrote #{written} glyphs where #{count} were asked for" unless written == count

      glyphs = Array.new(count) do
        next nil if cursor.unsigned(1).zero?

        advance, left, top = Array.new(3) { cursor.signed(4) }
        width, height = Array.new(2) { cursor.unsigned(4) }
        Coverage.new(advance: advance, left: left, top: top, width: width,
                     rows: Array.new(height) { cursor.bytes(width) }.freeze)
      end
      raise Error, 'erx-raster wrote bytes after its last glyph' unless cursor.done?

      Result.new(face: face, glyphs: glyphs.freeze)
    end

    # Little-endian fields of erx-raster's output, read in order; reading
    # past the end raises.
    class Cursor
      def initialize(bytes)
        @bytes = bytes.b
        @offset = 0
      end

      def unsigned(size) = take(size).unpack1({ 1 => 'C', 2 => 'v', 4 => 'V' }.fetch(size))

      def signed(size) = take(size).unpack1({ 2 => 's<', 4 => 'l<' }.fetch(size))

      def bytes(size) = take(size)

      def done? = @offset == @bytes.bytesize

      private

      def take(size)
        raise Error, 'erx-raster output ends inside a glyph' if @bytes.bytesize - @offset < size

        @offset += size
        @bytes.byteslice(@offset - size, size)
      end
    end

    # The most bytes one run may write: the largest role of a theme
    # rasterises well under a megabyte.
    MAX_OUTPUT = 64 << 20
    RUN_DEADLINE = 120

    # A located erx-raster.
    Program = Data.define(:path) do
      # The coverage of GLYPHS (each a U+XXXX or a glyph name, as erx_raster.c
      # reads them) of the font at FONT at SIZE pixels per em, as a Result.
      def rasterise(font:, size:, glyphs:, runner:)
        Dir.mktmpdir('erx-raster-') do |work|
          output = File.join(work, 'coverage')
          runner.run([path, File.expand_path(font), size.to_s, *glyphs], name: 'erx-raster', deadline: RUN_DEADLINE, chdir: work,
                                                       stdout: output, output_limit: MAX_OUTPUT)
          Raster.parse(BoundedFile.read(output, maximum: MAX_OUTPUT), count: glyphs.size)
        end
      end
    end

    # Compiles erx-raster for the host into OUTPUT beneath output_root: the
    # FreeType members INSTALL.ANY (lines 28-36 and 54-101, at 2.15.0) lists
    # for the TrueType driver and the anti-aliasing rasteriser, with a module
    # list naming only those, and the program, linked by the host compiler
    # driver. A missing member fails the link, never a run.
    class Build
      FREETYPE = %w[
        src/base/ftsystem.c src/base/ftinit.c src/base/ftdebug.c src/base/ftbase.c src/base/ftbitmap.c src/base/ftmm.c
        src/gzip/ftgzip.c src/sfnt/sfnt.c src/truetype/truetype.c src/psnames/psnames.c src/smooth/smooth.c
      ].freeze
      # The modules ftinit.c registers, in place of ftmodule.h's full list
      # (include/freetype/config/ftheader.h, FT_CONFIG_MODULES_H).
      MODULES = <<~HEADER
        FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
        FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
        FT_USE_MODULE( FT_Module_Class, psnames_module_class )
        FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
      HEADER
      MODULES_HEADER = 'erx_ftmodule.h'
      # FreeType's own code builds as its release does, its warnings its own;
      # DARWIN_NO_CARBON keeps ftbase.c from the Carbon resource-fork reader.
      FREETYPE_FLAGS = %W[-std=c99 -O2 -w -DFT2_BUILD_LIBRARY -DDARWIN_NO_CARBON
                          -DFT_CONFIG_MODULES_H=<#{MODULES_HEADER}>].freeze
      PROGRAM_FLAGS = %w[-std=c17 -O2 -Wall -Wextra -Werror].freeze
      DEADLINE = 300

      # program is the C source to build, the tree's unless a test seeds a fault
      # into a copy.
      def initialize(root:, runner:, output_root: root, compiler: ENV.fetch('CC', 'cc'),
                     program: File.join(root, PROGRAM_SOURCE))
        @root = File.expand_path(root)
        @output_root = File.expand_path(output_root)
        @runner = runner
        @compiler = compiler
        @program = File.expand_path(program)
      end

      def call
        inputs = Raster.inputs(root: @root, program: @program)
        tree = source_tree(inputs.fetch('source'))
        build = OutputDirectory.prepare(root: @output_root, path: File.join(@output_root, 'build'))
        Dir.mktmpdir('.erx-raster-', build) do |work|
          output = File.join(work, 'out')
          %w[config freetype out].each { |name| Dir.mkdir(File.join(work, name)) }
          File.write(File.join(work, 'config', MODULES_HEADER), MODULES)
          includes = ["-I#{File.join(work, 'config')}", "-I#{File.join(tree, 'include')}"]
          @runner.run([@compiler, '-c', *FREETYPE_FLAGS, *includes, *FREETYPE.map { |member| File.join(tree, member) }],
                      name: 'erx-raster-freetype', deadline: DEADLINE, chdir: File.join(work, 'freetype'))
          objects = FREETYPE.map { |member| File.join(work, 'freetype', "#{File.basename(member, '.c')}.o") }
          @runner.run([@compiler, *PROGRAM_FLAGS, *includes, '-o', File.join(output, 'erx-raster'), @program, *objects],
                      name: 'erx-raster-link', deadline: DEADLINE, chdir: work)
          stamp = { 'inputs' => inputs, 'compiler' => compiler_identity(work) }
          File.write(File.join(output, STAMP), JSON.pretty_generate(stamp) + "\n")
          publish(output)
        end
        Program.new(path: File.join(@output_root, OUTPUT, 'erx-raster'))
      end

      private

      # The fetched tree, accepted only with the record Dependencies#publish
      # wrote for this pin.
      def source_tree(source)
        parent = File.join(@root, 'build/third_party', SOURCE_ID)
        marker = File.join(parent, '.source.json')
        tree = File.join(parent, source.fetch('directory'))
        unless File.file?(marker) && !File.symlink?(parent) && File.directory?(tree)
          raise MissingSource, "FreeType source is not fetched: #{parent}; run tools/erx fetch --source #{SOURCE_ID}"
        end
        recorded = JsonInput.parse(BoundedFile.read(marker, maximum: 65_536), max_bytes: 65_536,
                                   label: 'source download record')
        raise MissingSource, "#{parent} holds another pin of FreeType; run tools/erx fetch --source #{SOURCE_ID}" unless recorded == source

        tree
      end

      def compiler_identity(work)
        record = @runner.run([@compiler, '--version'], name: 'erx-raster-compiler', deadline: 60, chdir: work)
        BoundedFile.read(record.fetch('log'), maximum: 65_536).lines.first.to_s.strip
      end

      # The new output replaces the old whole: the old tree moves aside first
      # and is deleted only after the new one is in place.
      def publish(output)
        destination = File.join(@output_root, OUTPUT)
        raise Error, "erx-raster output is a symbolic link: #{destination}" if File.symlink?(destination)

        previous = "#{output}.previous"
        File.rename(destination, previous) if File.exist?(destination)
        File.rename(output, destination)
      end
    end
  end
end
