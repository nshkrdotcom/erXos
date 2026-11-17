# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'abi_binary'
require_relative 'build_kind'
require_relative 'device_kinds'
require_relative 'generated_abi'
require_relative 'manifest_frontend'
require_relative 'domain_startup'

module Erx
  module Manifest
    class Unsupported < Invalid; end

    module Snapshot
      module_function

      def copy(value, depth: 0)
        raise Invalid.new('context nesting exceeds 64', property: 'context', field: 'input') if depth > 64
        case value
        when Hash
          unless value.keys.all? { |key| key.is_a?(String) }
            raise Invalid.new('context keys must be strings', property: 'context', field: 'input')
          end
          value.sort_by { |key, _item| key.b }.to_h do |key, item|
            [key.dup.freeze, copy(item, depth: depth + 1)]
          end.freeze
        when Array
          value.map { |item| copy(item, depth: depth + 1) }.freeze
        when String
          value.dup.freeze
        when Integer, TrueClass, FalseClass, NilClass
          value
        else
          raise Invalid.new('context contains an unsupported value', property: 'context', field: 'input')
        end
      end

      # Length framing preserves arbitrary original notice/path bytes without
      # treating a binary notice as JSON text or relying on hash insertion order.
      def digest(value)
        hash = Digest::SHA256.new
        append(hash, value)
        hash.hexdigest.freeze
      end

      def append(hash, value)
        case value
        when Hash
          hash << "h#{value.size}:"
          value.sort_by { |key, _item| key.b }.each do |key, item|
            append(hash, key)
            append(hash, item)
          end
        when Array
          hash << "a#{value.size}:"
          value.each { |item| append(hash, item) }
        when String
          hash << "s#{value.bytesize}:" << value.b
        when Integer
          hash << "i#{value};"
        when TrueClass then hash << 't'
        when FalseClass then hash << 'f'
        when NilClass then hash << 'n'
        end
      end
    end

    # Context is supplied by the build's checked artifact/platform boundaries,
    # never read from configuration text. Its catalog includes the reserved
    # manifest and NOTICES rows before any numeric entry index is assigned. Its
    # device_kinds are the rows of erx/device_kinds.h's two tables, each a hash of role,
    # compatible, role_word, peripheral and clocked (DeviceKinds.context_rows). Its
    # development_key is the public half of the builder's development package key, or
    # nil: never a manifest row, so no board source can name it, and the check admits it
    # only in a development build (docs/design-packaging.md, "The SDK").
    class Context
      attr_reader :build_kind, :platform, :catalog, :root_entry, :artifacts,
                  :provenance, :sizing, :device_kinds, :development_key, :fingerprint

      def initialize(build_kind:, platform:, catalog:, root_entry:, artifacts:,
                     provenance:, device_kinds:, sizing: nil, development_key: nil)
        build_kind = BuildKind.fetch(build_kind)
        unless platform.is_a?(Hash) && catalog.is_a?(Array) && artifacts.is_a?(Hash) &&
               provenance.is_a?(Array) && root_entry.is_a?(Integer) && root_entry.between?(0, catalog.size - 1) &&
               device_kinds.is_a?(Array) && !device_kinds.empty? && device_kinds.all? { |kind| device_kind?(kind) }
          raise Invalid.new('incomplete checked context', property: 'context', field: 'input')
        end
        unless development_key.nil? || (development_key.is_a?(String) && BuildKind.development?(build_kind))
          raise Invalid.new('only a development build trusts a development package key', property: 'context',
                                                                                          field: 'development_key')
        end
        notices = provenance.map do |record|
          unless record.is_a?(Hash)
            raise Invalid.new('invalid provenance record', property: 'context', field: 'provenance')
          end
          normalized = record.reject { |key, _value| key == 'notice' }
          if record.key?('notice')
            notice = record.fetch('notice')
            unless notice.is_a?(String)
              raise Invalid.new('notice must be bytes', property: 'context', field: 'provenance')
            end
            normalized = normalized.merge('notice_sha256' => Digest::SHA256.hexdigest(notice))
          end
          normalized
        end
        @build_kind = build_kind
        @platform = Snapshot.copy(platform)
        @catalog = Snapshot.copy(catalog)
        @root_entry = root_entry
        @artifacts = Snapshot.copy(artifacts)
        @provenance = Snapshot.copy(notices)
        @sizing = Snapshot.copy(sizing)
        @device_kinds = Snapshot.copy(device_kinds)
        @development_key = development_key&.b&.freeze
        validate_catalog_shape
        @fingerprint = Snapshot.digest('build_kind' => @build_kind, 'platform' => @platform,
                                        'catalog' => @catalog, 'root_entry' => @root_entry,
                                        'artifacts' => @artifacts, 'provenance' => @provenance,
                                        'sizing' => @sizing, 'device_kinds' => @device_kinds,
                                        'development_key' => @development_key&.unpack1('H*'))
        freeze
      end

      private

      # A kind row's fields, DeviceKinds::Kind's members by name (DeviceKinds.context_rows).
      DEVICE_KIND_FIELDS = DeviceKinds::Kind.members.map(&:to_s).sort.freeze

      def device_kind?(kind)
        kind.is_a?(Hash) && kind.keys.sort == DEVICE_KIND_FIELDS && [true, false].include?(kind['clocked']) &&
          kind.values_at('compatible', 'peripheral', 'role', 'role_word').all?(String)
      end

      def validate_catalog_shape
        previous = nil
        @catalog.each do |row|
          unless row.is_a?(Hash) && (row.keys - %w[path kind flags source image]).empty? &&
                 row['path'].is_a?(String) && row['kind'].is_a?(Integer) &&
                 row['flags'].is_a?(Integer) && row['source'].is_a?(Hash)
            raise Invalid.new('invalid catalog row', property: 'context', field: 'catalog')
          end
          path = row.fetch('path').b
          if previous && previous >= path
            raise Invalid.new('catalog paths must ascend strictly', property: 'context', field: 'catalog')
          end
          previous = path
          source = row.fetch('source')
          case source['kind']
          when 'artifact'
            unless source.keys.sort == %w[id kind sha256] && source['id'].is_a?(String) &&
                   source['sha256'].is_a?(String) && source['sha256'].match?(/\A[0-9a-f]{64}\z/)
              raise Invalid.new('invalid artifact identity', property: 'context', field: 'catalog.source')
            end
          when 'generated'
            unless source.keys.sort == %w[kind producer] && %w[manifest notices].include?(source['producer'])
              raise Invalid.new('unknown generated artifact', property: 'context', field: 'catalog.source')
            end
          when 'directory'
            unless source.keys == %w[kind]
              raise Invalid.new('invalid empty directory', property: 'context', field: 'catalog.source')
            end
          else
            raise Invalid.new('unknown catalog origin', property: 'context', field: 'catalog.source')
          end
        end
      end
    end


    # Structural fixtures exercise canonical bytes without claiming that an
    # initial-root startup or a machine configuration has been admitted.
    class StructuralFixture
      attr_reader :bytes, :report

      def self.prepare(source:, codec:, context:, planner: nil, consumers: {})
        raise Invalid.new('checked context required', property: 'context', field: 'input') unless context.is_a?(Context)
        parsed = Frontend.parse(source, version: codec.constant('manifest_version'))
        checker = EmptyNative.new(parsed, codec: codec, context: context,
                                  planner: planner, consumers: consumers)
        normalized, report = checker.check
        bytes = Encoder.new(codec).encode(normalized)
        codec.open('manifest', bytes)
        new(bytes: bytes, report: report, context: context)
      end

      def initialize(bytes:, report:, context:)
        @bytes = bytes.freeze
        @report = Snapshot.copy(report)
        @fingerprint = context.fingerprint
        freeze
      end
      private_class_method :new

      def matches?(context)
        context.is_a?(Context) && context.fingerprint == @fingerprint
      end
    end

    # The root startup rule: a declared sanity check, not a proof. It compares
    # the manifest's numbers with the platform record's, so a wrong
    # fiasco_reserve shows at boot, when the root's pool falls short. A report
    # therefore says root_startup: declared, never validated.
    module RootStartup
      module_function

      # The platform's declared memory. Without it no rule can be stated, so
      # nothing is admitted.
      def declared(platform)
        ram, reserve = platform.values_at('ram_bytes', 'fiasco_reserve')
        unless ram.is_a?(Integer) && reserve.is_a?(Integer) && reserve.positive? && reserve < ram
          raise Unsupported.new('the platform record states no RAM size and fiasco_reserve to check root startup against',
                                property: 4, field: 'root_startup')
        end
        { 'ram_bytes' => ram, 'fiasco_reserve' => reserve }.freeze
      end

      def check(loadable:, baseline:, root_memory:, platform:)
        memory = declared(platform)
        if loadable + baseline > root_memory
          raise Invalid.new("the root's loadable segments and system_baseline exceed root_memory",
                            property: 4, field: 'root_startup')
        end
        if root_memory > memory.fetch('ram_bytes') - memory.fetch('fiasco_reserve')
          raise Invalid.new('root_memory exceeds RAM less fiasco_reserve', property: 4, field: 'root_startup')
        end
      end

      # The archive rule, which the packer applies once it has written the archive. At
      # boot the root refuses unless the pool's free pages and its own image hold
      # root_memory (root_memory_fits in liberx/backend/fiasco/root.c). What sigma0 gives
      # the root is RAM less fiasco_reserve, less the archive, which bootstrap reserves
      # whole, less what the boot keeps besides (boot_kept). So the packer checks the
      # same inequality,
      #
      #   archive + root_memory <= RAM - fiasco_reserve - boot_kept,
      #
      # with boot_kept estimated from the platform record, the archive and the devices'
      # memory the manifest declares (dma_memory, the admission report's). The estimate
      # errs high by a few hundred KiB (docs/design-stopgap.md, "The root startup
      # rule"), so an image this refuses fails at boot or comes within that margin of
      # failing. Every figure is in bytes; the platform's come from archive_machine.
      # An archive that fits returns the figures the rule derived (ArchiveRoom), which
      # the packer reports, so no comment has to copy them.
      def check_archive(archive_bytes:, root_memory:, dma_memory:, ram_bytes:, fiasco_reserve:, root_withheld:)
        kept = boot_kept(ram_bytes: ram_bytes, fiasco_reserve: fiasco_reserve, archive_bytes: archive_bytes,
                         root_withheld: root_withheld, dma_memory: dma_memory)
        room = ram_bytes - fiasco_reserve - kept
        short = archive_bytes + root_memory - room
        unless short.positive?
          return ArchiveRoom.new(archive_bytes: archive_bytes, root_memory: root_memory, kept_bytes: kept,
                                 archive_max_bytes: room - root_memory)
        end

        raise Invalid.new("the archive (#{mib(archive_bytes)}) and root_memory (#{mib(root_memory)}) exceed the " \
                          "#{mib(room)} this machine leaves them (RAM less fiasco_reserve and the #{mib(kept)} " \
                          "the boot keeps) by #{(short + 1023) / 1024} KiB",
                          property: 4, field: 'root_startup')
      end

      # What check_archive derived for an archive that fits, in bytes: the archive, the
      # manifest's root_memory, what the boot keeps besides (boot_kept), and the largest
      # archive this root_memory leaves room for on the machine. The packer's report
      # carries it as a hash of those names.
      ArchiveRoom = Data.define(:archive_bytes, :root_memory, :kept_bytes, :archive_max_bytes) do
        def to_h = super.transform_keys(&:to_s)
      end

      # The line the image build prints for a pack's report: the archive; the room
      # root_memory leaves it on the machine (the report's ArchiveRoom); root_memory and
      # how much of it the manifest's budgets promise (the admission report's
      # promised_memory); and what the boot keeps.
      def room_line(report)
        room = report.fetch('archive_room')
        promised = report.fetch('manifest').fetch('promised_memory')
        "archive #{mib(room.fetch('archive_bytes'))}, room for #{mib(room.fetch('archive_max_bytes'))} " \
          "beside root_memory #{mib(room.fetch('root_memory'))}, of which budgets promise #{mib(promised)}; " \
          "the boot keeps #{mib(room.fetch('kept_bytes'))}"
      end

      # The boot's side of check_archive. The root reports the pool's free pages and its
      # own image, what root_memory_fits counted; RAM less fiasco_reserve, the archive and
      # those is what this boot kept besides. Once a boot keeps more than boot_kept
      # estimates, the packer can pass an archive the root refuses, so the production
      # image suite holds its boots to the estimate. A report that leaves the boot keeping
      # less than the page index alone is no measurement, and is refused too. archive_bytes
      # is the archive in whole pages, as bootstrap reserves it, and dma_memory the
      # manifest's devices' memory, which sized the boot's contiguous pool. The failure is the
      # platform record's or the boot's, not the manifest's, so it is a plain Error.
      def check_boot(archive_bytes:, pool_pages:, image_bytes:, dma_memory:, ram_bytes:, fiasco_reserve:, root_withheld:)
        kept = ram_bytes - fiasco_reserve - archive_bytes - (pool_pages * PAGE_BYTES) - image_bytes
        estimate = boot_kept(ram_bytes: ram_bytes, fiasco_reserve: fiasco_reserve, archive_bytes: archive_bytes,
                             root_withheld: root_withheld, dma_memory: dma_memory)
        index = page_index_bytes((ram_bytes - fiasco_reserve - archive_bytes) / PAGE_BYTES)
        raise Error, "the root's report leaves the boot #{kept} bytes, less than the #{index} of the page index" if kept < index
        return if kept <= estimate

        raise Error, "the boot kept #{kept} bytes besides the archive, #{kept - estimate} more than the #{estimate} " \
                     "the packer counts: the platform record's root_withheld #{root_withheld} is too small, " \
                     'or Fiasco or liberx keeps more than it was measured to'
      end

      # The platform's figures check_archive and check_boot take, from the record as Pack
      # receives it (Erx::Platform#record, or a ProductionImage::Machine's, which states
      # that machine's RAM and fiasco_reserve): RAM, fiasco_reserve and root_withheld.
      # Erx::Platform refuses a record without root_withheld when it loads it; a record
      # that reaches here some other way without one packs no image.
      def archive_machine(platform)
        memory = declared(platform)
        withheld = platform['root_withheld']
        unless withheld.is_a?(Integer) && withheld.positive?
          raise Unsupported.new('the platform record states no root_withheld to check the archive against',
                                property: 4, field: 'root_startup')
        end
        { ram_bytes: memory.fetch('ram_bytes'), fiasco_reserve: memory.fetch('fiasco_reserve'),
          root_withheld: withheld }
      end

      # What a boot keeps from RAM less fiasco_reserve besides the archive: the platform
      # record's root_withheld (Fiasco's and sigma0's images, the device tree, the
      # handoff page, and the pool's object table, the root's range table and its
      # thread table), liberx's contiguous pool for the devices' memory the manifest
      # declares, and the pool's page index.
      def boot_kept(ram_bytes:, fiasco_reserve:, archive_bytes:, root_withheld:, dma_memory:)
        root_withheld + contiguous_pool_bytes(dma_memory) +
          page_index_bytes((ram_bytes - fiasco_reserve - archive_bytes) / PAGE_BYTES)
      end

      # The contiguous pool the root takes for dma_memory bytes of devices' memory, as
      # erx_fiasco_contig_order (liberx/backend/fiasco/page_pool.c) sizes it: the
      # smallest power of two that holds them, at least CONTIGUOUS_POOL_MIN_BYTES. The
      # manifest check refuses more than CONTIGUOUS_POOL_MAX_BYTES, so a total past it
      # is the caller's error.
      def contiguous_pool_bytes(dma_memory)
        raise Error, "no contiguous pool holds #{dma_memory} bytes" unless
          dma_memory.between?(0, CONTIGUOUS_POOL_MAX_BYTES)

        [CONTIGUOUS_POOL_MIN_BYTES, 1 << (dma_memory - 1).bit_length].max
      end

      # A page and the contiguous pool's smallest and largest sizes, from the ABI
      # (page_size, fiasco_contig_order_min and fiasco_contig_order_max). The other two
      # are liberx's own and copied: sizeof(erx_backend_vm_page_t)
      # (liberx/backend/core/vm_table.h, which vm_table.c asserts) and VM_DEVICE_PAGES
      # (liberx/backend/fiasco/vm.c).
      PAGE_BYTES = ABI::Generated.constant('page_size')
      PAGE_INDEX_SLOT_BYTES = 16
      DEVICE_PAGES = 4096
      CONTIGUOUS_POOL_MIN_BYTES = 1 << ABI::Generated.constant('fiasco_contig_order_min')
      CONTIGUOUS_POOL_MAX_BYTES = 1 << ABI::Generated.constant('fiasco_contig_order_max')

      # erx_backend_vm_layout (liberx/backend/core/vm_table.c) sizes the index over the
      # pool's window, its contiguous pool and the device pages. The window and the
      # contiguous pool lie in RAM less fiasco_reserve and the archive, so sizing it over
      # all of those pages never comes out smaller. Its loop doubles from one page of
      # slots to the smallest power of two at least twice the pages covered; the shift
      # finds that power directly.
      def page_index_bytes(pages_free)
        covered = pages_free + DEVICE_PAGES
        slots = 1 << ((2 * covered) - 1).bit_length
        [slots, PAGE_BYTES / PAGE_INDEX_SLOT_BYTES].max * PAGE_INDEX_SLOT_BYTES
      end

      def mib(bytes) = format('%.2f MiB', bytes / 1_048_576.0)
    end

    # Phase 1's admission: Stopgap over a manifest with the system domain and
    # its configured domains, and the declared root startup rule. This factory alone mints the
    # private publication token, so a structural fixture cannot pass for it.
    class Admitted
      attr_reader :bytes, :report

      def self.admit(source:, codec:, context:, planner: nil, consumers: {})
        raise Invalid.new('checked context required', property: 'context', field: 'input') unless context.is_a?(Context)
        RootStartup.declared(context.platform)
        parsed = Frontend.parse(source, version: codec.constant('manifest_version'))
        checker = Stopgap.new(parsed, codec: codec, context: context,
                              planner: planner, consumers: consumers)
        normalized, report = checker.check
        bytes = Encoder.new(codec).encode(normalized)
        codec.open('manifest', bytes)
        checker.check_plans(bytes, normalized)
        new(bytes: bytes, report: report, context: context)
      end

      def initialize(bytes:, report:, context:)
        @bytes = bytes.freeze
        @report = Snapshot.copy(report)
        @fingerprint = context.fingerprint
        freeze
      end
      private_class_method :new

      def matches?(context)
        context.is_a?(Context) && context.fingerprint == @fingerprint
      end
    end

    def self.admit(source:, codec:, context:, planner: nil, consumers: {})
      Admitted.admit(source: source, codec: codec, context: context,
                    planner: planner, consumers: consumers)
    end

    # The artifact names the source's domain rows and session templates give as
    # releases, and the app template's (DomainStartup::APP_TEMPLATE) when the source has
    # an apps row, from which the check derives it, sorted and once each, read before any check so a build can make what
    # they name. A reference of another form names nothing here; admission refuses it
    # (Stopgap#artifact).
    def self.release_names(source:, codec:)
      records = Frontend.parse(source, version: codec.constant('manifest_version')).records
      records.values_at('domain', 'session').compact.flatten.filter_map do |record|
        tokens = record.properties.fetch('release')
        token = tokens.first if tokens.size == 1
        token.value.delete_prefix('@artifact.') if token && !token.quoted && token.value.start_with?('@artifact.')
      end.then { |names| records.key?('apps') ? [*names, DomainStartup::APP_TEMPLATE.release] : names }.uniq.sort
    end

    def self.structural_fixture(source:, codec:, context:)
      StructuralFixture.prepare(source: source, codec: codec, context: context)
    end

    # The readers and the normalization every check shares. A unit's holder is the
    # system domain or a configured domain, and nothing is reserved for a child. A subclass
    # states which modes and records it takes (check_mode), what it allows of a
    # platform device (check_device), what else it places (check_and_place)
    # and what its report claims (claims).
    class SystemDomainCheck
      TABLES = { 'principal' => 'principals', 'limits' => 'limits',
                 'runtime_limits' => 'runtime_limits', 'lane_class' => 'lane_classes',
                 'image' => 'images', 'domain' => 'domains' }.freeze
      # What a framebuffer row names (docs/design-device-tree.md, "The framebuffer record"):
      # the node whose children the root searches, and the compatible string the one child
      # it takes must carry.
      FRAMEBUFFER_PATH = '/chosen'
      FRAMEBUFFER_COMPATIBLE = 'simple-framebuffer'
      # A device-tree node path as erx_boot_node_path_valid (include/erx/core/boot_handoff.h)
      # has it: '/' and the characters the specification allows in names.
      NODE_PATH = %r{\A/[A-Za-z0-9,._+@/-]*\z}
      # The apps row (docs/design-packaging.md, "The apps row"), its defaults applied:
      # the budget all apps share, the names of the services an app may take, and max,
      # how many apps a boot holds. Every sum that counts a principal counts max apps,
      # each a principal with a domains quota of one holding every service of services,
      # and adds memory once (property 19's second clause). A manifest without the row
      # has NO_APPS, which takes no packages and adds nothing to any sum, so each sum
      # counts the row the same way whether or not the manifest has one.
      AppsRow = Data.define(:memory, :services, :max)
      NO_APPS = AppsRow.new(memory: 0, services: [].freeze, max: 0)
      # A package row of the image, bound to its package artifact (check_packages): its
      # app's name, its header's SHA-256 in hexadecimal, whether its row is enabled and
      # the memory its declaration asks.
      Package = Data.define(:name, :sha256, :enabled, :memory)
      # The name the machine gives the build's development package key
      # (erx_pkg_header:signer/0), which no signer row may take.
      DEVELOPMENT_SIGNER = 'development'

      def initialize(source, codec:, context:, planner:, consumers:)
        @source = source
        @codec = codec
        @context = context
        @planner = planner
        @consumers = consumers
        @reader = codec.schema.readers.find { |item| item.name == 'manifest' }
        @shares = records('share').to_h { |record| [record.name, share_record(record)] }
        @indices = TABLES.keys.to_h do |kind|
          [kind, records(kind).map(&:name).sort.each_with_index.to_h]
        end
      end

      def check
        machine = @source.machine
        flags = flags(machine, 'flags', 'manifest_flags')
        development = (flags & @codec.member('manifest_flags', 'development')) != 0
        unless development == BuildKind.development?(@context.build_kind)
          invalid('configuration conflicts with checked build kind', 9, 'machine.flags')
        end
        partial = (flags & @codec.member('manifest_flags', 'partial_boot')) != 0
        invalid('partial boot requires development mode', 9, 'machine.flags') if partial && !development
        check_mode(development: development, partial: partial)
        @apps = apps_row
        root_private_bytes = check_catalog
        platform_name = text(machine, 'platform')
        invalid('configuration names a different checked platform', 1, 'machine.platform') unless platform_name == @context.platform['name']
        parent_cpus = @context.platform['cpuset']
        unless parent_cpus.is_a?(Integer) && parent_cpus.between?(1, (1 << 64) - 1)
          invalid('checked platform requires a nonempty CPU set', 'context', 'platform.cpuset')
        end
        system_share = share(machine, 'system_share')
        users_share = share(machine, 'users_share')
        system_cpus, system_rate = effective_share(system_share, parent_cpus)
        users_cpus, users_rate = effective_share(users_share, parent_cpus)
        invalid('system grant has no execution capacity', 4, 'machine.system_share') unless system_rate.positive?
        invalid('system and users exceed the root CPU rate', 4, 'machine.shares') if system_rate + users_rate > population(parent_cpus)
        root_memory = number(machine, 'root_memory')
        baseline = number(machine, 'system_baseline')
        page = @codec.constant('page_size')
        invalid('root memory must be positive and page-aligned', 4, 'machine.root_memory') unless root_memory.positive? && (root_memory % page).zero?
        invalid('system baseline must be positive', 4, 'machine.system_baseline') unless baseline.positive?
        if baseline < root_private_bytes
          invalid('baseline is smaller than the checked private image memory', 4, 'machine.system_baseline')
        end
        rows = @reader.tables.keys.to_h { |name| [name, []] }
        normalize_profiles(rows)
        principals = normalize_principals(rows, users_cpus, users_rate)
        max_domains = number(machine, 'max_domains')
        # Every living domain, configured or requested, is one of its principal's quota,
        # and every app is a principal with a quota of one (property 19's second clause).
        if principals.sum { |row| row.fetch('domains') } + @apps.max > max_domains
          invalid('principal domain quotas and the apps row\'s max exceed max_domains', 4, 'principals.domains')
        end
        normalize_units(rows)
        device_memory = rows.fetch('devices').sum { |device| device.fetch('dma_memory') }
        # The stopgap's contiguous pool holds every device's memory at once (RootStartup.contiguous_pool_bytes).
        if device_memory > RootStartup::CONTIGUOUS_POOL_MAX_BYTES
          invalid("device memory exceeds the #{RootStartup::CONTIGUOUS_POOL_MAX_BYTES >> 20} MiB contiguous pool", 4, 'devices.dma_memory')
        end
        # The apps budget is carved from root_memory as a principal's is (property 19).
        promised = principals.sum { |row| row.fetch('memory') } + @apps.memory + baseline + device_memory
        if promised > root_memory
          invalid('principal budgets, the apps budget, system baseline and device memory exceed root memory', 4, 'principals.memory')
        end
        console = text(machine, 'console')
        hostlink = text(machine, 'hostlink')
        check_uarts(rows, console, hostlink)
        unless enum(machine, 'sealing', 'seal') == @codec.member('seal', 'none')
          invalid('no sealing service exists to hold a sealing secret', 7, 'machine.sealing')
        end
        shell = records('shell_principal').map do |record|
          { 'principal' => reference_token(record.properties.fetch('targets').first, 'principal', record.line) }
        end
        invalid('duplicate shell principal', 5, 'shell_principals') unless shell.map { |row| row.fetch('principal') }.uniq.size == shell.size
        rows['shell_principals'] = shell.sort_by { |row| row.fetch('principal') }
        check_and_place(rows, root_memory: root_memory, baseline: baseline, max_domains: max_domains)
        check_pin_controller(rows, console, hostlink)
        system_principal = reference(machine, 'system_principal', 'principal')
        # The system principal's sessions are root_N (erx_domain_core:session_prefix/3),
        # so a principal named root must be the system principal.
        root = @indices.fetch('principal').fetch('root', system_principal)
        invalid('only the system principal may be named root', 5, 'principal.name') unless root == system_principal
        header = {
          'magic' => @codec.constant('manifest_magic'), 'version' => @codec.constant('manifest_version'),
          'flags' => flags, 'host' => text(machine, 'host'), 'system_args' => words(machine, 'system_args'),
          'console' => console,
          'hostlink' => hostlink, 'platform' => platform_name, 'root_memory' => root_memory,
          'system_baseline' => baseline, 'system_reservation' => 0,
          'system_share' => system_share, 'users_share' => users_share,
          'system_principal' => system_principal,
          'max_domains' => max_domains, 'max_connections' => number(machine, 'max_connections'),
          'system_lane' => number(machine, 'system_lane'), 'system_queue' => number(machine, 'system_queue'),
          'peer_held' => number(machine, 'peer_held'), 'system_reserve' => number(machine, 'system_reserve'),
          'sealing' => @codec.member('seal', 'none'),
          'system_runtime_limits' => reference(machine, 'system_runtime_limits', 'runtime_limits'),
          'native_limits' => reference(machine, 'native_limits', 'limits')
        }
        check_lane(header.fetch('system_lane'), 'machine.system_lane')
        %w[system_queue peer_held].each do |key|
          invalid('limit must be positive', 4, "machine.#{key}") unless header.fetch(key).positive?
        end
        report = { 'structure' => 'validated',
                   'executable' => 'supplied_catalog', 'provenance' => 'supplied_context',
                   'policy_admission' => 'unsupported',
                   'child_plan_instances' => 0, 'dynamic_domain_reservation' => 0,
                   'root_image_private_bytes' => root_private_bytes, 'root_memory' => root_memory,
                   'dma_memory' => device_memory, 'promised_memory' => promised,
                   'effective_system_cpuset' => system_cpus,
                   'effective_users_cpuset' => users_cpus,
                   'context_sha256' => @context.fingerprint }.merge(claims)
        [{ 'header' => header, 'tables' => rows }, report]
      end

      private

      def invalid(message, property, field)
        raise Invalid.new(message, property: property, field: field)
      end

      def unsupported(message, field)
        raise Unsupported.new(message, property: 'unsupported', field: field)
      end

      def records(kind)
        @source.records.fetch(kind, [])
      end

      # The manifest's apps row, or NO_APPS. Its memory is a whole number of pages, as
      # root_memory is; its max is 1 to apps_max_limit; its services are distinct
      # identifiers, which the stopgap's check_apps resolves against the services.
      def apps_row
        record = records('apps').first
        return NO_APPS unless record

        memory = number(record, 'memory')
        invalid('the apps budget must be positive and page-aligned', 19, 'apps.memory') unless
          memory.positive? && (memory % @codec.constant('page_size')).zero?
        max = record.properties.key?('max') ? number(record, 'max') : @codec.constant('apps_max_default')
        limit = @codec.constant('apps_max_limit')
        invalid("max is outside 1 to #{limit}", 19, 'apps.max') unless max.between?(1, limit)
        services = record.properties.fetch('services', []).map do |token|
          record.line.fail!('services requires service names') if token.quoted || !token.value.match?(Frontend::IDENTIFIER)
          token.value
        end
        invalid('services names a service twice', 19, 'apps.services') unless services.uniq.size == services.size
        AppsRow.new(memory: memory, services: services.freeze, max: max)
      end

      def one(record, key)
        tokens = record.properties[key]
        record.line.fail!("#{key} requires one value") unless tokens && tokens.size == 1
        tokens.first
      end

      def text(record, key)
        token = one(record, key)
        return token.value.b if token.quoted
        if token.value.start_with?('hex:') && token.value.delete_prefix('hex:').match?(/\A(?:[0-9a-fA-F]{2})*\z/)
          return [token.value.delete_prefix('hex:')].pack('H*')
        end
        record.line.fail!("#{key} requires quoted or hexadecimal bytes")
      end

      # A word list as the page holds it, each word ended by a NUL. A source writes it
      # quoted, with its words separated by spaces, since the arguments it holds have no
      # empty word and no space.
      def words(record, key)
        return ''.b unless record.properties.key?(key)

        token = one(record, key)
        return text(record, key) unless token.quoted

        token.value.b.split(' ').map { |word| "#{word}\0" }.join
      end

      def number(record, key)
        token = one(record, key)
        record.line.fail!("#{key} requires an integer") if token.quoted
        value = ABI::Syntax.integer(token.value, line: record.line)
        invalid('value is outside unsigned 64-bit range', 'source', key) unless value.between?(0, (1 << 64) - 1)
        value
      end

      def flags(record, key, type)
        token = one(record, key)
        record.line.fail!('flag list cannot be quoted') if token.quoted
        return 0 if token.value == 'none'
        names = token.value.split(',', -1)
        invalid('duplicate flag', 'source', key) unless names.uniq.size == names.size
        names.reduce(0) { |mask, name| mask | member(record.line, key, type, name) }
      end

      def enum(record, key, type)
        token = one(record, key)
        record.line.fail!('enumeration value cannot be quoted') if token.quoted
        member(record.line, key, type, token.value)
      end

      # The value of the member of enumeration or flag set type that a source word names,
      # refused on its line when type has no such member.
      def member(line, key, type, name)
        members = @codec.schema.types.fetch(type).members
        members.fetch(name) { line.fail!("#{key} names no member of #{type}: #{members.keys.join(', ')}") }
      end

      def reference(record, key, kind)
        reference_token(one(record, key), kind, record.line)
      end

      def reference_token(token, kind, line)
        prefix = "@#{kind}."
        line.fail!('reference has the wrong kind') if token.quoted || !token.value.start_with?(prefix)
        name = token.value.delete_prefix(prefix)
        @indices.fetch(kind).fetch(name) { line.fail!('undefined source reference') }
      end

      # A holder or server: literal system, the system domain, or @domain.NAME, a
      # configured domain's index.
      def holder_index(token, property:, field:)
        return @codec.constant('mf_none') if !token.quoted && token.value == 'system'

        domain_index(token) || invalid('names neither the system domain nor a configured domain', property, field)
      end

      # A configured domain's index, or nil when the token names none.
      def domain_index(token)
        return nil if token.quoted || !token.value.start_with?('@domain.')

        @indices.fetch('domain')[token.value.delete_prefix('@domain.')]
      end

      def share(record, key)
        token = one(record, key)
        record.line.fail!('share requires a share reference') if token.quoted || !token.value.start_with?('@share.')
        @shares.fetch(token.value.delete_prefix('@share.')) { record.line.fail!('undefined share') }
      end

      def share_record(record)
        values = @codec.schema.types.fetch('erx_share').fields.to_h do |field|
          value = if field.name == 'flags'
                    flags(record, field.name, 'group_flags')
                  elsif field.name == 'quota_ns' && one(record, field.name).value == 'uncapped'
                    @codec.constant('quota_none')
                  else
                    number(record, field.name)
                  end
          [field.name, value]
        end
        checks = { 'period_ns' => %w[period_min period_max], 'slice_us' => %w[slice_min_us slice_max_us],
                   'grace_us' => %w[grace_min_us grace_max_us] }
        checks.each do |field, bounds|
          unless values.fetch(field).between?(*bounds.map { |name| @codec.constant(name) })
            invalid('grant value requires kernel clamping', 4, "share.#{field}")
          end
        end
        unless values.fetch('base') <= values.fetch('ceiling') && values.fetch('ceiling') <= @codec.constant('urgency_max')
          invalid('invalid urgency bounds', 4, 'share.urgency')
        end
        @codec.encode_layout('erx_share', values)
        values.freeze
      end

      def population(mask)
        mask.to_s(2).count('1')
      end

      def effective_share(share, parent)
        cpuset = share.fetch('cpuset') & parent
        cpuset = parent if cpuset.zero?
        rate = if share.fetch('quota_ns') == @codec.constant('quota_none')
                 Rational(population(cpuset), 1)
               else
                 Rational(share.fetch('quota_ns'), share.fetch('period_ns'))
               end
        [cpuset, rate]
      end

      def normalize_profiles(rows)
        rows['runtime_limits'] = records('runtime_limits').sort_by(&:name).map do |record|
          { 'name' => record.name }.merge(Frontend::FIELDS.fetch('runtime_limits').to_h { |key| [key, number(record, key)] })
        end
        rows['limits'] = records('limits').sort_by(&:name).map do |record|
          values = { 'name' => record.name }
          %w[memory outer lane connections crash peer_held peer_held_total].each { |key| values[key] = number(record, key) }
          values['grant'] = share(record, 'grant')
          values['flags'] = flags(record, 'flags', 'mf_limits_flags')
          values['runtime_limits'] = reference(record, 'runtime_limits', 'runtime_limits')
          spaces = one(record, 'spaces')
          enabled = (values.fetch('flags') & @codec.member('mf_limits_flags', 'spaces')) != 0
          if spaces.value == 'none' && !spaces.quoted
            invalid('enabled sub-spaces need a grant', 4, 'limits.spaces') if enabled
            values['spaces'] = @codec.schema.types.fetch('erx_share').fields.to_h { |field| [field.name, 0] }
          else
            invalid('disabled sub-spaces must have no grant', 4, 'limits.spaces') unless enabled
            values['spaces'] = share(record, 'spaces')
          end
          check_lane(values.fetch('lane'), 'limits.lane')
          values
        end
        rows['lane_classes'] = records('lane_class').sort_by(&:name).map do |record|
          lane = number(record, 'lane')
          check_lane(lane, 'lane_classes.lane')
          { 'name' => record.name, 'lane' => lane }
        end
      end

      def normalize_principals(rows, parent_cpus, parent_rate)
        result = records('principal').sort_by(&:name).map do |record|
          grant = share(record, 'grant')
          cpus, rate = effective_share(grant, parent_cpus)
          invalid('principal grant exceeds users', 4, 'principal.grant') if rate > parent_rate
          values = { 'name' => record.name, 'memory' => number(record, 'memory'), 'grant' => grant,
                     'domains' => number(record, 'domains'), 'names' => number(record, 'names'),
                     'default_limits' => reference(record, 'default_limits', 'limits'),
                     'ceiling_limits' => reference(record, 'ceiling_limits', 'limits') }
          pooled = "#{record.name}_#{values.fetch('names')}"
          invalid('name pool exceeds identifier bound', 5, 'principal.names') unless pooled.bytesize <= 63
          defaults = rows.fetch('limits').fetch(values.fetch('default_limits'))
          ceilings = rows.fetch('limits').fetch(values.fetch('ceiling_limits'))
          check_limits(defaults, ceilings, cpus, rate, rows.fetch('runtime_limits'))
          values
        end
        rows['principals'] = result
      end

      def check_limits(defaults, ceilings, cpus, parent_rate, runtime_limits)
        %w[memory outer lane connections crash peer_held peer_held_total].each do |field|
          invalid('default exceeds principal ceiling', 4, "limits.#{field}") if defaults.fetch(field) > ceilings.fetch(field)
        end
        invalid('default flags exceed principal ceiling', 4, 'limits.flags') unless (defaults.fetch('flags') & ~ceilings.fetch('flags')).zero?
        default_cpus, default_rate = effective_share(defaults.fetch('grant'), cpus)
        ceiling_cpus, ceiling_rate = effective_share(ceilings.fetch('grant'), cpus)
        if default_rate > ceiling_rate || ceiling_rate > parent_rate || (default_cpus & ~ceiling_cpus) != 0 ||
           defaults.fetch('grant').fetch('ceiling') > ceilings.fetch('grant').fetch('ceiling')
          invalid('default CPU grant exceeds principal ceiling', 4, 'limits.grant')
        end
        if (defaults.fetch('flags') & @codec.member('mf_limits_flags', 'spaces')) != 0
          _, child_rate = effective_share(defaults.fetch('spaces'), default_cpus)
          invalid('sub-space grant exceeds domain', 4, 'limits.spaces') if child_rate > default_rate
        end
        left = runtime_limits.fetch(defaults.fetch('runtime_limits'))
        right = runtime_limits.fetch(ceilings.fetch('runtime_limits'))
        Frontend::FIELDS.fetch('runtime_limits').each do |field|
          invalid('runtime default exceeds ceiling', 4, "runtime_limits.#{field}") if left.fetch(field) > right.fetch(field)
        end
      end

      def normalize_units(rows)
        units = @context.platform['units']
        invalid('checked platform needs a unit roster', 'context', 'platform.units') unless units.is_a?(Array)
        by_key = {}
        units.each do |unit|
          unless unit.is_a?(Hash) && unit['key'].is_a?(String) && unit['devices'].is_a?(Array) && !by_key.key?(unit['key'])
            invalid('invalid checked platform unit', 'context', 'platform.units')
          end
          by_key[unit.fetch('key')] = unit
        end
        placed = []
        records('unit').sort_by(&:name).each do |record|
          key = text(record, 'placement')
          unit = by_key[key] || invalid('unit is absent from checked placement', 1, 'unit.placement')
          invalid('unit is assigned more than once', 1, 'unit.placement') if placed.include?(key)
          placed << key
          holder = holder_index(one(record, 'holder'), property: 1, field: 'unit.holder')
          first = rows.fetch('devices').size
          invalid('platform unit has no devices', 'context', 'platform.units') if unit.fetch('devices').empty?
          unit.fetch('devices').sort_by { |device| device.fetch('placement_key').b }.each do |device|
            normalized = platform_device(device)
            normalized['clock'] = device_clock(normalized)
            check_device(normalized)
            rows.fetch('devices') << normalized
          end
          rows.fetch('units') << { 'name' => record.name, 'holder' => holder,
                                   'devices' => { 'table' => 'devices', 'first' => first, 'count' => rows.fetch('devices').size - first } }
        end
        check_framebuffer_windows(by_key.values.flat_map { |unit| unit.fetch('devices') })
      end

      # A framebuffer row's shape (docs/design-device-tree.md, "The framebuffer record"): a
      # device-tree row at FRAMEBUFFER_PATH for FRAMEBUFFER_COMPATIBLE's node, with no DMA, no
      # line and no flags, whose base and size are its window, whole pages, since the root maps
      # the framebuffer by the page and the tree chooses where in the window it lies.
      def check_framebuffer(device)
        return unless device.fetch('role') == @codec.member('mf_device_role', 'framebuffer')

        unless device.fetch('selector') == @codec.member('mf_selector', 'dt') && device['path'] == FRAMEBUFFER_PATH &&
               device['compatible'] == FRAMEBUFFER_COMPATIBLE
          invalid("a framebuffer row names #{FRAMEBUFFER_PATH} and #{FRAMEBUFFER_COMPATIBLE}", 'context', 'platform.devices')
        end
        unless device.fetch('dma') == @codec.member('mf_dma', 'none') && device.fetch('line').zero? && device.fetch('flags').zero?
          invalid('a framebuffer row has no DMA, line or flags', 'context', 'platform.devices')
        end
        page = @codec.constant('page_size')
        return if (device.fetch('base') % page).zero? && (device.fetch('size') % page).zero?

        invalid('a framebuffer window is whole pages', 'context', 'platform.devices')
      end

      # Property 1 for a framebuffer's window: the root maps for the window's holder whatever
      # pages of it the firmware's tree names, so a window that meets another device-tree
      # device's register window of the platform, placed or not, would let the tree hand that
      # holder another device's registers, and one that meets the platform's RAM would let it
      # hand over memory the root allocates. Every framebuffer row of roster, the platform
      # record's every device, is checked, placed or not, so a wrong window fails before a
      # manifest places it; each row is read as a placed one is (platform_device), so a field
      # the record writes as the codec's number compares as its name does. Windows are
      # half-open ranges, [base, limit).
      def check_framebuffer_windows(roster)
        devices = roster.map { |device| platform_device(device) }
        framebuffer = @codec.member('mf_device_role', 'framebuffer')
        device_tree = @codec.member('mf_selector', 'dt')
        devices.select { |device| device.fetch('role') == framebuffer }.each do |row|
          check_framebuffer(row)
          base = row.fetch('base')
          limit = base + row.fetch('size')
          invalid('a framebuffer window meets the platform\'s RAM', 1, 'devices.base') if meets_ram?(base, limit)
          devices.each do |device|
            next if device.fetch('role') == framebuffer || device.fetch('selector') != device_tree
            next unless device.fetch('base') < limit && base < device.fetch('base') + device.fetch('size')

            invalid("a framebuffer window meets #{device['path']}'s registers", 1, 'devices.base')
          end
        end
      end

      # Whether [base, limit) meets the RAM the platform record states.
      def meets_ram?(base, limit)
        first, bytes = @context.platform.values_at('ram_first', 'ram_bytes')
        invalid('checked platform needs its RAM', 'context', 'platform.ram_first') unless
          first.is_a?(Integer) && bytes.is_a?(Integer)
        base < first + bytes && first < limit
      end

      # A platform record's device row as the device table holds it: its selector, role and
      # DMA kind as the codec's numbers, flags and DMA memory defaulted to 0, and a
      # device-tree row's window and line checked integers (device_window).
      def platform_device(device)
        invalid('invalid checked device row', 'context', 'platform.devices') unless device.is_a?(Hash)
        normalized = device.dup
        { 'selector' => 'mf_selector', 'role' => 'mf_device_role', 'dma' => 'mf_dma' }.each do |field, type|
          normalized[field] = @codec.member(type, normalized.fetch(field)) if normalized[field].is_a?(String)
        end
        normalized['flags'] = normalized.fetch('flags', 0)
        normalized['dma_memory'] = normalized.fetch('dma_memory', 0)
        normalized.merge(device_window(normalized))
      end

      # A device-tree device's register window and interrupt line, which the platform record
      # must carry (docs/design-abi.md, "Devices and partition windows"); a PCIe function's
      # come from configuration space and are zero here.
      def device_window(device)
        fields = %w[base size line]
        unless device.fetch('selector') == @codec.member('mf_selector', 'dt')
          invalid('a PCIe function carries a window or line', 'context', 'platform.devices') if fields.any? { |field| device.fetch(field, 0) != 0 }
          return fields.to_h { |field| [field, 0] }
        end

        missing = fields.reject { |field| device[field].is_a?(Integer) }
        invalid("device-tree device lacks #{missing.join(', ')}", 'context', 'platform.devices') unless missing.empty?
        invalid('device-tree device has an empty window', 'context', 'platform.devices') if device.fetch('size').zero?
        # Line 0 is no line (docs/design-abi.md, "Devices and partition windows"), so only a
        # row no driver binds a line for, of the ordinary role, which no device kind has, or a
        # framebuffer's, carries it.
        if device.fetch('line').zero? && ![device_role('ordinary'), device_role('framebuffer')].include?(device.fetch('role'))
          invalid('a driven device-tree device names no interrupt line', 'context', 'platform.devices')
        end
        unless device_path?(device['path'])
          invalid("device-tree device's path is not a node path of at most #{@codec.constant('device_path_max')} bytes",
                  'context', 'platform.devices')
        end
        device.slice(*fields)
      end

      # A device-tree row's path, which its device record carries as PATH, the device's name
      # to its driver (docs/design-stopgap.md, "Device records"): a node path of at most the
      # ABI's device_path_max bytes, as erx_boot_device_path_valid admits it.
      def device_path?(path) = path.is_a?(String) && path.match?(NODE_PATH) && path.bytesize <= @codec.constant('device_path_max')

      # The frequency in hertz of the clock a device's driver divides rates from, the first
      # entry of its device-tree node's `clocks` (docs/design-abi.md, "Devices and partition
      # windows"). Whether a driver reads one is a fact of its device's kind, the clocked
      # column of erx/device_kinds.h, and only the board knows the rate, so a row of a clocked
      # kind carries a positive integer and every other row's is 0, absent or written so. The
      # codec holds the value to the row's 32 bits.
      def device_clock(device)
        clock = device.fetch('clock', 0)
        named = "#{device['compatible']} device #{device['path'].inspect}"
        if clocked?(device)
          invalid("#{named} lacks its clock in hertz", 'context', 'platform.devices') unless clock.is_a?(Integer) && clock.positive?
        else
          invalid("#{named} carries a clock, which no driver of its kind reads", 'context', 'platform.devices') unless clock == 0
        end
        clock
      end

      # Whether device, a normalized platform row, is of a kind whose row carries a clock: a
      # kind of its role and compatible string, as the root and the domain library match them.
      def clocked?(device)
        @context.device_kinds.any? do |kind|
          kind.fetch('clocked') && kind.fetch('compatible') == device['compatible'] &&
            @codec.member('mf_device_role', kind.fetch('role')) == device['role']
        end
      end

      def check_uarts(rows, console, hostlink)
        invalid('console and host link must differ', 8, 'machine.hostlink') if !hostlink.empty? && hostlink == console
        paths = rows.fetch('devices').select do |device|
          device.fetch('selector') == @codec.member('mf_selector', 'dt') && device.fetch('role') == @codec.member('mf_device_role', 'uart')
        end.map { |device| device.fetch('path') }
        [console, hostlink].reject(&:empty?).each do |path|
          field = path == console ? 'machine.console' : 'machine.hostlink'
          invalid('UART is not placed', 8, field) unless paths.include?(path)
          invalid('UART is not assigned to the system domain', 8, field) unless unit_holder(rows, path) == @codec.constant('mf_none')
        end
        check_console_kind(rows, console)
        unless @context.platform['console'] == console && (@context.platform.fetch('hostlink', '') == hostlink)
          invalid('UART paths disagree with checked platform', 8, 'machine.console')
        end
        check_uart_lines(rows, console, hostlink.empty? ? {} : { hostlink => 'machine.hostlink' })
      end

      # Property 8's pin controller clause (docs/design-header-io.md, "The pin controller and
      # the console"): whoever holds the pin controller's register page sets the function of
      # every pin, so when the board's header map gives a pin to the console or the host link,
      # a unit with a device-tree row on that page is held by the system domain or by a domain
      # of its own, which no manifest row names but those units, the services of the interfaces
      # they back and the boot order (pin_domain_row?); an unplaced unit has no row. A session
      # template holds nothing, since holder_index resolves every holder through the domain
      # table. The units are found by the page, not by the controller's path, so a second row
      # on the page under another path is caught too. A record without a map states no pin,
      # and the clause is empty. Console and host link are the checked platform's
      # (check_uarts). It runs once every row is placed, so it sees each one that names the
      # holder.
      def check_pin_controller(rows, console, hostlink)
        header = @context.platform['header']
        return if header.nil?

        uarts = [console, hostlink].reject(&:empty?)
        return unless header.fetch('rows').any? { |row| uarts.include?(row['use']) }

        controller = header.fetch('controller')
        device_tree = @codec.member('mf_selector', 'dt')
        row = platform_device(record_device(controller))
        invalid("pin controller #{controller.inspect} is no device-tree row", 'context', 'platform.header') unless
          row.fetch('selector') == device_tree
        page = register_pages(row)
        controlling = lambda do |unit|
          unit_devices(rows.fetch('devices'), unit).any? do |device|
            pages = register_pages(device)
            device.fetch('selector') == device_tree && pages.begin < page.end && page.begin < pages.end
          end
        end
        rows.fetch('units').select(&controlling).each do |unit|
          holder = unit.fetch('holder')
          next if holder == @codec.constant('mf_none')

          table, other = domain_references(rows, holder).find { |name, row| !pin_domain_row?(name, row, controlling) }
          next if other.nil?

          domain = @indices.fetch('domain').key(holder)
          invalid("unit #{unit.fetch('name')} reaches pin controller #{controller}'s registers, which set the console's " \
                  "and host link's pins, so its holder domain #{domain} is a domain of its own, but a row of #{table}" \
                  "#{" (#{other.fetch('name')})" if other.key?('name')} names it", 8, 'unit.holder')
        end
      end

      # The interfaces whose trees the pin controller's units back (docs/design-header-io.md,
      # "Holding and granting": each tree is a service of its holder), resolved against
      # abi/services, which declares them once run-time GPIO is built.
      PIN_CONTROLLER_INTERFACES = %w[gpio].freeze

      # Whether a row naming the pin controller's holder is one the clause admits: a unit
      # on the controller's page, a service of an interface those units back, or the boot
      # order, which names every domain. Facets of those services name the service, not
      # the holder, so grants to other domains pass without a row here.
      def pin_domain_row?(table, row, controlling)
        case table
        when 'units' then controlling.call(row)
        when 'services' then pin_controller_interfaces.include?(row.fetch('interface'))
        when 'boot_order' then true
        else false
        end
      end

      # PIN_CONTROLLER_INTERFACES' numbers, of those abi/services declares.
      def pin_controller_interfaces = PIN_CONTROLLER_INTERFACES.filter_map { |name| find_interface(name) }

      # An interface's number, or nil when abi/services declares none of that name.
      def find_interface(name) = @codec.schema.services.find { |service| service.fetch(:name) == name }&.fetch(:number)

      # Every row that names the domain at index, as [table, row] pairs. The manifest
      # reader's index rules into the domains table (abi/manifest.txt) list each field that
      # holds a domain, with the tag that makes it one, so a field the ABI adds is scanned
      # without an edit here, and a clause that admits only some rows refuses a new one.
      def domain_references(rows, index)
        @reader.rules.select { |rule| rule.fetch(:kind) == 'index' && rule.fetch(:table) == 'domains' }.flat_map do |rule|
          path = rule.fetch(:path)
          guard = rule[:guard]
          rows.fetch(path.scope).select do |row|
            row.dig(*path.fields) == index && (guard.nil? || row.dig(*guard.fetch(:tag).fields) == guard.fetch(:value))
          end.map { |row| [path.scope, row] }
        end
      end

      # The checked platform's device row at path, placed or not.
      def record_device(path)
        @context.platform.fetch('units').flat_map { |unit| unit.fetch('devices') }.find { |device| device['path'] == path } ||
          invalid("pin controller #{path} is no device of the checked platform", 'context', 'platform.header')
      end

      # The whole pages a normalized row's register window [base, base + size) lies in, as a
      # half-open range.
      def register_pages(device)
        size = @codec.constant('page_size')
        first = device.fetch('base') / size * size
        first...((device.fetch('base') + device.fetch('size') + size - 1) / size * size)
      end

      # The rows of unit's devices.
      def unit_devices(devices, unit)
        span = unit.fetch('devices')
        devices.slice(span.fetch('first'), span.fetch('count'))
      end

      # The console's record names the PERIPHERAL of its UART's row of erx/device_kinds.h's
      # erx_uart_kinds, and a UART of no row gets no record, so its console would start no
      # driver. The console is a placed UART (check_uarts).
      def check_console_kind(rows, console)
        return if console.empty?

        compatible = rows.fetch('devices').find { |device| device['path'] == console }.fetch('compatible')
        return if @context.device_kinds.any? { |kind| kind.fetch('role') == 'uart' && kind.fetch('compatible') == compatible }

        invalid("console UART #{console} is #{compatible}, which no UART kind of #{DeviceKinds::SOURCE} names", 8,
                'machine.console')
      end

      # Property 8's interrupt-line clause (docs/design-shared-devices.md, "Lines inside a
      # domain"): the console starts its own UART's driver, and the owner of its line when
      # the line is shared, and a line has one binder, so no other UART, the host link's or
      # a line grant's, of others by path with the field that names it, is on the console's
      # line; those UARTs may share lines with each other. Every UART here is a placed
      # device-tree device (check_uarts, parameter_value).
      def check_uart_lines(rows, console, others)
        return if console.empty?

        line_of = ->(path) { rows.fetch('devices').find { |device| device['path'] == path }.fetch('line') }
        others.each do |path, field|
          next unless line_of.call(path) == line_of.call(console)

          invalid("console #{console} and UART #{path} share interrupt line #{line_of.call(console)}", 8, field)
        end
      end

      # The holder of the unit whose devices include the device at path.
      def unit_holder(rows, path)
        rows.fetch('units').find do |unit|
          unit_devices(rows.fetch('devices'), unit).any? { |device| device['path'] == path }
        end.fetch('holder')
      end

      def check_lane(value, field)
        unless value.between?(@codec.constant('lane_min'), @codec.constant('lane_max')) && (value & (value - 1)).zero?
          invalid('lane must be a bounded power of two', 4, field)
        end
      end

      def check_catalog
        path = @codec.fixed_bytes('system_manifest_path')
        entries = @context.catalog.select { |row| row.fetch('path') == path }
        unless entries.size == 1 && entries.first.fetch('kind') == @codec.member('entry_kind', 'file') &&
               entries.first.fetch('flags') == @codec.member('entry_flags', 'system') &&
               entries.first.fetch('source') == { 'kind' => 'generated', 'producer' => 'manifest' }
          invalid('reserved manifest path must have its generated system-file row', 1, 'catalog.manifest')
        end
        root = @context.catalog.fetch(@context.root_entry)
        unless root.fetch('kind') == @codec.member('entry_kind', 'image') &&
               (root.fetch('flags') & @codec.member('entry_flags', 'system')) != 0 && root['image'].is_a?(Hash)
          invalid('root is not a system executable', 6, 'catalog.root')
        end
        image = root.fetch('image')
        unless image['magic'] == @codec.constant('image_magic') && image['version'] == @codec.constant('image_version') &&
               image['abi_version'] == @codec.abi_version &&
               image['flags'].is_a?(Integer) && (image.fetch('flags') & @codec.member('image_flags', 'jit')).zero?
          invalid('root image has incompatible ABI or JIT authority', 6, 'catalog.root')
        end
        @codec.encode_layout('erx_image_manifest', image)
        page = @codec.constant('page_size')
        image.fetch('segments').sum do |segment|
          if segment.fetch('prot') == @codec.member('prot', 'rw')
            bytes = segment.fetch('mem_size')
            invalid('root writable segment exceeds its bound', 6, 'catalog.root') if bytes > @codec.constant('image_writable_max')
            ((bytes + page - 1) / page) * page
          else
            0
          end
        end
      end
    end

    # M0's structural fixtures: a partial boot with no services or children.
    class EmptyNative < SystemDomainCheck
      private

      def check_mode(development:, partial:)
        unless partial
          unsupported('full boot needs the production sizing, planner and service consumers', 'mode')
        end
        %w[domain session partial_boot].each do |kind|
          unsupported('child domain planning is unavailable', kind) unless records(kind).empty?
        end
        %w[window service facet introduce image system_image liveness display apps package signer].each do |kind|
          invalid('empty native boot has no service or child assignments', 9, kind) unless records(kind).empty?
        end
        invalid('a partial boot starts no row', 17, 'start') unless records('start').empty?
      end

      def check_device(device)
        unsupported('device allocation needs a checked sizing provider', 'devices.dma') unless device.fetch('dma') == @codec.member('mf_dma', 'none')
        invalid('non-DMA device has a DMA reservation', 4, 'devices.dma_memory') unless device.fetch('dma_memory').zero?
      end

      def check_and_place(_rows, root_memory:, baseline:, max_domains:) = nil

      def claims = { 'mode' => 'empty_native', 'root_startup' => 'unsupported' }
    end

    # Phase 1's check (docs/design-stopgap.md, "The Phase 1 manifest check"): a
    # development manifest, full or partial boot, with the system domain and its
    # configured domains. A holder or server is the system domain or a configured
    # domain, and a grantee one of those or a session template; a domain row's runtime and release name artifacts of this
    # pack; the configured domains are ordered (10), checked against the rescue
    # configuration (11), planned by the domain library's host build (12) and held to
    # the headroom in system (13). What Phase 1 does not bring is refused here.
    class Stopgap < SystemDomainCheck
      REFUSED = {
        'partial_boot' => 'child domains of a partial boot arrive at M5',
        'liveness' => 'the system domain\'s watchdog pets without reading liveness records, which a later milestone brings'
      }.freeze

      private

      def check_mode(development:, partial:)
        unless development
          raise Unsupported.new('a release build needs the confinement check that M11 brings', property: 9, field: 'machine.flags')
        end
        REFUSED.each { |kind, reason| unsupported(reason, kind) unless records(kind).empty? }
        return unless partial

        invalid('a partial boot configures no domains', 12, 'domain') unless records('domain').empty?
        invalid('a partial boot makes no sessions', 14, 'session') unless records('session').empty?
        invalid('a partial boot starts no row', 17, 'start') unless records('start').empty?
        %w[apps package signer].each do |kind|
          invalid('a partial boot takes no packages', 19, kind) unless records(kind).empty?
        end
        %w[service facet introduce liveness display].each do |kind|
          invalid('a partial boot runs no services', 2, kind) unless records(kind).empty?
        end
        invalid('a partial boot has no domain to hold the system partition', 8, 'system_image') unless records('system_image').empty?
      end

      def check_device(device)
        invalid('no domain holds a PCIe function until M9', 3, 'devices.selector') if device.fetch('selector') == @codec.member('mf_selector', 'pci')
        role = device.fetch('role')
        invalid('no domain holds PCIe configuration space until M9', 3, 'devices.role') if role == device_role('configuration')
        invalid('no domain holds a TPM until M11', 7, 'devices.role') if role == device_role('tpm')
        case device.fetch('dma')
        when @codec.member('mf_dma', 'confined')
          unsupported('a confined device needs a DMA window, which M9 brings', 'devices.dma')
        when @codec.member('mf_dma', 'unconfined')
          invalid('an unconfined device needs a memory reservation', 4, 'devices.dma_memory') unless device.fetch('dma_memory').positive?
          # The domain library gives it as one contiguous object.
          if device.fetch('dma_memory') > @codec.constant('mem_contiguous_max')
            invalid('a device memory reservation exceeds mem_contiguous_max', 4, 'devices.dma_memory')
          end
        else
          invalid('non-DMA device has a DMA reservation', 4, 'devices.dma_memory') unless device.fetch('dma_memory').zero?
        end
      end

      def check_and_place(rows, root_memory:, baseline:, max_domains:)
        check_identity(rows.fetch('devices'))
        rows['domains'] = normalize_domains(rows)
        rows['sessions'] = normalize_sessions(rows)
        services = records('service').map { |record| [record, normalize_service(record)] }
                                     .sort_by { |_record, row| [row.fetch('name'), row.fetch('server')] }
        rows['services'] = services.map(&:last)
        invalid('two services of one server share a name', 5, 'service.name') unless
          rows['services'].map { |row| row.values_at('server', 'name') }.uniq.size == services.size
        rows['introductions'] = normalize_introductions
        app_services = check_apps(rows)
        rows['facets'], rows['facet_operations'], rows['facet_parameters'], facet_values =
          normalize_facets(services.map(&:first), rows, app_services)
        rows['starts'] = normalize_starts(services.map(&:first), rows)
        rows['apps'], rows['app_services'] = apps_rows(app_services, rows)
        check_app_start_rows
        rows['signers'] = signer_rows
        rows['development_key'] = @development_key = development_key_rows
        @packages = check_packages
        rows['packages'] = @packages.map { |package| package_row(package) }
        rows['displays'] = normalize_displays(services.map(&:first), rows, facet_values)
        edges = boot_edges(rows['facets'], rows['services'])
        rows['boot_order'] = boot_order(rows['domains'], edges)
        check_rescue(rows['domains'], edges)
        check_facets_supported(rows)
        rows['images'], rows['extents'] = normalize_images(rows.fetch('devices'))
        rows['system_image'] = system_image_rows
        rows['windows'] = normalize_windows(rows)
        check_system_service(rows)
        check_login_keys_service(rows, facet_values)
        RootStartup.check(loadable: root_loadable_bytes, baseline: baseline,
                          root_memory: root_memory, platform: @context.platform)
      end

      def claims
        { 'mode' => 'stopgap', 'root_startup' => 'declared', 'child_plan_instances' => records('domain').size,
          'root_image_loadable_bytes' => root_loadable_bytes,
          'packages' => @packages.map { |package| package.to_h.except(:memory).transform_keys(&:to_s) },
          'signers' => records('signer').map(&:name).sort,
          'development_key' => !@development_key.empty? }.merge(RootStartup.declared(@context.platform))
      end

      def check_identity(devices)
        invalid('host name is not a system identifier', 5, 'machine.host') unless text(@source.machine, 'host').match?(Frontend::IDENTIFIER)
        check_one_holder(devices)
        check_no_sealed_entry
      end

      def root_loadable_bytes
        page = @codec.constant('page_size')
        @context.catalog.fetch(@context.root_entry).fetch('image').fetch('segments').sum do |segment|
          ((segment.fetch('mem_size') + page - 1) / page) * page
        end
      end

      def service_name(record) = record.properties.key?('name') ? text(record, 'name') : record.name.b

      def device_role(name) = @codec.member('mf_device_role', name)

      def check_one_holder(devices)
        paths = devices.filter_map { |device| device['path'] }
        invalid('a device appears in more than one unit', 1, 'devices.path') unless paths.uniq.size == paths.size
      end

      def check_no_sealed_entry
        seal = @codec.member('entry_flags', 'seal')
        return if @context.catalog.none? { |row| (row.fetch('flags') & seal) != 0 }
        invalid('no entry carries the sealing secret until the vault at M11', 7, 'catalog.flags')
      end

      # A pooled name: an identifier, an underscore and decimal digits (docs/design-system.md,
      # "Identifiers").
      POOLED = /\A(?<stem>.+)_[0-9]+\z/.freeze

      # The configured domains in name order, which their references' indices follow.
      # A domain's runtime and release are artifacts of this pack: the runtime an
      # executable entry, the release a domain release's run of entries.
      def normalize_domains(rows)
        principals = rows.fetch('principals').map { |row| row.fetch('name') }
        records('domain').sort_by(&:name).map do |record|
          pooled = record.name.match(POOLED)
          invalid('a configured domain\'s name has a pooled name\'s form', 5, 'domain.name') if pooled&.[](:stem)&.match?(Frontend::IDENTIFIER)
          invalid('a configured domain shares a principal\'s name', 5, 'domain.name') if principals.include?(record.name)
          invalid('the system domain\'s name is not a configured domain\'s', 5, 'domain.name') if record.name == 'system'
          args = boot_args(record, property: 12, field: 'domain.args')
          strings = args.bytesize + words(record, 'env').bytesize
          invalid('arguments and environment exceed the boot page\'s strings', 12, 'domain.args') if
            strings > @codec.constant('boot_strings_max')
          kind = enum(record, 'kind', 'mf_kind')
          invalid('no secret domain until the vault at M11', 7, 'domain.kind') unless kind == @codec.member('mf_kind', 'service')
          runtime = artifact(record, 'runtime', 'executable', property: 12, field: 'domain.runtime')
          release = artifact(record, 'release', 'release', property: 12, field: 'domain.release')
          { 'name' => record.name, 'principal' => reference(record, 'principal', 'principal'), 'kind' => kind,
            'flags' => flags(record, 'flags', 'mf_domain_flags'), 'runtime' => runtime.fetch('entry'),
            'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
            'limits' => reference(record, 'limits', 'limits'), 'restarts' => number(record, 'restarts'),
            'restart_period_s' => number(record, 'restart_period_s'), 'boot_timeout_s' => boot_timeout(record),
            'args' => args, 'env' => words(record, 'env') }
        end
      end

      # The seconds a configured domain's init has to report ready: its row's own, or
      # boot_timeout_default_s where the row states none, from 1 to boot_timeout_max_s,
      # the reader's bound (abi/manifest.txt).
      def boot_timeout(record)
        seconds = if record.properties.key?('boot_timeout_s')
                    number(record, 'boot_timeout_s')
                  else
                    @codec.constant('boot_timeout_default_s')
                  end
        maximum = @codec.constant('boot_timeout_max_s')
        return seconds if seconds.between?(1, maximum)

        invalid("a configured domain's boot timeout of #{seconds} s is outside 1 to #{maximum} s", 'source',
                'domain.boot_timeout_s')
      end

      # Property 14: each session template, keyed by its principal, from which the
      # domain service makes every session of that principal on request
      # (docs/design-system.md, "The system manifest"). A template is not a domain row,
      # so the boot order, the plans and every holder, server and introduction, which
      # resolve through the domain table, never reach one; a facet alone may name it as
      # its grantee (facet_grantee). A `session NAME`
      # record's NAME is its principal's, so a principal has one by the source's own
      # key, and the rows are written in principal order. Its domain makes its
      # programs as sub-spaces, so its limits enable SPACES; the limits are judged
      # against the principal's ceilings, budget and quota when a session is made,
      # on the request path.
      def normalize_sessions(rows)
        spaces = @codec.member('mf_limits_flags', 'spaces')
        templates = records('session').map do |record|
          principal = @indices.fetch('principal')[record.name] ||
                      invalid('a session template names no principal', 14, 'session.name')
          limits = reference(record, 'limits', 'limits')
          invalid('a session template\'s limits do not enable SPACES', 14, 'session.limits') if
            (rows.fetch('limits').fetch(limits).fetch('flags') & spaces).zero?
          args = boot_args(record, property: 14, field: 'session.args')
          invalid('arguments and environment exceed the boot page\'s strings', 14, 'session.args') if
            args.bytesize + words(record, 'env').bytesize > @codec.constant('boot_strings_max')
          # A session's start gives it its principal and display variables after the template's words, which may
          # not shadow them.
          started = %w[principal_key display_key].map { |key| @codec.fixed_bytes(key) }
          invalid('a session template\'s environment sets a variable its start gives it', 14, 'session.env') if
            words(record, 'env').split("\0").any? { |word| started.include?(word.partition('=').first) }
          runtime = artifact(record, 'runtime', 'executable', property: 14, field: 'session.runtime')
          release = artifact(record, 'release', 'release', property: 14, field: 'session.release')
          { 'principal' => principal, 'limits' => limits, 'runtime' => runtime.fetch('entry'),
            'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
            'args' => args, 'env' => words(record, 'env') }
        end.sort_by { |row| row.fetch('principal') }
        @apps == NO_APPS ? templates : [*templates, app_template(rows)]
      end

      # The app template (docs/design-packaging.md, "The apps row"), derived from the
      # apps row and DomainStartup::APP_TEMPLATE, never from a source row: it names no
      # principal, so it sorts last and no source facet's @session.NAME reaches it, and
      # its limits are the manifest's `limits session` record, a session's defaults,
      # which must enable SPACES as every template's do.
      def app_template(rows)
        recipe = DomainStartup::APP_TEMPLATE
        limits = @indices.fetch('limits')['session'] ||
                 invalid('the apps row needs the limits session record its template takes', 19, 'apps')
        invalid('the limits session record the app template takes does not enable SPACES', 19, 'apps') if
          (rows.fetch('limits').fetch(limits).fetch('flags') & @codec.member('mf_limits_flags', 'spaces')).zero?
        runtime = named_artifact(recipe.runtime, 'executable', property: 19, field: 'apps')
        release = named_artifact(recipe.release, 'release', property: 19, field: 'apps')
        { 'principal' => @codec.constant('mf_none'), 'limits' => limits, 'runtime' => runtime.fetch('entry'),
          'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
          'args' => boot_page_args(recipe.args.split(' '), recipe.release), 'env' => recipe.env.b }
      end

      # Whether a facet row is granted to the app template.
      def app_template?(facet, tables)
        facet.fetch('grantee_kind') == grantee_kind('session') &&
          app_session?(tables.fetch('sessions').fetch(facet.fetch('grantee')))
      end

      # Whether a session row is the app template, the one naming no principal.
      def app_session?(session) = session.fetch('principal') == @codec.constant('mf_none')

      # The app template's index among the sessions, nil in a manifest without one.
      def app_template_index(tables) = tables.fetch('sessions').index { |session| app_session?(session) }

      # A domain row's or session template's arguments as its boot page holds them: its
      # emulator flags (the words before the first --), then -- -boot /bin/<name> --,
      # then its init arguments (the words after that --). /bin/<name> is the boot
      # script of the domain release that its `release @artifact.<name>` names
      # (docs/design-stopgap.md, "The production image"). The binding is init's first
      # flag and the second -- closes its value, so no later word (-extra, a final -S)
      # can make it a plain argument and leave init to its default script. Its own
      # arguments naming -boot are refused, since its release names the script.
      # erx_domain_srv:boot_args/2 binds a created domain's the same way.
      def boot_args(record, property:, field:)
        args = words(record, 'args').split("\0")
        invalid('the arguments name -boot, which the release sets', property, field) if args.include?('-boot')
        boot_page_args(args, release_name(record, property: property, field: field.sub('args', 'release')))
      end

      # A word list bound to the boot script of the release named name, as boot_args
      # describes.
      def boot_page_args(args, name)
        emulator, init = args.index('--').then { |at| at ? [args[0...at], args[at + 1..]] : [args, []] }
        [*emulator, '--', '-boot', "/bin/#{name}", '--', *init].map { |word| "#{word}\0" }.join.b
      end

      # The <name> of a record's `release @artifact.<name>`, once artifact has checked that
      # it names a release.
      def release_name(record, property:, field:)
        artifact(record, 'release', 'release', property: property, field: field)
        one(record, 'release').value.delete_prefix('@artifact.')
      end

      # The artifact a record's key names, of the kind the packer recorded for it.
      def artifact(record, key, kind, property:, field:)
        token = one(record, key)
        named = !token.quoted && token.value.start_with?('@artifact.')
        artifact = named ? @context.artifacts[token.value.delete_prefix('@artifact.')] : nil
        invalid("#{key} names no #{kind} artifact of this pack", property, field) unless artifact.is_a?(Hash) && artifact['kind'] == kind
        artifact
      end

      # The artifact of this pack named name, of the kind the packer recorded for it.
      def named_artifact(name, kind, property:, field:)
        artifact = @context.artifacts[name]
        invalid("no #{kind} artifact #{name} in this pack", property, field) unless artifact.is_a?(Hash) && artifact['kind'] == kind
        artifact
      end

      def normalize_service(record)
        name = service_name(record)
        invalid('service name is not a system identifier', 5, 'service.name') unless name.match?(Frontend::IDENTIFIER)
        { 'name' => name, 'server' => holder_index(one(record, 'server'), property: 2, field: 'service.server'),
          'interface' => interface_number(record) }
      end

      # A service's interface number: the name of an interface abi/services declares, as
      # design-abi.md writes it, or a number, which the stopgap also takes for an
      # interface no fragment declares yet. The row holds the number either way, so a
      # check that reasons from a declared interface (property 8's driver control) sees
      # both spellings.
      def interface_number(record)
        token = one(record, 'interface')
        return number(record, 'interface') if token.quoted || token.value.match?(/\A[0-9]/)

        find_interface(token.value) || record.line.fail!('interface names no service abi/services declares')
      end

      # An interface a check reasons from, which the ABI must declare.
      def fetch_interface(name) = find_interface(name) || raise(Erx::Error, "abi/services declares no interface #{name}")

      # The services an app may never take, whatever the apps row says, by name
      # (docs/design-packaging.md, "The build's check", property 19's first clause): the
      # services named packages_service and system_service, which every app holds
      # already, and those that
      # would let an app command the start table, install packages, rewrite
      # /etc/rc.conf or end the machine.
      def app_services_refused
        { @codec.fixed_bytes('packages_service') => 'every app holds its packages grant already',
          @codec.fixed_bytes('system_service') => 'only the derived system rows grant it',
          'start'.b => 'it would let an app command the start table',
          'apps'.b => 'it would let an app install packages',
          'etc'.b => 'it would let an app rewrite /etc/rc.conf',
          'machine'.b => 'it would let an app end the machine' }
      end

      # Property 19's first and seventh clauses; answers the index of each service of the
      # apps row's services, the services the board's sums count max apps holding. No
      # source facet carries a tree, which only a derived row may. Each name is the
      # name of exactly one service of the manifest, none of app_services_refused, of an
      # interface an ABI file declares, which gives every parameter a default (an optional
      # parameter), since an app's row is granted with no parameter stated, and every
      # quantity (derived_quantities). A service of the inspect interface is refused until
      # the scope an app principal gets is checked to be its own, never all, and one of
      # the files interface until the storage service's `tree apps` roots its grant at
      # the app's own directory, by interface, whatever its name.
      def check_apps(tables)
        invalid('a facet of the source carries a tree, which only the rows the build derives may', 19, 'facet.parameter') if
          records('facet').any? { |record| record.parameters.any? { |key, _value| key.value == 'tree' } }
        service_rows = tables.fetch('services')
        refused = app_services_refused
        indices = @apps.services.map do |name|
          reason = refused[name.b]
          invalid("services names #{name}: #{reason}", 19, 'apps.services') if reason
          matching = service_rows.each_index.select { |index| service_rows.fetch(index).fetch('name') == name.b }
          invalid("services names #{name}, which is not the name of one service of the manifest", 19, 'apps.services') unless
            matching.size == 1
          interface = service_rows.fetch(matching.first).fetch('interface')
          unsupported("services names #{name}, of the inspect interface, whose scope for an app is not checked", 'apps.services') if
            interface == fetch_interface('inspect')
          unsupported("services names #{name}, of the files interface, whose grant no tree apps roots yet", 'apps.services') if
            interface == fetch_interface('files')
          declared = declared_parameters(interface) ||
                     invalid("services names #{name}, whose interface no ABI file declares", 19, 'apps.services')
          required = declared.select { |_key, parameter| parameter.fetch(:cardinality) == 'one' }.keys
          invalid("services names #{name}, whose interface gives #{required.join(', ')} no default", 19, 'apps.services') unless
            required.empty?
          derived_quantities(interface, name)
          matching.first
        end
        indices.freeze
      end

      # The quantities of a facet row the build derives for a service of interface: those
      # its ABI file's quantity lines give (docs/design-abi.md, "Services, facets and their
      # parameter schemas"), every one of them required, and queue, which resolves to
      # system_queue as a source row's does when it states none.
      def derived_quantities(interface, name)
        declared = @codec.schema.services.find { |service| service.fetch(:number) == interface }&.fetch(:quantities) || {}
        missing = ABI::Contracts::FACET_QUANTITIES - declared.keys
        invalid("services names #{name}, whose interface declares no #{missing.join(', ')}", 19, 'apps.services') unless
          missing.empty?
        declared.merge('queue' => number(@source.machine, 'system_queue'))
      end

      # The facet rows the build derives from the apps row (docs/design-packaging.md, "The
      # apps row"), none without one: the system domain's grant of the service named
      # packages_service, rights rw, rooted at the tree's root, and the app template's,
      # rights rx and tree installed, rooted at installed/, where no upload in progress
      # lies; the system domain's grant of the service named system_service, rights ro, and
      # the template's, rights rx; the template's two grants are rx because an app's session
      # mounts its installed or image package at /app through one of them
      # (design-files.md F6: an rx mount only through an rx grant); and the template's grant
      # of each service of app_services, which states no parameter. Each is named as its
      # service is and takes derived_quantities. Answers each row with its resolved
      # parameter values, as normalize_facets builds a source row's.
      def app_facets(tables, app_services)
        return [] if @apps == NO_APPS

        service_rows = tables.fetch('services')
        packages = fetch_files_service(service_rows, 'packages_service', required_by: 'an apps row')
        tree = fetch_files_service(service_rows, 'system_service', required_by: 'an apps row')
        template = [grantee_kind('session'), app_template_index(tables)]
        system = [grantee_kind('system'), 0]
        [[system, packages, { 'rights' => 'rw' }], [template, packages, { 'rights' => 'rx', 'tree' => 'installed' }],
         [system, tree, { 'rights' => 'ro' }], [template, tree, { 'rights' => 'rx' }],
         *app_services.map { |service| [template, service, {}] }].map do |grantee, service, values|
          derived_facet(service_rows, grantee, service, values)
        end
      end

      # The home rows (docs/design-files.md, "A user's home"): for every session template
      # but the app template, a grant of the service named home_service, rights rw and
      # tree home, which roots it at the home of the session's user; none in a manifest
      # without that service. Answers each row as app_facets does.
      def home_facets(tables)
        service_rows = tables.fetch('services')
        name = @codec.fixed_bytes('home_service')
        return [] unless service_rows.any? { |row| row.fetch('name') == name }

        home = fetch_files_service(service_rows, 'home_service', required_by: 'a home service')
        sessions = tables.fetch('sessions')
        sessions.each_index.reject { |template| app_session?(sessions.fetch(template)) }.map do |template|
          derived_facet(service_rows, [grantee_kind('session'), template], home, { 'rights' => 'rw', 'tree' => 'home' })
        end
      end

      # One row the build derives: the grant of service to grantee, [kind, index], named
      # as its service is, with no operation and derived_quantities, paired with its
      # parameter values.
      def derived_facet(service_rows, (kind, grantee), service, values)
        row = service_rows.fetch(service)
        facet = { 'name' => row.fetch('name'), 'grantee_kind' => kind, 'grantee' => grantee, 'service' => service,
                  'operations' => { 'table' => 'facet_operations', 'first' => 0, 'count' => 0 },
                  **derived_quantities(row.fetch('interface'), row.fetch('name')) }
        [facet, values.freeze]
      end

      # The index of the one service named by the machine constant name, of the files
      # interface, which property 19 requires of a manifest with an apps row
      # (packages_service and system_service, app_facets) and of one with a system window
      # (system_service, its eighth clause), required_by naming which.
      def fetch_files_service(service_rows, name, required_by:)
        bytes = @codec.fixed_bytes(name)
        named = service_rows.each_index.select { |index| service_rows.fetch(index).fetch('name') == bytes }
        invalid("a manifest with #{required_by} holds one service named #{bytes}", 19, 'service.name') unless named.size == 1
        invalid("the service named #{bytes} is of the files interface", 19, 'service.interface') unless
          service_rows.fetch(named.first).fetch('interface') == fetch_interface('files')
        named.first
      end

      # Property 19's third clause: the start rows and every app's row fit the start table.
      def check_app_start_rows
        rows_max = @codec.constant('start_rows_max')
        invalid("the start rows and the apps row's max pass start_rows_max, #{rows_max}", 19, 'apps.max') if
          records('start').size + @apps.max > rows_max
      end

      # The packed apps row and its app_services rows: none without an apps row, and
      # otherwise the row, with the indices of the app template (app_template_index),
      # and of its packages and system facet rows, and its services, the indices check_apps resolved,
      # ascending, each with the index of the facet row granted to the template for it.
      # The rows are the ones app_facets derived, found by grantee and service, which no
      # source row shares with them: no source row names the template.
      def apps_rows(service_indices, tables)
        return [[], []] if @apps == NO_APPS

        template = app_template_index(tables)
        facets = tables.fetch('facets')
        tree = ->(name) { fetch_files_service(tables.fetch('services'), name, required_by: 'an apps row') }
        granted = lambda do |service|
          facets.index do |facet|
            facet.fetch('grantee_kind') == grantee_kind('session') && facet.fetch('grantee') == template &&
              facet.fetch('service') == service
          end
        end
        services = service_indices.sort.map { |index| { 'service' => index, 'facet' => granted.call(index) } }
        [[{ 'memory' => @apps.memory, 'max' => @apps.max, 'app_template' => template,
            'packages_facet' => granted.call(tree.call('packages_service')),
            'system_facet' => granted.call(tree.call('system_service')),
            'services' => { 'table' => 'app_services', 'first' => 0, 'count' => services.size } }], services]
      end

      # Property 19's sixth clause, and the signer rows it packs, sorted by name: every
      # signer row holds an Ed25519 public key of signer_key_bytes, written hex: and its
      # digits, never quoted, and none is named development, the name the machine gives
      # the build's development package key (development_key_rows), so no source row
      # stands in for it. The frontend keeps the rows' names unique.
      def signer_rows
        size = @codec.constant('signer_key_bytes')
        records('signer').sort_by { |record| record.name.b }.map do |record|
          invalid("signer #{DEVELOPMENT_SIGNER} is the build's development package key, never a row", 19, 'signer.name') if
            record.name == DEVELOPMENT_SIGNER
          record.line.fail!('key requires hexadecimal bytes, hex:...') if one(record, 'key').quoted
          key = text(record, 'key')
          invalid("signer #{record.name}'s key is not #{size} bytes", 19, 'signer.key') unless key.bytesize == size
          { 'name' => record.name, 'key' => key.bytes }
        end
      end

      # The build's development package key, packed as its own record, which only a
      # development manifest holds (docs/design-packaging.md, "The SDK"; Context admits
      # it only in a development build): none when the build context carries none or the
      # manifest has no apps row, whose machine takes no packages and so trusts no key, and
      # refused when it is not an Ed25519 public key of signer_key_bytes. A build therefore
      # hands every development check its key, whatever the manifest's mode.
      def development_key_rows
        key = @context.development_key
        return [] if key.nil? || @apps == NO_APPS

        size = @codec.constant('signer_key_bytes')
        invalid("the development package key is not #{size} bytes", 19, 'context.development_key') unless key.bytesize == size
        [{ 'key' => key.bytes }]
      end

      # The booted slot's system partition (docs/design-stopgap.md, "The booted slot"),
      # packed as its one system_image record from the erofs_image artifact the nameless
      # system_image row's input names, as ReleaseMedium.image records it: the image one
      # extent from the partition's start (checked_extents keeps it inside the partition),
      # and its tree, whole blocks from where the image ends and inside the partition,
      # with a salt of 1 to 32 bytes and a 32-byte root hash in lowercase hex. None
      # without the row.
      def system_image_rows
        record = records('system_image').first
        return [] unless record

        artifact = artifact(record, 'input', 'erofs_image', property: 8, field: 'system_image.input')
        extents = checked_extents(artifact, field: 'system_image.input')
        invalid('the system image is one extent at its partition\'s start', 8, 'system_image.input') unless
          extents.size == 1 && extents.first.fetch('slot_offset').zero?
        length = extents.first.fetch('length')
        tree = artifact['tree']
        case tree.is_a?(Hash) && tree.values_at('offset', 'length', 'salt', 'root_hash')
        in [Integer => offset, Integer => bytes, /\A(?:[0-9a-f]{2}){1,32}\z/ => salt, /\A[0-9a-f]{64}\z/ => root]
          partition = @codec.constant('medium_system_sectors') * @codec.constant('mbr_sector_size')
          invalid('the system image\'s tree is whole blocks from the image\'s end, inside the partition', 8, 'system_image.input') unless
            offset == length && !bytes.negative? && (bytes % @codec.constant('page_size')).zero? && offset + bytes <= partition
        else
          invalid('the system image\'s tree names its offset, length, salt and root hash', 8, 'system_image.input')
        end
        salt = [salt].pack('H*')
        [{ 'image_length' => length, 'tree_offset' => offset, 'tree_length' => bytes, 'salt_length' => salt.bytesize,
           'reserved' => 0, 'salt' => salt.ljust(32, "\0").bytes, 'root_hash' => [root].pack('H*').bytes }]
      end

      # A package row as the manifest packs it (erx_mf_package).
      def package_row(package)
        { 'name' => package.name, 'flags' => package.enabled ? @codec.member('mf_package_flags', 'enabled') : 0,
          'sha256' => [package.sha256].pack('H*').bytes }
      end

      # Property 19's fifth clause on the package rows the image builder adds
      # (Erx::ImageApps), as far as the host can judge it without admission: each row's
      # input is a package artifact of this pack, which the build's file check decoded
      # under the row's own name; the rows number at most the apps row's max, so none
      # without an apps row; and the declared memory of the enabled ones sums within the
      # apps budget. Answers each row as a Package, sorted by name.
      def check_packages
        packages = records('package').sort_by { |record| record.name.b }
        invalid("the package rows pass the apps row's max, #{@apps.max}", 19, 'package') if packages.size > @apps.max
        rows = packages.map do |record|
          package = artifact(record, 'input', 'package', property: 19, field: 'package.input')
          invalid("package #{record.name}'s input is the package of #{package['name']}", 19, 'package.input') unless
            package['name'] == record.name
          enabled = record.properties.key?('enable') && start_flags(record).positive?
          Package.new(name: record.name, sha256: package.fetch('sha256'), enabled: enabled, memory: package.fetch('memory'))
        end
        memory = rows.select(&:enabled).sum(&:memory)
        invalid("the enabled packages declare #{memory} bytes, past the apps budget of #{@apps.memory}", 19, 'package.enable') if
          memory > @apps.memory
        rows.freeze
      end

      # The ABI file's declaration of interface, or nil when no ABI file declares it.
      def service_declaration(interface) = @codec.schema.services.find { |service| service.fetch(:number) == interface }

      # The parameters an ABI file declares for interface, by key, or nil when no ABI
      # file declares the interface.
      def declared_parameters(interface) = service_declaration(interface)&.fetch(:parameters)

      # The grant checker the service of interface names in its parameters' checked_by,
      # one for all of them (abi_contracts.rb), or nil for a service with no parameter.
      def grant_checker(interface) = service_declaration(interface)&.fetch(:checked_by)

      # The manifest's start rows, sorted by their principal's index, each with its
      # defaults applied: enabled, no display and start_restarts_default ends in
      # start_period_default_s seconds (abi/manifest.txt). Property 17's structural clauses: a row is keyed
      # by its principal's name, so the frontend gives a principal at most one, and that
      # principal has a session template; no two enabled rows name one display; and a
      # display is a service of the windows interface that a facet row grants the
      # principal's template. Property 17's last
      # clause, that the enabled rows' sessions fit beside the configured domains, is the
      # domain library's judgment, in check_plans.
      def normalize_starts(services, tables)
        rows = records('start').map { |record| start_row(record, services, tables.fetch('sessions')) }
        enabled = @codec.member('mf_start_flags', 'enabled')
        none = @codec.constant('mf_none')
        displays = rows.select { |row| (row.fetch('flags') & enabled) != 0 }.map { |row| row.fetch('display') } - [none]
        invalid('two enabled start rows name one display', 17, 'start.display') unless displays.uniq.size == displays.size
        rows.reject { |row| row.fetch('display') == none }.each { |row| check_start_display(row, tables) }
        rows.sort_by { |row| row.fetch('principal') }
      end

      # One start row: its principal's index, which must have a session template, and
      # each field the record states or its default. The period is at least a second,
      # since the row's supervisor takes it as its own, and neither field is past its
      # ceiling in abi/manifest.txt, which the reader and the start table also hold to.
      def start_row(record, services, sessions)
        principal = @indices.fetch('principal')[record.name] || invalid('a start row names no principal', 17, 'start.name')
        invalid('a start row\'s principal has no session template', 17, 'start.name') unless
          sessions.any? { |row| row.fetch('principal') == principal }
        stated = ->(key, default, &value) { record.properties.key?(key) ? value.call(key) : default }
        row = { 'principal' => principal,
                'flags' => stated.call('enable', @codec.member('mf_start_flags', 'enabled')) { start_flags(record) },
                'display' => stated.call('display', @codec.constant('mf_none')) { start_display(record, services) },
                'restarts' => stated.call('restarts', @codec.constant('start_restarts_default')) { |key| number(record, key) },
                'restart_period_s' => stated.call('restart_period_s', @codec.constant('start_period_default_s')) { |key| number(record, key) } }
        invalid('a start row\'s restart period is under a second', 17, 'start.restart_period_s') if row.fetch('restart_period_s').zero?
        check_start_ceiling(row, 'restarts', 'start_restarts_max')
        check_start_ceiling(row, 'restart_period_s', 'start_period_max_s')
        row
      end

      # A start row's field Key is at most the ABI's limit Limit.
      def check_start_ceiling(row, key, limit)
        ceiling = @codec.constant(limit)
        invalid("a start row's #{key} is over #{ceiling}", 17, "start.#{key}") if row.fetch(key) > ceiling
      end

      # A row's enable: YES or NO, as rc.conf(5) writes it.
      def start_flags(record)
        token = one(record, 'enable')
        record.line.fail!('enable is YES or NO') if token.quoted || !%w[YES NO].include?(token.value)
        token.value == 'YES' ? @codec.member('mf_start_flags', 'enabled') : 0
      end

      # A row's display, @service.NAME, as the service's index in the sorted service table.
      def start_display(record, services)
        token = one(record, 'display')
        services.index { |service| !token.quoted && "@service.#{service.name}" == token.value } ||
          invalid('a start row\'s display names a service the manifest does not contain', 17, 'start.display')
      end

      # A row's display: a service of the windows interface, granted to the row's
      # principal's session template by a facet row.
      def check_start_display(row, tables)
        windows = find_interface('windows') ||
                  invalid('a start row names a display, and abi/services declares no windows interface', 17, 'start.display')
        display = row.fetch('display')
        invalid('a start row\'s display is not a windows service', 17, 'start.display') unless
          tables.fetch('services').fetch(display).fetch('interface') == windows
        session = tables.fetch('sessions').index { |template| template.fetch('principal') == row.fetch('principal') }
        grant = [grantee_kind('session'), session, display]
        invalid('a start row\'s display is not granted to its principal\'s session template', 17, 'start.display') unless
          tables.fetch('facets').any? { |facet| facet.values_at('grantee_kind', 'grantee', 'service') == grant }
      end

      # design-abi.md: an introduction joins two different configured domains and is
      # unique as an unordered pair, so each is written with the lower index first.
      def normalize_introductions
        rows = records('introduce').map do |record|
          pair = record.properties.fetch('targets').map do |token|
            domain_index(token) || invalid('introduction names no configured domain', 2, 'introduce')
          end
          invalid('an introduction joins two different domains', 2, 'introduce') unless pair.uniq.size == 2
          { 'from' => pair.min, 'to' => pair.max }
        end
        invalid('two introductions join one pair', 2, 'introduce') unless rows.uniq.size == rows.size
        rows.sort_by { |row| row.values_at('from', 'to') }
      end

      # Each facet row, sorted by name qualified by its grantee: its grantee (facet_grantee),
      # its service's index in the sorted service table and the grant's limits, an omitted
      # queue resolved to system_queue. A facet is installed in its grantee's registry
      # under its service's name (docs/design-system.md, "Facets a configured domain
      # serves"), so a grantee takes at most one facet of a service name, whichever domain
      # serves it (property 2); and the system domain takes no facet of its own service. A
      # session template may take a facet of a configured domain's service, which the
      # server grants each session made from it, or of a system-served one, which the
      # domain service starts for each such session (property 14). A facet of the
      # driver-control interface stops and starts another domain's drivers, so only the
      # system domain holds one (property 8); the network's facets are property 15's
      # (check_network_grants), and the files and inspect receivers' floors property 16's
      # (check_files_grants, check_inspect_grants). Each facet's parameters are resolved
      # against its service's declarations (facet_parameters), and its operations against
      # its interface's (facet_operations). Answers the sorted rows, each with its
      # operations and parameters spans, the facet_operations and facet_parameters tables
      # and each row's resolved parameter values, by key name, in the rows' order.
      def normalize_facets(services, tables, app_services)
        service_rows = tables.fetch('services')
        sources = records('facet').map do |record|
          token = one(record, 'service')
          index = services.index { |service| !token.quoted && "@service.#{service.name}" == token.value }
          invalid('facet names a service the manifest does not contain', 2, 'facet.service') unless index
          facet_row(record, index, tables.fetch('sessions'))
        end
        home = @codec.fixed_bytes('home_service')
        invalid('a facet of the source grants the home service, whose rows only the build derives', 19, 'facet.service') if
          sources.any? { |row| service_rows.fetch(row.fetch('service')).fetch('name') == home }
        derived = app_facets(tables, app_services) + home_facets(tables)
        rows = sources + derived.map(&:first)
        packed = records('facet').zip(sources).map { |record, row| facet_parameters(record, row, tables) } +
                 derived.map { |row, values| pack_parameters(values, granted_parameters(row, tables)) }
        grantee = ->(row) { row.values_at('grantee_kind', 'grantee') }
        server = ->(row) { service_rows.fetch(row.fetch('service')).fetch('server') }
        none = @codec.constant('mf_none')
        invalid('two facets of one grantee share a name', 5, 'facet.name') unless
          rows.map { |row| [grantee.call(row), row.fetch('name')] }.uniq.size == rows.size
        taken = rows.map { |row| [grantee.call(row), service_rows.fetch(row.fetch('service')).fetch('name')] }
        invalid('a grantee takes two facets of one service name', 2, 'facet.service') unless taken.uniq.size == taken.size
        invalid('the system domain takes no facet of its own service', 2, 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') == grantee_kind('system') && server.call(row) == none }
        control = fetch_interface('driver_control')
        invalid('only the system domain holds a driver-control facet', 8, 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') != grantee_kind('system') && service_rows.fetch(row.fetch('service')).fetch('interface') == control }
        # The domain service grants every session its code_objects facet by its own policy
        # (docs/design-system.md, "The code_objects facet"), so no row grants one: not to a
        # configured domain, and not to a template, whose limits would replace the service's.
        invalid('no facet row grants code_objects, which the domain service grants every session', 8, 'facet.service') unless
          facets_of(rows, 'code_objects', tables).empty?
        check_code_objects_service(service_rows)
        check_data_grants(rows, packed.map(&:first), tables)
        check_network_grants(rows, packed.map(&:first), tables)
        check_files_grants(rows, tables)
        check_inspect_grants(rows, tables)
        check_line_grants(rows, packed.map(&:first), tables)
        operations = records('facet').zip(sources).map { |record, row| facet_operations(record, row, service_rows) } +
                     derived.map { [] }
        order = rows.each_index.sort_by { |at| [rows.fetch(at).fetch('name'), *grantee.call(rows.fetch(at))] }
        facets = order.zip(spans(order.map { |at| operations.fetch(at) }, 'facet_operations'),
                           spans(order.map { |at| packed.fetch(at).last }, 'facet_parameters')).map do |at, named, stated|
          rows.fetch(at).merge('operations' => named, 'parameters' => stated)
        end
        [facets, order.flat_map { |at| operations.fetch(at) }.map { |number| { 'operation' => number } },
         order.flat_map { |at| packed.fetch(at).last }, order.map { |at| packed.fetch(at).first }]
      end

      # One span of table per list, each list's rows following the last's from row 0.
      def spans(lists, table)
        lists.each_with_object([]) do |list, result|
          first = result.empty? ? 0 : result.last.fetch('first') + result.last.fetch('count')
          result << { 'table' => table, 'first' => first, 'count' => list.size }
        end
      end

      # A facet record's operations, `none` or a comma-separated list of the names its
      # service's interface declares, each once (property 2), as their numbers in ascending
      # order, the facet_operations rows its span takes (docs/design-abi.md, "Services,
      # facets and their parameter schemas"). Which rows the stopgap can honour is
      # check_facets_supported's.
      def facet_operations(record, row, service_rows)
        token = one(record, 'operations')
        return [] if !token.quoted && token.value == 'none'

        declared = service_declaration(service_rows.fetch(row.fetch('service')).fetch('interface'))&.fetch(:operations) || {}
        record.line.fail!('operations requires none or unquoted operation names') if token.quoted
        names = token.value.split(',', -1)
        numbers = names.map { |name| declared[name] }
        invalid("facet #{row.fetch('name')}'s operations name an operation its interface does not declare", 2, 'facet.operations') if
          names.empty? || numbers.include?(nil)
        invalid("facet #{row.fetch('name')}'s operations name one twice", 2, 'facet.operations') unless names.uniq.size == names.size
        numbers.sort
      end

      # The checkers that consume a service's declared parameters, by the name its
      # declarations give in checked_by, each with the keys it consumes (docs/design-abi.md,
      # "Services, facets and their parameter schemas"): windows_grant is property 18,
      # check_display_grants, which reads pixels and session, and range-checks windows and
      # clipboard as their declarations bound them. line_grant is property 8's line clause,
      # check_line_grants, which reads uart and flow and range-checks rate. net_grant is
      # property 15's parameter clause, check_net_ports, which reads a net facet's ports and
      # listen; its sockets and buffers their declarations alone bound, and the grant
      # enforces all four at run time (abi/services/net.txt). files_grant takes a files
      # facet's rights and tree, whose member kinds alone bound them to their members, and
      # which the grant applies at run time; property 19 lets only a derived row state a
      # tree. A service declaring a parameter that no checker here consumes is unusable: no
      # facet of it is admitted, since nothing would check what it grants. Each checker
      # takes the facets of the services that name it (grant_checker), whatever their
      # interface.
      GRANT_CHECKERS = { 'windows_grant' => %w[windows pixels clipboard session].freeze,
                         'line_grant' => %w[uart rate flow].freeze,
                         'net_grant' => %w[sockets buffers ports listen].freeze,
                         'files_grant' => %w[rights tree].freeze }.freeze

      # A facet record's parameters resolved against its service's declarations: every
      # stated key is declared, appears once and has a value of its declared kind within
      # its bound, and every key declared one is stated. Answers the values, by key name,
      # and their packed facet_parameters rows in key order.
      def facet_parameters(record, row, tables)
        declared = granted_parameters(row, tables)
        pack_parameters(resolve_parameters(record, declared, tables.fetch('devices')), declared)
      end

      # The parameters a facet row's service declares, by key, each consumed by a grant
      # checker of GRANT_CHECKERS, or the row is refused as unsupported.
      def granted_parameters(row, tables)
        declared = declared_parameters(tables.fetch('services').fetch(row.fetch('service')).fetch('interface')) || {}
        return declared if declared.all? { |key, parameter| GRANT_CHECKERS.fetch(parameter.fetch(:helper), []).include?(key) }

        unsupported("facet #{row.fetch('name')}'s service declares a parameter no grant checker consumes", 'facet.parameter')
      end

      # Resolved parameter values, by key, and their packed facet_parameters rows in key
      # order, a set's one row an element, in ascending order of its elements.
      def pack_parameters(values, declared)
        rows = values.flat_map do |key, value|
          parameter = declared.fetch(key)
          parameter.fetch(:cardinality) == 'set' ? value.map { |item| parameter_row(parameter, item) } : [parameter_row(parameter, value)]
        end
        [values.freeze, rows.sort_by { |item| item.values_at('key', 'scalar') }]
      end

      # A facet record's parameter lines, KEY VALUE, as a map from key to value, a device
      # reference resolved against devices, the placed device rows. A set's lines, one an
      # element, give it the array of their values in ascending order: at most its
      # MAX_COUNT of them, and none twice. Every other key is stated at most once.
      def resolve_parameters(record, declared, devices)
        values = record.parameters.each_with_object({}) do |(key_token, value_token), result|
          key = key_token.value
          parameter = (!key_token.quoted && declared[key]) ||
                      invalid("facet parameter #{key} is not declared by its service", 2, 'facet.parameter')
          value = parameter_value(key, parameter, value_token, record.line, devices)
          if parameter.fetch(:cardinality) == 'set'
            set = result.fetch(key, [])
            invalid("facet parameter #{key} states #{value} twice", 2, 'facet.parameter') if set.include?(value)
            invalid("facet parameter #{key} states over #{parameter.fetch(:maximum_count)} values", 2, 'facet.parameter') if
              set.size == parameter.fetch(:maximum_count)
            result[key] = (set + [value]).sort.freeze
          else
            invalid("facet parameter #{key} is stated twice", 2, 'facet.parameter') if result.key?(key)
            result[key] = value
          end
        end
        declared.each do |key, parameter|
          invalid("facet parameter #{key} is required", 2, 'facet.parameter') if parameter.fetch(:cardinality) == 'one' && !values.key?(key)
        end
        values
      end

      # One value of its declared kind: an integer within its range, yes or no for a
      # boolean, quoted bytes within their bound, the bare name of one of a member kind's
      # members, which is the value, or for a device reference the index in devices of the
      # device-tree row at the quoted path, which its grant checker judges
      # (docs/design-abi.md, "Services, facets and their parameter schemas"); a set's
      # element is one value of its kind, which is u64 (the ABI reader refuses a set of
      # another). The domain and principal references are refused while no service
      # declares one, so nothing here guesses their spelling.
      def parameter_value(key, parameter, token, line, devices)
        kind = parameter.fetch(:kind)
        case kind
        when 'u64', 'i64'
          line.fail!("parameter #{key} requires an integer") if token.quoted
          value = ABI::Syntax.integer(token.value, line: line)
          low, high = parameter.fetch(:bound).drop(1).map { |word| ABI::Syntax.integer(word, line: line) }
          invalid("facet parameter #{key} is outside #{low} to #{high}", 2, 'facet.parameter') unless value.between?(low, high)
          value
        when 'boolean'
          line.fail!("parameter #{key} is yes or no") if token.quoted || !%w[yes no].include?(token.value)
          token.value == 'yes'
        when 'identifier', 'namespace_path', 'bytes'
          line.fail!("parameter #{key} requires quoted bytes") unless token.quoted
          value = token.value.b
          maximum = Integer(parameter.fetch(:bound).last)
          invalid("facet parameter #{key} is empty or over #{maximum} bytes", 2, 'facet.parameter') unless
            value.bytesize.between?(kind == 'bytes' ? 0 : 1, maximum)
          value
        when 'member'
          members = parameter.fetch(:members)
          line.fail!("parameter #{key} is one of #{members.join(', ')}") if token.quoted || !members.include?(token.value)
          token.value
        when 'device'
          line.fail!("parameter #{key} requires a quoted device-tree path") unless token.quoted
          dt = @codec.member('mf_selector', 'dt')
          devices.index { |device| device.fetch('selector') == dt && device['path'] == token.value } ||
            invalid("facet parameter #{key} names no placed device", 2, 'facet.parameter')
        else
          unsupported("facet parameter #{key} is a #{kind} reference, which no service declares", 'facet.parameter')
        end
      end

      # A resolved value as its packed facet_parameters row, every inactive field zero.
      def parameter_row(parameter, value)
        kind = parameter.fetch(:kind)
        row = { 'key' => parameter.fetch(:number), 'kind' => @codec.member('mf_parameter_kind', kind),
                'scalar' => 0, 'bytes' => ''.b, 'index' => 0, 'reserved' => 0 }
        case kind
        when 'u64' then row.merge('scalar' => value)
        when 'i64' then row.merge('scalar' => value & ((1 << 64) - 1))
        when 'boolean' then row.merge('scalar' => value ? 1 : 0)
        when 'member' then row.merge('scalar' => parameter.fetch(:minimum) + parameter.fetch(:members).index(value))
        when 'device' then row.merge('index' => value)
        else row.merge('bytes' => value)
        end
      end

      # Property 8's clause for the line interface (docs/design-system.md, "The manifest";
      # docs/design-bluetooth.md, "The controller's line"). The system domain serves every
      # line service. Of its services, the one named line is exactly the one of the line
      # interface, so the name the Erlang side keys on (erx_uart_sup:line_grants/1, the
      # serve call, the facet-names check, erx_ns:place/1) and the interface the root keys
      # on (boot_manifest.c) pick the same service. Each grant of a line service, of facets
      # with values, their resolved parameters in the same order, names by its uart a UART
      # whose unit the system domain holds, which is neither the console's nor the host
      # link's, is not on the console's interrupt line (check_uart_lines) and which no
      # other grant names, and holds flow to none or rts_cts. The grantee is a configured
      # domain, which mounts the tree its application start reads. The manifest grants the
      # interface at most once, since one line service serves one line (TODO.md, the line's
      # service side); the duplicate check runs first, so it holds once that limit is lifted.
      def check_line_grants(facets, values, tables)
        line = ->(service) { grant_checker(service.fetch('interface')) == 'line_grant' }
        system = @codec.constant('mf_none')
        if tables.fetch('services').any? { |row| line.call(row) && row.fetch('server') != system }
          invalid('only the system domain serves the line interface', 8, 'service.server')
        end
        interface = find_interface('line')
        misnamed = tables.fetch('services').find do |row|
          row.fetch('server') == system && (row.fetch('interface') == interface) != (row.fetch('name') == 'line')
        end
        if misnamed
          invalid("the system domain's service #{misnamed.fetch('name')} is named line exactly when it is of the line " \
                  'interface', 8, 'service.name')
        end
        grants = facets.zip(values).select { |row, _| line.call(tables.fetch('services').fetch(row.fetch('service'))) }
        console = @context.platform['console']
        reserved = [console, @context.platform.fetch('hostlink', '')]
        uarts = grants.map do |row, given|
          named = "line grant #{row.fetch('name')}"
          invalid("#{named} is granted to no configured domain", 8, 'facet.grantee') unless row.fetch('grantee_kind') == grantee_kind('domain')
          device = tables.fetch('devices').fetch(given.fetch('uart'))
          path = device.fetch('path')
          invalid("#{named}'s uart #{path} names no UART", 8, 'facet.parameter') unless device.fetch('role') == device_role('uart')
          invalid("#{named}'s uart #{path} is the console's or the host link's", 8, 'facet.parameter') if reserved.include?(path)
          unless unit_holder(tables, path) == @codec.constant('mf_none')
            invalid("#{named}'s uart #{path} is not the system domain's", 8, 'facet.parameter')
          end
          invalid("#{named}'s flow is none or rts_cts", 8, 'facet.parameter') unless %w[none rts_cts].include?(given.fetch('flow'))
          given.fetch('uart')
        end
        check_uart_lines(tables, console, uarts.to_h { |uart| [tables.fetch('devices').fetch(uart).fetch('path'), 'facet.parameter'] })
        invalid('two line grants name one UART', 8, 'facet.parameter') unless uarts.uniq.size == uarts.size
        invalid('a manifest holds at most one line grant', 8, 'facet.service') if grants.size > 1
      end

      # The displays (docs/design-display.md, "A display's session"), sorted by their
      # service's index; facet_values holds each facet row's resolved parameters, by the
      # facet table's index. A display record is keyed by its service's source alias, so
      # a service has at most one. Property 18: every service whose parameters name
      # windows_grant (grant_checker), of the windows interface or another, has a record and
      # every record names one; a display domain serves one display, so no domain pays
      # for two displays' grants out of one outer budget; and each display's grants pass
      # check_display_grants.
      def normalize_displays(services, tables, facet_values)
        display = ->(service) { grant_checker(service.fetch('interface')) == 'windows_grant' }
        rows = records('display').map do |record|
          index = services.index { |service| service.name == record.name } ||
                  invalid('a display record names a service the manifest does not contain', 18, 'display.name')
          invalid('a display record names a service whose parameters are not checked by windows_grant', 18, 'display.name') unless
            display.call(tables.fetch('services').fetch(index))
          display_row(record, index)
        end
        tables.fetch('services').each_with_index do |service, index|
          next unless display.call(service)
          invalid("service #{service.fetch('name')}, checked by windows_grant, has no display record", 18, 'display.name') unless
            rows.any? { |row| row.fetch('service') == index }
        end
        servers = rows.map { |row| tables.fetch('services').fetch(row.fetch('service')).fetch('server') }
        invalid('one domain serves two displays', 18, 'display.name') unless servers.uniq.size == servers.size
        rows.each { |row| check_display_grants(row, tables, facet_values) }
        rows.sort_by { |row| row.fetch('service') }
      end

      # One display record: its service's index, its policy and its idle times, of
      # which a nonzero time to turn the panel off comes no sooner than the time to dim it.
      def display_row(record, service)
        row = { 'service' => service, 'policy' => enum(record, 'policy', 'mf_display_policy') }
        %w[idle_dim_s idle_off_s].each do |key|
          row[key] = number(record, key)
          invalid("a display's #{key} is over #{(1 << 32) - 1}", 18, "display.#{key}") if row.fetch(key) >= (1 << 32)
        end
        invalid('a display turns its panel off before it dims it', 18, 'display.idle_off_s') unless
          row.fetch('idle_off_s').zero? || row.fetch('idle_off_s') >= row.fetch('idle_dim_s')
        row
      end

      # The environment keys a display domain takes from its display record, which its own
      # row may not set (abi/manifest.txt, display_key and the keys after it).
      def display_keys = %w[display_key display_policy_key display_idle_dim_key display_idle_off_key]
                         .map { |name| @codec.fixed_bytes(name) }

      # Property 18's clauses on one display's grants: its server is a configured
      # domain whose row sets none of display_keys, no facet row of its service grants it to the system domain, whose
      # connections no introduction makes and so carry no pixel area, no facet row of
      # its service sets session, and the grants' costs fit the
      # display domain's outer budget. Each grant costs its pixel area, its pixels or
      # windows_pixels_default, and the side the display reads for it, the display's own
      # lane, each rounded up to pages; a session template's grant costs that once for
      # each session its principal's domains quota lets live at once, a configured
      # domain's once. When the apps row's services name the display, its apps hold max
      # grants more, each of the parameters' defaults (property 19's second clause).
      def check_display_grants(display, tables, facet_values)
        service = tables.fetch('services').fetch(display.fetch('service'))
        server = service.fetch('server')
        invalid("display #{service.fetch('name')} is served by the system domain, not a display domain", 18, 'display.name') if
          server == @codec.constant('mf_none')
        domain = tables.fetch('domains').fetch(server)
        invalid("display #{service.fetch('name')}'s domain sets a key its display record gives it", 18, 'domain.env') if
          domain.fetch('env').split("\0").any? { |word| display_keys.include?(word.partition('=').first) }
        limits = tables.fetch('limits').fetch(domain.fetch('limits'))
        grants = tables.fetch('facets').zip(facet_values).select { |facet, _values| facet.fetch('service') == display.fetch('service') }
        counted = grants.map do |facet, values|
          invalid("facet #{facet.fetch('name')} grants a display to the system domain, whose connections carry no pixel area", 18,
                  'facet.grantee') if facet.fetch('grantee_kind') == grantee_kind('system')
          invalid("facet #{facet.fetch('name')} sets session, which the domain service alone sets", 18, 'facet.parameter') if
            values.key?('session')
          [grant_instances(facet, tables), values]
        end
        apps = grants.any? { |facet, _values| app_template?(facet, tables) }
        cost = counted.sum do |instances, values|
          pixels = values.fetch('pixels') { @codec.constant('windows_pixels_default') }
          instances * (pages(pixels) + pages(limits.fetch('lane')))
        end
        return if cost <= limits.fetch('outer')

        invalid("display #{service.fetch('name')}'s grants#{' and the apps row\'s max apps' if apps} cost #{cost} bytes, " \
                "past its domain's outer budget of #{limits.fetch('outer')}", 18, apps ? 'apps.max' : 'facet.parameter')
      end

      # How many grants a facet row makes at once: one for a domain, for the app template
      # the apps row's max, each app a principal with a domains quota of one (property
      # 19's second clause), and for another session template its principal's domains
      # quota, the sessions of it that can live at once.
      def grant_instances(facet, tables)
        return 1 unless facet.fetch('grantee_kind') == grantee_kind('session')
        return @apps.max if app_template?(facet, tables)

        principal = tables.fetch('sessions').fetch(facet.fetch('grantee')).fetch('principal')
        tables.fetch('principals').fetch(principal).fetch('domains')
      end

      # Bytes rounded up to whole pages.
      def pages(bytes)
        page = @codec.constant('page_size')
        (bytes + page - 1) / page * page
      end

      # Property 15: the system domain holds no facet of the network domain's net or
      # netadmin interface, compared by number, however the service row spells it. Each
      # grantee of net, a configured domain or a session template, and its server take
      # frames of at least net_max_frame_min bytes under their own runtime limits, since
      # the socket protocol's piece and its envelope arrive in one frame. The manifest is the only
      # source of a net grant, since no requested create carries one, so this holds for
      # every grant there is. The grants' ports are its parameter clause (check_net_ports).
      def check_network_grants(facets, values, tables)
        net, netadmin = fetch_interface('net'), fetch_interface('netadmin')
        interface = ->(row) { tables.fetch('services').fetch(row.fetch('service')).fetch('interface') }
        facets.each do |row|
          next unless row.fetch('grantee_kind') == grantee_kind('system') && [net, netadmin].include?(interface.call(row))

          invalid("facet #{row.fetch('name')} grants the system domain a network interface, which it never holds", 15, 'facet.grantee')
        end
        floor = @codec.constant('net_max_frame_min')
        facets_of(facets, 'net', tables).each { |row| check_receiver_floors(row, tables, 'net', { 'max_frame' => floor }, property: 15) }
        check_net_ports(facets.zip(values).select { |row, _| interface.call(row) == net }, tables)
      end

      # Property 15's parameter clause, over each net grant and its resolved parameters
      # (abi/services/net.txt): every listen port is one of the grant's ports, those it
      # lists or by default net_unprivileged_port to 65535, so no listen line is void; and a
      # privileged port, below net_unprivileged_port, which a grant binds only when it lists it,
      # is listed by one grant of its network domain alone, to a configured domain. That
      # domain's stack binds a port for the first grant to claim it (erx_net_bind), so a
      # second grant listing it could take it first, and a session template's grant is
      # every session's made from it.
      def check_net_ports(grants, tables)
        unprivileged = @codec.constant('net_unprivileged_port')
        privileged = grants.flat_map do |row, stated|
          server = tables.fetch('services').fetch(row.fetch('service')).fetch('server')
          ports = stated['ports']
          unbound = stated.fetch('listen', []).reject { |port| ports ? ports.include?(port) : port >= unprivileged }
          invalid("facet #{row.fetch('name')} listens on #{unbound.join(', ')}, none of its ports", 15, 'facet.parameter') unless
            unbound.empty?
          low = (ports || []).select { |port| port < unprivileged }
          invalid("facet #{row.fetch('name')} grants privileged ports to a session template", 15, 'facet.grantee') if
            !low.empty? && row.fetch('grantee_kind') != grantee_kind('domain')
          low.map { |port| [[server, port], row.fetch('name')] }
        end
        shared = privileged.group_by(&:first).select { |_held, holders| holders.size > 1 }
        shared.each do |(_server, port), holders|
          invalid("privileged port #{port} is listed by facets #{holders.map(&:last).join(', ')} of one network domain",
                  15, 'facet.parameter')
        end
      end

      # Property 16: every domain that receives the files protocol of a facet of an
      # interface abi/services declares served_as tree (files, windows, line), its
      # grantee (the system domain, a configured domain or a session template) and its
      # server, takes frames of at least files_max_frame_min bytes under its own runtime
      # limits, and the facet's max_request admits a request that long, since a read reply
      # or a write request of the client's 64 KiB transfer unit arrives in one frame, and
      # the funnel drops a longer frame and the facet a longer request.
      def check_files_grants(facets, tables)
        floor = @codec.constant('files_max_frame_min')
        trees = @codec.schema.services.select { |service| service.fetch(:served_as) == 'tree' }
        trees.each do |service|
          facets_of(facets, service.fetch(:name), tables).each do |row|
            if row.fetch('max_request') < floor
              invalid("facet #{row.fetch('name')}'s max_request #{row.fetch('max_request')} is below " \
                      "#{service.fetch(:name)}'s floor of #{floor}", 16, 'facet.max_request')
            end
            check_receiver_floors(row, tables, service.fetch(:name), { 'max_frame' => floor }, property: 16)
          end
        end
      end

      # Property 16 for inspect: every grantee of an inspect facet and its server, the
      # system domain, which also takes the runtime agents' answers of the same bound,
      # carry the interface's floor on each of the three limits the funnel applies to a
      # frame, so no receiver's funnel drops a valid answer (docs/design-live.md, "The
      # inspect service"). inspect_funnel_depth_min is computed from the inspection
      # schema (tools/lib/erx/abi_inspection_bounds.rb). Only the system domain serves
      # inspect, since it alone validates and scopes the answers a grantee reads.
      def check_inspect_grants(facets, tables)
        floors = { 'max_frame' => @codec.constant('inspect_max_frame_min'),
                   'max_message_heap' => @codec.constant('inspect_message_heap_min'),
                   'funnel_depth' => @codec.constant('inspect_funnel_depth_min') }
        inspect = fetch_interface('inspect')
        if tables.fetch('services').any? { |row| row.fetch('interface') == inspect && row.fetch('server') != @codec.constant('mf_none') }
          invalid('only the system domain serves the inspect interface', 16, 'service.server')
        end
        facets_of(facets, 'inspect', tables).each { |row| check_receiver_floors(row, tables, 'inspect', floors, property: 16) }
      end

      # At most one service of the code_objects interface, named code_objects and served by
      # the system domain, the name and server the domain service grants every session's
      # facet under (docs/design-system.md, "The code_objects facet").
      def check_code_objects_service(service_rows)
        interface = fetch_interface('code_objects')
        system = @codec.constant('mf_none')
        found = service_rows.select { |row| row.fetch('interface') == interface }
        return if found.empty?
        return if found.size == 1 && found.first.fetch('name') == 'code_objects' && found.first.fetch('server') == system

        invalid('the manifest serves code_objects once, by that name, from the system domain', 8, 'service.interface')
      end

      # Property 19's tenth clause (docs/design-files.md, "A user's home"): a user's one
      # place on the data volume is its home, so a grant of the service named
      # data_service that states no tree, the whole volume, is the system domain's or,
      # in a development manifest only, root's template's, the system principal's, and
      # no other grantee's: no configured domain's and no other template's. A row with a
      # tree (an app's, tree apps) is rooted below the volume and is not this clause's.
      # values holds each facet's parameter values, by key name, in facets' order.
      def check_data_grants(facets, values, tables)
        name = @codec.fixed_bytes('data_service')
        system_principal = reference(@source.machine, 'system_principal', 'principal')
        development = BuildKind.development?(@context.build_kind)
        allowed = lambda do |row|
          case row.values_at('grantee_kind', 'grantee')
          in [kind, _] if kind == grantee_kind('system') then true
          in [kind, template] if kind == grantee_kind('session')
            development && tables.fetch('sessions').fetch(template).fetch('principal') == system_principal
          else false
          end
        end
        facets.zip(values).each do |row, stated|
          next unless tables.fetch('services').fetch(row.fetch('service')).fetch('name') == name && stated['tree'].nil?
          next if allowed.call(row)

          invalid("facet #{row.fetch('name')} grants the whole volume, data, which only the system domain " \
                  "and, in a development manifest, root's template take", 19, 'facet.grantee')
        end
      end

      # The facet rows of the interface abi/services declares as NAME, compared by number.
      def facets_of(facets, name, tables)
        interface = fetch_interface(name)
        facets.select { |row| tables.fetch('services').fetch(row.fetch('service')).fetch('interface') == interface }
      end

      # Refuses, as PROPERTY, a facet whose grantee or server runs a runtime limit below
      # the interface's floor for it (docs/design-domains.md, "Floors from a protocol": a
      # floor binds both receivers). FLOORS maps a runtime_limits field to its floor.
      def check_receiver_floors(row, tables, interface, floors, property:)
        server = tables.fetch('services').fetch(row.fetch('service')).fetch('server')
        server_kind = server == @codec.constant('mf_none') ? grantee_kind('system') : grantee_kind('domain')
        receivers = { 'grantee' => receiver_limits(row.fetch('grantee_kind'), row.fetch('grantee'), tables),
                      'server' => receiver_limits(server_kind, server, tables) }
        receivers.each do |role, limits|
          floors.each do |field, floor|
            next if limits.fetch(field) >= floor

            invalid("facet #{row.fetch('name')}'s #{role} runs with #{field} #{limits.fetch(field)}, " \
                    "below #{interface}'s floor of #{floor}", property, "runtime_limits.#{field}")
          end
        end
      end

      # The runtime limits of a receiver of a protocol: the system domain's, the machine's
      # system runtime limits, or a configured domain's or a session template's.
      def receiver_limits(kind, index, tables)
        runtime_limits = tables.fetch('runtime_limits')
        return runtime_limits.fetch(reference(@source.machine, 'system_runtime_limits', 'runtime_limits')) if
          kind == grantee_kind('system')

        table = kind == grantee_kind('domain') ? 'domains' : 'sessions'
        runtime_limits.fetch(tables.fetch('limits').fetch(tables.fetch(table).fetch(index).fetch('limits')).fetch('runtime_limits'))
      end

      # The facets' edges from each configured or system grantee to its service's server,
      # mf_none for the system domain, which the boot order and the rescue configuration
      # follow. A session template is never started at boot, so its grants are no edge.
      def boot_edges(facets, services)
        none = @codec.constant('mf_none')
        facets.filter_map do |row|
          client = case row.fetch('grantee_kind')
                   when grantee_kind('domain') then row.fetch('grantee')
                   when grantee_kind('system') then none
                   end
          [client, services.fetch(row.fetch('service')).fetch('server')] if client
        end
      end

      def grantee_kind(name) = @codec.member('mf_grantee', name)

      # A facet's grantee as its kind and index: the system domain, written system, with
      # index 0; a configured domain, @domain.NAME, by its index; or a session template,
      # @session.PRINCIPAL, by its index in the sessions table.
      def facet_grantee(token, sessions)
        return [grantee_kind('system'), 0] if !token.quoted && token.value == 'system'

        domain = domain_index(token)
        return [grantee_kind('domain'), domain] if domain

        session = session_index(token, sessions)
        return [grantee_kind('session'), session] if session

        invalid('names neither the system domain, a configured domain nor a session template', 2, 'facet.grantee')
      end

      # A session template's index, or nil when the token names none.
      def session_index(token, sessions)
        return nil if token.quoted || !token.value.start_with?('@session.')

        principal = @indices.fetch('principal')[token.value.delete_prefix('@session.')]
        principal && sessions.index { |row| row.fetch('principal') == principal }
      end

      def facet_row(record, service, sessions)
        name = record.properties.key?('name') ? text(record, 'name') : record.name.b
        invalid('facet name is not a system identifier', 5, 'facet.name') unless name.match?(Frontend::IDENTIFIER)
        queue = record.properties.key?('queue') ? number(record, 'queue') : number(@source.machine, 'system_queue')
        kind, index = facet_grantee(one(record, 'grantee'), sessions)
        { 'name' => name, 'grantee_kind' => kind, 'grantee' => index,
          'service' => service,
          'operations' => { 'table' => 'facet_operations', 'first' => 0, 'count' => 0 },
          'queue' => queue }.merge(ABI::Contracts::FACET_QUANTITIES.to_h { |key| [key, number(record, key)] })
      end

      # What the stopgap cannot honour, refused once properties 2, 10 and 11 hold
      # (docs/design-time.md, "Phase 1"): a facet that names operations of a service a
      # configured domain serves, since only the system domain's erx_facet checks a
      # grant's operations, so the row would grant every operation. A tree's interface
      # declares none (facet_operations). Its parameters are resolved (facet_parameters).
      def check_facets_supported(rows)
        none = @codec.constant('mf_none')
        rows.fetch('facets').each do |facet|
          next if facet.fetch('operations').fetch('count').zero?

          service = rows.fetch('services').fetch(facet.fetch('service'))
          unsupported("facet #{facet.fetch('name')} names operations of a service a configured domain serves, " \
                      'which nothing on the stopgap checks', 'facet.operations') unless service.fetch('server') == none
        end
      end

      # Property 10: every server before its clients, ties broken by name order, which
      # the domains' indices follow. A domain is ready once every configured domain
      # its facets name is placed; none ready means the facets lead back to one.
      def boot_order(domains, edges)
        servers = edges.group_by(&:first).transform_values { |pairs| pairs.map(&:last) - [@codec.constant('mf_none')] }
        domains.each_index.each_with_object([]) do |_step, placed|
          ready = (domains.each_index.to_a - placed).find { |domain| (servers.fetch(domain, []) - placed).empty? }
          invalid('a configured domain\'s facets lead back to it', 10, 'facet.service') unless ready
          placed << ready
        end.map { |domain| { 'domain' => domain } }
      end

      # Property 11: a domain the rescue configuration starts takes facets only of
      # the system domain and of other domains it starts.
      def check_rescue(domains, edges)
        rescue_flag = @codec.member('mf_domain_flags', 'rescue')
        rescued = ->(index) { (domains.fetch(index).fetch('flags') & rescue_flag) != 0 }
        none = @codec.constant('mf_none')
        edges.each do |client, server|
          next unless client != none && server != none && rescued.call(client) && !rescued.call(server)

          invalid('a rescue domain names a service of a domain the rescue configuration does not start', 11, 'facet.service')
        end
      end

      public

      # Property 12: the domain library's host build, given the packed manifest, builds
      # the boot's view with the root's own builder, so each principal passes
      # erx_dom_principal_check, then plans every configured domain in boot order and
      # every introduction against a model machine that records each plan as the boot
      # does. So the configured domains' share of properties 4 and 13 (each principal's
      # domain quota and budget, each grant within system and the service grants within
      # its reserve) and the connection rows are the library's own judgment, in its own
      # arithmetic. Then, property 17's planning clause, it plans the sessions the boot
      # starts after them, in the boot's order (planned_sessions): root's console
      # session, and then each enabled start row's. So an enabled row whose principal
      # cannot hold its session beside the configured domains and the sessions before it
      # fails the build, and so does a system principal that cannot hold root's console
      # session. A build passes a planner always; without one, a manifest with no domains
      # and no session to plan is not planned, and any other fails closed.
      def check_plans(bytes, normalized)
        rows = normalized.fetch('tables')
        domains = rows.fetch('domains')
        sessions = planned_sessions(rows, normalized.fetch('header').fetch('system_principal'))
        unless @planner
          return if domains.empty? && sessions.empty?

          raise Unsupported.new('configured domains and sessions need the domain library\'s host planner',
                                property: 12, field: 'planner')
        end

        order = rows.fetch('boot_order').map { |step| step.fetch('domain') }
        statuses = @planner.call(plan_view(bytes, rows, order: order,
                                           templates: sessions.map { |session| session.fetch('template') }))
        invalid("the domain library refuses the manifest's view: #{statuses.fetch('refused').delete_prefix('manifest: ')}", 12, 'view') if statuses.key?('refused')
        order.zip(statuses.fetch('domains')).each do |index, status|
          refuse_plan(status, "configured domain #{domains.fetch(index).fetch('name')}", 'domain')
        end
        rows.fetch('introductions').zip(statuses.fetch('introductions')).each do |row, status|
          names = row.values_at('from', 'to').map { |index| domains.fetch(index).fetch('name') }
          refuse_plan(status, "the introduction of #{names.join(' and ')}", 'introduce')
        end
        sessions.each_with_index do |session, index|
          refuse_plan(statuses.fetch('sessions').fetch(index), session.fetch('what'), session.fetch('field'), property: 17)
        end
      end

      private

      # The sessions the boot starts, in its order, each its template's index in the
      # session table and how a refusal names it. First root's console session, from
      # the system principal's template: the reader requires a console line, which
      # logs root in at boot in a development build and must let root log in in any
      # build, so it is planned whenever that template exists; a system principal with
      # none gives the console no session to count. Then each enabled start row's.
      def planned_sessions(rows, system_principal)
        principals = rows.fetch('principals')
        console = rows.fetch('sessions').each_index.select do |index|
          rows.fetch('sessions').fetch(index).fetch('principal') == system_principal
        end
        console.map { |template| { 'template' => template, 'what' => "the console's session of root", 'field' => 'machine.console' } } +
          enabled_starts(rows).map do |start|
            name = principals.fetch(start.fetch('principal')).fetch('name')
            { 'template' => start.fetch('template'), 'what' => "the session of start row #{name}", 'field' => 'start' }
          end
      end

      # The enabled start rows, in the start table's order, each its principal's index
      # and the index of that principal's session template, which property 17's
      # structural clauses make exist and the session table holds one per principal.
      def enabled_starts(rows)
        enabled = @codec.member('mf_start_flags', 'enabled')
        template = rows.fetch('sessions').each_with_index.to_h { |row, index| [row.fetch('principal'), index] }
        rows.fetch('starts').select { |row| (row.fetch('flags') & enabled) != 0 }.map do |row|
          { 'principal' => row.fetch('principal'), 'template' => template.fetch(row.fetch('principal')) }
        end
      end

      # Refuses the manifest naming what the library refused; status 0 passes.
      def refuse_plan(status, what, field, property: 12)
        return if status.zero?

        name = (@codec.schema.statuses || {}).key(status) || status
        invalid("the domain library refuses #{what} with #{name}", property, field)
      end

      # The planner's view (DomainPlanner#call): the packed manifest, each archive entry
      # with the bytes it will start with, the configured rows in boot order, each
      # introduction's parties their places in it, and the session template of each
      # session to plan, in the order the boot starts them.
      def plan_view(bytes, rows, order:, templates:)
        place = order.each_with_index.to_h
        introductions = rows.fetch('introductions').map do |row|
          { 'a' => place.fetch(row.fetch('from')), 'b' => place.fetch(row.fetch('to')) }
        end
        { 'manifest' => bytes, 'files' => @context.catalog.map { |row| plan_file(row) }, 'order' => order,
          'introductions' => introductions, 'sessions' => templates }
      end

      # A boot-image entry as the archive will hold it: an image starts with its image
      # manifest, which the packer encodes so (PackWire#write_image); the library judges it.
      def plan_file(row)
        head = row['image'].is_a?(Hash) ? @codec.encode_layout('erx_image_manifest', row.fetch('image')) : ''.b
        { 'kind' => row.fetch('kind'), 'flags' => row.fetch('flags'), 'head' => head }
      end

      # Property 8's windows (docs/design-abi.md, "Devices and partition windows"; PW1 of
      # docs/design-storage.md): a role abi/manifest.txt does not mark configured is the
      # slot writer's, the system domain's alone in Phase 1, and the one system window is
      # read-only and held by its block device's holder, the storage domain whose block
      # driver serves it, since the driver hands a window only to its own domain
      # (docs/design-stopgap.md, "The booted slot").
      def normalize_windows(tables)
        devices = tables.fetch('devices')
        rows = records('window').map do |record|
          role = window_role(record)
          slot_writer = !@codec.attribute?('mf_window_role', role, 'configured')
          invalid('only the system domain, the slot writer, holds the slot windows', 8, 'window.holder') if
            slot_writer && !(one(record, 'holder').value == 'system' && !one(record, 'holder').quoted)
          { 'holder' => holder_index(one(record, 'holder'), property: 8, field: 'window.holder'),
            'device' => window_device(record, devices), 'role' => role, 'partition' => window_partition(record, role),
            'rights' => window_rights(record, role), 'image' => window_image(record, role) }
            .tap { |row| check_image_device(row, tables.fetch('images')) }
        end
        check_system_window(rows, tables)
        check_record_volume_window(rows)
        placed = rows.map { |row| row.values_at('device', 'role', 'partition', 'image') }
        invalid('two windows name one role and partition', 8, 'window.partition') unless placed.uniq.size == placed.size
        rows.sort_by { |row| row.values_at('holder', 'device', 'role', 'partition', 'image') }
      end

      # design-abi.md: fixed-medium roles have partition 0, because the medium
      # layout determines their sectors; FAT names a primary partition.
      def window_partition(record, role)
        partition = number(record, 'partition')
        allowed = role == @codec.member('mf_window_role', 'fat') ? (1..4) : (0..0)
        invalid('a fixed role has partition 0 and FAT a primary partition, 1 to 4', 8, 'window.partition') unless allowed.cover?(partition)
        partition
      end

      def window_rights(record, role)
        rights = flags(record, 'rights', 'mf_window_rights')
        read = @codec.member('mf_window_rights', 'read')
        invalid('a window grants at least read', 8, 'window.rights') if (rights & read).zero?
        writable = @codec.attribute?('mf_window_role', role, 'writable')
        invalid('a window of a role not marked writable grants read alone', 8, 'window.rights') if !writable && rights != read
        rights
      end

      # At most one system window, held by a storage domain: a configured domain, never
      # the system domain, that holds the window's block device. The window and the
      # system_image row come together, since its holder opens the window's image by
      # that row (docs/design-stopgap.md, "The booted slot").
      def check_system_window(rows, tables)
        system = rows.select { |row| row.fetch('role') == system_role }
        invalid('a manifest has at most one system window', 8, 'window.role') if system.size > 1
        described = !records('system_image').empty?
        invalid('a system window needs the system_image row that describes its image', 8, 'window.role') if system.any? && !described
        invalid('a system_image row needs the system window it describes', 8, 'system_image') if system.empty? && described
        system.each do |row|
          holder = row.fetch('holder')
          device = tables.fetch('devices').fetch(row.fetch('device')).fetch('path')
          invalid('a system window is held by the configured domain that holds its block device', 8, 'window.holder') unless
            holder != @codec.constant('mf_none') && holder == unit_holder(tables, device)
        end
      end

      # Property 19's eighth clause (docs/design-packaging.md, "The build's check"): a
      # manifest with a system window holds exactly one service named system_service,
      # of the files interface, served by the window's holder, so the domain that mints
      # the tree's grants is the one whose block driver serves its partition, and one
      # without a system window holds none, so an apps row, which needs the service,
      # needs the window; and no source facet row grants it, by whatever label its record
      # carries.
      def check_system_service(tables)
        name = @codec.fixed_bytes('system_service')
        window = tables.fetch('windows').find { |row| row.fetch('role') == system_role }
        unless window
          invalid("an apps row needs a system window, whose holder serves #{name}", 19, 'apps') unless @apps == NO_APPS
          invalid("a manifest without a system window holds no service named #{name}", 19, 'service.name') if
            tables.fetch('services').any? { |row| row.fetch('name') == name }
          return
        end

        index = fetch_files_service(tables.fetch('services'), 'system_service', required_by: 'a system window')
        service = tables.fetch('services').fetch(index)
        invalid("the service named #{name} is served by the holder of the system window", 19, 'service.server') unless
          window.fetch('holder') == service.fetch('server')
        labels = records('service').select { |record| service_name(record) == name }.map { |record| "@service.#{record.name}" }
        invalid("no source facet row names the service #{name}: only the derived system rows do", 19, 'facet.service') if
          records('facet').any? { |record| labels.include?(one(record, 'service').value) }
      end

      # Root's login keys on the medium (docs/design-ssh.md, "Who publishes it"): at most one
      # record_volume window, on the system window's medium and held by its holder, so the
      # domain that reads the record partition is the one whose block driver serves it.
      def check_record_volume_window(rows)
        volumes = rows.select { |row| row.fetch('role') == record_volume_role }
        invalid('a manifest has at most one record_volume window', 8, 'window.role') if volumes.size > 1
        system = rows.find { |row| row.fetch('role') == system_role }
        invalid('the record_volume window is held by the holder of the system window, on its device', 8, 'window.holder') if
          volumes.any? { |volume| system.nil? || volume.values_at('holder', 'device') != system.values_at('holder', 'device') }
      end

      # The other half of "Who publishes it": a manifest with a record_volume window holds
      # exactly one service named login_keys_service, of the files interface, served by the
      # window's holder, and one without holds none; and every facet row of it is read-only,
      # a row that states no rights being rw (abi/services/files.txt), and the system
      # domain's or the system principal's session template's, whose daemon of SSH's stage 1
      # reads root's keys (docs/design-ssh.md, "Invariants", H8).
      # facet_values holds each facet row's resolved parameters, in the rows' order.
      def check_login_keys_service(tables, facet_values)
        name = @codec.fixed_bytes('login_keys_service')
        service_rows = tables.fetch('services')
        indices = service_rows.each_index.select { |index| service_rows.fetch(index).fetch('name') == name }
        window = tables.fetch('windows').find { |row| row.fetch('role') == record_volume_role }
        invalid("a manifest with a record_volume window holds one service named #{name}, and one without holds none", 8,
                'service.name') unless indices.size == (window ? 1 : 0)
        return if indices.empty?

        index = indices.first
        service = service_rows.fetch(index)
        invalid("the service named #{name} is of the files interface", 8, 'service.interface') unless
          service.fetch('interface') == fetch_interface('files')
        invalid("the service named #{name} is served by the holder of the record_volume window", 8, 'service.server') unless
          window.fetch('holder') == service.fetch('server')
        principal = reference(@source.machine, 'system_principal', 'principal')
        root_template = tables.fetch('sessions').index { |row| row.fetch('principal') == principal }
        grantees = [[grantee_kind('system'), 0], [grantee_kind('session'), root_template]]
        tables.fetch('facets').zip(facet_values).each do |facet, values|
          next unless facet.fetch('service') == index

          invalid("facet #{facet.fetch('name')} grants #{name} to another grantee than the system domain or " \
                  'the system principal\'s session template', 8, 'facet.grantee') unless
            grantees.include?(facet.values_at('grantee_kind', 'grantee'))
          invalid("facet #{facet.fetch('name')} grants #{name} other than read-only", 8, 'facet.parameter') unless
            values.fetch('rights', 'rw') == 'ro'
        end
      end

      def window_device(record, devices)
        block_device(text(record, 'device'), devices) || invalid('window names no block device the manifest places', 8, 'window.device')
      end

      def block_device(path, devices) = devices.index { |device| device['path'] == path && device.fetch('role') == device_role('block') }

      def window_role(record)
        role = enum(record, 'role', 'mf_window_role')
        invalid('no vault partition until M11', 8, 'window.role') if role == @codec.member('mf_window_role', 'vault')
        role
      end

      # design-abi.md: a verified-image window names an image-table index, and every
      # other role names none.
      def window_image(record, role)
        token = one(record, 'image')
        absent = !token.quoted && token.value == 'none'
        if role == image_role
          invalid('a verified-image window names its image', 8, 'window.image') if absent
          reference_token(token, 'image', record.line)
        else
          invalid('only a verified-image window names an image', 8, 'window.image') unless absent
          @codec.constant('mf_none')
        end
      end

      # A verified-image window lies on the device its image lies on, since the image's
      # extents are places on that device.
      def check_image_device(row, images)
        return if row.fetch('role') != image_role || images.fetch(row.fetch('image')).fetch('device') == row.fetch('device')

        invalid("a verified-image window names its image's device", 8, 'window.device')
      end

      # An image's tree fields when the packer writes no tree.
      NO_TREE = { 'hash_block_size' => 0, 'hash_offset' => 0, 'hash_bytes' => 0, 'salt_length' => 0,
                  'hash_algorithm' => 0, 'salt' => Array.new(32, 0), 'root_hash' => Array.new(32, 0) }.freeze

      def image_role = @codec.member('mf_window_role', 'verified_image')

      def system_role = @codec.member('mf_window_role', 'system')
      def record_volume_role = @codec.member('mf_window_role', 'record_volume')

      # The image table and its extents (docs/design-stopgap.md, "The Phase 1 manifest
      # check"): each image is format erofs_unchecked, since the packer writes no hash
      # tree, so its record holds its data's length and extents, taken from the built
      # image its input artifact describes, and zeros for every tree field.
      def normalize_images(devices)
        block_size = @codec.constant('page_size')
        records('image').sort_by { |record| record.name.b }.each_with_object([[], []]) do |record, (images, extents)|
          invalid('image name is not a system identifier', 5, 'image.name') unless record.name.match?(Frontend::IDENTIFIER)
          invalid('an image without a hash tree takes no salt', 8, 'image.salt') if record.properties.key?('salt')
          placed = checked_extents(artifact(record, 'input', 'erofs_image', property: 8, field: 'image.input'), field: 'image.input')
          bytes = placed.sum { |extent| extent.fetch('length') }
          invalid('an image is whole blocks', 8, 'image.input') unless (bytes % block_size).zero?
          device = block_device(text(record, 'device'), devices) || invalid('image names no block device the manifest places', 8, 'image.device')
          images << { 'name' => record.name.b, 'device' => device,
                      'format' => @codec.member('mf_image_format', 'erofs_unchecked'),
                      'extents' => { 'table' => 'extents', 'first' => extents.size, 'count' => placed.size },
                      'data_bytes' => bytes, 'data_block_size' => block_size, 'data_blocks' => bytes / block_size }
                    .merge(NO_TREE)
          extents.concat(placed)
        end
      end

      # design-abi.md: nonempty, sorted and disjoint whole sectors, relative to the start of
      # the slot's system partition and inside it.
      def checked_extents(artifact, field:)
        sector = @codec.constant('mbr_sector_size')
        slot = @codec.constant('medium_system_sectors') * sector
        extents = artifact['extents']
        invalid('an image has at least one extent', 8, field) unless extents.is_a?(Array) && !extents.empty?
        extents.each_with_object([]) do |extent, placed|
          offset, length = extent.values_at('slot_offset', 'length') if extent.is_a?(Hash)
          floor = placed.empty? ? 0 : placed.last.fetch('slot_offset') + placed.last.fetch('length')
          unless offset.is_a?(Integer) && length.is_a?(Integer) && length.positive? && offset >= floor &&
                 (offset % sector).zero? && (length % sector).zero? && offset + length <= slot
            invalid('image extents are sorted, disjoint whole sectors inside a slot', 8, field)
          end
          placed << { 'slot_offset' => offset, 'length' => length }
        end
      end
    end

    # Physical positions are derived once from the final table plan. String
    # references are assigned in field traversal order, with no interning or
    # data-dependent map ordering. No bytes escape before the reader pass.
    class Encoder
      def initialize(codec)
        @codec = codec
        @reader = codec.schema.readers.find { |item| item.name == 'manifest' }
      end

      def encode(configuration)
        rows = configuration.fetch('tables')
        cursor = @reader.root.size
        positions = {}
        @reader.order.each do |name|
          next unless @reader.tables.key?(name)
          table = @reader.tables.fetch(name)
          count = rows.fetch(name).size
          raise Invalid.new('table exceeds bound', property: 'encoding', field: name) if count > table.fetch(:maximum)
          cursor += (table.fetch(:alignment) - cursor % table.fetch(:alignment)) % table.fetch(:alignment)
          positions[name] = { 'offset' => cursor, 'count' => count }
          cursor += count * table.fetch(:type).size
        end
        raise Invalid.new('tables exceed manifest byte bound', property: 'encoding', field: 'length') if cursor > @reader.maximum
        strings = +''.b
        string_budget = [@codec.constant('manifest_strings_max'), @reader.maximum - cursor].min
        header = configuration.fetch('header').merge('length' => 0, 'header_size' => @reader.root.size,
                                                    'strings' => { 'offset' => cursor, 'count' => 0 }).merge(positions)
        header = materialize(@reader.root, header, positions, strings, string_budget)
        encoded = {}
        @reader.tables.each do |name, table|
          encoded[name] = rows.fetch(name).map do |row|
            values = materialize(table.fetch(:type), row, positions, strings, string_budget)
            @codec.encode_layout(table.fetch(:type).name, values)
          end
        end
        header['strings'] = { 'offset' => cursor, 'count' => strings.bytesize }
        header['length'] = cursor + strings.bytesize
        result = "\0".b * cursor
        result[0, @reader.root.size] = @codec.encode_layout(@reader.root.name, header)
        encoded.each do |name, records|
          offset = positions.fetch(name).fetch('offset')
          records.each do |record|
            result[offset, record.bytesize] = record
            offset += record.bytesize
          end
        end
        (result << strings).freeze
      end

      private

      def materialize(type, values, positions, strings, budget)
        unless (values.keys - type.fields.map(&:name)).empty?
          raise Invalid.new('unknown normalized field', property: 'encoding', field: type.name)
        end
        type.fields.each_with_object({}) do |field, result|
          key = field.name
          next unless values.key?(key)
          value = values.fetch(key)
          if field.type.name == 'erx_mf_str'
            unless value.is_a?(String) && value.bytesize <= budget - strings.bytesize
              raise Invalid.new('string table exceeds bound', property: 'encoding', field: key)
            end
            result[key] = { 'offset' => value.empty? ? 0 : strings.bytesize, 'length' => value.bytesize }
            strings << value.b
          elsif field.type.name == 'erx_mf_span' && value.key?('table')
            table = @reader.tables.fetch(value.fetch('table'))
            extent = positions.fetch(value.fetch('table'))
            first = value.fetch('first')
            count = value.fetch('count')
            unless first.between?(0, extent.fetch('count')) && count.between?(0, extent.fetch('count') - first)
              raise Invalid.new('normalized slice is outside its table', property: 'encoding', field: key)
            end
            result[key] = { 'offset' => extent.fetch('offset') + first * table.fetch(:type).size, 'count' => count }
          else
            result[key] = value
          end
        end
      end
    end
  end
end
