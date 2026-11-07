#!/usr/bin/env python3
"""Content identity for the sources and resources actually shipped in a release."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
files = []
for directory in ("Sources", "examples", "packaging"):
    files.extend(p for p in (root / directory).rglob("*") if p.is_file() and "vendor" not in p.parts and p.name != ".DS_Store")
files.extend((root / "release").glob("*.sh"))
files.append(root / "release/source-digest.py")
digest = hashlib.sha256()
for path in sorted(files):
    digest.update(path.relative_to(root).as_posix().encode() + b"\0")
    digest.update(path.read_bytes() + b"\0")
print(digest.hexdigest())
