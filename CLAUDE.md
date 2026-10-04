# Claude Code Instructions

## gh CLI setup (new machine)

The GitHub API token is stored in SSM at `/home-platform/github/api-token`. Full step-by-step for both Windows and Linux (Rocky NUCs) machines is in `docs/new-machine-setup.md` — this is just the quick version.

**Windows:**
```powershell
# Install gh CLI
winget install --id GitHub.cli --accept-package-agreements --accept-source-agreements

# Auth from SSM (open a new terminal after install so PATH is updated)
$token = (aws ssm get-parameter --name "/home-platform/github/api-token" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$token | & "C:\Program Files\GitHub CLI\gh.exe" auth login --with-token
```

**Linux (Rocky/RHEL, dnf-based — the NUC pattern):**
```bash
# Install gh CLI
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh

# Auth from SSM
token=$(aws ssm get-parameter --name "/home-platform/github/api-token" --with-decryption --region us-east-1 --output json | jq -r '.Parameter.Value')
echo "$token" | gh auth login --with-token
gh auth setup-git   # required if the repo was cloned over HTTPS (the norm on Linux) so `git push` has credentials
```

After setup, use `gh run list --repo bcalaway/nyc_pa_aws_gitops` to check Actions runs.

## Git

`main` is protected (ruleset, 2026-09-30): no direct pushes, deletion or force-push — every change goes through a PR. Work on a branch, and always `git push` it immediately after every `git commit` without asking, then open a PR (or update the open one). Bill merges, with one exception: for a PR that changes only docs (`docs/**`, `*.md`), Claude turns on auto-merge, so it merges once its checks pass (Bill, 2026-10-04). Status updates go in one place: an app's own plan doc (e.g. mkt-data's `docs/phase-1.md`), with the roadmap milestone linking to it.

Merging to `main` can deploy: Terraform (`terraform/**`), the hub stack and NUCs (`compose/aws/**`, `ansible/**`, `compose/nuc/**`, `scripts/hub/**`, via `platform-deploy.yml`) and RouterOS all run in the `production` environment, which waits for Bill's approval before applying.

## AWS

- Account: 147856894209
- Region: us-east-1
- Terraform state bucket: `home-platform-terraform-state-147856894209`
- GitHub Actions IAM role: `home-platform-github-actions`

## Where context lives

CLAUDE.md holds rules and day-to-day operations only. Everything else is in `docs/`, and the same files are what voice Claude reads through `home-mcp`'s `get_context`/`search_context` tools (fetched from `main` on GitHub), so **keep them current and commit them** — an unpushed doc change is invisible to voice.

| File | What's in it |
|------|-------------|
| `docs/roadmap.md` | Active milestones + open loose ends. **Update when work lands** |
| `docs/roadmap-archive.md` | Completed milestones, full history |
| `docs/gotchas.md` | Every "learned the hard way" entry, grouped by area. **New gotchas go here, under the matching area**. (This was CLAUDE.md's "Gotchas" section until 2026-09-30 — older references to "CLAUDE.md's Gotchas" in code comments and docs mean this file) |
| `docs/adr/` | Architecture decisions (ADR-0001 → latest) |
| `docs/ssm-parameters.md` | Catalog of every SSM parameter. **Add a row for every new parameter** |
| `docs/platform-reference.md` | Network topology, site WAN IPs, Traefik/TLS, syslog receiver, hub host hardening |
| `docs/network-inventory.md` / `docs/hardware-inventory.md` / `docs/ip-plan.md` | Devices, IPs, MACs, reservations |
| `docs/app-platform.md` | The app platform contract (DB, auth, ingress, CI/CD) |
| `docs/new-machine-setup.md` | Full workstation/NUC setup, Windows + Linux |

Seasonality: the Rambles site is closed **November through April** — put year-round workloads on nuc4 (NYC), never nuc5.

## Ansible NUC provisioning

`ansible/` provisions the NUCs (base system, Docker, exporter stack from `compose/nuc/`). Ansible's control node doesn't support Windows, and neither a Windows workstation nor a bare Linux workstation without Ansible installed can run playbooks locally, so they run **from the EC2 hub**, which already has WireGuard routes to both site LANs and has `ansible-core` installed on demand.

```powershell
scripts/deploy-nucs.ps1    # Windows
```
```bash
scripts/deploy-nucs.sh     # Linux — same logic, kept in sync with the .ps1 version
```

This fetches the Ansible NUC private key from SSM, installs `ansible-core` on EC2 if missing, copies `ansible/` and `compose/nuc/` there, and runs `ansible-playbook site.yml` over SSH. Both NUCs are in `ansible/inventory/hosts.yml` (`nuc4`/NYC at 10.0.1.34, `nuc5`/Rambles at 10.0.2.10).

To add a new NUC to Ansible management: install the public key from SSM (`/home-platform/ansible/nuc-public-key`) into its `authorized_keys`, and configure passwordless sudo for its admin user (see the `bcalaway-ansible` sudoers drop-in on nuc5 for the pattern).

## New machine checklist

On a fresh machine (Windows or Linux — `docs/new-machine-setup.md` covers both), read that doc first for the full step-by-step. Key things to verify before starting work (same commands on both platforms):

```
aws sts get-caller-identity                          # creds valid?
gh run list --repo bcalaway/nyc_pa_aws_gitops        # gh authed?
```

If gh isn't authed yet, see the "gh CLI setup" section above.

## EC2 access

- IP: `3.82.89.106`, user: `ec2-user`
- SSH key in SSM at `/home-platform/ec2/ssh-private-key` → save to `~/.ssh/home-platform.pem`
- SSH is only open from WireGuard subnets. The laptop WireGuard peer was re-provisioned 2026-07-07 with a fresh keypair (private key in SSM at `/home-platform/wireguard/laptop-private-key` and imported into the local WireGuard app as tunnel `laptop-wireguard`; never committed to Git). If working from a device already on the NYC or Rambles LAN, that site's RB5009 also routes to the hub automatically, no client needed — but make sure the local `laptop-wireguard` tunnel is deactivated first if so, since an active tunnel takes priority for the `10.0.3.0/24` route and will break connectivity if its key is ever revoked again.
- **When connecting over the WireGuard tunnel, SSH to `10.0.3.1`, not the public IP `3.82.89.106`.** The laptop tunnel's `AllowedIPs` only covers `10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24` — traffic to the public IP goes out the normal internet path instead of the tunnel and gets blocked by the security group.

```powershell
ssh -i "$HOME\.ssh\home-platform.pem" ec2-user@10.0.3.1
```

## Deploying the AWS stack

**Normally automatic:** merging to `main` with changes under `compose/aws/`, `ansible/`, `compose/nuc/` or `scripts/hub/` runs `.github/workflows/platform-deploy.yml`, which waits for Bill's approval (the `production` environment's required reviewer, set 2026-10-01) and then deploys the hub stack and/or NUCs through S3 + SSM, the same way `routeros.yml` does. It can also be run by hand from the Actions tab (`workflow_dispatch`: hub / nucs / both). The hub-side logic lives in `scripts/hub/`; unreachable NUCs (nuc5 when Rambles is closed) are skipped, not failed. The scripts below remain for manual deploys.

`scripts/deploy-aws-stack.ps1` (Windows) / `scripts/deploy-aws-stack.sh` (Linux) push `compose/aws/` to the EC2 hub and bring the stack up — Prometheus, Grafana, Loki, Uptime Kuma, Authentik, Traefik, Postgres, Redis. Both fetch the same secrets from SSM into a generated `.env`, delete remote files that no longer exist locally (see `docs/gotchas.md` on why this matters), `scp` the compose dir over, and run `docker compose pull && docker compose build && docker compose up -d`. Keep the two scripts' deploy logic in sync when changing one.

```powershell
scripts/deploy-aws-stack.ps1    # Windows
```
```bash
scripts/deploy-aws-stack.sh     # Linux
```

## RouterOS config apply

Script: `routeros/apply-config.py`. Requires `pip install paramiko boto3`.

```powershell
# Apply to a live router (fetches password + WireGuard key from SSM automatically)
python routeros/apply-config.py 10.0.1.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password --wg-key-ssm /home-platform/wireguard/nyc-private-key

# First-time apply to factory-default router (provide factory password)
python routeros/apply-config.py 192.168.88.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password --ssh-password <factory-password> --wg-key-ssm /home-platform/wireguard/nyc-private-key --accept-new-host-key
```

**SSH host keys are pinned** in `ansible/known_hosts` (routers and NUCs). `apply-config.py` and Ansible refuse a host that isn't listed or whose key changed. After a factory reset or reinstall, run once with `--accept-new-host-key` (routers only, first contact), check the printed fingerprint on the device, and update its line in `ansible/known_hosts` — see `docs/gotchas.md` (NUCs and Ansible).

The script replaces `PLACEHOLDER` in the .rsc file with the real admin password from SSM, and (if `--wg-key-ssm` is given) `WG_PRIVATE_KEY_PLACEHOLDER` with the real WireGuard key. **It refuses to run at all if `WG_PRIVATE_KEY_PLACEHOLDER` is still present and `--wg-key-ssm` wasn't given** — see `docs/gotchas.md` (RouterOS) for why.

**For a small targeted change to an already-live router (e.g. adding one DNS record), don't reapply the whole `.rsc` file.** SSH in directly (paramiko or PuTTY) and run just that one RouterOS command. Reapplying the full file re-runs its WireGuard section too, which is only safe with a real key supplied.
