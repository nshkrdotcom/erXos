# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi'
require_relative 'compiler_rt'
require_relative 'error'
require_relative 'fiasco'
require_relative 'generated'
require_relative 'manifest_edit'
require_relative 'medium_boot'
require_relative 'native_root'
require_relative 'native_runtime'
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
  # brings the device up and erx_screen shows its splash until a window presents. The start row client
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
  # or a window never presented, leaves the splash; a wrong colour or channel order,
  # in the client, the window's buffer or the driver, gives another digest. Each fails
  # the cell. A domain that ends after the picture came is not seen: QEMU keeps the last
  # scanout.
  #
  # The same session runs erx_lvgl_lease_test beside it: the LVGL renderer drives the real
  # erx-lvgl through the program's handler over a buffer lent from the session's pixel
  # area, in rounds that lend more than the whole area. Its lease run's one outcome line
  # must be "lease passed" (check_run_lines); that is the boot's lvgl-lease cell (cells).
  # Each side cell fails on its own outcome, and the boot's cell passes whatever they are;
  # a boot that fails before the side cells' waits fails the suite, every cell with it.
  #
  # The same client then runs the renderer over PROBE, a stand-in for erx-lvgl that this
  # suite's image alone carries (test/guest/programs/uiprobe.c). Its damage run writes a
  # second damage report before the first is answered, then a rectangle outside the size
  # its report names; the renderer must stop the program each time and present only the
  # first report of the first. Its confine run stores to the last byte of the buffer it
  # was lent, has a report presented and answered, then stores one page past the
  # buffer, which must fault in the program. Each run's line, "damage passed" and "confine
  # passed", is the lvgl-damage and the lvgl-confine cell's (docs/design-display.md,
  # Verification, the kiosk's cells). A renderer that presents a bad report, or a session
  # that maps more of the pixel area than the buffer into the program, fails its cell.
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
  #
  # Last, the lvgl-restart cell: the system's Erlang shell kills the lvgl client's process
  # in the session (KILL_LINE). The session's domain must keep running, the client's
  # supervisor must start the process again, and its UI must come back on the screen and
  # take the click (check_restart). A client started outside its supervisor, or a kill
  # that ends the session, fails it.
  module DisplayDomain
    REFERENCES = 'test/display/reference'
    PATTERN = 'display-pattern'
    # The boot script of the client's session template: the client release's applications
    # (ReleaseFiles::RELEASE_SCRIPTS, client), what every session boots
    # (ReleaseFiles::SESSION_BASE), whose erx_session the template's -eval starts, and
    # the test-only clients, erx_pattern_test, the lvgl-lease cell's erx_lvgl_lease_test
    # and the lvgl cell's erx_kiosk_test.
    CLIENT_SCRIPT = ReleaseFiles::RELEASE_SCRIPTS.fetch('client')
    CLIENT_APPLICATIONS = (CLIENT_SCRIPT | ReleaseFiles::SESSION_BASE |
                           %w[erx_pattern_test erx_lvgl_lease_test erx_kiosk_test]).freeze
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

    # The name of the reference await_screen keeps of a screen that equals none.
    KEPT_SCREEN = 'screen'

    # The screen read through the QMP socket until it equals one of the references called
    # names in references, whose name it answers, or until wait_seconds have passed. Then
    # the last screen read is kept as the reference KEPT_SCREEN beside the socket, in the
    # run's own directory, and Mismatch names it and how it differs from each reference.
    def await_screen(socket:, references:, names:, wait_seconds: WAIT_SECONDS)
      raise Error, 'await_screen names no reference' if names.empty?

      wanted = names.map { |name| ScreenReference.load(references, name) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      client = Qmp.connect(socket)
      directory = File.dirname(socket)
      loop do
        image = client.screendump_image(File.join(directory, "#{KEPT_SCREEN}.ppm"))
        found = wanted.find { |reference| ScreenReference.matches?(image, reference) }
        return found.name if found
        raise kept_mismatch(image, directory: directory, references: references, names: names) if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL_SECONDS
      end
    ensure
      client&.close
    end

    # Writes image as the reference KEPT_SCREEN into directory and answers the Mismatch
    # that names it and each reference's mismatch.
    def kept_mismatch(image, directory:, references:, names:)
      mismatches = names.map do |name|
        ScreenReference.check(image, directory: references, name: name)
      rescue ScreenReference::Mismatch => e
        e.message
      end
      kept = ScreenReference.write(directory, KEPT_SCREEN, image)
      ScreenReference::Mismatch.new("the screen, kept at #{kept}, equals no reference: #{mismatches.join('; and ')}")
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

    # The outcome lines of erx_lvgl_lease_test's run called run (lease, damage or confine)
    # in a boot's serial log (erx_lvgl_lease_test:run/0): one "<run> passed" and no other,
    # or Error naming them.
    def run_line(run) = /erx_lvgl_lease_test: #{run} [^\r\n]*/n

    def check_run_lines(log, run:)
      lines = log.b.scan(run_line(run))
      return if lines == ["erx_lvgl_lease_test: #{run} passed"]

      raise Error, "the lvgl-#{run} client logged #{lines.size} outcomes, not one passed: #{lines.first(4).inspect}"
    end

    # How long the harness waits for the lease run's line once the input's lines came, and
    # for each later run's once the one before it logged.
    LEASE_WAIT_SECONDS = 240
    PROBE_WAIT_SECONDS = 90
    # The stand-in for erx-lvgl that the damage and confine runs start
    # (test/guest/programs/uiprobe.c), in the session release's bin/, linked with the
    # ui.txt writer it reports through. Only this suite's image carries it.
    PROBE = 'uiprobe'
    PROBE_SOURCES = %w[test/guest/programs/uiprobe.c build/gen/display/generated/erx_ui_wire.c].freeze

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
      await_screen(socket: socket, references: references, names: [LVGL])
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

    # The lvgl-restart cell (docs/design-display.md, Verification): typed at the system's
    # Erlang shell, where every variable carries the prefix Kt, once the other cells are
    # done. It finds the client's session, the domain service's only session row whose
    # node is the client principal's, and the lvgl client's process there, which
    # registers itself as erx_kiosk_test, kills that process through erpc at the
    # session's node, the route the driver domains suite kills a process of a domain by,
    # and polls every 500 ms, at most KILL_POLLS times, until the name is held by another
    # process. It answers {kiosk_killed, {Found, Replaced, Kept}}: whether the killed
    # process was a pid, whether another took its place, and whether the session's domain
    # pid is still the only one on that node; every erpc call waits at most 5 s, and any
    # exception on the way is the answer instead, {kiosk_killed, {Class, Reason}}, so the
    # cell fails on its own outcome and never waits out the boot's deadline.
    KILL_POLLS = 240
    KILL_LINE = 'KtDoms = fun() -> erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv))) end, ' \
                'io:format("~0kp~n", [{kiosk_killed, try ' \
                '[#{node := KtN, pid := KtP}] = [KtD || #{origin := {session, _}, node := KtM} = KtD <- KtDoms(), ' \
                'lists:prefix("client_", atom_to_list(KtM))], ' \
                'KtWho = fun() -> erpc:call(KtN, erlang, whereis, [erx_kiosk_test], 5000) end, KtK = KtWho(), ' \
                'true = erpc:call(KtN, erlang, exit, [KtK, kill], 5000), ' \
                'KtNew = (fun KtF(0) -> timeout; KtF(KtI) -> case KtWho() of KtQ when is_pid(KtQ), KtQ =/= KtK -> KtQ; ' \
                "_ -> timer:sleep(500), KtF(KtI - 1) end end)(#{KILL_POLLS}), " \
                '{is_pid(KtK), is_pid(KtNew), [KtR || #{node := KtM, pid := KtR} <- KtDoms(), KtM =:= KtN] =:= [KtP]} ' \
                'catch KtC:KtW -> {KtC, KtW} end}]).' "\r"
    KILL_ANSWER = /\A\{kiosk_killed,[^\r\n]*\}\r*\n\z/n
    KILLED = '{kiosk_killed,{true,true,true}}'
    KILL_SECONDS = (KILL_POLLS / 2) + 60

    # The lvgl-restart cell's check, given the answer line: the client killed, another in
    # its place and the session's domain as it was; then the new process's UI shown, the
    # screen equal to LVGL again, and the button's event once clicked, so the lines of the
    # client are KIOSK_LINES twice, or Error naming what came.
    def check_restart(answer, socket:, references:, serial:)
      raise Error, "the kill answered #{answer.strip.inspect}, not #{KILLED}" unless answer.strip == KILLED

      await_log(serial, wait_seconds: WAIT_SECONDS) { |text| text.scan(KIOSK_LINE).size > KIOSK_LINES.size }
      await_screen(socket: socket, references: references, names: [LVGL])
      click(socket)
      log = await_log(serial, wait_seconds: CLIENT_WAIT_SECONDS) { |text| text.scan(KIOSK_LINE).size >= 2 * KIOSK_LINES.size }
      lines = log.b.scan(KIOSK_LINE)
      raise Error, "the lvgl client logged #{lines.first(6).inspect}, not #{(KIOSK_LINES * 2).inspect}" unless lines == KIOSK_LINES * 2
    end

    # The suite's cells, from the cells of its boots: each boot's own, and its side cells,
    # which a boot checks one after the other and each of which fails on its own outcome.
    LVGL_CELL = '-lvgl'
    LEASE_CELL = '-lvgl-lease'
    DAMAGE_CELL = '-lvgl-damage'
    CONFINE_CELL = '-lvgl-confine'
    RESTART_CELL = '-lvgl-restart'
    SIDE_CELLS = [LVGL_CELL, LEASE_CELL, DAMAGE_CELL, CONFINE_CELL, RESTART_CELL].freeze
    def cells(boots) = boots.flat_map { |cell| [cell, *SIDE_CELLS.map { |side| "#{cell}#{side}" }] }

    # The production checkpoints to the command shell, whose banner starts the screen's
    # reads, then the driver's and the client's lines of the serial log at serial, then the
    # input typed and its lines, then the side cells, each through side, which records its
    # outcome: the lvgl cell (check_lvgl), then the lease cell on the serial log once the
    # lease run's line came, or once LEASE_WAIT_SECONDS passed, then the damage and the
    # confine cells each on its run's line, waiting PROBE_WAIT_SECONDS for it. Then the command
    # shell starts the Erlang shell, which types KILL_LINE, and its answer is the
    # lvgl-restart cell's (check_restart). points must end at the command shell.
    def checkpoints(points, socket:, references:, serial:, side:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      shell = points.last
      screen = lambda do |_text|
        await_screen(socket: socket, references: references, names: [PATTERN])
        log = await_client_line(serial)
        check_driver_lines(log)
        check_client_lines(log)
        type_input(socket)
        typed = await_log(serial, wait_seconds: CLIENT_WAIT_SECONDS) { |text| text.scan(INPUT_READ_LINE).size >= INPUT_READ.size }
        check_input_lines(typed)
        side.call(LVGL_CELL) { check_lvgl(socket: socket, references: references, serial: serial) }
        { LEASE_CELL => ['lease', LEASE_WAIT_SECONDS], DAMAGE_CELL => ['damage', PROBE_WAIT_SECONDS],
          CONFINE_CELL => ['confine', PROBE_WAIT_SECONDS] }.each do |cell, (run, wait)|
          side.call(cell) { check_run_lines(await_log(serial, wait_seconds: wait) { |text| text.match?(run_line(run)) }, run: run) }
        end
      end
      restart = lambda do |answer|
        side.call(RESTART_CELL) { check_restart(answer, socket: socket, references: references, serial: serial) }
      end
      seconds = shell.fetch(:seconds) + (2 * WAIT_SECONDS) + (3 * CLIENT_WAIT_SECONDS) + LEASE_WAIT_SECONDS +
                (2 * PROBE_WAIT_SECONDS) + 15
      [*points[0...-1], shell.merge(seconds: seconds, verify: screen, type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(name: 'system-erlang-shell', type: KILL_LINE).freeze,
       { name: 'kiosk-killed', pattern: KILL_ANSWER, verify: restart,
         seconds: KILL_SECONDS + (2 * WAIT_SECONDS) + CLIENT_WAIT_SECONDS }.freeze].freeze
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

      # Packs the test image, which carries the client's boot script (BOOT) and PROBE, once,
      # then boots it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        runtime = NativeRuntime.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco,
                                    platform: @machine.platform)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/display-domain/image'))
        # The image's build builds the runtime again; make finds nothing left to do.
        added = probe(fiasco, libc: runtime.build.libc)
        built = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                    fiasco: fiasco, runtime: runtime)
                               .build_test_image(directory: directory, added: added, machine: @machine, domains: [BOOT],
                                                 manifest_source: @manifest)
        booted = placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", show(accel, count, remote, built)]
        end
        booted.flat_map { |cell, sides| [[cell, 'passed'], *sides.map { |side, status| ["#{cell}#{side}", status] }] }.to_h
      end

      private

      # PROBE linked over musl's libc.a, the one the runtime images link, as a release file
      # of the session's, as the programs suite adds its programs (Programs::Run#added).
      def probe(fiasco, libc:)
        Generated.ensure(root: @root)
        native = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @machine.platform,
                                fiasco: fiasco)
        program = native.build_task_receipted(name: PROBE, sources: [*NativeRoot::PROGRAM, *PROBE_SOURCES],
                                              directory: File.join(@root, 'build/display-domain', PROBE),
                                              archives: [libc, CompilerRt.archive(root: @root, runner: @runner, compiler: @compiler)])
        codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
        ProductionImage::Added.new(entries: [ProductionImage.program_entry(PROBE, program, codec: codec)].freeze,
                                   inputs: program.fetch(:inputs), imports: {}.freeze)
      end

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
