# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../lib/erx/abi'

module Erx
  # App package files for erx_pkg_header's tests and fuzz target, written through the ABI
  # codec from abi/formats/package.txt (docs/design-packaging.md, "The package"). The
  # decoder reads only a file's length and its first pkg_header_max bytes, so a sample is
  # those two; the image and the hash tree are zeros, which nothing before a mount reads.
  #
  # A header lays its fixed part, the needs and applications tables, the string table and
  # the seal end to end in the reader's order. Edits replace fields of the fixed part after
  # the layout is computed, so a sample can be wrong in exactly one field.
  module PackageSeeds
    Sample = Data.define(:name, :length, :prefix)
    Declaration = Data.define(:name, :arch, :needs, :start, :license, :memory, :version)

    ERLANG = Declaration.new(name: 'dashboard', arch: 'aarch64', needs: %w[display data],
                             start: [:applications, %w[erx_dashboard erx_charts]],
                             license: 'BSD-2-Clause', memory: 67_108_864, version: 3)
    NATIVE = Declaration.new(name: 'doom', arch: 'aarch64', needs: %w[display],
                             start: [:program, 'bin/doom', ['-iwad', '', '/app/share/freedoom1.wad']],
                             license: '', memory: 134_217_728, version: 1)

    module_function

    def codec
      @codec ||= ABI::Codec.new(ABI::Generator.plan(root: File.expand_path('../..', __dir__)).schema)
    end

    def block = codec.constant('erofs_block_size')
    def header_max = codec.constant('pkg_header_max')

    # The sample of a well-formed package, or of one whose header fields edits replace,
    # whose header bytes header_edit rewrites, whose length length_edit changes or whose
    # first bytes prefix_edit rewrites.
    def sample(name, declaration:, image_blocks:, tree_blocks:, edits: ->(values) { values },
               header_edit: ->(bytes) { bytes }, length_edit: ->(length) { length },
               prefix_edit: ->(bytes) { bytes })
      header = header_edit.call(header(declaration, image_blocks: image_blocks,
                                                    tree_blocks: tree_blocks, edits: edits))
      boundary = align(header.bytesize, block)
      length = length_edit.call(boundary + ((image_blocks + tree_blocks) * block))
      file_start = header + ("\0".b * (boundary - header.bytesize))
      prefix = file_start.byteslice(0, [length, header_max].min).ljust([length, header_max].min, "\0")
      Sample.new(name: name, length: length, prefix: prefix_edit.call(prefix.b).b.freeze)
    end

    # The header's bytes: the fixed part with edits applied, the tables, the strings and
    # the seal, whose key and signature are not real ones; the decoder reads no signature.
    def header(declaration, image_blocks:, tree_blocks:, edits: ->(values) { values })
      strings = +''.b
      reference = lambda do |text|
        { 'offset' => strings.bytesize, 'length' => text.bytesize }.tap { strings << text.b }
      end
      kind, *start = declaration.start
      program, args = kind == :program ? start : [nil, []]
      applications = kind == :applications ? start.first : []
      values = { 'version' => codec.constant('pkg_version'),
                 'abi_version' => codec.abi_version,
                 'kind' => codec.member('pkg_kind', kind == :program ? 'native' : 'erlang'),
                 'app_version' => declaration.version, 'memory' => declaration.memory,
                 'image_blocks' => image_blocks, 'tree_blocks' => tree_blocks,
                 'salt' => "\x5a".b * 32, 'root_hash' => "\xa5".b * 32,
                 'arch' => reference.call(declaration.arch), 'name' => reference.call(declaration.name),
                 'license' => reference.call(declaration.license),
                 'program' => program ? reference.call(program) : { 'offset' => 0, 'length' => 0 },
                 'args' => kind == :program ? reference.call(args.map { |arg| "#{arg}\0" }.join) : { 'offset' => 0, 'length' => 0 } }
      needs = declaration.needs.map { |need| codec.encode_layout('erx_mf_str', reference.call(need)) }.join
      apps = applications.map { |app| codec.encode_layout('erx_mf_str', reference.call(app)) }.join
      needs_offset = align(codec.layout_size('erx_pkg_header'), 4)
      apps_offset = align(needs_offset + needs.bytesize, 4)
      strings_offset = apps_offset + apps.bytesize
      seal_offset = strings_offset + strings.bytesize
      seal = codec.encode_layout('erx_pkg_seal', 'key' => "\x11".b * 32, 'signature' => "\x22".b * 64)
      values = values.merge('header_length' => seal_offset + seal.bytesize,
                            'needs' => span(needs_offset, declaration.needs.size),
                            'applications' => span(apps_offset, applications.size),
                            'strings' => span(strings_offset, strings.bytesize),
                            'seal' => span(seal_offset, 1)).then(&edits)
      root = codec.encode_layout('erx_pkg_header', values)
      padded(root, needs_offset) + padded(needs, apps_offset - needs_offset) + apps + strings + seal
    end

    def span(offset, count) = { 'offset' => offset, 'count' => count }
    def align(value, alignment) = (value + alignment - 1) / alignment * alignment
    def padded(bytes, size) = bytes.b.ljust(size, "\0")
  end
end
