"""One reader per UART, one serialized operation queue, backend-owned capture."""
from __future__ import annotations

import re
import threading
import time
from collections import deque

import serial
from serial.tools import list_ports

from .configuration import apply_commands, validate
from .decoding import StreamDecoder
from .storage import SessionStore, now

PROMPT = re.compile(r"(?:mmwDemo|[A-Za-z0-9_]*Demo):\s*/?\s*>", re.I)
ERROR = re.compile(r"\b(?:error|exception|failed|failure|not recognized|invalid command)\b", re.I)


class CommandFailure(ValueError):
    def __init__(self, command, response, reason):
        super().__init__(f"{reason}: {command}\nResponse: {response or '(no response)'}")
        self.command, self.response = command, response


def serial_error(exc):
    return (f"{exc}. Close TI Visualizer and other serial programs; verify the selected USB ports. "
            "For Permission denied, check membership in the Ubuntu dialout group and log out/in after changing it; the app never changes permissions.")


class RadarService:
    def __init__(self, store: SessionStore, transport_factory=None, command_timeout=3.0):
        self.store = store
        self.factory = transport_factory or self._open_serial
        self.command_timeout = command_timeout
        self.operation = threading.Lock()
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.stop_event = threading.Event()
        self.command_port = self.data_port = None
        self.threads = []
        self.state = "disconnected"
        self.connection = {}
        self.applied_text = None
        self.applied_summary = None
        self.console = deque(maxlen=800)
        self.console_seq = 0
        self.recent = deque(maxlen=500)
        self.decoder = StreamDecoder()
        self.response = None
        self.last_rx = 0.0
        self.last_frame_wall = None
        self.frame_walls = deque(maxlen=100)
        self.fault = None
        self.failed_command = None
        self.progress = None

    @staticmethod
    def _open_serial(port, baud):
        # Set inactive handshakes before opening, rather than pyserial's default
        # active RTS/DTR. Never pulse lines or change them on an open device.
        uart = serial.Serial(port=None, baudrate=baud, timeout=0.1, write_timeout=1, exclusive=True)
        uart.dtr = False
        uart.rts = False
        uart.port = port
        uart.open()
        return uart

    @staticmethod
    def ports():
        return [dict(device=p.device, description=p.description, manufacturer=p.manufacturer,
                     serial_number=p.serial_number, hwid=p.hwid) for p in list_ports.comports()]

    def log(self, text):
        entry = f"{now()} {text}"
        with self.lock:
            self.console_seq += 1
            self.console.append(dict(seq=self.console_seq, text=entry))
        self.store.console(entry)

    def connect(self, command_port, data_port, command_baud=115200, data_baud=921600):
        with self.operation:
            if self.command_port is not None or self.data_port is not None:
                raise ValueError("Disconnect the current connection first.")
            if command_port == data_port:
                raise ValueError("Choose separate command and data UARTs.")
            if self.factory == self._open_serial:
                available = {p["device"] for p in self.ports()}
                if command_port not in available or data_port not in available:
                    raise ValueError("Choose ports from the current serial-port list, then refresh if USB was reconnected.")
            try:
                self.command_port = self.factory(command_port, command_baud)
                self.data_port = self.factory(data_port, data_baud)
            except (OSError, serial.SerialException) as exc:
                for port in (self.command_port, self.data_port):
                    if port:
                        port.close()
                self.command_port = self.data_port = None
                self.state, self.fault = "faulted", serial_error(exc)
                raise ValueError(self.fault) from exc
            with self.lock:
                self.connection = dict(command_port=command_port, data_port=data_port,
                                       command_baud=command_baud, data_baud=data_baud, connected_at=now())
                self.applied_text = self.applied_summary = None
                self.failed_command = self.fault = None
                self.stop_event.clear()
                self.recent.clear()
                self.frame_walls.clear()
                self.last_frame_wall = None
                self.decoder = StreamDecoder()
                self.state = "connected/state unknown"
            self.threads = [threading.Thread(target=self._command_reader, name="radar-command-reader", daemon=True),
                            threading.Thread(target=self._data_reader, name="radar-data-reader", daemon=True)]
            for thread in self.threads:
                thread.start()
            self.log("Connected. Sensor state is unknown until a successful operation. Reapply CFG for this connection before recording.")
            return self.status()

    def _command_reader(self):
        port = self.command_port
        try:
            while not self.stop_event.is_set():
                chunk = port.read(4096)
                if chunk:
                    text = chunk.decode("utf-8", errors="replace")
                    self.log("RX " + text)
                    with self.condition:
                        self.last_rx = time.monotonic()
                        if self.response is not None:
                            self.response = (self.response + text)[-65536:]
                        self.condition.notify_all()
        except Exception as exc:
            if not self.stop_event.is_set():
                self._fault(serial_error(exc))

    def _data_reader(self):
        port = self.data_port
        try:
            while not self.stop_event.is_set():
                chunk = port.read(65536)
                if chunk:
                    # Disk capture precedes display decoding and does not involve the browser.
                    self.store.write(chunk)
                    with self.lock:
                        frames = self.decoder.feed(chunk)
                        self.recent.extend(frames)
                        if frames:
                            self.last_frame_wall = time.monotonic()
                            for _ in frames:
                                self.frame_walls.append(self.last_frame_wall)
        except Exception as exc:
            if not self.stop_event.is_set():
                self._fault(serial_error(exc))

    def _fault(self, message):
        with self.condition:
            self.fault = message
            self.state = "faulted"
            self.applied_text = self.applied_summary = None
            self.stop_event.set()
            self.condition.notify_all()
        for port in (self.command_port, self.data_port):
            if port:
                try:
                    port.close()
                except OSError:
                    pass
        try:
            self.store.stop(message)
        except OSError:
            # Startup recovery handles metadata that the disk cannot accept now.
            pass

    def _send(self, command):
        self.log("TX " + command)
        deadline = time.monotonic() + self.command_timeout
        with self.condition:
            # Drain an initial prompt/previous response without a competing read.
            while self.last_rx and time.monotonic() - self.last_rx < 0.08:
                self.condition.wait(0.02)
                if time.monotonic() > deadline:
                    raise CommandFailure(command, "", "Command console did not become idle")
            if self.stop_event.is_set() or self.command_port is None:
                raise CommandFailure(command, "", "Radar is disconnected")
            self.response = ""
            try:
                payload = (command + "\n").encode("ascii")
                if self.command_port.write(payload) != len(payload):
                    raise CommandFailure(command, self.response, "Incomplete command UART write")
                while True:
                    response = self.response
                    # Strip echoed commands so names/arguments never count as acknowledgements.
                    cleaned = "\n".join(line for line in response.replace("\r", "").split("\n")
                                        if PROMPT.sub("", line).strip() != command)
                    if ERROR.search(cleaned):
                        raise CommandFailure(command, response, "Radar rejected command; antenna/open-configuration changes may require a physical reset")
                    if self.stop_event.is_set():
                        raise CommandFailure(command, response, self.fault or "Disconnected")
                    if PROMPT.search(cleaned) or (re.search(r"\bDone\b", cleaned) and time.monotonic() - self.last_rx >= 0.15):
                        return response
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise CommandFailure(command, response, "Command timeout; check UART selection and baud rate")
                    self.condition.wait(min(remaining, 0.05))
            finally:
                self.response = None

    def apply(self, text):
        summary = validate(text)
        rows = apply_commands(text)
        if not self.operation.acquire(blocking=False):
            raise ValueError("Another radar operation is running; wait for it to finish.")
        try:
            if self.store.status():
                raise ValueError("Stop recording before changing radar configuration. The recording must retain one immutable CFG.")
            if self.command_port is None or self.stop_event.is_set():
                raise ValueError("Connect both UARTs before applying a CFG.")
            previous = self.applied_summary
            if previous and previous["open_configuration"] != summary["open_configuration"]:
                self.log("Open configuration changed. A physical board reset may be required; flushCfg does not reset hardware.")
            with self.lock:
                self.state = "applying configuration"
                self.applied_text = self.applied_summary = None
                self.failed_command = self.fault = None
            try:
                for i, command in enumerate(rows):
                    with self.lock:
                        self.progress = dict(current=i + 1, total=len(rows), command=command)
                    self._send(command)
                with self.lock:
                    self.applied_text, self.applied_summary = text, summary
                    self.state = "measuring" if rows[-1].split()[0] == "sensorStart" else "configured"
                    self.decoder = StreamDecoder(summary["frame_period_ms"])
                    self.recent.clear()
                    self.frame_walls.clear()
            except Exception as exc:
                with self.lock:
                    self.state, self.fault = "faulted", str(exc)
                    self.failed_command = dict(command=getattr(exc, "command", self.progress["command"]), response=getattr(exc, "response", ""))
                raise
            finally:
                self.progress = None
            self.log("Configuration successfully applied; immutable recording snapshot is now available.")
            return self.status()
        finally:
            self.operation.release()

    def sensor(self, start):
        if not self.operation.acquire(blocking=False):
            raise ValueError("Wait for the current radar operation to finish.")
        try:
            if self.command_port is None or self.stop_event.is_set():
                raise ValueError("Connect the radar first.")
            if self.store.status():
                raise ValueError("Stop recording before starting or stopping the sensor.")
            if start and not self.applied_text:
                raise ValueError("Apply a CFG successfully on this connection first.")
            try:
                self._send("sensorStart 0" if start else "sensorStop")
                self.state = "measuring" if start else ("configured" if self.applied_text else "connected/state unknown")
                self.fault = None
            except Exception as exc:
                self.state, self.fault = "faulted", str(exc)
                self.applied_text = self.applied_summary = None
                self.failed_command = dict(command=getattr(exc, "command", ""), response=getattr(exc, "response", ""))
                raise
            return self.status()
        finally:
            self.operation.release()

    def start_recording(self, label, notes):
        if not self.operation.acquire(blocking=False):
            raise ValueError("Wait for the current radar operation to finish.")
        try:
            with self.lock:
                if not self.applied_text or self.state != "measuring" or self.stop_event.is_set():
                    raise ValueError("Successfully apply a known CFG on this connection and start the sensor before recording.")
                text, connection = self.applied_text, self.connection.copy()
                console = [c["text"] for c in self.console]
                # Keep a fault/disconnect from racing session creation.
                return self.store.start(label, notes, text, connection, console)
        finally:
            self.operation.release()

    def disconnect(self, reason="Radar disconnected by user"):
        with self.operation:
            self.stop_event.set()
            with self.condition:
                self.condition.notify_all()
            for port in (self.command_port, self.data_port):
                if port:
                    try:
                        port.close()
                    except OSError:
                        pass
            for thread in self.threads:
                if thread is not threading.current_thread():
                    thread.join(timeout=2)
            self.store.stop(reason)
            with self.lock:
                self.command_port = self.data_port = None
                self.applied_text = self.applied_summary = None
                self.state = "disconnected"
            return self.status()

    def status(self):
        recording = self.store.status()
        with self.lock:
            walls = self.frame_walls
            fps = (len(walls) - 1) / (walls[-1] - walls[0]) if len(walls) > 1 and walls[-1] > walls[0] else 0
            age = time.monotonic() - self.last_frame_wall if self.last_frame_wall else None
            return dict(state=self.state, connected=self.command_port is not None and not self.stop_event.is_set(),
                        connection=self.connection, configuration_known=self.applied_text is not None,
                        configuration_hash=self.applied_summary["configuration_hash"] if self.applied_summary else None,
                        configuration=self.applied_summary, recording=recording, last_recording=self.store.last_recording,
                        fault=self.fault, failed_command=self.failed_command, progress=self.progress,
                        frame_rate_hz=fps if age is not None and age < 2 else 0,
                        last_frame_age_s=age, health=self.decoder.health(), console=list(self.console))

    def live(self):
        with self.lock:
            return dict(frames=list(self.recent), config=self.applied_summary, cfg_text=self.applied_text or "",
                        diagnostics=dict(self.decoder.diagnostics))
