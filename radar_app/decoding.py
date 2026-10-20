"""Bounded incremental framing; packet semantics reuse the proven offline decoder."""
from __future__ import annotations

import struct
from collections import Counter, deque

from radar_analyzer.analyze import MAGIC, MAX_PACKET, decode_stream


class StreamDecoder:
    def __init__(self, period_ms: float = 20, gap_history_limit: int | None = 256):
        self.config = {"frame_period_ms": period_ms}
        self.buffer = bytearray()
        self.offset = 0
        self.last_number = None
        self.ticks = 0
        self.frames = 0
        self.detections = 0
        self.gaps = deque(maxlen=gap_history_limit)
        self.diagnostics = Counter(file_bytes=0, skipped_bytes=0, trailing_bytes=0,
                                   malformed_packets=0, missing_frames=0,
                                   duplicate_frames=0, counter_discontinuities=0)

    def discard(self, n: int):
        del self.buffer[:n]
        self.offset += n

    def feed(self, chunk: bytes) -> list[dict]:
        self.diagnostics["file_bytes"] += len(chunk)
        self.buffer.extend(chunk)
        result = []
        while self.buffer:
            start = self.buffer.find(MAGIC)
            if start < 0:
                # Keep a possible split magic word, not arbitrary old bytes.
                n = max(0, len(self.buffer) - 7)
                self.diagnostics["skipped_bytes"] += n
                self.discard(n)
                break
            if start:
                self.diagnostics["skipped_bytes"] += start
                self.discard(start)
            if len(self.buffer) < 40:
                break
            size = struct.unpack_from("<I", self.buffer, 12)[0]
            if size < 40 or size > MAX_PACKET:
                self.diagnostics["malformed_packets"] += 1
                self.diagnostics["skipped_bytes"] += 1
                self.discard(1)
                continue
            if len(self.buffer) < size:
                # A claimed oversized partial packet may be corrupt. Resync only
                # if a subsequent candidate can itself be fully validated.
                candidate = self.buffer.find(MAGIC, 8)
                if candidate >= 0 and len(self.buffer) >= candidate + 40:
                    other_size = struct.unpack_from("<I", self.buffer, candidate + 12)[0]
                    if 40 <= other_size <= len(self.buffer) - candidate:
                        try:
                            decode_stream(bytes(self.buffer[candidate:candidate + other_size]), self.config)
                        except ValueError:
                            break
                        self.diagnostics["malformed_packets"] += 1
                        self.diagnostics["skipped_bytes"] += candidate
                        self.discard(candidate)
                        continue
                break
            try:
                frames, _ = decode_stream(bytes(self.buffer[:size]), self.config)
                frame = frames[0]
            except ValueError:
                self.diagnostics["malformed_packets"] += 1
                self.diagnostics["skipped_bytes"] += 1
                self.discard(1)
                continue
            if self.last_number is not None:
                delta = (frame["number"] - self.last_number) & 0xFFFFFFFF
                if delta == 0:
                    self.diagnostics["duplicate_frames"] += 1
                elif delta < 1_000_000:
                    self.diagnostics["missing_frames"] += delta - 1
                    if delta > 1:
                        self.gaps.append(dict(after_frame=self.last_number, before_frame=frame["number"],
                                              first_missing=(self.last_number + 1) & 0xFFFFFFFF,
                                              last_missing=(frame["number"] - 1) & 0xFFFFFFFF, count=delta - 1))
                    self.ticks += delta
                else:
                    self.diagnostics["counter_discontinuities"] += 1
                    self.ticks += 1
            self.last_number = frame["number"]
            frame.update(t=self.ticks * self.config["frame_period_ms"] / 1000, offset=self.offset)
            self.frames += 1
            self.detections += len(frame["points"])
            result.append(frame)
            self.discard(size)
        return result

    def finish(self):
        self.diagnostics["trailing_bytes"] += len(self.buffer)
        self.buffer.clear()

    def health(self) -> dict:
        return dict(frames=self.frames, detections=self.detections,
                    parser_errors=self.diagnostics["malformed_packets"],
                    pending_bytes=len(self.buffer), missing_frame_ranges=list(self.gaps), diagnostics=dict(self.diagnostics))
