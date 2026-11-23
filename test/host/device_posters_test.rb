# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The chokepoint "only the block driver's one write path issues writes", held by
# construction: a call of erx_device:post/4 outside erx_blk_write fails, in the driver's
# own modules too, in every spelling of ErlangCallSpellings.
class DevicePostersTest < Minitest::Test
  include ChokepointsHelper

  WRITE_PATH = 'erlang/apps/erx_blk/src/erx_blk_write.erl'
  DRIVER = 'erlang/apps/erx_blk/src/erx_blk_virtio.erl'
  SEEDED = "p(D, Q, T, S) -> erx_device:post(D, Q, T, S).\n"

  RULES = %w[device-posters device-commands].freeze

  def lines_of(files) = erlang_found(RULES, files).map { |_, path, line| [path, line] }

  def test_the_tree_passes_and_the_write_path_posts
    files = erlang_tree
    assert_empty evaluate(RULES.map { |name| rule(name) }, files).map(&:to_s)
    assert_match rule('device-posters').pattern, files.fetch(WRITE_PATH)
    assert_match rule('device-commands').pattern, files.fetch(WRITE_PATH)
  end

  def test_a_seeded_post_outside_the_write_path_is_refused
    assert_equal [[DRIVER, 2]], lines_of(DRIVER => "%% erx_device:post/4 in a comment is not code\n#{SEEDED}")
    ErlangCallSpellings.all('erx_device', 'post').each do |spelling|
      assert_equal [['device-posters', DRIVER, spelling.line]], erlang_found(%w[device-posters], DRIVER => spelling.source),
                   spelling.form
    end
    ErlangCallSpellings.unrelated('erx_device', 'post').each { |source| assert_empty lines_of(DRIVER => source), source }
    # An import or a macro of the module reaches every issuing call, so each rule refuses it.
    assert_equal [['device-posters', DRIVER, 1], ['device-commands', DRIVER, 1]],
                 erlang_found(RULES, DRIVER => "-import(erx_device, [read/2, post/4]).\n")
    assert_equal [['erlang/apps/erx_uart/src/seeded.erl', 1]], lines_of('erlang/apps/erx_uart/src/seeded.erl' => SEEDED)
    assert_equal [['otp/lib/stdlib/src/seeded.erl', 1]], lines_of('otp/lib/stdlib/src/seeded.erl' => SEEDED)
  end

  # command/2 has one site, the write path: a post site of another transport may not issue
  # an SD command either.
  COMMANDED = "c(D, W) -> erx_device:command(D, W).\n"

  def test_a_seeded_command_outside_the_write_path_is_refused
    ErlangCallSpellings.all('erx_device', 'command').each do |spelling|
      assert_equal [['device-commands', DRIVER, spelling.line]], erlang_found(%w[device-commands], DRIVER => spelling.source),
                   spelling.form
    end
    net = 'erlang/apps/erx_net/erxos/erx_virtio_net.erl'
    assert_equal [[net, 1]], lines_of(net => COMMANDED)
    assert_equal [[net, 1]], lines_of(net => "-import(erx_device, [command/2]).\n")
    assert_empty lines_of(WRITE_PATH => COMMANDED)
  end

  def test_other_device_calls_the_write_path_and_tests_are_not_refused
    assert_empty lines_of(WRITE_PATH => SEEDED)
    assert_empty lines_of(DRIVER => "f(D, Q) -> erx_device:complete(D, Q), erx_device:poster(D), my_erx_device:post(D).\n")
    assert_empty lines_of(DRIVER => "f() -> \"erx_device, posted\".\n")
    assert_empty lines_of('test/erlang/seeded_tests.erl' => SEEDED)
  end

  # The source check runs the rule over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    error = enforce_seeded(RULES, DRIVER, SEEDED)
    assert_match "#{DRIVER}:1", error.message
  end
end
