# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'socket'
require 'tmpdir'
require_relative '../../tools/lib/erx/pcie_domain'

# The pcie suite's harness (tools/lib/erx/pcie_domain.rb): QEMU's plan with PCIe functions
# and QMP, the QMP reader's query-pci against a scripted peer, and each case's check of the
# guest's answer against QMP's functions.
class PcieDomainTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  PCIE = Erx::QemuPlan::Pcie
  # QEMU 11.1.3's query-pci of QEMU virt with qemu-xhci at slot 2, once its BAR 0 is
  # decoding at 0x10000000: the host bridge's function, then the xHCI controller's.
  QUERY_PCI = [{ 'bus' => 0, 'devices' => [
    { 'bus' => 0, 'slot' => 0, 'function' => 0, 'irq_pin' => 0, 'qdev_id' => '', 'regions' => [],
      'id' => { 'device' => 8, 'vendor' => 6966, 'subsystem' => 4352, 'subsystem-vendor' => 6900 } },
    { 'bus' => 0, 'slot' => 2, 'function' => 0, 'irq_pin' => 1, 'irq' => 0, 'qdev_id' => '',
      'id' => { 'device' => 13, 'vendor' => 6966, 'subsystem' => 4352, 'subsystem-vendor' => 6900 },
      'regions' => [{ 'bar' => 0, 'type' => 'memory', 'address' => 0x1000_0000, 'size' => 16_384,
                      'prefetch' => false, 'mem_type_64' => true }] }
  ] }].freeze
  WALK = '{pcie_walk,[true],[ok],[{0,0,0,6966,8,ready,[]},{0,2,0,6966,13,ready,[{0,268435456,16384}]}]}'

  def setup
    @directory = Dir.mktmpdir('erx-pcie-')
    File.chmod(0o700, @directory)
    @socket = File.join(@directory, 'q.sock')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def plan(**options) = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial', **options)

  # The plan attaches each function at its slot of the host bridge's bus, with QMP.
  def test_pcie_functions_are_attached_at_their_slots_with_qmp
    argv = plan(pcie: PCIE.new(qmp_socket: @socket, functions: { 2 => 'qemu-xhci' }))
    assert_equal plan, argv - ['-device', 'qemu-xhci,addr=2,id=pcie2', '-qmp', "unix:#{@socket},server=on,wait=off"]
    assert_includes argv.each_cons(2).to_a, ['-device', 'qemu-xhci,addr=2,id=pcie2']
  end

  def test_a_slot_or_device_outside_the_allowed_and_a_display_beside_them_are_refused
    [{ 0 => 'qemu-xhci' }, { 32 => 'qemu-xhci' }, { 2 => 'qemu-xhci,romfile=/etc/passwd' }, {}].each do |functions|
      assert_raises(Erx::Error) { PCIE.new(qmp_socket: @socket, functions: functions) }
    end
    assert_raises(Erx::Error) { PCIE.new(qmp_socket: "#{@socket},x", functions: { 2 => 'qemu-xhci' }) }
    pcie = PCIE.new(qmp_socket: @socket, functions: { 2 => 'qemu-xhci' })
    error = assert_raises(Erx::Error) { plan(pcie: pcie, display: Erx::QemuPlan::Display.new(qmp_socket: @socket)) }
    assert_match(/not both/, error.message)
  end

  # A scripted QMP peer that greets, takes the capabilities command, and answers the next
  # command with answer.
  def serve(answer)
    server = UNIXServer.new(@socket)
    thread = Thread.new do
      connection = server.accept
      connection.write(%({"QMP": {"version": {}, "capabilities": []}}\n))
      request = JSON.parse(connection.gets)
      connection.write(%({"return": {}, "id": #{request['id']}}\n))
      request = JSON.parse(connection.gets)
      connection.write(%({"return": #{JSON.generate(answer)}, "id": #{request['id']}}\n))
      connection.close
    end
    yield Erx::Qmp.connect(@socket, timeout: 2)
  ensure
    thread&.join(5)
    server&.close
    File.unlink(@socket) if File.socket?(@socket)
  end

  def test_query_pci_reads_each_function_and_an_unmapped_region_as_no_address
    unmapped = JSON.parse(JSON.generate(QUERY_PCI))
    unmapped[0]['devices'][1]['regions'][0]['address'] = -1
    functions = serve(unmapped) { |client| client.pci_functions }
    assert_equal [[0, 0, 0, 6966, 8], [0, 2, 0, 6966, 13]], functions.map { |f| [f.bus, f.slot, f.function, f.vendor, f.device] }
    assert_equal [Erx::Qmp::PciRegion.new(bar: 0, type: :memory, address: nil, size: 16_384)], functions[1].regions
  end

  def test_a_malformed_query_pci_answer_is_a_protocol_error
    bad_device = JSON.parse(JSON.generate(QUERY_PCI)).tap { |answer| answer[0]['devices'][1]['slot'] = 32 }
    bad_region = JSON.parse(JSON.generate(QUERY_PCI)).tap { |answer| answer[0]['devices'][1]['regions'][0]['type'] = 'rom' }
    [{ 'not' => 'a list' }, [{ 'bus' => 0 }], bad_device, bad_region].each do |answer|
      assert_raises(Erx::Qmp::ProtocolError) { serve(answer) { |client| client.pci_functions } }
    end
  end

  def functions = serve(QUERY_PCI) { |client| client.pci_functions }

  def test_the_walk_case_passes_on_qmp_s_functions_and_fails_on_a_bar_a_page_off
    qmp = functions
    assert_equal WALK, Erx::PcieDomain.walk_answer(qmp)
    Erx::PcieDomain.check_walk("(system@erxos)3> #{WALK}\r\n", functions: qmp)
    off = WALK.sub('268435456', (0x1000_0000 + 4096).to_s)
    error = assert_raises(Erx::Error) { Erx::PcieDomain.check_walk("#{off}\r\n", functions: qmp) }
    assert_match(/QMP's functions give/, error.message)
    assert_raises(Erx::Error) { Erx::PcieDomain.check_walk(WALK.sub('[ok]', '[{error,unavailable}]'), functions: qmp) }
  end

  def test_the_hold_case_wants_one_usb_record_of_bar_0_s_size
    qmp = functions
    xhci = Erx::PcieDomain.xhci(PLATFORM)
    Erx::PcieDomain.check_hold('4> {pcie_hold,[{"usb","xhci",16384}]}', functions: qmp, xhci: xhci)
    ['{pcie_hold,[]}', '{pcie_hold,[{"usb","xhci",4096}]}', '{pcie_hold,{error,{erpc,noconnection}}}',
     '{pcie_hold,[{"usb","xhci",16384},{"usb","xhci",16384}]}'].each do |line|
      assert_raises(Erx::Error) { Erx::PcieDomain.check_hold(line, functions: qmp, xhci: xhci) }
    end
  end

  def test_the_memory_note_names_the_pages_at_rest_or_what_came
    assert_equal "the PCIe domain's memory at rest: 4608 pool pages, 18.0 MiB",
                 Erx::PcieDomain.memory_note('5> {pcie_memory,{ended,20000,15392}}')
    assert_match(/not measured/, Erx::PcieDomain.memory_note('{pcie_memory,{timeout,20000,19000}}'))
  end
end
