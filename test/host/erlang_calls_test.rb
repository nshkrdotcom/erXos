# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/erlang_text'
require_relative 'erlang_call_spellings'

# Erx::ErlangText.calls, the one pattern of the Erlang rules "only X calls
# M:F": it refuses every spelling of a call of each function in
# ErlangCallSpellings and none of the unrelated sources.
class ErlangCallsTest < Minitest::Test
  CALLS = Erx::ErlangText.calls(module_name: 'm', functions: %w[f g])

  def test_every_spelling_of_either_function_is_refused
    %w[f g].each do |fun|
      ErlangCallSpellings.all('m', fun).each do |spelling|
        assert_match CALLS, Erx::ErlangText.code(spelling.source), "#{spelling.form} of #{fun}"
      end
    end
  end

  def test_unrelated_sources_pass
    ErlangCallSpellings.unrelated('m', 'f').each { |source| refute_match CALLS, Erx::ErlangText.code(source), source }
  end
end
