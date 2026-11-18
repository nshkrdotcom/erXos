# Source origin

The Doom demo ([design-packaging.md](../../docs/design-packaging.md#examples)) is
the git submodule `doom/` beside this file: erXos's fork of doomgeneric, under
GPL-2.0-or-later. erXos's commits on top of upstream's hold the platform layer,
in `doomgeneric/` beside upstream's own platform layers; the app's `app.txt`; its
build; and `deps.lock`, which pins Freedoom's WAD. No part of it is erXos's
tree. 0.1's published images carry it as `/bin/doom`, an example under the
dependency status `example` ([design.md](../../docs/design.md#dependencies)),
with its source offered at the fork's commit below.

| | |
| --- | --- |
| Upstream repository | `https://github.com/ozkl/doomgeneric` |
| Upstream commit | `e257a09527062bfb986b6e5e0780839b6cbd5b71`, the fork's base |
| Upstream archive SHA-256 | `26f8f60daa6c6e4d3c01e5eac9fb700d592dede803d13ac848154ff356b2a2e7`, of `https://codeload.github.com/ozkl/doomgeneric/tar.gz/e257a09527062bfb986b6e5e0780839b6cbd5b71`, whose tree the base commit's matches |
| erXos's fork | `https://github.com/stass/erxos-doom` |
| Fork commit | the superproject's gitlink (`git ls-tree HEAD examples/doom/doom`) |
| Download | Freedoom, its release and SHA-256 pinned in the submodule's `deps.lock` |

The superproject's gitlink records the commit the submodule is checked out at:
that commit is the pin, and this file does not name it, so it cannot disagree
with it. The fork's history is upstream's up to the commit it was imported
from, with erXos's commits on top. The fork's `deps.lock` pins Freedoom's
release archive (BSD-3-Clause) and its SHA-256, the value the release's signed
checksum file lists for it; the archive's `freedoom1.wad` is the demo's WAD.

`git clone` does not check the submodule out, and no gate, test build or check
reads it; only the published build, `tools/erx pack --published`, does
(`tools/lib/erx/doom_program.rb`), and it refuses a checkout that is missing,
at another commit than the gitlink's, or changed.
`tools/erx fetch --example doom` clones it at the recorded commit, with no
history, and fetches its downloads against their SHA-256 into
`build/examples/doom`; nothing of either runs. A checkout that is there is left as
it is.
