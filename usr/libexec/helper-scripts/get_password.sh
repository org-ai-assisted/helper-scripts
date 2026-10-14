#!/bin/bash

## Copyright (C) 2019 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## Copyright (C) 2019 - 2019 Dipto
## See the file COPYING for copying conditions.

## style-ok: R-010 -- pure sourced library (never executed); a top-level
## strict-mode block would leak into the sourcing shell (see R-010a).

get_password() {
   ## author of contents of get_password function
   ## Dipto
   ## https://askubuntu.com/users/133486/dipto
   ##
   ## source of contents of get_password function
   ##
   ## https://askubuntu.com/a/299469/389275
   ##
   ## license:
   ## licensed under cc by-sa 3.0 with attribution required.
   ##
   ## Reads one keystroke at a time. Callers set a global 'LC_ALL=C' (strict-mode
   ## block), under which 'read -n 1' is BYTE-wise and corrupts multibyte input
   ## on backspace; read under the caller's inherited locale, then restore.
   local char prompt saved_lc_all

   saved_lc_all="${LC_ALL:-}"
   unset LC_ALL

   password=""
   prompt=""

   while IFS= read -p "${prompt:-}" -r -s -n 1 char; do
      # Enter - accept password
      if [[ "${char}" == $'\0' ]] ; then
         break
      fi
      # Backspace
      if [[ "${char}" == $'\177' ]] ; then
         prompt=$'\b \b'
         password="${password%?}"
      else
         prompt='*'
         password+="${char}"
      fi
   done

   if [ -n "${saved_lc_all}" ]; then
      export LC_ALL="${saved_lc_all}"
   fi
}
