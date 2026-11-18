# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # What a domain's startup names that both the manifest check and the image builders
  # read, kept apart from either so that the check loads no runtime or release code:
  # the runtime artifact a domain row names, the app template's one recipe, and the
  # client side of the display.
  module DomainStartup
    # The artifact name of a domain's runtime image, the interpreter's, which a domain
    # row's or session template's `runtime @artifact.NAME` names (ProductionImage
    # places it).
    RUNTIME_ARTIFACT = 'emu'

    # The app template's startup (docs/design-packaging.md, "The apps row"), the one
    # recipe the manifest check derives the template's session row from: the runtime
    # and release artifacts it names, the release being the domain release's boot
    # script of that name (ReleaseFiles::RELEASE_SCRIPTS), its arguments as a source's
    # `args` writes them (the init arguments every session template gives, the network
    # client's grant flag and the -eval that starts erx_session and then erx_app, which
    # depends on it), and its environment, none.
    AppTemplate = Data.define(:runtime, :release, :args, :env)
    APP_TEMPLATE = AppTemplate.new(
      runtime: RUNTIME_ARTIFACT, release: 'app',
      args: '-- -root / -bindir /bin -progname erl -home / -nouser -nocookie -no_epmd -proto_dist erx ' \
            '-erx_net_client grant {erx_net_client_erxos,grant,[]} ' \
            '-eval ok=application:start(erx_session,permanent),ok=application:start(erx_app,permanent)',
      env: ''
    )

    # The client side of the display (docs/design-display.md, "The pixel area"): the
    # pixel primitives and erx_win, whose allocator, erx_pixels, gives a window its
    # buffer in the display's pixel area. Every release script that a holder of a
    # display's grant boots starts both, which property 18 checks against what the
    # checked context records each script starts (ReleaseFiles.domain_artifacts).
    DISPLAY_CLIENT = %w[erx_memdraw erx_win].freeze
  end
end
