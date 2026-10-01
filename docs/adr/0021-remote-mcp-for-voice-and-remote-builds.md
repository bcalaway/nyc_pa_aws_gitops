# ADR-0021: Hub-Hosted Remote MCP Server for Voice Access and Remote Builds

Date: 2026-09-30
Status: Accepted

## Context

Bill is starting a six-month build period (fixed income analytics + hands-on AI architecture) and wants to keep projects moving during drive time — not just check status, but **actually build things by voice**: start a coding task, hear whether it passed, and have a PR waiting for review. Voice Claude (Claude mobile, Pro plan) currently has no path into this platform at all.

Confirmed from Claude's own docs (2026-09-30), which shape everything below:

- Voice mode can use connected tools, and custom connectors (a remote MCP server added by URL) are available on Pro and work across web, desktop and mobile — they're configured once, then follow the account
- Claude connects to a remote MCP server **from Anthropic's cloud** (egress `160.79.104.0/21`), not from the phone — so the server must be publicly reachable, and a WireGuard-only endpoint won't work
- Sign-in is OAuth 2.0 with PKCE S256; a custom connector can use our own pre-registered client (client ID/secret under Advanced settings); the hosted apps' callback is `https://claude.ai/api/mcp/auth_callback`
- Discovery is RFC 9728: a `401` with `WWW-Authenticate: Bearer resource_metadata=...` pointing at a protected-resource document that names the authorization server

These are strong capabilities: something that can push code and run jobs on home hardware, driven by an internet-facing endpoint. Security has to be the design, not a later hardening pass.

## Options Considered

**Option A: Self-hosted GitHub Actions runner on a NUC; voice triggers workflows through the GitHub connector**
- No new public endpoint; nothing inbound at home
- `todo-app` and `hue` are public repos — a self-hosted runner attached to a public repo runs code from anyone's pull request on home hardware, GitHub's own documented anti-pattern
- Workflows are a coarse, slow interface for conversational "how's it going" status; no path to platform status (Prometheus/Uptime Kuma) or AWS without granting the runner broad credentials

**Option B: Remote MCP server on a NUC, exposed through a tunnel**
- Needs a new ingress path into a site LAN; nuc5 is seasonal (Rambles closed Nov–Apr), nuc4 would become a public-facing host
- Duplicates the ingress, TLS and auth the hub already has

**Option C: Remote MCP server on the hub, behind Traefik + Authentik; heavy work dispatched to nuc4 over WireGuard**
- Reuses everything that exists: Traefik routing/TLS, Authentik as the OAuth authorization server, WireGuard routes + the Ansible SSH key to both NUCs, Prometheus/Uptime Kuma for status, the hub's instance role for AWS
- No inbound port at either house; the only new public surface is one hostname on a box that already serves several
- The MCP server itself stays small (a policy/dispatch layer); coding work runs on nuc4, off the hub's t3.medium

## Decision

**Option C.** A small Python MCP server, `home-mcp`, at `https://mcp.billandjessie.com/mcp`, running in `compose/aws/` (same category as `cost-exporter`/`rachio-exporter`: platform tooling, not an app under ADR-0014). Year-round work (coding tasks, jobs) runs on **nuc4** (NYC), never nuc5, since Rambles is closed November through April.

### Security model (defense in depth, outermost first)

| Layer | Control |
|---|---|
| Network | Traefik `ipAllowList` on the `mcp.` router: Anthropic's egress range only. Authentik stays public (Bill's browser signs in there) |
| Identity | Authentik OAuth2 provider for `home-mcp`, access bound to Bill's user only, **MFA required for this app** (not changed for other apps). The MCP server validates every bearer token (signature via JWKS, issuer, audience, expiry) itself — it never trusts Traefik alone |
| Tools | Named tools only, never a raw shell or arbitrary command. Read-only tools may be "Always allow"; anything that changes state keeps Claude's per-call approval prompt |
| Coding agent | One disposable container per task on nuc4. It gets only a fine-grained GitHub token scoped to the specific app repos (contents + pull requests, no admin). No AWS credentials, no SSM, no SSH keys, no access to this platform repo |
| Production | Branch protection on `main` in app repos. The agent pushes `voice/<task>` branches and opens PRs; it can never merge. Deploys only happen through the existing CI after a human merge. **Merging from voice is out of scope for now**; revisit later with green-CI + explicit-confirmation gating |
| Visibility | Every tool call and task logged to Loki (who, what, result); an email when a coding task starts; a one-step kill switch (disable the Authentik application, or the flag the server checks) |

The main residual risk is prompt injection: text in a repo, issue, or web page steering the agent. The containment above bounds it — a fully misled agent can at most push a branch to a scoped repo that a human then reviews.

### Coding agent runtime

Headless Claude Code on nuc4, authenticated with Bill's **Pro subscription** to start (no extra cost; shares Pro usage limits). Switch to an API key if those limits become the bottleneck — a config change, not a redesign.

### Project context

Git stays the source of truth for platform context (roadmap, ADRs, gotchas) — it's versioned, reviewable, and what coding agents read anyway. It gets restructured to be consumable from outside this repo: CLAUDE.md slimmed to rules + pointers, gotchas moved to `docs/gotchas.md` grouped by area, roadmap split into active + archive. `home-mcp` exposes it read-only (`get_context(topic)`, `search_context(query)`) so voice, desk and agents read the same thing. Claude Docs holds drafts and brainstorming (voice can already write there); decisions get promoted into Git. A pgvector semantic index over this corpus is a natural later RAG project, not a dependency.

## Phases

1. **Spike** — `mcp.billandjessie.com` with one read-only tool, `platform_status` (sites, NUCs, apps, AWS in one spoken-friendly sentence), with the full security model above from day one. Proves custom connector + voice end to end before anything else is built
2. **Context** — restructure CLAUDE.md/roadmap/gotchas; `get_context`/`search_context` tools; connect the GitHub directory connector for CI/PR status
3. **Coding tasks** — `start_task`/`task_status`/`task_log_summary`, disposable containers on nuc4, scoped GitHub token, branch protection on app repos
4. **Jobs** — allowlisted named jobs (e.g. curve-fit runs) from a registry in Git, with short spoken-friendly results
5. **Preview environments** — per-PR temporary deployments (e.g. `pr-12.<app>.billandjessie.com`) so a feature can be exercised before merging; torn down on merge/close

## Consequences

- One new public hostname; its router is the only one on the hub with an IP allowlist, and the only Authentik app requiring MFA
- New Terraform: Route53 record for `mcp.`; later, SSM read grants for the GitHub token
- nuc4 becomes the platform's build worker — its reliability matters more now (see the 2026-09-20 nouveau wedge in CLAUDE.md's Gotchas)
- Anthropic's egress range is a dependency: if it changes, the allowlist must follow (documented in their IP address reference)

## Implementation notes (phase 3, 2026-09-30)

Details decided while building the coding worker, beyond the security table above:

- **hub → nuc4 control channel is SSH with a forced command, not gRPC** (a deliberate exception to ADR-0020, which covers app-to-app data calls). `voiceworker`'s key is `restrict,from="10.0.3.1",command=".../dispatch.py"`: the only operations are queue-a-task and read-status, there is no shell, and that user can't run git or Docker. nuc4's host key is pinned in home-mcp's compose env
- **The agent never holds a GitHub credential.** The root-owned runner clones twice: `pristine/` (never shown to the agent) and `work/` (the agent's). Because the agent controls everything in `work/` — including `.git/hooks` and `.git/config` — the runner never runs git there. The agent's changes are exported as a patch from inside a second, no-network container; applied to `pristine/`; changed paths re-read from the trusted index (`.github/`, git metadata rejected); then committed, pushed to `voice/<id>` and opened as a PR. The token reaches git through `GIT_CONFIG_*` env vars (not argv, which is visible in `ps`); the local clone uses `--no-hardlinks` so the agent's uid can't write pristine's objects through shared inodes
- **Egress allowlist**: the agent network is `internal: true`; its only way out is a squid proxy allowing `.anthropic.com`, `.claude.ai`, `.claude.com`, `pypi.org`, `files.pythonhosted.org`. Verified: GitHub and arbitrary sites get `TCP_DENIED/403`, direct egress has no route
- **Agent container**: uid 10001, all capabilities dropped, `no-new-privileges`, 2 CPU / 4 GB / 1024 PIDs, 45-minute cap; headless Claude Code with `--permission-mode acceptEdits --permission-prompts none` (not `--bare`, which ignores the subscription token)
- **`github_status` (2026-10-01)**: read-only PR/CI/deploy status for voice, via GitHub's anonymous API — the repos are public, so home-mcp holds no GitHub credential at all, keeping the "named tools only, nothing that writes" rule trivially true. If a repo ever goes private, it needs a read-only fine-grained token (metadata, pull requests, actions: read) in SSM, never the agent's token
- **Allowed repos (2026-09-30)**: `todo-app`, `hue`. Adding a repo takes three steps: add it to the agent's fine-grained token, give its `main` the todo-app ruleset (no deletion/force-push, PR required, CI check required), then add it to `VOICE_ALLOWED_REPOS` in `compose/aws/docker-compose.yml` and `voice_worker_allowed_repos` in `ansible/inventory/hosts.yml` and redeploy both. `nyc_pa_aws_gitops` is intentionally never allowed: it holds the agent's own guardrails and the infra. For hue, the Python-only agent image covers the hub backend only; the npm frontend and C++ agent rely on PR CI
- **Branch protection can't require an approval** on agent PRs: the agent's token acts as Bill, and GitHub won't let an author approve their own PR. So `main` requires a PR plus green CI, and the "never merges" guarantee comes from the agent having no credential, not from GitHub settings
