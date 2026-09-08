#!/usr/bin/env python3
"""Render the phase-2 pod spec for one loader variant.

Not sed. The init-container block is multi-line, and sed cannot substitute a
newline-bearing replacement portably -- the r/d workaround behaves differently on
BSD and GNU sed, and on BSD it silently duplicated the whole document. It also
matched the placeholder where it appears inside a *comment*, which is not a
substitution site.

So the rule here is explicit: @INIT_CONTAINERS@ is only replaced when it is the
entire content of a line. A mention inside prose is left alone.

  render_weights.py <template> <fragment-or-NONE> <output> KEY=VALUE [KEY=VALUE ...]
"""

from __future__ import annotations

import pathlib
import sys

INIT_TOKEN = "@INIT_CONTAINERS@"


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2

    template = pathlib.Path(sys.argv[1])
    fragment_arg = sys.argv[2]
    output = pathlib.Path(sys.argv[3])

    substitutions = {}
    for pair in sys.argv[4:]:
        if "=" not in pair:
            print(f"not a KEY=VALUE pair: {pair!r}", file=sys.stderr)
            return 2
        key, value = pair.split("=", 1)
        substitutions[f"@{key}@"] = value

    fragment = ""
    if fragment_arg != "NONE":
        fragment_path = pathlib.Path(fragment_arg)
        if not fragment_path.is_file():
            print(f"fragment not found: {fragment_path}", file=sys.stderr)
            return 1
        fragment = fragment_path.read_text().rstrip("\n")
        # The fragment carries its own placeholders (bucket, prefix, region).
        for token, value in substitutions.items():
            fragment = fragment.replace(token, value)

    rendered = []
    for line in template.read_text().splitlines():
        # The placeholder is written as a YAML comment so that the template parses as
        # valid YAML before rendering, which lets editors and linters check it. Both
        # forms are accepted.
        if line.strip() in (INIT_TOKEN, f"# {INIT_TOKEN}"):
            if fragment:
                rendered.extend(fragment.splitlines())
            continue
        for token, value in substitutions.items():
            line = line.replace(token, value)
        rendered.append(line)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(rendered) + "\n")

    leftover = sorted(
        {
            word
            for line in rendered
            if not line.lstrip().startswith("#")
            for word in line.split()
            if word.startswith("@") and word.endswith("@") and len(word) > 2
        }
    )
    if leftover:
        print(f"WARNING unsubstituted placeholders outside comments: {leftover}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
