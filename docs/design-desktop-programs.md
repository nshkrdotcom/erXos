# Desktop programs: stats, clock, month and files

erXos's desktop has four programs of its own besides the terminal:
**stats**, live graphs of the machine's own numbers; **clock**, the time
of day; **month**, a calendar; and **files**, a browser of the
session's namespace. Each is an Erlang application of the person's
session that opens one window with the widget toolkit, reads only what
the session already reads (the inspector, the file protocol and the
time page) and shows every value as it came, unknown included. The four
share one look, a theme that every renderer and the window manager's
decorations take from one declaration, so the desktop looks like one
system.

Plan 9 shaped how they work: everything they show is a file, a `/proc`
path or a typed record, read through the session's own namespace and
facets, and nothing they do needs a channel the shell does not have.
Plan 9 did not shape how they look. They look modern and quiet:
anti-aliased type on a 4-pixel grid, a restrained light palette,
rounded controls and soft depth where they help, and an icon set
drawn for erXos.

The architecture is [design.md](design.md); windows, the widget
toolkit, its renderers, presentations and the terminal are
[design-display.md](design-display.md); the inspector, `/proc` and
attributed text are [design-live.md](design-live.md); namespaces and the
file protocol are [design-files.md](design-files.md); the wall clock is
[design-time.md](design-time.md); commands are
[design-shell.md](design-shell.md); apps and packages are
[design-apps.md](design-apps.md) and
[design-packaging.md](design-packaging.md).

Decisions every reader of this document needs:

* **A program is a pure core and a thin shell.** Each program's state,
  its view and its answer to every input are one pure module,
  `erx_desk_<name>_core`: `init`, `step(Input, State) -> {State,
  [Effect]}` and `view(State) -> tree()`. The process around it performs
  the effects (an inspector query, a directory listing, a timer, a
  clipboard write) and hands the toolkit `view(State)` after every step.
  The toolkit diffs; the program never says what changed.
* **One toolkit for all four.** Every program is a widget tree handed to
  `erx_ui`, drawn by the Erlang renderer on the desktop and by LVGL or
  the browser where those are the medium. None opens a draw connection.
  The widget format gains what the four need and states as meaning: a
  `graph` kind, `icon`, `role`, `area` and `current` properties, icons
  on a `list` and activation of a list item ([Widget format
  additions](#widget-format-additions)).
* **Shipped in the session's release, started by commands.** The four
  are the application `erx_desk` in the desktop session's release,
  beside `erx_term`. The Erlang commands `stats`, `clock`, `month` and
  `files` each open one window and return. They are not packages: an app
  runs as its own principal, with its own inspect scope and its own
  files, and these programs must see the person's
  ([Shipping](#shipping-and-starting)).
* **They read what the session reads, and nothing else.** stats reads
  the inspector through the session's inspect facet with `erx:inspect/2`;
  files reads the namespace through `file`; clock and month read the
  wall clock from the time page through `os:system_time/1` and its state
  from the inspector's `time` path. No program holds a capability,
  facet or channel of its own.
* **Never fabricate.** A value whose status is not `ok` is shown with
  its status: a graph leaves a gap for every sample it does not have, a
  number shows `unknown`, `unsupported`, `partial` or `timeout` as its
  token, and a clock that is not set says so instead of showing the time
  since boot as a date.
* **Untrusted text is data until a renderer draws it.** File names,
  file contents and every text a domain reported reach a widget only as
  a text property, which every renderer draws through the line escape
  (design-display's G5). A core keeps the exact bytes it acts on, a
  file's raw name among them, beside the text it shows, and acts by
  position, never by the shown text.
* **Every non-rectangular pixel is a coverage mask.** Anti-aliased text,
  icons, rounded corners, soft shadows and graph lines are 8-bit
  coverage masks composed through `libmemdraw`'s one draw, which already
  reads a grey mask as coverage. Glyphs and icons are rasterised once
  by a host step, through FreeType run as a host build tool; corners,
  shadows and graph lines are computed by `erx_mask`, a pure Erlang
  module that the renderer and the window manager's menu share. No
  native primitive is added to `erx_memdraw`.
* **Padding is inside the node.** A node's `pad` is space between its
  edge and its content, as LVGL's and CSS's padding are, so a padded
  button's background and hit area cover its padding.
* **One theme, generated.** `abi/theme.txt` declares the type scale,
  the spacing grid, the radii, the shadows, the palette, and the fonts
  and icons to rasterise. Its generator writes the
  Erlang module both sides of the display take, the C header `erx-lvgl`
  builds with and the web client's constants, and checks every
  contrast ratio the palette must meet.

## Context

### What the programs are for

The four answer questions a person at an erXos desktop asks, in a window
instead of a command line:

* **stats**: what the machine is doing. erXos's own numbers are unlike
  a UNIX system's: CPU time is granted to groups, so the question is
  how much of its grant each domain uses; memory is carved into budgets,
  so the question is how much of its budget each domain spends; and
  domains talk by frames on connections, so message rates between
  domains are a first-class load. stats draws one row per domain
  against its grant and budget.
* **clock** and **month**: the time and the date. On the stopgap the
  wall clock may not be set: until a sample or a real-time clock sets
  it, wall time is uptime counted from 1970-01-01
  ([design-time.md](design-time.md#what-proc-shows), `state`).
* **files**: what is in the session's namespace, folder by folder, with
  each item's kind, size and date, and a preview of text. The
  FreeBSD-behaving commands `ls`, `cp`, `mv`, `rm` and `mkdir` change
  files ([design-shell.md](design-shell.md#commands)); files shows and
  opens them.

The look matters as much as the function: the desktop must look sharp
and current, with type and spacing chosen as a system, not drawn with a
bitmap font on a flat grey field. It must also look like erXos and like
nothing else: its palette, its icons and its proportions are its own,
and it takes no other system's assets, names or icons.

### What the tree holds

* **The widget toolkit** is `erlang/apps/erx_ui/src`: `erx_ui` exports
  `open/1`, `tree/2` and `close/1` (`erx_ui.erl:27`); `erx_ui_server`,
  `erx_ui_model`, the renderer behaviour and the LVGL renderer
  `erx_ui_lvgl` with its core exist. The Erlang renderer
  `erx_ui_erlang` and the browser renderer are not in the tree; the
  Erlang renderer is part 7 of track D
  ([plan.md](plan.md#track-d-windows-widgets-and-the-web)).
* **The widget format** `abi/formats/ui.txt` declares fourteen kinds,
  `column`, `row`, `grid`, `scroll`, `stack`, `label`, `button`,
  `checkbox`, `slider`, `input`, `list`, `image`, `spacer` and `graph`, and
  four enumerations, `ui_align`, `ui_role`, `ui_area` and `ui_icon`. It
  carries a text's role, a container's area, icons, a button's `current`
  and a list's `on_submit`, as [Widget format
  additions](#widget-format-additions) describes.
* **Drawing.** `display/libmemdraw` is 9front's `libmemdraw`. Its draw
  reads a mask without an alpha channel as grey and uses the grey as
  coverage (`draw.c:488-494`, `greymaskread` at `draw.c:1065`), so a
  fill through an 8-bit mask is an anti-aliased fill. Its lines,
  ellipses, arcs and polygons are not anti-aliased. `erx_memdraw`
  exports `alloc/5`, `draw/8`, `load/3` and the shapes
  (`erlang/apps/erx_memdraw/src/erx_memdraw.erl:19`). `erx_draw`,
  `erx_font`, `erx_draw_conn`, the overlapping policy `erx_wm_rio`, its
  menu and `erx_term` are part 6's and not in the tree.
* **Fonts.** The tree holds no font. design-display's dependency rows
  name plan9port's `fixed` bitmap fonts for the terminal and the first
  widgets, and the anti-aliased fonts these programs bring
  ([design-display.md](design-display.md#dependencies)). LVGL compiles in Montserrat 14 under OFL-1.1,
  which the release check admits as font data only
  (`tools/lib/erx/license_expression.rb:24-36`, `FONT_DATA_ONLY`).
* **LVGL** 9.6.0 (`display/lvgl/ORIGIN.md`, commit `80ca777e`) draws
  rounded corners, shadows and anti-aliased arcs in software: its
  configuration sets `LV_DRAW_SW_COMPLEX` to `LV_USE_DRAW_SW` when
  `lv_conf.h` leaves it unset
  (`include/lvgl/config/lv_conf_internal.h:674-684`; the template says
  it "adds rounded corners, shadows, skewed lines and arcs",
  `lv_conf_template.h:281-284`), and it has a chart widget, on by
  default (`lv_conf_internal.h:2670-2680`), which skips a point whose
  value is `LV_CHART_POINT_NONE` (`src/widgets/chart/lv_chart.c:424`).
  erXos's `display/lvgl/lv_conf.h` sets no option that turns these off,
  and sets theme transitions to zero time (`lv_conf.h:41`).
* **The inspector.** The schema `abi/inspection.txt` declares, among
  others, a group's `used_ns` and `capacity_mcpu`, a budget's `used`,
  `guarantee` and `cap`, a domain's `name`, `state`, `processes` and
  `run_queue`, and a CPU's `idle_time` and `ready_threads`, with the
  paths `domains *domain_id group` and `domains *domain_id budget`. It
  does not declare the `[domains, Id, connections]` records with
  their frame counts, which design-live lists
  ([design-live.md](design-live.md#paths)), nor the `time` path with its
  `state`, which design-time adds
  ([design-time.md](design-time.md#what-proc-shows)). design-live's
  Erlang interface is `erx:inspect(Path, Options)`
  ([design-live.md](design-live.md#erlang-in-every-domain)); the tree's
  `erx` module does not export it, and the query is
  `erx_inspector:inspect/1,2` (`erlang/apps/erx/src/erx_inspector.erl:57`).
* **Stock OTP** gives what the cores compute with: `file:list_dir_all/1`
  and `file:read_link_info/1` (`otp/lib/kernel/src/file.erl:1066`,
  `:821`), and `calendar:day_of_the_week/1`,
  `calendar:last_day_of_the_month/2`, `calendar:iso_week_number/1` and
  `calendar:system_time_to_universal_time/2`
  (`otp/lib/stdlib/src/calendar.erl:297`, `:410`, `:378`, `:727`).
* **Names.** FreeBSD builds `ncal`, which installs `cal`, and
  `calendar`, its reminder service (`usr.bin/Makefile`, lines 95 and
  189, at FreeBSD commit `95719d8a895b`). It has no `stats`, `clock`,
  `month` or `files` in `usr.bin`; `bin`, `sbin` and `usr.sbin` were not
  checked.

## Requirements

* **DP-R1.** stats shows, live, each visible domain's CPU use against
  its group's grant, its memory against its budget, and its message
  rate, and the machine's CPU, memory and scheduler load, read only
  through the session's inspect facet; a domain outside the facet's
  scope is neither shown nor counted.
* **DP-R2.** clock shows the time and date from the wall clock, and
  says when the wall clock is not set or its state is unknown.
* **DP-R3.** month shows any month of the Gregorian calendar with ISO
  week numbers, marks today only when the wall clock is trusted, and
  moves by month and to today.
* **DP-R4.** files lists any directory of the session's namespace
  within a bound on the memory a listing takes,
  navigates into folders, back and forward, shows an item's kind, size,
  date and mode, previews text, and copies a path to the clipboard when
  the session's display grant carries it. It acts only through the
  session's own grants.
* **DP-R5.** No value is shown as other than it came: every status but
  `ok` is visible as its token, and a missing sample is a gap.
* **DP-R6.** Untrusted text, file names and contents and every text a
  domain reported, reaches the screen only through a renderer's line
  escape, and never decides which file or domain an action reaches.
* **DP-R7.** The four share one visual language, declared once, which
  the window manager's decorations and the display's background take
  too.
* **DP-R8.** An idle program costs nothing: no program and no renderer
  redraws without a change, and only stats, clock and month wake on a
  timer, stats once per sampling period, clock once a minute and month
  once a day while it marks a today.
* **DP-R9.** Each program's decisions are a pure core with host tests;
  each failure a test guards has a seeded fault that makes it fail.

## The construction

A program is three parts:

```text
 erx_desk_sup (simple_one_for_one, temporary children)
   |
   +-- erx_desk_window: one process per open window
         state:  the core's State, the toolkit's Window, the tag of each
                 request in flight
         loop:   Input --> erx_desk_<name>_core:step/2 --> {State, Effects}
                 perform Effects (each reply comes back as an Input)
                 erx_ui:tree(Window, erx_desk_<name>_core:view(State))
   |
   +-- a worker per request in flight, linked: one inspector query, one
       listing, one page's file information, one file read; it sends
       its answer and ends
```

`erx_desk_window` is one module for all four; what differs is the core
it is started with. Inputs are the toolkit's `{ui, Window, Term,
Detail}`, a worker's answer tagged with the request it answers, and a
timer's tick. Effects form a closed set:

| Effect | Performed as | Answer, as an input |
| --- | --- | --- |
| `{inspect, Tag, Path}` | a worker calls `erx:inspect(Path, #{timeout => 1000})` | `{inspected, Tag, Result}` |
| `{list, Tag, Dir}` | a worker, its heap capped ([Bounds](#bounds)), calls `file:list_dir_all/1` | `{listed, Tag, Result}`, each name a binary |
| `{stat, Tag, Dir, Names}` | a worker calls `file:read_link_info/2` with `[{time, posix}]` on each of at most 256 names | `{stated, Tag, Results}`, one result per name, in order |
| `{read, Tag, Path, Bytes}` | a worker opens the file and reads at most `Bytes` | `{read, Tag, Result}`, `file:read/2`'s result; a folder answers `{error, eisdir}` |
| `{tick_after, Ms}` | `erlang:start_timer/3` with the relative delay `Ms`, cancelling the timer before | `{tick, Now}`, `Now` the wall clock read when the timer fires |
| `{snarf, Bytes}` | a write of `/clipboard` through the session's display grant | `{snarfed, ok \| {error, Errno}}` |
| `{cancel, Tag}` | the worker of `Tag` is unlinked and killed | none |
| `close` | `erx_ui:close/1`, and the process ends | none |

A worker that ends without answering, killed by its heap cap or by a
crash, becomes the input `{failed, Tag, Reason}`.

The core alone decides what to read, when, and what an answer means. It
tags each request with a counter it keeps, and drops an answer whose tag
is not the one it waits for, so a slow listing of a folder the person
has left changes nothing. The process holds no decision: it is the
effects and the toolkit's calls.

**Workers and the window's lifetime.** The window process traps exits
and links each worker it starts. Three rules follow, and no other
cleanup is needed:

* a worker that answers ends `normal`, and the window ignores the
  `'EXIT'` of a pid it no longer counts as in flight;
* a worker that ends otherwise, `killed` by its heap cap among them,
  reaches the window as `{'EXIT', Pid, Reason}`, which the window turns
  into `{failed, Tag, Reason}`; cancelling a worker unlinks it before
  the kill, so a cancelled worker sends nothing;
* the window ends with the reason `shutdown` on every path, a close, a
  `ui_down` or an `'EXIT'` from its supervisor, and with its crash
  reason on a crash; neither is `normal`, so every worker still linked,
  none of which traps exits, ends with it. A worker killed in a file
  request leaves no fid behind: the grant clunks the fids of a process
  that ends ([design-files.md](design-files.md), F10).

Ticks are timer messages carrying the timer's reference; the window
drops a tick whose reference is not the timer it last started.

What follows from this shape:

* **The toolkit diffs.** The core returns the whole tree after every
  step; `erx_ui_server` numbers it against the last and sends the
  renderer only what changed ([design-display.md](design-display.md#widget-trees)).
  So a stats sample that changes three numbers redraws three labels and
  the graphs, and a step that changes nothing sends the renderer nothing.
* **Idle costs nothing.** The only timers are the core's `tick_after`
  effects. files sets none; month sets one for the next midnight, only
  while it marks a today; clock sets one for the next minute; stats one
  for the next sample. The renderers have no timer
  (design-display's G6).
* **The window never waits.** Every read is a worker's, so a file server
  or a domain that does not answer delays only its own answer, and the
  window takes input meanwhile.
* **Failure is the process's end.** A crash of the window process ends
  its window, since the widget server ends with its opener, and the
  supervisor, whose children are temporary, does not restart it; the
  log records the reason. A window closed from the window manager's menu
  ends the widget server, whose `{ui_down, Window, Reason}` ends the
  process with `shutdown`, and its workers with it.
* **Host testing is the core's.** A core is a pure function of its
  inputs, with time an input, so its tests feed recorded inspector
  records, listings and ticks and compare trees, with no display and no
  machine.

## The visual language

### What it is

The look is calm and precise: warm-neutral surfaces, near-black text,
one deep accent used sparingly, hairline separators instead of boxes,
generous space, and type that carries the hierarchy. Depth is a single
level: a section lifts off the window by a soft shadow, and nothing
floats above that. Corners are rounded on controls and sections and
square on windows. Motion is a graph moving by one sample. Nothing
glows, blurs or animates for its own sake.

It is original by construction: the palette, the proportions and the
icons below are erXos's own, and nothing is taken from another system's
interface guidelines or assets.

### The theme: one declaration

`abi/theme.txt` is the one source of every visual fact. Like `ui.txt`,
it is a declaration in erXos's ABI grammar, read by `tools/gen_abi.rb`,
which validates every row and writes:

* `erx_theme`, an Erlang module of constants, in `erx_memdraw`, the
  library application both sides of the display take
  ([design-display.md](design-display.md#overview)): the Erlang renderer
  reads it in the session, and `erx_wm_rio`, `erx_wm_menu` and
  `erx_screen` read it in the display domain. It is data, not a reader:
  G9's check, which keeps every font and picture reader out of the
  display release, is unchanged;
* `erx/theme.h`, the same constants as C, from which `erx-lvgl` builds
  one LVGL style per role and replaces LVGL's default theme;
* `theme.ts`, the same constants for the web client, as CSS custom
  properties;
* and, held in the generator's model rather than written, the inputs
  of the glyph step (below): which font files, at which sizes and
  weights, and which icons at which sizes.

Its grammar, in outline (the full grammar is
[design-abi.md](design-abi.md#theme)'s):

```text
theme 1
  unit 4
  font ui display/fonts/inter regular Inter-Regular.ttf medium Inter-Medium.ttf semibold Inter-SemiBold.ttf
  range ui 0020-007E 00A0-017F 2000-206F 2190-21FF
  role display  font ui size 48 line 64 weight semibold figures tabular
  role title    font ui size 20 line 28 weight semibold
  role heading  font ui size 15 line 20 weight semibold
  role body     font ui size 13 line 20 weight regular
  role numeric  font ui size 13 line 20 weight medium figures tabular
  role caption  font ui size 11 line 16 weight regular color secondary
  space xs 1  s 2  m 3  l 4  xl 6  xxl 8          # in units of 4 px
  radius control 6  section 10  menu 8  window 0
  hairline 1
  shadow section 0 2 12 10                       # x y blur percent
  color window     F6F5F2
  color surface    FFFFFF
  color sunken     EEEDE9
  color line       DDDCD7
  color text       1B1C1E
  color secondary  5D6066
  color tertiary   8A8E94
  color accent     0E7A6B
  color on_accent  FFFFFF
  color ok         2F7D4F
  color warn       9A6A12
  color critical   B3362C
  color series_cpu 0E7A6B
  color series_mem 5B53C6
  color series_msg B8620B
  color desktop    D9DAD5
  contrast text      on window surface sunken 7.0
  contrast secondary on window surface sunken 4.5
  contrast on_accent on accent 4.5
  icons display/icons/icons.txt sizes 16 32
```

The colour values are the starting palette, tuned with the first
screenshots; the rules are what the generator enforces. Each is a
checked constraint, as the spec discipline asks:

* every colour a `role` or a `contrast` row names is declared, once;
* every `contrast` row holds, by WCAG 2's contrast ratio of relative
  luminances, whose definition the generator cites from the
  specification it implements: body text at 7:1 against every surface
  it names, secondary text at 4.5:1, text on the accent at 4.5:1; a
  seeded `secondary` of `B0B0B0` fails the build;
* every `role` names a declared font and weight, and a size and line
  height on the 4-pixel grid where the line height is concerned;
* every `space` and `radius` value is a whole number of units or
  pixels, and `radius window` is 0 (see Windows, below).

### Type

One family serves every role: Inter 4.1, under OFL-1.1
([Dependencies](#dependencies)). It was drawn for user interfaces at
small sizes, its figures can be tabular, and its look is neither
Plan 9's Lucida-derived faces nor any platform's own system font. Six
roles make the scale, from `display` (48 px, the clock's digits) to
`caption` (11 px); a renderer never picks a size, a role does. Numbers
that change in place, stats' values and the clock, use the tabular
figures, so digits do not shift as values change.

**The glyph step.** A host step, `Erx::Glyphs` in `tools/lib/erx`,
rasterises every glyph and icon through FreeType, run as a host build
tool ([Dependencies](#dependencies)). FreeType is fetched at its pinned
release and SHA-256 and compiled out of tree by erXos's own compiler
invocations from the source files its build notes list for a build
without its scripts (`docs/INSTALL.ANY`, lines 28 and 134-139, at
2.15.0), and linked into one small C17 host program of erXos's,
`erx-raster`, which nothing in an image contains. `Erx::Glyphs` runs
`erx-raster` with an argument vector, once per font file and size and
once per icon size, and reads back each glyph's coverage rows and
metrics. `erx-raster` loads each declared code point of the role's font
at the role's size unhinted (`FT_LOAD_NO_HINTING`,
`include/freetype/freetype.h`, line 3502) and renders it with
FreeType's anti-aliasing rasteriser, which computes the exact coverage
of straight segments on each pixel and approximates curves by
subdividing them (`src/smooth/ftgrays.c`, lines 45-48 and 63). It
builds each icon's paths as an outline, strokes them with FreeType's
stroker, round joins and round caps (`include/freetype/ftstroke.h`,
lines 136, 168 and 310), and renders the result with the same
rasteriser (`FT_Outline_Render`, `include/freetype/ftoutln.h`, line
496), so glyphs and icons have one engine and erXos writes none.

From that coverage the step writes one Plan 9 subfont per role, with an 8-bit grey
image (`k8`) where `fixed` has a 1-bit one. A subfont file is an image
in the external image format followed by the glyph table, and that
format's header names the image's channel, of which an 8-bit grey one
is valid (plan9port at commit `1f13969`, `man/man7/font.7`, lines
40-43, and `man/man7/image.7`, lines 27-41 and 97-104), so a `k8`
subfont is a subfont like any other, and
`erx_font` loads it into a font cache as it loads `fixed`; the `s`
message then draws each glyph with its cache entry as the mask, which
`libmemdraw` reads as coverage, so text is anti-aliased with no change
below `erx_font`. The same step writes LVGL's bitmap font form of each
role from the same coverage, so the two renderers draw the same glyphs,
and the `body` role's glyphs a third time as generated data for the
window manager's menu, an Erlang module of each glyph's metrics beside
its raw `k8` rows, which the menu loads with `erx_memdraw:load/3`, so
the display release reads no font file and holds no font reader
([Windows and the window manager](#windows-and-the-window-manager)).
Rasterisation is unhinted, as current desktop type is; output is a pure
function of the font file, the theme and FreeType's pinned release, so
images stay reproducible. The step chooses the tabular figures by the
font's glyph names (`FT_Get_Name_Index`, `include/freetype/freetype.h`,
line 4428) for the roles marked `figures tabular`: Inter 4.1's static
fonts have a version 2.0 `post` table that names the digits' tabular
forms `zero.tf` to `nine.tf`, and the step refuses a role whose font
lacks one.

A role's subfont has one glyph for each code point of its font's
ranges, in ascending order across the ranges, so glyph i is the i-th
code point the ranges list and the renderer finds a glyph from the
theme alone. A code point the font lacks has an empty glyph of width 0,
which a Plan 9 font reader takes as missing (plan9port at commit
`1f13969`, `src/libdraw/font.c`, lines 276-277), so the renderer draws
the replacement box for it, as for a code point outside the ranges. The
subfont's image is as tall as the role's line, and its baseline lies
where CSS puts it, half the line's leading below the font's ascender:
(line - (ascender + descender)) / 2 + ascender, from the font's own
metrics in exact arithmetic, rounded half up. A glyph is drawn its
coverage's offset right of the pen and advances by its advance rounded
half up to a whole pixel. The step refuses a glyph whose ink leaves the
line, and a role whose values the subfont format cannot hold (font(7):
a glyph's column in two bytes, its rows, offset and advance in one), so
no subfont is cut to fit.

A character outside the theme's ranges has no glyph: the renderer draws
the replacement box of the role's size. The ranges cover Latin scripts
and the line escape's tokens, which are ASCII; other scripts are a later
range of the theme, with a font that covers them.

### Spacing and layout

Everything sits on a 4-pixel unit. Window content is inset by `l`
(16 px); controls are 28 px tall; list rows are 28 px; a sidebar is 176
px wide; sections are separated by `xl` (24 px) and their content by `m`
(12 px). The tree's `pad`, `width` and `height` stay hints
([design-display.md](design-display.md#widget-trees)); where the tree
gives none, the renderer takes the theme's spacing for the node's kind
and role, so the four programs set almost no sizes and still align.

A node's `pad` is inside the node: its rectangle is the room its slot
gives it, its content (a label's text, a container's children) is
placed in that rectangle less the pad on each side, and its background,
border, `current` ring and hit area cover the whole rectangle, pad
included. That is how LVGL's padding (`erx-lvgl` sets `pad_all`) and
CSS's `padding` read it, so the three renderers agree with no
translation, and a padded button is pressed anywhere on its face, not
only on its text.

### Colour

The palette is above: a warm-neutral ground, white surfaces, one teal
accent for selection, focus and the primary series, and three status
colours used only for status. Graph series have one colour each, the
same in every program. The desktop background, which `erx_screen` fills
where no window is
([design-display.md](design-display.md#windows-and-the-window-system)),
is the theme's `desktop` colour. The theme has one palette, so no
window, session or display chooses between palettes, and the
decorations, the menu, the background and every renderer read the same
constants.

### Anti-aliasing, corners and depth: coverage masks

The Erlang renderer draws everything a widget needs from two operations
`erx_draw` already has: a fill of a rectangle with a colour, and a draw
of a colour through a mask. What is not a rectangle is a mask:

| Element | Mask | Made |
| --- | --- | --- |
| text | the glyph's coverage in the role's `k8` subfont | by the glyph step, at build |
| icons | the icon's coverage in the icon subfont | by the glyph step, at build |
| a rounded rectangle's corners | a quarter disc of the radius, exact area coverage | by `erx_mask`, once per radius, kept as an image of the draw connection |
| a hairline border on a rounded rectangle | a quarter ring of the radius and the hairline's width | the same, once per radius |
| a section's soft shadow | four blurred quarter discs and four blurred edge strips, each a mask; an edge is a one-pixel strip with the replicate bit, drawn along the side | the same, once per radius and shadow |
| a graph's line and the area below it | the polyline's stroke coverage and the area's coverage, in the graph's rectangle | by `erx_mask`, at each change of the graph |

A shadow's blur approximates CSS's blur radius as `box-shadow` reads
it: the section's shape convolved with a Gaussian whose standard
deviation is half the blur, cut off at the blur, so the shadow reaches
the blur's width beyond the shape and is full the same width inside it.
A corner part is the square of the radius plus twice the blur around the
corner, and an edge strip spans twice the blur across its side. The
section hides the shadow's full interior, which no part draws, so a
shadow's offset is at most its blur on each axis.

So a rounded section costs two rectangle fills and four corner draws,
its border four more, and its shadow eight; none touches a pixel
outside the section and its shadow. `erx_mask` is a pure Erlang
module from geometry to the bytes of a `k8` image, tested on the host
against analytic areas. It lives in `erx_memdraw`, the library both
sides of the display take, beside `erx_theme`, because the menu needs
its corners and shadow too and G9's check keeps every module of
`erx_ui` out of the display release; it reads nothing, so G9 is
unchanged. The masks the renderer makes once are images of the
window's draw connection, charged to its quota as every image is
([design-display.md](design-display.md#the-draw-connection)); the
menu's are images of the display domain's own memory, as the menu's
image is.
No anti-aliased primitive is added to `erx_memdraw`, and `libmemdraw`'s
own shapes stay what the draw protocol's clients get.

Translucency is left out: windows are composed by copying
([design-display.md](design-display.md#the-screen-and-its-one-path-to-the-device)),
so no window shows another through itself, and inside a window a
translucent panel would only show the window's own ground. Shadows fall
only inside a window, under its sections.

LVGL draws the same elements with its own software renderer, which
already anti-aliases, rounds and shadows ([What the tree
holds](#what-the-tree-holds)); `erx-lvgl` sets the radii, shadow and
colours of each role's style from `erx/theme.h`. The browser draws them
with CSS from `theme.ts`.

### Windows and the window manager

Windows are square-cornered: rounding a window's corners would ask the
display to mask a client's buffer against whatever lies behind it,
which is composition with alpha that the display does not do. The
overlapping policy's decorations take the theme: `decorate/2` returns
its border rectangles in the theme's `line` colour for windows that do
not take the keyboard and `accent` for the one that does, one hairline
wide, and the menu draws its items in the `body` role, on `surface`,
with the `menu` radius and the section shadow, inside its own image.
The menu's glyphs are the `body` role's, which the glyph step writes as
`erx_menu_glyphs`, an Erlang module of metrics and raw `k8` rows;
`erx_wm_menu` loads them into an image of the display domain's own
with `erx_memdraw:load/3` and draws each label's glyphs through it as
masks, so the display release holds no font file and no font reader
and G9's check is unchanged
([design-display.md](design-display.md#windows-and-the-window-system);
[Decisions](#decisions), 8). The decorations are borders only, with no
title bar ([Decisions](#decisions), 4).

### Motion

Motion appears in one place, where it means something: a graph
advances by one sample when a new sample arrives, so the newest value
enters at the right and the oldest leaves at the left. Nothing is
tweened between samples: an interpolated scroll would need a renderer
timer or a tree many times a second, and an idle window must cost
nothing (G6). Pressing a control changes it once, as LVGL is already
configured to do (`lv_conf.h:41`).

### Icons

The icon set is drawn for erXos: about twenty glyphs on a 24-unit grid
with a 1.5-unit stroke, rounded joins and caps, declared as paths in
`display/icons/icons.txt` and rasterised by the glyph step at 16 and 32
pixels into an icon subfont, stroked and rendered through FreeType as
glyphs are. An icon has at most two layers, a base drawn in the
`secondary` colour and an accent drawn in the `accent` colour, so an
icon carries no colour of its own and takes the palette's. The file is erXos's own work under its license,
so no icon set's license enters the question. The generator writes the
same paths for the web client as SVG path data, and LVGL takes the icon
subfont in its font form, so all three renderers draw one set.

The set, a closed list that `ui.txt` names ([Widget format
additions](#widget-format-additions)): `folder`, `document`, `text`,
`picture`, `program`, `package`, `link`, `system`, `unknown`, `back`,
`forward`, `refresh`, `copy`, `chevron`, `cpu`, `memory`, `messages`,
`load`, `clock`, `calendar`.

### What each renderer has and lacks

| Need | Erlang renderer (`erx_ui_erlang`, part 7) | LVGL (`erx-lvgl`) | Where the gap is closed |
| --- | --- | --- | --- |
| anti-aliased text | glyphs from `fixed`, 1-bit | Montserrat 14 only | the glyph step: `k8` subfonts and LVGL fonts of every role, from one rasterisation |
| a type scale | one size | one size | the theme's roles, and the `role` property |
| rounded corners, borders | none | yes | `erx_mask`'s corner masks, in the Erlang renderer |
| soft shadows | none | yes | `erx_mask`'s shadow masks, in the Erlang renderer |
| graphs | no kind | chart widget | the `graph` kind; `erx_mask`'s stroke and area masks in the Erlang renderer, `lv_chart` in LVGL |
| icons | no property | symbol font only | the icon set, the `icon` and `icons` properties |
| one palette | none | LVGL's default theme | the theme, in both renderers and the decorations |

## Widget format additions

The four programs need six additions to `abi/formats/ui.txt`. Each
states what a node is, not how it looks, so every renderer draws it as
fits its medium ([design-display.md](design-display.md#widget-trees)),
and each arrives in the validator, the binary form and the readers of
all three languages from the one declaration.

| Addition | Declared as | Meaning |
| --- | --- | --- |
| `role` | a property of a root `@enum` of type `u8`, `body` when absent, on the kinds that show text (`label`, `button`, `checkbox`, `input`, `list`, `graph`) | how the text ranks in the window: `display`, `title`, `heading`, `body`, `numeric` or `caption` |
| `area` | a property of a root `@enum` of type `u8`, absent by default, on `column`, `row`, `grid` and `scroll` | what the container is: `section`, `toolbar` or `sidebar` |
| `icon` | a property of a root `@enum` of type `u8`, the icon set, on `label` and `button` | the item the node stands for, drawn beside its text; a renderer without the icon shows the text alone |
| `icons` | a list of the same enumeration, on `list`, marked `parallel items` | each item's icon |
| `current` | a boolean, `false` when absent, on `button` | the button stands for the current one of its set: today in a month, the current folder in a path. A renderer marks it, the Erlang renderer and LVGL with the accent's ring, the browser with `aria-current` |
| kind `graph` | properties `samples`, `min`, `max`, `mark` and `text` | a series of at most 240 numbers, oldest first, each an integer within `min` and `max` or `none`; `mark` an optional reference value within them, such as a grant; `text` the caption, an `attr()` like any text |

`on_submit` on `list`, the existing event with the `selected` index as
its state value, is a kind line, not a new member: the person activated
the selected item, by a double click on it or Return while the list has
focus.

`role` is declared only beneath the kinds that show text and `area`
only beneath the containers, so either on another kind is refused by
the validator as any property a kind does not take is, with no rule of
its own. The grammar of [Widget format](design-abi.md#widget-format) gains
three things, and nothing else:

| Grammar addition | Meaning | Wire form |
| --- | --- | --- |
| `list NAME ELEMENT MAX [none]`, `ELEMENT` a text type, an integer type or a root `@enum` | at most MAX values of the element type; with `none`, the atom `none` is also a value, and only for an integer element | a count, then each value as that type's own field: text as today, an `@enum` as a `u8`, an integer as a signed 32-bit word, with `none` written as -2^31. The generator refuses `none` on an integer type whose range includes -2^31, so the sentinel is never a value |
| `within LOW HIGH` on a list of integers | each value but `none` lies between the two integer properties | unchanged |
| `parallel LIST` on a kind's property line | the list property is exactly as long as the list property `LIST`; the validator refuses another length with `bad_value` | unchanged |

`samples` is `list samples sample 240 none`, `sample` an integer type
from 0 to 2^31 - 1, taken by `graph` as `prop samples within min max`.
A `none` sample is a gap: every renderer leaves the line broken there
and draws no value, LVGL with `LV_CHART_POINT_NONE`. The largest `graph`
insert, 240 samples of four bytes, is within one 64 KiB update of the
web, which the generator checks for every kind.

These are changes of a format that nothing outside erXos reads, so they
replace the old form outright: the renderers, the parity corpus and the
fuzz targets' seeds follow from the declaration in the same change.

## stats

```text
+----------------------------------------------------------------------------------+
|  Stats                                                     ( Pause )  Every 1 s  |
|                                                                                  |
|  .-------------------.  .-------------------.  .-------------------.  .--------. |
|  | [cpu] CPU     38% |  | [mem] Memory 31%  |  | [msg] Messages    |  | [load] | |
|  |      _/\__/\_  _/ |  | ______------------|  |   4.1k frames/s   |  |  2.0   | |
|  | ___/        \/    |  |                   |  |  __/\___/\__/\__  |  | ready  | |
|  | 4 CPUs            |  | 1.2 of 3.8 GiB    |  | between domains   |  | threads| |
|  '-------------------'  '-------------------'  '-------------------'  '--------' |
|                                                                                  |
|  Domains                 CPU of grant           Memory of budget       Frames/s  |
|  ------------------------------------------------------------------------------- |
|   1  system     __/\_    12%  of 1.000 CPU      ======-------  41%          820  |
|   4  display    ___/_     3%  of 0.250 CPU      ===----------  18%          310  |
|   7  root_1     /\___    21%  of 2.000 CPU      ========-----  62%  unsupported  |
|   9  network    . . .    unknown                ====---------  27%           40  |
|                                                                                  |
|  4 domains in this session's view                                                |
+----------------------------------------------------------------------------------+
```

The window is a column: a toolbar; a row of four `section`s for the
machine; a `heading`; and a `scroll` of one row per domain. Each
domain's id is a `present` of type `domain`, so a click on it selects
that domain's row and shows its processes count and run queue beneath
it, and the same presentation clicked at a terminal inserts the id into
the command line ([design-display.md](design-display.md#presentations)).

### What it reads

Every sample is a set of inspector queries through the session's
inspect facet, `erx:inspect(Path, #{timeout => 1000})`, each a worker's
([The construction](#the-construction)):

| Measure | Path and attributes | Visible to a scoped facet | Shown as |
| --- | --- | --- | --- |
| CPU, machine | `[cpus]`, then `[cpus, N]`: `idle_time` | yes, `idle_time` is `visible any` | busy share of all CPUs over the period: 1 minus the sum of idle time's growth over the period divided by the period times the CPU count |
| memory, machine | `[]`: `memory_total`, `memory_free` | yes, both are `visible any` | used and total |
| scheduler load | `[cpus, N]`: `ready_threads`; `[domains, Id]`: `run_queue` | yes: `ready_threads` is `visible any`, and a domain's for its own domains | ready threads summed over urgencies and CPUs; each domain's run queue in its detail |
| CPU of a domain | `[domains, Id, group]`: `used_ns`, `capacity_mcpu` | yes, for its own domains | the growth of `used_ns` over the period, as a share of the grant: growth divided by period times `capacity_mcpu` / 1000 |
| memory of a domain | `[domains, Id, budget]`: `spending`, `guarantee`, `cap` | yes, for its own domains | `spending`, the budget's used, carved and lent pages ([design-live.md](design-live.md#paths)), against `cap`, with the guarantee as the graph's `mark` |
| frames of a domain | `[domains, Id, connections]`: frames accepted on each lane | yes, for its own domains | the growth of their sum over the period, per second |
| the domains | `[domains]`, then `[domains, Id]`: `name`, `state` | its own domains only | one row per listed domain |

A scoped facet, every session's in a release build, sees every row of
this table: `[]` and `[cpus, N]` show it the machine attributes marked
`visible any`, a CPU's idle time and ready threads among them, and
`[domains]` lists only the domains its scope covers
([design-live.md](design-live.md#inspection), "Scopes"). So the four
machine panels read the same in every session, and the rows beneath
them are the session's own domains ([Decisions](#decisions), 9). stats
has no answer of its own for a path out of scope: an `{error, scope}`
for a machine path is an error like any other, shown as its token with
a gap.

A machine's sample is a handful of queries; each domain adds four. The
period is one second by default, two, five and ten by the toolbar; at
one second with twenty domains a sample is about eighty queries, a cost
to measure ([Performance](#performance)). A sample is taken only when
the last one has answered or timed out, so a slow inspector stretches
the period instead of piling up queries.

### What it computes

`erx_desk_stats_core` keeps, for each measure, the last raw reading
with its status and the monotonic time it was taken, and a ring of 240
derived samples. A rate or a share is derived from two readings:

* both `ok`: the value, `ok`;
* either `partial`, the other `ok` or `partial`: the value, `partial`;
* either `unknown`, `unsupported`, `{timeout, Ms}` or `{error, _}`: no
  value, a gap in the graph, and the number shows that status's token,
  the worse of the two by the order `error`, `timeout`, `unsupported`,
  `unknown`;
* a counter that went down, which only a new domain or a restarted
  reporter does: no value and a gap, never a negative rate;
* a share whose denominator is zero, which the schema allows for a
  group's `capacity_mcpu`, a budget's `cap`, and the machine's
  `memory_total` and CPU count, the CPUs `[cpus]` lists: no value and
  a gap, and the number reads "no grant", "no cap", "no total" or "no
  CPUs", which are facts of the record, not estimates.

The ring holds only `ok` values: a derived sample that is `partial`, or
has no value, enters the ring as `none`, a gap, so an earlier partial
point never looks exact once later readings are `ok`. The number beside
the graph shows the latest derived value with its status, `partial`
included.

Samples are integers, as the `sample` type requires. A share is in
tenths of a percent, 0 to 1,000 on a graph whose `min` is 0 and `max`
1,000; a share above 100 percent, which a group that runs beyond its
grant gives, enters the ring as 1,000 and its number shows the true
value. A rate is per second, on a graph whose `max` is the ring's
largest value rounded up to 1, 2 or 5 times a power of ten, at least
10; memory is in pages against `max` the `cap`.

The inspector's status travels into the tree as the `attr()` of each
number's `text` property, and the renderer shows its token
(design-display's G7). A path the inspector answers with `{error,
unsupported}`, as `[domains, Id, connections]` does while its path has
no collector, makes that column `unsupported` for every domain, which is
the truth on that build.

A domain listed in one sample and gone from the next ends its row; a
new domain starts with an empty ring. A listing contains only the
domains the facet's scope covers, so stats never learns how many it
does not show and does not say. A listing marked `partial` is an
incomplete collection, not a hidden one: its rows stay, and the
domains heading carries the token `partial`.

### What it refuses

The command `stats` takes no arguments; any is a usage error. A session
without an inspect facet answers `no_facet` to the first query, and the
window shows one line, "This session has no inspect facet", and samples
nothing more. A listed domain whose path answers `{error, scope}` has
ended between the listing and the query, since a path outside the
scope and a path that names nothing get the same answer, and its row
ends.

## clock

```text
+--------------------------------+      +--------------------------------+
|                                |      |                                |
|             14:07              |      |             --:--              |
|                                |      |                                |
|    Sunday 15 November 2026     |      |         Clock not set          |
|              UTC               |      |     12 minutes since boot      |
+--------------------------------+      +--------------------------------+
        the clock set or boot                  the clock unset
```

clock shows the hour and minute in the `display` role, the weekday and
date in `body`, and the zone in `caption`. erXos has no time zone
setting, so clock shows UTC and says so ([Decisions](#decisions), 5).

**Reading the time.** At each tick the core reads the wall clock,
`os:system_time(millisecond)`, which is the time page's wall clock in
ERTS ([design-time.md](design-time.md#what-erxos-already-has)), and the
clock's state from the inspector's `[time]` record, `state`:

| `state` | Shown |
| --- | --- |
| `set` | the time and date |
| `boot` | the time and date, and the caption "from the real-time clock" |
| `unset` | `--:--`, "Clock not set", and the time since boot from `[]`'s `uptime`, an attribute every facet sees |
| not `ok` (`unsupported` until the schema declares `[time]`, `unknown`, `timeout`) | the time and date in the `tertiary` colour with the status token beside the zone, since the reading may be the time since boot |

An unset clock's reading is uptime counted from 1970-01-01, so showing
it as a date would be a wrong answer shown as a right one; clock shows
it as what it is.

**Ticking.** Erlang's timers run on monotonic time, which a step of the
wall clock does not move ([design-time.md](design-time.md#what-erxos-already-has)),
so clock does not ask for a wall-clock instant. After each tick the core
computes, from the wall reading `Now` it just took, the delay to the
start of the next minute, `60000 - Now rem 60000` milliseconds, and asks
for a `tick_after` of that delay. The timer therefore never drifts
across minutes: each delay is recomputed from a fresh reading. A step of
the wall clock, which `os:system_time/1` shows at once, is not seen
until the timer set before it fires, so the display is corrected at the
next tick, at most one minute after the step; a step back makes that
tick early by the wall clock, and a tick shows the minute it reads,
since a tick is a reading, not a count. clock wakes once a minute and
draws one changed label.

The command `clock` takes no arguments.

## month

```text
+---------------------------------------------------+
|  November 2026                 ( < )  Today ( > ) |
|                                                   |
|   Wk    Mo   Tu   We   Th   Fr   Sa   Su          |
|   44                                   1          |
|   45     2    3    4    5    6    7    8          |
|   46     9   10   11   12   13   14  (15)         |
|   47    16   17   18   19   20   21   22          |
|   48    23   24   25   26   27   28   29          |
|   49    30                                        |
|                                                   |
|  Sunday 15 November 2026, day 319, week 46        |
+---------------------------------------------------+
```

month is a `grid` of seven columns of buttons for the days, a column of
ISO week numbers in `caption`, a `title` with the month and year, and a
line for the selected day. Weeks start on Monday and are numbered as
ISO 8601 numbers them, since erXos has no locale and ISO 8601 needs
none. Today's button carries `current`, which every renderer marks
([Widget format additions](#widget-format-additions)); the selected day
is the one the line beneath names, set by a click on a day, and has no
mark of its own, so the format needs no selection state on buttons.

`erx_desk_month_core` is a function of a year, a month, a selected day
and today, `none` or a date, built on stock OTP's `calendar`. Today is
a date only when the clock's state is `set` or `boot`, read from the
inspector as clock reads it; otherwise no day is marked, and the window
opens on the month the command names or, when it names none, on the
month of the wall clock with the caption "Clock not set: no today".
Moving by month crosses years; Today returns to today's month and is
disabled when there is no today. A tick at midnight UTC moves today's
mark, so month sets one timer, a `tick_after` of the delay from its
wall reading to the next midnight, as clock computes its minute, only
while it has a today.

The command takes FreeBSD `cal`'s argument forms: `month`, `month
YEAR` for January of that year, `month MONTH YEAR`, with `MONTH` 1 to
12 and `YEAR` 1 to 9999. Anything else is a usage error that names the
forms.

## files

```text
+------------------------------------------------------------------------------------+
| ( < ) ( > )   [folder] /  >  data  >  logs              ( refresh )  ( copy path ) |
|-------------+------------------------------------------+---------------------------|
|  apps       |  [folder] archive                        |  [text]                   |
|  data       |  [text]   boot.log                       |  boot.log                 |
|  proc       |  [text]   net.log                        |  Text                     |
|  tmp        |  [unknown] core.bin                      |  12,481 bytes             |
|             |                                          |  Modified 2026-11-14      |
|             |                                          |  09:12 UTC                |
|             |                                          |  -rw-r--r--               |
|             |                                          |  .---------------------.  |
|             |                                          |  | 00:00:01 boot start |  |
|             |                                          |  | 00:00:02 storage up |  |
|             |                                          |  '---------------------'  |
|             |  4 items                                 |                           |
+------------------------------------------------------------------------------------+
```

files is three columns: a `sidebar` with the folders at the root of the
session's namespace, a `list` of the current folder with an icon per
item, and an info `section` for the selected item with, for text, a
preview. A `toolbar` holds back and forward, the path as a row of
buttons, one per folder from the root, the current folder's carrying
`current`, and refresh and copy path. A path deeper than 16 folders
shows the root's button, an ellipsis and the last 16, so the toolbar's
children stay within the schema's bound.

### What it reads and does

* **A folder** is listed in two steps, each a worker's, through the
  session's own namespace ([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)):
  `file:list_dir_all/1` gives the names, and `file:read_link_info/1`
  is then called only for the names of the page shown, at most 256
  ([Bounds](#bounds)). The core hides names that start with `.` unless
  the toolbar's toggle shows them, and sorts the rest by name, byte for
  byte, as Finder does by default; it does not put folders first, since
  that would need every name's information before the first page could
  be shown. The page shows "Loading" until its information arrives.
* **Kinds.** A directory is `folder`, a symbolic link `link`, a file
  with an execute bit `program`, a name ending in `.app` `package`
  ([design-packaging.md](design-packaging.md)), a name ending in `.png`
  `picture`, a name ending in one of the core's text suffixes (`.txt`,
  `.md`, `.log`, `.conf`, `.erl`, `.hrl`, `.c`, `.h`, `.rb`, `.sh`,
  `.rc`) `text`, anything under `/proc` `system`, and the rest
  `document`. The icon is a guess from the name, made without reading
  the file, so listing a folder reads no file.
* **Opening** an item, by `on_submit` on the list or a click on a path
  button, does one of three things. A folder or a link to one becomes
  the current folder, pushed on the back history. A file is read once,
  at most its first 16 KiB, and is text, whatever its name, when every
  byte read is valid UTF-8 and none is NUL, with one allowance: when the
  read stopped at 16 KiB, a character the limit cut short at the end is
  dropped, not counted as malformed. A malformed sequence anywhere else,
  a short sequence at the end of a file read whole included, makes the
  file not text. A read that fills the 16 KiB counts as stopped, so a
  file of exactly 16 KiB is judged as one cut there. A link to a folder,
  or an item whose information has not arrived, is read as a file is,
  and the read's `eisdir` opens it as a folder. Opening a text file shows the bytes read as its
  preview in the info section. Any other file shows its information,
  and the info section
  says that the desktop has no viewer for it. Nothing is started: files
  starts no program and no app.
* **Copy path** writes the selected item's path, its exact bytes, to
  `/clipboard`, when the session's display grant carries `clipboard`
  ([design-display.md](design-display.md#the-window-process)); without
  it the button is disabled.
* **Refresh** lists the folder again. Nothing watches a folder: the file
  protocol has no change notice, so a listing is as of its read, as
  design-files' made trees are.

Copying, moving, renaming and deleting are not files' to do: the
commands already do them, with FreeBSD's behaviour and errors, and a
window that deletes needs a confirmation, an undo or a trash, and a
policy for conflicts, none of which a first browser needs ([Decisions](#decisions), 2).

### Names and contents are untrusted

A name is the bytes its server gave, valid UTF-8 by the file protocol's
rule, and possibly holding controls, bidirectional overrides or text
that looks like another name ([design-files.md](design-files.md#text-in-file-names)).
The core keeps each item's raw name in its state, and the tree holds
only the shown text, which every renderer draws through the line escape
(design-display's G5), so an override shows as its token and a name
cannot pass for another. The shown text is cut, at a character
boundary, to the schema's 128 bytes of a list item, with the middle
replaced by an ellipsis so both ends stay visible.

Every action names its item by its index in the core's listing, never
by the shown text, so two names that show alike open their own files.
An index means an item only within one listing and one page, so the
list node's `key` names both, the binary `listing Generation Page`
(a key is an integer, an atom or a binary,
[Widget format](design-abi.md#widget-format)), `Generation` a
counter the core advances at every listing it takes in. A refresh, a
new folder or a turned page changes the key, the toolkit numbers the
list as a new node ([design-display.md](design-display.md#widget-trees)),
and an event a renderer reports on the old node, a late double click
included, is dropped by the widget server as an event on a node no
longer in the tree. The list's event terms carry the same key,
`{select, Key}` and `{open, Key}`, and the core drops one whose key is
not the listing it shows, which an event the server fired just before
the window took in a new listing is. An index the core acts on
therefore always indexes the page it shows. The path and sidebar
buttons' terms carry the folder they open, not a position.

A preview's text is the file's bytes shown under the file's name, so
it is attributed text: the core splits it into lines, cuts each to the
4,096 bytes of a `text` property and the preview to 200 lines, and the
renderer escapes each. A preview of bytes that are not valid UTF-8 is
never built, since such a file is not text. `/proc`'s files are written
through the field escape already ([design-live.md](design-live.md#the-proc-tree)),
and show as they read.

**The escape and the wire's bounds.** The cores cut a text to its
property's bound in raw bytes, and the line escape then lengthens it:
a control of one byte shows as the eight bytes of `<U+0001>`. The
Erlang and browser renderers escape where they draw, after the wire,
so they meet no bound. `erx_ui_lvgl` escapes before it encodes
([design-display.md](design-display.md#widget-trees)), and the C
reader refuses a text longer than its property's bound, so a valid
tree whose text is heavy with controls would become a record `erx-lvgl`
refuses. The cut therefore belongs with the escape: `erx_ui_lvgl` cuts
the escaped text to the property's bound at the end of a whole
character or token, never inside one, and ends it with an ellipsis.
That is a rule for design-display's LVGL renderer, which every program
needs, not these four alone ([Open decisions](#open-decisions), 1). The raw name stays in the core,
whatever is cut on the way to the screen.

### Bounds

A `list` holds at most 256 items (`ui.txt:33`). A larger folder is shown
256 items at a time, with "Items 257 to 512 of 1,204" and previous and
next beneath the list; selection and activation are by the core's
index within the page, so paging changes no action. Only the page's
names are looked up, so the information calls of a listing are at most
256, whatever the folder's size.

The names themselves are bounded by the worker that reads them.
`file:list_dir_all/1` gathers the whole folder in the calling process,
which is the listing worker, and the file protocol bounds each
`readdir` reply but not how many a client gathers
([design-files.md](design-files.md)). The worker is spawned with
stock OTP's `max_heap_size` process flag, `#{size => 524288, kill => true,
error_logger => false, include_shared_binaries => true}`, 524,288
words being 4 MiB on a 64-bit runtime
(`otp/erts/preloaded/src/erlang.erl`, `process_flag/2`'s
`max_heap_size`), so the names of an outsized folder can neither
exhaust the session's memory nor keep the worker reading: the runtime
kills the worker when its heap, names included, reaches the cap. The
window receives `{'EXIT', Pid, killed}`, the core `{failed, Tag,
killed}`, and the list's place says "This folder is too large to show
here" and names `ls` as the way to read it; the history is kept, so
back works. Four MiB holds tens of thousands of names, more than a
folder a person browses holds. The answer the worker sends is the same
size again in the window's heap, so the window's memory for a listing
is bounded by the same cap.

### What it refuses

The command `files [DIR]` opens `DIR`, or the session's working
directory, which must be a folder: a path that names nothing fails with
`files: DIR: No such file or directory`, and a file with `files: DIR:
Not a directory`, FreeBSD's texts for `ENOENT` and `ENOTDIR`. A folder
that cannot be listed in the window, by an errno or a timeout of its
server, shows the error's text in the list's place and keeps the history,
so back works.

## Shipping and starting

The four are one Erlang application, `erx_desk`, in the desktop
session's release beside `erx_term`, and its supervisor `erx_desk_sup`
is started by the application. Each program's command is an Erlang
command of that release ([design-shell.md](design-shell.md#commands)):
`stats`, `clock`, `month [[MONTH] YEAR]` and `files [DIR]`. A command
asks `erx_desk_sup` for a window, waits until `erx_ui:open/1` answers,
and returns: `ok` once the window is open, or the error, such as `stats:
no display` for `{error, no_display}`. Each run opens one more window;
nothing is single-instance.

The four could be packages under `examples/` instead, installed as
apps. They are not, for one reason that does not change when packaging
is built: an app is a principal of its own, whose session holds the
`apps` row's services and its own inspect scope and data directory
([design-packaging.md](design-packaging.md#an-apps-principal)). stats
would see only the app's own domains and files only the app's own
files, while both must see the person's. They stay on the public
surface all the same, `erx_ui:open/1`, `tree/2` and `close/1`, stock
OTP and `erx:inspect/2`, which a source check holds ([Verification and
testing](#verification-and-testing)).

A command a program runs, through `xargs` or a script, runs in that
program's command domain, which holds no display grant
([design-shell.md](design-shell.md#commands)), so it fails with `no
display`. Whether the desktop's session opens files and clock at its
start is the session template's arguments, and this design opens none
([Decisions](#decisions), 6).

## Concurrency and failure

Each window is one process with its own core; windows share nothing,
so two stats windows sample independently. A worker answers once and
ends; its answer is tagged, and the core drops an answer it no longer
waits for. The window process never calls a server itself, so its
mailbox drains and the window takes input while a read waits.

| Failure | Effect | Recovery |
| --- | --- | --- |
| an inspector query times out | its values show `timeout`, and the graph a gap | the next sample asks again |
| the inspector answers `no_facet` | stats shows its one line and stops sampling | a session that holds the facet |
| a file server does not answer | files shows "Loading" in the list's place; the window takes input | navigate elsewhere, which cancels the worker, or wait |
| a listing fails with an errno | its text in the list's place; history kept | back, or refresh |
| a folder's names reach the listing worker's heap cap | the worker is killed; "This folder is too large to show here" in the list's place; history kept | back, or `ls` at a terminal |
| a worker crashes | its request fails with the reason, shown as the error's text where the answer would go | refresh, or the next sample |
| a preview read fails | the info section shows the error's text | none needed |
| `/clipboard` refuses a write | the copy button reports the errno once | none needed |
| the window is closed from the menu | the widget server ends, the program receives `{ui_down, Window, _}` and ends with `shutdown`, its workers with it | the command again |
| the display goes away | the program receives `{ui_down, Window, display_down}` and ends | the command again, once the display is back |
| the window process crashes | its window ends with it; the log records the reason; the supervisor does not restart a temporary child | the command again |
| a tree fails validation | `erx_ui:tree/2` answers `{error, {Reason, Where}}`, the window keeps its last tree, and the process ends with that reason, since a core that builds an invalid tree is a bug | the command again, and the bug is fixed |
| the session ends | every window and program of it ends | the session's |

## Security

The four hold nothing of their own. stats acts with the session's
inspect facet, whose scope the domain service computed for the
session's principal; files acts with the session's namespace, whose
grants the servers enforce; clock and month read the time page every
domain maps. A program of the four cannot reach anything the person's
shell cannot, and runs only in the person's own session.

What they show comes from other domains: names of domains and of files,
file contents, and values a runtime reported under its own name. Each
reaches the screen only as a widget's text property, which every
renderer draws through `erx_text:escape_line/1` (design-display's G5),
and each decision the programs make about a file or a domain uses the
raw bytes or the id kept in the core, never the shown text. A click on
a presentation in stats grants nothing: it selects a row, and the same
presentation at a terminal inserts text that the shell checks as typed
text (design-display's G4).

What a folder's size can cost the session is bounded: the listing
worker's heap cap bounds the names gathered, and information is asked
for one page of names (D8).

Nothing here changes what the display domain parses: the theme is
generated constants and the menu's glyphs a generated module, and the
display's new work, the decorations' and the background's colours and
the menu's labels, reads them as data.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **D1.** A program reads only through the session's inspect facet, its namespace and the time page | the effect set is closed, and its performer calls `erx:inspect/2`, `file` and `os:system_time/1` and nothing else; no core performs an effect | a call from `erx_desk` to another erXos module than the public surface, a capability or a facet lookup | a source check over `erx_desk`'s modules: every call into an erXos module is one of `public.txt`'s functions ([design-packaging.md](design-packaging.md#the-sdk)) or `erx:inspect/2`, with a seeded call of `erx_inspector:route/4` failing it |
| **D2.** No value is shown as other than it came | each derived value carries the worse status of its readings; a status not `ok` reaches the tree as the `attr()` of its text, which the renderer shows as its token (G7); a missing or non-`ok` sample is `none` in `samples`, a gap; a zero denominator is no value | a status dropped on derivation; a gap filled with zero or the last value; a partial sample kept in the ring as a value; a negative rate from a counter that went down; a share of a zero grant shown as 0 or 100 percent | the stats core's status table test over every pair of statuses, with a seeded derivation that keeps `partial` as `ok` failing it; a recorded run with a connections path answering `unsupported`, every row showing the token, with a seeded zero failing it; a counter that goes down, giving a gap, with a seeded subtraction failing it; a partial sample followed by `ok` samples, leaving a gap at the partial point, with a seeded ring that stores partial values failing it; a group of `capacity_mcpu` 0 and a budget of `cap` 0, each giving a gap and its fact, with a seeded division that answers 0 failing it; a session with a scoped facet, see [Verification and testing](#verification-and-testing) |
| **D3.** A clock never shows an unset clock's reading as the date | the clock and month cores take the state as an input and show a date only for `set` or `boot`, and dimmed with a token when the state is not `ok` | a core that formats the reading without the state | the clock core's test for each state, with a seeded core that ignores `unset` showing `00:12` on 1 January 1970 and failing it |
| **D4.** Every action of files reaches the item the person chose | the core acts by index into its own listing of raw names, within the page whose list node is keyed by the listing's generation; the tree holds only shown text | a lookup by shown text; a list key that survives a new listing | a listing whose names `a<U+202E>b`, the eight characters of a token, and a name cut to the same 128 bytes as another, each opened by index and reaching its own file, with a seeded lookup by shown text opening the wrong one; a double click reported on the list of a listing a refresh has replaced, dropped by the widget server, with a seeded key that leaves out the generation opening an item of the new listing |
| **D5.** Every tree a core builds is valid, whatever the input | names and texts are cut to the schema's bounds at character boundaries, lists to 256 items, previews to 200 lines | a raw name in an `items` entry; a list longer than 256 | a property test over random listings, names of every length to 255 bytes, previews and inspector records, each tree passing `erx_ui_schema`, with a seeded core that skips the cut failing it |
| **D6.** An idle window costs nothing | the only timers are the core's `tick_after`; the renderers have none (G6) | a periodic redraw; a tick from files, or from month without a today | on the host, an idle files window and a month window without a today, each for a simulated day, issue no tree; a month with a today issues one at midnight; clock issues one a minute; with a seeded once-a-second tick in clock the test fails |
| **D7.** The palette meets its contrast rules | the generator checks every `contrast` row | a colour edited without the rule | the generator's test with a seeded `secondary` too light, failing the build |
| **D8.** A listing costs the session bounded memory and work | the listing worker runs under a heap cap, and information is asked for one page of at most 256 names | a worker spawned without the cap; a lookup of every name | files: bounds, below |
| **D9.** No worker outlives its window, and a cancelled worker sends nothing | workers are linked, the window traps exits, ends with `shutdown` or its crash reason, and unlinks before it kills | a window that ends `normal`; a kill without the unlink | the window's lifetime tests, below |

## Verification and testing

Host tests run with `make check`, as every core's do; the QEMU cell runs
in the `display_domain` suite when this part lands and at the milestone
gate. Each test names the fault that must make it fail.

**The cores, on the host.**

| Test | Passes when | Seeded fault that fails it |
| --- | --- | --- |
| stats: derivation | every pair of reading statuses gives the status D2's table says; shares and rates match hand-computed values over recorded readings | `partial` kept as `ok`; a share divided by the period without the grant |
| stats: gaps and resets | a counter that goes down, a domain that leaves and returns, and a timed-out query each give a gap, and no value is negative | the reset check removed |
| stats: pacing | with an inspector model that answers slowly, at most one sample is in flight | a tick that samples while the last sample waits |
| stats: answers out of order | an answer of an earlier sample, arriving after a later one, changes nothing | the tag check removed |
| stats: partial history and zero denominators | a partial sample followed by `ok` samples leaves a gap at the partial point; a group of `capacity_mcpu` 0, a budget of `cap` 0 and a machine of `memory_total` 0, all legal records of the schema, each give a gap and the number's fact | a ring that stores partial values; a division by zero answered as 0 |
| stats: a scoped facet | with an inspector model that answers as design-live's scoped facet does, for two ordinary principals, `[]` and `[cpus, N]` with only their `visible any` attributes and a listing of only each principal's own domains, the four machine panels show the same values for both principals, each window's rows are its own principal's domains, and no count of other domains appears anywhere | a CPU panel that reads `running_thread`, which the scoped record leaves out, and shows a gap |
| clock: states | each `state` and each non-`ok` status gives its row of the table | the state ignored (D3) |
| clock: ticks | over recorded readings, including a wall step back and forward and an early tick, each tick shows the minute it read and asks for a `tick_after` of the delay from its reading to the next minute's start; a step is shown by the first tick after it | the next tick set 60 s after the last instead of from the reading |
| month: every month | for every month from 1600 to 2400, the grid's first weekday, length and week numbers equal `calendar`'s | February given 29 days in 1900 |
| month: arguments | every form of `cal` and every refusal | a `MONTH` of 13 accepted |
| files: kinds and sorting | the kind table over a corpus of names and modes; byte order of names | a link to a folder listed as a folder without its link mark |
| files: by index | D4 | lookup by shown text |
| files: paging | a 1,204-item folder pages by 256, activation on page 3 opens item 513 + index, and each page asks information for its own names only, at most 256 | an off-by-one in the page offset; a `stat` effect over every name |
| files: bounds | a listing worker given a host folder of 500,000 names is killed by its heap cap, and the window shows "too large" and still takes input | the worker spawned without `max_heap_size`, so it answers the whole listing and the test, which expects the refusal, fails |
| files: text test and preview | a file with a NUL, with invalid UTF-8 at byte 10,000, and with valid text, each classified; a text file longer than 16 KiB whose 16,384th byte begins a three-byte character is text and its preview ends before that character; a file of 100 bytes ending in the first byte of a two-byte character is not text; a 1 MiB file reads at most 16 KiB | the read bound removed, caught by the read size; a classifier that checks only the first 4 KiB, caught by the byte 10,000 case |
| window: lifetime | with a file model that never answers, navigating away cancels the read and no input follows from it; closing a window with two workers in flight leaves neither alive, and the grant model holds no fid of theirs; a worker that crashes gives its request's error | the window ending `normal` on close, which leaves the workers alive; a kill without the unlink, which sends the window a `failed` input |
| every core: valid trees | D5 | the cut skipped |

**Rendering, on the host,** through `erx_ui_host`
([design-packaging.md](design-packaging.md#the-sdk)), which runs the
widget server, the schema and the renderer the session runs:

* each program's tree, from recorded inputs and a fixed time, drawn by
  the Erlang renderer equals its reference frame
  under `test/display/reference/desk/`; a section's radius changed by
  one pixel fails it;
* the attributed-text corpus of design-live, as file names in files and
  as a domain name in stats, draws its tokens; a seeded renderer without
  the line escape fails it;
* the parity test of track D runs the four programs' trees and inputs
  through the Erlang, LVGL and browser renderers and finds the same
  events, values and nodes, the new kinds and properties among them;
  a seeded LVGL reader that drops `none` samples fails it.

**The raster and glyph steps, on the host.** `erx_mask`'s quarter
disc of radius 1 to 32 sums, row by row, to the disc's area within one
part in a thousand, or within half of one coverage step where that is
larger (radius 1, whose one byte cannot come closer), and its stroke
of a straight line covers each column by the stroke's width at the
rows the line crosses; a seeded half-pixel offset fails both.
The glyph step's coverage of a square glyph is exact, its output is
byte-identical over two runs, and a role whose tabular figures it cannot
find is refused; a seeded glyph shifted by one pixel fails the
reference frames above. Every icon the `icon` enumeration names has
paths in `icons.txt`, a straight stroke of an icon covers each column
by the stroke's width, and the menu's glyph module loads with
`erx_memdraw:load/3`; a seeded icon without paths fails the generator.

**The widget format additions.** The validator refuses a `role` on a
kind that does not take it, `icons` of another length than `items`, a
sample outside `min` and `max`, and a 241st sample, each with its reason
and path; the generator refuses a `none` list whose integer type holds
-2^31; the readers' fuzz targets cover the new records with seeds the
generator writes from the declaration; a seeded validator without the
`parallel` check fails its test.

**The escape at the wire.** Names of 128 bytes made entirely of
controls and bidirectional overrides, preview lines of 4,096 such
bytes and a domain name of 255, each through the Erlang, LVGL and
browser renderers, are drawn as their tokens, cut at a whole token in
LVGL, and every record `erx_ui_lvgl` writes is accepted by the C
reader; a seeded `erx_ui_lvgl` that escapes without cutting fails it.

**The theme.** D7, and a `contrast` row naming an undeclared colour, refused.

**On QEMU, the `display_domain` suite.** One test, in the suite's one
cell, HVF at one CPU: the desktop's session runs `files` on a folder
of the suite's image and `month 11 2026`, and a screenshot through
QEMU's monitor equals the reference image; a seeded theme colour fails
it. stats and clock show live values, so the cell checks them through
the inspector instead of pixels: each window is listed under the display
domain's `[domains, Id]` record with its label, and over three seconds
stats' window's present count grows by at least two and clock's by at
most one, where a seeded stats that never samples fails the first and a
seeded once-a-second clock the second.

## Performance

Three costs are unmeasured and go on the performance watch list when
this part starts:

* a stats sample: about four inspector queries per domain per period,
  with each runtime's agent answering its share
  ([design-live.md](design-live.md#the-runtime-agent)); measured as the
  inspector's and the agents' CPU time per sample with twenty domains;
* `erx_mask`'s graph masks in Erlang: one stroke and one area mask
  per graph per sample, about twenty-five sparklines and four larger
  graphs at one second; measured as the renderer's time per sample;
* the Erlang renderer's time for a full files window of 256 items, at
  the first frame and at a selection change.

## Dependencies

| Component | Purpose | License | Status |
| --- | --- | --- | --- |
| Inter 4.1, Regular, Medium and SemiBold static TrueType fonts | the type of every role of the theme, rasterised by the glyph step into `k8` subfonts and LVGL fonts | OFL-1.1, font data only; the license text at tag `v4.1` names no Reserved Font Name (`LICENSE.txt`, SHA-256 `262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a`, fetched from `https://raw.githubusercontent.com/rsms/inter/v4.1/LICENSE.txt`) | permanent; the three font files are in the tree at `display/fonts/inter/` with the license and an `ORIGIN.md` recording the release archive, `https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip`, SHA-256 `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e` |
| FreeType 2.15.0 | the glyph step's rasteriser of the fonts' glyphs and of the icons' stroked paths, linked into erXos's host program `erx-raster` | FreeType License (FTL) or GPL-2.0-or-later, at the user's choice (`LICENSE.TXT`, SHA-256 `bd36c8b474855fa294c2ec5c184544478ef3720aad37d65a6296a4f264fd2d3b`); erXos uses it under the FTL, a BSD-style license (`docs/FTL.TXT`, SHA-256 `5a5ee54c5001bbad1cdc1a57cc3dd4c42199b2da09d39c7ee41fab002d02967f`), whose credit and binary-distribution clauses bind a program that contains FreeType, which no image does; its gzip module, which the `sfnt` module's WOFF and SVG-table readers link, is under the zlib license, compatible with the FTL (`LICENSE.TXT`, lines 35-36) | permanent build tool, never part of an image; `freetype-2.15.0.tar.xz` from `https://download.savannah.gnu.org/releases/freetype/`, SHA-256 `93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5`, fetched by the explicit fetch step and verified against that hash, compiled out of tree by erXos's own compiler invocations (`Erx::Raster::Build`) |

The icon set is erXos's own work, rasterised through FreeType with the
fonts. What an image carries from the glyph step is the coverage of
Inter's glyphs and of erXos's icons, never FreeType's code.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| The draw connection directly, for all four | each program would carry its own layout, hit testing, focus and text input, four times over, and none would render on LVGL or the web; the widget tree already owns these, and the two things it lacks, graphs and icons, are meaning it should state anyway |
| A widget toolkit for stats' graphs and a draw window beside it | two windows for one program, and a graph that neither LVGL nor the web can show |
| A graph as a PNG `image` the program encodes each sample | an encoder in the program, a picture of at most 48 KiB, and a value the renderers cannot read: no gap, no status, no parity |
| Icons as PNG images per item | 256 pictures in a list's tree, past the 64 KiB update, and icons that cannot follow the palette |
| Anti-aliased shapes in `erx_memdraw` | new native primitives over pixels for what masks already do with one existing draw; masks also cover glyphs and icons, so one mechanism serves all |
| The Go fonts | drawn by the designers of Lucida, Plan 9's face, and so the look this design moves away from; Inter is drawn for interface sizes and has tabular figures |
| A rasteriser of erXos's own in Ruby | outline decoding, curve flattening, exact coverage and stroking with round joins written and tested anew, for output a mature engine already gives; FreeType at a pinned release keeps the step reproducible as well |
| A dark palette beside the light one | a second value in every colour row, a setting that chooses between them and a second reference frame per program; the first version has one light palette |
| An icon set under a permissive license | a license and a style to inherit; twenty glyphs drawn for erXos are less work than reconciling a set's style with the theme |
| Packages under `examples/` | an app is its own principal, so stats and files would see the app's domains and files, not the person's ([Shipping](#shipping-and-starting)) |
| A tweened graph scroll | a renderer timer or many trees a second, against G6, for motion that adds nothing the step does not show |

## Decisions

1. **The new mechanisms this design names.** Two are new and accepted:
   the theme, `abi/theme.txt` with its generated module, header and
   constants, and six additions to `ui.txt` (`role`, `area`, `icon`,
   `icons`, `current` and `graph`, with list activation as a kind
   line), with three grammar additions: lists of integers or
   enumerations with an optional `none`, `within` applied to each value
   of a list, and `parallel`. The theme is the one source the look
   needs, without which every renderer and the decorations would each
   carry their own copy of the palette; the additions are meaning the
   tree should state, and each renderer gains them through the one
   declaration.
2. **Copy, move, rename and delete are not files'.** The commands do
   them; a window that deletes needs a trash or an undo, confirmation
   and conflict policy, which deserve their own design once there is a
   desktop to use them on.
3. **One palette, light.** The theme declares one palette, so there is
   no setting to choose between palettes, in the display's manifest
   entry, in its `screen` file or in a session's environment. A dark
   palette is work in `TODO.md`.
4. **No title bar.** A title bar with the window's label would change
   `decorate/2`, which returns rectangles and colours, to return a label
   too, a change to design-display's overlapping policy that belongs
   there; the decorations are borders.
5. **Time zones.** clock and month show UTC and say so. A zone needs a
   time zone database and a setting, FreeBSD's `/etc/localtime` over
   `zoneinfo`, which no design names; that is a design of its own,
   after which both programs take local time with no other change.
6. **What the desktop opens at its start.** Nothing beyond the
   terminal, as design-display's desktop session does; the session
   template's arguments can add `files` and `clock` once a person wants
   them there.
7. **The names.** `stats`, `clock` and `files` are free in FreeBSD's
   `usr.bin`; `cal` and `calendar` are FreeBSD's, so the calendar is
   `month`.
8. **How the menu loads its glyphs.** The glyph step writes the `body`
   role's glyphs as generated data, an Erlang module of metrics beside
   the raw `k8` rows, which the menu loads with `erx_memdraw:load/3`, so
   the display release reads no font file and G9 is unchanged;
   design-display records it
   ([design-display.md](design-display.md#windows-and-the-window-system)).
9. **Machine-wide CPU load is visible to every session.** The
   inspection schema marks a CPU's `idle_time` and `ready_threads`
   `visible any`, as `memory_total` and `memory_free` are, and `[cpus]`
   carries no `visible all` mark of its own, so a scoped facet reads the
   machine's busy share and ready threads, and stats' machine panels
   read the same in every session. The two figures tell one principal
   how busy the others keep the machine; design-live accepts that side
   channel beside free memory's ([design-live.md](design-live.md#inspection),
   "Scopes").
10. **Padding is inside the node.** A node's `pad` is space between its
    edge and its content, as LVGL and CSS read padding; design-display's
    property table and box model say so ([Spacing and
    layout](#spacing-and-layout)).
11. **The glyph rasteriser is FreeType**, run as a host build tool:
    fetched at a pinned release and SHA-256, compiled out of tree, and
    linked only into erXos's host program `erx-raster`, which rasterises
    the fonts' glyphs and strokes and rasterises the icons. Nothing of
    FreeType enters an image.

## Open decisions

1. **The LVGL renderer's cut after the escape.** design-display has
   `erx_ui_lvgl` escape each text before it encodes, and the readers
   refuse a text past its property's bound, so any program's valid
   text that is heavy with controls can become a record `erx-lvgl`
   refuses ([The escape and the wire's
   bounds](#names-and-contents-are-untrusted)). Recommendation:
   design-display states that `erx_ui_lvgl` cuts the escaped text to the
   property's bound at a whole character or token and ends it with an
   ellipsis, and the parity test carries control-heavy texts of every
   bound; no program cuts for a renderer.

## References

* [design-display.md](design-display.md): widget trees, the widget
  server and its renderers, the draw connection, presentations, the
  window system, G4 to G9
* [design-live.md](design-live.md): inspection records and paths,
  attributed text, `/proc`
* [design-files.md](design-files.md): namespaces, text in file names,
  the Erlang file client
* [design-time.md](design-time.md): the time page and the clock's
  `state`
* [design-shell.md](design-shell.md): commands
* [design-packaging.md](design-packaging.md): apps' principals, the SDK
  and `erx_ui_host`
* `abi/formats/ui.txt`, `abi/inspection.txt`
* `display/libmemdraw/draw.c`, lines 486-500 and 1065
* LVGL 9.6.0: `include/lvgl/config/lv_conf_internal.h`, lines 674-684
  and 2670-2680; `lv_conf_template.h`, lines 281-284;
  `src/widgets/chart/lv_chart.c`, line 424
* Inter 4.1, `LICENSE.txt` at tag `v4.1` (SHA-256 above)
* FreeBSD `usr.bin/Makefile` at commit `95719d8a895b`, lines 95 and 189
* plan9port at commit `1f13969`: `man/man7/font.7` (SHA-256
  `fe1ca23bb73034dbf98d330127f636ce18c7453014fee3554a872790385c5688`)
  and `man/man7/image.7` (SHA-256
  `bb541ffbf5dae3e080d9a9a6609f673efac143426cd0b8c65b1a76fca7619735`)
* WCAG 2.2, W3C Recommendation 12 December 2024,
  `https://www.w3.org/TR/2024/REC-WCAG22-20241212/` (SHA-256
  `6e3c5fe397257cae509a2fb4752b73062cf8cbeb92c2cec618989b17e4cf7057`):
  the definitions of "contrast ratio" (`#dfn-contrast-ratio`) and
  "relative luminance" (`#dfn-relative-luminance`), which the
  generator cites and implements
* CSS Fonts Module Level 3, W3C Recommendation 20 September 2018,
  `https://www.w3.org/TR/2018/REC-css-fonts-3-20180920/` (SHA-256
  `e3982d57e3992dfa7c0e56c1ff39977bd71d807731247decc794c61d2eacd63b`):
  section 3.2, `font-weight`, the numeric weights of `regular` (400),
  `medium` (500) and `semibold` (600)
* FreeType 2.15.0, `freetype-2.15.0.tar.xz` (SHA-256 above):
  `LICENSE.TXT`, lines 9-26, and `docs/FTL.TXT` (SHA-256s above);
  `docs/INSTALL.ANY`, lines 28 and 134-139 (SHA-256
  `945ea1d154cdbd7d4de906c012361c7ec8699fce02af952f6bc447dd3b632cc4`);
  `include/freetype/freetype.h`, lines 3502 and 4428 (SHA-256
  `7a343a0240598631b53adea94284d376979f42cf215e6ad7cfe932d96762497b`);
  `include/freetype/ftstroke.h`, lines 136, 168 and 310 (SHA-256
  `ba4ed8f81ac66e9e6a2cdf772b69da02a0085fc5576cd233e4da661c6fb1967c`);
  `include/freetype/ftoutln.h`, line 496 (SHA-256
  `db0585ea338debdb9b721adc5f6d138ec7f88df30ff44cf6fb3cac79a70982f8`);
  `src/smooth/ftgrays.c`, lines 45-48 and 63 (SHA-256
  `4ed0d154876ae4caf440224a04df9dc3f4bedd82e2b0fbb7e016de1d718c5379`)
