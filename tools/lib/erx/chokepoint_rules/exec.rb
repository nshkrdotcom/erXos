# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    EXEC_LOAD = 'liberx/exec/load.c'
    EXEC_FILES = %w[liberx/exec/load.c liberx/exec/load.h liberx/exec/load_plan.c liberx/exec/load_plan.h
                    liberx/exec/range.h liberx/exec/release.c liberx/exec/release.h].freeze

    # erXos's own C, the stopgap kernel's glue and erXos's C inside ERTS, which links liberx.
    EXEC_SCOPE = Chokepoints::Scope.new(own: true, extra: [GLUE, 'otp/erts/emulator/nifs/erxos/**/*',
                                                          'otp/erts/emulator/sys/erxos/**/*'])

    declare_group(
      rules: [
        # An executable file reaches a program only through erx_exec, which
        # plans its bytes once and maps by that plan, so a header rule is
        # written once. Beside it the stopgap's erx_image_map plans a file
        # entry of the boot archive, the host tools plan for the packer and
        # the fuzz target, and the loader's host driver plans for its test.
        Chokepoints::Forbidden.new(
          name: 'elf-reader-callers',
          rule: "only erx_exec's load (#{EXEC_LOAD}) and pure core call erx_elf_plan or erx_elf_relocation in " \
                "a program, beside the stopgap's erx_image_map of a file entry, the host planner, the fuzz " \
                "target and the loader's host driver",
          design: 'docs/design.md#chokepoint-checks',
          scope: EXEC_SCOPE,
          pattern: /\berx_elf_(?:plan|relocation)\b/,
          sites: %w[liberx/elf_plan.c include/erx/elf_plan.h liberx/exec/load.c liberx/exec/load_plan.c
                    liberx/backend/fiasco/service_task.c tools/host/elf_plan.c tools/fuzz/elf_fuzz.c
                    test/fixtures/exec_load_driver.c].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/program/seeded.c' => "bool f(void) { return (erx_elf_plan(b, n, n, &p, &e)); }\n",
                  'otp/erts/emulator/nifs/erxos/seeded.c' => "static void *plan = (void *)erx_elf_plan;\n" }
        ),
        # Both are the text half of the design's link check, whose object leg
        # waits for liberx's target objects (unchecked_objects below).
        #
        # liberx's one function that maps an executable file's code into a
        # program. Only erx_exec calls it; the program that runs it at
        # libexec/erx_exec is not in the tree yet, so no site outside the
        # loader names it but its host driver, which runs it over memory
        # calls of its own.
        Chokepoints::Forbidden.new(
          name: 'exec-code-map',
          rule: "only erx_exec maps an executable file's code into a program: erx_exec_load " \
                "(#{EXEC_LOAD}) is named only by its own module and its host driver",
          design: 'docs/design.md#chokepoint-checks',
          scope: EXEC_SCOPE,
          pattern: /\berx_exec_load\b/,
          sites: %w[liberx/exec/load.c liberx/exec/load.h test/fixtures/exec_load_effects.c].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/program/seeded.c' => "bool f(void) { return (erx_exec_load(o, n, b, &i, &e)); }\n",
                  'otp/erts/emulator/sys/erxos/seeded.c' => "(void)erx_exec_load(o, n, b, &i, &f);\n" }
        ),
        # A loader's tenure ends once, in the program layer's entry, before musl's
        # start (docs/design-programs.md, "The loader's bootstrap", Release): a
        # second caller would read a record whose page is already released.
        Chokepoints::Forbidden.new(
          name: 'exec-release-once',
          rule: 'only erx_prog_enter (liberx/program/program.c) calls erx_exec_release, beside its own module ' \
                'and its host driver',
          design: 'docs/design-programs.md#what-a-program-can-start',
          scope: EXEC_SCOPE,
          pattern: /\berx_exec_release\b/,
          sites: %w[liberx/exec/release.c liberx/exec/release.h liberx/program/program.c
                    test/fixtures/exec_release_driver.c].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/backend/fiasco/seeded.c' => "void f(void) { (void)erx_exec_release(r, own); }\n",
                  'otp/erts/emulator/sys/erxos/seeded.c' => "static void *release = (void *)erx_exec_release;\n" }
        )
      ],
      unchecked_objects: EXEC_FILES
    )
  end
end
