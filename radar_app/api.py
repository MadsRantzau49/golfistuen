"""Same-origin local API and the integrated workspace."""
from __future__ import annotations

import asyncio
import fcntl
import json
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .analysis import export_csv, inspect
from .configuration import validate
from .serial_service import RadarService
from .storage import SessionStore, atomic_json, read_text_exact, safe_child

ROOT = Path(__file__).resolve().parents[1]
STATIC = Path(__file__).with_name("static")


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class ConfigText(Model):
    text: str = Field(max_length=256_000)


class SaveConfig(ConfigText):
    name: str = Field(max_length=180)


class Connect(Model):
    command_port: str = Field(max_length=200)
    data_port: str = Field(max_length=200)
    command_baud: int = Field(default=115200, ge=1200, le=3_000_000)
    data_baud: int = Field(default=921600, ge=1200, le=3_000_000)


class Label(Model):
    label: str = Field(default="", max_length=200)
    notes: str = Field(default="", max_length=20_000)


class ImportPair(Label):
    dat: str = Field(max_length=180)
    cfg: str = Field(max_length=180)


class Filters(Model):
    rmin: float = Field(default=0, ge=0)
    rmax: float = Field(default=1e9, ge=0)
    vmin: float = Field(default=0, ge=0)
    vmax: float = Field(default=1e9, ge=0)
    snr: float = -1e9
    direction: str = Field(default="all", pattern="^(all|away|toward)$")


class Selection(Model):
    impact_s: float | None = Field(default=None, ge=0)
    from_s: float = Field(default=0, ge=0)
    to_s: float = Field(default=0, ge=0)
    points: list[tuple[int, int]] = Field(default_factory=list, max_length=100_000)
    filters: Filters = Field(default_factory=Filters)
    manual_only: bool = False


def create_app(root=ROOT, service_factory=None):
    store = SessionStore(Path(root))
    radar = service_factory(store) if service_factory else RadarService(store)

    @asynccontextmanager
    async def lifespan(app):
        # Single backend process owns both session recovery and serial devices.
        with (store.sessions / ".workbench.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Another radar workbench is already using this logs/sessions directory.") from None
            await asyncio.to_thread(store.recover)
            try:
                yield
            finally:
                await asyncio.to_thread(radar.disconnect, "Application shutdown")

    # Default Swagger/ReDoc pages load CDN assets; keep the application fully local.
    app = FastAPI(title="Golfistuen local radar workbench", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.store, app.state.radar = store, radar
    hosts = ["127.0.0.1", "localhost", "[::1]"]
    if service_factory is not None:
        hosts.append("testserver")  # Explicit in-process test apps only.
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=hosts)

    @app.middleware("http")
    async def local_requests(request: Request, call_next):
        if request.method in {"POST", "PUT", "PATCH", "DELETE"}:
            expected = f"{request.url.scheme}://{request.headers.get('host', '')}"
            origin = request.headers.get("origin")
            if (origin is not None and origin != expected) or request.headers.get("sec-fetch-site") == "cross-site" or request.headers.get("x-radar-local") != "1":
                return JSONResponse({"detail": "Use the same-origin local UI (X-Radar-Local header required)."}, status_code=403)
            if int(request.headers.get("content-length", "0")) > 1_000_000:
                return JSONResponse({"detail": "Request exceeds 1 MB."}, status_code=413)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "same-origin"
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' blob:; frame-ancestors 'self'; object-src 'none'; base-uri 'none'"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.exception_handler(ValueError)
    async def invalid(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=400)

    @app.exception_handler(OSError)
    async def io_error(request, exc):
        return JSONResponse({"detail": f"Local I/O failed: {exc}. Check file permissions, available disk space and USB connection."}, status_code=400)

    @app.get("/", response_class=HTMLResponse)
    def home():
        return (STATIC / "index.html").read_text()

    @app.get("/viewer", response_class=HTMLResponse)
    def viewer():
        template = (STATIC / "viewer.html").read_text()
        return template.replace("</body>", '<script src="/static/viewer-extension.js"></script></body>')

    @app.get("/api/status")
    def status():
        return radar.status()

    @app.get("/api/ports")
    def ports():
        return radar.ports()

    @app.post("/api/connect")
    def connect(body: Connect):
        return radar.connect(**body.model_dump())

    @app.post("/api/disconnect")
    def disconnect():
        return radar.disconnect()

    @app.get("/api/configs")
    def configs():
        return sorted(p.name for p in store.configs.glob("*.cfg") if p.is_file() and not p.is_symlink())

    @app.get("/api/configs/{name}")
    def config(name: str):
        path = safe_child(store.configs, name)
        if path.suffix != ".cfg":
            raise ValueError("Choose a .cfg file.")
        return dict(name=name, text=read_text_exact(path, encoding="utf-8-sig"))

    @app.post("/api/configs/validate")
    def config_validate(body: ConfigText):
        return validate(body.text)

    @app.post("/api/configs/save")
    def config_save(body: SaveConfig):
        validate(body.text)
        path = safe_child(store.configs, body.name)
        if path.suffix != ".cfg":
            raise ValueError("New configuration filename must end in .cfg.")
        with path.open("x", encoding="utf-8", newline="") as handle:
            handle.write(body.text)
        return dict(name=body.name)

    @app.post("/api/configs/apply")
    def config_apply(body: ConfigText):
        return radar.apply(body.text)

    @app.post("/api/sensor/{action}")
    def sensor(action: str):
        if action not in {"start", "stop"}:
            raise ValueError("Unknown sensor action.")
        return radar.sensor(action == "start")

    @app.post("/api/recording/start")
    def recording_start(body: Label):
        return radar.start_recording(body.label, body.notes)

    @app.post("/api/recording/stop")
    def recording_stop():
        return store.stop()

    @app.get("/api/sessions")
    def sessions():
        return store.list_sessions()

    @app.get("/api/import-files")
    def import_files():
        return {suffix[1:]: sorted(p.name for p in store.logs.glob(f"*{suffix}") if p.is_file() and not p.is_symlink()) for suffix in (".dat", ".cfg")}

    @app.post("/api/sessions/import")
    def import_session(body: ImportPair):
        return store.import_pair(body.dat, body.cfg, body.label, body.notes)

    @app.get("/api/demo")
    def demo():
        from .analyzer import analyze
        directory = Path(__file__).with_name("example_input")
        return analyze((directory / "recording.dat").read_bytes(), (directory / "profile.cfg").read_text(), "DEMO: existing recording.dat", "example_input/profile.cfg")

    @app.post("/api/demo/analysis")
    def demo_analysis(body: Selection):
        return inspect(demo(), body.model_dump())

    @app.get("/api/sessions/{session_id}")
    def session(session_id: str):
        return dict(metadata=store.metadata(session_id),
                    annotations=json.loads(store.path(session_id, "annotations.json").read_text()),
                    console=store.path(session_id, "console.log").read_text(errors="replace"),
                    cfg_text=read_text_exact(store.path(session_id, "profile.cfg")))

    @app.patch("/api/sessions/{session_id}")
    def update_session(session_id: str, body: Label):
        return store.update(session_id, body.label, body.notes)

    @app.get("/api/sessions/{session_id}/replay")
    def replay(session_id: str):
        return store.replay(session_id)

    @app.get("/api/sessions/{session_id}/bundle")
    def bundle(session_id: str):
        output = store.bundle(session_id)
        def chunks():
            try:
                while chunk := output.read(65536):
                    yield chunk
            finally:
                output.close()
        return StreamingResponse(chunks(), media_type="application/zip", headers={"Content-Disposition": f'attachment; filename="{session_id}.zip"'})

    def checked_selection(session_id, body):
        recording = store.replay(session_id)
        if body.to_s < body.from_s or body.to_s > recording["summary"]["duration_s"] + 1e-6:
            raise ValueError("Select an interval within this recording.")
        if body.impact_s is not None and body.impact_s > recording["summary"]["duration_s"]:
            raise ValueError("Impact time is outside this recording.")
        for i, j in body.points:
            if i < 0 or i >= len(recording["frames"]) or j < 0 or j >= len(recording["frames"][i]["points"]):
                raise ValueError("A manually selected point does not exist in this recording.")
        return recording, body.model_dump()

    @app.put("/api/sessions/{session_id}/annotations")
    def annotations(session_id: str, body: Selection):
        _, value = checked_selection(session_id, body)
        atomic_json(store.path(session_id, "annotations.json"), value)
        return value

    @app.post("/api/sessions/{session_id}/analysis")
    def analysis(session_id: str, body: Selection):
        recording, value = checked_selection(session_id, body)
        return inspect(recording, value)

    @app.post("/api/sessions/{session_id}/csv")
    def csv(session_id: str, body: Selection):
        recording, value = checked_selection(session_id, body)
        return Response(export_csv(recording, value, body.manual_only), media_type="text/csv", headers={"Content-Disposition": 'attachment; filename="radar_points.csv"'})

    @app.websocket("/ws")
    async def live(websocket: WebSocket):
        expected = f"{'https' if websocket.url.scheme == 'wss' else 'http'}://{websocket.headers.get('host', '')}"
        if websocket.headers.get("origin") != expected:
            await websocket.close(code=1008, reason="Same-origin local UI required")
            return
        await websocket.accept()
        last_console = 0
        sequence = 0
        try:
            while True:
                state = radar.status()
                entries = [c for c in state.pop("console") if c["seq"] > last_console]
                if entries:
                    last_console = entries[-1]["seq"]
                # At most one unacknowledged display snapshot per browser. While
                # waiting for rendering, readers/capture continue and old updates
                # are never enqueued. The next snapshot is the latest, not a backlog.
                sequence += 1
                await asyncio.wait_for(websocket.send_json(dict(seq=sequence, status=state, console=entries, live=radar.live())), timeout=0.75)
                acknowledgement = await asyncio.wait_for(websocket.receive_json(), timeout=20)
                if acknowledgement != {"ack": sequence}:
                    await websocket.close(code=1008, reason="Display acknowledgement required")
                    return
                await asyncio.sleep(0.1)
        except (WebSocketDisconnect, asyncio.TimeoutError, RuntimeError, OSError, ValueError):
            pass
        finally:
            try:
                await websocket.close()
            except (RuntimeError, OSError):
                pass

    app.mount("/static", StaticFiles(directory=STATIC), name="static")
    return app


app = create_app()
