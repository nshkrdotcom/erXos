# Generated interfaces and representations

Ruby generators turn erXos's interface declarations into readable C17,
Erlang, Ruby, TypeScript for the web client
([design-web.md](design-web.md#the-client)), and reference tables. A fact shared across languages or
consumers is declared once: its names, types, bounds, identifiers and
representations are derived together. Policy, resource admission,
ownership transitions and recovery decisions remain handwritten pure
cores under [Protocol verification](design-verification.md).

This document owns the generation rules. The subsystem designs own the
meaning of their interfaces. Generated reference sections describe the
declarations; architectural explanations and their rationale remain
handwritten in those designs.

## Sources and outputs

`abi/erx_abi.txt` is the root of the architecture-neutral declarations.
It explicitly includes `abi/inspection.txt` and `abi/services/<name>.txt`
as fragments of one declaration model, with shared types and
identifiers declared only once. These fragments hold inspection records
and service operations. Existing ABI and inspection version fields remain
declared in that model; splitting files introduces no new format or version.
Includes stay within `abi/`, have no cycles and resolve to a unique
definition of every qualified name.
Operations are qualified by service; generated names include that service,
so two services can both declare `read` without sharing an operation id.
The architecture file adds only architecture-specific declarations.
Device registers and terminal character classes keep sources of their
own ([Hardware and terminal sources](#hardware-and-terminal-sources)).

What each declaration file under `abi/` holds; the subsystem designs own
the meaning of what it declares, and the declaration language is
[design-abi.md](design-abi.md)'s:

| File | Holds |
| --- | --- |
| `erx_abi.txt` | the root: the ABI version and includes, status codes, the fault table, the boot formats (pack, boot locator, image manifest), the calls declared so far and the other layouts shared across languages |
| `kernel.txt` | rights, object types and creation kinds, root slots and reserved capability values, the crash record, and the kernel-visible layouts shared with runtimes and tooling |
| `arch/<arch>.txt` | the architecture binding: trap, call registers and hardware layouts |
| `inspection.txt` | the inspection schema: kinds, attributes, paths, units and backend reporters |
| `services/*.txt` | one interface each: operations, liveness, how it is served and its manifest parameters |
| `manifest.txt` | the system manifest's records and reader |
| `medium.txt` | the boot medium's partition layout, in sectors |
| `signals.txt`, `errno.txt`, `termios.txt` | the signal, errno and termios tables musl's headers and the protocols take their numbers from |
| `terminal.txt` | the character classes of the line and field escapes |
| `theme.txt` | the desktop's visual facts |
| `keymaps/*.txt` | keyboard layouts over evdev's key codes |
| `formats/*.txt` | binary formats: on-disk and on-wire records (EROFS, F2FS, MBR, ELF, virtio, USB, HID, IEEE 802.11 and others), the widget format, draw messages, input records, subfonts and packages |
| `protocols/*.txt` | frame and codec profiles: 9P2000.L, the program protocol, the host link and the web protocol |

| Source | Generated outputs | Contract owner |
| --- | --- | --- |
| ABI calls, layouts, rights, limits and architecture binding | C headers and accessors, call stubs for every backend, decoders, Erlang/Ruby representations, field offsets and sizes, compile-time layout assertions | [kernel](design-kernel.md#the-abi-file) |
| Service operation fragments | client stubs, server behaviour declarations and dispatch, bounded request and reply validation, operation identifiers, scoped-handle helpers, error types and reference tables | [domains](design-domains.md#authority) |
| Inspection fragment | C record builders, Erlang types and `erx_schema`, Ruby types and validators, path/field descriptors, shell/host renderers and `/proc` projections; from the `present` marks, `erx_present`'s `text/2`, `parse/2`, `path/2`, `uri/2`, `parse_uri/1`, `type/1` and `marks/0`; for the web client, the kinds, attribute names, units, backend reporters and `present` marks in TypeScript | [live machine](design-live.md#inspection-records), [presentations](design-display.md#presentations) |
| ABI status, errno, signal and fault declarations | context-specific status/error translations, diagnostic names and descriptions, signal defaults and fault-to-exit mappings, musl's signal-number header and set of valid signals, and the signal names and numbers of the shell's `kill` | [programs](design-programs.md#the-posix-lite-personality) |
| ABI log and trace event declarations | typed emitters, bounded record readers, field-name/unit tables and decoders for the inspector and host tools | [kernel](design-kernel.md#trace-ring), [live machine](design-live.md#tracing) |
| Protocol fields, bounds and operation declarations | codecs, per-operation reply checks, valid-input builders, boundary mutations, fuzz entry points and reference tables; for `web.txt`, the Erlang codec `erx_web_proto` and the TypeScript codec, with the protocol's limits and hash | [files](design-files.md#the-file-protocol), [programs](design-programs.md#the-program-protocol), [web](design-web.md#the-protocol) |
| Widget format (`abi/formats/ui.txt`) | the whole-tree validator `erx_ui_schema`; a reader and a writer of the binary operations and events in Erlang, C and TypeScript; the kind, property and image-type tables; fuzz entry points for the validator and every reader | [display](design-display.md#widget-trees), grammar in [ABI](design-abi.md#widget-format) |
| Checked system manifest and platform placement records | packed boot-order and configured-domain/device/facet descriptors, watchdog liveness roster, and a host-readable configuration report | [system](design-system.md#the-manifest) |
| Release command metadata and program list | command lookup/help/required-facet catalogs and callback checks | [shell](design-shell.md#interfaces) |
| SVD and system-register specifications | typed accessors, device descriptor helpers and register-field decoding tables | [hardware sources](#hardware-and-terminal-sources) |
| Escape rules and OTP's pinned Unicode data | C/Erlang/Ruby/TypeScript escaping tables | [escape rules](design-live.md#escape-rules) |

Existing declarations are extended for these outputs; a generator never
keeps another copy of a layout or operation list. Protocol-specific
frontends feed a common validated declaration model where they share
types and bounds. They do not require a general programming language in
the schema or a general runtime RPC framework.

## Service interfaces

Each service operation declares its request and result variants, bounds
on bytes, counts and nesting, its declared errors, and the authority each
target needs. Bounded opaque bytes remain opaque; a decoder does not
interpret them as terms or create atoms from received names. Input-derived
lengths and offsets use checked arithmetic before allocation or access.
An unbounded or unsupported declaration fails generation.

Generated C and Erlang clients construct and validate requests and check
replies against the operation and outstanding request. Ruby clients are
emitted for services exposed through the host link. The stubs use the
existing connection, facet, alias and program-channel contracts: they
introduce no transport, retry policy or implicit reconnection. They never
retry an operation merely because its reply was lost.

The generated server behaviour has one serving path. It preserves the
facet's classification of replies, signals and requests, authenticates
origin from the receiving lane, validates the request and reply target,
and applies the live grant's scope and rate limits before the callback.
Handwritten policy decides scope membership and mutable preconditions;
generated code calls that policy at admission and mints only handles
justified by its result. The resulting action follows the core's existing
locking, reservation or generation-validation rule, so a changed scope or
target cannot invalidate an unchecked admission before its effect.
Handlers receive validated data and scoped
handles. Authority-consuming effects are callable only through the
generated helpers, enforced by the existing build checks. A declared
right, a client stub or a pid is never authority by itself.

Callbacks perform pure decisions and explicit effects; a schema does not
choose grant policy, scheduling or resource lifetimes. Reply validation
enforces the declared shape and bound before publication. Native programs
continue to speak only to their handlers, which use generated service
clients with the session's authority. Generated dispatch never gives a
program another domain's capabilities or facets.

## Inspection and diagnostics

Each inspection kind declares its paths and attribute keys, value types,
units, bounds, permitted reporter categories and visibility requirements,
and the schema declares the backend reporters with the category each
stands in for, its label and its scope, in the grammar of
[design-abi.md](design-abi.md#inspection-schema).
Builders and validators preserve the existing tagged statuses, including
`partial`, `unknown`, `unsupported`, `timeout` and `error`, without filling
missing observations with successful defaults. C declarations describe the
bounded kernel representation; Erlang and Ruby projections represent the
same information rather than copying native structures onto the wire.

The inspector authenticates who supplied a record and applies the caller's
facet scope before rendering or projecting it. Reporter tags do not
authenticate a source. Runtime assertions remain marked as runtime reports.
Generated path dispatch calls handwritten scope checks and data collectors;
it does not enumerate restricted objects before authorizing the query.
Unknown field names are refused without making atoms. Adding a schema field
does not expose it automatically: its visibility rule and each public
projection must be declared. The previous-boot crash record is shown
only to the system shell, whatever an inspect facet's scope.

Shell, host and `/proc` output share generated field order, unit labels
and status/reporter formatting. Dynamic names and values still pass through
the sink's one escaper; `/proc` names use its injective encoding and values
use its tab/newline/backslash framing. Schema formatting cannot bypass
either operation. Error descriptions contain no raw request data.

Error translations are explicit directed mappings, not reversible aliases.
Where one kernel status has different POSIX meanings, the declaration
names the operation or translation context. Every declared status and
protocol error has a mapping or an explicit "not exposed here" result for
each consumer that needs one. A missing case fails generation; there is
no catch-all success or `EIO`. Unknown untrusted error codes follow the
owning protocol's specified diagnostic/fallback rule. POSIX numbers are
FreeBSD's, checked against FreeBSD's headers, and musl's errno, signal and
termios headers are generated from the ABI file's tables; 9P keeps its own Linux
wire numbering, which generation never redefines.

Log and trace emitters accept the fields an event declares, with types,
units, bounds and sensitivity marks. Per-build projections explicitly
select fields: a release record cannot acquire a development-only field
merely because its type contains one. Dynamic text goes through the
existing log or line escaper. Snapshot accessors retain one-load
semantics; generation does not make shared data trustworthy or atomic.

## Configuration and command catalogs

The packer validates the system manifest and then emits its ordered
descriptor arrays into that same packed manifest. Root-task and Erlang
readers obtain startup, device assignment, configured facets and liveness
targets from those arrays. There is no parallel compiled configuration
table and no generated C function that performs domain creation without
the domain library's whole-plan validation. The host report is a derived
artifact and cannot configure a boot. Equal dependency choices use a
stable name order so equivalent inputs produce identical images.

The release build extracts command names, help, required facets and a
declared stage heap, a whole number of MiB from 5 to 16
([design-shell.md](design-shell.md#pipelines)), from module metadata, and native commands from the image's program list. It generates the lookup catalog and validates
callbacks against their declarations without executing target modules.
Lookup retains the shell's precedence rules and reports conflicting
Erlang names with both origins instead of silently choosing one.
Sessions construct their namespace from the catalogs of the releases
they actually hold; a catalog never installs authority or makes an absent
program available. Live-loaded command modules pass the same metadata
validation before their catalog entries are published. Each runtime entry
binds its metadata to the module's verified blob hash and a local entry
fun created by that code version. The generated module accessor returns
the local fun and its metadata together; the code server associates them
with the verified loaded artifact. Dispatch checks the current binding
and never resolves an old entry through an external fun that follows the
latest module. The local entry fun keeps a load racing a start from
substituting a different version after that check.

Before replacing a command module, its code server makes the affected
entries unavailable to new starts. It validates the candidate's metadata
before loading and publishes the matching bindings after the local load
succeeds. Failure or unknown completion leaves the entries unavailable
until reconciled against the code actually loaded, independently of the
overlay published for restart. A job already started keeps its entry's
metadata; normal OTP code-purge semantics still apply. This provides no
rollback of application state or external effects. User functions,
jobs, executable bodies and the shell parser remain ordinary code/state.

## Hardware and terminal sources

The hardware sources and their consumers follow
[the kernel contract](design-kernel.md#hardware-register-sources). As
for the ABI, the generator reads complete inputs, validates a typed
immutable model, and constructs the complete output plan before
publishing. Unknown semantics fail; a source is never partially
interpreted.

### Register inputs

CMSIS-SVD supplies peripheral register names, offsets, widths, access,
fields and enumerated values. The input profile uses bounded XML with
no document types, entities or external references. A register array is
`NAME[%s]` with `dim` and `dimIncrement`. A field list is CMSIS-SVD's field
`dim` (svd-spec v1.3.9, commit 4195b358, `doxygen/src/svd_schema.txt`, SHA-256
`35d4179b3198faeaf9fe602970a70abb9ca4112521308bb8d8f8820e27f4950a`,
dimElementGroup and the field element): one field description named `NAME%s`,
repeated `dim` times, each element named by its `dimIndex` string (0 upwards by
default, or a range `FIRST-LAST` or comma list naming exactly `dim` elements) and
placed `dimIncrement` bits above the one before. Its elements are ordinary fields
of the register, so the generated accessors are those the fields written out one
by one would give. A field array, `NAME[%s]`, and `dimIndex`'s letter ranges have
no consumer and are refused. An enumeration a peripheral repeats is written once,
as an `enumeratedValues` with a `name`, and each other field copies it with an
empty `enumeratedValues derivedFrom="NAME"`: CMSIS-SVD's derivation "makes a copy
from a previously defined enumeratedValues section" and allows "no modifications"
(same source, the enumeratedValues element). The profile resolves a bare name
within its own peripheral, so a name defines one enumeration there and a
derivation names one defined before it; every copied value is checked against
the field that copies it. A defined enumeration holds 1 to 256 values, and
since lists and copies multiply what a file spells out, a peripheral carries at
most 16384 field and value names. Each register carries the profile's
one extension, `ownedByNif`, saying whether the device NIF owns it and writes it
only in sequences of its own (a ring's base address, a queue's setup, the
device's status and features); the mark may instead sit, as `true`, on single
writable fields of a register that carries none of its own
([design-device-dma.md](design-device-dma.md#register-ownership)).
`erx/hw/device_owned.h` names each register owned whole or in part by its
index in the table, for `erx_device.c` alone; a register with neither mark is
refused. A register is 8, 16, 32 or 64 bits wide, at an
offset aligned to its width, and every access to it is one access of that width,
as the virtio specification asks of a device's configuration fields (OASIS
Virtio 1.2, sections 4.2.2.2 and 4.1.3.1).

One file may describe several peripherals. A group of registers several
peripherals share is written once, as a `cluster` leading one peripheral, and each
other peripheral copies it with a cluster `derivedFrom="PERIPHERAL.CLUSTER"` as its
own first element, at the same offset and adding nothing, then declares registers
of its own. That is CMSIS-SVD's derivation (svd-spec v1.3.9,
`doxygen/src/svd_schema.txt`, the cluster element): a derived section copies its
source, and anything it restates overrides what it inherits; the specification
defines no merge of a peripheral's register list, so derivation is of a cluster,
never of a peripheral that then adds registers. The profile has one cluster level,
no cluster arrays and no derivation from a derived peripheral, and a cluster's
registers keep their own names. The copied registers lead both tables at the same
indices, and the table records the peripheral a kind derives from, so the device NIF
treats every kind as its transport. The virtio-mmio transport is such a cluster, and
each device kind a peripheral that copies it and adds its configuration fields
(`hw/svd/virtio_mmio/virtio_mmio.svd`). Other inheritance fails.
A PCIe bridge's configuration space is a view that takes 8-, 16- and
32-bit accesses at an offset of a block, each access bounded by the window
([design-pcie.md](design-pcie.md#the-bridge-seam)). The window is an erXos
extension of the peripheral, `<configurationSpace>`, with a `name`, its first
block's `addressOffset`, one block's `size`, 4 to 4096 bytes, and for
`NAME[%s]` a `dim` of blocks one after another, at most 65536; offset and size
are multiples of 4, and a space meets neither another space nor a register. ECAM's
(`hw/svd/pci_ecam/pci_ecam.svd`) is `FUNCTION[%s]`, 65536 blocks of 4 KiB from
offset 0, one per routing ID, so a block's offset is `(bus - first) << 20 |
device << 15 | function << 12`; a peripheral of spaces alone has no registers.
The BCM2711 bridge's spaces sit beside its registers in its one peripheral
(`hw/svd/bcm2711_pcie/bcm2711_pcie.svd`): `ROOT_PORT`, the root port's
own 256 bytes at offset 0, and `EXT_CFG_DATA`, the 256 bytes at `0x8000`
that show the function `EXT_CFG_INDEX` names. A standard register inside a
space, as the root port's link status, is read through the space as any
function's is, never declared again as a register, which would meet it.
The device NIF reaches a block only while it lies wholly inside the window it
opened ([design-runtime.md](design-runtime.md#the-device-nif)). A cluster whose base
the controller reports, as xHCI's are, names in an extension,
`<baseFrom>REGISTER.FIELD</baseFrom>`, the capability register and field its
base comes from, the field's bits in place being the offset; the cluster sits
at offset 0, and the generator checks that the field is a readable field of a
readable register at a fixed offset
([design-usb.md](design-usb.md#registers-at-offsets-the-controller-reports)).
A cluster of an extended capability, as xHCI's legacy support and
supported-protocol capabilities are, carries `<capabilityId>`, the
capability's ID, 1 to 255, and sits at offset 0; its peripheral names the
list's head once, in `<capabilitiesFrom>REGISTER.FIELD</capabilitiesFrom>`,
the field holding the head in 32-bit words from the window's start. One
such cluster may be an array, `NAME[%s]` with a `dim` and no
`dimIncrement`, one instance for each entry of its ID up to `dim`, each
where its entry lies; its registers are not arrays of their own. The
generator refuses two clusters with one ID, an ID together with a
`baseFrom`, a `dimIncrement` on such an array, a cluster array of any
other kind, a capability cluster on a peripheral without a list, and a
register past the movable span. A register array whose live length the device reports, as xHCI's `PORTSC`
is, names that field the same way in `<dimFrom>`, as `REGISTER.FIELD`, or
as `REGISTER.FIELD + N` where the length is the field's value and `N` more,
as xHCI's doorbells are `MaxSlots` + 1; its `dim` must cover the field's
largest value plus `N`. An access
sequence a device's specification prescribes and SVD cannot express is
declared in the device's `vendorExtensions` in erXos's own namespace and
emitted as one function per sequence, with its barriers
([Hardware register sources](design-kernel.md#hardware-register-sources));
each extension element, `ownedByNif` included, joins the profile with
its first consumer, and the generator refuses every element of that
namespace it does not implement, so an extension is never accepted
without its semantics. Registers fit their address block and cannot
overlap. Fields fit their register, cannot overlap, and every enumerated
value fits its field. Names and generated symbols are unique.

Read accessors perform one volatile access of the declared width. Write
accessors refuse values outside writable bits. A read with side effects
has no read-modify-write accessor; a one-to-clear field has a clear
operation rather than a setter. Field extraction and insertion are pure
unsigned operations, including full-width fields without undefined shifts.
Whole-register read-modify-write is emitted only when every writable field
uses ordinary replacement semantics; a side-effect field excludes that
operation for all its siblings too.
A field's `modifiedWriteValues` is `oneToClear`, `oneToSet` or `modify`, or
absent for a write that stores its value. A register's preserve mask is the
bits a write carries from the word read so that it changes only what it means
to: every readable field that stores what is written. A field whose write
acts, beside fields to preserve, is written as the word read, masked to the
preserve mask, with the driver's own bits, so such a register's read must have
no side effect; it gets no lone clear operation, which would write zero to the
preserved siblings, and its headers define the mask (`..._PRESERVE`). So do
those of a register a driver updates by writing back the word read, where the
mask is its writable bits: masking the word clears the reserved bits the
generated write refuses. xHCI's
`PORTSC` mask is the writable bits FreeBSD's `XHCI_PS_CLEAR` does not remove,
derived rather than copied ([design-usb.md](design-usb.md#the-controller-process)).
Hardware access remains an effect owned by the device shim or the
kernel's early-console writer, as their separate chokepoints require.

An SVD that a vendor publishes enters the tree as an import: `hw/svd/<device>/ORIGIN.md` records its
repository, release and SHA-256, and lists each edit the profile needed, which
a script under `tools/` makes again from the pinned upstream file. The file keeps the
vendor's license notice and descriptions, and only the peripheral erXos drives
enters the tree. The PL011's is the Raspberry Pi Pico SDK's UART0.

The same model produces the table `erx_device` resolves Erlang's register
names through ([design-runtime.md](design-runtime.md#the-device-nif)):
`include/erx/hw/device_types.h` its shapes, `device_table.h` each peripheral's
registers and fields, lower-cased, with window, offset, width, array shape,
access, masks, the device-address mark, whether a field may be replaced by
a read and a write, the preserve and owned masks, a
register's movable cluster and an array's count field, the peripheral's movable
clusters, and the peripheral a kind derives from; `device_access.h` the one volatile load and store of each
width. No peripheral may take one of those names. A bit the source does not declare
is written as zero, by a field's update too, so a register's source declares every bit
the hardware implements.

An Erlang driver takes its peripheral's fields from the same model, so it never
packs a register's bits by hand or copies a mask:
`erlang/apps/erx/include/generated/erx_hw_<peripheral>.hrl`, which a module
includes as `-include("generated/erx_hw_<peripheral>.hrl")`, defines for each
field of each register, as `ERX_HW_<PERIPHERAL>_<REGISTER>_<FIELD>_*`, its shift,
width and mask in place, a macro taking the field from a word, a guard that a
value fits it, a macro placing a value in a word, which fails with `badfield`
on a value that does not fit rather than spilling into the neighbouring
fields, and each value the source names for it. These are arithmetic on a
word only: a driver still reads and writes a register through `erx_device` by
name, which refuses what the register does not allow. The macro names share
one namespace, read from the headers themselves and checked like the C
symbols, so a value named for a macro suffix or two paths meeting at one name
are refused.

The system-register extractor consumes the pinned Arm register package
and a checked selection/attribute file. Encodings, widths and field ranges
come only from that package. erXos declares allowed read/write operations,
side effects and required synchronization beside those facts. The
extractor rejects missing, ambiguous and unsupported selected records;
it never picks the first alternative field layout. The derived JSON keeps
Arm's notice and exact source identity. The generator uses that checked-in
JSON offline; the extraction check recreates it from the pinned input.

### Escape rules

`abi/terminal.txt` declares the unsafe character classes. Pinned OTP Unicode
data supplies category and default-ignorable ranges. The generator emits C,
Erlang and Ruby tables from one normalized interval set. Input-derived names
never become atoms. The table consumer escapes invalid UTF-8, controls and
unsafe formatting characters in text labelled with its source before it is
displayed on the host or the target. A conservative ASCII host sink can escape
additional printable characters without admitting anything the generated
policy refuses.

## Reference tables and tests

Generation emits the factual parts of API documentation: signatures,
operation identifiers, fields, variants, units, bounds, declared rights
and error mappings. These are generated reference documents in the build tree (the ABI's is
`build/gen/docs/generated/abi-reference.md`), not copies in the design
documents. Handwritten examples and architectural rationale stay in the
design documents. A reference
table does not become another input to the generator.

Each generated parser lands with input builders and a fuzz entry point
that calls the production decoder. Deterministic boundary cases cover
empty and maximum values, one past the bound, truncation, invalid tags,
and checked-arithmetic failures. Mutation helpers change fields and lengths
without repairing them through the encoder. Round trips and generated
cases supplement independently constructed fixtures and external oracles;
matching encoder/decoder mistakes must have an independent place to fail.

Generator tests seed invalid declarations: duplicate identifiers, undefined
types, missing mappings, unbounded messages, absent visibility rules and
authority declarations that cannot reach a checked helper. Catalog tests
race starts with module replacement and inject failure before and after
code load and catalog publication, with changed facet requirements and
callbacks. No start may pair one version's metadata with another's
entry code. Independent
hostile tests exercise unauthorized origins, stale handles, restricted
inspection fields and mismatched replies. TLA+/TLC properties remain
independent specifications rather than outputs of these generators.

## Output inventory and publication

Each generator front end derives one immutable inventory of its
resolved input paths and every output path with its bytes (for the ABI,
`tools/lib/erx/abi.rb`). Paths are normalized relative paths, without
traversal or symlinks; inputs lie below the repository root and outputs
below the build's generated tree, `build/gen/`, which mirrors
repository-relative paths. Output bytes depend only on source bytes and
the generator, never wall-clock time, locale, filesystem enumeration
order or absolute checkout path. Declarations keep their declared field
order; unordered sets and reference tables use qualified-name byte
order. Every artifact names its sources and generator and carries the
project's BSD-2-Clause notice.

The outputs are C headers and sources for the kernel, `liberx` and its
backends, the device NIF and the display, and the seam headers of the
C17 cores' C++ glue (`include/erx/core/`), which does not include
`include/erx/abi.h` and gets each value it needs spelled as that header
spells it;
Erlang modules and headers for the `erx` applications and OTP's
preloaded modules; Ruby host codecs and readers under `tools/generated/`;
fuzz entry points that call the production readers; the web client's
TypeScript under `web/src/generated/`; and the reference documents under
`docs/generated/`. The inventory enumerates individual paths rather than
accepting arbitrary files below those directories.

All outputs are derived and validated before any publication, so a
failed schema check never reaches the effect stage. The tree is staged
beside `build/gen/` and moved into place by rename, so a process or
filesystem failure leaves the earlier tree or none, and the command
fails. The generated tree is regenerated whole, so an output the
inventory no longer lists does not survive, and a file edited or added
by hand fails the tree's stamp ([Generation](design-build.md#generation)).
The determinism test and the ASCII refusal of `Erx::Generated` hold the
byte-for-byte and ASCII properties.

Independent raw-byte fixtures live in `test/fixtures/` and do not derive
their expected bytes from the generator. Test builders use the generated
host codec where their purpose is constructing inputs rather than
serving as an independent oracle.

## Build contract

Generators are Ruby tools with a pure parse/validate/derive core. They
validate the complete input and output plan before publishing any output.
They run offline, with pinned third-party data, deterministic ordering
and explicit input/output inventories. A schema change regenerates all
affected language bindings, documentation and fixtures in one change.
Generated source is ASCII-only, readable and subject to the normal style,
stack, sanitizer and chokepoint checks. C code uses typed loads/accessors
and checked arithmetic rather than packed-structure casts or unchecked
pointer arithmetic over input. Data tables contain no new function-pointer
escape from the kernel's listed call targets.

The hardware generators have checks of their own. Independent fixtures
exercise register mask boundaries, side effects and malformed inputs,
and fuzz targets call the production readers. Cross-compilation checks
system-register instruction encodings against independent expected
words. Architecture terms and hardware instructions stay in their
binding layers: the vocabulary gate (`make check-arch-terms`) reads
literal word, prefix and instruction declarations from `hw/arch_terms/`,
each matching in any case unless marked case-sensitive, as a mnemonic
that is also an ordinary lower-case name is, and an instruction only
with an operand after it. It checks erXos's generic kernel, library and
system sources and architecture-neutral design documents; architecture,
platform and hardware binding directories and their binding documents
own the concrete names. Underscores delimit terms too, so embedding a
mode name inside a C identifier does not hide it from the gate.

Generated artifacts are never checked in: the build generates them into
`build/gen/`, regenerating the whole tree when an input or a generator
changes ([Generation](design-build.md#generation)). A test generates the
tree from the same inputs in different places and times and requires
identical bytes. Schema parsers reject unknown declarations; targets refuse
unsupported ABI/schema versions with a diagnostic. No generator emits
migration code or readers for old erXos formats.

The roadmap introduces each schema extension with its first consumer.
Generation does not delay the usable slice to build machinery for services
or protocols that slice does not need.

## References

* [OTP 29.1.2 fun semantics](https://www.erlang.org/doc/apps/erts/erlang.html#fun_info/1):
  local funs call the code version that created them; external funs follow
  the latest module version.
