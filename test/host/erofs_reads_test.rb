# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/erofs_reads'

# The chokepoint that the EROFS reader reaches an image only through
# erx_verity:read/3 and that no other module reaches erx_verity's store
# (docs/design-storage.md, invariant E1): the tree passes, and each seeded way
# around the funnel fails, and so does a mount of an image by any module but
# erx_ns and erx_storage_system, an open of one by the reader outside its mount, and a
# mount of the `system` tree with a layout its caller hands it.
class ErofsReadsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  READER = 'otp/erts/preloaded/src/erx_erofs.erl'
  SERVICE = 'erlang/apps/erx_files/src/seeded.erl'
  SYSTEM = 'erlang/apps/erx_storage/src/erx_storage_system.erl'
  # The reader's one open, in its mount, which every fixture of the reader ends with.
  OPEN = "mount(W, T, L) -> erx_verity:open(W, T).\n"

  def lines_of(files) = Erx::ErofsReads.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes_and_the_reader_uses_the_funnel
    paths = Erx::ErofsReads::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::ErofsReads.violations(files).map(&:to_s)
    assert_match(/erx_verity:read\(Image, First, Count\)/, files.fetch(READER))
  end

  def test_another_module_naming_the_funnel_fails
    text = "f(I) -> erx_verity:read(I, 0, 1).\ng() -> 'erx_verity'.\nh() -> \"erx_verity\".\n"
    assert_equal [[SERVICE, 1], [SERVICE, 2], [SERVICE, 3]], lines_of(SERVICE => text)
  end

  def test_the_reader_may_only_read_through_the_funnel
    assert_empty lines_of(READER => "f(I) -> erx_verity:read(I, 0, 1).\n-type t() :: erx_verity:image().\n" \
                                "-type u() :: erx_verity:tree().\n#{OPEN}")
    text = "f(I) -> erx_verity:check(I, 1).\ng(I) -> erx_verity:close(I).\n#{OPEN}"
    assert_equal [[READER, 1], [READER, 2]], lines_of(READER => text)
  end

  def test_the_reader_calls_no_module_that_reaches_state
    text = "f(I) -> persistent_term:get(I).\ng(I) -> 'ets':lookup(t, I).\nh(M, I) -> M:read(I).\n" \
           "i(I) -> apply(persistent_term, get, [I]).\nj() -> fun file:read_file/1.\nk() -> ?MODULE:f(1).\nl() -> lists:seq(1, 2).\n#{OPEN}"
    assert_equal (1..7).map { |line| [READER, line] }, lines_of(READER => text)
  end

  def test_comments_strings_and_binaries_in_the_reader_pass
    text = "%% persistent_term:get(x)\nf(<<V:16/little, _/binary>>) -> \"file:read(x)\", binary:at(<<1>>, V).\n" \
           "g() -> try ok catch throw:{x, Y} -> Y end.\nh() -> \#{a := b} = \#{a => b}.\n#{OPEN}"
    assert_empty lines_of(READER => text)
  end

  # Only erx_ns and erx_storage_system open an image in erx_verity, through the
  # mount; a call, a quoted call and a fun of it anywhere else fail.
  def test_only_the_two_mounters_mount_an_image
    call = "f(W) -> erx_erofs:mount(W, unchecked, fun log/1).\n"
    mounters = %w[erlang/apps/erx/src/erx_ns.erl erlang/apps/erx_storage/src/erx_storage_system.erl]
    assert_empty lines_of(mounters.to_h { |path| [path, call] })
    text = "#{call}g(W) -> 'erx_erofs':'mount'(W, unchecked, fun log/1).\nh() -> fun erx_erofs:mount/3.\n" \
           "i(W) -> erx_erofs:walk(W, []).\n%% erx_erofs:mount(W, unchecked, L)\nj() -> \"erx_erofs:mount(\".\n"
    assert_equal [[SERVICE, 1], [SERVICE, 2], [SERVICE, 3]], lines_of(SERVICE => text)
    assert_equal [['otp/erts/preloaded/src/erx_verity.erl', 1]], lines_of('otp/erts/preloaded/src/erx_verity.erl' => call)
  end

  # The reader opens an image in erx_verity once, in its mount, which no other function
  # of it calls, so the two mounters are the only modules that open one: an open in
  # another function, in a macro, a second one, none at all, and a call or a fun of the
  # mount inside a body fail.
  def test_the_reader_opens_an_image_only_in_its_mount
    assert_empty lines_of(READER => "-export([mount/3]).\n-spec mount(pid(), t(), l()) -> r().\n" \
                                    "mount(W, T, L) when is_function(L, 1) ->\n" \
                                    "    case 'erx_verity':'open'(W, T) of {ok, I} -> mount_image(I) end.\n" \
                                    "mount_image(I) -> erx_verity:read(I, 0, 1).\n")
    assert_equal [[READER, 1]], lines_of(READER => "f(I) -> erx_verity:read(I, 0, 1).\n")
    assert_equal [[READER, 1]], lines_of(READER => "g(W) -> erx_verity:open(W, unchecked).\nmount(W, T, L) -> g(W).\n")
    assert_equal [[READER, 2]], lines_of(READER => "#{OPEN}-define(OPEN(W), erx_verity:open(W, unchecked)).\n")
    assert_equal [[READER, 3]], lines_of(READER => "mount(W, T, L) ->\n    erx_verity:open(W, T),\n    erx_verity:open(W, T).\n")
    text = "#{OPEN}unchecked(W) -> mount(W, unchecked, fun(_) -> ok end).\nlog() -> fun mount/3.\n"
    assert_equal [[READER, 2], [READER, 3]], lines_of(READER => text)
  end

  # Only erx_storage_system's mint mounts the `system` tree, with the layout the module
  # reads from its own boot record (E1): a call or a fun of its mount, quoted or not, in
  # any other module of the release fails, and in its EUnit cases passes.
  def test_no_other_module_mounts_the_system_tree
    text = "f(W) -> erx_storage_system:mount(W, [], fun log/1).\ng() -> fun 'erx_storage_system':'mount'/3.\n" \
           "h(W) -> erx_storage_system:mount(W).\ni() -> erx_storage_system:start_mint().\n"
    assert_equal [[SERVICE, 1], [SERVICE, 2], [SERVICE, 3]], lines_of(SERVICE => text)
    assert_empty lines_of(SYSTEM => "f(W) -> erx_storage_system:mount(W).\n")
    assert_empty lines_of('test/erlang/erx_storage_system_tests.erl' => text)
  end

  def test_the_funnel_itself_and_files_outside_the_scope_pass
    call = "f(I) -> persistent_term:get(I), erx_verity:read(I, 0, 1).\n"
    assert_empty lines_of('otp/erts/preloaded/src/erx_verity.erl' => call, 'test/erlang/seeded_tests.erl' => call)
  end

  # The source check runs the rule over the files git lists, OTP's included.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(READER)))
      File.write(File.join(root, READER), "f(I) -> persistent_term:get(I).\n")
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_erofs_reads, [READER, 'README.md']) }
      assert_match "#{READER}:1", error.message
    end
  end
end
