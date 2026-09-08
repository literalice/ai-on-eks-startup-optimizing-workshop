#!/usr/bin/env python3
"""Fail if the Bottlerocket AMI is older than the minimum SOCI version.

Arm C's whole configuration is a no-op on Bottlerocket < 1.44.0: the snapshotter
setting is ignored and the arm quietly measures the same thing as arm A. That
failure mode reads as "SOCI does not help", which is the wrong conclusion to take
out of a workshop, so assert it up front.

AMI names look like: bottlerocket-aws-k8s-1.34-nvidia-x86_64-v1.64.0-7f9a1b2c
"""

import re
import sys


def parse(name: str):
    match = re.search(r"-v(\d+)\.(\d+)\.(\d+)", name)
    if not match:
        return None
    return tuple(int(g) for g in match.groups())


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: assert_br_version.py <ami-name> <minimum-version>", file=sys.stderr)
        return 2

    ami_name, minimum = sys.argv[1], sys.argv[2]
    want = tuple(int(p) for p in minimum.split("."))
    got = parse(ami_name)

    if got is None:
        print(
            f"    WARNING: could not read a version out of {ami_name!r}. "
            f"Confirm it is >= {minimum} before trusting arm C.",
            file=sys.stderr,
        )
        return 0

    if got < want:
        print(
            f"    ERROR: Bottlerocket {'.'.join(map(str, got))} is older than {minimum}. "
            "SOCI parallel pull/unpack is unavailable, so arm C would silently "
            "measure the same thing as arm A.",
            file=sys.stderr,
        )
        return 1

    print(f"    bottlerocket {'.'.join(map(str, got))} >= {minimum}, SOCI available")
    return 0


if __name__ == "__main__":
    sys.exit(main())
