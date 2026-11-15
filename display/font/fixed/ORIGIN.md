# Source origin

Repository: https://github.com/9fans/plan9port

Revision: 1f1396913fb5372408f442ed26933f5ae4b399cd

The inventory records the imported bytes and their license evidence.
Third-party notices remain in their original files.

The files are plan9port's, unchanged, at the commit above, the
`plan9port` pin of `deps.lock`; `archive_sha256` is the SHA-256 of that
pin's `git archive`. `6x13.0000` (U+0000 to U+00FF), `6x13.2000` (U+2000
to U+20FF) and `6x13.2500` (U+2500 to U+25FF, box drawing, block elements
and geometric shapes) are Plan 9 subfonts from `font/fixed/`, `README` is
`font/fixed/README` and `LICENSE` is plan9port's top-level `LICENSE`.
Purpose: the glyphs of the terminal and of the Erlang renderer, read by
`erx_font` ([design-display.md](../../../docs/design-display.md#dependencies)).

License: the glyphs are public domain. plan9port's `LICENSE` (lines
33-42) leaves its fonts out of its MIT grant and sends the reader to
`font/LICENSE` (SHA-256
`eec6ab2359a929f7b2d6fe0be9a25c27458c3e8352599ad73e7134e1077f5ac3`), which
names `fixed/README` for these; `README` says the fonts were converted
from the BDF files of the XFree86 distribution, all marked public domain.
Those BDF files are X.Org's `font-misc-misc`: release 1.1.3, fetched from
`https://xorg.freedesktop.org/releases/individual/font/font-misc-misc-1.1.3.tar.xz`
(SHA-256
`79abe361f58bb21ade9f565898e486300ce1cc621d5285bec26e14b6a8618fed`), has
`COPYING` (SHA-256
`1711d038bca0efb51b5114e902412019d1c21531882866b1a6908c6386268cfb`) reading
"Public domain font.  Share and enjoy.", and its `6x13.bdf` (SHA-256
`c68c55ca8effcdc2714fffa9c8e07df290411867b00b547eeae952f7473efc9b`) has the
same `COPYRIGHT` property. Every glyph of non-zero width in the three
subfonts, 604 in all, read by `erx_font:parse/1` and trimmed to its set
pixels, equals the glyph of the same code point in that `6x13.bdf`.
`README` and `LICENSE` are plan9port's text, under its MIT license.

```json
{
  "version": 1,
  "repository": "https://github.com/9fans/plan9port",
  "revision": "1f1396913fb5372408f442ed26933f5ae4b399cd",
  "archive_sha256": "13a993b331b95ca33e0e441f47a8da51f30d721ea9d8654d4dba12bb04bfe2f9",
  "exclusions": [],
  "files": {
    "6x13.0000": {
      "license": "LicenseRef-misc-fixed-public-domain",
      "evidence": "README (plan9port font/fixed/README): converted from the XFree86 BDFs, all marked public domain; every glyph matches X.Org font-misc-misc 1.1.3 6x13.bdf, whose COPYRIGHT is \"Public domain font.  Share and enjoy.\"",
      "reviewed": true,
      "sha256": "06ea4dc72d76d8d24f8982a2be4bf58a60febe3a77e7b123b1650c3fb32f09fb",
      "kind": "file",
      "non_ascii_lines": []
    },
    "6x13.2000": {
      "license": "LicenseRef-misc-fixed-public-domain",
      "evidence": "README (plan9port font/fixed/README): converted from the XFree86 BDFs, all marked public domain; every glyph matches X.Org font-misc-misc 1.1.3 6x13.bdf, whose COPYRIGHT is \"Public domain font.  Share and enjoy.\"",
      "reviewed": true,
      "sha256": "ce321182c996dce3aea7053b0beaf5db65791493704c193ed4aff2132ef36d13",
      "kind": "file",
      "non_ascii_lines": []
    },
    "6x13.2500": {
      "license": "LicenseRef-misc-fixed-public-domain",
      "evidence": "README (plan9port font/fixed/README): converted from the XFree86 BDFs, all marked public domain; every glyph matches X.Org font-misc-misc 1.1.3 6x13.bdf, whose COPYRIGHT is \"Public domain font.  Share and enjoy.\"",
      "reviewed": true,
      "sha256": "f25e4869b2463cf5832acf39fbecc2c78fc2ae5b674f380cc62ac2e0429ae8e6",
      "kind": "file",
      "non_ascii_lines": []
    },
    "LICENSE": {
      "license": "MIT",
      "evidence": "LICENSE",
      "reviewed": true,
      "sha256": "0596b18c65ebc9462dab21e6cded632fe2af56a93ca4c913431a8a45f1b7fa74",
      "kind": "file",
      "non_ascii_lines": []
    },
    "README": {
      "license": "MIT",
      "evidence": "LICENSE: Russ Cox's note in plan9port, under its MIT grant; font/LICENSE excepts the fonts, not this note",
      "reviewed": true,
      "sha256": "8abc3bf93ec4a382d099977dc2a819233e89ec3c864dda130a9bdb2a1dcb5108",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
