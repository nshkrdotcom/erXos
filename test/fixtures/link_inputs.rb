# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# A link's input list as LLD's --trace prints it (lld/ELF/InputFiles.cpp,
# doParseFile, LLVM 23.1.3): one loaded input per line, an archive member as
# archive(member).
module LinkInputsFixture
  module_function

  def text(*inputs) = inputs.map { |input| "#{input}\n" }.join
end
