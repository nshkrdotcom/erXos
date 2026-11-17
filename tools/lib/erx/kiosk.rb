# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'display_domain'
require_relative 'image_apps'
require_relative 'medium_boot'
require_relative 'package_key'
require_relative 'screen_reference'

module Erx
  # The offline kiosk as an image package (docs/design-packaging.md, Verification): the
  # production image of the development machine, with the board's own manifest, carries
  # examples/dashboard packed and signed as `tools/erx pack --app examples/dashboard
  # --enable dashboard` packs it (the steps of ImageApps.packed_apps), so the package lies at
  # apps/dashboard.app of the slot's system partition and its `package` row binds its
  # header's SHA-256. The harness plays the firmware (MediumBoot.firmware_tree, the dump
  # carrying the boot's virtio-gpu and input devices) and boots the medium with a
  # display under HVF. Once the command shell is up:
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
  module Kiosk
    APP = 'examples/dashboard'
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
    # so the dashboard shows that reason's words beside every quote. httpc's error there
    # is a shape erx_quotes_http does not name, so it shows the catch-all, failed
    # (TODO.md, the dashboard's offline reason).
    OFFLINE_REASON = :failed
    ALTERED = '-altered'
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

      # Packs the package once, from a copy of APP in the build tree so the packer's ebin/
      # never lands in the source tree, then an image of it and one of its altered copy,
      # and boots each at one CPU, the altered cell whatever the first found. Returns
      # { "hvf-1cpu" => 'passed', "hvf-1cpu-altered" => 'passed' }, a cell that failed
      # 'failed' with its reason in notes.
      def call(jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        work = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/kiosk'))
        sdk_directory, packages, altered_directory = %w[app-sdk app-packages altered].map { |name| FileUtils.mkdir_p(File.join(work, name)).first }
        app = File.join(work, 'app')
        FileUtils.cp_r(File.join(@root, APP), app)
        sdk = ImageApps.exported_sdk(sdk_directory, root: @root, runner: @runner)
        package, = ImageApps.gather([app], into: packages, sdk: sdk, signer: PackageKey.ensure, runner: @runner, root: @root,
                                           compiler: @compiler)
        draw = drawing(app: app, sdk: sdk)
        draw.call(WARM_MINUTE)
        { 'hvf-1cpu' => package, "hvf-1cpu#{ALTERED}" => Kiosk.altered(package, directory: altered_directory) }
          .to_h { |cell, packed| [cell, status(cell) { boot(cell, packed, fiasco, work, draw: draw) }] }
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

      def boot(cell, package, fiasco, work, draw:)
        directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(work, cell))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                             machine: @machine, fiasco: fiasco)
                                        .build_medium(directory: File.join(directory, 'image'),
                                                      apps: ImageApps.plan([package], enable: [NAME], signers: [], local: false))
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
                 directory: File.join(directory, 'boot'), display: display, dtb: tree, disks: disks,
                 checkpoints: checkpoints(built, cell, choice, socket: socket, directory: directory, draw: draw))
      end

      # The production checkpoints with the boot value's after the image's identity, and
      # the cell's checks at the command shell.
      def checkpoints(built, cell, choice, socket:, directory:, draw:)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: 1,
                                                  manifest_source: @manifest, memory_mib: @machine.memory_mib)
        at = points.index { |point| point.fetch(:name) == 'image-identity' }
        raise Error, 'the production checkpoints name no image-identity' unless at
        raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

        serial = File.join(directory, 'boot', 'serial.log')
        check = if cell.end_with?(ALTERED)
                  ->(_text) { Kiosk.check_altered(serial: serial) }
                else
                  ->(_text) { Kiosk.check_shown(serial: serial, socket: socket, directory: directory, draw: draw) }
                end
        shell = points.last
        [*points[0..at], MediumBoot.boot_value_checkpoint(choice), *points[(at + 1)...-1],
         shell.merge(seconds: shell.fetch(:seconds) + [SHOWN_SECONDS + DRAW_SECONDS + DisplayDomain::WAIT_SECONDS, REFUSED_SECONDS + SETTLE_SECONDS].max, verify: check).freeze]
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
