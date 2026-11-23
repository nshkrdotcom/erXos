# Loading code into a running machine

How to replace Erlang modules in a machine that is running, from your
development host, without writing a new image or rebooting. The design
is in [design-live.md](../design-live.md#code-from-the-host); the book
explains the model from the ground up in
[chapter 21, section 21.4](../book/21-live-machine.md#214-how-code-gets-into-a-domain).

Loading code is for development builds, which run trusted code only.
Whoever can load code into the system domain controls the machine.

## How code gets into a domain

* A compiled module is a **blob**, named by the SHA-256 of its bytes. A
  **manifest** maps module names to hashes. A module's version is its
  hash, so a copy from anywhere is the right module if its bytes hash
  to the name.
* At boot, `tools/erx pack` builds the boot image. It holds the runtime
  images (an interpreter ERTS for the system domain, the BeamAsm JIT
  for other domains) and, for each domain, its OTP release in a
  **release slice**: the `.beam` files of its applications and a boot
  script. The domain library maps the runtime and the slice into the new
  domain, ERTS starts, `init` runs the boot script, and the modules load
  from the slice. Apps installed from EROFS images are read from the
  image, and each domain checks the hash of what it loads.
* The system domain runs only installed code: modules of its slice, and
  modules the code service installs for it. Every other domain loads
  any code it is given.
* To change a module on a running machine, the host compiles it, hashes
  it, asks the machine which blobs it lacks, sends those, and the code
  service (`erx_code`) loads the whole batch at once: every module is
  current afterwards, or none changed. Over the host link the tool sends
  only the blobs the machine lacks; over SSH it sends every module of the
  batch.

A load lasts until the machine ends. Loaded code is kept in memory
only, so a reboot returns the machine to the modules of its boot image,
and a change that must stay ships in a new image.

## What works

* Loading into the **system domain**, which is where the system
  services run, over the host link socket (QEMU), over SSH (a board on
  the network), or from the board's own shell with `load -s`.
* `tools/erx watch`, which loads each source of a directory when it
  changes.

Not built:

* Loading into another domain. The tool accepts `--domain D`, but no
  session holds a code facet, so the machine refuses it with `load: no
  code facet`, and the host link socket refuses it before it is sent.
  The domain service does not report domains' starts to the code
  service, and overlays, which would keep a load across a domain's
  restart, and the reset `load -d DOMAIN -r`, depend on that.
* The system domain's refusal of code that is not installed
  (`{error, not_installed}`). Without it, the development build's
  trust in its own code is what keeps other code out.
* `--tty DEVICE`, which would open a serial adapter directly. Use a
  UART bridge that serves the line as a UNIX socket, and `--socket`.

## On QEMU

Build and boot the development image with the host link on:

```sh
tools/erx boot --hostlink
```

The boot prints the socket's path, in `build/production-image/hostlink/`.
In another terminal, load a module, given as a compiled `.beam` or an
Erlang source that the tool compiles first:

```sh
tools/erx load --socket build/production-image/hostlink/SOCKET --system my_module.erl
tools/erx watch --socket build/production-image/hostlink/SOCKET --system src/
```

`--build HEX` makes the tool refuse a machine of another build. The
socket is in a directory only your user can enter; the host link
authenticates nothing else.

On success `load` prints `loaded NAME ... (sent N of M modules)`. A
module the machine already holds is counted in M and not sent.
A failure prints `load: NAME: REASON` and exits 1. After 120 seconds the
tool stops waiting, and the outcome is unknown.

## On the Raspberry Pi 4

With the board on the network and your key on the card, load over SSH.
[The Raspberry Pi 4 guide](raspberry-pi-4.md#load-code-over-ssh) has the
command, the rules for names and the warning about keys.

```sh
tools/erx load --ssh ssh://root@BOARD-ADDRESS:2222 --system my_module.erl
```

When the network is down, or the code you load breaks it, use the host
link: a development card turns it on with `erx.hostlink=1` on UART3
([the wiring](raspberry-pi-4.md#what-you-need)). Serve that line as a UNIX
socket on your host with a UART bridge, and run the same `--socket`
commands as under QEMU.

From a shell on the board, `load -s FILE.beam ...` loads files the
session can read, for example copied with `scp x.beam root@BOARD:/data/`,
and `load -s -m MODULE:BYTES ...` reads modules from standard input.
`load -v` prints each module's hash and whether its blob was sent.

## Picking up the new code

A load makes the new version current in the system domain. A process
takes it at its next fully qualified call of the module,
`Module:Function(...)`, as an OTP behaviour does for its callbacks. A
process whose state the new code cannot read has to be started again.
