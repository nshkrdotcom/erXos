# Research: UI toolkits and application models

A point-in-time research record for the erXos UI survey, domain "UI
toolkits and application models".

* **Date:** 2026-11-15.
* **Host:** Apple Silicon macOS; documents fetched with `curl` over HTTPS,
  converted with `textutil` and `pdftotext`.
* **Compared against:** erXos master `9abb9e91c`,
  [design-display.md](design-display.md) and
  [design-desktop-programs.md](design-desktop-programs.md); line numbers
  below are theirs.
* **Sources:** at the end, with URL and SHA-256; copies in
  `~/erxos-scratch/sources/ui-survey/toolkits/`. No GPL or LGPL source
  code was read (GTK, Qt and Slint from documentation only). A claim no
  fetched source supports is marked **unverified**.

## The question, for this domain

The survey asks whether erXos is "porting over old desktop tech instead
of building the most innovative 21st century solution". For toolkits and
application models the question is: is the way an erXos program
describes its interface, gets events back and keeps its state the modern
way, and what do the modern toolkits have that erXos lacks?

The short answer: **the application model is already the modern one.**
erXos's widget toolkit is the model that SwiftUI, Jetpack Compose,
Flutter, React and Elm converged on, with two
properties most of them lack: the tree states meaning rather than
appearance, so one tree drives three renderers, and the whole pipeline
is pure functions over immutable terms. The gaps are elsewhere:
**no accessibility tree, no input method (IME) path, no motion model,
and no hot reload workflow**. Each of them fits the existing model
cleanly, and the first is the most important finding of this record.

## What erXos has today (the baseline)

Read from the design documents named above.

* **Application model: the Elm architecture.** Each desktop program is a
  pure module with `init`, `step(Input, State) -> {State, [Effect]}` and
  `view(State) -> tree()`; a thin process performs the effects and hands
  the toolkit `view(State)` after every step. "The toolkit diffs; the
  program never says what changed" (design-desktop-programs.md, 35-42).
* **The tree: declarative, semantic, closed.** `{Kind, Props, Children}`
  over a closed set of kinds and properties declared in
  `abi/formats/ui.txt`. Properties state meaning (`role => heading`,
  `area => toolbar`, `icon => folder`); layout properties are hints each
  renderer reads for its medium (design-display.md, 1424-1493).
* **Identity and reconciliation: React's rule.** Identity is parent,
  kind, fixed properties and `key` or sibling index; a change of kind
  remounts. `pair/3` numbers, `delta/2` emits `insert`, `remove`, `set`,
  `move`, `commit`, and `apply_ops(delta(A, B), A) == {ok, B}` covers
  every renderer (1472-1550). One rule replaces controlled and
  uncontrolled widgets: a property the tree sets wins, an omitted state
  property keeps the last value set by tree or user (1483-1493).
* **Where it runs.** Validation, diff, layout and drawing run in the
  application's own domain on its grant (3283-3331). The display never
  sees a tree; it composes pixel buffers. (The survey brief says trees
  are "validated by the display"; the design does the opposite on
  purpose, line 5209.)
* **Three renderers behind one behaviour.** `erx_ui_erlang` (a pure box
  model in `erx_ui_layout`, drawing with `erx_draw`), `erx_ui_lvgl`
  (LVGL in a native sub-space over pipes) and `erx_ui_browser` (the same
  delta to the web client) (3333-3380).
* **Theme: one checked declaration.** `abi/theme.txt` generates Erlang,
  C and TypeScript constants, and WCAG 2 contrast ratios are build
  failures (design-desktop-programs.md, 327-401).
* **Motion: none,** so an idle window costs nothing (G6; 570-578).
* **Absent** (grep of both documents): accessibility, input methods, hot
  reload; the keyboard layout format has no dead keys or compose
  sequences (design-display.md, line 1366).

## The lineage, system by system

Each entry says what the idea is, what it buys and costs, how mature it
is, and how it relates to erXos.

### Smalltalk-80 MVC

Krasner and Pope's cookbook splits model, view and controller; views and
controllers register as **dependents** of a model and get `update:` when
it broadcasts `changed:` [krasner-pope-mvc]. It buys several views of one
model, at the cost of a mutable many-to-many protocol whose delivery
order is an implementation detail. erXos's Elm split is MVC with the
dependency graph removed: one model, the view a function of it. No
action.

### NeXTSTEP / OpenStep / Cocoa: Interface Builder, nibs, target-action

A nib describes windows, views, controls and controller objects, and
loading it "recreates the entire graph of objects", connections included
[cocoa-nibs]. Target-action stores in a control a target and an action
selector to send when it fires [cocoa-target-action]. The idea buys
visual design and a decoupled control; the cost is an opaque archive of
live objects whose connections break silently on a rename. erXos has the
good half already: a tree is plain data that a file can hold and a
visual builder could edit, and `on_click => Term` is target-action with
the opener as target and any term as action.

### Haiku / BeOS Interface Kit

Each `BWindow` is a `BLooper`, a message loop on its own thread, and
draws "by talking to the App Server" [bebook-bwindow, bebook-blooper];
views are scriptable through "scripting suites and properties"
[bebook-bview]; Haiku composes layouts from group and grid layout items
with explicit alignment [haiku-layout]. One thread per window gives a
responsive interface by construction, at the price of C++ objects shared
across threads and locking rules. A window per Erlang process is the Be
model without the locks. Be's scripting, every view addressable from
outside, is worth taking in spirit (recommendation 1).

### Morphic (Self, then Squeak)

Maloney and Smith (UIST '95) name four supports for "directness and
liveness": structural reification (every part a visible, manipulable
morph), layout reification, ubiquitous animation and live editing
[morphic-uist95]. It buys an interface that can be inspected and changed
while it runs; it costs a single mutable image with no boundary between
program and environment, which a capability system cannot take whole.
In erXos the realised tree is already reified in the widget server, so
pointing at a widget to see its node and owner is a cheap inspector
feature, and live editing comes from hot code loading.

### React and React Native

React's reconciliation is an O(n) heuristic resting on two assumptions:
elements of different types produce different trees, and a `key` marks
children stable across renders; a full minimal tree edit is O(n^3)
[react-reconciliation]. State is kept "for as long as you render the same
component at the same position in the tree" [react-preserving-state].
React Native's renderer turns the element tree into an **immutable**
shadow tree in C++, lays it out, commits, and mounts it to host views;
the phases may run on different threads, and thread safety comes from
immutability [rn-render-pipeline, rn-threading]. Layout is Yoga, "an
embeddable layout system" implementing "a familiar subset of CSS, mostly
focused on Flexbox", in C++ [yoga-about].

It buys the declarative model, keyed identity and a renderer split that
lets one description drive web and native; it costs a diff on every
update (Svelte, below) and a JavaScript runtime. erXos adopted the
identity rule and the renderer split; Erlang's immutable terms give it
React Native's thread-safety argument for free; and erXos improves on
React by making identity fix the parent, so `move` names no parent and
a node cannot become its own ancestor (line 1481).

### The Elm architecture, and its descendants (Redux, Iced)

Elm programs break into Model ("the state of your application"), View ("a
way to turn your state into HTML") and Update ("a way to update your state
based on messages") [elm-architecture]. Iced, in Rust, is "inspired by
The Elm Architecture" with state, messages, update and view
[iced-readme]; Raph Levien notes the Elm architecture "does not require
shared mutable state" [raph-xilem].

It buys one value for the whole state, every input a message and a pure
view; it costs recomputing the view per message (Elm's lazy subtrees
mitigate it: **unverified**, the page could not be fetched). This is
exactly erXos's `init`/`step`/`view` with effects returned as data, and
Erlang adds what Elm's runtime hides: the effect performer is a
supervised process. The best fit of any model in this survey.

### SwiftUI, AppKit and Core Animation (Apple)

SwiftUI views are values whose `body` composes other views; modifiers wrap
a view in another view [swiftui-view]. Since Observation, "a view forms a
dependency on an observable data model object ... when the view's
property reads a property of the object"; if `body` reads nothing, it
tracks nothing [swiftui-model-data]. Swift's Observation proposal adds
`withObservationTracking`, which records which tracked properties a
closure reads and calls `onChange` when one changes [se0395-observation].
Animations are declared, not driven: "tell SwiftUI how to draw your app's
user interface for different states" and it animates between them, with
transitions for inserted and removed views and keyframe animators
[swiftui-animation].

Core Animation, underneath, keeps three trees: the **model layer tree**
holds target values, the **presentation tree** holds "in-flight values for
any running animations", and the render tree, private, performs them
[coreanimation-basics]. A layer "captures the content your app provides
and caches it in a bitmap"; changing a property changes state, and Core
Animation "passes the layer's bitmap and state information to the
graphics hardware" [coreanimation-basics]. (That the render tree lives in
a separate system process is widely stated but **unverified** here.)

AppKit's text input goes through `NSTextInputClient`: the view reports
whether it has **marked text**, its range, and unmarks it on commit
[appkit-nstextinputclient]. Its older `NSAccessibility` informal protocol
is "a legacy, informal protocol that Apple doesn't recommend"
[appkit-nsaccessibility].

Apple's stack buys fluid motion, because the application states end
values and the system interpolates, and fine-grained updates without a
whole-tree diff; it costs a GPU compositor, a large closed stack, and
compiler macros over mutable reference types. The lesson for erXos is
Core Animation's split: **the application says where things end, the
render side animates**. It is the way to add motion without breaking G6
and without putting applications in a frame loop (recommendation 4).

### Jetpack Compose

Compose renders a frame in three phases: composition ("what UI to
show"), layout (measure and place) and drawing [compose-phases]. It
"tracks what state is read within each" phase, so a state change reruns
only the phase that read it [compose-phases]. Layout visits each node
once: "the Compose runtime requires only one pass through the UI tree to
measure and place all the nodes" [compose-phases]. Composable functions
must be "fast, idempotent, and free of side-effects" [compose-mental-model].
Semantics, a parallel tree of meaning, serves "accessibility, autofill,
and testing": TalkBack reads it, and the test framework finds nodes and
asserts on it [compose-semantics].

Compose buys a pure view with skipping, single-pass layout and one
semantic tree for accessibility and tests, at the cost of a compiler
plugin and a snapshot-state runtime. erXos's tree already is the
semantics tree, where Compose builds one beside its visual tree, which
makes the accessibility and test uses below nearly free.

### Flutter and Impeller

Flutter's build phase turns immutable widgets into an element tree, and
render objects lay out and paint [flutter-arch]. Its layout contract is the
clearest in the survey: **constraints go down, sizes go up, the parent
places the child after it returns**; "the only information that flows from
parent to child are the constraints and the only information that flows
from child to parent is the geometry"; a clean child given the same
constraints returns at once, tight constraints and "parent does not use my
size" stop relayout from spreading, so "only those nodes and a limited part
of the subtree around them are visited" [flutter-inside]. Flutter aims at
linear first layout and sublinear relayout, in contrast with "fixed-point
iteration in some constraint domain" [flutter-inside]. Hot reload "loads
code changes into the VM ... and re-builds the widget tree, preserving the
app state; it doesn't rerun main() or initState()"; globals and statics
count as state and keep their old values [flutter-hot-reload].

Impeller, Flutter's renderer, "precompiles a smaller, simpler set of
shaders at engine-build time so they don't compile at runtime", builds
pipeline state up front, and is the default on iOS and Android API 29+
since 3.27 and on macOS, Linux and Windows since 3.47 [flutter-impeller].

Flutter buys predictable layout cost and stateful hot reload; it costs a
Dart VM, a C++ engine and a GPU renderer, and Impeller answers runtime
shader compilation, a problem a CPU compositor does not have. Take the
layout contract and hot reload, leave the engine: `erx_ui_layout`
already passes a size down and gets rectangles back, and Flutter's rules
(no child's layout depends on its position; same constraints and clean
means skip) are the caching to add if layout ever shows in a profile.

### The signals lineage: QML bindings, Solid, TC39 Signals, Svelte

QML property bindings are re-evaluated when "the QML engine monitors the
property's dependencies ... When a change is detected"; assigning a
static value later removes the binding [qt-bindings]. Solid builds its
reactivity on signals, a getter and setter pair [solid-signals]. The TC39
proposal, at Stage 1, standardises the core: automatic dependency
tracking, lazy evaluation, memoization, and "glitch-free" computation
[tc39-signals]. Svelte argues that the "virtual DOM is pure overhead":
"diffing isn't free", and a compiler "that knows at build time how things
could change" emits direct update code [svelte-vdom-overhead]. Phoenix
LiveView applies the same idea on the server: a template's static parts
are sent once, and a dynamic part is re-executed and resent only when an
assign it uses changes, down to map fields [liveview-assigns].

This lineage buys updates proportional to what changed, with no diff; it
costs a dependency graph of mutable cells with its own ordering and
glitch rules, or a template compiler, and rules a maintainer must
remember (QML's binding silently lost on assignment). Not worth it at
erXos's sizes: a desktop program's tree is hundreds of nodes, capped at
10,000, and `view/1` plus `delta/2` is a linear walk of immutable terms
on the application's own grant. Signals would add mutable state to a
design whose strength is that it has none; if a large tree is ever
measured slow, the fallback is lazy subtrees (recommendation 8).

### Immediate mode: Dear ImGui and egui

Dear ImGui's author defines IMGUI as a property of the **API**, not the
implementation: the application owns its data as the single source of
truth, and the UI system retains as little about it as possible; IMGUI
"does not mean that the library doesn't retain data", nor continuous
redraw [imgui-paradigm]. egui lists the gains (no callbacks, no lingering
callback "calling something that is gone", no app state and GUI state out
of sync) and the costs: layout needs a size before contents are laid out,
handled with a frame delay or a discarded extra pass; a full layout each
frame; IDs needed for retained bits such as scroll offsets [egui-readme].
egui gets accessibility through AccessKit [egui-readme].

* **erXos:** by Dear ImGui's own definition, erXos's API **is**
  immediate mode: `view(State)` returns a fresh description, the
  application holds no widget handles and the toolkit keeps only what it
  must (the realised tree, kept state, presentation state). The
  implementation is retained, which avoids egui's layout paradox and its
  per-frame work. The "imperative widgets" row of Alternatives
  considered (line 5239) already rejects handle-based APIs. Nothing to
  change; worth saying in the design's rationale, because it answers
  "why not immediate mode" in one line.

### Other toolkits, briefly: Qt Quick, GTK4, Slint, Godot, Electron, Tauri

* **Qt Quick** renders a dedicated scene graph through OpenGL, Vulkan,
  Metal or Direct3D instead of imperative QPainter calls, so it can batch
  draw calls, often on a render thread synchronised with the GUI thread
  each frame; a software adaptation exists where "not all concepts may
  apply" [qt-scenegraph]. C++, a JavaScript engine for bindings, GPU
  first: nothing to adopt.
* **GTK4** runs a frame clock through update, layout and paint phases and
  stays idle when nothing needs them; widgets snapshot into cached GSK
  render nodes, which OpenGL, Vulkan or cairo renderers draw
  [gtk4-drawing-model]. Its accessibility follows WAI-ARIA roles,
  properties, relations and states, and a role "cannot be changed over
  time": a control whose role changes is "removed and replaced"
  [gtk4-accessibility]. Two confirmations of erXos: the idle frame clock
  is G6, and the fixed role is erXos's identity rule (a change of kind
  remounts). GObject C under the LGPL and GPU-first: not a candidate.
* **Slint** compiles a `.slint` markup ahead of time to Rust, C++ or
  JavaScript; its expressions "are pure functions that the compiler can
  optimize"; it reaches microcontrollers (STM32, ESP32, RP2040) and has a
  software renderer [slint-readme, slint-software-renderer]. The nearest
  modern peer of LVGL, but Rust and C++ under royalty-free, GPLv3 or
  commercial licenses [slint-readme]. LVGL stays.
* **Godot** lays out with anchors or, for complex interfaces, nested
  containers whose children "give up their own positioning ability"; the
  Godot editor is built entirely from them [godot-containers]. Themes
  cascade from parent to child [godot-theme]. Containers are erXos's
  `row`, `column`, `grid` and `stack`; a cascading theme is weaker than
  erXos's one checked declaration.
* **Electron** "inherits its multi-process architecture from Chromium";
  its security guide forbids running remote code with Node.js
  integration and asks for sandboxing, and every app ships "Electron,
  Chromium shared library and Node.js" [electron-process,
  electron-security]. **Tauri** uses the system webview through WRY and
  TAO [tauri-arch]. A browser engine as the toolkit is the opposite of
  erXos's size, surface and language rules; erXos's browser renderer
  already gives the web its one useful role here, a remote display.

### LVGL (erXos's kiosk renderer, v9.6.0 in the tree)

Read from `display/lvgl/lvgl/docs/src` at commit `80ca777e` (MIT). LVGL
styles cascade and some properties inherit from parents, with a property
assigned to a state rather than CSS-style pseudo-classes
[lvgl-styles]; its flex layout is "a subset of CSS Flexbox behaviors"
[lvgl-flex]; a Subject/Observer module provides data binding, an
observable value with attached observers [lvgl-observer]; a pinyin IME
widget exists [lvgl-ime-pinyin]; and its XML declarative UI is now
documented only in "LVGL Pro" [lvgl-xml]. A grep of its docs finds no
screen-reader or accessibility-tree support.

* **erXos:** erXos uses LVGL correctly, as a renderer of a tree it does
  not own, with its theme replaced from `theme.txt`. Its observer and XML
  layers duplicate what Erlang trees already do and should stay unused.
  Its pinyin IME widget is the kiosk's answer to Chinese input if ever
  needed, inside the renderer, which is where erXos's design would put
  input composition anyway.

### Xilem (Raph Levien)

Levien frames reactive UI as "a pipeline of tree transformations"
[raph-reactive-ui]; Xilem generates a short-lived view tree each cycle,
diffs successive versions into a retained widget tree, and dispatches
events by an **id path** [raph-xilem]; it is experimental
[xilem-readme]. An independent confirmation of erXos's shape. erXos's
flat node numbers per window are simpler than id paths because the
widget server holds the whole realised tree.

### Erlang wx

wx maps each wxWidgets C++ class to a module; objects "should be seen as
erlang processes rather than erlang terms", are made with `new` and freed
with `destroy`, and the threaded driver means "if the erlang programmer
does an error, it might crash the emulator" [erlang-wx]. The
counter-example: imperative handles, manual destruction and a native
crash inside the runtime are what erXos rejects (lines 5231, 5239).

### Scenic (Elixir)

Scenic is "a client application framework written directly on the
Elixir/Erlang/OTP stack", retained mode, layered as scenes, a ViewPort and
drivers [scenic-overview]. A scene "is a GenServer process which creates
and manages a Graph"; reusable scenes are components, each its own
process [scenic-scene]. The ViewPort keeps scenes and drivers ignorant of
each other, owns ETS tables of graphs that "drivers should only read",
and hit-tests the graph of graphs to route input [scenic-viewport].
Graphs compile to `Scenic.Script`, static drawing commands sent
unmodified to drivers; a script a graph references is sent once
[scenic-script].

It is the first serious OTP-native UI, with supervision for UI parts and
a clean app/driver split. Its costs: a tree of visual primitives, so no
driver can render it for a browser or a screen reader; a public ETS table
between scene and ViewPort, which its source admits ("we also tried
casting the graph ... but that had issues"); a process per component.
erXos already took Scenic's declarative tree and dropped its driver
protocol (line 5232), and should keep declining the other two choices:
a process per component turns a window's consistency into a protocol,
and primitives lose meaning. Scenic's script reference for static
content is matched by erXos's separate draw window (line 1509).

### Server-driven UI: Phoenix LiveView, Blazor Server, Remote Compose, htmx

LiveView keeps state on the server and sends only changed dynamic parts
of templates [liveview-assigns, liveview-readme]; its diff engine tracks
components, static parts, keyed lists and streams [liveview-diff]. Blazor
Server runs components on the server over SignalR; each browser tab is a
separate circuit and "every user interaction involves a network hop"
[blazor-hosting]. Remote Compose, "a framework to create UI for remote
surfaces", is at 1.0.0-alpha23 [remote-compose]; htmx argues for HTML
over the wire [htmx-hypermedia]. These are the precedent for erXos's
widget server and renderers, the browser renderer above all, which is
LiveView's model with a typed tree in place of HTML. Because erXos sends
a closed, typed tree with every text through the line escape and no SVG
(lines 1431-1447), its renderers cannot be injected into, which none of
these four can say.

### The web platform's layout, as libraries

Taffy implements CSS block, flexbox and grid in Rust [taffy-readme];
Yoga a flexbox subset in C++ [yoga-about]. Cassowary is an incremental
dual-simplex solver for linear equalities and inequalities with
preferences, built for interfaces [cassowary-tochi] (that Apple's Auto
Layout derives from it is **unverified**). Both libraries are in excluded
languages, and constraint solving brings ambiguous and conflicting states
a maintainer must reason about, the "fixed-point iteration" Flutter
avoids [flutter-inside]. erXos's weighted rows and columns, grid and stack
cover the programs that exist; extend them in Erlang, under Flutter's
single-pass contract, when a real program needs wrapping or min and max
sizes.

## The themes, and where erXos stands on each

### Trees, reactivity, layout and placement

* **Declarative trees and diffing.** The state of the art is a fresh
  description per update diffed against a retained tree with keyed
  identity (React, Flutter, Compose, SwiftUI, Xilem), or no diff at all
  by compiling templates (Svelte) or tracking reads (signals). erXos is
  in the first group with a sharper contract than most: one pure
  difference, one property test, stateless binary readers fuzzed alone,
  node numbers never reused (lines 1512-1561). **Best fit; keep.**
* **Reactivity.** Whole-view recomputation plus diff is the simplest
  correct design at hundreds to thousands of nodes; add lazy subtrees
  only on a measurement. **Keep.**
* **Layout.** A pure box model with `Measure` passed in, so layout reads
  no font (lines 3367-3380), single pass as in Compose and Flutter.
  **Keep**, and write Flutter's contract into `erx_ui_layout`'s
  documentation so caching can be added without changing its interface.
* **Placement.** The widget server and renderers run in the
  application's domain; the display sees pixels. Against widgets in the
  display (the design's X11 and Arcan rows, 5230, 5236) or LiveView and Blazor circuits, this charges all UI
  work to the application and keeps the display's trusted code small.
  **Best fit; keep.**

### Accessibility trees

**State of the art:** a tree of nodes with integer IDs, roles, attributes
and actions, pushed **whole once and then as incremental updates** from
the process that owns the UI to the process that talks to assistive
technology. Chromium does this because renderer processes are sandboxed:
the browser process caches the tree and answers accessibility calls from
the cache, which may lag "by a fraction of a second"; its tree serializer
needs only unique integer IDs, an acyclic tree, and notification of node
and child-list changes [chromium-a11y]. AccessKit generalises Chromium's
design to any toolkit, with adapters for macOS, Windows, AT-SPI, Android
and iOS, and notes that only the adapter keeps the full tree, so even
immediate-mode toolkits fit "as long as they can provide a stable ID for
each UI element" [accesskit-readme]. AT-SPI on Linux is chatty over D-Bus,
with context switches its own developers suspect add up [atspi-arch].
Compose reuses its semantics tree for tests [compose-semantics].

**erXos:** this is the strongest finding in this domain. erXos's
`delta/2` stream **already is** a Chromium-style incremental tree update:
unique integer node numbers, an acyclic tree by construction, a full
tree on first `insert`s and then `set`/`insert`/`remove`/`move`. Its
kinds and `role` are close to ARIA roles; `text`, `alt`, `checked`,
`value`, `min`/`max`, `selected` and `enabled` are the attributes a
screen reader needs; `ui_hit` is the action path back. What is missing:

1. a **name** for nodes without text (an icon-only button);
2. a **consumer**: no renderer reads the tree for assistive technology,
   and no inspection path exposes it;
3. **focus** as shared state: today focus is each renderer's own
   presentation state (line 1492), but a screen reader must know and
   move it.

A toolkit whose tree is visual primitives (Scenic, egui, LVGL) must
rebuild meaning beside it; erXos needs no model change, only the
consumer, which is not a screen reader (a large project of its own) but
the path that one, a braille display or a test would read.

### Text input and IME

**State of the art:** Wayland's text-input protocol has the client send
surrounding text with cursor and anchor, a content type (purpose and
hints, password among them) and a cursor rectangle, double-buffered and
applied on `commit`; the input method answers with `preedit_string`,
`commit_string` and `delete_surrounding_text`, applied together on `done`
[wl-text-input-v3]; a separate input-method protocol connects the
compositor to the IME process [wl-input-method-v2]. AppKit's
`NSTextInputClient` has the view keep **marked text** (the preedit) and
its range until commit [appkit-nstextinputclient]. LVGL embeds a pinyin
IME as a widget [lvgl-ime-pinyin].

**erXos:** no IME, no compose or dead keys (line 1366). The design's own
split makes the fit clean: an `input`'s text is state, its cursor and
selection are the renderer's presentation state, and the secret `input`
already has a purpose that must disable any IME. Preedit belongs to the
renderer (as marked text belongs to the view in AppKit); a commit becomes
the ordinary `{change, V}`. A compose-key table in the keyboard layout
format is the first step and covers Western European input; a CJK input
method is a process the renderer talks to through a declared protocol,
modelled on text-input-v3's request and answer sets. **A real gap, but
not urgent for an English light-theme desktop; design it before a
multi-line text widget is built**, because a text editor widget built
without preedit has to be redone.

### Theming

**State of the art:** cascading styles (GTK's CSS box model
[gtk4-drawing-model], LVGL styles [lvgl-styles], Godot theme resources
[godot-theme]). **erXos:** one declaration with checked contrast ratios,
generated for three renderers; none of the toolkit documents read here
describes a build that fails on an unreadable colour. **Keep.**

### Animation models

**State of the art:** declare end states; the render side interpolates
(Core Animation's model and presentation trees [coreanimation-basics],
SwiftUI's animated state changes and transitions [swiftui-animation],
Compose's `animate*AsState` and `Transition` [compose-animation], LVGL's
style transitions [lvgl-styles]). GTK's frame clock runs only while an
animation needs it [gtk4-drawing-model].

**erXos:** no motion by decision, to keep G6 (idle costs nothing). This is
the place where "slick like OS X" and erXos's design pull apart. Core
Animation shows the reconciliation: the application never animates; it
sets end values, and the renderer runs a bounded, clocked interpolation
only while a transition is in flight, then stops. G6 would then read
"nothing paints without a change **or a running transition**", and its
test (an idle display makes no device request for a minute) still holds.
Transitions would be declared in `theme.txt` per kind and property (a
button's press, a list selection, a window's appearance), not per tree,
so applications stay unaware of them. **It needs a decision before any work.**

### Hot reload

**State of the art:** Flutter's stateful hot reload injects new code into
the VM and rebuilds the widget tree with state preserved; globals keep
their old values [flutter-hot-reload]. Slint advertises live preview
[slint-readme].

**erXos:** Erlang already keeps two versions of a module, "current" and
"old", both runnable, with fully qualified calls going to the current one
[erlang-code-loading]. A desktop program's core is a pure module called
by its shell process; loading a new `erx_desk_<name>_core` and having the
shell call `view(State)` again **is** Flutter's hot reload, with no VM
changes. A state whose shape changed needs a conversion function or a
restart of the program, as Flutter's hot restart. **Small, high value for
development; recommendation 2.**

### What model fits an Erlang system?

From the sources, the model that fits is the one erXos has:

* **One process per window, a pure core inside it.** Elm's split
  [elm-architecture] mapped onto OTP: the process owns effects and
  supervision, the core owns decisions. Not one process per widget (wx,
  Scenic components): widget state split across processes needs a
  consistency protocol and gains nothing, since a window's widgets change
  together.
* **Messages are data, events are terms.** Target-action with an arbitrary
  term [cocoa-target-action], delivered as `{ui, Window, Term, Detail}`.
* **The tree crosses boundaries as a typed difference, never as code or
  markup.** The renderers outside Erlang read a generated binary form;
  the browser receives no HTML and no SVG.
* **Meaning, not pixels, is the shared language** between the application
  and everything that reads its interface: three renderers today,
  assistive technology and tests next.

## Ranked: worth adopting or prototyping

| Rank | Idea | Why | Size |
| --- | --- | --- | --- |
| 1 | **The realised widget tree as an inspection path** (for example `/proc/<pid>/ui/<window>`), read as the tree plus a stream of `delta/2` operations | One semantic tree then serves rendering, inspection, tests and later accessibility, with no new tree; Be's scripting and Morphic's directness in erXos form; the CLAUDE.md home for "state someone reads" | small to medium: a design section in design-display.md and design-live.md; needs sign-off as a new inspection path |
| 2 | **Hot reload of a program's pure core** (`erx_desk_<name>_core`), with the shell re-rendering after `code:load_file/1` | Flutter-grade iteration on the desktop programs for nearly free, because the core is pure and Erlang keeps two code versions | small: a development command and a re-render message; no format change |
| 3 | **Accessibility readiness in the format**: a `name` property for nodes without text, focus reported as state, and a written mapping from kinds and roles to ARIA and AT-SPI roles | AccessKit and Chromium show the transport erXos already has; adding the three missing facts now keeps every later app accessible without retrofit | small (ui.txt rows, renderer reports) plus a design note; a screen reader itself is a separate, large project |
| 4 | **Renderer-side transitions declared in `theme.txt`** (Core Animation model: apps set end values, the renderer interpolates for a bounded time, then stops) | The single biggest step toward "slick" motion that keeps G6's idle guarantee and keeps apps out of any frame loop | medium: theme grammar, a transition clock in `erx_ui_erlang`, LVGL transitions on, G6 reworded; **decision needed** (reverses Motion, lines 570-578) |
| 5 | **Text input design before a text editor widget**: compose and dead keys in the layout format first, then a preedit/commit protocol between renderer and an input method, modelled on Wayland text-input-v3 | Avoids redoing a text widget later; secret inputs already carry the "password" purpose | medium: a design section; the compose table is small |
| 6 | **Tests that query the realised tree** (find node by kind, text, role; fire `ui_hit`; assert on the next tree) | Compose's semantics-tree testing; pure functions make it host-only and fast | small: a test helper module |
| 7 | **Flutter's layout contract written into `erx_ui_layout`**, and a clean-subtree cutoff only if layout is measured slow | Keeps the interface ready for caching; no work until a profile asks | small: documentation now; cache later, on the performance watch list |
| 8 | **Lazy subtrees** (skip `pair`/`delta` of a subtree whose input term is unchanged) | The Elm-style answer to large views, cheaper in concepts than signals | small, but only after a measurement; put "view+delta time for a 10,000-node tree" on the watch list |

## Attractive, but not a fit

* **Flutter, Qt Quick, GTK4, Slint, egui or Dear ImGui as the toolkit:**
  Dart, C++, Rust or GObject C; GPU-first renderers (Impeller exists to
  fix shader stalls a CPU compositor does not have); Slint's and GTK's
  licenses; and none carries a semantic tree a browser or screen reader
  can render. Take their ideas, not their code.
* **Signals, compiled templates (Svelte, LiveView's static/dynamic
  split), UI markup (QML, `.slint`, LVGL XML, nibs):** mutable cells, a
  compiler or a second language, for a problem a linear diff of small,
  schema-checked Erlang terms already solves.
* **Constraint layout (Cassowary, Auto Layout) and full flexbox (Taffy,
  Yoga):** solver states (ambiguous, conflicting) or a large
  specification, in excluded languages, for needs the box model meets.
* **One process per widget (wx, Scenic components)** and **visual
  primitives as the shared tree (Scenic graphs, GSK nodes):** the first
  splits a window's consistent state across processes; the second loses
  meaning, and with it the browser renderer, accessibility and semantic
  tests.
* **Server-side widgets in the display domain:** rejected by the design
  for authority and budget (line 5209); nothing here argues otherwise.
* **Electron, Tauri, Erlang wx, immediate-mode render loops (egui):** a
  browser engine as toolkit; a native crash inside the runtime;
  per-frame layout and repaint against G6.

## Open questions and unverified points

* **Decision needed:** whether erXos wants motion. Recommendation 4
  reverses the Motion section and rewords G6; it is the main lever toward
  "slick", at the cost of a renderer clock that runs only during
  transitions.
* **New mechanism check:** recommendation 1 adds an inspection path and
  recommendation 5 a declared protocol, both homes CLAUDE.md names; each
  needs a design section and sign-off before code. Recommendation 3's
  focus-as-state changes a stated rule (focus is renderer presentation
  state, line 1492).
* **Who reads the accessibility tree?** erXos has no screen reader,
  speech synthesis or braille driver. Whether it ever ships assistive
  technology, or only hands the tree to the browser renderer (whose web
  client could map it to ARIA for the host's own screen reader), is a
  scope question.
* **Unverified:** that Core Animation's render tree runs in a separate
  system process; BeOS's `hey` scripting tool; Elm's `Html.Lazy` (the
  page failed to fetch); Apple Auto Layout's derivation from Cassowary;
  whether ERTS's `=:=` short-circuits on identical (pointer-equal) terms,
  which decides how cheap lazy subtrees are in Erlang (read
  `erts/emulator/beam/utils.c` before relying on it).
* **Version caveat:** text-input-v3 was read from wayland.app's rendering
  (the freedesktop GitLab file sat behind a bot check, which was not
  passed); it lists requests such as `set_available_actions` and
  `show_input_panel`, and which protocol revision it shows is not pinned.
* **Not measured:** this record has no numbers; 10,000 nodes and 1,024
  children are design limits. The cost of `view/1` plus `delta/2` for a
  large tree settles recommendations 7 and 8.
* **Not fetched:** the IBus wiki (GitHub page chrome only) and Reenskaug's
  MVC pages (one URL served an HTML page instead of the PDF, the other a
  certificate for the wrong host); Krasner and Pope is cited instead.
  Nothing cited needed a sign-in.

## Sources

Fetched 2026-11-15 over HTTPS. SHA-256 of the file as fetched (for Apple
documentation, the JSON the documentation site serves).

| Key | Source | SHA-256 |
| --- | --- | --- |
| accesskit-readme | <https://raw.githubusercontent.com/AccessKit/accesskit/main/README.md> | `f5fac0f0c356d84dcd519c099b0a329b6bfc47b85cec6f6589f9f41445392472` |
| appkit-nsaccessibility | <https://developer.apple.com/tutorials/data/documentation/appkit/nsaccessibility.json> | `eccbec96725b56af71fa88feab0e911ee6955bf77dcee0e8ccc13cdf7bcd232e` |
| appkit-nstextinputclient | <https://developer.apple.com/tutorials/data/documentation/appkit/nstextinputclient.json> | `b211dca50c428e51aeb76fdf26ae483e042f090fa498bc6c0365ffcdba7ccd58` |
| atspi-arch | <https://gnome.pages.gitlab.gnome.org/at-spi2-core/devel-docs/architecture.html> | `2a26c1b35cb7649124b0fe2b8ebd82403467b0a0d1b4539d584a78370c60f69c` |
| bebook-blooper | <https://www.haiku-os.org/legacy-docs/bebook/BLooper_Overview.html> | `9cde54b440e320d1aefdddbe267e9054cdec251e3ed0310be08ae394fda0b252` |
| bebook-bview | <https://www.haiku-os.org/legacy-docs/bebook/BView_Overview.html> | `e26d385548344e193ecb728e465331a90f92b24487fe7d5564a0c56e81fcfbef` |
| bebook-bwindow | <https://www.haiku-os.org/legacy-docs/bebook/BWindow_Overview.html> | `dc9c9dd4cb41a787183c30e50c0c1cbcdfe07ee1fd41689763c7613d63d5b119` |
| blazor-hosting | <https://learn.microsoft.com/en-us/aspnet/core/blazor/hosting-models> | `61f95802050b7bc3bb18f40d71e1456eeb56be7c669378f9849de1f9177e15aa` |
| cassowary-tochi | <https://constraints.cs.washington.edu/solvers/cassowary-tochi.pdf> | `f7d90e2355d8f27a4d15133d54e5b36f6b5466f15e9c30da720967f9bba45ff9` |
| chromium-a11y | <https://chromium.googlesource.com/chromium/src/+/main/docs/accessibility/overview.md?format=TEXT> | `1f443f55ab1aa733967279f3c1faf6400f5cec20a3dfb662cea02c2c2665a5ac` |
| cocoa-nibs | <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/LoadingResources/CocoaNibs/CocoaNibs.html> | `200ccd98c8ae13ba6c56d510cd642a71622c9503fe4d63e84612a9ca73afe688` |
| cocoa-target-action | <https://developer.apple.com/library/archive/documentation/General/Conceptual/Devpedia-CocoaApp/TargetAction.html> | `923f8a834be6b0e11424ebf0ce5832ca4667dbb760593c054fea193dffa91cb1` |
| compose-animation | <https://developer.android.com/develop/ui/compose/animation/introduction> | `94a8d228ddf681ff468830b05cb28e752bf6c21a2430dc05cd970a08eb0e36eb` |
| compose-mental-model | <https://developer.android.com/develop/ui/compose/mental-model> | `f7c7f5eb158e37e7d942a7d5bb51f04c3e3ea009ceb2b60a0599c8346a216d27` |
| compose-phases | <https://developer.android.com/develop/ui/compose/phases> | `a9f2a5157e6c50b7826a6de7168d03b4da876a7113cc451ee8b85064f85a6b8d` |
| compose-semantics | <https://developer.android.com/develop/ui/compose/accessibility/semantics> | `fb0e884b1bd139d4f00fd69853dcfa234606fd5cfe2ba7b908369b32810694b5` |
| coreanimation-basics | <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html> | `915a0aba861935fff3c224281888bb7c4799725b20af2d133f454f435c50c373` |
| egui-readme | <https://raw.githubusercontent.com/emilk/egui/main/README.md> | `f6d9742a2cc9d5376537031aff758d322e165a728f5a6c7a19b01afdb36f0f0c` |
| electron-process | <https://www.electronjs.org/docs/latest/tutorial/process-model> | `e274038ae7818fca763860f46bc55a7fdfb57addabd4698a8af2ad7f69e38fa4` |
| electron-security | <https://www.electronjs.org/docs/latest/tutorial/security> | `f7bdff2038a83032112ee22ec61e207120960096a5699d676d2621ec4df08185` |
| elm-architecture | <https://guide.elm-lang.org/architecture/> | `dadb883be9f592cb0114d03464e20e8aea95e44b4d0387715e501b60c38dc3c6` |
| erlang-code-loading | <https://www.erlang.org/doc/system/code_loading.html> | `1bc4a0d3ee5c1abf76cd92bc1795591a3171efc957d1655af1b40a802f60cdee` |
| erlang-wx | <https://www.erlang.org/doc/apps/wx/chapter.html> | `078ace3ede866c27bb58d4eeb89ff6c9af3c4c0238f1f0d9d3fc82a0e22ff31f` |
| flutter-arch | <https://docs.flutter.dev/resources/architectural-overview> | `eed15d7c808d3f74c56eb5e636fe809c041b921762497a7d5e1cf558cc3f54d0` |
| flutter-hot-reload | <https://docs.flutter.dev/tools/hot-reload> | `ca71571a82d89b698b61437682ac14b0626064ef545000cab52b8dc3f8bbe8f8` |
| flutter-impeller | <https://docs.flutter.dev/perf/impeller> | `2c02246a2fbe967ccec7ec9a1c561fb2af5254228176fd5a953bcfc7d7b57d50` |
| flutter-inside | <https://docs.flutter.dev/resources/inside-flutter> | `e4e66fd42a59b76ba4700d850fe1b3d897b2196f3ff2b9ca42568743d579ca48` |
| godot-containers | <https://docs.godotengine.org/en/stable/tutorials/ui/gui_containers.html> | `aebe5f739c9d093f6a9dd8b6069e2f08633e02d981bd65bed8632fe77ae74326` |
| godot-theme | <https://docs.godotengine.org/en/stable/tutorials/ui/gui_skinning.html> | `5f69955c764446894bf6f899e9a8833398d12ca62efb2d396f738c3c8a37a550` |
| gtk4-accessibility | <https://docs.gtk.org/gtk4/section-accessibility.html> | `5ea0398bda69fa6550c347494ab55ccc4f733df6f88929a7301e982d7fd108af` |
| gtk4-drawing-model | <https://docs.gtk.org/gtk4/drawing-model.html> | `fccf3b38c116445b869e2ff045f37d7faeed54cadae4073b1061f5625e5bc3e2` |
| haiku-layout | <https://www.haiku-os.org/docs/api/layout_intro.html> | `598345daa581af4200c1df747a6f033ab6ccdb93e2d7e1f38d0291738bf3e3ea` |
| htmx-hypermedia | <https://htmx.org/essays/hypermedia-driven-applications/> | `1c0dddb30fd7ecf405ebcf6aa31454c60a1da7dadf58ea441e2a02674b739b41` |
| iced-readme | <https://raw.githubusercontent.com/iced-rs/iced/master/README.md> | `58c0921d4adfa3ec01c0600007e02772599d6efa671320263792f3fe26c6d71d` |
| imgui-paradigm | <https://raw.githubusercontent.com/wiki/ocornut/imgui/About-the-IMGUI-paradigm.md> | `05c8c89215b516020769ea0f53ad95833e2e5a6679613ae4c16584207efea03f` |
| krasner-pope-mvc | <https://www.ics.uci.edu/~redmiles/ics227-SQ04/papers/KrasnerPope88.pdf> | `2583c759a04cb4a33488bd4e1e38dca2a4dcb150a053ea0c4321ff413ef7fd1e` |
| liveview-assigns | <https://hexdocs.pm/phoenix_live_view/assigns-eex.html> | `d70e58118a69950d0830572a8b473c5dc0deb1b90ce69a248922bd96c0dfbd13` |
| liveview-diff | <https://raw.githubusercontent.com/phoenixframework/phoenix_live_view/main/lib/phoenix_live_view/diff.ex> | `05baccd5636d2ce69b77f04d0eaa592ded546c05d66cc462c237c1870f237b44` |
| liveview-readme | <https://raw.githubusercontent.com/phoenixframework/phoenix_live_view/main/README.md> | `82a04309dd592a11603020b127a45e6eefd67044d0ae66febe629cc3f3af8ef9` |
| lvgl-flex | erXos tree `display/lvgl/lvgl/docs/src/common-widget-features/layouts/flex.mdx`, LVGL v9.6.0, commit `80ca777e37a2` (MIT) | `65899b5bafd85ec94c7783ac5585238e0babb098f844ab63f0489e4be3fca470` |
| lvgl-ime-pinyin | erXos tree `display/lvgl/lvgl/docs/src/widgets/ime_pinyin.mdx`, LVGL v9.6.0, commit `80ca777e37a2` (MIT) | `bb899db860d43ba42c59a78e49ad2cd4070a7c4e529d8e98500a2861082340ec` |
| lvgl-observer | erXos tree `display/lvgl/lvgl/docs/src/main-modules/observer/observer.mdx`, LVGL v9.6.0, commit `80ca777e37a2` (MIT) | `cfd952c5917ee5fd58e7aea80decc843ab9d0ff4f171af8718e2e3e14001db90` |
| lvgl-styles | erXos tree `display/lvgl/lvgl/docs/src/common-widget-features/styles/overview.mdx`, LVGL v9.6.0, commit `80ca777e37a2` (MIT) | `4ceb27386ccd60475933ac1f3b38b53a354664e4b2f1bc82dd097cd51a5ad9cf` |
| lvgl-xml | erXos tree `display/lvgl/lvgl/docs/src/xml.mdx`, LVGL v9.6.0, commit `80ca777e37a2` (MIT) | `1391197ca3fea20aae56c7998d7fed01a5041d143f2a1c816a498d422c9a4936` |
| morphic-uist95 | <https://bibliography.selflanguage.org/_static/directness.pdf> | `d5faa13eaab31abe4e7aae398c594330ff0d143ebed31c987fe8b8d264e191ad` |
| qt-bindings | <https://doc.qt.io/qt-6/qtqml-syntax-propertybinding.html> | `868380ea92800b017888abf95cb924da0defb139b649fb7a5efffc6005ad669a` |
| qt-scenegraph | <https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html> | `a5fbb035845a85d8eccabfc3a145baa368fb991826e30f5acef254e15caf5ef7` |
| raph-reactive-ui | <https://raphlinus.github.io/ui/druid/2019/11/22/reactive-ui.html> | `0fbb96fd54a27803e2049bb357cbaa916f065deaeb2ca07bd5dcc867ae4739fe` |
| raph-xilem | <https://raphlinus.github.io/rust/gui/2022/05/07/ui-architecture.html> | `8ea15b103373dc1cfe89dcd6118570efd885ac0eed9f9165631496a31cb42fa6` |
| react-preserving-state | <https://react.dev/learn/preserving-and-resetting-state> | `223b32c1fc94c1cd4dcbf2c8eff22e395a9055a530177bb7c5a932a196e10b25` |
| react-reconciliation | <https://legacy.reactjs.org/docs/reconciliation.html> | `39436d12593936161ff46fb56584e23c9bbc8fc2b7445cbde71aa76f457e8fb2` |
| remote-compose | <https://developer.android.com/jetpack/androidx/releases/compose-remote> | `abaabc2f7ab4423af52f912da8fe3a26df7d0f2488d535eee724952a20918876` |
| rn-render-pipeline | <https://reactnative.dev/architecture/render-pipeline> | `8574f387a8d6715b12fd4863beb933f62098b986af8c6d5f415b8b1b0f183073` |
| rn-threading | <https://reactnative.dev/architecture/threading-model> | `3a0631d59abc5cd701709f1e4c715c200dcf363bf71a8e20e6c9ccae61745430` |
| scenic-overview | <https://hexdocs.pm/scenic/overview_general.html> | `a7fa4f7c96714c1391b763e98683b9045433c1ca60df0ac8098c35664bbe8eee` |
| scenic-scene | <https://hexdocs.pm/scenic/overview_scene.html> | `08705f4e0f3a7f5e553fa0f6785085efa85802c4d363fe47d74ae18ff374c085` |
| scenic-script | <https://raw.githubusercontent.com/ScenicFramework/scenic/main/lib/scenic/script.ex> | `6d9d0a06f73ff3bacd1f3c8a0d5a9011c22e8c6cfd7c1b1b73b2c17170b2ee2f` |
| scenic-viewport | <https://raw.githubusercontent.com/ScenicFramework/scenic/main/lib/scenic/view_port.ex> | `81bb3d4feeb0a740592c9a29fba228af8cb6799ea6659c9467b6b7d3c9686b27` |
| se0395-observation | <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0395-observability.md> | `e2aa3f053d541117b448def92eb11a7ed55f305b43fd52485c9aa1f6a97d099e` |
| slint-readme | <https://raw.githubusercontent.com/slint-ui/slint/master/README.md> | `63dbdb3575864dfc9382e5b9fbdb8b4f9d0e9d2193176b90699fadedd9724960` |
| slint-software-renderer | <https://docs.slint.dev/latest/docs/rust/slint/docs/cargo_features/> | `12e9375d5c1f15bcc147657952739707de7060476129cebc0b5e2e9f838e84de` |
| solid-signals | <https://docs.solidjs.com/concepts/signals> | `de5e39be6cf97074e32e10a9d59b2ae53273c03eb6e96dce510aa2746991bf1d` |
| svelte-vdom-overhead | <https://svelte.dev/blog/virtual-dom-is-pure-overhead> | `e9b1b51de2c0998a13430d3df763c47aac2aae9db44635b863f586bd6894ab3d` |
| swiftui-animation | <https://developer.apple.com/tutorials/data/documentation/swiftui/animations.json> | `7b587d4ac0a3e4c6dc4ca760867b0819b2abe6ae880198d6111ffbfedacd6272` |
| swiftui-model-data | <https://developer.apple.com/tutorials/data/documentation/swiftui/managing-model-data-in-your-app.json> | `68c4a1c0c07da76b234eba7a2ca9683aa2c2bc70b714864f3f78efb743f098dc` |
| swiftui-view | <https://developer.apple.com/tutorials/data/documentation/swiftui/view.json> | `58f325d35704ea0c3c28736e104fe388b7b32f57ea317abab9ca8d725f47f9e7` |
| taffy-readme | <https://raw.githubusercontent.com/DioxusLabs/taffy/main/README.md> | `ae639d00b0d3f0f0006dcbc9e696bdcea490d5b96fee774a837b1b7022008dd8` |
| tauri-arch | <https://v2.tauri.app/concept/architecture/> | `a574dd040840172d5fd3e8f28634f3753b82f3a064df59c5fb14d1fb27c8135b` |
| tc39-signals | <https://raw.githubusercontent.com/tc39/proposal-signals/main/README.md> | `604570573e8bba518d6bf0e067c1af3fb28c15b221aa3ede4e6804f0e3fb027f` |
| wl-input-method-v2 | <https://wayland.app/protocols/input-method-unstable-v2> | `92ddf08d48a2969515f3b26e9a02af721cf3fb8a4dc1e4f8b6b8f671726a7104` |
| wl-text-input-v3 | <https://wayland.app/protocols/text-input-unstable-v3> | `d2b0123045f60282319c62d6d3d31843397e3d4fb661de9672f5e350c8105183` |
| xilem-readme | <https://raw.githubusercontent.com/linebender/xilem/main/README.md> | `715125e5cc94a253ab9ee198f75a1e8aee77ba7a7b40b1c90236ef91a131edc8` |
| yoga-about | <https://www.yogalayout.dev/docs/about-yoga> | `0bb8ccf5f1406b353bf19b50d29d82da3da01e7583d49dc79d27202b38ca4973` |
