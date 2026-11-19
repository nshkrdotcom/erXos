# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'set'
require 'tmpdir'
require_relative '../../tools/lib/erx/interactive_boot'

# The pure half of `tools/erx boot` (its arguments, the accelerator it picks
# and the QEMU argument vector it plans) and the child handling of its run,
# with a Ruby child standing in for QEMU. Nothing here boots a guest.
class InteractiveBootTest < Minitest::Test
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))

  def test_no_arguments_ask_for_one_cpu_and_this_hosts_accelerator
    assert_equal Erx::InteractiveBoot::Request.new(accel: nil, cpus: 1, jobs: Erx::InteractiveBoot::DEFAULT_JOBS,
                                                    hostlink: false, without_web: false, medium: nil, print: false),
                 Erx::InteractiveBoot.request([])
  end

  def test_options_name_the_accelerator_cpus_and_jobs
    assert_equal Erx::InteractiveBoot::Request.new(accel: 'tcg', cpus: 4, jobs: 2, hostlink: false, without_web: false,
                                                    medium: nil, print: false),
                 Erx::InteractiveBoot.request(%w[--accel tcg --cpus 4 --jobs 2])
  end

  def test_bad_arguments_are_refused_as_usage_errors
    [%w[--cpus 0], %w[--cpus 9], %w[--cpus -1], %w[--cpus two], %w[--accel kvm], %w[--accel], %w[extra],
     %w[--memory-mib 512], %w[--jobs 0], %w[--jobs 65], %w[--print], %w[--medium m.img --hostlink],
     %w[--medium m.img --without-web], %w[--medium]].each do |arguments|
      assert_raises(OptionParser::ParseError, arguments.join(' ')) { Erx::InteractiveBoot.request(arguments) }
    end
  end

  def test_the_request_leaves_the_callers_arguments_alone
    arguments = %w[--cpus 2].freeze
    Erx::InteractiveBoot.request(arguments)
    assert_equal %w[--cpus 2], arguments
  end

  def test_medium_names_an_absolute_medium_and_print_asks_for_the_command
    request = Erx::InteractiveBoot.request(%w[--medium medium.img --print])
    assert_equal File.expand_path('medium.img'), request.medium
    assert request.print
  end

  # The command a person boots a release medium with, which the README documents through
  # --print: the medium's slot file as the kernel, the medium as a virtio disk, QEMU's
  # window with the virtio GPU, keyboard and tablet, user networking that reaches the host's
  # network with host loopback port 2222 forwarded to the guest's SSH port, and the serial
  # line on this terminal.
  def test_a_medium_boots_with_a_window_its_input_devices_and_ssh_forwarded
    argv = Erx::InteractiveBoot.medium_argv(platform: PLATFORM, accel: 'hvf', cpus: 1, kernel: '/tree/slot.boot',
                                            medium: '/tree/medium.img', memory_mib: 1024, dtb: '/tree/firmware.dtb')
    assert_equal '/tree/slot.boot', argv.fetch(argv.index('-kernel') + 1)
    assert_includes argv, 'file=/tree/medium.img,format=raw,if=none,id=disk0'
    assert_equal 'default', argv.fetch(argv.index('-display') + 1), 'QEMU shows its window'
    refute_includes argv, '-qmp'
    devices = argv.each_index.select { |at| argv[at] == '-device' }.map { |at| argv[at + 1].split(',').first }
    %w[virtio-gpu-device virtio-keyboard-device virtio-tablet-device virtio-net-device virtio-blk-device].each do |device|
      assert_includes devices, device
    end
    assert_equal ['user,id=nic_user,hostfwd=tcp:127.0.0.1:2222-:2222'],
                 argv.each_index.select { |at| argv[at] == '-netdev' }.map { |at| argv[at + 1] },
                 'one unrestricted user network with the SSH forward'
    assert_includes argv, 'virtio-net-device,netdev=nic_user,bus=virtio-mmio-bus.23'
    assert_equal 'mon:stdio', argv.fetch(argv.index('-serial') + 1)
    assert_equal '1024', argv.fetch(argv.index('-m') + 1)
    assert_equal '/tree/firmware.dtb', argv.fetch(argv.index('-dtb') + 1), 'the firmware tree names the booted slot'
  end

  def test_hvf_is_the_default_where_qemu_offers_it
    assert_equal 'hvf', Erx::InteractiveBoot.default_accel(Set['hvf', 'tcg'])
    assert_equal 'tcg', Erx::InteractiveBoot.default_accel(Set['tcg'])
    assert_equal 'tcg', Erx::InteractiveBoot.default_accel(Set[])
  end

  def test_qemu_runs_on_this_terminal_with_its_monitor_muxed_and_never_reboots
    argv = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'hvf', cpus: 2, image: '/tree/build/image.boot', memory_mib: 512)
    assert_equal 'qemu-system-aarch64', argv.first
    assert_equal 'mon:stdio', argv.fetch(argv.index('-serial') + 1)
    # The console is the first serial line; the second, the host link's UART, is QEMU's null device.
    assert_equal %w[mon:stdio null], argv.each_index.select { |at| argv[at] == '-serial' }.map { |at| argv[at + 1] }
    assert_includes argv, '-no-reboot'
    assert_equal '/tree/build/image.boot', argv.fetch(argv.index('-kernel') + 1)
    assert_equal '2', argv.fetch(argv.index('-smp') + 1)
    assert_equal '512', argv.fetch(argv.index('-m') + 1)
    refute(argv.any? { |word| word.start_with?('file:') })
  end

  # The harness's line, after the word that asks for the host link the plan gives the guest.
  def test_each_accelerator_gets_the_harness_kernel_command_line
    tcg = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'tcg', cpus: 1, image: 'image.boot', memory_mib: 512)
    hvf = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'hvf', cpus: 1, image: 'image.boot', memory_mib: 512)
    word = Erx::QemuPlan::HOSTLINK_WORD
    assert_equal ['-append', "#{word} #{Erx::ProductionImage::Run::COMMAND_LINES.fetch('tcg')}"], tcg.last(2)
    assert_equal ['-append', word], hvf.last(2)
  end

  def test_hostlink_asks_for_the_host_link_and_a_data_medium
    refute Erx::InteractiveBoot.request([]).hostlink
    assert Erx::InteractiveBoot.request(%w[--hostlink]).hostlink
    assert_raises(OptionParser::ParseError) { Erx::InteractiveBoot.request(%w[--hostlink /tmp/socket]) }
  end

  # --without-web builds the website's image from the site manifest the platform makes
  # from the development manifest, so the image's manifest check runs over what the site ships, into a
  # directory of its own, which a development boot never replaces; without the option
  # the image is the development manifest's. It cannot be combined with --hostlink,
  # whose web view the web domain serves.
  def test_without_web_builds_from_the_site_manifest
    root = File.expand_path('../..', __dir__)
    refute Erx::InteractiveBoot.request([]).without_web
    assert Erx::InteractiveBoot.request(%w[--without-web]).without_web
    assert_raises(OptionParser::ParseError) { Erx::InteractiveBoot.request(%w[--without-web --hostlink]) }
    assert_equal PLATFORM.manifest_source(root),
                 Erx::InteractiveBoot.manifest_source(root: root, platform: PLATFORM, without_web: false)
    # The website's image is the site manifest with the website's machine's boot timeout.
    site = Erx::InteractiveBoot.manifest_source(root: root, platform: PLATFORM, without_web: true)
    assert_equal Erx::ProductionImage::Machine.site(PLATFORM).boot_timeout_s,
                 Erx::Manifest::Edit.value(site, record: 'machine', field: 'boot_timeout_s')
    assert_equal Erx::Manifest::Frontend.render(Erx::Manifest::Frontend.read(PLATFORM.site_manifest_source(root))),
                 site.sub("  boot_timeout_s #{Erx::ProductionImage::Machine.site(PLATFORM).boot_timeout_s}\n", '')
    assert_equal Erx::InteractiveBoot::DIRECTORY, Erx::InteractiveBoot.image_directory(without_web: false)
    assert_equal 'build/production-image/site', Erx::InteractiveBoot.image_directory(without_web: true)
    # The website's image is packed for, and boots on, the RAM the website gives it.
    assert_equal 256, Erx::InteractiveBoot.machine(platform: PLATFORM, without_web: true).memory_mib
    # Any other is packed for, and boots on, the machine of the board's own manifest.
    assert_equal Erx::ProductionImage::Machine.board(PLATFORM), Erx::InteractiveBoot.machine(platform: PLATFORM, without_web: false)
  end

  # With a link, the second serial line listens on its socket without waiting
  # for a client, and the medium is the guest's one disk; the console stays on
  # this terminal.
  def test_a_link_puts_the_host_link_on_its_socket_and_attaches_the_medium
    link = Erx::InteractiveBoot::Link.new(socket: '/tree/build/link/socket', medium: '/tree/build/medium.img')
    argv = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'hvf', cpus: 1, image: '/tree/build/image.boot', memory_mib: 512, link: link)
    assert_equal ['mon:stdio', 'unix:/tree/build/link/socket,server=on,wait=off'],
                 argv.each_index.select { |at| argv[at] == '-serial' }.map { |at| argv[at + 1] }
    drives = argv.each_index.select { |at| argv[at] == '-drive' }.map { |at| argv[at + 1] }
    assert_equal ['file=/tree/build/medium.img,format=raw,if=none,id=disk0'], drives
    assert_includes argv, '-no-reboot'
  end

  def test_the_web_command_names_the_socket_as_one_shell_word
    assert_equal '/tree/tools/erx web --socket /tree/build/link/socket',
                 Erx::InteractiveBoot.web_command('/tree/tools/erx', '/tree/build/link/socket')
    assert_equal '/my\\ tree/tools/erx web --socket /my\\ tree/socket',
                 Erx::InteractiveBoot.web_command('/my tree/tools/erx', '/my tree/socket')
  end

  # The guest writes its private host key and /data into the disk it boots, so a boot of
  # a medium a person may publish must leave that file as pack wrote it: the boot takes an
  # owner-only sparse copy under build/, keeps it, guest writes included, while the medium
  # is unchanged, and copies again once the medium is written in place, its times put
  # back, or another one is given, without touching the disk a running guest holds.
  def test_a_medium_boots_from_a_kept_copy_and_is_never_written
    Dir.mktmpdir('erx-medium-copy-') do |root|
      FileUtils.mkdir_p(File.join(root, Erx::InteractiveBoot::MEDIUM_COPY_DIRECTORY), mode: 0o755)
      medium = File.join(root, 'medium.img')
      File.binwrite(medium, 'boot'.b + ("\0".b * (40 << 20)) + 'data'.b + ("\0".b * (40 << 20)))
      written = File.binread(medium)

      first = Erx::InteractiveBoot.medium_copy(root: root, medium: medium)
      copy = first.path
      assert first.fresh
      assert_equal File.join(File.realpath(root), Erx::InteractiveBoot::MEDIUM_COPY_DIRECTORY, 'medium.img'), copy
      assert_equal written, File.binread(copy), 'a trailing hole keeps the medium\'s length'
      assert_equal 0o600, File.stat(copy).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(copy)).mode & 0o777
      # APFS leaves a hole only for a gap of tens of MiB; a medium's are hundreds.
      assert_operator File.stat(copy).blocks * 512, :<, 8 << 20, 'the zero blocks are holes'

      File.open(copy, 'r+b') { |disk| disk.pwrite('host key', 1 << 20) } # the guest's first boot
      assert_equal Erx::InteractiveBoot::MediumCopy.new(path: copy, fresh: false),
                   Erx::InteractiveBoot.medium_copy(root: root, medium: medium)
      assert_equal 'host key', File.binread(copy, 8, 1 << 20), 'a second boot keeps the guest\'s writes'
      assert_equal written, File.binread(medium)

      kept = File.stat(medium)
      File.open(medium, 'r+b') { |disk| disk.pwrite('new!', 0) } # written in place, times put back
      File.utime(kept.atime, kept.mtime, medium)
      File.open(copy, 'rb') do |running| # a guest still booted from the kept copy
        assert Erx::InteractiveBoot.medium_copy(root: root, medium: medium).fresh
        assert_equal 'host key', running.pread(8, 1 << 20), 'the running guest keeps its disk'
      end
      assert_equal File.binread(medium), File.binread(copy)

      error = assert_raises(Erx::Error) { Erx::InteractiveBoot.medium_copy(root: root, medium: copy) }
      assert_match(/is the copy --medium boots/, error.message)
    end
  end

  def test_run_returns_the_childs_exit_status
    assert_equal 3, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'exit 3'])
    assert_equal 0, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'exit 0'])
  end

  def test_a_child_ended_by_a_signal_is_a_failure
    assert_equal 1, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'Process.kill("KILL", Process.pid)'])
  end

  # An interrupt that reaches tools/erx while QEMU runs must not leave QEMU
  # running: the child writes its pid, the test interrupts the waiting run,
  # and afterwards no process has that pid.
  def test_an_interrupt_stops_the_child_before_it_propagates
    pid = interrupted_child(body: 'sleep 60', interrupts: 1)
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  # A child that ignores SIGTERM, interrupted twice: the second interrupt
  # waits for the cleanup, which kills the child once its time is up.
  def test_a_second_interrupt_cannot_cut_the_stop_short
    pid = interrupted_child(body: 'trap("TERM") {}; sleep 60', interrupts: 2)
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  private

  # Runs a Ruby child with body under InteractiveBoot.run, raises Interrupt
  # in this thread interrupts times once the child has written its pid,
  # checks the interrupt propagated, and returns the child's pid.
  def interrupted_child(body:, interrupts:)
    Dir.mktmpdir('erx-interactive-boot-') do |directory|
      pid_file = File.join(directory, 'pid')
      child = [RbConfig.ruby, '-e', "File.write(ARGV.fetch(0), Process.pid.to_s); #{body}", pid_file]
      waiter = Thread.new(Thread.current) do |main|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        sleep(0.05) until File.size?(pid_file) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep(0.2) # the trap, where there is one, is set right after the write
        interrupts.times do
          main.raise(Interrupt)
          sleep(0.2)
        end
      end
      begin
        assert_raises(Interrupt) { Erx::InteractiveBoot.run(child, stop_seconds: 1) }
      ensure
        waiter.join(35) || waiter.kill
      end
      pid = Integer(File.read(pid_file))
      # A regressed stop leaves the child running: the caller's assertion
      # fails, and the child still does not outlive the test.
      begin
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end
      return pid
    end
  end
end
