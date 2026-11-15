# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'manifest_edit'
require_relative 'ppm'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'qmp'
require_relative 'release_files'
require_relative 'runner'
require_relative 'screen_reference'

module Erx
  # The display domain and a client's window on QEMU virt (docs/design-display.md,
  # Verification, "Drivers", and "Erlang clients"): a test image (it carries the client's
  # test-only application) boots on MediumBoot's machine with a manifest of the suite's
  # own, the site manifest keeping the development manifest's display domain, which holds
  # the platform's display unit, with a client (manifest), a virtio-gpu attached and QMP on an owner-only socket in the run's
  # directory. The development manifest's display row has no client and its boots attach
  # no gpu, so a client's window on a screen is this boot's alone. The virtio-gpu driver
  # brings the device up and erx_screen fills the empty layout's background. The start row client
  # names the display, so once its server has settled the row's keeper starts the
  # display's session, whose release (BOOT) runs erx_pattern_test: it opens a window
  # with erx_win:open/2, which the single policy places over the whole screen, fills it
  # with erx_pattern_test:pattern/0 and presents it. Once the command shell is up, the
  # harness reads the screen through QMP's screendump until its decoded pixels equal the
  # reference picture's, the pattern over the whole display
  # (test/display/reference/display-pattern.sha256), or the wait runs out, and the cell
  # fails naming both digests. Then the driver's lines in the serial log must be one
  # bring-up and nothing else (check_driver_lines), so a driver that failed a flush and
  # was restarted before the picture came does not pass.
  #
  # A driver that sets no scanout leaves QEMU's own picture of an inactive display; a
  # frame never flushed leaves the device's resource black; a session that never starts,
  # or a window never presented, leaves the background; a wrong colour or channel order,
  # in the client, the window's buffer or the driver, gives another digest. Each fails
  # the cell. A domain that ends after the picture came is not seen: QEMU keeps the last
  # scanout.
  #
  # The same session runs erx_lvgl_lease_test beside it: the LVGL renderer drives the real
  # erx-lvgl through the program's handler over a buffer lent from the session's pixel
  # area, in rounds that lend more than the whole area. Its one outcome line must be
  # "passed" (check_lease_lines); that is the boot's second cell, lvgl-lease (cells). That
  # cell fails on its own outcome, and the boot's cell passes whatever it is; a boot that
  # fails before the lease's wait fails the suite, both cells with it.
  #
  # Once the pattern client has read its input it ends its window, and erx_kiosk_test, the
  # lvgl cell's client in the same session, opens its UI with erx_ui:open(#{renderer =>
  # lvgl}): erx-lvgl, a native program of the session, draws the client's tree into the
  # window's buffer, which the single policy shows over the whole screen. The harness reads
  # the screen until it equals the reference (test/display/reference/display-lvgl.sha256),
  # the host's erx-lvgl's render of the same tree at the same size (test/host/
  # erx_lvgl_test.rb), clicks the button and waits for the client's line of the button's
  # event (check_lvgl). That is the boot's lvgl cell, which fails on its own outcome as the
  # lease cell does. A program that draws another picture than the host's, a window that
  # is not shown, or an input path that loses the click, fails it.
  module DisplayDomain
    REFERENCES = 'test/display/reference'
    PATTERN = 'display-pattern'
    # The boot script of the client's session template: the client release's applications
    # (ReleaseFiles::RELEASE_SCRIPTS, client), the command shell and erx_session, which
    # the template's -eval starts, and the test-only clients, erx_pattern_test and the
    # lvgl-lease cell's erx_lvgl_lease_test and the lvgl cell's erx_kiosk_test.
    CLIENT_SCRIPT = ReleaseFiles::RELEASE_SCRIPTS.fetch('client')
    CLIENT_APPLICATIONS = [*CLIENT_SCRIPT, 'erx_shell', 'erx_session', 'erx_pattern_test', 'erx_lvgl_lease_test',
                           'erx_kiosk_test'].freeze
    BOOT = ReleaseFiles.domain_boot('pattern', applications: CLIENT_APPLICATIONS, test: true)
    # How long the harness reads the screen after the shell's banner before it fails, and
    # how often.
    WAIT_SECONDS = 90
    POLL_SECONDS = 0.5
    # The development manifest's display domain, which the suite keeps in the site
    # manifest, and the service of its window tree.
    DOMAIN = 'display'
    SERVICE = 'display'
    # The display's client (docs/design-display.md, "A display's session"): principal
    # client, whose session template is granted the display's window tree with a pixel
    # area of PIXELS bytes, enough for a 1920 by 1080 screen of 32-bit pixels (8,294,400
    # bytes). The session's registry holds the grant under the service's name, SERVICE,
    # which the start row names, so it is the session's default display, which
    # erx_pattern_test opens (docs/design-system.md, "Facets a configured domain
    # serves"). Its domains quota, CLIENT_SESSIONS, is how many sessions of the template
    # can live at once, each a grant the display pays for.
    PIXELS = 8 << 20
    CLIENT_SESSIONS = 1
    LANE = 4096
    # What the client's sessions add to the display domain's outer budget, property 18's
    # sum (docs/design-system.md, "The manifest", property 18): for each session, its
    # pixel area and the side the display reads for it, its own lane.
    CLIENT_AREAS = CLIENT_SESSIONS * (PIXELS + LANE)
    # The client's principal holds one session of the site manifest's session limits,
    # its memory and its outer budget, on the users share.
    CLIENT_MEMORY = (36 << 20) + MediumBoot::DOMAIN_OUTER
    # The client: its principal and session template, whose release is BOOT's, the
    # session's grant of the display, and its start row, enabled, which names the display
    # as the session's, so the session the row keeps is the display's.
    CLIENT = "principal client\n  memory #{CLIENT_MEMORY}\n  grant @share.users\n  domains #{CLIENT_SESSIONS}\n" \
             "  names 1\n  default_limits @limits.native\n  ceiling_limits @limits.native\n" \
             "session client\n  limits @limits.session\n  runtime @artifact.emu\n  release @artifact.#{BOOT.name}\n" \
             "  args \"-- -root / -bindir /bin -progname erl -home / -nouser -nocookie -no_epmd -proto_dist erx " \
             "-eval ok=application:start(erx_session)\"\n" \
             "facet #{SERVICE}\n  grantee @session.client\n  service @service.#{SERVICE}\n  operations none\n" \
             "  max_request 131072\n  in_flight 16\n  reductions 100000\n  period_ns 1000000000\n" \
             "  max_heap_size 262144\n  parameter pixels #{PIXELS}\n" \
             "start client\n  enable YES\n  display @service.#{SERVICE}\n"

    module_function

    # The manifest, from source, the site manifest keeping the development manifest's
    # display domain (Platform#site_manifest_source, keep), so the suite boots the
    # display row, unit and gpu DMA memory the development image ships: without the
    # session template (ProductionImage.without_sessions), with the display domain's
    # outer budget grown by CLIENT_AREAS and its connections by a connection to each
    # session, with no restart, so a failing display fails the cell, and with CLIENT; the
    # system principal's memory grows by CLIENT_AREAS, root_memory by that and by the
    # client principal's memory, and max_domains and max_connections each by the client's
    # sessions: the principals' domains quotas sum within max_domains, and each session
    # has its connection to the display.
    def manifest(source)
      grown = Manifest::Edit.grow(ProductionImage.without_sessions(source),
                                { ["limits #{DOMAIN}", 'outer'] => CLIENT_AREAS,
                                  ["limits #{DOMAIN}", 'connections'] => CLIENT_SESSIONS,
                                  ['principal system', 'memory'] => CLIENT_AREAS,
                                  %w[machine root_memory] => CLIENT_AREAS + CLIENT_MEMORY,
                                  %w[machine max_domains] => CLIENT_SESSIONS,
                                  %w[machine max_connections] => CLIENT_SESSIONS })
      Manifest::Edit.set(grown, { ["domain #{DOMAIN}", 'restarts'] => 0 }) + CLIENT
    end

    # The screen read through the QMP socket until it equals the reference called name in
    # references, or until wait_seconds have passed, which raises the last mismatch.
    def await_screen(socket:, references:, name:, wait_seconds: WAIT_SECONDS)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      client = Qmp.connect(socket)
      dump = File.join(File.dirname(socket), 'screen.ppm')
      loop do
        image = client.screendump_image(dump)
        begin
          return ScreenReference.check(image, directory: references, name: name)
        rescue ScreenReference::Mismatch
          raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end
        sleep POLL_SECONDS
      end
    ensure
      client&.close
    end

    # The driver's lines of a boot's serial log: one bring-up, "erx_fb: scanout 0 at WxH",
    # and no other, or Error naming them.
    DRIVER_LINE = /erx_fb: [^\r\n]*/n
    BRING_UP = /\Aerx_fb: scanout 0 at [0-9]+x[0-9]+\z/n
    def check_driver_lines(log)
      lines = log.b.scan(DRIVER_LINE)
      return if lines.size == 1 && BRING_UP.match?(lines.first)

      raise Error, "the display driver logged #{lines.size} lines, not one bring-up: #{lines.first(4).inspect}"
    end

    # The client's outcome lines of a boot's serial log (erx_pattern_test:show/0): one
    # "presented" and no other, or Error naming them, so a client that failed, or whose
    # session was started again before the picture came, does not pass, and a failing
    # cell says what the client reported.
    CLIENT_LINE = /erx_pattern_test: (?!started|kbd |mouse |closed)[^\r\n]*/n
    PRESENTED = 'erx_pattern_test: presented'
    def check_client_lines(log)
      lines = log.b.scan(CLIENT_LINE)
      return if lines == [PRESENTED]

      raise Error, "the client logged #{lines.size} outcomes, not one presented: #{lines.first(4).inspect}"
    end

    # The serial log at serial once it holds a client's outcome line, or once wait_seconds
    # have passed: the client logs its outcome after the display answers its present,
    # which may reach the log after the screen shows the picture.
    CLIENT_WAIT_SECONDS = 15
    def await_client_line(serial, wait_seconds: CLIENT_WAIT_SECONDS)
      await_log(serial, wait_seconds: wait_seconds) { |log| log.match?(CLIENT_LINE) }
    end

    # The serial log at serial once the block says it is complete, or once wait_seconds
    # have passed.
    def await_log(serial, wait_seconds:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      loop do
        log = File.binread(serial).b
        return log if yield(log) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL_SECONDS
      end
    end

    # The input the harness types once the client has presented: the key a, down and up,
    # then the tablet at the screen's top left corner, each a batch QEMU ends with a report.
    # The corner is the least position QEMU's tablet sends, whatever its range, and the
    # router scales it to the screen's first pixel, which the client's window covers.
    TYPED = [true, false].map do |down|
      { 'type' => 'key', 'data' => { 'down' => down, 'key' => { 'type' => 'qcode', 'data' => 'a' } } }
    end.freeze
    CORNER = %w[x y].map { |axis| { 'type' => 'abs', 'data' => { 'axis' => axis, 'value' => 0 } } }.freeze
    # The input drivers' bring-ups, the tablet's then the keyboard's, on the display unit's
    # transports (QemuPlan::DISPLAY_TRANSPORTS, at 0x0a000000 and 0x200 apart, the paths
    # config/platforms/qemu-virt.json gives them), and what the client reads of the key and
    # the corner from its window's kbd and mouse files (erx_pattern_test:show/0): the
    # router's records for the key and the pointer, routed to the window.
    INPUT_DRIVER_LINE = /erx_virtio_input: [^\r\n]*/n
    INPUT_DRIVEN = %i[tablet keyboard].map do |role|
      format('erx_virtio_input: /virtio_mmio@%x driven', 0x0a000000 + (0x200 * QemuPlan::DISPLAY_TRANSPORTS.fetch(role)))
    end.freeze
    INPUT_READ = ['erx_pattern_test: kbd {typed,97}', 'erx_pattern_test: mouse {0,0,0}'].freeze
    INPUT_READ_LINE = /erx_pattern_test: (?:kbd|mouse) [^\r\n]*/n

    # The input drivers' lines of a boot's serial log, one bring-up of each in transport
    # order and no other, and the client's reads of the input, the key's then the corner's
    # and no other, or Error naming them.
    def check_input_lines(log)
      drivers = log.scan(INPUT_DRIVER_LINE)
      raise Error, "the input drivers logged #{drivers.first(4).inspect}, not #{INPUT_DRIVEN.inspect}" unless drivers == INPUT_DRIVEN

      read = log.scan(INPUT_READ_LINE)
      raise Error, "the client read #{read.first(4).inspect}, not #{INPUT_READ.inspect}" unless read == INPUT_READ
    end

    # The input typed through the QMP socket at socket.
    def type_input(socket)
      client = Qmp.connect(socket)
      [TYPED, CORNER].each { |events| client.input_events(events) }
    ensure
      client&.close
    end

    # The lvgl-lease client's outcome lines of a boot's serial log
    # (erx_lvgl_lease_test:run/0): one "passed" and no other, or Error naming them.
    LEASE_LINE = /erx_lvgl_lease_test: (?!started)[^\r\n]*/n
    LEASE_PASSED = 'erx_lvgl_lease_test: passed'
    # How long the harness waits for that line once the input's lines came.
    LEASE_WAIT_SECONDS = 240
    def check_lease_lines(log)
      lines = log.b.scan(LEASE_LINE)
      return if lines == [LEASE_PASSED]

      raise Error, "the lvgl-lease client logged #{lines.size} outcomes, not one passed: #{lines.first(4).inspect}"
    end

    # The lvgl cell's reference, the host's render of erx_kiosk_test:tree/0, and the
    # client's lines once the screen shows it and the harness has clicked its button: the
    # UI shown, then the button's event, and no other (erx_kiosk_test).
    LVGL = 'display-lvgl'
    KIOSK_LINE = /erx_kiosk_test: (?!started|refused )[^\r\n]*/n
    KIOSK_LINES = ['erx_kiosk_test: shown', 'erx_kiosk_test: event pressed'].freeze
    # The click: the tablet at 0x4000 on each axis, then the left button down and up. The
    # driver scales the device's own range to the screen (erx_virtio_input_core); the
    # range QMP's values span is not checked here, but the point lands on the button
    # (x 16 to 1263, y 96 to 655 in display-lvgl.ppm.gz) whether 0x4000 is half of it,
    # the screen's centre, or a quarter, (320, 200).
    CLICK = [%w[x y].map { |axis| { 'type' => 'abs', 'data' => { 'axis' => axis, 'value' => 0x4000 } } },
             [{ 'type' => 'btn', 'data' => { 'down' => true, 'button' => 'left' } }],
             [{ 'type' => 'btn', 'data' => { 'down' => false, 'button' => 'left' } }]].freeze

    # The lvgl cell's check: the screen until it equals LVGL, the click, then the client's
    # lines in the serial log at serial, or Error naming what came.
    def check_lvgl(socket:, references:, serial:)
      await_screen(socket: socket, references: references, name: LVGL)
      click(socket)
      check_kiosk_lines(await_log(serial, wait_seconds: CLIENT_WAIT_SECONDS) { |text| text.scan(KIOSK_LINE).size >= KIOSK_LINES.size })
    end

    # The lvgl client's lines of a boot's serial log: KIOSK_LINES and no other, or Error
    # naming them.
    def check_kiosk_lines(log)
      lines = log.b.scan(KIOSK_LINE)
      raise Error, "the lvgl client logged #{lines.first(4).inspect}, not #{KIOSK_LINES.inspect}" unless lines == KIOSK_LINES
    end

    # The click sent through the QMP socket at socket.
    def click(socket)
      client = Qmp.connect(socket)
      CLICK.each { |events| client.input_events(events) }
    ensure
      client&.close
    end

    # The suite's cells, from the cells of its boots: each boot's own, and its side cells,
    # which a boot checks one after the other and each of which fails on its own outcome.
    LVGL_CELL = '-lvgl'
    LEASE_CELL = '-lvgl-lease'
    SIDE_CELLS = [LVGL_CELL, LEASE_CELL].freeze
    def cells(boots) = boots.flat_map { |cell| [cell, *SIDE_CELLS.map { |side| "#{cell}#{side}" }] }

    # The production checkpoints to the command shell, whose banner starts the screen's
    # reads, then the driver's and the client's lines of the serial log at serial, then the
    # input typed and its lines, then the side cells, each through side, which records its
    # outcome: the lvgl cell (check_lvgl), then the lease cell on the serial log once the
    # lvgl-lease client's line came, or once LEASE_WAIT_SECONDS passed. points must end at
    # the command shell.
    def checkpoints(points, socket:, references:, serial:, side:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      shell = points.last
      screen = lambda do |_text|
        await_screen(socket: socket, references: references, name: PATTERN)
        log = await_client_line(serial)
        check_driver_lines(log)
        check_client_lines(log)
        type_input(socket)
        typed = await_log(serial, wait_seconds: CLIENT_WAIT_SECONDS) { |text| text.scan(INPUT_READ_LINE).size >= INPUT_READ.size }
        check_input_lines(typed)
        side.call(LVGL_CELL) { check_lvgl(socket: socket, references: references, serial: serial) }
        side.call(LEASE_CELL) do
          check_lease_lines(await_log(serial, wait_seconds: LEASE_WAIT_SECONDS) { |text| text.match?(LEASE_LINE) })
        end
      end
      seconds = shell.fetch(:seconds) + (2 * WAIT_SECONDS) + (3 * CLIENT_WAIT_SECONDS) + LEASE_WAIT_SECONDS + 15
      [*points[0...-1], shell.merge(seconds: seconds, verify: screen).freeze].freeze
    end

    # Boots the image under HVF at each CPU count, where placement puts each cell.
    # Returns { "<accel>-<n>cpu" => 'passed', and each side cell's "<accel>-<n>cpu<side>" =>
    # 'passed', or 'failed' with its reason in notes }; any other disagreement raises.
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
        @manifest = DisplayDomain.manifest(platform.site_manifest_source(@root, keep: [DOMAIN]))
        @notes = []
      end

      # Why each failed side cell failed.
      def notes = @notes.dup.freeze

      # Packs the test image, which carries the client's boot script (BOOT), once, then boots
      # it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/display-domain/image'))
        nothing = ProductionImage::Added.new(entries: [].freeze, inputs: [].freeze, imports: {}.freeze)
        built = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                    fiasco: fiasco)
                               .build_test_image(directory: directory, added: nothing, machine: @machine, domains: [BOOT],
                                                 manifest_source: @manifest)
        booted = placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", show(accel, count, remote, built)]
        end
        booted.flat_map { |cell, sides| [[cell, 'passed'], *sides.map { |side, status| ["#{cell}#{side}", status] }] }.to_h
      end

      private

      # One boot to the command shell, then the screen's reads; returns each side cell's
      # status, by its suffix. The run's directory is made afresh and owner-only here, so
      # the QMP socket QEMU creates in it and the dumps beside it are the harness's alone. A remote
      # placement reaches Qemu#run, which refuses a boot with a display there.
      def show(accel, count, remote, built)
        path = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/display-domain', "#{accel}-#{count}cpu"))
        boot = OutputDirectory.prepare(root: @root, path: path, mode: 0o700)
        socket = File.join(boot, 'qmp.sock')
        display = QemuPlan::Display.new(qmp_socket: socket)
        sides = SIDE_CELLS.to_h { |side| [side, 'failed'] }
        side = lambda do |suffix, &check|
          check.call
          sides[suffix] = 'passed'
        rescue Error => e
          @notes << "#{accel}-#{count}cpu#{suffix}: #{e.message}"
        end
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib,
                                                         test_image: true)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib, directory: boot, display: display,
                 checkpoints: DisplayDomain.checkpoints(points, socket: socket, references: File.join(@root, REFERENCES),
                                                        serial: File.join(boot, 'serial.log'), side: side))
        sides
      end
    end
  end
end
