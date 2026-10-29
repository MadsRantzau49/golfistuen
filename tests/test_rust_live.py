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
import tempfile
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
        log_root = tempfile.TemporaryDirectory(prefix="rust-live-logs-")
        process = subprocess.Popen([
            str(root / "radar_app/target/debug/radar_app"), "live",
            str(root / "radar_app/configs/golf.cfg"), os.ttyname(cli_slave),
            os.ttyname(data_slave), f"127.0.0.1:{port}",
            str(root / "radar_app/configs/swing.json"),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "RADAR_LOG_DIR": log_root.name})
        game = None
        frame = 0
        incoming = b""
        messages = []
        sent_bytes = bytearray()
        debug_mode = False
        last_debug_heartbeat = 0.0

        def send_frame(point=None):
            nonlocal frame
            frame += 1
            points = [] if point is None else ([point] if isinstance(point[0], (int, float)) else point)
            size = 48 + 16 * len(points) if points else 40
            packet = bytearray(size)
            packet[:8] = bytes([2, 1, 4, 3, 6, 5, 8, 7])
            struct.pack_into("<I", packet, 12, size)
            struct.pack_into("<I", packet, 20, frame)
            if points:
                struct.pack_into("<I", packet, 28, len(points))
                struct.pack_into("<I", packet, 32, 1)
                struct.pack_into("<II", packet, 40, 1, 16 * len(points))
                for index, point in enumerate(points):
                    struct.pack_into("<ffff", packet, 48 + 16 * index, *point)
            # Exercise UART read fragmentation too.
            os.write(data_master, packet[:13])
            os.write(data_master, packet[13:])
            sent_bytes.extend(packet)
            time.sleep(0.02)

        def receive_until(predicate, stream=True, timeout=3):
            nonlocal incoming, last_debug_heartbeat
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if debug_mode and time.monotonic() - last_debug_heartbeat > 1:
                    game.sendall(b'{"type":"debug_subscribe","enabled":true}\n')
                    last_debug_heartbeat = time.monotonic()
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

        def send_hit(speed):
            club_speed = speed * 0.7
            origin = 1.0
            period = 0.02
            for index in range(7):
                send_frame((0.0, origin + club_speed * index * period, 0.0, club_speed))
            launch_y = origin + club_speed * 7 * period
            deceleration = club_speed / (10 * period)
            for index in range(8):
                t = index * period
                club_y = launch_y + club_speed * t - deceleration * t * t / 2
                ball = (0.0, launch_y + speed * t, 3 * t - 9.80665 * t * t / 2)
                radial = (ball[1] * speed + ball[2] * (3 - 9.80665 * t)) / math.hypot(ball[1], ball[2])
                send_frame([(0.0, club_y, 0.0, club_speed - deceleration * t), (*ball, radial)])

        try:
            self.assertTrue(started.wait(8), "Rust uploads the CFG and starts the emulated sensor")
            game = socket.create_connection(("127.0.0.1", port), timeout=3)
            status = receive_until(lambda message: message["type"] == "status", stream=False)
            self.assertFalse(status["radar_ready"], "A socket alone must not imply radar readiness")
            os.write(data_master, b"serial startup noise")
            sent_bytes.extend(b"serial startup noise")
            receive_until(lambda message: message.get("radar_ready") is True)
            arm("turn-1")
            # A practice swing used to produce a false shot by itself.
            for index in range(3):
                send_frame((0.0, 1.0 + index * 0.2, index * 0.1, 10.0))
            swing = receive_until(lambda message: message["type"] == "detection"
                                  and message["state"] == "swing_detected")
            self.assertEqual(swing["arm_id"], "turn-1")
            receive_until(lambda message: message["type"] == "detection"
                          and message["state"] == "no_ball_detected")
            self.assertFalse(any(message["type"] == "shot" for message in messages))
            status = receive_until(lambda message: message["type"] == "status"
                                   and message.get("detection_state") == "no_ball_detected")
            self.assertEqual(status["arm_id"], "turn-1", "A miss must keep the same turn ready")
            send_hit(15.0)
            event = receive_until(lambda message: message["type"] == "shot")
            self.assertEqual(event["arm_id"], "turn-1")
            shot = event["shot"]
            self.assertAlmostEqual(shot["speed_mps"], math.hypot(15, 3), delta=0.5)
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
            send_hit(12.0)
            second = receive_until(lambda message: message["type"] == "shot")
            self.assertNotEqual(second["shot"]["shot_id"], shot["shot_id"])
            self.assertEqual(second["arm_id"], "turn-2")
            arm("turn-3")
            receive_until(lambda message: message.get("radar_ready") is False, stream=False)
            self.assertIsNone(messages[-1]["arm_id"], "Frame timeout disarms the detector")
            # A reconnect/disconnect must retain a partial attempt as aborted.
            receive_until(lambda message: message.get("radar_ready") is True)
            arm("turn-4")
            send_frame((0.0, 1.5, 0.0, 10.0))
            receive_until(lambda message: message["type"] == "detection"
                          and message["state"] == "swing_detected")
            game.close()
            game = None
            time.sleep(0.15)
            # Recording continues even without a connected game.
            send_frame((0.0, 1.6, 0.0, 10.0))
            time.sleep(0.1)
            # The instrument mode captures every raw point and keeps detecting
            # successive attempts without consuming gameplay turns.
            game = socket.create_connection(("127.0.0.1", port), timeout=3)
            incoming = b""
            debug_mode = True
            debug_start = len(messages)
            info = receive_until(lambda message: message["type"] == "debug_info")
            self.assertIn("sensor", info["configuration"])
            background = [(index * 0.001, 1.0, 0.0, 0.0) for index in range(193)]
            send_frame(background)
            number = frame
            receive_until(lambda message: message["type"] == "debug_frame"
                          and message["diagnostics"]["frame_number"] == number
                          and message["part"] == message["parts"] - 1)
            parts = [message for message in messages[debug_start:] if message["type"] == "debug_frame"
                     and message["diagnostics"]["frame_number"] == number]
            self.assertEqual(len(parts), 4)
            self.assertEqual(sum(len(part["diagnostics"]["points"]) for part in parts), 193,
                             "Background/person/club returns must not be filtered from the debug movie")
            for index in range(3):
                send_frame((0.0, 1.0 + index * 0.2, 0.0, 10.0))
            receive_until(lambda message: message["type"] == "debug_attempt_end" and message["source"] == "live"
                          and message["attempt_id"] == 1)
            send_hit(15.0)
            receive_until(lambda message: message["type"] == "debug_attempt_end" and message["source"] == "live"
                          and message["attempt_id"] == 2)
            for _ in range(8):
                send_frame()
            send_hit(12.0)
            receive_until(lambda message: message["type"] == "debug_attempt_end" and message["source"] == "live"
                          and message["attempt_id"] == 3)
            reports = [message["report"] for message in messages[debug_start:]
                       if message["type"] == "debug_attempt_begin" and message["source"] == "live"]
            self.assertEqual([report["outcome"] for report in reports],
                             ["no_ball_detected", "ball_detected", "ball_detected"])
            self.assertFalse(any(message["type"] == "shot" for message in messages[debug_start:]),
                             "The diagnostic mode must not deliver gameplay strokes")
            latest = next(message for message in reversed(messages) if message["type"] == "debug_frame"
                          and message["source"] == "live")
            mark = {"outcome": "operator_mark", "operator_label": "ball_hit", "operator_note": "integration label",
                    "start_frame": latest["diagnostics"]["frame_number"],
                    "end_frame": latest["diagnostics"]["frame_number"],
                    "start_time_s": latest["time_s"], "end_time_s": latest["time_s"]}
            game.sendall((json.dumps({"type": "debug_mark", "session_id": info["session_id"],
                                     "request_id": "mark", "report": mark}) + "\n").encode())
            receive_until(lambda message: message["type"] == "debug_marked")
            game.sendall(b'{"type":"debug_sessions","request_id":"sessions"}\n')
            sessions = receive_until(lambda message: message["type"] == "debug_sessions")
            self.assertEqual(sessions["sessions"][0]["id"], info["session_id"])
            game.sendall((json.dumps({"type": "debug_attempts", "request_id": "attempts",
                                     "session_id": info["session_id"]}) + "\n").encode())
            archive = receive_until(lambda message: message["type"] == "debug_attempts")
            self.assertEqual(len(archive["attempts"]), 8)
            self.assertEqual(archive["attempts"][-1]["operator_label"], "ball_hit")
            game.sendall((json.dumps({"type": "debug_clip", "request_id": "clip", "session_id": info["session_id"],
                                     "attempt_id": 0, "before_s": 0.1, "after_s": 0.1}) + "\n").encode())
            receive_until(lambda message: message["type"] == "debug_clip_end" and message["request_id"] == "clip")
            clip_frames = [message for message in messages if message["type"] == "debug_frame"
                           and message.get("request_id") == "clip"]
            self.assertTrue(any(message["diagnostics"]["points"] for message in clip_frames))
            clip_report = next(message["report"] for message in messages
                               if message["type"] == "debug_attempt_begin" and message.get("request_id") == "clip")
            self.assertEqual(clip_report["outcome"], "no_ball_detected")
            game.sendall(b'{"type":"debug_attempts","request_id":"bad","session_id":"../outside"}\n')
            receive_until(lambda message: message["type"] == "debug_error" and message["request_id"] == "bad")
            receive_until(lambda message: message["type"] == "debug_frame" and message["source"] == "live")
            game.close();game = None;debug_mode = False
            time.sleep(0.15)
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
        try:
            sessions = list(Path(log_root.name).iterdir())
            self.assertEqual(len(sessions), 1)
            session = sessions[0]
            self.assertEqual((session / "radar.cfg").read_text(), (root / "radar_app/configs/golf.cfg").read_text())
            metadata = json.loads((session / "session.json").read_text())
            self.assertAlmostEqual(metadata["settings"]["detector"]["sensor"]["range_resolution_m"], 0.1953125)
            self.assertEqual(metadata["settings"]["detector"]["algorithm"], "sensor_normalized_ballistic_split_v1")
            captured = b"".join(path.read_bytes() for path in sorted(session.glob("raw-*.dat")))
            self.assertEqual(captured, sent_bytes, "Capture must preserve every UART byte, including noise and unarmed frames")
            events = [json.loads(line) for path in sorted(session.glob("events-*.jsonl"))
                      for line in path.read_text().splitlines()]
            self.assertEqual([event["sequence"] for event in events], list(range(1, len(events) + 1)))
            completed = [event for event in events if event["type"] == "swing_completed"]
            self.assertEqual([event["data"]["report"]["outcome"] for event in completed],
                             ["no_ball_detected", "ball_detected", "ball_detected", "aborted",
                              "no_ball_detected", "ball_detected", "ball_detected"])
            self.assertEqual(len({event["swing_id"] for event in completed}), 7)
            miss = completed[0]["data"]["report"]
            self.assertGreater(miss["points_evaluated"], 0)
            self.assertTrue(all(track["rejection_reason"] for track in miss["tracks"]))
            self.assertIn("selected_fit", completed[1]["data"]["report"])
            self.assertGreaterEqual(len(completed[1]["data"]["report"]["selected_observations"]), 3)
            self.assertEqual(completed[3]["data"]["report"]["abort_reason"], "game_disconnected")
            self.assertTrue(any(event["type"] == "frame_timeout" for event in events))
            frames = [event["data"] for event in events if event["type"] == "frame"]
            self.assertTrue(any(not event["game_connected"] and event["diagnostics"]["points"] for event in frames))
            self.assertEqual(sum(event["type"] == "shot_emitted" for event in events), 4)
            self.assertEqual(sum(event["type"] == "operator_mark" for event in events), 1)
            replay = subprocess.run([str(root / "radar_app/target/debug/radar_app"), "replay-live",
                                     str(session), str(root / "radar_app/configs/swing.json")],
                                    check=True, capture_output=True, text=True)
            replay = json.loads(replay.stdout)
            self.assertEqual(replay["statistics"]["confirmed_balls"], 4)
            self.assertEqual(replay["statistics"]["frames"], len(frames))
            self.assertTrue(any(attempt["outcome"] == "aborted" for attempt in replay["attempts"]))
        finally:
            log_root.cleanup()


if __name__ == "__main__":
    unittest.main()
