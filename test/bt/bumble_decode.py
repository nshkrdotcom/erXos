# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
"""Bumble's side of the codec comparison (test/host/erx_bt_bumble_test.rb).

Reads the corpus file named by its one argument, lines of `CODEC HEX`, decodes
each frame with Bumble's own decoder and prints one canonical line per frame,
in the corpus's order. erXos's side prints the same form from its codecs
(test/erlang/erx_bt_bumble_decode.erl). The codecs:

  att     an ATT PDU, bumble.att.ATT_PDU.from_bytes
  smp     an SMP command, bumble.smp.SMP_Command.from_bytes
  hci     an HCI event's code and parameters, bumble.hci.HCI_Event.from_bytes on
          the packet they make
  l2cap   a frame on LE signaling, bumble.l2cap.L2CAP_Control_Frame.from_bytes
  att-op  an ATT opcode alone, looked up in Bumble's ATT_PDU classes

For att, smp and hci the line is:

  rejected                 the decoder refused the frame
  unknown OP               a code Bumble has no class for
  OP FIELD FIELD ...       the code in hex, then the fields: an integer, an enum or
                           a flag set in decimal, bytes or an address as its
                           octets in wire order, in hex, a UUID as its
                           128-bit form's octets in wire order, in hex

An ATT or SMP line has every field of the class in declaration order. An HCI
line has the fields erx_hci keeps (KEPT), in its order; an LE event's code is
0x3E and its subevent code, a Command Complete's line is its two fields and
then `ok` and the kept return parameters or `failed STATUS`, and an LE
Connection Complete that failed is `failed STATUS`, as its other parameters
are not valid (Core 6.3 Vol 4 Part E, 4.5.1, as erx_hci cites it).

For l2cap and att-op erXos's codec gives an answer, not fields, so the line is
an answer, which erXos's side prints from its codec. What Bumble decides in it
is only what Bumble knows; the rest is the specification's rule, restated here,
so for it the comparison checks erXos against that rule rather than against
Bumble:

  l2cap   `unparsed` for a frame Bumble's parser refuses; `drop` for a code
          Bumble names a response (Command Reject or a name ending in
          _RESPONSE), which is never answered; `reject ID` for any other code,
          answered with Command Reject, ID from Bumble's parse. Bumble decides
          the parse, which codes are responses and where the identifier is;
          that every command is rejected is erx_l2cap's rule (erXos asks for
          nothing and offers no channel), and the line does not show the
          reject's reason.
  att-op  Bumble decides which opcodes have a class and, by the last word of
          its name, whether a server receives it: `takes` for a request, a
          command or a confirmation, `ignores` for a PDU a server sends (a
          response, a notification or an indication). An opcode without a
          class is `ignores` when its Command Flag is set and `refuses` when
          not, ATT's rule for a command and a request a server does not
          support (Core 6.3 Vol 3 Part F, 3.3, as erx_att cites it).

A field of any type the form does not name stops the run: the form would
otherwise compare a repr.
"""

import logging
import sys

from bumble import att, core, hci, l2cap, smp

# Bumble logs a warning for a frame longer than its length says; the comparison
# reads the decoding, not the log.
logging.disable(logging.CRITICAL)

# The fields erx_hci keeps of each event and Command Complete return class, in
# its order; a return's status is not among them, as the line gives it as `ok`
# or `failed STATUS`.
KEPT = {
    "HCI_Command_Status_Event": ("status", "num_hci_command_packets", "command_opcode"),
    "HCI_Disconnection_Complete_Event": ("status", "connection_handle", "reason"),
    "HCI_Encryption_Change_Event": ("status", "connection_handle", "encryption_enabled"),
    "HCI_Encryption_Key_Refresh_Complete_Event": ("status", "connection_handle"),
    "HCI_LE_Connection_Complete_Event": ("connection_handle", "peer_address_type", "peer_address"),
    "HCI_LE_Connection_Update_Complete_Event": ("status", "connection_handle"),
    "HCI_LE_Long_Term_Key_Request_Event": ("connection_handle", "random_number", "encryption_diversifier"),
    "HCI_Read_Local_Version_Information_ReturnParameters":
        ("hci_version", "hci_subversion", "lmp_version", "company_identifier", "lmp_subversion"),
    "HCI_Read_Local_Supported_Commands_ReturnParameters": ("supported_commands",),
    "HCI_LE_Read_Local_Supported_Features_ReturnParameters": ("le_features",),
    "HCI_Read_BD_ADDR_ReturnParameters": ("bd_addr",),
    "HCI_LE_Read_Buffer_Size_ReturnParameters": ("le_acl_data_packet_length", "total_num_le_acl_data_packets"),
    "HCI_Read_Buffer_Size_ReturnParameters": ("hc_acl_data_packet_length", "hc_total_num_acl_data_packets"),
    "HCI_StatusAndConnectionHandleReturnParameters": ("connection_handle",),
    "HCI_StatusReturnParameters": (),
}

# The ATT PDUs a server receives, by the last word of their Bumble class names.
SERVER_RECEIVES = ("Request", "Command", "Confirmation")
# The Attribute Opcode's Command Flag (Core 6.3 Vol 3 Part F, 3.3.1), which Bumble
# does not name; abi/formats/bluetooth.txt holds it as att_command_flag.
COMMAND_FLAG = 0x40


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


def form(code, values):
    return " ".join([code] + [field_text(value) for value in values])


def kept(obj):
    name = type(obj).__name__
    if name not in KEPT:
        raise SystemExit("bumble_decode: no kept fields for %s" % name)
    return [getattr(obj, field) for field in KEPT[name]]


class Unparsed(Exception):
    """Bumble's decoder refused the frame."""


def parsed(decode, frame):
    """Bumble's decoding of frame; any exception its parsing raises is a refusal."""
    try:
        return decode(frame)
    except Exception as error:  # Bumble's decoders raise whatever their parsing meets.
        raise Unparsed() from error


def pdu_line(decode, base, code_attribute, frame):
    """An ATT PDU or SMP command: every field of its class, in declaration order."""
    pdu = parsed(decode, frame)
    code = "%02x" % int(getattr(pdu, code_attribute))
    if type(pdu) is base:
        return "unknown " + code
    # The fields Bumble parses, as its class lists them (hci.py, fields_from_dataclass);
    # a nested list would be a repeated group, which no PDU here has.
    names = [entry[0] for entry in type(pdu).fields if isinstance(entry, tuple)]
    if len(names) != len(type(pdu).fields):
        raise SystemExit("bumble_decode: %s has a repeated group of fields" % type(pdu).__name__)
    return form(code, [getattr(pdu, name) for name in names])


def hci_line(frame):
    packet = bytes([hci.HCI_EVENT_PACKET, frame[0], len(frame) - 1]) + frame[1:]
    event = parsed(hci.HCI_Event.from_bytes, packet)
    if type(event) is hci.HCI_Event:
        return "unknown %02x" % event.event_code
    if type(event) is hci.HCI_LE_Meta_Event:
        return "unknown %02x%02x" % (hci.HCI_LE_META_EVENT, event.subevent_code)
    if isinstance(event, hci.HCI_LE_Meta_Event):
        code = "%02x%02x" % (hci.HCI_LE_META_EVENT, event.subevent_code)
        if isinstance(event, hci.HCI_LE_Connection_Complete_Event) and event.status != hci.HCI_SUCCESS:
            return "%s failed %d" % (code, event.status)
        return form(code, kept(event))
    code = "%02x" % event.event_code
    if isinstance(event, hci.HCI_Command_Complete_Event):
        returned = event.return_parameters
        head = [event.num_hci_command_packets, event.command_opcode]
        if isinstance(returned, hci.HCI_StatusReturnParameters) and returned.status != hci.HCI_SUCCESS:
            return form(code, head) + " failed %d" % returned.status
        return form(code, head) + " " + form("ok", kept(returned))
    # Num_Handles pairs (7.7.19), each handle beside its count.
    if isinstance(event, hci.HCI_Number_Of_Completed_Packets_Event):
        pairs = zip(event.connection_handles, event.num_completed_packets)
        return form(code, [value for pair in pairs for value in pair])
    return form(code, kept(event))


def l2cap_line(frame):
    command = parsed(l2cap.L2CAP_Control_Frame.from_bytes, frame)
    name = l2cap.CommandCode(command.code).name
    if name == "L2CAP_COMMAND_REJECT" or name.endswith("_RESPONSE"):
        return "drop"
    return "reject %d" % command.identifier


def att_op_line(frame):
    (op,) = frame
    pdu_class = att.ATT_PDU.pdu_classes.get(op)
    if pdu_class is None:
        return "ignores" if op & COMMAND_FLAG else "refuses"
    return "takes" if pdu_class.__name__.endswith(SERVER_RECEIVES) else "ignores"


# Each codec's line, and its word for a frame Bumble's decoder refuses.
CODECS = {
    "att": (lambda frame: pdu_line(att.ATT_PDU.from_bytes, att.ATT_PDU, "op_code", frame), "rejected"),
    "smp": (lambda frame: pdu_line(smp.SMP_Command.from_bytes, smp.SMP_Command, "code", frame), "rejected"),
    "hci": (hci_line, "rejected"),
    "l2cap": (l2cap_line, "unparsed"),
    "att-op": (att_op_line, None),
}


def canonical(codec, frame):
    line, refused = CODECS[codec]
    try:
        return line(frame)
    except Unparsed:
        return refused


def main(corpus):
    with open(corpus, encoding="ascii") as lines:
        for line in lines:
            codec, frame = line.split()
            print(canonical(codec, bytes.fromhex(frame)))


if __name__ == "__main__":
    main(sys.argv[1])
