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
| Outward links | 32, all `https:`, to 23 hosts (papers, manuals, standards, `github.com`); no `http:` or `mailto:` (counted at `f5fdfeaf2`) |
| Images | 1: `22-display.md` shows `../../site/kiosk.png` |
| Raw HTML | none but HTML comments |
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

The Mermaid the chapters use is ordinary Mermaid: flowcharts with
rectangles, decisions and cylinders, labelled and dotted edges,
invisible links (`~~~`, `02-microkernels.md:117`), a labelled dotted
link without an arrow (`-.linked.-`, `17-network.md:344`), nested
subgraphs (`03-erlang.md`, `02-microkernels.md`, whose inner groups
set `direction TB` inside a `TB` graph), and one `classDef` with a
`class` line (`02-microkernels.md:132`, a red stroke on two nodes);
sequence diagrams with participants, messages, self-messages, notes
and `alt` frames; state diagrams with `[*]`, labelled transitions and
state descriptions. Most flowcharts have 4 to 11 nodes; two have 13
and 14. The writing guide caps a figure at about 12 nodes, forbids
colors and styles ("color must not carry meaning") and picks Mermaid
because GitHub renders it (`docs/book/style.md`, "Figures and
tables"). The `classDef` diagram breaks that rule; it is changed to
say in its labels what the red stroke says, as a book edit.

The book has no data for charts: its tables compare properties and
mechanisms, list states and statuses, and give limits; none is a
series of measurements.

### What the site does today

[site/README.md](../site/README.md) is the site's contract. The pages
`site/index.html` and `site/release-notes.html`, their stylesheet
`site/style.css` (color tokens on `:root`, redefined under
`prefers-color-scheme: dark`) and the console script `terminal.js`
are assembled by `tools/build_site.rb` and `Erx::Site`
(`tools/lib/erx/site.rb`) into `build/site/`:

* `Erx::Site.inventory` lists `PAGE_FILES` and refuses a page that
  holds `<!-- unverified` (`UNVERIFIED`): the site publishes no draft.
* `Erx::Site.publish` (`site.rb:264`) builds into a fresh sibling
  directory, then deletes the old output and renames the new one into
  place, and replaces only a directory holding its `.erx-site` marker.
  A refusal leaves the old output as it was; an interruption between
  the delete and the rename leaves no output directory.
* Script and image files are published under digest names
  (`Erx::Site.digest_name`), so a deployment never pairs one
  deployment's page with another's files.
* `render_index` fills `{{name}}` placeholders, escaping every value.
* `Erx::Site::REPOSITORY` (`https://github.com/stass/erXos`) with
  `Source#url` makes the page's link to the source at a commit.
* `--serve PORT` serves the result on `127.0.0.1`. Its route table
  (`Erx::Site.routes`, `site.rb:335`) maps each file to its path and
  adds `/` for `index.html`; no other directory answers. `--no-card`
  builds a preview without the board's card.
* The fonts, Archivo and IBM Plex Mono, load at run time from Google
  Fonts, in both `index.html` (lines 10 to 12) and `release-notes.html`
  (lines 9 to 11).
* The site build builds v64 (`Erx::SiteV64.build`,
  `site_v64.rb:67`), and that build runs `npm ci` against the npm
  registry (`site_v64.rb:76`): the site build reaches the network
  outside the fetch step.

A full site build needs v64's build tools, an erXos image and a card.
Nothing renders Markdown. `~/erxos-scratch/tools/book_links2.rb`, a
scratch script outside the tree, checks the book's relative links and
heading anchors with its own approximation of GitHub's slug.

The web client already installs npm packages the way the tree's rules
ask ([design-web.md](design-web.md#build-and-dependencies),
`Erx::WebBuild`, `tools/lib/erx/web_build.rb`): `web/package.json`,
`web/pnpm-lock.yaml` and `web/pnpm-workspace.yaml` pin every package
with its integrity hash; `tools/erx fetch` runs `pnpm install
--frozen-lockfile --ignore-scripts` into `build/web-modules/` and
records the SHA-256 of the package files it installed for; `engines`
names the oldest Node.js and pnpm; every later step runs offline.

### What the tools are

Licenses of cmark-gfm and the fonts were read on 2026-11-20 from each
project's official source over HTTPS; the files are in
`~/erxos-scratch/sources/book-site-2026-11-20/`, listed with their
URLs and SHA-256 digests in its `RECORD.txt`. The npm packages were
installed with pnpm for a bake-off of Mermaid renderers on the same
day (`~/erxos-scratch/bakeoff/RECORD.md`); their licenses are as each
package's `package.json` declares, and their license files were not
compared.

| Tool | What it does | License | Version |
| --- | --- | --- | --- |
| cmark-gfm | GitHub's CommonMark parser with GFM extensions, a C program; `-t xml` writes the parse tree, `--sourcepos` adds line numbers, `--smart` makes curly quotes, `-e NAME` turns on an extension (`man/man1/cmark-gfm.1`) | BSD-2-Clause, with MIT-licensed parts listed in the same file (`COPYING`, `c22e885f...`) | 0.29.0.gfm.14, the latest GitHub release |
| beautiful-mermaid | renders Mermaid text to SVG in TypeScript with no browser and no DOM; `renderMermaidSVG(text, options)` returns an SVG string; options set colors (as any CSS value, `var(--name)` included), the font family, spacing and a transparent background (`dist/index.d.ts`, `RenderOptions`) | MIT | 1.1.3, imported into the tree (see "The import") |
| esbuild | bundles the imported TypeScript source of beautiful-mermaid, with elkjs and entities, into one JavaScript module | MIT | 0.28.2, the version `web/package.json` pins |
| elkjs | the layered graph layout beautiful-mermaid calls | EPL-2.0 | 0.11.1, as beautiful-mermaid 1.1.3's lockfile resolves it |
| entities | HTML entity encoding, used by beautiful-mermaid | BSD-2-Clause | 7.0.1, likewise |
| mermaid | the official Mermaid library, whose parser needs a DOM under Node and is therefore not used (see "The parse check") | MIT | not pinned |
| Node.js | runs the two libraries, as a subprocess of the Ruby build | MIT (unverified in this task) | any at least the `engines` minimum; the publishing workflow pins one |
| Source Serif 4 | a text serif | OFL-1.1 (`LICENSE.md`, `75784a29...`) | tag `4.005R` |
| IBM Plex Mono | the site's mono face, and the one face of every diagram | OFL-1.1 (`license.txt`, `91c25c35...`) | tag `v6.4.2` |
| Archivo | the site's sans | OFL-1.1 (`OFL.txt`, `108b4e57...`) | `google/fonts` commit `95f4904fc8bc` |

Rejected in the bake-off, with the six diagrams it drew from the book
(`~/erxos-scratch/bakeoff/index.html`): official Mermaid through
`@mermaid-js/mermaid-cli`, which needs a headless Chrome (Chrome for
Testing, whose terms were not reviewed) and dropped the page's
`@font-face` until worked around; mmdflux 2.6.1, which mis-parsed an
unbracketed subgraph title into stray nodes without a warning; and
mermaid-rs-renderer 0.3.1, which laid the dense diagram out in one
row about 4,700 px wide. Ruby's REXML, which both `cmark-gfm -t xml`'s
output and the SVG need, is already used by the tree
(`tools/lib/erx/hardware.rb`). No Ruby gem is a dependency of the tree.

## Requirements

Each requirement names who needs it.

1. **Every chapter and appendix in `docs/book/` is a page of the site**,
   reached from a contents page, with the site's look. The reader.
2. **Rendering happens at build time; the pages carry no script.** The
   request asks for it, and a reader without JavaScript sees the whole
   book.
3. **Diagrams are drawn from the Mermaid the chapters hold**, so writers
   keep one source that GitHub also renders, and they look better than
   GitHub's rendering: drawn in the diagram style of "The diagram
   style", in the site's ink and paper, light and dark, crisp at any
   size. The request; the style is the one chosen from the bake-off.
4. **Every diagram also parses as official Mermaid**, so the drawing a
   reader of the repository host sees is never an error where the site
   shows a picture. The writer: the bake-off found a sequence label
   with `;` that beautiful-mermaid drew and official Mermaid 12.3.0
   rejected.
5. **Every link resolves**: within the book to a page and an anchor that
   exist, into the repository to the file at the commit the book was
   built from, and outward to a well-formed `https:` address. The
   reader; the writer's checklist (`docs/book/style.md`, "The writer's
   checklist", item 13) asks for it today and has only a scratch
   script to check it.
6. **The site publishes no draft.** The site's existing rule
   (`Erx::Site::UNVERIFIED`), from CLAUDE.md's "Never fabricate"; the
   `<!-- check: ... -->` markers block publishing too.
7. **The pages request nothing from another host.** Every font,
   stylesheet and image a page of the site loads is a file of the site.
   The reader's privacy: a page that loads a font from Google Fonts
   tells Google who reads it.
8. **The output is a function of its inputs**: the same tree, tool
   versions, package versions and font files give the same bytes, on
   one host and across the supported hosts, so a rebuild shows no
   change and a test can compare. Review of a published change.
9. **The step fits the site build** and also runs alone, quickly,
   without v64, an image or a card, and builds run offline. The writer,
   previewing a chapter; CLAUDE.md's "No implicit network access".

Not required, because no consumer needs it: charts (the book has no
measured data), search (see "Navigation, glossary and search"),
client-side theme switching, analytics, comments, or an e-book format.

## The construction

**One parse, one renderer, one resolver, and one writer for every
byte of a page.** cmark-gfm, run as a subprocess, parses each Markdown
file into its XML parse tree; nothing else parses Markdown. One Ruby
renderer walks that tree and writes every byte of HTML, so all markup
on a page comes from code in the tree and every piece of text is
escaped on the way out. Every target a page names, a link, an image or
a contents entry, goes through one resolver that knows the set of
pages and their heading anchors. Diagrams are drawn by beautiful-mermaid
in one Node process per build, and its SVG comes back as data: Ruby
parses it as XML and writes it into the page through the same writer,
keeping only the elements and attributes it knows, replacing the
library's style text with its own, restyling the tree into the diagram
style, renaming every id into the diagram's own name space and refusing
any reference that leaves the drawing. The look of a diagram is
therefore decided in two places only, both ours: the layout's text
metrics in the imported library, and the restyle in Ruby.

The requirements follow:

* GitHub parity of the Markdown (1) comes from parsing with GitHub's own
  parser; the site's look comes from the renderer, which is ours.
* No script (2): the renderer's output is complete HTML and inline SVG.
* Diagrams from the Mermaid source (3): the source stays as it is; the
  style text the writer puts in every drawing resolves each of the
  library's colors to `var(--ink)` or `var(--paper)`, so one drawing
  follows the page into dark mode, and its text is set in IBM Plex Mono
  by family name, from the page's own fonts.
* Official parse (4): the same Node process runs official Mermaid's
  parser over each diagram before drawing it.
* Links (5) resolve or fail the build, because the resolver is the only
  way a target reaches a page. The book build becomes the link check.
* No draft (6): the renderer meets every HTML comment, so it sees every
  marker.
* Nothing from another host (7): the renderer writes no reference to
  another host but an `<a href>`; the SVG writer replaces the library's
  style text, font `@import` included, and refuses any other address
  outside the drawing; and the hand-written
  pages move to the self-hosted fonts.
* Same bytes (8): the inputs are files, one pinned C tool and pinned
  packages; the step reads no clock and iterates in sorted order; the
  build record names every version.
* Fits the site (9): the step is a module the site build calls, with a
  small command of its own for previews; the network is reached only by
  `tools/erx fetch`.

## Pages and addresses

The book is the `book/` directory of the site; the fonts and the
color tokens are shared with the landing page at the site's root:

| Address | Source |
| --- | --- |
| `book/index.html` | the contents page, built from the outline's "Contents" section |
| `book/NN-name.html` | `docs/book/NN-name.md`, one page per chapter or appendix file |
| `book/outline.html` | `docs/book/README.md`, the outline |
| `book/style.html` | `docs/book/style.md`, the writing guide |
| `book/book-<digest>.css` | the book's stylesheet |
| `book/media/<digest>-<name>` | each image a page shows |
| `book/record.json` | the build record (see "Determinism") |
| `fonts-<digest>.css`, `tokens-<digest>.css` | the `@font-face` rules and the color tokens, linked by every page of the site |
| `fonts/<face>-<digest>.<ext>`, `fonts/OFL-<face>.txt` | the font files and their licenses |

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
quotes the writing guide asks for; code is not affected. The XML
renderer keeps raw HTML as `html_block` and `html_inline` nodes whatever
the flags (`src/xml.c` at `0.29.0.gfm.14`, read for the design's
external review), so `--unsafe` changes nothing here and is not given;
the refusal of raw HTML is the renderer's (below).

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
* **Fenced code** by language: `mermaid` goes to the diagram step;
  `c`, `erlang`, `ruby` and `sh` get highlighting (see "Code"); every
  other language, `text` included, and an untagged block render as
  preformatted text in the mono face.
* **A figure**: a diagram, a preformatted block, an image or a table
  followed directly by a paragraph that is all emphasis and begins
  `Figure N.M.` becomes `<figure>` with that paragraph as its
  `<figcaption>`, and the id `figure-N-M`. The writing guide's caption
  rule becomes the page's structure without new markup.
* **HTML** nodes, block and inline: a comment is dropped, after the
  draft check (see "Refusals"); any other HTML is refused, with its
  line. The book uses none, and allowing it would let a page differ
  from what GitHub shows. This is the one place raw HTML is stopped.
* **Every character above 0x7f** is written as a numeric character
  reference, so the generated pages are ASCII, as CLAUDE.md requires of
  generated output, whatever the prose holds.

Markup comes only from the renderer's builders, which return a value of
one type for markup; a plain `String` placed in a page is always
escaped, in text and in attributes alike. A template placeholder takes
either, and escapes a `String`.

### Heading ids

One slug function gives every heading its id, following GitHub's rule
as the tree's document-link check forms it (`DocLinks.anchor`,
`tools/lib/erx/doc_links.rb`, after html-pipeline's `TableOfContentsFilter`): lower-case the text of the heading, drop every
character that is not a letter, a digit, a space, `-` or `_`, turn each
space into `-`, and add `-1`, `-2` and so on to repeated slugs in a
page. The same function gives the anchors of every Markdown file a link
names, design documents included, which it reads through cmark-gfm too.
The ids come from a parse without `--smart`, so a heading's `--` or
straight quote reaches the slug as GitHub sees it; the page itself is
rendered from the `--smart` parse, whose headings are the same nodes in
the same order.
Any disagreement with the links the writers wrote against GitHub shows
as a missing anchor, which fails the build.

## Links

The resolver takes a target as written and the file it is written in,
and returns an address of one of three kinds, or refuses. Every
address it returns is one it built from parts it checked; nothing a
writer typed reaches an attribute unparsed.

| Target | Becomes |
| --- | --- |
| a Markdown file in `docs/book/`, with or without an anchor | the page's relative address, with the anchor if the page has it |
| any other path inside the repository, file or directory | the repository host's address of that path at the commit the book is built from: `REPOSITORY/blob/COMMIT/PATH` for a file, `REPOSITORY/tree/COMMIT/PATH` for a directory, with the anchor; for a Markdown file the anchor must exist in it |
| an absolute `https:` URL | the same URL, rebuilt from its parts: it must parse (Ruby's `URI`) with the scheme `https`, a host, no user information and no character outside printable ASCII; the host is lower-cased and the address written back from scheme, host, port, path, query and fragment |
| anything else: a path that does not exist, a path outside the repository, a missing anchor, `http:`, `mailto:`, `javascript:`, any other scheme, a scheme-relative `//host` | a refusal naming the file, the line and the target |

The rule for outward links is a closed set of one scheme. The book's
outward links are citations, every one `https:` today, to papers,
manuals and standards on 23 hosts; a host list would refuse the next
citation for no gain, since the book is reviewed text.

The repository's address is `Erx::Site::REPOSITORY`, the constant the
landing page's source link already uses, so the site has one place
that names the host. A link into the repository points at a commit
rather than a branch, so a reader of a published book reads the design
document as it was when the book was built. The commit is the full
hash of the tree's `HEAD`; the publishing build runs on a tree without
changes, so that commit holds exactly what the pages cite. The design
documents are not published as pages: they are the contracts, large
and edited daily, and the repository host renders them already.

"Inside the repository" means a path git tracks in the tree being
built, or a directory above one, so a link to a build product that
exists only on the writer's host is refused. A fragment into a file that
is not Markdown must name lines (`#L10`, `#L10-L20`), the only
fragments the repository host gives such a file.

Images go through the same resolver: an image path must be a file in
the repository, of type PNG, JPEG or SVG, and is copied to
`book/media/` under a digest name.

## Figures and diagrams

### Options

| Option | Look | Writers | Determinism | Cost |
| --- | --- | --- | --- | --- |
| (a) Mermaid's script in the reader's browser | Mermaid's own | unchanged | the browser's | a large script on every page; a reader without JavaScript sees source; not rendered at build time, which the request asks for |
| (b) official Mermaid at build time in a headless browser (`@mermaid-js/mermaid-cli` with Chrome for Testing) | Mermaid's own; one drawing per theme | unchanged | text measured by the browser's font stack | a browser in the build, under terms not reviewed; its themes drop the page's `@font-face` |
| (c) rewrite the 56 diagrams in Graphviz, Pikchr or D2 | good to very good | they lose GitHub's preview, and learn a new language | per tool version | rewriting every figure |
| (d) our own Ruby renderer of the book's Mermaid subset, with Graphviz for placement | ours | unchanged, within the subset | exact, per Graphviz version | about 800 lines of Ruby (estimate) and their geometry: nested groups, edge labels, shape clipping and sequence spacing are each ours to get right |
| (e) **beautiful-mermaid under Node, as a subprocess** | the cleanest flowcharts and the most readable dense diagram of the bake-off; colors as CSS custom properties, so one drawing serves light and dark | unchanged | text widths from a table in the library, not from a font, so independent of the host's fonts | Node and three packages as build tools; a driver of about 50 lines of JavaScript |

**Decision: (e).** It keeps one source that GitHub renders, draws in
the site's palette and faces in both themes from one render, needs no
browser, and leaves layout to a maintained library instead of 800 lines
of our own geometry. Its own look is not used: the bake-off restyled
its output into the diagram style below, and that style is the one
chosen (`~/erxos-scratch/bakeoff/RECORD.md`, "Manual style", with
`render/manual.rb` and the screenshots in `scratch/manual/final/`).
The restyle also removes two of the library's faults seen there: a
long cluster title clipped in the dense flowchart
(`02-microkernels.md`'s first diagram), because a group is laid out at
least as wide as its title; and edge labels drawn small in the
secondary text color, because every label is 12 px ink. The state
diagram's start dot far from its target remains, as the library lays
it out. A figure whose drawing a review of rendered pages finds
unreadable is fixed in its source (a shorter title), and a layout
fault worth fixing is fixed in the imported library (see "The import").

### The diagram style

This is the contract every drawing on the site meets. It is the look
of a figure in a printed technical manual: one face, ink only, thin
square lines, and a dithered shadow that sets the outer groups off the
page.

| Property | Rule |
| --- | --- |
| Face | IBM Plex Mono, regular, 12 px, for every label: nodes, edges, group titles, actors, messages, notes, states |
| Color | ink and paper only: every stroke, arrowhead, text and dot is `var(--ink)`; every fill that is not ink, and every mask, is `var(--paper)`; no other color, no tint, no fill on a box. Light is `--ink` on `--paper` of `site/tokens.css`, dark the same tokens' dark values, from one drawing |
| Lines | 1 px; square corners (no `rx`); dashed lines in long dashes, `stroke-dasharray: 10 6`; arrowheads solid ink, without an outline |
| Groups | no header bar; the title at the lower left, inside the box, in a row the layout reserves at the bottom; a group at least as wide as its title |
| Labels | edge labels plain text on a paper mask without a border; sequence message labels on a paper mask drawn above the lifelines they cross; notes plain rectangles, without the folded corner |
| Shadow | behind each outer group only (a group inside no other group): an L-shaped band 3 px off the box, 12 px wide on the right and 15 px deep below, set in from the box's top by 16 px and its left by 14 px, filled with a 2x2 pattern of two ink dots on the diagonal, which is a 50 percent dither; the drawing's canvas grows to hold it |
| Crossings | a line that crosses a shadow (an edge, a lifeline, a message) has a 6 px paper-colored underlay clipped to the shadows, so the dots stop short of the line on both sides |

The text of the site keeps its own faces: Source Serif 4 for prose,
Archivo for headings, navigation and captions, IBM Plex Mono for code
(see "Typography and look"). A diagram's face is the code face, so the
style adds no font file.

What the style cannot do, accepted as limits of drawing from a layout
engine rather than by hand:

* **No character grid.** ELK places boxes at fractional positions, so
  boxes, dash phases and shadow dots do not line up on character cells
  as a hand-drawn manual figure would.
* **No shadows in sequence and state diagrams.** Their layout leaves no
  room under an actor or a state, and they have no groups.
* **Routes are ELK's.** Edges are its orthogonal routes, with jogs a
  hand-drawn figure would not have, and it may order sibling groups
  differently from the source (the dense flowchart puts "Microkernel"
  first).
* **The dither greys at page scale.** On a screen whose pixels do not
  fall on the pattern's cells, the dots read as a grey band; the SVG
  opened at 1:1 shows them.
* **A character the face lacks** is drawn by the browser's fallback
  face, wider or narrower than the layout measured; the review of
  rendered pages judges such a label.

### The import

The layout must know the style's text widths, because a box is sized
before anything is drawn: the library measures a label from a table of
proportional character widths (`getCharWidth` and `measureTextWidth`,
`src/text-metrics.ts` lines 126 and 175 in 1.1.3), sets node labels at
13 px and edge labels at 11 px (`src/styles.ts` lines 37 and 39), and
reserves a group's title row at the top
(`'elk.padding': '[top=44,left=16,bottom=16,right=16]'`,
`src/layout-engine.ts` line 349). No option changes these. The change
is made in the library's source, never by substituting text in its
built `dist/index.js` at build time, which breaks silently when the
built file changes.

beautiful-mermaid enters the tree as erXos's code, as CLAUDE.md's
"Code erXos modifies or ships enters the tree as erXos's code"
provides: the `src/` directory of the npm package
`beautiful-mermaid@1.1.3`
(`https://registry.npmjs.org/beautiful-mermaid/-/beautiful-mermaid-1.1.3.tgz`,
from `https://github.com/lukilabs/beautiful-mermaid`) lives at
`tools/book/beautiful-mermaid/`, with the package's `LICENSE` (MIT)
and an `ORIGIN.md` beside it. The `ORIGIN.md` is the import record of
[design-build.md](design-build.md)'s import check, written by the same
import code as every other import's: it names the repository, the
version, the SHA-256 of the tarball imported and the inventory of the
files kept, and `Erx::Checks::IMPORTS` lists the directory, so `make
check` refuses a file that arrives without a record and a changed file
without its change notice. The library's own `package.json`, its build
(`tsup`) and its built `dist/` are not imported; its dependencies are
pinned by the book's own package files below.

The package's `src/` is 1.3 MB: about 16,800 lines of TypeScript
without its tests, and 7,500 more of tests, which run under Bun. The
book uses three of its renderers, and the import keeps only those:

| Kept | Lines | Left out | Lines |
| --- | --- | --- | --- |
| the flowchart parser, layout and renderer, which also draw state diagrams (`parser.ts` reads the `stateDiagram-v2` header), the sequence renderer (`sequence/`), and the shared text metrics, styles, theme and ELK instance | 5,284 | the ASCII renderer (`ascii/`) | 8,205 |
| | | the class, ER and XY-chart renderers (`class/`, `er/`, `xychart/`) | 3,266 |
| | | the browser entry (`browser.ts`) and the tests (`__tests__/`, Bun) | 24; 7,482 |

Only `index.ts` and `browser.ts` import from the left-out directories
(counted in the 1.1.3 package), so leaving them out is one edit of
`index.ts`, which drops their exports and their arms of the dispatch
on the diagram's header and refuses those headers with an error the
driver reports at the render stage of "The diagram step". The left-out paths are the import
record's exclusions, so the inventory lists only what is in the tree
and the tarball's digest still names the whole package. A renderer the
book later needs is imported from the same tarball by the same code.

erXos's changes are ordinary commits to those files, each changed file
carrying its change notice. They add three render options and leave the
library's default output unchanged when the options are absent:

| Option | Effect | The style sets |
| --- | --- | --- |
| `charWidth` | every label is measured as its number of characters times the font size times this advance, in ems, plus 0.15 of the font size; absent, the width table is used | `0.6`, IBM Plex Mono's advance (600 of 1,000 units for every glyph, read from the font's `hmtx` table) |
| `labelSize` | node and edge labels at this size in px | `12` |
| `groupTitle` | `"bottom"` reserves the title row below a group's contents (24 px above them, 40 px below) and `"top"` above them, as the library does; with either value set, a group is laid out at least as wide as its title plus 24 px, and without the option it is as wide as its contents, as upstream lays it out, so a long title may be clipped | `"bottom"` |

The library imports two packages, `elkjs` (`elk-instance.ts` loads
`elkjs/lib/elk.bundled.js`) and `entities`. Both stay out of the tree,
unmodified, pinned by `tools/book/pnpm-lock.yaml` at the versions
beautiful-mermaid 1.1.3's own lockfile resolves (elkjs 0.11.1,
entities 7.0.1) and installed with the book's other packages. The step
runs the pinned esbuild, by argument vector under a deadline, to bundle
the driver of "The diagram step", `tools/book/diagrams.ts`, with the
library and those two packages into one ES module,
`build/book-tools/diagrams.mjs`, resolving the two bare imports from
`build/book-modules/node_modules` through esbuild's node-paths setting,
which its command line reads from `NODE_PATH` (probed with esbuild
0.28.2: without it, `entities` does not resolve). It reuses an earlier
bundle only when the record beside it names the same sources (the
SHA-256 of the import's files in sorted path order, the driver and the
package files) and the same versions of elkjs, entities and esbuild.

### The diagram step

`Erx::Book::Diagrams` collects every `mermaid` block of the book, in
page order and then in source order, and hands them all to one Node
process, `tools/book/diagrams.ts`, a short TypeScript driver that esbuild bundles with the library, run by `Erx::Runner` with an
argument vector and a deadline:

```
node --permission --allow-fs-read=<bundle> <bundle>
```

The bundle is the driver with the library, elkjs and entities in one
module, so Node's permission model (`--permission`) lets the process
read only that file, and refuses file writes, network access, child
processes, worker threads and native add-ons (the "Permission Model"
section of Node 26.13.0's `doc/api/permissions.md`, SHA-256 `32b6ad04...`).
Network access is refused under the model only from Node 25.0.0, which
added `--allow-net` (`doc/api/cli.md`, `c32c9c59...`), so
`tools/book/package.json`'s `engines` names Node 25.0.0. Node gets
none of the caller's environment but `PATH`, with `LANG=C` and
`TZ=UTC`, so no `NODE_*` variable can widen the grant and the bundled
code reads no token or setting the caller holds. Neither library makes a
request: beautiful-mermaid 1.1.3's built `dist/index.js` holds no
`fetch`, `XMLHttpRequest` or `http` import, and erXos's changes add
none.

The request goes to the driver's standard input as one JSON document
and the reply comes back on its standard output as another:

* request: `{"options": {...}, "diagrams": ["<source>", ...]}`;
* reply: `{"versions": {"node": "..."}, "results": [...]}`, one result per diagram in the
  same order, either `{"svg": "..."}` or `{"error": {"stage": "parse"
  | "render", "message": "...", "line": N | null}}`.

The driver reads Node's version from the process; the step reads the
versions of elkjs, entities and esbuild from the `package.json` files
esbuild resolved, and the build record names the imported library by
the digest of its files, so the record names what ran. It reports a diagram's
failure as a result and goes on, and exits non-zero only for its own
failure (a missing package, a malformed request); Ruby turns the first
failed result, in book order, into the step's refusal. One process for
the whole book keeps the cost of starting Node to once per build.

The options are one frozen Ruby constant, the same for every diagram:

| Option | Value |
| --- | --- |
| `charWidth`, `labelSize`, `groupTitle` | `0.6`, `12`, `"bottom"` (the options erXos adds, "The import") |
| `font` | `IBM Plex Mono` |
| `transparent` | `true` |

No color is passed: the writer replaces the library's style text with
its own, which resolves every color the drawing names to `var(--ink)`
or `var(--paper)` ("From SVG to page"), and the page's tokens, light or
dark, color the drawing; the step refuses a token its style text names
that `site/tokens.css` does not declare, since an undefined token would
draw ink on ink. The font reaches the drawing only as a family name in
that style text; the page's `@font-face` for IBM Plex Mono supplies the
face, and no font file reaches Node. Every label is measured from the
face's fixed advance, so layout depends on no font file and no host,
and a label fills its box as the layout measured it.

The packages enter as the web client's do. `tools/book/package.json`,
`tools/book/pnpm-lock.yaml` and `tools/book/pnpm-workspace.yaml` pin
elkjs 0.11.1, entities 7.0.1 and esbuild 0.28.2 with
every package of their closure and its integrity hash, and allow no
build script;
`package.json`'s `engines` names the oldest Node and pnpm.
`tools/erx fetch` installs them into `build/book-modules/` by the same
code that installs `web/`'s (`Erx::WebBuild`'s install, taking the
package directory as an argument rather than gaining a copy), and the
book step refuses modules installed for other package files.

### The parse check

Before drawing a diagram, the driver passes its source to official
Mermaid's `mermaid.parse(text)` (`dist/mermaid.d.ts`, which documents
that it throws when the diagram is invalid). A diagram the parser
rejects is refused with Mermaid's message, before beautiful-mermaid
sees it, so a diagram the repository host would show as an error never
reaches the site. The pinned parser stands in for the repository
host's, whose version is not published (unverified).

`mermaid.parse` needs a DOM. A probe ran mermaid 12.3.0
under Node 26.13.0 with no DOM on the book's 61 diagrams: 19 sequence
diagrams parsed, 2 were rejected with parse errors, and the other 40,
every flowchart with a label and every state diagram, failed with
`DOMPurify.addHook is not a function`, since `dompurify` expects a
browser's `window`. The check is therefore not built, mermaid is not
among the pinned packages, and no DOM emulation is added; whether to
check diagrams another way is an open question below.

### From SVG to page

`Erx::Book::Svg` takes each SVG string the driver returns and writes it
into the page in five steps, each over the parsed tree:

1. **Parse.** REXML parses the string as XML; a string that does not
   parse is refused.
2. **Keep what is known.** The writer knows a closed set of SVG
   elements and attributes: the ones beautiful-mermaid 1.1.3 emits for
   flowcharts, sequence diagrams and state diagrams, which the
   implementation reads off its output for the whole book (the bake-off
   outputs hold `svg`, `style`, `defs`, `marker`, `g`, `rect`,
   `circle`, `line`, `polyline`, `polygon` and `text`). Any other
   element or attribute, `script`, `foreignObject`, `image` and every
   `on...` attribute among them, is refused with its name, so a new
   version that draws something new stops the build until someone has
   looked at it.
3. **Keep the drawing self-contained.** The library's `<style>` begins
   with `@import url('https://fonts.googleapis.com/...')` for its font
   (`buildStyleBlock`, `dist/index.js` line 148) and defines its color
   variables. The writer discards that style text whole and writes its
   own, two fixed rules: `text` names the face, and `svg` sets each of
   the library's color variables (`--_text`, `--_line`, `--_arrow`,
   `--_node-fill`, `--_group-hdr` and the rest, a closed list read off
   the library's output, as the bake-off's `render/manual.rb` lists
   them) to `var(--ink)` or `var(--paper)`. A `var(--name)` in the
   drawing that the list does not hold is refused, since it would draw
   in the browser's fallback color. Every `url(...)` in an attribute,
   and every `href`, must be a fragment, `#name`, naming an id in the
   same drawing; anything else is refused, not stripped.
4. **Restyle.** `Erx::Book::Style`, a pure function from the filtered
   tree to the restyled tree, applies "The diagram style": it removes
   each group's header bar and moves its title to the lower left of the
   row the layout reserved; replaces each note's folded polygon by a
   rectangle; gives edge labels a borderless paper mask and message
   labels a paper mask placed after the lifelines in drawing order;
   sets every corner square, every stroke 1 px, every dash `10 6`,
   every literal color ink (a `classDef` color carries no meaning, as
   the writing guide asks), every arrowhead solid, every text 12 px
   regular in ink; then adds, for each outer group, the shadow path
   filled from one dither `pattern`, one `clipPath` holding the same
   paths, and the paper underlay of every line, clipped to it; and
   grows the `viewBox` to hold the shadows. It works only on shapes the
   filter has already admitted, and writes only `path`, `pattern`,
   `clipPath`, `rect` and `g` with attributes it sets itself, so the
   allow-list of step 2 stays the library's output and the restyle's
   own elements are not filtered again. A drawing whose groups or notes
   lack the parts the restyle moves (a group without its box or its
   title) is refused with the diagram's file and line, so a new library
   version cannot draw half-restyled.
5. **Rename ids.** The library's ids are fixed marker names
   (`arrowhead`, `arrowhead-start`, `seq-arrow`, `seq-arrow-open`),
   the restyle's (`dither`, `shadows`) and the Mermaid node ids (`S`,
   `idle`, `kern`), so two diagrams on one
   page would collide, and a node id could meet a heading id. Every id
   becomes `dK.name`, where K is the diagram's place on the page, and
   every fragment reference is rewritten to match. A heading slug never
   holds a `.`, so a diagram id never meets an anchor.

The writer then serializes the tree as it serializes HTML: every text
node and attribute escaped, every character above 0x7f a numeric
reference. It adds `role="img"` to the root, with `aria-labelledby`
naming the figure's caption where there is one, and places the drawing
in `<figure class="diagram">`. The `width` and `height` the library
gives stay, and the stylesheet caps the drawing at the column's width.

The writer's `text` and `svg` rules, in an HTML page, apply to every
SVG element of the page. That reaches only diagrams, because the
renderer writes no other SVG. Numbers the restyle computes are written
with at most two decimals and no trailing zeros, so its output is the
same bytes on every host.

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

The book shares the landing page's identity, its warm paper and
near-black ink (`--ink` #121211 on `--paper` #efede6, and #ece9e1 on
#0f0f0e in dark mode, the same tokens the diagrams use), and sets it
as a technical manual of the 1970s and 1980s was set, kept readable
for long text: the manual feel comes from the structure and the
furniture of the page, not from the face of the text. It borrows the
typographic era only: no logo, name, seal or document-number format
of any real document or agency.

| Role | Face | Why |
| --- | --- | --- |
| text | Source Serif 4, roman and italic | a serif made for long text on screens, with optical sizes; OFL-1.1 |
| headings, numbers, captions, the running header, the contents | IBM Plex Mono | the diagram style's one face, so a page and its drawings read as one document; the landing page's mono |
| the landing page's headings and navigation | Archivo | the landing page's face; the book does not use it |

* **Fonts are self-hosted**, for the whole site. The fetch step fetches
  the upstream files at the pins above, each checked against its
  SHA-256 in `deps.lock` (`file` entries): WOFF2 for Source Serif 4
  (the release's `WOFF2/VAR` files) and IBM Plex Mono (`woff2/`, the
  regular and medium weights), and the TTF for Archivo, which
  `google/fonts` publishes only as TTF. They are served under digest
  names with `font-display: swap`, each beside its OFL-1.1 text, as
  the license asks. `site/fonts.css` holds the `@font-face` rules once,
  naming each file by its `deps.lock` id in double braces, which the
  build replaces with the published name; `index.html`,
  `release-notes.html` and every book page link it, and the Google
  Fonts `preconnect` and stylesheet links leave both hand-written
  pages. The files are served whole; subsetting needs another tool and
  is added only if the fonts' size is reported as a problem.
* **Measure and rhythm**: text at about 19 px on wide screens and 17 px
  on narrow ones, line height about 1.6, a measure of about 68
  characters; figures and wide tables may extend past the measure up to
  the content column's width. Hyphenation by the browser (`hyphens:
  auto`, `lang="en"`).
* **Headings**: IBM Plex Mono at its regular weight, with generous
  space above; chapter and section heads in capitals under a thin rule
  across the column, the chapter title under a heavier one with its
  label ("Chapter 16") set small above it. Every numbered heading's
  decimal number (`16.2`, `16.2.1`) is set in its own element, hung in
  the left margin on wide screens. The numbers are the ones the
  headings carry, because GitHub's anchors, which the book's links
  name, are made from them; the renderer derives each number from the
  heading tree (the chapter's number, then one counter per level) and
  refuses a heading whose written number differs, so the two cannot
  drift. A heading without a number (a chapter's "Summary") takes none
  and moves no counter.
* **Running header**: a line of small capitals in the mono face at the
  top of every page, the book's title on the left and the chapter's
  label and title on the right, over a thin rule.
* **Figures**: the caption beneath the figure, in the mono face, its
  label ("Figure 16.2.") set in capitals. The label keeps the number as
  the chapter writes it, since the prose cites figures that way.
  Tables get no number or caption of their own: the book's tables have
  no captions and its prose cites none by number, so a derived number
  would name nothing.
* **Color**: the site's tokens (`--paper`, `--ink`, `--muted`,
  `--hair`, `--rule`, `--signal`, ...) for text, rules and links; dark
  mode from `prefers-color-scheme`, as the landing page does, with no
  toggle (a toggle would need a script). The tokens live in
  `site/tokens.css`, which every page links, so the palette has one
  source. The one accent, `--signal`, marks only the reader's place:
  the current chapter in the contents rail, a hovered link, focus.
* **Rules, not fills**: tables have a heavier rule above and below,
  a thin rule under the header row and hairlines between rows, with no
  fills; code blocks sit in a thin-ruled box on the paper.
* **Status and background boxes**: the status box as a thin-ruled
  panel under the chapter title, with "Status", "Built" and "Designed"
  set as small mono labels; the background boxes between two
  hairlines in a quieter tone and size, so a reader who knows the
  topic can skip them.
* **Code**: preformatted, mono at about 0.85 of the text size, never
  wrapped, scrolling sideways when wide. See "Code".
* **Diagrams**: in "The diagram style": IBM Plex Mono at 12 px, ink
  on paper from the site's tokens, 1 px square lines, long dashes,
  titles at the lower left of their groups and a dithered shadow
  behind each outer group; no color carries meaning, as the writing
  guide asks.
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

* **Contents rail**: on wide screens a left column lists the chapters
  as a manual's table of contents does, each number in its own column,
  the current chapter opened to its numbered sections (its `##`
  headings). The contents page lists the parts, each chapter with a dot
  leader to its number. On narrow screens the same list sits in a `<details>`
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
`book/links.rb`, `book/diagrams.rb`, `book/svg.rb`, `book/style.rb`, `book/code.rb`) is
a functional core around its effects. The core: the resolver, the slug
function, the contents derivation, the page renderer, the request the
diagram step sends, the SVG writer, the restyle and the tokenizer, each a pure
function of its input. The effects: running cmark-gfm and Node, reading
the tree's files, the font files and the installed packages, and
writing the output.

* **`ruby tools/build_book.rb [--out DIR] [--serve PORT] [--drafts]`**
  builds a site tree holding `book/` and the shared fonts and tokens
  (`build/book-site/` by default) alone, in a few seconds, for a
  writer's preview, and serves it with `Erx::Site.serve`. It needs no
  v64, image or card.
* **`tools/build_site.rb`** builds the book into its staging
  directory from `Erx::Site.publish`, so the book and the landing page
  are published together or not at all; the site build gains no
  option. The landing page links to `book/`.
* **Serving a directory**: `Erx::Site.routes` maps every `X/index.html`
  also to `/X/`, as the static host does, so `/book/` answers in a
  local preview as on the published site; `/` is the case where X is
  empty, not a rule of its own. `Erx::Site.serve`'s content types gain
  `.woff2`, `.ttf` and `.txt`.
* **The site build runs offline.** v64's npm packages are installed by
  `tools/erx fetch` from its `package-lock.json`, with `npm ci
  --ignore-scripts` in a build-tree copy recorded by the SHA-256 of the
  lockfile, as `web/`'s are; `Erx::SiteV64.build` links them into its
  staging tree and refuses packages installed for another lockfile, so
  the site build runs no package manager. v64's Makefile reruns `npm
  ci` when its esbuild looks older than `package.json` (the comment at
  `site_v64.rb:78`); the staged copy keeps the installed files' times,
  and whether that keeps the rule from running is checked when the
  change is made (unverified).
* **Nothing from another host**: `Erx::Site.inventory` refuses a page
  or stylesheet of `PAGE_FILES` that loads a resource from an absolute
  address: a `link`, `script` or `img` whose address has a scheme or
  begins with `//`, or a CSS `url()` or `@import` that does. Links a
  reader follows (`<a href>`) are not loads. It refuses a script of
  `PAGE_FILES` that names an absolute address at all, as a string or
  template literal beginning with `scheme://` or `//`; the console's
  xterm.js is the site's own copy (`site/README.md`). It prevents a page from
  sending its readers' addresses to another host again; the book's
  pages meet the same rule by construction, since the renderer writes
  no load from another host.
* The publishing workflow (`.github/workflows/site.yml`) runs `tools/erx
  fetch` for cmark-gfm, the fonts and the package sets, and installs
  the one Node version it pins.
* The writing guide's checklist item 13 names `ruby
  tools/build_book.rb` as the check, and the scratch link script
  retires.

**cmark-gfm enters as other host tools do**: `deps.lock` pins its
source archive by URL and SHA-256; the fetch step fetches it; the book
step builds it out of tree with CMake into `build/book-tools/`, under a
deadline with its log in `build/logs/`, and reuses an earlier build
only when the archive's SHA-256, the step's fixed CMake options and the
C compiler's version string all match the record beside it.

**Dependencies.** The dependency table of
[design.md](design.md#dependencies) has the diagram step's rows:
beautiful-mermaid (MIT), a website build tool erXos modifies, imported
into `tools/book/beautiful-mermaid` with its `ORIGIN.md`; elkjs
(EPL-2.0), entities (BSD-2-Clause), mermaid (MIT) and esbuild (MIT),
each run unmodified out of tree from `tools/book/pnpm-lock.yaml`.
Nothing of any of them is shipped: the pages hold only the SVG the
writer built from the numbers they computed. The implementation adds
the rows of cmark-gfm (BSD-2-Clause) and the three faces (OFL-1.1,
font data, shipped on the website).

## Trust and escaping

The book is erXos's own text, written and reviewed in the tree. It is
not untrusted input in CLAUDE.md's sense (it does not come from a
domain, a device, the network or an upload), so its readers need no
fuzz targets, and the step guards against mistakes, not attacks.
Escaping is still total, because it is what makes pages correct: the
book shows pids such as `<4.0.0>`, comparisons and `&&` in code, and
these must reach the reader as text.

* The renderer escapes every text node and every attribute value.
* Raw HTML, block or inline, is refused by the renderer: cmark-gfm's
  XML output carries it as data whatever its flags, so the renderer is
  where it stops.
* Link addresses are only what the resolver builds, from a page, the
  repository at a commit or a parsed `https:` URL, so no `javascript:`
  or scheme-relative address can appear.
* The SVG is the output of third-party code, so it is parsed and
  rewritten rather than pasted: only known elements and attributes,
  only references inside the drawing, every text and attribute escaped
  by the same writer as the page.
* cmark-gfm and Node run by argument vector, never through a shell,
  each under a deadline; Node runs under its permission model with read
  access only to its driver and packages.
* Fonts, the cmark-gfm archive and the packages are checked against
  pinned SHA-256 digests or lockfile integrity hashes at fetch, and no
  package runs an install script.

## Refusals

The step fails at its first error, through one `Erx::Error` caught at
the command's entry, before anything is written to the output
directory: it builds into a fresh sibling and replaces the output only
when the whole build has succeeded, as `Erx::Site.publish` does, so a
refusal leaves the old output as it was. The replacement itself deletes
the old directory and renames the new one into place; an interruption
inside it leaves no output directory, which the next build writes. The
output is a build product, so nothing is lost, and no atomic exchange
is built for that window. Each refusal names the file and, where it
has one, the line:

| Refusal | Says |
| --- | --- |
| a tool or package set missing, not built, or installed for other package files | which, and the fetch command that provides it |
| a tool failing or exceeding its deadline | the tool, the input file and the log's path |
| a draft marker, `<!-- unverified` or `<!-- check:`, without `--drafts` | the file, the line and the marker; with `--drafts` the marker shows on the page as a highlighted note instead, and such a build is never published, since the site build has no `--drafts` |
| raw HTML other than a comment | the file, the line and the tag |
| a link or image that does not resolve, or an outward link outside the `https:` rule | the file, the line, the target, and whether the file, the anchor or the address form is wrong |
| a chapter or appendix file the contents do not name | the file |
| a diagram official Mermaid rejects | the file, the line (the fence's line from cmark-gfm's `--sourcepos` plus the line Mermaid's error names, or the fence's line when it names none) and Mermaid's message, quoted with escaping |
| a diagram beautiful-mermaid fails to draw | the same, with its message |
| a drawing the restyle cannot apply the style to: a group without its box or title, a note without its outline, a color variable outside the writer's list | the diagram's file and line, and the part that is missing or unknown |
| SVG that does not parse, or holds an element, attribute or reference outside the writer's rules | the diagram's file and line, and the element, attribute or address |
| a token the writer's style text names that `site/tokens.css` does not declare | the token |
| a page of the site that loads a resource from another host | the page and the address |

## Determinism

The pages depend only on the files of `docs/book/`, the Markdown files
the links name, the images, the font files, the commit, the version of
cmark-gfm, the files of the imported library, the versions of the packages the lockfile pins, and the
version of Node. The step reads no clock, writes no date, numbers
diagrams by their place in the page, walks directories in sorted order,
sends the diagrams in book order, and writes JSON and CSS in a fixed
order.

`book/record.json` is the build record: the commit, cmark-gfm's
version, the Node version and package versions the driver reported,
the SHA-256 of the imported library's files and esbuild's version, the SHA-256 of each
font file, and the SHA-256 of every other file the
step wrote, in sorted order. It holds no time and no host name.

The supported hosts are the primary development host, Apple Silicon
macOS, and the publishing workflow's Linux x86-64 runner. Text widths
come from the library's own table, layout from elkjs, and numbers are
written by JavaScript's number-to-text conversion, so for the same Node
version the output is expected to be the same on both; that is
assumed, not shown, until the comparison below runs. The comparison:
`ruby tools/build_book.rb --compare RECORD` builds the book and lists
every file whose digest differs from a build record's, and is run
against the published `book/record.json` at the same commit, with the
same Node version, whenever the step, its lockfile, cmark-gfm or the
pinned Node version changes. A difference is fixed in what the step
gives the tools, or in the imported library by an edit, never by rewriting the
output after the fact.

## Tests

Host tests in `test/host/book_test.rb`. The tests of the pure core
need no tool and run in `make check`; the tests that run cmark-gfm or
Node run with the site tests, on demand and in the publishing workflow
before it builds, and say plainly that they are skipped when a tool or
the packages are not installed. Each test names the fault that must
make it fail, planted once by hand when the test is written.

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| Slugs | the slug function gives GitHub's ids for a dozen headings taken from the book: section numbers with dots, backticks, colons, commas, apostrophes, a repeated heading | keep the dots (`2.5-the-l4...`); number repeats from 2 instead of 1 |
| The whole book builds | `tools/build_book.rb` builds every page of the tree, all 56 diagrams included, with no refusal (tool test) | point the resolver's book directory one level up, so book links stop resolving |
| Links resolve and refuse | a fixture page's links become the expected addresses: a book page with anchor, a design document at `REPOSITORY/blob/COMMIT/docs/...#anchor`, a directory at `tree/`, an `https` link with an upper-case host written back lower-cased; a missing anchor in a design document, a missing file, a path outside the repository, `http:`, `javascript:`, `//host/x` and an `https` URL with user information are each refused with file and line | resolve repository paths from `docs/book/` instead of the repository root; pass a target through unchanged when its scheme is `https` |
| Contents | the contents fixture gives the parts in order, an entry for an unwritten chapter without a link, and previous and next that skip it; a chapter file the contents omit is refused | take a link's part from the following bold paragraph; drop the unreferenced-file check |
| Raw HTML | a fixture with a block `<div>` and an inline `<span>` is refused at each line; a comment is dropped | handle only `html_block`, so the inline tag passes |
| Figures | a diagram, a text block and an image each followed by a `*Figure N.M. ...*` paragraph become `<figure>` with that caption and id `figure-N-M`; a figure without a caption stays a bare block | match the caption against the preceding paragraph |
| Escaping and ASCII | a fixture with `<4.0.0>`, `a && b` in code, a link whose fragment holds `"` and a curly quote in prose renders them as text and numeric references; every output byte is ASCII | drop the escape in attribute values; write non-ASCII characters as they are |
| SVG writer | given SVG strings in the shape the library returns: the library's style text, its `@import` with it, is replaced by the writer's; ids become `d1.arrowhead` and `d2.arrowhead` on one page, and each `url(#arrowhead)` and `url(#dither)` names its own diagram's; `<script>`, `onload=`, `<image href="https://x">`, `fill="url(https://x)"` and `stroke="var(--_nonesuch)"` are each refused; a `<` in a label is escaped | rename ids but not the `url()` references; strip an external `url()` instead of refusing it; restyle after renaming, so the dither's id stays bare |
| Style | a fixture flowchart with an outer group holding an inner group, a dashed edge crossing the outer group's shadow and a labelled edge, and a sequence diagram with a note: the header bars are gone and each title sits at the lower left; corners are square, strokes 1 px, dashes `10 6`; exactly one shadow path, for the outer group; the dashed edge has an underlay clipped to the shadows; the note is a rectangle; the sequence diagram has no shadow and the `viewBox` grows only for the flowchart; the restyle of a group without its title is refused | count a group as inside itself, so no group casts a shadow; drop the clip from the underlay |
| The library's options | a tool test that runs the driver with the bake-off's dense flowchart and a one-node fixture: with `charWidth: 0.6` and `labelSize: 12` the node labelled with 20 characters is a `rect` 144 px plus margins wide and its label's `font-size` is 12; with `groupTitle: "bottom"` a group's contents sit 24 px below its top and 40 px above its bottom, and a group whose title is wider than its contents is as wide as the title plus 24, in a top-down and a left-to-right flowchart alike; without the three options the six bake-off diagrams give the same SVG as the unmodified 1.1.3 bundle, kept as goldens | measure with the width table when `charWidth` is set; drop the title's minimum width; give it with its axes unswapped in a top-down flowchart; draw the title row at the top |
| Diagram step | the driver, given three diagrams of which the second is invalid, returns a drawing, an error with its stage and line, and a drawing, in order, and the step's refusal names the second diagram's chapter file and line (tool test) | let the driver stop at the first error, so the third result is missing; report the fence's line without the error's own line |
| Parse check | a sequence diagram with `;` in a label, which beautiful-mermaid draws, is refused at the parse stage with Mermaid's message (tool test; built only if the probe shows `mermaid.parse` runs under Node) | skip the parse call |
| Color tokens | a writer style naming `--nonesuch` is refused; the real style, naming `--ink` and `--paper`, passes against `site/tokens.css` | read the tokens from `site/style.css`, which no longer declares them |
| Drafts | a page with `<!-- check: x -->` is refused without `--drafts` and shows the note with it | let the comment rule drop comments before the draft check |
| Nothing from another host | `Erx::Site.inventory` refuses a fixture page with a Google Fonts stylesheet link, and one with `@import url(https://x)` in its CSS, and accepts a page with an outward `<a href>` | check only `link` elements |
| Directory routes | the route table answers `/book/` and `/` with their `index.html` | keep the special case for `/` only |
| Same bytes | building the book twice into two directories gives byte-identical trees, and the record lists every file (tool test) | write the build time into the page footer; send diagrams in `Dir.glob` order unsorted |
| Code | a C, an Erlang, a shell and a Ruby fixture highlight their comments and strings, and a `%` inside an Erlang string is not a comment | end an Erlang string at the first `"` after a backslash |

The look itself, faces, spacing, light and dark, the narrow layout,
print and the diagrams' readability, is accepted by review of rendered
pages, not by a test.

## Open questions for the user

1. **An offer upstream (optional).** Should the options erXos adds
   to beautiful-mermaid also be offered upstream, as a pull request
   to `https://github.com/lukilabs/beautiful-mermaid`, so that a later
   version carries them and a later import needs fewer changes? The
   import does not depend on the answer, and sending it is a push
   outside the project. Recommendation: offer `charWidth` and the
   title's minimum width, which are general (any monospace face, and
   the clipped title is the library's fault), and keep `groupTitle`
   as erXos's change unless upstream wants it.
2. **The parse check.** `mermaid.parse` needs a DOM under Node ("The
   parse check"), so no diagram is checked against official Mermaid,
   and a diagram GitHub would show as an error can reach the site
   when beautiful-mermaid draws it. Should the check come back, and
   how: with a DOM shim such as jsdom for DOMPurify under Node (a new
   pinned dependency, with mermaid pinned beside it), with a narrower
   check of the constructs Mermaid refuses and beautiful-mermaid draws,
   or not at all, leaving GitHub's preview and the review of rendered
   pages to catch such a diagram? Recommendation: not now, with the gap
   kept as a low-severity item of `TODO.md`; the two diagrams the probe
   found rejected are fixed in their source.
