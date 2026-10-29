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
        notes_mode = False
        last_notes_heartbeat = 0.0

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
            nonlocal incoming, last_notes_heartbeat
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if notes_mode and time.monotonic() - last_notes_heartbeat > 1:
                    game.sendall(b'{"type":"notes_subscribe","enabled":true}\n')
                    last_notes_heartbeat = time.monotonic()
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
            # Operator-defined start/end windows exist independently of whether
            # the detector finds a ball. Notes are saved against that exact ID.
            game = socket.create_connection(("127.0.0.1", port), timeout=3)
            incoming = b""
            notes_mode = True
            notes_start = len(messages)
            info = receive_until(lambda message: message["type"] == "notes_info")
            self.assertEqual(info["captures"], [])

            def command(kind, request, **fields):
                game.sendall((json.dumps({"type": kind, "request_id": request, **fields}) + "\n").encode())

            command("capture_start", "start-1", capture_id="notes-hit-1", client_time_ms=10000)
            first_capture = receive_until(lambda message: message.get("request_id") == "start-1")["capture"]
            self.assertEqual(first_capture["annotation"], {"speed": None, "elevation": None, "direction": None, "notes": None})
            send_hit(15.0)
            command("capture_end", "end-1", capture_id="notes-hit-1", client_time_ms=12000)
            captured_hit = receive_until(lambda message: message.get("request_id") == "end-1")["capture"]
            self.assertEqual(captured_hit["state"], "complete")
            self.assertGreater(captured_hit["frame_count"], 0)
            self.assertGreater(captured_hit["point_count"], 0)
            self.assertGreater(captured_hit["duration_s"], 0)
            self.assertEqual(captured_hit["confirmed_balls"], 1)
            annotation = {"speed": "full_speed", "elevation": "instant_ceiling", "direction": "full_left",
                          "notes": "Travelled about 4 m, about 2 m high, then hit ceiling"}
            command("capture_annotate", "save-1", session_id=info["session_id"], capture_id="notes-hit-1",
                    annotation_revision=0, annotation=annotation)
            saved_hit = receive_until(lambda message: message.get("request_id") == "save-1")["capture"]
            self.assertEqual(saved_hit["annotation"], annotation)
            self.assertEqual(saved_hit["annotation_revision"], 1)
            command("capture_start", "start-2", capture_id="notes-missed-2", client_time_ms=20000)
            receive_until(lambda message: message.get("request_id") == "start-2")
            # A retry of an earlier stop must not close the new capture.
            command("capture_end", "retry-end-1", capture_id="notes-hit-1", client_time_ms=21000)
            self.assertEqual(receive_until(lambda message: message.get("request_id") == "retry-end-1")["capture"]["ended"], captured_hit["ended"])
            send_frame((0.0, 1.0, 0.0, 0.0))
            command("capture_end", "end-2", capture_id="notes-missed-2", client_time_ms=22000)
            missed = receive_until(lambda message: message.get("request_id") == "end-2")["capture"]
            self.assertEqual(missed["state"], "complete")
            self.assertEqual(missed["confirmed_balls"], 0)
            self.assertGreater(missed["frame_count"], 0)
            command("capture_annotate", "save-2", session_id=info["session_id"], capture_id="notes-missed-2",
                    annotation_revision=0, annotation={"speed": "low", "elevation": "rolling", "direction": "full_right", "notes": None})
            self.assertIsNone(receive_until(lambda message: message.get("request_id") == "save-2")["capture"]["annotation"]["notes"])
            command("capture_annotate", "invalid", session_id=info["session_id"], capture_id="notes-missed-2",
                    annotation_revision=1, annotation={"spin": 1000})
            self.assertEqual(receive_until(lambda message: message.get("request_id") == "invalid")["type"], "notes_error")
            command("capture_start", "start-3", capture_id="notes-interrupted-3", client_time_ms=30000)
            receive_until(lambda message: message.get("request_id") == "start-3")
            send_frame((0.0, 1.0, 0.0, 0.0))
            game.close();game = None
            time.sleep(0.15)
            game = socket.create_connection(("127.0.0.1", port), timeout=3)
            incoming = b"";last_notes_heartbeat = 0
            restored = receive_until(lambda message: message["type"] == "notes_info")
            self.assertEqual(len(restored["captures"]), 3)
            self.assertEqual(restored["captures"][0]["state"], "interrupted")
            self.assertEqual(restored["captures"][0]["end_reason"], "client_disconnected")
            self.assertEqual(next(c for c in restored["captures"] if c["capture_id"] == "notes-hit-1")["annotation"], annotation)
            self.assertFalse(any(message["type"] == "shot" for message in messages[notes_start:]), "Notes capture must not deliver gameplay strokes")
            game.close();game = None;notes_mode = False
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
            self.assertEqual([event["data"]["report"]["outcome"] for event in completed[:4]],
                             ["no_ball_detected", "ball_detected", "ball_detected", "aborted"])
            miss = completed[0]["data"]["report"]
            self.assertGreater(miss["points_evaluated"], 0)
            self.assertTrue(all(track["rejection_reason"] for track in miss["tracks"]))
            self.assertIn("selected_fit", completed[1]["data"]["report"])
            self.assertGreaterEqual(len(completed[1]["data"]["report"]["selected_observations"]), 3)
            self.assertEqual(completed[3]["data"]["report"]["abort_reason"], "game_disconnected")
            self.assertTrue(any(event["type"] == "frame_timeout" for event in events))
            frames = [event["data"] for event in events if event["type"] == "frame"]
            self.assertTrue(any(not event["game_connected"] and event["diagnostics"]["points"] for event in frames))
            self.assertEqual(sum(event["type"] == "shot_capture_started" for event in events), 3)
            self.assertEqual(sum(event["type"] == "shot_capture_ended" for event in events), 3)
            for capture_id in ["notes-hit-1", "notes-missed-2", "notes-interrupted-3"]:
                record = json.loads((session / "captures" / f"{capture_id}.json").read_text())
                linked = [event for event in events if event["type"] == "frame" and event["capture_id"] == capture_id]
                self.assertEqual(record["frame_count"], len(linked))
                self.assertEqual(record["point_count"], sum(len(event["data"]["diagnostics"]["points"]) for event in linked))
                self.assertTrue(record["ended"])
                self.assertFalse("spin" in record["annotation"])
                start_marker = next(event for event in events if event["type"] == "shot_capture_started"
                                    and event["capture_id"] == capture_id)
                end_marker = next(event for event in events if event["type"] == "shot_capture_ended"
                                  and event["capture_id"] == capture_id)
                self.assertEqual(record["started"]["event_sequence"], start_marker["sequence"])
                self.assertEqual(record["ended"]["event_sequence"], end_marker["sequence"])
                self.assertGreaterEqual(record["ended"]["raw_bytes_received"], record["started"]["raw_bytes_received"])
                self.assertTrue(all(not isinstance(result["selected_shot"], dict) or "spin_rpm" not in result["selected_shot"]
                                    for result in record["detector_results"]))
            replay = subprocess.run([str(root / "radar_app/target/debug/radar_app"), "replay-live",
                                     str(session), str(root / "radar_app/configs/swing.json")],
                                    check=True, capture_output=True, text=True)
            replay = json.loads(replay.stdout)
            self.assertEqual(replay["statistics"]["confirmed_balls"], 3)
            self.assertEqual(replay["statistics"]["frames"], len(frames))
            self.assertTrue(any(attempt["outcome"] == "aborted" for attempt in replay["attempts"]))
        finally:
            log_root.cleanup()


if __name__ == "__main__":
    unittest.main()
