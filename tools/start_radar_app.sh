#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"
if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  printf '%s\n' 'Install first: python3 -m venv .venv && .venv/bin/python -m pip install -r requirements.txt' >&2
  exit 1
fi
# Resolve imports from the repository independently of the caller's directory.
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
exec "$ROOT/.venv/bin/python" -m uvicorn radar_app.api:app --host 127.0.0.1 --port 8000 --workers 1
