#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: verify-release-artifacts.sh VERSION [DIST_DIR]}"
dist="${2:-dist}"

python3 - "$version" "$dist" <<'PY'
import hashlib
import plistlib
import sys
import zipfile
from pathlib import Path

version, dist_arg = sys.argv[1:]
dist = Path(dist_arg)
expected = {
    f"NOOP-v{version}-macos.zip",
    f"NOOP-v{version}-ios.ipa",
    f"NOOP-v{version}.apk",
}

missing = sorted(name for name in expected if not (dist / name).is_file())
if missing:
    raise SystemExit(f"missing release artifacts: {', '.join(missing)}")

for name in sorted(expected):
    path = dist / name
    if path.stat().st_size == 0:
        raise SystemExit(f"empty release artifact: {name}")
    with zipfile.ZipFile(path) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise SystemExit(f"{name} has a corrupt member: {corrupt}")
        members = set(archive.namelist())
        if name.endswith("-macos.zip"):
            info_name = "NOOP.app/Contents/Info.plist"
            binary_name = "NOOP.app/Contents/MacOS/NOOP"
            if not {info_name, binary_name}.issubset(members):
                raise SystemExit(f"{name} is missing the app metadata or executable")
            info = plistlib.loads(archive.read(info_name))
            if info.get("CFBundleShortVersionString") != version:
                raise SystemExit(f"{name} embeds version {info.get('CFBundleShortVersionString')!r}")
        elif name.endswith("-ios.ipa"):
            info_name = "Payload/NOOP.app/Info.plist"
            if info_name not in members:
                raise SystemExit(f"{name} is missing {info_name}")
            if any(member.startswith("Payload/NOOP.app/Watch/") for member in members):
                raise SystemExit(f"{name} unexpectedly embeds a Watch app")
            info = plistlib.loads(archive.read(info_name))
            if info.get("CFBundleShortVersionString") != version:
                raise SystemExit(f"{name} embeds version {info.get('CFBundleShortVersionString')!r}")
        elif "AndroidManifest.xml" not in members:
            raise SystemExit(f"{name} is missing AndroidManifest.xml")

checksum_path = dist / "SHA256SUMS.txt"
if checksum_path.is_file():
    seen = set()
    for line in checksum_path.read_text().splitlines():
        digest, filename = line.split(maxsplit=1)
        filename = filename.lstrip("*")
        if filename not in expected:
            raise SystemExit(f"unexpected checksum entry: {filename}")
        actual = hashlib.sha256((dist / filename).read_bytes()).hexdigest()
        if digest.lower() != actual:
            raise SystemExit(f"checksum mismatch: {filename}")
        seen.add(filename)
    if seen != expected:
        raise SystemExit("checksum file does not cover every release artifact")

print(f"verified {len(expected)} release artifacts for v{version}")
PY
