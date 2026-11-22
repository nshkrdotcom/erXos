# frozen_string_literal: true

# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

require 'socket'
require_relative 'bumble'
require_relative 'error'
require_relative 'fiasco'
require_relative 'manifest_edit'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'pcie_domain'
require_relative 'process_group'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'runner'

module Erx
  # QEMU virt's Bluetooth suite (docs/design-bluetooth.md, "On QEMU against Bumble"). Its
  # manifest is the development manifest with the Bluetooth domain added (manifest): the
  # line unit, the virtio console of the platform's line row, placed on the system domain,
  # which serves its line tree; the domain's rows; and its one `line` grant, naming that
  # console. The harness serves Bumble's two controllers on loopback ports (Controllers),
  # boots that manifest on MediumBoot's machine with the line's console joined to the first
  # controller's port (QemuPlan::Line), and from the system's Erlang shell, as a person
  # would type it, waits for the Bluetooth domain and then for its controller process's
  # bring-up, whose facts the line prints (line). The bring-up case passes when those facts
  # are a map: every step from the line's reset through the identify answered by Bumble's
  # controller over the console (check_ready).
  module BtDomain
    DOMAIN = 'bt'
    NODE = "#{DOMAIN}@erxos".freeze
    LINE_UNIT = 'line'

    # The domain's memory, 32 MiB, a first figure above the PCIe domain's 25 MiB for an
    # interpreter domain of the same base with erx_bt and crypto loaded; it is not yet
    # measured at rest. Its outer budget is MediumBoot's, 1 MiB, as every service domain's.
    MEMORY = 32 << 20
    # The domain's rows (docs/design-bluetooth.md, "The Bluetooth domain"). Its runtime
    # limits are the PCIe domain's, whose max_frame, 131,072, is the line tree's floor,
    # files_max_frame_min (property 16). Its grant is a share of its own, 50 mcpu on CPU
    # 0, as the PCIe domain's. Its arguments name it, so a scanner tells
    # it from the host, and its -eval starts erx_bt and crypto, which every release only
    # loads, once init holds the ready answer's facets, the line grant among them.
    ROWS = <<~ROWS.freeze
      runtime_limits #{DOMAIN}
        max_frame 131072
        max_message_heap 131072
        funnel_depth 64
        exports 256
        tmp 0
        overlay 0
        atoms 16384
        foreign_atoms 1024
        processes 1024
      share #{DOMAIN}
        quota_ns 500000
        period_ns 10000000
        cpuset 1
        capacity_mcpu 50
        capacity_first 0
        slice_us 1000
        grace_us 5
        base 16
        ceiling 31
        flags none
      limits #{DOMAIN}
        memory #{MEMORY}
        outer #{MediumBoot::DOMAIN_OUTER}
        grant @share.#{DOMAIN}
        spaces none
        lane 4096
        connections 1
        crash 0
        flags none
        runtime_limits @runtime_limits.#{DOMAIN}
        peer_held 4096
        peer_held_total 4096
      domain #{DOMAIN}
        principal @principal.system
        limits @limits.#{DOMAIN}
        kind service
        flags none
        runtime @artifact.emu
        release @artifact.#{DOMAIN}
        restarts 0
        restart_period_s 600
        args "-- -root / -bindir /bin -progname erl -home / -nouser -nocookie -no_epmd -proto_dist erx -erx_bt name \\"erxos-bt\\" -eval {ok,_}=application:ensure_all_started(erx_bt,permanent)"
    ROWS
    # The line grant (docs/design-bluetooth.md, "The controller's line"): the device the
    # platform's line unit holds, a virtio console, which states no rate or flow, and a
    # files tree's quantities, as the data volume's grants: requests of the floor
    # files_max_frame_min, 16 in flight.
    def self.line_grant(device) = "facet line\n  grantee @domain.#{DOMAIN}\n  service @service.line\n  operations none\n" \
                                  "  max_request 131072\n  in_flight 16\n  reductions 100000\n  period_ns 1000000000\n" \
                                  "  max_heap_size 262144\n  parameter device \"#{device}\"\n"

    # The device of platform's line unit, a Platform of QEMU virt: its one device's path.
    def self.line_device(platform)
      devices = platform.record.fetch('units').select { |unit| unit.fetch('key') == LINE_UNIT }.flat_map { |unit| unit.fetch('devices') }
      raise Error, "the platform's line unit is not one serial device" unless devices.size == 1 && devices.first.fetch('role') == 'serial'

      devices.first.fetch('path')
    end

    # The suite's manifest from the development manifest's text, source, on platform: the
    # line unit on the system domain, with root_memory grown by its DMA memory
    # (Manifest::Edit.with_unit), then MediumBoot's medium manifest with room for one
    # domain of MEMORY, and the domain's rows and line grant. MediumBoot drops the system
    # principal's session template, as for every medium cell: the shell the line is typed
    # at runs on the console, and the room one more domain gives the principal makes no
    # more sessions that the display's grants would have to fit in its outer budget. The restarts are 0, so a failed bring-up that ends the domain
    # stays ended.
    def self.manifest(source, platform:)
      lined = Manifest::Edit.with_unit(source, LINE_UNIT, holder: 'system', units: platform.record.fetch('units'))
      MediumBoot.manifest(lined, row: ROWS + line_grant(line_device(platform)), domains: 1, domain_memory: MEMORY)
    end

    # The line typed at the Erlang shell, one expression per element: the wait for the
    # domain (PcieDomain::WAIT); BtFacts, run at the domain, its controller process's
    # bring-up facts (erx_bt_hci:facts/0) printed there as a string, or none before the
    # bring-up is ready: the facts' atoms are the Bluetooth domain's, and a frame to the
    # system domain creates no atom, so a term holding one of them arrives as an opaque
    # erx_foreign_reason; then BtReady(Last, K), which runs BtFacts every 100 ms at most
    # K times until it answers a string, and answers it, or {timeout, Last}, the last
    # answer. Every variable of its own starts with Bt, which nothing else the shell runs
    # binds.
    def self.line = [
      *PcieDomain::WAIT,
      "BtDom=PcWait(#{NODE},1200)",
      # BtFacts(): run at the domain, the bring-up's facts as a string, or none.
      'BtFacts=fun()->case erx_bt_hci:facts() of #{ready:=none}->none;' \
      '#{ready:=BtM}->lists:flatten(io_lib:format("~0p",[BtM])) end end',
      # BtReady(Last, K): BtFacts every 100 ms, each call given 1 s, at most K times.
      "BtReady=fun BtR(BtA,0)->{timeout,BtA};BtR(_,BtK)->case catch erpc:call(#{NODE},BtFacts,1000) of " \
      '[$#|_]=BtF->BtF;BtO->timer:sleep(100),BtR(BtO,BtK-1) end end',
      # The answer: the facts, or why none came.
      "io:format(\"~0kp~n\",[{bt_ready,case BtDom of timeout->{no_domain,PcFind(#{NODE})};_->BtReady(none,600) end}])"
    ].join(',').concat(".\r").freeze

    # The answer's line, which the shell's prompt may precede.
    ANSWER = /\A#{PcieDomain::PROMPT}\{bt_ready,/n
    # How long the line may take to print its answer: the domain's wait (1,200 polls of
    # 100 ms), its boot, and the bring-up's 600 polls of at most 1.1 s; a bring-up that
    # needs them all fails the checkpoint without the line's own timeout answer.
    READY_SECONDS = 240

    module_function

    # The bring-up case: the answer, its prompt removed, is {bt_ready, Facts} with Facts a
    # map, printed at the Bluetooth domain as a string, or Error naming what came.
    READY_LINE = /\A\{bt_ready,"#\{.*\}"\}\z/n
    def check_ready(text)
      line = text.b.sub(/\A#{PcieDomain::PROMPT}/n, '').strip
      raise Error, "the Bluetooth domain's bring-up answered #{line.inspect}, not its facts" unless READY_LINE.match?(line)
    end

    # The production checkpoints to the command shell, then the Erlang shell, the line and
    # its answer, checked as the bring-up case. points must end at the command shell.
    def checkpoints(points)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: BtDomain.line).freeze,
       { name: 'bt-ready', pattern: ANSWER, seconds: READY_SECONDS, verify: ->(text) { check_ready(text) } }.freeze].freeze
    end

    # Bumble's apps/controllers.py, unmodified, with its two controllers joined by its local
    # link, each on a TCP server transport bound to 127.0.0.1 (docs/design-bluetooth.md, "On
    # QEMU against Bumble"): the first for erXos's line, the second for a peer. It runs
    # under the runner's deadline tool in a process group of its own, standard input closed,
    # its output and Bumble's debug log, which shows every HCI packet, in log.
    module Controllers
      SCRIPT = 'apps/controllers.py'
      LOG_LEVEL = { 'BUMBLE_LOGLEVEL' => 'DEBUG' }.freeze
      LISTEN_SECONDS = 30
      KILL_AFTER_SECONDS = 10
    
      Ports = Data.define(:line, :peer)
    
      module_function
    
      # Runs the block with the controllers' Ports once both listen, and ends their process
      # group (ProcessGroup.terminate) when it returns or raises. seconds is their deadline,
      # timeout_program the tool that enforces it.
      def serve(environment, log:, seconds:, timeout_program:)
        line, peer = free_ports(2)
        ports = Ports.new(line: line, peer: peer)
        argv = [timeout_program, '-k', KILL_AFTER_SECONDS.to_s, seconds.to_s,
                *environment.argv(File.join(environment.tree, SCRIPT), *[ports.line, ports.peer].map { |port| "tcp-server:127.0.0.1:#{port}" })]
        pid = nil
        # The spawn and the pid's assignment are one step, so an interrupt cannot come between.
        Thread.handle_interrupt(Object => :never) do
          pid = Process.spawn(LOG_LEVEL, *argv, in: File::NULL, %i[out err] => [log, 'w', 0o600], pgroup: true)
        end
        begin
          listening(ports, pid: pid, log: log)
          yield ports
        ensure
          Thread.handle_interrupt(Object => :never) { ProcessGroup.terminate(pid) }
        end
      end
    
      # count distinct loopback ports the kernel picks, each held until all are picked.
      # Another process may take one between its release and Bumble's bind; Bumble then
      # ends, which listening reports.
      def free_ports(count)
        servers = []
        count.times { servers << TCPServer.new('127.0.0.1', 0) }
        servers.map { |server| server.addr[1] }
      ensure
        servers.each(&:close)
      end
    
      # Waits until the peer's port accepts a connection, which it closes at once, and the
      # controllers still run. controllers.py opens the line's transport first, so the peer's
      # listening means the line's does; the line's port is never touched, since every
      # connection to a Bumble server transport shares one sink, which a probe's end would
      # clear after QEMU had connected. Refused when the controllers end or LISTEN_SECONDS
      # pass first.
      def listening(ports, pid:, log:)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LISTEN_SECONDS
        begin
          Socket.tcp('127.0.0.1', ports.peer, connect_timeout: 1).close
        rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
          ended!(pid, log)
          raise Error, "Bumble's controllers did not listen on #{ports.peer} within #{LISTEN_SECONDS} s; see #{log}" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit
    
          sleep(0.2)
          retry
        end
        ended!(pid, log)
      end
    
      # Refuses controllers that have ended, as they do when another process holds a port.
      def ended!(pid, log)
        raise Error, "Bumble's controllers ended before both their ports listened; see #{log}" if Process.wait(pid, Process::WNOHANG)
      end
    end
    
    # Boots the image under HVF with one CPU against Bumble's controllers. Returns
    # { "hvf-1cpu" => 'passed' }; a boot that does not reach the bring-up's facts raises.
    class Run
      CELL_CPUS = 1

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = MediumBoot.machine(platform)
        @manifest = BtDomain.manifest(platform.manifest_source(@root), platform: platform)
      end

      # Packs the image once, then boots it.
      def call(jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/bt/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                     fiasco: fiasco)
                                .build_medium(directory: directory, machine: @machine, manifest_source: @manifest)
        accel = QemuCells::LOCAL_ACCELERATOR
        boot(accel, built)
        { "#{accel}-#{CELL_CPUS}cpu" => 'passed' }
      end

      private

      # One boot to the command shell, then the line's answer, with the controllers served
      # for its length; their log is bumble.log in the boot's owner-only directory. Their
      # deadline outlasts QEMU's, the checkpoints' seconds and a margin, by their own wait
      # to listen and a minute for QEMU's start.
      def boot(accel, built)
        cell = "#{accel}-#{CELL_CPUS}cpu"
        path = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/bt', cell))
        directory = OutputDirectory.prepare(root: @root, path: path, mode: 0o700)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: CELL_CPUS,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib)
        checkpoints = BtDomain.checkpoints(points)
        seconds = checkpoints.sum { |point| point.fetch(:seconds) } + Controllers::LISTEN_SECONDS + 60
        Bumble.use(root: @root, runner: @runner) do |environment|
          Controllers.serve(environment, log: File.join(directory, 'bumble.log'), seconds: seconds,
                                         timeout_program: @runner.timeout_program) do |ports|
            Qemu.new(root: @root, runner: @runner, program: @qemu)
                .run(platform: @machine.platform, accel: accel, cpus: CELL_CPUS, image: built.single, memory_mib: @machine.memory_mib,
                     directory: directory, line: QemuPlan::Line.new(port: ports.line), checkpoints: checkpoints)
          end
        end
      end
    end
  end
end
