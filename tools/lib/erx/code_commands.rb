# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require 'socket'
require 'tmpdir'
require_relative 'code_load'
require_relative 'code_ssh'
require_relative 'code_watch'
require_relative 'error'
require_relative 'hostlink_client'

module Erx
  # The host tool's code commands (docs/design-live.md, "Code from the host"):
  #
  #   tools/erx load  TRANSPORT (--system | --domain D) FILE...
  #   tools/erx watch TRANSPORT (--system | --domain D) [--interval S] DIR
  #   TRANSPORT: --socket PATH [--build HEX] | --ssh DEST
  #
  # load sends FILEs, each a compiled MODULE.beam or an Erlang source it compiles first, as
  # one batch; watch compiles and loads each source of DIR that changes. A command takes
  # exactly one transport and exactly one target: --system, through the install facet, or
  # --domain D, through the code facet. --socket PATH is the UNIX socket QEMU serves the
  # guest's host link UART on (QemuPlan), and HEX, when given, the build identifier the
  # guest's hello must report; --ssh DEST runs the session's load over an SSH exec
  # (CodeSsh). The host link session opens the install facet alone, so --socket takes
  # --system only.
  module CodeCommands
    # How a command reaches the guest, as the options gave it: a host link socket and the
    # build its hello must report, or an ssh destination; and where it loads, :system or
    # [:domain, D].
    Target = Data.define(:socket, :build, :ssh, :load_into) do
      def initialize(socket:, build:, ssh: nil, load_into: :system) = super
    end

    module_function

    # Runs load with arguments; returns the exit status. connect yields a HostlinkClient
    # with an open session for a Target; compile is an ErlangCompile; out prints a line.
    def load(arguments, connect:, compile:, out:)
      target, rest = options(arguments.dup, 'load')
      raise OptionParser::InvalidArgument, 'load names at least one FILE' if rest.empty?

      Dir.mktmpdir('erx-load') do |output|
        beams = rest.map { |file| file.end_with?('.erl') ? compile.call(file, output: output) : file }
        out.call(install(target, beams, connect: connect))
      end
      0
    end

    # Runs watch with arguments until it is stopped, or for rounds scans.
    def watch(arguments, connect:, compile:, out:, sleep: Kernel.method(:sleep), rounds: nil)
      interval = 0.5
      target, rest = options(arguments.dup, 'watch') do |flags|
        flags.on('--interval SECONDS', Float) { |value| interval = value }
      end
      raise OptionParser::InvalidArgument, 'watch names one DIR' unless rest.size == 1
      raise OptionParser::InvalidArgument, '--interval is a positive number of seconds' unless interval.positive?

      CodeWatch.new(compile: compile, load: ->(beams) { install(target, beams, connect: connect) },
                    out: out, interval: interval, sleep: sleep).call(rest.first, rounds: rounds)
      0
    end

    # Loads the module files beams as one batch in a session of their own, so a guest that
    # restarted between two loads of a watch is met with a new hello, though what earlier
    # loads installed is not sent again (TODO.md). Returns the line that reports it.
    def install(target, beams, connect:, ssh: CodeSsh.method(:install))
      blobs = beams.map { |path| CodeLoad::Blob.from_file(path) }
      result = if target.ssh
                 ssh.call(dest: target.ssh, target: target.load_into, blobs: blobs)
               else
                 connect.call(target) do |client|
                   CodeLoad.install(client, facet: CodeLoad.open_install(client), blobs: blobs)
                 end
               end
      "loaded #{result.loaded.join(' ')} (sent #{result.sent.size} of #{blobs.size} modules)"
    end

    # The connection the tool uses: QEMU's UNIX socket, a hello, and the session to the block.
    def connect_socket(target)
      UNIXSocket.open(target.socket) do |io|
        client = HostlinkClient.new(io: io, expected_build: target.build)
        client.hello
        yield client
      end
    rescue SystemCallError, IOError => e
      raise Error, "host link socket #{target.socket}: #{e.message}"
    end

    def options(arguments, command)
      given = { transports: [], targets: [] }
      build = nil
      OptionParser.new do |flags|
        flags.on('--socket PATH') { |value| given[:transports] << [:socket, value] }
        flags.on('--ssh DEST') { |value| given[:transports] << [:ssh, value] }
        flags.on('--build HEX', /\A\h+\z/) { |value| build = value.downcase }
        flags.on('--system') { given[:targets] << :system }
        flags.on('--domain D') { |value| given[:targets] << [:domain, value] }
        yield flags if block_given?
      end.parse!(arguments)
      [target(command, **given, build: build), arguments]
    end

    # The Target of exactly one transport and exactly one target; --build goes with --socket.
    def target(command, transports:, targets:, build:)
      raise OptionParser::InvalidArgument, "#{command} takes exactly one of --socket PATH and --ssh DEST" unless
        transports.size == 1
      raise OptionParser::InvalidArgument, "#{command} takes exactly one of --system and --domain D" unless targets.size == 1

      case [transports.first, targets.first, build]
      in [[:socket, socket], :system, _]
        Target.new(socket: socket, build: build)
      in [[:socket, _], [:domain, _], _]
        raise OptionParser::InvalidArgument, "#{command}: the host link session opens the install facet alone; --socket takes --system"
      in [[:ssh, _], _, String]
        raise OptionParser::InvalidArgument, "#{command}: --build goes with --socket"
      in [[:ssh, dest], load_into, nil]
        Target.new(socket: nil, build: nil, ssh: dest, load_into: load_into)
      end
    end
  end
end
