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
    --wg-key-ssm <param>   Fetch the WireGuard private key from AWS SSM and
                           substitute it for WG_PRIVATE_KEY_PLACEHOLDER.
                           REQUIRED if the .rsc still contains that token —
                           the script refuses to run otherwise (see Safety
                           check below).

If neither --ssm nor a positional password is given, you are prompted.
The prompted/positional value is used for both SSH auth and substitution.

Safety check:
    The NYC/Rambles WireGuard section unconditionally removes the live
    wg-aws interface/peer/address before recreating it — safe on a factory
    router with no tunnel yet, but it WILL DROP A LIVE TUNNEL if reapplied
    without a real key. So if WG_PRIVATE_KEY_PLACEHOLDER is still in the
    file after substitution, this script exits before ever connecting,
    unless --wg-key-ssm was given. Don't work around this by hand-editing
    the placeholder into the .rsc file — that would commit a live private
    key to Git.

Examples:
    # Re-apply to already-configured router, e.g. for a DNS-only change
    # (also substitutes the real WireGuard key so the reapply is safe):
    python apply-config.py 10.0.1.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password --wg-key-ssm /home-platform/wireguard/nyc-private-key

    # Initial setup from factory reset (SSH with factory password, set new from SSM):
    python apply-config.py 192.168.88.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password --ssh-password <factory-password> --wg-key-ssm /home-platform/wireguard/nyc-private-key

    # Rambles:
    python apply-config.py 192.168.88.1 routeros/rambles/initial-config.rsc --ssm /home-platform/router/rambles-admin-password --wg-key-ssm /home-platform/wireguard/rambles-private-key

    # Targeted one-line change (e.g. a single DNS record) instead of a full
    # reapply — safer, and doesn't need --wg-key-ssm at all. Write a small
    # script that opens an SSH session and runs just that one RouterOS
    # command via exec_command(), the way the recovery from the 2026-07-17
    # incident (see git log) did it.

Requirements:
    pip install paramiko
    AWS CLI configured with access to SSM (only needed for --ssm/--wg-key-ssm)
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
    parser.add_argument("--wg-key-ssm", metavar="PARAM", help="SSM parameter name for the WireGuard private key (substituted for WG_PRIVATE_KEY_PLACEHOLDER)")
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

    # WG_PRIVATE_KEY_PLACEHOLDER must be substituted (or checked for) BEFORE
    # the generic PLACEHOLDER substitution below — "PLACEHOLDER" is a
    # substring of "WG_PRIVATE_KEY_PLACEHOLDER", so doing it in the other
    # order corrupts the token into "WG_PRIVATE_KEY_<admin password>"
    # instead of leaving it recognizable. That exact substring collision is
    # what caused the 2026-07-17 incident (see Gotchas in CLAUDE.md).
    had_wg_placeholder = "WG_PRIVATE_KEY_PLACEHOLDER" in content

    if args.wg_key_ssm:
        print(f"Fetching WireGuard private key from SSM: {args.wg_key_ssm}")
        wg_key = get_ssm_password(args.wg_key_ssm)
        content = content.replace("WG_PRIVATE_KEY_PLACEHOLDER", wg_key)
        print("Substituted WG_PRIVATE_KEY_PLACEHOLDER with key from SSM.")
    elif had_wg_placeholder:
        print(
            "\nRefusing to apply: this config contains WG_PRIVATE_KEY_PLACEHOLDER.\n"
            "The WireGuard section unconditionally removes the live wg-aws interface\n"
            "before recreating it — uploading this as-is would DELETE THE LIVE TUNNEL\n"
            "and fail to bring it back up (invalid key), causing an outage.\n\n"
            "Re-run with --wg-key-ssm <param> to substitute the real key, e.g.:\n"
            "  --wg-key-ssm /home-platform/wireguard/nyc-private-key\n"
            "  --wg-key-ssm /home-platform/wireguard/rambles-private-key\n\n"
            "For a small targeted change (e.g. one DNS record) on an already-live\n"
            "router, don't reapply the whole file at all — SSH in and run just that\n"
            "one command instead."
        )
        sys.exit(1)

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
