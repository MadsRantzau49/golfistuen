#!/usr/bin/env python3
"""Build and launch Pinewater's native release. Python standard library only.

Uses --godot, GODOT_BIN, an installed Godot 4, or a checksum-verified local
download, in that order. The engine is cached outside the repository.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "golf_game"
VERSION = "4.5.1"
BASE_URL = f"https://github.com/godotengine/godot/releases/download/{VERSION}-stable"
# Official release SHA512 checksums, pinned with the engine version.
RELEASES = {
    ("Linux", "x86_64"): ("linux.x86_64.zip", "Godot_v4.5.1-stable_linux.x86_64",
        "5bccbed65a94b82c7c319fdb15719ee8113a6e503976cc54e16f1c61fe95f3d74e5e40b8449b5bb89ff7f424574c20af01a4f5ef08b389e4dc338b245185b0b9"),
    ("Linux", "arm64"): ("linux.arm64.zip", "Godot_v4.5.1-stable_linux.arm64",
        "9d55e9cdccaa4b6528d0b39824d51c47987667babffbab7f83b05fba2ece842a59752b84128332421c9d261fe06846b88480f3b0171af255ea99383d3bc96b2c"),
    ("Windows", "x86_64"): ("win64.exe.zip", "Godot_v4.5.1-stable_win64.exe",
        "ab84df90ead5a888530faaabe744a27678ef7635068883900174fae37f7fc6178d033b551d88963c7dc2466580915a582bbc79aca97c19085900655761f56a27"),
    ("Windows", "arm64"): ("windows_arm64.exe.zip", "Godot_v4.5.1-stable_windows_arm64.exe",
        "c0329c5170cdecb9768d93fe9069e104cb99fff0c59d58ac2048683199f757171be38c27c661c8d63a16062763204b6a87048034d1bfa273c8c4a2662ce434f7"),
    ("Darwin", "universal"): ("macos.universal.zip", "Godot.app/Contents/MacOS/Godot",
        "a91a7c3bb2faefafef41624fbd75705b91aec509823d41db595a38b79819e0f2e9c85eecdc7429c3159d8070604a3f4b4425aaa6094d7bcac147f52c89181ce9"),
}


def release_info() -> tuple[str, str, str]:
    system = platform.system()
    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "aarch64": "arm64"}.get(machine, machine)
    if system == "Darwin":
        arch = "universal"
    try:
        return RELEASES[system, arch]
    except KeyError:
        raise RuntimeError(f"No automatic Godot download for {system}/{machine}. Install Godot {VERSION} and pass --godot PATH.") from None


def download_engine() -> Path:
    suffix, executable, checksum = release_info()
    cache_base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    cache = cache_base / "golfistuen" / f"godot-{VERSION}-{platform.system()}-{platform.machine()}"
    binary = cache / executable
    if binary.is_file():
        return binary
    cache.mkdir(parents=True, exist_ok=True)
    name = f"Godot_v{VERSION}-stable_{suffix}"
    print(f"Downloading Godot {VERSION} from the official release (~70 MB). First launch only.", flush=True)
    request = urllib.request.Request(f"{BASE_URL}/{name}", headers={"User-Agent": "Golfistuen-Range/1.0"})
    with tempfile.TemporaryDirectory(prefix="golfistuen-") as temporary:
        archive = Path(temporary) / name
        digest = hashlib.sha512()
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                digest.update(chunk)
        if digest.hexdigest() != checksum:
            raise RuntimeError("Godot release checksum did not match. Download was not installed.")
        with zipfile.ZipFile(archive) as bundle:
            if platform.system() == "Darwin":
                for member in bundle.infolist():
                    destination = (cache / member.filename).resolve()
                    if not destination.is_relative_to(cache.resolve()):
                        raise RuntimeError("Unexpected path in Godot archive.")
                bundle.extractall(cache)
            else:
                # Only extract the executable; do not install unrelated archive paths.
                with bundle.open(executable) as source, binary.with_suffix(".part").open("wb") as output:
                    shutil.copyfileobj(source, output)
                binary.with_suffix(".part").replace(binary)
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    print(f"Godot cached at {binary}", flush=True)
    return binary


def find_engine(explicit: str | None) -> Path:
    selected = explicit or os.environ.get("GODOT_BIN")
    if selected:
        executable = shutil.which(selected) or selected
        binary = Path(executable).expanduser().resolve()
        if not binary.is_file():
            raise RuntimeError(f"Godot executable does not exist: {binary}")
        return binary
    for name in ("godot4", "godot", "Godot"):
        found = shutil.which(name)
        if found:
            return Path(found)
    return download_engine()


def run(command: list[str], timeout: int | None = None) -> int:
    return subprocess.run(command, cwd=ROOT, timeout=timeout, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help=f"Path to a Godot {VERSION} executable")
    parser.add_argument("--check", action="store_true", help="Run headless contract, physics, and integration checks")
    parser.add_argument("--fullscreen", action="store_true", help="Start the game fullscreen")
    args = parser.parse_args()
    binary = find_engine(args.godot)
    version = subprocess.check_output([str(binary), "--version"], text=True, timeout=15).strip()
    if not version.startswith(f"{VERSION}.stable"):
        raise RuntimeError(f"Godot {VERSION} stable is required; found {version}.")
    command = [str(binary), "--path", str(PROJECT)]
    # Registers global classes and imports bundled fonts/textures on a fresh clone.
    result = run(command + ["--headless", "--editor", "--import"], timeout=120)
    if result:
        return result
    if args.check:
        for script in ("range_checks.gd", "application_checks.gd", "camera_checks.gd", "hole_checks.gd", "hole_workspace_checks.gd", "hole_app_checks.gd", "match_checks.gd", "match_app_checks.gd", "radar_checks.gd"):
            result = run(command + ["--headless", "--script", f"res://tests/{script}"], timeout=120)
            if result:
                return result
        return 0
    system = platform.system()
    targets = {
        "Linux": ("Linux", "linux/Pinewater"),
        "Windows": ("Windows", "windows/Pinewater.exe"),
        "Darwin": ("macOS", "macos/Pinewater.app"),
    }
    if system not in targets:
        raise RuntimeError(f"No release export preset for {system}.")
    if system != "Darwin" and platform.machine().lower() not in ("x86_64", "amd64"):
        raise RuntimeError("The Linux and Windows release presets target x86-64.")
    preset, relative_path = targets[system]
    output = PROJECT / "exports" / relative_path
    output.parent.mkdir(parents=True, exist_ok=True)
    print(f"Building {preset} release: {output}", flush=True)
    result = run(command + ["--headless", "--export-release", preset, str(output)], timeout=300)
    if result:
        return result
    launch = [str(output)] if system != "Darwin" else ["open", "-W", str(output)]
    if args.fullscreen:
        if system == "Darwin":
            launch.append("--args")
        launch.append("--fullscreen")
    print("Opening Pinewater release. Choose Enter the range to play.", flush=True)
    return run(launch)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (OSError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"Could not start the range: {error}", file=sys.stderr)
        raise SystemExit(1)
