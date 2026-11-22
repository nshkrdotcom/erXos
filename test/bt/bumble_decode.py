# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
"""Bumble's side of the codec comparison (test/host/erx_bt_bumble_test.rb).

Reads the corpus file named by its one argument, lines of `CODEC HEX` where
CODEC is att or smp, decodes each frame with Bumble's own decoder
(bumble.att.ATT_PDU.from_bytes, bumble.smp.SMP_Command.from_bytes) and prints
one canonical line per frame, in the corpus's order:

  rejected                 the decoder raised
  unknown OP               a code Bumble has no class for
  OP FIELD FIELD ...       the code in two hex digits, then each field of the
                           class in declaration order: an integer, an enum or
                           a flag set in decimal, bytes or an address as its
                           octets in wire order, in hex, a UUID as its
                           128-bit form's octets in wire order, in hex

erXos's side prints the same form from erx_att:decode/1 and erx_smp:decode/1
(test/erlang/erx_bt_bumble_decode.erl). A field of any other type stops the
run: the form would otherwise compare a repr.
"""

import sys

from bumble import att, core, hci, smp

# Each codec's decoder, its base class, which an unknown code decodes to, and the
# attribute holding the code.
DECODERS = {
    "att": (att.ATT_PDU.from_bytes, att.ATT_PDU, "op_code"),
    "smp": (smp.SMP_Command.from_bytes, smp.SMP_Command, "code"),
}


def field_text(value):
    if isinstance(value, int):
        return str(int(value))
    if isinstance(value, bytes):
        return value.hex()
    # Bumble hands back the first registered UUID equal to the one read, which may
    # have another width (core.py, UUID.register), so the form takes the 128-bit one.
    if isinstance(value, core.UUID):
        return value.to_bytes(force_128=True).hex()
    if isinstance(value, hci.Address):
        return bytes(value).hex()
    raise SystemExit("bumble_decode: no canonical form for a field of type %s" % type(value).__name__)


def canonical(codec, frame):
    decode, base, code_attribute = DECODERS[codec]
    try:
        pdu = decode(frame)
    except Exception:  # Bumble's decoders raise whatever their parsing meets.
        return "rejected"
    code = "%02x" % int(getattr(pdu, code_attribute))
    if type(pdu) is base:
        return "unknown " + code
    # The fields Bumble parses, as its class lists them (hci.py, fields_from_dataclass);
    # a nested list would be a repeated group, which no PDU here has.
    names = [entry[0] for entry in type(pdu).fields if isinstance(entry, tuple)]
    if len(names) != len(type(pdu).fields):
        raise SystemExit("bumble_decode: %s has a repeated group of fields" % type(pdu).__name__)
    return " ".join([code] + [field_text(getattr(pdu, name)) for name in names])


def main(corpus):
    with open(corpus, encoding="ascii") as lines:
        for line in lines:
            codec, frame = line.split()
            print(canonical(codec, bytes.fromhex(frame)))


if __name__ == "__main__":
    main(sys.argv[1])
