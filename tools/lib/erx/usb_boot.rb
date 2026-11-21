# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'pcie_domain'

module Erx
  # The first cases of the `usb` QEMU suite (docs/design-usb.md, "QEMU suites"): qemu-xhci
  # with one usb-kbd behind the PCIe domain, enumerated end to end. It boots the pcie
  # suite's manifest (PcieDomain.manifest) with the test holder on the `usb` release
  # script, which carries erx_usb, so the holder plays the USB domain of design-usb.md's
  # "Who holds a controller". From the system's Erlang shell one line (line) waits for the
  # holder, then at the holder reads its function's record (erx_device_record), starts one
  # controller process alone as a probe, then the controller's supervisor, erx_usb_sup, on
  # erx_xhci, whose start opens and masters the function, and polls the controller's and
  # the bus's states until the keyboard's device descriptor is read or the wait runs out. Its answer names four
  # stages, each a cell of its own (STAGES): the controller running, a root port seeing the
  # keyboard, the keyboard addressed, and its device descriptor read.
  module UsbBoot
    # The holder's row, on the usb release script instead of erts.
    ROW = PcieDomain::HOLDER_ROW.sub("release @artifact.#{MediumBoot::DOMAIN_BOOT.name}\n", "release @artifact.usb\n").freeze
    raise Error, 'the holder row names no release to replace' if ROW == PcieDomain::HOLDER_ROW

    # The suite's manifest from PcieDomain.manifest_source's text.
    def self.manifest(source) = PcieDomain.manifest(source, row: ROW)

    # The four stages, in enumeration order, each a side cell.
    STAGES = %w[started connected addressed described].freeze
    SIDE_CELLS = STAGES.map { |stage| "-#{stage}" }.freeze

    # How long the line may take to print its answer: the holder's wait (PcieDomain::HOLD_SECONDS
    # covers it), the probe's 10 s, and the enumeration poll's 150 rounds of 200 ms.
    ANSWER_SECONDS = PcieDomain::HOLD_SECONDS + 60

    # The body of the fun the holder runs, one expression per element: it returns the stages,
    # the function's peripheral word, how a controller
    # process started alone ended, and what the stages were read from, as text.
    HOLDER_BODY = [
      # The function's record: its peripheral word, then its spec.
      'UbPe=hd([list_to_atom(UbP)||["function","usb",UbP|_]<-erx_device_record:records()])',
      '{ok,[UbSpec]}=erx_device_record:find(usb,UbPe)',
      'UbSelf=self()',
      # UbProbe: one controller process started alone by a process that traps its exit, and
      # how it ended within 10 s (or its core's phase then), so a failure the supervisors would
      # only log is seen in the answer.
      'spawn(fun()->process_flag(trap_exit,true),UbP0=(catch erx_xhci:start_link(UbSpec)),' \
      'UbP1=receive {\'EXIT\',_,UbX0}->UbX0 after 10000->{running,catch maps:get(phase,hd([UbM0||' \
      'UbM0<-tuple_to_list(sys:get_state(element(2,UbP0))),is_map(UbM0),is_map_key(phase,UbM0)]))} end,' \
      'case UbP0 of {ok,UbPp}->unlink(UbPp),exit(UbPp,kill);_->ok end,UbSelf!{ub_probe,{UbP0,UbP1}} end)',
      'UbProbe=receive {ub_probe,UbPr}->UbPr after 15000->probe_timeout end',
      # The supervisor, owned by a process of its own so the erpc call's end leaves it running.
      'spawn(fun()->UbSelf!{ub_started,erx_usb_sup:start_link({erx_xhci,start_link,[UbSpec]})},' \
      'receive after infinity->ok end end)',
      'UbSup=receive {ub_started,{ok,UbS}}->UbS;{ub_started,UbE}->exit({usb_sup,UbE}) after 10000->exit(usb_sup_timeout) end',
      # UbChild(Sup, Id): the child Id of Sup.
      'UbChild=fun(UbSu,UbId)->hd([UbP||{UbI,UbP,_,_}<-supervisor:which_children(UbSu),UbI=:=UbId]) end',
      # UbCore(Pid, Key): the map holding Key among Pid's state's elements, a core's state.
      'UbCore=fun(UbPid,UbK)->hd([UbM||UbM<-tuple_to_list(sys:get_state(UbPid)),is_map(UbM),is_map_key(UbK,UbM)]) end',
      # UbLook(): the stages, and the controller's phase, the root ports and the devices they
      # were read from, or the failure of the reading.
      'UbLook=fun()->try UbB=UbChild(UbSup,bus),' \
      'UbPh=maps:get(phase,UbCore(UbChild(UbB,controller),phase)),UbBc=UbCore(UbChild(UbB,bus),devices),' \
      'UbPs=maps:get(ports,maps:get(root,maps:get(hubs,UbBc),#{}),#{}),UbDs=maps:values(maps:get(devices,UbBc)),' \
      '{[{started,is_tuple(UbPh) andalso element(1,UbPh)=:=running},' \
      '{connected,UbDs=/=[] orelse [UbX||UbX:=UbV<-UbPs,UbV=/=off,UbV=/=empty]=/=[]},' \
      '{addressed,[UbD||#{slot:=UbSl}=UbD<-UbDs,is_integer(UbSl)]=/=[]},' \
      '{described,[UbD||#{descriptor:=UbDe}=UbD<-UbDs,UbDe=/=none]=/=[]}],' \
      '{UbPh,UbPs,[maps:with([speed,slot,descriptor],UbD)||UbD<-UbDs]}} ' \
      'catch UbC2:UbR2->{[],{UbC2,UbR2}} end end',
      # UbPoll(K): looks every 200 ms at most K times until the descriptor is read.
      'UbPoll=fun UbPo(0)->UbLook();UbPo(UbK)->case UbLook() of {[_,_,_,{described,true}],_}=UbL->UbL;' \
      '_->timer:sleep(200),UbPo(UbK-1) end end',
      '{UbStages,UbSeen}=UbPoll(150)',
      # The answer as text: an exit reason the system domain decodes holds no atom it lacks.
      'UbText=iolist_to_binary(io_lib:format("~0kp",[{UbStages,UbPe,UbProbe,UbSeen}]))',
      'binary:part(UbText,0,min(byte_size(UbText),1500))'
    ].join(',').freeze

    # The line typed at the Erlang shell. Every variable starts with Ub or Pc (PcieDomain::WAIT).
    def self.line = [
      *PcieDomain::WAIT,
      "PcHolder=PcWait(#{PcieDomain::HOLDER_NODE},1200)",
      # UbAt(Fun): Fun run at the holder's node, or the class and reason of its failure.
      "UbAt=fun(UbF)->try erpc:call(#{PcieDomain::HOLDER_NODE},UbF,60000) catch UbC:UbR->{UbC,UbR} end end",
      "io:format(\"~0kp~n\",[{usb_enum,UbAt(fun()->#{HOLDER_BODY} end)}])"
    ].join(',').concat(".\r").freeze

    # A stage of the answer's line, true or false, as the holder printed it.
    STAGE = /\{([a-z]+),(true|false)\}/n

    # The stages an answer's text shows passed.
    def self.passed(text)
      line = text.b.sub(/\A#{PcieDomain::PROMPT}/n, '')
      stages = line[/\A\{usb_enum,<<"\{\[([^\]]*)\]/n, 1].to_s
      stages.scan(STAGE).filter_map { |stage, value| stage if value == 'true' }
    end

    # The production checkpoints to the command shell, then the Erlang shell, the line and its
    # answer, whose stages are reported through side and whose whole text through note.
    def self.checkpoints(points, side:, note:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: line).freeze,
       { name: 'usb-enum', pattern: /\A#{PcieDomain::PROMPT}\{usb_enum,/n, seconds: ANSWER_SECONDS,
         verify: lambda do |text|
           note.call(text.b.strip[0, 2000])
           passed(text).each { |stage| side.call("-#{stage}") }
         end }.freeze].freeze
    end

    # Boots the image under HVF at each CPU count. Returns { "<accel>-<n>cpu" => 'passed',
    # and each stage's "<accel>-<n>cpu-<stage>" => 'passed' or 'failed' }.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = MediumBoot.machine(platform)
        @xhci = PcieDomain.xhci(platform)
        @manifest = UsbBoot.manifest(PcieDomain.manifest_source(@root, platform: platform))
        @notes = []
      end

      # What each boot's answer said.
      def notes = @notes.dup.freeze

      # Packs the image once, then boots it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/usb/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                     fiasco: fiasco)
                                .build_medium(directory: directory, machine: @machine, manifest_source: @manifest)
        booted = placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", boot(accel, count, remote, built)]
        end
        booted.flat_map { |cell, sides| [[cell, 'passed'], *sides.map { |side, status| ["#{cell}#{side}", status] }] }.to_h
      end

      private

      def boot(accel, count, remote, built)
        cell = "#{accel}-#{count}cpu"
        path = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/usb', cell))
        boot = OutputDirectory.prepare(root: @root, path: path, mode: 0o700)
        pcie = QemuPlan::Pcie.new(qmp_socket: File.join(boot, 'qmp.sock'), functions: { @xhci.slot => 'qemu-xhci' },
                                  usb: ['usb-kbd'])
        sides = SIDE_CELLS.to_h { |side| [side, 'failed'] }
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib, directory: boot, pcie: pcie,
                 checkpoints: UsbBoot.checkpoints(points, side: ->(side) { sides[side] = 'passed' },
                                                          note: ->(text) { @notes << "#{cell}: #{text}" }))
        sides
      end
    end
  end
end
