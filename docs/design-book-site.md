# The book on the website

The book in [book/](book/README.md), *erXos: An Operating System in
Erlang*, is written in GitHub Flavored Markdown and read today on the
repository host. This document is the contract for publishing it as
part of the website: a build step, in Ruby host tooling, that turns the
chapters into static HTML pages with the site's look, self-hosted
fonts, and diagrams drawn at build time from the Mermaid source the
chapters already hold. It says what the book is made of, what the site
does today, which tools the step runs and why, how links, figures and
diagrams are rendered, what the step refuses, and how it is tested.

The request it answers: integrate the book into the website so that it
looks good, ideally by rendering the Markdown statically into styled
HTML with good fonts at build time, and make the charts and diagrams
nicer. The site's look follows the desktop's rule: modern and original,
not a copy of any product's site.

## Context

### What the book is made of

Measured at commit `622d4a5cec17` with two scratch scripts outside the
tree (`~/erxos-scratch/tools/book_survey.rb` and
`mermaid_constructs.rb`, which count fenced blocks, link targets and
Mermaid syntax by line patterns, so the counts are close, not exact):

| Item | Count |
| --- | --- |
| Markdown files in `docs/book/` | 26: chapters 1 to 23, Appendix A (`a-glossary.md`), the outline (`README.md`) and the writing guide (`style.md`) |
| Chapters and appendices the outline lists but the tree does not hold | chapters 24 and 25, the afterword, appendices B to E |
| Fenced blocks | 56 `mermaid`, 40 `text`, 35 `erlang`, 11 `c`, 5 `sh`, 4 `markdown`, 3 `ruby`, 1 untagged |
| Mermaid kinds | 32 `flowchart` (19 `LR`, 12 `TB`, 1 `BT`), 20 `sequenceDiagram`, 4 `stateDiagram-v2` |
| Figure captions (`*Figure N.M. ...*`) | 62 |
| Tables | 69, about 490 rows |
| Block quotes | about 810 lines: 24 status boxes (`> **Status.**`), about 60 background boxes (`> **Background: ...**`), epigraphs |
| Links | 1,099 to book files (`NN-name.md#anchor`, `README.md#chapter-N-...`), 735 to design documents (`../design-*.md#anchor`), 59 to other files under `docs/`, 35 to repository paths (`../../README.md#current-status`, one image), 55 same-page anchors, 29 autolinks (`<https://...>`), 1 inline `https` link |
| Images | 1: `22-display.md` shows `../../site/kiosk.png` |
| Raw HTML | none but 12 HTML comments: 10 `<!-- check: ... -->` markers in prose, 2 inside a code block |
| Footnotes, task lists, strikethrough, math | none |
| Files with bytes above 0x7f | 2 |

Headings carry their own numbers (`## 16.2 Title`, `### 16.2.1 Title`,
`docs/book/style.md`, "Mechanics"), and links name them by GitHub's
heading slug: "2.5 The L4 family and Fiasco" is
`02-microkernels.md#25-the-l4-family-and-fiasco`. A chapter's title
heading, "# Chapter 16. Storage and Updates", has the slug
`chapter-16-storage-and-updates`, the same slug as that chapter's
entry heading in the outline, which is how chapters link to the
outline of a chapter not yet written.

The 40 `text` blocks are mostly listings: shell and Erlang shell
sessions without a language tag of their own, grammars, `/proc`
listings, log line formats. Two are box drawings (`02-microkernels.md`,
a capability table; `12-memory.md`, page lookups), and a few more are
indented trees.

The Mermaid the chapters use is a small subset, all of it listed here:

* `flowchart` with direction `LR`, `TB` or `BT`; rectangles `id["label"]`,
  decisions `id{"label"}` (2) and cylinders `id[(label)]` (3, one
  diagram); edges `-->`, `---`, `-.->`, `<-->`, with labels as
  `-->|label|` or `-- label -->`; chains `A --> B --> C`; `subgraph id["title"] ... end`
  (26), two of them with `direction TB` inside an `LR` graph; `<br/>`
  in one label; one `classDef` with a `class` line (`02-microkernels.md`,
  a red stroke on two nodes).
* `sequenceDiagram` with `participant X as label`, messages `->>`
  and `-->>` (with labels), self-messages (23), `Note over X` and
  `Note over X,Y` (7), and `alt ... else ... end` (2).
* `stateDiagram-v2` with `[*]`, transitions with labels and state
  descriptions `id: text`.

Most flowcharts have 4 to 11 nodes; two have 13 and 14. The writing
guide caps a figure at about 12 nodes, forbids colors and styles
("color must not carry meaning") and picks Mermaid because GitHub
renders it (`docs/book/style.md`, "Figures and tables").

The book has no data for charts: its tables compare properties and
mechanisms, list states and statuses, and give limits; none is a
series of measurements.

### What the site does today

[site/README.md](../site/README.md) is the site's contract. The landing
page `site/index.html`, its stylesheet `site/style.css` (color tokens
on `:root`, redefined under `prefers-color-scheme: dark`) and the
console script `terminal.js` are assembled by `tools/build_site.rb`
and `Erx::Site` (`tools/lib/erx/site.rb`) into `build/site/`:

* `Erx::Site.inventory` lists `PAGE_FILES` and refuses a page that
  holds `<!-- unverified` (`UNVERIFIED`): the site publishes no draft.
* `Erx::Site.publish` builds into a fresh sibling directory and renames
  it into place, and replaces only a directory holding its `.erx-site`
  marker.
* Script and image files are published under digest names
  (`Erx::Site.digest_name`), so a deployment never pairs one
  deployment's page with another's files.
* `render_index` fills `{{name}}` placeholders, escaping every value.
* `Erx::Site::REPOSITORY` (`https://github.com/stass/erXos`) with
  `Source#url` makes the page's link to the source at a commit.
* `--serve PORT` serves the result on `127.0.0.1`; `--no-card` builds a
  preview without the board's card.
* The fonts, Archivo and IBM Plex Mono, load at run time from Google
  Fonts (`site/index.html`).

A full site build needs v64's build tools, an erXos image and a card.
Nothing renders Markdown. `~/erxos-scratch/tools/book_links2.rb`, a
scratch script outside the tree, checks the book's relative links and
heading anchors with its own approximation of GitHub's slug.

### What the tools are

Licenses read on 2026-11-20 from each project's official source over
HTTPS. The files are in
`~/erxos-scratch/sources/book-site-2026-11-20/`, listed with their URLs
and SHA-256 digests in its `RECORD.txt`; nothing fetched was run.

| Tool | What it does | License (file read, SHA-256) | Version seen |
| --- | --- | --- | --- |
| cmark-gfm | GitHub's CommonMark parser with GFM extensions, a C program; `-t xml` writes the parse tree, `--sourcepos` adds line numbers, `--smart` makes curly quotes, `-e NAME` turns on an extension, `--unsafe` passes raw HTML (`man/man1/cmark-gfm.1`) | BSD-2-Clause, with MIT-licensed parts listed in the same file (`COPYING`, `c22e885f...`) | 0.29.0.gfm.14, the latest GitHub release |
| Graphviz `dot` | layered graph layout; `-Tjson0` writes the laid-out graph as JSON with the information of `-Tdot`, positions included (graphviz.org, "JSON") | EPL-2.0 (`LICENSE` on the `main` branch, `0becf165...`) | 16.1.1, the first version on graphviz.org's download page (unverified as the current stable) |
| Mermaid | the diagram language, JavaScript | MIT (`LICENSE`, `ec9fb67d...`, read at the monorepo tag `@mermaid-js/examples@2.1.0`) | not pinned |
| D2 | a diagram language and renderer, Go | MPL-2.0 (`LICENSE.txt`, `97933e57...`, tag `v0.9.0`) | 0.9.0 |
| Pikchr | a PIC-like diagram language, one C file | 0-clause BSD (pikchr.org home page, `e463ff45...`) | not pinned |
| kramdown and kramdown-parser-gfm | Markdown in pure Ruby, as a library | MIT (`COPYING`, `cc29f6a8...` and `0da09ed4...`, read at the old tags `REL_1_5_0` and `REL_1_1_0`, the first the tag list gave; the current release's license is unverified) | not pinned |
| Rouge | syntax highlighting in pure Ruby, as a library | MIT (`LICENSE`, `8d83d5d0...`, tag `v5.1.0`) | 5.1.0 |
| Source Serif 4 | a text serif | OFL-1.1 (`LICENSE.md`, `75784a29...`, tag `4.005R`) | 4.005 |
| IBM Plex Mono | the site's mono face | OFL-1.1 (`LICENSE.txt`, `7e6b2818...`, read at the monorepo tag `@ibm/plex-sans@1.1.0`; Plex Mono's own release tag is unverified) | to pin |
| Archivo | the site's sans | OFL-1.1 by [site/README.md](../site/README.md); the repository `Omnibus-Type/Archivo` gave no release or tag, so its license file is unverified | to pin by commit |

GitHub renders Mermaid in Markdown; that it renders none of D2, Pikchr
or Graphviz is unverified. Ruby's REXML, which `cmark-gfm -t xml`'s
output needs, is already used by the tree (`tools/lib/erx/hardware.rb`).
No Ruby gem is a dependency of the tree today: there is no `Gemfile`,
and `deps.lock` holds archives, files and git trees only.

## Requirements

Each requirement names who needs it.

1. **Every chapter and appendix in `docs/book/` is a page of the site**,
   reached from a contents page, with the site's look. The reader.
2. **Rendering happens at build time; the pages carry no script.** The
   request asks for it, and a reader without JavaScript sees the whole
   book.
3. **Diagrams are drawn from the Mermaid the chapters hold**, so writers
   keep one source that GitHub also renders, and they look better than
   GitHub's rendering: the site's faces and palette, light and dark,
   crisp at any size. The request.
4. **Every link resolves**: within the book to a page and an anchor that
   exist, into the repository to the file at the commit the book was
   built from, and outward as written. The reader; the writer's
   checklist (`docs/book/style.md`, "The writer's checklist", item 13)
   asks for it today and has only a scratch script to check it.
5. **The site publishes no draft.** The site's existing rule
   (`Erx::Site::UNVERIFIED`), from CLAUDE.md's "Never fabricate".
6. **The output is a function of its inputs**: the same tree, tool
   versions and font files give the same bytes, so a rebuild shows no
   change and a test can compare. Review of a published change.
7. **The step fits the site build** and also runs alone, quickly,
   without v64, an image or a card. The writer, previewing a chapter.

Not required, because no consumer needs it: charts (the book has no
measured data), search (see "Navigation, glossary and search"),
client-side theme switching, analytics, comments, or an e-book format.

## The construction

**One parse, one renderer, one resolver, and a box for every piece of
text.** cmark-gfm, run as a subprocess, parses each Markdown file into
its XML parse tree; nothing else parses Markdown. One Ruby renderer
walks that tree and writes every byte of HTML, so all markup on a page
comes from code in the tree and every piece of text is escaped on the
way out. Every target a page names, a link, an image or a contents
entry, goes through one resolver that knows the set of pages and their
heading anchors. And every diagram is turned into a model of boxes
whose sizes Ruby fixes before any layout runs, because every label is
set in a monospaced face whose width per character Ruby reads from the
font file: Graphviz places blank boxes of given sizes, and Ruby draws
the result as SVG with classes and no colors of its own.

The requirements follow:

* GitHub parity of the Markdown (1) comes from parsing with GitHub's own
  parser; the site's look comes from the renderer, which is ours.
* No script (2): the renderer's output is complete HTML and inline SVG.
* Diagrams from the Mermaid source (3): the source stays as it is;
  Ruby reads the subset the book uses and refuses the rest by name.
  Since no layout tool sees text, no font, rasterizer or host shapes a
  layout: text and positions come from numbers Ruby computed. The
  drawing carries classes, so the stylesheet colors it for light and
  dark like any page element.
* Links (4) resolve or fail the build, because the resolver is the only
  way a target reaches a page. The book build becomes the link check.
* No draft (5): the renderer meets every HTML comment, so it sees every
  marker.
* Same bytes (6): the inputs are files and two pinned tools; the step
  reads no clock and iterates in sorted order.
* Fits the site (7): the step is a module the site build calls, with a
  small command of its own for previews.

## Pages and addresses

The book is the `book/` directory of the site:

| Address | Source |
| --- | --- |
| `book/index.html` | the contents page, built from the outline's "Contents" section |
| `book/NN-name.html` | `docs/book/NN-name.md`, one page per chapter or appendix file |
| `book/outline.html` | `docs/book/README.md`, the outline |
| `book/style.html` | `docs/book/style.md`, the writing guide |
| `book/book-<digest>.css`, `book/fonts/<face>-<digest>.woff2`, `book/fonts/OFL-<face>.txt` | the stylesheet, the fonts and their licenses |
| `book/media/<digest>-<name>` | each image a page shows |

Every Markdown file in `docs/book/` is a page, so a link from one file
to another is a link from one page to another, with nothing rewritten
but the suffix.

**The contents page** is derived from the outline's "Contents" section,
which already lists the parts, the chapters and the appendices in
order. Each link there is an entry; its part is the bold text that
opens the paragraph it sits in, or the nearest such paragraph before
its list ("**Part I. Background**", "**Appendices.**"). An entry names
its chapter by slug (`#chapter-16-storage-and-updates`); the page whose
title heading has that slug is the chapter. An entry with no such page
is shown without a link, marked as in preparation. A chapter or
appendix file that no entry names is refused, so no page is
unreachable. The same order gives each page its previous and next page,
skipping entries without a page.

## Markdown to HTML

### Options

| Option | For | Against |
| --- | --- | --- |
| **cmark-gfm as a subprocess, its XML tree rendered by Ruby** | GitHub's own parser, so the site reads the Markdown exactly as the repository host does; C, BSD-2-Clause; an external tool invoked as a subprocess, as CLAUDE.md asks; the tree is ours to render, so heading ids, figures, links and diagrams need no hooks into a library | one more host tool to fetch and build (CMake); the renderer is ours to write, about 300 lines (estimate) |
| kramdown with kramdown-parser-gfm, in process | pure Ruby, MIT; an HTML converter included | its GFM is not GitHub's parser, so some constructs read differently (unverified which); it would be the tree's first in-process gem, loaded rather than run as a subprocess; heading ids and link rewriting go through its converter's hooks |
| commonmarker | GitHub's dialect | its current versions are a native extension written in Rust (unverified for the latest release), linked into the Ruby process: against both "no Rust" and "subprocesses, never linked" |
| our own Markdown parser for the book's subset | no dependency | CommonMark's inline rules (emphasis, code spans, links with backticks) are where hand-written parsers go wrong; about 600 lines (estimate) to maintain beside a mature parser |

**Decision: cmark-gfm.** It is run once per file as
`cmark-gfm -t xml --sourcepos --smart -e table -e autolink FILE`
(the extension names are unverified; `--list-extensions` gives them),
under the site's deadline runner (`Erx::Runner`). `--smart` gives the
pages curly quotes and apostrophes while the source keeps the straight
quotes the writing guide asks for; code is not affected. `--unsafe` is
never given.

### The renderer

`Erx::Book::Page` reads the XML with REXML and walks it once. Each
node kind has one rendering:

* **Headings** get the id GitHub would give them (below). A heading
  that opens with a section number (`16.2`, `16.2.1`) sets the number
  in its own element, so the stylesheet can hang it in the margin.
* **Paragraphs, emphasis, strong, code spans, links, lists, block
  quotes, tables, thematic breaks** render as their HTML elements.
  Tables sit in a scrolling container so a wide table never widens the
  page.
* **A block quote that opens with strong text "Status."** renders as
  the chapter's status box, and one that opens with strong text
  beginning "Background" as a background box: `<aside>` with a class
  each. Both are conventions of the writing guide, so the pages style
  what the source already marks. Other block quotes stay block quotes.
* **Fenced code** by language: `mermaid` goes to the diagram renderer;
  `c`, `erlang`, `ruby` and `sh` get highlighting (see "Code"); every
  other language, `text` included, and an untagged block render as
  preformatted text in the mono face.
* **A figure**: a diagram, a preformatted block, an image or a table
  followed directly by a paragraph that is all emphasis and begins
  `Figure N.M.` becomes `<figure>` with that paragraph as its
  `<figcaption>`, and the id `figure-N-M`. The writing guide's caption
  rule becomes the page's structure without new markup.
* **HTML comments** are dropped, after the draft check (see
  "Refusals"). Any other raw HTML is refused: the book uses none, and
  allowing it would let a page differ from what GitHub shows.
* **Every character above 0x7f** is written as a numeric character
  reference, so the generated pages are ASCII, as CLAUDE.md requires of
  generated output, whatever the prose holds.

Markup comes only from the renderer's builders, which return a value of
one type for markup; a plain `String` placed in a page is always
escaped. A template placeholder takes either, and escapes a `String`.

### Heading ids

One slug function gives every heading its id, following GitHub's rule
as `github-slugger` implements it (unverified in detail; not read from
source in this task): lower-case the text of the heading, drop every
character that is not a letter, a digit, a space, `-` or `_`, turn each
space into `-`, and add `-1`, `-2` and so on to repeated slugs in a
page. The same function gives the anchors of every Markdown file a link
names, design documents included, which it reads through cmark-gfm too.
Any disagreement with the links the writers wrote against GitHub shows
as a missing anchor, which fails the build.

## Links

The resolver takes a target as written and the file it is written in,
and returns one of three things, or refuses:

| Target | Becomes |
| --- | --- |
| a Markdown file in `docs/book/`, with or without an anchor | the page's address, with the anchor if the page has it |
| any other path inside the repository, file or directory | the repository host's address of that path at the commit the book is built from: `REPOSITORY/blob/COMMIT/PATH` for a file, `REPOSITORY/tree/COMMIT/PATH` for a directory, with the anchor; for a Markdown file the anchor must exist in it |
| `https:`, `http:` or `mailto:` | itself |
| anything else (a path that does not exist, a path outside the repository, a missing anchor, another scheme) | a refusal naming the file, the line and the target |

The repository's address is `Erx::Site::REPOSITORY`, the constant the
landing page's source link already uses, so the site has one place
that names the host. A link into the repository points at a commit
rather than a branch, so a reader of a published book reads the design
document as it was when the book was built. The commit is the full
hash of the tree's `HEAD`; the publishing build runs on a tree without
changes, so that commit holds exactly what the pages cite.

Images go through the same resolver: an image path must be a file in
the repository, of type PNG, JPEG or SVG, and is copied to
`book/media/` under a digest name.

Publishing the design documents themselves as pages of the site, so
that the 735 links to them stay on the site, is left out: the design
documents are the contracts, large and edited daily, and the
repository host renders them already. It is an open question below.

## Figures and diagrams

### Options

| Option | Look | Writers | Determinism | Cost |
| --- | --- | --- | --- | --- |
| (a) Mermaid's script in the reader's browser | Mermaid's own; themed through its settings | unchanged | the browser's | a script of several hundred kilobytes or more on every page (size unverified); a reader without JavaScript sees source; not rendered at build time, which the request asks for |
| (a2) Mermaid at build time in a headless browser (the tree pins `chromium-headless-shell` 158 in `deps.lock` for the web client's tests) | Mermaid's own, with inline styles to override | unchanged | text measured by the browser's font stack, so likely per platform only (unverified) | Mermaid pinned as a file; a Ruby driver for the browser; third-party JavaScript run by host tooling, which CLAUDE.md's language rules do not name |
| (b) rewrite the 56 diagrams in Graphviz, Pikchr or D2 | good to very good; D2 looks modern | they lose GitHub's preview, and learn a new language; Pikchr places every shape by hand | per tool version | rewriting every figure; D2 is MPL-2.0 and Go, Graphviz has no sequence diagrams |
| (c) **our renderer of the book's Mermaid subset: Graphviz places boxes, Ruby lays out sequence diagrams and draws everything** | ours: the site's faces and palette, light and dark | unchanged; GitHub's preview stays | exact, per Graphviz version | about 800 lines of Ruby (estimate); Graphviz as a host tool |
| (c2) as (c), with our own layered layout instead of Graphviz | ours | unchanged | exact | a layered layout with crossing reduction and nested groups is subtle code, about 600 more lines (estimate), for what a mature tool does |

**Decision: (c).** It keeps one source that GitHub renders, draws every
figure in the site's own style, and needs no script on the page and no
JavaScript in the build. The renderer accepts exactly the subset listed
in "What the book is made of" and refuses anything else with the file,
the line and the construct, so a writer who needs a new construct adds
it to the renderer instead of getting a wrong drawing. Option (a2) is
the fallback if the renderer's cost is judged too high (an open
question below).

### The diagram model

`Erx::Book::Mermaid` parses a block into one of two models:

* **A graph** (flowcharts and state diagrams): nodes with a shape
  (box, decision, cylinder; for state diagrams, state, start and end),
  groups (subgraphs) that hold nodes, and edges with an optional
  label, a line kind (solid, dotted, none) and arrowheads (at the end,
  at both ends, none). A state description `id: text` adds a line to
  the state's box. A chain `A --> B --> C` is two edges.
* **A sequence**: participants in order, and rows: a message (from, to,
  label, solid or dashed), a self-message, a note over one or two
  participants, or the start, divider and end of an `alt` frame.

Labels are split into lines at `<br/>` and wrapped at word boundaries
to at most 28 characters a line (one constant). A label is text: `<`
and `&` in it are characters, escaped when drawn.

`classDef`, `class` and `style` are refused, as the writing guide
forbids colors and styles; the one diagram that has them
(`02-microkernels.md`, line 132) is changed to say in its labels what
the red stroke said.

### Sizes before layout

Labels are set in IBM Plex Mono. The build reads the face's advance
width from the font file's `hmtx` table (the TTF of the same release as
the WOFF2 the pages serve; Ruby reads TTF tables with `unpack`) and
refuses a font whose `post` table does not mark it fixed-pitch. A
label's box is then its longest line's character count times the
advance at the label size, by its line count times the line height,
plus padding. No other measurement exists, so no tool's view of a font
can move a box. A mono face for labels matches the landing page, which
sets its layer sketch in the same face.

### Graph layout

`Erx::Book::Layout` writes each graph as DOT with no text in it: every
node is a fixed-size blank box (`shape=box`, `fixedsize=true`,
`label=""`, its width and height in inches from the sizes above), every
edge label is a small blank node of its own on the edge's path (so an
edge `A -- l --> B` is `A -> L -> B`), every group is a
`subgraph cluster_N` with a blank label area of its title's size, and
the graph's direction is `rankdir`. A group whose own `direction` is
perpendicular to the graph's puts its nodes on one rank (`rank=same`);
whether `dot` honours that inside a cluster is unverified, and the
renderer refuses such a group if it does not. `dot -Tjson0` returns
the positions: node centres, edge spline control points and cluster
bounding boxes (`pos` and `bb`; the exact field formats are unverified
until read from Graphviz's attribute documentation during
implementation). One `dot` process runs per diagram, under the
deadline runner.

Graphviz is run, not linked, and nothing of it ships: the pages hold
only numbers it computed.

### Sequence layout

Sequence diagrams need no layout tool, so Ruby lays them out: a column
per participant; the gap between two neighbouring columns is the
widest label of a message between them, or of a note over both, plus
padding (a message spanning several columns spreads its width over
their gaps); one row per message, note or frame line, of its label's
height; a self-message takes a row and a small loop to the right of its
column. `alt` frames are rectangles over their rows and the columns
their messages touch, with the condition in a tab and `else` as a
dashed divider.

### Drawing

`Erx::Book::Svg` draws both models the same way: inline `<svg>` with a
`viewBox`, `role="img"` and `aria-labelledby` naming the figure's
caption. Boxes are rounded rectangles (decisions diamonds, cylinders
cylinders, start and end of state diagrams a dot and a ringed dot);
edges are the spline `dot` returned, drawn as a path with an
arrowhead; edge labels sit on their line on a paper-colored ground;
groups are hairline rounded rectangles with their title at the top
left; lifelines are hairlines; replies are dashed. Every element
carries a class (`node`, `decision`, `edge`, `edge-dotted`, `label`,
`group`, `participant`, `lifeline`, `note`, `frame`) and no color, so
`book.css` colors the drawing from the site's tokens, and the dark
theme recolors it with no second drawing. Text in the drawing is real
text: it can be selected and found with the browser's find.

### Text diagrams

The `text` blocks stay preformatted text, set in the mono face on the
code ground, inside a figure when a caption follows. Most are listings,
which must stay text; the two box drawings read well in a mono face,
and converting them would change two figures for little gain. A writer
who wants a better drawing writes Mermaid.

## Charts

The book has no data that wants a chart, so the step builds nothing for
charts. A chapter that later shows measurements gets a design for it
then.

## Typography and look

The book shares the landing page's identity, its warm paper, ink and
signal-orange palette and its faces, and sets it for long reading.

| Role | Face | Why |
| --- | --- | --- |
| text | Source Serif 4, roman and italic | a serif made for long text on screens, with optical sizes; OFL-1.1 |
| headings, navigation, captions | Archivo, the site's sans | the landing page's face, so the book reads as the same site |
| code, diagrams, paths | IBM Plex Mono | the landing page's mono; fixed width is what makes diagram boxes exact |

* **Fonts are self-hosted**, from upstream release files fetched by the
  fetch step at a pinned version and SHA-256 (`deps.lock`, `file`
  entries), served as WOFF2 under digest names with `font-display:
  swap`, each beside its OFL-1.1 text, as the license asks. The pages
  then send no request to any other host. The files are served whole;
  subsetting needs another tool (HarfBuzz's `hb-subset`, a subprocess,
  license not checked in this task) and is added only if the fonts'
  size is reported as a problem. The landing page loads the same
  faces from Google Fonts at run time; moving it to the same
  self-hosted files is an open question below.
* **Measure and rhythm**: text at about 19 px on wide screens and 17 px
  on narrow ones, line height about 1.6, a measure of about 68
  characters; figures and wide tables may extend past the measure up to
  the content column's width. Hyphenation by the browser (`hyphens:
  auto`, `lang="en"`). Headings in Archivo's wide cut, with the section
  number hung in the left margin in the signal color on wide screens.
* **Color**: the site's tokens (`--paper`, `--ink`, `--muted`,
  `--hair`, `--signal`, `--code-bg`, ...) for text, rules, links and
  code; dark mode from `prefers-color-scheme`, as the landing page
  does, with no toggle (a toggle would need a script). The tokens move
  from `site/style.css` into `site/tokens.css`, which both stylesheets
  link, so the palette has one source.
* **Status and background boxes**: the status box as a panel under the
  chapter title, with "Built" and "Designed" set as small labels; the
  background boxes as asides with a hairline rule and a quieter face
  size, so a reader who knows the topic can skip them.
* **Code**: preformatted, mono at about 0.85 of the text size, on the
  code ground, never wrapped, scrolling sideways when wide. See "Code".
* **Diagrams**: hairline strokes in ink, boxes on the panel color,
  groups on paper with a hairline, labels in mono; no color carries
  meaning, as the writing guide asks.
* **Print**: `@media print` drops the navigation, sets text in the
  serif on white, keeps figures and tables whole across pages, and
  starts each chapter on a new page.

The look is the site's own. Its acceptance is a review of rendered
pages, in light and dark, on a wide and a narrow screen.

### Code

Highlighting is kept to comments and string literals, in two muted
tones, which is the help a short excerpt needs; keywords and operators
stay in the text color, as a printed book sets code. A tokenizer in
Ruby of about 80 lines (estimate) knows the comment and string syntax
of the four languages the book tags: C (`/* */`, `//`, `"..."`,
`'.'`), Erlang (`%`, `"..."`, `$c`), shell and Ruby (`#`, `'...'`,
`"..."`). Rouge would highlight more, but it would be the tree's first
in-process gem, with a lexer library of which the book uses four
lexers.

### Navigation, glossary and search

* **Contents rail**: on wide screens a left column lists the parts and
  chapters, the current chapter opened to its sections (its `##`
  headings). On narrow screens the same list sits in a `<details>`
  element at the top of the page. No script.
* **Previous and next** links at the foot of each page, in contents
  order.
* **The glossary** renders as the list it is, set with hanging terms;
  its links into the chapters resolve as any link does.
* **Search** is not built. A reader finds within a page with the
  browser, and the contents, the section lists and the glossary lead to
  the page. A site-wide search needs an index and a script; if readers
  ask for it, it gets a design then.

## Where it fits

`Erx::Book` (`tools/lib/erx/book.rb`, with `book/page.rb`,
`book/links.rb`, `book/mermaid.rb`, `book/layout.rb`, `book/svg.rb`,
`book/code.rb`) is a functional core around two effects. The core:
the resolver, the slug function, the contents derivation, the page
renderer, the Mermaid parser, the sequence layout, the DOT writer and
reader, the drawing and the tokenizer, each a pure function of its
input. The effects: running cmark-gfm and `dot`, reading the tree's
files and the font files, and writing the output.

* **`ruby tools/build_book.rb [--out DIR] [--serve PORT] [--drafts]`**
  builds `build/book/` (by default) alone, in a few seconds, for a
  writer's preview, and serves it with `Erx::Site.serve`. It needs no
  v64, image or card.
* **`tools/build_site.rb`** builds the book into its staging
  directory's `book/` from `Erx::Site.publish`, so the book and the
  landing page are published together or not at all; the site build
  gains no option. The landing page gets a link to `book/`.
* `Erx::Site.serve`'s content types gain `.woff2` and `.txt`.
* The publishing workflow (`.github/workflows/site.yml`) fetches and
  builds the two tools and the fonts as the site build does v64.
* The writing guide's checklist item 13 names `ruby
  tools/build_book.rb` as the check, and the scratch link script
  retires.

**Tools enter as other host tools do**: `deps.lock` pins the source
archives of cmark-gfm and Graphviz by URL and SHA-256; the fetch step
fetches them; the book step builds each out of tree, cmark-gfm with
CMake and Graphviz with only what `dot -Tjson0` needs (no Cairo, Pango
or GD; which build options and host tools, such as Bison and Flex,
that takes is unverified), into `build/book-tools/`, under deadlines
with logs in `build/logs/`, and reuses an earlier build of the same
archive. The pages then depend on exact tool versions, so two hosts
build the same bytes. Taking both tools from the `PATH` instead is an
open question below.

**Dependencies.** The implementation adds rows to the dependency table
of [design.md](design.md#dependencies): cmark-gfm (BSD-2-Clause, a
website build tool), Graphviz (EPL-2.0, a website build tool, run
unmodified out of tree, nothing of it ships), and the three faces
(OFL-1.1, font data, shipped on the website).

## Trust and escaping

The book is erXos's own text, written and reviewed in the tree. It is
not untrusted input in CLAUDE.md's sense (it does not come from a
domain, a device, the network or an upload), so its readers need no
fuzz targets, and the step guards against mistakes, not attacks.
Escaping is still total, because it is what makes pages correct: the
book shows pids such as `<4.0.0>`, comparisons and `&&` in code, and
these must reach the reader as text. The renderer escapes every text
node and attribute; SVG text is escaped the same way; link addresses
are only what the resolver returns, so no `javascript:` address can
appear; raw HTML is refused rather than passed through. cmark-gfm runs
without `--unsafe`, so even its own output could not carry raw HTML.

## Refusals

The step fails at its first error, through one `Erx::Error` caught at
the command's entry, and the output directory stays as it was (the
build writes a fresh sibling and renames it, as `Erx::Site.publish`
does). Each refusal names the file and, where it has one, the line
that cmark-gfm's `--sourcepos` gives:

| Refusal | Says |
| --- | --- |
| a tool missing or not built | which tool, and the fetch command that provides it |
| a tool failing or exceeding its deadline | the tool, the input file and the log's path |
| a draft marker, `<!-- unverified` or `<!-- check:`, without `--drafts` | the file, the line and the marker; with `--drafts` the marker shows on the page as a highlighted note instead, and such a build is never published, since the site build has no `--drafts` |
| raw HTML other than a comment | the file, the line and the tag |
| a link or image that does not resolve | the file, the line, the target, and whether the file or the anchor is missing |
| a chapter or appendix file the contents do not name | the file |
| a Mermaid construct outside the subset, or an unknown diagram kind | the file, the line in the file and the construct, quoted with escaping |
| a font file that is not fixed-pitch where the diagrams need it | the file |

The 10 `<!-- check: ... -->` markers in the tree are drafts by this
rule, so publishing waits until they are settled; whether a `check:`
marker should block publishing as `<!-- unverified` does is an open
question below.

## Determinism

The pages depend only on the files of `docs/book/`, the Markdown files
the links name, the images, the font files, the commit, and the
versions of cmark-gfm and Graphviz. The step reads no clock, writes no
date, numbers diagrams by their place in the book, walks directories in
sorted order, and writes JSON and CSS in a fixed order. That `dot`
gives the same output for the same input and version is assumed and
checked by the determinism test below; a failure there is fixed by
fixing the input the step gives `dot`, never by patching its output.

## Tests

Host tests in `test/host/book_test.rb`. The tests of the pure core
need no tool and run in `make check`; the tests that run cmark-gfm or
`dot` run with the site tests (`ruby test/host/site_test.rb`'s
neighbours), on demand and in the publishing workflow before it
builds, and say plainly that they are skipped when a tool is not
built. Each test names the fault that must make it fail, planted once
by hand when the test is written.

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| Slugs | the slug function gives GitHub's ids for a dozen headings taken from the book: section numbers with dots, backticks, colons, commas, apostrophes, a repeated heading | keep the dots (`2.5-the-l4...`); number repeats from 2 instead of 1 |
| The whole book builds | `tools/build_book.rb` builds every page of the tree with no refusal (tool test) | point the resolver's book directory one level up, so book links stop resolving |
| Links resolve and refuse | a fixture page's links become the expected addresses: a book page with anchor, a design document at `REPOSITORY/blob/COMMIT/docs/...#anchor`, a directory at `tree/`, an `https` link unchanged; a missing anchor in a design document, a missing file and a path outside the repository are each refused with file and line | resolve repository paths from `docs/book/` instead of the repository root; skip the anchor check for files outside `docs/book/` |
| Contents | the contents fixture gives the parts in order, an entry for an unwritten chapter without a link, and previous and next that skip it; a chapter file the contents omit is refused | take a link's part from the following bold paragraph; drop the unreferenced-file check |
| Mermaid subset | each construct of the subset, from fixtures cut from the book, parses to the expected model; `classDef`, `activate` and `gantt` are refused with their line | let the parser skip lines it does not know |
| No text reaches `dot` | the DOT the layout writes for a fixture graph contains no character of any label, and every box has the size Ruby computed | pass the label to `dot` as the node's label |
| Graph layout reads `dot` correctly | in a `TB` fixture `A --> B`, A's box lies above B's; in `LR`, to its left; every edge's path starts on its source box and ends on its target box (tool test) | swap x and y when reading `pos`; forget that `dot`'s y axis points up |
| Sequence layout | no message label overlaps another or crosses a lifeline it does not end on; rows increase down the page; a self-message stays in its column's gap | compute a gap from the wrong neighbour's labels |
| Figures | a diagram, a text block and an image each followed by a `*Figure N.M. ...*` paragraph become `<figure>` with that caption and id `figure-N-M`; a figure without a caption stays a bare block | match the caption against the preceding paragraph |
| Escaping and ASCII | a fixture with `<4.0.0>`, `a && b` in code, `<script>` in a Mermaid label and a curly quote in prose renders them as text and numeric references; every output byte is ASCII; raw `<div>` in Markdown is refused | drop the escape in SVG text; write non-ASCII characters as they are |
| Drafts | a page with `<!-- check: x -->` is refused without `--drafts` and shows the note with it | let the comment rule drop comments before the draft check |
| Same bytes | building the book twice into two directories gives byte-identical trees (tool test) | write the build time into the page footer; iterate a `Dir.glob` unsorted |
| Code | a C, an Erlang, a shell and a Ruby fixture highlight their comments and strings, and a `%` inside an Erlang string is not a comment | end an Erlang string at the first `"` after a backslash |

The look itself, faces, spacing, light and dark, the narrow layout and
print, is accepted by review of rendered pages, not by a test.

## Open questions for the user

1. **Diagrams: our renderer of the book's Mermaid subset (with Graphviz
   for placement), or Mermaid itself at build time in the pinned
   headless Chromium?** The first draws in the site's own style and
   keeps JavaScript out of the build, for about 800 lines of Ruby; the
   second matches GitHub's drawing exactly for about 150, but runs
   third-party JavaScript in host tooling, which the language rules do
   not name. Recommendation: our renderer.
2. **Graphviz (EPL-2.0) as a site build tool**, run unmodified out of
   tree as QEMU is, with nothing of it shipped? Recommendation: yes.
3. **cmark-gfm and Graphviz: pinned in `deps.lock` and built by the
   step, or taken from the `PATH` with a minimum version?** Pinned gives
   the same bytes on every host and in the workflow, at the cost of two
   builds (Graphviz's needs CMake and probably Bison and Flex);
   `PATH` is simpler but lets pages change with a host's versions.
   Recommendation: pinned.
4. **Do `<!-- check: ... -->` markers block publishing**, as
   `<!-- unverified` does? Recommendation: yes; ten markers in four
   chapters must be settled before the first publication.
5. **Faces: Source Serif 4 for the text**, with the site's Archivo and
   IBM Plex Mono, or the landing page's Archivo for the text too?
   Recommendation: Source Serif 4.
6. **Move the landing page from Google Fonts to the same self-hosted
   files**, so the site sends no request to another host and the faces
   have one source? Recommendation: yes, in the same change.
7. **Publish the design documents on the site too**, so the 735 links
   to them stay on the site? Recommendation: no, link to the repository
   at the build's commit; revisit when readers ask.
