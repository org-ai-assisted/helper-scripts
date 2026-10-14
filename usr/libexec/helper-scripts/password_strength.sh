#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## style-ok: R-010 -- pure sourced library (never executed); a top-level
## strict-mode block would leak into the sourcing shell (see R-010a).

## Shared passphrase-strength gate for the password/passphrase-setting tools
## (pwchange, grub-pwchange, crypt-pwchange, persistence-setup). Backed by
## libpwquality's 'pwscore'. Sourced, never executed: defines a function only.

password_strength_check() {
   ## Gate a passphrase through libpwquality 'pwscore'. The passphrase is read
   ## from STDIN, never from argv, so the secret never reaches 'ps' or a
   ## process argument list -- mirroring pwscore's own stdin contract. Returns
   ## 0 only when the passphrase earns the MAXIMUM score (100); 1 otherwise.
   ## pwscore's own stderr reason is shown to the user on a hard rejection.
   ##
   ## Strength POLICY (require best score) lives here; the per-tool
   ## --allow-weak-passphrase override is the caller's: a caller that honors
   ## the override simply skips this check.
   local passphrase score

   IFS= read -r passphrase || true
   score="$(printf '%s' "${passphrase}" | pwscore)" || return 1
   [ "${score}" = "100" ] || return 1
}
