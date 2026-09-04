#!/usr/bin/python3 -Bsu

## Copyright (C) 2014 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

"""
Shared display-availability guard for PyQt GUI helpers.

A Qt platform (QPA) plugin is resolved inside the QApplication constructor,
before Python regains control. With no reachable display the xcb plugin fails
to initialize and Qt calls abort() -- SIGABRT, exit 134 -- which no Python
try/except can catch (the abort is torn down before Python's exception
machinery runs). A GUI helper invoked from shell is frequently headless (a
systemd service, cron, an ssh session, an AppArmor-confined caller), so it must
detect that up front, before constructing a QApplication, rather than crash and
let the SIGABRT propagate to its caller as a spurious bug.

Usage in a GUI entry point, after argument parsing and before QApplication:

    from guimessages.display import exit_if_no_gui
    ...
    args = parser.parse_args()
    exit_if_no_gui()
    app = QtWidgets.QApplication(sys.argv)
"""

import os
import sys


def gui_available():
    """
    True when a Qt GUI can initialize.

    Mirrors msgcollector's msgfallbacks: a GUI is possible when DISPLAY or
    WAYLAND_DISPLAY is set. An explicit QT_QPA_PLATFORM (e.g. 'offscreen',
    'minimal') lets Qt initialize without a display too, so honour it -- a
    deliberate headless render (CI, tests) must not be suppressed.
    """
    return bool(
        os.environ.get("DISPLAY")
        or os.environ.get("WAYLAND_DISPLAY")
        or os.environ.get("QT_QPA_PLATFORM")
    )


def exit_if_no_gui(exit_code=0):
    """
    Exit cleanly before constructing a QApplication when no GUI is available.

    Call after argument parsing, before QtWidgets.QApplication(...). Prints a
    concise diagnostic to stderr and exits with exit_code (default 0: a 'yesno'
    dialog caller then reads no affirmative answer on stdout and safely
    declines, and a caller under 'set -e' is not tripped as if the script had a
    bug). Returns normally when a GUI is available, so the caller proceeds to
    build its dialog.
    """
    if gui_available():
        return
    program = os.path.basename(sys.argv[0]) or "gui"
    print(
        f"{program}: no GUI available (neither DISPLAY nor WAYLAND_DISPLAY "
        "set); cannot show dialog.",
        file=sys.stderr,
    )
    sys.exit(exit_code)
