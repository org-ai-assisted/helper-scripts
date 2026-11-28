#!/bin/bash

## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## style-ok: no-strict - sourced library.

# shellcheck source=./check_runtime.bsh
source "${HELPER_SCRIPTS_PATH:-}"/usr/libexec/helper-scripts/check_runtime.bsh || true
if ! declare -F was_executed >/dev/null; then
  printf '%s\n' "$0: ERROR: cannot source check_runtime.bsh!" >&2
  exit 1
fi

# shellcheck disable=SC2034
get_colors() {
  local -
  set +x

  local color_yes_or_no

  get_colors_was_run=1

  draw="" ## Intentionally not implemented, see below

  if test -n "${NO_COLOR:-}"; then
    color_yes_or_no=no
  fi
  if test -n "${ANSI_COLORS_DISABLED:-}"; then
    color_yes_or_no=no
  fi
  if test -z "${TERM:-}"; then
    color_yes_or_no=no
  fi
  if test "${TERM:-}" = "dumb"; then
    color_yes_or_no=no
  fi
  if test "${TERM:-}" = "unknown"; then
    color_yes_or_no=no
  fi
  if ! test -t 2; then
    color_yes_or_no=no
  fi

  if test "${COLOR_FORCE_YES-}" = 'true'; then
    color_yes_or_no=yes
  fi

  [[ -v color_yes_or_no ]] || color_yes_or_no="yes"

  if test "${color_yes_or_no}" = "no"; then
    nocolor=""; reset=""
    bold=""; nobold=""
    underline=""; nounderline=""
    under=""; eunder=""
    stout=""; estout=""
    blink=""
    italic=""; eitalic=""
    red=""; green=""; yellow=""; blue=""; magenta=""; cyan=""; white=""
    default=""
    alt=""; ealt=""
    hide=""; show=""
    save=""; load=""
    eed=""; eel=""; ebl=""; ewl=""
    back=""
    return 0
  fi

  ## Use printf -v so xtrace shows "\033" text, not raw escape bytes.
  printf -v nocolor     '%b' "\033[0m"
  ## Effects in xtrace.
  #reset="${nocolor}"
  printf -v reset       '%b' "\033[0m"

  printf -v bold        '%b' "\033[1m"
  printf -v nobold      '%b' "\033[22m"

  printf -v underline   '%b' "\033[4m"
  printf -v nounderline '%b' "\033[24m"
  ## Effects in xtrace.
  #under="${underline}"
  #eunder="${nounderline}"
  printf -v under       '%b' "\033[4m"
  printf -v eunder      '%b' "\033[24m"

  printf -v stout       '%b' "\033[7m"
  printf -v estout      '%b' "\033[27m"

  printf -v blink       '%b' "\033[5m"

  printf -v italic      '%b' "\033[3m"
  printf -v eitalic     '%b' "\033[23m"

  printf -v red         '%b' "\033[31m"
  printf -v green       '%b' "\033[32m"
  printf -v yellow      '%b' "\033[33m"
  printf -v blue        '%b' "\033[34m"
  printf -v magenta     '%b' "\033[35m"
  printf -v cyan        '%b' "\033[36m"
  printf -v white       '%b' "\033[37m"
  printf -v default     '%b' "\033[39m"

  printf -v alt         '%b' "\033[?1049h"
  printf -v ealt        '%b' "\033[?1049l"

  printf -v hide        '%b' "\033[?25l"
  printf -v show        '%b' "\033[?25h"

  printf -v save        '%b' "\0337"
  printf -v load        '%b' "\0338"

  printf -v eed         '%b' "\033[J"   # erase to end of display
  printf -v eel         '%b' "\033[K"   # erase to end of line
  printf -v ebl         '%b' "\033[1K"  # erase to beginning of line
  printf -v ewl         '%b' "\033[2K"  # erase whole line

  printf -v back        '%b' "\b"
}

get_colors_test() {
  ## This function is only meant for manual visual verification.
  ## It prints one feature per line, resetting after each line so styles
  ## does not leak into the next output.

  true "$0: START"
  set -o errexit
  set -o nounset
  set -o errtrace
  set -o pipefail

  printf '%s\n' "$0: test mode"

  ## Ensure variables are initialized (in case someone calls test directly).
  ## Not needed because when 'source'ing this script, it's already load.
  #get_colors

  ## --- Colors -------------------------------------------------------
  ## Foreground colors (8-color ANSI). Each line prints the color name in that color.
  printf '%s\n' "${red}red${nocolor}"
  printf '%s\n' "${green}green${nocolor}"
  printf '%s\n' "${yellow}yellow${nocolor}"
  printf '%s\n' "${blue}blue${nocolor}"
  printf '%s\n' "${magenta}magenta${nocolor}"
  printf '%s\n' "${cyan}cyan${nocolor}"
  printf '%s\n' "${white}white${nocolor}"

  ## Reset to terminal default foreground color (may differ from white).
  printf '%s\n' "${default}default${nocolor}"

  ## --- Text attributes ----------------------------------------------
  ## Bold / increased intensity.
  printf '%s\n' "${bold}bold${nocolor}"

  ## Cancel bold / intensity (may not affect underline/italic).
  printf '%s\n' "${nobold}nobold${nocolor}"

  ## Italic (may be unsupported or rendered as reverse/underline on some terminals).
  printf '%s\n' "${italic}italic${nocolor}"

  ## Cancel italic (not tested by default; usually harmless).
  #printf '%s\n' "${eitalic}eitalic${nocolor}"

  ## Underline.
  printf '%s\n' "${underline}underline${nocolor}"

  ## Cancel underline (not tested by default; usually harmless).
  #printf '%s\n' "${nounderline}nounderline${nocolor}"

  ## Standout / reverse video (often swaps foreground/background).
  printf '%s\n' "${stout}stout${nocolor}"

  ## Cancel standout / reverse video.
  printf '%s\n' "${estout}estout${nocolor}"

  ## Blinking text.
  printf '%s\n' "${blink}blink${nocolor}"

  ## --- Cursor / screen control --------------------------------------
  ## Hide cursor, print "hide", then show cursor again.
  ## Useful to confirm the escape sequences do not break output.
  printf '%s\n' "${hide}hide${show}${nocolor}"

  ## Cursor save/restore (not tested by default because it can look odd
  ## depending on where the cursor is when printed).
  #printf '%s\n' "${save}save${load}${nocolor}"

  ## Erase to end of display (J) / end of line (K) / beginning of line (1K)
  ## / whole line (2K). These are hard to "see" in a simple print, but
  ## included for completeness.
  #printf '%s\n' "${eed}eed${nocolor}"
  #printf '%s\n' "${eel}eel${nocolor}"
  #printf '%s\n' "${ebl}ebl${nocolor}"
  #printf '%s\n' "${ewl}ewl${nocolor}"

  ## Backspace character. Typically moves cursor one column left; visual
  ## effect depends on surrounding output.
  #printf '%s\n' "${back}back${nocolor}"

  ## Drawing characters capability is intentionally unsupported in this
  ## modern implementation; kept for compatibility (usually empty).
  printf '%s\n' "draw: ${draw:-}"

  true "$0: END"
}

if test "${get_colors_was_run:-}" != "1"; then
  get_colors
fi

if should_run_unit_tests "${BASH_SOURCE[0]}"; then
  get_colors_test
fi
