# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # Opening a file that must not be a symbolic link: File.open with O_NOFOLLOW, whose
  # refusal of a link at the path's last component is one typed error on every host.
  # POSIX names that refusal ELOOP, as macOS and Linux give it; FreeBSD gives EMLINK
  # instead (open(2), ERRORS and STANDARDS). ELOOP also means a loop of links earlier
  # in the path, which is refused the same way.
  module NoFollow
    # The path is a symbolic link, or resolving it met a loop of them.
    class Link < Error; end

    module_function

    # File.open(path, flags | O_NOFOLLOW, *rest, **options), yielding the file to the block and
    # closing it after, or returning it open without a block. Raises Link for a link;
    # every other error of the open, and every error the block raises, passes as it is.
    def open(path, flags, *rest, **options)
      file = begin
        File.open(path, flags | File::NOFOLLOW, *rest, **options)
      rescue Errno::ELOOP, Errno::EMLINK
        raise Link, "#{path} is a symbolic link"
      end
      return file unless block_given?

      begin
        yield file
      ensure
        file.close
      end
    end
  end
end
