# Source origin

Repository: https://github.com/rsms/inter

Revision: v4.1 (release archive https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip)

The inventory records the imported bytes and their license evidence.
Third-party notices remain in their original files.

The files are Inter 4.1's, unchanged, from the release archive
`Inter-4.1.zip` fetched from
`https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip`;
`archive_sha256` is that archive's SHA-256. `Inter-Regular.ttf`,
`Inter-Medium.ttf` and `Inter-SemiBold.ttf` are the archive's
`extras/ttf/` static TrueType fonts of those three weights, and
`LICENSE.txt` is the archive's top-level `LICENSE.txt`, the same bytes
as `https://raw.githubusercontent.com/rsms/inter/v4.1/LICENSE.txt`.
Purpose: the type of every role of the desktop theme (`abi/theme.txt`),
rasterised on the host by the glyph step (`Erx::Glyphs`, through
`erx-raster`) into `k8` subfonts
([design-desktop-programs.md](../../../docs/design-desktop-programs.md#type)).
No image carries these files; an image carries only the coverage the
glyph step derives from them.

License: SIL Open Font License 1.1 (`LICENSE.txt`, lines 1-3), font
data only, which erXos admits for font data alone. The copyright line
names no Reserved Font Name. Each font's `post` table is version 2.0
and names the tabular figures (`zero.tf` to `nine.tf`), from which the
glyph step takes the digits of a role marked `figures tabular`.


```json
{
  "version": 1,
  "repository": "https://github.com/rsms/inter",
  "revision": "v4.1 (release archive https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip)",
  "archive_sha256": "9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e",
  "exclusions": [],
  "removed": [],
  "files": {
    "Inter-Medium.ttf": {
      "license": "OFL-1.1",
      "evidence": "LICENSE.txt (Inter 4.1 release archive): the Inter Project Authors license the Font Software under the SIL Open Font License 1.1, with no Reserved Font Name",
      "reviewed": true,
      "sha256": "97ad806f526e41546d46365bb3a393145f75b7b1568913db74549ad8b8dba872",
      "kind": "file",
      "non_ascii_lines": []
    },
    "Inter-Regular.ttf": {
      "license": "OFL-1.1",
      "evidence": "LICENSE.txt (Inter 4.1 release archive): the Inter Project Authors license the Font Software under the SIL Open Font License 1.1, with no Reserved Font Name",
      "reviewed": true,
      "sha256": "40d692fce188e4471e2b3cba937be967878f631ad3ebbbdcd587687c7ebe0c82",
      "kind": "file",
      "non_ascii_lines": []
    },
    "Inter-SemiBold.ttf": {
      "license": "OFL-1.1",
      "evidence": "LICENSE.txt (Inter 4.1 release archive): the Inter Project Authors license the Font Software under the SIL Open Font License 1.1, with no Reserved Font Name",
      "reviewed": true,
      "sha256": "78a843fade9d4612a5567302fb595b56976eb5fcebf4fea5a5912d638bafcde3",
      "kind": "file",
      "non_ascii_lines": []
    },
    "LICENSE.txt": {
      "license": "OFL-1.1",
      "evidence": "LICENSE.txt (Inter 4.1 release archive): the Inter Project Authors license the Font Software under the SIL Open Font License 1.1, with no Reserved Font Name",
      "reviewed": true,
      "sha256": "262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
