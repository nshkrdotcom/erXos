# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'io/console'
require 'json'
require 'optparse'
require 'shellwords'
require_relative 'boot_record'
require_relative 'dev_key'
require_relative 'error'
require_relative 'fiasco'
require_relative 'json_input'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'

module Erx
  # `tools/erx boot`: builds the development boot image the QEMU harness boots
  # and runs it in QEMU with the guest's serial line on this terminal, so a
  # person can type at the Erlang shell. Reading the arguments, choosing the
  # accelerator and planning QEMU's argument vector are pure; building the
  # image and running QEMU are the effects at the edge.
  #
  # The image builds into one directory of the tree's build/, which each boot
  # replaces, so two boots of one tree at once would build over each other,
  # and the second would remove the first's host link socket.
  #
  # With --hostlink the guest also gets what the host tools need of it: its
  # host link's UART on a UNIX socket in an owner-only directory of build/,
  # where `tools/erx web`, `load` and `files` connect, and the image's release
  # medium as its disk, so the storage domain serves /data and root's session
  # has its data. The medium is written fresh with each build, so /data starts
  # empty at every boot.
  module InteractiveBoot
    DIRECTORY = 'build/production-image/interactive'
    # Where --without-web builds the website's image, apart from DIRECTORY, so a later
    # development boot never replaces the image tools/build_site.rb publishes.
    SITE_DIRECTORY = 'build/production-image/site'
    QUIT_HINT = 'quit QEMU with Ctrl-A then X'
    # How long QEMU has to exit after SIGTERM before it is killed.
    STOP_SECONDS = 10
    DEFAULT_JOBS = 4
    # The host link socket's directory, emptied and made owner-only at each boot.
    HOSTLINK_DIRECTORY = 'build/production-image/hostlink'
    # Where --medium leaves the bootable file it takes from the medium's committed slot.
    MEDIUM_DIRECTORY = 'build/production-image/medium-boot'
    # Where --medium keeps the copy of the medium the guest boots, owner-only. The guest
    # makes its SSH host key and keeps /data on the disk it boots, so it never boots the
    # medium given, which `make pack` wrote fresh and a person may publish.
    MEDIUM_COPY_DIRECTORY = 'build/production-image/medium-copy'
    MEDIUM_COPY_NAME = 'medium.img'
    # The unit medium_copy reads in and leaves a hole for when it is all zeros.
    COPY_BLOCK = 1 << 20
    # The medium a copy was made from, as the file system describes it: its file (device
    # and inode) and the times of its last write and status change, which a write in place
    # moves and no copying tool can set back. The copy is made again when the medium given
    # differs in any of them.
    MediumSource = Data.define(:dev, :ino, :size, :mtime_ns, :ctime_ns)
    # The copy a boot uses, and whether this boot made it, losing what the guest kept.
    MediumCopy = Data.define(:path, :fresh)
    # What booting a medium takes: its copy that the guest boots (medium_copy), the bootable
    # file of the copy's committed slot, and the device tree that names that slot.
    MediumBootFiles = Data.define(:disk, :fresh, :kernel, :dtb)
    # The host's loopback port forwarded to the guest's SSH port (DevKey::PORT) when a
    # person boots a medium: the same number, so `ssh -p 2222` reaches the guest.
    MEDIUM_SSH_PORT = DevKey::PORT

    # What the person asked for. A nil accel asks for this host's best. medium is the
    # absolute path of a release medium to boot instead of building an image, and print
    # asks for QEMU's command line instead of a boot.
    Request = Data.define(:accel, :cpus, :jobs, :hostlink, :without_web, :medium, :print)
    # The host link's socket and the medium the guest boots with, both absolute.
    Link = Data.define(:socket, :medium)
    # What a boot runs: the image's boot file, and its Link or nil.
    Boot = Data.define(:image, :link)

    module_function

    # The request the command-line arguments make. Raises OptionParser's
    # errors, which `tools/erx` reports as a usage error, before anything runs.
    def request(arguments)
      arguments = arguments.dup
      options = { accel: nil, cpus: 1, jobs: DEFAULT_JOBS, hostlink: false, without_web: false, medium: nil, print: false }
      OptionParser.new do |flags|
        flags.on('--accel NAME', %w[tcg hvf], 'Guest accelerator') { |value| options[:accel] = value }
        flags.on('--cpus N', Integer, 'Guest CPUs') { |value| options[:cpus] = value }
        flags.on('--jobs N', Integer, 'Build jobs') { |value| options[:jobs] = value }
        flags.on('--hostlink', 'Host link socket and data medium') { options[:hostlink] = true }
        flags.on('--without-web', 'Build the website\'s image, from its manifest without the web and display domains') { options[:without_web] = true }
        flags.on('--medium PATH', 'Boot this release medium (make pack PLATFORM=qemu-virt, or the website\'s) with a ' \
                                  'window, its keyboard and tablet, and SSH on host port 2222') do |path|
          options[:medium] = File.expand_path(path)
        end
        flags.on('--print', 'With --medium, print the qemu-system-aarch64 command line instead of running it') { options[:print] = true }
      end.parse!(arguments)
      raise OptionParser::InvalidArgument, 'unexpected arguments' unless arguments.empty?
      raise OptionParser::InvalidArgument, '--print goes with --medium' if options.fetch(:print) && !options.fetch(:medium)
      if options.fetch(:medium) && (options.fetch(:hostlink) || options.fetch(:without_web))
        raise OptionParser::InvalidArgument, '--medium boots a medium as it is, with no --hostlink or --without-web'
      end
      if options.fetch(:hostlink) && options.fetch(:without_web)
        raise OptionParser::InvalidArgument, '--without-web leaves out the web domain that --hostlink serves'
      end
      unless QemuPlan::CPUS.cover?(options.fetch(:cpus))
        raise OptionParser::InvalidArgument, "--cpus must be between #{QemuPlan::CPUS.min} and #{QemuPlan::CPUS.max}"
      end
      # Fiasco#build's own bound, checked here so a bad count is a usage error.
      raise OptionParser::InvalidArgument, '--jobs must be between 1 and 64' unless options.fetch(:jobs).between?(1, 64)

      Request.new(**options)
    end

    # HVF where this host's QEMU offers it, else TCG. available is the set
    # QemuGate.available_accelerators reads from `qemu-system-aarch64 -accel help`.
    def default_accel(available) = available.include?('hvf') ? 'hvf' : 'tcg'

    # QEMU's argument vector for platform's board: the harness's own plan, with
    # memory_mib of RAM (the machine the image was packed for, machine), the kernel
    # command line its boots of this image use, and the serial line on
    # this terminal in place of a file. With a link, the host link's UART
    # listens on its socket, without waiting for a client, and the medium is the
    # guest's disk; without one, the UART is QEMU's null device and there is no disk.
    def argv(platform:, accel:, cpus:, image:, memory_mib:, link: nil)
      QemuPlan.argv(platform: platform, accel: accel, cpus: cpus, image: image, serial: QemuPlan::CONSOLE,
                    memory_mib: memory_mib, command_line: ProductionImage::Run::COMMAND_LINES[accel],
                    hostlink: link&.socket, disks: link ? [QemuPlan::Disk.new(path: link.medium)] : [])
    end

    # QEMU's argument vector for a person booting a release medium (README, "Getting
    # started"): kernel, the bootable file of the medium's committed slot (medium_kernel),
    # where the firmware would load it; medium as the guest's disk; the display in QEMU's
    # window with its keyboard and tablet; user networking with the host's loopback port
    # MEDIUM_SSH_PORT forwarded to the guest's SSH port; and the serial line on this
    # terminal. tools/erx boot --medium runs it and --print prints it, so the documented
    # command is this one. dtb is the firmware's device tree that names the booted slot
    # (medium_boot), which QEMU, having no firmware, cannot make.
    def medium_argv(platform:, accel:, cpus:, kernel:, medium:, memory_mib:, dtb:)
      QemuPlan.argv(platform: platform, accel: accel, cpus: cpus, image: kernel, serial: QemuPlan::CONSOLE,
                    memory_mib: memory_mib, command_line: ProductionImage::Run::COMMAND_LINES[accel], dtb: dtb,
                    disks: [QemuPlan::Disk.new(path: medium)], display: QemuPlan::Display.window,
                    nic: QemuPlan::UserNet.new(forward: QemuPlan::Forward.new(host: MEDIUM_SSH_PORT, guest: DevKey::PORT)))
    end

    # What QEMU needs to boot medium as the firmware would (docs/design-platforms.md,
    # "Slots and the boot-selection record"): medium's copy (medium_copy), the bootable
    # file of the slot the slot parser chooses on it (BootRecord.read), and the device tree
    # whose /chosen/bootloader names that slot (MediumBoot.firmware_tree), the last two in
    # MEDIUM_DIRECTORY under root, replaced at each boot. Returns MediumBootFiles.
    def medium_boot(root:, runner:, medium:, machine:, cpus:)
      copy = medium_copy(root: root, medium: medium)
      directory = ProductionImage.clear_directory(root: root, path: File.join(root, MEDIUM_DIRECTORY))
      FileUtils.mkdir_p(directory)
      choice = BootRecord.read(copy.path)
      kernel = BootRecord.extract(copy.path, choice, output: File.join(directory, 'slot.boot'))
      dtb = MediumBoot.firmware_tree(runner: runner, qemu: 'qemu-system-aarch64', machine: machine, image: kernel,
                                     disks: [QemuPlan::Disk.new(path: copy.path)], choice: choice, cpus: cpus,
                                     directory: directory)
      MediumBootFiles.new(disk: copy.path, fresh: copy.fresh, kernel: kernel, dtb: dtb)
    end

    # The copy of medium a boot uses: MEDIUM_COPY_NAME in MEDIUM_COPY_DIRECTORY under root,
    # owner-only, since the guest keeps its private host key there. It is kept as the guest
    # left it while medium is the file it was made from (MediumSource, recorded beside it),
    # so the person's /data and host key last from boot to boot, which spares ssh a changed
    # host key at every boot; it is made again, sparse, when medium is another file or was
    # written since. The record exists only beside a whole copy: it is removed first and
    # written last, and the new copy is written under another name and renamed into place,
    # so an interrupted copy leaves no record and a guest still running keeps its own disk.
    # Returns MediumCopy.
    def medium_copy(root:, medium:)
      directory = owner_only_directory(root)
      copy = File.join(directory, MEDIUM_COPY_NAME)
      record = "#{copy}.source"
      source = medium_source(medium)
      raise Error, "#{medium} is the copy --medium boots; give the medium it was made from" if File.identical?(medium, copy)
      return MediumCopy.new(path: copy, fresh: false) if File.file?(copy) && recorded_source(record) == source

      FileUtils.rm_f(record)
      sparse_copy(medium, "#{copy}.new")
      File.rename("#{copy}.new", copy)
      File.write(record, "#{JSON.generate(source.to_h)}\n", perm: 0o600)
      MediumCopy.new(path: copy, fresh: true)
    rescue SystemCallError => error
      raise Error, "cannot copy the medium: #{error.message}"
    end

    # MEDIUM_COPY_DIRECTORY under root, made or put back to owner-only; its parents keep
    # the tree's own modes.
    def owner_only_directory(root)
      path = File.join(root, MEDIUM_COPY_DIRECTORY)
      OutputDirectory.prepare(root: root, path: File.dirname(path))
      directory = OutputDirectory.check(root: root, path: path)
      Dir.mkdir(directory, 0o700) unless File.directory?(directory)
      File.chmod(0o700, directory) # an existing directory keeps its mode otherwise
      directory
    end

    def medium_source(medium)
      stat = File.stat(medium)
      raise Error, "#{medium} is not a file" unless stat.file?

      MediumSource.new(dev: stat.dev, ino: stat.ino, size: stat.size, mtime_ns: nanoseconds(stat.mtime),
                       ctime_ns: nanoseconds(stat.ctime))
    rescue SystemCallError => error
      raise Error, "cannot read the medium: #{error.message}"
    end

    def nanoseconds(time) = (time.to_r * 1_000_000_000).to_i

    # The MediumSource recorded beside a copy, or nil when there is none or it does not parse.
    def recorded_source(record)
      fields = JsonInput.parse(File.binread(record), label: 'the medium copy record')
      fields.is_a?(Hash) ? MediumSource.new(**fields.transform_keys(&:to_sym)) : nil
    rescue Errno::ENOENT, Errno::EISDIR, Error, ArgumentError
      nil
    end

    # Copies from to a new owner-only file at to, removing any file an interrupted copy left
    # there, and leaves a hole wherever a block of from reads as zeros, as most of a medium does.
    def sparse_copy(from, to)
      zeros = "\0".b * COPY_BLOCK
      FileUtils.rm_f(to)
      File.open(from, 'rb') do |input|
        File.open(to, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW | File::BINARY, 0o600) do |output|
          output.chmod(0o600) # whatever the umask
          while (block = input.read(COPY_BLOCK))
            if block == zeros
              output.seek(block.bytesize, IO::SEEK_CUR)
            else
              output.write(block)
            end
          end
          output.truncate(input.size)
        end
      end
    end

    # The command a person runs in another terminal to see the guest's web
    # view; program is tools/erx's own path, so it runs from any directory.
    def web_command(program, socket) = Shellwords.join([program, 'web', '--socket', socket])

    # The directory under the tree's root an image builds into: SITE_DIRECTORY for the
    # website's image, else DIRECTORY.
    def image_directory(without_web:) = without_web ? SITE_DIRECTORY : DIRECTORY

    # Builds the kernel and the image into DIRECTORY under root, replacing the
    # image an earlier boot left there, and returns the path of its boot file.
    def build_image(root:, runner:, jobs:, platform:, **tools)
      build(root: root, runner: runner, jobs: jobs, hostlink: false, platform: platform, **tools).image
    end

    # The system manifest the image is built from: the website's manifest, which the
    # platform makes from its development manifest (Platform#site_manifest_source), when
    # without_web, else the development manifest as checked in for platform's board.
    def manifest_source(root:, platform:, without_web:)
      without_web ? platform.site_manifest_source(root) : platform.manifest_source(root)
    end

    # The machine the image is packed and checked on, and boots on: the website's
    # (Machine.site, the RAM the website gives its guest) when without_web, else the
    # development machine.
    def machine(platform:, without_web:)
      without_web ? ProductionImage::Machine.site(platform) : ProductionImage::Machine.development(platform)
    end

    # Builds the kernel and the image into its directory under root, replacing the
    # image an earlier boot left there. With hostlink, the image's release
    # medium is written beside it, and HOSTLINK_DIRECTORY under root is first
    # emptied of any socket an earlier boot left, made owner-only, and its
    # socket path checked, so a path QEMU cannot take fails before the build.
    # With without_web the image is the website's (manifest_source).
    def build(root:, runner:, jobs:, hostlink:, platform:, without_web: false, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
      socket = hostlink_socket(root) if hostlink
      fiasco = Fiasco.new(root: root, runner: runner, compiler: compiler)
      fiasco.build(jobs: jobs)
      directory = ProductionImage.clear_directory(root: root, path: File.join(root, image_directory(without_web: without_web)))
      image_builder = ProductionImage.new(root: root, runner: runner, compiler: compiler, linker: linker,
                                          machine: machine(platform: platform, without_web: without_web), fiasco: fiasco)
      source = manifest_source(root: root, platform: platform, without_web: without_web)
      # The website's image alone gets its build record, which tools/build_site.rb takes it only with.
      return Boot.new(image: image_builder.build(directory: directory, manifest_source: source, record: without_web).single, link: nil) unless socket

      built, written = image_builder.build_medium(directory: directory, manifest_source: source)
      Boot.new(image: built.single, link: Link.new(socket: socket, medium: written.path))
    end

    def hostlink_socket(root)
      directory = ProductionImage.clear_directory(root: root, path: File.join(root, HOSTLINK_DIRECTORY))
      socket = File.join(OutputDirectory.prepare(root: root, path: directory, mode: 0o700), 'socket')
      QemuPlan.hostlink_arguments(socket) # raises on a path QEMU cannot take
      socket
    end

    # Runs argv on this process's terminal until it exits, and returns its
    # exit status, 1 when a signal ended it. It has no deadline: the person
    # at the terminal decides when it ends.
    #
    # Whatever ends this process first (an interrupt, SIGTERM, SIGHUP) stops
    # the child before it propagates, and the terminal's mode is put back as
    # it was, whatever the child left it in. Signals reach this thread only
    # while it waits for the child; one that arrives during the spawn or the
    # cleanup waits until the cleanup is done, so a second signal cannot cut
    # the stop short. A child that ignores SIGTERM therefore holds this
    # process for up to stop_seconds. Only a signal this process cannot
    # handle (SIGKILL, for one) leaves the child running.
    def run(argv, stop_seconds: STOP_SECONDS)
      Thread.handle_interrupt(Object => :never) do
        saved_mode = $stdin.tty? ? $stdin.console_mode : nil
        # The [program, argv0] form never goes through a shell, whatever argv holds.
        pid = Process.spawn([argv.first, argv.first], *argv.drop(1), close_others: true)
        status = Thread.handle_interrupt(Object => :immediate) { Process.wait2(pid).last }
        pid = nil # reaped; nothing left to stop
        status.exitstatus || 1
      ensure
        stop(pid, seconds: stop_seconds) if pid
        restore_mode(saved_mode) if saved_mode
      end
    end

    # SIGTERM, which QEMU answers by restoring the terminal and exiting, then
    # SIGKILL if it has not exited within seconds. Reaps the child. Only a
    # child not yet reaped is signalled, so a reused pid never is.
    def stop(pid, seconds:)
      return if Process.wait(pid, Process::WNOHANG)

      Process.kill('TERM', pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until Process.wait(pid, Process::WNOHANG)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Process.kill('KILL', pid)
          Process.wait(pid)
          return
        end
        sleep(0.1)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # A terminal that hung up has no mode to restore; the failure must not
    # replace the signal that is ending this process.
    def restore_mode(mode)
      $stdin.console_mode = mode
    rescue SystemCallError
      nil
    end
    private_class_method :hostlink_socket, :stop, :restore_mode, :owner_only_directory, :medium_source, :nanoseconds, :recorded_source, :sparse_copy
  end
end
