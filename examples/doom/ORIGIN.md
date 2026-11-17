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
| Fork commit | `0a894fd53a001e465860d68654c6a077538883a1`, the superproject's gitlink |
| Download | Freedoom 0.13.0, pinned in the submodule's `deps.lock` |

The superproject's gitlink records the commit the submodule is checked out at:
that commit is the pin, and this file documents it. The fork's history records
which upstream commit it imported. The commit above adds the `deps.lock` that
pins Freedoom's release archive (`freedoom-0.13.0.zip`, BSD-3-Clause, SHA-256
`3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59`, the value
the release's signed `freedoom-0.13.0-CHECKSUM` lists for it), whose
`freedoom1.wad` is the demo's WAD.

`git clone` does not check the submodule out, and no gate, build or check reads it.
`tools/erx fetch --example doom` clones it at the recorded commit, with no
history, and fetches its downloads against their SHA-256 into
`build/examples/doom`; nothing of either runs. A checkout that is there is left as
it is. `tools/erx app run examples/doom/doom` then runs the demo on request.
