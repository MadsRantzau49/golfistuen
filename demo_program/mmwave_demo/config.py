import time
from pathlib import Path

import serial


CLI_PROMPT = b"mmwDemo:/>"


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


def iter_config_commands(config_file: Path):
    for raw_line in config_file.read_text().splitlines():
        line = raw_line.strip()

        if not line or line.startswith("%") or line.startswith("#"):
            continue

        yield line


def send_config(config_port: str, config_baud: int, config_file: Path):
    print(f"Sending config from {config_file} to {config_port} at {config_baud} baud")

    with serial.Serial(port=config_port, baudrate=config_baud, timeout=0.1) as ser:
        # Clear any startup banner/prompt before sending commands.
        read_cli_response(ser, timeout=0.5)

        for line in iter_config_commands(config_file):
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
