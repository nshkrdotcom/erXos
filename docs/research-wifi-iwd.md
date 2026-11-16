# iwd 3.12: a clean-room facts record for choosing a WiFi station design

Date: 2026-11-15. A point-in-time research record. Written by a clean-room facts writer who read the
LGPL-2.1 sources and documents listed below. Design and code agents read this record, not iwd.
Everything here is in the writer's own words: no code, no copied comments, no iwd identifiers beyond
the protocol names every 802.11 implementation shares and the Linux kernel's own interface names
(nl80211, rtnetlink, AF_ALG), and no structure mirrored from iwd. The record is organised by the
questions a designer asks, not by iwd's files. Where a statement is an inference rather than
something read, it says so.

## Sources

iwd release 3.12, the latest tag in the official repository on 2026-11-15
(`https://git.kernel.org/pub/scm/network/wireless/iwd.git`, tag `3.12`, commit
`d003d0e593323b3de427f01284ede81ba61e9dcc`; cgit's tag page showed the date 2026-03-13, not
cross-checked). Fetched over HTTPS, read as data, nothing run or built.

* The release tarball `https://www.kernel.org/pub/linux/network/wireless/iwd-3.12.tar.xz`, SHA-256
  `d89a5e45c7180170e19be828f9e944a768c593758094fc57a358d0e7c4cb1a49`, which matches the line for it
  in kernel.org's `sha256sums.asc` in the same directory (the signature on that list was not
  checked). The tarball carries the source, the man-page sources and a bundled copy of the ell
  library, but not `doc/*.txt` or `autotests/`.
* The API and design documents under `doc/`, fetched one by one from
  `https://git.kernel.org/pub/scm/network/wireless/iwd.git/plain/doc/NAME?h=3.12` (the snapshot
  endpoint answered HTTP 400).
* The names of the `autotests/` directories, from the cgit tree page at the tag. No autotest file
  was read.

Local copies, outside the erXos tree, with a `SHA256SUMS` file covering every file used:
`~/erxos-scratch/sources/iwd-3.12/`. In citations `S` is `iwd-3.12/src/`, `E` is `iwd-3.12/ell/`,
`D` is `git-3.12/doc/`; other paths are relative to `iwd-3.12/`. Line numbers are those of these
copies.

| File | SHA-256 | File | SHA-256 |
|---|---|---|---|
| `D access-point-api.txt` | `41642244e7de3871a6a4c493200e18e12c8a370bcb5a9eeb8206792b3eb369f9` | `D adapter-api.txt` | `3b5e1cd78072c68bcbf0eb3f473c27a24b345bb805a21f934fe1bad8479107d9` |
| `D agent-api.txt` | `3245ed1fdcc04a83263a432b311e61e88dc52984b31d33fe30a64e052fb97aa6` | `D automatic-net-selection.txt` | `fcd36a43c8d81989e21d60bd31d838376cab3b4ed642be70fa521e993ad5d71f` |
| `D basic-service-set.txt` | `17653268f2593bffa51af1cc5d44ca4f5027f92c61ac5948bb94d445900d240f` | `D daemon-api.txt` | `d9e088e9d9b02f660706b528b8646fc5cd58bb174562a57d33c5916ecbe067d3` |
| `D device-api.txt` | `264819315d263211587175729500254f59babe90aee1a5a8837599314b50c5c1` | `D features.txt` | `ce8a99967264497ae319ce249f25c7971402abb45e1846571a895826eaeed336` |
| `D hwsim-rules-api.txt` | `12d20da3266bbf1756d42972a08dffa39b7062edf51e7051d7e4553f00276d39` | `D knownnetwork-api.txt` | `8d1c40bed9faa29f9900e9f5fc16e6f5925ae246ad66e08e4ed0fbb462248d2b` |
| `D network-api.txt` | `b95b6d8acf9c0552b4b16853aa7e09755446cd2ddfaeaae80f4ffc00478e6ae1` | `D p2p-api.txt` | `444d13a57cd4b201d6a0285c8917085cc74f1334c454c5a2488d16997d361555` |
| `D station-api.txt` | `f1b72fdf07b150dac6a9b30cc6f6d6fae8f4faaff94d33c1af57d1bc9781b434` | `D station-debug-api.txt` | `40690850d78fcd8fbc53ab491c079ef85cdd7e43f2b46bce5112d796f6b17881` |
| `D station-diagnostic-api.txt` | `5267d3656948b715b27a5df0738f0cdcf71c119c11556f34b0b808c55573e547` | `D test-runner.txt` | `4ae66393867c6ff526891e3690a50ac59ed59ccb5d265d50b5ee88aba16a1cc7` |
| `D wpa-auth.txt` | `cdb3e8e7df90fa338502f92abf265fbe6a66e11d27314afa1e82504c007ae87d` | `iwd-3.12.tar.xz` | `d89a5e45c7180170e19be828f9e944a768c593758094fc57a358d0e7c4cb1a49` |
| `ChangeLog` | `74b0c57ba0b092e2f4c323c88a2ee8b1b29b113d3be8c9d13ead930e4113ef65` | `E cert-crypto.c` | `b1cd2a107e8b038d42cbafaeb0a9bddfdcbbdeb5fedaeaf2f63a0797ee63882b` |
| `E checksum.c` | `da0a2fcd07a52da26ba8a1b1beeaf854d5a5c5e743f9c92918b0d203032613e3` | `E ecc-external.c` | `d5415753901aeafcd8ccbf877b9fa2cac34ff15419ec25978fa87b1dd242570f` |
| `E ecc.c` | `e09aaacca7d6ec8364d31bc7dd2ede394d4304eb7cecbd80310a1f692445fb15` | `E key.c` | `7b4effd49794f0a4d1778a0306d58b2170ed63dced5021ed9777867369027826` |
| `E tls.c` | `62784f642c1055d1eaa14cf8c7e7383a3067c644aebf21d582fd9bc3ea175b4e` | `README` | `b6435fb079926b6c243b30f5c155d62d0047c864e464868c408ea0c9cf1266b0` |
| `S agent.c` | `12b2f45d8d9a35d71fcc501b288554ba60d85c615a68b6d49d13e136497ed56f` | `S ap.c` | `71023816f16f0ddeece91b939d52003d3f8f58286969c1a5b4ea36f08d9ce247` |
| `S auth-proto.h` | `dbbfebf8370fb2d9412eeeceb1e43b066f98fc231b7b3bee01e875a9ed45ef6a` | `S band.c` | `94b85c53bf816edf6ede53236973bcf8de25c6c99114fd84e6ccd2e388f8f362` |
| `S blacklist.c` | `9a2b61f343828484824c443fba35f9a64f4d538e38e1b8d297e8c51a36270f35` | `S blacklist.h` | `b2e023f2c6e5bcb6580a45a0033f59017a75c3f4c5f370a8fea2aff05a565ba8` |
| `S common.c` | `98d296b186169409f6f1f04bd181daec642ea3964555be3483f34088c5f4f793` | `S crypto.c` | `874bcc13be432230d33ea22903ae348fa01ac883bcbe66011674c0f378596c55` |
| `S device.c` | `4fcad7bd0f8e83b834b9722d32e58581b5d558d5db4c7149d9825c091c30212a` | `S dpp.c` | `a212a92c3d0542bb6624e3e4152ce30a062104755ce227328c48b0f11401db5e` |
| `S eap-private.h` | `d67aec176810efe945c9d7cfe03ff386601a61c9904d8e123c3e503e22a2034d` | `S eap-tls-common.c` | `8eeafb62927430c71816f4584d439882a7cf97ef9a565d9994b0b8089804e038` |
| `S eap.h` | `0771d9d556a6fa69110b096f3b9c039d75528133dd81fca94f147822c863a276` | `S eapol.c` | `f3a165eeb4b7da87bd865b1b9b39d1678b976a24a73c08423b4ee03bc72ea2d7` |
| `S eapol.h` | `0f64135fab20e1054487080e4efb23f1ae01bd54f94f7fca015af5a2af40254a` | `S handshake.c` | `b08efa78b3e0661e2d756d89bb9747b1bbf0348f1d02d77d1c438fcbfe4076ff` |
| `S handshake.h` | `c88a40744a13232742b7e0e6a3125fb91ce8c42be228ed4f0d7d27eb213e95ed` | `S iwd-dbus.conf` | `b557ba99a30209444ab014f03ce80865ce0f711d81327cb8d2fae06b091d3071` |
| `S iwd.config.rst` | `c4235d0dba78647da345d840889ad8961e937f671df0a284081e3c5d89616df4` | `S iwd.network.rst` | `a36af4488af12806db2243ad1bfc9d1555403e517f39423210df595f432ef49b` |
| `S iwd.service.in` | `e01c8bfe215a8947e5bcfad002c2db2686cc49ee0ffba93e7ed66c232618ab3f` | `S knownnetworks.c` | `fc37d2576c1340c79b81fb3d923b7d985ec98377405934a5e1d937c6e56173c0` |
| `S main.c` | `de769b59adfb6d205db433f9ac4371297e8859506a1fa829ad197baa18a409b2` | `S manager.c` | `d3eb5c4d720357818c2860e1666547a4d743931a94229cbc56b9e33cfd3b7571` |
| `S module.h` | `678d18b8d818ac837dd5d2240afda529ffdb3bfbb94a605ec9a2876837ad2fa3` | `S netdev.c` | `4e5a2834266dabc4cae0ce7533642a251cedad2a331da1ad8cb4646b4a1132eb` |
| `S network.c` | `55c618082c187af989617563af45ed22ab32bd6c692efe490b3c240c375978f4` | `S pmksa.c` | `a8bca8c547d6084ec5a794944a902a07e156d74a2277cbbaa2298acccb4bf6db` |
| `S pmksa.h` | `9d03fbfef8e8a1bbb717df35b6311e02298eb41b4ea83002598d58566acea86f` | `S sae.c` | `44478f42aceb75d24582634db80473f2248d4b351e3fb4fd0a7ecf47c7106c08` |
| `S scan.c` | `610320579947dc2876afa29a07f88130e2e756935e32892a15b17cb93c4542e6` | `S station.c` | `b08fc7b3acb6ef041c3ddcdd12b159186ee9e85a0202abf5fed9fd86ba642577` |
| `S storage.c` | `04ae404382d0920bbf5fd94461c7827f8e01316792cfaa855805e5a440d42781` | `S util.c` | `cd33a7d33b0914ec27ac01c4b42a4b087a208827a95aafd9c5d41e3485e57fbb` |
| `S vendor_quirks.h` | `14e9c739c674f5768fc9b84b0f1b8d4334868e832125b7e8912a989283915748` | `S wiphy.c` | `51c85bb5a849f60f798ff10dc7d136d2d1f6afed84c8d67a5b71486b7022b833` |
| `S wiphy.h` | `bfdaf25b61f1298583c1491309eddd11ac0700354be28165e3d1626624fdfde2` | `TODO` | `458dd0818114267c1875459905947e422bd94eb8766fb9cfd80dd607ded8d813` |
| `unit/test-eapol.c` | `648dea8707bd262b94e737f31bd86c754f26f144f5114a69eb3194c0652798d3` |  |  |

## 1. Architecture

**1. One daemon, no external supplicant.** Station management, scanning, the 4-way and group
handshakes, SAE, OWE, FILS, Fast Transition, pre-authentication, every EAP method, AP mode, ad-hoc,
P2P, DPP, WSC, Hotspot 2.0 queries, rfkill handling and optional IP configuration all run inside one
process. Its parts are built-in modules registered at link time, each naming the modules it depends
on; the start-up code orders them by those dependencies (`S module.h` whole file; the dependency
declarations sit at the end of each module, e.g. station depends on known networks, netdev,
netconfig, frame exchange and wiphy). Separate binaries exist only for the command-line client, a
netlink monitor, a radio simulator and an optional wired 802.1X daemon (`README` 78-97, 157-181).

**2. One thread, one event loop.** The daemon is single-threaded on ell's main loop. Every kernel
request is sent asynchronously with a completion callback and an id that can cancel it; timers are
loop timers (`S main.c` 536, 579-631). Start-up order: a crypto capability check, a generic-netlink
socket, the system D-Bus connection, acquisition of the service name, and only once the kernel's
nl80211 family is resolved are the modules initialised; if nl80211 never appears the daemon quits
(`S main.c` 182-205, 231-253).

**3. Its own support library.** ell supplies the D-Bus implementation (no libdbus), generic netlink,
rtnetlink, a settings-file parser, DHCPv4 and DHCPv6 clients and a DHCP server, TLS, X.509 handling
and elliptic-curve arithmetic (`E` directory listing). Because ell's API is not stable, the bundled
copy is the preferred build (`README` 147-155).

**4. How it talks to the kernel.** nl80211 over generic netlink for radios, interfaces, scanning,
connecting, keys, CQM and management frames; rtnetlink for link up/down, MAC address and operational
state; a raw packet socket for EAPoL only when the driver cannot carry EAPoL over nl80211; sysfs
writes for neighbour-cache behaviour; the rfkill device. On a new radio it dumps the existing
interfaces, deletes the default one and creates its own (one netdev per radio for station, AP and
ad-hoc, plus an optional P2P device), each created with nl80211's socket-owner attribute so the
kernel removes them if the daemon's socket closes. Interfaces created by someone else later are left
alone, not fought over (`S manager.c` 195-230, 646-658). A built-in driver-name list keeps the
default interface for drivers known to misbehave when it is destroyed; the list includes brcmfmac
(`S wiphy.c` 104-117), and the configuration can extend it (`S iwd.config.rst` 462-466).

**5. The kernel cleans up after a dead daemon.** Connect, associate and AP-start requests carry the
socket-owner attribute too, so a daemon crash disconnects the link instead of leaving it
half-managed (`S netdev.c` 2648, 2990, 4466; `S ap.c` 2876). EAPoL normally travels over nl80211's
control-port path straight to the owning socket instead of through the network device; the
documented reasons are CPU saved and an old race removed (the race between key installation and
data-path frames). A driver quirk list forces the raw-socket path for drivers that advertise control
port but break it (`S iwd.config.rst` 172-180, 468-473; `S netdev.c` 2023-2056).

**6. One work queue per radio.** Everything that needs the radio exclusively goes through an ordered
queue per radio. Priorities, highest first: FT authentication; action-frame exchanges and
off-channel work; connecting; user scans; periodic scans. One item runs at a time; an item can
report that it is still running and keep the head of the queue until it calls done; it can also be
re-queued under a new id (`S wiphy.h` 51-56; `S wiphy.c` 2694-2835). Consequence: scans never
collide with a connect or a roam, and background scans always yield.

**7. Connection type chosen from what the hardware offers.** For each AKM the daemon picks one of:
it runs authentication, association and the handshake itself (SoftMAC); the firmware associates and
the daemon runs only the handshake (FullMAC); the firmware also runs the PSK handshake, the 802.1X
handshake or SAE (three offload kinds); or SAE runs in the daemon over the kernel's
external-authentication path on FullMAC hardware. Offload wins when the hardware advertises it; FILS
is SoftMAC only; FT needs SoftMAC or firmware roaming (`S netdev.c` 4067-4161; `S wiphy.c` 243-281).

**8. Protocol cores behind narrow seams.** The pre-association exchanges (SAE, OWE, FILS, FT) share
one small interface: start, take a received Authentication frame, take a received Association
response, check the operating-channel information, and handle the two timeouts. Return values sort a
frame into ignore, retry inside the protocol, or fatal (`S auth-proto.h` whole file). The EAPoL
state machine never touches the kernel: transmitting a frame, drawing a nonce and installing each
key kind are callbacks set by the netdev layer (`S eapol.h` 109-114; `S handshake.h` 70-94).
Per-connection state (keys, the elements both sides sent, the chosen suites) lives in one handshake
object shared by these parts.

**9. Control surface: a D-Bus object tree.** One service name with the standard object manager at
the root (`S main.c` 231-253). A daemon object (version, state directory, whether IP configuration
is on) and an agent manager (`D daemon-api.txt` 8-30). One adapter per radio: powered, name, model,
vendor, supported modes (`D adapter-api.txt`). One device per interface: name, address, powered,
mode (station, AP, ad-hoc), where changing the mode swaps the interfaces on the object (`D
device-api.txt` 8-40). On the device, a station interface: scan, disconnect, the network list in the
daemon's rank order with signal strengths, the hidden-AP list, one-time hidden provisioning, a
signal-level agent with caller-chosen dBm thresholds, a state string, the connected network and BSS,
a scanning flag, a BSS affinity list (`D station-api.txt` 8-188). One network object per (SSID,
security class) seen: connect, name, connected, type, its known-network link and its BSS objects (`D
network-api.txt`); the path encodes the SSID in hex plus the class (`S station.c` 435-453). One
known-network object per profile: forget, name, type, hidden, last connected time, writable
autoconnect (`D knownnetwork-api.txt` 8-48). While connected, a diagnostics interface (BSSID,
frequency, security, RSSI and average, rates, MCS, cipher, times); for development, a debug
interface (connect or roam to a BSSID, scan chosen frequencies, per-BSS ranks, event signals) (`D
station-diagnostic-api.txt` 8-64; `D station-debug-api.txt` 1-68). Errors are named conditions
(busy, not found, service-set overlap, already provisioned, and so on).

**10. Two levels of state.** Clients see five station states: connected, disconnected, connecting,
disconnecting, roaming (`D station-api.txt` 138-143). Inside there are eleven: disconnected, quick
autoconnect, full autoconnect, connecting (user), connecting (auto), IP configuration, connected,
disconnecting, roaming, FT roaming and firmware roaming; the two autoconnect states are reported to
clients as disconnected (`S station.c` 1667-1695, 1757-1762).

**11. Secrets arrive through agents.** A client registers an agent object; the daemon calls it for a
passphrase, a private-key passphrase, a user name and password, or a password for a given user, and
cancels outstanding calls with a reason (out of range, user cancelled, timed out, shutdown) (`D
agent-api.txt` 71-131). The request timeout is a fixed 120 s (`S agent.c` 73-76). Several agents may
register, one per D-Bus client; a request goes to the agent of the client whose call started the
connection, otherwise to the first registered (`S agent.c` 327-335). Rules around secrets:
* autoconnect never prompts: a known network with missing secrets is skipped (`S network.c`
  970-1036);
* a passphrase typed into an agent is written to the profile only once the handshake has reached key
  installation, which proves it right (`S station.c` 1164-1173; `S network.c` 750-780);
* EAP secrets carry a cache policy of never or temporary; as read, temporary ones are kept in memory
  with the network and not written to its profile (`S eap.h` 36-54; `S network.c` 160-170, 400-445,
  724-725);
* a handshake failure, or a 4-way timeout, during a user-started connect makes the next attempt ask
  again (`S network.c` 1038-1051; `S station.c` 3739-3749).
A second agent kind can take over committing IP configuration; connection success then waits for
that agent (`D agent-api.txt` 28-59, 133-265).

**12. Authorisation is coarse.** The D-Bus policy lets root own the name and lets root and the
`wheel` and `netdev` groups call any method; everyone else is denied. No per-method check or polkit
use was found (`S iwd-dbus.conf` 10-28; grep of `S`). The shipped systemd unit keeps only the
network-admin, raw-socket and bind capabilities, protects the file system strictly, makes the state
directory mode 0700 and restarts the daemon on failure (`S iwd.service.in` 8-26).

## 2. Station behaviour

**13. A network is (SSID, security class).** The classes are open, WEP, PSK and 802.1X. Every
PSK-like AKM (PSK, PSK-SHA256, FT-PSK, SAE, FT-SAE) falls in the PSK class, every 802.1X and FILS
AKM in 802.1X, and OWE in open (`S common.c` 67-105). WPA2/WPA3 and open/OWE transition therefore
happen per BSS inside one network, and one profile covers both halves. BSSs whose SSID is not valid
UTF-8 are dropped from results (`S station.c` 1058, 1087).

**14. Quick scan first.** After start-up or a disconnect the station scans only the frequencies on
which the five most recently used known networks were seen, at most five frequencies each (`S
station.c` 69-70, 1614-1665). If that finds nothing to join, or cannot start, it falls back to full
autoconnect with periodic scanning (`S station.c` 1560-1605, 1767-1777). The quick scan waits while
the regulatory domain is being updated, and is skipped when 6 GHz was used before but is disabled
under an unknown country, since only a wide scan collects the beacons that re-enable it (`S
station.c` 1620-1645).

**15. Periodic scanning.** While disconnected, scans repeat from 10 s, doubling up to 300 s;
connecting stops them (`S scan.c` 1159-1180, 2660-2672; `S iwd.config.rst` 401-417). Periodic scans
are passive unless the previous results held a hidden BSS and a hidden network is known, in which
case the next one probes (`S scan.c` 1035-1068, 1999-2013). Quick and user scans are active when the
hardware can randomise the probe source address, when connected, or when a hidden network has to be
probed, and passive otherwise (`S station.c` 1532-1558). When disconnected, probe requests use a
randomised source address if the hardware supports it, and random sequence numbers (`S scan.c`
386-419). The radio's scheduled-scan capability is recorded (`S wiphy.c` 1429-1431), but no code
that starts a scheduled scan was found by grep; `D features.txt` 5-9 says one is used, which looks
stale (unverified beyond grep).

**16. Scan cache.** New results merge into the old: a cached BSS is dropped only when its frequency
was in the scan and it is older than 30 s, and the connected BSS is never dropped (`S station.c`
675-700, 1078-1150). A partial scan thus refreshes only what it covered. A user-requested scan runs
in subsets (2.4 GHz channels 1, 6 and 11; then 5 and 6 GHz; then the rest of 2.4 GHz) and publishes
results after each (`S station.c` 4491-4527, 5059-5100).

**17. BSS rank (0 to 65535).** The base is an estimate of the achievable data rate, worked out from
the RSSI and the HT, VHT and HE capabilities of both ends (`S scan.c` 1629-1640; `S wiphy.c` 1022;
`S band.c` 83, 251, 409, 596), divided by a ceiling of about 9.6 Gb/s. It is then multiplied by a
configurable per-band factor (2.4, 5 and 6 GHz; zero disables the band), by a load factor from the
BSS Load element (by default 0.8 at utilisation of 192/255 or more and 1.2 at 63/255 or less;
optionally an exponential decay above configurable utilisation and station-count thresholds), and by
an SNR factor (0.8 at 15 dB or less, 1.2 at 30 dB or more) (`S scan.c` 1693-1803; `S iwd.config.rst`
336-387). `D features.txt` 11-15 still describes the choice as highest signal.

**18. Network rank: four bands that do not overlap.** The connected network is always first. Known
networks that have been connected before come next: the best BSS rank scaled by a decay factor for
the network's position in the last-connected order (a fixed table falling roughly as the inverse 0.3
power of the position, floor about 0.29), shifted above the next band. Known networks never
connected use the plain best BSS rank; unknown networks get negative ranks. Within all bands the
result is then multiplied by 1.2 for an RSN element, 1.0 for WPA1, 0.5 for no security element, and
0.5 again when the privacy bit is clear (`S network.c` 1961-2020; `S util.c` 640-666). The position
counts only known networks currently seen by some radio (`S knownnetworks.c` 199-225). The same
order is what clients get as the ordered network list (`D station-api.txt` 25-50).

**19. Autoconnect.** Once scan results are in and any pending Hotspot 2.0 queries and hidden-OWE
probes have finished, the station lists networks by rank and tries each one's best BSS in turn,
moving on after each failure, and returns to full autoconnect when the list is exhausted (`S
station.c` 320-386, 3754-3760). The autoconnect path requires a known network with its autoconnect
flag set (`S network.c` 970-1036). `D automatic-net-selection.txt` 19-21 says networks never
connected are ignored, and a helper in `S network.c` 220-240 encodes that rule, but grep finds no
caller of it, so a pre-provisioned profile appears to be eligible (read, not tested). Within a
network BSS selection walks rank order, skips BSSs that fail the policy check (fact 36), that failed
earlier in this attempt or that are on the timed blocklist, and prefers the OWE half of an OWE
transition pair; a user-started connect falls back to a blocklisted BSS when nothing else is left
(`S network.c` 1257-1315).

**20. Failure handling and backoff.** The status or reason code decides what happens next (`S
station.c` 3493-3614):
* codes that mean bad credentials (802.1X failure, previous authentication no longer valid) stop the
  attempt and blocklist nothing;
* an SAE association rejected for an invalid PMKID retries the same BSS without the cached PMKSA;
* "no more stations" puts the BSS on a short busy list;
* bandwidth, poor channel and "rejected with suggested transition" only skip the BSS for this
  attempt;
* everything else puts the BSS on the timed blocklist; then the next BSS of the same network is
  tried.
A failed OWE association is retried once with group 19 as a workaround for APs that derive keys
wrongly (`S station.c` 3470-3491). The timed blocklist starts at 60 s, is multiplied by 30 on each
repeat failure, and caps at 24 h; the busy list starts at 30 s; entries expire lazily when looked
up, with no timers (`S blacklist.c` 41-49, 78-96, 140-171; `S iwd.config.rst` 274-322). The
per-attempt skip list clears on success or disconnect (`S network.c` 172-175, 210-218; `S station.c`
1802).

**21. Roam triggers.**
* Signal below a threshold (defaults -70 dBm on 2.4 GHz and -76 dBm on 5 GHz) arms a 5 s timer;
  rising back above it cancels the timer (`S station.c` 3419-3439; `S iwd.config.rst` 124-135).
* A packet-loss report of at least 10 packets roams at once, but at most one roam scan per 2 s;
  beacon loss roams after 2 s (`S station.c` 3794-3845).
* An AP's BSS Transition Management request is checked to come from the current BSS (both address
  fields) and parsed with bounds checks. If it announces imminent disassociation or termination, the
  roam is forced even to a worse candidate. The requesting BSS goes on the busy list. The candidate
  list in the frame is used, unless a per-AP-vendor quirk says to ignore it; otherwise a neighbour
  report is requested, otherwise a full scan runs (`S station.c` 3266-3417).
The threshold reaches the kernel as a CQM list with 5 dB hysteresis that also carries the
signal-level agent's thresholds, so one mechanism serves roaming and the UI meter; if the driver
refuses CQM, the daemon polls RSSI every second (`S netdev.c` 3844-3990). The daemon does no roaming
of its own when the hardware roams by itself, or when roam scans are disabled by configuration (`S
station.c` 3188-3209).

**22. Roam scan.** Channels come from, in order: a neighbour report cached at connect time (the
daemon requests one right after every connect and roam so it is ready); a fresh neighbour report
request; the frequencies known for this network; a full scan. The scan is active and names the SSID.
If a limited scan finds nothing while the signal stays low, a full scan follows immediately;
otherwise the roam is retried after 60 s (`S station.c` 2364-2476, 3041-3186, 3616-3631; `S
iwd.config.rst` 152-157).

**23. Choosing a roam target.** Candidates must have the same SSID and security class, pass the
policy check and not be on the timed blocklist. Their rank is multiplied by 1.3 when they share the
current FT mobility domain, then two flags are placed above the 16-bit rank: signal above the low
threshold, and not on the busy list. A candidate must beat the current BSS's value computed the same
way, except on an AP-forced roam (`S station.c` 170-241, 2893-3032).

**24. Executing a roam.** FT when possible: over the distribution system when the AP advertises it,
otherwise over the air, with an on-channel shortcut; the FT exchange runs as the highest-priority
radio work item. If FT fails with an invalid PMKID, the same BSS is re-queued for a plain
reassociation; other FT failures move to the next candidate (`S station.c` 2609-2743). Without FT,
an 802.1X connection whose current and target BSS both advertise pre-authentication
pre-authenticates over the current link (EAPoL ethertype 0x88c7) and then reassociates with the new
PMKID; otherwise a full reassociation and handshake run (`S station.c` 2745-2817; `D features.txt`
27-32). A failed reassociation leaves the station disconnected (`S station.c` 2420-2433). IP
configuration survives the roam or restarts after it, and the kernel's evict-on-carrier-loss
behaviour for ARP and neighbour entries is turned off during roams so cached neighbours survive (`S
station.c` 1697-1708, 1861-1874, 2375-2377). `D features.txt` 34-37 says only FT over the air is
supported; the code also does FT over the distribution system.

**25. Affinity.** A client may pin the current BSS. The roam threshold then drops to a critical
level (defaults -80 and -82 dBm) until the pin is cleared, the station roams or disconnects, or the
pinning client leaves the bus (`D station-api.txt` 173-188; `S iwd.config.rst` 136-150; `S
station.c` 1846-1850).

**26. Hidden networks.** A hidden network is joined only from a profile marked hidden. Scans made
while autoconnecting probe for the known hidden SSIDs; periodic scans do so only after a hidden BSS
has appeared in results; the SSIDs are packed up to the radio's per-scan SSID limit (`S station.c`
1506-1515; `S scan.c` 518-590, 1040-1060, 1999-2013). A one-time provisioning call finds and joins
an open or PSK hidden network by SSID; 802.1X hidden networks must be provisioned by file; an SSID
found as both open and PSK is refused as an overlap (`D station-api.txt` 52-107; `D
knownnetwork-api.txt` 26-33).

**27. Disconnect and interface lifetime.** A user disconnect also turns autoconnect off for that
device until the next user connect (`D station-api.txt` 15-23). Bringing the interface down removes
the station entirely; bringing it up creates a fresh one (`S station.c` 5925-5953).

**28. Link state follows authorisation.** On connect the link is set dormant and moved to up only
when the keys are in, so other daemons treat the link as usable only after authorisation (`S
netdev.c` 1429-1440).

## 3. Known networks and profiles

**29. One small file per network.** Profiles live in a state directory (default `/var/lib/iwd`, or
the directory systemd provides). The file name is the SSID (kept as is when it contains only
alphanumerics, space, underscore and minus, otherwise an equals sign and its hex) plus `.open`,
`.psk` or `.8021x`. The syntax is key=value lines in groups, like desktop entry files, with an
extension group kind that embeds PEM blocks (`S iwd.network.rst` 28-101). The daemon watches the
directory and reacts to files created, edited or removed by hand (`S iwd.network.rst` 33-36; `S
knownnetworks.c` 794-860, 1130). Writes go to a temporary file that is then renamed over the old one
(`S storage.c` 140-180).

**30. Timestamps are file times.** The last-connected time is the profile's modification time, and a
successful connection updates it (`S knownnetworks.c` 67; `S storage.c` 628-640); there is no
timestamp field. Per-network lists of frequencies seen live in a separate hidden file, keyed by a
UUID derived from the profile path and that time, so forgetting and re-adding a network gives it a
new identity (`S storage.c` 56, 683-704; `S knownnetworks.c` 354-371).

**31. What a profile holds** (`S iwd.network.rst` 114-450): autoconnect, hidden, per-network MAC
choices (fresh random address per connection, or a fixed one), the transition-disable flag and
disabled modes, a pin to the default ECC group, the passphrase, an SAE password identifier, a raw
PSK, the EAP method and its settings, static IPv4 and IPv6 configuration, whether DHCP sends the
host name, and multicast DNS. The daemon writes back the PSK it derived, the passphrase, the
password identifier and the SAE password elements (PT) for groups 19 and 20 (`S network.c` 62,
699-748). A legacy file holding only a PSK still works for WPA2, but SAE needs the passphrase, so
the agent is asked and the file rewritten (`S network.c` 623-679); a missing or malformed PT is
recomputed (`S network.c` 566-602). The passphrase, PSK and PT each let their holder authenticate as
the station (inference from the protocols). By default they are stored in clear in a 0700 directory;
an experimental option encrypts the security group with AES-SIV under a key systemd supplies, using
a random salt and the SSID as associated data; there is no way back except an offline tool (`S
iwd.config.rst` 200-216; `S storage.c` 400-452).

**32. Open networks become known on first success.** The first successful connection to an unknown
open network writes an empty profile, which makes it known and records the time (`S network.c`
183-194).

**33. Transition Disable is remembered.** A Transition Disable indication received in 4-way message
3 is stored in the profile as the disabled modes (personal, enterprise, open), and from then on
removes the legacy AKMs for that network (`S eapol.c` 2025-2032; `S network.c` 360-381, 699-722; `S
iwd.network.rst` 146-176).

## 4. Security handling

**34. AKM and cipher preference** (`S wiphy.c` 178-213, 283-375).
* 802.1X class: FT over FILS (SHA-384, then SHA-256) and FILS (SHA-384, then SHA-256) when cached
  ERP keys exist and the radio is SoftMAC; then FT-802.1X (SoftMAC, mobility domain present); then
  802.1X-SHA256; then 802.1X.
* PSK class: if the BSS is WPA3-Personal and the radio can do SAE, FT-SAE, then SAE; otherwise
  FT-PSK (SoftMAC, or PSK offload with firmware roaming), then PSK-SHA256, then PSK.
* Open class: OWE unless disabled for the driver.
The radio can do SAE only with CCMP and BIP-CMAC support, without the driver quirk that disables
SAE, and with one of the three kernel models of fact 7 (`S wiphy.c` 220-281). Pairwise and group
ciphers rank GCMP-256, CCMP-256, GCMP-128, CCMP-128, TKIP; management ciphers rank BIP-GMAC-256,
BIP-CMAC-256, BIP-GMAC-128, BIP-CMAC-128.

**35. PMF, OCV, Extended Key ID.** A setting of 0, 1 or 2, default 1: protection is used when both
ends support it; 2 requires it; 0 turns it off and thereby disables 6 GHz. On 6 GHz protection is
always required. An AP that requires protection is refused when the station cannot provide it (`S
station.c` 1273-1319; `S iwd.config.rst` 159-170). Operating channel validation is offered only when
the AP advertises it, protection is negotiated, no offload is in use and the AKM is not FT (the FT
case waits on kernel support) (`S station.c` 1321-1345). Extended Key ID is used only with CCMP or
GCMP and when both sides support it (`S station.c` 1347-1354).

**36. Per-BSS policy check** (`S network.c` 833-968). WEP is refused (also `D network-api.txt` 12).
On 6 GHz there is no open network without OWE, protection is required, TKIP is excluded and only
SAE, 802.1X or OWE AKMs qualify. When a Transition Disable record exists: personal removes the PSK
AKMs, enterprise removes plain 802.1X, open requires OWE, and TKIP and unprotected association are
excluded. Finally the radio must be able to select a pairwise cipher, a group cipher, a management
cipher when protection is required, and an AKM.

**37. SAE.** Groups are tried in ell's curve order; groups 21, 25 and 26 are skipped as
non-functional, and a per-network setting can force group 19 (`S sae.c` 151-196). Hash-to- element
is used only when the AP's RSNX element says so, with the PT computed for groups 19 and 20 when the
passphrase is set and cached in the profile (`S network.c` 319-334, 447-477). In hash-to-element
mode the rejected-groups element is sent in the commit and used as the key derivation salt;
anti-clogging token containers are supported (`S sae.c` 114-133, 631-639, 752-754). Retransmission
after 2 s, at most 3 state resyncs, at most 3 association retries (`S sae.c` 45-61). A password
identifier must be configured exactly when the BSS uses one (`S network.c` 494-505). When an AP
rejects the chosen ECC group, that network is pinned to the default group 19 for the rest of the
process's life (`S iwd.network.rst` 177-183; `S station.c` 3857-3867).

**38. OWE.** Open and OWE BSSs of one SSID form one network (fact 13). A transition pair is accepted
only when each BSS's transition element names the other's SSID and BSSID. The hidden OWE half is
found by a targeted scan that autoconnect waits for, and the open half is avoided whenever the OWE
half is usable (`S station.c` 371-375, 887-960; `S network.c` 1291-1302).

**39. EAP.** Each method registers with: a settings check (run before connecting, so missing secrets
are known up front and asked for together), settings loading, request and retransmit handling,
identity handling, and whether it exports an MSK (`S eap-private.h` 61-86). TLS, TTLS and PEAP share
one TLS core built on ell's TLS. Methods: AKA, AKA', MSCHAPv2, PEAP, PWD, SIM, TLS, TTLS, plus GTC
and MD5 as inner methods, TTLS's tunnelled non-EAP methods, and WSC (`S iwd.network.rst` 220-337; `D
features.txt` 55-65). A server domain mask is accepted only together with a CA certificate (`S
eap-tls-common.c` 1012-1040). TLS session resumption is a per-network switch because some RADIUS
servers fail every other attempt with it (`S iwd.network.rst` 297-311). ERP keys are kept for FILS
reconnection (`S station.c` 1232-1241); SIM credentials can come from oFono (`README` 190-194).

**40. PMKSA caching.** An in-memory cache, 255 entries by default, kept in expiry order, evicting
the entry closest to expiry when full; entries live 12 h and are keyed by own address, AP address,
SSID and AKM; they can also be pushed to the driver; one switch disables the whole cache (`S
pmksa.c` 41-42, 140-256; `S iwd.config.rst` 228-231). The cache is looked up only for SAE AKMs; an
invalid-PMKID rejection falls back to full SAE (`S station.c` 1355-1365, 3530-3561). The project
TODO still lists PMK caching and Opportunistic Key Caching as not done (`TODO` 179-193); the first
is done for SAE, and grep found no OKC code.

**41. 4-way handshake and key installation order** (`S eapol.c` 1740-2119):
* message 3 with a bad MIC is silently dropped;
* the RSN element in message 3 must equal the one from the beacon or probe response bit for bit, or
  the station deauthenticates with "IE different"; an optional second RSN element is checked to
  differ only in its pairwise suites, which must be a subset;
* operating channel information is validated when negotiated;
* a P2P IP address allocation element is checked; a Transition Disable element is passed up.
Then the group and integrity group keys are installed first, an identical group key is never
reinstalled (`S eapol.c` 1000-1016), message 4 is sent, the pairwise key is installed, and only then
is the peer marked authorised, which opens the controlled port (`S eapol.c` 2079-2106; `S netdev.c`
1920-1955). A retransmitted message 3 after completion gets message 4 again without reinstalling (`S
eapol.c` 2103-2104). On an Extended Key ID rekey the new key is installed for receive only, message
4 is sent, and then transmit switches (`S eapol.c` 2088-2099; `S netdev.c` 2075-2112). KEK, KCK and
replay counter go to the driver for group rekey offload (`S eapol.c` 2108-2110; `D wpa-auth.txt`
93-99). For WPA1, where the group handshake follows, the connection completes without group traffic
if no group key arrives within 2 s (`S netdev.c` 2114-2167). The whole handshake has a 5 s default
deadline (`S eapol.c` 52, 2865, 3186-3188). A rekey the hardware cannot do securely makes the
station reconnect (`S station.c` 1178-1180). One EAPoL frame that arrives before the state machine
is ready is buffered and replayed (`S eapol.c` 2714-2718, 2880-2885).

**42. Management-frame defences.** With protection negotiated, an unprotected deauthentication or
disassociation triggers an SA Query to the AP instead of an immediate disconnect, and the station
answers the AP's SA Queries (`D features.txt` 46-50; `S netdev.c` 4928-5177).

**43. What it refuses, in one place.** WEP; SSIDs that are not UTF-8; open networks on 6 GHz; hidden
802.1X networks through the provisioning call; SAE on hardware without CCMP and BIP-CMAC; FILS
without SoftMAC; TDLS and AP peer-key connection types (`S netdev.c` 4138-4141); a passphrase
outside 8 to 63 printable ASCII characters (`S crypto.c` 524-554).

## 5. Crypto

**44. Symmetric crypto through the kernel.** Hashes and HMACs (MD5, SHA-1, SHA-256, SHA-384,
SHA-512), CMAC-AES, AES in ECB, CBC and CTR, DES and 3DES go through the kernel's crypto user-space
socket interface (AF_ALG): a socket per algorithm and key, data sent with the more-data flag, the
digest read back (`E checksum.c` 127-163, 285-319). At start-up the daemon probes each needed
algorithm and prints the missing kernel configuration options, and refuses to start when a mandatory
one is missing (`S main.c` 273-403, 533).

**45. Asymmetric crypto is split.** Finite-field Diffie-Hellman (for WPS) and RSA/X.509 operations
for EAP-TLS go through the kernel keyring (keyctl DH compute and public-key operations); TLS-based
EAP needs kernel 4.20 or later (`E key.c` 26-35; `S main.c` 356-377). Elliptic-curve arithmetic for
SAE, OWE and DPP is in user space in ell, from a BSD-licensed small ECC library (`E ecc-external.c`
header). The TLS protocol itself is ell's own code (`E tls.c`, about 4000 lines). ARC4 for legacy
TKIP key unwrapping is a local routine (`S crypto.c` 444-490).

**46. Why.** No rationale was found in the documents read. The visible gains (inference): no OpenSSL
or other crypto library, and the kernel's accelerated implementations for free (the start-up check
names optional accelerated drivers, `S main.c` 285, 302-303, 312-319).

**47. Costs.** Linux only and dependent on kernel configuration; every primitive call is a
system-call round trip, so PBKDF2 for the PSK (4096 iterations for each of two output blocks, each
an HMAC update and digest read over the socket) is many thousands of calls (`S crypto.c` 556-586; `E
cert-crypto.c` 97-165; not measured, so unverified); that work and the PT derivation for two groups
run synchronously on the event loop when a passphrase is set or loaded (`S network.c` 281-301,
319-334); EAP-TLS is bounded by the kernel's asymmetric-key parsers (`S main.c` 367-377).

## 6. Regulatory, power, privacy, other modes

**48. Regulatory.** A configured country is only a request: self-managed radios cannot be set from
user space, and for others it is a hint the kernel may ignore (`S iwd.config.rst` 218-226). On a
regulatory change the daemon re-reads the radio's channel data; quick scans wait for that (`S
wiphy.c` 1134-1137, 2295-2330). The codes "OO" and "XX" count as an unknown country, meaning the
disabled-channel list may still change (`S wiphy.c` 948-960); see fact 14 for 6 GHz.

**49. Power save.** The kernel default is left alone; power save is turned off only for drivers on a
quirk list (`S netdev.c` 6421-6438, 6472; `S iwd.config.rst` 475-478). Automatic power save delivery
is listed as future work (`TODO` 195-200).

**50. MAC address policy** (`S iwd.config.rst` 90-122; `S iwd.network.rst` 131-145). Probe requests
use a random source while disconnected, when the hardware allows. The connection address is by
default the permanent one; "once" randomises it at start-up or hot-plug; "per network" derives it
from SHA-256 over the SSID and the permanent address, stable per network while hiding the permanent
one; a profile may instead ask for a fresh random address on every connection, or a fixed address.
Randomisation covers all six octets with the locally administered bit set, or only the last three
below the hardware OUI (`S wiphy.c` 818-845; `S network.c` 540-561). The address changes with the
interface up when the driver supports that, else with a down/up cycle (`S netdev.c` 3792-3843).

**51. Other modes, briefly.** AP mode with a built-in DHCP server and an address pool, but no EAP
(`D features.txt` 67-70; `S iwd.config.rst` 438-448); ad-hoc with RSN; Wi-Fi Direct (P2P) with its
own API objects; DPP by QR code and by PKEX, with an agent for shared codes; WSC push button and
PIN; Hotspot 2.0 with ANQP queries, off by default because some drivers freeze or crash on public
action frames (`S iwd.config.rst` 182-191; `S dpp.c`; `S iwd-dbus.conf` 15).

**52. IP configuration is optional and built in.** When enabled: static addresses from the profile,
or DHCPv4, DHCPv6 and router advertisements through ell; DNS through systemd-resolved or resolvconf;
a route-metric offset. DHCP may take about 30 s per BSS before a connect fails; FILS IP address
assignment can skip DHCP (`S iwd.config.rst` 57-75, 244-272; `D network-api.txt` 14-18; `S
station.c` 3634-3672).

## 7. Robustness

**53. Nothing waits on a peer indefinitely.** Kernel requests are asynchronous and cancellable;
agents time out at 120 s; the handshake, SAE and the WPA1 group key each have deadlines (facts 11,
37, 41). CPU-bound crypto is the exception (fact 47).

**54. Restart is the recovery.** Socket ownership makes the kernel drop the link and the daemon's
interfaces when the daemon dies (facts 4, 5); systemd restarts it; on start it redoes interface
setup. Persistent state is just the profiles and the frequency file, so a restart loses only caches
(PMKSA, scan results, blocklist) (`S manager.c` 646-658; `S iwd.service.in` 14; `S pmksa.c` whole
file). Interface down or removal discards the station and up creates a new one (fact 27); soft and
hard rfkill state is tracked per radio (`S wiphy.c` 2043-2044; `S device.c` 313-324).

**55. Driver trouble is handled by lists, not detection.** Driver-name quirks: keep the default
interface, force raw EAPoL, no power save, no multicast receive, no SAE, no OWE (`S wiphy.c` 70-125;
`S iwd.config.rst` 450-492). AP-vendor quirks keyed by OUI: ignore the candidate lists in transition
requests, tolerate replay-counter mismatches (`S vendor_quirks.h`). Where a failure can be seen at
run time it is handled: CQM refusal switches to polling (fact 21), firmware roam events have a state
of their own (fact 10), an insecure rekey forces a reconnect (fact 41).

**56. Frames from the air are untrusted.** Parsers check lengths before reading, as the
transition-request parser shows (`S station.c` 3285-3374). A frame-fuzzing autotest exists
(directory name only; contents not read).

## 8. Testing

**57. Unit tests.** 25 test programs with about 200 registered cases (count of registration calls):
crypto vectors (HMAC variants, PRF, KDF, CMAC, ARC4), element and MPDU parsing, SAE, EAPoL, EAP-SIM,
MSCHAPv2, WSC, DPP, P2P, PMKSA, storage, data-rate estimation (`unit/` listing). The EAPoL tests
drive the state machine with canned frames by replacing the transmit, nonce and key-install
callbacks of fact 8 (`unit/test-eapol.c` 2164-2257).

**58. Whole-system tests on simulated air.** About sixty scenario directories at the tag cover each
security mode and its options, SAE (anti-clogging, roaming, PMKSA), OWE transition, FT over 802.1X
and FILS, pre-authentication, roam retry, neighbour reports, the blocklist, hidden and known
networks, address randomisation, affinity, EAP variants with fragmentation, EAPoL and SA Query
spoofing, frame fuzzing, channel switch, IP configuration, AP, P2P, DPP, Hotspot, ad-hoc and agents
(cgit listing). Each holds one hardware description (up to 100 radios, per-radio disabled interface
types and ciphers, hostapd instances, an optional RADIUS-only server), Python test scripts and
hostapd configurations (`D test-runner.txt` 172-264). The runner boots User Mode Linux (recommended
as faster and steadier in timing) or QEMU over a read-only host file system, with hostapd,
wpa_supplicant, radvd and a DHCP server (`D test-runner.txt` 11-60). The air is mac80211_hwsim plus
the project's simulator daemon, whose frame rules match source, destination and frequency in
priority order and can set RSSI, drop or delay (`D hwsim-rules-api.txt` 1-75; `README` 246-264).
Simulated radios cannot yet vary their capabilities (`TODO` 78-89).

**59. What makes it testable.** Callback seams around the protocol cores (fact 8), a real reference
AP over simulated air, a debug interface to force BSSIDs and roams and watch internal events (fact
9), and a netlink monitor that decodes nl80211 traffic and merges with an EAPoL capture (`README`
197-243).

## 9. Weaknesses and lessons

**60. Bound to Linux by construction.** nl80211, rtnetlink, AF_ALG, keyctl, sysfs and mac80211_hwsim
run through every layer, and ell's API is unstable (fact 3). Nothing sits behind a kernel-neutral
interface.

**61. Documents drift from code.** Read against 3.12's code: `D features.txt` claims scheduled
scans, a single agent, FT over the air only and highest-signal BSS choice (facts 15, 11, 24, 17); `D
automatic-net-selection.txt` excludes never-connected networks (fact 19); the TODO still lists P2P,
DPP and PMK caching as future work (`TODO` 179-186, 213-221, 246-252).

**62. Open items the project lists.** Opportunistic Key Caching; automatic power save delivery;
802.11v network management beyond transition handling; TDLS; EAP-LEAP and EAP-OTP; WSC session
overlap detection; the OCE features (FILS Discovery frames, Reduced Neighbor Reports, OCE scan
flags, scanning channels 1, 6 and 11 first, RSSI-based association rejection, Extended BSS Load and
ESP); reusing an unexpired DHCP lease on rejoin (`TODO` 158-349). In code: the disassociation timer
and validity interval of transition requests are ignored, because the request is handled at once (`S
station.c` 3319-3326); the neighbour report that may come with a "suggested transition" rejection is
not used (`S station.c` 3578-3583); SAE groups 21, 25 and 26 do not work (`S sae.c` 172-178); OCV is
off for FT (`S station.c` 1338-1342); the agent timeout is not configurable (`S agent.c` 66-72).

**63. Other limits a designer should weigh.** Secrets are in clear on disk unless the experimental
encryption is on (fact 31); authorisation is per bus group, not per operation (fact 12); crypto
blocks the event loop (fact 47); driver problems are handled by name lists someone must maintain
(fact 55); AP mode has no enterprise security; hidden enterprise networks need a file; Hotspot 2.0
queries are off by default; turning protection off loses 6 GHz.

## Ideas worth considering

Neutral statements of ideas found in iwd, for comparison with other systems; no recommendation for
erXos.

* One process owns the whole station stack, supplicant included, so policy and protocol share one
  state model and no inter-process supplicant protocol exists.
* Network identity as (SSID, security class), with WPA2/WPA3 and open/OWE folded into one class, so
  transition modes are a per-BSS choice inside one network and one profile.
* A per-radio priority queue of exclusive radio work, so scans, connects, FT and off-channel
  exchanges never collide and background work always yields.
* Kernel-side cleanup tied to the daemon's socket, so a crash disconnects instead of leaving a
  half-managed link, and restart becomes the recovery path.
* Protocol cores (EAPoL, SAE, element parsing) that reach the driver only through callbacks,
  unit-tested with canned frames.
* A quick scan of recently used frequencies before a full scan; periodic scans with exponential
  backoff; passive scanning unless a hidden network is actually present.
* A BSS rank based on estimated data rate rather than raw RSSI, scaled by band, load and SNR;
  network ranking in separate bands ordered by recency of use.
* Roaming fed by neighbour reports fetched at connect time, CQM thresholds with a polling fallback,
  AP transition requests treated as hints unless disassociation is imminent, and a short "busy"
  blocklist kept apart from a long "failed" one.
* Failure handling keyed to 802.11 status and reason codes, with blocklist backoff expiring lazily,
  without timers.
* Secrets from client agents, never prompted during autoconnect, and saved only after the handshake
  proves them.
* Precomputed SAE password elements cached with the profile, and the AP's Transition Disable
  indication remembered per network.
* Key installation in the order group keys, message 4, pairwise key, port open, with refusal to
  reinstall an identical group key.
* Profiles as small text files in a watched directory, written atomically, with file times as
  timestamps.
* Primitive crypto from the kernel's API instead of a library, at the cost of system-call overhead
  and kernel dependence.
* Whole-system tests on simulated air with frame rules (RSSI, drop, delay) and a reference AP.
