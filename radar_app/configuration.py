"""CFG text validation and conservative estimates, built on the offline analyzer."""
from __future__ import annotations

import hashlib
import math
import re

from radar_analyzer.analyze import parse_config

# SDK OOB configuration commands only; deliberately no arbitrary CLI endpoint.
COMMANDS = set("sensorStop sensorStart flushCfg dfeDataOutputMode channelCfg adcCfg adcbufCfg profileCfg chirpCfg frameCfg lowPower guiMonitor cfarCfg multiObjBeamForming clutterRemoval calibDcRangeSig extendedMaxVelocity bpmCfg lvdsStreamCfg compRangeBiasAndRxChanPhase measureRangeBiasAndRxChanPhase CQRxSatMonitor CQSigImgMonitor analogMonitor aoaFovCfg cfarFovCfg calibData nearFieldCfg dcRangeSigCfg rxSatMonitor sigImgMonitor".split())
OPEN_COMMANDS = {"channelCfg", "adcCfg", "lowPower"}


def commands(text: str) -> list[str]:
    if len(text.encode()) > 256_000:
        raise ValueError("CFG is too large (maximum 256 kB).")
    result = []
    for line in text.splitlines():
        line = line.split("%", 1)[0].split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if parts[0] not in COMMANDS:
            raise ValueError(f"Unsupported SDK OOB configuration command: {parts[0]}")
        if len(line) > 2048 or any(not re.fullmatch(r"[-+\d.eE]+", p) for p in parts[1:]):
            raise ValueError(f"Invalid numeric arguments: {line}")
        try:
            if any(not math.isfinite(float(p)) for p in parts[1:]):
                raise ValueError()
        except ValueError:
            raise ValueError(f"Non-finite or invalid argument: {line}") from None
        result.append(" ".join(parts))
    return result


def validate(text: str) -> dict:
    rows = [c.split() for c in commands(text)]
    lengths = {"channelCfg": 4, "profileCfg": 15, "chirpCfg": 9, "frameCfg": 8,
               "cfarFovCfg": 5, "dfeDataOutputMode": 2, "sensorStop": 1, "flushCfg": 1}
    for row in rows:
        if row[0] in lengths and len(row) != lengths[row[0]]:
            raise ValueError(f"Wrong argument count for {row[0]}.")
    try:
        summary = parse_config(text)
        channel = next(r for r in reversed(rows) if r[0] == "channelCfg")
        rx, tx = int(channel[1]), int(channel[2])
        if not (0 < rx <= 15 and 0 < tx <= 7):
            raise ValueError("IWR6843 requires RX mask 1–15 and TX mask 1–7.")
        profiles = {int(r[1]): r for r in rows if r[0] == "profileCfg"}
        for p in profiles.values():
            if min(float(p[2]), float(p[5]), float(p[8]), int(p[10]), float(p[11])) <= 0 or min(float(p[3]), float(p[4])) < 0:
                raise ValueError("Invalid profile frequency, timing or ADC sampling parameters.")
        for r in rows:
            if r[0] == "chirpCfg" and int(r[3]) not in profiles:
                raise ValueError("chirpCfg references an undefined profile.")
            if r[0] == "cfarFovCfg" and float(r[3]) > float(r[4]):
                raise ValueError("Output filter minimum exceeds maximum.")
            if r[0] == "chirpCfg" and (int(r[1]) < 0 or int(r[2]) < int(r[1]) or int(r[2]) > 511 or not 0 < int(r[8]) <= 7):
                raise ValueError("Invalid chirp indices or TX mask.")
        summary.update(rx_mask=rx, tx_mask=tx,
                       chirp_sequence=[r[1:] for r in rows if r[0] == "chirpCfg"],
                       profiles=[dict(id=int(r[1]), adc_samples=int(r[10]), sample_rate_ksps=float(r[11])) for r in profiles.values()])
        if any(r[0] == "bpmCfg" and len(r) > 2 and r[2] != "0" for r in rows):
            for k in ("max_unambiguous_radial_mps", "doppler_bin_mps", "range_resolution_m"):
                summary.pop(k, None)
            summary["warnings"].append("BPM arrangement: estimate unavailable.")
    except (IndexError, StopIteration, OverflowError) as exc:
        raise ValueError("Incomplete or invalid CFG parameters.") from exc
    summary["configuration_hash"] = digest(text)
    summary["open_configuration"] = [" ".join(r) for r in rows if r[0] in OPEN_COMMANDS]
    summary["warnings"].append("Changing channel/ADC/low-power (open configuration) may require a physical board reset. flushCfg clears CLI configuration; it does not reset hardware.")
    return summary


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def apply_commands(text: str) -> list[str]:
    rows = commands(text)
    # Normalize lifecycle commands to a single safe preamble; preserve other ordering.
    body = [r for r in rows if r.split()[0] not in {"sensorStop", "flushCfg"}]
    starts = [i for i, r in enumerate(body) if r.split()[0] == "sensorStart"]
    if len(starts) > 1 or (starts and starts[0] != len(body) - 1):
        raise ValueError("sensorStart must occur at most once, at the end of the CFG.")
    return ["sensorStop", "flushCfg", *body]
