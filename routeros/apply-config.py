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
    --known-hosts <file>   Pinned SSH host keys (default ansible/known_hosts).
                           The router's key must be there or the script
                           refuses to connect; a CHANGED key is always refused.
    --accept-new-host-key  First contact only (factory-reset router at
                           192.168.88.1, or a new router): accept a host with
                           no known_hosts entry for this one session and print
                           the line to add. Never saves anything.

If neither --ssm nor a positional password is given, you are prompted.
The prompted/positional value is used for both SSH auth and substitution.

Two files per site as of 2026-07-17 (see routeros/NOTES.md "initial-config.rsc
vs. managed-config.rsc" for the full incident writeup):
    initial-config.rsc   One-time factory bring-up ONLY. Never reapply this
                          to an already-live router — it removes the router's
                          real LAN IP the same way it removes the factory one.
    managed-config.rsc   The ongoing-managed subset (firewall, DHCP, DNS,
                          WireGuard, NTP, SNMP, syslog). Safe to reapply to a
                          live router. This is the file the new Ansible
                          role/CI pipeline applies (see ansible/routeros.yml).

Safety check:
    managed-config.rsc's WireGuard section is idempotent (skips entirely if
    wg-aws already exists) as of 2026-07-17, but this script's placeholder
    guard stays as defense in depth: if WG_PRIVATE_KEY_PLACEHOLDER is still
    in the file after substitution, this script exits before ever
    connecting, unless --wg-key-ssm was given. Don't work around this by
    hand-editing the placeholder into the .rsc file — that would commit a
    live private key to Git.

Examples:
    # First-time bring-up from factory reset — two calls, in order. A reset
    # router has a NEW host key: the first call accepts it once and prints
    # it; replace the router's line in ansible/known_hosts with it (checked
    # against /ip ssh print on the console) before the second call.
    python apply-config.py 192.168.88.1 routeros/nyc/initial-config.rsc --ssm /home-platform/router/nyc-admin-password --ssh-password <factory-password> --accept-new-host-key
    python apply-config.py 10.0.1.1 routeros/nyc/managed-config.rsc --ssm /home-platform/router/nyc-admin-password --wg-key-ssm /home-platform/wireguard/nyc-private-key

    # Re-apply managed-config.rsc to an already-live router (safe — the
    # WireGuard section is idempotent, everything else is a brief blip
    # at worst, see routeros/NOTES.md for exactly what's still not
    # fully idempotent):
    python apply-config.py 10.0.1.1 routeros/nyc/managed-config.rsc --ssm /home-platform/router/nyc-admin-password --wg-key-ssm /home-platform/wireguard/nyc-private-key

    # Rambles, same pattern:
    python apply-config.py 10.0.2.1 routeros/rambles/managed-config.rsc --ssm /home-platform/router/rambles-admin-password --wg-key-ssm /home-platform/wireguard/rambles-private-key

    # Targeted one-line change (e.g. a single DNS record) instead of a full
    # reapply — still the preferred approach for a one-off change even
    # though managed-config.rsc is now much safer to reapply than the old
    # unified file was. Write a small script that opens an SSH session and
    # runs just that one RouterOS command via exec_command(), the way the
    # recovery from the 2026-07-17 incident (see git log) did it.

Requirements:
    pip install paramiko
    AWS CLI configured with access to SSM (only needed for --ssm/--wg-key-ssm)
"""

import sys
import os
import argparse
import base64
import hashlib
import getpass
import json
import subprocess
import paramiko


DEFAULT_KNOWN_HOSTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ansible", "known_hosts")


def _fingerprint(key):
    return "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")


class _AcceptOnceAndReport(paramiko.MissingHostKeyPolicy):
    """--accept-new-host-key: for a router whose key isn't known yet (a
    factory-reset RB5009 at 192.168.88.1, or a new site). Accepts it for
    this one session only and prints the line to add to ansible/known_hosts;
    nothing is saved. A key that is known but DIFFERENT is still refused
    (paramiko raises BadHostKeyException before any policy is consulted)."""

    def missing_host_key(self, client, hostname, key):
        print(f"WARNING: {hostname} isn't in known_hosts; accepting its {key.get_name()} key "
              f"{_fingerprint(key)} for this session only (--accept-new-host-key).")
        print("Check that fingerprint on the router (/ip ssh print), then add this line to ansible/known_hosts:")
        print(f"  {hostname} {key.get_name()} {key.get_base64()}")


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
    parser.add_argument("--known-hosts", metavar="FILE", default=DEFAULT_KNOWN_HOSTS,
                        help="Pinned host keys (default: ansible/known_hosts in this repo)")
    parser.add_argument("--accept-new-host-key", action="store_true",
                        help="First contact only (factory reset / new router): accept a host that has no "
                             "entry in --known-hosts for this session and print its key to add there. "
                             "A changed key is still refused.")
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
    # Host keys are pinned in ansible/known_hosts (CodeQL
    # py/paramiko-missing-host-key-validation): this session sends the admin
    # password and the WireGuard private key, so it must not trust whatever
    # answers on the router's IP.
    if os.path.exists(args.known_hosts):
        client.load_host_keys(args.known_hosts)
    elif not args.accept_new_host_key:
        print(f"Known-hosts file not found: {args.known_hosts}")
        sys.exit(1)
    client.set_missing_host_key_policy(
        _AcceptOnceAndReport() if args.accept_new_host_key else paramiko.RejectPolicy())
    try:
        client.connect(args.host, username="admin", password=ssh_password,
                       look_for_keys=False, allow_agent=False, timeout=10)
        print("Connected.")
    except paramiko.BadHostKeyException as e:
        print(f"REFUSING: {args.host}'s SSH host key has CHANGED (now {_fingerprint(e.key)}).")
        print("Either the router was reset/replaced, or something else is answering on its IP.")
        print("If it was reset, check the fingerprint on the router (/ip ssh print) and update ansible/known_hosts.")
        sys.exit(1)
    except paramiko.SSHException as e:
        if "not found in known_hosts" in str(e):
            print(f"REFUSING: {args.host} has no entry in {args.known_hosts}.")
            print("Add its key there (ssh-keyscan from a trusted network, checked against /ip ssh print),")
            print("or for a first connection to a factory-reset router use --accept-new-host-key.")
            sys.exit(1)
        print(f"SSH failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"SSH failed: {e}")
        sys.exit(1)

    remote_name = os.path.basename(args.config)
    print(f"Uploading {args.config} via SFTP as {remote_name}...")
    sftp = client.open_sftp()
    with sftp.open(remote_name, "w") as f:
        f.write(content)
    sftp.close()
    print("Upload complete.")

    print(f"Running /import {remote_name} ...")
    print("(SSH will drop here if this file changes the LAN IP — expected for initial-config.rsc, not for managed-config.rsc)")
    import_failed = False
    try:
        _, stdout, stderr = client.exec_command(f"/import {remote_name}", timeout=60)
        out = stdout.read(8192).decode(errors="replace")
        err = stderr.read(8192).decode(errors="replace")
        if out:
            print("Output:", out[:2000])
        if err:
            print("Stderr:", err[:500])
        # RouterOS reports per-line script errors in stdout (exit status from
        # exec_command is unreliable for this -- /import itself "succeeds" as
        # a session even when individual lines inside it fail), so this has
        # to be a text scan. Found 2026-07-17: a non-idempotent NTP line
        # failed with "Script Error: failure: duplicate address" and this
        # script printed it but still exited 0 -- meaning the Ansible role's
        # failed_when: rc != 0 (see ansible/roles/routeros) would have
        # silently treated a real failure as success. Fixed alongside making
        # managed-config.rsc's own sections properly idempotent.
        if "Script Error" in out or "failure:" in out:
            print("\nRouterOS reported a script error above -- treating this as a failed apply.")
            import_failed = True
        else:
            print("Import completed without connection drop.")
    except Exception as e:
        print(f"Connection dropped during import (expected if LAN IP changed): {e}")

    try:
        client.close()
    except Exception:
        pass

    if import_failed:
        print("\nFailed.")
        sys.exit(1)

    print("\nDone.")


if __name__ == "__main__":
    main()
