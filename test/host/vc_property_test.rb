# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/generated_tree'

# Judges the mailbox core of erx_firmware_request, kernel/core/vc_property.c
# (docs/design-kernel.md, "Firmware requests"; docs/design-board-sensors.md, "The kernel
# call"), through test/fixtures/vc_property_driver.c: the buffer it writes for the VL805's
# NOTIFY_XHCI_RESET (docs/design-usb.md, "The VL805's firmware") and for a model tag with
# an answer window, and its check of the answer the firmware leaves: a response code other
# than success, a first tag other than the row's or a length below the least answer is
# ERX_EPROTO, a response word without bit 31 is ERX_ENOTSUP, and a longer answer is cut to
# the window. SET_GPIO_STATE, which the firmware answers in its first value word, is ERX_OK
# with no bytes on a response word of 0 or with bit 31 set only when that word, the pin
# word, reads 0, and ERX_ENOTSUP otherwise, as a buffer the firmware left untouched keeps
# the pin the request wrote (docs/design-bluetooth.md, "The power line"). Seeded faults
# must each change a pinned answer.
class VcPropertyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'kernel/core/vc_property.c'
  DRIVER = 'test/fixtures/vc_property_driver.c'

  # name => [original, replacement]; each must change the answers of test_answers.
  MUTANTS = {
    "a word outside fw_tag given a declaration" => ["\tdefault:\n\t\treturn (NULL);", "\tdefault:\n\t\treturn (&vc_notify_xhci_reset);"],
    'the response code unchecked' => ['code != ERX_VC_CODE_SUCCESS', 'code == ERX_VC_CODE_REQUEST'],
    'the first tag searched past' => ['tag != spec->tag', 'tag == 0'],
    'the response bit unchecked' => ['erx_vc_tag_header_indicator_response_get(indicator) != 0 ||',
                                     'indicator != 0xffffffffu ||'],
    'the least answer unchecked' => [') < spec->least_bytes', ') > UINT32_MAX - 1'],
    'the window not cut' => ['length < spec->window_bytes ? length : spec->window_bytes', 'length'],
    'the value buffer sized by the request alone' =>
      ['spec->request_bytes > spec->window_bytes ? spec->request_bytes : spec->window_bytes', 'spec->request_bytes'],
    'the end tag left out' => ["\twords[at++] = ERX_VC_END_TAG;\n", ''],
    'the argument read past its words' => ['word < request_words', 'word <= request_words'],
    'the request built from its first word alone' => ['word < request_words ? argument[word]', 'word < request_words && word < 1 ? argument[word]'],
    "result_word ignored, so the power line's answer is refused" =>
      ['(spec->result_word && indicator == 0)', '(false && indicator == 0)'],
    'result_word taken as true for every tag, so an ignored VL805 notification reads as performed' =>
      ['.result_word = ERX_VC_NOTIFY_XHCI_RESET_RESULT_WORD != 0', '.result_word = true'],
    'the pin word unchecked, so an untouched buffer reads as performed' =>
      ['words[ERX_VC_VALUE_WORD] == 0 ? ERX_OK : ERX_ENOTSUP', 'ERX_OK'],
    'the copy past the answer' => ['at < answer.length ? value[at]', 'at < spec->window_bytes ? value[at]'],
    'the copy from the tag header' => ['&words[ERX_VC_VALUE_WORD]', '&words[ERX_VC_VALUE_WORD - 1]']
  }.freeze

  NOTIFY_ANSWER = '0000001c 80000000 00030058 00000004'
  MODEL_ANSWER = '00000020 80000000 00012345 00000008'
  GPIO_ANSWER = '00000020 80000000 00038041 00000008'

  # The requests the tests pin, and the answers the design gives them.
  ANSWERS = [
    # The VL805 at bus 1, device 0, function 0: seven words, 28 bytes, code 0, the tag,
    # a one-word value buffer, a request word of 0, the address, the end tag.
    ['request notify 00100000', 'request 0000001c 00000000 00030058 00000004 00000000 00100000 00000000'],
    # The model tag's 8-byte window sizes its value buffer: eight words.
    ['request model 00000007', 'request 00000020 00000000 00012345 00000008 00000000 00000007 00000000 00000000'],
    # A performed notification answers ERX_OK with nothing; a longer answer is cut to the
    # empty window.
    ["answer notify #{NOTIFY_ANSWER} 80000000", 'answer 0 0 '],
    ["answer notify #{NOTIFY_ANSWER} 80000004 11111111", 'answer 0 0 '],
    # The firmware ignored the tag: ERX_ENOTSUP.
    ["answer notify #{NOTIFY_ANSWER} 00000000", 'answer -12 0 '],
    ["answer notify #{NOTIFY_ANSWER} 00000004", 'answer -12 0 '],
    # An error parsing the buffer, a code never answered, another first tag: ERX_EPROTO.
    ['answer notify 0000001c 80000001 00030058 00000004 80000000', 'answer -18 0 '],
    ['answer notify 0000001c 80000002 00030058 00000004 80000000', 'answer -18 0 '],
    ['answer notify 0000001c 00000000 00030058 00000004 00000000', 'answer -18 0 '],
    ['answer notify 0000001c 80000000 00030059 00000004 80000000', 'answer -18 0 '],
    # A wrong tag is refused before its response word is read.
    ['answer notify 0000001c 80000000 00030059 00000004 00000000', 'answer -18 0 '],
    # The model tag: its length within the window, its bytes copied and zeroes after them;
    # a longer answer cut to the window; below its least answer, or ignored, nothing copied.
    ["answer model #{MODEL_ANSWER} 80000006 04030201 08070605 11111111", 'answer 0 6 0102030405060000'],
    ["answer model #{MODEL_ANSWER} 80000010 04030201 08070605 11111111", 'answer 0 8 0102030405060708'],
    ["answer model #{MODEL_ANSWER} 80000003 04030201 08070605", 'answer -18 0 0000000000000000'],
    ["answer model #{MODEL_ANSWER} 00000006 04030201 08070605", 'answer -12 0 0000000000000000'],
    # The power line's on request, pin 128 and state 1: eight words, 32 bytes, both words
    # in the two-word value buffer.
    ['request gpio 00000080 00000001', 'request 00000020 00000000 00038041 00000008 00000000 00000080 00000001 00000000'],
    # Performed: a response word of 0, as the Pi 4's firmware leaves it, or with bit 31 set,
    # and the pin word 0; ERX_OK with no bytes whatever the length.
    ["answer gpio #{GPIO_ANSWER} 00000000 00000000 00000001", 'answer 0 0 '],
    ["answer gpio #{GPIO_ANSWER} 80000000 00000000 00000001", 'answer 0 0 '],
    ["answer gpio #{GPIO_ANSWER} 80000008 00000000 00000001", 'answer 0 0 '],
    # Not performed: the pin word left at 128, as an untouched buffer keeps it, with either
    # response word; and a nonzero response word without bit 31, the tag ignored.
    ["answer gpio #{GPIO_ANSWER} 00000000 00000080 00000001", 'answer -12 0 '],
    ["answer gpio #{GPIO_ANSWER} 80000000 00000080 00000001", 'answer -12 0 '],
    ["answer gpio #{GPIO_ANSWER} 00000004 00000000 00000001", 'answer -12 0 '],
    # Outside the interface: an error parsing the buffer, or another first tag.
    ['answer gpio 00000020 80000001 00038041 00000008 00000000 00000000 00000001', 'answer -18 0 '],
    ['answer gpio 00000020 80000000 00030058 00000008 00000000 00000000 00000001', 'answer -18 0 '],
    # Only a member of fw_tag has a declaration: NOTIFY_XHCI_RESET's and SET_GPIO_STATE's
    # identifiers, and not a tag the firmware knows that erXos does not send, nor the end tag.
    ['tag 00030058', 'tag 1'],
    ['tag 00038041', 'tag 1'],
    ['tag 00030006', 'tag 0'],
    ['tag 00000000', 'tag 0']
  ].freeze

  def setup
    @directory = Dir.mktmpdir('erx-vc-property-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core: File.join(ROOT, CORE), name: 'driver')
    output = File.join(@directory, name.tr(" '", '--'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  # The driver's answers; a run that ends in a failure (a sanitizer's abort under a
  # mutant) answers nil, which no pinned list equals.
  def ask(program, strict: true)
    output, status = Open3.capture2e(program, stdin_data: ANSWERS.map { |request, _| "#{request}\n" }.join)
    assert status.success?, output if strict
    status.success? ? output.lines.map(&:chomp) : nil
  end

  def test_answers
    assert_equal ANSWERS.map(&:last), ask(build)
  end

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, CORE))
    MUTANTS.each do |name, (original, replacement)|
      assert_equal 1, source.scan(original).size, "mutant #{name}: #{original.inspect} is not unique in #{CORE}"
      mutant = File.join(@directory, "#{name.tr(" '", '--')}.c")
      File.write(mutant, source.sub(original, replacement))
      refute_equal ANSWERS.map(&:last), ask(build(core: mutant, name: name), strict: false), "mutant #{name} survives"
    end
  end
end
