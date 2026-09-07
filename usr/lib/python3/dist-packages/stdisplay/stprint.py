#!/usr/bin/python3 -Bsu

## Copyright (C) 2025 - 2025 Benjamin Grande M. S. <ben.grande.b@gmail.com>
## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

"""Safely print argument to stdout."""

from sys import argv, stdout
from stdisplay.stdisplay import stdisplay


def main() -> None:
    """Safely print argument to stdout."""
    stdout.reconfigure(  # type: ignore
        encoding="ascii", errors="replace", newline="\n"
    )
    ## End-of-options. The script doesn't support any options but this is good
    ## for consistency. "printf" supports end-of-options, so this is sensible.
    if len(argv) >= 2 and argv[1] == "--":
        argv.pop(1)
    if len(argv) > 1:
        untrusted_text = "".join(argv[1:])
        stdout.write(stdisplay(untrusted_text))
        stdout.flush()
