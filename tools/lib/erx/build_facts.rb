# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The facts of an image's build that `uname -v`, `-i` and `-K` show
  # (docs/design-shell.md, "Text commands"), as the file the image build
  # writes into each release of the image at abi/erx_abi.txt's build_facts_path and
  # erx_build reads back. The file is one `name value` line per fact, in
  # Facts' order:
  #
  #   revision n1234-5e45e725588e
  #   date 1794163353
  #   configuration qemu-virt/development
  #   kernel fiasco-50bbe8a98119
  #
  # revision is the source revision (SourceRevision#to_s) and date its
  # commit's time in seconds since the epoch, UTC, facts of the source
  # alone, so they are the same on every branch; both are unknown in a
  # tree that is not a git checkout, and they are the only facts of the
  # build host that enter the image. configuration is the platform and the
  # build kind, as FreeBSD's uname -i names a kernel configuration
  # (configuration), and kernel the packed kernel's name and upstream
  # revision. Each is the same for every build of one tree in one state, so
  # the image stays reproducible. A fact the build could not determine is
  # written `unknown`, never made up.
  module BuildFacts
    # nil stands for a fact the build could not determine.
    Facts = Data.define(:revision, :date, :configuration, :kernel)
    # What each fact may hold, which erx_build checks the same way when it
    # reads the file: printable ASCII with no space, so a line splits in two
    # at its first space and the fact needs no escaping to be shown.
    SHAPES = {
      revision: /\A(?:n[1-9][0-9]{0,9}-)?[0-9a-f]{12}(?:-dirty)?\z/,
      date: /\A[0-9]{1,12}\z/,
      configuration: %r{\A[a-z0-9][a-z0-9-]{0,63}/[a-z][a-z0-9-]{0,31}\z},
      kernel: /\A[a-z0-9][a-z0-9.-]{0,63}\z/
    }.freeze
    UNKNOWN = 'unknown'
    # What configuration adds to the build kind of a local test image.
    LOCAL = '-local'

    module_function

    # The configuration uname -i names: the platform record's name, a slash and
    # the build kind (development or release), each as it is, so a build of
    # qemu-virt for development is qemu-virt/development. A local test image, one
    # built to take packages whose license is not permissive (`tools/erx pack --local`),
    # adds -local to the build kind, qemu-virt/development-local, so uname -i on the
    # machine says the image may not leave the host that built it. It follows the
    # records, not where they lie in the tree.
    def configuration(platform:, build_kind:, local: false) = "#{platform}/#{build_kind}#{LOCAL if local}"

    # Whether configuration, a configuration fact, is a local test image's (configuration's local:).
    def local?(configuration) = configuration.end_with?(LOCAL)

    # The facts of an image of the source revision revision (SourceRevision.read, nil for a
    # tree that is no checkout) built for configuration with the kernel named kernel
    # (Fiasco#kernel_name).
    def gather(revision:, configuration:, kernel:)
      Facts.new(revision: revision&.to_s, date: revision&.committed_at&.to_i, configuration: configuration, kernel: kernel)
    end

    # Each fact's text by its name, in Facts' order, as the file holds it and the image's
    # build record names it (ImageRecord). A fact of the wrong shape raises, so the build
    # never writes a file erx_build would refuse.
    def texts(facts)
      facts.to_h.to_h do |name, value| # the Facts as a Hash, then each name to its text
        text = value.nil? ? UNKNOWN : value.to_s
        raise Error, "the build fact #{name} is not one uname can show: #{text.dump}" unless
          text == UNKNOWN || SHAPES.fetch(name).match?(text)

        [name.to_s, text]
      end
    end

    # The file's text.
    def render(facts) = texts(facts).map { |name, text| "#{name} #{text}\n" }.join
  end
end
