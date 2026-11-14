#!/usr/bin/python3 -Bsu

## Copyright (C) 2025 - 2025 Benjamin Grande M. S. <ben.grande.b@gmail.com>
## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

"""Safely print argument to stdout with echo's formatting."""

import sys
from stdisplay.stdisplay import stdisplay


def main() -> None:
    """Safely print argument to stdout with echo's formatting."""
    sys.stdout.reconfigure(  # type: ignore
        encoding="ascii", errors="replace", newline="\n"
    )
    ## End-of-options intentionally omitted, since "echo" doesn't support it.
    if len(sys.argv) > 1:
        untrusted_text = " ".join(sys.argv[1:])
        sys.stdout.write(stdisplay(untrusted_text))
    sys.stdout.write("\n")
    sys.stdout.flush()
