# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/generated_abi'
require_relative '../../tools/lib/erx/abi_code_bounds'

# The code interface's request bound and frame floors, computed from abi/services/code.txt
# (tools/lib/erx/abi_code_bounds.rb). The byte counts agree with stock OTP's
# erlang:external_size/1 (ERX_ERL) on the largest terms the bounds describe, built with a
# 255-byte node name; the depths and words are counted by hand; and the ABI publishes the
# values derived from the declared limits.
class AbiCodeBoundsTest < Minitest::Test
  Bounds = Erx::ABI::CodeBounds
  MODULES = 256
  PIECE = 65_536
  # abi/services/code.txt's code_load_reason, the reasons an answer may carry.
  REASONS = Erx::ABI::Generated::SCHEMA.types.fetch("code_load_reason").members.keys.freeze

  # Each term the bounds count, built by stock OTP and measured with external_size, in the
  # order of requests, replies, load_messages and answer_messages.
  ORACLE = <<~ERLANG
    Node = list_to_binary(lists:duplicate(255, $n)),
    Pid = binary_to_term(<<131, 88, 119, 255, Node/binary, 1:32, 0:32, 1:32>>),
    Ref = binary_to_term(<<131, 90, 5:16, 119, 255, Node/binary, 1:32, 1:32, 2:32, 3:32, 4:32, 5:32>>),
    Name = fun(I) -> <<I:32, (binary:copy(<<$m>>, 251))/binary>> end,
    Hash = binary:copy(<<1>>, 32),
    Big = 1 bsl 64 - 1,
    Atom = on_load_not_allowed,
    Seq = lists:seq(1, #{MODULES}),
    Domain = binary:copy(<<$d>>, 255),
    Manifest = [{Name(I), Hash} || I <- Seq],
    Call = fun(Request) -> {'$gen_call', {Pid, [alias | Ref]}, Request} end,
    NotLoaded = {not_loaded, [{Name(I), Atom} || I <- Seq]},
    Terms = [Call({load, Manifest}),
             Call({load, Domain, Manifest}),
             Call({reset, Domain}),
             Call({put, Hash, Big, Big, binary:copy(<<0>>, #{PIECE})}),
             {[alias | Ref], {ok, [Hash || _ <- Seq]}},
             {[alias | Ref], {error, NotLoaded}},
             {erx_code_load, Ref, [{Name(I), Hash, Big} || I <- Seq]},
             {erx_code_piece, Ref, Hash, Big, binary:copy(<<0>>, #{PIECE})},
             {erx_code_published, Ref, Ref},
             {erx_code_agent, Pid},
             {erx_code_get, Ref, Hash, Big},
             {erx_code_loaded, Ref, {error, NotLoaded}}],
    io:format("~w~n", [[erlang:external_size(T) || T <- Terms]]),
    halt().
  ERLANG

  def terms
    Bounds.requests(modules_max: MODULES, piece_max: PIECE) + Bounds.replies(modules_max: MODULES, reasons: REASONS) +
      Bounds.load_messages(modules_max: MODULES, piece_max: PIECE) + Bounds.answer_messages(modules_max: MODULES, reasons: REASONS)
  end

  def test_the_bytes_agree_with_external_size
    output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval', ORACLE,
                                     stdin_data: '')
    assert status.success?, output
    measured = output.strip.delete('[]').split(',').map { |size| Integer(size) }
    # external_size counts the version byte, as the facet's measure and a frame's payload do.
    assert_equal measured, terms.map { |term| 1 + term.bytes }
  end

  # A load opens its tuple, its manifest list and an entry tuple; an answer its tuple,
  # {error, _}, {not_loaded, _}, the list and a pair. A load's words are dominated by
  # its entries: a cons cell, a 4-word tuple, a refc name of 8 words, a 32-byte heap
  # hash of 6 and a two-word big size. A facet's request opens the call envelope, the
  # request, the manifest and an entry, and its reply the tag tuple and an answer's four.
  def test_the_floors_round_the_largest_message_up
    load = Bounds.load_messages(modules_max: MODULES, piece_max: PIECE)
    assert_equal [3, 1, 1], load.map(&:depth)
    assert_equal [1, 1, 5], Bounds.answer_messages(modules_max: MODULES, reasons: REASONS).map(&:depth)
    assert_equal [4, 4, 3, 3], Bounds.requests(modules_max: MODULES, piece_max: PIECE).map(&:depth)
    assert_equal [3, 5], Bounds.replies(modules_max: MODULES, reasons: REASONS).map(&:depth)
    # The load tuple of 4 words, its reference of 6 and the list's entries.
    assert_equal 4 + 6 + (MODULES * (2 + 4 + 8 + 6 + 2)), load.first.words
    assert_equal Bounds::Floors.new(max_frame: 131_072, max_message_heap: 8192, funnel_depth: 4),
                 Bounds.load_floors(modules_max: MODULES, piece_max: PIECE)
    assert_equal Bounds::Floors.new(max_frame: 131_072, max_message_heap: 4096, funnel_depth: 8),
                 Bounds.answer_floors(modules_max: MODULES, reasons: REASONS)
    assert_equal Bounds::Floors.new(max_frame: 131_072, max_message_heap: 8192, funnel_depth: 8),
                 Bounds.facet_floors(modules_max: MODULES, piece_max: PIECE, reasons: REASONS)
  end

  def test_the_abi_publishes_the_derived_bounds
    constant = ->(name) { Erx::ABI::Generated.constant(name) }
    modules = constant.call('code_modules_max')
    piece = constant.call('code_piece_max')
    assert_equal Bounds.request_max(modules_max: modules, piece_max: piece), constant.call('code_request_max')
    published = lambda do |receivers|
      %w[max_frame message_heap funnel_depth].map { |limit| constant.call("code_#{receivers}_#{limit}_min") }
    end
    { 'load' => Bounds.load_floors(modules_max: modules, piece_max: piece),
      'answer' => Bounds.answer_floors(modules_max: modules, reasons: REASONS),
      'facet' => Bounds.facet_floors(modules_max: modules, piece_max: piece, reasons: REASONS) }.each do |receivers, floors|
      assert_equal [floors.max_frame, floors.max_message_heap, floors.funnel_depth], published.call(receivers), receivers
    end
  end
end
