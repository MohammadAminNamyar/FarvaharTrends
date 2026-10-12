"""Physical Windows BLE central -> localhost TCP bridge for the Dart peer.

Run with -B. One JSON command per stdin line, one JSON event per stdout line.
The coordinator must verify peerDiscovered and send accept before TLS starts.
This helper does not authenticate publishers, decrypt TLS, publish news, pair
devices, enable Bluetooth, change the firewall, or use emulator virtual radios.
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import sys
import time
import uuid
from collections import OrderedDict
from typing import Any, Callable

from ble_wire import CREDIT, DATA, HELLO, MAX_BEACON, READY, WINDOW, Decoder, frame, hello, number, read_number

SERVICE = "8af06310-ea52-489e-b259-31f68fbb7045"
RX = "8af06311-ea52-489e-b259-31f68fbb7045"
TX = "8af06312-ea52-489e-b259-31f68fbb7045"


def emit(event: dict[str, Any]) -> None:
    # Only public admission beacons go to the local coordinator. Errors never
    # interpolate backend exception messages, which can contain MAC addresses.
    print(json.dumps({"transport": "bluetooth", **event}, separators=(",", ":")), flush=True)


def beacon_from(command: dict[str, Any]) -> bytes:
    value = command.get("beaconBase64")
    if not isinstance(value, str) or len(value) > 5500:
        raise ValueError("Invalid beacon")
    beacon = base64.b64decode(value, validate=True)
    hello(beacon)
    return beacon


class BridgeFailure(Exception):
    pass


class Link:
    def __init__(self, client: Any, beacon: bytes, output: Callable[[dict[str, Any]], None] = emit) -> None:
        self.client, self.beacon, self.emit = client, beacon, output
        self.route_id = "ble-pc-" + str(uuid.uuid4())
        self.decoder = Decoder()
        self.remote_beacon: bytes | None = None
        self.remote_hello = asyncio.Event()
        self.remote_ready = asyncio.Event()
        self.local_connected = asyncio.Event()
        self.admission: asyncio.Future[bool] = asyncio.get_running_loop().create_future()
        self.fault = asyncio.Event()
        self.reason = "gatt_disconnected"
        self.wake_sender = asyncio.Event()
        self.incoming: asyncio.Queue[bytes] = asyncio.Queue(512)
        self.outgoing: asyncio.Queue[bytes] = asyncio.Queue(128)
        self.payload_size = 17
        self.sequence = self.send_credit = self.receive_credit = self.credit_pending = 0
        self.accepted = self.ready_pending = self.ready_sent = self.closed = False
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.endpoint: asyncio.Server | None = None
        self.tasks: list[asyncio.Task[Any]] = []

    def event(self, kind: str, **values: Any) -> None:
        self.emit({"type": kind, "routeId": self.route_id, **values})

    def fail(self, reason: str) -> None:
        if not self.fault.is_set():
            self.reason = reason
            self.fault.set()
        self.wake_sender.set()

    async def guarded(self, awaitable: Any, timeout: float, reason: str) -> Any:
        task = asyncio.ensure_future(awaitable)
        fault = asyncio.create_task(self.fault.wait())
        try:
            done, _ = await asyncio.wait((task, fault), timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
            if self.fault.is_set():
                raise BridgeFailure(self.reason)
            if task not in done:
                raise BridgeFailure(reason)
            return await task
        finally:
            for pending in (task, fault):
                if not pending.done():
                    pending.cancel()
            await asyncio.gather(task, fault, return_exceptions=True)

    def receive(self, _characteristic: Any, value: bytearray) -> None:
        if self.closed or self.fault.is_set():
            return
        try:
            kind, payload = self.decoder.read(bytes(value))
            if kind == HELLO:
                if payload is not None:
                    self.remote_beacon = payload
                    self.remote_hello.set()
            elif kind == READY:
                if self.remote_ready.is_set():
                    raise ValueError("Duplicate BLE ready")
                self.send_credit = read_number(payload)
                self.remote_ready.set()
                self.wake_sender.set()
            elif kind == CREDIT:
                if not self.remote_ready.is_set():
                    raise ValueError("BLE credit before ready")
                amount = read_number(payload)
                if self.send_credit + amount > WINDOW:
                    raise ValueError("BLE credit overflow")
                self.send_credit += amount
                self.wake_sender.set()
            else:
                if (not self.accepted or not self.ready_sent or not self.remote_ready.is_set()
                        or self.writer is None or len(payload) > self.receive_credit):
                    raise ValueError("BLE data before ready or window exceeded")
                self.incoming.put_nowait(payload)
                self.receive_credit -= len(payload)
        except (ValueError, asyncio.QueueFull):
            self.fail("malformed_ble_frame")

    async def send(self, kind: int, payload: bytes) -> None:
        value = frame(kind, self.sequence, payload)
        self.sequence += 1
        await self.guarded(self.client.write_gatt_char(RX, value, response=True), 20, "gatt_write_timeout")

    async def sender(self) -> None:
        try:
            value = hello(self.beacon)
            for offset in range(0, len(value), self.payload_size):
                await self.send(HELLO, value[offset:offset + self.payload_size])
            pending: bytes | None = None
            while not self.closed and not self.fault.is_set():
                self.wake_sender.clear()
                if self.ready_pending and not self.ready_sent:
                    self.ready_sent = True
                    self.receive_credit = WINDOW
                    await self.send(READY, number(WINDOW))
                    continue
                if self.credit_pending:
                    amount, self.credit_pending = self.credit_pending, 0
                    self.receive_credit += amount
                    await self.send(CREDIT, number(amount))
                    continue
                if self.accepted and self.ready_sent and self.remote_ready.is_set():
                    if pending is None:
                        with contextlib.suppress(asyncio.QueueEmpty):
                            pending = self.outgoing.get_nowait()
                    if pending is not None and len(pending) <= self.send_credit:
                        self.send_credit -= len(pending)
                        await self.send(DATA, pending)
                        pending = None
                        continue
                await self.wake_sender.wait()
        except asyncio.CancelledError:
            raise
        except Exception:
            self.fail("gatt_send_failed")

    async def on_local(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self.closed or self.writer is not None:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            return
        self.reader, self.writer = reader, writer
        writer.transport.set_write_buffer_limits(high=WINDOW, low=WINDOW // 2)
        if self.endpoint is not None:
            self.endpoint.close()
        self.local_connected.set()

    async def read_tcp(self) -> None:
        try:
            while not self.closed:
                value = await self.reader.read(self.payload_size)
                if not value:
                    break
                await self.outgoing.put(value)
                self.wake_sender.set()
        except asyncio.CancelledError:
            raise
        except Exception:
            pass
        self.fail("local_stream_closed")

    async def write_tcp(self) -> None:
        try:
            while not self.closed:
                value = await self.incoming.get()
                self.writer.write(value)
                await self.guarded(self.writer.drain(), 20, "local_write_timeout")
                self.credit_pending += len(value)
                self.wake_sender.set()
        except asyncio.CancelledError:
            raise
        except Exception:
            self.fail("local_stream_closed")

    async def run(self) -> None:
        try:
            await self.guarded(self.client.start_notify(TX, self.receive, force_indicate=True), 20, "gatt_subscribe_timeout")
            # Use the negotiated WinRT MTU, never an assumed 517-byte request.
            self.payload_size = max(17, min(512, self.client.mtu_size - 3) - 3)
            self.tasks.append(asyncio.create_task(self.sender()))
            await self.guarded(self.remote_hello.wait(), 90, "discovery_timeout")
            self.event("peerDiscovered", role="central", beaconBase64=base64.b64encode(self.remote_beacon).decode("ascii"))
            admitted = await self.guarded(asyncio.shield(self.admission), 30, "admission_timeout")
            if not admitted:
                raise BridgeFailure("admission_rejected")
            self.accepted = self.ready_pending = True
            self.wake_sender.set()
            await self.guarded(self.remote_ready.wait(), 30, "remote_admission_timeout")
            self.endpoint = await asyncio.start_server(self.on_local, "127.0.0.1", 0, limit=WINDOW)
            port = self.endpoint.sockets[0].getsockname()[1]
            self.event("endpointReady", host="127.0.0.1", port=port,
                       beaconBase64=base64.b64encode(self.remote_beacon).decode("ascii"))
            await self.guarded(self.local_connected.wait(), 30, "local_endpoint_timeout")
            self.tasks.extend((asyncio.create_task(self.read_tcp()), asyncio.create_task(self.write_tcp())))
            self.event("status", state="connected", running=True, gattPayloadBytes=self.payload_size, physicalAdapter=True)
            try:
                await asyncio.wait_for(self.fault.wait(), 180)
                raise BridgeFailure(self.reason)
            except asyncio.TimeoutError:
                raise BridgeFailure("session_rotation") from None
        except BridgeFailure as error:
            self.reason = str(error)
            raise
        finally:
            await self.close()

    async def close(self) -> None:
        self.closed = True
        self.wake_sender.set()
        if self.endpoint is not None:
            self.endpoint.close()
        if self.writer is not None:
            self.writer.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.writer.wait_closed(), 2)
        if self.endpoint is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.endpoint.wait_closed(), 2)
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)


class Bridge:
    def __init__(self) -> None:
        self.beacon = b""
        self.runner: asyncio.Task[None] | None = None
        self.link: Link | None = None
        self.retry_after: OrderedDict[str, float] = OrderedDict()
        self.state: dict[str, Any] = {"type": "status", "state": "stopped", "running": False, "physicalAdapter": True}

    def status(self, state: str, **extra: Any) -> None:
        self.state = {"type": "status", "state": state, "running": self.runner is not None,
                      "physicalAdapter": True, "role": "central", "maxLinks": 1, **extra}
        emit(self.state)

    def disconnected(self, client: Any) -> None:
        # A delayed WinRT callback from a previous scan/connection must not
        # resolve through a loop variable now referring to the replacement link.
        current = self.link
        if current is not None and current.client is client:
            current.fail("gatt_disconnected")

    async def configure(self, beacon: bytes) -> None:
        await self.stop()
        self.beacon = beacon
        self.runner = asyncio.create_task(self.run())

    async def stop(self) -> None:
        runner, self.runner = self.runner, None
        if runner is not None:
            runner.cancel()
            await asyncio.gather(runner, return_exceptions=True)
        self.status("stopped")

    async def run(self) -> None:
        try:
            from bleak import BleakClient, BleakScanner
            from bleak.exc import BleakBluetoothNotAvailableError
        except ImportError:
            self.status("dependency_missing", detail="Install the project-local pinned BLE dependencies")
            return
        while True:
            device = None
            backoff = 2
            try:
                if self.state.get("state") not in ("bluetooth_off", "permission_required", "unsupported"):
                    self.status("discovering")
                device = await BleakScanner.find_device_by_filter(
                    lambda candidate, advertisement: SERVICE in advertisement.service_uuids
                    and self.retry_after.get(candidate.address, 0) <= time.monotonic(),
                    timeout=10, service_uuids=[SERVICE], scanning_mode="active")
                if device is None:
                    self.status("discovering")
                    continue
                self.status("connecting")
                current: Link | None = None

                client = BleakClient(device, disconnected_callback=self.disconnected,
                                     services=[SERVICE], timeout=30, pair=False,
                                     winrt={"use_cached_services": False})
                try:
                    await asyncio.wait_for(client.connect(), 35)
                    current = Link(client, self.beacon)
                    self.link = current
                    await current.run()
                finally:
                    if current is not None:
                        await current.close()
                        current.event("endpointLost", reason=current.reason)
                    self.link = None
                    with contextlib.suppress(Exception):
                        await asyncio.wait_for(client.disconnect(), 10)
            except asyncio.CancelledError:
                raise
            except BridgeFailure as error:
                self.status("retrying", detail=str(error))
            except BleakBluetoothNotAvailableError as error:
                reason = error.reason.name
                state = ("bluetooth_off" if reason == "POWERED_OFF" else
                         "unsupported" if reason in ("NO_BLUETOOTH", "NO_BLE_CENTRAL_ROLE") else
                         "permission_required" if reason.startswith("DENIED_") else "unavailable")
                self.status(state, detail=reason)
                backoff = 15
            except Exception as error:
                # Backend errors often contain identifiers. Export type only.
                self.status("scan_or_connect_failed", detail=type(error).__name__)
            finally:
                if device is not None:
                    self.retry_after[device.address] = time.monotonic() + 15
                    while len(self.retry_after) > 64:
                        self.retry_after.popitem(last=False)
            await asyncio.sleep(backoff)

    async def command(self, command: dict[str, Any]) -> bool:
        kind = command.get("type")
        if kind == "configure":
            await self.configure(beacon_from(command))
        elif kind == "updateBeacon":
            self.beacon = beacon_from(command)
        elif kind in ("accept", "reject"):
            current = self.link
            if current is not None and command.get("routeId") == current.route_id:
                if kind == "reject":
                    current.fail("admission_rejected")
                if not current.admission.done():
                    current.admission.set_result(kind == "accept")
        elif kind == "snapshot":
            emit(self.state)
        elif kind == "stop":
            await self.stop()
            return False
        else:
            raise ValueError("Unknown command")
        return True


async def main() -> None:
    bridge = Bridge()
    bridge.status("ready", detail="Physical Windows BLE adapter; central mode only")
    try:
        while True:
            raw = await asyncio.to_thread(sys.stdin.buffer.readline, 16385)
            if not raw:
                break
            if len(raw) > 16384:
                bridge.status("command_error", detail="Command exceeds size limit")
                break
            try:
                command = json.loads(raw)
                if not isinstance(command, dict) or not await bridge.command(command):
                    break
            except (ValueError, TypeError, UnicodeDecodeError):
                bridge.status("command_error", detail="Invalid control command")
    finally:
        await bridge.stop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
