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
| `/home-platform/wireguard/laptop-private-key` | Laptop WireGuard client private key |
| `/home-platform/wireguard/laptop-public-key` | Laptop WireGuard client public key |
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
| `/home-platform/nuc/rambles-nuc5-username` | nuc5 (Rambles NUC, 10.0.2.10) SSH username (`bcalaway`) — password auth, still valid as a fallback |
| `/home-platform/nuc/rambles-nuc5-password` | nuc5 SSH/sudo password |
| `/home-platform/ansible/nuc-private-key` | SSH private key Ansible uses to manage NUCs (key-based, passwordless sudo configured for `bcalaway`) |
| `/home-platform/ansible/nuc-public-key` | Matching public key — already installed in nuc5's `authorized_keys`; add to any new NUC the same way |

## Ansible NUC provisioning

`ansible/` provisions the NUCs (base system, Docker, exporter stack from `compose/nuc/`). Ansible's control node doesn't support Windows, and this workstation has neither WSL nor Docker, so playbooks don't run locally — they run **from the EC2 hub**, which already has WireGuard routes to both site LANs.

```powershell
scripts/deploy-nucs.ps1
```

This fetches the Ansible NUC private key from SSM, installs `ansible-core` on EC2 if missing, copies `ansible/` and `compose/nuc/` there, and runs `ansible-playbook site.yml` over SSH. Currently only `nuc5` (Rambles) is in `ansible/inventory/hosts.yml` — add `nuc4` once NYC's NUC has Rocky Linux installed.

To add a new NUC to Ansible management: install the public key from SSM (`/home-platform/ansible/nuc-public-key`) into its `authorized_keys`, and configure passwordless sudo for its admin user (see the `bcalaway-ansible` sudoers drop-in on nuc5 for the pattern).

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
- SSH is only open from WireGuard subnets. The laptop WireGuard peer was re-provisioned 2026-07-07 with a fresh keypair (private key in SSM at `/home-platform/wireguard/laptop-private-key` and imported into the local WireGuard app as tunnel `laptop-wireguard`; never committed to Git). If working from a device already on the NYC or Rambles LAN, that site's RB5009 also routes to the hub automatically, no client needed — but make sure the local `laptop-wireguard` tunnel is deactivated first if so, since an active tunnel takes priority for the `10.0.3.0/24` route and will break connectivity if its key is ever revoked again.
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

## Host-level security on EC2 hub

Also host-level, not tracked in Git (same caveat as nginx/certbot and rsyslog above). Reviewed and hardened 2026-07-11 as a follow-up to the AWS-level security group/IAM review (see recent git log) — that review covered the network perimeter only, not the instance itself.

- **SSH (`/etc/ssh/sshd_config`)**: `PasswordAuthentication no`, `PermitRootLogin without-password` (key-only, no root password path), `PubkeyAuthentication yes`, `KbdInteractiveAuthentication no` — this is AL2023's out-of-the-box cloud-init default from the AMI, not something added manually. Confirmed via `sshd -T`, not just by reading the file.
- **fail2ban**: installed 2026-07-11 (`dnf install fail2ban`, package is in the base `amazonlinux` repo, no EPEL needed). Config at `/etc/fail2ban/jail.local` (local override, `jail.conf` untouched) — `sshd` jail only, `maxretry=5`, `findtime=10m`, `bantime=1h`, `backend=systemd`. Deliberately does **not** whitelist the site LAN/WireGuard subnets in `ignoreip` (only `127.0.0.1`/`::1`) — SSH is already restricted to those subnets at the security-group level, so whitelisting them there too would make the jail a no-op; the point is defense-in-depth against a compromised/misbehaving internal host or leaked key. Ban action is the default `iptables-multiport`, which inserts its own dedicated chain and does not conflict with Docker's iptables-managed chains (`DOCKER`, `DOCKER-USER`, `DOCKER-ISOLATION-STAGE-*`) — verified both chain sets coexist after enabling. `systemctl enable --now fail2ban`.
- **firewalld**: pulled in as a dependency of the fail2ban package (AL2023's fail2ban RPM depends on `firewalld`/`nftables`, even though the jail itself is configured to use `iptables-multiport`, not firewalld, as the ban action). It was NOT started, and was explicitly `systemctl disable`d so it can't accidentally activate on a future reboot and reconflict with Docker's iptables rules. There is otherwise **no host-level firewall** — the AWS security group (`terraform/aws/security_groups.tf`) is the sole perimeter control, which is an intentional, acceptable pattern for this box and was left as-is (adding firewalld/nftables rules on top risks breaking Docker's own iptables-based container networking and was out of scope for this pass).
- **Docker port exposure**: `docker ps` / `ss -tlnp` confirmed every container publishes its port on `0.0.0.0` (Docker's default `docker-proxy` behavior) — node-exporter 9100, snmp-exporter 9116, prometheus 9090, cost-exporter 9199, loki 3100, grafana 3000, uptime-kuma 3001, matching `compose/aws/docker-compose.yml` exactly, nothing extra. Actual internet reachability is gated entirely by the security group: only 80, 443, 51820 (WireGuard) are open to `0.0.0.0/0`; 3001 (Uptime Kuma), 9090 (Prometheus), 3100 (Loki) are scoped to `10.0.3.0/24`; and 3000/9100/9116/9199 aren't opened in the security group at all, so they're unreachable from outside despite the container binding to `0.0.0.0`. No mismatch found.
- **nginx (`/etc/nginx/conf.d/home-platform.conf`)**: confirmed it only proxies `grafana.billandjessie.com` → `127.0.0.1:3000` and `status.billandjessie.com` → `127.0.0.1:3001`, nothing else. Both HTTPS server blocks send HSTS. No explicit `ssl_protocols`/`ssl_ciphers` directive, so it runs on nginx's compiled default; confirmed nginx version is 1.30.2 (modern default is TLSv1.2+TLSv1.3 only), so this is fine as-is.
- **Unattended security updates**: `dnf-automatic` was not installed; installed 2026-07-11. Configured in `/etc/dnf/automatic.conf` for **security updates only** (`upgrade_type = security`, `apply_updates = yes`, `download_updates = yes`) rather than the package default of all-updates. `systemctl enable --now dnf-automatic.timer` (runs once daily).
- **auditd**: already installed, active and enabled by default on this AMI. Not modified.
- **journald**: persistent logging already enabled (`/var/log/journal` exists and is populated). Not modified.
- No unexpected local logins found in `last`/`wtmp` — only the instance's own boot record.

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

- NYC RB5009 (`/system identity` = `rt-nyc`, renamed 2026-07-11): LAN 10.0.1.1/24, WireGuard 10.0.3.2
- Rambles RB5009 (`/system identity` = `rt-rambles`, renamed 2026-07-11): LAN 10.0.2.1/24, WireGuard 10.0.3.3
- EC2 WireGuard hub: 10.0.3.1 (interface ens5, not eth0)
- Laptop: WireGuard 10.0.3.4 (re-provisioned 2026-07-07 — see "EC2 access" above)
- Nighthawk RS700: AP mode at 10.0.1.2 (connect via LAN port, not WAN)
- ZenWiFi AX6600 (Rambles): converted to AP mode 2026-07-04, hangs off the RB5009 same as the RS700 pattern
- Both routers' `forward` chains trust each other's LAN subnet (not just the WireGuard subnet) — real cross-site LAN traffic works, not just router-to-router. See "Gotchas" below for why this wasn't originally obvious.
- Each router's own admin services (`www`/`www-ssl`/`winbox`) trust the *other* site's LAN too, as of 2026-07-11 — e.g. rt-nyc's web UI/Winbox is reachable from `10.0.1.0/24` (its own LAN), `10.0.2.0/24` (Rambles LAN), and `10.0.3.0/24` (WireGuard), and rt-rambles mirrors that. `ssh` was deliberately left scoped to own-LAN + WireGuard only (not widened) — this was specifically about the web/Winbox admin UI, per Bill's request. **Two separate ACLs had to be widened, not just one** — the `/ip service set ... address=` restriction on the service itself is necessary but not sufficient; each router's own `/ip firewall filter chain=input` also has its own LAN/WireGuard-only accept rules ending in a catch-all drop, and that chain governs traffic destined *to the router itself* (distinct from the `forward` chain, which only governs traffic passing *through* it to other LAN hosts). Widening only the service ACL and not the input-chain rule silently does nothing — the packets get dropped by the firewall before reaching the service layer. Added a `cross-site-lan` accept rule (source = the other site's LAN) to both routers' input chains, placed before `drop-input`.

## Gotchas (learned the hard way)

- **AWS CLI from Git Bash mangles SSM parameter paths.** MSYS auto-converts leading-`/` arguments into Windows paths, so `aws ssm get-parameter --name /home-platform/...` silently fails with `ParameterNotFound` or a path-validation error from Git Bash. Use PowerShell for any AWS CLI call involving a path-style name (SSM, IAM paths, etc).

- **Granting a new IAM permission and using it in the same Terraform apply can fail.** If a commit both adds a permission (e.g. `cloudfront:*`) to the GitHub Actions role's policy *and* creates a resource requiring it, the apply may run before the policy change has propagated (IAM is eventually consistent, typically a few seconds). Symptom: `AccessDeniedException` right after a successful policy update in the same run. Fix is just to re-run — or apply locally once with admin creds, which is unaffected since it's a different principal.

- **Compose config changes need an explicit container restart.** Editing `prometheus.yml`, `loki-config.yaml`, etc. and re-deploying (`scripts/deploy-aws-stack.ps1`) updates the file on disk, but the running container doesn't reload it automatically — `docker compose restart <service>` is required. Grafana's dashboard *provisioning* is the one exception (polls its directory every 30s per `dashboards.yml`), but Grafana datasource/plugin config still needs a restart same as everything else.

- **A freshly added Route53 record can take up to 24h to resolve on some networks.** Route53's SOA negative-cache TTL is 86400s by default. If a hosted zone existed *before* a record was added (ours did — the zone predates `billandjessie.com`'s apex A record by weeks), any resolver that queried it in the gap may have cached "no record" and will keep serving that until the negative-cache TTL expires, even though the record is now live and correct everywhere else. Verify with `--resolve` (bypasses DNS) or a fresh resolver (e.g. cellular data instead of home WiFi) before assuming something's actually broken.

- **Cisco SG300 switches (sw-main, sw-desk) need `pip install "paramiko<3"` for SSH.** Paramiko 3.x fully removed SHA-1-based key exchange (not just deprioritized — the implementation is gone), and these ~2013-era switches only offer `diffie-hellman-group1-sha1`/`group14-sha1`. Symptom: `IncompatiblePeer: no acceptable kex algorithm`. Paramiko 2.12.0 still has it.

- **SG300 SSH auth happens *inside* the shell, not at the SSH protocol layer.** `transport.auth_none(username)` succeeds and `is_authenticated()` reports `True` with no password at all — the device instead prints a `User Name:` / `Password:` prompt once you open a shell channel, exactly like a Telnet session. Send credentials as if typing them, not via paramiko's `auth_password`/`auth_interactive` (both get rejected with `BadAuthenticationType`).

- **Containers on the EC2 hub can't reach IMDS by default.** The instance's metadata hop limit defaults to 1, which only covers the host itself — a container one hop further away via the Docker bridge (e.g. `cost-exporter`'s boto3 client) gets no response and silently falls back to no credentials. Fixed via `metadata_options.http_put_response_hop_limit = 2` in `terraform/aws/ec2.tf`. Any future container that needs the instance profile's credentials relies on this already being set.

- **SG300 web UI "Add" dialogs are unreliable via clicks (real or synthetic).** Its buttons are `<table class="btn_normal">` elements with an `onclick` attribute, not real `<button>`/`<input>` elements, inside a nested frameset. Neither `computer` tool clicks nor DOM `.click()` reliably opened the dialogs. If the web UI must be used, call the handler function directly — find it via `element.getAttribute('onclick')` (grep for the function name, e.g. `addRecord`) then invoke `frame.functionName()` in the correct child frame. In practice it was easier to enable SSH under Security → TCP/UDP Services (a normal checkbox, works fine via clicks) and do everything else via CLI.

- **SG300 `snmp-server community <string> ro <ip> view <name>` — the IP comes BEFORE `view`, not after.** `ro view Default 10.0.3.1` fails with `"Wrong number of parameters or invalid range, size or characters entered"`, even though `snmp-server community public ro ?` lists `view` and an IPv4 address as if they were addable together — they're actually alternative choices for the *same* next token, and only IP-then-view is valid. Learned this the hard way by running `no snmp-server community public` first (to clear the old unrestricted entry) and then hitting this error, which left SNMP completely unconfigured — not just unrestricted, fully broken — until corrected and confirmed against a live Prometheus scrape. If clearing an existing community first, verify the replacement command actually succeeds before moving on.

- **RouterOS `/system logging add topics=a,b,c` is AND, not OR.** A single rule listing multiple topics only fires for a log entry carrying *all* of them simultaneously — which never happens, since a message only ever has one severity topic at a time. Nothing gets forwarded and there's no error; it just silently never matches. Fix: one rule per topic, all pointing at the same action, exactly like RouterOS's own built-in default rules do (`topics=info action=X`, `topics=warning action=X`, etc. as separate lines).

- **Promtail's built-in syslog scrape target only supports RFC5424, not legacy BSD syslog (RFC3164).** RouterOS and Cisco SG300 both send RFC3164 by default. Symptom: `promtail_syslog_target_parsing_errors_total` increments with `"expecting a version value in the range 1-999"` — the packets *are* arriving (check this counter, not just `promtail_sent_entries_total`, before concluding otherwise), they're just failing to parse. Fix: don't use Promtail's syslog target at all — run `rsyslog` (handles both formats) as the actual UDP 514 receiver, have it write one file per source IP, and let Promtail just tail those files. See "Syslog receiver on EC2 hub" above.

- **AL2023's `fail2ban` package silently pulls in `firewalld` and `nftables` as RPM dependencies**, even though fail2ban's own default `banaction` is `iptables-multiport` (plain iptables, not firewalld). `dnf install fail2ban` leaves firewalld installed and **enabled** (though inactive) — if left that way, a future reboot would start firewalld, which manages its own nftables-based ruleset independently of Docker's iptables chains and risks breaking container networking. Fix: `systemctl disable firewalld` right after installing fail2ban (don't just check `is-active`, check `is-enabled` too). This was caught during the 2026-07-11 EC2 host security review.

- **~~A RouterOS 7.19.6 RB5009's own `/system logging` remote-syslog action can silently fail to transmit at all~~ — misdiagnosis, resolved 2026-07-11.** Originally (2026-07-04) confirmed via `tcpdump` on the receiving end *and* RouterOS's own `/tool sniffer` on the sending router, both showing zero packets sourced from the router's LAN address, even though the firewall's `output` chain counts them as sent. The real cause: the router's self-generated syslog is sourced from its **WireGuard interface address** (10.0.3.2/10.0.3.3), not its LAN address (10.0.1.1/10.0.2.1) — makes sense in hindsight, since that's the interface the route to the hub actually goes out. Nothing was ever broken; the wrong source IP was being monitored. See `docs/network-inventory.md`'s "Log collection" section.

- **`ansible.builtin.ini_file` doesn't exist** — INI-file editing lives in `community.general.ini_file`, which isn't installed on the EC2 control node (`deploy-nucs.ps1` only ensures `ansible-core`, no extra collections). Symptom: `couldn't resolve module/action 'ansible.builtin.ini_file'`. For simple single-key edits to a well-known default config (e.g. `/etc/dnf/automatic.conf`), `ansible.builtin.lineinfile` with a `regexp`/`line` pair per key avoids the extra collection dependency entirely.

- **Promtail's `docker_sd_configs` + `__path__` relabel trick (to force file-based tailing instead of Docker-API log streaming) never actually switches tailing modes — confirmed root cause 2026-07-11.** `docker_sd_configs` targets are always consumed by Promtail 3.3.2's Docker-API-streaming target type (`target.go`, logged as `"added Docker target"` / `"finished transferring logs"`), which never reads `__path__` at all; that field is only honored by targets built from `static_configs`/`file_sd_configs` (a real `FileTarget`, logged as `"tail routine: started"`). The SD targets showing as discovered/ready on `/targets` is not evidence it's working — check which log lines actually appear (`target.go` vs `tailer.go`), not just target state. This is a known Promtail limitation, not a config mistake. Fix: don't use `docker_sd_configs` for this at all — use a plain `static_configs` job globbing `/var/lib/docker/containers/*/*-json.log` directly (safe to glob here, unlike `network-devices` above, since nothing needs relabeling off the pre-expansion filename), with `pipeline_stages` (`json` + `timestamp` + `output`) to unwrap Docker's JSON log envelope, plus a `regex` stage against the `filename` label to recover a `container_id` label (the log path only contains the opaque ID, not the container name — an accepted simplification; cross-reference via `docker ps` when needed). See `compose/aws/promtail/promtail-config.yaml`'s `docker` job.

- **`docker compose build` on the EC2 hub failed with `compose build requires buildx 0.17.0 or later`** even though Docker itself (25.0.16, AL2023's own `docker.x86_64` package) was current — AL2023's docker package doesn't pull in a buildx plugin as a dependency the way `docker-ce` does, so whatever buildx binary is present is whatever was manually dropped in at some point (found: v0.12.1, manually placed at `/usr/libexec/docker/cli-plugins/docker-buildx`, no RPM owns it). This only bites `deploy-aws-stack.ps1`'s `docker compose build` step (for `cost-exporter`, the one image built from a local Dockerfile) — `docker compose pull`/`up` for the other prebuilt images works regardless of buildx version. Fixed 2026-07-11 by downloading `docker/buildx` v0.35.0 from its GitHub releases (checksum-verified against the release's published `checksums.txt`) and replacing the binary in place (old one backed up alongside as `docker-buildx.bak-0.12.1`). Not tracked by any package manager — if the instance is ever rebuilt, redo this manually (same caveat as nginx/certbot/rsyslog above), or fix by installing a real `docker-buildx-plugin` RPM if AL2023 ever ships one.
