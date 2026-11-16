# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# A seeded fault in a module of tools/lib/erx: a copy of its source with one
# passage replaced, loaded in a forked child so the tree's module stays as it
# is in the test's own process. The copy's relative requires name the tree's
# files, so only the seeded module changes.
module SeededSource
  LIBRARY = File.expand_path('../../tools/lib/erx', __dir__)

  module_function

  # What the block gives in a child that loaded SOURCE with FAULT.first
  # replaced by FAULT.last: [:value, its value], or [:raised, class name,
  # whether it is an Erx::Error, message]. The copy is written into WORK.
  def run(source, fault, work:)
    text = File.read(source)
    raise "the seeded passage is not once in #{source}: #{fault.first}" unless text.scan(fault.first).size == 1

    path = File.join(work, File.basename(source))
    File.write(path, text.sub(fault.first) { fault.last }.gsub("require_relative '") { "require '#{LIBRARY}/" })
    in_child(path) { yield }
  end

  def in_child(path)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      $VERBOSE = nil
      load path
      outcome = begin
        [:value, yield]
      rescue Exception => e # the seeded module's outcome, a stack overflow included
        [:raised, e.class.name, e.is_a?(Erx::Error), e.message]
      end
      writer.write(Marshal.dump(outcome))
      writer.close
      exit!(0)
    end
    writer.close
    outcome = Marshal.load(reader.read) # our own child's pipe
    Process.wait(pid)
    outcome
  end
end
