# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'zlib'
require_relative 'error'
require_relative 'ppm'

module Erx
  # A reference picture of a guest's display: the checked-in digest a screendump must equal
  # (equal decoded pixels, Ppm::Image#digest, as docs/design-display.md, "Verification and
  # testing", defines a screenshot that equals its reference), and, beside it, the same picture as
  # a gzip-compressed PPM so that a person can look at what a failing run should have shown
  # (`gunzip -c NAME.ppm.gz > NAME.ppm`; compressed to keep the checked-in file small). For a
  # reference called NAME in a directory:
  #
  #   NAME.sha256    one line: the 64 lowercase hex digits, a space, WIDTHxHEIGHT
  #   NAME.ppm.gz    the picture
  module ScreenReference
    class Mismatch < Error; end

    LINE = /\A(?<digest>[0-9a-f]{64}) (?<width>[1-9][0-9]{0,4})x(?<height>[1-9][0-9]{0,4})\n\z/
    NAME = /\A[a-z][a-z0-9_-]{0,63}\z/

    Reference = Data.define(:name, :digest, :width, :height, :picture_path)

    module_function

    # The reference NAME in directory; a missing or malformed digest file raises.
    def load(directory, name)
      raise Error, "invalid reference name #{name.inspect}" unless name.is_a?(String) && NAME.match?(name)

      path = File.join(directory, "#{name}.sha256")
      match = LINE.match(File.binread(path, 128))
      raise Error, "#{path} is not '<sha256> <width>x<height>'" unless match

      Reference.new(name: name, digest: match[:digest], width: match[:width].to_i, height: match[:height].to_i,
                    picture_path: File.join(directory, "#{name}.ppm.gz"))
    rescue SystemCallError => e
      raise Error, "cannot read #{path}: #{e.class.name.split('::').last}"
    end

    # Whether image is the reference's picture, by its digest file alone.
    def matches?(image, reference)
      image.digest == reference.digest && image.width == reference.width && image.height == reference.height
    end

    # Nil when image is the reference's picture; otherwise Mismatch, naming both digests,
    # the reference picture to compare by eye and, for a screen of the reference's size,
    # how many pixels differ from that picture and where.
    def check(image, directory:, name:)
      reference = load(directory, name)
      return nil if matches?(image, reference)

      raise Mismatch, "screen is #{image.width}x#{image.height} digest #{image.digest}; reference #{name} is " \
                      "#{reference.width}x#{reference.height} digest #{reference.digest} (picture: #{reference.picture_path})" \
                      "#{difference(image, reference)}"
    end

    # The part of a mismatch's message that says where image differs from the reference's
    # picture; empty for a screen of another size, which the message's sizes already show.
    def difference(image, reference)
      return '' unless [image.width, image.height] == [reference.width, reference.height]

      found = image.difference(picture(reference))
      found ? "; #{found}" : '; no pixel differs from the picture, which its digest file does not name'
    rescue Error => e
      "; #{e.message}"
    end

    # The reference's own picture, decoded.
    def picture(reference)
      Zlib::GzipReader.open(reference.picture_path) do |gzip|
        Ppm.decode(gzip.read(Ppm::MAX_FILE_BYTES + 1))
      end
    rescue Zlib::Error, SystemCallError => e
      raise Error, "cannot read #{reference.picture_path}: #{e.class.name.split('::').last}"
    end

    # Writes image as the reference NAME in directory, both its files; answers the picture's path.
    def write(directory, name, image)
      raise Error, "invalid reference name #{name.inspect}" unless name.is_a?(String) && NAME.match?(name)

      digest, picture = encode(image)
      File.write(File.join(directory, "#{name}.sha256"), digest)
      File.join(directory, "#{name}.ppm.gz").tap { |path| File.binwrite(path, picture) }
    rescue SystemCallError => e
      raise Error, "cannot write the reference #{name} in #{directory}: #{e.class.name.split('::').last}"
    end

    # The two files of a reference for image, as [digest line, gzip PPM], for a person who
    # records a new reference after looking at the picture.
    def encode(image)
      [format("%<digest>s %<width>dx%<height>d\n", digest: image.digest, width: image.width, height: image.height),
       Zlib.gzip(image.to_ppm, level: 9)]
    end
  end
end
