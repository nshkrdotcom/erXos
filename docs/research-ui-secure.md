# Research record: secure and capability-based GUIs

Date: 2026-11-15. Host: Apple Silicon macOS, documents fetched with
curl over HTTPS and read as text (pdftotext 25.08.0, macOS textutil). Part of
the erXos UI survey; scope is GUIs designed around security and
capabilities, the area where erXos's architecture could lead.

Compared against erXos master as of commit `9abb9e91c`:
[design-display.md](design-display.md), [design-desktop-programs.md](design-desktop-programs.md),
[design-apps.md](design-apps.md), [design-files.md](design-files.md).
Every outside claim cites a document in the source table at the end
(by its key, for example [nitpicker_genodelabs]); a claim no fetched source
supports is marked *unverified*. No GPL or LGPL source code was read;
Genode (AGPL) and Qubes were read only through their papers, release
notes and documentation.

## 1. Summary

* erXos's display design already has most of the isolation properties
  that took the research systems a decade to argue for: no client sees
  another's pixels or input, the keyboard moves only on the user's own
  click, the reserved chord reaches no window, rendering and decoding
  run in the client's domain, and the display domain's trust is stated
  as plainly as EWS and Qubes state theirs. On isolation it is at
  parity with Nitpicker and EWS, level with Wayland's core protocol,
  and well ahead of X11 and Plan 9's rio.
* What it lacks is the *user-facing* half of a secure GUI: the user
  cannot tell which principal owns a window, the clipboard is shared by
  every grant that has it on, there is no trusted prompt, no way to
  hand one file to an app, no consented screen capture, and a client
  can take a click by raising its window just before the click lands.
  These matter now, because an app runs as its own principal and its
  window opens beside the person's on the same desktop
  (design-display.md:3657).
* The cheapest high-value additions are, in order: a stability delay on
  the pick (fixes the click-steal residual; small), a volitional
  clipboard policy in Genode's style (small), the principal's name and
  colour on window frames when more than one principal shares a display
  (small), and a trusted overlay on the reserved chord that dims every
  client and shows the true labels, Nitpicker's X-ray (small to medium).
  A powerbox file picker and consented screen capture are medium and
  each needs a design, since each is a new cross-domain facet.

## 2. What erXos has today

Read from the design documents (target design, not all built):

| Property | Where | Note |
| --- | --- | --- |
| Pixels private per client; display maps buffers read-only | design-display.md:4240 | G1. Same as Nitpicker's buffers and EWS's R1/R2. |
| No client reads the screen or another window | design-display.md:4240, 437 | Plan 9's `/dev/screen` and `/dev/wsys/N/window` are not offered. |
| Input to one window per event; gesture goes where its down went | design-display.md:4326 | Nitpicker and EWS rule exactly. |
| Keyboard moves only on the user's click or menu pick, never on a client request | design-display.md:1969 | Nitpicker: "only the user selects the focused view". |
| Reserved secure attention chord, decided before policy, reaches no window | design-display.md:2027 | What it opens is left to the login design (decision 14, :5344). |
| Window menu drawn by the display, labels escaped | design-display.md:1943 | A trusted surface, but only while open. |
| Borders always drawn by the display; colour marks the current window | design-display.md:1943 | No principal label or colour. |
| Clipboard per display, shared by every grant whose facet row turns `clipboard` on | design-display.md:4376 | Global among those grants; no per-paste authorisation. |
| Rendering, PNG decoding and draw parsing in the client's domain | design-display.md:4300 | Arcan's frameserver idea, by construction. |
| Display domain's trust stated (sees keys and pixels, as an X server) | design-display.md:4260 | Same honesty as Qubes's arch spec. |
| Residuals stated: a window can mimic another; raising under the pointer takes the click and keyboard | design-display.md:4404 | These are exactly the gaps the research below addresses. |
| Per-program namespace narrowing; a program reaches only fids walked for it | design-files.md:1425 | The mechanism a powerbox needs already exists. |
| Apps run as their own principal, windows beside the person's | design-apps.md:925, design-display.md:3657 | Makes labelling and clipboard policy matter now. |

## 3. A frame for judging: three lists

* **Six properties (Peres, 2014):** confidentiality, integrity and
  availability of input and of output. X11 has none; Wayland's core
  protocol has all six, leaving privileged interfaces (screenshots,
  virtual keyboards) outside it [mupuf_wayland_sec].
* **Volitional traceability (EWS, 2004):** "No communication may occur
  between applications through the display server unless we can
  demonstrate an authorizing user action" (R6), with isolation (R1), no
  shared mutable state (R2) and one recipient per event (R9)
  [eros_ews_sec04].
* **Yee's principles (2002):** among ten, explicit authority,
  visibility, revocability, *trusted path* ("an unspoofable and
  faithful communication channel between the user and any entity
  trusted to manipulate authorities") and *identifiability* [yee_uidss2].

erXos is strong on the six properties, R1, R2 and R9, and weak on R6
(clipboard), identifiability (no trusted labels) and trusted path (no
trusted prompt yet).

## 4. Systems and ideas

### 4.1 Genode: Nitpicker and the layered GUI stack

Nitpicker (2005, about 1,500 lines) knows only client buffers and
views; windows and widgets are client-side. The user alone picks the
focused view by a click; keys go only to the focused client; a drag
stays with the view that saw the press; input is scancodes only. Two
"magic keys" reach no client: Kill (freeze and lock out a client) and
X-ray [nitpicker_genodelabs].

**Trusted labels.** A label is a trusted part from the parent followed
by the client's untrusted part. Since a full-screen window can paint a
fake desktop, Nitpicker adds a reserved strip and dimming: in X-ray
mode every view but the focused client's is dimmed and labels float at
full brightness, so a dimmed view cannot mimic them; in Flat mode only
a red strip with the focused client's label shows. Only the user
toggles the mode, and "passwords should never be entered in Flat mode"
[nitpicker_genodelabs].

**Drag and drop** goes through a separate *negotiator* holding the
flow policy: it decides per target as the pointer crosses views and
copies the payload on release; Nitpicker only routes events, and the
one covert channel left (the target's choice of type) is "bounded by
user action" [nitpicker_genodelabs].

**The stack after 2014.** A window manager (under 2,000 lines) speaks
Nitpicker's interface, so clients cannot tell which they talk to, and
delegates to two sandboxed children: a layouter that sees no
application input or pixels, and a decorator that draws borders. It ran
acceptably on a Raspberry Pi in software rendering [genode_rn_14_08].
In 20.08 the drivers became *clients*: input drivers push into an
"Event" session, the framebuffer driver pulls from a "Capture" session,
so the 3,000-line server no longer depends on a 122,000-line Intel
driver [genode_rn_20_08].

**Clipboard (2019).** A copy or paste is allowed "only if the user
supplied a button press event to the application during the last 500
milliseconds", using Nitpicker's focus; no unfocused application can
read, and colluding applications leak only as fast as the user switches
focus. A static flow whitelist sits on top [genodians_copy_paste].

**Buys** a small trusted base with policy outside it; **costs**
client-side decorations and scancode handling; **mature** in Sculpt
OS. **Fit:** erXos's display already plays Nitpicker's role and
`erx_wm` is a pure policy module. Genode sandboxes its policy because
a C++ policy bug can be a memory bug; a pure Erlang function cannot
corrupt the router, so erXos's single domain is the right size. Worth
taking: X-ray, the trusted-plus-untrusted label, the 500 ms clipboard
rule, and Capture's idea that a recorder is the same kind of client as
the display driver (section 6.6).

### 4.2 EROS Trusted Window System (EWS)

Under 4,500 lines, "a factor of ten smaller than previous trusted
window systems such as Trusted X"; session resources come from the
client; the server queues no requests; input helpers post events
through capabilities distinct from clients' [eros_ews_sec04].

* *Nested sessions* a parent cannot spy on, through a verifiable
  `SessionCreator` [eros_ews_sec04].
* *Traceable cut and paste*: nothing moves until the user pastes; a
  server key table traces keyboard paste, and mouse paste needs a
  server-defined cursor visible for a minimum time [eros_ews_sec04].
* *Format negotiation without a back channel*: a frozen region holds
  the native format and a confined converter makes the others
  [eros_ews_sec04].
* *Title bars are directives*, drawn by the server in a compiled-in
  font. Yet "there is no label that the display server can apply on a
  window border that cannot be visually forged by a client", so EWS
  adds a reserved band and a bright focus border [eros_ews_sec04].
* *Most trusted paths are unnecessary in a capability system.* "There
  is no need for a trusted path to support a trusted SaveAs agent",
  because only the SaveAs agent holds the file-system capability: an
  application "might forge the appearance of a SaveAs dialog, but
  cannot forge possession of the necessary file system capability".
  What remains is password prompts, key passphrases and login; when a
  trusted client session is active, "all other windows are overlayed
  with a red alpha-blended overlay, and the reserved labeling region
  ... is distinctively marked" [eros_ews_sec04].

**Maturity.** A research prototype; resource quotas were not
implemented [eros_ews_sec04]. **Fit for erXos.** The SaveAs argument is
the most useful single sentence in this survey for erXos: a powerbox
needs no unforgeable UI, only the authority split. The trusted-session
overlay is the model for erXos's trusted prompts (section 6.4).

### 4.3 Qubes OS GUI virtualisation

Each AppVM runs its own X server on a dummy driver; an agent sends
window events and composition buffers (Xen grant references) to a
daemon in dom0 or a GUI VM, which sends input back only to the VM whose
window has focus. All messages but clipboard and buffer dumps are fixed
size, "so the parsing code can be small" [qubes_gui2]. The trusted
decorator paints every window's frame in the VM's colour and prefixes
the title with the VM's name; menus get a two-pixel frame [qubes_gui2],
against a VM that would "display imitation of other windows"
[qubes_arch_spec].

**Clipboard.** Per-VM clipboards; the user moves text with
Ctrl-Shift-C in the source and Ctrl-Shift-V in the target, which also
*clears* the global buffer [qubes_copy_paste2]. The docs admit that a
VM creating a window just before Ctrl-Shift-V can steal focus and the
paste [qubes_copy_paste2].

**Fit:** the coloured frame and name prefix map onto erXos's
`decorate/3`; erXos already avoids the focus gap, since a new window
never takes the keyboard (design-display.md:1969). Clear-on-paste is
one clipboard option; Genode's 500 ms rule is less intrusive (6.2).

### 4.4 Plan 9: rio and per-window namespaces

**What it is.** 8½ and rio serve each window its own `/dev/cons`,
`/dev/mouse` and friends; a window is a mount of the window server,
"so graphics need no new kind of object" [eight_half, rio_man]. Mouse
events are invisible to a window when the pointer is outside it
[rio_man].

But rio also serves every window `screen`, the image of "the entire
underlying display", `wsys/N/window` for any window, and one global
`snarf` [rio_man]: a naming convenience, not a security boundary.
erXos kept the shape and removed the leaks, which is right.

### 4.5 Arcan

**What it is.** A "desktop engine" whose window manager is a Lua script
(the *appl*) that owns all policy: sharing, input routing, and "any
user-facing privileged operation, like instructing where data should be
sent or shared-, authentication token retrieval, lock screens, file
pickers" [arcan_wiki_security, arcan_quest]. Parsing of untrusted data
(image and video decoding, encoding, OCR) is pushed into sandboxed
*frameservers* [arcan_quest]. Clients attach to named, single-use
connection points that the WM opens, which the author presents as a
rate limit against resource exhaustion; the WM can bind a connection
point to a launch target from a locked database to give a chain of
trust for input-method and assistive-device clients [arcan_quest].
Clipboard and drag and drop are specialisations of a typed alternate-
data-stream mechanism (`bchunkhints`), and clients can offer an
"accessibility" reduced representation of a window [arcan_quest]. The
project says full security review waits for its 0.9 release
[arcan_wiki_security].

**Fit:** erXos has the frameserver property by construction. The WM
as home for pickers and lock screens carries over (6.4, 6.5); typed
alternate representations come free with widget trees. By its own
author's account Arcan is not yet reviewed, so it gives ideas, not
guarantees.

### 4.6 Fuchsia: Scenic, Flatland, ViewRefs and the focus chain

Flatland is Scenic's 2D retained-mode composition API; each session
runs on its own dispatcher and images come from Scenic's allocator
without copies [fuchsia_flatland]. Each view has a `ViewRef`, an
eventpair whose kernel id is unforgeable and never reused, yet "merely
holding a ViewRef should not grant the holder powers" [fuchsia_viewref].
The view tree is an authority tree; the focus chain runs from the root
to the focused view, "ordered in amount of authority". Programmatic
focus moves only by *take* (an ancestor), *grant* (to a descendant) or
*release* (upward); a click or touch start moves it, hover never. Modal
dialogs are made by System UI with a scrim so no outside view can steal
their focus; secure input is out of scope [fuchsia_focus].

**Fit:** erXos's never-reused window ids and hidden holder pids are the
same "a name is not an authority" rule (design-display.md:1876 ff.).
Take/grant/release is a clean model for embedding, which erXos has no
consumer for yet; "modals belong to System UI" matches EWS and points
at display-owned prompts (6.4).

### 4.7 Wayland and the portals

Buffers pass by fd, and the protocol has no way to snoop, synthesise
or grab input [mupuf_wayland_sec]. The selection is set only with "the
serial number of the event that triggered this request" and offered
only to the client with keyboard focus; a drag needs "an active
implicit grab that matches the serial" [wayland_spec_datadevice]. So
clipboard writes and drags are tied to input and reads to focus.
Screenshots, recording and input injection are outside the core
[mupuf_wayland_sec] and are filled by:

* `security-context-v1`: a sandbox engine attaches a context to a
  listening socket, and the compositor restricts what connections
  arriving there can bind; nesting is refused [wayland_security_context].
* The ScreenCast portal: `Start()` "typically presents a dialog to the
  user"; sessions can persist through single-use restore tokens
  [portal_screencast]. The RemoteDesktop portal does the same for input
  injection, choosing keyboard, pointer and touch devices in a dialog,
  with events sent over libei [portal_remotedesktop].
* The FileChooser portal shows a dialog run outside the sandbox, and the
  chosen files are exposed through the Documents portal: a FUSE file
  system in which "the view inside the sandbox is restricted to just
  those files that the application is allowed to access", with
  permissions shown as POSIX mode bits [portal_filechooser, portal_docs].

Whether a given compositor shows a persistent indicator while capture
is active is compositor policy and *unverified* here.

**Fit:** the serial rule is the cheap form of EWS's R6 (6.2). The
Documents portal is erXos's "file tree its owner serves and the reader
mounts" pattern: a powerbox is a narrowed grant, not a new object (6.5).

### 4.8 macOS: TCC and secure event input

TCC asks consent before apps read Documents, Downloads, Desktop and
network volumes or use accessibility and automation, and keeps
per-app grants for input monitoring and screen recording, listed and
revocable in System Settings [apple_platform_security]: Yee's
visibility and revocability as a settings page.
`EnableSecureEventInput` keeps keys from event taps; since a 10.4
security update, while *any* process has it on, no intercept process
gets keys, foreground or not; `NSSecureTextField` uses it
[apple_secure_input_tn].

**Fit:** erXos has no event taps, so no secure-input mode is needed.
The settings list is worth taking for run-time grants (6.9). Apple's
App Sandbox "Powerbox" documentation could not be fetched.

### 4.9 Android: overlays, tapjacking, Cloak and Dagger

Apps with `SYSTEM_ALERT_WINDOW` draw over others. Defences piled up:
`filterTouchesWhenObscured`; since Android 12, touches through
another UID's untrusted overlays are blocked, but for alert windows
only at opacity 0.8 or more; partial occlusion has "no default
protections"; background toasts blocked [android_tapjacking]. Cloak and
Dagger: with that permission plus `BIND_ACCESSIBILITY_SERVICE` an app
can "completely control the UI feedback loop", steal PINs and silently
install a "God-mode" app; the first permission was granted
automatically to Play Store installs [cloak_dagger2].

**Fit:** erXos has no client overlays or click-through, so the top
window gets the click, as the user sees; partial occlusion by another
window remains. The lesson is accessibility as a declared grant (6.8).

### 4.10 Trusted path indicators and secure attention keys

* **Windows:** Ctrl+Alt+Del before sign-in "ensures that users are
  communicating through a trusted path"; it can be turned off for users
  with physical impairments, at a cost [ms_ctrl_alt_del, yee_uidss2].
* **Trusted Extensions:** a *trusted stripe* that "cannot be moved or
  obscured by other windows", with a trusted symbol, shown whenever the
  user deals with the trusted base, that "cannot be forged", and the
  active window's label [solaris_tx_symbol, solaris_tx_elements].

**Fit:** erXos has the chord. A permanent stripe fights the "slick and
sharp" direction; showing the trusted area on demand (Nitpicker) fits.

### 4.11 Clickjacking research: InContext and access control gadgets

**InContext (Huang et al., 2012).** Clickjacking presents a sensitive
element "out of context". The defence needs *visual integrity* (the
element and the pointer fully visible) and *temporal integrity* (the
click intended at that moment). Measures: a UI delay before a click on
a sensitive element counts, a stronger delay counted from each pointer
entry, and *pointer re-entry*: when a sensitive element appears under
the pointer, clicks are invalid until the pointer leaves and re-enters
[clickjacking_sec12]. Attack success in their studies ran from 43% to
98% [clickjacking_sec12].

**Access control gadgets (Roesner et al., 2012).** Each user-owned
resource (camera, clipboard, files) exposes a gadget, owned and drawn
by the system, that apps embed; a real click on it grants the
permission. The kernel keeps gadgets opaque and topmost, deactivates one
if any part is obscured, and activates one "only after it has been
fully visible in the same location for at least 200 ms" [acg_sp12b].
A forged gadget grants nothing [acg_sp12b]. Their studies found users
"expect data on the clipboard to remain private until pasted"
[acg_sp12b].

**Fit for erXos.** The stability delay is directly the fix for erXos's
click-steal residual (section 6.1). Embedded gadgets need cross-client
embedding, which erXos does not have; the powerbox (section 6.5) gives
the same "designation is authorisation" result without embedding.

### 4.12 Powerboxes: CapDesk, Polaris, DarpaBrowser, Sandstorm

The idea: the dialog the user already uses to designate a file *is* the
grant. "The dialog used to choose the file could also serve the purpose
of granting the appropriate capabilities to the application. This
dialog is named the powerbox" [hurd_powerbox].

* **CapDesk** (E) turns "a user-interface action into a request to a
  caplet, carrying a reference saying what object the caplet should
  operate on"; usable least authority means to "bundle authority with
  designation" (double-click, open dialog, drag) [miller_thesis].
* **Polaris** confined each Windows XP application in its own account;
  a double-click or Polaris's own Open/Save dialog gave it that one
  file; title bars showed the confinement domain; about 20 HP Labs
  users, some for over six months [polaris_soups].
* **DarpaBrowser**, a caplet using a possibly malicious renderer, was a
  reviewed proof of concept only [miller_thesis]; the review itself was
  unreachable.
* **Sandstorm**: an app asks for a *type* of resource and the user
  picks which one [sandstorm_powerbox].
* **Capsicum** found delegation "most valuable" in windowing:
  "Powerboxes (file dialogues running with ambient authority) and
  drag-and-drop" [capsicum_sec10]. Rutkowska replied in 2011 that
  Capsicum then had no GUI isolation and would complement, not replace,
  VM isolation [itl_gui_isolation].

**Fit:** strong and cheap in mechanism; file grants already narrow per
program (design-files.md:1425). See 6.5.

### 4.13 CHERI desktop work and Rutkowska

The 2021 CHERI desktop study compiled X11, Qt and KDE (about 6 million
lines) memory-safe with a 0.026% change rate and estimated past
vulnerabilities mitigated at 91% for X11, 82% Qt, 43% KDE;
compartmentalisation was only whiteboarded [cheri_desktop_report]. It
hardens a conventional stack; X11's authority model is unchanged. No
CHERI on erXos's targets; erXos gets the GUI-side effect by parsing in
Erlang in the client's domain.

Rutkowska's 2011 post shows X11 lets "one application ... sniff or
inject keystrokes to another one" across users and SELinux sandboxes
(`xinput test`), and that Qubes avoids it by giving each domain its own
X server [itl_gui_isolation]. erXos's display trust statement
(design-display.md:4260) follows Qubes's discipline [qubes_arch_spec].

## 5. Property matrix

| Property | X11 | rio | Wayland + portals | Nitpicker/Genode | EWS | Qubes | erXos (design) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Clients cannot read others' pixels | no | no | yes | yes | yes | yes | yes |
| Clients cannot read others' input | no | partly | yes | yes | yes | yes | yes |
| Clients cannot inject input elsewhere | no | ? | yes (core) | yes | yes | yes | yes |
| Keyboard moves only on user act | no | ? | compositor policy | yes | ? | WM policy | yes |
| Reserved key reaches no client | no | no | compositor policy | yes (2 keys) | not stated | yes (clipboard keys) | yes (1 chord) |
| Trusted per-principal label | no | no | no | yes (X-ray) | partly (band) | yes (colour + name) | **no** |
| Trusted prompt / dimming | no | no | no | X-ray | red overlay | no | **no** |
| Clipboard tied to user action | no | no | write: serial; read: focus | 500 ms rule | traced paste | user keys, clear on paste | **no** (facet only) |
| File grant by designation | no | no | FileChooser portal | not covered | SaveAs agent | qfilecopy | **no** (mechanism exists) |
| Screen capture behind consent | no | no | ScreenCast dialog | Capture session by policy | n/a | no | n/a (no capture at all) |
| Click stability delay | no | no | no | no | cursor delay for paste | no | **no** (residual) |

"?" means the source read here does not say. erXos's entries are from
its design documents, not a running system.

## 6. What a modern erXos design should add, with costs

Sizes: **S** is one module change with tests inside the display domain
and no new facet; **M** touches several modules or one new facet and
needs a short design section; **L** is a new cross-domain protocol with
its own design document.

### 6.1 Temporal integrity for the pick (S)

The residual at design-display.md:4404: a client that raises its window
under the pointer just before a click takes the click and the keyboard.
Fix in `erx_wm_rio`'s `input/4`: a press picks a window only if its
rectangle and stacking place have been unchanged for a minimum time
(ACGs use 200 ms [acg_sp12b]; InContext tested 250 to 1000 ms
[clickjacking_sec12]), or only if the pointer entered it after its
last change (InContext's pointer re-entry); otherwise the press is
dropped. A pure function of policy state and event time, testable on
the host. Cost: a timestamp per window, one rule, a seeded test (raise
then click, expect no pick). No new concept.

### 6.2 A volitional clipboard (S)

Today any grant with `clipboard` on reads what any other copies
(design-display.md:4376), and that set includes app principals beside
the person. Adopt Genode's rule [genodians_copy_paste]: a write to or
read of `/clipboard` succeeds only if it arrives on the grant that
holds the current window and that window received a button or key down
in the last 500 ms. `erx_winfs` knows the current window, every
window's holder and serves `/clipboard`, so this is one check in one
place. The clipboard becomes a user-traced channel (EWS R6) with no
prompt; a copy typed at a shell (`echo x > /dev/clipboard`) still works,
since Return was just pressed in that terminal; copying from a timer
stops, as intended. Optional, each S: Qubes's clear-on-paste across
principals [qubes_copy_paste2], a flow table between principals as
Genode's whitelist. It answers part of decision 14's open "who shares
the clipboard then".

### 6.3 Trusted labels when principals share a display (S)

Borders already come from the display. Add, in `decorate/3`, the
principal's colour (from the theme, keyed by principal) and a short
trusted label (the principal's name) ahead of the client's untrusted
`label`, Nitpicker's concatenation [nitpicker_genodelabs] and Qubes's
name prefix [qubes_gui2]. Show it only when windows of more than one
principal are shown, so the single-person desktop keeps its clean look.
The menu, which already names hidden windows, gets the same prefix.
Cost: the display needs each window's principal (it has the grant each
window came through; whether the grant record carries the principal's
name or only its template is to be checked), glyph drawing the menu
already does, and a theme entry. It does not stop a window drawing a
fake window inside itself (EWS: no border label is unforgeable
[eros_ews_sec04]); 6.4 covers that.

### 6.4 A trusted overlay on the reserved chord (S to M)

The chord is reserved and "opens nothing" yet (design-display.md:2027).
Make the display's answer to it a trusted overlay drawn by the display
domain, as the menu is: every client window dimmed, each window's true
label and principal shown at full brightness over it (Nitpicker X-ray
[nitpicker_genodelabs]), plus the trusted screens the login design
chooses (lock, login, unlock the vault). The same overlay mode is the
frame for any trusted prompt: while it is up, clients are dimmed (EWS's
red overlay [eros_ews_sec04]) and receive no input, the prompt is
topmost and cannot be occluded (ACG complete visibility [acg_sp12b]),
and keys go to the display domain alone. EWS's point that only login,
passphrases and key unlocks need a trusted path [eros_ews_sec04] keeps
the list short. Cost: the X-ray view is S (overlay image, labels,
dimming in `erx_screen`); trusted prompts are M because what they talk
to (the vault, the login service) is the login design's, and should be
designed there, not added here.

### 6.5 Powerbox file picker (M, needs a design)

For an app running as its own principal, the person's files are out of
reach, which is correct; today there is no way to give it one file.
Design the picker so that:

* the picker runs with the person's namespace (it is the `files`
  program, or a mode of it, in the person's session), not in the app;
* the app asks by type ("open a picture", "save as text"), as Sandstorm
  [sandstorm_powerbox] and the FileChooser portal [portal_filechooser]
  do;
* the user's choice yields a grant rooted at that one file or folder,
  read or write as chosen, served to the app's session and mounted in
  its namespace, the erXos form of the Documents portal's restricted
  view [portal_docs];
* opening a file from `files` into an app, and dropping a file on an
  app's window (6.7), are the same grant, Polaris's double-click
  [polaris_soups] and CapDesk's "bundle authority with designation"
  [miller_thesis].

By EWS's argument the picker needs no unforgeable chrome: a fake picker
drawn by the app grants nothing [eros_ews_sec04]. Cost: narrowing
exists (design-files.md:1425), but handing a grant from one principal's
session to another's is a new cross-domain facet and goes through the
design rules. Inside one person's session the shell's arguments already
are the designation; nothing changes there.

### 6.6 Screen capture as a grant with an indicator (M, needs a design)

erXos offers no capture today, which is the strongest possible default.
A desktop will want screenshots and recording. Shape:

* capture is a file tree the display serves (a screen or window image
  file) only on a grant whose facet row turns a `capture` flag on,
  exactly as `clipboard` is gated today, so no new kind of mechanism;
* while any capture grant has an open stream, the display draws an
  indicator in its own overlay that no client can cover;
* a one-shot screenshot the person takes is a display-owned action (a
  menu item) whose image is offered only to the display's session, so
  no app needs the flag;
* run-time consent for an app (Wayland's ScreenCast dialog
  [portal_screencast], macOS's list [apple_platform_security]) uses the
  trusted overlay of 6.4 and the grant list of 6.9.

Genode's Capture session is the elegant end state: driver and recorder
are the same kind of client [genode_rn_20_08]. Cost: encoding runs in
the reader's domain; indicator S; facet and consent M.

### 6.7 Drag and drop as a one-shot transfer (L, defer)

None exists between windows. If added, follow Nitpicker and EWS: the
display owns the gesture, the source declares a drag, the target sees
only typed "floating" events, and the payload moves once, on the up,
through a broker, never parsed by the display [nitpicker_genodelabs,
eros_ews_sec04]; a dropped file is the powerbox grant of 6.5. A new
protocol over three parties with no consumer yet: defer.

### 6.8 Accessibility and input injection as declared grants (M, later)

A screen reader reads every window and injects input; Cloak and Dagger
shows that pair of powers is the whole GUI [cloak_dagger2]. When one is
designed, it is a facet row with a visible indicator, like capture;
Arcan's WM-bound connection points [arcan_quest] show how to bind it to
a known program; widget trees give the structured form for free. The
baseline already holds: an input source "has the reach of a person at
the display, and no more" (design-display.md:4326).

### 6.9 Visibility and revocation of grants (S, with 6.5 and 6.6)

Yee's visibility and revocability [yee_uidss2], and macOS's settings
list [apple_platform_security]: every live run-time grant (file grants
from the powerbox, capture, accessibility) is listed at an inspection
path under `/proc` and in a settings window, with revoke as a `ctl`
write. This uses erXos's existing homes for state and commands; no new
mechanism.

## 7. Recommendations

### (a) Worth adopting or prototyping, ranked

1. **Pick stability delay or pointer re-entry** (6.1). Closes a stated
   residual with a pure, testable rule. S.
2. **Volitional clipboard, 500 ms after a down in the current window**
   (6.2). Removes the one piece of shared mutable state between
   principals. S.
3. **Trusted principal label and colour on frames when principals
   share a display** (6.3). Makes app windows distinguishable from the
   person's terminal. S.
4. **X-ray overlay on the reserved chord, frame for trusted prompts**
   (6.4). Gives the chord a use now and the login design its trusted
   surface. S for X-ray, M for prompts.
5. **Powerbox file picker** (6.5). The capability-native answer to
   "let this app open this file"; mechanism largely exists. M, design.
6. **Capture behind a facet flag with an uncoverable indicator** (6.6).
   Needed before any screenshot tool. M, design.
7. **Grant list and revoke** (6.9). Comes with 5 and 6. S.
8. **Accessibility as a declared facet** (6.8). When a11y is designed.
   M.
9. **Drag and drop via the display's gesture and a broker** (6.7).
   Only when a program needs it. L.

### (b) Attractive but not a fit now

* **Sandboxed layouter and decorator processes (Genode):** they guard
  against memory bugs in C++ policy; erXos's policy is pure Erlang, so
  the split adds protocols without removing a risk.
* **A permanent trusted stripe (Trusted Solaris, DOpE):** screen space
  on every screen, against the owner's visual direction; on-demand
  X-ray gives the assurance when it matters.
* **Embedded gadgets and nested sessions (ACG, EWS, Fuchsia):** need
  cross-client embedding with no consumer; the powerbox gets
  designation-as-authorisation without it.
* **Per-principal VMs (Qubes) and CHERI:** erXos domains already give
  the isolation; no CHERI hardware on the targets.
* **Scancode-only input (Nitpicker):** keymaps in the display are a
  UNIX-feel choice, and modifiers reach only the window typed to
  (design-display.md:4326).
* **Narrowing every CLI program to its arguments (CapDesk):** would
  break the UNIX behaviour the shell and toybox rely on.
* **Prompts as the main consent mechanism (TCC):** the ACG authors
  find prompts disruptive and that they teach users to ignore them
  [acg_sp12b]; prefer designation (powerbox, drop), keep prompts for
  the few trusted-path cases.

### (c) Open questions and unverified points

* Whether `erx_winfs`'s grant record carries the principal's name or
  only the template; 6.3 needs the name (to check in design-system.md).
* What the clipboard rule should be for configured domains that read
  `/clipboard` without a window (design-display.md:4376 names them);
  under 6.2 they could no longer read it, which may be right.
* The right delay for 6.1 on touch panels and encoders (InContext notes
  the plain delay is still needed where there is no pointer
  [clickjacking_sec12]).
* Whether Wayland compositors (GNOME, KDE, wlroots) show a persistent
  capture indicator: *unverified*, not read.
* Apple's App Sandbox "Powerbox" (out-of-process Open/Save panel) is
  known from memory only: *unverified*; the guide redirected to a
  script-only page.
* The Wagner-Tribble DarpaBrowser review, the CapDesk pages and Yee's
  "Aligning Security and Usability" were unreachable; claims about them
  rest on Miller's thesis [miller_thesis], which is a mirror copy, not
  the publisher's.
* Genode's current window manager and clipboard may differ from the
  2014 and 2019 write-ups read here.
* No search turned up GUI-security work specific to CHERI beyond the
  2021 desktop study; a later Morello GUI compartmentalisation result
  may exist and was not found.

## 8. Sources

All fetched 2026-11-15 over HTTPS into
`~/erxos-scratch/sources/ui-survey/secure/raw/`, with text in `txt/`
and `plain/`. SHA-256 of the fetched file:

| Key | URL | SHA-256 |
| --- | --- | --- |
| `genode_rn_14_08.html` | https://genode.org/documentation/release-notes/14.08 | `b8f667fe6cce7334e93e7abde102e1366584a893dda6fd56e13eb3db2447aef8` |
| `genode_rn_16_05.html` | https://genode.org/documentation/release-notes/16.05 | `26ba8c5ee4a1a8b4aa84bb19da3db5fb1f912c626e90b83ca1e6d3d1aa81c61d` |
| `genode_rn_20_08.html` | https://genode.org/documentation/release-notes/20.08 | `579c426812d22f82b9c2e4204511cced8511fa32324106f463542fd2bec56f89` |
| `eros_ews_sec04.pdf` | https://www.usenix.org/legacy/event/sec04/tech/full_papers/shapiro/shapiro.pdf | `18ab072a47846cf58fb2758898779b9e84c07b3b5b41e997ead6f5d710b6704a` |
| `qubes_arch_spec.pdf` | https://www.qubes-os.org/attachment/doc/arch-spec-0.3.pdf | `fb2a15352cd529d2ba49a083fe31cf987724ea5ffd18032adaa0fed369a83601` |
| `itl_gui_isolation.html` | https://theinvisiblethings.blogspot.com/2011/04/linux-security-circus-on-gui-isolation.html | `9e3354faac00c5e5e71db47db5ee3f153c7b731d443358b03ee495c0d4b37f2c` |
| `fuchsia_viewref.html` | https://fuchsia.dev/fuchsia-src/development/graphics/scenic/concepts/view_ref | `04a5ebc876bc9b2b0c13c25a3a689e47a852f135fca074b1608d4a6bfce88d75` |
| `fuchsia_focus.html` | https://fuchsia.dev/fuchsia-src/development/graphics/scenic/concepts/focus_chain | `e9f2cceef6a9f66f2de3621a87325af5756c26f574ac97e7a62c7acc51b7eeb8` |
| `fuchsia_flatland.html` | https://fuchsia.dev/fuchsia-src/concepts/ui/scenic/flatland | `e96869110dfee9ab18d6771fb26f11bc1587f087b86f5dca8b7ae5807503b485` |
| `mupuf_wayland_sec.html` | https://mupuf.org/blog/2014/02/19/wayland-compositors-why-and-how-to-handle/ | `28a9edc5206bfe1f37378128280fa26315cda956994bebeec812ab01f736e96f` |
| `wayland_security_context.html` | https://wayland.app/protocols/security-context-v1 | `36c12259e2fa441ffd208f425a7e4516fadc22d19e7a8b7116bb5069c2231207` |
| `portal_screencast.html` | https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html | `d790ed276a777b6652071a2370b096e15e79f67aeb940320ac1e83bc94388715` |
| `portal_filechooser.html` | https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.FileChooser.html | `de773381bc7b18195ab944637de434f38d8945d62affdf3827055615afe9169a` |
| `portal_docs.html` | https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Documents.html | `11ad1c40699bc0eca03c3c149a7c06bd41bf46051d585434f90a8e497760c5be` |
| `wayland_spec_datadevice.html` | https://wayland.freedesktop.org/docs/html/apa.html | `984dc0f66a00099e2561bcbcbc6cf0c064537d0ae9543a60c31b0caeaaa7c2ba` |
| `apple_secure_input_tn.html` | https://developer.apple.com/library/archive/technotes/tn2150/_index.html | `b1164de951366b899b8ec921d7997fc30d2141042e4ae639810714db06b8d273` |
| `android_tapjacking.html` | https://developer.android.com/privacy-and-security/risks/tapjacking | `6b1103b78c0c97800e8f40aa2e2e7cb4b9a445742abd498404a65d9605c6199c` |
| `rio_man.html` | https://9p.io/magic/man2html/4/rio | `0f73d39c3244d39dfaad6c77429a283a91a20237c879edd2366104f99759a15d` |
| `eight_half.html` | https://9p.io/sys/doc/8%BD/8%BD.html | `e2ae28808d97b240b314a9099384a42807d1417edf53b5ad72ae956343c14875` |
| `capsicum_sec10.pdf` | https://www.usenix.org/legacy/event/sec10/tech/full_papers/Watson.pdf | `7ff6a2cf650b15ad852594578847b14f6ecdf08cdedabdb1a03566a4eab4c2ab` |
| `clickjacking_sec12.pdf` | https://www.usenix.org/system/files/conference/usenixsecurity12/sec12-final39.pdf | `489de12622dbd5001444dd3f3529570b3166f5c67a55f97e9765d3c6f45cf6e2` |
| `sandstorm_powerbox.html` | https://docs.sandstorm.io/en/latest/developing/powerbox/ | `c8af110c6774dc325fcd7d646c4c44e18281f19aff53176af509ac79e6d2afe0` |
| `nitpicker_genodelabs.pdf` | https://genode-labs.com/publications/nitpicker-secure-gui-2005.pdf | `d7cc038bdcd99aa9c7b3b2d665ed941de08e13bffacb233a34e465a5e97eb5e6` |
| `qubes_gui2.html` | https://doc.qubes-os.org/en/latest/developer/system/gui.html | `60a7ed32c283ee319adcff3853dd5e4941030c5acec536dc080eabe75213e29f` |
| `qubes_copy_paste2.html` | https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-copy-and-paste-text.html | `4703d99ccd7f4b1fa106db2e0c0bc1f89278cec8abde0e6060f845f7c9fad27c` |
| `arcan_quest.html` | https://arcan-fe.com/2023/06/15/the-quest-for-a-secure-and-accessible-desktop/ | `482d22a6948f8e2801562064a44e591b432f3b73f7ac1e64a7c04b7b9c34ffbf` |
| `arcan_wiki_security.md` | https://raw.githubusercontent.com/wiki/letoram/arcan/Engine-Security.md | `ab2bc6f9e174ad921351883d3c3a8b73c37ff2e7aabf7df345a1ad9153afa68f` |
| `arcan_wiki_display.md` | https://raw.githubusercontent.com/wiki/letoram/arcan/Engine-Display-Server.md | `f122935347960cedf31d1e5772303393af419e131bf96d55b2acc86b65457913` |
| `cloak_dagger2.pdf` | https://www.ieee-security.org/TC/SP2017/papers/117.pdf | `71479d0f935fb21a4cc9c2f07f125a2db75af4e55f67759f0481662205057927` |
| `acg_sp12b.pdf` | https://www.ieee-security.org/TC/SP2012/papers/4681a224.pdf | `4b3e36e287ea9b07a5849aacdc73e9a943c109b5033b2d2f33a364929cfda5dc` |
| `yee_uidss2.pdf` | https://www2.eecs.berkeley.edu/Pubs/TechRpts/2002/CSD-02-1184.pdf | `c8ff5ebae52e628b5b924034617630d68f742630805cf34dfbf34c5b1f5a9d22` |
| `polaris_soups.pdf` | https://cups.cs.cmu.edu/soups/2005/2005posters/9-yee.pdf | `60344066aab64c0056129b20a2510f30e752722522ad40f68201729028cc6aff` |
| `miller_thesis.pdf` | https://lispmeister.github.io/file/2011/06/6365052-robust-composition-mark.s.miller-thesis.pdf | `ec1850bb8dc0627202d8d19dbcea6a79efb8db7bb2b98c8876f1548cd319f3d3` |
| `hurd_powerbox.html` | https://www.gnu.org/software/hurd/hurd/ng/powerbox.html | `8c4c6196db1df1eae931a46187d65106708d6a12ce87a46825158d9c6aece0a7` |
| `cheri_desktop_report.pdf` | https://www.cl.cam.ac.uk/research/security/ctsrd/pdfs/20210917-capltd-cheri-desktop-report-version1-FINAL.pdf | `507b4c6b51a497401f80cdb487d7cedadc3aeca828ad05b83405e33d2393446e` |
| `solaris_tx_elements.html` | https://docs.oracle.com/cd/E19253-01/819-0868/ugelem-1/index.html | `02b09ea3853a0587b14be323313a0b437b099c176876bdcfd9d1f5440a66ac12` |
| `solaris_tx_symbol.html` | https://docs.oracle.com/cd/E19082-01/819-7313/6n993dclh/index.html | `489d5e368c0e28fa4ad1875fed3365807625521a51ee2502e527b97ef62d630d` |
| `portal_remotedesktop.html` | https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html | `362b82c7afd0e95cae2438fb3f5f3f774271b48eeb759758a9a28596e4a187dd` |
| `ms_ctrl_alt_del.html` | https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/interactive-logon-do-not-require-ctrl-alt-del | `0ad209602f2672966d0be19cfbaa51f864ca763e608ec43195848ea4d34def6b` |
| `genodians_copy_paste.html` | https://genodians.org/nfeske/2019-07-03-copy-paste | `41d1486f4e50c4e4083a8c339369bad44c2b8f86e5c272ffa00983c4ac93a585` |
| `genode_rn_19_08.html` | https://genode.org/documentation/release-notes/19.08 | `74b5183ab31da829aa5ce898956901e3f25dec305666c5de840483e9a609a4eb` |
| `apple_platform_security.pdf` | https://help.apple.com/pdf/security/en_US/apple-platform-security-guide.pdf | `b52f68820c1ea891c34bba5b9f54ded6f1160fc72561d75fdf5c230c64f83e67` |
| `wayland_image_copy_capture.html` | https://wayland.app/protocols/ext-image-copy-capture-v1 | `62520319bd371681c0cdf9a5969bb8e7516f03641b70486bb8c021b205af1a90` |

Notes on the table: `genode_rn_16_05.html` was fetched but not cited.
`miller_thesis.pdf` is a third-party mirror of Mark S. Miller's 2006
thesis. `apple_platform_security.pdf` is the August 2026 edition.
`fuchsia_*` pages are the fuchsia.dev versions last updated 2025.

Unreachable or rejected (not cited as evidence):

* Nitpicker paper at `genode.org/documentation/publications/nitpicker_acsac05.pdf`:
  404; the genode-labs.com copy above was used instead.
* `combex.com` (DarpaBrowser review, CapDesk page): connection refused.
* `zesty.ca` (Yee papers): connection refused; the Berkeley technical
  report copy above was used.
* `srl.cs.jhu.edu` ("Capability Myths Demolished"): host not found.
* Apple App Sandbox Design Guide (HTML and PDF) and Apple Support
  screen-recording pages: redirected to script-only pages or refused.
* Linux kernel SAK documentation (`docs.kernel.org/security/SAK.html`):
  fetch failed.
* Arcan's Plan 9 article ("One night in Rio"): URL guessed wrong and not
  found by search.
* Fuchsia view ownership page: 404.
* Cloak and Dagger at `cloak-and-dagger.org`: failed; the IEEE S&P copy
  above was used.
