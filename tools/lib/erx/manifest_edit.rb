# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'manifest'

module Erx
  module Manifest
    # How a harness changes a manifest: a number of a named record read, grown or set, a
    # reference pointed elsewhere, named records taken out (without), the session
    # templates taken out (without_sessions), or a configured domain taken out with the
    # records only it uses (without_domain). Each reads the text with the manifest's own
    # reader (Frontend.read), changes the records it read, and writes them with its one
    # printer (Frontend.render), so an edit reaches a field only through its record and
    # the result is a manifest the reader takes, but its comments are gone. A record is
    # named by its first line, "machine", "principal system" or "limits display"; one
    # that is not there, a field it does not have, or a value of another form than the
    # edit's is refused, and so is a removal that leaves a record naming one it took, so
    # an edit is never silently lost.
    module Edit
      module_function

      # text with each [record, field] of growth grown by its number; a negative number
      # shrinks it.
      def grow(text, growth) = Frontend.render(changed(Frontend.read(text), growth) { |value, added| value + added })

      # text with each [record, field] of values set to its number.
      def set(text, values) = Frontend.render(changed(Frontend.read(text), values) { |_value, given| given })

      # The number of field in the record named record.
      def value(text, record:, field:) = named(Frontend.read(text), record).decimal(field)

      # text with field of the record named record, which must be the one reference
      # from, made the reference to: an edit of a row that no longer reads from is
      # refused rather than applied to whatever it reads now.
      def repoint(text, record:, field:, from:, to:)
        source = Frontend.read(text)
        found = named(source, record)
        raise Error, "the manifest's #{record} #{field} is #{found.reference(field)}, not #{from}" unless
          found.reference(field) == from

        token = ABI::Token.new(value: to.dup.freeze, quoted: false).freeze
        Frontend.render(replaced(source, found, with_field(found, field, token)))
      end

      # text without the records records names, each by its first line ("domain network",
      # "unit net"); nothing else changes, so what they took of a budget stays counted.
      def without(text, records)
        source = Frontend.read(text)
        Frontend.render(removed(source, records.map { |name| named(source, name) }))
      end

      # text with no session template: every session record, and every facet granted to
      # one, which would name a template no longer there.
      def without_sessions(text)
        source = Frontend.read(text)
        sessions = source.records.fetch('session', [])
        facets = source.records.fetch('facet', []).select do |facet|
          sessions.any? { |session| facet.reference('grantee') == reference_of(session) }
        end
        Frontend.render(removed(source, sessions + facets))
      end

      # text without the configured domain called name, as if it had never been written in.
      #
      # Taken out: the domain's record; the units it holds; the services it serves, each
      # with its display record and the facets that grant it; and its limits, then the
      # share and runtime limits they name, each unless a record left in still names it
      # (limits first, so limits another domain keeps keep their share too).
      #
      # Given back, where the manifest reckons the room: the domain's principal loses its
      # limits' memory and outer budget and one domain of its quota; the machine loses the
      # same budgets and its units' DMA memory from root_memory (each a device's dma_memory
      # in units, the platform record's units, which the domain library charges to the
      # system's budget), one domain from max_domains, and the domain's system connection
      # from max_connections (which the manifest reckons in its comments, one per
      # configured domain).
      #
      # Refused: a domain that is not there; one whose service a session or another domain
      # is granted, since what such a grant takes of max_connections and its server's
      # connections is the manifest's own reckoning, in its comments; a removal that leaves
      # a record naming a record it took out (a facet granted to the domain, an
      # introduction, a start row on its display); and a unit placed on no unit of units.
      def without_domain(text, name, units:)
        source = Frontend.read(text)
        all = source.records.values.flatten
        domain = defined_by(all, "@domain.#{name}")
        principal = defined_by(all, domain.reference('principal'))
        limits = defined_by(all, domain.reference('limits'))
        held = all.select { |record| %w[unit service].include?(record.kind) && names?(record, reference_of(domain)) }
        services = held.select { |record| record.kind == 'service' }
        facets = all.select { |record| record.kind == 'facet' && services.any? { |service| names?(record, reference_of(service)) } }
        displays = all.select { |record| record.kind == 'display' && services.any? { |service| service.name == record.name } }
        foreign = facets.find { |facet| facet.reference('grantee') != 'system' }
        raise Error, "domain #{name}'s service is granted by facet #{foreign.name}, not to the system domain alone" if foreign

        definitions = [limits, defined_by(all, limits.reference('grant')), defined_by(all, limits.reference('runtime_limits'))]
        remaining = removed(source, with_unused_definitions([source.machine, *all], [domain, *held, *facets, *displays], definitions))

        budget = %w[memory outer].sum { |field| limits.decimal(field) }
        dma = held.select { |record| record.kind == 'unit' }.sum { |unit| unit_dma(unit, units) }
        changes = { [principal.header, 'memory'] => -budget, [principal.header, 'domains'] => -1,
                    %w[machine root_memory] => -(budget + dma), %w[machine max_domains] => -1,
                    %w[machine max_connections] => -1 }
        Frontend.render(changed(remaining, changes) { |value, added| value + added })
      end

      # source with each [record, field] of changes replaced by what the block returns for
      # the field's value and the change's number, changed in order.
      def changed(source, changes)
        changes.reduce(source) do |current, ((name, field), change)|
          record = named(current, name)
          result = yield record.decimal(field), change
          raise Error, "the manifest's #{name} #{field} would be #{result}" unless result.is_a?(Integer) && !result.negative?

          token = ABI::Token.new(value: result.to_s.freeze, quoted: false).freeze
          replaced(current, record, with_field(record, field, token))
        end
      end

      # record with field holding token alone.
      def with_field(record, field, token)
        Record.new(**record.to_h, properties: record.properties.merge(field => [token].freeze).freeze).freeze
      end

      # source with record, which it holds, replaced by replacement in its place.
      def replaced(source, record, replacement)
        return Source.new(**source.to_h, machine: replacement).freeze if record.equal?(source.machine)

        records = source.records.merge(record.kind => source.records.fetch(record.kind).map do |each|
          each.equal?(record) ? replacement : each
        end.freeze)
        Source.new(**source.to_h, records: records.freeze).freeze
      end

      # source without gone, records it holds, refused when a record left in names one of
      # them. The machine names records too (system_share, native_limits, ...), and is
      # never taken.
      def removed(source, gone)
        raise Error, "the manifest's machine record cannot be taken out" if gone.any? { |record| record.equal?(source.machine) }

        kept = source.records.values.flatten.reject { |record| gone.any? { |each| each.equal?(record) } }
        [source.machine, *kept].each do |record|
          taken = gone.find { |each| names?(record, reference_of(each)) }
          raise Error, "the manifest's #{record.header} names a record the edit takes out, #{reference_of(taken)}" if taken
        end
        Source.new(version: source.version, machine: source.machine,
                   records: kept.group_by(&:kind).transform_values(&:freeze).freeze).freeze
      end

      # The record of source whose first line is name ("machine", "principal system").
      def named(source, name)
        kind, alias_name = name.split(' ', 2)
        found = kind == 'machine' && alias_name.nil? ? source.machine : source.records.fetch(kind, []).find { |record| record.name == alias_name }
        found or raise Error, "the manifest has no #{name} record"
      end

      # The one record reference (@kind.name) names among records.
      def defined_by(records, reference)
        records.find { |record| reference_of(record) == reference } or
          raise Error, "the manifest has no record #{reference.inspect}"
      end

      # removed with each of definitions that no record outside removed still names.
      def with_unused_definitions(records, removed, definitions)
        definitions.reduce(removed) do |gone, definition|
          others = records.reject { |record| (gone + [definition]).any? { |each| each.equal?(record) } }
          others.any? { |record| names?(record, reference_of(definition)) } ? gone : gone + [definition]
        end
      end

      # How a record names this one in a field: @kind.name.
      def reference_of(record) = "@#{record.kind}.#{record.name}"

      # Whether one of record's unquoted tokens, a field's, a directive's or a facet
      # parameter's, is reference.
      def names?(record, reference)
        [*record.properties.values, *record.parameters].flatten.any? { |token| !token.quoted && token.value == reference }
      end

      # The DMA memory of the platform unit unit is placed on, in bytes.
      def unit_dma(unit, units)
        key = unit.string('placement')
        platform_unit = units.find { |row| row.is_a?(Hash) && row['key'] == key && row['devices'].is_a?(Array) } or
          raise Error, "the manifest's unit #{unit.name} is placed on #{key.inspect}, which the platform has no unit of"
        platform_unit.fetch('devices').sum do |device|
          bytes = device['dma_memory']
          raise Error, "the platform unit #{key}'s device has no whole dma_memory" unless bytes.is_a?(Integer) && !bytes.negative?

          bytes
        end
      end
      private_class_method :changed, :with_field, :replaced, :removed, :named, :defined_by, :with_unused_definitions,
                           :reference_of, :names?, :unit_dma
    end
  end
end
