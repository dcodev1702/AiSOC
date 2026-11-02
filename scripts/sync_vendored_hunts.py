#!/usr/bin/env python3
"""Copy the root hunt corpus into the agents image build context and verify parity."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "hunts"
VENDORED = REPO / "services" / "agents" / "app" / "hunt" / "corpus"


def _digests(root: Path) -> dict[str, str]:
    if not root.is_dir():
        return {}
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(root.glob("*.yaml"))}


def check() -> int:
    source = _digests(SOURCE)
    vendored = _digests(VENDORED)
    if not source:
        print("sync_vendored_hunts: source corpus is empty", file=sys.stderr)
        return 1
    if source != vendored:
        print("sync_vendored_hunts: packaged corpus differs; run this script without --check", file=sys.stderr)
        return 1
    print(f"sync_vendored_hunts: OK — {len(source)} hunts, byte-identical")
    return 0


def sync() -> int:
    if VENDORED.exists():
        shutil.rmtree(VENDORED)
    VENDORED.mkdir(parents=True)
    for path in sorted(SOURCE.glob("*.yaml")):
        shutil.copy2(path, VENDORED / path.name)
    print(f"sync_vendored_hunts: copied {len(_digests(VENDORED))} hunts")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    return check() if parser.parse_args().check else sync()


if __name__ == "__main__":
    sys.exit(main())
