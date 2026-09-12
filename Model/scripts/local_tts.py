"""Cross-platform service lifecycle. Run with the isolated TTS environment's Python."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "logs" / "local_tts.json"
PORT = int(os.getenv("LOCAL_TTS_PORT", "8767"))


def health() -> dict:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=1) as response:
            return json.load(response)
    except (OSError, ValueError):
        return {}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["start", "stop", "status"])
    args = parser.parse_args()
    if not 1024 <= PORT <= 65535:
        raise SystemExit("Invalid LOCAL_TTS_PORT")
    current = health()
    if args.action == "status":
        print(json.dumps(current or {"status": "offline"}))
        raise SystemExit(0 if current.get("status") == "ready" else 1)
    if args.action == "stop":
        if not STATE.exists():
            raise SystemExit("No managed TTS process. Stop a foreground service in its own terminal.")
        state = json.loads(STATE.read_text())
        if not current or current.get("instance") != state["instance"] or current.get("pid") != state["pid"]:
            raise SystemExit("Service identity not verified; refusing to terminate a possibly unrelated process.")
        os.kill(state["pid"], signal.SIGTERM)
        for _ in range(50):
            if health().get("instance") != state["instance"]:
                STATE.unlink(missing_ok=True)
                print("Local TTS stopped.")
                return
            time.sleep(0.1)
        raise SystemExit("TTS shutdown still in progress; state file retained.")
    if current:
        raise SystemExit("Port already serves a process; use status or stop its owner first.")
    STATE.parent.mkdir(parents=True, exist_ok=True)
    instance = uuid.uuid4().hex
    env = dict(os.environ, LOCAL_TTS_INSTANCE=instance)
    with (ROOT / "logs" / "local_tts.log").open("ab") as log:
        process = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "tts_service.app:app", "--host", "127.0.0.1",
             "--port", str(PORT), "--no-access-log"],
            cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=os.name != "nt",
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
    STATE.write_text(json.dumps({"pid": process.pid, "instance": instance, "port": PORT}))
    for _ in range(100):
        current = health()
        if current.get("instance") == instance and current.get("status") == "ready":
            print(f"Local CPU TTS ready on 127.0.0.1:{PORT}, PID {process.pid}")
            return
        if process.poll() is not None:
            STATE.unlink(missing_ok=True)
            raise SystemExit("TTS startup failed; see logs/local_tts.log")
        time.sleep(0.2)
    raise SystemExit("TTS still loading; inspect status and logs. Managed process left running.")


if __name__ == "__main__":
    main()
