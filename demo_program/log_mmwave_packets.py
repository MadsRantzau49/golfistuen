import argparse
import csv
import struct
import time
from pathlib import Path

import serial


MAGIC_WORD = b"\x02\x01\x04\x03\x06\x05\x08\x07"

# mmWave SDK demo packet header:
# magicWord[4] uint16 + 8 uint32 fields = 40 bytes
HEADER_STRUCT = struct.Struct("<4H8I")
TLV_HEADER_STRUCT = struct.Struct("<II")


TLV_NAMES = {
    1: "Detected points",
    2: "Range profile",
    3: "Noise profile",
    4: "Azimuth static heatmap",
    5: "Range-Doppler heatmap",
    6: "Statistics",
    7: "Side info for detected points",
}


CLI_PROMPT = b"mmwDemo:/>"


def parse_packet(packet: bytes):
    """
    Parse one full mmWave demo packet.
    Returns basic frame information and TLV list.
    """

    if not packet.startswith(MAGIC_WORD):
        raise ValueError("Packet does not start with magic word")

    header = HEADER_STRUCT.unpack_from(packet, 0)

    version = header[4]
    total_packet_len = header[5]
    platform = header[6]
    frame_number = header[7]
    time_cpu_cycles = header[8]
    num_detected_obj = header[9]
    num_tlvs = header[10]
    subframe_number = header[11]

    tlvs = []
    offset = HEADER_STRUCT.size

    for _ in range(num_tlvs):
        if offset + TLV_HEADER_STRUCT.size > len(packet):
            break

        tlv_type, tlv_length = TLV_HEADER_STRUCT.unpack_from(packet, offset)
        offset += TLV_HEADER_STRUCT.size

        payload_start = offset
        payload_end = offset + tlv_length

        if payload_end > len(packet):
            # Corrupt or unexpected packet format
            break

        payload = packet[payload_start:payload_end]

        tlvs.append({
            "type": tlv_type,
            "name": TLV_NAMES.get(tlv_type, "Unknown"),
            "length": tlv_length,
            "payload": payload,
        })

        offset = payload_end

    return {
        "version": version,
        "total_packet_len": total_packet_len,
        "platform": platform,
        "frame_number": frame_number,
        "time_cpu_cycles": time_cpu_cycles,
        "num_detected_obj": num_detected_obj,
        "num_tlvs": num_tlvs,
        "subframe_number": subframe_number,
        "tlvs": tlvs,
    }


def parse_detected_points(tlv_payload: bytes):
    """
    TLV type 1 usually contains detected points:
    x, y, z, doppler as float32.
    Each point is 16 bytes.
    """

    points = []
    point_struct = struct.Struct("<ffff")

    count = len(tlv_payload) // point_struct.size

    for i in range(count):
        x, y, z, doppler = point_struct.unpack_from(tlv_payload, i * point_struct.size)
        points.append({
            "x": x,
            "y": y,
            "z": z,
            "doppler": doppler,
        })

    return points


def read_cli_response(ser: serial.Serial, timeout: float = 2.0) -> bytes:
    response = bytearray()
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        chunk = ser.read(4096)

        if chunk:
            response.extend(chunk)

            if CLI_PROMPT in response:
                break
        else:
            time.sleep(0.02)

    return bytes(response)


def send_config(config_port: str, config_baud: int, config_file: Path):
    print(f"Sending config from {config_file} to {config_port} at {config_baud} baud")

    with serial.Serial(port=config_port, baudrate=config_baud, timeout=0.1) as ser:
        # Clear any startup banner/prompt before sending commands.
        read_cli_response(ser, timeout=0.5)

        for raw_line in config_file.read_text().splitlines():
            line = raw_line.strip()

            if not line or line.startswith("%") or line.startswith("#"):
                continue

            print(f"> {line}")
            ser.write((line + "\n").encode("ascii"))
            ser.flush()

            timeout = 5.0 if line.startswith("sensorStart") else 2.0
            response = read_cli_response(ser, timeout=timeout)
            text = response.decode(errors="replace").strip()

            if text:
                print(text)

            if "Error" in text:
                raise RuntimeError(f"Radar rejected config command: {line}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-port", required=True, help="DATA UART port, for example COM7 or /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--config-port", help="CFG/command UART port, for example COM6 or /dev/ttyUSB0")
    parser.add_argument("--config-baud", type=int, default=115200)
    parser.add_argument("--config-file", type=Path, help="TI mmWave demo .cfg file to send before logging")
    parser.add_argument("--idle-status-seconds", type=float, default=5.0, help="Print a waiting message if no serial bytes arrive")
    parser.add_argument("--out-bin", default="mmwave_raw_packets.bin")
    parser.add_argument("--out-frames", default="mmwave_frames.csv")
    parser.add_argument("--out-points", default="mmwave_points.csv")
    args = parser.parse_args()

    if bool(args.config_port) != bool(args.config_file):
        parser.error("--config-port and --config-file must be used together")

    raw_path = Path(args.out_bin)
    frames_csv_path = Path(args.out_frames)
    points_csv_path = Path(args.out_points)

    ser = serial.Serial(
        port=args.data_port,
        baudrate=args.baud,
        timeout=0.1,
    )

    buffer = bytearray()

    print(f"Listening on {args.data_port} at {args.baud} baud")
    print(f"Writing raw packets to: {raw_path}")
    print("Press Ctrl+C to stop")

    if args.config_port:
        send_config(args.config_port, args.config_baud, args.config_file)

    with raw_path.open("ab") as raw_file, \
         frames_csv_path.open("w", newline="") as frames_file, \
         points_csv_path.open("w", newline="") as points_file:

        frame_writer = csv.DictWriter(
            frames_file,
            fieldnames=[
                "timestamp",
                "frame_number",
                "total_packet_len",
                "num_detected_obj",
                "num_tlvs",
                "tlv_summary",
            ],
        )
        frame_writer.writeheader()

        point_writer = csv.DictWriter(
            points_file,
            fieldnames=[
                "timestamp",
                "frame_number",
                "point_index",
                "x",
                "y",
                "z",
                "doppler",
            ],
        )
        point_writer.writeheader()

        bytes_seen = 0
        packets_seen = 0
        last_status = time.monotonic()

        try:
            while True:
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
                    magic_index = buffer.find(MAGIC_WORD)

                    if magic_index < 0:
                        # Keep only a few bytes in case magic word is split across reads
                        buffer = buffer[-len(MAGIC_WORD):]
                        break

                    # Remove garbage before magic word
                    if magic_index > 0:
                        del buffer[:magic_index]

                    # Need at least full header
                    if len(buffer) < HEADER_STRUCT.size:
                        break

                    try:
                        header = HEADER_STRUCT.unpack_from(buffer, 0)
                        total_packet_len = header[5]
                    except struct.error:
                        break

                    # Sanity check
                    if total_packet_len < HEADER_STRUCT.size or total_packet_len > 1000000:
                        del buffer[0]
                        continue

                    # Wait until full packet has arrived
                    if len(buffer) < total_packet_len:
                        break

                    packet = bytes(buffer[:total_packet_len])
                    del buffer[:total_packet_len]
                    packets_seen += 1

                    timestamp = time.time()

                    # Store exact raw packet bytes
                    raw_file.write(packet)
                    raw_file.flush()

                    try:
                        parsed = parse_packet(packet)
                    except Exception as e:
                        print(f"Could not parse packet: {e}")
                        continue

                    tlv_summary = "; ".join(
                        f"{tlv['type']}:{tlv['name']}({tlv['length']} bytes)"
                        for tlv in parsed["tlvs"]
                    )

                    frame_writer.writerow({
                        "timestamp": timestamp,
                        "frame_number": parsed["frame_number"],
                        "total_packet_len": parsed["total_packet_len"],
                        "num_detected_obj": parsed["num_detected_obj"],
                        "num_tlvs": parsed["num_tlvs"],
                        "tlv_summary": tlv_summary,
                    })
                    frames_file.flush()

                    print(
                        f"Frame {parsed['frame_number']} | "
                        f"objects={parsed['num_detected_obj']} | "
                        f"tlvs={parsed['num_tlvs']} | "
                        f"packet={parsed['total_packet_len']} bytes"
                    )

                    # Optional: extract detected points from TLV type 1
                    for tlv in parsed["tlvs"]:
                        if tlv["type"] == 1:
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

                            points_file.flush()

        except KeyboardInterrupt:
            print("\nStopped by user")

        finally:
            ser.close()
            print(f"Captured {packets_seen} packets from {bytes_seen} serial bytes")


if __name__ == "__main__":
    main()
