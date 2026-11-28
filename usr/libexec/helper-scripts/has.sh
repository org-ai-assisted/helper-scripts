#!/bin/bash

## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## style-ok: no-strict - sourced library.
## style-ok: no-has - this script is 'has' itself.

## TODO-HUMAN-DEVELOPER-ONLY: Temporarily kept to avoid breaking things
## mid-migration, delete this once everything uses has.bsh.

## This is just a simple wrapper around 'command -v' to avoid
## spamming '>/dev/null' throughout this function. This also guards
## against aliases and functions.
## https://github.com/dylanaraps/pfetch/blob/pfetch#L53
has() {
  local _cmd _name

  for _name in "$@"; do
    _cmd="$(command -v "${_name}")" 2>/dev/null || return 1
    ## REMINDER: has() is the R-090 drop-in replacement for 'command -v' and
    ## must succeed for everything 'command -v' does, builtins included --
    ## 'command -v' prints a bare word (not a path) for a builtin, function,
    ## alias or keyword. The '-x' check therefore applies only to a resolved
    ## absolute path. Do NOT restrict this to executable files only: that
    ## re-breaks 'has printf' (commit baa77320c) and dist-ai's
    ## has_builtin_test.sh canaries exactly that regression.
    case "${_cmd}" in
      /*)
        [ -x "${_cmd}" ] || return 1
        ;;
    esac
  done
}

is_type_file() {
  local _name

  for _name in "$@"; do
    if ! [ "$(type -t "${_name}")" = "file" ]; then
      return 1
    fi
  done
  return 0
}

type_exists() {
  local _name

  for _name in "$@"; do
    [ -n "$(type -t "${_name}")" ] || return 1
  done
  return 0
}

lsmod_deterministic() {
  lsmod | awk 'NR>1 {print $1}' | LC_ALL='C' sort
}

kernel_module_loaded_check() {
  lsmod_deterministic | grep --line-regexp --fixed-strings -- "${1}" >/dev/null
}

modprobe_remove() {
  if ! kernel_module_loaded_check "${1}"; then
    return 0
  fi
  modprobe --remove "${1}" || return 1
  return 0
}
