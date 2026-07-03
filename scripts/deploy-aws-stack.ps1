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

"GRAFANA_SMTP_PASSWORD=$smtpPassword" | Set-Content -Path (Join-Path $localDir ".env") -NoNewline

Write-Host "Copying compose stack to EC2..."
ssh -i $sshKey $ec2Host "mkdir -p $remoteDir"
scp -i $sshKey -r "$localDir\*" "${ec2Host}:${remoteDir}/"
scp -i $sshKey "$localDir\.env" "${ec2Host}:${remoteDir}/.env"

Write-Host "Starting stack..."
ssh -i $sshKey $ec2Host "cd $remoteDir && docker compose pull && docker compose up -d"

Write-Host "Done. Services on EC2 (reachable via WireGuard):"
Write-Host "  Grafana:      http://10.0.3.1:3000"
Write-Host "  Prometheus:   http://10.0.3.1:9090"
Write-Host "  Uptime Kuma:  http://10.0.3.1:3001"
Write-Host "  Loki:         http://10.0.3.1:3100"
