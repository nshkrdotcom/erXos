# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'display_domain'
require_relative 'image_apps'
require_relative 'medium_boot'
require_relative 'screen_reference'

module Erx
  # The offline kiosk as an image package (docs/design-packaging.md, Verification): the
  # production image of the development machine, with the board's own manifest, carries
  # examples/dashboard packed as the Raspberry Pi 4's card packs it
  # (ImageApps.packed_kiosk), enabled, so the package lies at apps/dashboard.app of the
  # slot's system partition and its `package` row binds its header's SHA-256. The harness
  # plays the firmware (MediumBoot.firmware_tree, the dump carrying the boot's virtio-gpu
  # and input devices) and boots the medium with a display under HVF. Once the command
  # shell is up:
  #
  # * the storage domain served the system tree (SERVED), the system admitted the
  #   package (ADMITTED), the app's session mounted /app (MOUNTED), and the dashboard
  #   logged the minute of the first screen it showed (SHOWN);
  # * the screen read through QMP equals the dashboard as the host's erx-lvgl draws it
  #   with every quote's first round failed for OFFLINE_REASON (DashboardScreen) at
  #   that minute or the next, since the guest's clock is not pinned and a minute may turn before the screen is read.
  #
  # The seeded fault, the altered cell, flips a bit of the package header's root_hash, the
  # root of the image's hash tree, and binds the package row to the altered header's
  # SHA-256, so admission takes it as the image's own and the build's file check
  # (AppPack.describe) never sees it; the session's /app mount then refuses the image
  # (UNVERIFIED), no /app is mounted and the dashboard shows nothing.
  #
  # The quotes cell (docs/design-quotes.md, "The QEMU cell") boots the same package on a
  # test image whose trust store adds the root of an offline HTTPS fixture
  # (QuotesFixture, ProductionImage#build_medium's test roots), with a network device on
  # restricted user networking whose one guest forward, for erx_quotes_table's address
  # and port 443, relays each connection to the fixture (QemuPlan::Relay). The fixture
  # answers sol's first request with a body too big for erx_quotes, then every pair
  # with its price, so the serial line shows `quotes: sol no_data -- too_big`, a bound
  # only httpc's erXos edit gives on the target, then every quote fresh at the
  # fixture's price. Seeded: a store that trusts another root than the fixture's
  # (Run#call's trusted false) must show every quote `no_data -- certificate`.
  module Kiosk
    NAME = 'dashboard'
    SERVED = /erx_storage_system: serving the system tree/n
    ADMITTED = /packages: admitted dashboard\r?\n/n
    MOUNTED = /erx_app: mounted \/app/n
    SHOWN = /erx_dashboard: shown ([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2})\r?\n/n
    # The mount's refusal of an image whose first block does not match its root hash:
    # erx_verity answers eio for the reader's first read, which erx_erofs reports.
    UNVERIFIED = /erx_ns: image: erofs: blocks 0\+1 failed to read/n
    # How long the altered cell watches after the refusal for a mount or a screen.
    SETTLE_SECONDS = 15
    # Why each quote's first fetch fails in the kiosk boot, which has no network device,
    # so the dashboard shows that reason's words beside every quote: with no interface
    # the stack finds no path (erx_net_frame's enetunreach), which erx_quotes_http names
    # connect, `cannot connect`.
    OFFLINE_REASON = :connect
    ALTERED = '-altered'
    QUOTES = '-quotes'
    # The guest's virtual network, covering erx_quotes_table's address, which the guest
    # forward takes, and the port its URLs name.
    QUOTES_NETWORK = '104.16.0.0/16'
    QUOTES_ADDRESS = '104.16.14.28'
    QUOTES_PORT = 443
    # The fixture's answers: sol's first too big, every other its price.
    QUOTES_ANSWERS = { 'sol' => %i[too_big body] }.freeze
    QUOTES_TOO_BIG = 'quotes: sol no_data -- too_big'
    QUOTE_LINE = /quotes: [^\r\n]*/n
    # How long the harness waits after the command shell for every quote's lines: the
    # first round, sol's retry after its failure and the TLS handshakes of each.
    QUOTES_SECONDS = 240
    # The fixture's source, which writes the test root and so is its receipt's source.
    FIXTURE = 'test/fixtures/quotes_fixture.rb'
    # The minute Run#call draws before the boots, to build and compile the renderer.
    WARM_MINUTE = [[1970, 1, 1], [0, 0, 0]].freeze
    # How long the harness waits after the command shell for the dashboard's line, and
    # for the altered package's refusal.
    SHOWN_SECONDS = 120
    REFUSED_SECONDS = 60
    # The host's two drawings at the shell, each warm (Run#call draws once before the
    # boots, so the first boot's minute is not spent compiling the renderer).
    DRAW_SECONDS = 2 * 60

    module_function

    # The package at path with one bit of its header's root_hash flipped, written into
    # directory, as an ImageApps::Package whose sha256 is the altered header's.
    def altered(package, directory:)
      fields = AppPackage.codec.schema.types.fetch('erx_pkg_header').fields.to_h { |field| [field.name.to_s, field.offset] }
      bytes = File.binread(package.path).b
      header_length = bytes.byteslice(fields.fetch('header_length'), 4).unpack1('V')
      at = fields.fetch('root_hash')
      bytes.setbyte(at, bytes.getbyte(at) ^ 0x01)
      path = File.join(directory, File.basename(package.path))
      File.binwrite(path, bytes)
      ImageApps::Package.new(path: path, name: package.name, memory: package.memory, license: package.license,
                             sha256: Digest::SHA256.digest(bytes.byteslice(0, header_length)))
    end

    # The wall-clock minute the dashboard's SHOWN line names, last in log, as the
    # [[year, month, day], [hour, minute, 0]] DashboardScreen draws, and the minute after it.
    def shown_minutes(log)
      fields = log.scan(SHOWN).last
      raise Error, 'the dashboard logged no shown line' unless fields

      first = Time.utc(*fields.map { |field| Integer(field, 10) })
      [first, first + 60].map { |time| [[time.year, time.month, time.day], [time.hour, time.min, 0]] }
    end

    # The checks of the package's boot once the dashboard logged SHOWN, against the serial
    # log at serial: its lines, then the screen against the dashboard drawn at each minute
    # shown_minutes names, written as references into directory.
    def check_shown(serial:, socket:, directory:, draw:)
      log = DisplayDomain.await_log(serial, wait_seconds: SHOWN_SECONDS) { |text| text.match?(SHOWN) }
      { SERVED => 'the storage domain served no system tree', ADMITTED => 'the system did not admit the package',
        MOUNTED => "the app's session mounted no /app" }.each do |line, failure|
        raise Error, failure unless log.match?(line)
      end
      names = shown_minutes(log).each_with_index.map do |minute, index|
        "#{NAME}-#{index}".tap { |name| ScreenReference.write(directory, name, draw.call(minute)) }
      end
      DisplayDomain.await_screen(socket: socket, references: directory, names: names)
    end

    # The checks of the quotes cell's boot once the command shell is up: the serial log at
    # serial shows each of lines (QuotesFixture.fresh_lines and QUOTES_TOO_BIG) within
    # QUOTES_SECONDS; a failure names the lines missing and the last quotes lines seen.
    def check_quotes(serial:, lines:)
      log = DisplayDomain.await_log(serial, wait_seconds: QUOTES_SECONDS) { |text| lines.all? { |line| text.include?(line) } }
      missing = lines.reject { |line| log.include?(line) }
      return if missing.empty?

      raise Error, "the quotes showed no #{missing.join('; ')}; last: #{log.scan(QUOTE_LINE).last(6).join('; ')}"
    end

    # The checks of the altered package's boot: admitted by its row, refused at the mount,
    # and nothing of the app ran. An altered image mounted or shown is the failure the cell
    # exists for, a hash check that let a changed image through, and its message says so
    # whenever the log shows it, before any other.
    def check_altered(serial:)
      log = DisplayDomain.await_log(serial, wait_seconds: REFUSED_SECONDS) { |text| text.match?(UNVERIFIED) }
      if log.match?(UNVERIFIED)
        log = DisplayDomain.await_log(serial, wait_seconds: SETTLE_SECONDS) { |text| text.match?(MOUNTED) || text.match?(SHOWN) }
      end
      raise Error, "the altered image's hash check let it through: its session mounted /app" if log.match?(MOUNTED)
      raise Error, "the altered image's hash check let it through: it showed the dashboard" if log.match?(SHOWN)
      raise Error, 'the system did not admit the altered package by its row' unless log.match?(ADMITTED)
      raise Error, 'the altered image was not refused at its mount' unless log.match?(UNVERIFIED)
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = ProductionImage::Machine.development(platform)
        @manifest = platform.manifest_source(@root)
        @notes = []
      end

      # Why each failed cell failed.
      def notes = @notes.dup.freeze

      # Packs the package once (ImageApps.packed_kiosk), then an image of it and one of its
      # altered copy, and boots each at one CPU, the altered cell whatever the first found,
      # then the quotes cell. Returns { "hvf-1cpu" => 'passed', "hvf-1cpu-altered" =>
      # 'passed', "hvf-1cpu-quotes" => 'passed' }, a cell that failed 'failed' with its
      # reason in notes. trusted false seeds the quotes cell: its store trusts another root.
      def call(jobs: 4, build: true, trusted: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        work = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/kiosk'))
        kiosk_directory, altered_directory = %w[kiosk altered].map { |name| FileUtils.mkdir_p(File.join(work, name)).first }
        kiosk = ImageApps.packed_kiosk(kiosk_directory, root: @root, runner: @runner, compiler: @compiler)
        package = kiosk.package
        draw = drawing(app: kiosk.app, sdk: kiosk.sdk)
        draw.call(WARM_MINUTE)
        shown = { 'hvf-1cpu' => package, "hvf-1cpu#{ALTERED}" => Kiosk.altered(package, directory: altered_directory) }
                .to_h { |cell, packed| [cell, status(cell) { shown_boot(cell, packed, fiasco, work, draw: draw) }] }
        quotes = "hvf-1cpu#{QUOTES}"
        shown.merge(quotes => status(quotes) { quotes_boot(quotes, package, fiasco, work, trusted: trusted) })
      end

      private

      # 'passed' once the cell's block returns; 'failed' when it raises, its reason noted.
      def status(cell)
        yield
        'passed'
      rescue Error => e
        @notes << "#{cell}: #{e.message}"
        'failed'
      end

      # The dashboard's boot: its screen, or for the altered cell its refusal.
      def shown_boot(cell, package, fiasco, work, draw:)
        boot(cell, package, fiasco, work) do |serial, socket, directory|
          if cell.end_with?(ALTERED)
            Kiosk.check_altered(serial: serial)
          else
            Kiosk.check_shown(serial: serial, socket: socket, directory: directory, draw: draw)
          end
        end
      end

      # The quotes cell's boot against the fixture, its root in the image's store unless
      # trusted is false, when the store takes another root in its place. The fixture is
      # loaded here, when the cell runs, so loading the suite loads no test code.
      def quotes_boot(cell, package, fiasco, work, trusted:)
        require_relative File.join('../../..', FIXTURE)
        roots = FileUtils.mkdir_p(File.join(work, "#{cell}-roots")).first
        context = QuotesFixture.chain(File.join(roots, 'fixture.pem'))
        QuotesFixture.chain(File.join(roots, 'other.pem')) unless trusted
        server = QuotesFixture::Server.new(context: context, answers: QUOTES_ANSWERS)
        begin
          relay = QemuPlan::Relay.new(network: QUOTES_NETWORK, address: QUOTES_ADDRESS, port: QUOTES_PORT, relay_port: server.start.port)
          boot(cell, package, fiasco, work, test_roots: [TrustStore::TestRoot.new(path: File.join(roots, trusted ? 'fixture.pem' : 'other.pem'), source: File.join(@root, FIXTURE))],
                                            nic: relay) do |serial, _socket, _directory|
            Kiosk.check_quotes(serial: serial, lines: trusted ? [QUOTES_TOO_BIG, *QuotesFixture.fresh_lines] : QuotesFixture.refused_lines)
          end
        rescue Error => e
          raise Error, "#{e.message} (fixture requests: #{server.requests})"
        ensure
          server.stop
        end
      end

      # Boots package on the image's release medium at one CPU under HVF, with nic when
      # given and a trust store adding test_roots, and runs the block's checks at the
      # command shell with the serial log's path, the QMP socket and the cell's directory.
      def boot(cell, package, fiasco, work, test_roots: [], nic: nil, &check)
        directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(work, cell))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                             machine: @machine, fiasco: fiasco)
                                        .build_medium(directory: File.join(directory, 'image'),
                                                      apps: ImageApps.plan([package], enable: [NAME], signers: [], local: false),
                                                      test_roots: test_roots)
        medium = written.fresh(directory: directory)
        choice = BootRecord.read(medium)
        image = BootRecord.extract(medium, choice, output: File.join(directory, 'slot.boot'))
        socket = File.join(directory, 'qmp.sock')
        display = QemuPlan::Display.new(qmp_socket: socket)
        disks = [QemuPlan::Disk.new(path: medium)]
        tree = MediumBoot.firmware_tree(runner: @runner, qemu: @qemu, machine: @machine, image: image, disks: disks,
                                        display: display, choice: choice, cpus: 1, directory: directory)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: 'hvf', cpus: 1, image: image, memory_mib: @machine.memory_mib,
                 directory: File.join(directory, 'boot'), display: display, dtb: tree, disks: disks, nic: nic,
                 checkpoints: checkpoints(built, choice, test_image: !test_roots.empty?) { check.call(File.join(directory, 'boot', 'serial.log'), socket, directory) })
      end

      # The production checkpoints, a test image's when the cell asked for one, with the boot value's
      # after the image's identity, and the block's checks at the command shell.
      def checkpoints(built, choice, test_image:, &check)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: 1,
                                                  manifest_source: @manifest, memory_mib: @machine.memory_mib,
                                                  test_image: test_image)
        at = points.index { |point| point.fetch(:name) == 'image-identity' }
        raise Error, 'the production checkpoints name no image-identity' unless at
        raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

        shell = points.last
        waits = [SHOWN_SECONDS + DRAW_SECONDS + DisplayDomain::WAIT_SECONDS, REFUSED_SECONDS + SETTLE_SECONDS, QUOTES_SECONDS]
        [*points[0..at], MediumBoot.boot_value_checkpoint(choice), *points[(at + 1)...-1],
         shell.merge(seconds: shell.fetch(:seconds) + waits.max, verify: ->(_text) { check.call }).freeze]
      end

      # The dashboard at app as a function from a minute to the picture the host's
      # erx-lvgl draws of it over sdk, on the SDK's emulator (DashboardScreen). The fixture
      # is loaded here, when the cell runs, so loading the suite loads no test code.
      def drawing(app:, sdk:)
        require_relative '../../../test/fixtures/dashboard_screen'
        ->(minute) { DashboardScreen.picture(minute, app: app, sdk: sdk, runner: @runner, reason: OFFLINE_REASON) }
      end
    end
  end
end
