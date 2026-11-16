# Research: display servers, compositors and window systems

A point-in-time research record for the erXos UI survey.

* Date: 2026-11-15 (sources fetched 2026-11-16 UTC, the same working session).
* Host: Apple Silicon macOS development host; sources fetched with `curl` over HTTPS, hashed with
  SHA-256, read as text. Nothing was run from them.
* Sources: `/Users/stas/erxos-scratch/sources/ui-survey/compositors/`, with `MANIFEST.tsv` (name,
  URL, fetch date, SHA-256, size). The table at the end lists every source cited here.
* Scope: one domain of the survey, display servers, compositors and window systems. Rendering,
  fonts, toolkits and UX are other records.
* Baseline: erXos master, `docs/design-display.md` and `docs/design-desktop-programs.md`, read by
  range.
* Licenses: only documentation, papers, protocol files and headers under MIT, BSD or Apache terms
  were read. No GPL or LGPL source was opened (KWin, Mutter, the Linux kernel and Enlightenment's
  compositor code were not read; the Linux kernel's KMS documentation was).
* Claims no source read in this task supports are marked **unverified**.

Two fetch notes. `gitlab.freedesktop.org` now answers automated fetches with a bot-check page, so
the Wayland core protocol, wayland-protocols and wlroots files were read from Debian's copies of the
upstream release tarballs (`deb.debian.org`, pinned versions wayland 1.26.0, wayland-protocols 1.50,
wlroots 0.19.3), not from the project's own host; their hashes are recorded. A few pages (Xaver
Hugl's explicit-sync article, Fuchsia's frame-scheduling page, two Arcan articles) returned 404 and
are not cited.

## 1. Summary

erXos's display is not old desktop technology on the compositor side. Its shape is the shape the
newest systems converged on: clients render into their own buffers, a window commits one atomic
`present` with damage rectangles, one present is in flight per window, the answer releases the
previous buffer and paces the client, and composition is a pure plan that may hand buffers to
hardware planes. That is Wayland's buffer model, Fuchsia Flatland's credit model, QNX Screen's
posting model and Nitpicker's buffers-and-views model, carried on erXos's own files and grants
instead of a new protocol. On two points it is simpler than any of them: the present's answer is the
release, the frame callback and the pacing signal in one message, and a window is a directory
reached through a grant, which gives Fuchsia-style unforgeable window identity with no new object
type. The "old technology" impression comes from the Plan 9 draw protocol and rio's look, which are
a client library and a window policy, not the compositor.

What is dated or missing is narrower and cheap to fix:

1. **No presentation timing.** The present's answer carries no timestamp, no refresh interval and no
   flag saying whether the frame was copied or scanned out directly. Wayland's `presentation-time`,
   Flatland's `OnFramePresented` and Windows' composition swapchain all report these, and newer
   protocols let a client ask for a frame "not before time T". erXos's own "Latency is UX" rule
   needs them.
2. **No pixel density.** Nothing in the display or the theme knows the screen's scale. Every modern
   system has one (macOS points and the backing scale factor, Windows per-monitor DPI, Wayland
   `fractional-scale-v1`, Flatland `device_pixel_ratio`). Because erXos windows are already measured
   in device pixels, adding a scale hint is *easier* for erXos than for Wayland: clients render at
   exact device size and the compositor never resamples.
3. **Tearing on single-buffered scanout.** On the Raspberry Pi firmware framebuffer the display
   copies into memory the panel scans all along. A second scanout buffer and wlroots-style damage of
   the last two frames remove tearing for a small cost (needs a hardware check).
4. **No trusted identity on screen.** Window borders are drawn by the display, which is the right
   place, but they show the client's own `label`. Capability window systems (EROS EWS, Nitpicker,
   Qubes) draw an identity the client cannot forge. erXos knows the principal of every grant and can
   do the same.
5. **No embedding.** A window cannot host another domain's view. Fuchsia (view tokens), Plan 9 (rio
   inside rio) and macOS (IOSurface's stated purpose: decode in a separate process for security) all
   support it. For erXos it is the safe way to show a preview rendered by an untrusted decoder
   inside Finder.
6. **No compositor-owned motion.** Core Animation and DirectComposition run animations in the
   compositor so the app can sleep. erXos's desktop design deliberately avoids decorative motion,
   which suits a CPU compositor; a few window transitions would be the one place where this matters
   for the "slick" goal, and should be measured on a Pi 4 before they are designed.

GPU composition, server-side layer trees with filters and blurs, HDR composition and adopting
Wayland itself all look attractive and do not fit erXos's targets or principles; section 5(b) says
why.

## 2. What erXos has today (the baseline)

From `docs/design-display.md` (line numbers on master at the time of reading):

* A display is a domain; a window is a directory (`ctl`, `mouse`, `kbd`, `wctl`, `label`) reached
  through a grant rooted at the client's own directory (lines 37-43).
* A window's pixels are a buffer in a **pixel area**, one memory object per connection that the
  client writes and the display maps read-only (lines 44-51).
* One command: `present` with a buffer and at most 16 changed rectangles; the answer comes when the
  device has taken the frame, releases the previous buffer, paces the client and keeps one present
  in flight (lines 52-58). The answer is defined per device: a virtio fence, the last byte on a
  panel's bus, or rows stored into a firmware framebuffer, optionally after a vertical blank (lines
  1686-1705). It carries no time.
* Rendering is the client's; the draw protocol (Plan 9 draw(3)) runs in the client's session, as
  plan9port's `devdraw` does (lines 59-69).
* Composition is a pure plan over rectangles, buffers and what the driver reports; paths are copy
  and direct; a 2D engine, plane compositor or GPU adds a buffer source or a composition path (lines
  124-131, 3887-3932).
* "Nothing paints without a change": no redraw timers anywhere (line 160, invariant G6 at line 430).
* Borders, menu and background are drawn by the display from the theme; windows are opaque
  `x8r8g8b8` (lines 445, 1948-1960).
* The design already compares itself with QNX Screen, Wayland and Fuchsia and takes their rules
  without their protocols (lines 194-199, 5212-5214).

From `docs/design-desktop-programs.md` lines 312-321: one level of depth, square window corners,
"nothing glows, blurs or animates for its own sake". No document mentions pixel density, scale or
colour space.

## 3. The systems

Each entry says what the system does, what it buys, what it costs, how mature it is, and what it
means for erXos.

### 3.1 macOS: WindowServer, Core Animation, IOSurface, Metal

**What it is.** Apple's archived guides describe a window server that composites every window's
backing store; on a high-resolution display apps draw in *points*, the backing store is allocated at
the backing scale factor (2x), and "the window server scales the content appropriately, mapping
points to onscreen pixels" [apple-hires-osx]. Core Animation keeps three trees per app: the
**model** layer tree the app edits, the **presentation** tree with in-flight animated values, and
the private **render** tree that performs the animations [apple-ca-basics]. A layer "merely manages
the state information surrounding a bitmap"; changing a property animates the cached bitmap in
hardware instead of calling the app's drawing code again [apple-ca-basics]. The OS X overview says
Core Animation's performance comes from "server-side content caching"
[apple-osx-tech-overview-graphics]. Apple's render-loop talk (iOS, but the same framework) describes
the pipeline: the app's commit phase sends the changed layer tree to "a separate process called the
render server", which prepares and executes it on the GPU for the next vsync; a late commit is a
"commit hitch", a late render a "render hitch"; and when nothing is committed no frame is produced
[apple-techtalk-10855]. The companion talk names the cost of the rich server: shadows, masks,
rounded clipping and blur/vibrancy force **offscreen passes**, where the GPU renders a layer
elsewhere and copies it back [apple-techtalk-10857].

IOSurface is "a framebuffer object suitable for sharing across process boundaries", "commonly used
to allow applications to move complex image decompression and draw logic into a separate process to
enhance security" [apple-iosurface]. `CAMetalLayer` hands out a small pool of drawables
(`maximumDrawableCount`, `nextDrawable`), can sync to the display (`displaySyncEnabled`) and opts
into extended range (`wantsExtendedDynamicRangeContent`) [apple-cametallayer]. `CADisplayLink` is
the timer that synchronises drawing to the refresh [apple-cadisplaylink]. **EDR**: content stays
display-referred; values in the standard range show as before, and larger values are allowed up to a
range that adapts to the display and its brightness setting [apple-edr].

**Buys and costs.** Smooth animation with the app asleep, one owner of timing, HiDPI that legacy
drawing code mostly gets for free, out-of-process decoding with zero-copy surfaces, HDR that
degrades gracefully; paid for with a large server-side scene whose effects need a GPU and offscreen
passes.

**For erXos.** Take the *points vs pixels* idea as a scale hint, the IOSurface use case (decode in a
sandbox, show without copying) as an argument for embedding, and the render-loop vocabulary (commit,
render, hitch) for measurements. Do not take the server-side layer tree: it needs a GPU and puts
every client's scene state in the display. Whether macOS app windows' title bars are drawn
in-process by AppKit is **unverified** here.

### 3.2 Windows: DWM, DirectComposition, flip model

**What it is.** Since Vista, windows draw to off-screen surfaces that the Desktop Window Manager
composes [ms-dwm-overview]. DirectComposition splits into an app library (`dcomp.dll`), a kernel
object database in `win32k.sys` that marshals commands, and one composition engine (`dwmcore.dll`)
in `dwm.exe` that "handles the DirectComposition composition trees for all applications and the DWM
composition tree" [ms-dcomp-arch]. The visual tree is retained and edited in batches applied
atomically at `Commit`; properties are write-only because the engine runs asynchronously
[ms-dcomp-arch]. Animations are functions made of cubic, sinusoidal, repeat and end segments, run by
the engine "on a separate thread" while app threads sleep [ms-dcomp-animation]. The **flip model**
shares the app's back buffers with DWM so it "can compose straight from those back buffers without
any additional copy operations" [ms-dxgi-flip]. The **composition swapchain** API lets a present
carry a *target time* and reports present statistics [ms-comp-swapchain]. **Advanced Color**: DWM
composes in a canonical composition colour space, scRGB (sRGB primaries, linear) in FP16, converting
each app into it before blending; before that, windowed apps were limited to 8 bits per channel
[ms-hdr]. **DPI**: apps declare an awareness mode; unaware apps are bitmap-stretched and look
blurry; per-monitor aware apps relayout on DPI change [ms-hidpi].

**Buys and costs.** Compositor animations, zero-copy windowed presentation, timed presents and one
composition space for SDR and HDR mixes; paid for with surfaces in video memory, a kernel component
in the path, and DPI awareness as a compatibility matrix Windows still carries.

**For erXos.** Two lessons: a present can carry a target time, and a compositor that mixes colour
spaces needs one declared composition space. The DPI history is the cautionary tale: decide the
scale model before there are many apps, so there is no "unaware" mode to support.

### 3.3 Wayland and wlroots

**What it is.** In Wayland "the compositor is the display server"; rendering happens in the client,
which "just sends a request to the compositor to indicate the region that was updated"
[wl-architecture]. `wl_surface` state is double-buffered and `commit` "atomically creates a Content
Update" placed in a per-surface queue [wayland.xml]; damage can be given in buffer coordinates
(`damage_buffer`) [wayland.xml]. The extensions read for this record:

* `wl_shm` for CPU buffers [wayland.xml] and `linux-dmabuf` for GPU buffers [linux-dmabuf-v1.xml];
* `presentation-time`: after the flip, the compositor reports the realised presentation time with
  flags `vsync`, `hw_clock`, `hw_completion` and `zero_copy` ("compositing with OpenGL counts as
  copying") [presentation-time.xml];
* `commit-timing-v1`: present "as closely as possible to, but not before, a specified time"
  [commit-timing-v1.xml];
* `fifo-v1`: use completion of a refresh cycle as a readiness constraint [fifo-v1.xml];
* `tearing-control-v1`: let games accept tearing for latency [tearing-control-v1.xml];
* `linux-drm-syncobj-v1`: **explicit sync**, an acquire timeline point the compositor waits on
  before reading and a release point it signals when done [linux-drm-syncobj-v1.xml];
* `fractional-scale-v1`: the compositor sends a preferred scale as a numerator over 120; the client
  renders a buffer of surface size times scale and uses `wp_viewport` to map it back
  [fractional-scale-v1.xml, viewporter.xml];
* `xdg-decoration`: without negotiation "clients continue to self-decorate"; the protocol lets a
  client ask for server-side decorations [xdg-decoration-unstable-v1.xml];
* `color-management-v1`: immutable *image descriptions* for outputs and surfaces, with named
  primaries (sRGB, Display P3, BT.2020 ...), transfer functions (gamma 2.2, PQ, HLG, linear ...) and
  rendering intents [color-management-v1.xml];
* `security-context-v1`: a sandbox engine tags connections so the compositor can restrict them
  [security-context-v1.xml].

wlroots (MIT) implements "components common to many compositors" (its README). Its scene graph is "a
declarative way to display surfaces" with only tree, rect and buffer nodes, deliberately limited to
"basic 2D composition operations (like the KMS API or the Wayland protocol does)"; buffer nodes
carry opacity and an opaque region, and outputs try direct scanout [wlr_scene.h]. Its **damage
ring** keeps per-buffer damage so a swapchain buffer of age *n* is repainted with the union of the
last *n* frames' damage [wlr_damage_ring.h]. wlroots ships a **pixman (CPU) renderer** beside GLES2
and Vulkan (the `render/pixman` directory of the 0.19.3 tarball).

**Buys.** A minimal core protocol; clients own rendering; atomic updates; zero-copy; a large
extension set for the hard parts (timing, scale, colour).

**Costs.** File descriptors in messages, one protocol per concern (dozens of XML files), and
client-side decorations by default, so every toolkit draws its own frames. The timing and colour
extensions are still marked "testing" in wayland-protocols 1.50. Whether GNOME refuses server-side
decorations is **unverified** here.

**For erXos.** The design already took the buffer rules and rejected the protocol (design-display.md
line 5212); that remains right. What it has not taken yet: the presentation feedback flags, the "not
before T" constraint, the scale numerator over 120, an opaque region if windows ever gain alpha, and
the damage ring for multi-buffered scanout. wlroots' CPU renderer is evidence that CPU composition
is a supported, first-class mode, not a fallback to be ashamed of.

### 3.4 Fuchsia: Scenic and Flatland

**What it is.** Scenic is the system compositor. Flatland is its 2D API: "retained mode", a global
scene graph "with content distributed between components", built from **rectangular layers only**
[fx-flatland-concepts]. It supersedes Scenic's earlier 3D API (all clients are being migrated to
Flatland) because "Fuchsia's current customers are fundamentally 2D products"
[fx-flatland-concepts]. Design decisions: commands are enqueued on the server and committed by
`Present()`; Flatland "aims to delegate composition work to Video Display Controller hardware where
possible" and "closely follows" the display controller's strictly 2D model; there is "one
deadline-scheduled render thread" and each session runs on its own dispatcher; image allocation goes
through an Allocator and "no copies are made" [fx-flatland-concepts]. The FIDL file shows the
contract [fx-flatland.fidl]: a client has *present credits* (one before the first event); each
`Present` costs one; `OnNextFrameBegin` returns credits and says when to start rendering;
`OnFramePresented` reports what reached the display. `PresentArgs` carry
`requested_presentation_time`, `acquire_fences`, `release_fences` and `unsquashable`. Transforms
carry translation, orientation, scale, opacity and a clip; images carry sample region, destination
size, blend mode and opacity. Layout information carries a `logical_size` and a
`device_pixel_ratio`, and "the client should allocate buffers that are sized
(`logical_size`*`device_pixel_ratio`)". Embedding uses a token pair: a parent `CreateViewport` with
one token, the child `CreateView` with the other [fx-flatland.fidl]. A **ViewRef** is backed by a
kernel eventpair, so it "cannot be forged" and is unique over the system's life [fx-view-ref]. When
a session dies, its links break and Scenic frees everything it held [fx-scenic-index].

**Buys and costs.** A capability OS's answer to the compositor: unforgeable view identity, embedding
by token, plane-first composition, credits instead of a flood of frames, explicit fences; paid for
with a per-client scene graph in the compositor, fences as kernel objects and a negotiated allocator
(sysmem). Which products ship Flatland is **unverified** here.

**For erXos.** The closest relative in spirit. erXos already has the credit (one present in flight)
and the plane-first plan. Worth taking: the `requested_presentation_time` idea, the logical size
plus pixel ratio, and token-based embedding mapped onto grants. The retreat from 3D to 2D rectangles
is the strongest evidence in this survey that a compositor should stay close to what display
hardware does: rectangles, offsets, scale, opacity.

### 3.5 Android: SurfaceFlinger and the Hardware Composer

**What it is.** SurfaceFlinger composes buffers that apps queue through BufferQueue
[aosp-surfaceflinger, aosp-bufferqueue]. The Hardware Composer HAL decides composition:
SurfaceFlinger gives it the full layer list, HWC marks each layer *device* (an overlay plane) or
*client* (GPU composition into a target buffer), and SurfaceFlinger composes the client layers
[aosp-hwc]. "Android devices typically support four overlay planes"; planes "may be less efficient
than GL composition when nothing on the screen is changing", so HWC can composite once and keep
showing the cached result to save battery [aosp-hwc]. Explicit sync is a kernel sync framework of
timelines, points and fences; HWC takes *acquire* fences with input buffers and returns *release*
fences [aosp-sync]. **VSync offsets**: by default an app renders frame N+2 while SurfaceFlinger
composes N+1 and the display shows N, at least two frames of latency; phase offsets for the app and
SurfaceFlinger signals reduce it [aosp-vsync].

**Buys and costs.** Battery life through planes and caching, device-specific composition behind one
HAL and a documented latency model; paid for with vendor HALs, a GPU fallback that must always exist
and phase offsets tuned per device.

**For erXos.** The HWC "validate then present" exchange is the same idea as erXos's composition plan
checked against the driver (and KMS's `DRM_MODE_ATOMIC_TEST_ONLY`, 3.11). The caching trick matters
on the Pi: when a plane set is unchanged, nothing is recomposed. The vsync offset model is the
clearest statement of where pipeline latency comes from, and the measurement erXos should make
before adding machinery.

### 3.6 Haiku app_server

**What it is.** BeOS's design, kept by Haiku (MIT): apps send drawing commands to `app_server`,
which draws them. It was built for "low latency response ... making use of the quite powerful CPU,
but somewhat limited RAM", so BeOS used a single-buffered framebuffer; 2D acceleration came through
*accelerants* loaded into the server, but on modern hardware "Haiku does not currently use most of
these acceleration features, doing its drawing using the CPU instead" [haiku-graphics]. Single
buffering causes "flickering and stamping" when apps redraw slowly, which the server works to hide
[haiku-graphics]. The server is a port-monitoring message loop with per-app threads
[haiku-AppServer].

**For erXos.** A data point for CPU drawing being fast enough on a desktop, and against server-side
drawing: the glitches Haiku works around are the ones client buffers remove by construction. erXos
already moved from Plan 9's server-side draw to client-side buffers, for the same reason.

### 3.7 Enlightenment and EFL Evas

**What it is.** Evas is "a canvas display library": unlike "immediate mode display targets" it is
"structural and is also a state engine"; the program moves, resizes, shows and hides objects and the
canvas works out "what changed in the canvas since it was last drawn" and redraws only that
[efl-evas-rendering]. It does not own windows; it "draws the pixels and reports to the user the
areas that are changed" [efl-evas-rendering]. Rendering goes to engines (`buffer`, `fb`,
`software_x11`, `gl_x11` ...); a missing primitive falls back to software [efl-evas-engines]. Under
Wayland, EFL's shared-memory and EGL engines support double or triple buffering, transparency,
rotation, partial swaps with buffer ageing, and client-side decorations [efl-ecore-wayland]. That
Enlightenment's own compositor uses Evas as its scene graph is **unverified** here (its code is not
under a license this survey may read, and no design document was found).

**For erXos.** Evas is the retained-canvas idea at the client, the same place erXos puts its widget
trees, and it shows the canvas computing damage for the compositor, which is what erXos's renderers
report in `present`. Nothing to move into the display.

### 3.8 Plan 9: 8½, rio and draw

**What it is.** 8½ "provides textual I/O and bitmap graphic services ... by offering a multiplexed
file service"; "the file service that 8½ offers its clients is identical to that it uses for its own
implementation, so it is fundamentally no more than a multiplexer", and that design is "the most
important contributor to its small size" [p9-8half]. rio serves per-window files and posts `$wsys`
so that a mount creates a new window [p9-rio4]. draw(3) gives each connection
`/dev/draw/n/{ctl,data,colormap,refresh}`, with images, screens and font caches held by the draw
device, and *public* screens other processes may reach [p9-draw3]. Pike's earlier concurrent window
system argued that a window system written in a concurrent language with clients on synchronous
channels avoids event-loop state machines, and that "the window system itself may be run
recursively" for subwindows [pike-concurrent-ws].

**For erXos.** erXos keeps the file tree and drops the server-side images and public screens
(design-display.md lines 63-69); that is the correct reading of Plan 9 for a capability system. Two
Plan 9 ideas are not yet used: **recursion** (a window system inside a window, which is embedding by
another name) and the observation in Pike's paper that channels per device make clients simple,
which is exactly what Erlang processes and the `{ui, ...}` messages give.

### 3.9 Arcan

**What it is.** A display server built on a multimedia engine with a Lua scripting interface for
policy, one IPC system (SHMIF) and two client APIs [arcan-about]. SHMIF segments carry pixels, audio
and events in shared memory with dirty-region tracking and semaphores for buffer synchronisation;
extra segments for popups and decorations live and die with the primary one; segments announce
*alternative representations* (for example a textual form for accessibility); the server can push
fonts and "dynamic density" updates including "physical size (mm) of what the user currently deems
as a readable component size"; and a client can be given a fallback connection point to "resume a
connection later, should the server crash" [arcan-wiki-shmif]. Connections are *authoritative* (set
up by a parent process) or not [arcan-wiki-shmif].

**For erXos.** erXos already rejected Arcan as a component (too large a trusted base, frameservers
duplicate programs; design-display.md line 188). Ideas worth noting: density as a readable physical
size, not a bare factor; alternative representations of a window (erXos's widget trees and
presentations already go further); and client survival across a display restart (erXos makes a new
connection and a zeroed area, line 568, and clients redraw, which is simpler and adequate).

### 3.10 ChromeOS, Ozone and Viz

**What it is.** Ozone is Chromium's platform layer beneath its Aura window system, for targets from
embedded SoCs to Wayland [cr-ozone]. Viz's **display compositor** "uses Gpu or software to composite
a set of frames, from multiple clients, into a single backing store", with platform code for
presentation and overlays [cr-viz-readme]. Renderers' `cc` compositor builds *compositor frames* of
quads and render passes and submits them to the SurfaceAggregator; a *SurfaceLayer* refers to
another producer's stream of frames, which is how one client embeds another; and cc handles pinch
and scroll "without involving Blink", so scrolling stays smooth when the page's main thread is busy
[cr-how-cc-works]. Software raster tiles are about 256 by 256 pixels [cr-how-cc-works].

**For erXos.** Two ideas: embedding by surface identity (as Fuchsia's token), and handling scroll at
the composition layer. The second does not fit a CPU compositor that copies opaque windows: the
client would still have to render the newly exposed rows. It belongs inside a client's renderer (the
widget server can scroll a retained surface), not in the display.

### 3.11 Game consoles and embedded compositors

* **gamescope** (Valve, BSD-2): a "micro-compositor" that gets game frames without an intermediate
  copy, flips them directly to the screen with KMS "even when stretching or when notifications are
  up", and when it must compose uses async Vulkan compute; nested, it gives the game a sandboxed
  virtual screen of chosen size and refresh [gamescope-readme]. Lesson: the fastest path is a direct
  flip with planes for overlays; composition is the exception.
* **Nintendo Switch** display services, from a community reverse-engineering wiki (not vendor
  documentation): displays and a small set of *layers* with scaling modes and a vsync event, and a
  window-buffer path whose parcels carry Android-derived structures [switchbrew-vi]. Lesson: a
  console compositor is a fixed layer stack, not a general window system. Details beyond the method
  names are **unverified**.
* **QNX Screen**: a client/server compositor in which "all application rendering is performed on
  off-screen buffers"; windows combine output from different renderers [qnx-screen-arch]. erXos's
  design already names Screen as its closest relative (line 196).
* **Linux KMS atomic**: planes, CRTCs and connectors are committed atomically; "no hardware changes
  are allowed when the commit would fail", which is what makes `DRM_MODE_ATOMIC_TEST_ONLY` possible;
  planes carry optional `FB_DAMAGE_CLIPS` rectangles and in/out fence properties [kms-atomic].
  erXos's "composition is a plan, checked against the device before it is applied" is the same
  contract.

### 3.12 Capability and high-assurance window systems

These are the systems most like erXos in what they must guarantee.

* **EROS Window System (EWS)**, Shapiro et al., USENIX Security 2004: under 4,500 lines, "a factor
  of ten smaller" than Trusted X [eros-ews]. Its principles include: no operation on one session can
  observe another (R1); no shared mutable state (R2); minimise server resource types (R3) and
  algorithmic complexity (R4); no communication between apps through the server without a
  demonstrable user action, "volitional traceability" (R6); the server queues no input, uses bounded
  resources, and "dynamically allocated resources, if any, should come from the client" (R7); each
  input event goes to exactly one recipient (R9) [eros-ews]. Clients render into shared memory; "a
  side benefit of client-side rendering is that the server is no longer responsible for font
  handling", the server keeping one compiled-in font for title bars; the bitblt routine is the only
  code that reads client memory, and a fault there severs the client's session [eros-ews].
* **Nitpicker** (Feske and Helmuth, TU Dresden, 2005): 1,500 lines; only two object kinds, *buffers*
  (client memory imported by shared memory) and *views* (rectangles on screen showing a region of a
  buffer, several views per buffer allowed); windows are handled client-side; two magic keys no
  client sees, *Kill* to lock out a misbehaving client and *X-ray* to show dimming, borders and
  "floating labels" naming each view's owner [nitpicker].
* **Qubes OS**: each VM's windows are composition buffers shared with the GUI domain by grant-table
  pages, with damage events forwarded; the GUI daemon shows them through its own X server
  [qubes-gui]. Qubes' coloured, VM-labelled frames are a well-known feature but the colour detail
  was not in the page read and is **unverified** here.

**For erXos.** erXos already meets R1, R2, R4 and R9 by construction (design-display.md G1, line
425) and, like EWS, renders clients' content on the client side and draws its own text only from
built-in glyphs. Two differences stand out. First, EWS charges a session's resources to the client
(R7) while erXos charges the pixel area to the display, bounded by the grant (design-display.md, the
"client paying for its pixel area" row, line 5217); both are bounded, and erXos's reasoning (the
reader keeps the mapping after the writer ends) is sound, but the difference deserves a sentence in
the design. Second, all three systems show the owner's identity with a mark the client cannot draw;
erXos's borders show the client's `label`. Drawing the grant's principal in the border (and offering
an X-ray-style key) is a small change with real anti-spoofing value.

## 4. Themes

### 4.1 Retained mode, and where the scene lives

At the compositor every modern system is retained: the last frame of a quiescent client stays on
screen [fx-scenic-index], and no commit means no frame [apple-techtalk-10855]. Evas, Core Animation
and cc also retain structure on the client side to compute damage cheaply [efl-evas-rendering,
apple-ca-basics, cr-how-cc-works]; erXos's widget server, which keeps the realised tree and diffs
it, is in that line. The real question is how much scene the *compositor* holds. Two families:

| Family | Systems | Server holds |
| --- | --- | --- |
| layer tree with effects | macOS Core Animation render server, DirectComposition, Scenic's superseded 3D API | transforms, opacity, masks, filters, animations per layer |
| 2D rectangles of client buffers | Wayland (+wlroots scene), Flatland, SurfaceFlinger/HWC, QNX Screen, Nitpicker, EWS, erXos | a few buffers per window with position, crop, scale, opacity |

The trend is towards the second: Fuchsia is moving every client from its 3D scene to 2D rectangles
that mirror the display controller [fx-flatland-concepts]; wlroots limits its scene to what KMS can
do [wlr_scene.h]. The first family's benefits (compositor animation, GPU effects) come with
offscreen passes and server state [apple-techtalk-10857]. erXos holds one rectangle per window, with
no crop, scale or opacity. That is narrower than Flatland but sufficient while windows are opaque
and composition is a copy. **Keep it; grow it only by a named consumer** (an embedded view is the
likely first one, section 4.10).

### 4.2 GPU versus CPU composition

Every desktop system above composes on the GPU, with hardware planes preferred (HWC, Flatland,
gamescope, Viz overlays). The CPU exceptions are deliberate: Haiku draws with the CPU because 2D
acceleration "is often not that fast" [haiku-graphics], wlroots ships a pixman renderer, EWS and
Nitpicker blit. For erXos's targets the arithmetic decides: a full 1920x1080 frame of 32-bit pixels
is 8,294,400 bytes, so a full recomposite at 60 Hz moves about 498 MB/s, while a typical change (a
clock, a graph line, a typed character) is a few kilobytes. With opaque windows and damage, the CPU
copy is cheap; full-screen motion is where it is not. On the Pi the useful hardware is the HVS plane
compositor, which erXos's design already places as a composition path (line 3921); the V3D GPU adds
little to opaque rectangle composition. **erXos's choice is right for its targets**, with planes as
the next step, not GL.

### 4.3 Damage tracking

All current systems pass damage from client to compositor (`wl_surface.damage_buffer` [wayland.xml];
Evas reports changed areas [efl-evas-rendering]; SHMIF tracks dirty regions [arcan-wiki-shmif]; KMS
planes take `FB_DAMAGE_CLIPS` [kms-atomic]). erXos's up to 16 rectangles per present matches this.
The piece erXos lacks is the **damage ring** [wlr_damage_ring.h]: when the screen has two or more
scanout buffers, each must be repaired with the damage of every frame since it was last shown. erXos
needs it only if it double-buffers scanout (4.4).

### 4.4 Vsync, frame pacing and latency

What the systems do:

* Pace by credit or callback: Flatland credits [fx-flatland.fidl], Wayland frame callbacks, Windows
  present queues [ms-comp-swapchain], erXos's single in-flight present. Equivalent; erXos's is
  simplest.
* Report what happened: `presentation-time` flags and timestamps [presentation-time.xml],
  `OnFramePresented` [fx-flatland.fidl], Windows present statistics [ms-comp-swapchain]. **erXos has
  nothing.**
* Ask for a time: `commit-timing` [commit-timing-v1.xml], `requested_presentation_time`
  [fx-flatland.fidl], composition swapchain target time [ms-comp-swapchain]. **erXos has nothing.**
* Tell the client when to start: Flatland's `OnNextFrameBegin` [fx-flatland.fidl], Android's app
  vsync phase [aosp-vsync]. erXos's answer implicitly says "now".
* Avoid tearing: present at vertical blank (`vsync` flag semantics [presentation-time.xml]; HVS
  display lists applied at blanking per erXos's own table, line 3921). On the Pi firmware
  framebuffer erXos copies into memory the panel scans, so a large copy can tear unless the driver
  waits for blanking first (lines 1700-1705).

Latency comes from pipeline depth: Android documents at least two frames by default [aosp-vsync];
Apple's loop is commit, render, display [apple-techtalk-10855]. erXos's path has more hops before
the screen (lane, funnel, `erx_winfs`, window process, `erx_screen`, driver) and its performance
section already asks for that round trip to be measured (line 5154).

**For erXos:**

1. Put presentation feedback into the present's answer: the monotonic time the frame was taken (and
   shown, where the device knows), the refresh period when known, and flags for vsync-aligned,
   hardware timestamp, and copied versus direct. Unknown values are reported as unknown, as erXos's
   never-fabricate rule requires. Small change; it is what an animated clock or graph needs to keep
   a steady cadence, and what `tools/erx bench` needs to measure latency.
2. Later, an optional "not before T" on `present` for video and timed animation. Small, once (1)
   exists.
3. On the Pi, two scanout buffers swapped at blanking (or HVS planes), with a two-frame damage ring.
   Whether the Pi 4/5 firmware framebuffer supports a second buffer by panning is **unverified**
   here and must be checked against the firmware mailbox documentation.

### 4.5 Zero-copy buffer sharing and synchronisation

Zero-copy is universal: DXGI flip model [ms-dxgi-flip], IOSurface [apple-iosurface], dmabuf,
Flatland's "no copies" [fx-flatland-concepts], Nitpicker and EWS shared memory, Qubes grant pages
[qubes-gui]. erXos's pixel area is the same mechanism with one extra property the others lack: the
system domain makes it, the display maps it read-only, and a present is checked against its size
(G1, line 425). **Current, and better isolated than most.**

Synchronisation splits into release (the compositor is done reading) and acquire (the producer is
done writing). erXos's answer is the release. Acquire is implicit because the CPU finishes writing
before the client writes `present`. It stops being implicit the day a render service (V3D, virgl)
fills buffers asynchronously: then the display must not read until the job completes, as Wayland's
syncobj timeline points [linux-drm-syncobj-v1.xml], Flatland's `acquire_fences` [fx-flatland.fidl]
and Android's acquire fences [aosp-sync] ensure. In Erlang the natural form is not a kernel fence
object but a message: the window process holds the present until the render service reports the job
done. This belongs in the render-service design the display document already defers (line 3901), not
now.

### 4.6 HiDPI and fractional scaling

Approaches:

* **Logical units plus a factor, the compositor scales legacy content**: macOS points and backing
  stores [apple-hires-osx]; Windows DPI awareness with bitmap stretching for unaware apps
  [ms-hidpi].
* **The client renders at device pixels from a hint**: Wayland `fractional-scale-v1` (scale in
  120ths, buffer at surface size times scale, `wp_viewport` back to surface size)
  [fractional-scale-v1.xml]; Flatland `logical_size` and `device_pixel_ratio`, buffers sized to
  their product [fx-flatland.fidl]; Arcan's density events with a readable physical size
  [arcan-wiki-shmif].

The second family gives sharp output at any factor, including 1.25 and 1.5, and never resamples in
the compositor. Wayland needed a viewport extension to get there because its surfaces are in logical
units. **erXos's windows are already in device pixels**, so the whole of fractional scaling for
erXos is: the display tells each window the scale (one more field in the `ctl` read, for example a
numerator over 120 as Wayland uses), and the renderers lay out in scaled units. The window system,
the plan, the copy path and the buffers do not change. The cost lands elsewhere: the theme's type is
pre-rasterised into Plan 9 subfonts at one pixel size per role at build time
(design-desktop-programs.md), so each supported scale needs its own glyph set or run-time
rasterisation in the client's session (the fonts record of this survey owns that choice); icons are
stroked at build time and need the same. Mixed-density multi-monitor is out of scope: an erXos
display domain serves one screen.

**Recommend:** decide the scale model now, before apps exist, so there is no "unaware" mode to carry
later (Windows' lesson [ms-hidpi]). Small in the display; medium in the renderers and the build's
glyph step.

### 4.7 HDR and colour management at the compositor

The state of the art: Windows composes everything in scRGB FP16 and converts each app into it
[ms-hdr]; macOS keeps content display-referred and allows values beyond the standard range up to an
adaptive limit [apple-edr]; Wayland describes outputs and surfaces with immutable image descriptions
so the compositor converts between them [color-management-v1.xml]; KMS has colour-management plane
properties [kms-atomic]. All three desktop approaches assume GPU composition: FP16 doubles the bytes
of every pixel and linear blending needs per-pixel conversion. erXos's targets have 8-bit SDR
panels, its composition is an opaque copy with no blending, and its channel descriptors say nothing
of colour space.

**Recommend:** state in the design that buffers and the screen are sRGB, and leave a seam (a
colour-space tag beside the channel) for the day a wide-gamut panel or an image app needs it. HDR
composition does not fit (5(b)).

### 4.8 Animations owned by the compositor

Core Animation and DirectComposition run animations in the compositor from declared start and end
values or segment functions, so the app can sleep and a busy app does not stutter [apple-ca-basics,
ms-dcomp-animation]. cc does the same for scroll inside Chromium [cr-how-cc-works]. Wayland and
Flatland do not: clients animate by presenting frames, with timing feedback to keep cadence.

For erXos two facts pull against compositor animation: the compositor is a CPU copy, so an animated
window means recompositing its whole area every frame (a moving 800x600 window is about 1.9 MB per
frame, 115 MB/s at 60 Hz, by the same arithmetic as 4.2), and the desktop design rejects decorative
motion (design-desktop-programs.md line 320). One pull for it: the "slick and sharp" feel the
desktop brief asks for comes largely from short window transitions (open, close, hide), which only
the compositor can run without each client's help. They would be time-bounded sequences of plans in
`erx_screen`, pure functions of time and two layouts, which suits the functional-core rule;
invariant G6 would read "nothing paints without a change or a transition a change started".

**Recommend:** do not design this yet. First measure the copy rate on a Pi 4 at 1080p (already on
the watch list, line 5152) and a throwaway transition, per the "cheap hacks first" practice.
Translation-only transitions need no new pixel operation; fades need alpha blending, which the draw
library's Porter-Duff operators already define [p9-draw2], and cost per-pixel work on every frame.

### 4.9 Decorations: client-side, server-side, trusted

Wayland defaults to client-side decorations and negotiates server-side ones
[xdg-decoration-unstable-v1.xml]; EFL draws its own frames under Wayland [efl-ecore-wayland]; Qubes,
EWS and Nitpicker draw frames in the trusted server, and EWS keeps one compiled-in font for titles
[eros-ews, nitpicker, qubes-gui]. erXos draws borders in the display (line 1956), which avoids every
toolkit drawing frames differently and keeps the move/resize logic in one place. **Correct for
erXos.** The gap is what the frame says: show the principal and app from the grant, escaped, rather
than (or beside) the client's `label`, and consider a reserved key, as Nitpicker's X-ray, that dims
everything but the focused window and names its owner. Small change, real security value.

### 4.10 Embedding and nesting

Fuchsia embeds by token pair with unforgeable ViewRefs [fx-flatland.fidl, fx-view-ref]; Chromium by
surface identity [cr-how-cc-works]; Plan 9 by running the window system recursively [p9-8half,
pike-concurrent-ws]; macOS's IOSurface exists so decoding can move to a separate process
[apple-iosurface]. erXos has none. Its natural form: a window directory gains a way to make a child
window clipped to it, and the client can hand a grant on that child directory to a sub-space or
another session, which then presents into the child as into any window. Consumers: Finder previews
of untrusted files rendered by a sandboxed decoder without Finder copying pixels; a browser or
document viewer hosting untrusted content; a terminal multiplexer. This is a new mechanism, so under
erXos's rules it needs a design section first. Medium.

### 4.11 Fit with per-window file trees and capabilities

How each idea lands on erXos's model (a window is a directory, the grant is the authority, one
command about pixels):

| Idea | Lands as | New mechanism? |
| --- | --- | --- |
| presentation feedback | more fields in the existing `present` answer | no |
| "not before T" | an optional field of `present` | no |
| scale hint | a field of the `ctl` read | no |
| trusted identity | the display draws what it knows of the grant | no |
| colour-space tag | a field beside the channel | no (until used) |
| two scanout buffers | inside the Pi display driver and the plan | no |
| embedded child window | a child directory and a grant handed on | yes: needs design |
| render-service completion | a message the window process waits for | yes, in the render-service design |
| compositor transitions | plans as functions of time in `erx_screen` | yes: needs design and measurement |
| per-window layers (crop, scale, opacity) | more fields per buffer in `present` | yes: only with a consumer |

The file tree carries every one of these without new object types, which is the property Plan 9
promised and the capability systems in 3.12 want. Nothing found in this survey argues for replacing
it.

## 5. Conclusions

### (a) Ranked ideas worth adopting or prototyping

1. **Presentation feedback in the `present` answer** (time taken, refresh period, vsync /
   hardware-clock / copied-or-direct flags, unknown reported as unknown). Needed for steady
   animation of the clock and stats and for latency benchmarks. *Small.*
2. **A scale hint and a scale model decided now** (scale in 120ths in the `ctl` read; windows stay
   in device pixels; renderers lay out in scaled units). Sharp output at 1x, 1.25x, 1.5x, 2x with no
   compositor resampling. *Small in the display; medium in renderers, glyph and icon build steps.*
3. **Trusted identity in window borders, plus an X-ray-style key.** Anti-spoofing from what the
   display already knows. *Small.*
4. **Tear-free scanout on the Pi** (two buffers swapped at blanking or HVS planes, two-frame damage
   ring). *Small to medium; needs a firmware check.*
5. **Embedded child windows via a grant on a child directory.** Safe previews and hosted content.
   *Medium; needs a design section.*
6. **"Not before T" on `present`.** Video and timed animation. *Small, after 1.*
7. **Measure, then decide on compositor window transitions.** A throwaway transition and the copy
   rate on a Pi 4 at 1080p first. *Measurement small; the feature medium.*
8. **State sRGB and leave a colour-space seam.** *Documentation only.*
9. **Note the acquire-side completion for the future render service** (a message the window process
   waits for). *Documentation only now.*

### (b) Attractive but not a fit

* **A server-side layer tree with effects** (Core Animation, DirectComposition): needs a GPU and
  offscreen passes, puts every client's scene state and animation engine in the display, against the
  display-parses-nothing rule and EWS's R3/R4.
* **Adopting the Wayland protocol or wlroots**: C libraries, file descriptors in messages, dozens of
  extension protocols; erXos already carries the same rules on its own files (design-display.md line
  5212).
* **GPU composition on the Pi's V3D**: Mesa and a GPU domain for what is an opaque rectangle copy;
  HVS planes give the zero-copy win without it.
* **HDR and FP16 composition**: doubles bytes per pixel, needs per-pixel conversion, and the targets
  have SDR panels.
* **Compositor-side scrolling** (Chromium cc): useless while the compositor cannot render the
  exposed rows; belongs in the client's renderer.
* **Arcan's scripting engine in the display**: a large trusted component; erXos's window policies
  are already Erlang modules in the display domain.
* **Server-side drawing** (Haiku, original Plan 9 draw): glitches and server-side parsing; erXos
  already moved past it.
* **Tearing control and Android-style vsync phase tuning**: for games and phones; premature before
  the present round trip is measured.
* **Negotiated buffer allocation** (Fuchsia sysmem): erXos states the one constraint, the area's
  size and kind, in the manifest.

### (c) Open questions and unverified points

* Whether the Pi 4/5 firmware framebuffer supports a second buffer by virtual offset, and the HVS
  plane count on each board: **unverified**, needed for idea 4.
* The present round trip and the copy rate on HVF and on a Pi 4: not measured; already on the
  display design's watch list.
* How the pointer image is drawn and whether virtio-gpu's cursor queue or an HVS cursor plane is
  used: not found in a quick search of the display design; virtio-gpu cursor support is
  **unverified** here.
* EWS charges a session's resources to the client, erXos charges the pixel area to the display:
  worth a sentence in the design.
* Whether compositor transitions are wanted at all, given "nothing animates for its own sake": a
  product question, not a technical one.
* Unverified claims named in the text: macOS title bars drawn by AppKit, GNOME's stance on
  server-side decorations, Enlightenment's compositor built on Evas, Qubes' coloured frames, Switch
  details beyond method names.
* The WWDC 2014 session page had no transcript and is not cited; the render-server statements come
  from Apple's tech talks 10855 and 10857, which describe iOS. That macOS's WindowServer runs the
  same render-server pipeline is **unverified** here.

## Sources

Fetched by `curl` over HTTPS into `/Users/stas/erxos-scratch/sources/ui-survey/compositors/`.
Citations in the text use the names below (tarball files by their file name).

| Name | URL | Fetched (UTC) | SHA-256 |
| --- | --- | --- | --- |
| `apple-ca-basics.html` | https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html | 2026-11-16 | `915a0aba861935fff3c224281888bb7c4799725b20af2d133f454f435c50c373` |
| `apple-hires-osx.html` | https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Explained/Explained.html | 2026-11-16 | `90399f0abfb9b6ed3fb242c3803fb0698266c128e65da45aaf5406d59e4b2697` |
| `apple-iosurface.json` | https://developer.apple.com/tutorials/data/documentation/iosurface.json | 2026-11-16 | `a3d61b98a4fb9bc59799ab39bb9854ec77dc269e2a8f442e9ba96c58bed80a1d` |
| `apple-cametallayer.json` | https://developer.apple.com/tutorials/data/documentation/quartzcore/cametallayer.json | 2026-11-16 | `57b94d273e0dac40d5a9320119bd7e8d4f6e3c312d985fde2481cea41a5ed6e6` |
| `apple-edr.json` | https://developer.apple.com/tutorials/data/documentation/metal/displaying-hdr-content-in-a-metal-layer.json | 2026-11-16 | `3f9e1e414d96b84df7c591cbf4ac64a6ef5e2d6fb68ab6fda2ae423628f15d2c` |
| `apple-cadisplaylink.json` | https://developer.apple.com/tutorials/data/documentation/quartzcore/cadisplaylink.json | 2026-11-16 | `6e2836564ac0cbdefae5f0bdeeda16cda220f955bb05dc56c21504e499061f25` |
| `apple-osx-tech-overview-graphics.html` | https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/OSX_Technology_Overview/MediaLayer/MediaLayer.html | 2026-11-16 | `81ec215c1f8d3c41b28eca9002871180c9890aac6b121857014dc6be8ea6ea52` |
| `ms-dwm-overview.html` | https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview | 2026-11-16 | `9229d92ea699274248ecd03552411174a4e964c2fef9f6e9d49c3af76a038385` |
| `ms-dcomp-arch.html` | https://learn.microsoft.com/en-us/windows/win32/directcomp/architecture-and-components | 2026-11-16 | `57700772baeaad180e34cca4c01fb7ef8e7c9971b140a938aada8e7999782eff` |
| `ms-dxgi-flip.html` | https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-flip-model | 2026-11-16 | `a4818774c289198e0c44a1c6d4aa4b9738445756cf441c7c184fd122689537c7` |
| `ms-comp-swapchain.html` | https://learn.microsoft.com/en-us/windows/win32/comp_swapchain/comp-swapchain | 2026-11-16 | `048ea2825c30027511ab103cbe0043815911f7dec456e250bd8f4fbc8571b6f1` |
| `ms-hdr.html` | https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range | 2026-11-16 | `e563cee5a441c111dff9311bc57d1fc15b6b11935b5ad0e070cfe2b0264ce1f1` |
| `ms-hidpi.html` | https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows | 2026-11-16 | `e2ea7382bc5ebeab7715da65a9e1ca47af154cf38fda188b42f2157de7d01f8b` |
| `ms-dcomp-animation.html` | https://learn.microsoft.com/en-us/windows/win32/directcomp/animation | 2026-11-16 | `799805d5f6738179abb51268645b73dabf5142106bfaa6be125c5f3beac62a4b` |
| `wl-architecture.html` | https://wayland.freedesktop.org/architecture.html | 2026-11-16 | `1c6d070c5466b276bf2fd0543ed6c288c49a50e111ac5a84e5db1e68932b2b7b` |
| `fx-scenic-index.html` | https://fuchsia.dev/fuchsia-src/concepts/ui/scenic/index | 2026-11-16 | `1d2f7467a296f8b94f40ad14f53b3828b3f3055794dfb7baa029e8985fd936df` |
| `fx-flatland.fidl.b64` | https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/sdk/fidl/fuchsia.ui.composition/flatland.fidl?format=TEXT | 2026-11-16 | `b47b76499089ab83b50b075e2721c44dd9287b1aa097ee7e7756432159fa257a` |
| `fx-view-ref.html` | https://fuchsia.dev/fuchsia-src/development/graphics/scenic/concepts/view_ref | 2026-11-16 | `42bb6cf9f1d55dfb4e9e106eabd090f525d0e3d17d55cd4f1ea513fd6c0109b0` |
| `aosp-surfaceflinger.html` | https://source.android.com/docs/core/graphics/surfaceflinger-windowmanager | 2026-11-16 | `c16124c65b7efddde663ee6339f3ce055fa675f271c43c91ee36b60572cf7c31` |
| `aosp-hwc.html` | https://source.android.com/docs/core/graphics/hwc | 2026-11-16 | `d7a87ce6de884de07deebf08b0b3c570a96b68d8c2bcdf65b84bad495f67d45c` |
| `aosp-bufferqueue.html` | https://source.android.com/docs/core/graphics/arch-bq-gralloc | 2026-11-16 | `9ef68a492aad8c22fb9922c716a3f840e33034b9adabbff654679c3856518799` |
| `aosp-sync.html` | https://source.android.com/docs/core/graphics/sync | 2026-11-16 | `c229c1198876112833cbb045d8f56601680af477c77b5643742a1b0167b32f97` |
| `aosp-vsync.html` | https://source.android.com/docs/core/graphics/implement-vsync | 2026-11-16 | `4b5055158416c762a1d67d1cd7570f32306e2d0bedffd965edd2acef3efc75b8` |
| `p9-8half.html` | https://9p.io/sys/doc/8%BD/8%BD.html | 2026-11-16 | `e2ae28808d97b240b314a9099384a42807d1417edf53b5ad72ae956343c14875` |
| `p9-rio4.html` | https://9p.io/magic/man2html/4/rio | 2026-11-16 | `0f73d39c3244d39dfaad6c77429a283a91a20237c879edd2366104f99759a15d` |
| `p9-draw3.html` | https://9p.io/magic/man2html/3/draw | 2026-11-16 | `02fb5c60fe1bb6243033df373bfe151e7031e501655f3b6b7ae2b39158d9f9ff` |
| `p9-draw2.html` | https://9p.io/magic/man2html/2/draw | 2026-11-16 | `04fe6eb35a720946e48b87787bb8af90ed871bdf3ad5e9116efe7522a7d26703` |
| `arcan-about.html` | https://arcan-fe.com/about/ | 2026-11-16 | `b1e93b22cb98e10f07728802e3859cad113de19d5a2e9af4087f017592c76625` |
| `arcan-wiki-shmif.md` | https://raw.githubusercontent.com/wiki/letoram/arcan/Shmif.md | 2026-11-16 | `cf3cbf65fe1ee836ddbcfa330833320d932e553948056210137e3b1f87c50adc` |
| `cr-ozone.md.b64` | https://chromium.googlesource.com/chromium/src/+/HEAD/docs/ozone_overview.md?format=TEXT | 2026-11-16 | `2d96e6eb22641abaf3e72cd7ed9dc71b865765135ed485127bab60e83f83d677` |
| `cr-viz-readme.md.b64` | https://chromium.googlesource.com/chromium/src/+/HEAD/components/viz/README.md?format=TEXT | 2026-11-16 | `7d2172b8d7252a8d88052f5f1c253f9ff328a86eaf96f7437f229018d5042e51` |
| `cr-how-cc-works.md.b64` | https://chromium.googlesource.com/chromium/src/+/HEAD/docs/how_cc_works.md?format=TEXT | 2026-11-16 | `6db7f9f0dff3849ef7f262ce6472d8d84be38e9670f3913b7fc8c0863f4f47bb` |
| `gamescope-readme.md` | https://raw.githubusercontent.com/ValveSoftware/gamescope/master/README.md | 2026-11-16 | `032d311808b7cac4c63318981da9ea9776f62ae1be3476bab808ee813ca50913` |
| `gamescope-license` | https://raw.githubusercontent.com/ValveSoftware/gamescope/master/LICENSE | 2026-11-16 | `907dd845489cd09c25f18b6819f476805285e2adcad8c099e3506260023e9e5f` |
| `eros-ews.pdf` | https://www.usenix.org/legacy/event/sec04/tech/full_papers/shapiro/shapiro.pdf | 2026-11-16 | `18ab072a47846cf58fb2758898779b9e84c07b3b5b41e997ead6f5d710b6704a` |
| `nitpicker.pdf` | https://genode-labs.com/publications/nitpicker-secure-gui-2005.pdf | 2026-11-16 | `d7cc038bdcd99aa9c7b3b2d665ed941de08e13bffacb233a34e465a5e97eb5e6` |
| `qubes-gui.html` | https://doc.qubes-os.org/en/latest/developer/system/gui.html | 2026-11-16 | `60a7ed32c283ee319adcff3853dd5e4941030c5acec536dc080eabe75213e29f` |
| `kms-atomic.html` | https://docs.kernel.org/gpu/drm-kms.html | 2026-11-16 | `89d67c1d1b8d836e801ca63ce82e0a319785a1d76ef1fe834ca4e381b31be260` |
| `fx-flatland-concepts.html` | https://fuchsia.dev/fuchsia-src/concepts/ui/scenic/flatland | 2026-11-16 | `bd69d36e6a460234db7e6548f9d909b4f6656297a614052159b20d893e4b3822` |
| `qnx-screen-arch.html` | https://www.qnx.com/developers/docs/8.0/com.qnx.doc.screen/topic/manual/cscreen_about.html | 2026-11-16 | `bba95117bc27bec4c9bc4057c21e8893ea7a91b4cad3fd1b95a50f22cfc67c1c` |
| `wayland-protocols_1.50.orig.tar.xz` | https://deb.debian.org/debian/pool/main/w/wayland-protocols/wayland-protocols_1.50.orig.tar.xz | 2026-11-16 | `4460c20cfcf68b994a5ee206ed15fc19ad312f16c96075186e83b0e3f4aa48a5` |
| `wlroots_0.19.3.orig.tar.bz2` | https://deb.debian.org/debian/pool/main/w/wlroots/wlroots_0.19.3.orig.tar.bz2 | 2026-11-16 | `195b8be12ed3f39c09258cdac11705c6d2660db8f516a5e98e6c2cb3482b02cd` |
| `wayland_1.26.0.orig.tar.xz` | https://deb.debian.org/debian/pool/main/w/wayland/wayland_1.26.0.orig.tar.xz | 2026-11-16 | `64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3` |
| `apple-techtalk-10855.html` | https://developer.apple.com/videos/play/tech-talks/10855/ | 2026-11-16 | `1c6583c6b02dc38c8858d6339cfa3f06ec4cb34078aedba72fb49abc5ba67248` |
| `apple-techtalk-10857.html` | https://developer.apple.com/videos/play/tech-talks/10857/ | 2026-11-16 | `a12baf296f69a64bab61899c0e86c7957151166be72a45e4d7f9a00940db694b` |
| `haiku-AppServer.rst` | https://raw.githubusercontent.com/haiku/haiku/master/docs/develop/servers/app_server/AppServer.rst | 2026-11-16 | `c9fabbf7706daa29064754178937fe26e833732a65509cfe2a97dfcabfee30c9` |
| `haiku-graphics.rst` | https://raw.githubusercontent.com/haiku/haiku/master/docs/develop/servers/app_server/graphics.rst | 2026-11-16 | `4eb3604c78c97d0c70676c5609051e33d54fcd99c26a9686342ab3ad95c57201` |
| `haiku-License.md` | https://raw.githubusercontent.com/haiku/haiku/master/License.md | 2026-11-16 | `8dd7908c3fcf600b4d378d5f425eebe45663e0d0d8df1004e1317d4580ce7f10` |
| `switchbrew-vi.html` | https://switchbrew.org/wiki/Display_services | 2026-11-16 | `337e7e2c4556e089ab4457a28d977ad88779d5503842ea86a880af5317caced2` |
| `pike-concurrent-ws.pdf` | https://swtch.com/~rsc/thread/cws.pdf | 2026-11-16 | `227a16253efc12e6a226c73e03c772567dc9479aa8d2977e6687c6d0303dd7f1` |
| `efl-evas-rendering.html` | https://www.enlightenment.org/develop/legacy/program_guide/evas/rendering_concept_and_method_in_evas | 2026-11-16 | `a04f685da38a8fecb1ddfc578ef557bbaa74c18de2a3679044ff0e9e5eded2df` |
| `efl-evas-engines.html` | https://www.enlightenment.org/develop/legacy/program_guide/evas/evas_engines_concept | 2026-11-16 | `b4da0ffec848729ff8fe6b4915cf324b826ca598e4eb76fa2ed1a093c75c6b2e` |
| `efl-ecore-wayland.html` | https://www.enlightenment.org/about-wayland | 2026-11-16 | `2ec7b7405b65e083e0e4060196b7a912dc9bf84e8cecb1a7a13ffaacdf2e3f62` |

| File inside a tarball above | SHA-256 |
| --- | --- |
| `wayland-1.26.0/protocol/wayland.xml` | `cc860987e54f8d85c940e97fa1270c69b6e4ad31fbcf5a7f00107ce1157f5e07` |
| `wayland-protocols-1.50/COPYING` | `f1a2b233e8a9a71c40f4aa885be08a0842ac85bb8588703c1dd7e6e6502e3124` |
| `wayland-protocols-1.50/stable/linux-dmabuf/linux-dmabuf-v1.xml` | `d4feffb8c0a3dbdecfff141f4d65d88d91ff2b022cb343c988b73e3c358d9a76` |
| `wayland-protocols-1.50/stable/presentation-time/presentation-time.xml` | `0a9e4ee351aada90af9d165a540b86ad9d85f740ce87cf8c26490dd1ae701b5f` |
| `wayland-protocols-1.50/stable/viewporter/viewporter.xml` | `dcb12279a03746301fe490aaed4b38a403485a925abfce2ccfceb644e104fe71` |
| `wayland-protocols-1.50/staging/fractional-scale/fractional-scale-v1.xml` | `42945a10487cebe2f16c2f0284f263957d78325748409bfa8bcada385b65f86a` |
| `wayland-protocols-1.50/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml` | `68753c4a85a28659e3aa1fe0f138329a8bf3dff0b4789f4663a2c7fedbfecf2f` |
| `wayland-protocols-1.50/staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml` | `5ede41a56eced6aa635caa7ab2996066bff9fd211620dbf9f73aafab740bec71` |
| `wayland-protocols-1.50/staging/color-management/color-management-v1.xml` | `afa46ce15b135cce09cb46e0fbe9469914f5f9819cb938662c3cea370bd825ca` |
| `wayland-protocols-1.50/staging/commit-timing/commit-timing-v1.xml` | `ff3fcf31d13d44bad756a50fda663a43008bacbbd2bf8cba3a1bf5ffe7f54172` |
| `wayland-protocols-1.50/staging/fifo/fifo-v1.xml` | `0b6c31dfe6bca19b712745c9de7a4a398558cfa1087b1938e96fd3b10ffc1069` |
| `wayland-protocols-1.50/staging/tearing-control/tearing-control-v1.xml` | `846895b4a90ba1ddd75673cefc596480beef318f1694ec7dbca0fec54bb27043` |
| `wayland-protocols-1.50/staging/security-context/security-context-v1.xml` | `f4f8ba15ebd2df62db611b1de32e992f660a4aeeea83250cb88fa468da42ffcb` |
| `wlroots-0.19.3/LICENSE` | `35d427c043dcafe8893b9e7247348f599847c81d9a067703587c80707f3d58df` |
| `wlroots-0.19.3/README.md` | `f8cef13ec52a35a6a67eb3d6bba8953512a094f89b9cb1f6abd99e5b70cc2a58` |
| `wlroots-0.19.3/include/wlr/types/wlr_scene.h` | `48495d5b486adf80f487ed1d52e54deb49d0e2b6a25292771a3151c4c827b4bc` |
| `wlroots-0.19.3/include/wlr/types/wlr_damage_ring.h` | `22ec908c41c81e7b380a124691ba9c93eca7dbeaaa58e9b637364741f7817040` |
