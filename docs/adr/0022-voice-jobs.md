# ADR-0022: Named Jobs by Voice (Milestone 18, Phase 4)

Date: 2026-10-01
Status: Proposed

## Context

ADR-0021 phase 4: "allowlisted named jobs from a registry in Git, with short spoken-friendly results." Voice can already check status (`platform_status`, `github_status`) and start coding tasks that end in a PR. It can't *do* anything operational. Today, restarting an app, deploying the NUCs or taking a backup means a laptop, or merging a PR just to trigger a workflow.

Constraints from what's already built:

- **home-mcp holds no GitHub credential and runs no commands** (ADR-0021: named tools only, no shell). Anything that changes state should keep that property, or add as little as possible.
- **Every deploy already waits for Bill's tap** on the `production` environment (required reviewer since 2026-10-01), and `platform_status` reports anything waiting. That gate and that signal exist; jobs should reuse them, not invent a second approval path.
- **The hub already runs privileged work for CI via S3 + `ssm:SendCommand`** (`routeros.yml`, `platform-deploy.yml`, `app-deploy.yml`), audited in GitHub, with secrets read on the hub by its own role.
- Anonymous GitHub API reads work for all three repos (public) at about 60 calls/hour.
- A fine-grained PAT needs **Actions: write** to trigger `workflow_dispatch` (docs/gotchas.md, GitHub and CI/CD).

## Options Considered

**Option A: home-mcp dispatches one GitHub workflow (`voice-job.yml`); the job runs on the hub via SSM behind the `production` approval**
- Same path as every other privileged change: GitHub audit log, approval tap, SSM, hub role for secrets
- Needs one new credential on home-mcp: a fine-grained token, this repo only, **Actions: read and write**. It can dispatch, re-run or cancel workflows. It **can't** change code, merge, or approve deployments (that needs Deployments permission, deliberately not granted; **verify before building**)
- Slower: about 30–60 s runner start, plus however long Bill takes to tap approve

**Option B: home-mcp runs jobs directly (SSM from the hub's role, or SSH forced commands like `voiceworker`)**
- Fast, and no GitHub credential
- The only approval is Claude's per-call confirmation in the chat, which doesn't amount to a gate: a misled conversation is one "yes" away from running it. Audit lives only in Loki
- Gives home-mcp's container the ability to run privileged commands on the hub, the thing ADR-0021 deliberately kept out of it

**Option C: Hybrid. Read-only jobs direct (B), state-changing jobs through GitHub (A)**
- Most useful read-only checks are already in `platform_status`; the remaining ones don't justify a second execution path
- Two mechanisms to secure and document

## Decision

**Option A**, one path for every job.

### Registry (`jobs/registry.yml`, in Git)

```yaml
restart-app:
  say: "restart <app>"                 # how Bill would ask; shown by list_jobs
  description: Restart one app's containers on the hub
  args:
    app: [todo-app, hue]               # enum only, never free text
  target: hub                          # hub | nucs (nuc4 compute jobs: later)
  script: scripts/jobs/restart-app.sh
  timeout_minutes: 5
```

Arguments are **always enums**. No job takes free text, so neither voice nor a prompt-injected agent can pass a path, flag or shell fragment. A new job, or a new allowed value, is a PR Bill merges.

### Flow

1. Voice: "restart hue." Claude calls `run_job("restart-app", {"app": "hue"})`, after reading it back and getting a yes, same rule as `start_task`.
2. home-mcp checks the job and args against the registry (fetched from `main`, like `context.py`), then calls `workflow_dispatch` on `voice-job.yml` with `job`, `args` (JSON) and a `request_id`. `run-name` includes the `request_id`, so the run can be found again.
3. `voice-job.yml` **re-validates against the registry** (defense in depth: the token could dispatch any input), then its `run` job waits in the `production` environment. `platform_status`/`github_status` already say "voice-job for restart-app hue is waiting for your approval."
4. Bill taps approve. The job runs `scripts/jobs/<script>` on the hub via SSM, through the same `run-on-hub` helper as `platform-deploy.yml`.
5. Each script ends with one line, `RESULT: <one spoken sentence>` (e.g. "hue restarted, health check OK in 4 seconds"). The workflow publishes it as a `::notice title=result::` annotation.
6. `job_status(request_id="")` finds the run by name and reads its status plus that annotation through the anonymous API: "restart hue: waiting for your approval / running / done: hue restarted, health OK" or "failed: <reason>".

### New tools on home-mcp

- `list_jobs()`: names, "say" phrases and allowed values (read-only)
- `run_job(job, args)`: dispatches; confirm first
- `job_status(request_id="")`: latest job if omitted

These change the tool list, so the claude.ai connector needs a disconnect and reconnect after deploying (docs/gotchas.md, Voice access).

### Starter jobs

| Job | Does | Why first |
|---|---|---|
| `restart-app {todo-app, hue}` | `docker compose restart` in `/home/ec2-user/apps/<app>`, then checks `/health` | most likely fix from the car |
| `deploy-nucs` | existing `scripts/hub/deploy-nucs-on-hub.sh` | rolls out the new hue-agent image without a PR (today it needs one) |
| `deploy-hub` | existing `scripts/hub/deploy-hub-stack.sh` | re-run after a failed or partial deploy |
| `postgres-backup-now` | runs the `postgres-backup` container once and reports dump size and S3 key | before a risky change |
| `hub-docker-prune` | `docker image prune` older than 7 days and reports space freed | the hub disk is the likeliest slow-burn failure |

### Credential

- SSM `/home-platform/github/voice-jobs-token`: fine-grained PAT, repository `nyc_pa_aws_gitops` only, **Actions: Read and write** plus Metadata: Read, nothing else. One-year expiry, flagged in `platform_status` 21 days ahead, like the agent's tokens
- Passed to home-mcp through the compose `.env`, like its other secrets (`scripts/hub/deploy-hub-stack.sh` and `deploy-aws-stack.*` read it, and the `hub_platform_deploy` policy grants it)
- What it can still do if leaked: dispatch, re-run or cancel workflows in this repo. Every dispatchable workflow that changes anything (`voice-job`, `platform-deploy`, `routeros`) waits for Bill's approval; worst case is noise plus cancelled runs, not changes

## Consequences

- Voice gets "do" without home-mcp gaining a shell or running anything itself. It only asks GitHub, and Bill's tap is still the gate
- One new credential on home-mcp, limited to Actions on one repo. This relaxes ADR-0021's "home-mcp holds no GitHub credential"; that statement should be updated if this is accepted
- Jobs are minutes, not seconds (runner start plus approval), which is fine for "restart", "deploy" and "backup", and wrong for anything interactive
- Every new job is a PR: registry entry plus script, reviewed like any other change
- **Later, not in this phase:** compute jobs on nuc4 (e.g. curve-fit runs for the fixed-income work). They'd reuse the registry and tools with `target: nuc4`, dispatched from the hub to `voiceworker`'s forced command (ADR-0021), likely without the approval tap since they only compute

## Open questions for Bill

1. Starter list above, or different?
2. Should every job wait for approval, including harmless ones like the backup? Recommendation: yes for now, since one rule is easier to trust
3. Compute jobs on nuc4: part of this phase, or after?
