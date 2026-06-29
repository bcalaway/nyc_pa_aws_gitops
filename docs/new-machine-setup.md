# New Machine Setup

How to pick up where we left off from a fresh machine. Everything except AWS credentials lives in AWS or GitHub — setup takes about 10 minutes.

---

## 0. Set up Claude Code

Claude Code is the AI assistant that does all the implementation work on this project. Install it first — it will guide you through the rest if needed.

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

On first run it will ask you to log in with your Anthropic account (claude.ai login, not AWS).

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

```powershell
winget install --id Amazon.AWSCLI --silent --accept-package-agreements --accept-source-agreements
winget install --id Hashicorp.Terraform --silent --accept-package-agreements --accept-source-agreements
winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
```

Open a new shell after installing so PATH is updated.

---

## 2. Configure AWS credentials

Account: `147856894209`
IAM user: `home-platform-admin`

```powershell
aws configure set aws_access_key_id     <access-key-id>
aws configure set aws_secret_access_key <secret-access-key>
aws configure set region                us-east-1
aws configure set output                json
```

> The access key ID and secret are in Bill's **Google Password Manager** under the saved password for **aws.com**, entry `home-platform-admin`.
> Do not store them in this file or anywhere in the repository.

Verify:
```powershell
aws sts get-caller-identity
# Expected: arn:aws:iam::147856894209:user/home-platform-admin
```

---

## 3. Clone the repository

```powershell
git clone git@github.com:bcalaway/nyc_pa_aws_gitops.git
cd nyc_pa_aws_gitops
git config user.email "bcalaway@gmail.com"
git config user.name "Bill Calaway"
```

---

## 4. Restore the EC2 SSH key

The private key is stored in SSM. Pull it down and set permissions:

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

> **Note:** SSH to the EC2 instance is only open from WireGuard subnets (10.0.1/2/3.x).
> From outside those subnets, temporarily open port 22 for your IP:
> ```powershell
> $myIp = (Invoke-WebRequest -Uri "https://checkip.amazonaws.com" -UseBasicParsing).Content.Trim()
> aws ec2 authorize-security-group-ingress --group-id sg-085be907c12c4e161 --protocol tcp --port 22 --cidr "$myIp/32" --region us-east-1
> # Remember to revoke when done:
> aws ec2 revoke-security-group-ingress --group-id sg-085be907c12c4e161 --protocol tcp --port 22 --cidr "$myIp/32" --region us-east-1
> ```

---

## 5. Initialize Terraform

```powershell
cd terraform/aws
terraform init
terraform plan   # should show 0 changes if infrastructure is current
```

State is in S3 (`home-platform-terraform-state-147856894209`) — no local state file needed.

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

Retrieve any secret:
```powershell
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
