#!/usr/bin/env python3
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parent.parent
value = hashlib.sha256()
for path in sorted(list((root / 'Sources').rglob('*.swift')) + list((root / 'Tests').glob('*.swift'))):
    value.update(path.relative_to(root).as_posix().encode() + b'\0' + path.read_bytes())
print(value.hexdigest())
