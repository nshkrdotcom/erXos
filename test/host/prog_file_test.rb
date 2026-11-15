# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'fcntl'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# liberx's file client (liberx/program/file.h) with the descriptor table and the data area
# (liberx/program/fd.h, liberx/program/data.h), through test/fixtures/prog_file_driver.c,
# whose stand-in channel checks every request with the profile's generated request check and
# serves it as the program's handler would, from a file system in memory: an open sends
# lopen, or lcreate with O_CREAT, its flags as 9P2000.L's values and its mode less the
# umask; a write and a read move their bytes through a data slot, in parts of one slot,
# stopping at a short part; dup shares the open and its last close clunks it once; an open
# reserves its slot before its request, so a full table refuses it unsent, a refused open
# gives its slot back, and a dup3 onto the slot meanwhile is EBUSY; an open's O_CLOEXEC
# marks its slot, F_GETFL reads its access mode and status, and F_SETFL may not change a
# file's O_APPEND; flags the request cannot carry, bad paths
# and a dirfd that is no directory are refused before anything is sent; and a read answer
# past its count is EIO (docs/design-files.md, "Native clients: liberx's file client";
# docs/design-programs.md, "Descriptors and files" and "Reads and writes"). Every case runs
# under the address and undefined sanitizers, the threaded one under the thread sanitizer
# too, and each seeded fault must fail the case named beside it.
class ProgFileTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  FD = 'liberx/program/fd.c'
  FILE_C = 'liberx/program/file.c'
  DATA = 'liberx/program/data.c'
  SOURCES = [FD, 'liberx/program/fd_plan.c', FILE_C, DATA, 'liberx/program/wake.c', 'liberx/program/pages.c', 'liberx/erx_profile.c',
             'liberx/erx_etf.c', 'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c',
             'build/gen/liberx/generated/prog_profile.c', 'test/fixtures/prog_file_driver.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread'].freeze
  ASAN = ['-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  TSAN = ['-fsanitize=thread'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  # The driver's errors are the host's own numbers; the stand-in answers in them too.
  E = %i[ENOENT EIO EBADF EACCES EEXIST ENOTDIR EINVAL EMFILE EFAULT ENAMETOOLONG ENOSYS EBUSY EOVERFLOW]
      .to_h { |name| [name, -Errno.const_get(name)::Errno] }.freeze

  FLAGS_CASE = 'O_DIRECTORY and O_NOFOLLOW as 9P2000.L values, whatever O_CREAT, and O_NONBLOCK as nothing'

  CASES = {
    'an open, a write, a read back and a close' => [
      ['slots 4', 'ok'],
      ['open cwd /a wronly|creat|trunc 0666', '0'],
      ['write 0 hello', '5'],
      ['close 0', '0'],
      ['open cwd /a rdonly 0', '0'],
      ['read 0 100', '5 hello'],
      ['read 0 100', '0 -'],
      ['close 0', '0'],
      ['log', 'lcreate:/a:0x201:0644 write:0:5:0 clunk:0 lopen:/a:0 read:0:100:0 read:0:100:0 clunk:0']
    ],
    'flags as 9P2000.L values and the mode less the umask' => [
      ['slots 1', 'ok'],
      ['umask 027', 'ok'],
      ['open cwd /f wronly|creat|excl|append|sync 0777', '0'],
      ['open cwd /f rdwr|trunc 0', '1'],
      ['open cwd /f rdonly|excl|dsync|cloexec|noctty 0', '2'],
      ['open cwd /f wronly|creat 0', '3'],
      ['log', 'lcreate:/f:0x101481:0750 lopen:/f:0x202 lopen:/f:0x101000 lcreate:/f:0x1:0']
    ],
    FLAGS_CASE => [
      ['slots 1', 'ok'],
      ['open cwd /f rdonly|creat 0644', '0'],
      ['open cwd /f rdonly|directory 0', '1'],
      ['open cwd /f rdonly|nofollow 0', '2'],
      ['open cwd /f rdonly|nonblock 0', '3'],
      ['open cwd /f wronly|creat|directory|nofollow 0600', '4'],
      ['log', 'lcreate:/f:0:0644 lopen:/f:0x10000 lopen:/f:0x20000 lopen:/f:0 lcreate:/f:0x30001:0600']
    ],
    'flags, paths and directories refused before a request' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdonly|creat 0644', '0'],
      ['log', 'lcreate:/f:0:0644'],
      ['open cwd /f accmode 0', E[:EINVAL].to_s],
      ['open cwd /f rdonly|async 0', E[:EINVAL].to_s],
      ['open cwd @ rdonly 0', E[:EFAULT].to_s],
      ['open cwd % rdonly 0', E[:ENOENT].to_s],
      ['open cwd #4097 rdonly 0', E[:ENAMETOOLONG].to_s],
      ['open 9 f rdonly 0', E[:EBADF].to_s],
      ['open 0 f rdonly 0', E[:ENOTDIR].to_s],
      ['log', 'none'],
      ['open 9 /f rdonly 0', '1'],
      ['open cwd #4096 rdonly 0', E[:ENOENT].to_s],
      ['log', "lopen:/f:0 lopen:#{'a' * 4096}:0"]
    ],
    "the handler's errors" => [
      ['slots 1', 'ok'],
      ['open cwd /f wronly|creat 0600', '0'],
      ['fail 13', 'ok'],
      ['open cwd /f rdonly 0', E[:EACCES].to_s],
      ['open cwd /f wronly|creat|excl 0600', E[:EEXIST].to_s],
      ['open cwd /f rdonly 0', '1'],
      ['fail 5', 'ok'],
      ['write 0 x', E[:EIO].to_s],
      ['write 0 x', '1'],
      ['log', 'lcreate:/f:0x1:0600 lopen:/f:0 lcreate:/f:0x81:0600 lopen:/f:0 write:0:1:0']
    ],
    'reads and writes past a slot go in parts' => [
      ['slots 2', 'ok'],
      ['open cwd /big rdwr|creat 0600', '0'],
      ['writen 0 3 150000', '150000'],
      ['open cwd /big rdonly 0', '1'],
      ['readn 1 3 200000', '150000 same'],
      ['readn 1 3 10', '0 same'],
      ['log', 'lcreate:/big:0x2:0600 write:0:65536:0 write:0:65536:0 write:0:18928:0 lopen:/big:0 ' \
              'read:1:65536:0 read:1:65536:0 read:1:65536:0 read:1:10:0']
    ],
    'no request for a transfer of no bytes' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat 0600', '0'],
      ['writen 0 1 0', '0'],
      ['readn 0 1 0', '0 same'],
      ['log', 'lcreate:/f:0x2:0600']
    ],
    'a read answer past its count is EIO' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat 0600', '0'],
      ['write 0 abc', '3'],
      ['open cwd /f rdonly 0', '1'],
      ['lie 1', 'ok'],
      ['read 1 2', "#{E[:EIO]} -"]
    ],
    'dup shares the open and the last close clunks it once' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat 0600', '0'],
      ['dup 0', '1'],
      ['close 0', '0'],
      ['log', 'lcreate:/f:0x2:0600'],
      ['write 1 x', '1'],
      ['close 1', '0'],
      ['close 1', E[:EBADF].to_s],
      ['log', 'write:0:1:0 clunk:0']
    ],
    'a full table refuses an open before its request' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat 0600', '0'],
      ['dupall 0', '1023'],
      ['open cwd /f rdonly 0', E[:EMFILE].to_s],
      ['log', 'lcreate:/f:0x2:0600']
    ],
    'a reserved slot holds nothing and is taken by no dup while its open waits' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat 0600', '0'],
      ['probe 1', 'ok'],
      ['open cwd /f rdonly 0', '1'],
      ['dup 0', '3'],
      ['log', "lcreate:/f:0x2:0600 probe:#{E[:EBADF]}:#{E[:EBADF]}:none:2:#{E[:EBUSY]} lopen:/f:0"]
    ],
    "an open's O_CLOEXEC, F_GETFL and an O_APPEND that stays the open's" => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat|cloexec 0600', '0'],
      ['open cwd /f wronly|append 0', '1'],
      ['fcntl 0 getfd rdonly', Fcntl::FD_CLOEXEC.to_s],
      ['fcntl 1 getfd rdonly', '0'],
      ['fcntl 0 getfl rdonly', Fcntl::O_RDWR.to_s],
      ['fcntl 1 getfl rdonly', (Fcntl::O_WRONLY | Fcntl::O_APPEND).to_s],
      ['fcntl 1 setfl rdonly', E[:EINVAL].to_s],
      ['fcntl 0 setfl append', E[:EINVAL].to_s],
      ['fcntl 1 setfl append|nonblock', '0'],
      ['fcntl 1 getfl rdonly', (Fcntl::O_WRONLY | Fcntl::O_APPEND | Fcntl::O_NONBLOCK).to_s],
      ['fcntl 0 getfl rdonly', Fcntl::O_RDWR.to_s],
      ['log', 'lcreate:/f:0x2:0600 lopen:/f:0x401']
    ],
    # lseek moves the description's offset as FreeBSD's vn_seek does; pread and pwrite
    # leave it; a whence past SEEK_END and a negative pread offset send nothing.
    'lseek, pread and pwrite of a file' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat 0600', '0'],
      ['write 0 hello', '5'],
      ['lseek 0 0 cur', '5'],
      ['lseek 0 -2 end', '3'],
      ['read 0 100', '2 lo'],
      ['lseek 0 -6 cur', E[:EINVAL].to_s],
      ['lseek 0 9223372036854775807 cur', E[:EOVERFLOW].to_s],
      ['lseek 0 0 data', E[:EINVAL].to_s],
      ['pread 0 3 1', '3 ell'],
      ['read 0 100', '0 -'],
      ['pwrite 0 1 EL', '2'],
      ['pread 0 100 0', '5 hELlo'],
      ['pread 0 4 -1', "#{E[:EINVAL]} -"],
      ['pread 0 4 99', '0 -'],
      ['log', 'lcreate:/f:0x2:0600 write:0:5:0 seek:0:0:cur seek:0:-2:eof read:0:100:0 seek:0:-6:cur ' \
              'seek:0:9223372036854775807:cur pread:0:1:3:0 read:0:100:0 pwrite:0:1:2:0 pread:0:0:100:0 ' \
              'pread:0:99:4:0']
    ],
    'what a file does not offer' => [
      ['slots 1', 'ok'],
      ['open cwd /f rdwr|creat 0600', '0'],
      ['fstat 0', E[:ENOSYS].to_s]
    ]
  }.freeze

  # Two threads read their own files through a data area of one slot; each read's slot stays
  # taken while the stand-in sleeps, so a slot both took would carry the other's bytes.
  THREADED = {
    'two threads take turns at one data slot' => [
      ['slots 1', 'ok'],
      ['slow 2000', 'ok'],
      ['race 20 70000', 'ok ok']
    ]
  }.freeze

  # A seeded fault, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    'a negative pread offset is sent' =>
      ['lseek, pread and pwrite of a file', FD, "\tif (offset < 0)\n\t\treturn (-EINVAL);\n\tif (len == 0)\n", "\tif (len == 0)\n"],
    'a slot taken is not marked taken' => ['two threads take turns at one data slot', DATA, "\ttaken |= UINT32_C(1) << slot;\n", ''],
    'a read answer past its count is copied' =>
      ['a read answer past its count is EIO', FILE_C, "if (answer->u.ok.io_done > count)\n", "if (false)\n"],
    'the umask is not applied' =>
      ['flags as 9P2000.L values and the mode less the umask', FILE_C, 'mode & ~(mode_t)umask & 07777', 'mode & ~(mode_t)(umask & 0) & 07777'],
    'a short part does not end the transfer' =>
      ['reads and writes past a slot go in parts', FILE_C, "\t\tif (done < part)\n\t\t\tbreak;\n", ''],
    'a file is let go at its first close while a dup holds it' =>
      ['dup shares the open and the last close clunks it once', FD, 'return (--obj->refs == 0);', 'return (--obj->refs <= 1);'],
    'an open asks before it finds a slot' =>
      ['a full table refuses an open before its request', FILE_C, "\tif ((fd = erx_prog_fd_reserve()) < 0) {\n", "\tif ((fd = erx_prog_fd_reserve()) < -1000) {\n"],
    'a reserved slot is empty to a dup' =>
      ['a reserved slot holds nothing and is taken by no dup while its open waits', 'liberx/program/fd_plan.c',
       "\treturn (slot->obj == NULL && !slot->reserved);\n", "\treturn (slot->obj == NULL);\n"],
    'a refused open keeps its slot' =>
      ["the handler's errors", FILE_C, "\t\terx_prog_fd_unreserve(fd);\n", ''],
    'a dup3 onto a reserved slot takes it' =>
      ['a reserved slot holds nothing and is taken by no dup while its open waits', 'liberx/program/fd_plan.c',
       'return (slots[req.at].reserved ? -EBUSY : (int)req.at);', 'return ((int)req.at);'],
    "an open's O_CLOEXEC is dropped" =>
      ["an open's O_CLOEXEC, F_GETFL and an O_APPEND that stays the open's", FILE_C,
       'erx_prog_fd_fill(fd, &file->obj, (flags & O_CLOEXEC) != 0);', 'erx_prog_fd_fill(fd, &file->obj, false);'],
    "a file's O_APPEND may change" =>
      ["an open's O_CLOEXEC, F_GETFL and an O_APPEND that stays the open's", FD,
       "\t\treturn (O_APPEND);\n", "\t\treturn (0);\n"],
    'O_EXCL travels without O_CREAT' =>
      ['flags as 9P2000.L values and the mode less the umask', FILE_C, 'if (create && (flags & O_EXCL) != 0)', 'if ((flags & O_EXCL) != 0)'],
    'a flag open_plan does not know is sent' =>
      ['flags, paths and directories refused before a request', FILE_C, '(flags & ~(OPEN_MAPPED | OPEN_IGNORED)) != 0 ||', ''],
    'O_DIRECTORY is not sent' => [FLAGS_CASE, FILE_C, "\t\tp9 |= ERX_P9_O_DIRECTORY;\n", ''],
    'O_NOFOLLOW is not sent' => [FLAGS_CASE, FILE_C, "\t\tp9 |= ERX_P9_O_NOFOLLOW;\n", ''],
    'O_NONBLOCK is refused' => [FLAGS_CASE, FILE_C, 'O_NOCTTY | O_NONBLOCK | LARGEFILE', 'O_NOCTTY | LARGEFILE'],
    'O_NONBLOCK is sent as O_APPEND' =>
      [FLAGS_CASE, FILE_C, "\tif ((flags & O_APPEND) != 0)\n", "\tif ((flags & (O_APPEND | O_NONBLOCK)) != 0)\n"]
  }.freeze

  def test_each_case_under_the_address_and_undefined_sanitizers
    with_driver({}, ASAN) do |driver|
      CASES.merge(THREADED).each do |name, steps|
        assert_equal steps.map(&:last), run_case(driver, steps), name
      end
    end
  end

  def test_threaded_cases_under_the_thread_sanitizer
    with_driver({}, TSAN) do |driver|
      THREADED.each do |name, steps|
        assert_equal steps.map(&:last), run_case(driver, steps), name
      end
    end
  end

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, (kase, file, original, replacement)|
      source = File.read(File.join(ROOT, file))
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
      with_driver({ file => source.sub(original, replacement) }, ASAN) do |driver|
        steps = CASES.merge(THREADED).fetch(kase)
        refute_equal steps.map(&:last), run_case(driver, steps), "seeded fault not caught: #{name}"
      end
    end
  end

  private

  # Builds the driver from SOURCES, each source named in replaced taking the text it maps to.
  def with_driver(replaced, sanitizers)
    Dir.mktmpdir('erx-prog-file-') do |directory|
      sources = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(directory, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
      end
      binary = File.join(directory, 'driver')
      includes = ['-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                  '-I', File.join(ROOT, 'kernel/crypto')]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *sanitizers, *includes, *sources, '-o', binary, stdin_data: '')
      assert status.success?, "compiling the driver failed:\n#{output}"
      yield binary
    end
  end

  # The driver's answers to the case's commands, a line each, or all it printed when it stopped.
  def run_case(driver, steps)
    Dir.mktmpdir('erx-prog-file-case-') do |directory|
      script = File.join(directory, 'script')
      File.write(script, steps.map { |command, _| "#{command}\n" }.join)
      output, = Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0' }, 'gtimeout', '-k', '10', '120',
                                driver, script, stdin_data: '')
      output.lines(chomp: true)
    end
  end
end
