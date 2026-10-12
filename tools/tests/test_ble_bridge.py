"""Host-only protocol and duplex/backpressure tests; no radio is claimed."""
from __future__ import annotations

import asyncio
import contextlib
import sys
import unittest
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ble_pc_bridge import Bridge, BridgeFailure, Link
from ble_wire import CREDIT, DATA, HELLO, READY, WINDOW, Decoder, frame, hello, number, read_number


class WireTests(unittest.TestCase):
    def test_full_beacon_at_minimum_mtu_and_sequence_wrap(self):
        decoder, sequence = Decoder(), 0
        beacon = bytes(range(256)) * 16
        value = hello(beacon)
        for offset in range(0, len(value), 17):
            _, decoded = decoder.read(frame(HELLO, sequence, value[offset:offset + 17]))
            sequence += 1
        self.assertEqual(decoded, beacon)
        while sequence < 65538:
            decoder.read(frame(CREDIT, sequence, number(1)))
            sequence += 1
        with self.assertRaises(ValueError):
            decoder.read(frame(DATA, sequence + 1, b"x"))

    def test_bounded_malformed_inputs(self):
        values = (b"", bytes(513), frame(DATA, 0, b"x"), frame(READY, 0, number(1)),
                  frame(HELLO, 0, b"\x10\x01"), frame(HELLO, 0, b"\x00\x01xy"))
        for value in values:
            with self.subTest(value_length=len(value)), self.assertRaises(ValueError):
                Decoder().read(value)
        for amount in (0, 8193):
            with self.assertRaises(ValueError):
                number(amount)
        for length in (0, 4097):
            with self.assertRaises(ValueError):
                hello(bytes(length))


class FakeGattPeer:
    """A serialized, credit-respecting Android peripheral protocol model."""
    def __init__(self, mtu):
        self.mtu_size = mtu
        self.payload_size = min(512, mtu - 3) - 3
        self.decoder = Decoder()
        self.sequence = self.credit = 0
        self.callback = None
        self.received_beacon = None
        self.echo = deque()
        self.max_echo_bytes = 0
        self.max_outstanding_writes = self.outstanding_writes = 0

    async def start_notify(self, _uuid, callback, **_kwargs):
        self.callback = callback
        beacon = hello(b"public-test-peer-beacon")
        for offset in range(0, len(beacon), self.payload_size):
            self.emit(HELLO, beacon[offset:offset + self.payload_size])

    def emit(self, kind, payload):
        self.callback(None, bytearray(frame(kind, self.sequence, payload)))
        self.sequence += 1

    def flush(self):
        while self.echo and len(self.echo[0]) <= self.credit:
            value = self.echo.popleft()
            self.credit -= len(value)
            self.emit(DATA, value)

    async def write_gatt_char(self, _uuid, value, response):
        if not response:
            raise AssertionError("Writes must have ATT responses")
        self.outstanding_writes += 1
        self.max_outstanding_writes = max(self.max_outstanding_writes, self.outstanding_writes)
        try:
            await asyncio.sleep(0)
            kind, payload = self.decoder.read(value)
            if kind == HELLO and payload is not None:
                self.received_beacon = payload
            elif kind == READY:
                self.credit = read_number(payload)
                self.emit(READY, number(WINDOW))
            elif kind == DATA:
                self.echo.append(payload)
                self.max_echo_bytes = max(self.max_echo_bytes, sum(map(len, self.echo)))
                self.emit(CREDIT, number(len(payload)))
                self.flush()
            elif kind == CREDIT:
                self.credit += read_number(payload)
                self.flush()
        finally:
            self.outstanding_writes -= 1


class DuplexTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        # Production asyncio.run uses debug=False. Per-frame debugger stack
        # capture would dominate a 6000-frame minimum-MTU host throughput test.
        asyncio.get_running_loop().set_debug(False)

    async def test_old_client_disconnect_cannot_close_replacement_link(self):
        bridge = Bridge()
        old_client, replacement_client = object(), object()
        replacement = Link(replacement_client, b"public-test-beacon", lambda _: None)
        bridge.link = replacement
        bridge.disconnected(old_client)
        self.assertFalse(replacement.fault.is_set())
        bridge.disconnected(replacement_client)
        self.assertTrue(replacement.fault.is_set())
        self.assertEqual(replacement.reason, "gatt_disconnected")

    async def test_admission_then_large_duplex_stream_at_two_mtus(self):
        for mtu in (23, 517):
            with self.subTest(mtu=mtu):
                fake = FakeGattPeer(mtu)
                endpoint = asyncio.get_running_loop().create_future()
                events = []
                link = None

                def event(value):
                    events.append(value)
                    if value["type"] == "peerDiscovered":
                        self.assertIsNone(link.endpoint)
                        link.admission.set_result(True)
                    elif value["type"] == "endpointReady":
                        endpoint.set_result(value["port"])

                local_beacon = bytes(range(256)) * 16
                link = Link(fake, local_beacon, event)
                running = asyncio.create_task(link.run())
                writer = None
                try:
                    port = await asyncio.wait_for(endpoint, 5)
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    payload = bytes(range(256)) * 400  # 100 KiB, >12 receive windows.
                    received = asyncio.create_task(reader.readexactly(len(payload)))
                    writer.write(payload)
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(received, 30), payload)
                    self.assertEqual(fake.received_beacon, local_beacon)
                    self.assertEqual(fake.max_outstanding_writes, 1)
                    self.assertLessEqual(link.incoming.qsize(), 512)
                    self.assertLessEqual(link.outgoing.qsize(), 128)
                    self.assertTrue(any(item["type"] == "status" for item in events))
                finally:
                    link.fail("test_complete")
                    if writer is not None:
                        writer.close()
                        await writer.wait_closed()
                    with contextlib.suppress(BridgeFailure):
                        await asyncio.wait_for(running, 5)

    async def test_rejected_identity_never_opens_loopback_endpoint(self):
        fake, events = FakeGattPeer(23), []
        link = None

        def event(value):
            events.append(value)
            if value["type"] == "peerDiscovered":
                link.admission.set_result(False)

        link = Link(fake, b"public-test-local-beacon", event)
        with self.assertRaisesRegex(BridgeFailure, "admission_rejected"):
            await asyncio.wait_for(link.run(), 5)
        self.assertIsNone(link.endpoint)
        self.assertFalse(any(value["type"] == "endpointReady" for value in events))

    async def test_unauthorized_data_and_credit_overflow_close_route(self):
        fake = FakeGattPeer(517)
        link = Link(fake, b"public-test-local-beacon", lambda _: None)
        await fake.start_notify(None, link.receive)
        fake.emit(READY, number(WINDOW))
        fake.emit(DATA, b"premature")
        self.assertTrue(link.fault.is_set())
        self.assertEqual(link.incoming.qsize(), 0)

        fake = FakeGattPeer(517)
        link = Link(fake, b"public-test-local-beacon", lambda _: None)
        await fake.start_notify(None, link.receive)
        fake.emit(READY, number(WINDOW))
        fake.emit(CREDIT, number(1))
        self.assertTrue(link.fault.is_set())
        self.assertEqual(link.send_credit, WINDOW)

    async def test_receive_window_bounds_data_when_local_consumer_stalls(self):
        fake = FakeGattPeer(517)
        link = Link(fake, b"public-test-local-beacon", lambda _: None)
        await fake.start_notify(None, link.receive)
        fake.emit(READY, number(WINDOW))
        link.accepted = link.ready_sent = True
        link.receive_credit = WINDOW
        link.writer = object()  # Deliberately stalled: no socket writer task.
        for _ in range(16):
            fake.emit(DATA, bytes(509))
        self.assertFalse(link.fault.is_set())
        self.assertEqual(link.receive_credit, 48)
        fake.emit(DATA, bytes(49))
        self.assertTrue(link.fault.is_set())
        self.assertEqual(link.incoming.qsize(), 16)
        self.assertEqual(sum(map(len, link.incoming._queue)), 8144)


if __name__ == "__main__":
    unittest.main()
