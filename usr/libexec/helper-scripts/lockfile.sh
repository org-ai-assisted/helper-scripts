#!/bin/bash

## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## Lock file mechanism to prevent duplicate script instances per user
##
## Two ways to use it:
##   * Source it to self-lock the sourcing script. Only one instance of the
##     script will be able to run at a time.
##   * Execute it as  'lockfile.sh <lock-key> -- <command> [args...]'  to run the
##     command under a per-key lock (skipping, non-zero, if the key is already
##     held).

## Based on flock man page.
## > [ "${FLOCKER}" != "${0}" ] && exec env FLOCKER="${0}" flock -en "${0}" "${0}" "$@" || :

## style-ok: no-strict -- sourced helper.

## style-ok: allow-exec -- process handoff is used here intentionally.

true "${BASH_SOURCE[0]}: START"

true "${BASH_SOURCE[0]}: INFO: FLOCKER: ${FLOCKER-}"

## No fallback outside of /run/user/$EUID by design. A fallback such as /tmp or
## a 1777 root:root dir under /run would introduce TOCTOU issues. A fallback to
## ${HOME}/.cache would allow multiple instances of the script to run at once
## if one instance is launched before login and another one after. Callers who
## launch locking scripts before user login must create a /run/user/$EUID
## directory with the proper ownership themselves.
flocker_runtime_dir="${XDG_RUNTIME_DIR:-/run/user/${EUID}}"
if [ -d "${flocker_runtime_dir}" ] && [ ! -L "${flocker_runtime_dir}" ] && [ -O "${flocker_runtime_dir}" ]; then
  flocker_temp_folder="${flocker_runtime_dir}/flocker-temp-folder"
else
  printf '%s\n' "$0: ERROR: no per-user runtime dir with proper ownership, cannot create a lock directory!" 1>&2
  exit 1
fi
mkdir --parents -- "${flocker_temp_folder}"
if [ -L "${flocker_temp_folder}" ] || [ ! -O "${flocker_temp_folder}" ]; then
  printf '%s\n' "$0: ERROR: refusing unexpected symlink or non-owned directory at lock directory location '${flocker_temp_folder}'!" 1>&2
  exit 1
fi

## If lockfile.sh is called with arguments, and LOCK_NAME is not set, $1 is
## used as the name of the lock file, and remaining arguments are the command
## to run. LOCK_NAME exists so that lockfile.sh can be inlined into
## dist-installer-cli without causing $1 to be interpreted as a lockfile.
lockfile_wrap="no"
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ -z "${LOCK_NAME-}" ] && [ "${#}" -ge 1 ]; then
  lockfile_wrap="yes"
  LOCK_NAME="${1}"
fi

## The lock key defaults to this script's own path. A caller that runs the same
## script concurrently for different keys can set LOCK_NAME to lock per key
## instead.
if [ -n "${LOCK_NAME-}" ]; then
  flocker_key="${LOCK_NAME}"
else
  flocker_key="$(realpath -- "${0}")"
fi

flocker_path_substituted="${flocker_key//_/_underscore_}"
flocker_path_substituted="${flocker_path_substituted//\//_slash_}"
flocker_path_substituted="${flocker_path_substituted//./_dot_}"
flocker_lockfile="${flocker_temp_folder}/${flocker_path_substituted}"

if ! test -f "${flocker_lockfile}"; then
  touch -- "${flocker_lockfile}"
fi

if [ "${FLOCKER-}" != "${0}" ]; then
  true "${BASH_SOURCE[0]}: INFO: FLOCKER set to self: no"

  if ! flock --exclusive --nonblock "${flocker_lockfile}" /usr/bin/true 2>/dev/null; then
    printf '%s\n' "${0}: another instance is already running; exiting." 1>&2
    exit 75
  fi

  if test -o xtrace; then
    ## Code duplication. Also in xtrace.bsh function shellopts_with_xtrace.
    ## This helper intentionally avoids sourcing dependencies.
    ## TODO: Do we need to avoid sourcing dependencies?
    case ":${SHELLOPTS-}:" in
      *:xtrace:*)
        flocker_shellopts="${SHELLOPTS-}"
        ;;
      *)
        flocker_shellopts="${SHELLOPTS-}:xtrace"
        ;;
    esac
    exec env SHELLOPTS="${flocker_shellopts}" FLOCKER="${0}" flock --conflict-exit-code 75 --close --exclusive --nonblock "${flocker_lockfile}" "${0}" "${@}"
  else
    exec env FLOCKER="${0}" flock --conflict-exit-code 75 --close --exclusive --nonblock "${flocker_lockfile}" "${0}" "${@}"
  fi
  ## Never reached due to 'exec' above.
fi

## If we get this far and lockfile_wrap is set to 'yes', we're in wrap mode.
## The above code will have re-executed this script with the lock held, so now
## we just need to hand off to the target command.
if [ "${lockfile_wrap}" = "yes" ]; then
  shift # Get rid of the lock key name
  if [ "${#}" -ge 1 ] && [ "${1}" = "--" ]; then
    shift # We support end-of-options even though we don't have any options
  fi
  if [ "${#}" -lt 1 ]; then
    printf '%s\n' "${0}: ERROR: usage: ${0} <lock-key> -- <command> [args...]" 1>&2
    exit 2
  fi
  unset LOCK_NAME FLOCKER
  exec -- "${@}"
fi

## FLOCKER is set and lockfile_wrap is not set to 'yes', therefore we've
## successfully locked already and can allow the sourcing script to run.

true "${BASH_SOURCE[0]}: INFO: FLOCKER set to self: yes"

true "${BASH_SOURCE[0]}: END"
