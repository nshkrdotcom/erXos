# Source origin

Repository: https://github.com/LoupVaillant/Monocypher

Revision: 4.0.2

Monocypher's Ed25519 signature check, imported as erXos's code for the
small verifier of [design.md](../docs/design.md#dependencies): the
per-byte primitive `erx_bytes:ed25519_verify/3`
(`otp/erts/emulator/nifs/erxos/erx_bytes_bif.c`), which checks an app
package's seal ([design-packaging.md](../docs/design-packaging.md#the-package))
and, later, an update's signature.

The import is the release archive `monocypher-4.0.2.tar.gz`, fetched over
HTTPS from `https://monocypher.org/download/monocypher-4.0.2.tar.gz`; the
copy the GitHub release offers
(`https://github.com/LoupVaillant/Monocypher/releases/download/4.0.2/monocypher-4.0.2.tar.gz`)
has the same SHA-256, the `archive_sha256` below. Five files were taken,
flattened into this directory:

| File | Upstream path | SHA-256 of the imported bytes |
| --- | --- | --- |
| `LICENCE.md` | `LICENCE.md` | `5f8360e4c06ddcc584bdb4b210c6af824c4bb301e6a9a521869b6d90795ca4b3` |
| `monocypher.c` | `src/monocypher.c` | `afe2b098c8569577a84488e0b98d276d1fba6506adea68bb9241a52111734c59` |
| `monocypher.h` | `src/monocypher.h` | `f78bb31255cfb7beba66afd2137f5194c8a025cf40488b6cc1e295234d43f374` |
| `monocypher-ed25519.c` | `src/optional/monocypher-ed25519.c` | `7c9b16056cbd27521919e8a6f56a228808b9e718afc42e3d33f28c08e5abdee2` |
| `monocypher-ed25519.h` | `src/optional/monocypher-ed25519.h` | `bd546edcd468d64e28caa3dbf4b1d6bfad7435c0ce994723fd81aae26405121b` |

License: Monocypher is dual-licensed, BSD-2-Clause or CC0-1.0, and each
source file says so in its SPDX line; erXos uses it under BSD-2-Clause,
whose text and copyright holders are `LICENCE.md`.

Left out: the tests, the manual, the build files and `change-prefix.sh`.
erXos tests the import against RFC 8032's vectors and the host's OpenSSL
(`test/host/erx_ed25519_test.rb`).

Review: erXos calls only `crypto_ed25519_check`, the RFC 8032 check with
SHA-512, through `crypto_eddsa_check_equation`. It refuses a public key
or signature point not on the curve and a scalar `S` not below the
group's order, and accepts a non-canonical encoding of either point. Its
work is variable-time, which is safe here because a check's inputs, the
key, the signature and the message, are all public. The rest of both
files (X25519, ChaCha20, Argon2, BLAKE2b, signing) is not called by the
runtime; the fuzz target, `tools/fuzz/ed25519_fuzz.c`, signs with it to
make valid inputs.

Each file erXos changes says so in a `Modified by erXos` notice at its
top, which lists the changes. All five are unchanged.

The inventory records the imported bytes and their license evidence.
Third-party notices remain in their original files.

```json
{
  "version": 1,
  "repository": "https://github.com/LoupVaillant/Monocypher",
  "revision": "4.0.2",
  "archive_sha256": "38d07179738c0c90677dba3ceb7a7b8496bcfea758ba1a53e803fed30ae0879c",
  "exclusions": [],
  "files": {
    "LICENCE.md": {
      "license": "BSD-2-Clause OR CC0-1.0",
      "evidence": "reviewed LICENCE.md: Monocypher as a whole is dual-licensed, a 2-clause BSD license or CC0-1.0; erXos uses it under BSD-2-Clause",
      "reviewed": true,
      "sha256": "5f8360e4c06ddcc584bdb4b210c6af824c4bb301e6a9a521869b6d90795ca4b3",
      "kind": "file",
      "non_ascii_lines": []
    },
    "monocypher-ed25519.c": {
      "license": "BSD-2-Clause OR CC0-1.0",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "7c9b16056cbd27521919e8a6f56a228808b9e718afc42e3d33f28c08e5abdee2",
      "kind": "file",
      "non_ascii_lines": []
    },
    "monocypher-ed25519.h": {
      "license": "BSD-2-Clause OR CC0-1.0",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "bd546edcd468d64e28caa3dbf4b1d6bfad7435c0ce994723fd81aae26405121b",
      "kind": "file",
      "non_ascii_lines": []
    },
    "monocypher.c": {
      "license": "BSD-2-Clause OR CC0-1.0",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "afe2b098c8569577a84488e0b98d276d1fba6506adea68bb9241a52111734c59",
      "kind": "file",
      "non_ascii_lines": [
        "1d0dad678a3fa34bc328aa0e981f63fc97fe6a750990f577d4d5f0571605426f"
      ]
    },
    "monocypher.h": {
      "license": "BSD-2-Clause OR CC0-1.0",
      "evidence": "file SPDX",
      "reviewed": false,
      "sha256": "f78bb31255cfb7beba66afd2137f5194c8a025cf40488b6cc1e295234d43f374",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
