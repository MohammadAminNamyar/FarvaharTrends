"""BLE framing shared by the physical Windows adapter helper and host tests.

No signature or encryption implementation: the Dart peer validates admission
and its existing mutually authenticated TLS runs over the opaque DATA bytes.
"""
from __future__ import annotations

HELLO, DATA, READY, CREDIT = range(1, 5)
MAX_BEACON, WINDOW, MAX_VALUE = 4096, 8192, 512


def frame(kind: int, sequence: int, payload: bytes) -> bytes:
    if kind not in (HELLO, DATA, READY, CREDIT) or len(payload) > MAX_VALUE - 3:
        raise ValueError("Invalid BLE frame")
    return bytes((kind, (sequence >> 8) & 255, sequence & 255)) + payload


def hello(beacon: bytes) -> bytes:
    if not 0 < len(beacon) <= MAX_BEACON:
        raise ValueError("Invalid discovery beacon length")
    return len(beacon).to_bytes(2, "big") + beacon


def number(amount: int) -> bytes:
    if not 0 < amount <= WINDOW:
        raise ValueError("Invalid BLE credit")
    return amount.to_bytes(2, "big")


def read_number(value: bytes) -> int:
    if len(value) != 2:
        raise ValueError("Invalid BLE credit length")
    amount = int.from_bytes(value, "big")
    number(amount)
    return amount


class Decoder:
    def __init__(self) -> None:
        self.sequence = 0
        self.complete = False
        self._hello = bytearray()

    def read(self, value: bytes) -> tuple[int, bytes | None]:
        if not 3 <= len(value) <= MAX_VALUE:
            raise ValueError("Invalid BLE attribute length")
        kind, sequence, payload = value[0], int.from_bytes(value[1:3], "big"), value[3:]
        if sequence != self.sequence:
            raise ValueError("Out-of-order BLE frame")
        self.sequence = (self.sequence + 1) & 65535
        if kind not in (HELLO, DATA, READY, CREDIT):
            raise ValueError("Unknown BLE frame")
        if kind == HELLO:
            if self.complete or not payload or len(self._hello) + len(payload) > MAX_BEACON + 2:
                raise ValueError("Invalid BLE discovery fragment")
            self._hello.extend(payload)
            if len(self._hello) < 2:
                return kind, None
            length = int.from_bytes(self._hello[:2], "big")
            if not 0 < length <= MAX_BEACON or len(self._hello) > length + 2:
                raise ValueError("Invalid BLE discovery length")
            if len(self._hello) < length + 2:
                return kind, None
            self.complete = True
            beacon = bytes(self._hello[2:])
            self._hello.clear()
            return kind, beacon
        if not self.complete:
            raise ValueError("BLE data before discovery")
        if kind == DATA and not payload:
            raise ValueError("Empty BLE data")
        if kind in (READY, CREDIT):
            read_number(payload)
        return kind, payload
