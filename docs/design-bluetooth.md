# Bluetooth Low Energy: a peripheral that a phone talks to

This document is erXos's Bluetooth stack: how a Bluetooth controller
reaches erXos, which domain parses what it sends, how an erXos machine
advertises itself, serves the GATT services that apps declare to a phone,
carries a serial line to a phone, and pairs and bonds with LE Secure
Connections; and, as later stages, Wi-Fi provisioning from a phone, HID
over GATT into the display's input router, and classic Bluetooth. It
refines the unit rule of
[design-shared-devices.md](design-shared-devices.md#the-unit-rule), the
Raspberry Pi 4's UARTs of
[design-platforms.md](design-platforms.md#raspberry-pi-4-model-b), the
facets and the manifest of [design-system.md](design-system.md#the-manifest),
the vault of [design-system.md](design-system.md#the-vault) and the input
records of [design-display.md](design-display.md#input-events).

Decisions every reader needs:

* **erXos is a peripheral first.** The first milestone is an erXos
  machine that a phone app finds, connects to and talks to: it
  advertises its name and service UUIDs, serves GATT, carries a serial
  line and pairs. The central role (scanning, connecting, a GATT client)
  arrives with HID over GATT, a later stage.
* **One table, one gate.** The GATT attribute table is configuration:
  it is built from checked-in service declarations that the manifest
  selects, and it never changes while the Bluetooth domain lives. Every
  access a phone makes, and every notification an app sends, passes one
  pure function of the characteristic's declared requirement and the
  link's security, which the controller's own encryption report alone
  sets for the one key the link holds in its life. No app checks
  security, and no app can be reached over a link weaker than its
  declaration asks for.
* **Apps declare; Erlang processes handle.** An app names its services
  in `abi/gatt/` and its facet row; the stack derives handles,
  declarations, descriptors, subscriptions, MTU and long values. The
  app's handler process answers writes, sets the values reads return,
  and sends notifications and indications, through the `ble` facet.
* **The Bluetooth domain parses everything radio-derived.** Every byte
  from the controller is hostile: the controller's closed firmware parses
  the air, and anyone in radio range reaches the parsers above it. The
  Bluetooth domain, `bt`, holds no device; the system domain moves the
  controller's bytes and parses none of them.
* **The controller's line is a file tree.** On the Raspberry Pi 4 the
  controller is on UART0, a sub-device of the PL011 unit the system
  domain holds. The system domain serves it as the unit rule says: a
  tree with a `data` file of H4 bytes and a `ctl` file whose one word,
  `reset`, power-cycles the controller and programs the UART afresh, so
  every bring-up starts from one state.
* **Pairing happens only in a window an operator opens, and a bond is
  only ever made, never replaced.** LE Secure Connections only, with a
  16-octet key; a window is an open file, ends with its first pairing,
  and opens to a radio peer only after the wait that SMP asks after a
  failed pairing.
* **Bonds are machine secrets.** Release builds keep them in a sealed
  state slot of the vault, an opaque blob the vault never parses
  ([design-system.md](design-system.md#state-slots)); development builds
  keep them in the Bluetooth domain's directory on the data partition,
  as the SSH design keeps its host key before the vault.

## Context

### What is matched

erXos implements the host side of the Bluetooth Core Specification 6.3
(the HTML edition, [Sources](#sources)) for a device in the LE
peripheral role, and is held to what each part requires of it:

| Part | What erXos implements first | What it rests on |
| --- | --- | --- |
| Vol 4 Part A, UART transport (H4) | the host end of the line | a one-byte packet indicator before each HCI packet, `0x01` command, `0x02` ACL data, `0x04` event (section 2, Table 2.1); 8 data bits, no parity, one stop bit, RTS/CTS, which "should not be used for flow control of HCI" (section 3); a wrong indicator or an out-of-range length is a loss of synchronization, after which "a reset is needed" (section 4) |
| Vol 4 Part E, HCI | the commands and events of a peripheral's host | one command outstanding within the controller's `Num_HCI_Command_Packets` (4.4); no ACL packet sent while the controller's free-buffer count is zero (4.1.1); a Disconnection Complete returns every unacknowledged packet of its handle (4.3); LE Read Buffer Size describes packets from host to controller (7.8.2), and the host states the longest ACL packet it accepts with Host Buffer Size, by which the controller segments what it sends the host, flow control on or off (7.3.39) |
| Vol 3 Part A, L2CAP | the three LE-U fixed channels, ATT `0x0004`, LE signaling `0x0005`, SMP `0x0006` (2.1) | an unknown signaling command answered with `L2CAP_COMMAND_REJECT_RSP`, "Command not understood" (4.1) |
| Vol 3 Part F, ATT | a server | a server answers at least Find Information and Read (3.3); an unsupported request is answered Request Not Supported, an unsupported command ignored (3.3); one request and one indication outstanding per bearer, and commands that cannot be processed are discarded (3.3.2); a transaction not completed in 30 s fails the bearer (3.3.3); a value is at most 512 octets (3.2.9); the error codes of Table 3.4 |
| Vol 3 Part G, GATT | the server features of Table 4.1 | the mandatory discovery and read sub-procedures (4.2); the Service Changed characteristic exists when services can change in the device's lifetime, and is indicated to a bonded client at reconnection (2.5.2); a Client Characteristic Configuration persists for bonded clients and resets for others (3.3.3.3); default ATT_MTU 23 (5.2.1) |
| Vol 3 Part H, SMP | a responder, LE Secure Connections only | the key size between 7 and 16 octets, failed with "Encryption Key Size" when below the minimum (2.3.4); the peer's public key validated on P-256 and failed with "DHKey Check Failed" when off it, the debug key refusable, equal X coordinates failed (2.3.5.6.1); a fresh passkey per pairing (2.3.5.6.3); a fresh key pair after every pairing (2.3.6); after a failed pairing, a wait before answering a Pairing Request from a device claiming the failed one's identity, growing exponentially with each further failure, limited to a maximum and shrinking back to a minimum when no failure follows (2.3.6), the reason Repeated Attempts (`0x09`) for a request it refuses (Table 3.7); a Security Request the peripheral may send, never while pairing or encryption is in progress (2.4.6); a claimed identity address valid only after a reconnection with the pairing's key (2.4.3.2); a 30 s timer (3.4); the reason codes of Table 3.7 |
| Vol 3 Part C, GAP | a peripheral in LE security mode 1 that pairs only by LE Secure Connections | levels 1, 2 and 4 of LE security mode 1, with "the use of LE Secure Connections pairing" enforced for services at level 2, which 10.2.1 permits; not Secure Connections Only mode (10.2.4), which would allow level 4 alone; the error a server answers for each access, link state and pairing state (10.3.1, Table 10.2); security checked before every notification and indication (10.3.1.1); a static address and resolvable private addresses (10.8) |

The serial service follows Nordic's UART service, so that existing phone
terminal apps work: one service, a characteristic the phone writes with
and without response, and one it subscribes to for notifications, with
UUIDs `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, `...0002...` and `...0003...`,
as Apache NimBLE's `bleuart` service declares them
(`nimble/host/services/bleuart/src/bleuart.c:52-86`).

HID over GATT, a later stage, follows the HID over GATT Profile 1.1 and
the HID Service 1.0: a Report Host (HOGP 2.1), which bonds (7.2),
encrypts as early as possible after reconnection (7.2), enables
notifications of every Input Report (4.8), and prepends the Report ID of a
characteristic's Report Reference to each value before the HID parser
sees it (4.8.1); the Report Map is at most 512 octets (HIDS 2.6.1).

### The hardware

* **The Raspberry Pi 4's controller is a Cypress CYW43455 on UART0**, the
  first PL011, on GPIO 30 to 33 in function ALT3: CTS0, RTS0, TXD0 and
  RXD0 (BCM2711 peripherals, section 5.3; Raspberry Pi documentation,
  `interfaces.adoc`, the table of primary and secondary UARTs). Whether
  the firmware leaves those pins in ALT3 is probe B-P1.
* **UART0 is held, undriven.** The five PL011s share one register page
  and one interrupt line, 153, so they are one unit, which the system
  domain holds for UART3, the host link
  ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b),
  `config/platforms/raspi4b.json`, unit `hostlink-uart`). Each PL011's
  clock is 48 MHz in the record, so 115200 baud divides as the host
  link's does.
* **Power.** The controller's enable line is, by all accounts, a pin of
  the firmware's GPIO expander, which the VideoCore drives on a mailbox
  request. FreeBSD's expander driver numbers those pins from 128
  (`raspberrypi_gpio.c:51`) and sets one with the property tag
  `0x00038041`, whose request is the pin and its state
  (`bcm2835_firmware.h:144`, `:161-168`). Which pin, and its polarity,
  only GPL sources state; probe B-P2 reads them from the device tree the
  firmware passes at run time, which is data, and records whether the
  firmware leaves the controller powered.
* **The patch.** Every permissive host that drives a CYW43xxx loads a
  patch into the controller's RAM before use: NetBSD's `btattach` sends
  the vendor command `0xFC2E` (download minidriver), replays the `.hcd`
  file as HCI commands of the form `opcode(2, little-endian) length(1)
  payload`, each awaiting its Command Complete, sleeps, and resets
  (`init_bcm43xx.c:105-141`); Zephyr's Infineon driver does the same and
  stops at any record but `0xFC4C` (Write RAM) and `0xFC4E` (Launch RAM),
  though only after sending it (`hci_uart_infineon.c:141-191`). The Pi
  4's patch is
  `BCM4345C0.hcd`, which the fetch step downloads and the Pi 4's image
  ships ([Stage 1](#the-bring-up)).
* **QEMU has no Bluetooth.** QEMU removed its Bluetooth emulation in 5.0
  "without replacement" (QEMU's 5.0 change log), and QEMU `virt`'s two
  PL011s are the console and the host link (`virt.rst:36`, `:55-62`). The
  integration tests run in [hosted mode](design-runtime.md#hosted-mode)
  against Google's Bumble, whose virtual controllers speak H4 over a TCP
  socket ([Verification](#verification)).

### Sources

Every source was read at a pinned version, fetched over HTTPS into a
directory outside the tree; none under the GPL or the LGPL was read. The
Bluetooth SIG's specifications are their HTML editions, the Core
Specification at
`https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/index-en.html`.

| Source | Version | File | SHA-256 |
| --- | --- | --- | --- |
| Core Specification 6.3 | 6.3 | index | `96b569247cc6999f35463c6483efb3392babe9d240c0d22ab20a9c870b5310e6` |
| | | Vol 4 Part A, UART transport | `f5fc6f3977bf3d7f2a86422b38c74590c071b2ec693b9349ce1092616871621b` |
| | | Vol 4 Part E, HCI | `76eb9e21a158ac3a2340087568437b0b91408b333ab135c7a13f9b5bdcc57ed2` |
| | | Vol 3 Part A, L2CAP | `9fc72a9efd4229c3f800ac862808bba7b33d6a95679cfbd2acda5b3650069905` |
| | | Vol 3 Part F, ATT | `272a2472b71b54503d44a16286b9e399a323774d8b7b8246283a7c49e96d0638` |
| | | Vol 3 Part G, GATT | `25539e2ca6f127cf98bb34baae0c2cb774549ccb94d54f331c3c3ef4efa02add` |
| | | Vol 3 Part H, SMP | `16d561aab6cb6a219a55963fdb7acd68bfcac69eacf7387ae0b7366f180a4974` |
| | | Vol 3 Part C, GAP | `e095f6af2a746e898c36ed63ec9655fdf803d747daa4b6b68d21624acde835bf` |
| HID over GATT Profile | 1.1 | index | `b763f6511244e97f2fc1d9387f0e999c6bbbc82c8d58e92b66f1eb025972d725` |
| HID Service | 1.0 | index | `b114fb6930bb11a99bc8b6be72593e185abbbe4827a6ec18851ef2664d5f79a3` |
| NetBSD | trunk `5cebe14c1559` | `usr.sbin/btattach/init_bcm43xx.c` | `2c25439d61fbfd410f9cd8216152a7f8bc4dd9f7dbb974b58dc351d4d9f46f53` |
| | | `usr.sbin/btattach/btattach.c` | `58c3d467335cfb0e2791ef185ca232326f9289e570df887c1387c77df3e92b74` |
| Zephyr | main `7cd4b562b30a` | `drivers/bluetooth/hci/hci_uart_infineon.c` | `07aa15b3b1db206875ab3df72c739174d83e328ed9b59fc65cacd16917b8a288` |
| FreeBSD | releng/15.1 `95719d8a895b` | `sys/arm/broadcom/bcm2835/raspberrypi_gpio.c` | `ad34506dd6f69144bc4bfb3bfb00fb87b6c327ad5fe30ae03ee80437e3a79224` |
| | | `sys/arm/broadcom/bcm2835/bcm2835_firmware.h` | `9dfeb72a9a56556531afab024d80d45baaba40bc07351b970f651325b3d339a7` |
| | | `usr.sbin/bluetooth/hcsecd/hcsecd.h` | `fcb787bdad0ea5cde10d6fd3d6a058414686a1d783d34aa324b148c26de0e849` |
| RPi-Distro bluez-firmware | `cdf61dc691a4` | `LICENSE.cypress` | `a92f031f19089fa63bd24ac4c5298ca1356670321b39c67024a961ee3285fff7` |
| Raspberry Pi documentation | `c6a64966af13` | `computers/configuration/interfaces.adoc` | `20c0c5f8dcf2ba501ec7888028aa576be2c965f9b06dd04022e3c9d187b33cef` |
| BCM2711 ARM Peripherals | unversioned | the PDF | `d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78` |
| PrimeCell UART (PL011) Technical Reference Manual | ARM DDI 0183G, r1p5 | the PDF, from `documentation-service.arm.com` | `9cfe1a296ebe7accd905fb569e4c545ed9ca01d8341603568017319abe7e51e7` |
| QEMU | wiki, read 2026-11-14 | `wiki.qemu.org/ChangeLog/5.0` | `210bfe5e852d8395bfd937cf312ac62d936ee8948d6c310f19110f161843ca00` |
| QEMU | `v11.1.3` | `docs/system/arm/virt.rst` | `9fbcc9fc3040ef695e3058cd4bab05e10f6282ab7ba0846a93ee9f524933e3e1` |
| Apache NimBLE | master `648fc0213fb7` | `nimble/host/services/bleuart/src/bleuart.c` | `2a51bad8f39685887b10f2301e023baa2af9200685d91528ae330bef78a21ed1` |
| Bumble | `v0.0.237`, `34def7f112f9` | `apps/controllers.py` | `2d57845479e214137210db48bf12f3ac0309f01abb5cb4c6088b1d35ae462a05` |
| | | `bumble/controller.py` | `8869ca13997bcc39b1fd2932438b720ac66db866d17a10b3ec4ba6504dc778db` |
| | | `bumble/keys.py` | `5a06ecf86854108ca9714409a81ef0cc62cdc37010136c8e8f013c012a024b38` |
| | | `examples/device_with_rpa.json` | `d8c7a1515716ed182ddd2e4476f5a5600a30c772bbdb1101ac63c71f50b84c89` |
| | | `apps/scan.py` | `352443d071e7f112d80d1c787cbbd3598ebcf90c4b57076b62da9029e96efee3` |
| | | `apps/gatt_dump.py` | `e04a4958947e3a131614cb0215ef60ec182e09cbd7855aaea32ca1c00ff7f428` |
| | | `apps/pair.py` | `5d137d70db884e78ec1806daac8c848066937fbfdbfd5f2e159b2e781b3bcf9c` |
| | | `examples/run_scanner.py` | `37a0cba92cceb8488422ca00390f944a619278b55a7d7299c9d889b91d992ee7` |
| | | `examples/run_gatt_client.py` | `aec03764d636d0e024dc443d777989fad7ecf45b10e40e56ebd77e7e65613b48` |
| | | `examples/run_connect_and_encrypt.py` | `c15665cf0dc4e8f0437e21940c2a4304a28adfefd2091d732c281bcc28e3f891` |
| | | `bumble/core.py` | `99604dffc77ee642b256d86d1f6e27fdc7e770bd70f62ecd225f485810f87aa0` |
| | | `bumble/hci.py` | `6eacd9bd72df40da6a5b79e9e7130e8c20434d01e6d379b150808b3de8c0e865` |
| | | `bumble/transport/common.py` | `c62ac850542cf9ef8668ebbe801e3a5dc369a50464c1faba875fb404935b409d` |

The Core Specification Supplement, which defines the advertising data
types and the Flags structure, and Vol 6 Part B, which defines the formats
of static and resolvable private addresses, were not fetched. The values
this document uses from them come from Bumble's `core.py:1594-1622` and are
marked unverified until the supplement is read.

## Requirements

Each names its consumer.

| | Requirement | Consumer | Stage |
| --- | --- | --- | --- |
| B1 | A phone's scanner shows the machine's name and the UUIDs of the services it advertises | the vendor's phone app, which finds its device by service UUID | 1 |
| B2 | A phone discovers, reads and writes the characteristics apps declare, and subscribes to their notifications and indications | the vendor's phone app | 2 |
| B3 | An app declares its services as data; Erlang processes answer writes, set values and send notifications | the vendor's app on erXos | 2 |
| B4 | A byte stream between a phone and an app, which phone terminal apps for Nordic's UART service open | serial tools; the console | 3 |
| B5 | A characteristic may require an encrypted link, or an authenticated one, reached by LE Secure Connections pairing and bonding | Wi-Fi provisioning, the console | 4 |
| B6 | A pairing is made only in a window someone with the right opened, and no bond is replaced by pairing | every characteristic that requires a bond | 4 |
| B7 | Every byte from the controller and every PDU from a peer is parsed by a bounded parser with a fuzz target; a malformed one ends at most its link, or restarts the controller | the machine's integrity against anyone in radio range | all |
| B8 | The trusted base parses no radio bytes | the system domain's integrity ([design.md](design.md#decisions)) | 1 |
| B9 | Every bring-up starts from one state, whatever the last one left | restarts of the controller, the Bluetooth domain and the line | 1 |
| B10 | A connection's name never names a later connection | apps that notify after a phone left | 2 |

## The construction

### One table, one gate

The attribute table is a pure function of configuration:
`erx_gatt_db:build(Services)` takes the declarations of the services the
manifest selects, in the order of their names, and returns the table:
every attribute's handle, type, value or value source, permissions, and
each characteristic's declaration, value and descriptors. The Bluetooth
domain builds it once at its start; nothing adds, moves or removes an
attribute while the domain lives. The table's **hash**, SHA-256 over its
declarations in table order (`erx_bytes:sha256/1`), names it.

Every access passes one pure function, the **gate**:

```erlang
-spec erx_gatt_gate:check(level(), link_security()) -> ok | {error, att_error()}.
-type level() :: open | encrypted | authenticated. % GAP 10.2.1 levels 1, 2 and 4
-type link_security() :: #{key := none | encrypted | authenticated, encrypted := boolean()}.
```

It is GAP's Table 10.2 (10.3.1) for the three levels erXos uses, whose
columns are the key the server has for the peer, not whether that key is
stored: an `open` access is allowed; an `encrypted` or `authenticated`
access on a link with no key answers Insufficient Authentication
(`0x05`); on a link with a key but not yet encrypted, Insufficient
Encryption (`0x0F`); an `authenticated` access on a link encrypted with
an unauthenticated key, Insufficient Authentication. Since every key is 16 octets and only
Secure Connections pairs, level 3 and Encryption Key Size Too Short
never arise. The ATT server calls the gate for every read and write of a
characteristic value or a descriptor; the link calls it before every
notification and indication it sends, as GAP 10.3.1.1 requires; nothing
else decides access.

`link_security()` is a derived fact of the link, and one transition
sets it, for the first pairing and for every reconnection alike:

* **A link holds at most one key in its life.** It has none at LE
  Connection Complete. It gets a kept bond's key when the phone's address
  resolves to that bond ([Reconnection](#reconnection)), or the key its
  pairing computes, at the moment SMP's second phase makes it
  ([Secure Connections only](#secure-connections-only)). A link with a
  bond's key never pairs, and a pairing runs only on a link with no key,
  so a key, once a link has one, never changes; a pairing that fails
  after it made its key ends its link, so a link's key is a kept bond's
  or its own pairing's. `key` is its level, `encrypted` for Just Works
  and `authenticated` for Passkey Entry.
* **`encrypted` is set only by the controller, for that key.** At LE Long
  Term Key Request the link answers Reply with its key, or Negative Reply
  when it has none (HCI 7.8.25, 7.8.26). `encrypted` becomes true at the
  controller's next report that encryption started, Encryption Change
  with encryption on or Encryption Key Refresh Complete, each with status
  success, after a Reply; any other report about encryption on the link,
  an error, a change to off or a report after a Negative Reply, ends the
  link.

So the first pairing encrypts as SMP has it, with the pairing's key
before the third phase distributes the phone's identity (SMP 2.4.3),
and reaches its level then; a reconnection encrypts with the bond's key
the same way; and the level a link reaches is always the level of the
key the controller is using on it, which no field a peer sends sets.
Whether a pairing's key has been kept decides what outlives the link,
not what the link may do: only the peer that completed the pairing in
the window holds that key, before the store keeps it as after. A
pairing whose store answers `unavailable` fails and ends its link
([Bonds and the store](#bonds-and-the-store)), so no link outlives the
store's refusal of its key.

From these two constructions:

* **An app is never reached over a link weaker than its declaration.**
  The handler receives a write only after the gate allowed it, and a
  notification it asks for is sent only where the gate allows it, so no
  app checks security and none can forget to.
* **The table never goes stale under a phone.** Within a domain's life
  there is no service change to announce, so a phone that is not bonded
  rediscovers each connection as GATT 2.5.2 requires and is never
  wrong; a bonded phone, whose cache outlives connections, gets Service
  Changed with the whole range at its first connection after the table's
  hash differs from the one its bond records ([Reconnection](#reconnection)).
* **Apps cannot reach each other's attributes.** An app's facet names
  services, never handles, and the registry routes each event to the one
  handler of its service.

### A name dies at once

Connection handles are the controller's and are reused. The controller
process gives each connection a fresh reference, `Conn`, at LE
Connection Complete, and every request an app makes names `Conn`. The
registry maps a live `Conn` to its link process; the link's end removes
it, so a notification to a phone that left answers `{error, gone}` and
never reaches a later phone that took the same handle. As in the USB
design ([design-usb.md](design-usb.md#a-name-dies-at-once-hardware-is-freed-only-on-the-controllers-report)),
the controller's resources are freed only on its report: a handle's
outstanding ACL packets return to the credit count at its Disconnection
Complete, as HCI 4.2 states, and not before.

### One owner, one step

Each kind of process owns its state and decides by a pure step that
returns the actions it performs, as the network stack's and the USB
stack's owners do
([design-network-stack.md](design-network-stack.md#one-owner-one-step)):

| Owner | Its state | Its pure core | Effects |
| --- | --- | --- | --- |
| the **controller process**, `erx_bt_hci` | the bring-up, the command slot, ACL credits, the map from handles to links, advertising | `erx_bt_hci_core` | items for its writer, which writes `data` and `ctl`; acknowledgements to its reader; starting and ending link processes ([The controller process's effects](#the-controller-processs-effects)) |
| a **link process**, `erx_bt_link`, one per connection | L2CAP reassembly, the ATT bearer (MTU, the request in progress, queued commands, the prepared write, the indication in flight), the notifications waiting for credits, subscriptions, its one key and whether it is encrypted, the pairing in progress | `erx_bt_link_core`, over `erx_gatt_server`, `erx_gatt_gate` and `erx_smp_core` | messages to the controller process, the registry, the window and the store, and its two calls at its start ([The link's messages](#the-links-messages)) |
| the **registry**, `erx_gatt_srv` | the table, each service's handler, the live `Conn` map, the `ble` facets | `erx_gatt_registry` | a monitor of each link, events to handlers, requests to links |
| the **store**, `erx_bt_store` | the identity address, from stage 1; the bonds, from stage 4 | `erx_bt_state` (stage 4) | reads and writes through the store's backend; a monitor of each link holding a bond, and `forgotten` to it (stage 4) |
| the **window**, in `erx_bt_fs` (stage 4) | whether a pairing window is open, its mode and its opener's fid; the pairing wait | `erx_bt_window` | lines on the opener's `pair` file; a monitor of each link that owes it a pairing's outcome |

Every timer is a deadline in its owner's state, and `next_deadline/1`
answers the earliest ([design.md](design.md#drivers-and-dma), "Deadlines in state"). No caller strings operations together:
the bring-up is one state machine, a pairing is one, and a write's
round trip to a handler is one step out and one step back.

### What disappears

| Case that would need handling | Why it cannot arise |
| --- | --- |
| an app forgets to check that a link is encrypted | the gate decides before the app sees the write, and before a notification leaves |
| a peer raises its link's security by a field it sends | only the controller's report of encryption, after the link gave its one key, sets it |
| the first pairing and a reconnection need different security transitions | both encrypt with the link's one key, through the one transition |
| a pairing on a bonded link, or a second key on one link | a link with a key never pairs, so its key never changes |
| a database change mid-connection, Service Changed to unbonded phones, a client made change-unaware | the table is fixed for the domain's life; Database Hash is not served, so robust caching is not required (GATT 2.5.2.1) |
| two apps declare the same UUID, or the advertising data overflows | the manifest check refuses the configuration ([Declarations](#declarations-abigatt)) |
| a notification reaches a phone that took a departed phone's handle | `Conn` dies at once |
| a bring-up starts from a controller left at an unknown rate, patched or half-patched, or from a UART holding the last controller's bytes or the boot's settings | `reset` power-cycles the controller and programs the UART afresh before every bring-up |
| an app that opens windows one after another lets a guesser retry at once | the pairing wait is the window process's and outlives every window |
| a weaker pairing overwrites a stronger bond (BLURtooth's class) | pairing never replaces a bond; only `forget` ends one |
| a phone's subscription lost at a power cut | a bonded link's configuration write is answered only once the store has kept it |
| a peer with a bonded phone's address changes that bond's kept subscriptions or table hash | a link is its bond's only from its encryption with the bond's key, and only the bond's own link writes them |
| a window closed as its pairing completes leaves a kept bond counted failed, or a failure kept | the link's one step that hands the bond to the store decides which side the close fell on, and the store's answer is the outcome |
| an app's crash leaves dangling attributes | attributes are configuration; the handler detaches, values stay |

## Stages

The work is ordered by the first consumer, a phone app talking to an
erXos device, in four stages whose sections follow: the controller and
advertising, the GATT server, the serial service, and pairing and
bonding. Each ends in a demo against a phone and a test against Bumble
([Hosted mode against Bumble](#hosted-mode-against-bumble)); Wi-Fi
provisioning, HID over GATT and classic Bluetooth come after them
([Later stages](#later-stages)). [plan.md](plan.md#track-b-bluetooth)
schedules the work.

Stages 1 to 3 need no Security Manager: until stage 4 the link answers
every SMP PDU with Pairing Failed, Pairing Not Supported (`0x05`), and the
gate refuses every `encrypted` and `authenticated` access with
Insufficient Authentication, which is the right answer for a server with
no key for the peer (GAP 10.3.1). The phone console is part of stage 3's service but
is offered only once stage 4 exists, since its characteristics are
`authenticated` ([The console](#the-console)).

## Domains and authority

### The Bluetooth domain

The Bluetooth domain is a configured `service` domain of the manifest,
named `bt` (node `bt@erxos`), of the principal that owns the machine's
services, on the BeamAsm image, whose OpenSSL its Security Manager calls
through OTP's `crypto` ([Stage 4](#stage-4-pairing-and-bonding)). It holds
no device. Its release script, `bt`, ships `kernel`, `stdlib`, `erx`, `erx_files`,
`crypto` and `erx_bt`. Its manifest row holds:

* one grant of the `line` interface, which the system domain's line
  service serves as its service named `line`, its parameters naming the controller's UART
  ([The controller's line](#the-controllers-line));
* its arguments: the advertised name (the machine's host name by
  default), the appearance, the connection limit (1 by default, at most
  `bt_connections_max`), the patch file and the manufacturer it applies
  to where the board needs one, and the service the console serves, if
  any (the opt-in of [Decisions](#decisions), 2: absent from every
  manifest erXos ships). They are application keys of `erx_bt` in OTP's
  own form, `-erx_bt Key Value` among the row's `init` arguments, which
  `application:get_env/2` reads, as the network domain's row sets
  `-erx_net interfaces` (`config/manifest/qemu-virt-development.txt`):
  `name`, `appearance`, `connections`, `patch`, a file of `erx_bt`'s
  `priv` directory, `patch_manufacturer` and `console`. The host name is
  the host part of the domain's node name
  ([design-system.md](design-system.md#identifiers));
* at stage 4, the store's grant: in a release build the vault's state
  facet `{state, "bt"}` ([design-system.md](design-system.md#state-slots)),
  and in a development build a files service of its own that the storage
  domain roots at the data volume's `bt/` directory and grants to the
  Bluetooth domain alone, as it serves SSH's `ssh_state`
  ([design-ssh.md](design-ssh.md#host-keys));
* at stage 4, the system domain's login facet, when the console is
  configured ([The console](#the-console)).

It serves three things: the `ble` facet to apps ([The `ble`
facet](#the-ble-facet)); its **control tree**, an instance of `files`
with `ctl` and `pair` ([Stage 4](#stage-4-pairing-and-bonding)), which
the manifest grants to administrators' sessions and to whichever app
templates it names; and its state at `/proc/bt`, through the inspection
schema ([Inspection](#inspection)).

It is a domain of its own, not a part of the devices domain: what it
parses comes from anyone in radio range, so it holds no device and no
grant that a radio peer should not reach through a parser defect, as the
network domain holds only its network device. The manifest check holds a
`bt` row to exactly the grants listed above, as it holds the SSH
domain's row to its grant, its login facet and its host key facet
([design-ssh.md](design-ssh.md#invariants), H3): it refuses a device, a
partition window, a second `line` grant, and any facet but the `line`
grant, the store's grant and the login facet, and a release manifest
refuses the development store.

### The controller's line

The controller is a sub-device of the system domain's PL011 unit, so it
reaches the Bluetooth domain through the home the unit rule gives:
a file tree its holder serves, with a `ctl` file for one-shot control
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)). The
**line service**, `erx_line`, a service of the system release, serves
one **line tree** for each grant of the `line` interface, which
`abi/services/line.txt` declares with its files, `ctl`'s word and three
parameters, each with its checked consumer as every facet parameter has
([design-abi.md](design-abi.md#system-manifest-representation)): `uart`,
the UART's device-tree path; `rate`, 115200 on every board this design
names; and `flow`, `none` or `rts_cts`. A line is thus configured where
every grant is, in the facet's row, and the manifest needs no field of
its own for it. The manifest check gives the unit of each `line` grant's
UART to the system domain, as property 8 gives the console's and the
host link's ([design-system.md](design-system.md#the-manifest)), and
refuses two grants that name one UART, and a grant that names the
console's or the host link's:

| File | Read | Write |
| --- | --- | --- |
| `data` | the bytes the controller sent, at least one and at most what is buffered, waiting while none is; `eio` once the line is broken | the bytes to send, in order, returning once the driver has taken all of them |
| `ctl` | `eacces` | `reset`, with or without its newline, at most 16 bytes: the steps of [A reset](#a-reset) below; answers once done, or `eio` when a power notification failed; any other write is `einval` |

`line.txt` is shaped as `windows.txt` is, an `erx_fs` grant of one tree
with typed parameters: `uart` of kind `device`, `rate` a `u64` held to
115200, and `flow` an `identifier` of `none` or `rts_cts`, each
`checked_by` the line's grant checker; the tree's name in an attach,
`line_tree`, `line`; its files, `line_file`, `data` and `ctl`; and
`line_rx_max` and `ctl`'s 16 bytes as limits. Every grantee carries
frames of at least `files_max_frame_min`, as a `files` grantee does, so
a read of `line_rx_max` answers in one frame. The line service is a
service of the system domain, so the domain service hands each grantee
its grant in the grantee's ready answer, before any of its applications
starts, and the grant ends with the grantee or with the tree behind it
([design-system.md](design-system.md#facets-a-configured-domain-serves),
"Facets of the system domain's services"). The grantee mounts it as
every `files` service of the system domain is mounted, at the place
`erx_ns` gives its facet name: `line` at `/line`, read-write on the tree
`line`, beside `machine` at `/machine`
([design-files.md](design-files.md#building-binding-and-mounting), "A
facet's mount"). `erx_bt`'s application start mounts its facets with
`erx_ns:mount_facets/1`, as a session's does, so the Bluetooth domain's
processes open `/line/data` and `/line/ctl`.

The line service parses no byte of `data`: it moves bytes between a
fid and its driver. Its one grammar of untrusted input is `ctl`'s, one
word, with a fuzz target. Its receive buffer holds at most
`line_rx_max`, 64 KiB, about five seconds of 115200 baud; a driver input
that would pass it marks the line **broken**: buffered bytes are dropped
and every read answers `eio` until the next `reset`. A loss of bytes is a
loss of synchronization, which H4 answers with a reset anyway (Part A,
section 4), so the line's one failure is the controller's restart.

Every read and write of `data` that cannot finish at once, and every
`reset`, is a waiting request whose keeper is the line's process, the
one owner of its buffer and its driver
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"): the tree's `read` and `write` answer `{wait, Line,
Request}` and return, and the line answers each when its bytes arrive,
its driver has taken them or its reset is done. So the reader's read
that waits for the controller never holds up the writer's command, on
one `data` file through one grant, and a clunk or the Bluetooth
domain's end settles a waiting read without taking bytes the next
reader should have. A `reset` begins when it arrives, unless another
runs, ahead of every `data` write: each write sent before it, the one
the driver holds and those still waiting, answers `eio`, as does each
read waiting, since no byte of the last bring-up survives a reset; a
read that arrives during one answers `eio`, and a write that arrives
during one waits at the line until the reset answers.

A request the line has begun is answered with what it did, flushed or
not ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests", rule 3): a `reset` is begun at its first step, since
stopping the driver already changes the line, and is answered when its
last step is done; a `data` write is begun once its bytes are handed to
the driver, and is answered with its count when the driver has taken
them. Each step of a reset waits on a timer of the line's or on a
process it monitors, so a reset ends; a data write may not
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests", rule 4):

* a `reset` waits for the old driver's end, then for two notifications
  of [The power line](#the-power-line), each at most 1 s at the device
  service's firmware worker once the worker's earlier requests, each at
  most 1 s, have run, and for the off and on times, and the fresh
  driver's start programs its registers without waiting; a notification
  that fails or times out answers the `reset` `eio` before its next
  step;
* a `data` write waits for the driver, which may hold bytes for as long
  as a controller holds CTS off under `rts_cts` flow. Such a write ends
  at the line's next `reset`, whose first step ends the driver and
  answers the write `eio`, and the controller's side writes one at
  every restart: the controller group's, which a command left
  unanswered for 5 s forces ([Failure handling](#failure-handling)),
  and a restarted Bluetooth domain's bring-up, whose first step it is
  ([The bring-up](#the-bring-up)). So a write a controller holds delays
  its fid's clunk, and the end of a grant whose domain has ended, until
  that reset.

A read waiting for bytes, and a write waiting behind a
`reset`, have begun nothing, and a flush or a clunk answers them `eintr`
at once. The line keeps them in one `erx_fs_waits` set, at most the
grant's 64 requests in flight, each a read's count or a write's bytes
of at most 64 KiB, beside its receive buffer, and its process's heap
bound covers both.

#### A reset

`reset` takes the line through four steps, in this order, each finished
before the next:

1. **Stop the driver.** The line's driver process ends, so nothing
   touches the UART until step 3.
2. **Device off.** Where the platform names a power line for the UART's
   device, the line service asks for its off notification and waits the
   off time ([The power line](#the-power-line)).
3. **The UART afresh.** The line service starts the driver again with
   `init => fresh` in its record, which programs the UART from nothing
   (below), empties the receive buffer and clears the broken mark.
4. **Device on.** It asks for the on notification and waits the on time,
   then discards whatever the driver delivered during the wait, which a
   controller powering up may send, and answers.

So no byte and no setting of the last bring-up survives a `reset`:
the transmit FIFO is emptied while the controller is off, the receive
side holds only what the new controller sends after the answer, and the
UART's rate, format and flow are the grant's, whatever the boot or the
last driver left. A platform with no power line runs steps 1 and 3 alone,
and its bring-up relies on `HCI_Reset`.

**Its driver is `erx_pl011`, started fresh.** For the console and the
host link, `erx_pl011` keeps what the boot left: it clears neither FIFO,
since the kernel's last lines and a person's typing are in them, and
programs the divisors only of a UART the boot left unprogrammed, so
starting it again resets neither the bytes nor the rate. A line's record carries `init => fresh`, its rate and its flow,
and `erx_pl011:program/1`, a pure function of the record, which carries
the UART's clock, returns the register steps the driver performs, in
order,
following the programming note of the PL011's manual (DDI 0183G, page
3-16):

1. `CR` written 0: the UART, the transmitter, the receiver and both flow
   enables off; then `IMSC` written 0, so the controller's bytes raise
   nothing on a line another driver shares until the start ends. The driver then waits one character time at the boot's
   divisors, as `keep` does, for the character in flight, and does not
   wait for `FR`'s `BUSY`: with CTS flow control a controller holding CTS
   off keeps the transmitter busy indefinitely.
2. `LCR_H`'s `FEN` cleared, which flushes the transmit FIFO (the note's
   step 3); then `DR` read until `FR`'s `RXFE` is set, at most 33 reads,
   the receive FIFO's 32 entries (page 2-6) and the holding register,
   which empties the receive side.
3. `IBRD` and `FBRD` written with the divisors of the record's rate, then
   `LCR_H` written whole: 8 data bits, no parity, one stop bit, FIFOs on,
   no break. The `LCR_H` write comes last because it latches the
   divisors (page 3-14).
4. `ICR` written with every interrupt bit.
5. `CR` written whole: `UARTEN`, `TXE` and `RXE`, and `RTSEN` and
   `CTSEN` when the flow is `rts_cts`, so the PL011 holds RTS off while
   its receive FIFO is full and sends only while CTS is on.

Either start ends by attaching the UART's interrupt line and then
writing `IMSC` whole with the receive and receive-timeout interrupts
and no other. The console's and the host link's start keep their
own sequence, `init => keep`, which a record that names no `init` takes
and `program/1` also returns, so one function names both and the
driver's effects are the same loop over its list. The
driver speaks the six console driver messages, unchanged. The line runs
at 115200 baud throughout; a faster rate is a measured optimization
([Performance](#performance)).

**The shared line 153.** UART0 and UART3, the host link, interrupt on one
line, so the drivers of two services of the system domain share it, and
a line has one binder. The system domain starts the host link and the
line trees under one supervisor, `erx_uart_sup`, `one_for_one`, of
**line groups**, one for each interrupt line those UARTs use. A group is
a `rest_for_one` supervisor: the line's owner first, when the line is
shared, which `erx_irq_line:owners/1` computes from the drivers'
records, then the line's services, a `one_for_one` supervisor of the
host link if its UART is on the line and each line tree on it, each
starting its own driver, which joins the owner
([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)).
So an owner's failure restarts exactly the services whose UARTs share
its line, one service's failure restarts no other, and a failure on
another line restarts nothing here. On the
Pi 4 one group holds line 153's owner, the host link and the Bluetooth
line's tree; on QEMU `virt` the host link's group holds the host link
alone. The console is not in a group: it starts its own line's owner,
under `user_sup` and `erx_console_sup`, and takes that owner's end as
its driver's, which ends the runtime
([design-runtime.md](design-runtime.md#configuration)), and the manifest
check refuses a console UART that shares an interrupt line with any
other UART the system domain drives, as it refuses one that shares the
host link's ([design-shared-devices.md](design-shared-devices.md#open-decisions)).

#### The power line

Power is the device service's, through the one kernel call for the
firmware's requests, `erx_firmware_request`
([design-kernel.md](design-kernel.md#firmware-requests)), whose
`index` names one of the notifications the platform record lists for the resource's device,
the VL805's one being index 0. The Pi 4's record lists two for UART0's
device entry, `/soc/serial@7e201000`: index 0 turns the controller off
and index 1 turns it on, each the tag `0x00038041` with the expander pin
`128 + P` and that state, and it gives the off and on times,
provisionally Zephyr's 300 ms and 500 ms
(`hci_uart_infineon.c:38-39`, `:236-246`); probe B-P2 settles the pin,
the polarity and the times. UART0's device record, which the line
service reads at a tree's start, carries the times and whether the
device has a power line.

* **Authority.** The line service asks the device service,
  `erx_devices:power(Device, off | on)`, a call inside the system
  domain. The device service makes the kernel call through the domain
  library, `erx_domain_lib:device_notify(Device, Index)`, a use of
  `erx_domain_lib:firmware/2` for a device's row
  ([design-board-sensors.md](design-board-sensors.md#the-requests)), with the
  resource UART0's device record holds, carved with `ERX_CARVE_DEVICE`
  from the entry the record names with notifications, as `pci_firmware/1`
  makes it for a bridge ([design-pcie.md](design-pcie.md#facets)). So the
  caller chooses neither the tag nor the value, only which listed
  notification, no device outside the system domain asks for one, and no
  domain but the system domain holds a resource that names the entry.
* **Deadline and answer.** The call's: a poll of at most 1 s, the answer
  matched by its buffer, `ERX_OK` for a success whose tag's response
  word has bit 31 set or is 0, and an error status for any other
  answer, for a resource without notifications and for an index past
  its device's list. The word of 0 is a fact of `0x00038041`: FreeBSD
  records that the firmware does not set the set-GPIO-state tag's
  response word, and takes a word of 0 as its answer
  (`bcm2835_mbox.c:362-370`), so that tag's declaration takes it as
  performed, once, for every caller
  ([design-board-sensors.md](design-board-sensors.md#the-requests)).
  On this tag an ignored request cannot be told from a performed one;
  the controller's bring-up after the cycle is what shows a power line
  that did nothing, and probe B-P2 records the raw word. The device
  service answers `ok` for `ERX_OK` and `{error, Status}` otherwise,
  and the line service answers `reset` with `eio` for any error,
  before its next step.
* **After a timeout.** The call's rule holds for the whole boot and every
  device: after one `ERX_ETIMEDOUT`, every later notification of the
  boot answers `ERX_ETIMEDOUT` at once without touching the mailbox. So a
  Bluetooth power request that times out also keeps the VL805's
  notification from being sent in that boot, and the bridge's
  `firmware_lost` mark follows at the PCIe domain's next request, as
  design-pcie has it; a VL805 notification that timed out likewise
  leaves the Bluetooth line unable to power-cycle, and every `reset`
  answers `eio` until the next boot. A mailbox that does not answer in
  1 s is broken for every caller, and neither consumer works around it.
* **Concurrency.** The device service makes every notification from its
  one firmware worker
  ([design-system.md](design-system.md#devices), "Firmware requests"),
  so two requests never meet in the kernel and `ERX_EBUSY` arises only
  beside a trial request or a call a restarted device service's old
  worker left in the kernel. The worker waits on the kernel call alone,
  and the device service's own process on nothing, so it answers the
  watchdog's liveness call throughout; the off and on times are the
  line service's timers, so a power cycle holds the worker for two
  calls, at most 1 s each.

**In hosted mode** the line's driver is `erx_stdio` over a descriptor the
harness opens to a Bumble controller's TCP transport and passes to the
hosted runtime, speaking the same six messages
([design-runtime.md](design-runtime.md#the-console-and-standard-io)), so
the line service, the tree and everything in the Bluetooth domain are the
ones the board runs; the hosted record names no power line, and a fresh
start of `erx_stdio` drops what it has read. A future transport, a
virtio-console port on QEMU `virt` or HCI over USB, is another driver
behind the same tree.

### What a radio peer can make the domain spend

Every bound is a constant of `abi/formats/bluetooth.txt` or of the
table, fixed before any peer arrives:

| Resource | Bound | Fixed by |
| --- | --- | --- |
| connections | the row's limit, at most `bt_connections_max`, 4; advertising stops at the limit | the controller process |
| ACL packets in flight to the controller | the controller's LE buffer count, at most `bt_acl_credits_max`, 8, split evenly among the configured connections, so no link holds another's | the controller process |
| packets and commands waiting to be written | one: the writer takes the next only after its last write returned | the controller process and the writer |
| notifications waiting for a link's credits | `bt_notify_queue`, 16 frames, per link; past it `notify` answers `{error, busy}`, and an SMP or signaling answer is dropped and counted, a dropped SMP answer failing its pairing at SMP's timeout; ATT's responses and its one indication queue past it, and one that would make the queue hold more than 18 frames ends the link, since an honest phone sends a request only after it received the last response (ATT 3.3.2) | the link |
| an ACL packet from the controller | `bt_acl_rx_max`, 251 octets of data, which the bring-up states with Host Buffer Size; a longer one is a loss of synchronization | `erx_h4` |
| messages from the controller process waiting in a link's mailbox | `bt_link_backlog`, 32, each an event or one ACL packet; the link acknowledges each once stepped, and a link at the bound is sent nothing more and disconnected ([Commands and data credits](#commands-and-data-credits)) | the controller process |
| an L2CAP frame being reassembled | 4 bytes of header and the channel's MTU: 65 for SMP, and ATT's 247 for ATT and every other channel; a longer frame ends the link, and a signaling frame past MTUsig, 23, is answered Command Reject (L2CAP 4) | `erx_bt_link_core` |
| ATT requests | one outstanding (ATT 3.3.2); a second before the response ends the link | the link |
| ATT commands waiting for a handler | `bt_write_queue`, 16; past it a command is discarded and counted, as ATT 3.3.2 allows | the link |
| a prepared (long) write | one per link, at most the characteristic's maximum, 512 octets at most | the link |
| subscriptions | one configuration per characteristic with notify or indicate, per link | the table |
| pairings | one at a time, in an open window, which closes at the first, and none during the pairing wait | the window |
| bonds | `bt_bonds_max`, 8 | the store |
| the stored state | `bt_state_max`, 4 KiB | the store |
| time | every HCI command 5 s; every handler's answer 5 s; every call of the store's backend 5 s; SMP 30 s (SMP 3.4); an indication 30 s (ATT 3.3.3) | each owner |

A peer that passes a bound loses its link and costs nothing more; the
controller's report of the disconnection returns its credits.

## Stage 1: the controller and advertising

### H4 framing

`erx_h4:split(Bytes) -> {Packets, Rest} | {error, Reason}` takes the bytes
read so far and returns every whole packet, by binary matching on the
indicator and the length field of each packet kind: an event's one-byte
length (`0x04`, code, length), an ACL packet's two-byte length (`0x02`,
handle and flags, length). Any other indicator, and an ACL length beyond
`bt_acl_rx_max`, is a loss of synchronization (Part A, section 4): the
controller process ends, and its restart resets the line and the
controller. The bound is the host's own, the same before and after the
bring-up: 251 octets, the longest L2CAP frame any link accepts (4 bytes
of header and ATT's MTU of 247), so a longer packet could carry nothing
a link takes. The bring-up tells the controller with Host Buffer Size,
by which the controller segments what it sends the host (HCI 7.3.39),
so only a controller that ignores it meets the bound. LE Read Buffer
Size bounds the other direction alone (HCI 7.8.2) and plays no part
here. `Rest`, an incomplete packet, is at most one packet's bound.
Synchronous and ISO packets are never enabled, so their indicators are
errors too.

### The bring-up

The bring-up is a state machine in `erx_bt_hci_core`, explored
exhaustively on the host. Each step sends one command and waits for its
Command Complete with status success, within the command deadline; any
other answer, or none, ends the controller process with the step and the
status as its reason.

1. **Reset the line.** The writer writes `reset` to `ctl`, and its
   answer is the core's input `line_ready`
   ([The controller process's effects](#the-controller-processs-effects)).
   The controller is fresh
   from power-on where the platform has a power line, and the UART is
   programmed afresh ([A reset](#a-reset)). The reset is under its own
   deadline, `bt_line_reset_timeout_ms`, 5 s: two power notifications,
   each answered within the mailbox's 1 s, and the off and on times, with
   room to spare; a reset that has not answered by then ends the
   controller process, so every step of the bring-up has a deadline. The
   controller process does not wait on the `ctl` write: the line's answer
   arrives as one more input, so a line service that never answers
   cannot hold it.
2. **`HCI_Reset`** (HCI 7.3.2).
3. **Identify.** Read Local Version Information (7.4.1), Read Local
   Supported Commands (7.4.2), LE Read Local Supported Features Page 0
   (7.8.3) and Read BD_ADDR (7.4.6), each shown at `/proc/bt`.
4. **Patch**, only when the row names a patch; with none, the bring-up
   goes from step 3 to step 5. The row also names the
   manufacturer the patch is for, from probe B-P3; a controller that
   reports another stops the bring-up with `patch_for_other_controller`,
   so no vendor command reaches a controller it was not written for. The
   step sends `0xFC2E` and waits `bt_patch_minidriver_ms`, replays the
   patch's records, each a command whose Command Complete it awaits, waits
   `bt_patch_launch_ms`, and then runs two steps of its own: **`HCI_Reset`
   after the patch** and **identify after the patch**, the commands of
   steps 2 and 3 again, so `/proc/bt` shows the patched version, after
   which it goes to step 5. The patched states are distinct from the
   first ones, so the bring-up patches at most once and is a line of
   states, not a loop. The waits are NetBSD's, 1 s
   and 4 s (`init_bcm43xx.c:123-125`, `:139`), the longer of the two
   permissive hosts' (Zephyr waits none and 270 ms); probe B-P5 settles
   them. The patch is read whole, by `erx_bt_patch:records/1`, before its
   first record is sent: it accepts a file made only of complete records
   of the opcodes `0xFC4C` and `0xFC4E`, which Zephyr's loader also
   requires, and refuses any other, so a damaged file sends nothing
   rather than half a patch. The controller's name, which NetBSD uses to choose the file
   (`init_bcm43xx.c:110-114`), is text the controller writes and chooses
   nothing here.
5. **Buffers.** LE Read Buffer Size (7.8.2); a controller that answers a
   length or a count of 0 has no LE buffers of its own and shares its
   BR/EDR buffers, which Read Buffer Size gives (7.8.2, 4.1.1). A length
   from 1 to 26, which 7.8.2 alone reserves, stops the bring-up; Read
   Buffer Size reserves no length, and a length or count of 0 from it,
   outside the ranges 7.4.5 gives, stops the bring-up. A controller with
   fewer buffers than the row's connection limit lowers the limit to its
   buffer count, so each link's share is at least one buffer, and
   `/proc/bt` shows the limit in force. Then Host Buffer Size (7.3.39)
   with `bt_acl_rx_max` and `bt_host_acl_packets`, 8, flow control from
   the controller staying off. The count is required, from 1 to 0xFFFF
   (7.3.39), but with flow control off the controller sends without
   counting the host's buffers (4.2), so it bounds nothing: the host
   always reads, and the line's bound is the backstop ([Commands and data
   credits](#commands-and-data-credits)). It stays a small nominal 8;
   turning flow control on would make it a limit, with Host Number Of
   Completed Packets returning the host's buffers (4.2), and needs a
   design of its own.
6. **Configure.** Set Event Mask (7.3.1) and LE Set Event Mask (7.8.1)
   with the events erXos decodes and no others; LE Set Random Address
   (7.8.4) with the identity address ([below](#the-identity-address));
   LE Set Advertising Parameters, Data and Scan Response Data (7.8.5,
   7.8.7, 7.8.8).
7. **Ready.** LE Set Advertising Enable (7.8.9) while connections are
   below the limit.

The patch ships in the Pi 4's image as a file of `erx_bt`'s `priv`
directory, unmodified, under its license (Cypress's Driver End User
License Agreement, `LICENSE.cypress` of the firmware repository, which
grants reproduction and distribution "in object code form only, solely
for use in connection with Cypress integrated circuit products" and
forbids modification), with its notice in the image's `NOTICES`; the Pi 4's
manifest alone names it. It is in the boot image rather than on the
boot partition beside the VideoCore firmware because erXos, not the
firmware, reads it, and only the slot writer may read a slot's partitions
([design-system.md](design-system.md#the-manifest), property 8).

### Commands and data credits

The controller process keeps one command in flight: it sends the next
only when the last was answered, by Command Complete or Command Status,
and the controller's latest `Num_HCI_Command_Packets` is at least one (HCI
4.4); a Command Complete or Status with opcode `0x0000` only updates that
count, and one whose opcode is neither `0x0000` nor the command in
flight's ends the controller process, as a loss of synchronization
does. Commands in this design are few and none is urgent, so one in
flight is enough and makes every command's answer the answer to the last.
A command's deadline, `bt_command_timeout_ms`, starts when the command
falls due, not when it is written, and runs through any time the
controller allows none: a controller that answers
`Num_HCI_Command_Packets` 0 and never follows with an opcode-0 event
ends the controller process at the deadline. Which command is due is
decided again on every step, and the command is chosen and taken only
when the writer takes it, so a disconnect for a handle that has gone,
even one the controller has since given a new peer, or advertising at
the limit, is never sent. A link's disconnect stays with its handle,
asked and then taken, until the handle's Disconnection Complete, so a
second request is ignored and no disconnect is decided for a handle
after its Disconnection Complete. A connection on a handle whose
disconnect is handed to the writer and unanswered ends the controller
process: the controller may carry that disconnect out on the new peer,
and the restart, the one recovery that exists, resets every link rather
than leaving the core to guess which peer the disconnect reached.
Unknown Connection Identifier (Vol 1 Part F, 2.2) means the handle has
gone, which Disconnection Complete reports or has reported; any other
failure ends the controller process. The controller reuses handles, so a
link is named by its handle and the connection that gave it the handle: the
controller process gives a link its name when it starts it, names the link in
everything it sends it, and every request of a link, a packet, a disconnect or a
Long Term Key reply, carries the name, in one envelope whose name the core checks before it reads the
request. A request whose name is not its handle's current link is refused and
changes nothing, so a link that has gone can never send a packet
to, or disconnect, the peer the controller gave its handle next. A link
answers LE Long Term Key Request with `{ltk_reply, Key}`, or
`{ltk_reply, none}` when it has no key, which the controller process
sends as Reply or Negative Reply for the link's own handle (HCI 7.8.25,
7.8.26) and whose Command Complete it passes back as
`{ltk_reply_complete, ok | {failed, Status}}`; the reply waits with its
handle as a disconnect does, goes with it at Disconnection Complete, and
once handed to the writer and unanswered ends the controller process at a
connection on its handle. A command is in
flight once the writer has it, and the writer takes the command before
any queued packet: an answer to a command still waiting for the writer
is a controller fault and ends the controller process. The line's reset,
a bring-up wait and a command are the states of one slot, each holding
its own deadline, so the core has at most one deadline at a time and
leaving a state drops it.

ACL packets to the controller use packet-based flow control (HCI 4.1.1).
The controller process keeps, for each live handle, how many of its
packets are outstanding, from the moment the link hands one over, and
the free credits are derived: the buffer count from the bring-up, at
most `bt_acl_credits_max`, less the live handles' outstanding packets.
Number Of Completed Packets returns a handle's packets, and a handle's
Disconnection Complete returns all of them by removing it (HCI 4.3),
which cannot be forgotten since nothing else holds them. A completion
that names a handle that is not live, or more packets than the handle
has given the writer, is a controller fault and ends the controller
process: a forged report can return no credit for a packet that was
never sent, nor for one still waiting for the writer, so what waits for
the writer stays within the credits however long the line stalls. Each
link may hold at most its share of the buffers in flight, the buffer
count divided by the connection limit, at least one since the bring-up
keeps the limit at most the buffer count. A link learns its share when it
starts, and its handle's returned packets from the core, which passes
each live handle's count in Number Of Completed Packets to the handle's
link as `{completed, Count}`; so a link hands over a packet only while
its outstanding packets are below its share, and its notifications wait
in its own queue, at most `bt_notify_queue`. The core answers a packet
beyond the share with `busy`, which a link that counts never meets; a
link that meets it ends, and its end disconnects it
([The controller process's effects](#the-controller-processs-effects)).
Controller-to-host flow control is not enabled: the host always reads,
and the line's bound is the backstop.

**A link's backlog** is the other direction's share. The controller
process never waits on a link, so what it forwards faster than the link
steps would otherwise wait in the link's mailbox without bound, as it
does while the link makes its two calls at its start ([The link's
messages](#the-links-messages)). The core keeps, for each live handle,
how many of the messages it has sent the handle's link, events and ACL
packets alike, the link has not yet taken; the link's core returns
`taken` from its step of each such message, which the link process
sends as a request in the link's envelope like its packets, so the
acknowledgement of a link that has gone changes nothing. A message for
a link whose backlog is `bt_link_backlog`, 32, is not sent: the core
drops it, sends that link nothing more, and asks the handle's
disconnect with Remote Device Terminated Connection due to Low
Resources (`0x14`, one of the reasons HCI 7.1.6 allows), and the link
ends at its `link_down` as every link does. So a link's mailbox holds
at most 32 of the controller's messages, about 8 KiB, whatever the peer
sends and however long the link is held up, and a peer that outruns
its link loses the link, as a peer that passes any other bound does.
An honest phone does not meet it: it sends an ATT request only after
the last response (ATT 3.3.2) and a link steps a packet in far less
time than the line takes to carry one; a stream of Write Commands
past `bt_write_queue` is discarded as the link steps it, not held.

The controller process does no I/O itself: a reader process keeps one
read of `data` outstanding and sends the bytes it got, waiting for the
controller process's acknowledgement before the next read, and a writer
process writes what the controller process gives it, one packet or
command at a time, acknowledging each once its write of `data` returned;
the controller process gives the next only after the acknowledgement.
So what waits for the line is bounded locally, by one item at the writer
and the credits and the command slot at the controller process, whatever
the controller reports; the controller process never waits on the line
and always takes events; what the line delivers faster than the
controller process consumes waits in the line service, up to its bound;
and what the controller process forwards faster than a link consumes
waits in that link's mailbox, up to its backlog. How the process
finds its reader, writer and links, and where its configuration comes
from, is [The controller process's effects](#the-controller-processs-effects).

Events the controller process decodes: Command Complete, Command Status,
Disconnection Complete, Encryption Change, Encryption Key Refresh
Complete, Number Of Completed Packets, Hardware Error, and the LE Meta
events LE Connection Complete, LE Long Term Key Request and LE
Connection Update Complete. Any other event is counted and dropped after
its length is checked. Hardware Error ends the controller process.

### The controller process's effects

`erx_bt_hci` is a loop around `erx_bt_hci_core`: it turns each message
into one input, steps the core and performs the actions in order. Its
group, `erx_bt_host_sup`, `one_for_all`, starts its children in this
order: `erx_bt_link_sup`, `erx_bt_line_rx`, `erx_bt_line_tx`, then
`erx_bt_hci`. The first three register their names in the Bluetooth
domain's runtime, so when the controller process starts its siblings
run and it reaches each by its registered name; the reader and the
writer answer whichever process gave them work and never look it up.
Any child's end ends the whole group, which starts again in the same
order, so the four always belong to one run of the core. Neither the
reader nor the writer traps exits, so the group's shutdown also ends one
blocked in a call to the line service.

**Configuration.** At its start the controller process builds the
core's `new/1` configuration from owners that outlive its group, so a
restart of the group rebuilds the same configuration:

* `connections`, from the application key `connections`
  ([The Bluetooth domain](#the-bluetooth-domain));
* `address`, the identity address, from the store,
  `erx_bt_store:address/0` ([The identity address](#the-identity-address));
* `advertising_data` and `scan_response_data`, from `erx_bt_adv:data/1`,
  a pure function of the UUIDs the registry's table marks `advertise`
  (`erx_gatt_srv:advertised/0`), the name and the appearance
  ([Advertising](#advertising));
* `patch`: `none` when the row names no patch, else the manufacturer from
  `patch_manufacturer` and the records `erx_bt_patch:records/1` returns
  for the file `patch` names. The file is read whole here, so a file the
  reader refuses ends the process before the line is touched.

It then steps `start`, whose one action is `line_reset`.

**The writer** takes two kinds of item. Bytes it writes to `/line/data`,
and acknowledges with `written`. The action `line_reset` it carries out
by writing `reset` to `/line/ctl`, and acknowledges with `line_ready`.
The core gives `line_reset` only as the bring-up's first step, before any
other item, so the writer is idle then and still holds one item at a
time. A write that fails, `eio` from `data` or from `ctl` included, ends
the writer and so the group: the group's restart is the recovery for a
broken line and for a failed power notification alike, and the core has
no input for a line failure. A reset that never answers is the core's
own: the slot's deadline passes and the core stops with
`line_reset_timeout`.

**The reader** opens `/line/data` at its start and reads only after an
acknowledgement; the controller process gives the first when it steps
`line_ready`. A read waiting at a reset answers `eio`
([Concurrency](#concurrency)), so a reader that read before the reset
answered would end its group at every start; reading only after an
acknowledgement puts the bring-up's reset before every read, with no
case of its own. Each read asks for `line_rx_max` bytes, so one read can
take everything the line holds. The controller process appends what
arrives to the bytes the last split left, splits them with
`erx_h4:split/1`, decodes each packet with `erx_hci` and steps it, then
acknowledges. A split error ends the controller process
([H4 framing](#h4-framing)); a read that fails ends the reader, and so
the group.

**Links.** The core's link actions go to link processes, one for each
link the core has named:

* `{link_up, Name, Info}`: the controller process makes the link's
  `Conn`, a fresh reference, starts `erx_bt_link` as a temporary child of
  `erx_bt_link_sup` with `Name`, `Conn`, `Info` (the peer's address,
  the identity address, `acl_tx_max` and the link's share) and its own
  pid, monitors it, and maps `Name` to it;
* `{to_link, Name, Event}`, `busy` among the events: sent as `{hci, Event}`
  to the process `Name` maps to; an action for a name that maps to none is dropped, since
  its link has already ended. Every message for a link, `busy` included, leaves the core
  through the one count of the link's backlog ([Commands and data credits](#commands-and-data-credits));
* `{link_down, Name}`: the controller process removes `Name` and ends its
  process through `erx_bt_link_sup`;
* a link process that ends while its name is mapped: the controller
  process removes the name and steps `{request, Name, {disconnect,
  16#13}}`, Remote User Terminated Connection (`bumble/hci.py:752`). So a
  link's end is its disconnect, whatever ended it; a link that wants
  another reason asks for it before it ends, and the core ignores a
  second disconnect for the handle and refuses one whose name is no
  longer current ([Commands and data credits](#commands-and-data-credits)).

The core's names are unique only within one run of the core: the serial
in a name starts again at each `new/1`. So the controller process maps
full names, never handles, to link processes, and every link process is
a child of `erx_bt_link_sup` in the same `one_for_all` group, which ends
with the core: no link outlives the core that named it, and no name a
later run gives can reach it. What leaves the group is `Conn`, which is
unique for the runtime's life, so no app meets a name that a later run
reuses ([A name dies at once](#a-name-dies-at-once)). From stage 2 a link
registers its `Conn` with the registry when it starts, and the registry
monitors it ([The link's messages](#the-links-messages)).

Before stage 2 a link process has no channels: it hands over no packet,
drops and counts every ACL packet it is given, and ends at `link_down`;
stage 2 gives it the fixed channels ([Links: the fixed
channels](#links-the-fixed-channels)). The core's `{ready, Facts}`, and
`facts/1` at any moment, are what the controller process shows at
`/proc/bt` ([Inspection](#inspection)).

### The identity address

erXos's identity on the air is a **static random address** that the
Bluetooth domain makes from `erx_bytes:entropy/1` and sets with LE Set
Random Address; advertising uses it as its own address. It names neither
the board nor its controller, so no Bluetooth address of an erXos
machine names its hardware, as no IPv6 address does
([design-network-stack.md](design-network-stack.md#ipv6-neighbour-discovery-and-autoconfiguration)).
It needs no vendor command to set the public address and no address in
the device tree. Its one owner is the store, `erx_bt_store`, from stage
1 on: before stage 4 the store makes a new one when it starts, which is
at each start of the Bluetooth domain, and keeps it in memory, which
costs an unbonded phone nothing, since it rediscovers at every
connection. From stage 4 it is part of the stored state and lasts as
long as the bonds that name it. The store sits before the controller
group in `erx_bt_sup` ([Concurrency](#concurrency)), so a restart of the
group keeps the address, and the controller process asks for it,
`erx_bt_store:address/0`, at each of its starts. Its form, two top
bits set and the rest neither all zeros nor all ones, is Vol 6 Part B
1.3.2.1's, unverified until that part is read; the test of its maker
checks it against Bumble's address parser.

### Advertising

The controller process advertises, connectable and undirected, on all
three channels at a 100 ms interval, while connections are below the
row's limit. The data are a pure function of the table, the name and
the appearance, `erx_bt_adv:data/1`, which the controller process calls
at its start ([The controller process's effects](#the-controller-processs-effects));
the table is fixed for the domain's life, so every start computes the
same bytes:

* **advertising data:** the Flags structure (LE General Discoverable,
  BR/EDR not supported) and the list of UUIDs of the services whose
  declaration says `advertise`, as complete lists of 16-bit and 128-bit
  UUIDs;
* **scan response data:** the complete local name, or the shortened name
  where it does not fit, and the appearance when it fits.

Each is at most 31 bytes, and the manifest check computes both and
refuses a configuration whose advertised UUIDs do not fit; the name is
shortened rather than refused. The AD type values come from Bumble's
`core.py:1594-1622`, unverified against the supplement.

When a connection completes, the controller stops advertising, as it does
for connectable advertising, and the controller process enables it again
while connections remain below the limit. A connection that completes
while the enable is written and unanswered came from that enable, which
the controller carried out before it answered, so the enable's answer
leaves advertising off.

## Stage 2: the GATT server

### Declarations: `abi/gatt`

A service is one checked-in file, `abi/gatt/NAME.txt`, as a keyboard
layout is ([design-display.md](design-display.md#input-events)). For
example:

```text
# nus: a serial line in the style of Nordic's UART service.
service nus 6e400001-b5a3-f393-e0a9-e50e24dcca9e advertise
#              name uuid                                 max  accesses
characteristic rx   6e400002-b5a3-f393-e0a9-e50e24dcca9e 244  write open write_without_response open
characteristic tx   6e400003-b5a3-f393-e0a9-e50e24dcca9e 244  notify open
```

A `service` line gives the service's name, an identifier, its UUID, 16-bit
or 128-bit, and optionally `advertise`. Each `characteristic` line gives
its name, an identifier unique in the service, its UUID, the maximum
length of its value, at most 512, and the accesses it allows, each with
the level it requires: `read`, `write`, `write_without_response`,
`notify` and `indicate`, each `open`, `encrypted` or `authenticated`. A
readable characteristic may end with `value` and its initial value in
hexadecimal, so a constant needs no handler.

`tools/gen_gatt.rb` reads every file and generates `erx_gatt_decl`, one
term per service, the list of names the manifest check holds a row
to, and the names of those that say `advertise`. A UUID has one
spelling: one of the Base UUID with a 16-bit value is written in 16
bits, since Find By Type Value compares a service declaration's value
octet by octet (ATT 3.4.3.3) and a phone looks for the 2-octet form. It
refuses a missing or repeated `service` line, a name that differs
from its file's, a UUID that is malformed, the 128-bit form of a 16-bit
one included, or is one of the GATT and GAP
declarations' own (the enum `gatt_uuid` of `abi/formats/bluetooth.txt`),
a service named `gap` or `gatt`, the names the table
gives GAP's and GATT's own services, two characteristics of one name or UUID, a maximum
over 512, an access without a level or repeated, a `notify` and an
`indicate` with different levels, a characteristic with no access, an
initial value longer than its maximum or on a characteristic that is not
readable, and a byte above 0x7f or a control byte. Nothing reads a
declaration at run time, so it is not an input to fuzz.

Which services a machine serves is the manifest's: each `ble` facet row
names, in its `services` parameter, the services its grantee handles, and
the Bluetooth domain's row names its console's. The manifest check refuses
a service no file declares, a service two rows name, two served services
of one UUID, more than `gatt_services_max` services, and advertising data
that do not fit.

### The attribute table

`erx_gatt_db:build/1` lays out, in this order: the GAP service, with
Device Name and Appearance, read `open`; the GATT service, with Service
Changed, `indicate open`, and its Client Characteristic Configuration;
then each served service in the order of its name, each characteristic as
its declaration, its value and, when it allows `notify` or `indicate`,
one Client Characteristic Configuration descriptor. The descriptor is
readable openly and writable at the one level of the characteristic's
`notify` or `indicate`, whichever it declares, since the generator
refuses the two at different levels, so subscribing is gated as
notifying and indicating are, for Service Changed's `indicate open` as
for any other; on a link that holds a key the write requires at least
`encrypted`, since there it writes the bond's kept configuration
([The link's messages](#the-links-messages)). The GATT service has
no Database Hash: with Service Changed alone, robust caching is not
required (GATT 2.5.2.1).

A characteristic's value is the one the handler last set, or the
declared initial value, or empty: a read never waits on an app. A read of
a value that changes between two Read Blob requests may tear, which ATT
leaves to the higher layer (3.2.9); the one reader such tearing would
hurt, a long read of a value an app changes while a phone reads it, is
named in no stage.

### The ATT server

`erx_gatt_server:request(Pdu, Server, Bearer) -> {Actions, Bearer}`
answers one PDU over `Server`, the table, the values the handlers last
set and the link's security, and the bearer's state; `reply(Ref, Answer,
Server, Bearer)` takes a handler's answer to the write `Ref`, and drops
it unless the bearer waits on that write, so an answer that comes after
its write timed out is never taken for the next one; and `notify(Kind,
Key, Value, Server, Bearer)` makes a notification or an indication the
gate allows. The actions are the PDUs to send, the write for the
handler, numbered by the bearer, and the events for the handlers. A
`Ref` is the link's own, from 1 on every bearer, so it never leaves
the domain as it is: the facet hands its handler a `Req` it makes
unique, and maps it back to the link and its `Ref`, accepting an
answer only for a `Req` it delivered to that handler and not yet
answered ([The `ble` facet](#the-ble-facet)). It
answers Exchange MTU with 247, Find Information, Find By Type Value, Read
By Type, Read, Read Blob, Read By Group Type, Write Request, Prepare
Write and Execute Write, and takes Write Command and Handle Value
Confirmation; every other request is Request Not Supported with handle
0, every other command is ignored (ATT 3.3), and a request whose length is
wrong is Invalid PDU. These cover the server's mandatory features and
the optional ones a first stage needs (GATT Table 4.1): Read Multiple and
Read Multiple Variable stay unsupported. A write of a characteristic's
value whose length exceeds its maximum is Invalid Attribute Value Length;
a prepared write that would exceed it, or that names another
characteristic than the one already prepared, is Prepare Queue Full,
and one to a descriptor is Write Not Permitted. Execute Write joins the
parts from an empty value, each at an offset at most the length the
parts before it wrote, so the handler receives the whole value; ATT
leaves a long value's meaning to the higher layer (3.4.6.1). A request
longer than the bearer's MTU is Invalid PDU, and a command that long is
ignored.

`erx_att` is the PDU codec, whose codes `abi/formats/bluetooth.txt`
holds, with a fuzz target. Its MTU is per bearer, 23 until the client exchanges
it (GATT 5.2.1).

### The `ble` facet

An app reaches the Bluetooth domain only through its `ble` facet, an
instance of the interface `abi/services/ble.txt` declares, with one
parameter, `services`, a set of at most `gatt_services_max` identifiers.
The facet is a process of the Bluetooth domain that the registry makes
when the domain service introduces the grantee, as the network service
makes its grants
([design-system.md](design-system.md#the-network-domain)). Its operations:

| Operation | Answer |
| --- | --- |
| `attach(Service)` | `{ok, #{Char => Limits}}`: the caller becomes the service's handler; the facet monitors it, and its end detaches it |
| `set(Service, Char, Value)` | `ok`: reads return `Value` from now on |
| `notify(Conn, Service, Char, Value)` | `ok` once queued for the link, or `{error, busy}` when its queue holds `bt_notify_queue` |
| `indicate(Conn, Service, Char, Value)` | `ok` once the phone confirms |

`Service` is one the grant names; `Char` one the declaration names. A
handler receives, through the envelope rule, which the client module
`erx_gatt` alone takes off ([design-domains.md](design-domains.md#the-funnel)):

| Event | Meaning |
| --- | --- |
| `{connected, Conn, #{address := A, bonded := boolean(), level := L}}` | a phone connected, or its link's security changed: `level` is what the link reaches now, `open` until it is encrypted and then its key's, and `bonded` is true once the link is encrypted with a kept bond's key, a resolved bond's or its own pairing's once kept |
| `{mtu, Conn, Mtu}` | the bearer's MTU changed; a notification carries at most `Mtu - 3` octets |
| `{subscribed, Conn, Char, none \| notify \| indicate}` | the phone wrote the characteristic's configuration |
| `{write, Req, Conn, Char, Value}` | a write the gate allowed; the handler answers `erx_gatt:reply(Req, ok \| {error, Code})`, where `Req` is a reference the facet made for this write, which names it to no other handler, link or write |
| `{disconnected, Conn}` | the phone left; `Conn` is dead |

The link takes the next request of its phone only after the handler
answered the last write request, so a handler sees one write request of a
link at a time, as ATT's sequential protocol has them; write commands
queue behind it, within `bt_write_queue`. For a write command the
handler's answer is awaited and dropped, so the queue is its pace. An
answer `{error, Code}` with `Code` from `0x80` to `0x9F` is the ATT
Application Error of that code; Value Not Allowed is `value_not_allowed`.
No answer within 5 s is Unlikely Error (`0x0E`). A service with no
handler serves reads from its values and answers writes Unlikely Error.

`connected` and `disconnected` come from the registry, which monitors
every link: so every handler of a link's services hears of its end,
however the link ended. `erx_gatt_service`, a behaviour over the facet,
turns these into callbacks for an app that wants them, and `erx_gatt`'s
calls are what it uses.

### Links: the fixed channels

A link process reassembles L2CAP B-frames from the ACL packets of its
handle, as HCI 5.4.2's packet-boundary flags mark them, and refuses a
frame longer than its channel's bound, a continuation without a start, a
start inside a frame or bytes past a frame's length, which ends the link
(`erx_l2cap`). Channel `0x0004` is the ATT bearer; `0x0006` is SMP; on
`0x0005`, LE signaling, it answers Command Reject, "Command not
understood", to every command but a response, and drops responses:
erXos asks no connection parameter update and offers no credit-based
channel. A signaling frame longer than MTUsig, 23 octets, is answered
Command Reject, "Signaling MTU exceeded", with 23, as L2CAP 4 requires,
rather than ending the link; one too short to carry a command, or whose
Data Length disagrees with it, is not correctly formed (L2CAP 4) and is
dropped. A frame on any other channel is dropped and counted.

### The link's messages

`erx_bt_link_core:step(Input, Now, Core) -> {Actions, Core}` is the
link's pure core, and `next_deadline/1` its earliest deadline: a
handler's answer, 5 s; an indication's confirmation, 30 s (ATT 3.3.3);
a pairing's step, 30 s (SMP 3.4); the next look at the pairing wait
before a Security Request ([Reconnection](#reconnection)). The link
process reads the clock, keeps one wake-up at that deadline and steps
`expired` when it fires.

**A link's pid is its address, and the runtime reports its end.** Every
message to a link is `{Role, Input}`, sent to its pid, but for the
registry's notifications, which are requests (below); every message
from it is `{erx_bt_link, Link, Message}`, sent to the owner's
registered name, where `Link` is the link's pid, and for the controller
process, which maps its core's names to links, the link's name
([The controller process's effects](#the-controller-processs-effects)).
An owner that keeps a link's pid past one answer monitors the link from
the moment it takes the pid, and acts on the link's end at the
monitor's `'DOWN'`:

| Owner | Monitors a link | At the link's end |
| --- | --- | --- |
| the controller process | from `link_up` | disconnects the handle |
| the registry | from the link's `join` | tells the handlers `disconnected`; `Conn` answers `{error, gone}` from then on |
| the window | from its `open` verdict until the link reports the pairing failed or hands its bond to the store (`keeping`) | counts the pairing failed, `disconnected`, for the pairing wait, and writes `failed ADDR disconnected` if the window is still open |
| the store | from a `resolve` it answers with a bond, or a `keep` it answers `ok` | drops the link |

So no owner learns of a link's end from the link. A kill, the shutdown
that `link_down` gives, a raise in `step/3` and the controller group's
restart all reach every owner that holds the pid, and the link traps no
exits and has no `terminate/2`. An alias would not do: no process can
monitor one, and the pid already dies with the link. A link monitors no
owner: the store, the registry and `erx_bt_fs` start before the
controller group under `erx_bt_sup`, `rest_for_one`, so each outlives
every link, and the end of one ends the group after it
([Concurrency](#concurrency)).

**The core is the one table of who sends what.** `Role` is `hci`,
`window`, `registry` or `store`. The core's `input()` is keyed by it, and
so is its `action()`, the controller process's included (`{hci, {send,
Boundary, Data}}`): the link process steps each message as it arrives
and sends each action `{Role, Message}` to that role's owner, so the
core's clauses are the only list of what each owner may send, and the
process keeps no copy of it, nor of any core state. A message no clause
takes is a defect of the domain's own code and ends the link through
`step/3`'s raise. The role is a label, not a proof: only the domain's
own processes reach a link, and a peer's bytes reach it only as the
controller process's `acl`.

**The link's start.** `erx_bt_link_sup:start_child/1` is a synchronous
call of the controller process, so `init/1` reads only its argument and
nothing in it can fail: the link's name and `Conn`, the controller
process's pid and, from `link_up`'s `Info`, the phone's address, which
`erx_hci` decodes as `{public | random, Address}`, the identity address
the controller advertises with, `acl_tx_max` and the share. `erx_hci`
reads LE Connection Complete's Status first: a failed one carries no
valid parameter but its Status (HCI 4.5.1, Table 4.1), so it decodes as
`{le_connection_complete, {failed, Status}}` with nothing after the
Status read, whatever those octets hold, and the controller core takes
it as no connection. Only a successful one is read further, and there a
Peer_Address_Type other than `0x00` and `0x01` is reserved (HCI
7.7.65.1), so `erx_hci` decodes it as malformed, as it does a reserved
handle, and the controller process ends as for any malformed event: a
controller's breach of HCI, not a start that fails. The controller
process's `{ok, Pid} = start_child(...)` therefore holds. Then, before
its first step, the link makes its only two calls, each to an owner
that never waits on a link:

1. `erx_bt_store:resolve(Address) -> none | Bond`. The store resolves
   the address against the bonds ([Reconnection](#reconnection)) and
   answers the one bond it names, with its LTK, level, identity, table
   hash and subscriptions and without its IRK, so no other bond's key
   leaves the store. A store left `unknown` by its start's read
   holds no bonds and answers `none`; one `unknown` after an unconfirmed
   `put` answers from the bonds it holds, so bonds already kept work on a
   trial boot (below). The
   address names a candidate, not a proven bond: what of the bond the
   link may use before its encryption is the key alone (below).
2. `erx_gatt_srv:join(Conn, #{address := Address}) -> #{table := Table,
   values := Values}`. The registry maps `Conn` to the link, tells the
   services' handlers `connected` at level `open` and not bonded, as
   every link starts, and answers the table and the values the handlers
   last set. It takes `join` and `set` in one order, so every `set`
   after the values it answered reaches the link.

`erx_bt_link_core:new/1` builds the core from these. What the controller
process sends meanwhile waits in the mailbox, within the link's backlog
([Commands and data credits](#commands-and-data-credits)), and is
stepped in order after. A call that fails, or is not answered within
OTP's 5 s default, ends the link, and the phone reconnects.

**A link is its bond's only from its encryption.** An address is
whatever the peer sends: a public address is copied by anyone, and a
resolvable private address resolves for whoever repeats it, since `ah`
is computed from the address's own random part and the IRK alone (SMP
2.2.2). Only the key proves the bond, since a central must hold the
LTK to set up an encrypted session with it (SMP 2.4.4.2), which is the
same fact the gate rests on. So the core holds a resolved bond in two
parts. The key it holds from its start: it answers the Long Term Key
Request and gives the gate its column, so an `encrypted` access answers
Insufficient Encryption and the phone knows to encrypt (ATT 3.2.5). The
rest, the bond's subscriptions and table
hash, enters the core only at the transition that sets `encrypted`
([One table, one gate](#one-table-one-gate)): there the link restores
the subscriptions, tells the registry `bonded`, and may indicate
Service Changed ([Reconnection](#reconnection)). Every store write for
a bonded link, `subscriptions` and `served`, is made from that rest, so
a link not yet encrypted has nothing to send one from, and a peer
without the key never changes a bond's kept state. A pairing's bond is
made over its link encrypted with the pairing's key (SMP 2.4.3.2), so the
same holds for it. A configuration
write is a write of that state, which GATT lets a server guard (GATT
3.3.3.3: "Authentication and authorization may be required by the
server to write the configuration descriptor"): on a link that holds a
key, the descriptor's write requires at least `encrypted`, so until the
link is encrypted the gate answers it Insufficient Encryption, as it
answers any `encrypted` access there, and the configuration stays the
link's default.

No setting says whether a link may pair. Every link runs its Security
Manager, and the window decides: its verdict is `closed` while no window
is open, and no window opens while the start's read has left the store
`unknown` ([Refusals](#refusals-and-error-results)), so a domain running
without bonds refuses every Pairing Request with Pairing Not Supported
through the verdict, and a pairing whose store fails it later fails
`unavailable` ([Bonds and the store](#bonds-and-the-store)). Before
stage 4, which brings the window, the link's Security Manager is
disabled and answers so itself.

**The messages.** Each row names the consumer that needs the message.
LE Connection Update Complete goes to no link: erXos asks no parameter
update and new parameters change nothing, so the controller process
takes it and forwards nothing.

| From, to | Message | When | Consumer, and what breaks without it |
| --- | --- | --- | --- |
| controller process, link | `{acl, Boundary, Data}` | an ACL packet of the link's handle | reassembly; no channel works |
| | `{completed, Count}` | the controller sent `Count` of the link's packets | the link's share; once used up, nothing more is sent |
| | `busy` | the controller's core counted the link past its share | the link ends, since its count of packets outstanding is wrong |
| | `{le_long_term_key_request, Handle, Rand, Ediv}`, `{encryption_change, Status, Handle, Enabled}`, `{encryption_key_refresh_complete, Status, Handle}` | the controller's reports for the handle, as `erx_hci` decodes them (HCI 7.7.65.5, 7.7.8, 7.7.39) | the one key's transition ([One table, one gate](#one-table-one-gate)); nothing encrypts |
| | `{ltk_reply_complete, ok \| {failed, Status}}` | the controller answered the link's `ltk_reply` | a Reply that failed counts as none |
| link, controller process | `{send, Boundary, Data}` | while the link's packets outstanding are below its share | the writer; nothing reaches the phone |
| | `{ltk_reply, Ltk \| none}` | at each Long Term Key Request | Reply, or for `none` Negative Reply (HCI 7.8.25, 7.8.26); the phone's encryption never completes |
| | `taken` | with the step of every message the controller process sent | the link's backlog ([Commands and data credits](#commands-and-data-credits)); without it the controller's messages would wait in the mailbox without bound |
| link, window | `{admit, Tag, Address}` | a Pairing Request | the window's verdict; at `open` the window monitors the link |
| | `{passkey, Tag, N}` | Passkey Entry made its passkey | the `passkey` line; nobody can type it |
| | `{outcome, Tag, {failed, Reason}}` | the admitted pairing failed while the link ran it | the `failed` line and the pairing wait; the window then drops its monitor. Without it every failure would end as `disconnected` |
| | `{keeping, Tag}` | the link handed the pairing's bond to the store, in the step that sends `keep` | the window drops its monitor and takes the store's `outcome` as the pairing's; without it a link that ends while the store writes would count a kept bond as failed |
| | `wait` | a link holding a kept bond's key, at its start and at the deadline the last answer set | the Security Request ([Reconnection](#reconnection)), which SMP 2.3.6 holds to the pairing wait |
| window, link | `{admission, Tag, Verdict}` | at once, for each `admit` | the Security Manager |
| | `{withdraw, Tag}` | the window closes while the link runs its pairing, before its `keeping` | Pairing Failed, Unspecified Reason, and the outcome `withdrawn` ([The pairing window](#the-pairing-window)); after the link sent `keeping` it changes nothing |
| | `{wait, Ms}` | at once, for each `wait` | at `0` the link sends the Security Request unless the phone has begun encryption; otherwise it asks again `Ms` later |
| link, registry | `{write, Ref, Key, Value}` | a write the gate allowed | the service's handler, which the facet hands it under a fresh `Req` |
| | `{subscribed, Key, none \| notify \| indicate}`, `{mtu, Mtu}` | the phone wrote a configuration; the bearer's MTU changed | the handlers' `subscribed` and `mtu` |
| | `{security, #{level := L, bonded := B}}` | the link's level or `bonded` changed | the handlers' `connected` |
| registry, link | `{answer, Ref, Answer}` | the handler answered the write `Ref` | the write's response; an answer to a write no longer awaited changes nothing |
| | `{set, Key, Value}` | a handler set a value | reads return it |
| | `{notify, notify \| indicate, Key, Value}`, a request of `gen_server:send_request/2`, answered `ok \| {error, Reason}` | a handler's `notify` or `indicate` | the registry answers its own caller from the answer, and the request's monitor makes a link that ends first answer `{error, gone}`; a caller's `From` passed to the link would wait for nothing when the link ends |
| link, store | `{keep, Tag, Bond, Subscriptions}` | the pairing's third phase ended | the store keeps the bond, tells the window the outcome and, at `ok`, monitors the link ([Bonds and the store](#bonds-and-the-store)) |
| | `{subscriptions, Subscriptions}` | a link encrypted with a kept bond's key changed a configuration | GATT 3.3.3.3: the Write Response waits for the store's answer |
| | `{served, Hash}` | a link encrypted with a kept bond's key had Service Changed confirmed | the bond's table hash; not answered, since a hash not kept costs one more Service Changed |
| store, window | `{outcome, Link, Tag, {bonded, Identity, Level} \| {failed, Reason}}` | the store answered the `keep` of `Link`, the pid it came from | the `bonded` or `failed` line and the pairing wait |
| store, link | `{kept, ok \| {error, Reason}}` | the store answered `keep` or `subscriptions` | for `keep`, at `ok` the key is a kept bond's, otherwise the link ends; the configuration write's response or Unlikely Error |
| | `forgotten` | the link's bond is forgotten, or missing from the state read after a `put` left unconfirmed | the link ends ([Bonds and the store](#bonds-and-the-store)) |

**A pairing's outcome has one ordering point: the link's step that ends
its third phase.** Before that step the pairing is the link's: a
withdrawal or the link's end fails it, and no key reaches the store.
In that step the link sends `keep` to the store and `keeping` to the
window, and from it the pairing is the store's: the link's Security
Manager is done, so a withdrawal that arrives later changes nothing,
and the store's answer to `keep` is the outcome, which it sends the
window whether or not the link still lives. The window learns which
side of the step a link's end fell on from the link's own messages,
since a process's messages reach the window before the `'DOWN'` its end
gives: `keeping` then `'DOWN'` is a pairing the store decides,
`'DOWN'` alone one the link's end failed. So the outcome the window
counts and writes is the store's own answer to `keep` whenever the
store was asked, and a pairing the window counts failed before that
step never reached the store; a `put` left unconfirmed is the store's
`unavailable`, with what follows it there. The window matches each
outcome by the link and its tag.

The store finds the bond of `subscriptions` and `served` by the link it
monitors, and `kept` carries no tag because a link asks the store one
thing at a time and the store answers every request
([Bonds and the store](#bonds-and-the-store)), so a link never
abandons one and no late answer can meet a later request: a pairing's
`keep` comes only from a link without a kept bond's key and
`subscriptions` only from one encrypted with it, and a configuration
write, request or command, waits for the store's last answer as a
write request waits for its handler. The link process takes
the registry's request in `handle_call/3` and steps it as `{registry,
{notify, From, Kind, Key, Value}}`; the core answers `{reply, From,
Answer}` when the notification is queued or refused, or the indication
confirmed or timed out.

The link answers a Long Term Key Request with Reply only when it holds
a key and the request carries zero EDIV and Rand. A Reply the
controller answers with a failure counts as no Reply, so the link's
next report about encryption ends it: HCI 7.8.25's Status says only
that the command failed, not whether the controller kept the key, and
ending the link is the reading that never takes an unconfirmed key as
the link's. A step's actions end at its first `{close, Reason}`, after
the packets it hands over, and what is still queued is dropped with the
link, whose end disconnects it. A link with a key
passes the window's `open` verdict to the Security Manager as `bonded`,
so its pairing fails. The core's `key` and Security Manager state, and
the bond in `resolve`'s answer and in `keep`, hold secrets; the link
process shows `erx_bt_link_core:facts/1`, which holds none, in crash
reports and `/proc`, and ends with a reason built from it alone when
`step/3` raises, since a stack trace carries the core.

## Stage 3: the serial service

### For apps

`abi/gatt/nus.txt` (above) declares the service, and `erx_gatt_serial`,
a library over the facet, turns it into a byte stream for each phone:
`rx` writes, each `{write, ...}` answered at once, become `{serial, Conn,
Bytes}` messages to the app, and `erx_gatt_serial:send(Conn, Bytes)`
cuts the bytes into notifications of at most `Mtu - 3` octets on `tx`,
returning once all are queued. The stream is as reliable as ATT makes it:
a phone that writes faster than the app reads loses the commands past
`bt_write_queue` (ATT 3.3.2), which nRF-style terminal apps send as write
commands; an app that needs every byte uses `write` with response.

### The console

The phone console is the serial service made a **login line**, as an SSH
connection is ([design-ssh.md](design-ssh.md#an-ssh-connection-is-a-line)):
`erx_bt_console`, in the Bluetooth domain, is the handler of the
`console` service, a declaration with the UART service's UUIDs whose
`rx` and `tx` require `authenticated`. Each phone's stream is a line: it
asks for a name and a passphrase, logs in through the system domain's
login facet, which the Bluetooth domain holds as the SSH and web front
ends hold theirs, and the session's tty takes the line, with the
console process as the tty's master, speaking the console interface's
messages. The login facet's interface is the one the login design settles
for every place a person meets the system
([design-display.md](design-display.md#risks-and-decisions), 14).

The line never logs anyone in without a passphrase, in any build, and
never offers the system shell, which only the console's secure lines
carry ([design.md](design.md#decisions)). Since a passphrase must not
cross the air in clear and a login prompt must not be reachable by
anyone nearby, the manifest check refuses a `console` service whose `rx`
or `tx` is below `authenticated`, which in turn needs stage 4. The
UART service and the console share UUIDs, so a machine serves one of them.
A release build offers the console only when its manifest opts in, with
the Bluetooth row's console argument, and no manifest erXos ships does: a
build check over the shipped release manifests fails on one that names a
console service ([Decisions](#decisions), 2).

## Stage 4: pairing and bonding

### Secure Connections only

`erx_smp_core` is the Security Manager as responder, a pure state machine
explored exhaustively on the host; `erx_smp` is its PDU codec, with a
fuzz target; `erx_smp_crypto` computes `f4`, `f5`, `f6` and `ah` with OTP's
`crypto` (AES-CMAC, AES-128) and does the P-256 key agreement, with the
sample data of SMP Appendix D as its tests. The responder:

* answers a Pairing Request only while a window is open; outside one,
  Pairing Failed, Pairing Not Supported (`0x05`);
* answers a Pairing Request only once the pairing wait has passed
  ([The pairing window](#the-pairing-window)), and before that Pairing
  Failed, Repeated Attempts (`0x09`), which leaves the window open;
* fails, with Unspecified Reason (`0x08`), a Pairing Request on a link
  whose address resolved to a kept bond, so a link with a key never
  pairs; a window takes it as its pairing and reports `already_bonded`;
* fails, with Authentication Requirements (`0x03`), a request without the
  Secure Connections flag, so legacy pairing never runs: the device
  enforces LE Secure Connections pairing for its services at level 2, as
  GAP 10.2.1 permits, and level 4 is that pairing's by definition;
* sets its maximum and minimum key size to 16 and fails a smaller
  request with Encryption Key Size (`0x06`) (SMP 2.3.4), so every key is
  16 octets;
* states the IO capability the window's mode gives, DisplayOnly or
  NoInputNoOutput, and fails, with Authentication Requirements, a
  pairing whose method would not reach the window's level: a `display`
  window takes Passkey Entry alone, so a phone that offers no keyboard
  cannot make a weaker bond in it;
* asks the phone to distribute its identity key, the IRK and identity
  address, and distributes none of its own, since erXos's identity
  address is static; it clears the link-key bit in both directions, so no
  key for another transport is ever derived (SMP 2.3.5.7);
* fails, with Authentication Requirements, a request that does not ask
  for bonding or does not offer the phone's identity key, since such a
  pairing could leave no bond ([Bonds and the store](#bonds-and-the-store));
* checks the phone's public key on the curve, `y^2 = x^3 - 3x + b mod p`
  with both coordinates below `p`, in Erlang before any key agreement,
  and fails a key off the curve with DHKey Check Failed, as SMP
  2.3.5.6.1 requires; it refuses SMP's debug key with Invalid Parameters,
  and a key with the X coordinate of its own with DHKey Check Failed
  (2.3.5.6.1). The curve's constants, which the specification gives in
  Vol 2 Part H 7.6 (not fetched), come from OTP crypto's curve table,
  `crypto:ec_curve(secp256r1)`, so no copy of them is written down, and
  the check's test feeds a point with `y + 1`;
* makes a fresh key pair and, for Passkey Entry, a fresh six-digit
  passkey from `crypto:strong_rand_bytes/1` for every pairing (SMP
  2.3.5.6.3, 2.3.6);
* gives the link its key when the second phase computes the LTK, so the
  phone's encryption at the end of that phase uses it
  ([One table, one gate](#one-table-one-gate)), and takes the phone's
  identity in the third phase over the encrypted link;
* ends a pairing at 30 s without a step (SMP 3.4), and the link with it.

Before stage 4, the link answers every SMP command with Pairing Failed,
Pairing Not Supported, but the phone's own Pairing Failed, which is
never answered, and the reserved codes and empty PDUs the Security
Manager ignores in every phase.

### The pairing window

A window is an open fid of the control tree's `pair` file. Opening it
while another window is open, or while the pairing a closed window
admitted has no outcome yet, answers `ebusy`, so the window process
awaits at most one pairing. The opener writes one
line, `display` or `nodisplay`, at most 16 bytes, which opens the window
for `bt_pair_window_s`, 120 s, and reads lines that the window writes,
each ASCII the window composes from numbers and addresses alone:

| Line | Meaning |
| --- | --- |
| `wait N` | the window is open, and the pairing wait has `N` seconds to run |
| `waiting` | the window is open, the wait has passed, and the machine is bondable (GAP 9.4.3) |
| `passkey NNNNNN AA:BB:CC:DD:EE:FF` | type this passkey on the phone with this address |
| `bonded AA:BB:CC:DD:EE:FF authenticated` or `unauthenticated` | a bond is kept |
| `failed AA:BB:CC:DD:EE:FF REASON` | the pairing failed, with its reason ([Refusals](#refusals-and-error-results)) |
| `closed timeout` | the time ran out |

After `bonded`, `failed` or `closed`, the file ends. A read that finds no
line waits for one as a waiting request the window process keeps
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"). Clunking the fid, or
the opener's end, closes the window at once, so no window outlives the
person who opened it, by construction of the file protocol's fid
lifetime ([design-files.md](design-files.md#fid-owners)). A window takes
one pairing: whatever its outcome, the window closes.

**Closing a window withdraws its pairing.** The authority to bond is the
opener's, so it ends with the window: when the fid is clunked, or the
opener ends, while the link still runs the pairing the window admitted,
the window withdraws it, and the link fails it with Pairing Failed,
Unspecified Reason (`0x08`) and reports `withdrawn` to the window
process, which counts it as a failure like any other for the pairing
wait and writes the log's record; the `pair` file has no reader by
then, so its line is never written. Closing the window is the
opener's one way to stop a pairing, for instance one whose `passkey`
line names an address the opener does not expect. A pairing withdrawn
after its second phase ends its link with the pairing's key, as every
failure does once a link has a key
([One table, one gate](#one-table-one-gate)); the key never reaches
the store. A pairing whose third phase the link ended before the
withdrawal reached it is complete: the opener's window was open when
the phone distributed its keys, the link has handed the bond to the
store, and the store's answer is its outcome, which the window process
counts and logs as for any other pairing
([The link's messages](#the-links-messages)). Closing a window and a
pairing completing race only at that one step of the link, and
whichever comes first decides. The window's time bounds admission only: once it has
admitted a pairing, it waits for that pairing's outcome, so a person
typing a passkey as the time runs out is not cut off. SMP's 30 s timer
bounds each step, not the pairing (3.4): a phone that steps just inside
it through Passkey Entry's some 45 PDUs holds the window, which answers
`ebusy` to other openers, for about 20 minutes, and the opener ends
that by closing the window. The link's `admit` carries the
number of its Pairing Request, and the window's verdict and withdrawal
carry it back, so a verdict or a withdrawal that arrives late, after
its request failed and the phone asked again, changes nothing
(`erx_smp_core`).

**The pairing wait** is SMP 2.3.6's, kept by the window process and not
by any window, so whoever opens windows, and however fast, does not
shorten it. After a pairing fails, whatever the reason, the timeout and
the end of its link included, so that leaving halfway through Passkey
Entry's rounds is a failure too, no Pairing Request is answered for the
wait, which starts at
`bt_pair_wait_min_s`, 2 s, doubles at each further failure up to
`bt_pair_wait_max_s`, 64 s, and halves for each `bt_pair_wait_decay_s`,
600 s, without a failure, down to the minimum; a success leaves it as
it is. The window process monitors a link from its `open` verdict until
the link reports the pairing failed or hands its bond to the store, so
a link that ends first, however it ends, is a failure, `disconnected`,
and one that ends while the store writes is not
([The link's messages](#the-links-messages)). A request during the wait is answered Pairing Failed, Repeated
Attempts (`0x09`), which is not a pairing and changes neither the wait
nor the window. SMP asks the wait of a device claiming the failed one's
identity; before its third phase a pairing has no identity but an
address a peer changes at will, so the wait holds for every claimant at
once, which is the rule's strictest reading. The link asks the window
whether the wait has passed before it answers a Pairing Request and
before it sends a Security Request ([Reconnection](#reconnection)), the
other message 2.3.6 governs. The wait starts each life of the window
process at its minimum; nothing a radio peer sends restarts more than
its own link ([Concurrency](#concurrency)). So a guesser gets one try
per window and at most one per wait, and a fresh passkey for each
(SMP 2.3.5.6.3).

Who may open a window is who holds the control tree: the manifest grants
it to administrators' sessions and to the app templates it names, such
as a vendor app that opens a window when its button is pressed. No
window opens by itself, at first boot or ever.

The `nodisplay` window makes Just Works bonds, unauthenticated: they
reach `encrypted` characteristics and never `authenticated` ones. A
nearby attacker can pair during such a window, which is why the level
is the declaration's to require and the window's to offer.

**Where the passkey is shown.** A `display` window's passkey reaches a
person only on the `pair` file, through whatever the opener holds the
control tree by: an administrator's session at the console, over SSH or
the web client, or an app the manifest grants the tree, which shows it
on a display it holds. Each is a channel the system already trusts to
manage the machine, and the passkey is fresh for each pairing; no
passkey is printed on a device or fixed in its configuration, since a
static passkey leaks over repeated attempts. A machine with no such
channel opens only `nodisplay` windows, so it serves `authenticated`
characteristics, the console and Wi-Fi provisioning among them, to no
one; those wait for an out-of-band method of their own design, such as
NFC or a code the phone scans ([Decisions](#decisions), 3).

### Bonds and the store

A **bond** holds the phone's identity address, its IRK, the LTK, the
level, the table hash it was last served, and its subscriptions to
characteristics with `notify` or `indicate`. The stored **state** is the
identity address and at most `bt_bonds_max` bonds, encoded by `erx_bt_state`
in a form with a version, which refuses any other version and any
malformed or oversized input with a fuzz target, since what a store
returns is untrusted wherever a medium can be written. The store keeps
the whole state through one seam, the vault's state slot
([design-system.md](design-system.md#state-slots)), taken with all its
results: `get() -> {ok, Blob} | none | {error, unavailable}` and
`put(Blob) -> ok | {error, too_large | unavailable}`, the blob replaced
whole. Both stores behind it answer with exactly these results:

* **in a development build**, a file in the Bluetooth domain's directory
  on the data partition, replaced whole by write, sync and rename, as the
  SSH domain keeps its host key before the vault
  ([design-ssh.md](design-ssh.md#host-keys)); `get` answers `none` when
  the file does not exist and `unavailable` when it cannot be read, and
  `put` answers `unavailable` when any step of the replacement fails;
* **in a release build**, the vault's state slot `{state, "bt"}`,
  whose `get` and `put` are the seam's
  ([design-system.md](design-system.md#state-slots)); the release
  manifest check refuses a `bt` row whose store is the development one.

What `get` returns is untrusted wherever the medium can be written:
`erx_bt_state` decodes it, and a blob that does not decode is not a
state.

**Every call of the backend ends by a deadline.** Neither store behind
the seam promises to answer in any time: a vault checkpoint or a
storage domain may stall. So the store makes each `get` and `put` from
a short-lived process of its own that it monitors, and ends that
process at `bt_store_timeout_ms`, 5 s. A `get` not answered by then is
`{error, unavailable}`, and a `put` not answered by then is
unconfirmed, as any `put` that does not answer `ok` is (below): it may
yet complete, so the store becomes `unknown` and the next change reads
first. Those are results the store already takes, so the deadline adds
no state. The store waits on nothing else, so it answers every request
it takes, a pairing's `keep` and a link's `subscriptions` included,
within two backend calls, a read and a put, of reaching it; no link,
window or configuration write waits on the store without end, and none
keeps a deadline of its own for it. A link that starts while the store
waits on its backend may meet its own call's 5 s and end, and the
phone reconnects.

**The domain changes only a state it has read.** The store process
holds the store as one of two values: `read`, the state last read or
confirmed, or `unknown`. At the start of the Bluetooth domain it starts
`unknown` and calls `get`:

| `get` answers | The store | The bonds | The identity address | Reason at `/proc/bt` and in the log |
| --- | --- | --- | --- | --- |
| `none` | `read`, empty | none | made now, kept by the first `put` | none |
| `{ok, Blob}` that decodes | `read` | the blob's | the blob's | none |
| `{ok, Blob}` that does not decode | `unknown` | none | made now, for this start only | `store_unreadable` |
| `{error, unavailable}` | `unknown` | none | made now, for this start only | `store_unavailable` |

A store that is `unknown` after the start's read refuses every change
until `forget all`, below, or the next start, which reads again: the
domain runs without bonds and refuses pairing, as it did before stage 4,
and the address made for this start is not the one a stored state may
name, so a later read could give bonds an address they were never
advertised under. A pairing, a bonded link's configuration write and
`forget` are the changes. Each puts the whole new state, built from the
state last read or confirmed, and goes on only from `read`; a store that
is `unknown` otherwise fails the change as the next paragraphs say and
is left as it was. So no ordinary change replaces a state the domain
could not read. The one write that does not start from a read state is
`forget all`: it puts an empty state with the identity address in use,
whatever the store holds, the explicit way past a blob that does not
decode, and a confirmed answer makes the store `read` and the address
kept.

**Publication.** A `put` that answers `ok` is confirmed: the store holds
the new state and the domain's `read` value is it. Any other answer
leaves the change unconfirmed: the medium may keep the old blob or the
new, each complete, as for every change to the vault's files that fails
before its checkpoint answers
([design-system.md](design-system.md#the-vault), One owner per file),
and as for a development file whose rename may or may not have reached
the medium. The domain then keeps what it had, fails the change, and
sets the store to `unknown`, so the next change reads first and starts
from whichever blob the store kept; when that read leaves the store
`unknown` the change fails and the store stays so. A read that follows
an unconfirmed put replaces the bonds with the blob's, and a connected
link whose bond the blob lacks ends, as forgetting a bond ends it. The
identity address a stored blob names is the one in use, since the domain
made it or read it before any `put`. `too_large` takes the same path: the
encoder bounds a state to `bt_bonds_max` bonds, whose largest encoding
fits the vault's 4 KiB, so meeting it is a bug.

A pairing that completes asks the store to keep the new state, the
bond with the subscriptions its link has made so far, under the tag the
window admitted it by; the store tells the window its answer, which is
the pairing's outcome however the link has fared since
([The link's messages](#the-links-messages)). The bond is kept with no
table hash, since `keep` carries none, so the first reconnection
encrypted with its key indicates Service Changed once if the phone
subscribed to it ([Reconnection](#reconnection)). The link's key
is a kept bond's once the store answered `ok`, which `connected` tells
the handlers with `bonded => true`; the link's level does not wait on
the store ([One table, one gate](#one-table-one-gate)). A pairing whose
store is `unknown`, or whose `put` is not `ok`, fails `failed ...
unavailable`, its keys are discarded and the link ends. On a trial boot
both stores are read-only, since every file system mounts read-only
([design-storage.md](design-storage.md#system-updates)), so a `put`
fails `unavailable` there, pairing fails, and bonds already kept work.

**Pairing never replaces a bond.** A pairing whose phone turns out, at
its key distribution, to have the identity of a bond already kept fails
with `already_bonded`, its keys discarded; the operator ends a bond with
`forget AA:BB:CC:DD:EE:FF` written to the control tree's `ctl`, or
`forget all`, and pairs again. A ninth bond fails with `bonds_full`.
Forgetting a bond ends its connected link: the store sends `forgotten`
to each link it monitors for that bond
([The link's messages](#the-links-messages)). SMP 2.4.3.2 holds a
distributed identity address valid only once a reconnection has used it
with the pairing's key; the same caution keeps a claimed identity from
ever overwriting a kept one.

A bonded link's subscriptions persist across connections, as GATT
3.3.3.3 requires: a write of a Client Characteristic Configuration that
changes it on a link encrypted with a kept bond's key is answered with
its Write Response only once the store has kept the new state, and a
store that is `unknown` or does not answer `ok` answers Unlikely Error
and leaves the configuration as it was. So a phone that saw its write
answered may rely on it after a power cut, Service Changed's
configuration included, which a change of the table at a later start
needs. On a link that holds a key and is not yet encrypted, a resolved
one or a pairing's between its second phase and the encryption, the
write is answered Insufficient Encryption and changes nothing, since
only the key in use proves whose configuration it is ([The link's
messages](#the-links-messages)). A write that changes nothing, and
every other write the gate allows on a link whose key is neither kept
nor being kept, is answered at once; one that comes
while the store keeps the link's pairing waits for the store's answer,
and is then kept as a bonded link's write is, so `keep` never leaves
out a subscription the phone saw answered; a Write Command to the
descriptor, which has no answer, changes the configuration where the
gate allows the write, and is then kept as a request's would be. ATT's
one request at a time and a bonded peer bound the store's writes.

### Reconnection

At its start the link asks the store to resolve the phone's address
against the bonds ([The link's messages](#the-links-messages)): an identity address by equality, a resolvable private address
by `ah` with each bond's IRK (SMP 2.2.2), whose form, top two bits `01`,
is Vol 6 Part B 1.3.2.2's, unverified until read. A resolved link holds
the bond's key from then on, and the transition of [One table, one
gate](#one-table-one-gate) encrypts it; in Secure Connections the Long
Term Key Request carries zero EDIV and Rand, and one that does not is
answered Negative Reply. A resolved link also sends a Security Request
(SMP 3.6.7) with the bond's authentication requirements, MITM set for
an `authenticated` bond, as soon as the pairing wait has passed, unless
the phone has already begun encryption, which SMP 2.4.6 forbids it to
interrupt: a bonded phone that only waits for its notifications is
thereby asked to encrypt, rather than left waiting. Until it does, the
link is not yet its bond's ([The link's messages](#the-links-messages)):
it has the default configuration and no subscription, refuses a
configuration write with Insufficient Encryption, and sends no
notification. At encryption the link becomes the bond's: the registry
tells the handlers with `connected`, now `bonded`, and the link
restores the bond's subscriptions. Then, when the bond's table hash
differs from the table's and the phone subscribed to Service Changed,
the link indicates Service Changed for `0x0001` to `0xFFFF` (GATT
2.5.2) and, at the confirmation, records the new hash. So neither the
subscriptions nor the hash a bond keeps change at the word of a peer
that only copied its phone's address.

## Later stages

### Wi-Fi provisioning

A phone gives the machine a network's name and passphrase over an
`authenticated` characteristic, so credentials never cross the air in
clear or to a peer who saw no passkey. The Bluetooth side is a
declaration and an app, with nothing new below them. The app derives
the network's PMK and hashed values as the session's `wlankey` does and
hands them to the vault's `{wpa, Service}` purpose through a
`wpa_admin` facet of its own session template, never to the WiFi
domain, and no state slot of Bluetooth's holds them
([design-wifi.md](design-wifi.md#credentials)). Its `authenticated`
characteristic needs a passkey shown through a trusted channel, so a
machine with none waits for an out-of-band method
([Decisions](#decisions), 3).

### HID over GATT

A Bluetooth keyboard or mouse types into a display, as a USB one does.
This stage adds the central role and keeps every rule above:

* **Central.** The controller process gains passive and active scanning
  (LE Set Scan Parameters and Enable), an advertising report decoder with
  a fuzz target, and LE Create Connection to bonded devices through the
  filter accept list; a link gains the GATT client, a pure state machine
  over the same codec, explored exhaustively; pairing as initiator
  shares `erx_smp_core`'s checks, with erXos showing the passkey a
  keyboard types, in a window as above.
* **Input only through a bond.** The HID function of a link, the only
  writer of its input records, starts only when the link is encrypted
  with a bond's key, and the GATT client sends no request before that,
  so encryption is the first thing after connection, as HOGP 7.2 asks; a
  link whose encryption fails is ended, never used in clear. The HID
  function discovers the HID service, reads the Report Map with long
  reads, reads each Report characteristic's Report Reference, enables
  notifications of every Input Report (HOGP 4.6, 4.8), and folds each
  notification, with its Report ID prepended when the layout has report
  ids (HOGP 4.8.1), through the USB design's `erx_hid_desc` and
  `erx_hid_core` ([design-usb.md](design-usb.md#hid)), unchanged; their
  descriptor bound, `hid_report_descriptor_max`, is 4 KiB
  ([design-usb.md](design-usb.md#what-a-device-can-make-the-domain-spend)),
  above HIDS's 512. Notifications that arrive before discovery ends wait
  in a bounded queue and fold after it, so the key that woke a keyboard
  is not lost.
* **Input numbers.** The Bluetooth domain serves an input tree of input
  numbers, a service of the `input` interface under a name of its own,
  granted to a display read-only, through the same module as
  the USB domain's, whose stream process writes `release` when its
  occupant ends ([design-usb.md](design-usb.md#hid-reaches-the-display)).
  The domain then has, toward that display, the reach of a person at it
  and no more ([design.md](design.md#threat-model)).

### Classic Bluetooth

Classic HID (BR/EDR) adds inquiry, an SDP client, L2CAP's
connection-oriented channels with configuration, Secure Simple Pairing,
link keys and the HID control and interrupt channels, each a parser with
its fuzz target, under the same window and store, and a link kind beside
the LE link. Cross-transport key derivation stays off unless a consumer
is named. It is designed when a classic device is needed.

## Security

The Bluetooth domain is outside the trusted base. What it holds and what
a radio peer can do:

| Adversary | Can | Cannot |
| --- | --- | --- |
| A radio peer, anyone in range | send any packet the controller forwards; connect while a slot is free and so hold it; read and write `open` characteristics; pair during a `nodisplay` window and so reach `encrypted` characteristics | reach an `encrypted` characteristic without a bond made in a window, or an `authenticated` one without the passkey the window showed; make the system domain parse a radio byte; make the Bluetooth domain hold more than its bounds; replace a bond |
| The controller, its closed firmware | everything a radio peer can; read every LTK erXos gives it; forge what a bonded peer could send | reach anything erXos does not send it: it sees the line, not the machine |
| A compromised Bluetooth domain | everything the controller can; read the bonds; act as any bonded phone toward the apps it serves; see every byte of the console's lines, passphrases included | reach a device, a partition or a facet beyond its row's; log anyone in without the passphrase, which the vault checks |

The vault cannot keep a bond's key from the Bluetooth domain or the
controller, which needs it in clear in LE Long Term Key Request Reply;
what any store gives is sealing at rest and one owner, not containment.

No report of the domain carries a radio peer's or the controller's
bytes, nor a key: the domain takes the report filter, `erx_report`,
at boot, before any process of it starts
([design-log.md](design-log.md#reports-carry-no-term)), so the crash
of a process with controller bytes in its mailbox or its stack trace's
arguments (an unknown action, a `function_clause` in a core, the
`badarg` of a send to a line process that has gone) is logged as names,
classes and arities.

### Attack classes

* **KNOB, key size downgrade.** Every key is 16 octets by construction:
  the responder's minimum is 16 and a smaller negotiation fails with
  Encryption Key Size (SMP 2.3.4), so no bond and no LTK given to the
  controller is shorter; legacy pairing, where EDIV and Rand would carry
  keys, never runs.
* **BLURtooth, cross-transport key overwrite.** No key is derived for
  another transport: the link-key bit is cleared both ways, and erXos has
  no BR/EDR before the classic stage. Independently, pairing never
  replaces a bond, so no unauthenticated pairing overwrites an
  authenticated key, which is the overwrite the attack needs.
* **BLESA, reconnection spoofing.** It attacks a client that accepts data
  from a reconnected server before re-encrypting. As a server, erXos
  decides access from the link's encryption state, set only by the
  controller for a key the link supplied, never from the peer's
  address, so a peer spoofing a bonded phone's address without its LTK
  gets errors; nor does it reach the bond's kept subscriptions or table
  hash, which a link takes on only at encryption with the bond's key.
  As a client, in the HID stage, the GATT client sends no
  request and the HID function takes no notification before encryption
  with the bond's key, and a failed encryption ends the link.
* **Unauthenticated HID injection,** a host taking HID reports from a
  peer it never bonded with. Until the HID stage erXos takes no input from
  Bluetooth at all; in it, input records come only from a link encrypted
  with a kept bond.
* **Pairing method confusion,** a man in the middle running Passkey Entry
  with one side and Numeric Comparison with the other, where the person
  compares the passkey shown with a number the phone shows. erXos never
  offers Numeric Comparison, and the window's line says to type the
  passkey on the phone; a person who confirms a matching number instead
  remains the attack's residual, which no one side closes.
* **Passkey guessing.** One pairing per window, a fresh passkey per
  pairing and the pairing wait leave a guesser one try in a million per
  window, and at most one try per wait, which doubles to 64 s, however
  windows are opened (SMP 2.3.5.6.3, 2.3.6).
* **Tracking.** The identity address is static for an installation, so
  a machine advertising is recognizable while it advertises, as any
  peripheral without privacy is; advertising with resolvable private
  addresses is a later option with a consumer to name.
* **Holding the only slot.** With the default limit of one connection, a
  peer that connects and stays keeps the phone out. This is a security
  residual of the design, which fails safely: the peer reaches only
  `open` characteristics, and the phone gets no connection rather than a
  wrong one. Its remedy, accepting connections outside a window only
  from bonded phones, through the filter accept list and the
  controller's resolving list, waits for a deployment that needs it.

### Inspection

`/proc/bt` shows the controller (bring-up state, manufacturer, versions,
the patch applied, the address it reports and the identity address),
each connection (`Conn`'s number, the peer's address, the bond's identity
when resolved, the level, the MTU, subscriptions), each bond (identity
address, level; never a key), and the counters: framing errors, dropped
events and frames, discarded commands, refused PDUs, failed pairings by
reason. A value the domain does not know, such as the version before the
bring-up reached it, is `unknown`, never a guess. The line service shows
its line at the system domain's `/proc`: bytes each way, breaks, resets.

## Concurrency

* **One controller process** serializes everything about the controller:
  commands, credits, the handle map, advertising. Links talk to the
  controller only through it.
* **A link per connection** processes its phone's PDUs in order; a
  handler's write answer is a message back to the link, which takes the
  next request only after it, so a link never waits on a handler while
  events arrive: confirmations, commands and the controller's reports
  still reach it. A link waits on another process only at its start,
  on the store's `resolve` and the registry's `join`, and no owner waits
  on a link, so no two processes wait on each other.
* **The registry outlives links and the controller.** It sits before the
  controller group in the domain's `rest_for_one` supervisor, so a
  controller restart ends every link, every handler hears `disconnected`
  for each, and handlers stay attached.
* **A disconnection during a handler's answer** drops the answer: the
  reply goes to the link's pid, whose process no longer exists; the handler
  has already heard `disconnected` from the registry or hears it next.
* **A notification and a disconnection** race only at the registry, which
  answers `{error, gone}` for a dead `Conn`, and for a notification whose
  link ended before answering it; a notification queued before
  the end is dropped with the link's queue, as the controller drops what
  it had.
* **One window** exists at a time; its state and the pairing wait are
  the window process's, and the link asks it at a Pairing Request and
  before a Security Request, and tells it a failure or that the store
  has the bond, whose answer the store then sends it; the window
  process monitors a link from its `open` verdict until one of those,
  so a link that ends mid-pairing, however it ends, counts as a
  failure, and one that ends while the store writes its bond does not.
  The window process needs no monitor of the store: the store sits
  before it under `rest_for_one`, so the store's end ends the window
  process too. The window process
  sits before the controller group, so a controller restart, the only
  restart a radio peer's traffic can cause beyond its own link, keeps the
  wait.
* **The store** is one process; a pairing's `put` and a link's
  configuration writes are serialized there, and each `put` writes the
  whole state. Its one wait, on its backend, ends at
  `bt_store_timeout_ms`, so it answers every request it takes.
* **The line service** serves one reader and writers in arrival order; the
  Bluetooth domain has one of each. Its reads, writes and resets that
  wait are waiting requests the line's process keeps, so a read that
  waits holds up no write, and the grant in `erx_fs` waits on
  neither ([The controller's line](#the-controllers-line)). A `reset`
  holds both until it answers; a read waiting at a `reset` answers
  `eio`.
* **The device service** makes every firmware notification from its one
  firmware worker, so a power cycle and the VL805's notification never
  meet in the kernel, and its own process stays free to answer
  ([The power line](#the-power-line)).

The supervision tree of `erx_bt`:

```text
erx_bt_sup                      rest_for_one
  erx_bt_store                  the identity address and the bonds
  erx_gatt_srv                  the table, handlers, Conn map, ble facets
  erx_bt_fs                     the control tree and the window
  erx_bt_host_sup               one_for_all, at most 5 restarts in 60 s
    erx_bt_link_sup             a temporary link per connection
    erx_bt_line_rx              the reader, registered
    erx_bt_line_tx              the writer, registered
    erx_bt_hci                  the controller process, started last
  erx_bt_console                when configured
```

The controller group starts in that order, so the controller process
finds its siblings running and registered when it starts
([The controller process's effects](#the-controller-processs-effects)),
and stops in the reverse order, the controller process first.

## Failure handling

| Failure | Detected by | What ends | Recovery |
| --- | --- | --- | --- |
| a framing error, a malformed event (a reserved handle or Peer_Address_Type included), a Hardware Error event, a command not answered in 5 s, an answer to another command, a completion for a handle not live or beyond its outstanding packets, a failed bring-up step, a line reset not answered in 5 s; a failed open, read or write of `data` or `ctl` | the controller process; for the line's files, the reader or the writer, whose end ends the group | the controller group: the controller process, the line's reader and writer, every link | the group restarts: `reset`, then the bring-up; past 5 restarts in 60 s the domain ends and the domain service restarts it within its intensity |
| a malformed L2CAP frame, a second outstanding ATT request, an SMP timeout, an encryption change the link did not key, a packet the core answered `busy`, a link process's crash | the link | the link: its end makes the controller process send Disconnect | the phone reconnects |
| a link whose backlog of the controller's messages reaches `bt_link_backlog` | the controller process | the link: its handle is disconnected with `0x14` and it ends at `link_down` | the phone reconnects |
| a malformed ATT request | the ATT server | nothing: Invalid PDU | none needed |
| a handler that does not answer in 5 s | the link's deadline | nothing: Unlikely Error | none |
| a handler that ends | the facet's monitor | the handler's attachment | the app attaches again |
| the store answers `unavailable`, returns a blob that does not decode, or leaves a `put` unconfirmed, a backend call past `bt_store_timeout_ms` included | the store | the pairing; at start, the bonds: the domain runs without them and refuses pairing; the configuration write; `forget` | `/proc/bt` and the log say `store_unavailable` or `store_unreadable`; the store is `unknown`; after an unconfirmed `put` a change reads first and fails unless the read succeeds; after the start's read the next start reads again; `forget all` alone replaces a blob that does not decode ([Bonds and the store](#bonds-and-the-store)) |
| a broken line | the line service | reads of `data` | the controller group's restart writes `reset` |
| a line tree or the host link ends, or line 153's owner | its line group's supervisor | the group after it: on the Pi 4, the tree's fids and, for the owner, the host link's sessions | the group restarts, its owner first; the console, in no group, is untouched. The Bluetooth domain's `line` grant ended with the tree, and a grant of a system domain's service comes only in a ready answer, so `/line` answers `eio` to the controller group's restarts until the domain ends at its intensity; the domain service restarts it, and its ready answer brings a grant of the new tree |
| a power notification that fails | `reset`'s answer, `eio` | the bring-up | the group's restart retries within its intensity; after an unanswered request every later notification of the boot fails at once, the VL805's included, so the Bluetooth domain ends at its intensity, and its log records and the line service's `/proc` show why |
| a configuration write the store does not keep | the store, `unknown` or a `put` not `ok` | nothing: Unlikely Error, the configuration unchanged | the phone writes again |

## Refusals and error results

| Interface | Refusal | When |
| --- | --- | --- |
| the line's `ctl` | `einval` | any write but `reset` |
| | `eio` | a power notification answered other than `ERX_OK`, `ERX_ETIMEDOUT` for every one after the boot's first timeout included |
| the line's `data` | `eio` | the line is broken |
| the control tree's `pair` | `ebusy` | another window is open |
| | `einval` | a first write other than `display` or `nodisplay` |
| | `eio` | the store is `unknown` after its read |
| the control tree's `ctl` | `einval` | any write but `forget ADDRESS` or `forget all` |
| | `eio` | `forget ADDRESS` while the store stays `unknown`, or any `forget` whose `put` is unconfirmed |
| | `enoent` | no bond has that identity |
| `ble` facet | `{error, not_granted}` | a service the grant does not name |
| | `{error, attached}` | the service already has a handler |
| | `{error, no_such_characteristic}`, `{error, not_allowed}` | an unknown name; an access the declaration does not allow |
| | `{error, too_long}` | a value over the characteristic's maximum, or a notification over the bearer's `Mtu - 3` |
| | `{error, busy}` | the link's notification queue holds `bt_notify_queue` |
| | `{error, gone}` | a dead `Conn` |
| | `{error, not_subscribed}`, `{error, insufficient_security}` | the phone did not subscribe; the gate refused |
| | `{error, timeout}` | an indication unconfirmed in 30 s, after which the link ends (ATT 3.3.3) |
| a pairing, on `pair` | `failed ADDR not_supported`, `secure_connections_required`, `key_size`, `method`, `confirm`, `dhkey`, `bonding`, `invalid`, `unexpected`, `peer`, `timeout`, `already_bonded`, `bonds_full`, `unavailable`, `disconnected` | SMP's reasons and the store's, each mapped from one Pairing Failed code or one event |
| a Pairing Request during the pairing wait | Pairing Failed, Repeated Attempts (`0x09`) | the wait has not passed; no line on `pair`, the window stays open |
| a configuration write on a bonded link | Unlikely Error (`0x0E`) | the store is `unknown` or its `put` was not `ok` |
| a configuration write on a link that holds a key | Insufficient Encryption (`0x0F`) | the link is not yet encrypted |

The ATT errors erXos sends are Table 3.4's: Invalid Handle, Read Not
Permitted, Write Not Permitted, Invalid PDU, Insufficient Authentication,
Request Not Supported, Invalid Offset, Prepare Queue Full, Attribute Not
Found, Attribute Not Long, Invalid Attribute Value Length, Unlikely Error,
Insufficient Encryption, Unsupported Group Type, Value Not Allowed and the
handler's Application Errors. The SMP reasons it sends are Table 3.7's
Authentication Requirements, Confirm Value Failed, Pairing Not Supported,
Encryption Key Size, Command Not Supported, Unspecified Reason, Repeated
Attempts, Invalid Parameters and DHKey Check Failed.

## Verification

Agents iterate on the host tests and hosted mode; the board runs by hand,
once per batch, under the manual checklist.

### Host tests of the cores

Each core's test is paired with the seeded faults it must catch.

| Core | Holds | Seeded fault that must fail it |
| --- | --- | --- |
| `erx_h4` | a stream cut at every byte offset splits into the same packets; an unknown indicator, an over-long ACL length and an ACL packet past `bt_acl_rx_max` (251 octets) are errors, before and after the bring-up | the indicator check removed; the ACL length read as one byte; the bound one octet too long. A bound taken from LE Read Buffer Size cannot be written: `split/1` takes only the constant |
| `erx_bt_hci_core`, explored over every reachable state until none is left (the clock moves only to a deadline that passes, so it takes at most three values; the count of dropped events, a statistic, is explored to one; a path makes at most three connections, enough for one handle to be given a new peer while the other is live), and case by case | the writer never holds two items; a wake-up before the deadline changes nothing, and the deadline's passing stops the core or changes it; a command the controller never allows ends at its deadline; every state before `ready`, the line's reset included, has a deadline, so every bring-up reaches `ready` or a stated reason, patching at most once; an opcode-0 event never moves the deadline; credits never go below zero and connections never pass the limit; a disconnect is written only for a handle whose disconnect was asked since it last connected; a request naming a gone link changes nothing, even on a reused handle; Number Of Completed Packets reaches each live handle's link as `{completed, Count}`; advertising is never on at the limit, and with nothing written, sent or due it is on exactly while connections are below the limit; the controller process ends for exactly these reasons: an answer naming another command, a deadline passed, a completion beyond a handle's outstanding packets or for a dead handle, a connection past the limit, during the bring-up, on a live handle or on one whose disconnect is unanswered, a failed disconnect, a patch for another controller, a hardware error, an unanswered line reset, a malformed event and a failed step; fewer buffers than the connection limit lower the limit; Read Buffer Size takes any length from 1 | the command slot not cleared by Command Status; a handle kept live after Disconnection Complete; a completion count taken without the outstanding bound (a forged report grows the credits), or counting packets still waiting for the writer; advertising not re-enabled after a disconnection; the deadline armed only once the controller allows the command; the connection limit kept above the buffer count; LE's 27-octet minimum applied to Read Buffer Size; any failed disconnect taken as the handle gone; the line's reset under no deadline; and, each caught by the exploration, a disconnect kept after Disconnection Complete, a connection on a handle being disconnected accepted, a connection before the enable's answer leaving advertising on, completions not passed to their links, a deadline passed a millisecond early or only after its instant, and a request's link name ignored. A second deadline, or cancelling one never armed, cannot be written: each deadline is a field of the slot state it guards. Credits not returned at disconnection cannot be written: the free credits are derived from the live handles' outstanding packets |
| `erx_bt_patch` | a synthetic patch replays in order; a truncated last record or a foreign opcode refuses the file whole, before any record is sent | the record length not checked against the bytes left |
| `erx_gatt_db` | a built table matches a hand-written one; the hash changes with a characteristic and not with the manifest's row order | services laid out in manifest order |
| `erx_gatt_gate` | GAP Table 10.2's rows for levels 1, 2 and 4 | Insufficient Encryption answered on a link with no key |
| `erx_gatt_server` | each supported request; long reads and prepared writes at every MTU from 23 to 247; the gate asked for every value and descriptor access; a descriptor write on a link that holds a key and is not encrypted answers Insufficient Encryption, at every level the characteristic declares | the gate skipped for Read Blob; the descriptor's write level taken from `read`; the descriptor's write level taken from the declaration alone (an `open` write before encryption answered) |
| `erx_bt_link_core`, explored | reassembly at every fragment size; one outstanding request; commands past the queue discarded and counted; a first pairing reaches its level before the store answers, a reconnection the bond's; a Pairing Request on a resolved link fails; `encrypted` set only by a success report after a Reply; one Security Request, never during encryption; a bonded configuration write answered only after the store's `ok`; a resolved link sends no `subscriptions` or `served` and indicates no Service Changed before its encryption, and restores the bond's subscriptions at it; every controller message's step returns `taken`; `keep` and `keeping` leave in one step, and a `withdraw` after it changes nothing | an Encryption Change accepted after a Negative Reply; encryption accepted only for kept bonds; the configuration write answered before the store; the bond's subscriptions taken at `new/1` (a resolved link's configuration reads as the bond's before encryption); a `withdraw` taken in the Security Manager's `done` (the outcome `withdrawn` while the store keeps the bond) |
| `erx_smp_core`, explored over every message order | Passkey Entry and Just Works complete; every refusal of [Secure Connections only](#secure-connections-only) fires; a `display` window refuses Just Works; one pairing per window | the key-size check removed; the curve check removed (the `y + 1` point accepted); the link-key bit kept |
| `erx_bt_window` | the wait doubles from 2 to 64 s after failures, a disconnection mid-pairing counting as one, and halves after 600 s without one; a Pairing Request during it answers Repeated Attempts and leaves the window open; back-to-back windows do not shorten it | the wait reset when a window opens; a disconnection not counted |
| `erx_pl011:program/1` | `fresh` writes `CR` 0 first, clears `FEN` before the divisors, drains the receive side within 33 reads, writes the divisors before `LCR_H` and `CR` whole last with the flow enables; `keep` clears no FIFO and programs the divisors only of an unprogrammed UART | `LCR_H` before the divisors, so the rate never latches; `fresh` keeping the boot's divisors |
| `erx_smp_crypto` | SMP Appendix D's sample data for `f4`, `f5`, `f6` and `ah` | the AES-CMAC key byte order reversed |
| `erx_bt_state` | a state round-trips; another version, a truncation and an oversized count are refused; the largest state encodes in at most 4 KiB | the bond count read without its bound |
| the store's table, against a scripted fake store and a development file over a fake data tree that fails a chosen step | a start reading `unavailable` or an undecodable blob runs with no bonds and refuses pairing, configuration writes and `forget ADDRESS`, and `forget all` replaces the bad blob; a start reading `none` makes the identity address; a `put` that reached the medium but answered `unavailable` fails the pairing, and the next pairing reads first and keeps its bond; after every confirmed change and read the domain's bonds are the store's | `unavailable` read as `none` (a pairing overwrites the stored bonds); the pre-put state kept after an unconfirmed `put` (the failed pairing's bond lost) |
| the line's `ctl` grammar | `reset`, with or without newline; everything else `einval` | a prefix match accepting `resetx` |
| the line service's reset, over a model driver and device service | the four steps in order; the driver's input during the on time discarded; a power `{error, _}` answers `eio` before the next step | the driver started before the off notification, so the old FIFO drains into the new controller |
| the line service through a real `erx_fs` grant, reader and writer on one `data` file | a write is answered within 1 s while a read waits, and the driver's answer reaches the read once; a `reset` answers a waiting read `eio`; a clunk during a waiting read is answered within 1 s and the next reader gets the next bytes whole | a `read` that waits inside its callback; a dropped flush of a waiting read |
| flushes of begun and buffered requests, with power notifications held by the test | a `reset` flushed at any step is answered once its last step is done, then the flush; a write flushed after the driver took its bytes answers its count; a read flushed with bytes buffered answers with them, and before bytes arrive `eintr`, the next read getting them whole | a flushed `reset` answered `eintr` while its steps run; a read held while bytes are buffered |
| the identity address | 10,000 addresses have the static form and parse in Bumble's `Address` as static | the top bits cleared |
| the controller group, over a model line, store and registry (the group's start takes the open function, since on stock's emulator no namespace reaches a mounted tree; the model `ctl` answers after a set delay, and a `data` read waiting at a reset answers `eio`) | `ready` from start and again after the controller process is killed; the first `data` read after `ctl`'s answer; the identity address unchanged across the restart; a killed link process leads to one `HCI_Disconnect` with reason `0x13`; after `link_down` a `to_link` for the name reaches no process; completions reach their links; a `ctl` answering `eio` ends the group | the reader reading at its start, so the group never reaches `ready`; the controller process making the address itself; a link process's end ignored; completions not passed to the link |
| `erx_hci`'s LE Connection Complete | Peer_Address_Type `0x00` and `0x01` decode as `public` and `random`; `0x02` and `0xFF` make a successful event malformed; a failed one, Status `0x3C` with Peer_Address_Type `0xFF` and handle `0xFFFF`, decodes as `{failed, 16#3C}` | the type passed through as its octet; the type or the handle checked before the Status (the failed event malformed) |
| the link's start, against a store and a registry that hold its calls until the test releases them | `start_child` returns while both calls wait; what the controller process sends meanwhile is stepped in order once the core is built; a phone whose address resolves gets its bond's key | the store's `resolve` called from `init/1`, so `start_child` does not return within the test's deadline |
| a link's end, with the window process and the registry running | a link killed by `exit(Link, kill)` after an `open` verdict writes `failed ADDR disconnected` and doubles the wait; a link that reports its outcome and then ends counts once; the handlers hear `disconnected` once | the window's monitor not taken (nothing written, the wait unchanged); the monitor kept after the outcome (counted twice) |
| a notification to a link that ends before answering it | the registry's caller gets `{error, gone}` | the caller's `From` handed to the link in a plain message (the caller waits until its own timeout) |
| `forget` with bonded links connected | the link whose address resolved to the forgotten bond at its start ends; a link of another bond stays | the store taking a link's pid only at `keep` |
| `erx_bt_hci_core`'s backlog, case by case | a link that acknowledges nothing is sent exactly `bt_link_backlog` messages, events and ACL packets alike; the next is dropped, the handle's disconnect is asked with `0x14`, and nothing more reaches the link; a link that acknowledges every message is never disconnected; a `taken` naming a gone link changes nothing, even on a reused handle | the bound compared one too late (33 sent); `completed` not counted; `taken` taken without its name (a gone link's acknowledgement lowers the next link's backlog) |
| the link's backlog through the controller group, a link held at its start by a store that does not answer while the model line delivers 40 ACL packets for its handle | `HCI_Disconnect` with `0x14` is written after the 32nd; the link's mailbox never holds more than 32 of the controller's messages | the bound removed (all 40 delivered) |
| a pairing's outcome, with the link, the window process and the store running | a window closed after the link's `keeping` leaves the bond kept, the window process logging `bonded` and counting no failure; a window closed before it fails the pairing `withdrawn`, and the store gets no `keep`; a link killed after `keeping` leaves the store's outcome as the pairing's; a window opened before that outcome answers `ebusy` | the window's monitor kept past `keeping` (the killed link counted `disconnected` while its bond is kept); the store's outcome sent to the link alone (the window waits) |
| the store against a backend that never answers | a `put` is unconfirmed at `bt_store_timeout_ms`: the pairing fails `unavailable`, the window gets that outcome, a configuration write answers Unlikely Error, and the store is `unknown`; a `get` at the start leaves the store `unknown` at the same deadline | the backend called with no deadline (the test's own deadline passes with `keep` unanswered) |

### Fuzz targets

`erx_h4`, the HCI event decoder and its Command Complete returns
(`erx_hci:event/2`, `return/2`), the L2CAP reassembly and frame decoder,
the LE signaling decoder, `erx_att`, `erx_smp`, `erx_bt_state`, the line
service's `ctl` grammar, the control tree's `pair` and `ctl` grammars,
and the `ble` facet's request decoder; in the HID stage, the advertising
report decoder, the GATT client's response decoder and the Report
Reference decoder (the Report Map is `erx_hid_desc`'s, which has its
own). Each runs at the milestone gate's budget, and the codecs are also
compared with Bumble's decoders on the same corpus, a differential test
on the host.

### Hosted mode against Bumble

The harness, in Ruby, runs Bumble unmodified: `apps/controllers.py` with
two TCP transports joined by its local link, one controller for erXos's
line, whose socket the harness passes to the hosted runtime as the
line's descriptor, and one for the peer. Bumble's stream transports carry H4 framing
(`bumble/transport/common.py:41-46`, `:125-144`), and its controller
implements every command stage 1 to 4 send (`bumble/controller.py:1996`,
`:2344`, `:2874`, `:2953`, `:3004-3067`, `:3299-3310`). Python runs only
the peer's scripts, in `test/bt/peer/`, each started by the harness by
argument vector:

| Stage | Peer | Passes | Seeded fault |
| --- | --- | --- | --- |
| 1 | `examples/run_scanner.py tcp-client:...`, and a peer script that scans and prints each report as one JSON line | erXos's name and its advertised UUIDs appear; after a `reset` and bring-up they appear again | the advertising data built with the 16-bit list's type for 128-bit UUIDs: the UUIDs are missing |
| 2 | `examples/run_gatt_client.py` and `apps/gatt_dump.py` | every attribute of the expected table is discovered, with its handle; `open` values read as set; `encrypted` ones answer Insufficient Authentication | the gate allows every read: the `encrypted` value is read |
| 2 | `test/bt/peer/gatt_peer.py`: writes, a write past the maximum, a subscription, notifications, an indication and its confirmation, a long write | each answers as declared; the handler sees each write once, in order | the link takes a second request before the handler answered the first |
| 3 | `test/bt/peer/serial_peer.py`: 64 KiB through an echo app with `write` with response | every byte comes back in order | `erx_gatt_serial:send/2` cutting at `Mtu` rather than `Mtu - 3` |
| 4 | `apps/pair.py --mode le --sc true --mitm true --io keyboard C tcp-client:...`, where the device configuration `C` fixes the peer's address and names its key store, `"keystore": "JsonKeyStore:K"` (`bumble/keys.py:198-206`, `:272-285`); the harness reads the passkey from the `pair` file and writes it to `pair.py`'s standard input, which `input()` reads (`apps/pair.py:102-107`, `:159-168`) | `bonded ... authenticated`; then `apps/gatt_dump.py --device-config C --encrypt` reads an `authenticated` value; after the Bluetooth domain restarts, it reads it again | the LTK reply sending a key of the wrong bond: encryption fails |
| 4 | `apps/pair.py --sc false` | `failed ... secure_connections_required` | the Secure Connections flag check removed |
| 4 | `apps/pair.py` while no window is open | Pairing Not Supported | the window check removed |
| 4 | a second `apps/pair.py` run with the same address and an empty key store, in a new window | `failed ... already_bonded`; the first key store still encrypts | the bond replaced |
| 4 | `apps/pair.py` with a wrong passkey, then again at once in a new window | the first `failed ... confirm`; the second answered Repeated Attempts until 2 s have passed, then pairs | the wait not kept across windows |
| 4 | a bonded peer subscribes, the Bluetooth domain is killed at once after the Write Response, and the peer reconnects encrypting only on erXos's Security Request | the subscription is restored and a notification arrives | the configuration kept only at the link's end; no Security Request sent |
| 4 | a peer with the bonded peer's address and an empty key store connects and writes Service Changed's configuration | Insufficient Encryption; the bonded peer then reconnects and finds its subscription as it kept it | the configuration write kept on a resolved link before its encryption |

Reconnection with a resolvable private address uses Bumble's
`examples/device_with_rpa.json` as the peer's configuration;
`apps/scan.py` is stage 1's second scanner, and
`examples/run_connect_and_encrypt.py` stage 4's second reconnecting
peer.

### On the board

The Pi 4's checklist, by hand, with a phone and with a Bumble peer on a
USB dongle on the development host, which makes the peer side scripted:
the machine appears in the phone's scanner with its name; nRF-style GATT
browsers show the declared table; a terminal app for Nordic's UART
service echoes through an app; the phone pairs by typing the passkey the
`pair` file shows, reboots the machine, and reads an `authenticated`
value again; the console logs in from the phone; a `reset` written
while the stack is mid-way through a patch download is followed by a
bring-up that reaches advertising. The board probes precede the first
of these ([Board probes](#board-probes)).

## Performance

Nothing here is on a fast path. What may matter, and is on the watch
list ([todo-performance.md](todo-performance.md)):

* the patch download at 115200 baud: `BCM4345C0.hcd` is 63,806 bytes in
  the firmware repository's tree listing at `cdf61dc691a4`, about 5.5 s
  at 11,520 bytes a second before the record overheads and the 5 s of
  waits, so a boot or a restart advertises some ten seconds after the
  bring-up starts; the vendor rate command `0xFC18`
  (`init_bcm43xx.c:152-158`; `hci_uart_infineon.c:100-131`) and a `rate`
  word of `ctl` would cut it, if a measurement says the wait matters;
* a phone's write reaching a handler and its answer coming back across
  two domains, measured by a peer script that times write requests
  through an echo handler, in hosted mode and on the board;
* `erx_pl011`'s wait of 1 ms at a time while its transmit FIFO is full
  (`erx_pl011.erl:45`, `:236-243`), which the patch download and bursts
  of notifications meet.

## Alternatives considered

* **A domain registers its services at run time.** Every stack surveyed
  has the application register a service table in code. Here it would
  bring handle allocation while phones are connected, Service Changed and
  change-unaware clients within a connection, run-time conflicts between
  apps, a run-time parser of declarations with its fuzz target, and
  advertising data that may stop fitting. Declarations as configuration
  remove all of these; an app installed later brings its declaration
  with its package, and the table changes at the Bluetooth domain's next
  start.
* **Reads answered by the handler.** A read that waits on an app needs a
  deadline, a policy for a missing handler and a consistency rule across
  Read Blob requests. A value the handler sets covers the constants,
  measurements and states the stages need; a characteristic whose read
  must compute can be added as a declared access when one is named.
* **Characteristics as files.** The display serves windows as files, and
  an app could write `value` and read a stream of writes. A write
  request needs the app's verdict within the ATT transaction, which a
  file stream cannot answer without a second file and a matching rule:
  a live conversation, so a declared protocol.
* **The controller's own P-256** (LE Read Local P-256 Public Key, LE
  Generate DHKey, HCI 7.8.36 and 7.8.37) and ctaes for AES. It would keep
  OpenSSL out of the Bluetooth domain, at the cost of a new AES primitive,
  a dependency on commands a controller may lack, and the curve check
  still in the host. The network domain calls no OpenSSL because a SYN
  flood would make hashing per packet
  ([design-network-stack.md](design-network-stack.md#where-c-is-used-and-what-is-measured));
  here the inputs that reach OpenSSL are one 64-byte public key per
  pairing in a window and 16-byte blocks, checked first.
* **3 Mbaud from the start.** It needs a rate word in `ctl`, the vendor
  rate and clock commands whose details differ between NetBSD and Zephyr
  (`0xFC45` sent or not), a switch timed to a response, and a transmit
  path faster than `erx_pl011`'s millisecond wait. 115200 carries BLE's
  traffic for the stages; the rate is a measured optimization.
* **Choosing the patch by the controller's local name**, as NetBSD does.
  The name is text the controller writes; the manifest names the file.
* **The Bluetooth domain inside the devices domain.** One ERTS fewer, but
  a parser defect reachable from anyone in range would reach every slow
  device's driver.
* **A power line left alone.** Without a power cycle, a restarted
  bring-up meets a controller at an unknown rate, patched or not, and
  needs a case for each.
* **A UART left as the last driver had it.** Restarting `erx_pl011` the
  console's way keeps the boot's divisors and both FIFOs, so a restarted
  bring-up would meet the last controller's bytes and whatever rate the
  boot chose; programming the line afresh makes the UART one state as the
  power cycle makes the controller one.
* **A pairing wait per window, or none.** One pairing per window alone
  gives no interval between attempts when an app opens windows itself;
  a wait per claimed identity cannot hold before a pairing's third phase,
  where the only identity is an address a peer chooses.
* **A `lines` field in the manifest.** A field of its own beside
  `console` and `hostlink` would need its own packed representation and
  reader; a `line` grant's parameters are a facet row the manifest
  already has, checked as every parameter is.

## Decisions

1. **Decided: bonds go in an opaque sealed state slot of the vault.** The
   state is the identity address and the bonds, at most 4 KiB, needed at
   boot before anyone logs in, and sent whole to the controller in use,
   so any store gives sealing at rest and one owner, not containment.
   The vault keeps it as one blob of purpose `{state, "bt"}` in the
   machine's file, sealed as machine keys are, with `get` and `put`; it
   parses nothing of the blob and learns no Bluetooth structure, and the
   Bluetooth domain's `erx_bt_state` decodes it as untrusted input
   ([design-system.md](design-system.md#state-slots)). The slot is
   generic; the WiFi design keeps no network key in one, since a PMK
   never has to leave the vault ([design-wifi.md](design-wifi.md#decisions), 1). The
   alternatives were a bond purpose with store, forget and list, which
   teaches the vault a bond's structure for no protection the slot
   lacks; a seal-and-open purpose, which leaves the domain a data grant
   and its own atomic replacement, which the vault's publication already
   gives; and the development file in release builds, as FreeBSD's
   `hcsecd` keeps its link keys in `/var/db/hcsecd.keys` (`hcsecd.h:39`),
   which a copied medium yields whole.
2. **Decided: release builds offer the phone console only by a manifest
   opt-in, and every manifest erXos ships leaves it off.** It is a
   login line reachable over the air by anyone who completed an
   authenticated pairing in a window. A release build serves it only
   when the Bluetooth row's console argument names the service, and
   the manifests erXos ships do not; its characteristics are
   `authenticated`, which the manifest check requires; the normal login
   limits of the login facet apply, as at every other line; and it
   never offers the system shell, which only the console's secure lines
   carry.
3. **Decided: fresh passkeys, shown through a management channel the
   machine already trusts.** A `display` window shows each pairing's
   fresh passkey on the `pair` file, to an administrator's session or an
   app the manifest grants the control tree ([Where the passkey is
   shown](#the-pairing-window)). A machine with no display and no such
   channel opens only `nodisplay` windows, whose Just Works bonds serve
   only services that declare `encrypted` or `open`. Authenticated
   services on such a machine, the console and Wi-Fi provisioning among
   them, wait for an out-of-band method, by NFC or a code the phone
   scans, designed separately. Static passkeys printed on a device are
   excluded: they leak over repeated attempts.

## Board probes

Each runs on the Pi 4 under Fiasco before the code that depends on
it, and its readings go into a research record.

* **B-P1** Read GPIO 30 to 33's function at erXos's start. If not ALT3,
  `config.txt` gains `gpio=` lines for them, as it has for UART3's pins.
* **B-P2** Before any power notification, send `HCI_Reset` at 115200 on
  UART0: did the firmware leave the controller powered? Read the
  expander node's `gpio-line-names` from the device tree the firmware
  passes, find the controller's enable line, its pin and polarity, and
  check that a cycle with 300 ms off and 500 ms on brings the controller
  back at 115200; record whether the controller sends any byte between
  power-on and `HCI_Reset`, and the raw response word the firmware
  leaves in each power notification's answer, which the tag's
  declaration takes as performed when it is 0.
* **B-P3** Read Local Version and Read BD_ADDR before and after the patch:
  the manufacturer the patch row names, the ROM's and the patch's versions.
* **B-P4** Advertise and accept a connection on the ROM firmware, without
  the patch: is the patch needed for the stages at all?
* **B-P5** The patch's two waits: does the download succeed with
  Zephyr's shorter ones?
* **B-P6** Kill the Bluetooth domain mid-way through a patch download,
  with CTS held off by the controller, and check that the next `reset`
  starts the driver without waiting on `BUSY` and that the next bring-up
  reaches advertising.
