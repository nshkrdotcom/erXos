# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'pcie_domain'

module Erx
  # The first cases of the `usb` QEMU suite (docs/design-usb.md, "QEMU suites"): qemu-xhci
  # with one usb-kbd behind the PCIe domain, held by the USB domain of QEMU virt's
  # development manifest, usb, whose application, erx_usb, starts the controller's
  # supervisor at the domain's start (docs/design-usb.md, "Who holds a controller"). The
  # suite boots that manifest without its web domain, which it tests nothing of, and with
  # the USB domain's restarts 0, so a failure is seen, not restarted away.
  #
  # From the system's Erlang shell two lines run, each at the USB domain's node. The first
  # (line) waits for the domain, arms a tracer of the writes to the input numbers' streams
  # (erx_usb_input_stream:write/2, which a HID function calls with the records of its
  # reports), and polls the controller's and the bus's states until the keyboard's device
  # descriptor is read or the wait runs out. Its answer names four stages: the controller
  # running, a root port seeing the keyboard, the keyboard addressed, and its device
  # descriptor read. Then the harness types the key a, down and up, through QMP's
  # input-send-event (Qmp#input_events), and the second line (typed_line) asks the tracer
  # for the writes it saw: a fifth stage, typed, passes when a HID function wrote records
  # to its input number's file. Each stage is a cell of its own (STAGES).
  module UsbBoot
    DOMAIN = 'usb'
    NODE = "#{DOMAIN}@erxos".freeze
    LEFT_OUT = 'web'

    # The development manifest's text for platform, a Platform of QEMU virt, from root's
    # sources, without the web domain.
    def self.manifest_source(root, platform:) =
      Manifest::Edit.without_domain(platform.manifest_source(root), LEFT_OUT, units: platform.record.fetch('units'))

    # The suite's manifest, from manifest_source's text: MediumBoot's medium manifest with no
    # configured row of its own and no room added, and the USB domain without restarts.
    def self.manifest(source)
      Manifest::Edit.set(MediumBoot.manifest(source, row: '', domains: 0), { ["domain #{DOMAIN}", 'restarts'] => 0 })
    end

    # The five stages, in order, each a side cell.
    STAGES = %w[started connected addressed described typed].freeze
    SIDE_CELLS = STAGES.map { |stage| "-#{stage}" }.freeze

    # How long the first line may take to print its answer: the domain's wait (the hold at
    # boot, which PcieDomain::HOLD_SECONDS covers) and the enumeration poll's 150 rounds of
    # 200 ms. The second waits at most 10 s for the tracer.
    ANSWER_SECONDS = PcieDomain::HOLD_SECONDS + 60
    TYPED_SECONDS = 30

    # The body of the fun the first line runs at the USB domain, one expression per element:
    # it returns the stages, the function's peripheral words and what the stages were read
    # from, as text.
    ENUM_BODY = [
      'UbPe=[list_to_atom(UbP)||["function","usb",UbP|_]<-erx_device_record:records()]',
      # UbTr: keeps the first 64 writes to the input numbers' streams, each the records
      # written, until asked, then waits up to 5 s for a first one if it has none.
      'UbTr=spawn(fun()->(fun UbTl(UbA)->receive {trace,_,call,{_,_,[_,UbRs]}} when length(UbA)<64->' \
      'UbTl([UbRs|UbA]);{ub_get,UbP} when UbA=/=[]->UbP!{ub_writes,lists:reverse(UbA)};' \
      '{ub_get,UbP}->receive {trace,_,call,{_,_,[_,UbRs]}}->UbP!{ub_writes,[UbRs]} after 5000->' \
      'UbP!{ub_writes,[]} end;_->UbTl(UbA) end end)([]) end)',
      'true=register(ub_tracer,UbTr)',
      'erlang:trace_pattern({erx_usb_input_stream,write,2},true,[global])',
      'erlang:trace(all,true,[call,{tracer,UbTr}])',
      # UbSup(): the controller's supervisor, the one child of the application's supervisor.
      'UbSup=fun()->[UbS]=[UbS||{_,UbS,_,_}<-supervisor:which_children(erx_usb)],UbS end',
      # UbChild(Sup, Id): the child Id of Sup.
      'UbChild=fun(UbSu,UbId)->hd([UbP||{UbI,UbP,_,_}<-supervisor:which_children(UbSu),UbI=:=UbId]) end',
      # UbCore(Pid, Key): the map holding Key among Pid's state's elements, a core's state.
      'UbCore=fun(UbPid,UbK)->hd([UbM||UbM<-tuple_to_list(sys:get_state(UbPid)),is_map(UbM),is_map_key(UbK,UbM)]) end',
      # UbLook(): the stages, and the controller's phase, the root ports and the devices they
      # were read from, or the failure of the reading.
      'UbLook=fun()->try UbB=UbChild(UbSup(),bus),' \
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
      'UbText=iolist_to_binary(io_lib:format("~0kP",[{UbStages,UbPe,UbSeen},40]))',
      'binary:part(UbText,0,min(byte_size(UbText),3000))'
    ].join(',').freeze

    # The body of the fun the second line runs at the USB domain: the writes the tracer saw,
    # as text, after which the tracing is off.
    TYPED_BODY = [
      'ub_tracer!{ub_get,self()}',
      'UbWs=receive {ub_writes,UbW}->UbW after 10000->[] end',
      'erlang:trace(all,false,[call])', 'erlang:trace_pattern({erx_usb_input_stream,write,2},false,[global])',
      'UbTyped=[UbR||UbRs<-UbWs,UbR<-UbRs]=/=[]',
      'UbText=iolist_to_binary(io_lib:format("~0kP",[{[{typed,UbTyped}],UbWs},40]))',
      'binary:part(UbText,0,min(byte_size(UbText),2000))'
    ].join(',').freeze

    # UbAt(Fun): Fun run at the USB domain's node, or the class and reason of its failure.
    AT = "UbAt=fun(UbF)->try erpc:call(#{NODE},UbF,60000) catch UbC:UbR->{UbC,UbR} end end".freeze

    # The first line typed at the Erlang shell. Every variable starts with Ub or Pc
    # (PcieDomain::WAIT).
    def self.line = [
      *PcieDomain::WAIT,
      "UbDomain=PcWait(#{NODE},1200)",
      AT,
      "io:format(\"~0kp~n\",[{usb_enum,UbAt(fun()->#{ENUM_BODY} end)}])"
    ].join(',').concat(".\r").freeze

    # The second line, typed once the key has been sent. The shell keeps the first line's
    # bindings, UbAt among them.
    def self.typed_line = "io:format(\"~0kp~n\",[{usb_typed,UbAt(fun()->#{TYPED_BODY} end)}]).\r".freeze

    # A stage of an answer's line, true or false, as the domain printed it.
    STAGE = /\{([a-z]+),(true|false)\}/n

    # The stages the answer's text of the line tagged tag shows passed.
    def self.passed(text, tag:)
      line = text.b.sub(/\A#{PcieDomain::PROMPT}/n, '')
      stages = line[/\A\{#{tag},<<"\{\[([^\]]*)\]/n, 1].to_s
      stages.scan(STAGE).filter_map { |stage, value| stage if value == 'true' }
    end

    # The key the harness types, down then up, each a batch QEMU ends with a report, which
    # QEMU's usb-kbd sends on its interrupt pipe.
    TYPED = [true, false].map do |down|
      [{ 'type' => 'key', 'data' => { 'down' => down, 'key' => { 'type' => 'qcode', 'data' => 'a' } } }]
    end.freeze

    # Types TYPED through the QMP socket at socket.
    def self.type_key(socket)
      client = Qmp.connect(socket)
      TYPED.each { |events| client.input_events(events) }
    ensure
      client&.close
    end

    # The production checkpoints to the command shell, then the Erlang shell, the first
    # line and its answer, after which the key is typed through socket, and the second line
    # and its answer. Each answer's stages are reported through side and its text through
    # note.
    def self.checkpoints(points, socket:, side:, note:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      answer = lambda do |tag|
        lambda do |text|
          note.call(text.b.strip[0, 2000])
          passed(text, tag: tag).each { |stage| side.call("-#{stage}") }
        end
      end
      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: line).freeze,
       { name: 'usb-enum', pattern: /\A#{PcieDomain::PROMPT}\{usb_enum,/n, seconds: ANSWER_SECONDS,
         verify: lambda do |text|
           answer.call('usb_enum').call(text)
           type_key(socket)
         end, type: typed_line }.freeze,
       { name: 'usb-typed', pattern: /\A#{PcieDomain::PROMPT}\{usb_typed,/n, seconds: TYPED_SECONDS,
         verify: answer.call('usb_typed') }.freeze].freeze
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
        @manifest = UsbBoot.manifest(UsbBoot.manifest_source(@root, platform: platform))
        @notes = []
      end

      # What each boot's answers said.
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
        socket = File.join(boot, 'qmp.sock')
        pcie = QemuPlan::Pcie.new(qmp_socket: socket, functions: { @xhci.slot => 'qemu-xhci' }, usb: ['usb-kbd'])
        sides = SIDE_CELLS.to_h { |side| [side, 'failed'] }
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib, directory: boot, pcie: pcie,
                 checkpoints: UsbBoot.checkpoints(points, socket: socket, side: ->(side) { sides[side] = 'passed' },
                                                          note: ->(text) { @notes << "#{cell}: #{text}" }))
        sides
      end
    end
  end
end
