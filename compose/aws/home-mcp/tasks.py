"""Voice coding tasks (Milestone 18 phase 3, ADR-0021).

home-mcp never touches git, GitHub or Claude Code itself. It talks to the
worker on nuc4 over SSH as `voiceworker`, whose key is locked (on nuc4's
side) to one forced command -- dispatch.py: queue a task, read status --
and to this hub's WireGuard address. nuc4's host key is pinned, so a
spoofed host on the path can't impersonate the worker.

Kill switch: VOICE_TASKS_ENABLED=false (compose env) refuses new tasks
while leaving status readable; disabling the Authentik app stops
everything.
"""

import asyncio
import base64
import json
import logging
import os
import smtplib
import time
from email.message import EmailMessage
from pathlib import Path

log = logging.getLogger("home-mcp.tasks")

WORKER = os.environ.get("VOICE_WORKER_HOST", "voiceworker@10.0.1.34")
ENABLED = os.environ.get("VOICE_TASKS_ENABLED", "false").lower() == "true"
ALLOWED_REPOS = [r.strip() for r in os.environ.get("VOICE_ALLOWED_REPOS", "todo-app").split(",") if r.strip()]
KEY_PATH = Path("/tmp/voice-worker-key")
KNOWN_HOSTS = Path("/tmp/voice-worker-known-hosts")


def _prepare_ssh() -> bool:
    key_b64 = os.environ.get("VOICE_WORKER_SSH_KEY_B64", "")
    host_key = os.environ.get("VOICE_WORKER_HOST_KEY", "")
    if not key_b64 or not host_key:
        return False
    if not KEY_PATH.exists():
        KEY_PATH.write_bytes(base64.b64decode(key_b64))
        KEY_PATH.chmod(0o600)
        KNOWN_HOSTS.write_text(host_key.strip() + "\n")
    return True


async def _ssh(command: str, stdin: bytes = b"") -> dict:
    if not _prepare_ssh():
        return {"error": "voice worker SSH credentials aren't configured on the hub"}
    argv = [
        "ssh", "-F", "/dev/null", "-i", str(KEY_PATH),
        "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={KNOWN_HOSTS}",
        "-o", "ConnectTimeout=10",
        WORKER, command,
    ]
    proc = await asyncio.create_subprocess_exec(
        *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        env={**os.environ, "HOME": "/tmp"},
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(stdin), timeout=30)
    except asyncio.TimeoutError:
        proc.kill()
        return {"error": "the worker on nuc4 didn't answer within 30 seconds"}
    try:
        return json.loads(out.decode().strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        log.warning("worker ssh failed rc=%s: %s", proc.returncode, err.decode(errors="replace")[-300:])
        return {"error": "couldn't reach the worker on nuc4"}


def _email(subject: str, body: str) -> None:
    password = os.environ.get("SMTP_PASSWORD", "")
    if not password:
        return
    msg = EmailMessage()
    msg["From"] = msg["To"] = "bcalaway@gmail.com"
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        with smtplib.SMTP("smtp.gmail.com", 587, timeout=15) as s:
            s.starttls()
            s.login("bcalaway@gmail.com", password)
            s.send_message(msg)
    except Exception as exc:  # noqa: BLE001 -- a notification failure must not fail the task
        log.warning("start email failed: %s", exc)


def _spoken(s: dict) -> str:
    if "error" in s:
        return s["error"]
    tid, state = s.get("id", "?"), s.get("state")
    if state == "queued":
        return f"Task {tid} is queued."
    if state == "running":
        mins = round((time.time() - s.get("started_at", time.time())) / 60)
        return f"Task {tid} is running: {s.get('step', 'working')}, {mins} minutes in."
    if state == "done" and s.get("pr_url"):
        summary = s.get("summary", "")
        return f"Task {tid} finished in {s.get('minutes')} minutes. Pull request {s.get('pr_number')} is open: {s['pr_url']}. {summary}"
    if state == "done":
        return f"Task {tid} finished: {s.get('message', 'no changes')}"
    if state == "failed":
        return f"Task {tid} failed: {s.get('error', 'unknown error')}"
    return json.dumps(s)


async def start_task(repo: str, instructions: str, user: str | None) -> str:
    if not ENABLED:
        return "Voice coding tasks are switched off on the hub right now."
    if repo not in ALLOWED_REPOS:
        return f"I can only work on {', '.join(ALLOWED_REPOS)} for now."
    result = await _ssh("start", json.dumps({"repo": repo, "instructions": instructions, "requested_by": user or ""}).encode())
    if "error" in result:
        return f"Couldn't start the task: {result['error']}"
    tid = result["id"]
    await asyncio.to_thread(
        _email,
        f"[home-mcp] Voice coding task started: {repo} ({tid})",
        f"A voice coding task was queued on nuc4 by {user}.\n\nRepo: {repo}\nTask: {tid}\n\n{instructions}\n\n"
        "It will open a PR on a voice/ branch and never merge. To stop new tasks, set "
        "VOICE_TASKS_ENABLED=false for home-mcp or disable the home-mcp app in Authentik.",
    )
    return f"Started task {tid} on {repo}. It usually takes 5 to 20 minutes; ask me for its status any time."


async def task_status(task_id: str = "") -> str:
    if task_id == "all":
        result = await _ssh("list")
        tasks = result.get("tasks", [])
        if "error" in result:
            return result["error"]
        return " ".join(_spoken(t) for t in tasks) if tasks else "No voice tasks yet."
    return _spoken(await _ssh(f"status {task_id}".strip()))
