# Runs the Ansible NUC-provisioning playbook from the EC2 hub.
# Ansible's control node doesn't support Windows, so this pushes ansible/ and
# compose/nuc/ to EC2 (which already has WireGuard routes to both site LANs)
# and triggers the run there via SSH.
# Requires: WireGuard tunnel active, AWS credentials configured, EC2 SSH key
# at ~/.ssh/home-platform.pem.

$ErrorActionPreference = "Stop"

$aws       = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$sshKey    = "$HOME\.ssh\home-platform.pem"
$ec2Host   = "ec2-user@10.0.3.1"
$remoteDir = "/home/ec2-user/home-platform"
$repoRoot  = Join-Path $PSScriptRoot ".."

Write-Host "Fetching Ansible NUC private key from SSM..."
$nucKey = (& $aws ssm get-parameter --name "/home-platform/ansible/nuc-private-key" --with-decryption --region us-east-1 --output json | ConvertFrom-Json).Parameter.Value

Write-Host "Ensuring Ansible is installed on EC2..."
ssh -i $sshKey $ec2Host "command -v ansible-playbook >/dev/null 2>&1 || sudo dnf install -y ansible-core"

Write-Host "Copying ansible/ and compose/nuc/ to EC2..."
ssh -i $sshKey $ec2Host "mkdir -p $remoteDir/ansible $remoteDir/compose/nuc"
scp -i $sshKey -r "$repoRoot\ansible\*" "${ec2Host}:${remoteDir}/ansible/"
scp -i $sshKey -r "$repoRoot\compose\nuc\*" "${ec2Host}:${remoteDir}/compose/nuc/"

Write-Host "Installing NUC SSH key on EC2..."
$nucKeyUnix = ($nucKey -replace "`r`n", "`n").TrimEnd("`n") + "`n"
$tmpKeyFile = Join-Path $env:TEMP "ansible-nuc-deploy-key"
[System.IO.File]::WriteAllText($tmpKeyFile, $nucKeyUnix, (New-Object System.Text.UTF8Encoding $false))
ssh -i $sshKey $ec2Host "mkdir -p ~/.ssh"
scp -i $sshKey $tmpKeyFile "${ec2Host}:~/.ssh/ansible-nuc"
ssh -i $sshKey $ec2Host "chmod 600 ~/.ssh/ansible-nuc"
Remove-Item $tmpKeyFile

Write-Host "Running playbook..."
ssh -i $sshKey $ec2Host "cd $remoteDir/ansible && ansible-playbook site.yml"

Write-Host "Done."
