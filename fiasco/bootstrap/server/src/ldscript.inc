/* Modified by erXos: bootstrap's device table comes first in .data, so the linker
   fills it by section name (docs/design-fiasco.md, "Toolchain"). */
/* vi:ft=c
   Common functionality for linker scripts in bootstrap */

#define CTORS                             \
    . = ALIGN(0x10);                      \
    PROVIDE (__CTORS_BEGIN = .);          \
    KEEP (*(SORT(.ctors.*)))              \
    KEEP (*(.ctors))                      \
    PROVIDE (__CTORS_END = .);            \
    PROVIDE (__preinit_array_start = .);  \
    KEEP (*(SORT(.preinit_array.*)))      \
    KEEP (*(.preinit_array))              \
    PROVIDE (__preinit_array_end = .);    \
    PROVIDE (__init_array_start = .);     \
    KEEP (*(SORT(.init_array.*)))         \
    KEEP (*(.init_array))                 \
    PROVIDE (__init_array_end = .);


#define PLATFORMS                      \
    PROVIDE (__PLATFORMS_BEGIN = .);   \
    KEEP (*(.platformdata))            \
    PROVIDE (__PLATFORMS_END = .);

/* The UART device table. It precedes every rule that matches .data.*, so the
   first rule a .data.l4redevice section matches is this one. */
#define DEVS \
    PROVIDE (__L4RE_DEVICE_BEGIN = .); \
    KEEP (*(.data.l4redevice)) \
    PROVIDE (__L4RE_DEVICE_END = .);
