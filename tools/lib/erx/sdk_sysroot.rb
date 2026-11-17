# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'abi_emit_draw'
require_relative 'compiler_rt'
require_relative 'error'
require_relative 'fiasco'
require_relative 'generated_abi'
require_relative 'musl'
require_relative 'native_root'
require_relative 'native_runtime'
require_relative 'platform'
require_relative 'runtime'

module Erx
  # The SDK's native half (docs/design-packaging.md, "The SDK"): what a third party's C
  # program builds with into an executable a package starts, linked as the boot image's
  # programs are, at task.ld's fixed addresses.
  #
  # sysroot/aarch64/include holds musl's headers as the runtime's build merges them and
  # erx/draw.h, the draw protocol's layouts generated from abi/formats/draw.txt;
  # sysroot/aarch64/lib holds musl's libc.a, compiler-rt's builtins, task.ld and
  # liberx_program.a, liberx's program layer and task entry (NativeRoot::PROGRAM), with the
  # Fiasco libraries and boot cores the entry calls beside it. share/erxos/sdk.mk is the
  # recipe: the compile flags of every task's C (NativeRoot::CODE_FLAGS) and the task link
  # NativeRoot.link_options and archive_group state, with liberx_program.a linked whole, so
  # an SDK's program links every object the tree's own programs link. share/licenses/LIB/
  # holds the license notices of each library of lib/ (NOTICES).
  class SdkSysroot
    ARCH = 'aarch64'
    PROGRAM_ARCHIVE = 'liberx_program.a'
    RECIPE = 'share/erxos/sdk.mk'
    # Where the program layer's objects are compiled, under the tree and the runtime tree's lock.
    OBJECTS = 'build/sdk/program'
    DEADLINE = 120
    BOOT_CORES = 'libboot_cores.a'
    BLAKE3_NOTICE = 'kernel/crypto/blake3/LICENSE_A2LLVM'
    # Each library of lib/ and its license notices, paths under the tree; compiler-rt's is
    # in its fetched source (CompilerRt.notice).
    NOTICES = { PROGRAM_ARCHIVE => ['LICENSE', BLAKE3_NOTICE], 'libc.a' => [Musl::NOTICE, 'LICENSE'],
                BOOT_CORES => ['LICENSE', BLAKE3_NOTICE], **NativeRoot::LIBRARIES.to_h { [it, [Fiasco::USER_NOTICE]] } }.freeze
    LICENSES = 'share/licenses'

    def initialize(root:, runner:, compiler:, linker:)
      raise Error, 'set ERX_CLANG to the installed LLVM clang' if compiler.to_s.empty?

      @root = root
      @runner = runner
      @compiler = compiler
      @linker = linker
    end

    # Writes sysroot/ and share/ into directory, the SDK being made. Fiasco is built first,
    # since the program layer compiles against its headers and links its archives; musl's
    # build and header merge write the runtime's tree, so the rest runs under its lock,
    # exclusive, as Runtime#build holds it.
    def write(directory)
      Fiasco.new(root: @root, runner: @runner, compiler: @compiler).build
      Runtime.hold_tree(@root, mode: :exclusive) { write_locked(directory) }
    end

    private

    def write_locked(directory)
      sysroot = File.join(directory, 'sysroot', ARCH)
      include = File.join(sysroot, 'include')
      lib = File.join(sysroot, 'lib')
      [include, File.join(include, 'erx'), lib, File.dirname(File.join(directory, RECIPE))].each { FileUtils.mkdir_p(it) }
      musl = Musl.new(root: @root, runner: @runner, compiler: @compiler)
      build = File.join(@root, NativeRuntime::BASE, 'musl')
      libc = musl.build(directory: build)
      FileUtils.cp_r("#{musl.merge_headers(directory: build, sysroot: File.join(@root, NativeRoot::LIBC_SYSROOT))}/.", include)
      FileUtils.cp(File.join(@root, Generated::OUTPUT, ABI::DrawEmitter::C_PROGRAM_HEADER_PATH), File.join(include, 'erx'))
      FileUtils.cp([libc, CompilerRt.archive(root: @root, runner: @runner, compiler: @compiler),
                    File.join(@root, NativeRoot::TASK_LINK_SCRIPT)], lib)
      program_archive(lib)
      licenses(File.join(directory, LICENSES))
      File.write(File.join(directory, RECIPE), recipe)
    end

    # The program layer's objects, compiled as the tree compiles them, as liberx_program.a,
    # and the Fiasco archives they call into beside it.
    def program_archive(lib)
      native = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                              platform: Platform.development(@root))
      fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
      objects = native.compile_all(sources: NativeRoot::PROGRAM, directory: File.join(@root, OBJECTS))
      FileUtils.cp(fiasco.boot_core_archive, File.join(lib, BOOT_CORES))
      FileUtils.cp(NativeRoot::LIBRARIES.map { fiasco.user_library(it) }, lib)
      @runner.run([File.join(File.dirname(@compiler), 'llvm-ar'), 'qcs', File.join(lib, PROGRAM_ARCHIVE), *objects],
                  name: 'sdk-program-archive', deadline: DEADLINE)
    end

    # Each library's notices in licenses/LIB/, by the notice's file name.
    def licenses(directory)
      notices = NOTICES.merge(CompilerRt::ARCHIVE => [CompilerRt.notice(root: @root, runner: @runner)])
      notices.each do |library, paths|
        FileUtils.mkdir_p(File.join(directory, library))
        paths.each { |path| FileUtils.cp(File.join(@root, path), File.join(directory, library, File.basename(path))) }
      end
    end

    # share/erxos/sdk.mk: make variables naming the SDK's own files from where the
    # fragment lies, so the SDK can be moved; ERX_CC and ERX_LD are the host's LLVM.
    def recipe
      lib = '$(ERX_SYSROOT)/lib'
      ldflags = NativeRoot.link_options(script: "#{lib}/#{File.basename(NativeRoot::TASK_LINK_SCRIPT)}",
                                        flags: NativeRoot::TASK_LINK_FLAGS, strip_debug: true)
      libs = ['--whole-archive', "#{lib}/#{PROGRAM_ARCHIVE}", '--no-whole-archive',
              *NativeRoot.archive_group(["#{lib}/libc.a", "#{lib}/#{CompilerRt::ARCHIVE}"], boot_core: "#{lib}/#{BOOT_CORES}",
                                                                                       libraries: NativeRoot::LIBRARIES.map { "#{lib}/#{it}" })]
      <<~MAKE
        # Generated by tools/erx sdk export (docs/design-packaging.md, "The SDK"), for GNU make.
        # A program's object: $(ERX_CC) $(ERX_CFLAGS) -c FILE.c -o FILE.o
        # Its executable: $(ERX_LD) $(ERX_LDFLAGS) -o PROGRAM OBJECTS $(ERX_LIBS)
        ERX_SDK := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../..)
        ERX_SYSROOT := $(ERX_SDK)/sysroot/#{ARCH}
        ERX_CC ?= clang
        ERX_LD ?= ld.lld
        ERX_CFLAGS := #{NativeRoot::CODE_FLAGS.join(' ')} -isystem $(ERX_SYSROOT)/include
        ERX_LDFLAGS := #{ldflags.join(' ')}
        ERX_LIBS := #{libs.join(' ')}
      MAKE
    end
  end
end
