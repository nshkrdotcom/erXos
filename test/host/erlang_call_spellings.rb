# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The spellings of a call of Module:Function a module can write, which every
# Erlang chokepoint rule built by Erx::ErlangText.calls refuses: the builder's
# own test and each rule's test read them from here, so a form one rule misses
# fails that rule's test. Each spelling is one line but the split call, whose
# line is the module's.
module ErlangCallSpellings
  Spelling = Data.define(:form, :source, :line)

  module_function

  # Every form: those that name the module or the function as an atom, and those
  # that name only the function, the module held in a variable or a macro.
  def all(mod, fun)
    {
      'a remote call' => "f(A) -> #{mod}:#{fun}(A).\n",
      'a fun' => "f() -> fun #{mod}:#{fun}/1.\n",
      'quoted atoms' => "f(A) -> '#{mod}':'#{fun}'(A).\n",
      'an apply of the module' => "f(A) -> apply(#{mod}, #{fun}, [A]).\n",
      'an erlang:apply of the module' => "f(A) -> erlang:apply(#{mod}, #{fun}, A).\n",
      'a module and function pair' => "f() -> {#{mod}, #{fun}}.\n",
      'an import' => "-import(#{mod}, [#{fun}/1]).\n",
      'an import of another function' => "-import(#{mod}, [other/0]).\n",
      'a macro of the module' => "-define(M, #{mod}).\n",
      'a function-like macro of the module' => "-define(M(), #{mod}).\n",
      'a macro of the function' => "-define(F, #{fun}).\n",
      'a call split across lines' => "f(A) ->\n    #{mod}:\n        #{fun}(A).\n",
      'a variable module' => "f(M, A) -> M:#{fun}(A).\n",
      'a macro module' => "f(A) -> ?M:#{fun}(A).\n",
      'an apply through a variable' => "f(M, A) -> apply(M, #{fun}, [A]).\n"
    }.map { |form, source| spelling(form, source) }
  end

  # Sources that name the module or the function but call neither together:
  # another function of the module, the function of another module, a local
  # call, a module calling itself through ?MODULE, and a comment.
  def unrelated(mod, fun)
    ["f(A) -> #{mod}:other(A), #{mod}_x:#{fun}(A), #{fun}(A), ?MODULE:#{fun}(A).\n",
     "%% #{mod}:#{fun}(A) in a comment is not code\nf() -> {#{fun}, 1}, [#{mod}].\n"]
  end

  def spelling(form, source) = Spelling.new(form: form, source: source, line: source.start_with?("f(A) ->\n") ? 2 : 1)
end
