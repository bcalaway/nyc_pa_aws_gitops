# New Machine Setup

How to pick up where we left off from a fresh machine. Everything except AWS credentials lives in AWS or GitHub — setup takes about 10 minutes.

Two tracks below: **Windows** (Bill's primary workstation, uses winget/PowerShell) and **Linux** (Rocky Linux NUCs — nuc4, nuc5, and any future ones; dnf-based, matches how `ansible/roles/base` provisions them). Pick the one that matches the machine.

---

## 0. Set up Claude Code

Claude Code is the AI assistant that does all the implementation work on this project. Install it first — it will guide you through the rest if needed.

### Windows

**Install Node.js** (required by Claude Code):
```powershell
winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
```

**Install Claude Code:**
```powershell
npm install -g @anthropic-ai/claude-code
```

**Start a session:**
```powershell
cd C:\path\to\nyc_pa_aws_gitops
claude
```

### Linux

No Node.js dependency — Claude Code ships a native binary on Linux. This is the actual method used on nuc4 and nuc5 (2026-07-14, see `docs/network-inventory.md`):

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Installs to `~/.local/bin/claude`. Make sure `~/.local/bin` is on `PATH` (it is by default on Rocky 10 for interactive shells).

**Start a session:**
```bash
cd ~/workspace/nyc_pa_aws_gitops   # or wherever the repo is cloned
claude
```

### Both platforms

On first run it will ask you to log in with your Anthropic account (claude.ai login, not AWS) — this step is interactive (browser OAuth) and can't be done on your behalf by an existing Claude Code session.

**Kick-off prompt to resume work:**

Once Claude starts, paste this to bring it up to speed instantly:

```
I'm picking up the home-platform project on a new machine.
The repo is at github.com/bcalaway/nyc_pa_aws_gitops.
AWS credentials are configured (home-platform-admin, account 147856894209).
Please read docs/new-machine-setup.md and docs/roadmap.md,
then tell me where we left off and what's next.
```

Claude will read the docs and then automatically run these checks before reporting status — no need to re-explain the project or ask Claude to verify anything manually:

**Claude: run these checks immediately after reading this file, without being asked:**
1. `aws sts get-caller-identity` — confirm credentials are valid and return the ARN. If this fails, tell Bill before doing anything else: the credentials need to be updated (see step 2 below).
2. `terraform -chdir=terraform/aws plan -detailed-exitcode` — confirm no unexpected drift.
3. Report the results of both checks alongside the project status summary.

> **Note:** Claude Code is billed per token through your Anthropic account. No separate API key is needed when using the Claude Code CLI with your claude.ai account.

---

## 1. Install tools

### Windows

```powershell
winget install --id Amazon.AWSCLI --silent --accept-package-agreements --accept-source-agreements
winget install --id Hashicorp.Terraform --silent --accept-package-agreements --accept-source-agreements
winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
```

Open a new shell after installing so PATH is updated.

### Linux

Git and `dnf-plugins-core` are already present on Ansible-provisioned NUCs (installed by `ansible/roles/base`) — the `dnf install git` below is only needed on a machine that skipped that role. None of AWS CLI, gh, or Terraform are installed by Ansible; all three need doing manually here.

**AWS CLI v2** (no dnf package — Amazon ships it as a zip installer):
```bash
sudo dnf install -y git unzip
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
```

**Terraform** (HashiCorp's official yum repo):
```bash
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform
```

**gh CLI** (GitHub's official yum repo):
```bash
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh
```

Verify all three landed:
```bash
aws --version && terraform version && gh --version
```

---

## 2. Configure AWS credentials

Account: `147856894209`
IAM user: `home-platform-admin`

Identical command on both platforms:
```
aws configure set aws_access_key_id     <access-key-id>
aws configure set aws_secret_access_key <secret-access-key>
aws configure set region                us-east-1
aws configure set output                json
```

> The access key ID and secret are in Bill's **Google Password Manager** under the saved password for **aws.com**, entry `home-platform-admin`.
> Do not store them in this file or anywhere in the repository.

Verify (identical command on both platforms):
```
aws sts get-caller-identity
# Expected: arn:aws:iam::147856894209:user/home-platform-admin
```

---

## 3. Clone the repository

### Windows

```powershell
git clone git@github.com:bcalaway/nyc_pa_aws_gitops.git
cd nyc_pa_aws_gitops
git config user.email "bcalaway@gmail.com"
git config user.name "Bill Calaway"
```

### Linux

Clone over HTTPS, not SSH — push auth is wired up via `gh auth setup-git` in step 5, so no separate SSH deploy key is needed:

```bash
git clone https://github.com/bcalaway/nyc_pa_aws_gitops.git
cd nyc_pa_aws_gitops
git config --global user.email "bcalaway@gmail.com"
git config --global user.name "Bill Calaway"
```

(`--global` here since NUCs are single-user machines — matches the pattern already on nuc4/nuc5.)

---

## 4. Restore the EC2 SSH key

The private key is stored in SSM. Pull it down and set permissions.

### Windows

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.ssh" | Out-Null
$pem = aws ssm get-parameter --name "/home-platform/ec2/ssh-private-key" --with-decryption --region us-east-1 |
  ConvertFrom-Json | Select-Object -ExpandProperty Parameter | Select-Object -ExpandProperty Value
[System.IO.File]::WriteAllText(
  "$HOME\.ssh\home-platform.pem",
  $pem,
  (New-Object System.Text.UTF8Encoding $false)
)
icacls "$HOME\.ssh\home-platform.pem" /inheritance:r /grant:r "${env:USERNAME}:R"
```

Verify SSH works (requires WireGuard tunnel or temporary SG rule — see below):
```powershell
ssh -i "$HOME\.ssh\home-platform.pem" ec2-user@3.82.89.106 "echo connected"
```

### Linux

```bash
mkdir -p ~/.ssh
aws ssm get-parameter --name "/home-platform/ec2/ssh-private-key" --with-decryption --region us-east-1 \
  --query "Parameter.Value" --output text > ~/.ssh/home-platform.pem
chmod 600 ~/.ssh/home-platform.pem
```

If the machine is a NUC physically on the NYC or Rambles LAN (the normal case — see "Network topology" in `CLAUDE.md`), it already reaches the hub over the site router's own WireGuard link, no client tunnel needed. SSH straight to the hub's WireGuard IP, not the public Elastic IP:
```bash
ssh -i ~/.ssh/home-platform.pem ec2-user@10.0.3.1 "echo connected"
```

### Both platforms — if the machine is remote (not on either site LAN)

> **Note:** SSH to the EC2 instance is only open from WireGuard subnets (10.0.1/2/3.x). From a machine with neither a site LAN connection nor a WireGuard client, temporarily open port 22 for your IP instead of using `10.0.3.1`:
> ```powershell
> $myIp = (Invoke-WebRequest -Uri "https://checkip.amazonaws.com" -UseBasicParsing).Content.Trim()
> aws ec2 authorize-security-group-ingress --group-id sg-085be907c12c4e161 --protocol tcp --port 22 --cidr "$myIp/32" --region us-east-1
> # Remember to revoke when done:
> aws ec2 revoke-security-group-ingress --group-id sg-085be907c12c4e161 --protocol tcp --port 22 --cidr "$myIp/32" --region us-east-1
> ```
> Then SSH to the public IP (`ec2-user@3.82.89.106`) instead of `10.0.3.1`. A remote Linux machine that needs *ongoing* (not one-off) access would need its own WireGuard peer provisioned — the existing "laptop" peer (`10.0.3.4`) is tied to Bill's Windows laptop specifically and shouldn't be reused elsewhere.

---

## 5. Install gh CLI and authenticate

The GitHub token is stored in SSM — no need to generate a new one.

### Windows

```powershell
winget install --id GitHub.cli --accept-package-agreements --accept-source-agreements

# Open a new terminal after install, then:
$token = (aws ssm get-parameter --name "/home-platform/github/api-token" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$token | gh auth login --with-token

gh run list --repo bcalaway/nyc_pa_aws_gitops --limit 5  # verify it works
```

### Linux

gh itself was already installed in step 1 — this just authenticates it and wires it up as git's credential helper (needed since the repo was cloned over HTTPS in step 3):

```bash
token=$(aws ssm get-parameter --name "/home-platform/github/api-token" --with-decryption --region us-east-1 --output json | jq -r '.Parameter.Value')
echo "$token" | gh auth login --with-token
gh auth setup-git

gh run list --repo bcalaway/nyc_pa_aws_gitops --limit 5  # verify it works
```

`jq` is a dnf base package (`sudo dnf install -y jq` if missing). `gh auth setup-git` registers `gh auth git-credential` as the credential helper for `github.com`/`gist.github.com` in `~/.gitconfig` — without it, `git push` will prompt for a username/password it can't satisfy.

---

## 6. Install Python dependencies (for RouterOS config apply)

### Windows

```powershell
pip install paramiko boto3
```

### Linux

```bash
sudo dnf install -y python3-pip
pip3 install --user paramiko boto3
```

Used by `routeros/apply-config.py` to SSH into routers and push config files. (Note the separate CLAUDE.md gotcha: talking to the Cisco SG300 switches specifically needs `paramiko<3`, since those switches only offer SHA-1 key exchange that paramiko 3.x removed — install a pinned second copy or a venv if you need both.)

---

## 7. Initialize Terraform

Identical on both platforms:

```bash
cd terraform/aws
terraform init
terraform plan   # should show 0 changes if infrastructure is current
```

State is in S3 (`home-platform-terraform-state-147856894209`) — no local state file needed.

---

## 8. Set up PuTTY for SSH to Linux boxes (NUCs, EC2 hub)

PuTTY renders using a font installed on *this* Windows machine, not anything on the remote Linux box — without a proper font, Claude Code's box-drawing/status symbols and Neovim's devicons/statusline glyphs show up as boxes or garbage.

```powershell
winget install --id PuTTY.PuTTY --silent --accept-package-agreements --accept-source-agreements
winget install --id DEVCOM.JetBrainsMonoNerdFont --accept-package-agreements --accept-source-agreements
```

For each PuTTY session you create (nuc4, nuc5, the EC2 hub, etc.):
1. **Session** — enter host name, save the session name
2. **Window → Appearance → Font** — click "Change...", select **JetBrainsMono NF**, size 11, and set Font Quality to **ClearType**
3. **Window → Translation → Remote character set** — set to **UTF-8**
4. Go back to **Session**, click **Save**

If you already have saved PuTTY sessions and want to apply this to all of them at once instead of clicking through each one:
```powershell
Get-ChildItem "HKCU:\Software\SimonTatham\PuTTY\Sessions" | ForEach-Object {
  $p = $_.PSPath
  Set-ItemProperty -Path $p -Name "Font" -Value "JetBrainsMono NF"
  Set-ItemProperty -Path $p -Name "FontHeight" -Value 11
  Set-ItemProperty -Path $p -Name "FontQuality" -Value 3
  Set-ItemProperty -Path $p -Name "LineCodePage" -Value "UTF-8"
}
```
Close and reopen any already-open PuTTY windows for the change to take effect.

> The remote side also needs a UTF-8 locale (`locale` should show `en_US.UTF-8`) — this is already the default on the NUCs and EC2 hub, so it's normally a non-issue.

---

## Key inventory (all in SSM)

| SSM Path | Type | Contents |
|----------|------|----------|
| `/home-platform/ec2/ssh-private-key` | SecureString | EC2 SSH private key |
| `/home-platform/wireguard/server-private-key` | SecureString | WireGuard hub private key |
| `/home-platform/wireguard/server-public-key` | String | WireGuard hub public key |
| `/home-platform/wireguard/nyc-private-key` | SecureString | NYC RB5009 WireGuard private key |
| `/home-platform/wireguard/nyc-public-key` | String | NYC RB5009 WireGuard public key |
| `/home-platform/wireguard/rambles-private-key` | SecureString | Rambles RB5009 WireGuard private key |
| `/home-platform/wireguard/rambles-public-key` | String | Rambles RB5009 WireGuard public key |
| `/home-platform/wireguard/laptop-private-key` | SecureString | Laptop WireGuard private key |
| `/home-platform/wireguard/laptop-public-key` | String | Laptop WireGuard public key |
| `/home-platform/grafana/smtp-password` | SecureString | Grafana Gmail SMTP password (set when configuring Milestone 3) |

Retrieve any secret (identical on both platforms):
```
aws ssm get-parameter --name "/home-platform/ec2/ssh-private-key" --with-decryption --query "Parameter.Value" --output text
```

---

## Infrastructure summary

| Resource | Value |
|----------|-------|
| EC2 instance | `i-0938524547e847e77` (t3.small, Amazon Linux 2023) |
| Elastic IP | `3.82.89.106` |
| EC2 key pair name | `home-platform` |
| EC2 security group | `sg-085be907c12c4e161` |
| VPC | `vpc-043187c1d1b29ff6d` |
| Terraform state bucket | `home-platform-terraform-state-147856894209` |
| Logs bucket | `home-platform-logs-147856894209` |
| Portal bucket | `home-platform-portal-147856894209` |
| Route53 hosted zone | `Z0138104TDGCUTG6KYQI` (billandjessie.com) |
| GitHub Actions IAM role | `arn:aws:iam::147856894209:role/home-platform-github-actions` |
| WireGuard hub | `10.0.3.1` on EC2 |
| NYC WireGuard peer | `10.0.3.2` (RB5009) |
| Rambles WireGuard peer | `10.0.3.3` (RB5009) |
| Laptop WireGuard peer | `10.0.3.4` (road warrior) |

---

## What the AWS credentials cannot recover

Nothing — the access key + secret above is the single recovery credential. Everything else flows from it. Keep it in a password manager.

If the `home-platform-admin` access key is ever rotated or deleted, create a new key in IAM and update `aws configure`.
