#!/usr/bin/python3 -Bsu

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

"""
Shared display-availability guard for PyQt GUI helpers.

Use in a GUI entry point, after argument parsing and before QApplication:

    from guimessages.check_display import exit_if_no_gui
    ...
    args = parser.parse_args()
    exit_if_no_gui()
    app = QtWidgets.QApplication(sys.argv)
"""

import os
import sys


def gui_available() -> bool:
    """
    True when a Qt GUI can initialize.
    """
    return bool(
        os.environ.get("DISPLAY")
        or os.environ.get("WAYLAND_DISPLAY")
        or os.environ.get("QT_QPA_PLATFORM")
    )


def exit_if_no_gui(exit_code: int = 0) -> None:
    """
    Print a message and exit cleanly when no GUI is available.
    """
    if gui_available():
        return
    program: str = os.path.basename(sys.argv[0]) or "gui"
    print(
        f"{program}: no GUI available; cannot show dialog.",
        file=sys.stderr,
    )
    sys.exit(exit_code)
