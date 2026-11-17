# Source origin

The Doom demo ([design-packaging.md](../../docs/design-packaging.md#examples)) is
the git submodule `doom/` beside this file: doomgeneric, under GPL-2.0, with erXos's
glue, its `app.txt` and a `Makefile` over the SDK's `sdk.mk`. No part of it is
erXos's tree, and it never ships: its license keeps it out of every image erXos
distributes.

| | |
| --- | --- |
| Upstream repository | `https://github.com/ozkl/doomgeneric` |
| erXos's fork | `https://github.com/stass/erxos-doom` |
| Fork commit | the superproject's gitlink (`git ls-tree HEAD examples/doom/doom`) |
| Download | Freedoom, its release and SHA-256 pinned in the submodule's `deps.lock` |

The superproject's gitlink records the commit the submodule is checked out at:
that commit is the pin, and this file names no commit, so it cannot disagree
with it. The fork's history records which upstream commit it imported. The fork's
`deps.lock` pins Freedoom's release archive (BSD-3-Clause) and its SHA-256,
the value the release's signed checksum file lists for it; the archive's
`freedoom1.wad` is the demo's WAD.

`git clone` does not check the submodule out, and no gate, build or check reads it.
`tools/erx fetch --example doom` clones it at the recorded commit, with no
history, and fetches its downloads against their SHA-256 into
`build/examples/doom`; nothing of either runs. A checkout that is there is left as
it is. `tools/erx app run examples/doom/doom` then runs the demo on request.
