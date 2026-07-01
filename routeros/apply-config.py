"""
Apply a RouterOS .rsc config to an RB5009 via SSH/SFTP.

Usage:
    python apply-config.py <host> <config.rsc> [options]

Options:
    --ssm <param>          Fetch the router admin password from AWS SSM.
                           Used for both SSH auth and substituted into the
                           .rsc in place of PLACEHOLDER.
    --ssh-password <pass>  SSH auth password when it differs from the new
                           password (factory reset scenario: SSH with the
                           factory password while SSM holds the desired new
                           password). Requires --ssm.

If neither --ssm nor a positional password is given, you are prompted.
The prompted/positional value is used for both SSH auth and substitution.

Examples:
    # Re-apply to already-configured router (password already matches SSM):
    python apply-config.py 10.0.1.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password

    # Initial setup from factory reset (SSH with factory password, set new from SSM):
    python apply-config.py 192.168.88.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password --ssh-password <factory-password>

    # Rambles:
    python apply-config.py 192.168.88.1 routeros/rambles/initial-config.rsc --ssm /home-platform/router/rambles-admin-password

Requirements:
    pip install paramiko
    AWS CLI configured with access to SSM (only needed for --ssm)
"""

import sys
import argparse
import getpass
import json
import subprocess
import paramiko


def get_ssm_password(param_name):
    result = subprocess.run(
        ["aws", "ssm", "get-parameter", "--name", param_name,
         "--with-decryption", "--output", "json"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"SSM fetch failed: {result.stderr.strip()}")
        sys.exit(1)
    return json.loads(result.stdout)["Parameter"]["Value"]


def main():
    parser = argparse.ArgumentParser(description="Apply RouterOS config to RB5009")
    parser.add_argument("host", help="Router IP (e.g. 192.168.88.1 or 10.0.1.1)")
    parser.add_argument("config", help="Path to .rsc file")
    parser.add_argument("--ssm", metavar="PARAM", help="SSM parameter name for the admin password")
    parser.add_argument("--ssh-password", metavar="PASS", help="SSH auth password (factory reset only; requires --ssm)")
    args = parser.parse_args()

    if args.ssh_password and not args.ssm:
        parser.error("--ssh-password requires --ssm")

    if args.ssm:
        print(f"Fetching password from SSM: {args.ssm}")
        new_password = get_ssm_password(args.ssm)
        ssh_password = args.ssh_password if args.ssh_password else new_password
    else:
        new_password = getpass.getpass(f"Admin password for {args.host}: ")
        ssh_password = new_password

    with open(args.config, "r") as f:
        content = f.read()

    if "PLACEHOLDER" in content:
        content = content.replace("PLACEHOLDER", new_password)
        print("Substituted PLACEHOLDER with password from SSM.")

    print(f"Connecting to {args.host}...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(args.host, username="admin", password=ssh_password,
                       look_for_keys=False, allow_agent=False, timeout=10)
        print("Connected.")
    except Exception as e:
        print(f"SSH failed: {e}")
        sys.exit(1)

    print(f"Uploading {args.config} via SFTP...")
    sftp = client.open_sftp()
    with sftp.open("initial-config.rsc", "w") as f:
        f.write(content)
    sftp.close()
    print("Upload complete.")

    print("Running /import initial-config.rsc ...")
    print("(SSH will drop when the LAN IP changes — that is expected)")
    try:
        _, stdout, stderr = client.exec_command("/import initial-config.rsc", timeout=60)
        out = stdout.read(8192).decode(errors="replace")
        err = stderr.read(8192).decode(errors="replace")
        if out:
            print("Output:", out[:2000])
        if err:
            print("Stderr:", err[:500])
        print("Import completed without connection drop.")
    except Exception as e:
        print(f"Connection dropped during import (expected if LAN IP changed): {e}")

    try:
        client.close()
    except Exception:
        pass

    print("\nDone.")


if __name__ == "__main__":
    main()
