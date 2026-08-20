# Runs the Ansible NUC-provisioning playbook from the EC2 hub.
# Ansible's control node doesn't support Windows, so this pushes ansible/ and
# compose/nuc/ to EC2 (which already has WireGuard routes to both site LANs)
# and triggers the run there via SSH.
# Requires: WireGuard tunnel active, AWS credentials configured, EC2 SSH key
# at ~/.ssh/home-platform.pem.

$ErrorActionPreference = "Stop"

# $ErrorActionPreference only governs PowerShell cmdlets -- ssh.exe/scp.exe
# are native processes, so a non-zero exit code from them does NOT stop the
# script on its own. Hit for real 2026-08-20: the hub had three ansible/
# files (site.yml, one host's inventory, routeros.yml) left root-owned by
# some earlier operation, so `scp` (running as ec2-user) failed with
# "Permission denied" on every file in ansible/ -- printed the errors, but
# the script carried on to "Running playbook..." regardless, silently
# running the *stale* pre-existing copy on the hub instead of what was just
# pushed. Several ansible-playbook runs "succeeded" against files that were
# never actually updated before this was caught. Every external command
# that must not be allowed to fail silently now goes through this check.
function Invoke-Checked {
    param([string]$Description)
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

$aws       = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$sshKey    = "$HOME\.ssh\home-platform.pem"
$ec2Host   = "ec2-user@10.0.3.1"
$remoteDir = "/home/ec2-user/home-platform"
$repoRoot  = Join-Path $PSScriptRoot ".."

Write-Host "Fetching Ansible NUC private key from SSM..."
$nucKey = (& $aws ssm get-parameter --name "/home-platform/ansible/nuc-private-key" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value

Write-Host "Ensuring Ansible is installed on EC2..."
ssh -i $sshKey $ec2Host "command -v ansible-playbook >/dev/null 2>&1 || sudo dnf install -y ansible-core"
Invoke-Checked "Ensuring ansible-core is installed"

Write-Host "Copying ansible/ and compose/nuc/ to EC2..."
ssh -i $sshKey $ec2Host "mkdir -p $remoteDir/ansible $remoteDir/compose/nuc"
Invoke-Checked "Creating remote directories"
scp -i $sshKey -r "$repoRoot\ansible\*" "${ec2Host}:${remoteDir}/ansible/"
Invoke-Checked "Copying ansible/ to EC2 -- check file ownership on the hub if this is a permission error"
scp -i $sshKey -r "$repoRoot\compose\nuc\*" "${ec2Host}:${remoteDir}/compose/nuc/"
Invoke-Checked "Copying compose/nuc/ to EC2 -- check file ownership on the hub if this is a permission error"

Write-Host "Installing NUC SSH key on EC2..."
$nucKeyUnix = ($nucKey -replace "`r`n", "`n").TrimEnd("`n") + "`n"
$tmpKeyFile = Join-Path $env:TEMP "ansible-nuc-deploy-key"
[System.IO.File]::WriteAllText($tmpKeyFile, $nucKeyUnix, (New-Object System.Text.UTF8Encoding $false))
ssh -i $sshKey $ec2Host "mkdir -p ~/.ssh"
Invoke-Checked "Creating ~/.ssh on EC2"
scp -i $sshKey $tmpKeyFile "${ec2Host}:~/.ssh/ansible-nuc"
Invoke-Checked "Copying the Ansible NUC key to EC2"
ssh -i $sshKey $ec2Host "chmod 600 ~/.ssh/ansible-nuc"
Invoke-Checked "Setting permissions on the Ansible NUC key"
Remove-Item $tmpKeyFile

Write-Host "Running playbook..."
ssh -i $sshKey $ec2Host "cd $remoteDir/ansible && ansible-playbook site.yml"
Invoke-Checked "ansible-playbook site.yml"

Write-Host "Done."
