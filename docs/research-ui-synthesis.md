# Research: the UI survey, synthesis

A point-in-time record that draws the five records of the erXos UI survey into one answer.

* Date: 2026-11-15. Host: Apple Silicon macOS development host. Nothing was run or measured here.
* Inputs, cited below by letter and section:
  * **C**: `research-ui-compositors.md` (display servers, compositors, window systems)
  * **R**: `research-ui-rendering.md` (rendering, images, fonts)
  * **T**: `research-ui-toolkits.md` (toolkits and application models)
  * **U**: `research-ui-ux-ideas.md` (interaction and conceptual ideas)
  * **S**: `research-ui-secure.md` (security of the GUI)
  * **K**: the Kerning section of `design-desktop-programs.md` on branch `kerning` (commits
    `7f9df6436`, `a6f1d4540`), which measured what R only argued; where K and R differ, K is used.
  * Baseline: `docs/design-display.md` and `docs/design-desktop-programs.md` on master `9abb9e91c`.
* No new external source was fetched. A statement here that no record and no design text read in
  this task supports is marked **unverified**. Sizes: **S** one module or one document section,
  **M** several modules or one new facet, **L** a subsystem with a design document of its own.
* One caution on the inputs. Each record was written against the erXos baseline, and all five
  conclude "already modern". A survey framed that way tends to confirm its baseline, so this
  synthesis leans on the places where the records name a gap, disagree, or skip a cost.

## 1. The answer

**Is erXos porting old desktop technology? In the plumbing, no. In what a person sees and does in
the first minute, partly yes. The approach should not change; the layer above the windows should
be added, and four dated habits should be dropped.**

What is not old, although its Plan 9 names make it look so:

* The compositor's shape (client-rendered buffers, one atomic `present` with damage, one present
  in flight, a pure composition plan that can hand buffers to hardware planes) is the shape
  Wayland, Fuchsia Flatland and QNX Screen converged on (C 1, C 4.1-4.5).
* The application model (pure `init`/`step`/`view`, a keyed diff, a tree that states meaning, not
  appearance) is what SwiftUI, Compose, Flutter, React and Elm converged on, and it drives three
  renderers, which none of those do (T "The question", T "Themes").
* Isolation is at parity with the research window systems (Nitpicker, EWS) and ahead of X11 and
  rio (S 1, S 5).
* Vector imaging in the client and bitmaps in the window server is where Apple went when it
  dropped Display PostScript (R 1); premultiplied Porter-Duff is the standard algebra (R 5).

What is old, candidly:

1. **Text setting.** Whole-pixel advances, no kerning, gamma-space coverage, one script, fixed
   sizes: the habits of 1990s bitmap fonts (R Summary). Kerning is in flight (K); the rest is not.
2. **No pixel density anywhere** (C 4.6, R 1). Every current system has a scale.
3. **The interaction layer is rio's.** A right-button menu, dragging a rectangle to place a
   window, no launcher, no palette, no "open this with that", no notifications, no overview
   (U Summary 2). This is the part a person will feel as old, and no amount of compositor
   correctness hides it.
4. **No motion at all** (design-desktop-programs "Motion"). Two records independently say this is
   where "slick like OS X" and the design pull apart (C 4.8, T "Animation models").
5. **The user-facing half of GUI security is missing**: no trusted identity, a clipboard shared by
   every grant that has it, no way to hand one file to an app (S 1).

And the other direction, equally candid: the mainstream's "21st century" rendering stack (GPU
scene graphs, Vello, Skia Graphite, HDR composition, layer trees with blur) is not available to
erXos. It needs Mesa and a Linux GPU driver on the Pi, or languages erXos does not admit, and
GPU-driven 2D is still research even where it runs (R 3, R (b), C 5(b)). erXos will not win on
pixels. Where it can be ahead of every shipping desktop is the combination no one else has: typed
presentations plus per-window file trees plus capabilities plus a live, inspectable process
system. The groundbreaking part of an erXos desktop is **find and act, identity and inspection**,
not a renderer. That is the change of emphasis this survey supports.

One risk the records understate: the CPU compositor sets a ceiling. No translucency, no blur and,
until measured, no smooth full-screen motion at 1080p on a Pi. If the desktop is to move, the
route on the Pi is HVS planes (a plane has position, scaling and alpha, design-display.md:3921),
not faster copies. Whether there are enough planes is **unverified** (section 6).

## 2. Verdict per layer

### 2.1 Compositor and window system

* **Current:** buffer model, damage, pacing, zero-copy pixel areas mapped read-only, display-drawn
  borders, composition as a pure plan (C 4.1-4.5, 4.9). Keep all of it. No record found a reason
  to adopt Wayland, a layer tree or GPU composition (C 5(b)).
* **Dated or missing:** no presentation timing in the `present` answer (C 4.4); no scale (C 4.6);
  tearing risk on the Pi firmware framebuffer (C 4.4); no motion (C 4.8); no embedding (C 4.10).
* **Weak point in C:** it names "steady cadence of the clock and stats" as the consumer of
  presentation timing, but nothing in the desktop animates, so that consumer does not exist. The
  real consumers are `tools/erx bench` ("Latency is UX") and any later transition. Still worth
  doing: it is a few fields.
* **Weak point in C:** "decide the scale model now so there is no unaware mode to carry" borrows
  Windows' lesson, but erXos owes no backward compatibility in development, and programs built on
  widget trees and theme tokens never state a pixel. Only draw-protocol clients do. The retrofit
  cost is therefore smaller than C says; the scale is still cheap to reserve (2.6).

### 2.2 Rendering and text

* **Current:** exact-area grayscale coverage, unhinted outlines, no LCD subpixel AA (what macOS
  converged on, R 8.2), no font parser on the target (R 8.1), PNG decoded in Erlang (R 7).
* **Dated:** spacing, gamma, scale, scripts, colour (R Summary).
* **R is superseded on kerning.** R said whole-pixel kerning "would mostly round to 0 or -1" and
  ranked first a fractional pen with each glyph rounded (R 8.4 level 1). K measured the opposite
  over 400 lines: that pen puts 19-28% of neighbour distances off by half a pixel to a pixel,
  which reads as uneven spacing; a whole-pixel pen with each kerned advance rounded keeps every
  distance within half a pixel but shifts tracking (`body` lines 5.2 px long, `title` 4.4 short).
  So R's level 1 is rejected, and the live choice is whole pixels now against glyph phases later
  (K open decision 3). R's "use FreeType's GPOS option or HarfBuzz" is also settled: the option
  is off by default and drops 529-568 pairs per font, and a Ruby reader of `GPOS` does the job
  with no new dependency (K, commit `7f9df6436`). HarfBuzz remains only as an optional test
  oracle (K open decision 2).
* **Weak point in R:** "have `erx_png` refuse PNGs whose `iCCP` or `gAMA` say otherwise" (R 6).
  Ordinary PNGs often carry such chunks (**unverified** here), so refusing would reject files
  people have. The rule should be: treat as sRGB, ignore the tag, and say so in the design.
* **Weak point in R:** NEON paths are ranked third with no measurement behind them (R (c)).
  Measure first; with damage rectangles the copy may never show in a profile.

### 2.3 Toolkit and application model

* **Current, and the strongest part of the system:** the tree, the diff, the placement in the
  application's own domain, the checked theme (T "Themes"). Keep. Do not adopt a foreign toolkit,
  signals, markup or constraint layout (T "Attractive, but not a fit").
* **Missing:** a reader of the tree other than the renderers (inspection, tests, assistive
  technology), text input beyond ASCII keys (no compose, no dead keys, no IME), motion, a hot
  reload workflow (T ranked list).
* **Weak point in T:** exposing a window's realised tree at an inspection path is called "small
  to medium" with no word on who may read it. The tree holds the window's text. S 6.8 says a
  reader of every window plus input injection "is the whole GUI". The path needs a stated access
  rule (the window's own principal and the person at the display), and secret inputs never
  appear in it. That is a design question, not a detail.
* **Unverified opportunity:** the browser renderer already receives the semantic tree, so the web
  client could map it to ARIA and give erXos a working screen reader, the host's, for almost
  nothing. `design-web.md` does not mention ARIA (grep, this task). Whether the mapping is as
  cheap as it looks is unverified.

### 2.4 Interaction and UX

* **Current:** per-window file trees and presentations are the two ideas of this field that
  history rates highest and the mainstream never shipped (U Summary 1).
* **Dated:** everything above the window (U Summary 2). See section 1, item 3.
* **Weak points in U:** it is the thinnest record on sources (much of it is Wikipedia, and its own
  unverified list is long, U (c)). Its case for tiling rests on Star's testers and Oberon's
  judgement from the 1980s plus niri's popularity, which it marks unverified. It ranks a command
  table and a plumber as two mechanisms, but a plumb rule is "content of this type goes to that
  command", which the typed command table already expresses. They are one design (2.6). And it
  proposes a strip policy that scrolls "by whole columns, without animation": a scroll of the
  whole strip is exactly the full-screen recomposite the CPU path is worst at, and an
  unanimated jump of every window may disorient (**unverified**).

### 2.5 Security of the GUI

* **Current:** isolation of pixels and input, focus only by the user's act, a reserved chord,
  decoding in the client's domain (S 2, S 5).
* **Missing:** identity, volitional clipboard, pick stability, a trusted prompt, file grant by
  designation, capture behind consent (S 5 matrix, bold cells).
* **Weak point in S and C:** both put a trusted label "on the frame". erXos windows have borders
  only and no title bar (design-desktop-programs, Decisions 4), and the border's colour already
  marks the current window (design-display.md:1943-1948). There is nowhere on the frame for a
  name, and the colour is taken. The label needs a place before it is "small" (2.6).
* **Weak point in S:** the 200 ms pick delay drops a real click on a window that has just
  appeared. S treats that as free. Pointer re-entry (S 6.1's alternative) costs nothing for a
  window the pointer was already in, and is the better first rule; touch needs the delay.
* **Phase 1 context:** development builds run trusted code only, and protection against hostile
  peers is recorded, not engineered (CLAUDE.md, Delivery). These items therefore belong in the
  target design now, where they are cheap to state, and in code when the display is next touched.

### 2.6 Where the records overlap or disagree, reconciled

| Topic | The records | One proposal |
| --- | --- | --- |
| Scale | C 4.6: fractional, in 120ths, decide now. R 1: integer 1 or 2, fractional later | Theme sizes become units; the window's `ctl` read carries a scale as a rational; the build ships 1x only. A 2x glyph and mask set is added when a panel needs it. Fractional scales wait for run-time rasterisation (R 8.9). The field is fractional-capable; the shipped sets are not |
| Motion | C 4.8: window transitions in `erx_screen`, measure first. T rank 4: widget transitions declared in `theme.txt`, decide first | One concept, a **transition**: declared in the theme, started only by a change, bounded in time, run by whoever owns the pixels (a renderer for a control, `erx_screen` for a window). G6 is reworded once: "nothing paints without a change or a transition a change started". Applications never animate. Build the widget half first (a button's press touches kilobytes); build the window half only on a Pi measurement or on HVS planes |
| Trusted identity | C rank 3: always show principal on the border. S 6.3: only when principals share a display; S 6.4: X-ray on the reserved chord | A principal mark on the border only when more than one principal is on screen (form to be designed: there is no title bar), and names in a display-drawn overlay on the reserved chord, which is also the frame for trusted prompts. Designed inside the login design (design-display decision 14), not beside it |
| Embedding | C rank 5: child windows by grant, medium. U rank 7: previewers in sub-spaces. S 7(b): no consumer, defer | Defer embedding. A preview needs none: the `files` session starts a sub-space with a read grant and a lent buffer, as the LVGL renderer already runs (README, "Display and input"), and draws the result itself. Embedding returns when a program hosts another principal's content |
| The tree as data | T ranks 1, 3, 6: inspection path, accessibility readiness, tree tests. U rank 3: "what is this?" | One inspection path for a window's realised tree, with an access rule (2.3). Its readers, in order: host tests (need no path at all), "what is this?" in the inspector, the browser's ARIA mapping, assistive technology |
| Commands | U ranks 1, 2 and 10: command table, plumber, palette rules | One "find and act" design: a table of typed commands, default routes from a presentation type to a command (the plumber's job), shown as a palette, a context menu and bindings; served as a file tree so `rc` can call any of it (U "Arcan and Durden") |
| Hot reload | T rank 2, U rank 9 | One development command; no disagreement |
| Chords and overlays | S 6.4 X-ray, U rank 3 "what is this?", U rank 8 overview, U rank 10 palette key | Too many chords for one desktop. One reserved chord opens the trusted overlay (identity, prompts); "what is this?" and the overview are entries of the palette and items of that overlay, not chords of their own |
| sRGB | C rank 8, R rank 6 | One sentence in design-display; the PNG rule of 2.2 |

## 3. The programme, ranked

"Consumer" is what breaks or stays worse without the item. "New?" says whether it is a new
mechanism that needs a design section before code. "Decide" points to section 5.

### Now: cheap, and it helps build or judge the basic desktop

| # | Proposal | Consumer | Size | New? | Decide | From |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Land kerning as designed on `kerning`: whole-pixel pen, `GPOS` pairs by the Ruby reader | uneven letter spacing at 11-15 px, the first defect a person sees | S, in flight | no | no | K, R 8.4 |
| 2 | One type session on the reference frames of clock and month: glyph phases against the whole-pixel pen, slight hinting on and off, a coverage curve with slight emboldening per role | text weight and tracking; three choices settled by eye in one sitting instead of three | S (a throwaway build of variants) | no | D1 | K dec. 3, R 5, R 8.3 |
| 3 | Hot reload of a program's pure core: a development command that loads the module and re-renders | every hour spent tuning the four desktop programs | S | no | no | T rank 2, U rank 9 |
| 4 | Presentation feedback in the `present` answer: time taken, refresh period, copied or direct, unknown reported as unknown | `tools/erx bench` cannot measure latency to the screen; transitions cannot be paced | S | no (fields) | no | C 4.4 |
| 5 | Measure the Pi: copy rate at 1080p, colour through a `k8` mask, the present round trip | every later choice about motion, NEON, strip scrolling, overview rests on these numbers | S | no | no | C 5(c), R (c) |
| 6 | State in design-display that buffers and the screen are sRGB, premultiplied where there is alpha; `erx_png` treats tagged files as sRGB by a declared rule | an unstated convention; a later colour-space tag has nothing to attach to | tiny | no | no | C 4.7, R 6 |
| 7 | Reserve the scale: theme sizes in units, a scale in the `ctl` read (1 today) | a 4K monitor or dense panel shows 11 px captions at half size; draw-protocol programs written now would hard-code pixels | S | no (a field) | D2 | C 4.6, R 1 |
| 8 | Tree test helper (find a node by kind, text or role; fire a hit; assert on the next tree), and a `name` property for nodes without text | desktop program tests poke at structure by position; an icon-only button has no name for a test, the browser or a reader | S | no | no | T ranks 3, 6 |
| 9 | Write the volitional clipboard rule and the pick rule (pointer re-entry; a delay for touch) into the target design; build with the next display change | an app principal reads whatever the person copies; a raised window takes a click (design-display residual at :4404) | S each | no | D3 | S 6.1, 6.2 |

### Next: after a probe, still inside the basic desktop

| # | Proposal | Consumer | Size | New? | Decide | From |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | Tear-free scanout on the Pi: two buffers swapped at blanking with a two-frame damage ring, or HVS planes | visible tearing on any large update on the board | S to M | no | no; needs probe P2 | C 4.4 |
| 11 | Widget transitions from the theme (press, selection, a section appearing), bounded, then idle | the desktop reads as static beside the "slick" brief | M | yes: a transition clock in each renderer, G6 reworded | D4 | T rank 4, C 4.8 |

### After the basic desktop works: each needs a design first

| # | Proposal | Consumer | Size | New? | Decide | From |
| --- | --- | --- | --- | --- | --- | --- |
| 12 | Find and act: typed command table, routes from presentation types, palette, context menu, bindings, a file tree for `rc` | no way to launch, find or act except a right-button menu and a shell; each program would grow its own command plumbing | L | yes | D5 | U ranks 1, 2, 10 |
| 13 | Trusted identity: principal mark on borders when principals mix; the reserved chord opens a display-drawn overlay with true names; trusted prompts in the same frame | an app's window is indistinguishable from the person's terminal; the chord opens nothing | S to M | yes, within the login design | D6 | S 6.3, 6.4, C 4.9 |
| 14 | A window's realised tree as an inspection path with an access rule; "what is this?" in the inspector | the system's most distinctive property (every pixel has a supervised owner) is invisible; no path for a reader or remote test | M | yes: an inspection path | D7 | T rank 1, U rank 3 |
| 15 | Powerbox: `files` in the person's session picks, the app receives a grant on that one file; a list of live grants with revoke | a packaged app that runs as its own principal cannot be given a file at all | M | yes: a cross-principal facet | no (design review) | S 6.5, 6.9 |
| 16 | Notification model: a notification is state at an inspection path; rate, summary and who may notify are session policy | the first app that wants attention invents its own way, and every later one copies it | M design, S build | yes | no | U rank 5 |
| 17 | Window transitions (open, close, hide) and a strip window policy, both only if P1 or P3 says the Pi can move a window smoothly | "slick" window behaviour; a non-overlapping option | M and S | transitions yes; a policy module no | D4, D8 | C 4.8, U rank 4 |
| 18 | Previews by a decoder in a sub-space of the `files` session | `files` previews text only; an untrusted decoder must not run in `files` | M | no (existing sub-space and lent buffer) | no | U rank 7 |

### On a named consumer, not before

| Proposal | The consumer that triggers it | From |
| --- | --- | --- |
| Text-input design (preedit and commit), compose and dead keys in the layout format | a multi-line text widget or a non-English keyboard; the design must precede the widget | T rank 5 |
| 2x glyph and mask sets; later a `fontsrv`-style font server | a dense panel; then user-chosen sizes, fractional scales or user fonts | R 1, R 8.9 |
| NEON kernels in `libmemdraw` | a profile from P1 that shows the scalar loops | R 3 |
| Screen capture behind a facet flag with an uncoverable indicator | the first on-target screenshot tool | S 6.6 |
| A second codec, Wuffs first | a photo viewer or a browser | R 7 |
| Shaping and bidi (SheenBidi, kb_text_shape) in a session-side service | a non-Latin script as a goal | R 8.5 |
| Embedded child windows; "not before T" on `present`; overview; live queries; drag and drop; accessibility as a declared facet; a sparse-strip path rasteriser | hosted foreign content; video; many windows; change reports from file servers; a program that needs it; assistive technology; run-time vector content | C 4.10, C 4.4, U ranks 6, 8, S 6.7, 6.8, R 4 |

Consistency with "a working system first": items 1-9 are small, touch no architecture, and several
make the basic desktop faster to build (3, 8) or to judge (2, 4, 5). Items 10-11 wait on a probe
or a decision. Nothing from item 12 down starts before stats, clock, month and files run on the
desktop; their designs can be written in parallel, because none blocks the basic desktop.

## 4. What not to do

* **Do not change the architecture.** No Wayland, no server-side layer tree, no widgets in the
  display, no GPU composition: each puts client state or a large C stack in the trusted display,
  or needs Mesa (C 5(b), T "not a fit").
* **Do not chase GPU renderers or GPU text** (Vello, Graphite, Slug, SDF): no driver for years,
  and slower than masks on a CPU (R 8.7, R (b)).
* **Do not adopt a foreign toolkit** (Flutter, Qt Quick, GTK, Slint, egui): excluded languages,
  GPU-first, and none carries a semantic tree three renderers can share (T "not a fit").
* **No LCD subpixel anti-aliasing**: Apple's reasons for dropping it apply more strongly to baked
  masks and scaled planes (R 8.2).
* **No fractional pen without glyph phases**: it trades even spacing for line length (K).
* **No HDR, full colour management, JPEG XL or AVIF now**: no consumer, SDR panels (C 4.7, R 6).
* **No zooming, 3D or physics desktop, compound documents, system-wide undo, wallpaper-derived
  colour**: they need GPU composition or failed for reasons isolation does not remove (U (b)).
* **No permanent trusted stripe, no prompts as the main consent mechanism**: the first costs
  screen on every screen; the second trains people to click through. Prefer designation (S 7(b)).
* **No pick delay as the only rule, and no PNG refusal by colour tag**: both cost ordinary use
  (2.5, 2.2).
* **Do not build a plumber and a command table as two mechanisms, or four overlay chords** (2.6).
* **Do not start find-and-act, identity or notifications code before the basic desktop works.**

## 5. Decisions needed

Each is stated as a question, with the options and a recommendation. The records' own
recommendations are cited; no advisor pass was run for this synthesis.

**D1. Text: whole-pixel pen for good, or glyph phases?** Options: (a) whole pixels, as K builds
now; (b) three or four phases per text glyph, a positioned-glyph draw message, text subfonts 3-4x
wider, an LVGL font change. Recommendation: K's own: land (a), then judge (b) by eye in the type
session (item 2) together with hinting and the coverage curve. R 8.4 level 1 is off the table.
A HarfBuzz test oracle (K decision 2): not now.

**D2. The scale model.** Options: (a) none until a dense panel exists; (b) reserve now: theme in
units, a rational scale in `ctl`, ship 1x; (c) build 2x sets now. Recommendation: (b). It is a
field and a renaming while there are four programs; (c) has no panel to check against. Open
inside (b): whether a 4K monitor on a Pi is in scope for the first desktop; if yes, (c) follows
soon.

**D3. Tighten the clipboard and the pick in the accepted design?** Options: (a) leave both as
recorded residuals; (b) clipboard reads and writes only from the current window within 500 ms of
a key or button down, and a press picks a window only after pointer re-entry (a delay on touch).
Recommendation: (b), stated in the design now. It changes accepted behaviour in one known way:
a configured domain that reads `/clipboard` with no window (design-display.md:4376) loses that
read. Sub-question: is that loss intended? S 7(c) thinks it may be right; nothing settles it.

**D4. Does erXos move?** Options: (a) keep "nothing animates"; (b) allow transitions as in 2.6,
widgets first, windows only on a measurement; (c) full compositor animation. Recommendation: (b).
It keeps the idle guarantee and keeps applications out of any frame loop. (c) fails on the CPU
arithmetic (C 4.8: a moving 800x600 window is about 115 MB/s). A caution against over-reading
both records: neither cites a source for "slick comes largely from transitions". Sharp type, no
tearing and immediate response come first and are prerequisites for motion anyway (items 1, 2,
4, 10).

**D5. Scope: is find-and-act part of the erXos desktop, and when?** Options: (a) not planned;
(b) design it after the basic desktop, as the desktop's main distinguishing feature; (c) start
the design now, in parallel. Recommendation: (c) for the design document only, (b) for code. A
dependent choice: the route rules' language (Plan 9's plumbing grammar, awklog or Datalog) needs
approval under the language rule; no recommendation without the design.

**D6. How is identity shown without a title bar?** Options: (a) names only in the reserved-chord
overlay and the menu; (b) also a principal mark on the border when principals mix (a second
hairline or corner tab, since border colour already means "current"); (c) a title bar. This is
partly a visual-direction choice. Recommendation: (a) first, (b) designed with the login work;
not (c).

**D7. Who may read a window's widget tree?** Options: (a) nobody outside the window's domain
(today); (b) the window's own principal and the person at the display, secret inputs excluded;
(c) any holder of an inspection grant. Recommendation: (b), written into the design before the
path exists.

**D8. Default window policy.** Options: (a) overlap (rio) stays the default; (b) a scrollable
strip becomes the default; (c) strip added as a third policy, overlap default. Recommendation:
(c), and only after P1. The earlier direction (a Finder-like browser, a look in the family of
OS X) presumes overlap, and U's evidence for tiling is old or unverified.

**D9. Imported generated C (Wuffs) and other new dependencies.** No decision is needed today: no
consumer exists for a second codec, a shaper or a font server. When JPEG is needed, the
recommendation is Wuffs' generated C as imported code under the "inherited code keeps its
languages" rule, after confirming it has a JPEG decoder (**unverified**, R 7).

## 6. Unverified points a decision rests on, and the cheapest probe

| # | Unverified point | Decides | Cheapest probe |
| --- | --- | --- | --- |
| P1 | Copy rate and mask-over-colour speed on a Pi 4 at 1080p; the present round trip | D4, D8, NEON, overview | `tools/erx bench` cells for a full-frame copy, an 800x600 move and a text fill, on the board by hand; then one throwaway window slide ("cheap hacks first") |
| P2 | Whether the Pi 4/5 firmware framebuffer can hold a second buffer and switch by virtual offset at blanking | item 10 | read the firmware mailbox property documentation at a pinned commit; then one hand test on the board with a full-screen alternating fill |
| P3 | How many HVS planes each board gives, and whether a plane's position and alpha can change every frame | D4 (window transitions for nearly nothing), item 10 | read the HVS documentation the display design already cites at :3921; a facts record if the only source is GPL driver code |
| P4 | Whether phases, slight hinting or a coverage curve are visible improvements for Inter at 11-15 px on a 1x panel | D1 | item 2: one build of variants, reference frames side by side, on a real panel as well as in QEMU |
| P5 | Whether the grant record `erx_winfs` holds carries the principal's name or only its template | D6 | read design-system.md and the `erx_winfs` grant record (S 7(c)) |
| P6 | Whether common PNGs carry `iCCP`/`gAMA` chunks often enough that refusing them hurts | item 6 | count chunks over the PNGs in the tree and a sample of ordinary files |
| P7 | Whether the web client can map the widget delta to ARIA cheaply | 2.3, item 14's reader order | a one-day prototype in the web client against the host's screen reader |
| P8 | Whether 9P file servers and the inspection protocol can report changes | live queries, notifications as state | read design-files.md and design-live.md for a change report; not checked by U |
| P9 | Cost of `view` plus `delta` on a large tree; whether `=:=` on identical terms is cheap in ERTS | lazy subtrees, layout caching (T ranks 7, 8) | a host benchmark on a 10,000-node tree; read `erts/emulator/beam/utils.c` |
| P10 | Whether an unanimated strip scroll is usable | D8 | the strip policy as a throwaway module on QEMU, tried by hand |
| P11 | Whether Wuffs ships a JPEG decoder; licenses of kb_text_shape and others R could not read | D9 | fetch the Wuffs release at a pinned tag and list its codecs, when the consumer appears |

Also unverified and worth a line each: how the pointer image is drawn (C 5(c) could not find it
in the display design); the claim that macOS's WindowServer runs the pipeline Apple's iOS talks
describe (C 5(c)); pixman's NEON paths (R 3); the mixed reception of Stage Manager and niri's
adoption (U (c)); Genode's current clipboard and window manager against the older write-ups S
read (S 7(c)).

## 7. In one paragraph

Keep the architecture: it is the modern one under old names. Fix the type (in flight), reserve a
scale, add timing to `present`, measure the Pi, and get hot reload, all now and all small. Decide
whether the desktop moves, and if so by bounded transitions declared in the theme. Then, once
stats, clock, month and files run, put the innovation where erXos has an advantage no shipping
desktop has: one typed command table with routes and a palette, identity a client cannot forge,
a file handed to an app by picking it, and a desktop on which any pixel can be asked what it is.

## 8. Decisions taken

On 2026-11-15 every recommendation of section 5 was accepted as written:
D1 the whole-pixel kerned pen now, glyph phases judged later in a type
session; D2 the scale reserved, 1x shipped; D3 the clipboard and pick rules
tightened, windowless configured domains losing clipboard reads; D4 bounded
transitions declared in the theme, widgets first, with G6 reworded; D5 the
find-and-act design started now, its code after the basic desktop; D6 the
reserved-chord overlay first; D7 a window's tree readable by its own
principal and the person at the display, secrets excluded; D8 overlapping
windows stay the default; D9 no new dependency before a consumer.
