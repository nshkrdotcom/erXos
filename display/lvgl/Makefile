# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# Builds erx-lvgl for the host: LVGL's sources from the submodule, the
# theme's fonts the glyph step writes (Glyphs::LvglFont), the generated
# reader and writer of ui.txt's binary form, and erx_lvgl.c. For the
# target it builds only $(OUT)/liblvgl.a, LVGL and the fonts compiled with the
# code generation FLAGS names (Lvgl::Program.library_flags), and
# tools/lib/erx/native_root.rb links the program from it.
# tools/lib/erx/lvgl.rb runs it with every variable set; objects go under
# OUT, so the submodule's tree is never written. Each object's headers are
# recorded in a .d file beside it, so a change to an LVGL header rebuilds
# what includes it.
#
#   LVGL     LVGL's tree, the submodule display/lvgl/lvgl
#   GEN      build/gen, holding include/erx/ui_wire.h and the C source
#   GLYPHS   build/glyphs, holding each role's erx_lvgl_font_ROLE.c (Glyphs.ensure)
#   OUT      the output directory
#   CC       the C compiler
#   AR       the archiver: the host's ar, or LLVM's llvm-ar for the target's ELF
#   FLAGS    the code generation flags: the host's -g -O1, or the target's
#            (Lvgl::Program), its libc's headers among them
#   SANITIZE the sanitizer flags, or nothing

AR ?= ar
HERE := $(dir $(lastword $(MAKEFILE_LIST)))

# Sorted, so the archive's members are in one order on every host. FrogFS, which
# LV_USE_FS_FROGFS leaves off, is left out whole: it is MPL-2.0, and its decomp_raw.c
# compiles under any configuration (Lvgl::Program::LICENSE).
LVGL_SOURCES := $(sort $(filter-out $(LVGL)/src/libs/frogfs/%,$(shell find $(LVGL)/src -name '*.c' -type f)))
LVGL_OBJECTS := $(patsubst $(LVGL)/%.c,$(OUT)/lvgl/%.o,$(LVGL_SOURCES))
# One font a theme role; the directory is exactly what the glyph step wrote.
FONT_SOURCES := $(sort $(wildcard $(GLYPHS)/erx_lvgl_font_*.c))
FONT_OBJECTS := $(patsubst $(GLYPHS)/%.c,$(OUT)/fonts/%.o,$(FONT_SOURCES))
ifeq ($(FONT_SOURCES),)
$(error $(GLYPHS) holds no erx_lvgl_font_*.c; the glyph step writes them)
endif

COMMON := -std=c17 $(FLAGS) -MMD -MP $(SANITIZE) -DLV_CONF_INCLUDE_SIMPLE -I$(HERE) -I$(LVGL)
LVGL_CFLAGS := $(COMMON) -w
OWN_CFLAGS := $(COMMON) -Wall -Wextra -Werror -I$(GEN)/include

$(OUT)/erx-lvgl: $(OUT)/erx_lvgl.o $(OUT)/erx_ui_wire.o $(OUT)/liblvgl.a
	$(CC) $(SANITIZE) -o $@ $(OUT)/erx_lvgl.o $(OUT)/erx_ui_wire.o $(OUT)/liblvgl.a -lm

# The Makefile too, so a source it stops listing leaves the archive, and the
# glyph directory, which the glyph step replaces whole when a role changes.
$(OUT)/liblvgl.a: $(LVGL_OBJECTS) $(FONT_OBJECTS) $(HERE)Makefile $(GLYPHS)
	rm -f $@
	$(AR) rcs $@ $(LVGL_OBJECTS) $(FONT_OBJECTS)

$(OUT)/lvgl/%.o: $(LVGL)/%.c $(HERE)lv_conf.h
	@mkdir -p $(dir $@)
	$(CC) $(LVGL_CFLAGS) -c $< -o $@

$(OUT)/fonts/%.o: $(GLYPHS)/%.c $(HERE)lv_conf.h
	@mkdir -p $(dir $@)
	$(CC) $(OWN_CFLAGS) -c $< -o $@

$(OUT)/erx_lvgl.o: $(HERE)erx_lvgl.c $(HERE)lv_conf.h $(GEN)/include/erx/ui_wire.h
	@mkdir -p $(OUT)
	$(CC) $(OWN_CFLAGS) -c $< -o $@

$(OUT)/erx_ui_wire.o: $(GEN)/display/generated/erx_ui_wire.c $(GEN)/include/erx/ui_wire.h
	@mkdir -p $(OUT)
	$(CC) $(OWN_CFLAGS) -c $< -o $@

-include $(LVGL_OBJECTS:.o=.d) $(FONT_OBJECTS:.o=.d) $(OUT)/erx_lvgl.d $(OUT)/erx_ui_wire.d
