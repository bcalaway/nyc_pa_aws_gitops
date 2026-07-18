# Deploys/updates the AWS monitoring stack (Prometheus, Grafana, Loki, Uptime Kuma) to EC2.
# Requires: WireGuard tunnel active, AWS credentials configured, EC2 SSH key at ~/.ssh/home-platform.pem.

$ErrorActionPreference = "Stop"

$aws       = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$sshKey    = "$HOME\.ssh\home-platform.pem"
$ec2Host   = "ec2-user@10.0.3.1"
$remoteDir = "/home/ec2-user/compose-aws"
$localDir  = Join-Path $PSScriptRoot "..\compose\aws"

Write-Host "Fetching Grafana SMTP password from SSM..."
$smtpPassword = (& $aws ssm get-parameter --name "/home-platform/grafana/smtp-password" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value

Write-Host "Fetching Postgres admin password from SSM..."
$postgresPassword = (& $aws ssm get-parameter --name "/home-platform/postgres/admin-password" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value

"GRAFANA_SMTP_PASSWORD=$smtpPassword`nPOSTGRES_PASSWORD=$postgresPassword" | Set-Content -Path (Join-Path $localDir ".env") -NoNewline

Write-Host "Copying compose stack to EC2..."
ssh -i $sshKey $ec2Host "mkdir -p $remoteDir"

# Delete remote files that no longer exist locally before copying. scp -r alone
# only adds/overwrites, so a removed dashboard/config would silently keep being
# provisioned forever -- confirmed 2026-07-12 when a couple of deleted dashboard
# JSON files kept getting served after being removed from this repo.
#
# IMPORTANT: this must delete individual stale FILES, never directories. An
# earlier version of this fix did `rm -rf $remoteDir && mkdir -p` before
# copying, which recreates directories like grafana/provisioning with a new
# inode -- for a container that's still running (not recreated, since no
# service definition changed) with that path bind-mounted, Docker's bind mount
# doesn't follow the path to the new inode, so the container sees "no such
# file or directory" until it's restarted. Confirmed live: this broke Grafana's
# dashboard provisioning the same day this fix was first added. Deleting only
# the specific stale files (not their parent directories) avoids the problem
# entirely, since existing directory inodes are never touched.
$localDirResolved = (Resolve-Path $localDir).Path
$localFiles = Get-ChildItem -Path $localDirResolved -Recurse -File | ForEach-Object {
    ($_.FullName.Substring($localDirResolved.Length + 1)) -replace '\\', '/'
}
$remoteFiles = (ssh -i $sshKey $ec2Host "find $remoteDir -type f -printf '%P\n'") -split "`n" | Where-Object { $_ -and $_ -ne '.env' }
$staleFiles = $remoteFiles | Where-Object { $_ -notin $localFiles }
foreach ($f in $staleFiles) {
    Write-Host "  Removing stale remote file: $f"
    ssh -i $sshKey $ec2Host "rm -f '$remoteDir/$f'"
}

scp -i $sshKey -r "$localDir\*" "${ec2Host}:${remoteDir}/"
scp -i $sshKey "$localDir\.env" "${ec2Host}:${remoteDir}/.env"

Write-Host "Starting stack..."
ssh -i $sshKey $ec2Host "cd $remoteDir && docker compose pull && docker compose build && docker compose up -d"

Write-Host "Done. Services on EC2 (reachable via WireGuard):"
Write-Host "  Grafana:      http://10.0.3.1:3000"
Write-Host "  Prometheus:   http://10.0.3.1:9090"
Write-Host "  Uptime Kuma:  http://10.0.3.1:3001"
Write-Host "  Loki:         http://10.0.3.1:3100"
