# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'generation_plan'

module Erx
  # The GATT service declarations (docs/design-bluetooth.md, "Declarations:
  # `abi/gatt`"): every file abi/gatt/NAME.txt, read and checked whole, becomes one
  # term of the generated Erlang module erx_gatt_decl, in the shape
  # erx_gatt_db:build/1 takes (its service() type). Nothing reads a declaration at
  # run time.
  #
  # A declaration is lines of space-separated tokens, with # starting a comment:
  #
  #   service        NAME UUID [advertise]                   once, first, NAME the file's name
  #   characteristic NAME UUID MAX ACCESS LEVEL... [value HEX]
  #
  # NAME is a lower-case identifier; UUID four lower-case hexadecimal digits, or the
  # 8-4-4-4-12 form of a 128-bit UUID in lower case; MAX the longest value in octets,
  # in decimal, at most the ABI's att_value_max; ACCESS one of ACCESSES and LEVEL one
  # of LEVELS, each access given once; HEX the initial value, two lower-case
  # hexadecimal digits an octet.
  #
  # UUIDs are compared as 128-bit UUIDs, as ATT compares attribute types (Core 6.3,
  # Vol 3 Part F, 3.4.4.1 and 3.4.4.9, notes): a 16-bit UUID is placed in the
  # Bluetooth Base UUID (Vol 3 Part B, 2.5.1, which was not read; BASE_UUID is
  # Bumble v0.0.237's, bumble/core.py, lines 202 and 212, and is unverified against
  # Part B). So a characteristic UUID given once short and once long is given twice,
  # and the long form of one of GATT's and GAP's own UUIDs is theirs.
  module GattDecl
    class DeclarationError < Error; end

    DECLARATIONS = 'abi/gatt/*.txt'
    OUTPUT = 'erlang/apps/erx_bt/src/erx_gatt_decl.erl'
    MAX_DECLARATION_BYTES = 65_536
    # The enum of GATT's and GAP's own UUIDs (abi/formats/bluetooth.txt): the
    # attribute types and the two services the table lays out itself, which no
    # declaration may use.
    RESERVED_ENUM = 'gatt_uuid'
    VALUE_MAX_LIMIT = 'att_value_max'
    # The names erx_gatt_db gives GAP's and GATT's own services (gap/0, gatt/0).
    RESERVED_NAMES = %w[gap gatt].freeze
    ACCESSES = %w[read write write_without_response notify indicate].freeze
    LEVELS = %w[open encrypted authenticated].freeze
    NAME = /\A[a-z][a-z0-9_]{0,62}\z/
    UUID16 = /\A[0-9a-f]{4}\z/
    UUID128 = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    DECIMAL = /\A(?:0|[1-9][0-9]{0,5})\z/
    HEX = /\A(?:[0-9a-f]{2})+\z/
    BASE_UUID = 0x0000_0000_0000_1000_8000_0080_5f9b_34fb

    # A UUID as written, 16 or 128 bits wide, and its value.
    Uuid = Data.define(:bits, :value) do
      # The UUID as 128 bits, by which UUIDs are compared.
      def wide = bits == 128 ? value : BASE_UUID | (value << 96)
    end
    # access: ACCESSES member => LEVELS member, in ACCESSES order. value: the
    # initial value's octets, or nil.
    Characteristic = Data.define(:name, :uuid, :max, :access, :value)
    Service = Data.define(:name, :uuid, :advertise, :characteristics)
    # What a declaration is checked against, from the ABI: the reserved UUIDs by
    # their wide value => their gatt_uuid member, and the longest value.
    Vocabulary = Data.define(:reserved, :value_max)

    module_function

    # The plan Erx::Generated publishes into the build tree. It reads every
    # declaration the glob finds and every ABI source, which the vocabulary comes
    # from.
    def generation(root:)
      root = File.realpath(root)
      sources = ABI::Sources.read(root: root)
      vocabulary = vocabulary(ABI::Model.validate(sources))
      paths = Dir.glob(DECLARATIONS, base: root).sort
      raise DeclarationError, "no GATT service declaration matches #{DECLARATIONS}" if paths.empty?

      texts = paths.to_h { |path| [path, BoundedFile.read(File.join(root, path), maximum: MAX_DECLARATION_BYTES)] }
      services = texts.map { |path, text| parse(path: path, text: text, vocabulary: vocabulary) }
      reads = sources.inputs.merge(texts).transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      GenerationPlan.new(files: { OUTPUT => erlang(services).freeze }, reads: reads, globs: { DECLARATIONS => paths })
    end

    def vocabulary(schema)
      type = schema.types[RESERVED_ENUM]
      unless type.is_a?(ABI::EnumType) && !type.flags
        raise DeclarationError, "the ABI declares no enum #{RESERVED_ENUM}"
      end

      limit = schema.constants[VALUE_MAX_LIMIT] or raise DeclarationError, "the ABI declares no #{VALUE_MAX_LIMIT}"
      reserved = type.members.to_h { |member, value| [Uuid.new(bits: 16, value: value).wide, member] }
      Vocabulary.new(reserved: reserved.freeze, value_max: limit.value)
    end

    # The service the file at path declares, or a DeclarationError naming the file,
    # the line and what is wrong there.
    def parse(path:, text:, vocabulary:)
      file_name = File.basename(path, '.txt')
      raise DeclarationError, "#{path}: #{file_name.inspect} is not a service name" unless file_name.match?(NAME)

      service = nil
      characteristics = []
      text.b.split("\n", -1).each.with_index(1) do |line, number|
        where = "#{path}:#{number}"
        refuse_bytes(line, where: where)
        tokens = line.partition('#').first.strip.split(/ +/)
        next if tokens.empty?

        case tokens.first
        when 'service'
          raise DeclarationError, "#{where}: a second service line" if service

          service = service_line(tokens, file_name: file_name, vocabulary: vocabulary, where: where)
        when 'characteristic'
          raise DeclarationError, "#{where}: a characteristic before the service line" unless service

          characteristic = characteristic_line(tokens, vocabulary: vocabulary, where: where)
          refuse_repeat(characteristic, characteristics, where: where)
          characteristics << characteristic
        else
          raise DeclarationError, "#{where}: #{tokens.first} is not a line of a GATT declaration"
        end
      end
      raise DeclarationError, "#{path}: no service line" unless service

      service.with(characteristics: characteristics.freeze)
    end

    # Only printable ASCII and the space reach the tokenizer: a byte above 0x7f or a
    # control byte (a tab, a carriage return) is refused, not read around.
    def refuse_bytes(line, where:)
      byte = line.each_byte.find { |candidate| candidate > 0x7e || candidate < 0x20 }
      return unless byte

      kind = byte > 0x7f ? 'a byte above 0x7f' : 'a control byte'
      raise DeclarationError, format('%s: %s, 0x%02x', where, kind, byte)
    end
    private_class_method :refuse_bytes

    def service_line(tokens, file_name:, vocabulary:, where:)
      name, uuid, advertise =
        case tokens
        in ['service', name, uuid] then [name, uuid, false]
        in ['service', name, uuid, 'advertise'] then [name, uuid, true]
        else raise DeclarationError, "#{where}: a service line is service NAME UUID [advertise]"
        end
      identifier(name, where: where)
      raise DeclarationError, "#{where}: #{name} is the name of the table's own service" if RESERVED_NAMES.include?(name)
      raise DeclarationError, "#{where}: service #{name} in a file named #{file_name}" unless name == file_name

      Service.new(name: name, uuid: uuid(uuid, vocabulary: vocabulary, where: where), advertise: advertise,
                  characteristics: [].freeze)
    end
    private_class_method :service_line

    def characteristic_line(tokens, vocabulary:, where:)
      unless tokens.size >= 4
        raise DeclarationError, "#{where}: a characteristic line is characteristic NAME UUID MAX ACCESS LEVEL..."
      end

      _keyword, name, uuid, max, *rest = tokens
      identifier(name, where: where)
      accesses, value = rest.include?('value') ? [rest[0...rest.index('value')], rest[rest.index('value')..]] : [rest, []]
      characteristic = Characteristic.new(name: name, uuid: uuid(uuid, vocabulary: vocabulary, where: where),
                                          max: max(max, vocabulary: vocabulary, where: where),
                                          access: access(accesses, name: name, where: where), value: nil)
      value.empty? ? characteristic : characteristic.with(value: initial_value(value, characteristic, where: where))
    end
    private_class_method :characteristic_line

    def identifier(name, where:)
      raise DeclarationError, "#{where}: #{name} is not a name" unless name.match?(NAME)
    end
    private_class_method :identifier

    def uuid(token, vocabulary:, where:)
      uuid = case token
             when UUID16 then Uuid.new(bits: 16, value: token.to_i(16))
             when UUID128 then Uuid.new(bits: 128, value: token.delete('-').to_i(16))
             else raise DeclarationError, "#{where}: #{token} is not a 16-bit or 128-bit UUID"
             end
      member = vocabulary.reserved[uuid.wide]
      raise DeclarationError, "#{where}: #{token} is GATT's or GAP's own UUID #{member}" if member

      uuid
    end
    private_class_method :uuid

    def max(token, vocabulary:, where:)
      raise DeclarationError, "#{where}: #{token} is not a length in decimal" unless token.match?(DECIMAL)

      max = token.to_i
      raise DeclarationError, "#{where}: a maximum of #{max}, over #{vocabulary.value_max}" if max > vocabulary.value_max

      max
    end
    private_class_method :max

    # The accesses and their levels, in pairs; an access followed by another access,
    # by value or by nothing has no level.
    def access(tokens, name:, where:)
      access = tokens.each_slice(2).each_with_object({}) do |(access, level), map|
        raise DeclarationError, "#{where}: #{access} is not an access" unless ACCESSES.include?(access)
        raise DeclarationError, "#{where}: #{access} given twice" if map.key?(access)
        raise DeclarationError, "#{where}: #{access} has no level" if level.nil? || ACCESSES.include?(level)
        raise DeclarationError, "#{where}: #{level} is not a level" unless LEVELS.include?(level)

        map[access] = level
      end
      raise DeclarationError, "#{where}: #{name} allows no access" if access.empty?
      if access.key?('notify') && access.key?('indicate') && access['notify'] != access['indicate']
        raise DeclarationError, "#{where}: #{name} notifies #{access['notify']} and indicates #{access['indicate']}"
      end

      ACCESSES.select { |key| access.key?(key) }.to_h { |key| [key, access.fetch(key)] }.freeze
    end
    private_class_method :access

    def initial_value(tokens, characteristic, where:)
      hex = case tokens
            in ['value', hex] if hex.match?(HEX) then hex
            else raise DeclarationError, "#{where}: value takes one string of lower-case hexadecimal octets"
            end
      octets = [hex].pack('H*')
      unless characteristic.access.key?('read')
        raise DeclarationError, "#{where}: an initial value of #{characteristic.name}, which is not readable"
      end
      if octets.bytesize > characteristic.max
        raise DeclarationError,
              "#{where}: an initial value of #{octets.bytesize} octets, over #{characteristic.name}'s maximum"
      end

      octets.freeze
    end
    private_class_method :initial_value

    def refuse_repeat(characteristic, earlier, where:)
      if earlier.any? { |other| other.name == characteristic.name }
        raise DeclarationError, "#{where}: a second characteristic #{characteristic.name}"
      end
      return unless (other = earlier.find { |candidate| candidate.uuid.wide == characteristic.uuid.wide })

      raise DeclarationError, "#{where}: #{characteristic.name} has #{other.name}'s UUID"
    end
    private_class_method :refuse_repeat

    # erx_gatt_decl: names/0, advertised/0 and service/1, one clause per service in
    # the order of its name. Every atom is quoted, so a name that is a reserved word
    # (end, of) is an atom all the same.
    def erlang(services)
      names = services.map { |service| atom(service.name) }
      advertised = services.select(&:advertise).map { |service| atom(service.name) }
      <<~ERLANG
        %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
        %% SPDX-License-Identifier: BSD-2-Clause
        %% Generated by tools/lib/erx/gatt_decl.rb (tools/gen_gatt.rb) from #{DECLARATIONS}; do not edit.
        -module(erx_gatt_decl).
        -moduledoc """
        The GATT services declared in abi/gatt (docs/design-bluetooth.md, "Declarations:
        `abi/gatt`"), each as erx_gatt_db:build/1 takes it: UUIDs as ATT carries them, least
        significant octet first, and each access with the level it requires.
        """.

        -export([names/0, advertised/0, service/1]).
        -export_type([name/0]).

        -type name() :: #{names.join(' | ')}.

        -doc "Every declared service.".
        -spec names() -> [name(), ...].
        names() ->
            [#{names.join(', ')}].

        -doc "The services whose declarations say `advertise`.".
        -spec advertised() -> [name()].
        advertised() ->
            [#{advertised.join(', ')}].

        -doc "The declaration of the service `Name`.".
        -spec service(name()) -> erx_gatt_db:service().
        #{services.map { |service| service_clause(service) }.join(";\n")}.
      ERLANG
    end
    private_class_method :erlang

    def service_clause(service)
      characteristics = service.characteristics.map { |characteristic| characteristic_term(characteristic) }
      list = characteristics.empty? ? ' []' : "\n          [#{characteristics.join(",\n           ")}]"
      "service(#{atom(service.name)}) ->\n    " \
        "\#{name => #{atom(service.name)}, uuid => #{uuid_literal(service.uuid)},\n      " \
        "characteristics =>#{list}}"
    end
    private_class_method :service_clause

    def characteristic_term(characteristic)
      access = characteristic.access.map { |key, level| "#{key} => #{level}" }.join(', ')
      value = characteristic.value && ",\n             value => #{binary_literal(characteristic.value)}"
      "\#{name => #{atom(characteristic.name)}, uuid => #{uuid_literal(characteristic.uuid)}, " \
        "max => #{characteristic.max},\n             access => \#{#{access}}#{value}}"
    end
    private_class_method :characteristic_term

    def atom(name) = "'#{name}'"
    private_class_method :atom

    # The UUID's value in hexadecimal as it is written, stored least significant
    # octet first (Vol 3 Part F, 3.3.1).
    def uuid_literal(uuid)
      format("<<16#%0#{uuid.bits / 4}x:#{uuid.bits}/little>>", uuid.value)
    end
    private_class_method :uuid_literal

    def binary_literal(octets)
      lines = octets.bytes.each_slice(12).map { |slice| slice.map { |byte| format('16#%02x', byte) }.join(', ') }
      "<<#{lines.join(",\n                        ")}>>"
    end
    private_class_method :binary_literal
  end
end
