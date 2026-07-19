#!/bin/bash

## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## style-ok: no-strict
## Sourced-only function library: top-level strict-mode would leak into the
## sourcing shell (see R-010 waiver rationale).

## style-ok: no-has
## 'command -v sudo' below deliberately captures the resolved path into
## 'sudo_exe' for the subsequent 'test -x'; 'has' only reports presence, not the
## path, so it cannot replace this use.

sudo_useable_test() {
   use_sudo='no'

#    local id_user
#    if ! id_user="$(id --user)" ; then
#       echo "$0: WARNING: Cannot run 'id --user'. Cannot use sudo." >&2
#       return 0
#    fi
#
#    if [ "$id_user" = "0" ] ; then
#       true "$0: INFO: Already using account root / id 0. No need to use sudo."
#       return 0
#    fi

   if ! sudo_exe="$(command -v sudo)"; then
      true "$0: INFO: sudo executable cannot be found. Cannot use sudo."
      return 0
   fi

   ## Debugging.
   ## sets: boot_session
   source "${HELPER_SCRIPTS_PATH:-}"/usr/libexec/helper-scripts/boot-session-detection.bsh

   if ! test -x "$sudo_exe"; then
      true "$0: INFO: sudo is not executable. Cannot use sudo."
      return 0
   fi

   use_sudo='yes'
}

sudo_error_exit_if_unavailable() {
   local msg

   if [ "$use_sudo" = "no" ]; then
      msg="ERROR: sudo unavailable. Boot into sysmaint session?"
      ## Launched from a .desktop entry there is no controlling terminal, so
      ## the stderr message is invisible; surface it in a dialog instead. Show
      ## the dialog only when this really looks like a graphical launch: no
      ## stream is a terminal AND a display is reachable. That keeps the plain
      ## stderr path for an interactive CLI caller (even one redirecting only
      ## stderr, e.g. 'tool 2>log') and for an unattended batch job (cron, CI,
      ## systemd, ssh command) that has no display, so neither is blocked by a
      ## modal dialog. Soft dependency: no dialog when msgcollector is absent.
      if [ ! -t 0 ] && [ ! -t 1 ] && [ ! -t 2 ] \
         && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; } \
         && [ -x /usr/libexec/msgcollector/generic_gui_message.py ]; then
         /usr/libexec/msgcollector/generic_gui_message.py \
            error "Superuser rights unavailable" "$msg" "" ok || true
      fi
      printf '%s\n' "$msg" >&2
      exit 1
   fi
}

sudo_useable_test
