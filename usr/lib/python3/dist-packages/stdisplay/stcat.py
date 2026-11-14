#!/usr/bin/python3 -Bsu

## Copyright (C) 2025 - 2025 Benjamin Grande M. S. <ben.grande.b@gmail.com>
## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

"""Safely print stdin or file to stdout."""

import sys
from pathlib import Path
from stdisplay.stdisplay import stdisplay


def main() -> None:
    """Safely print stdin or file to stdout."""
    sys.stdout.reconfigure(  # type: ignore
        encoding="ascii", errors="replace", newline="\n"
    )
    if sys.stdin is not None:
        sys.stdin.reconfigure(  # type: ignore
            encoding="utf-8", errors="replace", newline="\n"
        )
    ## End-of-options. The script doesn't support any options but this is good
    ## for consistency.
    if len(sys.argv) >= 2 and sys.argv[1] == "--":
        sys.argv.pop(1)
    if len(sys.argv) == 1:
        if sys.stdin is not None:
            for untrusted_line in sys.stdin:
                sys.stdout.write(stdisplay(untrusted_line))
            sys.stdout.flush()
        return
    for untrusted_arg in sys.argv[1:]:
        if untrusted_arg == "-":
            if sys.stdin is not None:
                for untrusted_line in sys.stdin:
                    sys.stdout.write(stdisplay(untrusted_line))
        else:
            path = Path(untrusted_arg)
            untrusted_text = path.read_text(
                encoding="utf-8", errors="replace", newline="\n"
            )
            sys.stdout.write(stdisplay(untrusted_text))
    sys.stdout.flush()
