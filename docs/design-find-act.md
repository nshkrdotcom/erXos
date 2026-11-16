# Find and act: the palette, routes and bindings

**Find and act** is the layer of a person's desktop session above its
windows: a **palette**, one window in which the person finds any command
the session can run by typing part of its name, and in which a typed
value on the screen, a process in stats or a file in files, shows the
commands that take it, the usual one first. It adds no authority and no
second command system. Its central construction is one sentence: **an
act is a line of rc that the session's own shell runs exactly as if the
person had typed it.** The table of commands is the session's command
namespace, which already carries each command's argument types; a
**route** is a rule that turns a typed value into such a line; the
palette, the context menu on a value, the Services-style "act on this"
entries, a bound key and the rc command `plumb` are only different ways
to build the line.

The architecture is [design.md](design.md); the command shell, its
command namespace, its catalogs and its evaluator are
[design-shell.md](design-shell.md); windows, presentations, the widget
toolkit, the terminal and the reserved chord are
[design-display.md](design-display.md); the desktop's own programs are
[design-desktop-programs.md](design-desktop-programs.md); apps and the
start service are [design-apps.md](design-apps.md); the inspector is
[design-live.md](design-live.md). The survey that asked for this layer
is [research-ui-synthesis.md](research-ui-synthesis.md), with its inputs
[research-ui-ux-ideas.md](research-ui-ux-ideas.md) and
[research-ui-secure.md](research-ui-secure.md).

Decisions every reader of this document needs:

* **An act is a line of rc run by the session's shell.** Whatever the
  person triggers, a palette entry, a value's offer, a bound key or
  `plumb`, becomes one unit of rc text run in a new evaluator of the
  session's shell, with the session's capabilities and the shell's
  per-command facet checks (design-shell's SH1). A value enters the
  line only as an rc variable, `$1`, which rc never splits or globs
  again, so it is always exactly one argument.
* **The table is the session's command namespace.** Commands, their
  help, the facets they need (`-erx_needs`) and the types of their
  arguments (`-erx_args`) come from the catalogs the session already
  builds ([design-shell.md](design-shell.md#commands)). Find and act
  keeps no registry of its own.
* **Routes are data the person keeps.** An ordered list of rules says
  which line a value of a type opens, which types the palette lists by
  name, and which keys run which lines. The person's file,
  `$home/lib/act`, comes before the defaults the release ships. Their
  meaning is fixed here; their surface syntax is [open decision
  1](#open-decisions).
* **One window shows every way in.** The palette is a window of the
  person's session. Opened by a key it searches commands; opened on a
  value, at the pointer, it lists that value's offers, which is the
  context menu and the Services entry in one.
* **A value on the screen only opens the palette.** The terminal and
  the widget server hand a presentation to the act service and do
  nothing else; nothing runs until the person picks a line the palette
  shows beside the value it acts on.
* **The display keeps its one reserved chord.** The palette key is the
  session's own binding, taken in the session's own windows; it is not
  reserved and the display does not know it.
* **Nothing crosses a domain.** The act service is reached by a
  registered name, and registered names never leave their domain
  ([design-domains.md](design-domains.md#frames)). No app adds a
  command to a person's palette; an app is started only through the
  start service's own judgement.

## The problem and the evidence

The survey's verdict on erXos's desktop is that its plumbing is current
and its interaction layer is rio's: "a right-button menu, dragging a
rectangle to place a window, no launcher, no palette, no 'open this
with that'" ([research-ui-synthesis.md](research-ui-synthesis.md),
section 1, item 3). It places what erXos can do that no shipping desktop
does in "find and act, identity and inspection", and asks for one design
in which a table of typed commands, routes from presentation types, a
palette, a context menu and bindings are one mechanism, not a plumber
beside a command table (section 2.6, "Commands"; section 4). Decision D5
of that record, accepted on 2026-11-15, starts the design now and its
code after stats, clock, month and files run on the desktop
(section 8).

The consumers, each a person at a desktop session today:

* **Launching.** stats, clock, month, files and a terminal start only
  from a shell, and an installed app only by typing `service NAME
  onestart display=D` ([design-apps.md](design-apps.md#interfaces)).
  design-display already expects "a launcher's `start APP display=D`"
  ([design-display.md](design-display.md#a-displays-session), "An app a
  person starts").
* **Acting on what is shown.** A pid, a domain or a budget in stats or
  an inspector window is a presentation, typed and bound to its value
  ([design-display.md](design-display.md#presentations)); a click on it
  selects a row or inserts its text at a terminal, and offers nothing
  else.
* **Opening a file.** files previews text and otherwise says that the
  desktop has no viewer for the item: "Nothing is started: files starts
  no program and no app"
  ([design-desktop-programs.md](design-desktop-programs.md#what-it-reads-and-does)).
* **Every program's own plumbing.** Without one shared way, each
  program that wants "open this" or "inspect that" grows its own menu,
  and every later program copies it (synthesis, section 3, item 12).

What the systems the survey read teach, as that record reports them
([research-ui-ux-ideas.md](research-ui-ux-ideas.md)):

| System | What erXos takes | What it leaves |
| --- | --- | --- |
| Genera and CLIM | a command loop: acquire a command by menu, typed name or a clicked object; acquire its arguments, where visible objects of the right type can be clicked or typed with completion; run it ("Presentations and commands") | the single address space, in which a presentation was the object |
| Oberon | a command is a procedure `M.P`, not a program ("Presentations and commands") | running any clicked text: here only commands of the session's namespace run |
| NeXT Services | an application indicates only the types of data it uses, and the operations that take that type are offered ("Object and document desktops") | applications installing entries unasked, which clogged the menu |
| Plan 9's plumber | rules in the person's own `lib/plumbing` decide where a value goes, so the person does not carry data from program to program; `plumb start window acid $0` starts a command in a new window with the value as its argument (Pike, "Plumbing and Other Utilities", as fetched for that record, `plumb.txt`, lines 18, 145 and 219-226) | the message server and its ports, the classification of untyped text by regular expressions, delivery to a running program |
| Quicksilver, Raycast, VS Code | one keyboard-first search over every action; an object, an action and an argument ("Find and act") | each product's own registry, which knows nothing of the selection's type |
| Durden | every action is a path, so bindings and scripts reach all of them ("Current platforms") | a virtual file tree: here every act is already a line rc can type |

Plan 9's plumber spends most of its rule language turning untyped text
into a type: a pid is recognised by `data matches '[0-9][0-9]+'` and
`arg isdir /proc/$0`, and the text under the cursor is winnowed to the
match that touches it (`plumb.txt`, lines 186-190 and 221-229). erXos's
presentations arrive typed, so that half of the plumber is not needed
for them, and what remains of a plumb rule, "a value of this type goes
to that command", is a route over the typed table.

## What exists today

In the design:

* **A typed command table.** A command module declares its name and
  help, the facets it needs with `-erx_needs` and the presentation types
  of its arguments with `-erx_args([pid, ...])`; the build emits each
  release's catalog from them, and a session builds its command
  namespace from the catalogs of the releases it holds
  ([design-display.md](design-display.md#presentations), lines
  1617-1620; [design-shell.md](design-shell.md#interfaces),
  [design-generation.md](design-generation.md#configuration-and-command-catalogs)).
* **Half of CLIM's argument loop, inside a terminal.** While the shell
  edits a command whose argument types it knows, it writes an input
  context, and the terminal highlights the presentations of those types;
  a click inserts the value's text into the line
  ([design-display.md](design-display.md#the-terminal), "Presentations
  in a terminal").
* **G4, a presentation grants nothing.** The terminal's only actions on
  a presentation are inserting its text and highlighting; a widget's
  only action is `{select, Type, Value}` to its application; `erx_term`
  and `erx_ui_server` call no facet, which an xref check proves
  ([design-display.md](design-display.md#invariants), G4; Chokepoints).
* **What a link shows is not what it holds.** A program may write a
  link whose shown text differs from its URI; the click inserts the
  URI's text, which the command line shows before anything runs
  ([design-display.md](design-display.md#security), "Presentations
  grant nothing").
* **The keyboard moves only on the person's act.** A window takes the
  keyboard only by the person's click or the menu; a client's `wctl`
  `top` raises a window and gives it no keyboard, and a new window is
  current only once clicked
  ([design-display.md](design-display.md#windows-and-the-window-system),
  "The current window"; [Interfaces](design-display.md#interfaces)).
* **One reserved chord**, kept by the display's router before any
  policy, which reaches no window and opens nothing yet
  ([design-display.md](design-display.md#windows-and-the-window-system),
  "The reserved chord").
* **Registered names stay in their domain**
  ([design-domains.md](design-domains.md#frames), "Registered names
  stay inside their domain").

In the tree:

* The shell's evaluator takes its variables as a map,
  `erx_shell_eval:new(Vars, Runner, State)`
  (`erlang/apps/erx_shell/src/erx_shell_eval.erl:145`), and runs a whole
  source with `run_source/2` (`:183`). Text that comes from a value is
  `lit` and "never a pattern" (`:68-74`), so a variable's value is
  neither split nor globbed.
* The runner's state is a working directory, standard streams, the
  command table and a reader of the session's facets, read for each
  command (`erlang/apps/erx_shell/src/erx_shell_runner.erl:99-122`).
* The command table is built from `-erx_command` attributes
  (`erlang/apps/erx_shell/src/erx_shell_namespace.erl:63`); no module
  declares `-erx_args` yet.
* `erx_win:kbd/1` reads one `kbd` record for any Erlang client of a
  window (`erlang/apps/erx_win/src/erx_win.erl:186-189`), decoded by
  `erx_win_core:kbd/1` into `{typed, Char}`, `{down, Keys}` or `{up,
  Keys}` (`erx_win_core.erl:63`, `:107`).
* `erx_vt:link_at/3` answers the link's type and text under a cell
  (`erlang/apps/erx_win/src/erx_vt.erl:246`). The terminal process
  `erx_term`, the overlapping policy and the Erlang renderer are not in
  the tree.
* `erx_desk` holds the files and stats cores only. Nothing of find and
  act exists.

## Requirements

* **FA-R1.** From any window of a person's desktop session, the person
  finds and runs any command of the session's namespace that the
  session can run, by typing part of its name.
* **FA-R2.** A presentation on the screen, in a terminal or a widget,
  and a file or folder in files, can be acted on: the person sees the
  commands that take it, the default first, and runs one with the value
  as its argument.
* **FA-R3.** What runs is a line the person could have typed at the
  session's shell, with the same authority and the same facet checks. No
  value, rule or gesture adds authority.
* **FA-R4.** Nothing runs from a value on the screen without the
  person's choice of a line, shown with the value before it runs.
* **FA-R5.** Which line a value of a type opens is data the person keeps
  and edits, over defaults the release ships.
* **FA-R6.** rc reaches the same routes.
* **FA-R7.** A key the person binds runs a line in the session's own
  windows, the palette key among them; the display keeps its one
  reserved chord.
* **FA-R8.** No app, kiosk or other domain adds a command to a person's
  palette or reaches the act service.
* **FA-R9.** Every parser of untrusted input has a fuzz target, every
  buffer has a bound, and a failure ends at most one palette or one act.

Outside this design: handing a value to an app that runs as another
principal, which is the powerbox of
[research-ui-secure.md](research-ui-secure.md) section 6.5 and needs a
design of its own; "what is this?" for any pixel and the reserved
chord's overlay, which are the identity and inspection designs of the
synthesis (section 3, items 13 and 14); notifications; the web client,
whose sessions have no display window to open a palette in; and
plumbing untyped text, which [Alternatives
considered](#alternatives-considered) explains.

## The construction

```text
 a person's desktop session: one domain, one runtime
+--------------------------------------------------------------------+
| erx_term: button 3 on a link ------------+                         |
| erx_ui_server: secondary press on a node +- {offer, Object, Where} |
|   that carries `present`                 |                         |
| files: "Open with" ----------------------+  erx_act:offer/2        |
| erx_win:kbd/1: a bound key ------------------ {bound, Line, Where} |
|                                          |                         |
|                                          v                         |
| erx_act: one process, registered in this runtime only              |
|   the rules: $home/lib/act, then the release's defaults            |
|   erx_act_core:offers/4 and entries/5, pure                        |
|   owns the ETS table erx_act_bindings, which erx_win:kbd/1 reads   |
|   one palette per display; runs a bound line itself                |
|                                          |                         |
|                                          v                         |
| the palette: a window of the session, a pure core and a process    |
|   shows offers or matching commands; on the person's choice:       |
|                                          |                         |
|                                          v                         |
| erx_act_run: a new evaluator of the session's shell                |
|   run_source(Line), $1 the value, $display the display             |
|                                          |                         |
|                                          v                         |
| the command, through the session's command namespace and SH1       |
+--------------------------------------------------------------------+
  rc reaches the same routes: `act`, `plumb` and `window` are commands
```

### Acts

An **act** is a unit of rc text and the variables it runs with:

```erlang
-type act() :: #{line := binary(),                 % rc text, at most 4,096 bytes
                 vars := #{binary() => [binary()]}}. % <<"*">> and <<"display">> only
```

`erx_act_run` runs an act in a new process: an evaluator made with
`erx_shell_eval:new(Vars, Runner, State)`, whose runner state holds the
command table the session's shell uses, the session's facets read for
each command, and a working directory and standard streams its caller
names, and then `run_source(Line, Sh)`. The palette and a bound key
name the person's home, standard input at its end, and standard output
and error to one collector, which keeps the first 64 KiB the line
writes and counts the rest; `plumb` names its own working directory and
streams. The result is the status, as rc sets it, and what the
collector kept. `*` holds the value's text when the act has a value, so
`$1` is that text, and `display` holds the name of the display the act
was started from, which shadows the session's own `display` variable
for this line alone.

Everything find and act runs goes through this one function, and every
requirement on what runs follows from it:

* **Authority** is the session's, because the evaluator is the
  session's and its runner reads the session's facets for each command;
  a command whose `-erx_needs` the session does not meet fails with
  `no_facet` before it starts, as at the shell (FA-R3).
* **Only commands of the namespace run**, because rc resolves every
  name in the session's command namespace; the namespace is the
  declaration (FA-R3).
* **A value is one argument**, because it reaches the line only as a
  variable, whose text is `lit`, never split by `$ifs` and never globbed
  (`erx_shell_eval.erl:68-74`). A file named `a b; rm -rf $home` is one
  argument to `vi`, with no quoting step that could be wrong.
* **What runs is what is shown**: the palette shows the act's line
  verbatim and the value beside it, and the evaluator runs exactly that
  line with exactly that value (FA-R4).

The evaluator's stages are admitted within the session's stage
allowance like a background job's: when the allowance is full the line
fails at once with `too many stages`, and never waits
([design-shell.md](design-shell.md#invariants), SH2).

### Objects

An **object** is a value find and act can act on:

```erlang
-type object() :: {Type :: atom(), Text :: binary()}.
%% Type: a presentation's name (erx_present:marks/0), or file, or folder.
%% Text: the presentation's canonical text, or the absolute path.
```

All objects enter through one funnel, `erx_act:offer(Input, Where)`,
whose input is one of two forms:

* `{Type, Text}`, a presentation's name and text, from a terminal link,
  a widget's `present` property or `act TYPE TEXT`. The name is read
  with `erx_present:type/1`, which makes no atom, and the text with
  `erx_present:parse/2`, the presentation reader with its fuzz target;
  the object's text is then `erx_present:text(Type, Value)`, the
  canonical form. A text that does not parse makes no object. The text
  is parsed whoever sent it, so the one check sits at the one funnel.
* `{path, Path}`, an absolute path in the session's namespace, from
  files or from `plumb` and `act`, which resolve their argument against
  their working directory first. A worker reads the path's information
  with `file:read_file_info/1`, which follows a link, unlike
  `read_link_info/1` (`otp/lib/kernel/src/file.erl:823-826`), within one
  second:
  a directory makes a `folder` object and anything else a `file` object;
  a path that names nothing makes none. A path is at most 4,096 bytes
  and holds no NUL; its other bytes are kept as they are, since it
  reaches a command only as a variable and the screen only through the
  line escape.

`Where` names the display the gesture came from and, for a pointer
gesture, the point on its screen: `#{display := Name, at => {X, Y}}`.

`file` and `folder` are not presentations: design-display's decision 16
keeps presentations to inspector paths, and no window shows a file as
one. They are object types of this design alone, so a route can name
them; a file presentation, if design-display adds one, becomes an
object with no change here.

One presentation is added for launching: the inspection schema's
`apps *name` path is marked `present app`, over a segment type of its
own, `app_name`, since a presentation over the shared `name` type would
make every attribute of that type an app
([design-display.md](design-display.md#presentations), "the generator
refuses two such presentations over one type").

### Rules

The rules are one ordered list of statements of three kinds. Their
meaning, below, is this design's; how they are written is [open decision
1](#open-decisions), and the examples use its recommended form.

| Statement | Fields | Meaning |
| --- | --- | --- |
| route | a type; for `file` only, one or more name patterns; a label; a line | an object of the type, whose last path component matches one of the patterns when it is a file, is offered the line under the label, with `$1` its text |
| list | a type | the palette's search lists every member of the type by name, each with its first offer |
| bind | a key chord; a line | the chord, typed in a window of the session's Erlang clients, runs the line |

The fields' bounds and checks:

* a type is a presentation's name, `file` or `folder`; a `list` type is
  a presentation of one variable segment whose marked path lies under a
  listing path, such as `pid` under `processes` or `app` under `apps`,
  so its members can be listed;
* a name pattern is at most 255 bytes, with `*` for any run of bytes and
  `?` for one character, matched byte for byte against the last
  component, as FreeBSD's fnmatch(3) does without flags; the matcher
  runs in time linear in the name times the pattern, with no
  backtracking;
* a label is 1 to 64 bytes of UTF-8;
* a line is 1 to 4,096 bytes that rc's parser accepts whole;
* a chord is one to four keys, each a member of `abi/formats/input.txt`'s
  `input_rune`, such as `kmod4`, or one printable character;
* a file holds at most 256 statements in at most 64 KiB.

The reader, `erx_act_rules:read/1`, is a pure function from bytes to
rules or to the first error with its line. It fails the whole file at
its first error, so a file is used whole or not at all.

The rules in force are the person's file followed by the release's
defaults: routes and lists in that order, so the person's routes come
first and the first offer is theirs where they wrote one; a `bind` of
the person's replaces the defaults' `bind` of the same chord. The
person's file is `$home/lib/act`, as Plan 9's plumber reads
`lib/plumbing` in the person's home (`plumb.txt`, line 145). A file that
is absent is the ordinary case. One that fails to read, is too long or
fails the reader leaves the defaults alone in force, and its diagnostic,
`lib/act:LINE: REASON`, heads every palette until `act -r` reads a good
file.

The defaults are a file of the `erx_act` application,
`erlang/apps/erx_act/priv/rules`, checked in. The build reads it with
the same reader and fails on any error, and on a route or bind whose
line's first command is not in the catalog of the desktop session's
release. In the recommended form of open decision 1:

```erlang
%% A process: the inspector first.
{route, pid, "Inspect", "i $1"}.
%% An app: started on this display, in a session of its own principal.
{route, app, "Start", "service $1 onestart 'display='$display"}.
{list, app}.
%% A folder opens in files; text opens in vi, in a terminal of its own.
{route, folder, "Open", "files $1"}.
{route, file, ["*.txt", "*.md", "*.log", "*.conf", "*.erl", "*.hrl",
               "*.c", "*.h", "*.rb", "*.sh", "*.rc"],
 "Edit", "window vi $1"}.
%% The palette key: the logo key with Space.
{bind, [kmod4, $\s], "act"}.
```

The defaults carry no route that changes a file or a service on a
value alone: installing a package stays `cp NAME.app /apps/`, typed
([design-packaging.md](design-packaging.md)).

The palette key is the logo key with Space because the logo key types no
character, so the chord takes nothing a program in a terminal reads, and
the shipped layout makes both Meta keys `Kmod4`
(`abi/keymaps/us.txt:116-117`). It is a rule like any other, which a
person changes in their file.

### Offers

`erx_act_core:offers(Object, Rules, Table, Facets)` is a pure function
that lists what an object can be given to:

1. every route of the object's type whose patterns match, in rule order;
2. then, by name, every command of the table whose first `-erx_args`
   type is the object's type, as the route `NAME $1` labelled with its
   name, which is NeXT's Services drawn from the declarations commands
   already make;
3. keeping only an offer whose line's first command is one the table
   holds and whose `-erx_needs` the session's facets meet, and dropping
   an offer whose line an earlier one already has.

The first offer is the **default**. The filter in step 3 is a
convenience, so the palette shows what can run here; the gate is the
shell, which checks the facets again when the line runs.

`erx_act_core:entries(Query, Rules, Table, Facets, Members)` lists what
the palette's search shows before any object is chosen: every Erlang
command and program command of the table the session can run, labelled
with its name and the first line of its help, but no builtin or
function, which acts on a shell's own state while an act's evaluator is
new each time; and for each `list` type, each of its members, `Members`
being the listings the palette read, with the member's first offer. An
entry matches when the query's characters appear in its label in order,
ignoring ASCII case; matches rank prefix first, then those that match at
the start of a word, then the rest, each group by label. The palette
shows at most the first 256, the bound of a `list` widget.

### The palette

The palette is a program of the desktop session's release, built as
design-desktop-programs builds its programs: a pure core,
`erx_act_palette_core`, with `init`, `step` and `view`, a thin window
process that performs its effects, and a worker for each request in
flight ([design-desktop-programs.md](design-desktop-programs.md#the-construction)).
Its effects are a listing of a type's members through the session's
inspect facet, `{run, Tag, Act}`, the window's placement, asking for the
keyboard ([open decision 2](#open-decisions)) and `close`.

It opens in one of two ways, and is the same window either way:

* **On no object**, from `act` or the palette key, near the top of the
  screen: an input line and the matching entries. While the input holds
  one word, Return runs the selected entry: a command entry runs its
  name alone, a member entry runs the member's default offer. Once the
  input holds more, it is an rc line: the list shows the members of the
  type that the command's `-erx_args` gives the argument under the
  cursor, Tab inserts the selected member's text, and Return runs the
  line as typed. Arguments without a declared type complete nothing.
* **On an object**, from a gesture on a value or `act TYPE TEXT`, at the
  point `Where` names: the object's text at the top, its offers below,
  the default selected, and an input that filters the offers by label.
  Return, or a click, runs the selected offer.

Under the list the palette always shows the selected offer's line
verbatim, so the person sees what will run, `$1` and all, beside the
value `$1` will be. Every text it shows, labels, lines, object texts,
output and diagnostics, is a widget text property, which every renderer
draws through the line escape (design-display's G5).

When an act ends with an empty status and no output, the palette
closes. Otherwise it shows the status and the output, cut to 200 lines
of at most 4,096 bytes each, as files cuts a preview, with a note of how
many bytes the collector did not keep, until the person closes it. While
an act runs, the palette shows that it runs; Escape or closing the
window ends the palette, and the act with it, since the act's process is
linked to the palette's.

A session has at most one palette on each display: a new one replaces
the one open there. The palette ends on Escape, after an act that
needs nothing shown, when its window ends, and when another window
becomes current, which it learns from its window's `wctl` read once
design-display reports the current state there (open decision 2).

A member listing runs in a worker with stock OTP's `max_heap_size` set
to 4 MiB, as files lists a folder
([design-desktop-programs.md](design-desktop-programs.md#bounds)), with
the inspector's one-second timeout. A listing that fails, times out or
outgrows the cap shows as a line in the list's place with its status,
`scope`, `timeout` or "too many to list", and nothing is made up in its
place.

### Bindings

A bound key is taken where every key of an Erlang client passes:
`erx_win:kbd/1`. After decoding a record, it consults the ETS table
`erx_act_bindings` of its own runtime, whose one row is the map from
chord to line. On a `{down, Keys}` whose set equals a bound chord, it
sends `{bound, Line, Where}` to `erx_act`, with the window's display as
`Where`, and drops that record and every `{typed, _}` and `{up, _}`
record that follows until the chord's last non-modifier key is up, so
the key's character, its repeats and its release reach no caller. A
pure function, `erx_win_core:bind/3`, decides each record from the
table's map and whether a bound chord is held. That one fact needs a
home between reads, and a `typed` record does not carry the keys held,
so `kbd/1` answers the next handle with each key, `{ok, Key, Window}`,
as `resized/1` already answers a new handle after a resize
(`erlang/apps/erx_win/src/erx_win.erl`), and the handle carries the
fact and the name of the display it was opened on. The one caller in
the tree, `erx_ui_lvgl`'s key reader
(`erlang/apps/erx_ui/src/erx_ui_lvgl.erl:430-435`), threads the handle
as its pointer reader already does.

What follows by construction:

* **Every Erlang client of the session gets the bindings**, the
  terminal and every renderer of the widget toolkit, with no binding
  code in either, since both read their keys through `erx_win:kbd/1`. A native
  program reads its window's `kbd` through fids its handler walked for
  it, so a program keeps every key of its window, as a full-screen
  program in a terminal does.
* **Bindings live exactly as long as the act service.** The table is
  `erx_act`'s, so it dies with the process: while `erx_act` is down a
  bound key reaches its window as an ordinary key, and nothing is left
  over to swallow keys for a service that is gone.
* **An app's window gets every key.** An app's session runs no
  `erx_act`, so its runtime has no table and `kbd/1` takes nothing.
  The same holds on a kiosk, whose app's release runs no shell
  ([design-display.md](design-display.md#a-displays-session)), so no
  key at a kiosk reaches a command line.
* **The reserved chord is untouched.** The display's router keeps it
  before any window is asked
  ([design-display.md](design-display.md#the-input-router)), so it
  never reaches `kbd/1`.

`erx_act` runs a bound line as an act with `$display` set and no value.
When the act ends with a non-empty status or with output, `erx_act`
opens the palette on that display showing the result, the one place
results are shown. A line that does not end runs until it does, as
`cmd &` does at a shell.

### Gestures on a value

Two places hold presentations on the screen, a closed set that G4
already names, and each gains one action:

* **The terminal**: button 3 on a cell that carries a link sends `{offer,
  {Type, Text}, Where}` to `erx_act`, the type and text from
  `erx_vt:link_at/3`, which are the link's URI and never the cells'
  shown text. Button 3 inside a window is the client's; the overlapping
  policy's menu takes the right button only outside every window.
* **The widget server**: a renderer reports a secondary press on a node
  as `{act, NodeId}`, and the server, when the node carries a `present`
  property whose status is `ok` or `partial`, sends `{offer, {Type,
  erx_present:text(Type, Value)}, Where}` to `erx_act`. The report
  reaches no application, so the renderers' parity on application
  events is unchanged. The Erlang renderer reports button 3; the LVGL
  and browser renderers serve kiosks and the web, whose sessions run no
  act service, and report nothing.

Each sends only when a process is registered as `erx_act` in its
runtime, so in a session without find and act the gesture does nothing.
Neither calls a facet or the evaluator.

files gains an "Open with" toolbar button, enabled while an item is
selected, which calls `erx_act:offer({path, Path}, Where)` with the
item's exact path from its core, never its shown name
([design-desktop-programs.md](design-desktop-programs.md#names-and-contents-are-untrusted)).
files itself still starts nothing: the palette runs what the person
picks.

### The commands

Three Erlang commands of the `erx_act` application, in the desktop
session's release; none declares a facet:

| Command | Does |
| --- | --- |
| `act` | opens the palette on `$display` with no object |
| `act TYPE TEXT`, `act PATH` | opens it on that object: a presentation, or the file or folder the path names |
| `act -r` | reads the rules again and prints the reader's diagnostic, or nothing when the file is good or absent |
| `plumb PATH`, `plumb TYPE TEXT` | runs the object's default offer as an act, in `plumb`'s own working directory and with its own standard streams, and ends with the act's status |
| `plumb -l PATH`, `plumb -l TYPE TEXT` | prints each offer, its label, a tab and its line, one a line, and runs nothing |
| `window` | opens a terminal of the session on `$display`, as Ctrl-Shift-N does |
| `window CMD [ARG ...]` | opens a terminal whose shell runs the words as one simple command, without parsing them again, and ends when it ends |

`plumb` is rc's way to the routes, as `open` is on macOS and `plumb` is
on Plan 9. `window` takes its name and its use in a route from rio's,
which the plumbing paper's `plumb start window acid $0` shows
(`plumb.txt`, lines 219-226). Whether FreeBSD 15.1 has a `window` in its
base system was not checked: unverified, to be settled before the name
is used, as design-desktop-programs checked its names.

## Homes, ownership and input

Each mechanism, the consumer that needs it, and the home design.md's
rule gives it
([design.md](design.md#decisions), "a new need has one of three homes").
That rule governs entry points between domains; inside one domain
processes call each other freely, so a mechanism that never leaves the
session needs no home, and none is added.

| Mechanism | Consumer | Home | Owner | Untrusted input it reads, and its fuzz target |
| --- | --- | --- | --- | --- |
| acts, `erx_act_run` | everything that runs | none: the session's own evaluator | the session; runs with its capabilities | rc text from the person's rules or typing: rc's parser, whose fuzz target exists ([design-shell.md](design-shell.md#verification-and-testing)) |
| the rules | which line a value opens; keys | bytes the person keeps: an ordinary file in `$home`, and a file of the release | the person; read by `erx_act` | the rules file: **new fuzz target**, `erx_act_rules:read/1` with the matcher |
| objects | all gestures, `act`, `plumb` | none: an argument of `erx_act:offer/2` | `erx_act` | presentation texts from terminal links: `erx_present:parse/2`, whose fuzz target exists; paths: bounded and passed as data |
| `erx_act` | holds the rules, the bindings table, one palette per display | none: a local process, registered in its own runtime, serving no facet and no tree | the desktop session's release | messages from its own runtime only |
| the palette | launching, offers, results | a window through the session's display grant | the session | the person's typing, as rc text; inspector listings, as typed records; command output, as attributed text through the line escape |
| bindings | the palette key, lines on keys | the client library's key reader | `erx_act` owns the table; `erx_win` reads it | `kbd` records from the display, already decoded by `erx_win_core:kbd/1` |
| `act`, `plumb`, `window` | rc | commands of the namespace | the session | arguments: a path, or a type through `erx_present:type/1` and a text through `parse/2` |

No inspection path is added: nothing outside the session reads the act
service's state, and a person reads the rules with `cat` and their
diagnostic from `act -r` or the palette.

## Apps and other domains

* **An app adds no command to a person's palette.** The palette's table
  is the person's session's command namespace, which holds only the
  commands of releases that session holds
  ([design-shell.md](design-shell.md#data-model)); an app's commands run
  in the app's own session. There is no path by which a command of one
  principal is offered in another's session, so there is nothing to
  admit.
* **An app is reached by starting it.** The `app` presentation, its
  `list` statement and its route turn every row of the start table into
  a palette entry whose line is `service NAME onestart`, and the start
  service judges that command as it judges it from a shell
  ([design-apps.md](design-apps.md#how-a-command-is-judged)): the
  session needs the `start` grant, which `service` declares, so a
  session without it is offered no app at all. The members come from
  the `[apps]` listing, which only an inspect facet of scope `all`
  reads ([design-apps.md](design-apps.md#interfaces), "Inspection");
  [open decision 3](#open-decisions) is what a release build's
  administrator sees.
* **Handing an app a value waits for the powerbox.** Opening a person's
  file in an app of another principal needs a grant from one session to
  another, a new cross-domain facet
  ([research-ui-secure.md](research-ui-secure.md), section 6.5). When
  that design adds a command to the session's namespace, routes reach it
  as they reach any command; nothing here changes.
* **An app's own presentations stay in the app.** An app's widget
  server is in the app's runtime, which has no `erx_act`, so a secondary
  press there does nothing; whatever an app draws, including a fake
  palette, runs with the app's authority and reaches nothing of the
  person's session.
* **No domain reaches `erx_act`.** It is reached only by its registered
  name, and a registered name of another domain cannot be addressed
  ([design-domains.md](design-domains.md#frames)); it encodes its pid
  into no frame, so no export entry ever names it.

## Concurrency and failure

`erx_act` is one `gen_server` under the `erx_act` application's
supervisor. It never waits: the rules are read by a worker with a
one-second timeout, path information by a worker, offers are a pure
computation, and palettes and acts are processes of their own. A
reload builds the new map and replaces the table's one row, so a
reader sees the old bindings or the new, never a mixture. Palettes are
linked to `erx_act` and monitored by it to keep the one-per-display
map; an act is linked to the palette that started it, and a bound
line's act to a temporary runner under `erx_act`'s supervisor.

| Failure | What the person sees | What recovers it |
| --- | --- | --- |
| `erx_act` crashes | open palettes close; bound keys reach windows as ordinary keys | its supervisor restarts it, which reads the rules and fills the table again |
| the rules file fails to read, times out, is too long or fails the reader | the defaults alone; `lib/act:LINE: REASON` heads every palette | `act -r` after the file is fixed |
| a presentation's text does not parse | the palette, opened on the gesture, says that the text is not a value of the type, and offers nothing | none needed |
| a path names nothing | `act` and `plumb` fail with FreeBSD's `ENOENT` text | none needed |
| no offer for an object | the palette says no command takes it; `plumb` fails | a route in the person's file |
| a line fails or crashes | the palette shows the status and output | none needed |
| a line runs long | the palette shows that it runs | Escape or closing the palette ends it |
| a line writes more than 64 KiB | the first 64 KiB and how many bytes were dropped | none needed |
| the stage allowance is full | the status `too many stages` at once | none needed |
| a member listing fails or outgrows its cap | its status in the list's place | typing the value |
| the palette's display ends | the palette and its act end with it | none needed |
| the keyboard cannot be handed to the palette in time | the palette opens without it; a click picks it | none needed |

A failure ends at most one palette and the act it runs, or `erx_act`
and every open palette with it; the session, its shell and its other
windows are untouched.

## Refusals and error results

| Request | Result |
| --- | --- |
| `act` or `plumb` with a type `erx_present:type/1` does not know, other than `file` and `folder` | `act: TYPE: unknown type` or `plumb: ...`, status 1 |
| a text that does not parse as its type | `act: TEXT: not a TYPE` or `plumb: ...`, status 1; on a gesture, the palette's note |
| a path that names nothing | `act: PATH: No such file or directory` or `plumb: ...`, FreeBSD's text for `ENOENT`, status 1 |
| `plumb` on an object with no offer | `plumb: no route for TEXT`, status 1 |
| `act` with no display, or a display that refuses the window | `act: no display`, status 1, as `erx_ui:open/1` answers `{error, no_display}` |
| `act -r` on a bad file | the diagnostic on standard error, status 1; the defaults stay in force |
| an offer whose command the session cannot run | not shown; typed anyway, the line fails with `no_facet` at the shell's check |
| more than one palette on a display | the new one replaces the old |

## Security

The threat model is the system's: development builds run trusted code
only ([design.md](design.md#decisions), "Development builds run
trusted code only"), and what a hostile peer could do here is stated,
not engineered against.

* **No authority is added.** Every act is a line run by the session's
  own evaluator with the session's capabilities; find and act holds no
  facet, grant or capability of its own, serves none, and reaches no
  service but through commands (FA1).
* **Presentations still grant nothing.** A presentation reaches
  `erx_act` only as a type and a text, which the funnel parses; it
  opens a palette, and what runs then is a line the person chose (FA2).
  A program that writes a link labelled `a.txt` whose URI names
  `pid/3.45.0` gets a palette that shows `3.45.0` and the offers of a
  pid, since the object comes from the link's URI (FA4).
* **No injection.** A value is a variable, which rc never rescans, so
  no file name, process name or link text can become a second word or a
  command (FA3); a file's or folder's text is an absolute path, which
  begins with `/`, so no command takes it for an option. Labels and lines
  come from the person's
  rules; output comes from commands; both are shown only through the
  line escape.
* **The palette is not a trusted surface.** It is a window of the
  person's session, drawn by its renderer. An app may draw a window
  that looks like it, and keys typed into that window are the app's;
  such a window can run nothing in the person's session. Telling the two
  apart is the reserved chord's overlay, the identity design of the
  synthesis (item 13). This is a residual.
* **The keyboard pass stays inside one grant.** Under open decision 2's
  recommendation a client may hand the keyboard only from its own
  current window to another window of the same grant, within 500 ms of a
  key or button down the display delivered to the current window, the
  user-traced act of the accepted clipboard rule (synthesis D3,
  [research-ui-secure.md](research-ui-secure.md) section 6.2). It
  cannot take the keyboard from another client, so it moves no key a
  client could not already read.
* **The rules file is the person's.** A program of the session that
  may write `$home/lib/act` can route a type to a line of its choosing,
  exactly as it could edit the person's rc functions or scripts; it is
  the same trust as any file in `$home`, recorded as a residual.
* **Bounds.** The rules file is 64 KiB and 256 statements; a line 4,096
  bytes; an act's kept output 64 KiB; a listing worker 4 MiB; a session
  has one palette per display; an act's stages are within the session's
  allowance.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **FA1.** An act runs with the session's authority and no more | `erx_act_run` is the only way find and act runs anything, and it runs a line in the session's evaluator, whose runner reads the session's facets for each command; nothing in find and act holds or makes a capability | a palette or binding that calls a command's module directly; a runner state with facets of its own | a session without the inspect facet: the pid offers do not include `i`, and the line `i 3.45.0` typed into the palette fails with `no_facet`; the source check of FA2 |
| **FA2.** A gesture on a value only opens the palette | `erx_term` and `erx_ui_server` reach find and act only by sending `{offer, ...}` to `erx_act`; `erx_act` runs a line only on the palette's `run` effect, a bound key or `plumb` | a terminal or widget server that runs a default offer; an `erx_act` that runs on an offer | a test that right-clicks a pid and a file with a recording evaluator, which records no run; an xref check that `erx_term`, `erx_ui_server` and their callees reach neither a facet client nor `erx_act_run` |
| **FA3.** A value reaches a command as exactly one argument | the value is `$1`, a variable, whose text the evaluator holds as `lit` and never splits or globs | a line built by pasting the value's text into rc source | a recording command run by a route on files named with a space, `'`, `;`, `$`, `*`, `[`, a newline and a first `-`, which receives each path as one argument |
| **FA4.** The palette shows what runs | the object's text is the canonical text of the parsed value, from a link's URI, never from the shown cells; the offer's line is shown verbatim; both through the line escape | an object built from a window's shown text; a line shown after a rewrite | a terminal link whose shown text differs from its URI, after which the palette's object text is the URI's |
| **FA5.** Bindings exist only while `erx_act` lives, and only in its own runtime | the table is created and owned by `erx_act`, so it dies with it; `erx_win:kbd/1` reads only its own runtime's table | bindings kept in a persistent term or a table of another owner | kill `erx_act`: the bound chord then reaches the terminal's tty; an app session's window receives the chord as keys |
| **FA6.** A bound key reaches no caller | `erx_win_core:bind/3` drops the bound down and every typed and up record until the chord's last non-modifier key is up | a funnel that drops only the down | the chord typed in a terminal window: the palette opens and the tty receives none of its bytes, held long enough to repeat |
| **FA7.** Everything find and act keeps is bounded | the bounds of [Security](#security), each enforced where the data enters: the reader, the collector, the worker's heap flag, the one-per-display map | a reader without its size check; a collector that keeps all output | the bound tests of [Verification](#verification-and-testing) |

## Verification and testing

Each test names the fault that must make it fail, so that a pass shows
the code under test ran. Host tests run the pure cores with no display;
hosted mode runs the session's applications with a display model; one
QEMU test runs the whole path.

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| offers, host | a pid object gets the person's route, then the defaults', then `-erx_args` commands by name, each once | offers that skip step 2 lose the derived commands; offers that skip the duplicate rule show `i $1` twice |
| needs filter, host | with facets lacking `inspect`, no offer starts with `i` | a filter that ignores `-erx_needs` |
| the shell is the gate, hosted | the line `i 3.45.0` from the palette in that session ends with `no_facet` | a runner state given a facet map of its own |
| no run on a gesture, hosted | right-click on a pid and "Open with" on a file open a palette and the recording evaluator records no run | an `erx_act` that runs the default offer on `offer` |
| one argument, hosted | a recording command receives each awkward file name of FA3 as exactly one argument, through a route and through `plumb` | an act built by splicing the path into the line's text |
| link spoof, hosted | a link shown as `a.txt` whose URI is `pid/3.45.0` opens a palette on the pid `3.45.0` | an object taken from the cells' text |
| unparsable text, host | a link whose text is not a pid this runtime can name makes no object, and the palette says so | a funnel that passes the raw text on |
| rules reader, host | every example of this document reads; a bad line fails the file with its line number; an empty or absent file leaves the defaults | a reader that keeps the statements before the bad one |
| rules bounds, host | a file of 64 KiB and one byte, a 257th statement, a 4,097-byte line, a 65-byte label and a five-key chord are each refused | each bound removed in turn |
| rules order, host | the person's route for `pid` is the default; the person's `bind` of the default chord replaces it | a merge that puts the defaults first |
| matcher, host | `*` and `?` match as fnmatch(3) without flags on the cases of a table; a pattern of 255 `*` against a 255-byte name ends within a fixed step count | a backtracking matcher fails the step count |
| defaults check, build | the shipped defaults read, and every line's first command is in the desktop release's catalog | a seeded route to a command no release declares |
| bindings swallow, hosted | the chord in a terminal window opens the palette and the tty receives no byte of it, held through repeats | a funnel that drops only the down record |
| bindings die with the service, hosted | after `erx_act` is killed the chord reaches the tty; after its restart it opens the palette again | the table kept in a persistent term |
| app windows, hosted | in an app session's window the chord arrives as keys | a funnel that reads a table of another runtime |
| widget gesture, host | a secondary press on a node with an `ok` or `partial` `present` sends an offer; on `unknown`, `timeout` or no `present`, none | a server that forwards every status |
| output bound, hosted | a line that writes 1 MiB shows its first 64 KiB and the count of the rest, and the palette's heap stays within its bound | a collector without its cap |
| listing bound, hosted | completing a `pid` argument over a listing that outgrows 4 MiB shows "too many to list" | the worker spawned without its heap flag |
| never fabricate, host | a member listing answering `scope`, `timeout` and an error shows each as its status | a palette that shows an empty list for a failed listing |
| one palette per display, hosted | a second `act` on a display ends the first palette | a map that keeps both |
| `plumb`, hosted | `plumb notes.txt` runs `window vi` on the file and returns its status; `plumb -l` prints the offers; an unrouted file fails with status 1 | a `plumb` that ignores the person's file |
| the source checks | the FA2 xref check fails on a seeded call from `erx_term` to `erx_act_run` | none further |
| desktop, QEMU | on the desktop image, the palette key in the first terminal opens the palette; typing `files` and Return opens a files window | the default binding removed |
| keyboard pass, hosted, if open decision 2 takes (b) | the palette opened by a key is current at once; a `current` write with no recent act, or for another grant's window, fails with `EINVAL` | the rule without its grant check, under which a second session's window takes the keyboard |

The palette's core is not a protocol state machine, so it is tested on
its cases, not exhaustively.

## Performance

Offers and entries are pure work over at most 256 rules and the
session's command table, which is microseconds. The key path gains one
ETS lookup for each `{down, _}` record in every Erlang client of a
session. The rules are read at `erx_act`'s start and at `act -r`, never
on a gesture. A member listing is one inspector query per argument, in a
worker.

The cost that matters is the palette's appearance: a window made, a
buffer allocated, a tree laid out and drawn, and the first present
answered, all after a key. It is unmeasured; the watch list holds it
([todo-performance.md](todo-performance.md)), to be settled with a
`tools/erx bench` workload from the bound key's down to the palette's
first present answer, under QEMU and on a Raspberry Pi 4.

## Changes to other designs

Find and act needs these changes elsewhere, made when this design is
accepted:

* **design-display.** G4 names the third action: the terminal and the
  widget server hand a presentation to the session's act service, which
  only opens the palette; the chokepoint row "`erx_term` and
  `erx_ui_server` call no facet" adds "and no evaluator". The terminal's
  button 3 on a link offers it. The renderer behaviour gains the
  `{act, NodeId}` report, which the Erlang renderer makes on button 3,
  and the widget server forwards. `erx_win:kbd/1` consults the bindings
  table and answers `{ok, Key, Window}`, its handle carrying whether a
  bound chord is held and the display's name. Open decision 2's `wctl`
  change, if taken.
* **The inspection schema.** A segment type `app_name` for `apps
  *app_name`, marked `present app`.
* **design-shell.** `service` declares `-erx_args([app])`; commands that
  take a pid, a domain or another presentation first declare it, so the
  Services offers find them; the catalog carries each command's help and
  `-erx_args`, which design-display already says.
* **design-desktop-programs.** files' toolbar gains "Open with".
* **design.md** lists this document in its map.

## Dependencies

None new. Find and act is Erlang in the desktop session's release, over
the shell's evaluator and parser, the widget toolkit, the inspector and
the file protocol.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| A plumber served as a file tree, `send` and ports, as Plan 9's | every caller is a process of the same session, which calls `erx_act` directly, and design.md's homes are for entry points between domains; rc reaches routes through `plumb`; no native program has asked to plumb. Ports deliver a message to a running program, and no erXos program reads one: every route starts a command |
| Classifying untyped text by patterns, Plan 9's `data matches` with the click offset | erXos's values arrive typed as presentations, and `ls` and `grep` output stays text by design ([design-shell.md](design-shell.md)); no first-desktop consumer needs it. When one does, it is a `text` object type and a pattern statement, which bears on open decision 1, where Plan 9's grammar fits it best |
| A registry of palette contributions with titles and icons, as editors keep | a second table beside the catalogs, which every command would have to join; the catalog's names and help are the labels |
| A context menu drawn inside each window | every client would draw it, the terminal and three renderers, each in its own way; one palette window drawn by one program serves all of them |
| A global palette chord kept by the display, or the palette opened from the reserved chord's overlay | a second reserved chord is what the synthesis asks not to have (section 2.6, "Chords and overlays"); the overlay is the display's trusted surface, and opening the session's palette from it would need a channel from the display to the session that nothing else needs |
| Running the default offer on a single click, as Plan 9's plumbing does | a link's URI is chosen by whatever program wrote it, so a click could start a command on a value the person never saw; one more gesture in a window that shows the line is the price of FA2 |
| Building the line by quoting the value into rc text | correct only while the quoting is; a variable cannot be mis-quoted, because rc never rescans it |
| Apps offering commands in a person's palette | a command of one principal run in another's session, or a new cross-domain protocol, for no consumer; the powerbox is the design for handing an app a value |
| files' kind table as the source of routes | a kind is a guess at a file's content for its icon; a route is the person's choice of command; they need not change together, so they are not one fact |
| Ranking by use, hiding entries | no consumer yet: few commands declare `-erx_args`, so the Services lists are short; the rule order is the ranking |
| A click on a presentation in any window filling the palette's argument, CLIM's full loop | the act service would track every terminal's and widget server's context, a coordination of many participants; the palette's completion from the type's listing, and object-first offers, cover the cases |

## Open decisions

**1. How the rules are written.** The rules' meaning is fixed above: a
type, name patterns for files, a label and an rc line for a route; a
type for a list; a chord and an rc line for a binding. In every option
the line is rc, the shell's own grammar, and no option needs a rule
engine: there is no join, recursion or negation. The choice is the
outer syntax, which needs approval under the language rule
([design.md](design.md#decisions), "Languages").

| Option | What it costs | What it gives |
| --- | --- | --- |
| (a) Plan 9's plumbing language, the part that applies: `type is`, `plumb start`, with `name matches` for files | a reader of a grammar half of whose verbs (`plumb to`, `plumb client`, `src`, `wdir`, `attr`, the click attribute) mean nothing here, so it would look like Plan 9's without being it | familiarity to Plan 9 users; the best fit if untyped text is ever plumbed, since its regular expressions and winnowing are built for that |
| (b) awklog | a Datalog engine in AWK for rules with no join; on the target it would run under toybox's `wak` as a program, or the person's file would need a host step | nothing these rules use; awklog's place is a host-side check |
| (c) Datalog, Soufflé or an engine in Erlang | Soufflé is a host C++ tool; an Erlang engine is a new module for the same nothing | as (b) |
| (d) Erlang terms, one tuple a statement, read with `erl_scan` and `erl_parse` and checked by one shape reader | no new grammar: every runtime already reads Erlang terms; scanning makes atoms before the shape check, at most about 21,000 from a 64 KiB file, in the session's own table, whose limit is 1,048,576 (`otp/erts/emulator/beam/atom.h:32`); the person writes Erlang's quoting around rc's | the system's own language; the reader is a shape check over terms; the examples above |
| (e) a line format of erXos's own, rc's word syntax for every field, `route file '*.txt' Edit window vi $1` | a small new grammar and its reader, beside rc's | one quoting rule for the whole line; it reads like the shell |

Recommendation: **(d)**. It adds no language, and its reader is a check
of a closed set of term shapes, with its fuzz target. If untyped text
plumbing becomes a goal, (a) is the better outer syntax for that day.

**2. Handing the keyboard to the palette.** A new window is current
only once the person clicks it, and `wctl` `top` gives no keyboard
([design-display.md](design-display.md#windows-and-the-window-system)).
So a palette opened by a key cannot be typed into, and one opened at
the pointer takes its first click as a pick, which the policy keeps for
itself. Options: (a) no change: the person clicks the palette before
using it; (b) rio's `current` as a `wctl` command, admitted only when
the window's grant holds the current window and that window received a
key or button down within the last 500 ms, the user-traced act of the
accepted clipboard rule (synthesis D3), and refused with `EINVAL`
otherwise; with it, `wctl`'s read carries whether the window is current,
so the palette can close when the person picks another window. (c) the
palette drawn inside the window the gesture came from, rejected under
[Alternatives considered](#alternatives-considered). Recommendation:
**(b)**. The keyboard still moves only on the person's act, and only
between windows of the client that already has it, so no client gains a
key it could not read before; without it the palette and the context
menu each cost an extra click on every use. It changes an accepted rule
of design-display, which is why it is not taken here. The `wctl` read's
current-state word is rio's form, unverified in this task against a
rio source.

**3. App names in a release build's palette.** The palette lists apps
from the `[apps]` listing, which only an inspect facet of scope `all`
reads; in a release build no session holds one, so an administrator's
palette, which may start apps, cannot list them. Options: (a) leave it:
development builds, where `root` holds scope `all`, list apps, and a
release build's administrator types `service NAME onestart`; (b) a
visibility class for the start table's row names, readable by a facet
whose principal holds the `start` grant, in the inspection schema and
design-apps. Recommendation: **(a)** until a release build exists, since
nothing ships before the security closure milestone and (b) changes who
sees what in the inspector.

## References

* [research-ui-synthesis.md](research-ui-synthesis.md): sections 1, 2.4,
  2.6 and 3, decision D5 and section 8.
* [research-ui-ux-ideas.md](research-ui-ux-ideas.md): "Presentations
  and commands", "Object and document desktops", "Find and act",
  "Current platforms", ranks 1, 2 and 10; its sources as fetched on
  2026-11-15, among them Rob Pike, "Plumbing and Other Utilities",
  `https://9p.io/sys/doc/plumb.html`, SHA-256
  `af88d34db2de942bd3a8226491807d9e10ccc7c43c0909908d3ca4e5251d2d15`,
  read as text at
  `~/erxos-scratch/sources/ui-survey/ux-ideas/txt/plumb.txt`.
* [research-ui-secure.md](research-ui-secure.md): sections 4.11, 4.12,
  6.2, 6.4 and 6.5.
* [design-display.md](design-display.md): Presentations, The terminal,
  Links and the input context, Windows and the window system, The
  widget server, Erlang clients, Interfaces, Security, G4 and
  Chokepoints.
* [design-shell.md](design-shell.md): Commands, rc as a program,
  Interfaces, SH1 and SH2.
* [design-desktop-programs.md](design-desktop-programs.md): The
  construction, files.
* [design-apps.md](design-apps.md): Interfaces, How a command is judged.
* [design-domains.md](design-domains.md): Frames, "Registered names
  stay inside their domain".
* FreeBSD fnmatch(3), for the name patterns' meaning without flags; not
  fetched in this task, to be read at the pinned FreeBSD release before
  the matcher is written.
