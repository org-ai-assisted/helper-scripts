#!/bin/sh

## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## style-ok: no-strict - sourced library.

## 'local' is not in POSIX proper but is supported by every shell this ships
## on (bash, busybox, dash).
# shellcheck disable=SC3043

## NOTE: Must not include bashisms!

## NOTE: Fully installed packages only (third field 'installed'). The want
##       field may be 'install' or 'hold' -- a held package IS installed
##       (apt-mark hold only pins the version), so both count as installed.

## NOTE: code duplication: Function pkg_installed is duplicated elsewhere in derivative-maker source code.

pkg_installed() {
   ## 'local' does not break 'sh'.
   local package_name dpkg_query_output
   local want error_flag status

   package_name="$1"
   ## Cannot use '&>' because it is a bashism.
   dpkg_query_output="$(dpkg-query --show --showformat='${Status}' "${package_name}" 2>/dev/null)" || true
   ## dpkg_query_output Examples:
   ## install ok half-configured
   ## install ok installed

   want=$(printf '%s' "${dpkg_query_output}" | awk '{print $1}')
   error_flag=$(printf '%s' "${dpkg_query_output}" | awk '{print $2}')
   status=$(printf '%s' "${dpkg_query_output}" | awk '{print $3}')

   ## A held package ('hold ok installed') is installed; apt-mark hold only
   ## pins its version. Accept 'hold' alongside 'install'.
   if [ "${want}" != 'install' ] && [ "${want}" != 'hold' ]; then
      true "$0: INFO: package '${package_name}' want '${want}' is neither 'install' nor 'hold'."
      return 1
   fi
   if ! [ "${error_flag}" = 'ok' ]; then
      true "$0: INFO: package '${package_name}' error_flag '${error_flag}' is not 'ok'."
      return 1
   fi
   if ! [ "${status}" = 'installed' ]; then
      true "$0: INFO: package '${package_name}' status '${status}' is not 'installed'."
      return 1
   fi

   true "$0: INFO: '${package_name}' is installed, ok."
   return 0
}
