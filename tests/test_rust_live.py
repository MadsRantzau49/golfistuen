"""Hardware-free live Rust service check using two emulated serial UARTs (Linux)."""
import json
import math
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest


@unittest.skipUnless(sys.platform.startswith("linux"), "Serial emulation uses Linux PTYs")
class RustLiveTest(unittest.TestCase):
    def test_live_serial_to_game_protocol(self):
        import pty

        root = Path(__file__).resolve().parents[1]
        subprocess.run(["cargo", "build", "--manifest-path", str(root / "radar_app/Cargo.toml")],
                       check=True, capture_output=True)
        cli_master, cli_slave = pty.openpty()
        data_master, data_slave = pty.openpty()
        started = threading.Event()
        stop = threading.Event()

        def emulate_cli():
            buffer = b""
            while not stop.is_set():
                if not select.select([cli_master], [], [], 0.05)[0]:
                    continue
                buffer += os.read(cli_master, 4096)
                while b"\n" in buffer:
                    command, buffer = buffer.split(b"\n", 1)
                    os.write(cli_master, b"\r\nDone\r\nmmwDemo:/>")
                    if command.strip() == b"sensorStart":
                        started.set()

        worker = threading.Thread(target=emulate_cli, daemon=True)
        worker.start()
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        process = subprocess.Popen([
            str(root / "radar_app/target/debug/radar_app"), "live",
            str(root / "radar_app/configs/golf.cfg"), os.ttyname(cli_slave),
            os.ttyname(data_slave), f"127.0.0.1:{port}",
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        game = None
        frame = 0
        incoming = b""
        messages = []

        def send_frame(point=None):
            nonlocal frame
            frame += 1
            size = 64 if point else 40
            packet = bytearray(size)
            packet[:8] = bytes([2, 1, 4, 3, 6, 5, 8, 7])
            struct.pack_into("<I", packet, 12, size)
            struct.pack_into("<I", packet, 20, frame)
            if point:
                struct.pack_into("<I", packet, 28, 1)
                struct.pack_into("<I", packet, 32, 1)
                struct.pack_into("<IIffff", packet, 40, 1, 16, *point)
            # Exercise UART read fragmentation too.
            os.write(data_master, packet[:13])
            os.write(data_master, packet[13:])
            time.sleep(0.02)

        def receive_until(predicate, stream=True, timeout=3):
            nonlocal incoming
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if stream:
                    send_frame()
                if select.select([game], [], [], 0.03)[0]:
                    incoming += game.recv(65536)
                while b"\n" in incoming:
                    line, incoming = incoming.split(b"\n", 1)
                    message = json.loads(line)
                    messages.append(message)
                    if predicate(message):
                        return message
            self.fail(f"No expected live event; received {messages}")

        def arm(token):
            game.sendall((json.dumps({"type": "ready", "ready": True, "arm_id": token}) + "\n").encode())
            receive_until(lambda message: message.get("arm_id") == token and message["type"] == "status")

        try:
            self.assertTrue(started.wait(8), "Rust uploads the CFG and starts the emulated sensor")
            game = socket.create_connection(("127.0.0.1", port), timeout=3)
            status = receive_until(lambda message: message["type"] == "status", stream=False)
            self.assertFalse(status["radar_ready"], "A socket alone must not imply radar readiness")
            os.write(data_master, b"serial startup noise")
            receive_until(lambda message: message.get("radar_ready") is True)
            arm("turn-1")
            for index in range(3):
                send_frame((0.0, 1.0 + index * 0.2, index * 0.1, 10.0))
            event = receive_until(lambda message: message["type"] == "shot")
            self.assertEqual(event["arm_id"], "turn-1")
            shot = event["shot"]
            self.assertAlmostEqual(shot["speed_mps"], math.sqrt(125), places=3)
            self.assertGreater(shot["elevation_deg"], 0)
            self.assertEqual(shot["spin_rpm"], 0)
            # A delayed ready heartbeat for a consumed arm must not arm again.
            game.sendall(b'{"type":"ready","ready":true,"arm_id":"turn-1"}\n')
            receive_until(lambda message: message["type"] == "status" and message.get("arm_id") is None)
            for index in range(3):
                send_frame((0.0, 1.0 + index * 0.2, 0.0, 10.0))
            before = sum(message["type"] == "shot" for message in messages)
            receive_until(lambda message: message["type"] == "status")
            self.assertEqual(sum(message["type"] == "shot" for message in messages), before)
            arm("turn-2")
            for index in range(3):
                send_frame((0.0, 1.0 + index * 0.3, 0.0, 15.0))
            second = receive_until(lambda message: message["type"] == "shot")
            self.assertNotEqual(second["shot"]["shot_id"], shot["shot_id"])
            self.assertEqual(second["arm_id"], "turn-2")
            arm("turn-3")
            receive_until(lambda message: message.get("radar_ready") is False, stream=False)
            self.assertIsNone(messages[-1]["arm_id"], "Frame timeout disarms the detector")
        finally:
            if game:
                game.close()
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            stop.set()
            worker.join(timeout=1)
            for descriptor in (cli_master, cli_slave, data_master, data_slave):
                os.close(descriptor)
            if process.returncode not in (-15, 0):
                self.fail(f"Rust live service failed: {stdout}\n{stderr}")


if __name__ == "__main__":
    unittest.main()
