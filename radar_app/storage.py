"""Project-scoped files, exact-byte recording and atomic session metadata."""
from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from radar_analyzer.analyze import analyze
from .configuration import digest, validate
from .decoding import StreamDecoder


def now():
    return datetime.now(timezone.utc).isoformat()


def read_text_exact(path: Path, encoding="utf-8") -> str:
    """Preserve CFG line endings: hashes refer to the saved snapshot text."""
    with path.open("r", encoding=encoding, newline="") as handle:
        return handle.read()


def safe_child(parent: Path, name: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,179}", name) or name in {".", ".."}:
        raise ValueError("Use a simple filename with letters, numbers, dots, underscores or hyphens.")
    path = parent / name
    if path.is_symlink() or path.resolve().parent != parent.resolve():
        raise ValueError("File must be directly inside the project data directory; symlinks are not allowed.")
    return path


def atomic_json(path: Path, value: dict):
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class SessionStore:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.configs = self.root / "configs"
        self.logs = self.root / "logs"
        self.sessions = self.logs / "sessions"
        for directory in (self.configs, self.logs, self.sessions):
            if directory.is_symlink():
                raise ValueError("Project data directories must not be symlinks.")
            directory.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.active = None
        self.last_recording = None

    def path(self, session_id: str, filename: str | None = None) -> Path:
        directory = safe_child(self.sessions, session_id)
        if not directory.is_dir():
            raise ValueError("Session does not exist.")
        return safe_child(directory, filename) if filename else directory

    def metadata(self, session_id):
        return json.loads(self.path(session_id, "session.json").read_text())

    def list_sessions(self):
        result = []
        for directory in self.sessions.iterdir():
            if directory.is_dir() and not directory.is_symlink():
                try:
                    result.append(self.metadata(directory.name))
                except (ValueError, OSError):
                    continue
        return sorted(result, key=lambda m: m["started_at"], reverse=True)

    def create(self, label, notes, cfg_text, connection, source="radar"):
        validate(cfg_text)
        label = label.strip() or "Untitled experiment"
        slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:60] or "experiment"
        session_id = f"{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}_{slug}_{uuid.uuid4().hex[:12]}"
        directory = safe_child(self.sessions, session_id)
        directory.mkdir(exist_ok=False)
        meta = dict(schema_version=1, id=session_id, label=label, notes=notes,
                    started_at=now(), ended_at=None, duration_s=0, byte_count=0,
                    decoded_frames=0, detection_count=0, missing_frames=0, missing_frame_ranges=[], parser_errors=0,
                    configuration_hash=digest(cfg_text), connection=connection,
                    source=source, completion_status="recording", interruption_reason=None)
        try:
            with (directory / "profile.cfg").open("x", encoding="utf-8", newline="") as cfg:
                cfg.write(cfg_text)
            (directory / "profile.cfg").chmod(0o444)
            (directory / "console.log").touch(exist_ok=False)
            atomic_json(directory / "annotations.json", dict(impact_s=None, from_s=0, to_s=0, points=[]))
            atomic_json(directory / "session.json", meta)
        except Exception:
            # Keep any created files for investigation rather than overwriting.
            raise
        return directory, meta

    def start(self, label, notes, cfg_text, connection, console):
        with self.lock:
            if self.active:
                raise ValueError("An experiment is already recording.")
            directory, meta = self.create(label, notes, cfg_text, connection)
            stream = None
            try:
                stream = (directory / "stream.dat").open("xb", buffering=0)
                log = (directory / "console.log").open("a", encoding="utf-8")
            except OSError as exc:
                if stream:
                    stream.close()
                meta.update(completion_status="incomplete", ended_at=now(), interruption_reason=f"Could not open recording files: {exc}")
                atomic_json(directory / "session.json", meta)
                raise
            self.active = dict(directory=directory, meta=meta, stream=stream, console=log,
                               decoder=StreamDecoder(validate(cfg_text)["frame_period_ms"], gap_history_limit=None),
                               start=time.monotonic(), checkpoint=time.monotonic())
            try:
                log.write("\n".join(console) + "\n")
                log.flush()
            except OSError as exc:
                self.stop(f"Console write failure: {exc}")
                raise
            return meta.copy()

    def update_counts(self, active):
        meta, decoder = active["meta"], active["decoder"]
        meta.update(duration_s=time.monotonic() - active["start"], decoded_frames=decoder.frames,
                    detection_count=decoder.detections, missing_frames=decoder.diagnostics["missing_frames"],
                    missing_frame_ranges=list(decoder.gaps), parser_errors=decoder.diagnostics["malformed_packets"], diagnostics=dict(decoder.diagnostics))

    def write(self, chunk: bytes):
        with self.lock:
            if not self.active:
                return
            a = self.active
            try:
                view = memoryview(chunk)
                while view:
                    n = a["stream"].write(view)
                    if not n:
                        raise OSError("Short/zero data write")
                    a["meta"]["byte_count"] += n
                    a["decoder"].feed(bytes(view[:n]))
                    view = view[n:]
                if time.monotonic() - a["checkpoint"] >= 1:
                    self.update_counts(a)
                    atomic_json(a["directory"] / "session.json", a["meta"])
                    a["checkpoint"] = time.monotonic()
            except Exception as exc:
                self.stop(f"Recording write/parser failure: {exc}")
                raise OSError(f"Recording failed: {exc}. Check disk space and directory permissions.") from exc

    def console(self, entry):
        with self.lock:
            if self.active:
                try:
                    self.active["console"].write(entry + "\n")
                    self.active["console"].flush()
                except OSError as exc:
                    self.stop(f"Console write failure: {exc}")
                    raise

    def status(self):
        with self.lock:
            if not self.active:
                return None
            self.update_counts(self.active)
            return self.active["meta"].copy()

    def stop(self, reason=None):
        with self.lock:
            if not self.active:
                return None
            a, self.active = self.active, None
            errors = []
            a["decoder"].finish()
            self.update_counts(a)
            for key in ("stream", "console"):
                try:
                    a[key].flush()
                    os.fsync(a[key].fileno())
                except OSError as exc:
                    errors.append(str(exc))
                finally:
                    try:
                        a[key].close()
                    except OSError as exc:
                        errors.append(str(exc))
            reason = reason or ("Finalization write failure: " + "; ".join(errors) if errors else None)
            a["meta"].update(ended_at=now(), completion_status="incomplete" if reason else "complete", interruption_reason=reason)
            self.last_recording = a["meta"].copy()
            try:
                atomic_json(a["directory"] / "session.json", a["meta"])
            except OSError as exc:
                self.last_recording.update(completion_status="incomplete", interruption_reason=f"Metadata finalization failed: {exc}. Startup recovery will inspect the retained files.")
                raise
            return a["meta"]

    def recover(self):
        for meta in self.list_sessions():
            if meta["completion_status"] != "recording":
                continue
            try:
                cfg = read_text_exact(self.path(meta["id"], "profile.cfg"))
                decoder = StreamDecoder(validate(cfg)["frame_period_ms"], gap_history_limit=None)
                with self.path(meta["id"], "stream.dat").open("rb") as handle:
                    while chunk := handle.read(65536):
                        decoder.feed(chunk)
                decoder.finish()
                meta.update(byte_count=decoder.diagnostics["file_bytes"], decoded_frames=decoder.frames,
                            detection_count=decoder.detections, diagnostics=dict(decoder.diagnostics),
                            missing_frames=decoder.diagnostics["missing_frames"], missing_frame_ranges=list(decoder.gaps), parser_errors=decoder.diagnostics["malformed_packets"])
            except (OSError, ValueError) as exc:
                meta["recovery_error"] = str(exc)
            meta.update(completion_status="incomplete", interruption_reason="Application exited without finalizing (crash or power loss). Duration is the last persisted estimate.", recovered_at=now())
            atomic_json(self.path(meta["id"], "session.json"), meta)

    def replay(self, session_id):
        active = self.status()
        if active and active["id"] == session_id:
            raise ValueError("Stop this recording before opening its replay.")
        data = self.path(session_id, "stream.dat")
        if data.stat().st_size > 128 * 1024 * 1024:
            raise ValueError("Interactive replay is limited to 128 MiB. Export the bundle and use the Python analyzer for larger recordings.")
        text = read_text_exact(self.path(session_id, "profile.cfg"))
        if digest(text) != self.metadata(session_id)["configuration_hash"]:
            raise ValueError("The saved CFG snapshot hash has changed outside the workbench. Inspect the session files before relying on replay timing.")
        recording = analyze(data.read_bytes(), text, f"{session_id}/stream.dat", "profile.cfg")
        original_warnings = recording["config"]["warnings"]
        recording["config"] = validate(text)
        recording["config"]["warnings"] = list(dict.fromkeys([*recording["config"]["warnings"], *original_warnings]))
        return recording

    def update(self, session_id, label, notes):
        with self.lock:
            if self.active and self.active["meta"]["id"] == session_id:
                self.active["meta"].update(label=label, notes=notes)
                meta = self.active["meta"]
            else:
                meta = self.metadata(session_id)
                meta.update(label=label, notes=notes)
            atomic_json(self.path(session_id, "session.json"), meta)
            return meta

    def import_pair(self, dat_name, cfg_name, label, notes):
        data = safe_child(self.logs, dat_name)
        cfg = safe_child(self.logs, cfg_name)
        if data.suffix.lower() != ".dat" or cfg.suffix.lower() != ".cfg":
            raise ValueError("Explicitly choose a DAT and CFG from logs/.")
        text = read_text_exact(cfg, encoding="utf-8-sig")
        directory, meta = self.create(label or data.stem, notes, text, {}, "import")
        meta.update(pairing="user-supplied", original_data=dat_name, original_configuration=cfg_name)
        decoder = StreamDecoder(validate(text)["frame_period_ms"], gap_history_limit=None)
        try:
            with data.open("rb") as src, (directory / "stream.dat").open("xb") as dst:
                while chunk := src.read(65536):
                    dst.write(chunk)
                    decoder.feed(chunk)
                dst.flush()
                os.fsync(dst.fileno())
            decoder.finish()
            meta.update(byte_count=decoder.diagnostics["file_bytes"], decoded_frames=decoder.frames,
                        detection_count=decoder.detections, missing_frames=decoder.diagnostics["missing_frames"], missing_frame_ranges=list(decoder.gaps),
                        parser_errors=decoder.diagnostics["malformed_packets"], diagnostics=dict(decoder.diagnostics),
                        duration_s=(decoder.ticks + 1) * decoder.config["frame_period_ms"] / 1000 if decoder.frames else 0,
                        completion_status="imported", ended_at=now())
        except Exception as exc:
            meta.update(completion_status="incomplete", interruption_reason=f"Import failed: {exc}", ended_at=now())
            raise
        finally:
            atomic_json(directory / "session.json", meta)
        return meta

    def bundle(self, session_id):
        with self.lock:
            if self.active and self.active["meta"]["id"] == session_id:
                raise ValueError("Stop the recording before exporting its bundle.")
            # Snapshot mutable small files, then release the recording lock before
            # compressing an older capture. Export must not stall a new recording.
            metadata = {name: self.path(session_id, name).read_bytes() for name in ("session.json", "annotations.json")}
            files = {name: self.path(session_id, name) for name in ("stream.dat", "profile.cfg", "console.log")}
        # Spooled output avoids keeping a second entire capture in RAM.
        import tempfile
        output = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024)
        try:
            with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
                for name, path in files.items():
                    archive.write(path, f"{session_id}/{name}")
                for name, contents in metadata.items():
                    archive.writestr(f"{session_id}/{name}", contents)
            output.seek(0)
            return output
        except Exception:
            output.close()
            raise
