#!/usr/bin/env python3
"""Check and unpack an app's staged Airflow DAGs (ADR-0031).

Run by app-deploy.sh as root on the hub. The archive comes from the app's
CI (s3://<bucket>/apps/<app>/dags.tar.gz), so it's checked here before any
of it lands in Airflow's DAG folder: regular files and directories only (no
links, devices or absolute/.. paths), .py files with plain names, and size
limits. Only the checked files are written, by this script, into an empty
staging directory; tarfile's own extraction is never used.

Usage: app-dags.py <archive> <empty staging dir>
Prints the number of DAG files written. Exits 1 with a reason on stdout if
the archive breaks a rule (nothing is written in that case).
"""

import os
import re
import sys
import tarfile

MAX_FILES = 200
MAX_FILE_BYTES = 1024 * 1024
NAME = re.compile(r"(?:[A-Za-z0-9_][A-Za-z0-9_-]*/)*[A-Za-z0-9_][A-Za-z0-9_-]*\.py")


def main(archive: str, dest: str) -> int:
    files = []
    with tarfile.open(archive, "r:gz") as tar:
        for m in tar.getmembers():
            name = m.name[2:] if m.name.startswith("./") else m.name
            if name in ("", "."):
                continue
            if m.isdir():
                continue
            if not m.isreg():
                print(f"not a regular file: {m.name}")
                return 1
            if not NAME.fullmatch(name):
                print(f"not an allowed DAG file name: {m.name}")
                return 1
            if m.size > MAX_FILE_BYTES:
                print(f"too large ({m.size} bytes): {m.name}")
                return 1
            files.append((name, m))
        if len(files) > MAX_FILES:
            print(f"too many files ({len(files)} > {MAX_FILES})")
            return 1
        for name, m in files:
            path = os.path.join(dest, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with tar.extractfile(m) as src, open(path, "wb") as out:
                out.write(src.read())
    print(len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
