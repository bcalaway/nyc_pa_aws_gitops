#!/usr/bin/python3
"""SSH forced command for the `voiceworker` user (Milestone 18 phase 3, ADR-0021).

This is the ONLY thing the hub's home-mcp can run on this NUC: its key in
~voiceworker/.ssh/authorized_keys is `restrict,from="10.0.3.1",command=...`
pointing here. It validates a request and drops it in the queue; it never
touches git, Docker, or any credential -- the root-owned runner
(runner.py) does the actual work. Stdlib only.

  start           JSON on stdin: {"repo": "...", "instructions": "..."}
  status [<id>]   one task's status, or the most recent task's
  list            the 5 most recent tasks
"""

import json
import os
import re
import secrets
import sys
import time
from pathlib import Path

BASE = Path("/var/lib/voice-worker")
QUEUE = BASE / "queue"
STATUS = BASE / "status"
CONFIG = json.loads(Path("/etc/voice-worker/config.json").read_text())
MAX_INSTRUCTIONS = 4000
ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-z0-9]{4}$")


def out(obj, code=0):
    print(json.dumps(obj))
    sys.exit(code)


def load_status(task_id):
    p = STATUS / f"{task_id}.json"
    if p.exists():
        return json.loads(p.read_text())
    if (QUEUE / f"{task_id}.json").exists():
        return {"id": task_id, "state": "queued"}
    return None


def recent(n):
    ids = {p.stem for p in STATUS.glob("*.json")} | {p.stem for p in QUEUE.glob("*.json")}
    return [load_status(i) for i in sorted(ids, reverse=True)[:n]]


def main():
    argv = os.environ.get("SSH_ORIGINAL_COMMAND", "").split()
    cmd = argv[0] if argv else ""

    if cmd == "start":
        try:
            req = json.loads(sys.stdin.read(MAX_INSTRUCTIONS * 2))
        except json.JSONDecodeError:
            out({"error": "request must be JSON"}, 2)
        repo, instructions = req.get("repo", ""), (req.get("instructions") or "").strip()
        if repo not in CONFIG["allowed_repos"]:
            out({"error": f"repo {repo!r} is not allowed; allowed: {CONFIG['allowed_repos']}"}, 2)
        if not instructions or len(instructions) > MAX_INSTRUCTIONS:
            out({"error": f"instructions must be 1-{MAX_INSTRUCTIONS} characters"}, 2)
        active = [s for s in recent(20) if s and s.get("state") in ("queued", "running")]
        if len(active) >= CONFIG["max_active"]:
            out({"error": f"{len(active)} tasks already queued or running; try again when one finishes"}, 3)
        task_id = time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(2)
        tmp = QUEUE / f".{task_id}.tmp"
        tmp.write_text(json.dumps({
            "id": task_id,
            "repo": repo,
            "instructions": instructions,
            "requested_by": str(req.get("requested_by", ""))[:64],
            "queued_at": int(time.time()),
        }))
        tmp.rename(QUEUE / f"{task_id}.json")
        out({"id": task_id, "state": "queued"})

    if cmd == "status":
        task_id = argv[1] if len(argv) > 1 else ""
        if task_id and not ID_RE.match(task_id):
            out({"error": "bad task id"}, 2)
        if not task_id:
            latest = recent(1)
            out(latest[0] if latest else {"error": "no tasks yet"})
        s = load_status(task_id)
        out(s if s else {"error": f"no task {task_id}"}, 0 if s else 4)

    if cmd == "list":
        out({"tasks": [s for s in recent(5) if s]})

    out({"error": "usage: start | status [<id>] | list"}, 2)


if __name__ == "__main__":
    main()
