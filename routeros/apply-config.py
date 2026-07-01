"""
Apply a RouterOS .rsc config to an RB5009 via SSH/SFTP.

Usage:
    python apply-config.py <host> <config.rsc> [password]

    host        Router IP (factory default: 192.168.88.1)
    config.rsc  Path to the .rsc file to upload and import
    password    Admin password (prompted if omitted)

The script uploads the file via SFTP then runs /import on the router.
If the config changes the LAN IP (section 6), SSH will drop mid-import —
that is expected. RouterOS continues running /import server-side.

Requirements:
    pip install paramiko
"""

import sys
import getpass
import paramiko

def main():
    if len(sys.argv) < 3:
        print("Usage: python apply-config.py <host> <config.rsc> [password]")
        sys.exit(1)

    host = sys.argv[1]
    config_path = sys.argv[2]
    password = sys.argv[3] if len(sys.argv) > 3 else getpass.getpass(f"Password for admin@{host}: ")

    print(f"Connecting to {host}...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(host, username="admin", password=password,
                       look_for_keys=False, allow_agent=False, timeout=10)
        print("Connected.")
    except Exception as e:
        print(f"SSH failed: {e}")
        sys.exit(1)

    print(f"Uploading {config_path} via SFTP...")
    with open(config_path, "r") as f:
        content = f.read()
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
