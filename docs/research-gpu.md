# Research: GPU acceleration for erXos (OpenGL ES, Vulkan)

Point-in-time research record, 2026-11-15. Draft, not yet placed in the
tree.

* **Host:** Apple Silicon macOS (Darwin 27.0.0). QEMU 11.1.3 from Homebrew.
* **Sources:** Mesa 26.3.0 (commit `0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4`,
  tagged 2026-11-09), virtio 1.3 CSD01, Fuchsia and Genode documentation,
  LVGL v9.6.0 (the submodule pinned in `display/lvgl/ORIGIN.md`), Raspberry Pi
  and Broadcom public documents. Everything fetched is under
  `~/erxos-scratch/sources/gpu/`, and `SOURCES.txt` there lists the URL, date
  and SHA-256 of each file. The table at the end lists the files this record
  relies on.
* **Clean room:** no Linux, QEMU, U-Boot or other GPL/LGPL source was read.
  Every Mesa file read was checked for its license header first, and all were
  MIT. Mesa's `include/drm-uapi/sync_file.h` was fetched, found to be
  `GPL-1.0-or-later WITH Linux-syscall-note`, and deleted without being read.
  QEMU was used only through its user documentation page, patch cover letters
  on patchew (no patch bodies were read), and by running the installed binary
  to list its devices.
* **Marking:** a claim with no source read in this task is marked
  **unverified**.

## The question

The owner's note: "One note on GPU -- we should plan on having OpenGL/GPU
acceleration at some point. This is important for kiosk apps as well."

Today erXos draws everything on the CPU: libmemdraw, virtio-gpu 2D, and LVGL
for the kiosk. `docs/design-display.md` ("Graphics hardware") already names
three places hardware can attach: a **buffer source**, a **composition path**
and a **render service**. It already has rows for virtio-gpu with
virgl/venus and for the Pi's V3D. The UI survey
(`research-ui-rendering.md`) concluded that GPU work "does not fit erXos
today" because the Pi's GPU is reached only "through Mesa and a Linux kernel
driver". This record looks for the realistic path past that verdict.

## Summary

1. **The Linux kernel driver is not the obstacle it looks like.** For V3D,
   Mesa's client driver (all MIT) does almost everything: it compiles
   shaders, builds the binning and rendering command lists, allocates the
   tile memory, and lays out buffers. The kernel side does six things:
   creating and mapping buffers into the GPU's address space, submitting
   jobs (bin/render, TFU, compute, cache clean, CPU), waiting on sync
   objects, reading parameters, and performance monitors
   (`v3d_drm.h:33-46`). It does not parse the command lists. Isolation comes
   from V3D's own MMU, not from validating commands. Mesa's own simulator
   backend reimplements that kernel side in about 1,900 lines of MIT C
   against Broadcom's simulator (`v3d_simulator.c`, `v3dx_simulator.c`).
2. **The real obstacle is documentation.** "Broadcom never released a public
   specification for the V3D 3.x or 4.x series" (Mesa `docs/drivers/v3d.rst`).
   Mesa's MIT simulator code gives the register *names* and the order of
   writes for a submit, but not the register offsets, the MMU page-table
   format, reset, or power-up. Those are public only in Linux's GPL driver
   and in Broadcom's NDA specification. A V3D service for erXos needs a
   clean-room facts record made from the GPL driver by a separate agent, or
   the NDA specification.
3. **QEMU first is right, but not on stock Homebrew QEMU.** The installed
   QEMU 11.1.3 offers only `virtio-gpu-device` and `virtio-gpu-pci` (2D).
   GPU passthrough to a guest on an Apple Silicon host works today in UTM 5.0
   (released 2026-01-11: Venus Vulkan 1.3, and OpenGL 4.1 through Apple's
   CoreGL) and in libkrun/krunkit (Venus over MoltenVK). Upstream QEMU
   patches for Venus on macOS are posted, but whether they have been merged
   is unverified.
4. **Mesa can run as an ordinary user-mode library on erXos.** Genode (Intel,
   Vivante, Mali-400), Redox ("the Linux DRM API but fully in userspace") and
   Fuchsia (Magma) each run Mesa's client drivers over their own user-mode GPU
   servers. Two seams are available: libdrm's `drmIoctl`, which Genode and
   Redox emulate, and a narrower one Mesa already has for V3D, the single
   `v3d_ioctl()` wrapper the simulator build redirects.
5. **The cost lies outside the drivers.** Building Mesa needs Meson, Python 3
   and Mako (Mesa `docs/install.rst:19-43`). Mesa's OpenGL frontend carries a
   C++ GLSL compiler (about 54,000 lines of C++ in `src/compiler/glsl`). Both
   need the owner's agreement under the language rules. A Vulkan-only build
   avoids the C++, but LVGL needs OpenGL ES.
6. **What the kiosk gains is narrower than "GPU-drawn".** LVGL 9.6's OpenGL
   ES draw unit renders each draw task with the software renderer into an
   ARGB texture, caches it, and composes the textures on the GPU. The NanoVG
   draw unit draws vectors on the GPU. The 3D draw task needs OpenGL ES. The
   real gains are composition, transforms, opacity, blur and 3D at full frame
   rate on a 1080p panel. How much that buys on a Pi 4 or 5 is unmeasured.

## 1. QEMU `virt`: virtio-gpu with 3D

### The device side (virtio 1.3)

* Feature bits: `VIRTIO_GPU_F_VIRGL` (0), `F_EDID` (1), `F_RESOURCE_UUID`
  (2), `F_RESOURCE_BLOB` (3), and `F_CONTEXT_INIT` (4), which means
  "multiple context types and synchronization timelines" and requires
  VIRGL (virtio 1.3 section 5.7.3).
* There are ten 3D commands from `0x0200`: `CTX_CREATE`, `CTX_DESTROY`,
  `CTX_ATTACH_RESOURCE`, `CTX_DETACH_RESOURCE`, `RESOURCE_CREATE_3D`,
  `TRANSFER_TO_HOST_3D`, `TRANSFER_FROM_HOST_3D`, `SUBMIT_3D`,
  `RESOURCE_MAP_BLOB` and `RESOURCE_UNMAP_BLOB`, plus `GET_CAPSET_INFO`,
  `GET_CAPSET`, `RESOURCE_CREATE_BLOB` and `SET_SCANOUT_BLOB` among the
  base commands (section 5.7.6). `SUBMIT_3D` carries "an opaque command
  stream. The type of the command stream is determined when creating a
  context." The low 8 bits of `context_init` in `CTX_CREATE` name the
  capability set (capset).
* Capsets: `VIRGL` 1 and `VIRGL2` 2 (Gallium OpenGL), `GFXSTREAM` 3,
  `VENUS` 4 (Vulkan), `CROSS_DOMAIN` 5 (Wayland proxy). Mesa's
  `virtgpu_drm.h:166-171` adds `DRM` 6, the DRM native context.
* Fences: a request with `VIRTIO_GPU_FLAG_FENCE` is answered only when it
  completes. With `FLAG_INFO_RING_IDX`, `fence_id` is a sequence number on a
  timeline per (context, ring), and completing one answers every earlier
  fence on that timeline (section 5.7.6.7). This is the device's only
  synchronization primitive, and it is enough for the timeline semaphores
  Mesa uses.
* Blob resources live on the host. The guest sees them only through the
  device's "host visible" shared-memory region (`VIRTIO_GPU_SHM_ID_HOST_VISIBLE`),
  by mapping with `RESOURCE_MAP_BLOB` (cache type: none, cached, uncached or
  write-combined). "The virtio-gpu is based around the concept of resources
  private to the host" (section 5.7.5).
* The specification leaves the 3D commands' payload structs mostly
  undescribed. The BSD-licensed `virtio_gpu.h` that FreeBSD 14.1 carries
  (already in `sources/freebsd-14.1.0-virtio-gpu/`, SHA-256
  `fe2a9154...`) defines `virtio_gpu_resource_create_3d`,
  `virtio_gpu_transfer_host_3d` and `virtio_gpu_cmd_submit`, and the blob
  and context-init commands. FreeBSD's driver (`virtio_gpu.c`) is 2D only.

### The guest side: what Mesa needs

There are three ways to drive the device. Each is a Mesa driver over a small
winsys:

| Mode | Mesa driver | API to applications | Winsys calls (Mesa `virtgpu_drm.h`) |
| --- | --- | --- | --- |
| virgl | Gallium `virgl` (9,600 lines + 3,400 of winsys) | OpenGL ES / GL; needs Mesa's GL frontend and GLSL compiler | `GETPARAM`, `GET_CAPS`, `CONTEXT_INIT`, `RESOURCE_CREATE`, `RESOURCE_CREATE_BLOB`, `MAP`, `EXECBUFFER`, `TRANSFER_TO/FROM_HOST`, `WAIT` |
| Venus | `src/virtio/vulkan` (27,000 lines) | Vulkan | the same, and it needs `3D_FEATURES`, `CAPSET_QUERY_FIX`, `RESOURCE_BLOB`, `HOST_VISIBLE` and `CONTEXT_INIT` "unless vtest is used" (`docs/drivers/venus.rst`) |
| DRM native context | the native hardware driver (freedreno, amdgpu, i915, asahi, panfrost) over `src/virtio/vdrm` | whatever that driver offers | `drm_hw.h` messages inside `EXECBUFFER` |

Native context needs a matching host GPU (an Adreno for freedreno, and so
on), so it does not help on a Mac. The QEMU documentation lists native
contexts only for amdgpu, freedreno, i915, asahi and panfrost, and no V3D
context.

**vtest shows Mesa needs no kernel.** Mesa's virgl and Venus drivers each
have a second winsys, *vtest*: a UNIX-socket protocol to virglrenderer's test
server (`vtest_protocol.h`, version 4, 38 commands: resource create, submit,
blob create returning an mmap-able file descriptor passed with
`SCM_RIGHTS`, sync create/wait/signal, timeline waits). Native contexts have
the same alternative (`vdrm_vpipe.c`). A vtest-shaped transport over an
erXos channel to the domain that holds the device is therefore a near-copy
of code Mesa already ships. The guest-side changes are confined to one
winsys file per driver.

### The host side on Apple Silicon under HVF

* **Stock QEMU (Homebrew 11.1.3, checked on this host):** `-device help`
  lists `virtio-gpu-device` and `virtio-gpu-pci` only. `-display help` lists
  `none`, `curses`, `cocoa` and `dbus`. There is no `virtio-gpu-gl` and no
  GL display. **2D only.**
* **QEMU's own documentation** gives the 3D device lines:
  `-device virtio-gpu-gl` for virgl, `...,hostmem=8G,blob=true,venus=true`
  for Venus, and `drm_native_context=on`. Host requirements are listed only
  for Linux (virglrenderer 0.8.2+ for GL, 1.0.0+ for Venus).
* **Upstream work for macOS:** an RFC by Joelle van Dyne (UTM), 2025-12-03,
  "introduce Venus support for macOS", with "Metal texture scanout" and a
  check that a blob mapping is page-aligned. A series by Lucas Amaral (v5,
  2026-03-17), "enable Venus/Vulkan without OpenGL display", since "On
  macOS, no OpenGL display backend exists". Its cover letter adds
  `VIRTIO_GPU_F_BLOB_ALIGNMENT` (feature bit 5) because the HVF map granule
  can exceed the guest page size. **Whether either series is merged is
  unverified.**
* **UTM 5.0.0** (GitHub release, 2026-01-11): "Vulkan 1.3 is now supported
  on Linux guests with VirtIO Venus drivers in Mesa. OpenGL 4.1 is supported
  with the new Apple Core OpenGL backend". Known issue: "Apple CoreGL backend
  does not support Vulkan".
* **libkrun/krunkit** (Apache-2.0, Rust, macOS 14+): a Venus-capable
  virtio-gpu over Hypervisor.framework, with MoltenVK as the host Vulkan
  ("deviceName = Virtio-GPU Venus (Apple M1)", sinrega.org, 2024-03-06). It
  boots EFI guests. Whether it can boot erXos images is unverified.

**What erXos would need on the host:** a QEMU built with virglrenderer and
either MoltenVK (for Venus) or a GL path (ANGLE or CoreGL, for virgl). The
options are UTM's QEMU binary, or our own out-of-tree build of QEMU,
virglrenderer and MoltenVK from pinned sources. Both are tools, run as
subprocesses, so QEMU's GPL does not reach the tree. Whether UTM's bundled
QEMU can be run headless by `tools/erx`'s harness is unverified.

**The page-size trap:** HVF maps host memory into the guest in 16 KiB units.
A guest that uses 4 KiB pages needs blob mappings aligned to 16 KiB, which is
why the alignment feature bit is being added. erXos's page size on QEMU
should be checked against this before a design commits to blob mappings.

## 2. Raspberry Pi 4 (V3D 4.2) and Pi 5 (V3D 7.1)

### What Mesa supports

`docs/drivers/v3d.rst`: "a conformant GLES3.1 driver called V3D and a Vulkan
graphics driver called V3DV, notably used on the Raspberry Pi 4 and
Raspberry Pi 5". Support for 3.3 and 4.1 was dropped when 7.1 landed.
`v3dv_device.c:87` sets the Vulkan API version to 1.3. The Gallium driver
reports GLSL feature level 330 (`v3d_screen.c:307`). On Linux, display goes
through the separate `vc4` KMS driver, with Mesa's "kmsro" helpers sharing
buffers between the two. erXos needs none of that: its display is its own
(the firmware framebuffer today, the HVS later).

### The kernel interface Mesa uses (`v3d_drm.h`, MIT)

| Call | What it does | Notes |
| --- | --- | --- |
| `CREATE_BO` | allocates `size` bytes and returns a handle and a 32-bit `offset` "in the V3D address space ... private to the DRM fd", never 0 | the kernel allocates and maps into the GPU MMU |
| `MMAP_BO` | returns an offset to `mmap` the BO through the device node | CPU mapping |
| `GET_BO_OFFSET` | the GPU address of an imported BO | |
| `WAIT_BO` | waits for the last job using a BO, with a timeout | implicit sync |
| `SUBMIT_CL` | `bcl_start/end`, `rcl_start/end` (GPU addresses), `qma/qms/qts` (tile allocation memory and tile state), a list of BO handles, `in_sync_bcl`, `in_sync_rcl`, `out_sync`, `perfmon_id`, extensions | "This BCL will block on any previous BCL submitted on the same FD"; the render list waits on its own bin list |
| `SUBMIT_TFU` | raw texture-format-unit register values (`icfg`, `iia`, `iis`, `ica`, `iua`, `ioa`, `ios`, `coef[4]`, and `v71.ioc`), 4 BO handles, in/out sync | the client fills the registers |
| `SUBMIT_CSD` | raw compute dispatch `cfg[7]`, `coef[4]`, BOs, sync | the same |
| `SUBMIT_CPU` | indirect compute, timestamp and performance queries done by the kernel between jobs | a Vulkan convenience |
| `PERFMON_*` | create, destroy, read and describe counters; up to 32 | optional |
| `GET_PARAM` | hub and core identity registers, and feature flags (TFU, CSD, cache flush, perfmon, multisync, CPU queue, super pages, reset counters) | `v3d_noop.c:47-65` gives the identity values of a 4.2 and a 7.1 |

The generic DRM calls Mesa's v3d and v3dv also make, counted across the
fetched files: `GEM_CLOSE`, `GEM_OPEN`/`FLINK`, PRIME import and export
(sharing buffers as file descriptors), and syncobj create, destroy, wait,
signal, reset, and import or export as a sync file. The queues are
`V3D_BIN`, `V3D_RENDER`, `V3D_TFU`, `V3D_CSD`, `V3D_CACHE_CLEAN` and
`V3D_CPU`. Synchronization uses syncobjs, with a multi-sync extension for
many waits and signals per job.

### What the kernel side does, from Mesa's simulator (MIT)

`v3d_simulator.c` "emulate[s] the V3D ioctls' behavior in the kernel on top
of the simpenrose software simulator". `v3dx_simulator.c` shows the hardware
sequence:

* **Submit (`simulator_submit_cl_ioctl`):** reload the per-client memory
  protection (GMP) table, invalidate the caches, write `CT0QMA/CT0QMS`
  (tile allocation), `CT0QTS`, then `CT0QBA/CT0QEA` (bin list start/end).
  Wait for the bin-flush counter `BFC` to advance, invalidate the caches
  again, write `CT1QBA/CT1QEA` (render list), and wait for `RFC`. "The
  kernel's scheduler implements this using the GPU scheduler blocking on the
  bin fence completing."
* **Interrupts (`simulator_init_regs`):** per core, `OUTOMEM` (the binner ran
  out of tile memory and the kernel must supply more) and on 4.2 `GMPV` (a
  protection violation). On the hub: MMU write violation, page-table entry
  invalid, MMU capability exceeded, and TFU done (and `GMPV` on 7.1).
* **Caches:** L2C, L2T, L1TD and slice invalidation and flush sequences, and
  a TFU and CSD submit, each a few register writes.
* **GMP:** a per-client bitmap of 2-bit access flags per granule
  (`set_gmp_flags`). The simulator gives each DRM file its own region. How
  Linux's driver uses GMP and the MMU between clients is unverified.

The register **offsets** come from Broadcom's simulator headers
(`libs/core/v3d/registers/4.2.14.0/v3d.h`, `7.1.7.0`), which are not public.

### Public documentation

* Mesa: "Broadcom never released a public specification for the V3D 3.x or
  4.x series ... Developers with NDA access with Broadcom or Raspberry Pi can
  get access to the V3D architecture specification". The public VideoCore IV
  3D Architecture Reference Guide (2013, fetched) covers the Pi 1-3's VC4,
  not V3D 4.2 or 7.1.
* `src/broadcom/cle/v3d_packet.xml` (1,735 lines, MIT) describes every
  control-list packet, shader record and state for V3D 4.2 and 7.1. Together
  with the Mesa compiler (the QPU instruction set in `src/broadcom/qpu`), it
  is the public programming model for the *client* side, and it is complete
  enough to have earned conformance.
* The BCM2711 peripherals datasheet: "There are a number of peripherals which
  are intended to be controlled by the GPU. These are omitted from this
  datasheet." V3D appears only as VideoCore interrupt 26 and the HVS as 49.
  No BCM2712 peripherals datasheet was found at the expected URL (404).
* The firmware mailbox property interface (Raspberry Pi firmware wiki)
  documents a clock ID `0x5: V3D`, with get, set and max-rate tags, and
  "Set power state" for the listed devices. A V3D power domain is not in
  its device list. **How V3D is powered on and clocked on the Pi 4 and 5 is
  unverified.**

### Thin shim versus policy

The work splits cleanly along erXos's driver rule (Erlang driver over a
device shim):

* **Device shim (C, parses nothing):** register reads and writes for a job
  start (about ten writes), the interrupt status and acknowledge, cache
  flush sequences, reset, and writing page-table entries in bulk into the
  page-table memory the domain owns.
* **Erlang driver (policy):** one queue per V3D queue, ordering bin before
  render, fences and their timelines, job timeouts and GPU reset, `OUTOMEM`
  handling from a pool, the per-client address space (which BO is at which
  GPU address), import of buffers other domains share, performance counters,
  and scheduling between clients.
* **Client (Mesa, in the client's own session):** everything else:
  compiling shaders, building control lists, tile memory sizing, texture
  layout, TFU and CSD register values.

No command list has to be validated, because V3D 4.2 and 7.1 have an MMU
(the `MMU_PTI`, `MMU_WRV` and `MMU_CAP` interrupts) and every address in a
control list is a GPU virtual address. This is what makes V3D a good fit for
a small service. VC4 on the Pi 1-3 had no MMU, and its kernel validated every
command (not checked here).

### VideoCore firmware, the HVS and V3D

* The **HVS** is the plane compositor that scans out. Today the firmware
  owns it, and erXos uses the firmware framebuffer. `design-display.md`
  already has an HVS row: planes from contiguous memory at bus addresses,
  with its holder in the trusted base because no IOMMU stands before it.
* **V3D renders into memory.** A V3D-rendered buffer reaches the screen by
  copy (the display's copy path) or, once the HVS is driven, as a plane. The
  HVS needs physically contiguous memory at a bus address; V3D, through its
  MMU, does not. A buffer meant to be scanned out directly must be allocated
  contiguous from the start.
* The **firmware** sets V3D's clock (and probably its power; unverified) and
  shares the GPU's L2 cache arrangement ("BCM2711 provides a 1MB system L2
  cache, which is used primarily by the GPU", datasheet). Nothing else of
  V3D runs through the firmware.

### DMA, IOMMU and trust

* Pi 4: `design-platforms.md` (lines 608-616) says "No IOMMU is described for
  the Pi 4", and every DMA device is unconfined. V3D's MMU confines what
  *jobs* reach, but whoever programs the MMU's page-table base reaches all of
  memory. **The domain that holds V3D is in the trusted base**, as the HVS
  holder is.
* Pi 5: "the Pi 5's tree assigns its IOMMUs to neither RP1 nor the SD
  controllers". **Whether one sits before V3D 7.1 is unverified** (the
  device tree is GPL source and was not read).
* Isolation between clients rests on the V3D MMU. Either the service keeps
  one page table per client and switches the table base between jobs (jobs
  are serialized per queue anyway), or all clients share one table with
  disjoint ranges, which isolates nothing against a hostile client.
  Fuchsia's Magma requires the first: "Client connections are isolated from
  one another through independent hardware address spaces" (RFC-0198).
  Whether V3D's TLB flush on a table switch is cheap enough is unverified.

## 3. How other non-Linux systems did it

| System | Split | What they had to build | GPUs |
| --- | --- | --- | --- |
| **Fuchsia (Magma)** | a client driver (ICD) in the application, and a *Magma system driver* (MSD) in a user-mode driver host ("analogous to a kernel driver on other operating systems") | the MSD per GPU, written fresh or ported; the generic `magma_system` layer (driver setup, IPC, some validation); a client library at Mesa's winsys. "The Magma system driver must be open source but not GPL" | "four supported Magma drivers (three in production)" (RFC-0198); the porting guide cites `msd-intel-gen` and `msd-arm-mali` (Mali through a SoC driver `aml-gpu`) |
| **Genode** | Mesa linked into the application; a GPU server component per GPU behind the *Gpu session* (introduced in 2017 for Intel) | a custom Intel GPU multiplexer of their own; Linux's etnaviv (Vivante, i.MX8, 21.11) and Lima (Mali-400, PinePhone, 22.08) ported as user-mode components; a libdrm back end that marshals ioctls into packet-stream packets (deep copy of the submit arrays); Mesa updated to 24.0.1 (24.05) | Intel Gen8-12, Vivante, Mali-400. **No V3D** in any release note checked (21.08-25.08) |
| **Redox** | user-mode drivers in Rust; "the Linux DRM API but fully in userspace" (Redox book) | Mesa with a Redox back end for llvmpipe and lavapipe; a start on Intel modesetting (`ihdgd`). "As we don't support 2D/3D hardware acceleration yet" | none accelerated |
| **Haiku** | Mesa on top of Haiku's own EGL driver (`src/egl/drivers/haiku` in Mesa) | an NVIDIA driver ported from NVIDIA's open kernel modules, needing the GSP firmware (alpha, 2026-01-01, OSNews; Hackaday 2026-07-12). AMD and Intel are modesetting only (an OSNews comment, not authoritative) | NVIDIA Turing and later |
| **QNX** | Screen (a compositor server) with plug-in modules for display, 2D and 3D; vendor OpenGL ES and EGL behind Screen's `libEGL` | integration only: "hardware vendors have their own implementation of the Khronos standards" (QNX 8.0 docs); for guests, a virtio-gpu virtual device on the host | vendor-supplied |

The lessons that carry over:

1. **Everyone keeps Mesa's client driver unchanged and replaces the bottom
   layer.** Genode and Redox emulate the DRM ioctls. Fuchsia defined Magma
   and put a small client library under Mesa. Genode found its first
   interface, "modeled after the perceived requirements of the Linux i915 DRM
   back end", too Intel-shaped, and reworked it twice (21.11, 23.02). In
   23.02 it moved buffer handling into the client and kept only "video
   memory" in the server, because Mesa "allocates and frees a lot of small
   GPU buffer objects".
2. **Client-side allocation wins.** Magma's buffers are allocated by the
   client and imported ("in Magma, it's the ICD that allocates and maps
   memory, not the MSD"). The client also manages GPU addresses, so the
   server never patches command buffers. This matches erXos's budgets: what a
   client draws with is charged to the client.
3. **Feed-forward IPC.** Magma's primary channel is asynchronous, with flow
   control by published maximums and a separate notification channel for
   completions. On an error the connection closes, and the client reports
   "device lost". That is erXos's restart-over-recovery rule.
4. **Porting a Linux kernel driver was the fast route for Genode** (Lima in
   "merely two weeks"), using their Linux driver environment. erXos's rules
   rule that out for GPL drivers: clean room only.

## 4. Mesa as a user-mode library on erXos

### What Mesa needs from the OS

* POSIX threads, `mmap` of BOs (through the device node in Linux), and file
  descriptors as handles for shared buffers (PRIME) and fences (sync files).
  Waits on fence file descriptors use `poll`.
* libdrm (MIT) for `drmIoctl`, syncobj helpers and `drmGetVersion`. The
  fetched v3d and v3dv files use only the calls listed in section 2.
* A loader and EGL platform. Mesa's EGL has `dri2` (DRM, GBM, Wayland, X11,
  **surfaceless**, device), `haiku` and `wgl` drivers. Surfaceless (EGL
  pbuffers and FBOs, with `EGL_PLATFORM_SURFACELESS_MESA`) needs no window
  system. LVGL 9.6's `lv_opengles_pbuffer.c:85` uses exactly that.
* No LLVM for v3d, v3dv, virgl or Venus. llvmpipe and lavapipe need LLVM and
  a JIT, which only images marked for JIT may run on erXos.
* A build with Meson, Python 3.10+ and Mako (`docs/install.rst:19-43`).

### Sizes (line counts of Mesa 26.3.0's tarball, by `tools/gpu_loc.rb`)

| Part | C | C++ | Python (build) |
| --- | --- | --- | --- |
| `src/broadcom` (v3d compiler, QPU, CLE, v3dv, common) | 74,000 incl. headers | 600 | 860 |
| `src/gallium/drivers/v3d` | 16,200 | 0 | 0 |
| `src/gallium/drivers/virgl` + winsys | 14,000 | 400 | 0 |
| `src/virtio/vulkan` (Venus) | 27,200 | 0 | 60 |
| `src/compiler` (NIR, GLSL, SPIR-V and more) | 209,000 | 75,700 (GLSL 53,600) | 19,300 |
| `src/mesa` (GL state tracker) | 214,000 | 6,700 | 10,800 |
| `src/gallium/auxiliary` (partly used) | 181,500 | 5,400 | 1,200 |
| `src/util` | 86,900 | 13,500 | 5,000 |
| `src/vulkan` (runtime and WSI) | 84,000 | 5,500 | 6,100 |
| `src/egl` | 24,400 | 500 | 600 |
| All of `src/` | 3.2 M | 0.8 M | 0.12 M |

These are upper bounds by directory. A GLES build for V3D or virgl uses
roughly 0.6-0.8 M lines. A Vulkan-only v3dv or Venus build uses roughly
0.4 M, with little C++. These are estimates; the exact numbers come from a
build.

### Licenses (checked by SPDX and header text)

* Every Mesa file read for this record is MIT. Mesa's `licenses/` directory
  lists Apache-2.0, BSL-1.0, GPL-1.0-or-later, GPL-2.0-only, MIT and
  SGI-B-2.0. Searching the tarball for GPL or LGPL SPDX tags found them only
  in `svga` (VMware) headers, `freedreno/vulkan/msm_kgsl.h`, and the Linux
  uAPI headers `sync_file.h`, `dma-buf.h`, `etnaviv_drm.h`, `lima_drm.h`,
  `pvr_drm.h`, `rknpu_ioctl.h` and `d3dkmthk.h`, all with the syscall note.
  Of these, the v3d, virgl and Venus paths reach `sync_file.h` through
  `src/util/libsync.h` and `src/virtio/vulkan/vn_renderer_internal.c`. An
  erXos port replaces sync files, so those includes go away. No Apache-2.0
  SPDX tags were found in the broadcom, v3d, compiler, util, vulkan, egl,
  mesa or drm-uapi paths.
* virglrenderer (host side, a tool): MIT (`COPYING`).
* LVGL: MIT. Its bundled NanoVG: zlib-style ("Permission is granted to
  anyone to use this software for any purpose").
* MoltenVK (Apache-2.0) and ANGLE (BSD) appear only on the host, as tools.
  These licenses are not verified here.

### A Magma-like erXos interface

Can a narrow erXos GPU protocol let Mesa's v3d and virgl drivers run
unmodified or nearly so? **Yes, with one winsys file each:**

* **V3D:** every kernel call in the gallium and Vulkan drivers goes through
  `v3d_ioctl(fd, request, arg)`, which the simulator build points at
  `v3d_simulator_ioctl` (`v3d_simulator.h`; `v3d_bufmgr.c:154`,
  `v3dv_bo.c:278`). An erXos build points it at a client library that turns
  each request into a message to the GPU service. CPU mapping (`mmap` of
  `MMAP_BO`'s offset, `v3dv_bo.c:352`) and the syncobj helpers need small
  changes, or an erXos `libdrm` that offers them.
* **virgl and Venus:** the vtest winsys already speaks a socket protocol with
  file-descriptor passing. An erXos vtest-like transport replaces the
  socket.

The protocol should be erXos's own and Magma-shaped, not the Linux uAPI
structs. That follows the seam rule ("a stopgap never leaks its own data
model or ABI"), and Genode's experience points the same way:

| Operation | Meaning | V3D payload | virtio payload |
| --- | --- | --- | --- |
| query | device identity and features | `GET_PARAM` values | capsets |
| connect | one connection per client; its own GPU address space | a page table | a virtio context |
| import buffer | a memory object of the client's pixel area or budget, by capability | map at a GPU address | blob or resource |
| execute | vendor bytes, the buffers they use, wait and signal fences | `SUBMIT_CL`/`TFU`/`CSD` fields | `SUBMIT_3D` stream |
| fence | a timeline value per connection; wait, signal, export to another domain | syncobj | ring fence |
| notify | completion, fault, reset, "device lost" | interrupt | fence response |

Buffers are allocated by the client from its own budget. Fences are
timeline points, not file descriptors.

## 5. The kiosk and LVGL

LVGL v9.6.0 (in tree, MIT) has three GPU paths, all OpenGL ES:

* **OpenGL ES draw unit** (`src/draw/opengles/lv_draw_opengles.c`,
  `LV_USE_DRAW_OPENGLES`): for each task (fill, border, box shadow, label,
  arc, line, triangle, image) `draw_to_texture` renders it *with the
  software renderer* into an ARGB8888 buffer, uploads it as a texture, and
  caches it keyed by the draw descriptor. Composition, blending and layers
  run on the GPU. Canvas rendering is not supported ("not a texture").
* **NanoVG draw unit** (`src/draw/nanovg`, GLES2 or GLES3 back end; it
  cannot be combined with the GLES unit): fills, strokes, gradients, arcs,
  box shadows, blur and vector paths drawn by the GPU, with image and FBO
  caches.
* **3D** (`lv_draw_3d`, `lv_draw_nanovg_3d.c`): a draw task type that only the
  GL units implement.
* **Drivers:** `lv_opengles_egl.c`, `lv_opengles_glfw.c`, and
  `lv_opengles_pbuffer.c`, which uses EGL surfaceless pbuffers and
  `lv_opengles_pbuffer_read_to_draw_buf` reads the result back into an LVGL
  draw buffer. On Linux, `src/drivers/display/drm/lv_linux_drm_egl.c`.

**What the kiosk gains:**

* Full-screen composition, scaling, rotation, opacity and blur at panel rate
  without spending CPU. Software blur and large transformed images are where
  CPU renderers fall over at 1080p.
* GPU vector drawing (NanoVG) for charts and dashboards.
* 3D content, impossible today.
* Animation of cached content becomes cheap.

What it does not gain: text and the first drawing of widgets still go
through the software renderer in the GLES unit. **How much any of this buys
on a Pi 4 or 5 is unmeasured.** Following the "cheap hacks first" rule, the
first step is a profile of the kiosk on the board, to see whether
composition or rasterization dominates.

The first erXos integration is the pbuffer path: render on the GPU, then
present. Reading back to the CPU defeats the purpose on a Pi; the target is
rendering straight into the window's buffer, through an EGL image over a
buffer imported from the pixel area.

## 6. The seam with the display

`design-display.md` already fixes the frame: "A device that draws is held by
one domain ... serves drawing into buffers ... The client's renderer builds
the device's commands; the serving domain checks and submits them. The
display is no party to it: what it is presented is a buffer." This research
adds the following.

1. **Buffer ownership.** The render target is a buffer in the client's
   pixel area. The client imports that memory object into its GPU
   connection, and the GPU domain maps it into the client's GPU address
   space. The display maps the same object read-only, as today. This needs
   the system domain to give the GPU domain access to a pixel area that
   belongs to the client's connection with the display. The display design
   already lists this as open ("how the system domain installs a pixel area
   in a third domain"). On the Pi it also needs the pages' bus addresses for
   V3D's page table, a kernel interface question (`design-kernel.md`,
   "Resources, DMA windows and consoles"; not checked here for unconfined
   devices).
2. **Fences before composition.** The simplest correct start needs no new
   mechanism: the client waits for its job's completion fence before it
   sends `present`, so the display never reads a buffer the GPU is writing.
   It costs one GPU-to-client wakeup per frame. An *acquire fence* carried
   in `present` (Wayland's explicit sync, recorded in
   `research-ui-compositors.md`) is a later optimization that needs its own
   design.
3. **Release.** The display's answer to `present` already releases the
   buffer. Nothing new is needed for GPU-filled buffers. Double buffering
   stays the client's business.
4. **Sharing between domains.** Exporting a buffer is the capability to its
   memory object, which erXos already has. Nothing like dma-buf is needed
   beyond what memory objects give. Exporting a *fence* to another domain (a
   GPU timeline point the display would wait on) is new and belongs to the
   acquire-fence design, not to the first stage.
5. **Memory accounting.** BOs come from the client's budget (Magma's
   client-side allocation). The GPU domain's own costs for each client (its
   page table, the `OUTOMEM` binner overflow pool, perfmon state) come from
   the service's grant for that client's lane, as `CLAUDE.md`'s rule for
   services requires. A client cannot make the GPU domain allocate without
   bound.
6. **Device resources on QEMU.** The display domain holds the one
   virtio-gpu, so it is also the render relay. GPU-rendered virgl and Venus
   resources live on the host, and the CPU cannot read them unless they are
   blob-mapped. The display's composition path for them is the device (a
   host context draws each shown window's resource) or `SET_SCANOUT` to one
   resource. A **kiosk under the single policy is the easy case:** one
   full-screen window, scanned out directly, with no composition at all.
7. **Faults.** A GPU fault or timeout ends the client's connection
   ("device lost"). A hang that reset cannot clear restarts the GPU domain.
   Shader code is GPU code in BOs, executed only through the V3D MMU. It
   touches none of erXos's rules about CPU code (no mapping writable and
   executable, JIT only in images marked for it). This should be stated in
   the design.

## Staged path

Each stage lands something usable. Sizes count erXos-authored code and are
estimates.

| Stage | What | erXos code | Takes on | Licenses |
| --- | --- | --- | --- | --- |
| G0 | Owner decisions (below); `docs/design-gpu.md`: the render-service protocol (section 4), fences, buffer import, accounting; drift check against `design-display.md` | design only | none | none |
| G1 | QEMU host tooling: a pinned out-of-tree build of QEMU, virglrenderer and MoltenVK (or ANGLE), or UTM's QEMU; a harness switch for `virtio-gpu-gl` | about 200 lines of Ruby | QEMU (GPL, tool), virglrenderer (MIT, tool), MoltenVK (Apache-2.0, tool) | tools only |
| G2 | Mesa in erXos: imported as a fork submodule (as LVGL is) or into the tree; built for the target with musl; EGL surfaceless; the virgl driver over an erXos vtest-like transport; virtio-gpu 3D commands and fence timelines in the display domain's Erlang driver; fuzz targets for the new virtio responses | 3,000-5,000 lines (C client transport and EGL glue 1,500-2,500; Erlang 1,000-2,000) | Mesa virgl + GL frontend + GLSL + NIR + util (about 0.6-0.8 M lines, including about 75,000 of C++) | MIT (check per file), Meson/Python at build time |
| G3 | Kiosk on QEMU: LVGL's GLES or NanoVG unit through the pbuffer driver; a single-policy kiosk scanned out from one resource; before and after numbers | a few hundred lines | none new | MIT, zlib |
| G4 | V3D facts record: clean room from Linux's GPL driver by a separate agent (registers, MMU page-table format, interrupts, reset, power and clock through the firmware), checked against Mesa's MIT simulator sequence | a record | none | (clean room) |
| G5 | Pi 4 V3D: a GPU domain with an Erlang driver over a device shim (section 2); the erXos client library at Mesa's `v3d_ioctl` seam; the gallium v3d driver; GLES 3.1 for the kiosk; copy-path presentation | Erlang 2,000-3,000; shim C 500-1,000; client C 1,000-2,000 | Mesa v3d + broadcom (about 90,000 lines more) | MIT |
| G6 | Pi 5 V3D 7.1 (`v3d71` paths; the IOMMU question); v3dv Vulkan; direct scanout of V3D buffers as HVS planes (with the HVS design) | modest over G5 | v3dv, Vulkan runtime | MIT |
| later | an acquire fence in `present`; GPU composition in the display domain itself; Venus and Vulkan on QEMU | | | |

**Why QEMU first:** G2-G3 build and test the whole render-service protocol,
the Mesa port and the LVGL integration without the documentation risk, and
the same protocol then carries V3D. The catch is that the host side on a Mac
(G1) is still young, so G1 should start with a probe: boot a Linux guest
with Mesa's virgl on the chosen QEMU build under HVF, before any erXos code.
That probe is also the oracle for G2.

**The cheap alternative to G2 if host GL on the Mac stalls:** skip virgl and
run Venus (Vulkan) alone. That avoids Mesa's GL frontend and its C++, but
the kiosk then needs GL on Vulkan (Mesa's Zink, which brings the GL
frontend back) or LVGL GPU paths that do not exist. So it is a fallback, not
a plan.

## Risks

* **V3D documentation (high).** No public specification. The clean-room
  record from a GPL driver costs time and needs the owner's sign-off. NDA
  access is the alternative.
* **Owning Mesa (high).** "Code erXos modifies or ships enters the tree as
  erXos's code." Hundreds of thousands of lines, fast upstream movement, and
  security fixes to carry. A fork submodule (as LVGL) keeps upstream merges
  possible.
* **Build-tool and language rules (high, policy).** Meson and Python with
  Mako at build time, and C++ in the GLSL compiler, both conflict with
  `CLAUDE.md` as written unless approved as inherited build machinery and
  inherited code.
* **The Mac host stack (medium).** Venus and GL on macOS hosts are out of
  tree or recent (UTM 5.0, Jan 2026; QEMU patches unmerged or unverified).
  HVF's 16 KiB granule against the guest's page size affects blob mappings.
* **Trust (medium).** The V3D holder is in the Pi 4's trusted base, since
  the device is unconfined. Isolation between clients depends on giving each
  connection its own V3D page table. On QEMU, isolation between guest
  contexts is virglrenderer's job on the host (acceptable for a development
  host).
* **Benefit unmeasured (medium).** The kiosk's gain on a Pi is unknown until
  profiled. The GLES draw unit still rasterizes on the CPU.
* **Power and clock (low to medium).** V3D's power-up through the firmware
  is undocumented in the mailbox wiki.

## Open questions for the owner

1. **Mesa's build:** may Mesa keep Meson, Python 3 and Mako as inherited
   build machinery behind erXos's top-level build (as OTP keeps Perl and
   autoconf)? Python is otherwise allowed only for the Bumble test peer.
2. **Mesa's C++:** may Mesa's GL frontend and GLSL compiler (about 54,000
   lines of C++) enter as inherited code, as asmjit did? Without it there is
   no OpenGL ES.
3. **Placement:** Mesa as a fork submodule (as LVGL), or imported into the
   tree with an `ORIGIN.md`?
4. **Clean room for V3D:** approve a facts record of Linux's v3d driver
   (registers, MMU, reset, power) made by a separate agent? Or is NDA access
   to Broadcom's V3D specification possible?
5. **QEMU host:** build our own QEMU, virglrenderer and MoltenVK (or ANGLE)
   from pinned sources, or depend on UTM's binary?
6. **API target:** OpenGL ES 3.1 for the kiosk first (virgl, then v3d), or
   Vulkan first (Venus, then v3dv)?
7. **Which domain holds V3D,** and is one page table per client required
   from the first V3D stage? Magma requires it; Linux's arrangement is
   unverified here.

Advisors (two-advisor rule) have not been consulted on any of this; the
choices above are inputs for them.

## Sources

Full list with SHA-256: `~/erxos-scratch/sources/gpu/SOURCES.txt`. Mesa
files are at commit `0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4` (tag
mesa-26.3.0). All were fetched 2026-11-15 over HTTPS.

| File | URL | SHA-256 |
| --- | --- | --- |
| `mesa/v3d_drm.h` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/include/drm-uapi/v3d_drm.h | 4e02a6af8c7c585d8a3f9e04abe8fa5af3723f3d7ef0415c240329303005774d |
| `mesa/virtgpu_drm.h` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/include/drm-uapi/virtgpu_drm.h | c98308e9f015388d7218fab64f1f1bbef53a27a450ef178ec21be19e6cafa0fa |
| `mesa/v3d_bufmgr.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/gallium/drivers/v3d/v3d_bufmgr.c | c25752cd1749a20a6c43bbad7fe234ea62d94cfb0e2a9a2955361ba98aaca806 |
| `mesa/v3d_screen.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/gallium/drivers/v3d/v3d_screen.c | e450a2e1efdf7e2732d0bcec2b13d8877523fba3370a177b94aeff90df02667a |
| `mesa/v3d_simulator.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/broadcom/simulator/v3d_simulator.c | 178ee40e1762746bf1aa7b530a3a85651fbf0b59deeec7b1267cf4218e9e86cf |
| `mesa/v3d_noop.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/broadcom/drm-shim/v3d_noop.c | 8c35aaec44efa9c72aac19f1697116d37138172d808825efd56beb221a6e5683 |
| `mesa/v3dv_queue.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/broadcom/vulkan/v3dv_queue.c | aa589b32b1e27a1be0be549fef1e2f127f96f63f1fc5d3804d3b0eb966ac8ef5 |
| `mesa/v3dv_bo.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/broadcom/vulkan/v3dv_bo.c | 470afe13e6ae9ccb884edb3cf2a689f6055f2c4117527ba93e0cec014a0d22e7 |
| `mesa/vtest_protocol.h` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/virtio/vtest/vtest_protocol.h | d1f83473cd0c6c79ab6f17fe04b7ac4540b6a26f52a710bd5d7f763d632d9fa7 |
| `mesa/vdrm_vpipe.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/virtio/vdrm/vdrm_vpipe.c | a64d3f84998bf2e8fce1267f415faf6306df7b827ba6c890e67a1f5918f2bc40 |
| `mesa/virgl_vtest_socket.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/gallium/winsys/virgl/vtest/virgl_vtest_socket.c | 012fbc69a5078cee72a1a823930df458631239778206c791acb1e1aedecdeb3b |
| `mesa/docs-v3d.rst` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/docs/drivers/v3d.rst | 7dbeb249c37fc7b71bd84f3d4e31c9f397a1f43fc33b2d15f51f79dcd72e2ec0 |
| `mesa/docs-venus.rst` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/docs/drivers/venus.rst | 96624f69f329ab8e18871e9dffffd4f6c06c39979e2be90b3802f9ebb0913f23 |
| `mesa/v3dx_simulator.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/broadcom/simulator/v3dx_simulator.c | 826d28f4e12bacebd14095fa20da2f3c8675342c41ae8d62110b9bccbb5a1561 |
| `web/fuchsia-magma-design.html` | https://fuchsia.dev/fuchsia-src/concepts/graphics/magma/design | 52e18e21056f819756f6941db6a123dfffff7a7885203505c9cd7bf3c48b0a5a |
| `web/fuchsia-rfc0198-magma-api.html` | https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0198_magma_api_design | da8b35f56fd67d72e21749e6b36230b5396a4cddb0e930d08f0885484a6b5550 |
| `web/fuchsia-magma-porting.html` | https://fuchsia.dev/fuchsia-src/development/graphics/magma/concepts/porting | 338d62fc71ce4b37f2aaf9ff0aba6ebbb857f726e05313ba86ff1a90502d97c1 |
| `web/qemu-virtio-gpu-doc.html` | https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html | c7f658f0c273ed74120cb888d90bce2d714f20f9f9e90090690ed130bc1a6578 |
| `web/patchew-venus-macos-rfc.html` | https://patchew.org/QEMU/20251203040754.94487-1-j@getutm.app | 9981f4d4118794329152863b167022a17b9dfc3e33f5b0bb1cd714d7a292df6a |
| `web/patchew-venus-without-gl-v2.html` | https://patchew.org/QEMU/20260311022752.64192-1-lucaaamaral@gmail.com | 37326852dfa5f7b9573b94628e41c441b90a20bdff7533bf78fccc31b1405bd8 |
| `web/genodians-etnaviv-gpu-session.html` | https://genodians.org/jws/2021-09-03-experimental-etnaviv-gpu-session | 0dede31ccf83626c757e6a3a1f11a10846b3a98f2cafeb2581558109cb06c3e2 |
| `web/krunkit-README.md` | https://raw.githubusercontent.com/containers/krunkit/main/README.md | 07d07064189e9a0e3215f6dc93368da211f4c501a8870f1cd7d04e1f49e3078f |
| `web/sinrega-containers-gpu-macos.html` | https://sinrega.org/2024-03-06-enabling-containers-gpu-macos/ | aa26ddbfbed5c3f0cca1427624ff7f14b00bf0735977a6be8c408a7729706c6b |
| `web/genode-rn-21.08.html` | https://genode.org/documentation/release-notes/21.08 | 7bc0aa8e2a75717994e6245ab9cfb677dd16481249a3758222b862028a588519 |
| `web/genode-rn-21.11.html` | https://genode.org/documentation/release-notes/21.11 | c96e2ab6a82267e85d5dd1be9200a10ec4ab85b4ccf85d29b5b5cf89f47fa332 |
| `web/genode-rn-22.08.html` | https://genode.org/documentation/release-notes/22.08 | 071e7e28d4f572e8b5385eef49e6977b1fca37715bed2c97bcf2a7f2975d2846 |
| `web/genode-rn-23.02.html` | https://genode.org/documentation/release-notes/23.02 | 51992a0a5d0792a06e6e610eedff3c5864febfc20fe79815cd8895a08c088071 |
| `web/genode-rn-24.05.html` | https://genode.org/documentation/release-notes/24.05 | cf77ad7454ffc8448ecb4dd5e7d6b871f899bc117db92ddd6e4cf0cda9670db8 |
| `web/lvgl-9.5-opengl-overview.html` | https://docs.lvgl.io/9.5/integration/embedded_linux/opengl.html | e2a8ad80b0bf462856b83a48c9df2abc3ee7f542636f8c2325b5400b9243822e |
| `web/lvgl-9.5-nanovg.html` | https://docs.lvgl.io/9.5/integration/embedded_linux/nanovg.html | 74d206f0bd11f8b2e2ec13b0c4450a39ae6ed6ff6271b2c015c223e200a59269 |
| `web/qnx-8.0-screen-opengles.html` | https://qnx.com/developers/docs/8.0/com.qnx.doc.screen/topic/manual/cscreen_rendering-hardware-opengles.html | 4394938eabafdfb29295a8b955bc56fb134cbd84a61c64d71cc7b5228ae38fdb |
| `web/qnx-7.1-gpu-sharing.html` | https://china.qnx.com/developers/docs/7.1/com.qnx.doc.qavf.overview/topic/gpu.html | 6ad334c41297c9035cd85efa5634c6854c4cf8aeb5018fecead3455b5eae5797 |
| `web/hackaday-haiku-nvidia-2026.html` | https://hackaday.com/2026/07/12/porting-the-nvidia-gpu-driver-to-haiku-for-3d-acceleration/ | f43c42352acc5273b9047fc404fcf2a0daef47d3c0fa839df81c8d48f02e6429 |
| `web/rpi-firmware-mailbox-property.html` | https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface | 8d0f8cc524eb2541db0c25bd1aa3f8387df574e52086354221be366eb41cf38e |
| `web/virtio-v1.3-csd01.html` | https://docs.oasis-open.org/virtio/virtio/v1.3/csd01/virtio-v1.3-csd01.html | 3423e9507f2c363fc8e7bbdd013afc0436ed2954b79aa34db55cbf9afa07d45d |
| `web/bcm2711-peripherals.pdf` | https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf | d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78 |
| `web/videocoreiv-3d-ag-2013.pdf` | https://docs.broadcom.com/doc/12358545 | 9f83ecef4b9c2acb142cc43cf8fa11fb331a0144bf6579452559993dfe665936 |
| `mesa/docs-license.rst` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/docs/license.rst | 0d1a0472ecc81830e75c20d59b0ea02841e3db21255e0ebad97ab682c54d6615 |
| `mesa/docs-install.rst` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/docs/install.rst | f1d97f37591060387c678b28b597fd934ceada80aa33e71f346e70d3ce214088 |
| `mesa/virglrenderer-COPYING` | https://gitlab.freedesktop.org/virgl/virglrenderer/-/raw/1.3.0/COPYING | 3b32caf16e2402c2aff2b716858713f3e1feded85c25e71bf829816ee5009402 |
| `web/utm-release-v5.0.0.json` | https://api.github.com/repos/utmapp/UTM/releases/tags/v5.0.0 | 8482e5aedd378c37c7ee26ebe4255c9fb0cc1261cc01af8b6c184577c34ca786 |
| `mesa/v3dv_device.c` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/broadcom/vulkan/v3dv_device.c | d1d4f907e7ce308e475129499b842407fa5b6c6d87d3144e2435c591908fb53c |
| `mesa/v3d_simulator.h` | https://gitlab.freedesktop.org/mesa/mesa/-/raw/0a6fa60abb737d26ac8a316a4aad7c9ddf64f9e4/src/broadcom/simulator/v3d_simulator.h | 9de8dc8b960a6870281c7e3e9f9eb08efa474710c2d749dc4ff9c4a6d5c5d241 |
| `tarball/mesa-26.3.0.tar.xz` | https://archive.mesa3d.org/mesa-26.3.0.tar.xz | 91d729aa68bb89e4ec857841300bbe922bcb3e52b1f97566ca83930d3b28343a |
| `web/redox-book-graphics.html` | https://doc.redox-os.org/book/graphics-windowing.html | 0d60fd36a3ad9b5b779c038733d7727a1296202493f68cb4bedec93612fc3132 |
| `web/osnews-haiku-nvidia.html` | https://www.osnews.com/story/144097/haiku-gets-accelerated-nvidia-graphics-driver/ | a41e2d998a39f13de67beb473aca74088e7990c1528cfdbdd54fd372251bb8d5 |
| `freebsd-14.1.0-virtio-gpu/virtio_gpu.h` (fetched earlier, BSD) | FreeBSD releng/14.1 `sys/dev/virtio/gpu/virtio_gpu.h` | fe2a91547ba04bae7ac6b804e14596245084f32b5997e976b0f7ae44d48160dd |
| LVGL v9.6.0 (in tree, `display/lvgl/lvgl`) | https://github.com/lvgl/lvgl commit 80ca777e37a2b176770726a02e07a6fb79ef0b39 | archive b20ee3acc1bba13c62d854f9ebd62e4c51e0b443b1e0225892e86442defa84df (from `ORIGIN.md`) |

The Mesa tarball has no `.sha256sum` beside it at that URL (404), so its hash
was computed here and is not checked against an upstream signature. Also run
on this host: `qemu-system-aarch64 --version` (11.1.3), `-M virt -device
help`, `-display help`.
