import argparse
import csv
import struct
import time
from pathlib import Path

import serial

from .config import send_config
from .packets import HEADER_STRUCT, MAGIC_WORD, parse_detected_points, parse_packet, tlv_summary


DEFAULT_RAW_PATH = Path("data/raw/mmwave_raw_packets.bin")
DEFAULT_FRAMES_PATH = Path("data/processed/mmwave_frames.csv")
DEFAULT_POINTS_PATH = Path("data/processed/mmwave_points.csv")


FRAME_FIELDS = [
    "timestamp",
    "frame_number",
    "total_packet_len",
    "num_detected_obj",
    "num_tlvs",
    "tlv_summary",
]


POINT_FIELDS = [
    "timestamp",
    "frame_number",
    "point_index",
    "x",
    "y",
    "z",
    "doppler",
]


def ensure_parent_dirs(*paths: Path):
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)


def build_parser():
    parser = argparse.ArgumentParser(description="Capture TI mmWave SDK demo packets")
    parser.add_argument("--data-port", required=True, help="DATA UART port, for example COM7 or /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--config-port", help="CFG/command UART port, for example COM6 or /dev/ttyUSB0")
    parser.add_argument("--config-baud", type=int, default=115200)
    parser.add_argument("--config-file", type=Path, help="TI mmWave demo .cfg file to send before logging")
    parser.add_argument("--idle-status-seconds", type=float, default=5.0, help="Print a waiting message if no serial bytes arrive")
    parser.add_argument("--out-bin", type=Path, default=DEFAULT_RAW_PATH)
    parser.add_argument("--out-frames", type=Path, default=DEFAULT_FRAMES_PATH)
    parser.add_argument("--out-points", type=Path, default=DEFAULT_POINTS_PATH)
    parser.add_argument("--max-frames", type=int, help="Stop after this many complete packets")
    parser.add_argument("--duration-seconds", type=float, help="Stop after this many seconds of logging")

    return parser


def validate_args(parser, args):
    if bool(args.config_port) != bool(args.config_file):
        parser.error("--config-port and --config-file must be used together")

    if args.max_frames is not None and args.max_frames < 1:
        parser.error("--max-frames must be at least 1")

    if args.duration_seconds is not None and args.duration_seconds <= 0:
        parser.error("--duration-seconds must be greater than 0")


def write_frame_row(frame_writer, timestamp, parsed):
    frame_writer.writerow({
        "timestamp": timestamp,
        "frame_number": parsed["frame_number"],
        "total_packet_len": parsed["total_packet_len"],
        "num_detected_obj": parsed["num_detected_obj"],
        "num_tlvs": parsed["num_tlvs"],
        "tlv_summary": tlv_summary(parsed["tlvs"]),
    })


def write_detected_points(point_writer, timestamp, parsed):
    for tlv in parsed["tlvs"]:
        if tlv["type"] != 1:
            continue

        points = parse_detected_points(tlv["payload"])

        for i, point in enumerate(points):
            point_writer.writerow({
                "timestamp": timestamp,
                "frame_number": parsed["frame_number"],
                "point_index": i,
                "x": point["x"],
                "y": point["y"],
                "z": point["z"],
                "doppler": point["doppler"],
            })


def extract_next_packet(buffer: bytearray):
    while True:
        magic_index = buffer.find(MAGIC_WORD)

        if magic_index < 0:
            # Keep only a few bytes in case magic word is split across reads.
            buffer[:] = buffer[-len(MAGIC_WORD):]
            return None

        if magic_index > 0:
            del buffer[:magic_index]

        if len(buffer) < HEADER_STRUCT.size:
            return None

        try:
            header = HEADER_STRUCT.unpack_from(buffer, 0)
            total_packet_len = header[5]
        except struct.error:
            return None

        if total_packet_len < HEADER_STRUCT.size or total_packet_len > 1000000:
            del buffer[0]
            continue

        if len(buffer) < total_packet_len:
            return None

        packet = bytes(buffer[:total_packet_len])
        del buffer[:total_packet_len]

        return packet


def capture(args):
    ensure_parent_dirs(args.out_bin, args.out_frames, args.out_points)

    ser = serial.Serial(
        port=args.data_port,
        baudrate=args.baud,
        timeout=0.1,
    )

    buffer = bytearray()
    bytes_seen = 0
    packets_seen = 0
    last_status = time.monotonic()
    started_at = time.monotonic()

    print(f"Listening on {args.data_port} at {args.baud} baud")
    print(f"Writing raw packets to: {args.out_bin}")
    print(f"Writing frame CSV to: {args.out_frames}")
    print(f"Writing point CSV to: {args.out_points}")
    print("Press Ctrl+C to stop")

    try:
        if args.config_port:
            send_config(args.config_port, args.config_baud, args.config_file)

        with args.out_bin.open("ab") as raw_file, \
             args.out_frames.open("w", newline="") as frames_file, \
             args.out_points.open("w", newline="") as points_file:

            frame_writer = csv.DictWriter(frames_file, fieldnames=FRAME_FIELDS)
            frame_writer.writeheader()

            point_writer = csv.DictWriter(points_file, fieldnames=POINT_FIELDS)
            point_writer.writeheader()

            while True:
                if args.duration_seconds and time.monotonic() - started_at >= args.duration_seconds:
                    print("Reached duration limit")
                    break

                data = ser.read(4096)

                if not data:
                    now = time.monotonic()

                    if args.idle_status_seconds and now - last_status >= args.idle_status_seconds:
                        print(
                            f"Waiting for data... bytes_seen={bytes_seen}, "
                            f"packets_seen={packets_seen}, buffered={len(buffer)}"
                        )
                        last_status = now

                    continue

                bytes_seen += len(data)
                last_status = time.monotonic()
                buffer.extend(data)

                while True:
                    packet = extract_next_packet(buffer)

                    if packet is None:
                        break

                    packets_seen += 1
                    timestamp = time.time()

                    raw_file.write(packet)
                    raw_file.flush()

                    try:
                        parsed = parse_packet(packet)
                    except Exception as exc:
                        print(f"Could not parse packet: {exc}")
                        continue

                    write_frame_row(frame_writer, timestamp, parsed)
                    frames_file.flush()

                    print(
                        f"Frame {parsed['frame_number']} | "
                        f"objects={parsed['num_detected_obj']} | "
                        f"tlvs={parsed['num_tlvs']} | "
                        f"packet={parsed['total_packet_len']} bytes"
                    )

                    write_detected_points(point_writer, timestamp, parsed)
                    points_file.flush()

                    if args.max_frames and packets_seen >= args.max_frames:
                        print("Reached frame limit")
                        return

    except KeyboardInterrupt:
        print("\nStopped by user")

    finally:
        ser.close()
        print(f"Captured {packets_seen} packets from {bytes_seen} serial bytes")


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_args(parser, args)
    capture(args)
