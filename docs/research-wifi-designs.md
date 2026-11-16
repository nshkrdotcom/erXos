# Research: how other systems structure a WiFi station

A point-in-time survey, written 2026-11-15 on the Apple Silicon macOS
development host (Darwin 27.0.0). It compares how wpa_supplicant,
OpenBSD, FreeBSD, 9front, Fuchsia, QNX, Zephyr, Android and Apple split
the work of a WiFi station, and lists which of their ideas fit erXos's
principles and which do not. It is input for the designer of
[design-wifi.md](design-wifi.md); it decides nothing.

**Clean room.** iwd (LGPL) is covered by a separate writer. No iwd, Linux
or other GPL or LGPL source or documentation was read for this record.
An `iwd` directory exists under the scratch sources from earlier work; it
was not opened. The Fuchsia files read each carry the BSD-style header
or sit under the repository's BSD-style `LICENSE`; nothing else was read
from Fuchsia.

**Method.** Every file was fetched over HTTPS from the project's own
source at a pinned release or commit into
`~/erxos-scratch/sources/wifi-survey/` (wpa_supplicant and OpenBSD's
kernel sources were reused from earlier fetches of the same pinned
releases), read as data, and nothing was built or run. Vendor
documentation pages (QNX, Android, Apple) were fetched without sign-in;
no page required one. Line numbers cite the files below. A claim no file
supports is marked **unverified**.

## Sources

**wpa_supplicant 2.12**, `https://w1.fi/releases/wpa_supplicant-2.12.tar.gz`
(`08e23937e16d0155e55cab2b51f51fbe10d80a1aa91c4e15442645059b737ef6`),
BSD-3-Clause:

| File | SHA-256 |
| --- | --- |
| `wpa_supplicant/README` | `29631e03453491eeefe2ae894b8af47d7e38e64ef3495837e7b8529c6bbf2e2f` |
| `wpa_supplicant/ChangeLog` | `057a85f39897a4ca222e4f96f0c6c03ce2240d9d1a1e5f3292f06e602d7f68f5` |
| `wpa_supplicant/wpa_supplicant.conf` | `6c808ca084ea5bf511e52c437c92670b917fc4c0a82c45e3de8d9551999fe1e8` |
| `wpa_supplicant/events.c` | `18ced492b8a1057b2ccdbf9893e5fc47e73ec161875eb4ae6bb3d5ffdc2b5596` |
| `wpa_supplicant/wpa_supplicant.c` | `38711194c4e60c05244e863cecff6acd13351a871eac46411662ef3291025364` |
| `wpa_supplicant/ctrl_iface.c` | `98e18aabf3bac9477501ddaf232b99c5bc9722c25f1ae7e8764f2191b401a4e4` |
| `wpa_supplicant/config_ssid.h` | `34b01fa370d19eba854d3a9764493fed32bd4ac6a84e548a130cf0f8b84c6ed5` |
| `wpa_supplicant/bssid_ignore.c` | `b4383848a9420d3a82cd71ffabcc8eceb52a49a3cd111c6e1fdd0000e7b30b19` |
| `src/drivers/driver.h` | `109413f73450e8d4dbe6d70a1270c29717056a014b3986d948ca41b183554cf1` |

**OpenBSD 8.0**, ISC, from `https://cdn.openbsd.org/pub/OpenBSD/8.0/`:
`sys.tar.gz` (`964b1aed7839b86f4e010a0fdd03dcd409e6f569e69fe85f95e5fceb740c2aaf`)
and `src.tar.gz` (`9984c74ff875b5ff041e4676a7f3e4e1ead2cc47a284d705eb9f37cbec4fe795`),
both matching the release's `SHA256` file.

| File | SHA-256 |
| --- | --- |
| `sys/net80211/ieee80211_node.c` | `6842049c5483eba99bf64d6f3898ec60e8c762e9906acbee556ddb5ffcb79af2` |
| `sys/net80211/ieee80211_ioctl.c` | `49600030248c0b5932311a40869f48b36744404d1af264fe510c785cad87715e` |
| `sys/net80211/ieee80211_var.h` | `9d0a7889a3e1ad9acd875abf31c2f6d4ec2bc8ef6e8326f3970f0a7a46855911` |
| `sys/net80211/ieee80211_pae_input.c` | `c5f57f3946d8fbf5c6466e77e97322e50d839a3504db7414f6dc9a0c455585ee` |
| `sys/net80211/ieee80211_proto.c` | `0a2d5e107b1a5370a705eb58f017e98fafe2e2969c4af6decdb88f171edf1458` |
| `sbin/ifconfig/ifconfig.c` | `6266edbd533c0789383678a50fa22e859693f1f64b37cb42e656e1f02c6e4e34` |
| `sbin/ifconfig/ifconfig.8` | `41646f4d70c29a0b929a085b044dbfd6d0f8ca428d617226fb077de3e2787faf` |
| `share/man/man5/hostname.if.5` | `4e79977e74906bfab300a19c78a490d2ed9040a5c5276066a108207b5e487538` |
| `etc/netstart` | `cc743d22d085c4d1a112b0c36363fa2d62618a2148cfaf2016c058fab6171bc2` |

**FreeBSD releng/15.1**, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
from `https://raw.githubusercontent.com/freebsd/freebsd-src/`, BSD:

| File | SHA-256 |
| --- | --- |
| `share/man/man4/wlan.4` | `3b05cdf47324f79904c32eac1ebc8a0b8f336bf6d69925fbebd90c78dd2c3b78` |
| `sbin/ifconfig/ifconfig.8` | `745effccdbede31d74eb7f617b92ea68439ca3e91f8d72dab402d6a594c1466e` |
| `sys/net80211/ieee80211_scan_sta.c` | `1cb1382c9098eaf3657ca94ca0e5a3212f8399a6be3be6b3fadec93ad7c9de4b` |
| `contrib/wpa/src/drivers/driver_bsd.c` | `b6cb4596cb9d36f0ce0ef820bdf99229047c5ff556ddbec3968dc751df3fd15f` |
| `libexec/rc/rc.d/wpa_supplicant` | `5c8ccf3e13ae5e0eb3feadc85f7cf1b0d0afe178f2741411a9aa73702bc2efe2` |
| `libexec/rc/network.subr` | `7071b4edc3b0ea280ee0ae4726b9fbf076341c866fc21044d1a27aa2d196a48f` |
| `sbin/devd/devd.conf` | `474249c39e6669a6a4e665aa87201f0a0256364cf34ccfaaa6c2d82ed7e8d976` |
| `share/man/man5/rc.conf.5` | `bebf785c43ef4e943b247994335766c9fbd762e1e81f99da0a4f2e11028e8044` |
| `usr.sbin/wpa/Makefile.inc` | `863ff2dbfe813239e0b2ba94dc56eb0b6ed5ee2781c0e93b66cbc48800c45df0` |
| `usr.sbin/wpa/wpa_supplicant/wpa_supplicant.conf.5` | `5ac525edd2d4d1db433211e38689beee4df0e27655bf9bdd2e45581acdd89fb8` |

**9front**, commit `303bbdba4fc9bc9dc178aa3104e6e0d162c93055` (2026-11-15),
from `https://raw.githubusercontent.com/9front/9front/`, MIT per
`lib/legal/NOTICE` (`8daa82fb04eb56344e06902609a580e8fe40cf900043945288fa58bf1ebb3e6c`):

| File | SHA-256 |
| --- | --- |
| `sys/src/9/port/wifi.c` | `ae3d5249161fdb6994ccda27fddb5cd35f6a4ef878fa015acdfd14862f40c9c9` |
| `sys/src/9/port/wifi.h` | `bf79a4bbf4c70172274f95b00247cb72df1c07f39b3438dc0b79917df5b53380` |
| `sys/src/cmd/aux/wpa.c` | `358c5c7167c7db4a1d5124bd350066837631a4864bf2c7098d449a047d82a269` |
| `sys/man/8/wpa` | `c0e171542a787d6eb19b34cf1d0298497a0854968ce8a70fa38a4a7bda5f83dd` |
| `sys/man/8/plan9.ini` | `7e54bf32d7bf9c01be497524d6637ec2933c26cd0fc65cc2b4f2846982ccd794` |

**Fuchsia**, commit `0f3b770945f24131db76f7e3920011b03efcee4e` (2026-11-15),
from `https://fuchsia.googlesource.com/fuchsia/+/<commit>/<path>?format=TEXT`,
`LICENSE` BSD-style (`83c1763356e822adde0a2cae748d938a73fdc263849ccff6b27776dff213bd32`).
Paths under `src/connectivity/wlan/` are shortened to `wlan/`:

| File | SHA-256 |
| --- | --- |
| `wlan/README.md` | `c68fffeb4c7ff3dffdd99c0d4ad210f25073bb83566dd1c84c4c2cccfcb2c930` |
| `wlan/lib/README.md` | `31453c94d1f46a6e13bcc7d73bc4bea2814319d78885e5aed67dbabb69dd99a2` |
| `wlan/lib/mlme/README.md` | `25aaf57d13eb6fb1a2beea70f8f3079a94eafd3a88da6e73d9e8256ca7b7ca4e` |
| `wlan/FIDL.md` | `9c5bfeab9b7516e7a23976cb43750748f357ae22052c138b78ec72c1d66e38a5` |
| `wlan/tests/README.md` | `239848089afa4f210f04a72898fc7d09b7a77910d51dc496e752d82c6919f00c` |
| `sdk/fidl/fuchsia.wlan.policy/client_provider.fidl` | `2b8b81c4796c915f8904a9b32eec8084f711f0dcc823c30a8aec04e5b1e82cb5` |
| `sdk/fidl/fuchsia.wlan.policy/types.fidl` | `3450c037663dfee54ea955845b5cefbda8706b7a8767d81c42ed7c9375cb84ba` |
| `wlan/wlancfg/src/client/state_machine.rs` | `240093fd1ab1005ec18c7583aabc72ccc2cd364fc7103cfe33ed3b55147c74c6` |
| `wlan/wlancfg/src/client/connection_selection/network_selection.rs` | `ccbefe86b675b890d6b333352948aa72967d8821eecc0914134ac8896eba04b8` |
| `wlan/wlancfg/src/client/connection_selection/scoring_functions.rs` | `49230be7b1a7d033f44f9971194504508688165af8a172b5bca6be1a1c56bb14` |
| `wlan/wlancfg/src/client/roaming/lib.rs` | `727d20e6392bde70b7644a0e7f91d10fea6fa28d7a519567d0bf082389ca75c2` |
| `wlan/wlancfg/src/client/roaming/roam_monitor/stationary_monitor.rs` | `4388af71f53a7d68f5ea2c2b2a85640876a519affe32cd14ee6be2d45c4304cd` |
| `wlan/wlancfg/src/config_management/config_manager.rs` | `cf0315275a53ba2dec364db88b13e0effcb39ecf04edb83f7ef57e0e81226b25` |
| `wlan/wlancfg/src/config_management/network_config.rs` | `9d1757e2a2f5a07031aab09a49700058033830f135687b7e09996ea1491ef921` |
| `wlan/lib/storage/src/storage_store.rs` | `02da73ae978cb8dce120fa5986f771ca5c45bd4eff29b1a58df79635d34950ec` |
| `wlan/lib/sme/src/client/state/mod.rs` | `3c46ff9e81af2c66f540d91a790b45ce3c09671a69d2f01d42bce15b3ee493c6` |
| `wlan/lib/mlme/fullmac/src/mlme_main_loop.rs` | `56dd3f09a8998f6b483f5666d3b0b3cddd5f273d187da6afd53e030561d231c1` |

**QNX documentation**, `https://www.qnx.com/developers/docs/` (and the
`qnx.com` and `get.qnx.com` hosts of the same site), no sign-in:

| Page | SHA-256 of the HTML fetched |
| --- | --- |
| `8.0/com.qnx.doc.neutrino.io_sock/topic/overview_WiFi.html` | `8416288f49bc16aca0ee3d7443033258bbba28f2f8846ea001438baa790cd884` |
| `8.0/com.qnx.doc.neutrino.utilities/topic/d/devs-qwdi_syn_dhd_pcie.so.html` | `c9d224fea4949270567f4ae04cb8bcd95d85cb6552760f2760f2fb8ed4973dd8` |
| `8.0/com.qnx.doc.wpactrl/topic/about_wpa__ctrl_8h.html` | `8425e8e009c141da8cd1d33472a49ea5f65dbd4e31f413388ca49560882d4433` |
| `7.1/com.qnx.doc.qwf.overview/topic/arch.html` | `761209046718820fb6d62adafc84cbbff7a7e5f4456326f18422412e58124f08` |
| `7.0.0/com.qnx.doc.qwf.system_services/topic/wpa_supplicant.html` | `cd87636b3e9951c673d43f270904d50c901f2f1094b032727b67ad99043ed68f` |
| `7.0.0/com.qnx.doc.qwf.system_services/topic/wpa_pps.html` | `ed89a44daec66abda87c686e58b100365c633aed107f73444c6b8a97ddb6469a` |
| `6.6.0.update/com.qnx.doc.car.ppsref/topic/serviceswificontrol.html` | `ca5cdb55aced6c955e368bd9fe026a7189514f7378c834b468e05b89ea7221a8` |

**Zephyr v4.5.0**, `https://raw.githubusercontent.com/zephyrproject-rtos/zephyr/v4.5.0/`,
Apache-2.0: `include/zephyr/net/wifi_mgmt.h`
(`90dbc6e9e322e347d021d45ad00de6efeefe5def2c62b013ef47b4989e15e72f`),
`include/zephyr/net/wifi_credentials.h`
(`64bc4883e2f24411015f9699029d968bc50c6e8ea8cdc9ef141f292d128425ae`),
`subsys/net/lib/wifi_credentials/wifi_credentials.c`
(`b14b613bc69dd333cef950faf728d19552eb6df36cdfd8f7e45600605151d3d2`).
The WiFi `.rst` guides were not at their old paths in v4.5.0 and were
not read.

**Android and Apple documentation**:
`https://source.android.com/docs/core/connect/wifi-overview`
(`d31d12d4c965a10674cef488ff737507ff1f361503c803704ed11742162b34f8`),
`https://source.android.com/docs/core/connect/wifi-network-selection`
(`e11e268f16c7ab7c6980a83a1e61c6084969b05b5b1782edb39b62a407a8489d`),
`https://support.apple.com/en-us/102169`, published 2026-06-12
(`50688905de6efedcfecc1410dba94e981f4c02e3aff79a6c61bca2ba06c07808`).

## What erXos has today

[design-wifi.md](design-wifi.md) puts the whole WiFi conversation in one
domain, `wifi`, which reaches the CYW43455 through the storage domain's
`sdio` facet and lends the network domain an Ethernet medium whose link
is up exactly while the station's port is open
([The construction](design-wifi.md#the-construction)). Three processes
run under a supervisor that restarts nothing, so any fault restarts the
domain and reloads the firmware
([The WiFi domain](design-wifi.md#the-wifi-domain)). The station is one
pure `step(State, Event) -> {Actions, State}` with seven states and
closed event and action sets; the supplicant's cores are pure functions
it calls ([The station](design-wifi.md#the-station),
[The supplicant](design-wifi.md#the-supplicant)). Network choice is a
pure function of configuration, credential store and scan, never of an
earlier failure, so a failed SAE never falls back to PSK; ties break by
`priority`, then signal. Configuration is a subset of
`wpa_supplicant.conf` with no secret in it; secrets are given through a
`ctl` file, kept as PMK and PT (never the passphrase) in one blob behind
the vault's state slot, and read whole by the WiFi domain
([Configuration, credentials and control](design-wifi.md#configuration-credentials-and-control)).
Roaming, PMKSA caching, 802.1X and host-AP mode are out of scope
([Requirements](design-wifi.md#requirements)).

## wpa_supplicant 2.12

**Authority split.** One daemon per interface (or one with a global
socket) holds the configuration, the passphrases, every key and the
whole state machine, and talks to the driver through a driver wrapper
(`nl80211`, `bsd`, `wired` and others). The optional privilege
separation build moves only the driver wrapper and the packet socket
into a root `wpa_priv` process and runs the rest, EAP and the
handshakes included, unprivileged (`README:916-945`). Keys go to the
driver through `set_key`; the daemon keeps them too.

**Control surface.** A text protocol over a UNIX datagram socket per
interface, access controlled by the socket directory's group
(FreeBSD's default `ctrl_interface_group=wheel`,
`wpa_supplicant.conf.5:472-473` in FreeBSD's tree). `ctrl_iface.c` is
15,414 lines and compares the request against 321 command strings; 58
`CTRL-EVENT-*`/`WPA_EVENT_*` names are defined for unsolicited events.
Network blocks are edited live with `SET_NETWORK`; `GET_NETWORK` never
returns keys (`ctrl_iface.c:3812`, `wpa_config_get_no_key`). When a
secret is missing it asks attached front ends with
`CTRL-REQ-<type>-<id>:<text>` and takes the answer by a matching
command (`README:719-745`).

**Driver abstraction and events.** `struct wpa_driver_ops`
(`driver.h:3543`) has 193 function pointers and `enum wpa_event_type`
(`driver.h:5977`) 82 events; the driver calls one
`wpa_supplicant_event` that dispatches them. `events.c`,
`wpa_supplicant.c` and `ctrl_iface.c` carry 178, 217 and 215
`#ifdef CONFIG_*` blocks: one program serves every feature combination.

**State machine and selection.** Network blocks are grouped by
`priority`; `wpa_supplicant_pick_network` walks the groups from the
highest and takes the first scan result (results are already sorted)
that `wpa_scan_res_match` accepts (`events.c:1798-1850`). The acceptance
test, `wpa_scan_res_ok`, is about 360 lines of checks
(`events.c:1283-1640`). Roaming within an ESS compares the current and
best BSS by a table of signal differences adjusted by estimated
throughput, band and SNR (`events.c:2186-2375`).

**Secrets.** Passphrases or PSKs sit in the configuration file, which
the daemon rewrites when `update_config=1`; `mem_only_psk=1` keeps a
network's PSK out of the file (`config_ssid.h:289-292`), and
`ext_password_backend` reads secrets from a separate store, a file or a
test backend (`wpa_supplicant.conf:370-379`). The PSK from a passphrase
is computed in the daemon.

**Failure recovery.** A failing BSSID goes on an ignore list for 10 s,
then 60, 120, 600 and 1,800 s as its count grows
(`bssid_ignore.c:78-99`); the list is cleared when nothing else matches
(`events.c:1834-1845`). A network whose authentication fails is
disabled for 10 s rising to 300 s after 50 failures
(`wpa_supplicant.c:9597-9625`). The AP may also send a Transition
Disable indication that permanently removes WPA2-PSK, non-PMF or open
fallbacks from the profile (`config_ssid.h:1243-1261`).

**Testing.** Module tests ship in the tarball
(`wpas_module_tests.c`, `common_module_tests.c`, `crypto_module_tests.c`);
the larger simulated-radio test suite lives in the project's git
repository, not the release, and was not read (**unverified**).

**Weaknesses reported in its own ChangeLog.** Key reinstallation (KRACK,
CVE-2017-13077 to -13088, `ChangeLog:238-241`), SAE side channels and
SAE confirm bypass (CVE-2019-9494, -9495, -9499, `ChangeLog:184-191`),
and further side-channel hardening in 2.9 and later (`ChangeLog:87-147`).
These are the bugs design-wifi's key-slot rule and constant-time SAE
NIF already target. Its size (533,583 lines of C in the tarball, shared
with hostapd) and the `#ifdef` matrix are why
[design-wifi.md](design-wifi.md#alternatives-considered) does not adopt
it as C.

## OpenBSD 8.0: WPA in the kernel and the join list

**Authority split.** net80211 in the kernel does scanning, selection,
association, the 4-way and group handshakes for PSK
(`ieee80211_pae_input.c`) and roaming. There is no supplicant for PSK.
`ifconfig` turns a passphrase into the PMK with PBKDF2 in user mode
(`ifconfig.c:2277`) and hands the 32-byte PMK to the kernel; for 802.1X
a user-mode supplicant from ports hands the PMK over with the root-only
`SIOCS80211KEYAVAIL` (`ieee80211_ioctl.c:666-672`). FullMAC chips such
as `bwfm` run with their firmware supplicant off, and net80211 does the
handshakes for them. SAE appears only as an AKM bit parsed from the RSN
element and reported (`ieee80211_input.c:1475`, `ieee80211_node.c:307`);
no SAE exchange was found in net80211, so OpenBSD's station does not do
WPA3-Personal on SoftMAC chips.

**Control surface.** `ifconfig` alone. `join ID [wpakey K]` adds a
network with its PMK to the kernel's join list; `-join ID` removes it
and disconnects; `joinlist` and `-joinlist` show and clear it
(`ifconfig.8:1015-1087`). `nwid ID` overrides the list for one network.
Persistence is `/etc/hostname.if`, a list of `ifconfig` argument lines
run at boot, typically `join mynwid wpakey mywpakey` followed by
`inet autoconf` (`hostname.if.5:76-82`); `netstart` resets the file to
root-only if anyone else can read it (`netstart:167-172`).

**Selection.** The join list is an unordered set of up to
`IEEE80211_CACHE_SIZE` entries (`ieee80211_node.c:376-400`), each with
SSID, flags and PMK (`ieee80211_var.h:410-430`). After a scan,
`ieee80211_switch_ess` compares every BSS that matches an entry
(`ieee80211_node.c:596-665`) with one fixed score: +32 for an explicit
entry over "join any", +16 RSN, +8 WPA, +4 privacy, +2 for 5 GHz above
a threshold, +1 each for HT and VHT, +21 if the AP never failed, and +1
to the stronger signal after a 2.4 GHz penalty
(`ieee80211_node.c:448-551`). There is no user priority. An empty `join`
ID joins any open network when nothing on the list is found
(`ifconfig.8:1031-1037`).

**Secrets.** The PMK lives in the kernel's join list; reading it back
returns a flag with the key zeroed (`ieee80211_ioctl.c:656-665`). The
passphrase lives in `/etc/hostname.if` in clear, protected by file mode.

**Roaming.** In the kernel: a background scan starts when the current
AP's signal falls under a band-specific threshold
(`ieee80211_node.c:1779-1800`); if the scan picks the same AP or one
that is no better, the interval doubles up to a cap
(`ieee80211_node.c:1585-1605`); otherwise the driver flushes its queues
and the node switches (`ieee80211_node.c:1612-1640`).

**Failure recovery.** Per-AP failure counts: a node that has failed is
skipped and freed after three more scans so it can be retried from a
fresh beacon (`ieee80211_node.c:1431-1438`); the score's +21 favours
APs with no failures.

**Testing and weaknesses.** No test harness was found in the files read
(**unverified** whether one exists). The model is simple and widely
praised, but WPA3-SAE, PMF negotiation for a block and 802.1X depend on
code outside it, the join list has no user ordering, and the secret
lives in a text file.

## FreeBSD 15.1: net80211, wlan cloning and wpa_supplicant

**Authority split.** The driver attaches a parent device; a `wlan(4)`
virtual interface is cloned from it with `ifconfig wlan0 create wlandev
X` or `wlans_X="wlan0"` in `rc.conf`, and one device can carry several
(`wlan.4:57-70`; `rc.conf.5:1730-1731`). net80211 in the kernel holds
scanning, the MLME and the data path; "WPA, 802.11i, and 802.1x ... are
supported through a combination of in-kernel code and user-mode
applications" (`wlan.4:48-49`). wpa_supplicant is that user-mode part,
holding the secrets and the handshakes.

**Control surface and plumbing.** `devd` runs `pccard_ether ...
startchildren` when a WiFi device attaches (`devd.conf:50-57`), which
creates the `wlan` children; `ifconfig_wlan0="WPA DHCP"` makes
`network.subr` start `/etc/rc.d/wpa_supplicant start wlan0`
(`network.subr:219-220`), which runs `wpa_supplicant -B -i wlan0 -c
/etc/wpa_supplicant.conf -D bsd` (`rc.d/wpa_supplicant:30-31`). The
`bsd` driver wrapper talks to net80211 with `SIOCS80211`-family ioctls
(`IEEE80211_IOC_MLME`, `_WPAKEY`, `_APPIE`, `_SCAN_REQ`) and reads
events (`RTM_IEEE80211_ASSOC`, `_DISASSOC`, `_SCAN`, `_JOIN`, `_REPLAY`,
`_MICHAEL`) from a routing socket (`driver_bsd.c:821-860, 1808-1830`).

**Selection and roaming.** Two owners. With `roaming auto`, net80211
chooses: `sta_compare` prefers privacy, then fewer recent failures, then
signal, with rate and 5 GHz deciding when signals are within 5 dB
(`ieee80211_scan_sta.c:868-912`), and `sta_roam_check` switches when the
signal or rate falls under per-mode thresholds
(`ieee80211_scan_sta.c:1341-1418`). wpa_supplicant sets
`roaming manual` at start (`driver_bsd.c:1409-1412`) and restores the old
mode on exit (`driver_bsd.c:1757`), so with a supplicant all selection
is wpa_supplicant's. `ifconfig.8:2030-2048` documents the three modes.

**Secrets.** In `/etc/wpa_supplicant.conf`, as wpa_supplicant keeps
them.

**Feature set as built.** FreeBSD's base wpa_supplicant is built with
`CONFIG_IEEE80211W`, `_IEEE80211R`, `_WNM`, `_MBO`, `_PASN`,
`_PRIVSEP`, WPS, Hotspot 2.0 and EAP methods (`Makefile.inc:32-92`), but
no `CONFIG_SAE` appears in `Makefile.inc` or the program's `Makefile`:
the base system's supplicant does not do WPA3-SAE in this release.

**Testing.** `wtap(4)`, a simulated radio, which
[design-wifi.md](design-wifi.md#verification) already uses for its
differential test against wpa_supplicant and hostapd.

**Weaknesses.** Two places choose a BSS, switched by a mode the
supplicant must set and restore; a supplicant that dies leaves
`roaming manual` set. The route from device attach to a running
supplicant crosses `devd`, `pccard_ether`, `network.subr` and an rc
script.

## 9front: a file-configured layer and factotum

**Authority split.** A small kernel layer, `wifi.c` (1,759 lines), sits
under SoftMAC drivers: it keeps a table of 32 nodes from beacons
(`wifi.h`), authenticates and associates, and encrypts and decrypts
CCMP and TKIP in software. The handshake runs in a user program,
`aux/wpa` (1,515 lines), which opens the interface's EAPOL connection
(`dev!0x888e`, `wpa.c:1199`), writes the RSN element to the interface's
`ctl` as `auth HEX` (`wpa.c:1231`) and installs keys by writing
`rxkey`/`txkey` lines (`wifi.c:1074-1086`). Until a transmit key is
installed the node's status is `blocked` and only EAPOL frames pass
(`wifi.c:35, 730-745`): the port is a state of the layer.

**Who holds the secret.** `factotum`, Plan 9's authentication agent.
`aux/wpa` never holds the passphrase or the PMK: it starts a
`proto=wpapsk role=client essid=...` conversation on
`/mnt/factotum/rpc`, writes the two addresses and two nonces, and reads
back the PTK (`wpa.c:474-520`). With `-p` it prompts once and stores the
key in factotum (`wpa.c:442-470`, `wpa(8)`); otherwise factotum's own
key prompter asks the user when the key is missing.

**Control surface.** Files. `essid NAME` and `bssid ADDR` go to the
interface's `ctl` or `clone` file, or `essid=` to `plan9.ini` at boot
(`plan9.ini(8)`, the `iwl` entry; `wificfg`, `wifi.c:944-960`). The
`ifstats` file shows the joined BSS, status, channel, key ciphers and
lengths but never key bytes (`wifi.c:1094-1140`), then one line per node
seen: the scan result is a file.

**Selection, roaming, recovery.** One ESSID; the first node that
matches it, or the configured BSSID, is tried (`goodbss`,
`wifi.c:604-616`). No ranking, roaming or backoff beyond the layer's
watchdog. The whole design is 3,384 lines across the two components.

**Weaknesses.** No WPA3, no PMF, no priority among networks; software
crypto only fits SoftMAC chips. Its value for erXos is the shape, not the
feature set.

## Fuchsia: policy, SME and MLME

**Authority split.** Four layers in separate components talking FIDL
(`wlan/README.md`): a **policy** component, `wlancfg`, owns saved
networks, auto-connect, network and BSS selection and roaming decisions;
a **device monitor** discovers PHYs, creates interfaces and hands the
policy component SME channels; the **SME** (station management entity)
runs connection states, scanning, security handshakes (`lib/rsn`) and
SAE and OWE (`lib/fcg-crypto`, over BoringSSL); the **MLME** is either
host state machines for SoftMAC or a translation layer for FullMAC that
turns SME's MLME requests into vendor driver calls and driver events
into MLME indications (`wlan/lib/mlme/README.md`;
`mlme_main_loop.rs:125-126`). The policy component holds the stored
credentials and passes them to the SME per connection.

**Control surface.** `fuchsia.wlan.policy.ClientProvider`: one
controller at a time ("eliminate the 'last-caller wins' paradigm"; a
second registrant's channel is closed), any number of read-only
listeners (`client_provider.fidl:9-38`). The controller starts and stops
client mode, scans (results through an iterator), saves, forgets and
lists networks, and asks to connect to a saved network, falling back to
automatic selection if that fails (`client_provider.fidl:46-125`).
`FIDL.md:8-41` sorts every protocol by layer boundary and stability, and
`FIDL.md:44-48` asks for typed results wherever an error changes control
flow.

**State machines.** The SME's client states are declared with a
`statemachine!` macro that lists every legal transition, `Idle =>
Connecting`, `Connecting => [Associated, Disconnecting, Idle]` and so on
(`state/mod.rs:138-150`); a transition not listed does not compile. The
policy client state machine is a set of async functions per state
(`state_machine.rs:303, 432, 679`), not a pure step.

**Selection.** A network is identified by (SSID, security type)
(`types.fidl:31-40`); the credential is a passphrase, a PSK or none
(`types.fidl:51-61`). A saved network may be used on a BSS of the same
or a higher security, never a lower one: a WPA2 entry may join WPA3, a
WPA3 entry never joins WPA2 (`config_manager.rs:54-61, 561-582`).
Network-level selection is currently "all available" with a TODO
(`network_selection.rs:10-23`); BSS scoring is a pure function of the
candidate: signal (tapered above -30 dBm), a 5 GHz bonus, minus 5 per
recent failure on that BSSID (10 beyond five), 30 for a recent
credential rejection and 20 per recent short connection
(`scoring_functions.rs:13-69`). Each saved network keeps up to 10 results
per BSS and 120 past connections, and a probability that it is hidden
(`network_config.rs:24-58`).

**Roaming.** A roam monitor, separate from the SME, smooths signal with
an exponential average and asks for a roam scan when it falls under -72
dBm (2.4 GHz) or -75 dBm (5 GHz), roams only for 3 dB or more, backs off
between roam scans and allows at most five roams a day
(`stationary_monitor.rs:22-38`; `roaming/lib.rs:16-21`); the SME has a
`Roaming` state for the execution (`state/mod.rs:119, 146`).

**Secrets.** Saved networks, credentials included, are one JSON file in
the policy component's own storage, replaced by write, `fsync` and
rename (`storage_store.rs`, `StorageStore::write`). Whether the storage
is encrypted at rest was not checked (**unverified**); isolation comes
from per-component storage capabilities.

**Testing.** Host and sandboxed unit tests of the algorithms, parsers,
handshakes and state machines; end-to-end tests on a hardware testbed
against an OpenWrt access point the test drives over SSH
(`tests/README.md`); a simulated PHY protocol, `fuchsia.wlan.tap`,
exists in the SDK (its use was not read).

**Weaknesses.** About 28,000 lines in the 23 files read alone, and four
components with versioned and unversioned protocols between them; the
network-selection step is still a stub. The layering is the reusable
part.

## QNX

**Authority split.** QNX does not write its own supplicant: it ships
wpa_supplicant (2.9 for the control library in SDP 8.0,
`about_wpa__ctrl_8h.html`) and hostapd. Drivers run inside the network
manager: SDP 8.0's `io-sock` "supports native FreeBSD WiFi drivers" and
a Synaptics DHD (FullMAC) driver started as `io-sock -m pci -d
qwdi_syn_dhd_pcie` (`overview_WiFi.html`,
`devs-qwdi_syn_dhd_pcie.so.html`). QWDI is QNX's driver interface
towards wpa_supplicant; the driver's version names the supplicant
version it serves, and firmware, NVRAM and CLM files are driver options
read from `/etc/qwdi_wifi.conf` (`devs-qwdi_syn_dhd_pcie.so.html`).

**Control surface.** On top of wpa_supplicant, a policy service,
`wpa_pps`, talks to the supplicant's control socket and publishes state
in PPS (persistent publish/subscribe) objects, file-like objects under
`/pps` (`wpa_pps.html`; `qwf/arch.html`). The older documented form is
a server object `/pps/services/wifi/control`: a client writes
`msg::cmd`, `id::N`, `dat:json:{...}` and reads `res::cmd`, `id::N`,
`dat`, `err`; commands include `scan`, `scan_results`, `wnet_new`,
`wnet_update`, `wnet_select`, `wnet_enable`, `wnet_disable`,
`wnet_delete` and `wifi_power`, and status appears in
`/pps/services/wifi/status` (`serviceswificontrol.html`). Password,
PSK and WEP key attributes read back as null and are changed by writing
`new<attr>` (`serviceswificontrol.html`). Later releases hide the
objects behind a C library (`wpa_pps.html`).

**Selection and secrets.** Profiles with `_enable` and `priority` in a
JSON file, `/etc/wpa_pps.conf`; the sample stores `"psk":"abcdabcd"` in
clear (`wpa_pps.html`). Selection itself is wpa_supplicant's.

**Recovery.** `wpa_supplicant` must start after the driver and before
`wpa_pps`, which waits for its socket (`waitfor
/var/run/wpa_supplicant_global 5`, `wpa_supplicant.html` 7.0.0);
`wpa_pps -a` leaves connections up when it exits (`wpa_pps.html`). No
restart policy is described.

**Weaknesses.** Three stacked owners of the same state (supplicant,
policy service, client library) and secrets in clear in two files.

## Zephyr, Android and Apple, briefly

**Zephyr** exposes WiFi as network-management requests, 75
`NET_REQUEST_WIFI_CMD_*` values (`wifi_mgmt.h`), served by a driver's
`struct wifi_mgmt_ops` of 40 operations (`wifi_mgmt.h:2021`) or by its
wpa_supplicant port. A credentials library keeps networks with their
passwords behind a pluggable backend (`none`, `psa` protected storage,
`settings`, per the file names in `subsys/net/lib/wifi_credentials/`),
and `NET_REQUEST_WIFI_CONNECT_STORED` joins from it
(`wifi_mgmt.h:138-140, 342-345`).

**Android** runs the WiFi services in the system server, talks to the
supplicant, hostapd and vendor HALs over AIDL, and gives `nl80211` to a
separate process, `wificond` (`wifi-overview`). Selection
(`wifi-network-selection`) first asks whether the current network is
sufficient (selected less than 10 s ago, chosen by the user, or strong,
validated and unmetered) and only then scans; candidates are filtered
by signal and a BSSID blocklist whose duration grows exponentially per
failure type; nominators propose saved and app-suggested networks, and
one scorer ranks them by signal, estimated throughput and bonuses; a
wrong password disables the network until the user selects it again,
while a DHCP failure disables it for 5 minutes after five failures.
Disconnected scans back off over 20, 40, 80 and 160 s, and with the
screen off the firmware scans for preferred networks itself.

**Apple** ranks known networks by most preferred, private before
public, then configuration method (managed before manual), Wi-Fi
standard, band, security and signal last; an open network not joined by
hand in two weeks is never auto-joined, and after a restart credentials
are available only after the device is unlocked (`102169`).

## Comparison

| | Keys and handshake | Talks to the chip | Policy (selection) | Control surface | Secrets at rest | Roaming | Recovery from failures |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **erXos** (design) | Erlang station in the WiFi domain | chip process in the same domain, over `sdio` | pure function: block, store, scan; `priority` then signal | `ctl` file, `/proc`, `wpa_supplicant.conf` subset | PMK and PT in vault slot, read whole by the domain | out of scope | restart the domain; rescan 1 s doubling to 60 s |
| **wpa_supplicant** | daemon (C) | its driver wrapper, optionally `wpa_priv` | priority groups, first match in sorted results | text socket, 321 commands, events | config file, or external backend | in daemon, signal-difference table | BSSID ignore list 10-1,800 s; SSID disable 10-300 s |
| **OpenBSD** | kernel (PSK); user mode only for 802.1X | kernel | kernel, fixed score, no priority | `ifconfig join` | passphrase in `hostname.if`; PMK in kernel | kernel bgscan, interval doubling | per-AP fail count, retry after 3 scans |
| **FreeBSD** | wpa_supplicant | kernel net80211 | kernel (`auto`) or supplicant (`manual`) | `ifconfig`, wpa_cli | `wpa_supplicant.conf` | kernel or supplicant | per-entry fails in kernel; supplicant's lists |
| **9front** | `aux/wpa` user program; PTK from factotum | kernel `wifi.c` | first node matching one ESSID | `ctl`/`clone`/`ifstats` files, `plan9.ini` | factotum (agent) | none | watchdog only |
| **Fuchsia** | SME component (Rust) | MLME / FullMAC translation component | policy component, pure BSS score with failure penalties | FIDL, one controller, many listeners | JSON in policy's storage | policy decides, SME executes; 5 roams a day | per-BSS penalties; credential-rejected penalty |
| **QNX** | wpa_supplicant | driver inside `io-sock` | wpa_supplicant, profiles from `wpa_pps` | PPS objects, later a C library | JSON and conf in clear | wpa_supplicant | not described |
| **Android** | supplicant HAL | `wificond` (`nl80211`), vendor HAL | system server: sufficiency, nominators, one scorer | Binder APIs | not read | firmware when screen off; framework otherwise | BSSID blocklist, SSID disable by failure type |

## Ideas that fit erXos's principles

Each idea names where it would land in [design-wifi.md](design-wifi.md)
and what it costs. None is decided here.

1. **Keep the long-term secret out of the domain that parses the air,
   as factotum does.** 9front's supplicant never sees the PMK: it sends
   the two addresses and two nonces to an agent and gets the PTK back
   (`wpa.c:474-520`). In erXos the WiFi domain decodes every network's
   PMK and PT from the store and keeps them
   ([Credentials](design-wifi.md#credentials)), so a radio attacker who
   breaks the parser of the domain the design calls "hostile parsing has
   one home" takes every saved network's password equivalent. With an
   agent, the same break yields only the session keys of the network in
   use. For PSK the agent's operation is one KDF; for SAE it is the
   commit and confirm arithmetic, which the design already isolates in
   three `crypto` functions ([OTP's crypto](design-wifi.md#otps-crypto-saes-arithmetic)),
   so the agent's interface would be those steps keyed by SSID. The
   design rejected a WiFi purpose of the vault because "SAE needs PT in
   the WiFi domain for every exchange"
   ([Alternatives considered](design-wifi.md#alternatives-considered));
   factotum's shape answers that by moving the exchange's secret steps,
   not handing out PT. The cost is real: a WiFi-specific purpose in the
   vault (or a small key domain) that knows two KDFs and the SAE steps,
   against the vault's rule of parsing nothing. Worth a design question;
   it is the one idea here that changes a security property.

2. **Remember failures per BSSID, never per security choice.** Every
   system surveyed keeps failure memory: wpa_supplicant's escalating
   ignore list (`bssid_ignore.c:78-99`), FreeBSD's `se_fails`
   (`ieee80211_scan_sta.c:1475-1490`), OpenBSD's `ni_fails`
   (`ieee80211_node.c:1431-1438`), Fuchsia's score penalties
   (`scoring_functions.rs:24-28`), Android's blocklist. erXos's choice
   is "never of an earlier failure", which rightly forbids SAE-to-PSK
   fallback but also means a broken AP of an SSID with two APs is chosen
   again after every backoff. A record that can only lower a BSS's rank
   among BSSs already admitted for the same block and AKM keeps the
   downgrade property by construction (the AKM table runs first and
   never reads the record) and fixes the loop. It belongs in
   [The station](design-wifi.md#the-station), as one more input to the
   pure choice, bounded and expiring.

3. **Stop retrying a rejected secret.** Android disables a network after
   one wrong password until the user acts; Fuchsia penalises a
   credential rejection by 30; wpa_supplicant disables the SSID for an
   escalating time (`wpa_supplicant.c:9597-9625`). erXos rescans with
   backoff to 60 s and rejoins forever, so a changed passphrase means a
   handshake attempt per minute, each giving an attacker-in-the-middle
   a fresh message 2 to test guesses against. A reason
   `secret_rejected` at `/proc` that parks the SSID until `secret` or
   `reconfigure` is one state and one counter. Detecting rejection on
   PSK is indirect (no message 3, or deauthentication after message 2),
   so the rule should be "N consecutive handshake failures on every BSS
   of the SSID", with N measured on the board.

4. **Pin the security level up, never down.** Fuchsia lets a saved WPA2
   network join a WPA3 BSS but never the reverse
   (`config_manager.rs:561-582`), and wpa_supplicant honours the AP's
   Transition Disable indication, which removes WPA2-PSK from the
   profile for good (`config_ssid.h:1243-1261`). erXos already refuses a
   downgrade within a block that allows SAE alone; a block that allows
   both pays the offline-guess exposure the design names. Honouring
   Transition Disable (bit 0) by recording "SAE only" for the SSID in
   the credential blob would close that exposure for networks that ask,
   with no new mechanism beyond one flag in the blob the station already
   writes.

5. **Split the pure core into a policy function and a protocol
   machine, as Fuchsia splits policy from SME.** erXos's one
   `erx_wifi_sta` step both chooses networks and runs SAE and the 4-way
   handshake. Two pure parts in the same process, `choose(Config, Store,
   Scan, History) -> Candidate | {refused, Reasons}` and the protocol
   `step`, keep the exhaustive state-machine test to the protocol's
   states and make choice a table test. Roaming, when it comes, is a
   third pure part that only emits a `roam` event, as Fuchsia's roam
   monitor is separate from the SME's `Roaming` state
   (`stationary_monitor.rs`; `state/mod.rs:146`). No new process, no new
   interface.

6. **Declare the legal transitions as data.** Fuchsia's
   `statemachine!` lists every edge and refuses an unlisted one at build
   time (`state/mod.rs:138-150`). erXos could state the station's
   transitions as rows (in `abi/formats/ieee80211.txt`, which already
   holds the AKM table) and have the generator emit the dispatch and the
   exhaustive test's edge list, per principle 4 and "One source for
   every fact"; the design's prose rule "an event acts only where it
   applies" becomes a checked table.

7. **Name the chip actions after the 802.11 MLME primitives.** Fuchsia's
   FullMAC layer is a translation from standard MLME requests and
   indications to vendor calls (`wlan/lib/mlme/README.md`). erXos's
   closed action and event sets are already close; naming them as
   scan, join (connect), set-keys, delete-keys, EAPOL send and their
   confirms and indications, with no `bwfm` term above the chip process,
   makes the chip process the only thing a second chip or a SoftMAC
   MLME replaces. That is the "seams, not rewrites" rule at no cost
   today; wpa_supplicant's 193-operation driver table shows what happens
   when the seam is drawn around every driver feature instead.

8. **Show why a candidate was refused, so a front end can ask.**
   wpa_supplicant asks for a missing secret with `CTRL-REQ-*`
   (`README:719-745`) and factotum's prompter asks for a missing key.
   erXos needs no prompt protocol: if `/proc` lists, per SSID seen, the
   refusal reason (`no_secret`, `akm_unsupported`, `pmf_required`), a
   desktop or shell can offer `secret ssid=...` itself. The design
   counts refusals by reason; this is the same data keyed by SSID.

9. **Check "is the current link sufficient" before scanning.** Android
   skips selection while the link is recent, user-chosen or strong
   (`wifi-network-selection`); OpenBSD's background scan backs off when
   it finds nothing better (`ieee80211_node.c:1585-1605`). When roaming
   is designed, a sufficiency predicate in front of the roam scan keeps
   scans (which interrupt traffic on a single-radio chip) rare.

10. **Scripted access point for board tests.** Fuchsia's end-to-end tests
    drive an OpenWrt AP over SSH (`tests/README.md`). erXos tests the
    board by hand ([Verification](design-wifi.md#verification)); a
    host-scripted hostapd AP (on any spare machine with a radio) that
    switches between open, WPA2, WPA3 and transition configurations
    would make W3 to W5 repeatable at the cost of one test peer, as the
    Bluetooth design uses a scripted peer.

11. **Confirmations that the design already matches the best practice.**
    The port as a layer state that passes only EAPOL (9front `blocked`,
    `wifi.c:730-745`; erXos "the port is the link"); write-only secrets
    that read back masked (QNX's null attributes, wpa_supplicant's
    `wpa_config_get_no_key`, OpenBSD's zeroed PSK, erXos's `secret` and
    `/proc`); one controller, many readers (Fuchsia's ClientProvider,
    erXos's root-only `ctl` and `/proc`); privilege separation (the
    `wpa_priv` split is erXos's domain boundary, done by the kernel
    rather than by convention); no WPA3 or PMF in OpenBSD's or FreeBSD's
    base station, which the design's W5 goes beyond.

## Ideas that do not fit, and why

1. **The kernel holds the join list and runs the handshake (OpenBSD).**
   erXos's kernel holds no protocol; the equivalent "one owner" already
   exists as the WiFi domain. OpenBSD's persistence model, a text file
   of commands with the passphrase in it (`hostname.if.5:76`), is what
   erXos's vault rule forbids.

2. **`join` and `-join` as the configuration interface (OpenBSD).**
   Attractive and simple, but erXos follows FreeBSD where UNIX systems
   differ, and FreeBSD's persistent form is `wpa_supplicant.conf`. A
   `join` verb that also edited network blocks would make two sources
   for one fact. If wanted, `ifconfig wlan0 ssid NAME` (FreeBSD's verb,
   already in the design) is the one-shot override, like OpenBSD's
   `nwid`.

3. **A fixed score with no user priority (OpenBSD).** It ignores
   `priority`, which FreeBSD's `wpa_supplicant.conf` users rely on, and
   its weights (+21 for no failures beside +16 for RSN,
   `ieee80211_node.c:471-511`) mix security and failure history in one
   number, which is exactly the coupling idea 2 keeps apart.

4. **"Join any" open network (OpenBSD's empty `join` ID,
   `ifconfig.8:1031-1037`).** Auto-joining unknown open networks hands
   traffic to whoever advertises one; Apple refuses even known open
   networks not joined by hand within two weeks (`102169`). erXos joins
   an open network only by a block or by `ssid NAME`.

5. **Two owners of selection switched by a mode (FreeBSD's `roaming
   auto|manual`, `driver_bsd.c:1409-1412, 1757`).** A mode that one
   process must set and restore is an obligation every exit path must
   remember; erXos has one owner by placement. The FullMAC firmware's own
   roaming, when roaming is designed, should be either off or the only
   owner, not a mode.

6. **A generic driver abstraction now (wpa_supplicant's 193 operations,
   Zephyr's 40, QNX's QWDI).** erXos has one chip. Idea 7's naming gives
   the seam; a table of optional operations waits for a second chip.

7. **A policy service stacked on a supplicant stacked on a driver
   (QNX `wpa_pps`, Android's HALs, Fuchsia's four components).** Each
   layer re-models the same networks and states; QNX keeps profiles in
   both `/etc/wpa_pps.conf` and the supplicant's file. erXos's single
   station owns the model, and its views are `/proc` and `ctl`, per
   "no new mechanism without a design that names it".

8. **Hidden-network probabilities and connection histories (Fuchsia,
   `network_config.rs:24-58`).** Machinery for a phone that meets many
   networks; a block's `scan_ssid` states the fact the probability
   estimates. Revisit only with a consumer.

9. **Throughput estimation and multi-bonus scorers (Android's
   `ThroughputScorer`, wpa_supplicant's `est_throughput`).** Their inputs
   (rates per BSS, metered status, validation) do not exist in erXos's
   station and have no consumer on a Pi; `priority` then signal, with
   idea 2's per-BSS penalty, covers the common path.

10. **Interactive secret prompts in the protocol (`CTRL-REQ`, factotum's
    prompter).** A conversation inside `ctl` would be a new protocol;
    idea 8 gives a front end what it needs through the existing
    inspection path.

11. **Software CCMP in the host (9front).** Right for SoftMAC; the
    CYW43455 does CCMP in firmware, and erXos installs keys into it.

12. **Credentials as plaintext passphrases in a component's file
    (Fuchsia, QNX, Zephyr's `settings` backend).** erXos already keeps
    derived values only, in the vault; nothing to take.

## Not verified

- Whether OpenBSD 8.0 has an SAE exchange anywhere outside net80211
  (only the AKM bit was found).
- wpa_supplicant's simulated-radio test suite (in its git repository,
  not the release tarball).
- Whether Fuchsia's per-component storage is encrypted at rest, and how
  `fuchsia.wlan.tap` is used in its tests.
- QNX 8.0's PPS object layout (the 8.0 and 7.x documents say the objects
  are undocumented; the 6.6 layout is cited as the documented form).
- Android's storage of saved credentials (not in the pages read).
- How a wrong PSK shows on the CYW43455 (missing message 3 or a
  deauthentication reason), which idea 3 depends on; a board probe
  settles it.
