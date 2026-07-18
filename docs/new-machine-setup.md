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

**Alternative: SSH instead of HTTPS.** If you'd rather use `git clone git@github.com:...` directly (e.g. muscle memory, or `gh` isn't set up on this box), pull the shared NUC keypair from SSM instead of generating a new one:
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
aws ssm get-parameter --name "/home-platform/github/nuc-ssh-private-key" --with-decryption --region us-east-1 \
  --query "Parameter.Value" --output text > ~/.ssh/id_ed25519
aws ssm get-parameter --name "/home-platform/github/nuc-ssh-public-key" --region us-east-1 \
  --query "Parameter.Value" --output text > ~/.ssh/id_ed25519.pub
chmod 600 ~/.ssh/id_ed25519
ssh -o StrictHostKeyChecking=accept-new -T git@github.com   # should greet you as bcalaway
git clone git@github.com:bcalaway/nyc_pa_aws_gitops.git
```
This key is already registered on GitHub (titled "nuc key") and already deployed on nuc4/nuc5 — reuse it rather than generating a new one per machine, same as the Ansible key.

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

**Also set `COLORTERM=truecolor` on the remote side**, or Claude Code's TUI renders noticeably worse (chunky/low-fidelity mascot art, coarser box-drawing) — confirmed 2026-07-17 by comparing a NUC's PuTTY session against a truecolor-enabled one side by side. PuTTY itself has supported 24-bit color since v0.71 and needs no special local setting for it; the gap is that PuTTY doesn't set `COLORTERM` on the remote shell, and Claude Code's terminal-capability detection falls back to a reduced palette without it. Add to `~/.bashrc` (already done on nuc4/nuc5):
```bash
export COLORTERM=truecolor
```
Close and reopen the PuTTY session (or `source ~/.bashrc`) for it to take effect.

---

## 9. Install pgAdmin (Windows workstation)

pgAdmin is the GUI client for the shared Postgres instance running on the AWS hub (`compose/aws/docker-compose.yml`, Milestone 11 — ADR-0016). The hub's security group only allows port 5432 from WireGuard peers (`10.0.3.0/24`, see `terraform/aws/security_groups.tf`), so this only works over the WireGuard tunnel or from a site LAN that routes to the hub (same reachability rules as SSH — see "EC2 access" in `CLAUDE.md`).

```powershell
winget install --id PostgreSQL.pgAdmin --silent --accept-package-agreements --accept-source-agreements
```

**Register the server connection via CLI** (avoids clicking through the GUI, and avoids ever typing the Postgres password into anything — it registers host/port/user only, no password):

```powershell
# First launch initializes pgAdmin's own config DB (~\AppData\Roaming\pgAdmin\pgadmin4.db)
# and a default desktop user, pgadmin4@pgadmin.org -- launch it once and close it if the
# steps below fail with "no such user".
$pgadminDir = "$env:LOCALAPPDATA\Programs\pgAdmin 4"
$serversJson = "$env:TEMP\pgadmin-servers.json"
@'
{
    "Servers": {
        "1": {
            "Name": "Home Platform Postgres (Hub)",
            "Group": "Servers",
            "Host": "10.0.3.1",
            "Port": 5432,
            "MaintenanceDB": "postgres",
            "Username": "postgres",
            "SSLMode": "prefer"
        }
    }
}
'@ | Set-Content -Path $serversJson

$env:PATH = "$pgadminDir\runtime;" + $env:PATH   # libpq.dll lives here; psycopg needs it on PATH
& "$pgadminDir\python\python.exe" "$pgadminDir\web\setup.py" load-servers $serversJson --user pgadmin4@pgadmin.org --replace
Remove-Item $serversJson
```

On first connect in the pgAdmin GUI, it'll prompt for the password — fetch it from SSM rather than storing it anywhere:
```powershell
(aws ssm get-parameter --name "/home-platform/postgres/admin-password" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
```
Check "Save Password" in the prompt if you want pgAdmin to remember it (encrypted in its own config DB, gated by your Windows login) — or leave it unchecked and re-enter each session.

---

## 10. Set up NvChad on a NUC

This is Bill's personal editor config for `bcalaway` on the NUCs (nuc4, nuc5) — not Ansible-managed, since it's a dotfiles preference rather than infrastructure state. Redo manually on any new/reimaged NUC. Requires the PuTTY font setup from step 8 to actually see the icons.

Rocky Linux's EPEL-packaged Neovim (0.10.1 as of Rocky 10.2) is too old for current NvChad/plugin configs, which expect ≥0.11 — install a current upstream release instead of the distro package:

```bash
# fd/fzf are in EPEL (already enabled on the NUC image); lazygit isn't packaged, grab it from GitHub
sudo dnf install -y fd-find fzf

# Neovim: check https://github.com/neovim/neovim/releases/latest for the current version
cd /tmp
curl -fsSL -o nvim-linux-x86_64.tar.gz https://github.com/neovim/neovim/releases/download/v0.12.4/nvim-linux-x86_64.tar.gz
tar tzf nvim-linux-x86_64.tar.gz > /dev/null && echo 'archive OK'   # sanity check before extracting
mkdir -p ~/.local
rm -rf ~/.local/nvim-0.12.4
tar xzf nvim-linux-x86_64.tar.gz -C ~/.local/
mv ~/.local/nvim-linux-x86_64 ~/.local/nvim-0.12.4
ln -sf ~/.local/nvim-0.12.4/bin/nvim ~/.local/bin/nvim   # ~/.local/bin is already first on PATH (bcalaway's .bashrc)
rm nvim-linux-x86_64.tar.gz
nvim --version | head -1

# lazygit: check https://github.com/jesseduffield/lazygit/releases/latest for the current version
curl -fsSL -o lazygit.tar.gz https://github.com/jesseduffield/lazygit/releases/download/v0.63.1/lazygit_0.63.1_linux_x86_64.tar.gz
tar tzf lazygit.tar.gz > /dev/null && echo 'archive OK'
tar xzf lazygit.tar.gz -C /tmp lazygit
mv /tmp/lazygit ~/.local/bin/lazygit
chmod +x ~/.local/bin/lazygit
rm lazygit.tar.gz

# NvChad itself
git clone https://github.com/NvChad/starter ~/.config/nvim
rm -rf ~/.config/nvim/.git   # detach from the starter repo, it's your own config now

# Sync plugins headlessly so the first interactive launch isn't slow
timeout 180 nvim --headless '+Lazy! sync' +qa
```

> **Gotcha:** `nvim --headless '+Lazy! sync' +qa` hangs silently (0% CPU, no output, no error) if the installed Neovim is older than what the config requires — it's stuck on an interactive "Press any key to exit" version-check prompt with no TTY to receive the keypress. Always wrap the sync in `timeout` and check `ps`/CPU usage if it's not progressing after a minute or two; don't assume it's just slow.

Verify it worked:
```bash
ls ~/.local/share/nvim/lazy/ | wc -l   # ~27 plugins expected
nvim --headless -c 'lua print(#vim.tbl_keys(require("lazy").plugins()))' -c 'qa'
```

Alias `vi` to `nvim` (there's an existing "User specific aliases and functions" comment line in `~/.bashrc` on the Rocky NUC image — add it there):
```bash
sed -i "/# User specific aliases and functions/a alias vi='nvim'" ~/.bashrc
```
Reconnect (or `source ~/.bashrc`) for it to take effect.

### Optional: custom prompt (user@host + cwd + [git branch] + `>`)

Bill's preferred prompt format (matches a style he uses elsewhere), added to `~/.bashrc`. Colors: username red, `@` white/grey, hostname green, path blue, `[branch]` red, `>` blue.
```bash
cat >> ~/.bashrc <<'EOF'

# Custom prompt: user@host + cwd + [git branch] + >
parse_git_branch() {
  git branch --show-current 2>/dev/null
}
PS1='\[\e[1;31m\]\u\[\e[1;37m\]@\[\e[1;32m\]\h\[\e[1;34m\]\w\[\e[0m\] \[\e[1;31m\][$(parse_git_branch)]\[\e[1;34m\]>\[\e[0m\]'
EOF
```
Renders as `bcalaway@nuc4~/workspace/foo [branch-name]>` inside a git repo, or `bcalaway@nuc4~ []>` outside one — no separator between hostname and path, no trailing space after `>`.

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
| `/home-platform/postgres/admin-password` | SecureString | Shared Postgres (hub) superuser password — used by pgAdmin, see step 9 |

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
