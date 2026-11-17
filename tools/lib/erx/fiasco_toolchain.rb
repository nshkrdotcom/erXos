# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The LLVM toolchain that builds Fiasco and L4Re (docs/design-fiasco.md,
  # "Toolchain"): compiler is clang (ERX_CLANG), linker is ld.lld (ERX_LLD),
  # and LLVM's binary tools are those installed beside clang, as every other
  # erXos build finds them. The inherited make systems read the toolchain
  # from each build directory's Makeconf.local (kernel_settings,
  # user_settings), not from the command line, where a CC would override
  # the target flag they add. CROSS_COMPILE only names the target triple
  # they pass to clang; no program of that prefix runs.
  FiascoToolchain = Data.define(:compiler, :linker) do
    def initialize(compiler:, linker:)
      unless [compiler, linker].all? { |path| path.to_s.start_with?('/') }
        raise Error, "the Fiasco build needs ERX_CLANG and ERX_LLD, absolute paths of LLVM's clang and ld.lld"
      end

      # One spelling for every caller: settings, records and keys name the installed
      # programs, whichever link the environment names, so siblings come from the real
      # installation. ld.lld keeps its name, by which the multi-call lld knows its part,
      # beside the program it resolves to.
      # A program that is not there stays as given; running it fails.
      super(compiler: installed(compiler), linker: File.join(File.dirname(installed(linker)), File.basename(linker)))
    end

    # LLVM's binary tool of that name, beside clang: program('nm') is llvm-nm.
    def program(name) = File.join(File.dirname(compiler), "llvm-#{name}")

    # The settings of the kernel's build directory. The kernel's Makeconf adds
    # clang's --target from CROSS_COMPILE and takes an LLD linker and a named
    # CPP as given. Its ARFLAGS end in T, which recent GNU ar reads as truncated
    # names but llvm-ar as a thin archive, whose members the link audit cannot
    # read (ArchiveMember); without it llvm-ar makes the normal archive GNU ar did.
    def kernel_settings
      { 'CC' => compiler, 'CXX' => clang('clang++'), 'CPP' => clang('clang-cpp'), 'LD' => linker,
        'ARFLAGS' => 'crsU', **binary_tools }
    end

    # Every program either build runs from the toolchain.
    def programs = [compiler, clang('clang++'), clang('clang-cpp'), linker, *binary_tools.values]

    # The settings of L4Re's build directory. CLANG names clang's directory,
    # from which mk takes clang, clang++ and clang-cpp with the target flag.
    def user_settings
      { 'CLANG' => "#{File.dirname(compiler)}/", 'LD' => "#{linker} -m $(LD_EMULATION)", **binary_tools }
    end

    private

    def installed(path) = File.exist?(path) ? File.realpath(path) : path

    def clang(name) = File.join(File.dirname(compiler), name)

    def binary_tools = %w[AR NM OBJCOPY OBJDUMP RANLIB SIZE STRIP].to_h { |name| [name, program(name.downcase)] }
  end

  class FiascoToolchain
    # The target the inherited make systems give clang, as their CROSS_COMPILE.
    CROSS_COMPILE = 'aarch64-none-elf-'

    # The toolchain the environment names.
    def self.from_environment(environment = ENV)
      new(compiler: environment.fetch('ERX_CLANG', ''), linker: environment.fetch('ERX_LLD', ''))
    end
  end
end
