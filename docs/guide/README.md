# Guide

How-tos for people who use erXos and people who work on it. What each part
is and why it is built that way is in the design documents, starting at
[design.md](../design.md); the book, [The Design and Implementation of the
erXos Operating System](../book/README.md), explains the whole system from
the ground up.

## Using erXos

* [Raspberry Pi 4](raspberry-pi-4.md): write the card, boot the board,
  check its SD card and Ethernet, load code over SSH, and netboot builds
  from a Mac.
* [Loading code into a running machine](loading-code.md): how code gets
  into a domain, and how to replace modules from your host on QEMU and on
  the Pi.

Building the system and running it in QEMU is in the
[top-level README](../../README.md#getting-started).

## Developing erXos

Start with [the developer's guide](developing.md), a tour of the loop from
a fresh checkout to a landed change. Its steps link to these pages:

* [Loading code into a running machine](loading-code.md): change Erlang
  code and see it run without a new image.
* [Debugging](debugging.md): the transcript, the inspector and `/proc`,
  the logs, hosted mode, the kernel debugger, and what is not built.
* [Tracing](tracing.md): `erx:trace/1`, OTP's own tracing, the kernel
  trace ring, and benchmarks.
* [Testing](testing.md): the two gates, and how to run one QEMU suite, one
  host test or all of `make check`.
