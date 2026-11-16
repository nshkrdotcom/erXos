# Cryptography: OpenSSL 3.5 and OTP's `crypto`

OTP's `crypto`, `public_key`, `asn1`, `ssl` and `ssh` run on erXos over
OpenSSL 3.5, in every domain that loads them except the system domain,
which never holds OpenSSL. This document says where the library runs, how
it is built, linked and seeded, and how its use is tested. The SSH
service built on it is [design-ssh.md](design-ssh.md); the vault's use of
it is [design-system.md](design-system.md#the-vault); TLS for the web is
[design-web.md](design-web.md#the-network-front-end). It also says how a
session or an app makes HTTPS requests, with `ssl`, `inets`' HTTP client
and the image's trust store ([HTTPS clients](#https-clients)); the first
app that does is the full kiosk's live quotes of
[design-quotes.md](design-quotes.md).

## Context

Four uses need cryptography: the web domain's TLS listener, the vault's
Argon2id, HKDF and AES-256-GCM, SSH, and HTTPS clients in sessions and
apps, which fetch data from servers on the internet, the full kiosk's live
quotes first ([design-quotes.md](design-quotes.md)). The architecture already
decides the library: "OTP's `crypto`, `ssl` and `ssh` use OpenSSL 3.5"
and "a small verifier keeps the full library out of the system domain"
([design.md](design.md#decisions)); its dependency row says "in
application domains and the vault's, never in the system domain". OTP's
`crypto` is written against OpenSSL, and 3.5 is a long-term-support
series, supported until 2030-04-08
([research](research-boards-storage.md#cryptography-libraries)).

Unpredictable values come from the kernel's generator alone:
`erx_bytes:entropy/1` is Erlang's one entry, and OpenSSL's generator is
seeded from `erx_entropy_read`, never from another source
([design.md](design.md#decisions)). How good the generator's seed is
belongs to the machine: the boot banner reports `entropy_quality`, a
release build stops the boot on a weak seed and a development build
continues ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy));
on Fiasco the seed is the counter and `/chosen`'s seeds where the
device tree carries them; where it carries none, the Raspberry Pi 4 adds
its RNG200 and other boards use the counter alone
([design-fiasco.md](design-fiasco.md#the-call-table)).

ERTS is built once per execution flavour, as the interpreter and as
BeamAsm, and each build is linked into the runtime images that use it
([design-runtime.md](design-runtime.md#beamasm)). The system domain runs
the interpreter flavour, so that the trusted base holds no generated code
and no C++; command domains and, in deterministic mode, every domain run
it too.

What the sources say, read at the pins of [Sources](#sources):

* **OTP links its NIFs statically when asked.** With static NIFs, ERTS's
  build adds `asn1rt_nif.a` and `crypto.a` to the emulator
  (`erts/emulator/Makefile.in:229-237`) and generates the static NIF
  table `driver_tab.c` with `utils/make_driver_tab` (`:702-704`);
  `--with-ssl=PATH` names the OpenSSL to build against and
  `--disable-dynamic-ssl-lib` links it statically
  (`make/configure.ac:256-286`). erXos's ERTS loads only statically
  linked NIFs ([design-runtime.md](design-runtime.md#everything-else)).
* **`crypto` builds without engines.** Engine support is compiled only
  when OpenSSL lacks `OPENSSL_NO_ENGINE`
  (`lib/crypto/c_src/openssl_config.h:387-388`).
* **`crypto:strong_rand_bytes/1` is OpenSSL's `RAND_bytes`**
  (`lib/crypto/c_src/rand.c:41`), and `crypto:rand_seed/1` only adds
  bytes through `RAND_seed` (`rand.c:150`).
* **OpenSSL's seed sources are chosen when it is configured**
  (`--with-rand-seed`, `INSTALL.md:476-520`). The `os` method turns on
  both `getrandom` and `devrandom`
  (`providers/implementations/rands/seeding/rand_unix.c:205-210`). The
  `getrandom` method's `syscall_random` first looks for libc's
  `getentropy` through a weak reference, except on FreeBSD, NetBSD and
  DragonFly (`rand_unix.c:354-386`), then calls the `getrandom` system
  call on Linux, `getrandom()` on FreeBSD 12 and later, and on any other
  target fails with `ENOSYS` (`:388-405`). Its caller asks for what the
  pool still needs, gives up after three failed attempts, and leaves the
  pool empty on an error other than `EINTR` (`:637-660`); a generator that
  gets no seed refuses to produce bytes (`INSTALL.md:1979-1983`). `rdcpu`
  reads the CPU's `RNDRRS` on AArch64 (`INSTALL.md:508-511`).
* **A weak reference does not pull a member out of an archive**: LLD
  leaves it undefined, so it resolves to null, unless another reference
  extracts the member (`lld/ELF/Symbols.cpp:416-418`, `:640-646`).
  erXos's runtime code is compiled for `aarch64-none-elf`
  (`tools/lib/erx/musl.rb:17`), which defines neither `__linux` nor
  `__FreeBSD__`.
* **musl's `getrandom` is the system call** `SYS_getrandom`
  (`musl/src/linux/getrandom.c`); its `getentropy` refuses more than 256
  bytes with `EIO` and loops over `getrandom` otherwise
  (`musl/src/misc/getentropy.c`).
* **OpenSSL finds AArch64 CPU features by `getauxval` only on glibc,
  Android, FreeBSD and OpenBSD**; elsewhere it probes instructions and
  catches `SIGILL` (`crypto/armcap.c:61-105`, `:234-250`), from a
  constructor that runs at load (`armcap.c:65-67`). The environment
  variable `OPENSSL_armcap` overrides both (`armcap.c:265-268`).
* **OpenSSL cross-builds from a target description**: `linux-aarch64`
  is `linux-generic64` with the AArch64 assembler
  (`Configurations/10-main.conf:768-772`), and `--config=FILE` adds
  targets without editing the tree (`Configure:30`).
* **OpenSSL's configuration reads more than the library.** The top-level
  `build.info` names `crypto`, `ssl`, `apps`, `util`, `tools`, `fuzz`,
  `providers`, `doc` and `exporters` unconditionally, `test` unless
  `no-tests`, `demos` when enabled, and `engines` while the 3.0
  deprecated interfaces are on (`build.info:4-14`). `Configure` skips a
  directory only for a disabled feature's subdirectory of `crypto/`, or
  `engines/` under `no-engine` (`Configure:1947-1949`, `:2064-2068`), and
  opens the `build.info` of every other (`:2208-2213`). It reads its Perl
  modules from `util/perl` and `external/perl` (`:16`, `:20`; the
  template engine `Text::Template` comes from `PERL5LIB`, below) and its
  version from `VERSION.dat` (`:345`). `demos` is off by default
  (`:601`).
* **OTP's TLS client verifies by default.** `ssl`'s default `verify` is
  `verify_peer` for a client and `verify_none` for a server
  (`lib/ssl/src/ssl_config.erl:734-739`); a client with `verify_peer` and
  neither `cacerts` nor `cacertfile` is refused before it connects
  (`:942-955`). The default versions are `['tlsv1.3', 'tlsv1.2']`, those
  of `?ALL_SUPPORTED_VERSIONS` the crypto library supports
  (`ssl_internal.hrl:78`, `tls_record.erl:345-365`, `ssl_config.erl:658-660`);
  `tlsv1.1` and `tlsv1` are taken only when a caller names them
  (`ssl_internal.hrl:79`). A client connecting to a host name sends it
  as the server name and checks the peer's certificate against it
  (`ssl_config.erl:1107-1120`, `ssl_certificate.erl:247-256`); a name that
  does not match is a `bad_certificate` alert, as is any other failed
  path check but the expired, revoked, unsupported and unknown-issuer
  ones, which have alerts of their own (`ssl_handshake.erl:2287-2320`).
* **Validity is checked against the wall clock.** A certificate whose
  validity period does not hold the current time fails with
  `{bad_cert, cert_expired}` (`lib/public_key/src/pubkey_cert.erl:155-166`),
  the alert `certificate_expired`.
* **`public_key` finds the system's roots by the OS type.**
  `public_key:cacerts_get/0` loads them once and keeps them in a
  persistent term, from the application variable `cacerts_path` when it
  is set, else from a list of paths per OS: `/etc/ssl/cert.pem` first on
  FreeBSD and the other BSDs, and `{error, {enotsup, Os}}` for an OS the
  list does not name (`pubkey_os_cacerts.erl:40-90`, `:228-233`).
* **`httpc` uses them by default.** A request to an `https` URL that
  gives no `ssl` option takes `ssl_verify_host_options(true)`:
  `verify_peer`, `public_key:cacerts_get()` and RFC 6125's wildcard rule
  for the host name (`lib/inets/src/http_client/httpc.erl:861-871`,
  `:1506-1508`). A direct `ssl:connect/3` gets no such default: it must
  name `cacerts` itself (above).
* **`httpc`'s bounds are partial.** `max_header_size` and
  `max_body_size` are options of a request, the fourth argument of
  `httpc:request/4`; placed among the HTTP options of the third, an
  option is ignored with an info report (`httpc.erl:215-233`,
  `:1412-1423`, `:1600-1610`). Their defaults are 10,240 bytes and
  `nolimit` (`http_internal.hrl:29-30`). `max_body_size` refuses a body
  whose `content-length` is larger (`httpc_handler.erl:1011-1031`) and
  bounds a chunked one's decoded bytes, with the error `{body_too_long,
  {max, Max}}` (`http_chunk.erl:161-166`). What it misses: a body that
  ends when the server closes, with no length, grows whatever the bound
  says (`httpc_response.erl:68-85`, `httpc_handler.erl:512-527`), and so
  does such a body's first fragment, which arrives with the headers and
  is kept or delivered at the close without passing that branch
  (`httpc_handler.erl:606-613`, `:1011-1024`). `max_header_size` counts
  header bytes only: the status line and reason phrase are gathered with
  no count (`httpc_response.erl:169-264`), and the branch for a line
  break followed by a byte adds to the count without checking it
  (`:332-336`), so a server that sends an endless reason phrase or
  endless one-byte lines grows the client's memory until the request's
  timeout. `autoredirect` is on by default (`httpc.erl:293-299`), and
  `autoretry`, `infinity` by default, repeats a request once after a
  `Retry-After` of any length (`:301-309`).

## Requirements

* **CR1.** No code of OpenSSL is mapped into the system domain, and no
  constructor of it runs there.
* **CR2.** OpenSSL's generator is seeded only from `erx_entropy_read`; a
  failed read fails the seeding, and no other source is tried.
* **CR3.** `crypto`, `public_key` and `ssh` on erXos agree with stock OTP
  29.1.2 built against the same OpenSSL configuration, case by case in
  OTP's own suites, whose `public_key` cases exercise `asn1`'s run-time
  module, `asn1rt_nif`.
* **CR4.** OpenSSL uses the CPU's AES and SHA instructions where the CPU
  has them and constant-time software where it does not, decided from the
  features the kernel reports, never from a probe that faults.
* **CR5.** OpenSSL reads no file and opens no socket on erXos.
* **CR6.** An `httpc` request to an `https` URL that names no `ssl`
  option checks the server's chain against the image's trust store and
  its certificate against the host name it asked for, and speaks only
  TLS 1.3 or 1.2; a direct `ssl` client gets the same by naming the
  store, `{cacerts, public_key:cacerts_get()}`, and nothing else.
* **CR7.** The trust store is the same file in every domain, no domain
  can change it, and it changes only with the image.
* **CR8.** `httpc` never holds more of a response's head than the
  request's `max_header_size` and one read of the socket, nor more of its
  body than its `max_body_size`, whatever the framing and however the
  bytes are split.

## Design

### Three runtime images, and OpenSSL in two of them

The construction is that **the system domain runs an image of its own,
and OpenSSL is linked into every other image**. ERTS's two builds are
linked three times:

| Image | Build | Static NIFs beyond ERTS's and erXos's own | Run by |
| --- | --- | --- | --- |
| the **system image** | the interpreter build, no BeamAsm, asmjit or C++ | none | the system domain alone, in every mode |
| the **interpreter image** | the interpreter build | `crypto` and `asn1rt_nif`, with OpenSSL's `libcrypto` | command domains, every domain but the system domain in deterministic mode, and domains whose specification chooses it |
| the **BeamAsm image** | the BeamAsm build | `crypto` and `asn1rt_nif`, with OpenSSL's `libcrypto` | every other ERTS domain |

Each requirement follows:

* **CR1 holds by construction.** OpenSSL is absent from the one file the
  system domain maps, so no call, constructor or data of it exists there.
  No list of modules the system release must avoid loading is needed, and
  a `crypto` beam put into the system release by mistake fails at its
  `on_load`, because the image has no NIF named `crypto`.
* **Every other domain has the same library.** A domain needs no choice
  to get `crypto`: the web domain's TLS, the vault, the SSH domain and
  every session find it in whichever image they run, including in
  deterministic mode, where every domain but the system domain runs the
  interpreter image.
* **The system image is the interpreter build linked without OpenSSL.**
  The interpreter image as [design-runtime.md](design-runtime.md#beamasm)
  describes it (no BeamAsm, asmjit, libc++ or libc++abi, no
  `ERX_IMAGE_JIT`) is the system image, which links OTP's `driver_tab.o`.
  The interpreter image is a second
  link of the same build's objects that differs from it by its static NIF
  table, `driver_tab_crypto.o`, generated by `make_driver_tab` with the two
  NIFs (the `erx_crypto_tab` target of `erts/emulator/Makefile.in`, which
  `tools/lib/erx/native_runtime.rb` runs over the archives
  `tools/lib/erx/domain_image_apps.rb` lists), and by the two
  NIFs' archives and `libcrypto`. Each link names its one table, since
  `libbeam.a` holds none, so a link that named two would fail on a
  duplicate symbol and one that named none on an undefined one. It carries
  no `ERX_IMAGE_JIT` either, so command domains still make no code.

The BeamAsm image is the one link of the BeamAsm build, with the same
NIFs as the interpreter image. Each image is a file of the boot image,
mapped and shared by the domains that run it, so OpenSSL's text is in
memory once for the domains of the interpreter image and once for those
of the BeamAsm image, when domains of both run. The build's static NIF
classification ([design-runtime.md](design-runtime.md#everything-else))
gains one column, the images each NIF is linked into.

### Domains that call no OpenSSL

A domain that runs the interpreter or BeamAsm image maps OpenSSL whether
or not it uses it, and the library's constructor on AArch64,
`OPENSSL_cpuid_setup` (`armcap.c:65-67`), runs there at load, reading
the feature words and `OPENSSL_armcap` (below), and the CPU's main ID register
only when those claim `HWCAP_CPUID`, which the kernel's feature words
never do (below). Nothing
more of
OpenSSL runs in a domain that never calls `crypto`. The network domain
is one: no module of the network stack calls `crypto`, which a build
check of the stack proves
([design-network-stack.md](design-network-stack.md#build-checks)), and
its boot script names no `crypto`, so `crypto` is not on its code path,
no `on_load` there reaches the NIF and no packet reaches OpenSSL. (The
one domain release holds every script's applications, so a domain could
still load `crypto` by name; nothing in the network domain does.) So the network domain keeps the BeamAsm image
and its speed, and what keeps OpenSSL off its packets is the stack's own
check rather than the image; the system domain alone needs the image to
lack the library, since a constructor run there is code of the library
in the trusted base.

### Building OpenSSL

OpenSSL 3.5.9 is imported into `openssl/` as erXos's code, with an
`ORIGIN.md` recording the release tarball's SHA-256 and each file's, and
its `LICENSE.txt`. It is changed (below), so it enters the tree rather than
being fetched and built unchanged
([design.md](design.md#dependencies)). The import keeps whole every
directory and file that `Configure` reads under the configuration below,
but one module, so OpenSSL's build machinery runs unedited but for one list:
`Configure`, the
top-level `build.info`, `VERSION.dat`, `configdata.pm.in`, `Configurations/`,
`apps/`, `crypto/`, `doc/`, `exporters/`, `external/`, `fuzz/`,
`include/`, `providers/`, `ssl/`, `tools/` and `util/`. It leaves out only
what that configuration never reads: `test/` (`no-tests`), `demos/` (off
by default), `engines/` (`no-engine`), `os-dep/`, `VMS/` and `ms/`, which
other systems' configurations name, the seven empty directories the
release carries (`cloudflare-quiche/`, `oqs-provider/`,
`pkcs11-provider/`, `python-ecdsa/`, `tlsfuzzer/`, `tlslite-ng/` and
`wycheproof/`), and the Perl module `Text::Template` that the release
bundles under `external/perl/`. That module is a build tool OpenSSL
uses as released: `Configure` and make's generators (`util/dofile.pl`) load
it on the build host. It is fetched, not imported: `deps.lock` pins
Text-Template 1.56's CPAN tarball (`text-template`) by SHA-256, the fetch
step verifies it and unpacks it out of tree, and the build sets `PERL5LIB`
to its `lib/` for `Configure` and make, which see none of the caller's
`PERL5LIB` or `PERL5OPT`. `external/perl/MODULES.txt`, the list of
directories that `OpenSSL::fallback` appends to Perl's search path, is
empty, since that module refuses a listed directory that is absent.
`make check-openssl`'s integration test
(`test/integration/libcrypto_build_test.rb`) proves the set: it runs
`Configure` with erXos's options on the imported tree and builds
`libcrypto.a`, and on a copy without `ssl/build.info` sees `Configure`
fail on the `build.info` it cannot open. OpenSSL's `Configure` and its
Perl assembler generators are inherited build machinery, invoked through
one entry point of erXos's top-level build, as OTP's `configure` is
([design.md](design.md#build-and-toolchain)), and the build makes the
`libcrypto.a` target alone.

The build (`tools/lib/erx/libcrypto.rb`, run by `tools/erx build openssl`
and by each runtime build against that build's own musl) configures one
target of erXos's own, `erxos-aarch64`, in a file the build passes with
`--config`, `config/openssl/erxos-aarch64.conf`: `linux-aarch64`'s settings with
erXos's compiler, sysroot and flags, and `-D__erxos__`. The configuration:

```
./Configure erxos-aarch64 --config=<erXos's target file>
    --with-rand-seed=getrandom
    no-shared no-module no-dso no-engine no-async no-sock
    no-autoload-config no-ui-console no-apps no-tests no-docs
    no-legacy no-quic no-http
```

Each option has one reason:

| Option | Reason |
| --- | --- |
| `--with-rand-seed=getrandom` | the one seed path (below); `os` would add `devrandom` (`rand_unix.c:205-210`) and `rdcpu` would read the CPU directly |
| `no-shared`, `no-module`, `no-dso` | ERTS links NIFs statically and loads no library at run time; providers are built into `libcrypto` |
| `no-engine` | engines are loadable code; `crypto` compiles without them (`openssl_config.h:387`) |
| `no-async` | its jobs switch stacks with `ucontext`, which musl does not provide and nothing on erXos asks for |
| `no-sock`, `no-http` | `crypto` asks OpenSSL for no network I/O, and the seam has no sockets in a runtime |
| `no-autoload-config`, `no-ui-console` | no configuration file and no terminal prompt are read (CR5) |
| `no-legacy` | the legacy provider (MD4, RC4, Blowfish, single DES and others) serves nothing erXos uses; `crypto:supports/0` lists what remains |
| `no-quic`, `no-apps`, `no-tests`, `no-docs` | nothing erXos ships; OTP's `ssl` implements TLS itself over `crypto` and links no `libssl` |

The assembler is kept: OpenSSL's AArch64 code is where its AES, GHASH,
SHA and ChaCha20 are fast and constant-time.

**Three edits**, each under `__erxos__`, the first two taking FreeBSD's
branch; each file carries its notice:

* `crypto/armcap.c` defines `OSSL_IMPLEMENT_GETAUXVAL` under `__erxos__`,
  so CPU features come from `getauxval(AT_HWCAP)` and `AT_HWCAP2`, which
  the seam answers from the boot information page, or in a program from
  its argument registers, and the `SIGILL`
  probe is never compiled. One read of the CPU stays: when the words
  claim `HWCAP_CPUID`, `OPENSSL_cpuid_setup` reads the main ID register (in the
  tree's `armcap.c`, the `ARMV8_CPUID` test before `_armv8_cpuid_probe`)
  to pick code tuned for the core, and user mode's read of it traps on
  erXos. The kernel's feature words never claim `HWCAP_CPUID` (the rule
  `TODO.md`'s feature-words item carries to where the words are filled),
  so the read is not reached. `OPENSSL_armcap` sets the features and
  returns before that test, so it never causes the read. With the words
  0, as on Fiasco, no feature bit is set, `OPENSSL_armcap_P` stays
  0, and every algorithm takes its software path.
* `providers/implementations/rands/seeding/rand_unix.c` includes
  `<sys/random.h>` and, in `syscall_random`, skips the weak `getentropy`
  lookup and returns `getrandom(buf, buflen, 0)` under `__erxos__`, so
  the seed path is a direct, strong call that the link resolves to musl's
  `getrandom`.
* `crypto/arm64cpuid.pl`'s `_armv7_tick` returns 0 under `__erxos__`
  instead of reading the timer's counter, which only the C library's
  `erx_fiasco_counter` reads (the counter-read build check of every
  linked program refuses the read). OpenSSL calls it only when
  `OPENSSL_armcap` sets `ARMV7_TICK`, and `OPENSSL_rdtsc` answers 0
  without that bit anyway.

### Seeding

OpenSSL's one seed path is `getrandom`, in musl, over the seam's
`SYS_getrandom` row, over `erx_entropy_read`, in `liberx`:

* **The call is strong.** `syscall_random` calls `getrandom` by name, so
  the link takes musl's `getrandom.o` into every image with `libcrypto`;
  no weak reference is left to resolve to null and fall through to
  `ENOSYS` (`rand_unix.c:401-403`).
* **The seam's `SYS_getrandom` row** fills the caller's buffer with
  `erx_entropy_take` in pieces of at most 256 bytes (`entropy_bytes_max`),
  returns the full length, and on any failed piece returns `-EIO`, so musl
  sets `errno` to `EIO`. It never returns a short count and never fills
  from another source. It answers the same in a program
  ([design-programs.md](design-programs.md)), so a native program's
  `getrandom` and `getentropy` behave as a runtime's.
* **Any request size works.** The row loops in pieces, so however much
  OpenSSL's pool asks for at the first seed or at a reseed, the answer is
  all of it or `EIO`; musl's 256-byte bound on `getentropy` is not on
  OpenSSL's path.
* **A failed seed fails the operation.** On `EIO` OpenSSL's pool stays
  empty (`rand_unix.c:637-660`), and its generator refuses to produce
  bytes until it is seeded (`INSTALL.md:1979-1983`), so
  `crypto:strong_rand_bytes/1` raises, key generation fails, and an SSH
  or TLS handshake that needs fresh randomness ends; no caller continues
  with a value it never got, as the entropy decision requires. Since
  `getrandom` is the only method compiled in, there is no second source
  to fall back to.
* **Quality is the machine's.** OpenSSL credits each seed byte with eight
  bits, as from any operating system source. Whether the kernel's seed
  deserves that is reported by `entropy_quality`; a release build never
  runs on a weak seed. A development build on Fiasco leaves
  `entropy_quality` unreported, and its banner names the `/chosen` seeds
  it mixed or says it seeds from the counter alone; keys made on a
  boot without a seed are as weak as the counter, which
  [design-ssh.md](design-ssh.md#host-keys) records for the host key.
* **Reseeding** follows OpenSSL's own intervals, each a call through the
  same path; on Fiasco each is a request to the root's generator
  service. A generator already seeded need not read the kernel for every
  request, so a failure of the kernel's generator after the first seed
  shows at the next reseed, not at once.

`crypto:rand_seed/1` adds bytes to OpenSSL's generator and never replaces
its seed, so it cannot weaken it.

### CPU features and constant time

OpenSSL picks its AES, GHASH, SHA and polynomial code from the feature
words, so the choice follows the kernel's report:

* **With the ARMv8 cryptographic extension**, as on the development
  hosts' CPUs under HVF and on the Raspberry Pi 5's Cortex-A76
  (unverified for the Pi 5, settled as for the Pi 4 below), AES-GCM
  uses the AES and polynomial-multiply instructions, which take the same
  time for every key and input.
* **Without it**, as on the Raspberry Pi 4's Cortex-A72 (unverified: the
  board's identification registers, which the boot reads, settle it),
  AES uses OpenSSL's vector-permutation code for NEON, which uses no
  table indexed by secret data, and ChaCha20-Poly1305 is the faster
  cipher, which is first in SSH's order
  ([design-ssh.md](design-ssh.md#algorithm-policy)).
* **X25519, Ed25519 and ML-KEM-768** are OpenSSL's own constant-time
  implementations. erXos adds no cryptographic code to OpenSSL and calls
  no primitive outside `crypto`'s NIF.
* **`OPENSSL_armcap`** in a domain's environment still overrides the
  feature words (`armcap.c:265`). A domain's environment is set by its
  own specification or by its own processes, so the override can only
  slow or weaken that domain's own cryptography, or, by claiming a
  feature the CPU lacks, end that domain at the first use of the
  algorithm that needs it, never another's.

### OTP's applications

`lib/crypto`, `lib/asn1`, `lib/public_key`, `lib/ssh`, `lib/ssl` and
`lib/inets` are imported into `otp/` from the same OTP 29.1.2 archive as
the rest, as erXos's code, with the test suites of `crypto`,
`public_key`, `ssh`, `ssl` and `inets` as fixtures. The import leaves out what the build neither reads nor
ships, each part with its reason in `config/imports/otp.json` and
`otp/ORIGIN.md`: their documentation and examples, which go by one rule
for the whole of OTP's tree (every `doc`, `examples` and `internal_doc`
entry, but the files the build reads from beneath one: the Markdown
that `-moduledoc` and `-doc` attributes take by `{file, ...}` and
`stdlib`'s `erl_id_trans`), their prebuilt beams, the
Erlang the ASN.1 compiler generated from `public_key`'s specifications,
and all of `asn1` but its run-time module `asn1rt_nif`, its NIF and the
files its make reads to build them, so the ASN.1 compiler, its test
suites and its examples stay out. The ASN.1 compiler that generates
`public_key`'s modules on the host is the stock oracle's, a build tool
as its `erlc` is, so a copy in the tree would be one nothing builds or
runs. Each ships its beams, `.app` and headers, as the other shipped
applications do
([design-runtime.md](design-runtime.md#everything-else)), in releases that
ask for them; the system release never does.

* **`crypto`** takes one edit: `sae_pt/3`, `sae_commit/5` and
  `sae_key/5` on `secp256r1`, each a whole secret-dependent step of
  WiFi's SAE, so no secret of the exchange becomes an Erlang integer,
  over OpenSSL's `EC_POINT_mul`, `EC_POINT_add` and BIGNUM with every
  point decoded and checked by `EC_POINT_oct2point`; their additions and
  field arithmetic are not yet constant-time, a residual WiFi records
  ([design-wifi.md](design-wifi.md#otps-crypto-saes-arithmetic)).
  Its NIF is built as `crypto.a` against
  `openssl/`'s `libcrypto.a` and linked into the interpreter and BeamAsm
  images. Its `on_load` finds the NIF in the static table.
* **`asn1`** ships its run-time module `asn1rt_nif`, which
  `public_key`'s generated decoders call, and none of the ASN.1 compiler,
  which runs at build time on the host to generate `public_key`'s modules.
* **`public_key`** takes one edit: `pubkey_os_cacerts:load/0` gains a
  row for `{unix, erxos}`, which loads `cacerts.pem` of `public_key`'s
  `priv` directory, the image's trust store
  ([The trust store](#the-trust-store)). `cacerts_get/0`, its
  `cacerts_path` override and every caller of them are unchanged.
* **`ssh`** takes the edits of [design-ssh.md](design-ssh.md#edits-to-otps-ssh).
* **`ssl`** is unchanged: the web domain's TLS listener uses it
  ([design-web.md](design-web.md#the-network-front-end)), and every HTTPS
  client ([HTTPS clients](#https-clients)).
* **`inets`** ships its HTTP client, `httpc`, and with it the rest of the
  application as OTP builds it; its HTTP server, `httpd`, is part of the
  application and nothing starts it. It takes one edit: **every byte of
  a response is counted where it enters the handler**, so the two limits
  hold for every path the parsers take (CR8):
  * `httpc_handler`'s receive of socket data (`httpc_handler.erl:499`)
    passes each segment's size to `httpc_bound`, a pure module added to
    the application, before any parser sees it. `httpc_bound:take(Count,
    Bytes, Limits)` answers the new count or the error the request ends
    with. The count starts at zero with each response.
  * While the response's head, its status line and headers, is
    unfinished, every byte taken is the head's. When a segment arrives
    and the head's count before it is already above `max_header_size`,
    the request ends with `{error, {header_too_long, {max, Max}}}`
    without the segment being parsed. This one
    rule covers the status line, the reason phrase, every header branch
    and every continuation, so none of the parsers' own counts has to be
    complete; a head can hold at most `max_header_size` and one segment.
  * When the head ends (`handle_http_msg`, `httpc_handler.erl:927-947`),
    the count restarts at the bytes after it in that segment, the body's
    first fragment, and every later segment adds to it. Once it passes
    `max_body_size`, before the bytes are kept, decoded or delivered, the
    request ends with `{error, body_too_big}`. The count is of bytes as
    they arrive, chunk framing included, so it bounds a body framed by
    `content-length`, by chunks or by the connection's end alike, and an
    overflow has one error in every framing; a chunked body whose decoded
    size fits but whose framing does not is refused, which only a server
    sending chunks of a few bytes meets.

  A request with `nolimit` for either limit, or none for
  `max_body_size`, is unbounded there as on stock OTP, and its domain's
  memory is the bound. The chunked overflow's error, `body_too_big`
  where stock OTP answers `{body_too_long, {max, Max}}`, is a documented
  difference with its own test (below).

The oracle's stock OTP 29.1.2 builds `crypto` on the development host
against the same OpenSSL 3.5.9 with the same options, the target and the
three edits aside, so `crypto:supports/0` agrees on both sides and a
difference between them is erXos's
([design-host-oracle.md](design-host-oracle.md)). The three SAE
functions exist on erXos alone; OTP's suites do not call them, and their
own tests check them against Annex J.10's vectors and each other.

### HTTPS clients

The construction is that **the trust store is one file of the domain
release, and stock OTP's defaults do the rest.** `public_key:cacerts_get/0`
reads that file through `public_key`'s `{unix, erxos}` row; `ssl`'s
client defaults take it when a caller names it, and `httpc`'s default
`ssl` options name it. So an `httpc` request that names no TLS option
gets the image's roots, the host name check and TLS 1.3 or 1.2, with no
erXos module between it and OTP:

```erlang
{ok, _} = application:ensure_all_started(ssl),
{ok, _} = application:ensure_all_started(inets),
{ok, {{_, 200, _}, _Headers, Body}} =
    httpc:request(get, {"https://api.kraken.com/0/public/Ticker?pair=XBTUSD", []},
                  [{timeout, 20000}, {autoredirect, false}, {autoretry, 0}],
                  [{body_format, binary}, {max_body_size, 65536}]).
```

`inets` does not name `ssl` among its applications, so a program starts
both, or names both in its own `.app`. The limits are options of the
fourth argument; `autoredirect` is off because a redirect may lead to
plain `http`, and `autoretry` off because the program, not `httpc`,
should decide when to ask again. A direct `ssl` client names the store:

```erlang
ssl:connect(Host, 443, [{cacerts, public_key:cacerts_get()}], 10000)
```

What this removes: an HTTP or TLS client of erXos's own with an API
programs must learn; a certificate path every caller must name; a trust
setting per app. A caller that names `ssl` options of its own and leaves
out `cacerts`, or calls `ssl:connect/3` without it, is refused before it
connects (`ssl_config.erl:942-955`), so forgetting the store fails
closed.

Each requirement follows:

* **CR6** is `ssl`'s and `httpc`'s defaults as the sources state them
  ([Context](#context)), over the store below; a direct `ssl` client
  names the store, as above. What a caller can still
  weaken, it weakens for its own connections in its own domain alone:
  `{verify, verify_none}`, `versions` naming `tlsv1.1`,
  `{server_name_indication, disable}`, a `customize_hostname_check` of
  its own. No client erXos writes names any of them.
* **CR7** holds because the store is a file of the domain release, which
  every domain reads from its slice of the boot image or from an EROFS
  image under its hash tree, and none can write
  ([design-runtime.md](design-runtime.md#everything-else)). A domain's
  code may trust other roots for its own connections, by naming
  `cacerts` or by `public_key:cacerts_load/1` into its own persistent
  term; no other domain sees it.
* **CR8** is `inets`' edit ([OTP's applications](#otps-applications)),
  for a request that gives the limits in its fourth argument.

#### Releases

`ssl`, which needs `crypto`'s NIF, and `inets` join `asn1`, `crypto`,
`public_key` and `ssh` among the applications that only domains' boot
scripts hold, and the scripts that load those load these too: the
`session` script, so a
person's session can use them and fetch with them, and the `app` script
of [design-packaging.md](design-packaging.md#the-apps-row), so an app
can; the web domain's script holds `ssl` for its listener. A script only
loads them, as it loads `ssh` (`tools/lib/erx/release_files.rb`,
`RELEASE_SCRIPTS`): an app whose `.app` names `ssl` and `inets` among its
applications has them started by `erx_app`'s
`application:ensure_all_started/2`
([design-packaging.md](design-packaging.md#starting-an-app)), and code in
a session starts them when it calls them. The system release never
holds them, and could not run `ssl`: its image has no `crypto` NIF (K1).

#### The trust store

| Root | Needed by | Publisher |
| --- | --- | --- |
| GTS Root R4 | Kraken and Coinbase: a leaf from Google Trust Services' WE1 | Google Trust Services |
| GlobalSign Root CA | the same chains, which carry GTS Root R4 cross-signed by it, for a validator that ends the path there | GlobalSign |
| ISRG Root X1 | Cboe: Let's Encrypt's YE1, Root YE, ISRG Root X2 cross-signed by X1 | Internet Security Research Group |
| ISRG Root X2 | the same chain, ending at X2 | Internet Security Research Group |
| DigiCert Global Root G3 | FRED: DigiCert Global G3 TLS ECC SHA384 2020 CA1 | DigiCert |

The chains are those the servers sent to a live request
([design-quotes.md](design-quotes.md#what-the-sources-offer)). Which of
two anchors of one chain OTP's path validation ends at is not relied on:
the store holds both.

* **Where it is kept.** Each root is one file, `config/trust/NAME.pem`,
  imported from its publisher's own repository over HTTPS, with
  `config/trust/ORIGIN.md` recording for each the URL, the SHA-256 of
  the file as fetched, the certificate's SHA-256 fingerprint and the
  sources that need it, as for every import erXos ships
  ([design.md](design.md#dependencies)). A root enters, leaves or is
  replaced by a reviewed commit.
* **How it reaches a machine.** The build joins the files in name order
  into `cacerts.pem` in `public_key`'s `priv` directory of the domain
  release, a generated file that is not checked in. Its reader takes each
  file whole and refuses, naming the file, one that is longer than
  8 KiB, is not ASCII, or holds anything but exactly one `CERTIFICATE`
  block of PEM's base64 and blank lines. So an image's store is exactly
  the tree's roots, and it changes on a machine only with the image,
  through the update that replaces the image.
* **A test image adds roots.** A suite's image plan may name more root
  files, which the build joins after the tree's; the production image
  takes none, so no test root reaches an image erXos distributes.
* **No run-time change.** No command adds or removes a root on a running
  machine; a program that must trust another root names it for its own
  connections.

Revocation is not checked: `ssl`'s `crl_check` is `false` and its
`stapling` `no_staple` by default (`ssl_config.erl:1527`,
`ssl_internal.hrl:197`), and no client erXos writes changes them, so a
revoked certificate is accepted until it expires.
The leaves of the sources above live about 90 days.

#### Time

Validation reads the wall clock, so it is as right as the clock. The
clock's state is `/proc/time/status`'s `state`: `unset`, `boot` or `set`
([design-time.md](design-time.md#what-proc-shows)).

| Machine | Wall clock at boot |
| --- | --- |
| QEMU `virt` on erXos's kernel | the PL031's reading, which the kernel takes once at boot ([design-kernel.md](design-kernel.md), "Time"), so `state` is `boot`. QEMU starts its real-time clock at the host's time unless `-rtc base=` says otherwise (unverified: QEMU's documentation was not read); deterministic mode starts it at 2026-01-01 ([design-fiasco.md](design-fiasco.md#deterministic-mode)) |
| Fiasco, on QEMU `virt` | the PL031's reading, which Fiasco's root takes once at boot into the time page, as erXos's kernel does, so `state` is `boot`, and QEMU's clock starts as in the row above |
| Fiasco, on the Raspberry Pi 4 without a module | 1970-01-01, `unset`: the board has no real-time clock and nothing sets the clock ([design-time.md](design-time.md#phase-1)) |
| the Raspberry Pi 4 with a DS3231 module | the module's time, read at `/dev/rtc/time` by the system domain's wall-clock keeper ([design-header-io.md](design-header-io.md#devrtc)), so `state` is `set` |
| any machine running `ntpd` | set by the first sample ([design-time.md](design-time.md)); off unless enabled |
| hosted mode | the host's clock, `boot` |

Fiasco's root reads the PL031 because that gives the time page the value the kernel interface promises and touches nothing above it. The Raspberry Pi 4 gets its time from a DS3231 module and the wall-clock keeper, since the board has no clock of its own. `ntpd` is designed and off unless an operator enables it with a server of their own.

**What an unset clock does.** Validation compares each certificate's
validity period with the wall clock as it reads; it never reads the
clock's `state` (`pubkey_cert.erl:177-189`). On an unset clock the wall
clock reads 1970 plus the uptime, so a chain is accepted only if every
certificate in it was valid then. Certificates from public authorities
are not: the leaves the sources sent were issued within their 90-day
lifetimes, so `ssl` refuses their chains with `certificate_expired` and
the connection fails. A certificate made to be valid from 1970, as a
test may make, is accepted on an unset clock as on a set one; erXos adds
no rule that refuses every connection while the clock is unset. No
client skips the validity check, and nothing sets the clock from a TLS
peer's time. A client that shows the failure to a person can tell an
unset clock from the wall clock alone: no machine erXos runs on reads a
time before 2000 once its clock is set, and the live quotes show
`clock not set` when a certificate is refused as outside its validity
while the wall clock reads before 2000
([design-quotes.md](design-quotes.md#refusals-and-error-results)).

#### Reaching the network

An app reaches the network domain through the facets that exist. Its
declaration says `needs net`; admission keeps the `apps` row's `net`
facet row for it ([design-packaging.md](design-packaging.md#the-apps-row));
when its session starts, the system domain introduces the network domain
to it, the network service mints the session's `erx_net_grant`, and the
session installs it as `net`
([design-network-stack.md](design-network-stack.md#the-grant)). The app
template's arguments set `erx_net_client`'s `grant` key as a session
template's do. `ssl` runs over `gen_tcp`, which runs over the grant, and
`httpc` resolves names with `inet_res` over the grant's name servers,
which `erx_inet` loads into `inet_db`
([design-network-stack.md](design-network-stack.md#name-resolution)). No
facet, protocol or service is added; IPv4 is what `erx_gen_udp` carries
for the resolver.

## Invariants

| Invariant | Holds because |
| --- | --- |
| **K1.** The system domain holds no OpenSSL | its image's link names neither `libcrypto.a` nor a NIF archive or table of `crypto` or `asn1rt_nif`; the list's shape holds it, and a host test of the list pins that shape (below) |
| **K2.** OpenSSL's only seed is `erx_entropy_read` | `getrandom` is the only seed method compiled in, `syscall_random` calls it directly, and the seam's row reads nothing else |
| **K3.** A failed seed never yields bytes | the seam answers `EIO` and OpenSSL's unseeded generator refuses |
| **K4.** CPU features come from the kernel's report | `armcap.c`'s edit compiles `getauxval` and no `SIGILL` probe; its one read of the CPU, the main ID register, runs only when the feature words claim `HWCAP_CPUID`, which the kernel's never do (`liberx/backend/core/arch/aarch64/cpu_features.c`, `test/host/cpu_features_test.rb`) |
| **K5.** OpenSSL loads no code, and reads no file unless a caller names one | `no-shared`, `no-module`, `no-dso` and `no-engine` leave no loader; `no-autoload-config` reads no configuration file at start. OpenSSL's file functions (`BIO_new_file`, the configuration and store loaders) stay compiled and run only on a path a caller passes, and `crypto`'s NIF passes none |
| **K6.** An `httpc` request that names no TLS option verifies the server against the image's store and its host name, over TLS 1.3 or 1.2 | `httpc`'s default `ssl` options, `ssl`'s defaults, and `cacerts_get/0`'s `{unix, erxos}` row; a client, `httpc`'s or a direct `ssl` one, that names options without `cacerts` is refused before connecting |
| **K7.** Every domain's store is the image's, unchangeable by any domain | the store is a file of the domain release, read from the boot image's checked slice or a hash-checked EROFS image; its build joins only `config/trust/` and a suite's named roots |
| **K8.** `httpc` holds at most `max_header_size` and one segment of a head, and at most `max_body_size` of a body | every segment of a response passes `httpc_bound` in the handler's receive before a parser sees it, the head's count while the head is unfinished and the body's from the first byte after it |

## Failure handling

| Failure | Seen as | Result |
| --- | --- | --- |
| the kernel's generator does not answer (the stopgap's generator service down) | `getrandom` fails with `EIO` | OpenSSL's generator stays unseeded, or fails its next reseed; `crypto:strong_rand_bytes/1` raises; the caller's operation fails and is retried by its own supervisor |
| a weak seed on a development build | the banner's `entropy_quality` | keys work and are as weak as the seed; a release build never boots so |
| a domain's environment sets `OPENSSL_armcap` | slower or software code paths, or a fault at the first use of an instruction the CPU lacks | that domain's own cryptography only; a fault ends that domain |
| a `crypto` beam in the system release | `on_load` fails: no static NIF `crypto` | the system release does not boot; the build's release check refuses it first |
| the imported tree lacks a directory `Configure` reads | `Configure` fails in the build and in `make check-openssl` | the build fails, naming the `build.info` it could not open |
| the wall clock is unset, or wrong by more than a certificate's validity | `ssl` refuses the chain with `certificate_expired` | the connection fails; a client that shows it says the clock is not set when the wall clock reads before 2000 |
| a server's chain ends at no root of the store, or its certificate does not name the host | `unknown_ca`, or `bad_certificate` | the connection fails; the image's store is unchanged |
| a file of `config/trust/` is not one PEM certificate | the build's reader | the build fails, naming the file |
| the store is missing from the domain release | `cacerts_get/0` raises `failed_load_cacerts` | every verifying client fails before connecting; the store's QEMU test fails on it (below) |
| a server sends more body than `max_body_size`, in any framing | `{error, body_too_big}` | that request fails; the connection is closed |
| a server sends a head longer than `max_header_size`, in its status line, reason phrase or headers | `{error, {header_too_long, {max, Max}}}` | that request fails; the connection is closed |

## Security

* **What OpenSSL's code can reach** is the memory and capabilities of the
  domain it runs in, as any code there can. Which domains load it, and so
  what a defect in it exposes, is each user's design: the web domain's
  connections, the vault's keys
  ([design-system.md](design-system.md#the-vault)), the SSH domain's
  connections ([design-ssh.md](design-ssh.md#security)). It never runs in
  the system domain, so no defect of it reaches the domain library, the
  manifest's policy or the machine's end.
* **No code is made.** OpenSSL makes no machine code at run time; in the
  BeamAsm image it runs beside the JIT under the same rule, that no
  mapping is writable and executable at once.
* **What reaches OpenSSL from outside** is what `crypto`'s NIF passes it:
  key material and data that OTP's Erlang code has already decoded and
  bounded. OTP's own parsers (`public_key`'s key and certificate decoders,
  `asn1rt_nif`'s BER reader, `ssh`'s message decoders) are OTP's, kept as
  OTP ships them, and tested by OTP's suites against the oracle.
* **TLS clients' defaults** are verification, the host name check and
  TLS 1.3 or 1.2 (CR6, K6). A program weakens them only for its own
  connections; a domain's weak client harms that domain alone. Plain
  `http` stays available to `httpc`, and `autoredirect`, on by default,
  follows a redirect wherever it points, to plain `http` or to another
  host, this machine's listeners included; so the example above turns it
  off, and a client whose answers must come from the host it named
  follows redirects itself, as the live quotes do, within the same
  origin ([design-quotes.md](design-quotes.md#one-request)).
* **Response size.** `inets`' edit bounds what a server can make `httpc`
  hold, head and body, at the one place every byte enters (K8), for a
  request that gives its limits in the fourth argument; a request that
  gives none is bounded by its domain's memory.
* **The store's integrity** is the release's: no domain writes a release
  file, the boot image's slices are checked at boot, and an EROFS image's
  blocks against its hash tree as they are read
  ([design-runtime.md](design-runtime.md#everything-else)). Whoever can change
  `config/trust/` or a suite's image plan chooses whom every client
  trusts, so a change there is reviewed as security code. Five roots
  bound the set of authorities any client trusts to those five and the
  CAs they certify.
* **Revocation and time.** No revocation is checked, and validity is as
  right as the clock: a clock set by an attacker on the path of
  unauthenticated network time can make an expired certificate valid
  again ([design-time.md](design-time.md#security)); an unset clock
  makes every certificate from a public authority invalid, which fails
  closed ([Time](#time)).
* **What a holder of `net` can reach.** A session or app with the grant
  reaches every address the stack routes to: the internet, the local
  network, and this machine's own addresses through loopback, where the
  listeners of other domains lie (the web front end, the SSH domain, the
  port mapper on 4,369 and the distribution ports of exposed domains,
  and other apps' listeners); and, under a grant's default limits, it
  may listen on any port above 1,023 of every local address
  ([design-network-stack.md](design-network-stack.md#the-grant)). What
  those listeners give a peer is each one's own: the port mapper answers
  any peer's lookups and name lists and takes registrations only through
  grants
  ([design-network-stack.md](design-network-stack.md#distribution-to-other-machines)),
  the web front end and SSH authenticate a person before granting
  anything, and an app's listener answers whom its author lets it. The
  grant's limits can
  narrow binding and listening, not the remote addresses a socket may
  reach ([Risks and open questions](#risks-and-open-questions), 3).
* **DNS is unauthenticated.** An on-path attacker can answer a name with
  any address; the TLS check then fails, so the attacker can withhold an
  answer but not substitute one.

## Verification

Each test names the seeded failure that proves it ran.

| Test | Passes when | Seeded failure |
| --- | --- | --- |
| `crypto_SUITE`, `public_key_SUITE` and `pubkey_*_SUITE`, whose decoders call `asn1rt_nif`, through `make check-oracle` | every case agrees with stock OTP 29.1.2 built against the same OpenSSL | erXos's OpenSSL configured with `no-chacha`: the ChaCha20 cases differ from the oracle and the comparison fails |
| the system image's link list, a host test (`test/host/native_runtime_link_test.rb`) | the system image's link list (`NativeRuntime::Built#system_archives`) names its own static NIF table once and no `libcrypto.a`, `crypto.a`, `asn1rt_nif.a` or `crypto`'s table; each domain image's names `crypto`'s table and not the system image's | stand-ins of `libbeam.a` and the two tables, linked from the list as an image is: with `crypto`'s table added the link fails on a duplicate symbol, and with the system table taken out on an undefined one; a list that takes `crypto`'s archives fails the test |
| the import's configure check, `make check-openssl` | `Configure` with erXos's options succeeds on the imported tree and the build makes `libcrypto.a` | `ssl/build.info` left out of the import: `Configure` fails |
| the seam's `getrandom` row, a host unit test of the seam | 1, 256, 257 and 4,096 bytes come back whole, from 1, 1, 2 and 16 reads of a stub generator; a stub failure on the second piece returns `-EIO` | the row returns the bytes read so far on a failure: the test fails on the short count |
| first seeding on QEMU | `crypto:strong_rand_bytes(32)` returns 32 bytes in a fresh domain of the interpreter image and in one of the BeamAsm image; in a domain of each started with the backend's generator made to fail by the test image's hook, so that its first seed fails, the first call raises, and in the SSH domain so made a key exchange fails | the seam falls back to zeros on failure: the call returns and the test fails |
| OpenSSL's start on QEMU | a domain that loads `crypto` starts on a CPU model with the cryptographic extension and on one without (`-cpu cortex-a72` under TCG), and AES-256-GCM vectors pass on both | `armcap.c` built without its edit: the probe's `SIGILL` ends the domain at load and the test fails |
| known-answer vectors | AES-GCM, ChaCha20-Poly1305, X25519, Ed25519 and ML-KEM-768 vectors from their specifications through `crypto` on QEMU | one vector's expected tag changed: the test fails |
| `ssl`'s suites and `inets`' `httpc_SUITE` through `make check-oracle` | every case agrees with stock OTP 29.1.2, but those whose answer `inets`' edit changes, a chunked overflow's error and the bounds it adds, each a documented difference with a test below | erXos's `ssl` built with `?ALL_SUPPORTED_VERSIONS` cut to `tlsv1.3`: the TLS 1.2 cases differ from the oracle |
| the store's reader, a host test | the store the build writes from `config/trust/` is its files joined in name order, and stock OTP's `public_key:pem_decode/1` reads from it one self-signed CA certificate per file; a fixture directory holding a file of two certificates, one holding a private key and one of 9 KiB is refused, naming each file | a reader that takes a file's first block accepts the two-certificate file |
| the store on QEMU | in a session of the interpreter image, `public_key:cacerts_get/0` returns one certificate per file of `config/trust/`, and the quotes cell connects through it ([design-quotes.md](design-quotes.md#verification-and-testing)) | `public_key` built without its `{unix, erxos}` row: the call raises `failed_load_cacerts` |
| `httpc_bound`, EUnit | a head whose count is exactly `max_header_size` takes the next segment, and one whose count is a byte more refuses it; a body's count of exactly `max_body_size`, the arriving segment included, is accepted and one byte more refused; `nolimit` refuses nothing | comparing the head's count with `>=` refuses the head whose count is exactly `max_header_size` |

**`inets`' bounds against a server.** EUnit cases with erXos's `inets`
beams ahead of stock OTP's; a server on the host's loopback answers each
request, and each case makes it with the request expression of the
example above, limits in the fourth argument, `max_header_size` 1,024
and `max_body_size` 4,096. The server counts what it writes, and a case
that expects an error also expects the client to close before the
server has written 4 MiB, so a client that kept reading fails it.

| Case | Passes when | Seeded failure |
| --- | --- | --- |
| `content-length` | a body of 4,096 bytes arrives; one of 4,097 gives `{error, body_too_big}` | the limit placed in the third argument, as an HTTP option: the 4,097-byte body arrives |
| chunked | a body of 4,000 bytes in two chunks arrives; one of 4,097 bytes in chunks of 1,000 gives `{error, body_too_big}`, the same error as the other framings | the edit taken out: the error is `{body_too_long, {max, 4096}}` |
| ending with the connection | a body of 4,096 bytes then the close arrives; an endless body gives `{error, body_too_big}` | the edit taken out: the client reads to the 4 MiB cap |
| first fragment | headers and a 5,000-byte body in one segment, then the close at once, give `{error, body_too_big}` | the body's count started at the next segment: the body arrives |
| endless reason phrase | `HTTP/1.1 200 ` and reason bytes with no line end give `{error, {header_too_long, {max, 1024}}}` | the edit taken out: the client reads to the cap |
| endless short lines | a status line, then `\r\nA` repeated, gives `{error, {header_too_long, {max, 1024}}}` | the edit taken out: the client reads to the cap |

**`erx_httpc_response_fuzz`**, run by `make check-fuzz`, serves
generated responses over the host's loopback to `httpc` as the cases
above call it: status lines and reason phrases of every length, headers
within and past 1,024 bytes, line breaks of `\r\n`, `\n` and a bare
`\r`, bodies framed by `content-length`, by chunks with extensions and
trailers, and by the connection's end, some endless, each written in
segments split at random. Properties: every request ends, before the
server has written 4 MiB, with a status and a body of at most 4,096
bytes or with one of the errors `httpc` documents; nothing in the
client raises. *Seeded failure:* the head's count taken out of the
receive lets an endless reason phrase run to the cap.

The first-seeding test makes the generator fail before the domain's
first call, since an already seeded generator need not read the kernel
again before its reseed. OpenSSL's own test suite is not run on erXos:
OTP's suites exercise exactly what `crypto` calls, against an oracle,
which OpenSSL's tests do not.

## Dependencies

* OpenSSL 3.5.9, Apache-2.0, permanent, imported into `openssl/`
  ([design.md](design.md#dependencies)).
* OTP 29.1.2's `crypto`, `asn1`, `public_key`, `ssh`, `ssl` and `inets`,
  Apache-2.0, part of the imported OTP.
* The trust store's five root certificates, from their publishers,
  imported into `config/trust/` with an origin file
  ([design.md](design.md#dependencies)). They need no license: a root
  certificate is a public key and a name, facts and not a creative work.
* Perl on the build host, for OpenSSL's `Configure` and assembler
  generators, as OTP's build already needs.

## Alternatives considered

* **OpenSSL in both of two images, never loaded by the system release.**
  Rejected: OpenSSL's constructors run in every process that maps it
  (`armcap.c:65-67`), so the library would run in the system domain, and
  keeping it from being called would be a rule about what the system
  release loads rather than a fact of its image.
* **A fourth image, BeamAsm without OpenSSL, for the network domain.** Not
  adopted: one more link of ERTS and one more image file, whose text no
  other domain shares with the network domain, to keep from the network
  domain a library that nothing there calls
  ([Domains that call no OpenSSL](#domains-that-call-no-openssl)).
* **The network domain on the system image.** Rejected: the interpreter
  is up to four times slower than BeamAsm
  ([design-runtime.md](design-runtime.md#one-mechanism-per-job)) on the
  domain that handles every packet.
* **`crypto` in the BeamAsm image only.** Rejected: deterministic mode
  and command domains run the interpreter image, so the web domain's TLS
  and every SSH session would fail in deterministic mode, and a command
  could not use `crypto`.
* **A loadable NIF library.** Rejected: ERTS on erXos links NIFs
  statically, and mapping a library into a runtime would be a second
  loader beside `liberx`'s.
* **Fetching OpenSSL unchanged and setting `OPENSSL_armcap` in every
  domain's environment.** Rejected: an environment variable every domain
  must carry is a rule each specification must remember, and the seed
  path would still end in `ENOSYS`; the edits make the feature words
  and the seam's row the only inputs.
* **Keeping the weak `getentropy` and forcing musl's `getentropy.o` into
  the link** with `-u getentropy`. Rejected: a link flag every image must
  remember for a library call, and musl's 256-byte bound would then sit
  on OpenSSL's path.
* **The library's sources alone, with OpenSSL's build files edited to
  match.** Rejected: edits to the top-level `build.info` and `Configure`
  are inherited build machinery changed for a smaller tree, to save
  directories the build reads but never compiles.
* **BoringSSL, LibreSSL or a smaller library.** Rejected by the existing
  decision: OTP's `crypto` is written against OpenSSL, and 3.5 is
  supported until 2030 ([research](research-boards-storage.md#cryptography-libraries)).
* **An HTTP client of erXos's own**, a few hundred lines of GET over
  `ssl`. Rejected: its consumers, the live quotes, a command that
  fetches packages in a person's session
  ([design-packaging.md](design-packaging.md#requirements)) and
  third-party Erlang code written against stock OTP, which the SDK makes
  public, are all served by `httpc`; a client of our own would be a
  second API for app authors, a second response parser with a fuzz target
  of its own, and code to maintain, to save beams that only the releases
  loading `inets` carry. `httpc`'s one gap for untrusted servers, the
  unbounded body that ends with the connection, is one edit.
* **The store at `/etc/ssl/cert.pem`**, the path `public_key` tries
  first on FreeBSD. Not adopted: a session's `/etc` is its export's own
  names and, for a session holding `start`, the `etc` tree
  ([design-apps.md](design-apps.md#the-start-table)), so the store there
  would be one more name in every session's export, while only Erlang
  code reads it and `public_key`'s `priv` directory serves it with no new
  name.
* **A wrapper module that sets erXos's TLS options.** Rejected: `ssl`'s
  and `httpc`'s defaults already are those options, and a wrapper is a
  call every client must remember to make.
* **Removing TLS 1.1 and 1.0 from `ssl`.** Not adopted: neither is
  offered unless a caller names it, and a caller that does weakens only
  its own connections; the edit would make every oracle case that names
  them differ.
* **The store as a generated Erlang module of DER binaries.** Not
  adopted: `public_key`'s loader already reads a PEM file, which a person
  can also read.

## Risks and open questions

* **Three images.** The system domain's image is a file of its own, one
  more link of the interpreter build and one more file in the boot image;
  it is what makes K1 a fact of the image
  ([design-runtime.md](design-runtime.md#beamasm)).
* **`no-legacy`.** It removes algorithms some stock OTP users call
  through `crypto`, so programs that use them fail on erXos and on the
  oracle alike; SSH, TLS and the vault use none of them.
* **OpenSSL mapped where nothing calls it.** The network domain, and any
  domain whose release has no `crypto`, maps OpenSSL and runs its
  constructor, which reads the feature words and nothing else; the
  network stack's build check keeps its packets from the library
  ([Domains that call no OpenSSL](#domains-that-call-no-openssl)).
* **The cost of `crypto` in the interpreter image**, its size and AES's
  speed without the cryptographic extension on the Pi 4, is on the watch
  list ([todo-performance.md](todo-performance.md)),
  settled by `tools/erx bench` numbers for SSH's bulk transfer.
* **`ssl` and `inets` in every session and app.** The `session` and
  `app` scripts load them in every such domain, whether it fetches
  anything or not; what that costs a session's memory and start is on
  the watch list ([todo-performance.md](todo-performance.md)).

The decisions below are open:

1. **Which roots.** The store holds the five roots its consumers need.
   The alternative is the root set of Mozilla's root program, which
   serves any public HTTPS server; it is distributed in NSS as
   `certdata.txt`, under MPL-2.0, a file-level copyleft license, with
   trust bits a converter would read (unverified: neither the file nor
   its license was read for this design). *Recommendation:* the explicit list,
   which bounds whom every client trusts; take Mozilla's set when a
   general fetcher needs it, if MPL-2.0 is accepted for that data.
2. **How far an app's `net` reaches.** The `apps` row's `net` gives every
   app that names it the grant's defaults: any remote address, this
   machine's listeners included, and listening on any port above 1,023
   ([Security](#security)). The options: (a) that; (b) an app
   principal's policy with `listen` `false`, a limit the grant has, so an
   app is a client only, and the quotes cell's fixture runs in a
   configured test domain instead of an app; (c) a limit on remote
   addresses, which the grant does not have and the network stack's
   design would add. *Recommendation:* (a): an administrator installs
   every app, the machine's privileged listeners authenticate a person
   before granting anything and the port mapper answers only public
   lookups, and narrowing per app needs a choice the declaration deliberately does not
   carry.

## Sources

* OTP 29.1.2 source archive, `otp-c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049.tar.gz`,
  SHA-256 `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`
  (the pin in `otp/ORIGIN.md`): `erts/emulator/Makefile.in`,
  `make/configure.ac`, `lib/crypto/c_src/openssl_config.h`,
  `lib/crypto/c_src/rand.c`; `crypto` 5.10 (`lib/crypto/vsn.mk`).
  For the HTTPS clients: `lib/ssl/src/ssl_config.erl`,
  `ssl_internal.hrl`, `tls_record.erl`, `ssl_certificate.erl`,
  `ssl_handshake.erl`, `ssl.erl` (`ssl` 11.7.8);
  `lib/public_key/src/public_key.erl`, `pubkey_os_cacerts.erl`,
  `pubkey_cert.erl` (`public_key` 1.21.8);
  `lib/inets/src/http_client/httpc.erl`, `httpc_handler.erl`,
  `httpc_response.erl`, `lib/inets/src/http_lib/http_chunk.erl`,
  `http_internal.hrl` (`inets` 9.8.1); `lib/stdlib/src/json.erl`.
* OpenSSL 3.5.9, `https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz`,
  SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`,
  matching the release's published `.sha256`: `INSTALL.md`,
  `providers/implementations/rands/seeding/rand_unix.c`,
  `crypto/armcap.c`, `Configurations/10-main.conf`, `Configure`,
  `build.info`.
* LLVM 21.1.8, `https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-21.1.8/lld/ELF/Symbols.cpp`,
  SHA-256 `0fa29d79990534b8c3a174356f2492b4c5610e0e88b59f66770c4042c8d2509b`.
* musl 1.2.6 in the tree: `src/misc/getentropy.c`,
  `src/linux/getrandom.c`; erXos's seam
  `musl/src/internal/erxos/syscall.c`; `tools/lib/erx/musl.rb`.
