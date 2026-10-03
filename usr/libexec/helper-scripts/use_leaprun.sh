#!/bin/bash

## Copyright (C) 2025 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## style-ok: no-strict -- sourced library.

leaprun_useable_output() {
   printf "%s\n" "${*}" >&2
}

leaprun_useable_test() {
   ## use_leaprun is used by sourcing scripts.
   # shellcheck disable=SC2034
   use_leaprun='no'

   ## privleap / leaprun is supposed to work fine even if called as root.
   ## Not giving special treatment for account 'root'.

   if ! [ -x '/usr/bin/leaprun' ]; then
      leaprun_useable_result="${0}: WARNING: leaprun executable cannot be found. Cannot use privleap."
      leaprun_useable_output "${leaprun_useable_result}"
      return 0
   fi

   local my_user_id
   if ! my_user_id="$(id --user)"; then
      leaprun_useable_result="${0}: WARNING: Failed to execute 'id --user'. Cannot use privleap."
      leaprun_useable_output "${leaprun_useable_result}"
      return 0
   fi

   local comm_socket="/run/privleapd/comm/${my_user_id}"

   if ! [ -S "${comm_socket}" ]; then
      leaprun_useable_result="${0}: WARNING: Cannot communicate with privleapd. Socket '${comm_socket}' does not exist. Cannot use privleap.

You might be able to create a privleap socket by executing: sudo leapctl --create '${USER:-${my_user_id}}'"
      leaprun_useable_output "${leaprun_useable_result}"
      return 0
   fi

   if ! socat UNIX-CONNECT:"${comm_socket}",connect-timeout=2 STDIO <<< '' >/dev/null 2>&1 ; then
      leaprun_useable_result="${0}: WARNING: privleapd is not reachable on socket '${comm_socket}'. Cannot use privleap."
      leaprun_useable_output "${leaprun_useable_result}"
      return 0
   fi

   # shellcheck disable=SC2034
   use_leaprun='yes'
}

leaprun_useable_test
