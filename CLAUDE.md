# Claude Code Instructions

## gh CLI setup (new machine)

The GitHub API token is stored in SSM at `/home-platform/github/api-token`.

```powershell
# Install gh CLI
winget install --id GitHub.cli --accept-package-agreements --accept-source-agreements

# Auth from SSM (open a new terminal after install so PATH is updated)
$token = (aws ssm get-parameter --name "/home-platform/github/api-token" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$token | & "C:\Program Files\GitHub CLI\gh.exe" auth login --with-token
```

After setup, use `gh run list --repo bcalaway/nyc_pa_aws_gitops` to check Actions runs.

## Git

Always `git push` immediately after every `git commit` without asking.

## AWS

- Account: 147856894209
- Region: us-east-1
- Terraform state bucket: `home-platform-terraform-state-147856894209`
- GitHub Actions IAM role: `home-platform-github-actions`

## SSM parameters

| Path | What it is |
|------|-----------|
| `/home-platform/github/api-token` | GitHub PAT for gh CLI |
| `/home-platform/router/nyc-admin-password` | NYC RB5009 admin password |
| `/home-platform/router/rambles-admin-password` | Rambles RB5009 admin password (set when hardware arrives) |
| `/home-platform/wireguard/server-private-key` | EC2 WireGuard hub private key |
| `/home-platform/grafana/admin-password` | Grafana admin login |
| `/home-platform/grafana/smtp-password` | Grafana Gmail SMTP password (placeholder until real App Password set) |
| `/home-platform/uptime-kuma/admin-password` | Uptime Kuma admin login |
| `/home-platform/switch/nyc-sw-desk-username` | sw-desk (Cisco SG300-10, 10.0.1.11) admin username — not "admin", a personal account |
| `/home-platform/switch/nyc-sw-desk-password` | sw-desk admin password |
| `/home-platform/switch/nyc-sw-main-username` | sw-main (Cisco SG300-10, 10.0.1.10) admin username |
| `/home-platform/switch/nyc-sw-main-password` | sw-main admin password |
| `/home-platform/switch/nyc-sw10g-username` | sw-10g (MikroTik, 10.0.1.12) admin username |
| `/home-platform/switch/nyc-sw10g-password` | sw-10g admin password |
| `/home-platform/nas/nyc-nas2-username` | nas2 (Synology, 10.0.1.7) admin username |
| `/home-platform/nas/nyc-nas2-password` | nas2 admin password |

## New machine checklist

On a fresh machine, read `docs/new-machine-setup.md` first — it has the full step-by-step. Key things to verify before starting work:

```powershell
aws sts get-caller-identity                          # creds valid?
gh run list --repo bcalaway/nyc_pa_aws_gitops        # gh authed?
```

If gh isn't authed yet, see the "gh CLI setup" section above.

## EC2 access

- IP: `3.82.89.106`, user: `ec2-user`
- SSH key in SSM at `/home-platform/ec2/ssh-private-key` → save to `~/.ssh/home-platform.pem`
- SSH is only open from WireGuard subnets. **There is currently no laptop WireGuard peer** (removed 2026-07-04 as redundant once Rambles' RB5009 was deployed — see Milestone 2 in `docs/roadmap.md`). If working from a device already on the NYC or Rambles LAN, that site's RB5009 routes to the hub automatically, no client needed. If working remotely (not on either site's LAN), either provision a fresh laptop peer or temporarily open port 22 for your IP (see `docs/new-machine-setup.md`).
- **When connecting over the WireGuard tunnel, SSH to `10.0.3.1`, not the public IP `3.82.89.106`.** The laptop tunnel's `AllowedIPs` only covers `10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24` — traffic to the public IP goes out the normal internet path instead of the tunnel and gets blocked by the security group.

```powershell
ssh -i "$HOME\.ssh\home-platform.pem" ec2-user@10.0.3.1
```

## TLS / reverse proxy on EC2 hub

Unlike the Docker Compose stack, this is host-level config on EC2 and **not tracked in Git** — if the instance is ever rebuilt, redo this manually (or write an Ansible role for it under Milestone 8/9).

- nginx installed via `dnf`, reverse-proxies `grafana.billandjessie.com` → `127.0.0.1:3000` and `status.billandjessie.com` → `127.0.0.1:3001`, config at `/etc/nginx/conf.d/home-platform.conf`
- Certbot installed via pip into a venv at `/opt/certbot-venv`, symlinked to `/usr/bin/certbot` (AL2023 has no native certbot package)
- Cert obtained via `certbot-dns-route53` plugin (DNS-01, no inbound ports needed) — covers both `grafana.` and `status.` subdomains in one cert, stored at `/etc/letsencrypt/live/grafana.billandjessie.com/`
- EC2 has an IAM instance role (`home-platform-hub`, in `terraform/aws/tls.tf`) scoped to Route53 record writes on our zone only — that's what lets certbot-dns-route53 work without embedding credentials
- Renewal: `certbot-renew.timer` (systemd, runs twice daily, reloads nginx via deploy-hook) — not an OS package unit, created manually since pip-installed certbot doesn't ship one
- Port 80 redirects to HTTPS for both subdomains; both HTTPS server blocks send HSTS (`max-age=31536000; includeSubDomains`)

## Syslog receiver on EC2 hub

Also host-level, not tracked in Git (same caveat as nginx/certbot above).

- `rsyslog` (native package, not containerized) listens on UDP 514, config at `/etc/rsyslog.d/network-devices.conf`
- Writes one file per source IP to `/var/log/network-devices/<ip>.log` — Promtail (in the compose stack) bind-mounts that directory read-only and tails it, with one explicit `static_configs` entry per known device mapping IP → friendly device name (see `compose/aws/promtail/promtail-config.yaml`)
- rsyslog owns port 514 natively; Promtail's container does **not** publish that port (it did originally, using Promtail's own built-in syslog receiver, but that only supports RFC5424 and choked on RouterOS/Cisco's legacy BSD syslog — see Gotchas below)
- Devices are pointed at `10.0.3.1:514` (the hub's WireGuard IP) via each device's own remote-syslog config — RouterOS `/system logging`, Cisco `logging host`, Synology DSM's Log Center

## RouterOS config apply

Script: `routeros/apply-config.py`. Requires `pip install paramiko boto3`.

```powershell
# Apply to a live router (fetches password from SSM automatically)
python routeros/apply-config.py 10.0.1.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password

# First-time apply to factory-default router (provide factory password)
python routeros/apply-config.py 192.168.88.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password --ssh-password <factory-password>
```

The script replaces `PLACEHOLDER` in the .rsc file with the real password from SSM before uploading.

## Network topology

- NYC RB5009: LAN 10.0.1.1/24, WireGuard 10.0.3.2
- Rambles RB5009: LAN 10.0.2.1/24, WireGuard 10.0.3.3
- EC2 WireGuard hub: 10.0.3.1 (interface ens5, not eth0)
- Laptop: no peer currently exists (10.0.3.4 was removed 2026-07-04) — see "EC2 access" above
- Nighthawk RS700: AP mode at 10.0.1.2 (connect via LAN port, not WAN)
- ZenWiFi AX6600 (Rambles): converted to AP mode 2026-07-04, hangs off the RB5009 same as the RS700 pattern
- Both routers' `forward` chains trust each other's LAN subnet (not just the WireGuard subnet) — real cross-site LAN traffic works, not just router-to-router. See "Gotchas" below for why this wasn't originally obvious.

## Gotchas (learned the hard way)

- **AWS CLI from Git Bash mangles SSM parameter paths.** MSYS auto-converts leading-`/` arguments into Windows paths, so `aws ssm get-parameter --name /home-platform/...` silently fails with `ParameterNotFound` or a path-validation error from Git Bash. Use PowerShell for any AWS CLI call involving a path-style name (SSM, IAM paths, etc).

- **Granting a new IAM permission and using it in the same Terraform apply can fail.** If a commit both adds a permission (e.g. `cloudfront:*`) to the GitHub Actions role's policy *and* creates a resource requiring it, the apply may run before the policy change has propagated (IAM is eventually consistent, typically a few seconds). Symptom: `AccessDeniedException` right after a successful policy update in the same run. Fix is just to re-run — or apply locally once with admin creds, which is unaffected since it's a different principal.

- **Compose config changes need an explicit container restart.** Editing `prometheus.yml`, `loki-config.yaml`, etc. and re-deploying (`scripts/deploy-aws-stack.ps1`) updates the file on disk, but the running container doesn't reload it automatically — `docker compose restart <service>` is required. Grafana's dashboard *provisioning* is the one exception (polls its directory every 30s per `dashboards.yml`), but Grafana datasource/plugin config still needs a restart same as everything else.

- **A freshly added Route53 record can take up to 24h to resolve on some networks.** Route53's SOA negative-cache TTL is 86400s by default. If a hosted zone existed *before* a record was added (ours did — the zone predates `billandjessie.com`'s apex A record by weeks), any resolver that queried it in the gap may have cached "no record" and will keep serving that until the negative-cache TTL expires, even though the record is now live and correct everywhere else. Verify with `--resolve` (bypasses DNS) or a fresh resolver (e.g. cellular data instead of home WiFi) before assuming something's actually broken.

- **Cisco SG300 switches (sw-main, sw-desk) need `pip install "paramiko<3"` for SSH.** Paramiko 3.x fully removed SHA-1-based key exchange (not just deprioritized — the implementation is gone), and these ~2013-era switches only offer `diffie-hellman-group1-sha1`/`group14-sha1`. Symptom: `IncompatiblePeer: no acceptable kex algorithm`. Paramiko 2.12.0 still has it.

- **SG300 SSH auth happens *inside* the shell, not at the SSH protocol layer.** `transport.auth_none(username)` succeeds and `is_authenticated()` reports `True` with no password at all — the device instead prints a `User Name:` / `Password:` prompt once you open a shell channel, exactly like a Telnet session. Send credentials as if typing them, not via paramiko's `auth_password`/`auth_interactive` (both get rejected with `BadAuthenticationType`).

- **SG300 web UI "Add" dialogs are unreliable via clicks (real or synthetic).** Its buttons are `<table class="btn_normal">` elements with an `onclick` attribute, not real `<button>`/`<input>` elements, inside a nested frameset. Neither `computer` tool clicks nor DOM `.click()` reliably opened the dialogs. If the web UI must be used, call the handler function directly — find it via `element.getAttribute('onclick')` (grep for the function name, e.g. `addRecord`) then invoke `frame.functionName()` in the correct child frame. In practice it was easier to enable SSH under Security → TCP/UDP Services (a normal checkbox, works fine via clicks) and do everything else via CLI.

- **RouterOS `/system logging add topics=a,b,c` is AND, not OR.** A single rule listing multiple topics only fires for a log entry carrying *all* of them simultaneously — which never happens, since a message only ever has one severity topic at a time. Nothing gets forwarded and there's no error; it just silently never matches. Fix: one rule per topic, all pointing at the same action, exactly like RouterOS's own built-in default rules do (`topics=info action=X`, `topics=warning action=X`, etc. as separate lines).

- **Promtail's built-in syslog scrape target only supports RFC5424, not legacy BSD syslog (RFC3164).** RouterOS and Cisco SG300 both send RFC3164 by default. Symptom: `promtail_syslog_target_parsing_errors_total` increments with `"expecting a version value in the range 1-999"` — the packets *are* arriving (check this counter, not just `promtail_sent_entries_total`, before concluding otherwise), they're just failing to parse. Fix: don't use Promtail's syslog target at all — run `rsyslog` (handles both formats) as the actual UDP 514 receiver, have it write one file per source IP, and let Promtail just tail those files. See "Syslog receiver on EC2 hub" above.

- **A RouterOS 7.19.6 RB5009's own `/system logging` remote-syslog action can silently fail to transmit at all** — confirmed via `tcpdump` on the receiving end *and* RouterOS's own `/tool sniffer` on the sending router, both showing zero packets, even though the firewall's `output` chain counts them as sent. This looks like a genuine RouterOS bug/quirk specific to remote syslog over a WireGuard-only route, unresolved as of 2026-07-04. Doesn't affect Cisco SG300 traffic *forwarded through* the same router (that works fine) — only the router's own self-generated syslog.
