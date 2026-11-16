# UI survey: interaction, UX, and novel or forgotten ideas

A point-in-time research record (2026-11-15) for one part of the erXos
desktop survey: interaction and UX, historical systems whose ideas never
went mainstream, today's platforms, and current research. For each idea:
what it is, why it did or did not catch on, and whether erXos's
architecture makes it newly practical. Fonts, toolkits and rendering belong
to other parts of the survey.

**Method.** Every document cited was fetched over HTTPS on 2026-11-15 into
`/Users/stas/erxos-scratch/sources/ui-survey/ux-ideas/raw/`, converted to
text in `txt/` (`textutil`, `pdftotext`) and read there. A citation such as
`[acme]` is a row of the source table at the end (URL, SHA-256). No GPL or
LGPL source code was read; for GPL projects (niri, PaperWM, Eagle Mode,
Looking Glass) only READMEs, home pages and encyclopedia articles. Claims
resting on Wikipedia, a secondary source, say "(Wikipedia)". Anything no
fetched source supports is marked **unverified**. Not fetchable (JavaScript
or refused): Apple's support pages for Stage Manager, Mission Control and
Focus; Apple's App Intents and visionOS HIG pages; Material 3's site; the
Mercury OS essay on Medium (HTTP 403); MIT's copy of Ciccarelli's
presentation thesis (HTTP 429).

**What erXos is compared against** (master `9abb9e91c`):
`docs/design-display.md` serves each window as a file tree (`ctl`,
`mouse`, `kbd`, `wctl`, `label`), Plan 9 style; has one window system with
two policies, **overlapping** (rio's) and **single** (kiosk); composes
client buffers on the CPU; draws declarative **widget trees** from Erlang
apps through Erlang, LVGL or browser renderers; and has **presentations**,
typed values derived from the inspection schema (pids, domains, modules,
budgets, programs, devices) whose canonical text the shell parses back.
Selecting a presentation inserts its text or sends the app
`{select, Type, Value}`, and grants nothing (lines 132-141, 184-189, 428,
1563-1620). `docs/design-desktop-programs.md` gives stats, clock, month and
files with borders but no title bars and one light palette;
`docs/design-shell.md` gives rc with text pipes.


## Summary

1. erXos's interaction architecture already holds the two ideas of this
   domain that history rates highest and the mainstream never adopted:
   Plan 9's per-window file trees and Genera's presentations (typed output
   that stays bound to its value). They are not "old desktop tech" in the
   sense the concern means; the mainstream keeps rediscovering parts of
   them (command palettes, Raycast, Durden's "every action is a path").
2. The weak spot is the layer above the windows, here called **find and
   act**: erXos has no command palette, no plumber, no previewer, no
   notification and focus model, and no window overview. Nearly every
   well-remembered system in this field is strong exactly there: Oberon,
   acme, CLIM, NeXT Services, Spotlight, Quicksilver, Raycast.
3. The most valuable addition is **one table of typed commands**, shown as
   a keyboard palette, as a context menu on a presentation, and as
   Services-style "act on this" entries. It is the CLIM command loop
   [mcclim-manual] with Oberon's `Module.Procedure` commands
   [oberon-system], which map onto Erlang's `Module:Function`. erXos has the
   hard parts already: presentation types, their grammars, and
   facet-checked commands.
4. Second, a **plumber** [plumb] served by the session as a file tree with
   declarative rules, so the content of what is clicked decides where it
   goes. Per-process namespaces and file servers, which kept the plumber
   inside Plan 9, are everywhere in erXos.
5. Third, **"what is this?" everywhere**: a chord that shows, for any
   pixel, the owning process, its supervisor, its code and its widget node
   through the inspector. That is Smalltalk's Reactive Principle
   [smalltalk-ingalls], Morphic's core sampler [self-morphic], Star's Show
   Properties [star-retro] and NeXT's inspectors [wiki-nextstep], done
   across isolated processes.
6. Window management evidence points to tiling: Star's testers rearranged
   windows until none overlapped [star-retro], Oberon judged overlap not
   worth its cost [oberon-system], acme tiles [acme], and scrollable tiling
   (niri, PaperWM) is today's liveliest idea [niri-readme]. A
   **scrollable-strip policy** fits erXos's "a policy only decides
   geometry" as a third policy, at small cost.
7. Zooming, 3D and physics desktops, compound documents and spatial
   computing do not fit: they need GPU composition erXos does not do, or
   failed for reasons erXos would inherit.

## The systems, one by one

In "fit", **adopt** means worth building, **have** means erXos already has
it, **lesson** means a rule to keep, and **no** means it does not fit.

### The pioneers

**Engelbart's NLS (1968).** A 90-minute live demonstration at the Fall
Joint Computer Conference [engelbart-demo] showed the mouse, hypertext,
shared screens and structured documents; workstations had a three-button
mouse and a chord keyset [wiki-nls]. *What failed:* its learning curve:
"heavy use of program modes ... a strict hierarchical structure ... no
point-and-click ... cryptic mnemonic codes" (Wikipedia, [wiki-nls]).
*Fit:* lesson. erXos's structured objects (the inspection schema) must be
reachable by pointing and by completed typing, never by memorised codes.

**Xerox Alto (1973) and Star (1981).** About 2,000 Alto IIs were built
[wiki-alto]; Star was the first commercial system with several programs on
screen [star-retro]. Its designers' retrospective [star-retro] is the most
useful document of this survey for erXos, because it records ideas and
mistakes alike:

* **Generic commands**: "Move, Copy, Open, Delete, Show Properties, and
  Same (Copy Properties)" on dedicated keys, each interpreted by the object;
  printing was Copy onto a printer.
* **Data, not tools**: Star rejected the "Tools metaphor" of starting
  programs and opening files, and admitted the cost: using a file with
  another program "must be handled in Star in an ad hoc way, whereas
  systems like Unix allow almost any file to be run through a wide variety
  of programs".
* **Tiled windows**: "users spent a lot of time adjusting windows and
  usually adjusted them so that they did not overlap", so application
  windows were kept from overlapping; dialogs still overlapped.
* **What failed**: a monolith ("the system 'knew' about all
  applications"), closed ("Star should have been designed to be open and
  extensible by users from the start, as the Alto was"), priced against
  minicomputers while competing with PCs, without firm performance goals.

*Fit:* adopt the generic verbs; keep the lessons. In erXos every object
already answers generic verbs, because everything is a file tree or an
inspection path; Show Properties is the inspector. Star's admission is the
case for a plumber with rules, so data-first does not lock data to one
program. Its monolith is the warning against a desktop that "knows" every
app; erXos's apps are separate processes added at run time.

**Smalltalk-80.** Ingalls's "Design Principles Behind Smalltalk" (Byte,
1981) [smalltalk-ingalls] reads like a specification of erXos's inspector:
"**Reactive Principle**: Every component accessible to the user should be
able to present itself in a meaningful way for observation and
manipulation", and "An operating system is a collection of things that
don't fit into a language. There shouldn't be one." *What failed (as a
desktop):* one image, one address space, no isolation; its later market
history is **unverified**. *Fit:* have, partly. Erlang with `/proc` and the
inspector is the nearest an isolated multi-domain system gets to the
Reactive Principle; missing is the gesture that makes it felt (ranked 3).

### Presentations and commands

**Genera, Dynamic Windows, CLIM.** Dynamic Windows (Genera 7, 1986) types
all screen output and "keeps its connection to the objects displayed";
applicable operations follow from the object's class and the commands,
which live in "hierarchical command tables with typed parameters" entered
by mouse, keystroke or command line, and "all applications share one
command line interpreter" (Wikipedia, [wiki-genera]). CLIM carried
presentations to other Lisps [wiki-clim]. The McCLIM manual states the
point: toolkits run event handlers "in a null context", while CLIM runs a
**command loop**: acquire a command (menu, typed name, key, button or a
clicked object); acquire its arguments, where "visible objects of the right
presentation type can be clicked on ... You can also type a textual
representation of the argument, using completion"; run it; redisplay.
"Application logic is completely separate from interaction policies"
[mcclim-manual]. *What failed:* the Lisp machine; Genera ran only on
Symbolics hardware or its emulator [wiki-genera], and CLIM stayed in the
Common Lisp world [wiki-clim]. *Fit:* have half, adopt the other half.
`design-display.md` (lines 184-189) takes presentations and drops the
single address space (a presentation is a type and a text and grants
nothing, G4). Not yet taken: the **command loop with typed arguments**.
Today a click on a presentation inserts text or sends one event to one app;
with a declared command table, the same types fill the arguments of any
command, by click or by completed text (ranked 1).

**Oberon (ETH Zurich, late 1980s).** The screen is tiled into **viewers**,
each a title bar with a command menu over a content frame [oberon-system].
Overlap was rejected: hidden windows "are typically brought to the top and
made fully visible before any operation is applied ... the benefit of a
complication is incommensurate with its cost". A program is "far too large
unit of action to serve as a command"; a command is an exported procedure
`M.P`, "invoked at any time by pointing at its name in any text visible in
any viewer ... and by clicking the middle mouse button", loading `M` if
needed [oberon-system]. *What failed:* a single-user, single-process system
in one language [wiki-oberon], used mostly inside ETH. *Fit:* adopt the
command model with erXos's rule added. `M.P` is Erlang's `M:F`, and loading
on first call is what the code server does; but clicked text must never
call arbitrary functions, so only commands in a declared table, run through
the actor's facets, execute. That table is the palette's.

**Plan 9: 8½/rio, acme, plumbing.** 8½ serves each window as files
(`cons`, `mouse`, `bitblt`) in a private namespace [rio-pike]; erXos has
this. **Acme** is "a hybrid of window system, shell, and editor" with
columns of automatically placed windows, "to avoid asking the user to place
and arrange them" [acme]. Each window's **tag** is editable text holding its
name and commands; the middle button executes any text, the right button
opens or searches it, and `dat.h:27` jumps to the line. Each window is a
directory `/mnt/acme/N/` (`addr`, `body`, `ctl`, `data`, `event`, `tag`); a
program reading `event` "is asked to interpret all middle- and right-button
actions" [acme], so outside programs give a window behaviour without a
plug-in API. The **plumber** is a file server: programs write to
`/mnt/plumb/send`, and pattern-action rules route messages to ports such as
`/mnt/plumb/edit`. "Unlike with drag and drop or cut and paste, the user
doesn't need to deliver the data; the contents of a plumbing message, as
interpreted by the plumbing rules, determine its destination" [plumb].
*What failed:* nothing in the design; it needs per-process namespaces and
file servers, which UNIX and Windows lack. Acme's mouse chords [acme] may
have kept it niche (**unverified**). *Fit:* adopt the plumber. erXos has
both preconditions, and a plumber is one of the design's three homes ("a
thing someone commands is a file tree its owner serves"). Its rules suit
principle 4, but the rule language (Plan 9's grammar, awklog or Datalog)
needs approval. Acme's `event` file is a lesson that erXos already follows:
widget events go to the app, not the display.

### Object and document desktops

**NeXTSTEP: Services, Dock, Workspace, inspectors.** NeXTSTEP introduced
the Dock and Shelf, system-wide drag and drop, "system-wide piped
services" and properties panels called "inspectors" (Wikipedia,
[wiki-nextstep]); its File Viewer used Miller columns [wiki-workspace].
Services: "An application does not need to know in advance what operations
are available; the application merely needs to indicate the types of data
it uses" [apple-services]. *What failed:* Services stayed obscure, and the
menu "tends to clog up with dozens of entries" because apps install them
unasked [wiki-services]; the macOS Dock grew into launcher, switcher and
shelf at once [wiki-dock]. *Fit:* adopt Services inside the typed command
table (offer the commands whose argument type matches the selection), rank
by context and use, and let users hide entries. No Dock is needed: the
owner's fixed furniture (stats, clock, calendar, files) fills that role.
Miller columns suit `files` for deep trees like `/proc` (small).

**BeOS and Haiku: Tracker, attributes, live queries.** Any file carries
typed attributes, shown and edited as Tracker columns; People files are
"0-sized files with attached attributes" [haiku-attributes]; queries are
saved as formulas, not results [haiku-queries]. Giampaolo defines a **live
query** as "a persistent query that monitors all file operations and
reports additions to and deletions from the set of matching files", e.g.
`MAIL:status = New` "and not require polling", and warns of "many subtle
locking issues" [bfs-book]. *What failed:* the company: Apple chose NeXT
over Be in 1996 and Palm bought the assets in 2001 (Wikipedia,
[wiki-beos]); Spotlight later brought metadata search to macOS
[apple-spotlight-arch]. *Fit:* adopt for live state, not files. `/proc` is
live state, so live queries over inspection paths ("processes that
restarted more than N times") would let stats and files stop polling. An
indexed attribute file system is the costly, subtle part; WinFS shows how
such projects end (below).

**OpenDoc, OLE, Taligent, Cairo, Workplace Shell.** OpenDoc (1992-1997)
built documents from vendors' components; analysts and users "had very
different views" of it, few components shipped compared with ActiveX, and
Jobs cancelled it in 1997 (Wikipedia, [wiki-opendoc]); OLE survives in
Office [wiki-ole]. That one crashing part took down a document is
**unverified**. Taligent's object-oriented OS found "little interest in a
new OS" and dissolved into IBM [wiki-taligent]. Cairo's object file system
returned as WinFS and was cancelled in 2006 [wiki-cairo]; OS/2's Workplace
Shell was an object desktop on SOM [wiki-workplace-shell]. *Fit:* no, and
lessons. Process isolation and supervision would fix crash coupling, but
these failed on coordination, incentives and cost. Keep files as files;
structure lives in the inspection schema already.

**Newton and HyperCard.** Newton's early handwriting recognition drew bad
reviews (Wikipedia, [wiki-newton]); its object store ("soups") is
**unverified** here. HyperCard, "a software erector set" with an editable
script on every object, "was successful almost instantly", got its last
update in 1998 and was withdrawn in 2004 [wiki-hypercard]. *Fit:* lessons:
ship the reliable input path first; end-user construction can succeed and
still be dropped for business reasons.

### Humane and modeless interfaces

**Raskin: The Humane Interface, Canon Cat, Archy.** Raskin argued for no
**modes**, or **quasimodes** that last only while a key is held; one way to
do each thing; universal undo even across restarts; no "are you sure?"
prompts, which habit defeats; and **ZoomWorld**, one zoomable plane of all
documents (Wikipedia, [wiki-humane]). The Canon Cat had no mouse or icons,
one stream of text, and commands under a held "Use Front" key; about
20,000 were sold [wiki-canoncat]. **Archy** added a zooming interface,
**Leaping** (incremental search on thumb keys) and commands that "can be
inserted and executed at any place", typed while holding the command key
[wiki-archy]. *What failed:* Raskin died in 2005 [wiki-raskin]; Archy
stalled and was non-commercial until 2017 [wiki-archy]; the Cat was a
single-purpose machine. *Fit:* adopt the quasimode (a held key opens the
palette while held; erXos's reserved chord is one already); incremental
search everywhere; undo in each program that edits (rename, move, delete to
a trash folder) rather than system-wide, which would need versioned state
in every service. ZoomWorld: no (below).

### Spatial interfaces

**Zooming interfaces.** Pad++ (1994) made zooming "the fundamental
navigational technique" and introduced **semantic zooming**, where a
zoomed-out object draws a simpler form [padpp]; the paper gives a section
to keeping "an intuitive sense of location". The line ran on through
Jazz, Piccolo and Piccolo2D (Wikipedia, [wiki-zui]); Eagle Mode (GPL C++)
still ships a zoomable cosmos of file manager, viewers and games
[eaglemode]. *What failed:* no general desktop adopted one (**unverified**
as a survey of adoption). *Fit:* no. Multi-scale redraw on a CPU
compositor at Pi resolutions contradicts "an idle window costs nothing".
Semantic zoom's one cheap use is an overview that shows window summaries.

**Looking Glass, BumpTop, visionOS.** Sun's Java 3D desktop began as one
engineer's spare-time project and is inactive (Wikipedia,
[wiki-lookingglass]). BumpTop (CHI 2006) used **piles** and physics,
"objects can be casually dragged and tossed around" [bumptop]; Google
bought and withdrew it in 2010 [wiki-bumptop]. visionOS targets by gaze and
commits by pinch; reviewers praised "the window mechanics" while
criticising the hardware (Wikipedia, [wiki-visionos]). *Fit:* no; GPU or
headset needed. One lesson carries: separating targeting from committing is
the same split as pointing at a presentation and pressing a key.

### Live, malleable systems

**Self/Morphic, Squeak, Lively Kernel.** In Morphic every visible thing is
a morph in a tree of **submorphs**, and the **core sampler** "shows the set
of submorphs below a given point" [self-morphic]. Morphic moved to Squeak
and to JavaScript as the Lively Kernel (Wikipedia, [wiki-morphic]), which
"is able to edit its own code and graphics" [lively-wiki]. (Maloney and
Smith's UIST 1995 paper sits behind an ACM sign-in; not read.) *What
failed:* single images without isolation stayed research and teaching tools
(**unverified** as a cause). *Fit:* adopt two parts. The core sampler:
widget trees have stable node ids, so "what is under the pointer" resolves
to a window, a process and a node, each a presentation. Liveness: Erlang
reloads a running app's module and the widget server diffs trees, so an
edited desktop program updates in place, without an image and without
losing isolation.

**Bret Victor and Dynamicland.** "Magic Ink": most software is information
software, context should be inferred from environment and history, and
"interactivity considered harmful. The user can suggest what's relevant,
but only as a last resort" [victor-magicink]. "Learnable Programming": "see
the state" and "create by reacting" [victor-learnable]. Dynamicland is "a
computer that is a place" (Realtalk), and argues it "cannot be a product"
[dynamicland]. *Fit:* lesson, supporting erXos's direction: stats, clock
and month are information software, and the inspector is "see the state".

**Ink & Switch and Mercury OS.** "Local-first software" lists seven ideals,
from "No spinners" to "The network is optional", on CRDTs [localfirst].
Muse is a spatial iPad "studio for ideas" [muse]. Potluck proposes
**gradual enrichment** from plain notes to tools through saved searches
[potluck]; Embark does it for travel plans, against apps that "don't share
broader context" [inkswitch-embark]. "Malleable software" (2025) argues
"tools, not apps", "a gentle slope from user to creator", and that AI code
generation alone leaves the question of how tools "compose with one another
... over shared data" [malleable]. Mercury OS is "a reimaging of the
operating system as a fluid modeless experience drive[n] by human intent"
[mercury-home]; its details (modules, flows, spaces, a "locus") are
**unverified** here. *Fit:* lesson with a hook. erXos already names shared
data (files, inspection paths) and its apps are small Erlang programs
sending declarative trees; a typed command table plus a plumber is the
composition layer the essay finds missing. Local-first sync is a separate,
later subject.

### Window management

**Overlap versus tiling.** Star tiled; Cedar (1982) tiled; Windows 1.0
tiled, partly over Apple's litigation, and "due to complaints" 2.0
overlapped (Wikipedia, [wiki-tiling]). Oberon [oberon-system] and acme
[acme] tiled by design. 8½ chose overlap "by fiat", for familiarity, as
mux's successor [rio-pike]. i3 splits containers in a tree and offers an
IPC interface on a UNIX socket for bars and scripts [i3-guide].

**Scrollable tiling: PaperWM and niri.** PaperWM brings scrollable tiling
to GNOME Shell [paperwm-readme]. Niri arranges windows "in columns on an
infinite strip going to the right. Opening a new window never causes
existing windows to resize", with one strip per monitor and dynamic
vertical workspaces [niri-readme]; major distributions package it
(Wikipedia, [wiki-niri]). It removes classic tiling's flaw (a new window
shrinks the others) and keeps its virtue (nothing hides behind anything).
*Fit:* adopt as a third policy. A policy "decides geometry and which window
takes each input event, and nothing else" (`design-display.md` 70-76), so a
strip policy is a module beside `erx_wm_rio` and `erx_wm_single` with no
client change. Scrolling by whole columns, without animation, keeps CPU
composition cheap. Which policy is the default is the owner's call.

**Exposé, Mission Control, Stage Manager.** Exposé (2003) showed all
windows to pick one; Lion merged it with Spaces and Dashboard as Mission
Control in 2011 (Wikipedia, [wiki-expose]). Ventura (2022) added Stage
Manager "as an alternative interface for multitasking" [wiki-ventura]; its
layout and mixed reception are **unverified**. *Fit:* adopt a plain overview
chord under the overlapping policy, with thumbnails downscaled on the CPU
and cached at each present; its cost on a Pi 4 needs measuring.

### Find and act

**Spotlight and Quick Look.** Spotlight (Tiger, 2005) indexes metadata
through per-format importers [apple-spotlight-arch], [wiki-spotlight];
Quick Look (10.5) previews through per-type generators [apple-quicklook].
*Fit:* adopt Quick Look's shape with isolation: a previewer that parses an
untrusted file runs in a sub-space holding a read grant to that file and a
buffer, never in `files` or the display domain ("code of unknown
provenance runs only in an address space of its own"). A content indexer is
a later decision.

**AppleScript and Shortcuts.** AppleScript drives apps through Apple events;
Apple cut its automation product manager's role in 2016 (Wikipedia,
[wiki-applescript]). Shortcuts began as Workflow, bought in 2017, and runs
from widgets, share sheets, Siri and triggers [wiki-shortcuts]. *Fit:* have
the substrate: everything in erXos is a file or a message reachable from rc
and the Erlang shell, and a command table gives scripts the same verbs.

**Quicksilver, PowerToys, Raycast, palettes.** Quicksilver (2003) offered
"an object, an action, and an optional attribute—analogous to creating a
sentence" over a catalog, with incremental search (Wikipedia,
[wiki-quicksilver]). PowerToys Run (Alt+Space, prefix-chosen plug-ins)
[pt-run] is giving way to Command Palette, "designed for keyboard-first
workflows" [pt-cmdpal]. Raycast extensions use TypeScript and React: "You
concentrate on the logic, we push the pixels" [raycast-dev]; its manual
lists script commands, window management, clipboard history and AI agents
[raycast-manual]. VS Code made Ctrl+Shift+P standard [vscode-ui]. A palette
is "a searchable index of software commands" that "may include commands
not exposed elsewhere" [wiki-cmdpalette]. *What failed:* nothing; this is
the strongest mainstream trend here. Its weakness is silos: each product
keeps its own registry and does not know the type of the selection
(**unverified** beyond the products read). *Fit:* adopt (ranked 1). erXos
can have one system-wide table whose commands take typed arguments from
presentations: Quicksilver's object and action, with types. The palette is
a widget-tree app, which is Raycast's "we push the pixels" model.

### Current platforms

**Material You.** Android 12 (2021) generated themes from the wallpaper;
"Material 3 Expressive" followed in 2025 (Wikipedia, [wiki-material]). Its
colour utilities define **HCT**, "hue, chrome, tone ... based on CAM16 x
L*", with contrast tools [m3-color-utils]. *Fit:* wallpaper themes conflict
with the single light palette; a perceptual contrast check at build time is
for the visual-design part of the survey.

**GNOME, KDE, COSMIC.** GNOME Shell centres on the Activities overview
(Wikipedia, [wiki-gnome-shell]); its guide says to "question whether users
really need to be informed" and to summarise instead of notifying per
message [gnome-hig-notif]. Plasma 6 moved to Qt 6 and Wayland and merged
Overview with Desktop Grid [kde-plasma6]; KDE's rule is "Simple by default,
Powerful when needed" [kde-hig]. COSMIC was rebuilt on the Iced toolkit
(Wikipedia, [wiki-cosmic]). *Fit:* lesson. They converge on an overview,
tiling options and restrained notifications, all cheap for erXos to match;
none has anything like presentations or per-window file trees.

**Arcan and Durden.** Arcan is a display server and multimedia framework
with Lua scripting and its own IPC [arcan-about]. In Durden (BSD), "all
actions ... are mapped into a huge virtual filesystem tree. Keybindings, UI
buttons etc. are all simply paths" [arcan-durden]. *Fit:* precedent for
serving the command table as a file tree, so a binding is a path and rc can
call any UI action.

### Cross-cutting questions

**Notifications and focus.** iOS 15's Focus states (Work, Sleep, custom)
filter notifications by app and contact and sync across devices
(Wikipedia, [wiki-ios15]). People "compensate for interruptions by working
faster, but this comes at a price: experiencing more stress, higher
frustration, time pressure" (Mark, Gudith, Klocke, CHI 2008
[mark-interrupt]). *Fit:* adopt, designed before the first app notifies: a
notification is state someone reads (an inspection path) plus a way to
show it; policy (rate, summaries, focus states, who may notify) sits in
the session; app text reaches the screen only through the sink's escaping.

**Keyboard and mouse.** Screen edges and corners are "infinitely large
targets in one dimension" [wiki-fitts]. Pie menus select by direction; a
1988 test measured 15% less selection time and fewer errors than linear
menus, and Maya uses the marking-menu form (Wikipedia, [wiki-pie]).
Acme puts the mouse first [acme], the Cat and Archy the keyboard
[wiki-canoncat], [wiki-archy], Command Palette says "keyboard-first"
[pt-cmdpal]. *Fit:* both through one table: the palette for keys, context
menus on presentations for the pointer, a radial menu for touch kiosks
(whether LVGL has one is **unverified**), corners for the overview chord.

**Direct manipulation and discoverability.** Shneiderman (1983):
"continuous representation of the object of interest", physical actions,
"rapid, incremental, reversible operations whose impact ... is immediately
visible" [shneiderman-dm], [wiki-dm]. Palettes aid discovery because each
entry shows its binding [wiki-cmdpalette]; CLIM shows the commands that
apply under the pointer [mcclim-manual]. *Fit:* lessons: drag-to-move in
`files` needs undo, and every chord and quasimode also appears in the
palette with its binding.

**Object-oriented versus app-centric desktops.** Star [star-retro],
Workplace Shell [wiki-workplace-shell], OpenDoc [wiki-opendoc] and Cairo
[wiki-cairo] went object-first; NeXT [apple-services] and BeOS
[haiku-attributes] half way; the market went app-first; Ink & Switch now
calls app silos the problem [malleable]. Object desktops needed every
vendor to implement shared object protocols, and the incentives were not
there. erXos stands in a third place none of them had: data shared and
named by the system (files, typed inspection paths), apps as supervised
processes, and **commands rather than objects** as the shared vocabulary.

## What erXos's architecture makes newly practical

| Idea | What held it back | What erXos supplies | Verdict |
| --- | --- | --- | --- |
| Genera presentations | Lisp hardware; the presentation was the object | type plus text from the schema, granting nothing | have; extend |
| CLIM command loop | Common Lisp only | presentation types and parsers; facet-checked commands | adopt |
| Oberon `M.P` commands | one process; any text could run anything | Erlang `M:F`, code loading; a declared table and facets | adopt via the table |
| Plan 9 plumber | needed namespaces and file servers | both, everywhere; declarative rules | adopt |
| BeOS live queries | indexed attributes, subtle FS locking | `/proc` is live state | adopt if change reports exist |
| Reactive Principle, core sampler | one image, no isolation | inspector over all processes; stable widget node ids | adopt |
| Smalltalk/Lively liveness | images, no security | per-module hot loading; tree diffs keep state | adopt for development |
| Star generic verbs | every object had to implement them | file trees and inspection paths answer them | adopt in the palette |
| NeXT Services | clogging, obscurity | type matching and ranking from one table | adopt in the table |
| Raskin quasimodes | niche hardware, unfinished project | the reserved-chord pattern | adopt for the palette key |
| Quick Look generators | (succeeded on macOS) | sub-spaces for untrusted parsers | adopt with isolation |
| OpenDoc parts | coordination and incentives | isolation fixes crashes, not the cause | no |

These ideas mostly died with the systems that hosted them, not on their
merits. Most needed a typed, inspectable system with a namespace per
process and cheap isolation, and erXos is one.

## (a) Ranked: worth adopting or prototyping

1. **One typed command table, shown as palette, context menu and
   Services.** Commands are exported Erlang functions with arguments typed
   by presentation types (CLIM, Oberon, Quicksilver, NeXT). It makes every
   action scriptable, bindable and discoverable, and removes per-app
   command plumbing. *Size:* medium to large: a design section (it is a new
   mechanism the design must name), a palette app as a widget tree, and
   completion from the existing presentation grammars. Serve it as a file
   tree, as Durden does [arcan-durden].
2. **A plumber**: send and port files and declarative rules that route
   clicked text, presentations and paths [plumb]; the UNIX-respecting
   answer to Star's "data locked to its application". *Size:* medium: a
   session service, a rule reader with its fuzz target, a rule-language
   decision.
3. **"What is this?"**: a chord over any pixel opens the inspector on the
   window's process, supervisor, loaded code and widget node
   [self-morphic], [smalltalk-ingalls], [star-retro]. It makes erXos's
   distinctive property visible in one gesture. *Size:* small to medium;
   the inspector and pid presentations exist.
4. **A scrollable-strip window policy** [niri-readme], backed by Star's and
   Oberon's findings; keep rio's overlap beside it. *Size:* small: one
   policy module and tests, no client change.
5. **A notification and focus design** before any app notifies
   [mark-interrupt], [gnome-hig-notif], [wiki-ios15]. *Size:* medium design,
   small first build; later means retrofitting every app.
6. **Live queries over inspection paths** [bfs-book], so stats and files
   stop polling and users can save queries. *Size:* medium, depending on
   change reporting (open question).
7. **Previewers in sub-spaces** for `files` [apple-quicklook]. *Size:*
   medium.
8. **An overview chord** for the overlapping policy. *Size:* small to
   medium; measure thumbnail cost on a Pi 4 first.
9. **Live reload of desktop programs in development** through hot code
   loading and tree diffs. *Size:* small, mostly tooling.
10. **Small rules:** a held quasimode key for the palette; incremental
    search everywhere; undo in every editing program; every chord listed in
    the palette; Miller columns in `files`. *Size:* small each.

## (b) Attractive, but they do not fit

* **Zooming desktops** (Pad++, Eagle Mode, ZoomWorld): multi-scale redraw
  fights CPU composition and idle-costs-nothing; no desktop adopted one.
* **3D and physics desktops** (Looking Glass, BumpTop): GPU compositor
  needed; both abandoned.
* **Spatial and room-scale computing** (visionOS, Dynamicland): hardware
  erXos does not target; Dynamicland says it cannot be a product.
* **Compound documents and object stores** (OpenDoc, OLE, Taligent, Cairo,
  WinFS, a BFS-style attribute index): failed on coordination and cost,
  which isolation does not remove.
* **System-wide universal undo** (Raskin): versioned state in every
  service; keep undo per program.
* **Users editing the system UI in place** (Lively, Smalltalk images):
  conflicts with signed packages and the trusted display domain; hot
  reload in development and run-time apps give most of the benefit.
* **Chord-heavy input** (acme's chords, NLS's keyset): NLS's history warns
  against it; chords only as accelerators the palette also lists.
* **Wallpaper-derived colour** (Material You): conflicts with the single
  light palette.
* **Mercury OS's "no apps"**: a concept without an implementation; its
  intent-first part is the palette.

## (c) Open questions and unverified points

Questions for the owner or the design:

* Default desktop policy: rio's overlap (current design) or a scrollable
  strip, with the other available? Advisors should see [star-retro] and
  [oberon-system].
* The plumber's rule language: Plan 9's grammar, awklog or Datalog?
  Principle 4 favours declarative; the language approval rule applies.
* The command table is a new mechanism: a declared protocol or a session
  file tree, with a design before code.
* Can the 9P file servers and the inspection protocol report changes, so
  live queries do not poll? Not checked here.
* G4 must survive: the terminal and widget server still call no facet;
  the command table, run through the actor's facets, stays the only route
  from a presentation to an action.

Unverified in the text: Smalltalk's market history; Morphic and Lively's
adoption limits; OpenDoc's crash coupling and performance; Newton soups;
Stage Manager's layout and reception; Mercury OS beyond one line; ZUI
adoption; whether BumpTop's piles survived elsewhere; niri's popularity in
numbers; acme's chords as a cause of its niche; an LVGL radial menu; other
palettes' lack of selection types beyond those read; the Material colour
utilities' license (README read, license file not fetched); Plan 9's MIT
relicensing (relevant only if acme itself were considered).

## Sources

All fetched 2026-11-15 into
`/Users/stas/erxos-scratch/sources/ui-survey/ux-ideas/raw/<key>`, with
text in `txt/<key>.txt` and the full list in `manifest.tsv`. Wikipedia
articles are secondary sources.

| Key | URL | SHA-256 |
| --- | --- | --- |
| `acme` | https://9p.io/sys/doc/acme/acme.html | `54afec308de29847d537be90c420eb8bf1481aef0a7ad32e1282dac78e7d23b9` |
| `apple-quicklook` | https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Introduction/Introduction.html | `9c45aafed66df993f3d7c8c12544aa585844e20f62d8b30dd9ed9d6dadb73d54` |
| `apple-services` | https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/introduction.html | `991c10f29ae33d9299ff5a00c2621827155287b1fc715b8f6f9c4953115327ba` |
| `apple-spotlight-arch` | https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/MetadataIntro/MetadataIntro.html | `43026508df5be9da18f5ea439bc843b026d2bea6f9cab9e5815d246f11071355` |
| `arcan-about` | https://arcan-fe.com/about/ | `e46177b366c393bc614810d31612d451bf67ca9cad09272184421d7b346c470c` |
| `arcan-durden` | https://durden.arcan-fe.com/ | `969decbd6c3612171cc6b63c454c1519d93eb1c1c2209e4d504c21d00078f9eb` |
| `bfs-book` | https://www.nobius.org/dbg/practical-file-system-design.pdf | `8ccde4a26047827f75da52f286a7711815641add6795cc3b5162ec9439871f47` |
| `bumptop` | https://www.dgp.toronto.edu/~ravin/papers/chi2006_bumptop.pdf | `4be274597595096ef9f766da6af9307808d1babc9fb79cc29883ac4fe9affb58` |
| `dynamicland` | https://dynamicland.org/ | `493cb25d63f7eeedc0be0a3e4e887570355d175ac5ceab131043455f605b477a` |
| `eaglemode` | https://eaglemode.sourceforge.net/ | `3cd3096d1c353876cfff93bd741edfb72bef33a6ae7b2f12dbbd5a297a8508c6` |
| `engelbart-demo` | https://www.dougengelbart.org/content/view/209/ | `e0ad7f6f55362ade1b3de3787b8986c251b7dec9e781967a9e265e5f687083fa` |
| `gnome-hig-notif` | https://developer.gnome.org/hig/patterns/feedback/notifications.html | `390913f684e77c328b62095ccbc2c9a8c8c59ac75fcedd641e014f2dade236b6` |
| `haiku-attributes` | https://www.haiku-os.org/docs/userguide/en/attributes.html | `d1f4c50775064d551262a19be5f8e2601782c1d03bce27cb1e56944c9083b526` |
| `haiku-queries` | https://www.haiku-os.org/docs/userguide/en/queries.html | `7881754957eb989b158c7577833377656b65087032f597221119391a2e6a7586` |
| `i3-guide` | https://i3wm.org/docs/userguide.html | `a801fb6a4dd809b1fd0bfac1f6b1e201d6ec0961149731192819bbb54bf7b58e` |
| `inkswitch-embark` | https://www.inkandswitch.com/embark/ | `3a00b79d2e4a1041f17982964c1f287337f08ca63ed920ea0e77b1903aecd6e4` |
| `kde-hig` | https://develop.kde.org/hig/ | `9652146bad829676257b5b4c42611ffcc09c209678d132a0fa508ef9a1dfc084` |
| `kde-plasma6` | https://kde.org/announcements/megarelease/6/ | `cd577240de36d7c1ca20854a06b1a1ef4bbf219c9c97ed4870af8c0417a4e1ff` |
| `lively-wiki` | https://en.wikipedia.org/wiki/Lively_Kernel | `2ce184cc4bf3506f6db2a7355be17bb93eae1c4eda30888d646bf48fd74357d3` |
| `localfirst` | https://www.inkandswitch.com/essay/local-first/ | `48ae8cd816b3fbe37b85af7e552abf674d14c84936ae9842af747fc0bf595bd5` |
| `m3-color-utils` | https://raw.githubusercontent.com/material-foundation/material-color-utilities/main/README.md | `8ddfebb9a61d1724620af5ec34d40983cf48b00959e496b20cafcb41dbd9678d` |
| `malleable` | https://www.inkandswitch.com/essay/malleable-software/ | `94345231064401b7a12e0d0e9a185b1f0254d1c99ab4e721313408e15d5ece6d` |
| `mark-interrupt` | https://www.ics.uci.edu/~gmark/chi08-mark.pdf | `e562bd16eca40a2a59499d79b15d5577d1ea3365401a8b6cb8e834187fb7fb8b` |
| `mcclim-manual` | https://mcclim.common-lisp.dev/static/manual/mcclim.html | `09ef387e9e1d1fdadf63f23ac92f88c827019141294200479ddbb775fa06fd62` |
| `mercury-home` | https://www.mercuryos.com/ | `13509b65d9ea7db1abaa9ac5863e16b33940ca87d4897f4459416253c02a6a72` |
| `muse` | https://www.inkandswitch.com/muse/ | `e84ce5635d442466a36bb553e805cf952ba05067d58f1009960952b2235e5ca0` |
| `niri-readme` | https://raw.githubusercontent.com/YaLTeR/niri/main/README.md | `ade5027b78f6d2c7164e093bb4c81ddf77780f416eab275351b5f707f2325682` |
| `oberon-system` | https://people.inf.ethz.ch/wirth/ProjectOberon/PO.System.pdf | `1bce71b2e0a291f2757f22a24a4a04100ef66d1dc7b802df97c53e50cb3110f9` |
| `padpp` | https://www.cs.umd.edu/~bederson/images/pubs_pdfs/p23-bederson.pdf | `42d4ffc5e07fe7ed184ed493de18c69977f28c8f291a7a2c0c5de16a34a566ee` |
| `paperwm-readme` | https://raw.githubusercontent.com/paperwm/PaperWM/develop/README.md | `d8399ce86412209dc755f7951cdf1561f69ee1d6419af95d9f7b00490dc49c57` |
| `plumb` | https://9p.io/sys/doc/plumb.html | `af88d34db2de942bd3a8226491807d9e10ccc7c43c0909908d3ca4e5251d2d15` |
| `potluck` | https://www.inkandswitch.com/potluck/ | `cef6e7de92fe4212b465ad0a78980521431aee226b914d0d414157bb81900d71` |
| `pt-cmdpal` | https://learn.microsoft.com/en-us/windows/powertoys/command-palette/overview | `75de953b715799b8b122efe2feee46869fb9908c796471bb2d24a290c4183e46` |
| `pt-run` | https://learn.microsoft.com/en-us/windows/powertoys/run | `23741c618d89a6a475e419b320c56e90ad5817bf7198f10149f37c8be742d13d` |
| `raycast-dev` | https://developers.raycast.com/ | `07378f93bfcef599faccad02babfc78afb1e93852a761d2a39c3afe5f976f958` |
| `raycast-manual` | https://manual.raycast.com/ | `8ca8088f53667dceb71f1ac1e6a9d8c559e005b47900d209774830d8b69f8b64` |
| `rio-pike` | https://9p.io/sys/doc/8%C2%BD/8%C2%BD.html | `e2ae28808d97b240b314a9099384a42807d1417edf53b5ad72ae956343c14875` |
| `self-morphic` | https://handbook.selflanguage.org/2017.1/morphic.html | `34e0cdbf1d1eeabb47485246c38a848bde24314def3b8d3bb0eece211adbe4b1` |
| `shneiderman-dm` | https://www.cs.umd.edu/~ben/papers/Shneiderman1983Direct.pdf | `4dc29926c05033d1cdb702444158bf8d154d8a152cad1b4a430ffd0403d3af33` |
| `smalltalk-ingalls` | https://www.cs.virginia.edu/~evans/cs655/readings/smalltalk.html | `e9e17e6efe4a69b08de0087812f6347ad97aed549d374c20aaa13f85ee99b447` |
| `star-retro` | https://www.digibarn.com/friends/curbow/star/retrospect/ | `87515be8f24f547a208e239f50c83e03cc5d27b55e44c82bb59e7aa06cdacbd5` |
| `victor-learnable` | https://worrydream.com/LearnableProgramming/ | `75451eeecd09d4408c93b443415b2aff2e573a8691883f50e53b09dc4bf6a69d` |
| `victor-magicink` | https://worrydream.com/MagicInk/ | `41f63a553e63c39704241bd41e5cc75c80703e3d882267f414bc6b71912c2a45` |
| `vscode-ui` | https://code.visualstudio.com/docs/getstarted/userinterface | `a039e295926142248b6d54693ce26e3b31161db3d3b1b0c71f16989e90cd1cdf` |
| `wiki-alto` | https://en.wikipedia.org/wiki/Xerox_Alto | `8a89a258aa21c0de127d162387925edd65300e4fe9dd7e05929410e1f8452e6b` |
| `wiki-applescript` | https://en.wikipedia.org/wiki/AppleScript | `716bec256ae008b81a060cfc4cb2bda8900d9f7b3362b638fac9a9ada3390912` |
| `wiki-archy` | https://en.wikipedia.org/wiki/Archy_(software) | `f69862a16bd4b0e744d2b34e408f818f0ae9ed9f6c8277553ec5cd797098199b` |
| `wiki-beos` | https://en.wikipedia.org/wiki/BeOS | `1a51cdbf4bfa259026dc2da4e7753bab5a435a4138c4a325b58c9c46bc64dc98` |
| `wiki-bumptop` | https://en.wikipedia.org/wiki/BumpTop | `6737b81b00c9bc309869cba1e205e1898b6cdc0ce807bbd8856c95f7ccff2f8d` |
| `wiki-cairo` | https://en.wikipedia.org/wiki/Cairo_(operating_system) | `1d8ca6dff6a96e9c04ec82136dd773f4f6046fd1e9ef9617255d3273acb76ae6` |
| `wiki-canoncat` | https://en.wikipedia.org/wiki/Canon_Cat | `6e3f45657624fd47c0620ce969cb1d5fadcbc6e3f688c8c84a4445fcc3350b5b` |
| `wiki-clim` | https://en.wikipedia.org/wiki/Common_Lisp_Interface_Manager | `52df963cfae67c1038563e2a20a05fac072138af13a4d1873a64bb0dd247cb12` |
| `wiki-cmdpalette` | https://en.wikipedia.org/wiki/Command_palette | `bc893e46effa52d03c7edf921b3be366732cb5da302db09ee0489114e8dff835` |
| `wiki-cosmic` | https://en.wikipedia.org/wiki/COSMIC_(desktop_environment) | `9e66042ad521f7490ea1451580b9b89206767081caf5a672239f8b762c7e3e99` |
| `wiki-dm` | https://en.wikipedia.org/wiki/Direct_manipulation_interface | `a0518236c1c83e23fa59920af875e9e54569e4b40ce9b0cc21ee553287570f42` |
| `wiki-dock` | https://en.wikipedia.org/wiki/Dock_(macOS) | `dc214464c0ddf54d5fea369b063459942061ae534b840cb1dbd1021fd910a1f4` |
| `wiki-expose` | https://en.wikipedia.org/wiki/Mission_Control_(macOS) | `943dbfa7098ba9dc31e91f559318b2043c0248328d68b503ff98a4073586c588` |
| `wiki-fitts` | https://en.wikipedia.org/wiki/Fitts%27s_law | `5f436f516ea8d656628b2172df0e7f6215853153fefa88d6b9e71d1182ee1769` |
| `wiki-genera` | https://en.wikipedia.org/wiki/Genera_(operating_system) | `35dcb6444dab653679c99dbac273391ab0f289e1e04957fa92bd9ad6d715b0ca` |
| `wiki-gnome-shell` | https://en.wikipedia.org/wiki/GNOME_Shell | `fe8be4c2cd6aeba0575d759bfc94d2ba2c4ced60bde094bc27f171021fd6d198` |
| `wiki-humane` | https://en.wikipedia.org/wiki/The_Humane_Interface | `19d578d47379eb38dd5958de5f3fdba8f1ef9dcf7ed7263b5a992c05f0bed525` |
| `wiki-hypercard` | https://en.wikipedia.org/wiki/HyperCard | `4fce0bfa8d8c54dedacaff134eadb3d01a8698c5881187c4aca805211eae3955` |
| `wiki-ios15` | https://en.wikipedia.org/wiki/IOS_15 | `290396db586ebb1ca5bf7133990473d759e10e80880819aaf1db1f033448b51e` |
| `wiki-lookingglass` | https://en.wikipedia.org/wiki/Project_Looking_Glass | `c93db1b3ab2fcf4942880d416a4d6c8bf6449f172713304f60bba6969ab3a727` |
| `wiki-material` | https://en.wikipedia.org/wiki/Material_Design | `892197ea7a6373e432c720e5a0be94a9ec42ce1e6513cc14d43fe1969ade032f` |
| `wiki-morphic` | https://en.wikipedia.org/wiki/Morphic_(software) | `e0fef3215e42e75c1213e33928eef8f5da4bd1de49aee3077d40772d5977b86e` |
| `wiki-newton` | https://en.wikipedia.org/wiki/Newton_OS | `3e45666f1413c6a383f523ea2f766c6edbec34e13575edd833f6fc324debd78c` |
| `wiki-nextstep` | https://en.wikipedia.org/wiki/NeXTSTEP | `2f3525e954f480f7f12e96aa0d8b2c884063c1a9b2bd68a009387ecf61f4f247` |
| `wiki-niri` | https://en.wikipedia.org/wiki/Niri_(window_manager) | `66f71b1226891205170a3f0bacc910fee01134273e5197f731502eced1bf1ade` |
| `wiki-nls` | https://en.wikipedia.org/wiki/NLS_(computer_system) | `fa65a106e71f6a02fbd88644d3b0559d5a3dc245eedd80624ecf150c4ee6f32e` |
| `wiki-oberon` | https://en.wikipedia.org/wiki/Oberon_(operating_system) | `32e928fbb43aef2583c28ed1b8939a625af08e2abbd5efa8f12a13e0a482f0b1` |
| `wiki-ole` | https://en.wikipedia.org/wiki/Object_Linking_and_Embedding | `696883b791a2082dfa5106580cb3219540b100f07566715026ef9bccaeb9a895` |
| `wiki-opendoc` | https://en.wikipedia.org/wiki/OpenDoc | `0ab386663f40441d144a8165be7ef1f93ce4a996466980c64ac0600e7e0a631c` |
| `wiki-pie` | https://en.wikipedia.org/wiki/Pie_menu | `d7ebd94ed8d36e3d2764e7b8b8858dc2a5ef7c0c0f43afe9e5f60414ac7c0957` |
| `wiki-quicksilver` | https://en.wikipedia.org/wiki/Quicksilver_(software) | `b256dbac61e8df45ff997a9bbaf18f7bb4aae39353198fc141357f4ee49ad360` |
| `wiki-raskin` | https://en.wikipedia.org/wiki/Jef_Raskin | `91445ec17f1b9864a3170fc5ba7c864da14666ed0a2b05e0ff3144f2efb3d7c6` |
| `wiki-services` | https://en.wikipedia.org/wiki/Services_menu | `688a8d98350d157e2ef6096c6326204722dc0f73d56e881536e29e9302876011` |
| `wiki-shortcuts` | https://en.wikipedia.org/wiki/Shortcuts_(Apple) | `885e2499a0a55346c2024d0ec830ced84c0c8be93b430849fd99d156113fa28b` |
| `wiki-spotlight` | https://en.wikipedia.org/wiki/Spotlight_(Apple) | `059ffcd467bd848706499e8e2535308c54dffe4a9c13b7a4342e4823d239a7df` |
| `wiki-taligent` | https://en.wikipedia.org/wiki/Taligent | `f9190cb9561be7e0a11896defba639bafc9304a55ee7453f0571114b5202eb70` |
| `wiki-tiling` | https://en.wikipedia.org/wiki/Tiling_window_manager | `8d4e23a27b0dd5740cbb04a17cb35a16a28bb83e37c2c7674311055d802680eb` |
| `wiki-ventura` | https://en.wikipedia.org/wiki/MacOS_Ventura | `492e78eeccd423c893d58ffcc5fbf0c076ab30dc3ec4d2e0d8fa2d7dfa120209` |
| `wiki-visionos` | https://en.wikipedia.org/wiki/VisionOS | `7a57da91a9b0bc5f0164087d0ce5d78c9013015aaba52c19c976ffd098068538` |
| `wiki-workplace-shell` | https://en.wikipedia.org/wiki/Workplace_Shell | `9635cef75daf9dcbdd896a852ae24b42839341eac42fc0e89e2891837c18a967` |
| `wiki-workspace` | https://en.wikipedia.org/wiki/Workspace_Manager | `05e703dcd6b79bbb11d9336956cfe618da85c142690165f1cdd48a35501b9882` |
| `wiki-zui` | https://en.wikipedia.org/wiki/Zooming_user_interface | `31aa0f2c138c25874dcb8cfe420ebb3b640de426a11d03eceecd1d82fd1bf6af` |
