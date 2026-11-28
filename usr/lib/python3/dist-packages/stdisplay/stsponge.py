#!/usr/bin/python3 -Bsu

## Copyright (C) 2025 - 2025 Benjamin Grande M. S. <ben.grande.b@gmail.com>
## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

"""Safely print stdin to stdout or file."""

import sys
from stdisplay.stdisplay import stdisplay


def main() -> None:
    """Safely print stdin to stdout or file."""
    sys.stdout.reconfigure(  # type: ignore
        encoding="ascii", errors="replace", newline="\n"
    )
    if sys.stdin is not None:
        sys.stdin.reconfigure(  # type: ignore
            encoding="utf-8", errors="replace", newline="\n"
        )
    untrusted_text_list = []
    if sys.stdin is not None:
        for untrusted_text in sys.stdin:
            untrusted_text_list.append(untrusted_text)
    ## End-of-options. The script doesn't support any options but this is good
    ## for consistency.
    if len(sys.argv) >= 2 and sys.argv[1] == "--":
        sys.argv.pop(1)
    if len(sys.argv) == 1:
        sys.stdout.write(stdisplay("".join(untrusted_text_list)))
        sys.stdout.flush()
    else:
        for file in sys.argv[1:]:
            with open(
                file, "w", encoding="ascii", errors="replace", newline="\n"
            ) as out_file:
                out_file.write(stdisplay("".join(untrusted_text_list)))
