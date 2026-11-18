# Research record: C libraries and C++ runtimes for ERTS on AArch64

A point-in-time comparison of the C libraries and C++ runtimes that could carry
ERTS from OTP 29.1.2 built freestanding on AArch64, once for the kernel at EL1
and once for protection domains at EL0. It records what ERTS asks of its C
library, read from the OTP source; eight facts about each candidate; a
comparison; the C++ runtime options for the BeamAsm JIT; the ranking reached by
the survey this record restates, with its reasons; and what a C library seam
has to own. It does not choose a library: that is a project decision, recorded
in [design.md](design.md#decisions) when made. Findings here are never edited
in place; a re-check gets a new record.

**Superseded premise; trimmed record.** The build "for the kernel at EL1"
is superseded: every runtime, ERTS included, runs in user mode
([design.md](design.md#trust-placement)), and erXos chose musl
([design.md](design.md#c-library)). This copy drops the per-candidate
sections on FreeBSD libc, picolibc, the Arm Toolchain for Embedded, LLVM
libc, newlib and mlibc; the comparison and ranking still cover them. The
full record is `~/erxos-history/docs-archive/research-c-library.md`,
history commit `e38149b`.

**Date:** 2026-10-29.
**Host:** Apple M4 Max, macOS 27.0.1 (26A434).
**Sources read** (read only; no script, makefile or binary from them was run,
and no compiler was invoked):

* Erlang/OTP 29.1.2, `otp_src_29.1.2.tar.gz`, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`.
* musl 1.2.6, `musl-1.2.6.tar.gz`, SHA-256
  `d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a`.
* Sparse clones at picolibc 1.8.12 (`2ae376c6cdf4`), LLVM `llvmorg-23.1.4`
  (`7a941dfb2877`), mlibc v7.0.0 (`7c2a17814262`) and newlib-4.6.0
  (`8ba4275b83ec`); single files of ATfE 23.1.0, FreeBSD 15.1, libc++, libcxxrt
  and LLVM libc at the revisions under [Sources](#sources); the web pages
  listed there, accessed 2026-10-29.
* Searches with ugrep 7.8.4 and `wc`; pages fetched with curl 8.7.1.

Paths are relative to each source tree: `erts/...` and `lib/...` are OTP;
`src/...`, `arch/...` and `include/...` are musl unless a candidate is named.

## Method

* The record restates a survey of the candidates made for erXos on 2026-10-29.
  The survey read each candidate's source and documentation at the version
  given, counted physical source lines (`.c`, `.h`, `.s`, `.S`, `.cpp`, `.hpp`,
  `.cc`, test directories excluded) and summed the `.text` of static-archive
  members with `llvm-size`. Sizes, SPDX tag counts and dates are the survey's.
* Re-checked for this record: every ERTS-side statement, against the pinned OTP
  tree; musl's thread-pointer sites, `floatscan` buffer, TLS layout, `errno`,
  string routines, license notices, system-call count and size, against the
  pinned musl tree; and, in the clones and downloads, picolibc's digit limit,
  `_set_tls` sites, string-routine guards, lock hooks, ports and options, LLVM
  libc's missing math functions, baremetal configuration, header list and
  vendor symbols, mlibc's `strtod`, newlib's string guards and thread pointer,
  ATfE's pins, flags and README statements, libc++'s platform table and C
  library switch, libcxxrt's license and guards, FreeBSD's `tls.h`, the Docker
  official-images entry for erlang, libc.llvm.org, and musl commit `6426a515`.
* Where a re-check disagreed with the survey, this record gives the re-checked
  fact. The differences:
  1. Outside ethread, the JIT build's asmjit locks its `JitAllocator` with a
     pthread mutex; the survey found no `pthread_*` user outside ethread.
  2. The one compiler thread-local variable in OTP's C sources is a
     Windows-only `__declspec(thread)` in erl_interface, not a NIF.
  3. `getauxval` and `elf_aux_info` are called from asmjit's `cpuinfo.cpp`, not
     from its VirtMem.
  4. ERTS calls `ldexp`, `log10`, `pow`, `sqrt`, `fabs`, `floor`, `ceil` and
     `round` outside `erl_math.c`, beyond the rounding BIFs.
  5. `strtod` has a fourth caller, the `string:list_to_float/1` BIF behind
     `string:to_float/1`.
  6. The JIT includes more standard headers than the survey listed, and the
     `short` float format uses the bundled Ryu only under the default
     `--enable-builtin-ryu`.
  7. musl's `__set_thread_area` masks bits in `AT_HWCAP` and `AT_HWCAP2` and
     hides `AT_HWCAP3` and `AT_HWCAP4`; the survey named only `AT_HWCAP`.
  8. picolibc's general-register string routines need only
     `__ARM_FEATURE_UNALIGNED`; only its SIMD routines also need `__ARM_NEON`.
  9. libcxxrt's license carries the "views and conclusions" paragraph, which
     SPDX names `BSD-2-Clause-Views`.
  10. musl's 114k lines is a count without `compat/` (114,237); with it the
      count is 115,268.
  11. LLVM libc's baremetal configuration for AArch64 lists 25 public headers
      (26 with experimental entry points); the survey's 31 is the line count of
      the list file.
* "(survey's judgement)" marks an assessment rather than a measured fact, as
  are the activity labels and the EL1 and EL0 grades. Release and commit dates
  are in the [Comparison](#comparison) and under [Sources](#sources). Every
  statement has a source; none is marked unverified.

## What ERTS needs from the C library

Read from the pinned OTP tree [O1].

* **Threads.** ERTS's own C code reaches pthreads only through its ethread
  layer: `erts/lib_src/pthread/ethread.c` (819 lines) and `ethr_event.c` (703
  lines), with `erts/lib_src/common/ethr_mutex.c` and the headers under
  `erts/include/internal/`. It uses thread create, join, detach and exit,
  thread attributes (stack and guard size), keys for thread-specific data,
  mutexes, condition variables with `pthread_condattr_setclock`, rwlocks,
  spinlocks, `pthread_sigmask`, `pthread_kill` and the set-name calls. Events
  use the Linux futex when available (`ETHR_LINUX_FUTEX_IMPL__`,
  `ethr_event.c:52`) and otherwise a mutex and condition variable.
  `erts/lib_src/win/` implements the same layer without pthreads.
* **Other pthread users.** In the JIT build, asmjit's `JitAllocator` holds a
  `Lock` (`erts/emulator/asmjit/core/jitallocator.cpp:468`) that is a pthread
  mutex on POSIX (`asmjit/core/osutils_p.h:31-39`), and `protect_jit_memory`
  calls `pthread_jit_write_protect_np` only on macOS on Arm
  (`asmjit/core/virtmem.cpp:90-96`, `1218-1222`). zstd's thread pool is
  compiled out: nothing in the build defines `ZSTD_MULTITHREAD`
  (`erts/emulator/zstd/zstd.mk`). `erl_threads.h` names pthreads only in
  comments.
* **No compiler TLS.** No `__thread`, `_Thread_local` or `thread_local` appears
  in OTP's C or C++ sources under `erts` and `lib`; the one thread-local
  variable is a Windows-only `__declspec(thread)` in
  `lib/erl_interface/src/misc/ei_pthreads.c:36`. ERTS keeps thread-specific
  data in ethread keys.
* **Memory.** `malloc`, `realloc` and `free` for `sys_alloc`; `mmap`, `munmap`,
  `mremap`, `madvise` and `mprotect` in `erts/emulator/sys/common/erl_mmap.c`.
  JIT memory goes through asmjit's VirtMem (`mmap`, `mprotect`, `ftruncate`,
  and `memfd_create` or `shm_open` and `shm_unlink` for dual mapping,
  `asmjit/core/virtmem.cpp`), and CPU features through `getauxval` or
  `elf_aux_info` with `sysconf` (`asmjit/core/cpuinfo.cpp`).
* **Float formatting.** ERTS has its own printf
  (`erts/lib_src/common/erl_printf_format.c`) but hands each double to libc
  `sprintf` (`fmt_double`, line 435), after sizing the output with `log10`.
  `float_to_list/1` and `float_to_binary/1` default to 20 decimals in `%e`
  form: `SYS_DEFAULT_FLOAT_DECIMALS` is 20 (`erts/emulator/beam/sys.h:890`),
  and `sys_double_to_chars_ext` formats with `"%.*e"`
  (`erts/emulator/sys/unix/sys_float.c:58`). The `{decimals, N}` form uses
  ERTS's own `sys_double_to_chars_fast`
  (`erts/emulator/sys/common/erl_sys_common_misc.c:161`, with `floor` and
  `round`). The `short` form uses the bundled Ryu `d2s` (`erts/emulator/ryu/`)
  under the default `--enable-builtin-ryu`, or C++17 `std::to_chars` under
  `--disable-builtin-ryu` (`erts/emulator/sys/common/erl_float_short.cpp`).
* **Float parsing.** `sys_chars_to_double` (`sys_float.c:73`) checks the syntax
  itself, then calls `strtod` (lines 109 and 120, the second time with the
  other radix character). It rejects a result that is not finite or that
  overflowed to `HUGE_VAL` with `ERANGE`, and accepts underflow (lines
  126-136). Its callers are the `string:list_to_float/1` BIF behind
  `string:to_float/1` (`erts/emulator/beam/bif.c:3673`), `list_to_float/1` and
  `binary_to_float/1` (`bif.c:3689`) and `FLOAT_EXT` decoding
  (`erts/emulator/beam/external.c:4642`).
* **libm.** `erts/emulator/beam/erl_math.c` calls cos, cosh, sin, sinh, tan,
  tanh, acos, acosh, asin, asinh, atan, atanh, erf, erfc, exp, log, log2 (as
  `log(x)` divided by ln 2 without `HAVE_LOG2`), log10, sqrt, atan2, pow, ceil,
  floor and fmod. It checks results for finiteness (`ERTS_FP_ERROR_THOROUGH`,
  with an `isfinite` fallback in `erts/emulator/sys/unix/erl_unix_sys.h:365`)
  and reads `errno` only for acos and asin (`math_call_errno_1`), so a libm
  that never sets `errno` serves it. Elsewhere ERTS calls floor, ceil, round
  and fabs for the `trunc`, `floor`, `ceil`, `round` and `abs` BIFs
  (`erl_bif_guard.c`), ldexp (`big.c:2522`), pow and fabs (`utils.c:2409`),
  sqrt (`erl_db_hash.c:4106`), and pow, ceil and log10
  (`erts/emulator/sys/unix/sys_time.c:982`).
* **Time.** `clock_gettime` with `CLOCK_MONOTONIC` and `CLOCK_MONOTONIC_RAW`,
  `clock_getres`, `gettimeofday` and `times` (`sys_time.c`).
* **Dynamic loading.** `dlopen`, `dlsym`, `dlerror` and `dlclose`
  (`erts/emulator/sys/unix/erl_unix_sys_ddll.c`) serve only dynamically loaded
  NIFs and drivers; static ones need none.
* **The JIT's C++.** The JIT needs C++17 (`erts/configure.ac`, around line
  3112). Its sources (`erts/emulator/beam/jit/` and `jit/arm/`) include
  `<algorithm>`, `<numeric>`, `<vector>`, `<unordered_map>`, `<string>`,
  `<map>`, `<queue>`, `<limits>`, `<iterator>`, `<functional>`, `<cstring>`,
  `<cmath>` and, once, `<sstream>`; asmjit adds `<atomic>`. The one
  `std::stringstream` (`jit/arm/beam_asm_module.cpp:711`) names the anchor
  label of a veneer. `dynamic_cast` appears only under `DEBUG`
  (`beam_jit_common.cpp:136`) and `std::mutex` only under `BEAMASM_DUMP_SIZES`
  (`beam_asm_module.cpp:36-45`); asmjit throws no exceptions; no OTP build file
  passes `-fno-exceptions` or `-fno-rtti`. The release JIT could therefore
  build with both once the stringstream is replaced (survey's judgement).

## Candidates

### musl 1.2.6

Sources: [M1] to [M7], [X1].

1. **License.** `MIT`. TRE regex is `BSD-2-Clause`, `crypt_des.c`
   `BSD-3-Clause`, blowfish crypt public domain with a permissive fallback, and
   smoothsort MIT-style; math files carry the Sun notice (`SunPro`) or
   FreeBSD-author and Arm (`MIT`) notices (`COPYRIGHT`).
2. **Size and maintenance.** 114k lines, 24.7k of them math, complex and fenv
   (re-counted: 114,237 without `compat/`, 24,685). Alpine's `musl-dev`
   1.2.6-r6 aarch64 `libc.a`, which includes libm and pthreads, has 549 KB of
   `.text`. Master is active: commit `6426a515`, "strtod: fix incorrect logic
   detecting underflow", reports `ERANGE` on any inexact denormal; such fixes
   reach 1.2.6 only by cherry-pick.
3. **Freestanding.** No: the FAQ says musl is "intended for use on Linux-based
   systems."
4. **OS hooks.** The Linux system-call ABI: every call goes through
   `__syscallN` in `arch/aarch64/syscall_arch.h` (`svc 0`), and `src/` names
   341 distinct `SYS_` numbers. About 25 matter here: read, readv, writev,
   close, lseek, ioctl, fcntl and open for stdio; mmap, munmap and optionally
   brk, mremap and madvise for mallocng; clock_gettime, clock_getres and
   clock_nanosleep; clone, futex (wait, wake, requeue and timed waits; the PI
   operations only for PI mutexes), set_tid_address, exit, mprotect,
   sched_yield and rt_sigprocmask for threads; and an auxv. On another kernel
   one either emulates Linux or forks the bottom half: Fuchsia's libc is a musl
   fork with "no UNIX signals, fork, and exec", wasi-libc pairs a musl "top
   half" with a cloudlibc "bottom half", and seL4 keeps a musllibc fork.
   [research-erts-host.md](research-erts-host.md#musls-kernel-interface-on-aarch64)
   has musl's whole kernel interface.
5. **Threads and TLS.** Full pthreads on
   `clone(CLONE_VM|...|CLONE_SETTLS|CLONE_CHILD_CLEARTID...)` and futex. TLS is
   variant 1 (`TLS_ABOVE_TP`, `GAP_ABOVE_TP 16`,
   `arch/aarch64/pthread_arch.h`), with musl's `struct pthread` just below the
   thread pointer. `errno` (`__errno_location` returns
   `&__pthread_self()->errno_val`), locale, stdio lock ownership and the thread
   list hang off that struct, so every thread that calls musl must be a musl
   thread. TPIDR_EL0 is hard-coded in three places:
   `arch/aarch64/pthread_arch.h:4` (`mrs`),
   `src/thread/aarch64/__set_thread_area.c:8` (`msr`) and
   `src/ldso/aarch64/tlsdesc.s:23` (`mrs`); clang's `-mtp` does not reach them
   [C1]. `__init_tls` finds `PT_TLS` through `AT_PHDR`
   (`src/env/__init_tls.c:90-96`) and copies the image into a built-in buffer
   or an mmap'd block. `__set_thread_area` writes TPIDR_EL0 and then edits the
   auxv: it clears SME and unknown future bits in `AT_HWCAP` (bits 42 to 63)
   and `AT_HWCAP2`, and turns `AT_HWCAP3` and `AT_HWCAP4` into `AT_IGNORE`.
6. **libm and conversions.** FreeBSD msun and fdlibm lineage, with Arm
   optimized-routines for exp, exp2, log, log2 and pow. The goal is under 1.5
   ulp, with documented exceptions including the inverse hyperbolics and lgamma
   and tgamma; it sets no `errno` (`math_errhandling` is `MATH_ERREXCEPT`,
   `include/math.h:26-28`); every ERTS function is present. Decimal conversions
   are correctly rounded and exact. AArch64's `long double` is binary128
   (`LDBL_MANT_DIG` 113), so `decfloat` in `src/internal/floatscan.c` keeps an
   8 KiB stack array (`uint32_t x[KMAX]` with `KMAX` 2048, lines 22-28 and 65),
   and printf hands every double to `fmt_fp` as a `long double`
   (`src/stdio/vfprintf.c:181`) and formats it in software binary128
   arithmetic: slower, and the stack array matters on small kernel stacks. For
   a double, `fmt_fp`'s own digit buffer is sized from `DBL_MAX_EXP`, 128
   words.
7. **libc++.** libc++ runs on musl in production (Chimera Linux uses musl with
   libc++ and libunwind on AArch64), but libc++'s platform table says of Linux:
   "Only glibc-2.24 and later and no other libc is officially supported"
   (`libcxx/docs/index.rst:149`).
8. **EL1 and EL0.** `memcpy` uses only general-purpose registers; `memset` uses
   Advanced SIMD (`v0` and `q0`, `src/string/aarch64/memset.S:26-74`); both
   assume unaligned access. Poor at EL1 (three TPIDR_EL0 sites, the TCB at the
   thread pointer, futex-based internal locks); good at EL0 through a Linux
   shim or a forked bottom half.

### Others and exclusions

Sources: [E1], [E2].

* **Bionic:** Linux-only; its libc NOTICE is mostly BSD, ISC and MIT with some
  `Apache-2.0`, and its libm is FreeBSD msun; its reserved TLS slots are "not
  compatible with ARM's variant 1 layout".
* **Cosmopolitan 4.0.2:** `ISC`; it targets host OS ABIs plus BIOS and keeps
  its TLS pointer in `x28` on AArch64.
* **OpenBSD libc** (OpenBSD 8.0): `ISC` and BSD, tied to the OpenBSD kernel,
  for example by `pinsyscalls(2)`.
* **relibc:** `MIT`, but written in Rust.
* **Excluded on license**, all Linux-only as well: glibc (`LGPL-2.1-or-later`),
  uClibc-ng 1.0.59 (`LGPL-2.1`) and dietlibc 0.35 (`GPL-2.0`).

## Comparison

| Candidate | License | Size | Freestanding | OS hooks | Threads and TLS | libm and conversions | libc++ | EL1 | EL0 | Release; activity |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| musl 1.2.6 | MIT (+ BSD-2-Clause, BSD-3-Clause, SunPro, public domain) | 114k lines; 549 KB `.text` | no | Linux system calls (341 names) | pthreads on clone and futex; variant 1, TCB at TP, TPIDR_EL0 in assembly at 3 sites | msun, fdlibm and Arm routines, goal under 1.5 ulp; exact conversions | works (Chimera Linux), unofficial | poor | good through a Linux shim or a forked bottom half | 2026-03-20; active |
| FreeBSD 15.1 libc and msun | BSD-2-Clause, BSD-3-Clause, ISC, some BSD-4-Clause, dtoa, SunPro | about 336k lines; 1.64 MB + 241 KB `.text` | no | FreeBSD system calls (libsys), umtx | libthr; variant I, TPIDR_EL0 in `tls.h` | msun, the best of the fdlibm line; exact | on FreeBSD only | poor | poor | 2026-06-16; active |
| picolibc 1.8.12 | mostly BSD-3-Clause (+ Ryu Apache-2.0 OR BSL-1.0, SunPro) | 252k lines (all architectures); 518 KB `.text` | yes | about 20 POSIX functions in a `libos` port, 8 lock hooks | none; compiler TLS following `-mtp`; `_set_tls` at 2 sites | fdlibm and Arm routines; printf at most 17 significant digits, `strtod` exact to 17 digits | official (arm); Arm tests AArch64 | excellent | good | 2026-08-01; active |
| ATfE 23.1.0 | Apache-2.0 WITH LLVM-exception, plus components | 22 AArch64 variants; libc++ 652 or 759 KB | yes | as picolibc or LLVM libc | libc++ without threads; TPIDR_EL0 | as picolibc | yes, exceptions and RTTI on or off | recipe only | recipe only | 2026-09-10 |
| LLVM libc 23.1.4 | Apache-2.0 WITH LLVM-exception | 316k lines; 994 + 443 KB `.text` | yes | 9 vendor symbols; in-tree port for POSIX | Linux only; baremetal single-threaded | correctly rounded, but 8 ERTS doubles missing | partial (CI without locale or threads) | fair (no locking) | fair | 2026-10-20; very active |
| newlib 4.6.0 | BSD-like mix; LGPL only for `*-linux` | 431k lines | yes | about 17 `_r` system calls | none; `_reent` or a TLS option | fdlibm and Arm routines; exact | unofficial; ATfE overlay | good | fair | 2026-01-23; slow |
| mlibc 7.0.0 | MIT | 124k lines | no | sysdeps (16 mandatory) | pthreads; TPIDR_EL0 hard-coded | musl libm; `strtod` and printf inexact | out of tree | poor | fair after float fixes | 2026-08-02; active |
| Bionic, Cosmopolitan, OpenBSD | BSD-like, ISC, ISC | - | no | host kernel ABI | Android slots, `x28`, rthreads | msun, -, - | - | poor | poor | rolling, 2025-01-04, 2026-10-20 |

## C++ runtime options

Sources: [X1], [X2], [A1], and [O1] for the JIT.

**libc++, libc++abi and libunwind** (LLVM 23.1.x; `Apache-2.0 WITH
LLVM-exception`):

* **Switches.** Threads through pthread, C11 or
  `LIBCXX_HAS_EXTERNAL_THREAD_API` (a vendor `<__external_threading>` header);
  `LIBCXX_ENABLE_EXCEPTIONS` and `LIBCXX_ENABLE_RTTI`, with RTTI off only when
  exceptions are off; `LIBCXX_ENABLE_LOCALIZATION`, whose off state removes
  `<iostream>`, `<regex>` and `<locale>`; separate switches for wide
  characters, filesystem, `random_device` and the monotonic clock;
  `LIBCXX_CXX_ABI` of `libcxxabi`, `libcxxrt` or `none`; `RUNTIMES_USE_LIBC` of
  `system`, `llvm-libc`, `picolibc` or `newlib`.
* **Needs from below.** The C string, stdlib and stdio functions and `abort`;
  with threads, mutex, condition variable, once, thread and TLS-key primitives,
  a monotonic clock and `nanosleep`. libc++abi needs `malloc` and
  `aligned_alloc` for `operator new`, stderr for abort messages (silent with
  `LIBCXXABI_BAREMETAL` and `NDEBUG`), a way to wait on static-initialisation
  guards (the Linux futex, otherwise libc++'s mutex and condition variable,
  `cxa_guard_impl.h`), and exception globals through `thread_local` or keys.
  libunwind, needed only with exceptions, needs `dl_iterate_phdr` or the
  baremetal linker symbols `__eh_frame_start`, `__eh_frame_end`,
  `__eh_frame_hdr_start` and `__eh_frame_hdr_end`.

**libcxxrt** (master `a6f71cbc`; `BSD-2-Clause-Views`, its demangler
`BSD-2-Clause` from elftoolchain): FreeBSD's Itanium ABI runtime, with RTTI,
exceptions (on LLVM libunwind or libgcc_s) and thread-safe static guards built
on atomics and `sched_yield` (`src/guard.cc:346`), without futexes. Its C
library needs are small: weak `pthread_key_*` and `pthread_once` with a "fake
TLS" fallback, and `dladdr` and `printf` only for the default terminate
diagnostics, which `LIBCXXRT_NO_DEFAULT_TERMINATE_DIAGNOSTICS` removes;
`CXXRT_NO_EXCEPTIONS` builds a variant without exceptions. It is simpler than
libc++abi, with a much smaller community.

**The minimum for `-fno-exceptions -fno-rtti` code that uses new and delete,
static locals and containers:**

1. The `operator new` and `delete` family (plain, array, sized, aligned,
   nothrow) over `malloc` and `aligned_alloc`, calling `abort` on failure.
2. `__cxa_guard_acquire`, `__cxa_guard_release` and `__cxa_guard_abort`; a
   futex-based version is about 50 lines. `-fno-threadsafe-statics` removes
   them, which is unsafe with concurrent schedulers.
3. `__cxa_atexit` and `__dso_handle`.
4. `__cxa_pure_virtual` and `__cxa_deleted_virtual`, both calling `abort`.
5. From a `libc++.a` built without exceptions and RTTI:
   `__libcpp_verbose_abort` (which the `__throw_*` helpers call when exceptions
   are off), `__next_prime` (for `unordered_map`) and the `basic_string`
   instantiations; plus compiler-rt builtins for binary128 soft float.

Either `libc++.a` with a libc++abi built without exceptions, or
`LIBCXX_CXX_ABI=none` with items 1 to 4 in the seam, meets this. With the JIT's
one `std::stringstream` replaced, `LIBCXX_ENABLE_LOCALIZATION=OFF` works and
libunwind is unnecessary. At EL1, every library that uses TLS (the C library,
and libc++abi when exceptions are on) must be compiled with clang's `-mtp=el1`
[C1].

## Ranking

The survey ranks the candidates for this design as follows; the reasons are the
survey's findings, not a decision of this record. Two findings drive it:

* ERTS uses pthreads only through ethread, which has a non-pthread backend
  (`erts/lib_src/win/`), so an ethread backend on native threads removes the
  need for a libc pthread library at both levels. That removes most of the
  advantage of the libraries that own thread creation and the thread-pointer
  layout (musl, mlibc, FreeBSD). The re-check adds one more user in the JIT
  build: asmjit's `Lock`, a four-function class with POSIX, Windows and empty
  variants.
* ERTS depends on the C library for float conversion through only two paths,
  both in sys-layer files: `strtod` from `sys_float.c` and `sprintf` for `%e`,
  `%f` and `%g` from `erl_printf_format.c`. A seam can own exact conversions,
  and the math BIFs' libm can be replaced behind it too.

1. **picolibc 1.8.12 at EL1 and EL0, with a project-built LLVM 23 libc++ and
   libc++abi** (libunwind only with exceptions), using ATfE 23.1.0 as the build
   recipe rather than as shipped binaries.
   * Why: the only candidate good at both levels with one code base and one
     seam; built for bare metal, with a hook surface of about 20 functions as
     `libos` ports and 8 lock hooks; it does not own threads, so ethread can
     sit directly on erXos threads; its TLS follows `-mtp=el1`, with a single
     overridable register write; libc++ supports it officially, and Arm builds
     and tests libc++ on AArch64 picolibc; mostly `BSD-3-Clause`.
   * Main risk: float fidelity and POSIX breadth. printf stops at 17
     significant digits, so `float_to_list/1` output would differ from OTP on
     Linux and musl; `strtod` double-rounds inputs of 18 or more digits; libm
     is fdlibm-grade, not correctly rounded. picolibc has no `pthread.h`,
     `sys/socket.h` or `sys/uio.h`, which the ERTS sys layer must supply.
   * Mitigation: the seam owns exact conversions (Ryu `d2fixed`, under the same
     `Apache-2.0 OR BSL-1.0` terms as ERTS's bundled Ryu, or David Gay's dtoa),
     and optionally replaces math functions with CORE-MATH (`MIT`) [R1] or LLVM
     libc's `shared/math.h`. Secondary risk: ATfE's stated move to LLVM libc
     may shrink Arm's investment in picolibc (survey's judgement).
2. **musl 1.2.6, at EL0 only.**
   * Why: the most complete at EL0 (full POSIX and pthreads, exact conversions,
     `MIT`), and ERTS 29.1.2 ships on musl for arm64 as a Docker official image
     (`29.1.2-alpine`, `arm64v8` [M5]), so the unix sys layer and the pthread
     ethread backend would work largely unchanged.
   * Main risk: the seam's vocabulary becomes Linux: either about 25 Linux
     system calls emulated with their full semantics (clone flags, futex
     operations, auxv, `-errno` returns), or a fork of musl's bottom half
     maintained as Fuchsia and wasi-libc do. musl is not usable at EL1 without
     surgery (three TPIDR_EL0 sites, the TCB at the thread pointer, futex-based
     internal locks), which probably means a second C library and a second C++
     runtime configuration for the kernel (survey's judgement).
3. **LLVM libc 23.1.x.**
   * Why: the same license and project as clang and libc++, the smallest
     baremetal hook set, correctly rounded math, exact printf and `strtod`,
     memory routines that follow the compile flags, and Arm's announced
     direction.
   * Main risk: too immature for this use: 8 ERTS math functions missing in
     23.1.x (5 of them also on main), no thread safety in baremetal mode,
     libc++ only in reduced configurations, and an out-of-tree port for full
     POSIX on another operating system. The survey suggests using it as a parts
     source behind the seam and re-evaluating it at a later LLVM release.
4. **newlib**, a fallback to picolibc: exact conversions, but heavier, with an
   older reentrancy model.
5. **mlibc**: a good porting model, but its conversions are wrong for ERTS and
   the library is C++20.
6. **FreeBSD**: parts only (msun, gdtoa).

Bionic, Cosmopolitan, OpenBSD libc and relibc are unsuitable.

## What a C library seam must own

Whatever C library is chosen, the survey finds that the seam has to own:

* the ethread backend;
* memory mapping (`erl_mmap.c` and asmjit's VirtMem);
* clocks and sleep, the console, and entropy;
* float to string and string to float conversion (`sys_float.c` and the `%e`,
  `%f` and `%g` path in `erl_printf_format.c`);
* optionally, the libm behind the math BIFs.

The C library then supplies only string, ctype, stdlib, stdio formatting and
`malloc`, and switching it changes only the adapter: a `libos` port, the lock
hooks and `_set_tls` for picolibc; the nine vendor symbols and locking wrappers
for LLVM libc; a Linux system-call shim for musl.

The re-check of the OTP source adds, for the JIT build, asmjit's `Lock` (a
pthread mutex) and its CPU-feature query (`getauxval` or `elf_aux_info`). It
also identifies two contracts the conversions must keep: `strtod` reports
overflow as `HUGE_VAL` with `ERANGE`, which `sys_chars_to_double` turns into an
error while it accepts underflow, and `float_to_list/1` prints 21 significant
digits in `%e` form, so a conversion exact to only 17 digits changes its
output.

## Sources

All accessed 2026-10-29.

* [O1] Erlang/OTP 29.1.2, pinned tree:
  `erts/lib_src/pthread/{ethread.c,ethr_event.c}`, `erts/lib_src/win/`,
  `erts/lib_src/common/{ethr_mutex.c,erl_printf_format.c}`,
  `erts/include/internal/`,
  `erts/emulator/beam/{erl_math.c,erl_bif_guard.c,big.c,utils.c,erl_db_hash.c,bif.c,external.c,sys.h,erl_threads.h}`,
  `erts/emulator/sys/unix/{sys_float.c,sys_time.c,erl_unix_sys.h,erl_unix_sys_ddll.c}`,
  `erts/emulator/sys/common/{erl_mmap.c,erl_sys_common_misc.c,erl_float_short.cpp}`,
  `erts/emulator/beam/jit/` and `jit/arm/`,
  `erts/emulator/asmjit/core/{jitallocator.cpp,osutils.h,osutils_p.h,virtmem.cpp,cpuinfo.cpp}`,
  `erts/emulator/zstd/zstd.mk`, `erts/emulator/Makefile.in`,
  `erts/configure.ac`, `lib/erl_interface/src/misc/ei_pthreads.c`.
* [M1] musl 1.2.6, pinned tree: `COPYRIGHT`,
  `arch/aarch64/{pthread_arch.h,syscall_arch.h,bits/float.h}`,
  `include/math.h`, `src/thread/aarch64/__set_thread_area.c`,
  `src/ldso/aarch64/tlsdesc.s`, `src/env/__init_tls.c`,
  `src/errno/__errno_location.c`, `src/string/aarch64/{memcpy.S,memset.S}`,
  `src/internal/floatscan.c`, `src/stdio/vfprintf.c`,
  `src/thread/pthread_create.c`.
* [M2] musl releases, https://musl.libc.org/releases.html (1.2.6, 2026-03-20);
  musl git, https://git.musl-libc.org/cgit/musl/ (master `7813e9119eb5`; commit
  `6426a515`, 2026-10-12,
  https://git.musl-libc.org/cgit/musl/commit/?id=6426a515).
* [M3] musl FAQ, https://www.musl-libc.org/faq.html ; musl wiki, "Mathematical
  library", https://wiki.musl-libc.org/mathematical-library
* [M4] Alpine `musl-dev` 1.2.6-r6 aarch64,
  https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64/musl-dev-1.2.6-r6.apk
* [M5] Docker official images, `library/erlang` (tag `29.1.2-alpine` with
  `arm64v8`, GitCommit `dcff99bf8e6d`),
  https://github.com/docker-library/official-images/blob/master/library/erlang
* [M6] Chimera Linux, https://chimera-linux.org/about/
* [M7] Fuchsia, "libc" (updated 2025-03-22),
  https://fuchsia.dev/fuchsia-src/development/languages/c-cpp/libc ; wasi-libc,
  https://github.com/WebAssembly/wasi-libc ; seL4 musllibc,
  https://github.com/seL4/musllibc
* [F1] FreeBSD releases, https://www.freebsd.org/releases/ ; tag release/15.1.0
  (`96841ea08dcf`, released 2026-06-16), https://cgit.freebsd.org/src/ :
  `sys/arm64/include/tls.h`, `lib/libc/gen/tls.c`,
  `lib/libc/aarch64/string/Makefile.inc`, `lib/libthr`, `lib/msun/man/math.3`,
  `contrib/gdtoa`, `lib/libgcc_eh/Makefile.inc`; 15.1-RELEASE arm64 `base.txz`,
  https://download.freebsd.org/releases/arm64/aarch64/15.1-RELEASE/base.txz ;
  libsys status report,
  https://www.freebsd.org/status/report-2024-01-2024-03/libsys/
* [P1] picolibc 1.8.12 (`2ae376c6cdf4`, released 2026-08-01; 1.8.11 released
  2026-01-27), https://github.com/picolibc/picolibc/releases/tag/1.8.12 :
  `README.md`, `COPYING.picolibc`, `doc/os.md`, `doc/tls.md`, `doc/locking.md`,
  `doc/printf.md`, `meson_options.txt`, `libos/`,
  `libc/machine/aarch64/{tls.c,*-stub.c,*.S}`,
  `picocrt/machine/aarch64/crt0.c`,
  `libc/stdio/{conv_flt.c,dtoa.h,vfprintf_float.c}`.
* [P2] Debian `picolibc-aarch64-linux-gnu` 1.8.10-2,
  https://deb.debian.org/debian/pool/main/p/picolibc/ ; Zephyr 3.5
  announcement, https://www.zephyrproject.org/introducing-zephyr-3-5/
* [A1] Arm Toolchain for Embedded 23.1.0 (released 2026-09-10; successor of the
  LLVM Embedded Toolchain for Arm),
  https://github.com/arm/arm-toolchain/releases/tag/release-23.1.0-ATfE ;
  picolibc pin `7971005` dated 2026-07-13; branch `release/arm-software/23.x`:
  `arm-software/embedded/README.md`, `docs/llvmlibc.md`, `versions.json`,
  `arm-multilib/json/multilib.json`, `variants/aarch64a*.json`,
  `arm-runtimes/CMakeLists.txt`.
* [L1] LLVM 23.1.4 (`7a941dfb2877`, released 2026-10-20),
  https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.4 ; main at
  `85bff8425ce2`.
* [L2] LLVM libc, https://libc.llvm.org/ , https://libc.llvm.org/porting.html ,
  https://libc.llvm.org/headers/math/index.html ; at `llvmorg-23.1.4`:
  `libc/config/baremetal/config.json`,
  `config/baremetal/aarch64/{entrypoints,headers}.txt`,
  `config/linux/aarch64/entrypoints.txt`, `src/math/generic/`,
  `src/__support/OSUtil/baremetal/{io.h,exit.cpp}`, `src/time/baremetal/`,
  `src/__support/freelist_heap.h`, `src/__support/threads/mutex.h`,
  `startup/linux/aarch64/tls.cpp`, `shared/math.h`,
  `docs/dev/printf_behavior.md`.
* [X1] libc++, libc++abi and libunwind at `llvmorg-23.1.4`:
  `libcxx/docs/index.rst`, `VendorDocumentation.rst`,
  `DesignDocs/ThreadingSupportAPI.rst`, `libcxx/CMakeLists.txt`,
  `libcxx/utils/ci/run-buildbot`, `cmake/caches/Generic-llvm-libc.cmake`,
  `runtimes/cmake/Modules/HandleLibC.cmake`,
  `libcxxabi/{CMakeLists.txt,src/cxa_guard_impl.h,src/cxa_exception_storage.cpp,src/abort_message.cpp}`,
  `libunwind/src/AddressSpace.hpp`.
* [X2] libcxxrt, master `a6f71cbc3a1e` (last commit 2025-02-25),
  https://github.com/libcxxrt/libcxxrt : `README`, `LICENSE`, `src/guard.cc`,
  `src/exception.cc`, `src/CMakeLists.txt`, `CMakeLists.txt`.
* [N1] newlib 4.6.0 (released 2026-01-23), https://sourceware.org/pub/newlib/
  (newlib-4.6.0.20260123); tag newlib-4.6.0 (`8ba4275b83ec`): `COPYING.NEWLIB`,
  `newlib/configure.ac`, `newlib/libc/include/reent.h`,
  `newlib/libc/machine/aarch64/`; libc++ issue #54594,
  https://github.com/llvm/llvm-project/issues/54594
* [B1] mlibc v7.0.0 (`7c2a17814262`, released 2026-08-02),
  https://github.com/managarm/mlibc/releases/tag/v7.0.0 : `LICENSE`,
  `meson.build`,
  `options/internal/include/mlibc/{all-sysdeps.hpp,strtofp.hpp}`,
  `options/internal/aarch64-include/mlibc/thread.hpp`; frigg `b0dbea66bc19`,
  `include/frg/formatting.hpp`; PR #1912 (opened 2026-10-01),
  https://github.com/managarm/mlibc/pull/1912 ; Motor OS,
  https://motor-os.org/c-cpp.html
* [R1] CORE-MATH, master `42b48ae76610` (`MIT`),
  https://core-math.gitlabpages.inria.fr/ ; Arm optimized-routines v26.07,
  https://github.com/ARM-software/optimized-routines
* [E1] Bionic (AOSP main): `README.md`, `docs/elf-tls.md`, `libc/NOTICE`,
  `libm/`, https://android.googlesource.com/platform/bionic ; Cosmopolitan
  v4.0.2 (2025-01-04), https://github.com/jart/cosmopolitan ; OpenBSD 8.0
  (2026-10-20), https://www.openbsd.org/ and
  https://man.openbsd.org/pinsyscalls.2 ; relibc,
  https://gitlab.redox-os.org/redox-os/relibc
* [E2] uClibc-ng, https://uclibc-ng.org/ and
  https://github.com/wbx-github/uclibc-ng ; dietlibc,
  https://www.fefe.de/dietlibc/ ; SPDX,
  https://spdx.org/licenses/LGPL-2.1-or-later.html ,
  https://spdx.org/licenses/SunPro.html , https://spdx.org/licenses/dtoa.html ,
  https://spdx.org/licenses/BSD-2-Clause-Views.html
* [C1] clang `-mtp=` option, `clang/include/clang/Options/Options.td` at
  `llvmorg-23.1.4`.
