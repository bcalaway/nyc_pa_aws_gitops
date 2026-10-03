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

Write-Host "Fetching Redis password from SSM..."
$redisPassword = (& $aws ssm get-parameter --name "/home-platform/authentik/redis-password" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value

Write-Host "Fetching Rachio API key from SSM..."
$rachioApiKey = (& $aws ssm get-parameter --name "/home-platform/rachio/api-key" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value

Write-Host "Fetching Authentik secrets from SSM..."
$authentikDbPassword = (& $aws ssm get-parameter --name "/home-platform/authentik/db-password" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikSecretKey = (& $aws ssm get-parameter --name "/home-platform/authentik/secret-key" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikBootstrapPassword = (& $aws ssm get-parameter --name "/home-platform/authentik/bootstrap-password" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikGrafanaClientId = (& $aws ssm get-parameter --name "/home-platform/authentik/grafana-client-id" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikGrafanaClientSecret = (& $aws ssm get-parameter --name "/home-platform/authentik/grafana-client-secret" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikTodoAppClientId = (& $aws ssm get-parameter --name "/home-platform/authentik/todo-app-client-id" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikTodoAppClientSecret = (& $aws ssm get-parameter --name "/home-platform/authentik/todo-app-client-secret" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikHueClientId = (& $aws ssm get-parameter --name "/home-platform/authentik/hue-client-id" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikHueClientSecret = (& $aws ssm get-parameter --name "/home-platform/authentik/hue-client-secret" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikHomeMcpClientId = (& $aws ssm get-parameter --name "/home-platform/authentik/home-mcp-client-id" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$authentikHomeMcpClientSecret = (& $aws ssm get-parameter --name "/home-platform/authentik/home-mcp-client-secret" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
# Multi-line private key -> base64 so it survives the .env file as one line.
$voiceWorkerSshKeyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((& $aws ssm get-parameter --name "/home-platform/voice-worker/ssh-private-key" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value))

Write-Host "Fetching Umami secrets from SSM..."
$umamiDbPassword = (& $aws ssm get-parameter --name "/home-platform/postgres/umami-password" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$umamiAppSecret = (& $aws ssm get-parameter --name "/home-platform/umami/app-secret" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
$umamiTwoFactorKey = (& $aws ssm get-parameter --name "/home-platform/umami/two-factor-encryption-key" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value
# Optional (ADR-0022): "none" until the voice jobs token exists.
$voiceJobsToken = (& $aws ssm get-parameter --name "/home-platform/github/voice-jobs-token" --with-decryption --region us-east-1 --output json 2>$null | ConvertFrom-Json).Parameter.Value
if (-not $voiceJobsToken) { $voiceJobsToken = "none" }
# Optional (ADR-0024): "none" until the GitHub security-read token exists.
$githubSecurityToken = (& $aws ssm get-parameter --name "/home-platform/github/security-read-token" --with-decryption --region us-east-1 --output json 2>$null | ConvertFrom-Json).Parameter.Value
if (-not $githubSecurityToken) { $githubSecurityToken = "none" }
# ADR-0024: home-mcp's Authentik audit token, generated once if missing
# (same as scripts/hub/deploy-hub-stack.sh's audit_token).
$auditToken = (& $aws ssm get-parameter --name "/home-platform/authentik/home-mcp-audit-token" --with-decryption --region us-east-1 --output json 2>$null | ConvertFrom-Json).Parameter.Value
if (-not $auditToken) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $auditToken = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    # No --overwrite: if the read above failed for any reason other than the
    # parameter not existing, this fails instead of replacing a live token.
    & $aws ssm put-parameter --name "/home-platform/authentik/home-mcp-audit-token" --type SecureString --value $auditToken --region us-east-1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't read or create /home-platform/authentik/home-mcp-audit-token" }
}
# Airflow (ADR-0027). Created by the CI platform deploy; a manual deploy only
# reads them, so run the CI deploy once first.
function Get-Required($param) {
    $v = (& $aws ssm get-parameter --name "/home-platform/$param" --with-decryption --region us-east-1 --output json 2>$null | ConvertFrom-Json).Parameter.Value
    if (-not $v) { throw "/home-platform/$param missing -- run the CI platform deploy first" }
    return $v
}
$airflowDbPassword = Get-Required "postgres/airflow-password"
$airflowFernetKey = Get-Required "airflow/fernet-key"
$airflowApiSecretKey = Get-Required "airflow/api-secret-key"
$airflowJwtSecret = Get-Required "airflow/jwt-secret"

"GRAFANA_SMTP_PASSWORD=$smtpPassword`nPOSTGRES_PASSWORD=$postgresPassword`nREDIS_PASSWORD=$redisPassword`nRACHIO_API_KEY=$rachioApiKey`nAUTHENTIK_DB_PASSWORD=$authentikDbPassword`nAUTHENTIK_SECRET_KEY=$authentikSecretKey`nAUTHENTIK_BOOTSTRAP_PASSWORD=$authentikBootstrapPassword`nAUTHENTIK_GRAFANA_CLIENT_ID=$authentikGrafanaClientId`nAUTHENTIK_GRAFANA_CLIENT_SECRET=$authentikGrafanaClientSecret`nAUTHENTIK_TODO_APP_CLIENT_ID=$authentikTodoAppClientId`nAUTHENTIK_TODO_APP_CLIENT_SECRET=$authentikTodoAppClientSecret`nAUTHENTIK_HUE_CLIENT_ID=$authentikHueClientId`nAUTHENTIK_HUE_CLIENT_SECRET=$authentikHueClientSecret`nAUTHENTIK_HOME_MCP_CLIENT_ID=$authentikHomeMcpClientId`nAUTHENTIK_HOME_MCP_CLIENT_SECRET=$authentikHomeMcpClientSecret`nVOICE_WORKER_SSH_KEY_B64=$voiceWorkerSshKeyB64`nUMAMI_DB_PASSWORD=$umamiDbPassword`nUMAMI_APP_SECRET=$umamiAppSecret`nUMAMI_TWO_FACTOR_KEY=$umamiTwoFactorKey`nVOICE_JOBS_GITHUB_TOKEN=$voiceJobsToken`nGITHUB_SECURITY_TOKEN=$githubSecurityToken`nAUTHENTIK_HOME_MCP_AUDIT_TOKEN=$auditToken`nAIRFLOW_DB_PASSWORD=$airflowDbPassword`nAIRFLOW_FERNET_KEY=$airflowFernetKey`nAIRFLOW_API_SECRET_KEY=$airflowApiSecretKey`nAIRFLOW_JWT_SECRET=$airflowJwtSecret" | Set-Content -Path (Join-Path $localDir ".env") -NoNewline

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

# Per-PR previews' network (ADR-0023), created once; see scripts/hub/deploy-hub-stack.sh.
ssh -i $sshKey $ec2Host "docker network inspect preview >/dev/null 2>&1 || docker network create --internal preview"
# Exposure-check results dir (ADR-0024), bind-mounted into home-mcp.
ssh -i $sshKey $ec2Host "sudo install -d -m 0755 /var/lib/home-platform/exposure"

Write-Host "Starting stack..."
# Promtail -> Alloy (2026-10-02): remove the old container first; see deploy-hub-stack.sh.
ssh -i $sshKey $ec2Host "docker rm -f promtail >/dev/null 2>&1 || true"
# HUP Prometheus (config reload) only if it was already running before `up`,
# and from inside the container: `docker kill` marks it manually stopped, so it
# wouldn't come back after a reboot (see docs/gotchas.md).
# Airflow DAG root (ADR-0027, see scripts/hub/deploy-hub-stack.sh).
# Also the app-job helper and .airflowignore at the DAG root (ADR-0031). App
# connections (/home/ec2-user/airflow/connections.env) are only built by the
# CI deploy, which reads the registry; a manual deploy leaves them as they are.
ssh -i $sshKey $ec2Host "mkdir -p /home/ec2-user/airflow/dags/platform && cp -rT $remoteDir/airflow/dags/platform /home/ec2-user/airflow/dags/platform && cp $remoteDir/airflow/dags/home_platform_jobs.py $remoteDir/airflow/dags/.airflowignore /home/ec2-user/airflow/dags/"
ssh -i $sshKey $ec2Host "cd $remoteDir && docker compose pull && docker compose build && t0=`$(date +%s) && docker compose up -d && s=`$(docker inspect -f '{{.State.StartedAt}}' prometheus) && if [ `"`$(date -d `"`$s`" +%s)`" -lt `"`$t0`" ]; then docker exec prometheus kill -HUP 1; fi"

Write-Host "Installing host units (ADR-0024)..."
ssh -i $sshKey $ec2Host "sudo bash $remoteDir/host/install.sh $remoteDir"

Write-Host "Done. Services on EC2 (reachable via WireGuard):"
Write-Host "  Grafana:      http://10.0.3.1:3000"
Write-Host "  Prometheus:   http://10.0.3.1:9090"
Write-Host "  Uptime Kuma:  http://10.0.3.1:3001"
Write-Host "  Loki:         http://10.0.3.1:3100"
