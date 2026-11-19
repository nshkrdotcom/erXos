# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/error'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/runtime'

# Runs an Erlang probe of test/fixtures in the hosted runtime, for the runtime's integration
# tests: the host's OTP compiles test/fixtures/NAME.erl, and the runtime loads the BEAM from
# its standard input, in base64, and runs NAME:main(), which prints its result and halts. The
# release has no compiler and reaches no host file, and the boot page's limit on strings
# leaves no room for the BEAM among the arguments.
module RuntimeProbe
  ROOT = File.expand_path('../..', __dir__)
  COMPILE_SECONDS = 120

  # The probe's output, standard error included, and its exit status, under a deadline of
  # budget_seconds (gtimeout's status 124 when it passes).
  def self.run(name, budget_seconds:)
    output = Erx::Runtime.output(root: ROOT)
    load = "{module, #{name}} = code:load_binary(#{name}, \"#{name}\", " \
           "base64:decode(string:trim(io:get_line(\"\"))))"
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge('ERL_CRASH_DUMP_BYTES' => '0')
    Open3.capture2e(environment, 'gtimeout', '-k', '10', budget_seconds.to_s, output.beam, output.archive,
                    '-noshell', '-eval', "#{load}, #{name}:main().", stdin_data: "#{compiled(name)}\n")
  end

  # The probe's BEAM, in base64; an Erx::Error when the host's compiler refuses it.
  def self.compiled(name)
    erlc = File.join(File.dirname(Erx::Oracle.new(root: ROOT).erl_path(Erx::Runtime::HOST_OTP_FLAVOUR)), 'erlc')
    Dir.mktmpdir("erx-#{name}-") do |directory|
      log, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', COMPILE_SECONDS.to_s, erlc,
                                    '-o', directory, File.join(ROOT, 'test/fixtures', "#{name}.erl"), stdin_data: '')
      raise Erx::Error, "erlc exit #{status.exitstatus} (124 is the deadline)\n#{log}" unless status.success?

      [File.binread(File.join(directory, "#{name}.beam"))].pack('m0')
    end
  end
  private_class_method :compiled
end
