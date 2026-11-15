# Trust store origin

The root certificates of erXos's trust store
([design-crypto.md](../../docs/design-crypto.md#the-trust-store)), one
`NAME.pem` per root. The build joins them in name order into
`cacerts.pem` in `public_key`'s `priv` directory of the domain release.
A root enters, leaves or is replaced by a reviewed commit that updates
this record.

Each file was fetched on 2026-11-15 over HTTPS from its publisher's own
repository, with no sign-in, terms or form. "File SHA-256" is the
SHA-256 of the bytes as fetched; "Certificate SHA-256" is the SHA-256
fingerprint of the certificate's DER encoding. Every certificate is
self-signed: it verifies under its own public key.

| File | Root | Publisher | URL | File SHA-256 | Certificate SHA-256 | Needed by |
| --- | --- | --- | --- | --- | --- | --- |
| `digicert-global-root-g3.pem` | DigiCert Global Root G3 | DigiCert | <https://cacerts.digicert.com/DigiCertGlobalRootG3.crt.pem> | `1914cd2d4cde263315f9e32c7683fc0e1b921919ad12b256d49bf782011c03cc` | `31ad6648f8104138c738f39ea4320133393e3a18cc02296ef97c2ac9ef6731d0` | FRED: DigiCert Global G3 TLS ECC SHA384 2020 CA1 |
| `globalsign-root-ca.pem` | GlobalSign Root CA | GlobalSign | <https://secure.globalsign.com/cacert/root-r1.crt> | `ebd41040e4bb3ec742c9e381d31ef2a41a48b6685c96e7cef3c1df6cd4331c99` | `ebd41040e4bb3ec742c9e381d31ef2a41a48b6685c96e7cef3c1df6cd4331c99` | Kraken and Coinbase: GTS Root R4 cross-signed by GlobalSign Root CA |
| `gts-root-r4.pem` | GTS Root R4 | Google Trust Services | <https://pki.goog/repo/certs/gtsr4.pem> | `7e8b80d078d3dd77d3ed2108dd2b33412c12d7d72cb0965741c70708691776a2` | `349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d` | Kraken and Coinbase: a leaf from Google Trust Services' WE1 |
| `isrg-root-x1.pem` | ISRG Root X1 | Internet Security Research Group | <https://letsencrypt.org/certs/isrgrootx1.pem> | `22b557a27055b33606b6559f37703928d3e4ad79f110b407d04986e1843543d1` | `96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6` | Cboe: Let's Encrypt's YE1, Root YE, ISRG Root X2 cross-signed by X1 |
| `isrg-root-x2.pem` | ISRG Root X2 | Internet Security Research Group | <https://letsencrypt.org/certs/isrg-root-x2.pem> | `a13d881e11fe6df181b53841f9fa738a2d7ca9ae7be3d53c866f722b4242b013` | `69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470` | Cboe: the same chain, ending at X2 |

Four files are the bytes as fetched. GlobalSign publishes its root as
DER alone, so `globalsign-root-ca.pem` is the PEM encoding of the
fetched DER file (64-column base64, as OpenSSL writes it); its file
SHA-256 above is the DER file's, which is also its fingerprint, and the
PEM file's own SHA-256 is
`df68841998b7fd098a9517fe971e97890be0fc93bbe1b2a1ef63ebdea3111c80`.

The five fingerprints were checked against a second source: each is in
Mozilla's root bundle as Homebrew's `ca-certificates` 2026-10-20
installs it.

GlobalSign Root CA expires on 2028-01-28; the others expire between
2035 and 2040.
