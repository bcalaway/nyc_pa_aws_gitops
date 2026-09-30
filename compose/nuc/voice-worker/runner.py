#!/usr/bin/python3
"""Voice-task runner (Milestone 18 phase 3, ADR-0021). Runs as root under
systemd (voice-worker-runner.service); stdlib only.

Picks queued tasks (written by dispatch.py) one at a time and turns each
into a PR:

  1. Clone the repo twice from the public URL (no credentials):
       pristine/  -- never shown to the agent; the only tree this process
                     ever runs git in with the GitHub token
       work/      -- handed to the agent container
  2. Run headless Claude Code in a throwaway container on work/: no GitHub
     credentials, no host mounts beyond work/, egress only via the
     allowlisting proxy (Anthropic + PyPI), non-root, caps dropped.
  3. Export the agent's changes as a patch FROM INSIDE a second no-network
     container. The agent controls everything in work/ -- including
     .git/hooks and .git/config -- so this process never runs git there;
     a patch is inert data.
  4. Reject patches touching .github/ (CI/CD) or git metadata, apply the
     patch to pristine/, commit, push voice/<id>, open a PR. Never merge:
     the token isn't even asked to.

Status is written to /var/lib/voice-worker/status/<id>.json, which
dispatch.py (the SSH forced command) reads back for home-mcp.
"""

import base64
import json
import logging
import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = Path("/var/lib/voice-worker")
QUEUE, STATUS, TASKS = BASE / "queue", BASE / "status", BASE / "tasks"
ETC = Path("/etc/voice-worker")
AGENT_IMAGE = "voice-agent:latest"
AGENT_NETWORK = "voice-agent-net"
PROXY = "http://voice-proxy:3128"
AGENT_UID = 10001
FORBIDDEN_PATHS = re.compile(r"^(\.github/|\.git/|\.gitmodules$|\.gitattributes$)")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("voice-runner")


def config():
    return json.loads((ETC / "config.json").read_text())


def secret(name):
    return (ETC / name).read_text().strip()


def write_status(task, **fields):
    task.update(fields, updated_at=int(time.time()))
    tmp = STATUS / f".{task['id']}.tmp"
    tmp.write_text(json.dumps(task))
    tmp.chmod(0o644)
    tmp.rename(STATUS / f"{task['id']}.json")
    log.info("task %s -> %s", task["id"], task.get("state"))


def run(argv, cwd=None, timeout=600, env=None, input_bytes=None):
    return subprocess.run(argv, cwd=cwd, timeout=timeout, env=env, input=input_bytes, capture_output=True, check=True)


def git(repo_dir, *args, token=None, timeout=300):
    """git in the PRISTINE clone only. Hooks off, no inherited config beyond ours.

    The token goes in via GIT_CONFIG_* environment variables, not argv --
    argv is world-readable in `ps`, a process's environment is not.
    """
    base = ["git", "-C", str(repo_dir), "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
    env = None
    if token:
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        env = {
            **os.environ,
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
            "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: basic {basic}",
            "GIT_TERMINAL_PROMPT": "0",
        }
    return run(base + list(args), timeout=timeout, env=env)


AGENT_PROMPT = """You are running unattended in a disposable container, on a fresh clone of the
`{repo}` repository at /work. No human can answer questions during this run.

Do the task below. Keep changes focused on it. Read the README and CI config to
learn how the project is built and tested, install dependencies, and make the
project's tests and linters pass before you finish.

Rules:
- Never modify anything under .github/ -- changes there are rejected.
- Don't try to push, open pull requests, or reach GitHub: the harness does that.
- You may commit locally or leave changes uncommitted; either works.

Finish with a summary of at most 5 short sentences: what you changed and the
test/lint result. It will be read aloud, so no code blocks or file listings.

Task:
{instructions}
"""


def run_agent(task, work, cfg):
    env_file = TASKS / task["id"] / "agent.env"
    env_file.write_text(f"CLAUDE_CODE_OAUTH_TOKEN={secret('claude-oauth-token')}\n")
    env_file.chmod(0o600)
    prompt = AGENT_PROMPT.format(repo=task["repo"], instructions=task["instructions"])
    name = f"voice-agent-{task['id']}"
    argv = [
        "docker", "run", "--rm", "--name", name,
        "--network", AGENT_NETWORK,
        "--env-file", str(env_file),
        "-e", f"HTTPS_PROXY={PROXY}", "-e", f"HTTP_PROXY={PROXY}",
        "-e", f"https_proxy={PROXY}", "-e", f"http_proxy={PROXY}",
        "-e", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
        "--user", f"{AGENT_UID}:{AGENT_UID}",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--cpus", "2", "--memory", "4g", "--pids-limit", "1024",
        "-v", f"{work}:/work:Z", "-w", "/work",
        AGENT_IMAGE,
        "claude", "-p", prompt,
        "--output-format", "json",
        "--permission-mode", "acceptEdits",
        "--allowedTools", "Bash,Read,Edit,Write,Glob,Grep",
        "--permission-prompts", "none",
    ]
    try:
        proc = subprocess.run(argv, capture_output=True, timeout=cfg["max_minutes"] * 60)
    except subprocess.TimeoutExpired:
        subprocess.run(["docker", "kill", name], capture_output=True)
        raise RuntimeError(f"agent ran past the {cfg['max_minutes']}-minute limit and was stopped")
    finally:
        env_file.unlink(missing_ok=True)
    try:
        result = json.loads(proc.stdout.decode(errors="replace").strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        raise RuntimeError(f"agent produced no result (exit {proc.returncode}): {proc.stderr.decode(errors='replace')[-400:]}")
    if result.get("is_error") or proc.returncode != 0:
        raise RuntimeError(f"agent failed: {str(result.get('result', ''))[:400]}")
    return result


def export_patch(task, work, base_sha):
    """Diff the agent's tree against base_sha, inside a no-network container."""
    script = (
        "set -e; cd /work; git add -A; "
        f"git diff --binary --cached {base_sha} -- . ; "
    )
    proc = run(
        ["docker", "run", "--rm", "--network", "none", "--user", f"{AGENT_UID}:{AGENT_UID}",
         "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
         "-v", f"{work}:/work:Z", "--entrypoint", "sh", AGENT_IMAGE, "-c", script],
        timeout=120,
    )
    return proc.stdout


def open_pr(task, branch, summary, cfg, token):
    title = "voice: " + task["instructions"].splitlines()[0][:60]
    body = (
        f"Opened by the voice coding agent (task `{task['id']}`, ADR-0021). **Not merged automatically** — review and merge yourself.\n\n"
        f"### Request\n\n{task['instructions']}\n\n### Agent summary\n\n{summary}\n"
    )
    req = urllib.request.Request(
        f"https://api.github.com/repos/{cfg['owner']}/{task['repo']}/pulls",
        data=json.dumps({"title": title, "head": branch, "base": "main", "body": body}).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def process(task):
    cfg = config()
    tdir = TASKS / task["id"]
    shutil.rmtree(tdir, ignore_errors=True)
    tdir.mkdir(parents=True)
    pristine, work = tdir / "pristine", tdir / "work"
    url = f"https://github.com/{cfg['owner']}/{task['repo']}.git"
    started = time.time()
    write_status(task, state="running", step="cloning", started_at=int(started))

    run(["git", "clone", "--quiet", url, str(pristine)], timeout=300)
    base_sha = git(pristine, "rev-parse", "HEAD").stdout.decode().strip()
    # --no-hardlinks: a local clone otherwise hardlinks .git/objects, and the
    # chown below would hand the agent's uid write access to pristine's
    # object files through those shared inodes.
    run(["git", "clone", "--quiet", "--no-hardlinks", str(pristine), str(work)], timeout=300)
    run(["chown", "-R", f"{AGENT_UID}:{AGENT_UID}", str(work)])

    write_status(task, step="agent working", base_sha=base_sha)
    result = run_agent(task, work, cfg)
    summary = str(result.get("result", "")).strip()[:2000]
    cost = result.get("total_cost_usd")

    write_status(task, step="collecting changes", summary=summary, cost_usd=cost)
    patch = export_patch(task, work, base_sha)
    if not patch.strip():
        write_status(task, state="done", step="no changes", pr_url=None,
                     minutes=round((time.time() - started) / 60, 1),
                     message="The agent finished without changing any files, so no PR was opened.")
        return
    (tdir / "task.patch").write_bytes(patch)

    branch = f"voice/{task['id']}"
    git(pristine, "checkout", "--quiet", "-b", branch)
    git(pristine, "apply", "--index", "--binary", "--whitespace=nowarn", str(tdir / "task.patch"))
    # Ask the trusted tree what actually changed, rather than parsing the
    # (agent-produced) patch text, which rename/quoting tricks could dodge.
    paths = [p for p in git(pristine, "diff", "--cached", "--no-renames", "--name-only").stdout.decode().splitlines() if p]
    bad = [p for p in paths if FORBIDDEN_PATHS.match(p)]
    if bad:
        raise RuntimeError(f"agent changed protected paths {bad}; nothing was pushed")
    token = secret("github-token")
    git(pristine, "-c", "user.name=voice-agent", "-c", f"user.email=voice-agent@{cfg['owner']}.invalid",
        "commit", "--quiet", "-m", f"voice: {task['instructions'].splitlines()[0][:60]}",
        "-m", f"Voice task {task['id']} (ADR-0021).\n\n{summary}")
    write_status(task, step="pushing", files_changed=len(paths))
    git(pristine, "push", "--quiet", "origin", f"HEAD:refs/heads/{branch}", token=token)
    pr = open_pr(task, branch, summary, cfg, token)
    write_status(task, state="done", step="pr opened", pr_url=pr["html_url"], pr_number=pr["number"],
                 branch=branch, minutes=round((time.time() - started) / 60, 1))


def main():
    for d in (QUEUE, STATUS, TASKS):
        d.mkdir(parents=True, exist_ok=True)
    log.info("voice-worker runner started")
    while True:
        queued = sorted(QUEUE.glob("*.json"))
        if not queued:
            time.sleep(3)
            continue
        qfile = queued[0]
        task = json.loads(qfile.read_text())
        qfile.unlink()
        try:
            process(task)
        except subprocess.CalledProcessError as exc:
            err = (exc.stderr or b"").decode(errors="replace")[-400:]
            write_status(task, state="failed", error=f"{' '.join(map(str, exc.cmd[:3]))} failed: {err}")
        except urllib.error.HTTPError as exc:
            write_status(task, state="failed", error=f"GitHub API {exc.code}: {exc.read().decode(errors='replace')[:300]}")
        except Exception as exc:  # noqa: BLE001 -- any failure must land in status, not kill the loop
            write_status(task, state="failed", error=str(exc)[:500])


if __name__ == "__main__":
    main()
