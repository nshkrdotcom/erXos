# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest_edit'
require_relative '../../tools/lib/erx/platform'

# The edits harnesses make to a manifest (tools/lib/erx/manifest_edit.rb), over the
# manifest's own reader and its one printer (Manifest::Frontend.read and render), on the
# development manifest of QEMU virt.
class ManifestEditTest < Minitest::Test
  Edit = Erx::Manifest::Edit
  Frontend = Erx::Manifest::Frontend
  ROOT = File.expand_path('../..', __dir__)
  VIRT = Erx::Platform.development(ROOT)
  SOURCE = VIRT.manifest_source(ROOT)
  # The display unit's platform unit, of two devices with 4 and 3 bytes of DMA memory.
  UNITS = [{ 'key' => 'display', 'devices' => [{ 'dma_memory' => 4 }, { 'dma_memory' => 3 }] }].freeze

  # Each record of text by its first line, with what it holds: its properties and facet
  # parameters, each token as its value and whether it is quoted.
  def records(text)
    source = Frontend.read(text)
    [source.machine, *source.records.values.flatten].to_h do |record|
      tokens = ->(list) { list.map { |token| [token.value, token.quoted] } }
      [[record.kind, record.name || record.properties['targets']&.map(&:value)&.join(' ')],
       [record.properties.transform_values(&tokens), record.parameters.map(&tokens)]]
    end
  end

  def value(text, record, field) = Edit.value(text, record: record, field: field)

  # Every board's development manifest, printed, reads back to the same records.
  def test_the_printer_writes_what_the_reader_reads_back
    %w[qemu-virt raspi4b].each do |board|
      source = Erx::Platform.load(root: ROOT, name: board).manifest_source(ROOT)
      printed = Frontend.render(Frontend.read(source))
      assert_equal records(source), records(printed), board
      assert_equal printed, Frontend.render(Frontend.read(printed)), board
    end
    quoted = Erx::ABI::Token.new(value: "a \"b\" \\ \x01", quoted: true)
    assert_equal '"a \"b\" \\\\ \x01"', Frontend.send(:token_text, quoted)
  end

  # A field is reached through its record: the other records keep every field, and the
  # edited records every other one.
  def test_grow_and_set_edit_only_the_named_records_field
    grown = Edit.grow(SOURCE, { ['principal system', 'memory'] => 5, %w[machine root_memory] => -1 })
    set = Edit.set(grown, { %w[machine max_domains] => 7 })
    assert_equal value(SOURCE, 'principal system', 'memory') + 5, value(set, 'principal system', 'memory')
    assert_equal value(SOURCE, 'machine', 'root_memory') - 1, value(set, 'machine', 'root_memory')
    assert_equal 7, value(set, 'machine', 'max_domains')
    changed = records(SOURCE).reject { |key, held| records(set)[key] == held }.keys
    assert_equal [%w[machine], ['principal', 'system']], changed.map(&:compact).sort
    assert_equal 0, value(set, 'limits session', 'outer') - value(SOURCE, 'limits session', 'outer')
  end

  # A record or field that is not there, a value that is not a decimal number, and a
  # result below zero are refused, never applied somewhere else.
  def test_an_edit_that_has_no_one_place_is_refused
    root = value(SOURCE, 'machine', 'root_memory')
    { %w[machine absent] => 1, ['principal absent', 'memory'] => 1, %w[nothing root_memory] => 1,
      ['domain display', 'args'] => 1, ['unit display', 'placement'] => 1, %w[machine root_memory] => -root - 1 }
      .each do |field, number|
        assert_raises(Erx::Error, field.join(' ')) { Edit.grow(SOURCE, { field => number }) }
      end
    assert_raises(Erx::Error) { Edit.grow("#{SOURCE}machine\n  root_memory 1\n", { %w[machine root_memory] => 1 }) }
  end

  # A reference is pointed elsewhere only from the one it was: the network row's runtime,
  # and nothing else, changes; a row that no longer reads from is refused.
  def test_repoint_moves_one_reference_from_the_one_it_was
    jit = Edit.repoint(SOURCE, record: 'domain network', field: 'runtime', from: '@artifact.emu', to: '@artifact.jit')
    changed = records(SOURCE).reject { |key, held| records(jit)[key] == held }.keys
    assert_equal [%w[domain network]], changed
    assert_equal [['@artifact.jit', false]], records(jit).dig(%w[domain network], 0, 'runtime')
    [['domain network', 'runtime', '@artifact.emu'], ['domain network', 'absent', '@artifact.emu'],
     ['domain absent', 'runtime', '@artifact.emu'], ['unit display', 'placement', '"display"']].each do |record, field, from|
      assert_raises(Erx::Error, "#{record} #{field}") { Edit.repoint(jit, record: record, field: field, from: from, to: '@x.y') }
    end
  end

  # Named records are taken out and nothing else: no budget moves. A record that is not
  # there, one a record left in names, or the machine, which is never taken, is refused.
  def test_without_takes_only_the_named_records
    gone = Edit.without(SOURCE, ['facet network_ctl', 'service network_ctl'])
    assert_equal [%w[facet network_ctl], %w[service network_ctl]], (records(SOURCE).keys - records(gone).keys).sort
    assert_equal records(SOURCE).slice(*records(gone).keys), records(gone)
    error = assert_raises(Erx::Error) { Edit.without(SOURCE, ['service network_ctl']) }
    assert_match(/facet network_ctl names a record the edit takes out, @service.network_ctl/, error.message)
    assert_raises(Erx::Error) { Edit.without(SOURCE, ['service absent']) }
    assert_raises(Erx::Error) { Edit.without(SOURCE, ['machine']) }
  end

  # The session templates go with the facets granted to them, and nothing else does.
  def test_without_sessions_takes_the_templates_and_their_facets
    gone = Edit.without_sessions(SOURCE)
    taken = records(SOURCE).keys - records(gone).keys
    refute_empty taken
    assert_equal %w[facet session], taken.map(&:first).uniq.sort
    session_facets = Frontend.read(SOURCE).records.fetch('facet').select { |facet| facet.reference('grantee').start_with?('@session.') }
    assert_equal session_facets.map { |facet| ['facet', facet.name] }.sort, taken.select { |kind, _| kind == 'facet' }.sort
    assert_equal records(SOURCE).slice(*records(gone).keys), records(gone)
    error = assert_raises(Erx::Error) { Edit.without_sessions("#{SOURCE}start system\n  display @session.system\n") }
    assert_match(/start system names a record/, error.message)
  end

  # A part of a manifest, which is no manifest alone, is read record by record, each
  # pointing at its own file and line.
  def test_a_part_is_read_record_by_record
    part = File.binread(File.join(ROOT, VIRT.manifest_path))
    read = Frontend.records(part, path: VIRT.manifest_path)
    machine = read.find { |record| record.kind == 'machine' }
    assert_equal VIRT.manifest_path, machine.line.path
    assert_equal "machine\n", part.lines[machine.line.number - 1]
    assert_raises(Erx::Manifest::Invalid) { Frontend.read(part) }
    assert_raises(Erx::Error) { Frontend.records("facet f\n  grantee system\n", path: 'part.txt') }
  end

  # Taking the display domain out takes its records and those only it named, keeps the
  # share and runtime limits other records still name, and gives back its room: its
  # budgets from the principal and root_memory, its unit's DMA memory (4 and 3) from
  # root_memory, and one domain and one connection.
  def test_without_domain_takes_its_records_and_gives_back_its_room
    gone = Edit.without_domain(SOURCE, 'display', units: UNITS)
    taken = records(SOURCE).keys - records(gone).keys
    assert_equal [%w[display display], %w[domain display], %w[limits display], %w[runtime_limits display],
                  %w[service display], %w[share display], %w[unit display]], taken.sort
    budget = value(SOURCE, 'limits display', 'memory') + value(SOURCE, 'limits display', 'outer')
    { ['principal system', 'memory'] => -budget, ['principal system', 'domains'] => -1,
      %w[machine root_memory] => -budget - 7, %w[machine max_domains] => -1, %w[machine max_connections] => -1 }
      .each do |(record, field), change|
        assert_equal value(SOURCE, record, field) + change, value(gone, record, field), "#{record} #{field}"
      end
    kept = records(gone).reject { |key, _held| [%w[machine], %w[principal system]].include?(key.compact) }
    assert_equal records(SOURCE).slice(*kept.keys), kept
  end

  # The apps row taken out gives back its memory in root_memory, its max apps in
  # max_domains and, in max_connections, each app's system connection, its packages
  # connection and one for each service of the row, and nothing else changes; a
  # manifest with no apps row is returned as it is, and the site manifest carries none.
  def test_without_apps_takes_the_row_and_gives_back_its_room
    gone = Edit.without_apps(SOURCE)
    assert_equal [%w[apps]], records(SOURCE).keys.map(&:compact) - records(gone).keys.map(&:compact)
    apps = Frontend.read(SOURCE).records.fetch('apps').first
    max = apps.decimal('max')
    { 'root_memory' => -apps.decimal('memory'), 'max_domains' => -max,
      'max_connections' => -max * (2 + apps.properties.fetch('services').size) }.each do |field, change|
      assert_equal value(SOURCE, 'machine', field) + change, value(gone, 'machine', field), field
    end
    kept = records(gone).reject { |key, _held| key.compact == %w[machine] }
    assert_equal records(SOURCE).slice(*kept.keys), kept
    assert_equal gone, Edit.without_apps(gone)
    refute_match(/^apps$/, VIRT.site_manifest_source(ROOT))
  end

  # A share the machine names stays when the domain's limits name it too: the machine
  # is among the records that keep a definition in use.
  def test_without_domain_keeps_what_the_machine_names
    source = SOURCE.sub(/^(limits display\n(?:  .*\n)*?)  grant @share\.display\n/, "\\1  grant @share.system\n")
    refute_equal SOURCE, source
    assert_includes records(Edit.without_domain(source, 'display', units: UNITS)).keys, %w[share system]
  end

  # A domain that is not there, whose service is granted to a session or another domain,
  # which leaves a record naming one it took, or whose unit is on no platform unit, is
  # refused.
  def test_without_domain_refuses_what_it_cannot_take_whole
    [['absent', SOURCE, /no record "@domain.absent"/],
     ['web', SOURCE.sub("facet web\n  grantee system\n", "facet web\n  grantee @session.system\n"), /granted by facet web/],
     ['display', "#{SOURCE}start system\n  display @service.display\n", /start system names a record/],
     ['display', "#{SOURCE}introduce @domain.storage @domain.display\n",
      /introduce @domain.storage @domain.display names a record/],
     ['display', SOURCE.sub('placement "display"', 'placement "spare"'), /placed on "spare"/]].each do |name, source, message|
      error = assert_raises(Erx::Error) { Edit.without_domain(source, name, units: UNITS) }
      assert_match message, error.message
    end
  end
end
