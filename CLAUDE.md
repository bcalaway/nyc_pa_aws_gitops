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
- SSH is only open from WireGuard subnets — laptop WireGuard must be active, or temporarily open port 22 for your IP (see `docs/new-machine-setup.md`)

```powershell
ssh -i "$HOME\.ssh\home-platform.pem" ec2-user@3.82.89.106
```

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
- Laptop: WireGuard 10.0.3.4
- Nighthawk RS700: AP mode at 10.0.1.2 (connect via LAN port, not WAN)
