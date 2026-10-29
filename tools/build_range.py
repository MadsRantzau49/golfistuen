#!/usr/bin/env python3
"""Developer release builder. Players only need the resulting executable.

python3 tools/build_range.py --target linux windows
Downloads checksum-verified official export templates once; exports embedded-PCK
release binaries, player instructions, notices, ZIPs, and a SHA256 manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import urllib.request
import zipfile

from run_range import BASE_URL, PROJECT, ROOT, VERSION, find_engine

APP_VERSION = "0.2.0"
TEMPLATE_SHA512 = "8a65c73541184fbcf1a7afedb37c9c15ed0f3babdaafe36ff47ccc515548ac84bc7563ba5b94c253e6085b121ac608b7e03d35dfc0b2c8c690a646a8755b57e5"
TARGETS = {
    "linux": ("Linux", "Pinewater", ["linux_release.x86_64", "linux_debug.x86_64"]),
    "windows": ("Windows", "Pinewater.exe", ["windows_release_x86_64.exe", "windows_debug_x86_64.exe"]),
    "macos": ("macOS", "Pinewater.zip", ["macos.zip"]),
}


def fetch(url: str, destination: Path, expected: str) -> None:
    if destination.is_file() and digest(destination, "sha512") == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(".part")
    request = urllib.request.Request(url, headers={"User-Agent": "Golfistuen-Build/0.2"})
    print(f"Downloading {destination.name} (official desktop template bundle, ~1.3 GB; cached).", flush=True)
    hasher = hashlib.sha512()
    with urllib.request.urlopen(request, timeout=90) as response, partial.open("wb") as output:
        while chunk := response.read(4 * 1024 * 1024):
            hasher.update(chunk)
            output.write(chunk)
    if hasher.hexdigest() != expected:
        partial.unlink(missing_ok=True)
        raise RuntimeError("Official export-template checksum mismatch.")
    partial.replace(destination)


def digest(path: Path, algorithm="sha256") -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as source:
        while chunk := source.read(4 * 1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def template_directory() -> Path:
    if platform.system() == "Windows":
        base = Path(os.environ["APPDATA"]) / "Godot"
    elif platform.system() == "Darwin":
        base = Path.home() / "Library/Application Support/Godot"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "godot"
    return base / "export_templates" / f"{VERSION}.stable"


def install_templates(targets: list[str]) -> None:
    destination = template_directory()
    required = {name for target in targets for name in TARGETS[target][2]}
    if all((destination / name).is_file() for name in required):
        return
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "golfistuen"
    archive = cache / f"Godot_v{VERSION}-stable_export_templates.tpz"
    fetch(f"{BASE_URL}/{archive.name}", archive, TEMPLATE_SHA512)
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        for name in required:
            target = destination / name
            with bundle.open(f"templates/{name}") as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(target.stat().st_mode | stat.S_IXUSR)


def checked(command: list[str], timeout=300) -> None:
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, encoding="utf-8", errors="replace",
                            timeout=timeout, check=False)
    # Godot sometimes reports script/asset errors without a failing process code.
    if result.returncode or "SCRIPT ERROR:" in result.stdout or "ERROR:" in result.stdout:
        print(result.stdout, end="", flush=True)
        raise RuntimeError(f"Build/check failed: {' '.join(command)}")
    for line in result.stdout.splitlines():
        if line.startswith(("PASS:", "PACKAGED APP PASS:", "PACKAGED HOLE PASS:", "PACKAGED MATCH PASS:", "Driver:", "7 Iron:", "Wedge:", "WARNING:")):
            print(line, flush=True)


def package(binary: Path, target: str, output: Path) -> Path:
    directory = binary.parent
    shutil.copyfile(PROJECT / "PLAYER_GUIDE.txt", directory / "READ ME.txt")
    licenses = directory / "licenses"
    licenses.mkdir(exist_ok=True)
    for name, source in {
        "Outfit-OFL.txt": PROJECT / "assets/OFL.txt",
        "Fraunces-OFL.txt": PROJECT / "assets/Fraunces-OFL.txt",
        "Godot-LICENSE.txt": PROJECT / "licenses/Godot-LICENSE.txt",
        "Godot-COPYRIGHT.txt": PROJECT / "licenses/Godot-COPYRIGHT.txt",
        "ambientCG-Grass004.txt": PROJECT / "licenses/ambientCG-Grass004.txt",
    }.items():
        shutil.copyfile(source, licenses / name)
    if target == "linux":
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        fallback = directory / "Play with OpenGL.sh"
        fallback.write_text('#!/bin/sh\nHERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$HERE/Pinewater" --rendering-method gl_compatibility "$@"\n')
        fallback.chmod(0o755)
    archive = output / f"Pinewater-{APP_VERSION}-{target}-{'universal' if target == 'macos' else 'x86_64'}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
        for path in sorted(directory.rglob("*")):
            if path.is_file():
                bundle.write(path, Path(directory.name) / path.relative_to(directory))
    return archive


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, nargs="+", default=["linux"])
    parser.add_argument("--godot")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/pinewater" / APP_VERSION)
    parser.add_argument("--skip-checks", action="store_true", help="For iteration only; CI always runs checks")
    args = parser.parse_args()
    binary = find_engine(args.godot)
    version = subprocess.check_output([str(binary), "--version"], text=True).strip()
    if not version.startswith(VERSION + ".stable"):
        raise RuntimeError(f"Release builds require Godot {VERSION}.stable; found {version}.")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    command = [str(binary), "--headless", "--path", str(PROJECT)]
    checked(command + ["--editor", "--import"])
    if not args.skip_checks:
        checked(command + ["--script", "res://tests/range_checks.gd"])
        checked(command + ["--script", "res://tests/application_checks.gd"])
        checked(command + ["--script", "res://tests/camera_checks.gd"])
        checked(command + ["--script", "res://tests/hole_checks.gd"])
        checked(command + ["--script", "res://tests/hole_workspace_checks.gd"])
        checked(command + ["--script", "res://tests/hole_app_checks.gd"])
        checked(command + ["--script", "res://tests/match_checks.gd"])
        checked(command + ["--script", "res://tests/match_app_checks.gd"])
        checked(command + ["--script", "res://tests/radar_checks.gd"])
    install_templates(args.target)
    manifest = {"application": "Pinewater", "version": APP_VERSION, "engine": version, "artifacts": []}
    for target in args.target:
        preset, filename, _ = TARGETS[target]
        destination = args.output / f"Pinewater-{target}"
        destination.mkdir(exist_ok=True)
        executable = destination / filename
        checked(command + ["--export-release", preset, str(executable)])
        print(f"{target}: native release exported to {executable}", flush=True)
        if not executable.is_file() or executable.stat().st_size < 1024 * 1024:
            raise RuntimeError(f"Expected native executable was not produced: {executable}")
        if target == "linux" and platform.system() == "Linux":
            checked([str(executable), "--headless", "--", "--smoke-app"])
            checked([str(executable), "--headless", "--", "--smoke-holes"])
            checked([str(executable), "--headless", "--", "--smoke-match"])
        if target == "windows" and platform.system() == "Windows":
            checked([str(executable), "--headless", "--", "--smoke-app"])
            checked([str(executable), "--headless", "--", "--smoke-holes"])
            checked([str(executable), "--headless", "--", "--smoke-match"])
        archive = package(executable, target, args.output)
        manifest["artifacts"].append({"file": archive.name, "sha256": digest(archive), "bytes": archive.stat().st_size})
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.output / "SHA256SUMS.txt").write_text("".join(f"{item['sha256']}  {item['file']}\n" for item in manifest["artifacts"]))
    print(f"Player-ready packages: {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"Release build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
