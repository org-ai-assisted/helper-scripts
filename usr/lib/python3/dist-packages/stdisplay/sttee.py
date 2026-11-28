#!/usr/bin/python3 -Bsu

## Copyright (C) 2025 - 2025 Benjamin Grande M. S. <ben.grande.b@gmail.com>
## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

"""Safely print stdin to stdout and file."""

import sys
from contextlib import ExitStack
from typing import TextIO
from stdisplay.stdisplay import stdisplay


def main() -> None:
    """Safely print stdin to stdout and file."""
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
    with ExitStack() as stack:
        output_files: list[TextIO] = []
        if len(sys.argv) > 1:
            for file_arg in sys.argv[1:]:
                output_files.append(
                    stack.enter_context(
                        open(
                            file_arg,
                            "w",
                            encoding="ascii",
                            errors="replace",
                            newline="\n",
                        )
                    )
                )
        if sys.stdin is not None:
            for untrusted_text in sys.stdin:
                rendered_text: str = stdisplay(untrusted_text)
                sys.stdout.write(rendered_text)
                for output_file in output_files:
                    output_file.write(rendered_text)
        sys.stdout.flush()
