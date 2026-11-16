# Research: 2D rendering, images, colour and fonts

A point-in-time research record for the erXos UI survey, domain
"rendering". Date: 2026-11-15. Host: Apple Silicon macOS. Every source was
fetched over HTTPS on that date into
`~/erxos-scratch/sources/ui-survey/rendering/` (plain-text copies under
`txt/`) and is listed with its URL and SHA-256 in [Sources](#sources).
Sources are cited as `[key]`, the key column of that table. A claim no
fetched source supports is marked **unverified**. No GPL or LGPL source
code was read; Cairo and AGG were read only through their documentation.

The question from the survey brief: is erXos porting old desktop technology
instead of the best 21st-century approach? This record answers it for
drawing pixels: vector against raster, renderers, compositing, colour,
image formats and type.

## Summary

The core of erXos's approach is where the field has ended up. The parts
that are dated need no GPU and no rewrite: each can be fixed in the build
step and in `libmemdraw`.

* **The architecture matches current practice.** Clients render into their
  own buffers and a compositor puts the buffers together. Apple chose that
  model when it dropped NeXT's Display PostScript for Mac OS X: the window
  server keeps window bitmaps and runs no PostScript, and vector drawing
  stays in client libraries [wiki-display-postscript]. The newest CPU
  renderer research, sparse strips [stampfl-thesis-2025], turns each path
  into run-length coverage plus solid spans, then composites them. Its
  authors present path caching as glyph caching made general
  [levien-rustweek-2025]. erXos's coverage masks (`k8` glyphs, corner
  discs, shadow strips) are a small hand-built case of the same idea.
* **The compositing algebra is the standard one.** Plan 9's draw has
  Porter and Duff's twelve operators on premultiplied alpha, which is what
  the W3C compositing specification states [porter-duff-1984]
  [w3c-compositing].
* **What is dated is text layout and colour, not rendering:**
  1. advances are whole pixels and there is no kerning; Inter 4.1's
     kerning lives only in `GPOS`, since its static TTFs have no `kern`
     table (Section 8.4);
  2. coverage is blended in gamma-encoded sRGB with no correction, so
     dark text on the light theme comes out heavier than designed and
     white text on the accent thinner [ft-text-rendering-general];
  3. there is no scale factor (HiDPI);
  4. text is Latin only, with no shaping or bidirectional text;
  5. nothing manages colour.

  These are habits of 1990s Plan 9 bitmap fonts. The first a user will
  notice is uneven letter spacing at 11-13 px, and all of them are fixable
  in the build step and one draw message.
* **Deliberately absent, and rightly so:** subpixel AA, server-side vector
  imaging, JIT rendering and a GPU renderer.
* **GPU-centred technology does not fit erXos today.** That covers Vello's
  compute renderer, Skia Graphite, Pathfinder, Rive, Spinel, Slug and
  SDF/MSDF text, some of it the real state of the art. The Pi 4 and 5 GPU
  has conformant Vulkan 1.3 and GLES 3.1, but only through Mesa and a
  Linux kernel driver [xdc2024-rpi] [mesa-v3d]. erXos has no GPU driver
  and is years from one.
* **The fast CPU renderers are in languages erXos does not admit.**
  Blend2D is C++ with a JIT compiler [blend2d-about]; Vello CPU and
  tiny-skia are Rust [vello-cpu-docsrs] [tiny-skia-README]; ThorVG is C++
  [thorvg-README]. erXos can take their ideas, not their code.

## What erXos has today

From `docs/design-display.md` and `docs/design-desktop-programs.md`
(master at `9abb9e91c`), and the `kerning` branch (`7bec5218c`):

* **Pixels.** Buffers are in Plan 9 channel formats (`x8r8g8b8`, `k8`, ...).
  A client draws into its window's buffer through the draw protocol, which
  9front's `libmemdraw` executes on the CPU in the session domain. The
  display domain composes windows by copying (draw's `S`, not `SoverD`),
  so no window shows through another (design-display.md:2281;
  design-desktop-programs.md, "Anti-aliasing, corners and depth").
* **Anti-aliasing is masks.** Text, icons, rounded corners, hairlines,
  shadows and graph lines are 8-bit coverage masks, drawn as a colour
  through a mask. `erx_mask`, a pure Erlang module, computes exact-area
  coverage for corners and graphs. No anti-aliased primitive is added to
  `libmemdraw`.
* **Type.** Inter 4.1 in six fixed roles from 11 to 48 px. A host build
  step (`Erx::Glyphs`, with `erx-raster` over FreeType 2.15.0) rasterises
  each glyph unhinted with FreeType's exact-area rasteriser. It writes Plan
  9 `k8` subfonts, LVGL's font form, and an Erlang module for the window
  menu. A Plan 9 `Fontchar` holds a one-byte `width`, the advance in whole
  pixels [plan9port-font7]. The `kerning` branch imports Inter's static
  TTFs; its diff adds no kerning code yet.
* **Images.** PNG only, decoded by `erx_png` and `erx_inflate` in Erlang in
  the session domain, with checked sizes and a fuzz target
  (design-display.md:3352, 4500).
* **Hardware.** virtio-gpu on QEMU and the HVS plane compositor on the Pi
  (design-display.md:3921). No 3D engine is used.

## 1. Resolution independence

**Display PostScript (NeXT, 1987).** NeXT and Adobe built Display
PostScript as the window system's imaging layer. Each window had its own
PostScript context in the server, and NeXT added window and event
operators to the language [wiki-display-postscript]. It bought one imaging
model for screen and printer, in device-independent coordinates. It cost an
interpreter in the window server running client programs, and Adobe's
licence fees.

**Quartz 2D and "Display PDF" (Mac OS X).** Apple kept the imaging model
and dropped the interpreter in the server. Quartz 2D is a client library
providing "PostScript-style imaging using the PDF rendering model". The
window server caches window graphics as bitmaps, and "there is no
PostScript present in the Mac OS X window server". Apple's reasons
included avoiding licence fees and serving QuickDraw code, which drew
bitmaps [wiki-display-postscript]. Quartz 2D uses the painter's model on a
"page" and generates PDF natively [quartz2d-overview]. GPU acceleration
reached the compositor (Quartz Extreme) well before 2D drawing: Quartz 2D
Extreme was not enabled by default "due to potential video redraw issues
or kernel panics" [wiki-quartz].

**Points instead of pixels (HiDPI).** Mac OS X sizes everything in points
and keeps the backing store at a scale factor, 2x on Retina. Points may be
fractional, and bitmaps need @2x versions to stay sharp
[apple-highres-explained]. Plan 9 from User Space is blunter: bitmap fonts
are pixel-doubled above 200 DPI, and `fontsrv` fonts are synthesised at
double size [plan9port-font7].

**Fit for erXos.** The lesson of the NeXT-to-Quartz history is that vector
imaging belongs in the client and the window server should handle bitmaps.
erXos already splits it that way. The draw protocol, a raster protocol
with a few shapes, is a sound middle ground. What erXos lacks is a **scale
factor**: the theme fixes sizes in pixels (`l` = 16 px, `caption` = 11 px)
and glyphs are rasterised at those sizes. The cheapest fix states theme
sizes in points, gives each display an integer scale (1 or 2), rasterises
each role subfont once per shipped scale (a 2x set has four times the
pixels), and lets `erx_mask` compute masks at the scale. Fractional scales
(1.25, 1.5) need a run-time rasteriser or a subfont set per scale; leave
them out until a panel needs them.

Size: medium. It touches the theme ABI, the glyph step and the window
manager's sizes, not the protocol.

## 2. Modern 2D renderers

| Renderer | Where it rasterises | Language, licence | Status per its own docs | Fit |
| --- | --- | --- | --- | --- |
| Skia (CPU raster pipeline; Ganesh, now Graphite, on GPU) | CPU or GPU | C++, BSD | Chrome's renderer. Graphite ships in Chrome on Dawn (WebGPU): multithreaded, depth testing for 2D, compute path rasterisation planned [skia-graphite-blog]. 370 KLOC, about 7 MLOC with dependencies, fast path clang-only [tiny-skia-README] | no: size, C++ |
| Vello (compute) | GPU compute | Rust, Apache-2.0/MIT | "experimental implementation for compute-capable GPUs" [vello-README] | no: GPU, Rust |
| Vello GPU (hybrid), Vello CPU | CPU geometry; GPU raster pipeline or SIMD CPU | Rust | Sparse strips. CPU is "the most mature choice" without a suitable GPU [vello-README]; u8 and f32 pipelines [vello-cpu-docsrs] | ideas only |
| Blend2D | CPU, JIT-compiled pipelines, multithreaded | C++ with AsmJit, zlib | Analytic rasteriser, curve-offset stroking, AArch64 JIT since 2024; a portable non-JIT pipeline "under active development" [blend2d-about] | ideas only |
| Pathfinder 3 | GPU (GL3, GLES3, Metal) | Rust, Apache/MIT | "under heavy development and is incomplete" [pathfinder-README] | no |
| Rive Renderer | GPU (Metal, Vulkan, D3D, GL) | C++ | built for Rive's animation runtime [rive-renderer-README] [rive-runtime-README] | no |
| ThorVG | CPU (AVX2/NEON), GPU backends | C++, MIT | "production-ready"; core about 170 KB; runs on ESP32; SVG and Lottie [thorvg-README] | no: C++ |
| NanoVG | OpenGL | C, zlib | "not actively maintained" [nanovg-README] | no |
| Cairo | CPU (pixman), others | C | 1.18.6 released 2026-09-20 [cairo-home]; LGPL/MPL **unverified** | no: licence, size |
| Anti-Grain Geometry | CPU, exact-coverage scanlines, gamma tables | C++ templates [agg-intro] | old; maintenance **unverified** | ideas only |
| tiny-skia | CPU | Rust, BSD | About 14 KLOC and 200 KiB. 20-100 % slower than Skia on x86-64, 100-300 % slower on ARM; "never will be" a Skia replacement [tiny-skia-README] | no: Rust |
| Spinel (Fuchsia) | GPU compute | C | **unverified**: README not found at the current Fuchsia path | no: GPU |

**What the numbers say for CPU rendering.** Stampfl's ETH Zürich thesis
[stampfl-thesis-2025] added Vello CPU, tiny-skia and raqote to the Blend2D
benchmark harness, beside Blend2D, Skia (CPU), Cairo, AGG and JUCE. The
runs were on an M1 Pro with NEON, single- and multi-threaded, at 512x600.
The results:
* Blend2D "is the clear winner" in nearly all configurations, credited to
  its JIT architecture and years of tuning;
* Vello CPU "outperforms nearly all other renderers, including Skia or
  Cairo, as the shape size increases", and is weaker on small shapes;
* Qt 6 and CoreGraphics were "very slow in many cases" and were dropped
  from the plots.

No source measured any of these renderers on a Pi 4 or Pi 5 CPU, so their
order there is **unverified**.

**Fit for erXos.** The desktop as designed needs no general vector
renderer, because every non-rectangular element is a mask computed once per
radius or per graph change. A renderer becomes necessary only with
run-time SVG icons, charts at many sizes, a PDF viewer or a browser. Even
then, erXos should not import one, since every competitive renderer is C++
or Rust. The better route is a small C17 path rasteriser that produces
`k8` masks for `libmemdraw` to composite. The sparse-strip design
(Section 4) is fully described in the thesis and short enough for a port
by redesign. `erx_mask` stays in Erlang for the fixed shapes: it is exact
and runs once per shape.

## 3. CPU against GPU, and what is fast on a Pi

**GPU-driven 2D is still research.** Raph Levien lists the limits of the
original Vello compute renderer: it needs a reasonably modern GPU and fails
on WebGL, its memory use is high and unpredictable, it is hard to integrate
with existing render passes, it has performance cliffs, and its compute
logic is complex [levien-rustweek-2025]. His newer design moves allocation and scheduling to the CPU and keeps only
per-pixel work on the GPU; fully GPU-driven rendering "is still a goal but
has many practical challenges". His 2020 compute design already "relies
heavily on GPU compute capabilities, so will not run on older hardware or
drivers" [skia-sparse-strips-intro].

**The Pi's GPU.** Mesa's drivers for V3D 4.2 (Pi 4) and V3D 7.1 (Pi 5)
are conformant for OpenGL ES 3.1 and, since August 2024, Vulkan 1.3.
Desktop OpenGL 3.1 is not fully conformant because hardware features are
missing [xdc2024-rpi]. Display goes through the VC4 kernel driver and
rendering through the V3D kernel module [mesa-v3d]. The hardware is
capable, but the software behind it is Mesa plus a Linux DRM driver.
erXos would need its own V3D shim, command submission and shader
compiler: years of work, and out of scope until long after the desktop
works.

**What is fast on a NEON CPU without a GPU.** These points are inferred
from the sources above; no Pi measurement was found.
* *Touch only covered pixels, and span-fill solid interiors.* Sparse
  strips and erXos's masks both do this; a solid interior "has only
  per-strip setup cost, no alpha" [levien-rustweek-2025].
* *Use 8-bit integer arithmetic in the inner loop.* Vello CPU's default u8
  pipeline is "for speed focused rendering", with f32 kept for precision
  [vello-cpu-docsrs]. A 128-bit NEON register holds sixteen u8 lanes.
  Stampfl's kernels target NEON, SSE4.2 and WASM SIMD, "all of which
  operate on 128-bit vector types" [stampfl-thesis-2025].
* *Cache rendered shapes.* erXos already does, with glyphs, corners and
  shadows.
* *Mind memory traffic.* A 1920x1080 `x8r8g8b8` frame is 8.3 MB
  (design-display.md:503), so a full copy 60 times a second moves about
  1 GB/s of reads and writes. If bandwidth is the Pi's scarce resource
  (**unverified**: no Pi bandwidth figure was read), damage rectangles and
  HVS planes matter more than rasteriser speed. erXos already presents
  only changed rectangles and gives top windows planes.
* *Skip the JIT.* Blend2D's JIT wins benchmarks, but erXos permits no
  writable-and-executable mapping and allows JIT only in marked images.
  Blend2D tests its JIT and portable pipelines for "pixel identical
  output" [blend2d-about], so the JIT is an optimisation, not part of the
  design.

**Fit.** CPU compositing on the Pi is right for erXos. The gap is that
`libmemdraw` is scalar C. NEON paths would cover its hot operations: the
rectangle fill, the `S` copy, a solid colour through a `k8` mask with
`SoverD` onto `x8r8g8b8`, and `SoverD` of an RGBA source. Each NEON path would be checked pixel for pixel against the scalar path, as
`erx_draw_ref` checks the operators. Measure the scalar path first with
`tools/erx bench`. pixman (MIT, used by Cairo and X) is known for NEON
paths of exactly these operations. That is **unverified** here: its
repository sat behind a bot check and its mirrors failed.

## 4. Coverage: exact area, supersampling and sparse strips

*Exact (analytic) coverage* computes the fraction of each edge pixel's area
inside the shape. FreeType's "smooth" rasteriser does it for line segments
and subdivides curves (design-desktop-programs.md, "Type"); AGG uses 256
coverage levels and contrasts them with 5-level renderers [agg-gamma];
Blend2D calls its rasteriser analytic [blend2d-about]. *Supersampling and
MSAA* take N samples per pixel: cheap on a GPU, N times the work on a CPU.
Slug dropped supersampling for tiny text because it "made a difference
only for text so small that it was barely readable anyway"
[slug-decade]. On a CPU, exact coverage with accumulation cells is the
established best. FreeType, AGG, Blend2D and Vello CPU all use it, and so
does font-rs (**unverified**: its article did not fetch).

**Sparse strips** [stampfl-thesis-2025] [levien-rustweek-2025] build their
mask in five steps: flatten the path to lines; bin the lines into tiles 4
or 8 pixels high; sort the tiles; merge tiles at the same coordinates,
computing exact coverage only where an edge crosses and recording in each
strip whether the gap to its left is inside (by winding); and emit commands
per wide tile. The result is a run-length shape: alpha runs at edges and solid spans
between. It can be composited at once or kept as a cache, and its memory
grows with edge length, not area. Work splits by object up to coarse
rasterisation, then by tile.

**Fit.** Sparse strips are the algorithm to copy if erXos ever needs a
C17 path rasteriser. The output is a compact run-form mask that a NEON
loop composites. Each stage is a pure list-to-list function, which suits
the functional-core rule and host tests against `erx_mask`'s exact areas.
How small a single-threaded version without the GPU half would be needs a
prototype to settle (**unverified**).

## 5. Compositing: Porter-Duff, premultiplied alpha and linear light

**Porter-Duff.** The 1984 paper made the case for "four-channel pictures",
with a matte computed like the colour channels, and defined the
compositing operators [porter-duff-1984]. Premultiplied alpha makes `over`
one multiply-add per channel and keeps filtering and scaling correct. The
W3C specification writes simple alpha compositing as `co = cs + cb x (1 -
as)` on premultiplied values, and adds blend modes and isolated groups
[w3c-compositing]. Plan 9's draw has the twelve operators, and
`erx_draw_ref` checks `libmemdraw`'s arithmetic for them on premultiplied
sources (design-display.md:1090, 4466-4491). **erXos is current here.**

**Linear light.** That arithmetic is correct only on values proportional to
light, and sRGB values are gamma-encoded. FreeType says it plainly: "only a
pixel value of about 186 results in 50% brightness - 128 ends up too dark
on both bright and dark backgrounds". It goes on: "the correct way" is to
blend "in linear space and then apply gamma correction". It also notes
that no toolkit does this by default on X11, though Qt 5 and Skia can
[ft-text-rendering-general]. Blending in gamma space has three effects:
* dark-on-light edges get darker, so text looks bolder;
* light-on-dark edges get darker, so text looks thinner;
* gradients and scaled images darken in the midtones (a known effect whose
  primary reference needed JavaScript and was not read).

AGG's cheaper answer is a 256-entry curve applied to coverage before
blending, tuned by eye. It warns that the right curve depends on content:
small glyphs want sharper curves than large shapes [agg-gamma].

**For erXos.** `libmemdraw` blends in gamma-encoded space with no
correction. Since the theme is light only, with a known small set of text
colours on known grounds, the cheapest correction is precise enough: **bake
a coverage curve into each role's `k8` subfont at build time**, chosen for
that role's usual polarity (dark on light, or white on the accent).
Nothing changes at run time. Full linear-light compositing in `libmemdraw`
would cost a lookup to linear and back per channel per edge pixel, or
16-bit intermediates. It would also change arithmetic that `erx_draw_ref`
pins against Plan 9's. Record it as a later choice.

## 6. Colour management, wide gamut and HDR

* **Platforms.** Quartz 2D lists colour management among its features
  [quartz2d-overview]. The Wayland colour-management protocol lets a
  client tag a surface with an image description, either an ICC profile
  (v2/v4) or parametric (primaries, transfer function, HDR metadata). The
  compositor converts each surface for each output and advertises a
  preferred description per surface [wayland-color-management-v1].
* **Libraries.** Little CMS is a widely used ICC colour engine
  [lcms-home]; its licence is **unverified** here. skcms is Skia's ICC
  library; its README here says only how to build it [skcms-README], so
  its size and licence are **unverified**.
* **Formats.** The PNG third edition, a W3C Recommendation of 24 June
  2025, adds animated PNG, `cICP` (colour-space code points) and `mDCV`
  mastering-display metadata used with PQ HDR [png3].

**Fit.** erXos's displays are sRGB panels and its content is a fixed sRGB
theme plus PNGs, so colour management buys nothing until wide-gamut panels
or photographs arrive. Two cheap steps are worth taking now: state in the
design that every channel descriptor means sRGB-encoded values,
premultiplied where there is alpha; and have `erx_png` refuse, or convert
by one declared rule, PNGs whose `cICP`, `iCCP` or `gAMA` say otherwise.
Wayland's design is the one to copy later: a surface carries a colour-space
tag, and one converter in the compositor serves every window. In erXos
that tag would be an attribute in the window's `ctl`.

## 7. Image codecs

| Format | What it buys | Decoder options | Fit |
| --- | --- | --- | --- |
| PNG | lossless, alpha, now APNG and HDR tags [png3] | erXos's `erx_png` in Erlang (memory-safe, fuzzed). Wuffs: C transpiled from a memory-safe language, MIT/Apache-2.0, 1.2-2.7x faster than libpng by its own figures; it "cannot make any syscalls" and cannot "allocate or free memory" [wuffs-README]. libspng: C, BSD-2, on OSS-Fuzz [libspng-README] | keep `erx_png`; Wuffs if PNG shows up in a profile |
| JPEG | photographs; the web's format | libjpeg-turbo (BSD-style, SIMD) [libjpeg-turbo-README]; Wuffs JPEG (**unverified**: its README names no JPEG decoder) | for a photo viewer or browser; Wuffs first |
| QOI | lossless; 14-byte header; one-page spec; explicit "sRGB with linear alpha" or "all channels linear" flag [qoi-spec] | write it: a page of Erlang or C | only as an internal fast lossless form, when PNG is too slow |
| JPEG XL | lossless and lossy; ISO/IEC 18181; lossless JPEG recompression with byte-exact reconstruction [libjxl-README]; its community site claims lossless files 46 % smaller than PNG [jpegxl-info] | libjxl: C++, BSD-3 [libjxl-README] | not now: C++, large |
| AVIF | AV1 stills in HEIF [avif-spec] | dav1d (C with ARMv8 assembly, "very liberal license") [dav1d-README], plus a HEIF parser | not now: large attack surface |
| stb_image, stb_truetype | tiny public-domain C [stb-README] | README: security fixes "may take significant time" | no: untrusted input |

**Fit.** PNG is the right choice, and decoding it in Erlang is the most
erXos-like decision in the stack: a memory-safe decoder of untrusted bytes,
with no C to fuzz. For the next codec, Wuffs suits erXos's security stance
better than any hand-written C. Its generated C has no ambient authority
and never allocates, so it is a per-byte primitive in CLAUDE.md's sense.
The catch is that Wuffs is its own language. erXos would import the
transpiled C as inherited code, which needs a decision under the language
rule. JPEG XL and AVIF can wait behind the same image seam.

## 8. Fonts

### 8.1 Rasterisers

FreeType is the reference rasteriser outside Apple and Windows, and erXos
runs it on the host only. Its `smooth` exact-area rasteriser with unhinted
loading is what current desktops use. libschrift is a small C99 TrueType
rasteriser [libschrift-README] whose licence is **unverified**.
stb_truetype is public domain but not for untrusted fonts [stb-README].
erXos's choice, FreeType at build time and nothing at run time, is the
simplest and safest available: no font parser runs on the target, so no
untrusted font ever reaches C. It costs fixed sizes, scripts and fonts.
Section 8.9 shows how to lift that.

### 8.2 Philosophies, subpixel anti-aliasing and why it went away

Apple and Microsoft "have always disagreed" [joel-font-smoothing]. Apple
preserves the typeface's design "even at the cost of a little bit of
blurriness". Microsoft hammers letters "into pixel boundaries to prevent
blur", at the cost of text "lighter than it would be in print".
DirectWrite moved Microsoft partway towards Apple by adding subpixel
positioning, which gives fractional glyph origins and even spacing
[directwrite-intro]. Its modes include `NATURAL` (anti-aliasing in x
only), `NATURAL_SYMMETRIC` (both axes) and `OUTLINE`, which bypasses the
rasteriser [dwrite-rendering-mode].

**Subpixel anti-aliasing (ClearType, LCD filtering)** treats each
pixel's red, green and blue stripes as three horizontal samples. FreeType
documents a ClearType-style mode with a 5-tap colour-balancing filter, and
"Harmony" for any fixed subpixel layout [ft-lcd-rendering]. macOS 10.14
Mojave turned it off by default. Peter Ammon, a former macOS engineer,
gave the reasons: it "requires threading physical pixel geometry up through
multiple graphics layers", it "multiplies your glyph caches: glyph *
subpixel offset", and it "requires knowing your foreground and background
colors at render time, which is an unnatural requirement when you want to
do GPU-accelerated compositing" [mjtsai-mojave-subpixel]. Users on 1x
displays noticed the loss [apple-mojave-whatsnew-hn].

**Fit: do not adopt subpixel AA.** Ammon's reasons apply to erXos with more
force. Glyphs are baked at build time, while subpixel order belongs to the
panel and the HVS scales planes (design-display.md:3921). Masks are drawn
over unknown grounds, and the window menu and kiosks reuse the same
coverage. Grayscale exact coverage, which macOS converged on, is what
erXos does.

### 8.3 Hinting, stem darkening and gamma

FreeType documents its own policy [ft-text-rendering-general]
[ft-subpixel-hinting]:
* **Slight hinting** snaps glyphs to the grid vertically only, "just like
  Adobe's proprietary font engine and in a certain way also Microsoft's
  ClearType/DirectWrite", which keeps horizontal spacing true.
* **The v40 TrueType interpreter** (FreeType 2.7) gives DirectWrite-like
  results by ignoring horizontal hinting: "There actually is no subpixel
  hinting going on here."
* **Stem darkening** pairs with gamma correction. Correct linear blending
  makes thin unhinted text "thin out", so "Mac OS X and Adobe's proprietary
  font engine implement a counter-measure: stem darkening at smaller
  sizes". It should "only be enabled when doing gamma correction".
  FreeType offers it for CFF fonts and the auto-hinter, not for TrueType's
  native hinting.

**Fit.** erXos renders unhinted, matching macOS and practice at high DPI.
At 1x on the 11-13 px roles, slight hinting would sharpen x-heights and
baselines without breaking spacing. It is one flag in `erx-raster`
(`FT_LOAD_TARGET_LIGHT`) and keeps output a pure function of its inputs;
compare both on a 1x panel before choosing. Gamma and darkening go with the
coverage curve of Section 5. If the build bakes a gamma-correcting curve,
it should also embolden small sizes slightly. FreeType's darkener does not
apply to unhinted TrueType, so the step would embolden the outline itself
(`FT_Outline_Embolden`, **unverified**: not read). If no curve is baked,
gamma-space blending already darkens dark-on-light text, which is partly
why unhinted Inter will likely look acceptable on the light theme. White
labels on the teal accent are where it will look thin.

### 8.4 Subpixel positioning and kerning: the most valuable change

This section bears directly on the kerning table erXos is adding.

**What the sources say.** AGG's study of text rasterisation shows that
rounding advances to whole pixels "accumulates a huge error along the text
line": ten "i"s of 2.6 px, hinted to 3 px, take 30 px where the typography
says 26. Horizontal positions in 1/256 px with vertical-only hinting stay
sharp and even, and a third of a pixel "is good enough for accurate kerning
and sharp text at the same time" [agg-font-rasterization]. DirectWrite adopted subpixel positioning for the same reason
[directwrite-intro].

**What erXos has.** A Plan 9 subfont stores each advance as a one-byte
whole-pixel `width` [plan9port-font7], and the `s` message advances by
those widths. Kerning added on top in whole pixels would mostly round to 0
or -1 at 11-15 px, which is where spacing errors show most.

**Where Inter's kerning is.** A script read the table directory of the
imported `Inter-Regular.ttf`: `GDEF GPOS GSUB OS/2 cmap cvt fpgm gasp glyf
head hhea hmtx loca maxp name post prep`. **There is no `kern` table**,
and `GPOS` is 83,724 bytes. The OpenType specification says `kern` cannot
serve CFF fonts, which use `GPOS` [ot-kern]. FreeType's `FT_Get_Kerning`
reads `GPOS` pairs only "with `TT_CONFIG_OPTION_GPOS_KERNING` enabled", and
only "the basic, pair-wise kerning feature"; it returns zero for
right-to-left pairs that use placement offsets [ft-glyph-retrieval].

Two points are open. Whether the option is on by default is
**unverified**; erXos compiles FreeType itself, so it can set the option.
Kerning that Inter expresses through class-based or contextual lookups
beyond plain pairs would be missed, and how much of it there is is also
**unverified**. A build-time HarfBuzz pass that shapes every pair of the
theme's characters would capture all of it. HarfBuzz is "Old MIT"
[harfbuzz-COPYING] and would run as a host tool, as FreeType does.

**Recommendation.** Keep the layout's pen position in fractions of a pixel
(FreeType's 1/64, or 1/4 px). Keep the subfont's whole-pixel `width`, and
generate beside it a per-role table of exact advances and pair adjustments
(from `GPOS`, through FreeType with the option or HarfBuzz on the host).
Then choose a level:
1. **Round per glyph.** Accumulate exact advances plus kerning and round
   each glyph's origin. No subfont grows, and line length is exact. A glyph
   may land up to half a pixel from its ideal place. Small change: the
   generator, the table reader, and text layout in `erx_font`, the Erlang
   renderer and LVGL's font form.
2. **Phase glyphs.** Also rasterise 3 or 4 horizontal phases of each
   text-role glyph and pick the phase from the pen's fraction. The
   text-role subfonts grow 3-4x (the display role need not), and spacing
   matches DirectWrite and macOS. This is Ammon's "glyph * subpixel
   offset" multiplication, paid once at build time and in image size.

Because `s` advances by subfont widths, kerned text needs a draw message
with explicit positions or a run of single-glyph draws. The draw protocol
is erXos's own, so add the message and leave `s` unchanged.

### 8.5 Shaping, bidi and complex scripts

A shaping engine is needed because `cmap` lookup is not enough: fonts
carry ligatures and contextual forms, and many scripts need "complex
joining, reordering, and positioning" [harfbuzz-why]. The options:
* **HarfBuzz**, the reference, "Old MIT" [harfbuzz-COPYING]; on the target
  it would be new C++.
* **kb_text_shape.h**, a single-header C library [kb-README]. It does
  ICU-like segmentation (direction, line, script, word, grapheme),
  "Harfbuzz-like text shaping for OpenType fonts" and font coverage
  checks. Its examples show Arabic, Hindi, Khmer and Myanmar. It does no
  rasterisation and no paragraph layout. The README says
  "permissively-licensed"; the exact licence is **unverified**.
* **SheenBidi**, a C implementation of the Unicode Bidirectional
  Algorithm under Apache-2.0 [sheenbidi-README] [uax9].

**Fit.** The theme covers Latin only and design-desktop-programs.md defers
other scripts. Pre-rasterised glyphs can serve fixed strings (menus,
labels) in complex scripts if they are shaped at build time. User text
cannot be handled that way, because shaping depends on the whole string. A
terminal or editor showing Arabic or Devanagari needs a shaper at run
time. When that becomes a goal:
* SheenBidi and kb_text_shape are small, permissive C, fit to sit in a
  session-side text service;
* shaping is a pure function from (font, string, features) to (glyphs,
  positions), suited to a functional core with a fuzz target in the
  session domain, never the display domain.

Size: large.

### 8.6 Variable fonts

A variable font carries continuous design axes such as weight, each a 16.16
range; a coordinate array picks an instance [ot-otvaroverview]. erXos
already gets the useful result, any weight it wants, by naming instances in
the theme and rasterising at build time. Inter's variable font would let
the theme pick weights (and optical sizes, if Inter 4.1 has that axis,
**unverified**) freely. Small, optional.

### 8.7 Distance fields, Slug and GPU outline rendering

* **SDF (Valve, 2007):** a distance field in a low-resolution texture,
  thresholded on the GPU, for scalable glyphs with cheap outlines and
  shadows [valve-sdf-2007].
* **MSDF (Chlumsky):** three channels keep corners sharp where one channel
  rounds them; the core is "bare C++" [msdfgen-README].
* **Slug (Lengyel, JCGT 2017):** anti-aliased glyphs drawn straight from
  Bezier outlines in a pixel shader, "without the use of any precomputed
  texture images or distance fields", correct "under any affine or
  projective transformation" [slug-jcgt-2017]. Its patent (US 10,373,352)
  was dedicated to the public domain on 2026-03-17, and reference shaders
  were released under MIT [slug-decade].
* **Glyph atlases:** Levien argues a sparse per-size cache costs O(n)
  memory against O(n^2) for a dense atlas, with no 2D atlas allocation
  [levien-rustweek-2025]. A Plan 9 subfont is a dense atlas strip per role.

**Fit.** All of these solve text under arbitrary transforms on a GPU (3D,
zoom, rotation). erXos draws axis-aligned text at a few sizes on a CPU.
There a pre-rasterised mask is the cheapest per pixel (one lookup) and the
best looking (exact area at the target size). A distance field sampled on a
CPU costs more and looks worse at 11-15 px. Slug matters only if erXos
ever drives the V3D. A dense subfont strip is fine at a few hundred glyphs
per role.

### 8.8 Colour fonts and emoji

`COLR` v0 stacks coloured glyph layers. `COLR` v1 adds gradients, affine
transforms, blend modes and variation [ot-colr]. Noto Color Emoji is
OFL-1.1 and uses `CBDT/CBLC` bitmaps [noto-emoji-README]. Emoji are images,
not masks, so they need an RGBA subfont drawn with `SoverD`. The subfont's
glyph image is an ordinary Plan 9 image with any channel
[plan9port-font7], so the build step could rasterise a fixed emoji set
into an RGBA subfont with no new mechanism at run time. Levien calls emoji
the "superpower" that CPU rendering gets for free [levien-rustweek-2025].
Low priority.

### 8.9 Fonts as a file tree: Plan 9's own answer

plan9port's `fontsrv` serves the host's vector fonts as a Plan 9 file tree
[plan9port-fontsrv4]: one directory per font, holding size directories
such as `12` (bitmap) and `12a` (anti-aliased grey), each with a `font`
file and 32-character subfonts (`x0000.bit`, ...). Sizes are synthesised on
lookup: "looking up 19a will synthesize the 19-point anti-aliased size".
`openfont` starts it on demand for `/mnt/font` paths.

**Fit.** This is the erXos-native way to lift the fixed-size limit. Under
CLAUDE.md, "bytes someone keeps ... is a file tree its owner serves and the
reader mounts". A font-server domain would run FreeType (later a shaper)
on the target and serve subfonts and kerning tables per size and scale.
`erx_font` would read them exactly as it reads build-time subfonts, so
nothing above it changes. The costs: FreeType becomes an on-target C parser
and a permanent dependency, needing a fuzz target and a domain holding
nothing else, and user-supplied fonts become untrusted input. Do it when user-chosen sizes, fractional scales or user-installed fonts
become goals. Until then the build step computes the same function with no
attack surface.

## (a) Ranked list worth adopting or prototyping

1. **Fractional pen positions plus `GPOS` kerning from the build step**
   (8.4, level 1). Fixes the most visible defect. *Small*: the glyph step,
   a generated table per role, layout in three renderers, and one draw
   message for positioned glyphs.
2. **A coverage curve and slight emboldening baked per role for the light
   theme** (5, 8.3). Text weight then matches the design on both
   polarities at no run-time cost. *Small*: the glyph step only, judged on
   screenshots.
3. **NEON paths for `libmemdraw`'s hot operations, after a scalar
   measurement** (3). Compositing cost on the Pi is this domain's one
   performance risk. *Medium*: three or four C17 kernels checked against
   scalar, plus a bench.
4. **Phase-rasterised text glyphs** (8.4, level 2). Brings spacing up to
   DirectWrite and macOS quality. *Small to medium*: text-role subfonts
   grow 3-4x.
5. **A scale factor (points) with 2x subfonts and masks** (1). Needed
   before any HiDPI panel. *Medium*: theme ABI, glyph step, window manager
   sizes.
6. **State sRGB and premultiplication as facts; have `erx_png` refuse or
   convert other colour tags** (6). *Tiny*.
7. **Slight (vertical-only) hinting for small roles at 1x**, if
   screenshots favour it (8.3). *Tiny*: one load flag.
8. **A `fontsrv`-style font server as a file tree** (8.9), when sizes,
   scales or user fonts demand it. *Medium to large*.
9. **A C17 sparse-strip path rasteriser producing `k8` masks** (2, 4),
   when run-time vector content (SVG icons, charts, PDF) becomes a goal.
   *Medium*.
10. **Wuffs for the next codec (JPEG)** (7), after a decision on importing
    transpiled C. *Small to medium*.
11. **SheenBidi and kb_text_shape in a session-side text service** (8.5),
    when a non-Latin script is a goal. *Large*.

## (b) Attractive but not a fit

* **GPU renderers (Vello compute, Graphite, Pathfinder, Rive, Spinel) and
  GPU text (Slug, SDF, MSDF):** need a GPU driver erXos will not have for
  years, and on a CPU are slower than masks.
* **Blend2D:** fastest measured, but C++ with a JIT that needs a JIT-marked
  image for little desktop gain. **Vello CPU, tiny-skia:** Rust; take the
  sparse-strip algorithm, not the code. **ThorVG, Skia, AGG, msdfgen, and
  HarfBuzz on the target:** C++ (HarfBuzz stays usable as a host tool).
  **Cairo:** large, older, LGPL/MPL (**unverified**). **NanoVG:** OpenGL,
  unmaintained.
* **Subpixel (LCD) anti-aliasing:** Apple's reasons for dropping it apply
  even more to baked masks and HVS-scaled planes.
* **Display PostScript or PDF in the display server:** history moved the
  interpreter out of the window server, and one there would break G9, "the
  display domain interprets nothing a client drew".
* **JPEG XL, AVIF, full colour management, HDR and linear-light
  compositing now:** no consumer yet. **stb_image and stb_truetype on the
  target:** not meant for untrusted input.

## (c) Open questions and unverified points

* **Pi speed.** How fast are `libmemdraw`'s mask-over-colour and copy on
  Pi 4 and Pi 5 CPUs, and how much would NEON gain? No Pi figures for any
  renderer were found; measure with `tools/erx bench`.
* **Inter's kerning.** How much of it is plain pair positioning that
  `FT_Get_Kerning` returns with `TT_CONFIG_OPTION_GPOS_KERNING`, and how
  much needs HarfBuzz? Is the option on by default in FreeType 2.15.0? A
  build-time comparison over the theme's characters settles both.
* **The positioned-glyph message.** Should it carry an explicit x per
  glyph, or advances plus kerning deltas? Should LVGL's font form get the
  same table? A design question for design-display.md.
* **Wuffs.** Importing transpiled C from a language erXos does not write
  needs a decision, and whether Wuffs has a production JPEG decoder is not
  stated in its README.
* **Not checked from primary sources:** the licences of Cairo, AGG, Little
  CMS, skcms, libschrift and kb_text_shape; pixman's NEON paths; Spinel's
  design; font-rs; `FT_Outline_Embolden`; Inter 4.1's axes.
* **Hinting.** Whether slight hinting beats unhinted output for Inter at
  11-13 px on a 1x Pi panel is settled by screenshots, not sources.

## Sources

All fetched 2026-11-15; SHA-256 is of the bytes as fetched. A `.b64` file
is googlesource's base64 form, decoded beside it. The key
`skia-sparse-strips-intro` is Raph Levien's blog post "Fast 2D rendering
on GPU" (2020), saved under that name. Fetches that failed or returned
bot-check or JavaScript-only pages were dropped and are not cited: the
Vello sparse-strips READMEs, Spinel's README, color.org, Phoronix, Medium
(font-rs), pixman, and Eric Brasseur's gamma page.

| Key | URL | SHA-256 |
| --- | --- | --- |
| `vello-README` | <https://raw.githubusercontent.com/linebender/vello/main/README.md> | `71c190bf810ec4a7314c9d6f1428c719d21a135bb990d926f610ec33a9d9138b` |
| `vello-cpu-docsrs` | <https://docs.rs/vello_cpu/latest/vello_cpu/> | `fe84aa86d67c0e1c620c2d940c340fc59a3c40db8fca571cedf3042f81578db7` |
| `levien-rustweek-2025` | <https://docs.google.com/presentation/d/1f_vKBJMaD68ifBO2j83lBly9Zdk-2bsvj_DIHXxvcuk/htmlpresent> | `3e32e3fe1e3e0ee8815c06dd5af595b7ef07da486e776626d4a9f34dc94f9745` |
| `skia-graphite-blog` | <https://blog.chromium.org/2025/07/introducing-skia-graphite-chromes.html> | `bad44bfcb57c5ad73edf7fe8b1f0cf15fefc2621d2e7911da56511ed9212730b` |
| `pathfinder-README` | <https://raw.githubusercontent.com/servo/pathfinder/main/README.md> | `2ac6afba2c5f0ed3f9edf7ab00fca7bdffb52ebdb739de029d6e072699017d39` |
| `blend2d-about` | <https://blend2d.com/about.html> | `e94d55b5d8817d4d4659b36c58a93305cb9f2f82c28705eac1f20453f07c7dc5` |
| `rive-runtime-README` | <https://raw.githubusercontent.com/rive-app/rive-runtime/main/README.md> | `c1bd3fba3bf8ace66346e1819160dddb327d1403f339bcb9beafd7b0dc3d3c1f` |
| `rive-renderer-README` | <https://raw.githubusercontent.com/rive-app/rive-runtime/main/renderer/README.md> | `d3c6790fd6d522c5a0b7ce843ddd2eee193b1939e2525d53e2d3439ef7a30348` |
| `thorvg-README` | <https://raw.githubusercontent.com/thorvg/thorvg/main/README.md> | `2365c7f5aaf249f0663744be279434bcb02f9c3c871693d7b6192c872299e727` |
| `nanovg-README` | <https://raw.githubusercontent.com/memononen/nanovg/master/README.md> | `c2182eb9bdfa293bd4aead3ee9514e032b3dfed63000b6cc756691e026179c0f` |
| `cairo-home` | <https://www.cairographics.org/> | `4158b5fa23e0205925d45b87a990c75cdad2502f3a43e2ed65037457d22ecfdd` |
| `agg-intro` | <https://agg.sourceforge.net/antigrain.com/doc/introduction/introduction.agdoc.html> | `e2933f4c3b3ad35a03eff8acf7b596b013d16d5d5fe2773bc36fb968218bf9fa` |
| `agg-font-rasterization` | <https://agg.sourceforge.net/antigrain.com/research/font_rasterization/index.html> | `9eef46a64e5e375bdb59afd76b9dd723acc7a64304dca780eff2558b01c681ca` |
| `agg-gamma` | <https://agg.sourceforge.net/antigrain.com/research/gamma_correction/index.html> | `8374a31a64791163712d82648e3b7802239b86184eb4db16801a514c14748a42` |
| `tiny-skia-README` | <https://raw.githubusercontent.com/linebender/tiny-skia/main/README.md> | `e904cae91a7954e538c4b3d9d357d1ece2ddddba9bf0ca5bbfb340925396ef29` |
| `quartz2d-overview` | <https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_overview/dq_overview.html> | `b8a34476207a4aee30a386371996f6abfec5f7a5a594c0c4f4935fde269c15c4` |
| `apple-highres-explained` | <https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Explained/Explained.html> | `90399f0abfb9b6ed3fb242c3803fb0698266c128e65da45aaf5406d59e4b2697` |
| `wiki-display-postscript` | <https://en.wikipedia.org/wiki/Display_PostScript> | `6a99b9831aef31882eb67448afea1d0e19682e109454bff9365b52d3aca6071d` |
| `wiki-quartz` | <https://en.wikipedia.org/wiki/Quartz_(graphics_layer)> | `9f1ff92661bb68b5fd50e3cd9ddddb84c6402991863f044de00999e7556aee4b` |
| `porter-duff-1984` | <https://keithp.com/~keithp/porterduff/p253-porter.pdf> | `e468d83dbb0f946f23546a6e19d2097e21a793421b6629b2d39e77d64f69d003` |
| `w3c-compositing` | <https://www.w3.org/TR/compositing-1/> | `0fb91119308e706a5e4df368a91fa3b43cd5fe8cd8f192418b2df0a30ba8a62b` |
| `skcms-README` | <https://skia.googlesource.com/skcms/+/refs/heads/main/README.md?format=TEXT> | `e7736edfa291789c8111025db415bb1d57605a20998491f905758277a9129826` |
| `lcms-home` | <https://www.littlecms.com/> | `a751c42c6b360e93d593341c032049bf7f3f5657c5ee14fd58680559e7f120cd` |
| `png3` | <https://www.w3.org/TR/png-3/> | `a3ac82bb9eb8664b93961a2a9ff6def3d70e3a9f63d92721143c1f391d04edec` |
| `qoi-spec` | <https://qoiformat.org/qoi-specification.pdf> | `e9389266f56db4e1614810f2a0003e85e11a5dd3c5e46b7ccc09bcfee8b17a42` |
| `libjxl-README` | <https://raw.githubusercontent.com/libjxl/libjxl/main/README.md> | `2e71db87654b1152b394a71160f54f08705d3464421ff03e47f3b550cb28b42d` |
| `jpegxl-info` | <https://jpegxl.info/> | `8aee35fd785f4beaed46e0a7b939a26053ac332ba4c20d34afa39ff93cd2ffd0` |
| `avif-spec` | <https://aomediacodec.github.io/av1-avif/> | `1978ae12bb4906403c5f4207289eef71aafb7fb77a9dd6234f4978ad5b9846f5` |
| `libjpeg-turbo-README` | <https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/README.md> | `e1e42b12d37ab9b55ac574fd418018817478e6ab86a8133bc6d4c8db3c5bb6e2` |
| `wuffs-README` | <https://raw.githubusercontent.com/google/wuffs/main/README.md> | `e94f5436b8fb272ca1898f00120c2e6d383953dc198e7b4fa79871f199643319` |
| `libspng-README` | <https://raw.githubusercontent.com/randy408/libspng/master/README.md> | `e776a476c13d31336689765326733f492644e83e5c5a85f5728f8240d35fc3f1` |
| `stb-README` | <https://raw.githubusercontent.com/nothings/stb/master/README.md> | `210e04de525ce52ff7e84e2b06e700a5ca40fe638ceec475a927fb6ede186c97` |
| `ft-text-rendering-general` | <https://freetype.org/freetype2/docs/hinting/text-rendering-general.html> | `ef42c819889f2fa1b4c2e08a0038e80a83d3a9ce0e434401f7b25d47da010ec0` |
| `ft-subpixel-hinting` | <https://freetype.org/freetype2/docs/hinting/subpixel-hinting.html> | `4c8642695c3daf263d8e0cfb8358925d568bb55d09ee08950ded3bacc1f10df1` |
| `ft-lcd-rendering` | <https://freetype.org/freetype2/docs/reference/ft2-lcd_rendering.html> | `7dc6e8bf2640aa608be03b47694efe52bc6dc6080a29c83947b0fa88284ae12e` |
| `directwrite-intro` | <https://learn.microsoft.com/en-us/windows/win32/directwrite/introducing-directwrite> | `4720a0fd9042fa14e2ec17b532d66e91da000654fd8493794d6cc8adb5b75adb` |
| `dwrite-rendering-mode` | <https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ne-dwrite-dwrite_rendering_mode> | `ae251ad1c03f03a71d03a5434097b91cef224747516b8dcf5da40dc045b0eb4c` |
| `joel-font-smoothing` | <https://www.joelonsoftware.com/2007/06/12/font-smoothing-anti-aliasing-and-sub-pixel-rendering/> | `c7f92798ed78f1f883b1ab7d5fbd006eb83bf6f09d12c26a0d60c0bf61ce8ba8` |
| `mjtsai-mojave-subpixel` | <https://mjtsai.com/blog/?p=22090> | `af0dd3aa9f541d4cda8a72ddc10d888078874c62e112f11a26fe5cd77055b83e` |
| `harfbuzz-why` | <https://harfbuzz.github.io/why-do-i-need-a-shaping-engine.html> | `e8dd478a13f47185098aa03718ad46440ed9fa72366c2fac2f6e872c188ea43c` |
| `harfbuzz-COPYING` | <https://raw.githubusercontent.com/harfbuzz/harfbuzz/main/COPYING> | `ba8f810f2455c2f08e2d56bb49b72f37fcf68f1f4fade38977cfd7372050ad64` |
| `kb-README` | <https://raw.githubusercontent.com/JimmyLefevre/kb/main/README.md> | `91fbfc07371c4a85b63d56345454ef3cee2376cc1a77ff922366286d915c19d3` |
| `sheenbidi-README` | <https://raw.githubusercontent.com/Tehreer/SheenBidi/master/README.md> | `34376a693954902b6b587d29d008d07e8ac29e4e553e8319d2f1d5ab7e3ae1c8` |
| `uax9` | <https://www.unicode.org/reports/tr9/> | `3c281b38800bad85b16bf3a169b8cb693d8a2dbceb60903feb26e68a2659ee8a` |
| `msdfgen-README` | <https://raw.githubusercontent.com/Chlumsky/msdfgen/master/README.md> | `483c15e4d1963619c9a552ee7b564a3744a211e9a3beaee3808928e2423544a6` |
| `valve-sdf-2007` | <https://steamcdn-a.akamaihd.net/apps/valve/2007/SIGGRAPH2007_AlphaTestedMagnification.pdf> | `1b6253164f146c8a2fd2d21b77b0540e5160e53157596b8591e5bfb1cb50d4b6` |
| `slug-jcgt-2017` | <https://jcgt.org/published/0006/02/02/paper.pdf> | `6f6d693e6ed8ec3c788d475cbe961a89f41c990f4635f2af018a65fcf40a57b2` |
| `slug-decade` | <https://terathon.com/blog/decade-slug.html> | `2c385308d1116421636021ac1bd0e115efca55dee99b7f7b96df179b2df72cbc` |
| `ot-otvaroverview` | <https://learn.microsoft.com/en-us/typography/opentype/spec/otvaroverview> | `718c6d005101ba222479ec423cde4f644792dde5cb9045da523a9a67a560def9` |
| `ot-colr` | <https://learn.microsoft.com/en-us/typography/opentype/spec/colr> | `2c8f71fa4d5c7c87035273f8cd36eb881484c02bb07064edbae380c0a98fa6a8` |
| `ot-kern` | <https://learn.microsoft.com/en-us/typography/opentype/spec/kern> | `4362eaa6d5672136ca82964f6c23398bba69791a3e9e70b6861ac58e20590418` |
| `plan9port-font7` | <https://9fans.github.io/plan9port/man/man7/font.html> | `e303af9815db03667593833b3753d99e6b21c5528456a3b6cb8fba21e892b0a6` |
| `libschrift-README` | <https://raw.githubusercontent.com/tomolt/libschrift/master/README.md> | `52a060eb5c18f0858ce3366565c14c4aef2e6455a9b8a3712c0c5d93a89112c8` |
| `mesa-v3d` | <https://docs.mesa3d.org/drivers/v3d.html> | `be6bf6fe5679b8a376f82e1eb0cfb3a9b9cd6463fe038e606eac6f1b3cd04709` |
| `xdc2024-rpi` | <https://indico.freedesktop.org/event/6/contributions/300/attachments/236/317/XDC2024-RPI-Slides.pdf> | `bae471663a077032a6454f238dfa674cc52451ed5032e92cdedfab34136b5375` |
| `noto-emoji-README` | <https://raw.githubusercontent.com/googlefonts/noto-emoji/main/README.md> | `1ae0343308fe8c7e6e679cd12688df7586aa87df286be19d8bb2969b8abcac64` |
| `stampfl-thesis-2025` | <https://raw.githubusercontent.com/LaurenzV/master-thesis/main/main.pdf> | `27900b4f4db5aa3d69db7eca279417aa1bbcca44da503568a3332680f9aa54b4` |
| `skia-sparse-strips-intro` | <https://raphlinus.github.io/rust/graphics/gpu/2020/06/13/fast-2d-rendering.html> | `78e4f6b17d346ab635bd0d6e6514bdfc60086322397083c1943adfcbda0e8e00` |
| `dav1d-README` | <https://raw.githubusercontent.com/videolan/dav1d/master/README.md> | `392f5b97fef0590409a372fac6dc6dc99284f0e05b189131973812fca3f0c1b9` |
| `wayland-color-management-v1` | <https://wayland.app/protocols/color-management-v1> | `e5a1bb1e3d47dacb79076d651c64b55805825349ae58bfe02b020f52d3d44b01` |
| `apple-mojave-whatsnew-hn` | <https://news.ycombinator.com/item?id=17476873> | `cca02239ec483e4a9a080d382883de0948e8b3b2252834efb4c226d1cf55e46e` |
| `plan9port-fontsrv4` | <https://9fans.github.io/plan9port/man/man4/fontsrv.html> | `c757694e1d0578b357b96e191d10152f10ad2904aafae2dffcb5a1e634d93409` |
| `ft-glyph-retrieval` | <https://freetype.org/freetype2/docs/reference/ft2-glyph_retrieval.html> | `0c0b2065fb2ca65d1b6262179da2d9fd9e6614ae67b743bd13798bffdbe8bfab` |
