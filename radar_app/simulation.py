"""Deterministic in-memory UART transport for tests; never accesses hardware."""
from __future__ import annotations

import queue
import threading


class SimulatedSerial:
    def __init__(self, command=False, replies=None):
        self.command = command
        self.replies = replies or {}
        self.input = queue.Queue()
        self.closed = False
        self.writes = []
        self.reader_ids = set()

    def feed(self, data):
        self.input.put(data)

    def read(self, size):
        self.reader_ids.add(threading.get_ident())
        if self.closed:
            raise OSError("Simulated USB removed")
        try:
            data = self.input.get(timeout=0.02)
        except queue.Empty:
            return b""
        if isinstance(data, Exception):
            raise data
        if len(data) > size:
            self.input.put(data[size:])
        return data[:size]

    def write(self, data):
        if self.closed:
            raise OSError("Simulated port closed")
        command = data.decode().strip()
        self.writes.append(command)
        if self.command:
            response = self.replies.get(command, command.encode() + b"\r\nDone\r\nmmwDemo:/>")
            if response is not None:
                for chunk in (response[:3], response[3:11], response[11:]):
                    if chunk:
                        self.feed(chunk)
        return len(data)

    def close(self):
        self.closed = True


class SimulatedTransport:
    def __init__(self, replies=None):
        self.command = SimulatedSerial(True, replies)
        self.data = SimulatedSerial()

    def __call__(self, port, baud):
        return self.command if port == "sim-command" else self.data
