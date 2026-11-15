# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# The erxos arch layers on a CPU's arch: arch/aarch64's headers and assembly stay,
# and this directory's files replace the few that assume Linux. ERX_ROOT is the erXos
# tree, ERX_GEN its generated files (build/gen, searched before the tree), and
# ERX_COMPILER_INCLUDE holds the compiler's <stdatomic.h>, which musl does not offer
# and the generated erx/abi.h includes. The files of ERX_ABI_OBJS read erx/abi.h, and
# those of ERX_SEAM_OBJS liberx's declarations too, so each rebuilds when what it
# reads changes. erXos's own files keep erXos's warnings, less the one musl's internal
# headers trip.
ARCH_CPU = aarch64

ERX_SEAM_OBJS = obj/src/internal/erxos/syscall.o obj/src/thread/erxos/clone.o obj/src/thread/erxos/pthread_create_executor.o
ERX_ABI_OBJS = $(ERX_SEAM_OBJS) obj/src/string/erxos/strsignal.o
$(ERX_ABI_OBJS): $(ERX_GEN)/include/erx/abi.h
$(ERX_ABI_OBJS): CFLAGS_ALL += -I$(ERX_GEN)/include -isystem $(ERX_COMPILER_INCLUDE)
$(ERX_SEAM_OBJS): $(wildcard $(ERX_ROOT)/liberx/backend/fiasco/*.h)
$(ERX_SEAM_OBJS): CFLAGS_ALL += -I$(ERX_GEN) -I$(ERX_ROOT) -I$(ERX_ROOT)/include

# posix_spawn and its file actions build the spawn planner's request (liberx/program/spawn_plan.h).
ERX_SPAWN_OBJS = $(filter obj/src/process/erxos/posix_spawn%,$(ALL_OBJS))
ERX_SPAWN_HEADERS = $(ERX_GEN)/include/erx/abi.h $(wildcard $(ERX_ROOT)/liberx/backend/fiasco/*.h) $(ERX_GEN)/include/erx/prog_profile.h $(wildcard $(ERX_ROOT)/liberx/program/*.h)
$(ERX_SPAWN_OBJS): $(ERX_SPAWN_HEADERS) $(srcdir)/src/process/erxos/spawn_action.h
$(ERX_SPAWN_OBJS): CFLAGS_ALL += -I$(ERX_GEN) -I$(ERX_GEN)/include -I$(ERX_ROOT) -I$(ERX_ROOT)/include -isystem $(ERX_COMPILER_INCLUDE)

ERX_OWN_OBJS = $(addsuffix /erxos/%.o,obj/src/internal obj/src/thread obj/src/signal obj/src/process obj/src/string)
$(filter $(ERX_OWN_OBJS),$(ALL_OBJS)): CFLAGS_ALL += -Wall -Wextra -Werror -Wno-unused-parameter

# The numbers abi/signals.txt states, generated under $(ERX_GEN)/musl/include and
# searched after musl's own directories, as Erx::Musl#include_directories gives them
# to programs. No header of musl's has their names. Every object reads them, so every
# object rebuilds when they change.
ERX_NUMBER_HEADERS = $(ERX_GEN)/musl/include/bits/signum.h
CFLAGS_ALL += -I$(ERX_GEN)/musl/include
$(ALL_OBJS) $(ALL_OBJS:%.o=%.lo): $(ERX_NUMBER_HEADERS)
