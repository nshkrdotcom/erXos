# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
"""The serial service's peer (docs/design-bluetooth.md, "On QEMU against Bumble").

Started by the Bluetooth suite's harness (tools/lib/erx/bt_domain.rb, Serial)
on Bumble's second controller:

  serial_peer.py TRANSPORT

TRANSPORT is a Bumble transport name, tcp-client:127.0.0.1:PORT. The peer scans
for the advertiser whose advertising data lists nus's UUID (not by name: Bumble's
controller answers a scan request with the advertising data again,
bumble/controller.py:1210-1225, so the scan response's name never reaches it),
connects, exchanges an MTU of MTU_ASKED, finds nus's rx and tx, subscribes to tx's
notifications and writes BYTES pseudo-random octets to rx, each piece a write with
response, then waits until as many octets have come back on tx. It passes when
they are the octets it wrote, in order. The pieces' sizes cycle through 1,
MTU - 3, MTU - 2 and rx's maximum: a piece over MTU - 3 octets goes as a long write
(Prepare and Execute Write, which Bumble's write_value makes of it), so the echo
sends it back in more than one notification and a send that cuts at more than
MTU - 3 octets shows.

Everything the radio sends is bounded before it is kept: at most MAX_REPORTS
advertising reports are looked at, the MTU must lie in ATT's range, each
notification may carry at most MTU - 3 octets and all of them together at most
BYTES. The peer prints one line, `serial passed BYTES MTU` or
`serial failed REASON`, and exits 0 or 1; REASON names counts and offsets only,
never the radio's bytes, so nothing a peer sends reaches the harness's terminal.
"""

import asyncio
import itertools
import random
import sys

from bumble.core import UUID, AdvertisingData, ProtocolError
from bumble.device import Device, Peer
from bumble.hci import Address
from bumble.transport import open_transport

NUS = UUID('6e400001-b5a3-f393-e0a9-e50e24dcca9e')
RX = UUID('6e400002-b5a3-f393-e0a9-e50e24dcca9e')
TX = UUID('6e400003-b5a3-f393-e0a9-e50e24dcca9e')
# rx's declared maximum (abi/gatt/nus.txt): a write carries at most this many octets.
RX_MAX = 244

BYTES = 64 * 1024
# The MTU the peer asks for, below rx's maximum + 3, so the longest pieces need more than
# one notification back and every piece size, MTU - 2 included, fits rx, and ATT's range of MTUs (Core 6.3 Vol 3 Part F, 3.2.8 and
# 3.4.2.2).
MTU_ASKED = 100
MTU_MIN = 23
MTU_MAX = 517
# The peer's own address, a static random one, as Bumble's examples take.
OWN_ADDRESS = 'F0:F1:F2:F3:F4:F5'
MAX_REPORTS = 256
SCAN_SECONDS = 30
CONNECT_SECONDS = 30
# Every byte back after the last write's answer within this long.
DRAIN_SECONDS = 60


class Failed(Exception):
    """The run's one failure path: what went wrong, in counts and offsets."""


class Stream:
    """The octets tx brings back, each notification bounded before it is kept."""

    def __init__(self, limit, piece):
        self.limit = limit
        self.piece = piece
        self.received = bytearray()
        self.fault = None
        self.complete = asyncio.Event()

    def notified(self, value):
        if self.fault is not None:
            return
        if not isinstance(value, (bytes, bytearray)):
            self.fault = 'a notification that is not octets'
        elif len(value) > self.piece:
            self.fault = f'a notification of {len(value)} octets, over MTU - 3 = {self.piece}'
        elif len(self.received) + len(value) > self.limit:
            self.fault = f'more than {self.limit} octets back'
        else:
            self.received.extend(value)
        if self.fault is not None or len(self.received) == self.limit:
            self.complete.set()


async def advertiser(device):
    """The address of the first advertiser among MAX_REPORTS that lists nus."""
    found = asyncio.get_running_loop().create_future()
    seen = 0

    def report(advertisement):
        nonlocal seen
        if found.done():
            return
        seen += 1
        uuids = advertisement.data.get(AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS) or []
        if NUS in uuids:
            found.set_result(advertisement.address)
        elif seen >= MAX_REPORTS:
            found.set_exception(Failed(f'no advertiser lists nus in {seen} reports'))

    device.on('advertisement', report)
    await device.start_scanning(active=False, filter_duplicates=True)
    try:
        return await asyncio.wait_for(found, SCAN_SECONDS)
    except asyncio.TimeoutError:
        raise Failed(f'no advertiser lists nus within {SCAN_SECONDS} s') from None
    finally:
        await device.stop_scanning()


def one_characteristic(service, uuid, name):
    found = service.get_characteristics_by_uuid(uuid)
    if len(found) != 1:
        raise Failed(f'nus has {len(found)} characteristics {name}')
    return found[0]


def first_difference(sent, received):
    return next(index for index, (a, b) in enumerate(zip(sent, received)) if a != b)


async def run(transport):
    async with await open_transport(transport) as hci:
        device = Device.with_hci('serial-peer', Address(OWN_ADDRESS), hci.source, hci.sink)
        await device.power_on()
        address = await advertiser(device)
        connection = await asyncio.wait_for(device.connect(address), CONNECT_SECONDS)
        peer = Peer(connection)
        mtu = await peer.request_mtu(MTU_ASKED)
        if not MTU_MIN <= mtu <= MTU_MAX:
            raise Failed(f'an MTU of {mtu}, outside {MTU_MIN}..{MTU_MAX}')
        services = await peer.discover_service(NUS)
        if len(services) != 1:
            raise Failed(f'{len(services)} services nus')
        await peer.discover_characteristics(service=services[0])
        rx = one_characteristic(services[0], RX, 'rx')
        tx = one_characteristic(services[0], TX, 'tx')

        piece = mtu - 3
        stream = Stream(BYTES, piece)
        await peer.subscribe(tx, stream.notified)
        sent = random.Random(BYTES).randbytes(BYTES)
        sizes = itertools.cycle([1, piece, piece + 1, RX_MAX])
        offset = 0
        while offset < BYTES:
            size = next(sizes)
            await peer.write_value(rx, sent[offset:offset + size], with_response=True)
            offset += size
        try:
            await asyncio.wait_for(stream.complete.wait(), DRAIN_SECONDS)
        except asyncio.TimeoutError:
            raise Failed(f'{len(stream.received)} of {BYTES} octets back within {DRAIN_SECONDS} s') from None
        if stream.fault is not None:
            raise Failed(stream.fault)
        if bytes(stream.received) != sent:
            raise Failed(f'the octets back differ from those sent at offset {first_difference(sent, stream.received)}')
        await asyncio.wait_for(connection.disconnect(), CONNECT_SECONDS)
        return mtu


def main(argv):
    if len(argv) != 2 or not argv[1].startswith('tcp-client:127.0.0.1:'):
        print('usage: serial_peer.py tcp-client:127.0.0.1:PORT', file=sys.stderr)
        return 2
    try:
        mtu = asyncio.run(run(argv[1]))
    except Failed as failure:
        print(f'serial failed {failure}', flush=True)
        return 1
    except ProtocolError as error:
        # Bumble's name for the ATT or HCI error code the radio answered.
        print(f'serial failed the radio answered {error.error_name}', flush=True)
        return 1
    except (asyncio.TimeoutError, ConnectionError) as error:
        print(f'serial failed {type(error).__name__}', flush=True)
        return 1
    print(f'serial passed {BYTES} {mtu}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
