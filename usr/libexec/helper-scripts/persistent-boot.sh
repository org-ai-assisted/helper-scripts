#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## style-ok: R-010 -- sourced library.

# shellcheck source=./live-boot-cmdline.bsh
source "${HELPER_SCRIPTS_PATH:-}"/usr/libexec/helper-scripts/live-boot-cmdline.bsh

## Helpers for managing a writable boot partition for ISO persistent mode.

## Used to validate if a word can be placed into grub.cfg unquoted.
persistent_boot_safe_token_re='^[A-Za-z0-9._:/=,@%!+-]+$'

## Used to validate that a label name is safe.
persistent_boot_label_re='^[A-Za-z0-9._-]+$'

persistent_boot_uuid_re='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

## Render an untrusted value safe for a SINGLE-LINE log message. sanitize-string
## (stdisplay) strips ANSI/markup but PRESERVES newlines, so a crafted value
## could still forge a second log line; collapse CR/newline to '?' here too.
persistent_boot_log_safe() {
   local safe
   safe="$("${HELPER_SCRIPTS_PATH:-}"/usr/bin/sanitize-string -- nolimit "$1")"
   safe="${safe//$'\r'/?}"
   safe="${safe//$'\n'/?}"
   printf '%s' "${safe}"
}

## Generate a base kernel command line.
persistent_boot_cmdline() {
   local overlay_label luks_uuid boot_cmdline orig_cmdline iso_cmdline token
   local volume_label out
   local -a orig_token_list boot_token_list
   local IFS=$' \t\n'

   overlay_label="${1}"
   luks_uuid="${2:-}"

   if ! [[ "${overlay_label}" =~ ${persistent_boot_label_re} ]]; then
      printf '%s\n' "persistent-boot: refusing unsafe overlay label '$(persistent_boot_log_safe "${overlay_label}")'." >&2
      return 1
   fi
   if [ -n "${luks_uuid}" ] && ! [[ "${luks_uuid}" =~ ${persistent_boot_uuid_re} ]]; then
      printf '%s\n' "persistent-boot: refusing malformed luks uuid '$(persistent_boot_log_safe "${luks_uuid}")'." >&2
      return 1
   fi

   ## Getting the right command line is tricky. We cannot simply reuse the
   ## command line from /proc/cmdline because it may contain or omit kernel
   ## hardening options that the user only intended to add or remove
   ## temporarily. It also will break the iso-scan mechanism to do this. We
   ## cannot generate the list of hardening options from
   ## /etc/default/grub{,.d/*} and then add on a hardcoded list of live ISO
   ## parameters, because we don't know the volume label of the ISO to use as
   ## the base. We can get the volume label by figuring out what device
   ## provides the overlayfs base of / and then extracting the label from that,
   ## but that is a lot of work. Therefore, we use the hardening options +
   ## hardcoded list strategy, but extract the volume label from /proc/cmdline
   ## for simplicity. This label has to be correct for the system to boot, so
   ## it can be trusted.

   if ! boot_cmdline="$(cat -- "${PERSISTENT_BOOT_CMDLINE_FILE:-/proc/cmdline}" 2>/dev/null)" || [ -z "${boot_cmdline}" ]; then
      printf '%s\n' "persistent-boot: could not read boot kernel command line." >&2
      return 1
   fi
   local grub_default="${PERSISTENT_BOOT_GRUB_DEFAULT:-/etc/default/grub}"
   orig_cmdline="$(
      ## style-ok: R-011 -- errexit/nounset off only inside this grub-config subshell.
      set +o errexit
      set +o nounset
      ## Mirror grub-mkconfig: the config is the '${grub_default}' FILE plus the
      ## '${grub_default}.d/*.cfg' drop-ins -- NOT '${grub_default}/*' (the file
      ## is not a directory; that glob stayed literal and errored).
      if [ -f "${grub_default}" ]; then
         source "${grub_default}"
      fi
      for cfg in "${grub_default}.d"/*.cfg; do
         [ -e "${cfg}" ] || continue
         source "${cfg}"
      done
      # shellcheck disable=SC2154  # GRUB_CMDLINE_LINUX* set by the sourced /etc/default/grub
      printf '%s' "${GRUB_CMDLINE_LINUX# }${GRUB_CMDLINE_LINUX:+ }${GRUB_CMDLINE_LINUX_DEFAULT# }"
   )"
   if [ -z "${orig_cmdline}" ]; then
      printf '%s\n' "persistent-boot: could not extract base kernel command line." >&2
      return 1
   fi
   read -r -a boot_token_list <<< "${boot_cmdline}"
   read -r -a orig_token_list <<< "${orig_cmdline}"

   volume_label=''
   for token in "${boot_token_list[@]}"; do
      ## Technically the last root= parameter is likely the one that will be
      ## respected, but in practice the chances of there being two root=
      ## parameters is extremely low, and we may want to use the earlier one
      ## even if there are multiple.
      if [[ "${token}" = root=live:CDLABEL=* ]]; then
         ## Remove 'root='
         volume_label="${token#*=}"
         ## Remove 'live:CDLABEL='
         volume_label="${volume_label#*=}"
         if ! [[ "${volume_label}" =~ ${persistent_boot_label_re} ]]; then
            printf '%s\n' "persistent-boot: volume label '$(persistent_boot_log_safe "${volume_label}")' contains illegal characters." >&2
            return 1
         fi
         break
      fi
   done
   if [ -z "${volume_label}" ]; then
      printf '%s\n' "persistent-boot: no volume label found in boot command line." >&2
      return 1
   fi

   iso_cmdline="$(live_boot_base_iso_cmdline "${volume_label}")"

   out="${iso_cmdline}"
   for token in "${orig_token_list[@]}"; do
      if ! [[ "${token}" =~ ${persistent_boot_safe_token_re} ]]; then
         printf '%s\n' "persistent-boot: dropping unsafe cmdline token '$(persistent_boot_log_safe "${token}")'." >&2
         continue
      fi
      ## The overlay label and the optional LUKS uuid are re-added canonically
      ## below; rd.live.overlay.reset=1 is DESTRUCTIVE and must ride ONLY the
      ## confirmation-wrapped RESET entry. Drop any copy arriving from the base
      ## config so a plain USER/SYSMAINT entry can never silently reset the
      ## persistent overlay on a normal boot, nor carry a stale/duplicate
      ## overlay or luks token. (rd.live.overlay.overlayfs is NOT matched here.)
      case "${token}" in
         rd.live.overlay.reset | rd.live.overlay.reset=* | rd.live.overlay=* | rd.luks.uuid=*)
            continue
            ;;
      esac
      out+=" ${token}"
   done
   out+=" rd.live.overlay=LABEL=${overlay_label}:/live/overlay"
   if [ -n "${luks_uuid}" ]; then
      out+=" rd.luks.uuid=${luks_uuid}"
   fi
   printf '%s\n' "${out}"
}

## Find and output the first valid LUKS volume UUID found in the boot kernel
## command line. Returns 0 on success, 1 if no LUKS volume UUIDs are in the
## command line, 2 on error.
persistent_boot_luks_uuid() {
   local boot_cmdline token luks_uuid_maybe found_luks_uuid
   local -a token_list
   local IFS=$' \t\n'

   boot_cmdline="$(cat -- "${PERSISTENT_BOOT_CMDLINE_FILE:-/proc/cmdline}" 2>/dev/null)" || return 2
   read -r -a token_list <<< "${boot_cmdline}"
   found_luks_uuid='false'
   for token in "${token_list[@]}"; do
      if [[ "${token}" = rd.luks.uuid=* ]]; then
         found_luks_uuid='true'
         luks_uuid_maybe="${token#rd.luks.uuid=}"
         luks_uuid_maybe="${luks_uuid_maybe#luks-}"
         if [[ "${luks_uuid_maybe}" =~ ${persistent_boot_uuid_re} ]]; then
            printf '%s\n' "${luks_uuid_maybe}"
            return 0
         fi
      fi
   done
   if [ "${found_luks_uuid}" = 'true' ]; then
      return 2
   fi
   return 1
}

## Find the partition with the specified GPT partition label. Outputs the name
## of the partition device if found, nothing if no partition device was found
## or multiple were found and no preferred device could be determined.
persistent_boot_device() {
   local partlabel lsblk_name candidate_name lsblk_partlabel medium_dir \
      medium_src booted_disk_pkname candidate_disk_pkname
   local -a candidate_list candidate_on_boot_list

   partlabel="${1}"
   if [ -z "${partlabel}" ]; then
      return 0
   fi

   if [ -n "${PERSISTENT_BOOT_DEVICE:-}" ]; then
      ## Override for testing purposes.
      printf '%s\n' "${PERSISTENT_BOOT_DEVICE}"
      return 0
   fi

   candidate_list=()
   while read -r lsblk_name lsblk_partlabel; do
      if [ "${lsblk_partlabel}" = "${partlabel}" ]; then
         candidate_list+=( "${lsblk_name}" )
      fi
   done < <(lsblk --noheadings --raw --paths --output NAME,PARTLABEL 2>/dev/null)
   if [ "${#candidate_list[@]}" -eq 0 ]; then
      return 0
   fi
   if [ "${#candidate_list[@]}" -eq 1 ]; then
      printf '%s\n' "${candidate_list[0]}"
      return 0
   fi

   ## There are multiple partitions with the same label. See if there is one
   ## (and only one) on the boot drive.
   medium_src=''
   for medium_dir in "${PERSISTENT_BOOT_MEDIUM_DIR:-}" /run/initramfs/live /run/rootfsbase; do
      if [ -z "${medium_dir}" ]; then
         continue
      fi
      medium_src="$(findmnt --noheadings --first-only --nofsroot --output SOURCE --mountpoint "${medium_dir}" 2>/dev/null)" || medium_src=''
      if [ -n "${medium_src}" ]; then
         break
      fi
   done
   if [ -z "${medium_src}" ]; then
      return 0
   fi

   booted_disk_pkname="$(lsblk --noheadings --paths --output PKNAME "${medium_src}" 2>/dev/null | head --lines 1)"
   if [ -z "${booted_disk_pkname}" ]; then
      return 0
   fi

   candidate_on_boot_list=()
   for candidate_name in "${candidate_list[@]}"; do
      candidate_disk_pkname="$(lsblk --noheadings --paths --output PKNAME "${candidate_name}" 2>/dev/null | head --lines 1)"
      if [ "${candidate_disk_pkname}" = "${booted_disk_pkname}" ]; then
         candidate_on_boot_list+=( "${candidate_name}" )
      fi
   done

   if [ "${#candidate_on_boot_list[@]}" -eq 1 ]; then
      printf '%s\n' "${candidate_on_boot_list[0]}"
   fi
}

## Create ${mount_dir}/boot if needed, verify it is not a symlink or non-dir
## file, and echo the path to it. Returns 0 on success, 1 on failure.
persistent_boot_safe_boot_dir() {
   local mount_dir boot_dir

   mount_dir="${1}"
   if [ -z "${mount_dir}" ]; then
      printf '%s\n' "persistent-boot: empty mount dir, refusing." >&2
      return 1
   fi

   boot_dir="${mount_dir}/boot"
   if [ -L "${boot_dir}" ]; then
      printf '%s\n' "persistent-boot: refusing 'boot' symlink at '${boot_dir}'." >&2
      return 1
   fi
   if [ -e "${boot_dir}" ] && [ ! -d "${boot_dir}" ]; then
      printf '%s\n' "persistent-boot: '${boot_dir}' exists and is not a directory, refusing." >&2
      return 1
   fi

   mkdir --parents -- "${boot_dir}" || return 1
   printf '%s\n' "${boot_dir}"
}

## Clean up outdated kernel and initramfs files from the boot partition.
persistent_boot_prune() {
   local boot_dir src_dir kernel_file kernel_version

   boot_dir="${1}"
   src_dir="${2}"
   if [ -z "${boot_dir}" ] || [ -z "${src_dir}" ]; then
      return 0
   fi
   if [ -L "${boot_dir}" ]; then
      printf '%s\n' "persistent-boot: refusing to prune a symlinked boot dir." >&2
      return 0
   fi

   for kernel_file in "${boot_dir}"/vmlinuz-*; do
      if [ ! -f "${kernel_file}" ]; then
         continue
      fi
      kernel_version="${kernel_file##*/vmlinuz-}"
      if [ ! -f "${src_dir}/vmlinuz-${kernel_version}" ]; then
         safe-rm --force -- "${boot_dir}/vmlinuz-${kernel_version}" "${boot_dir}/initrd.img-${kernel_version}" 2>/dev/null || true
      fi
   done
}

## Atomically copy not-yet-synced kernel and initramfs files to the boot
## partition.
persistent_boot_install() {
   local boot_dir src_dir copy_ok kernel_file kernel_version kernel_name \
      initrd_name

   boot_dir="${1}"
   src_dir="${2}"
   copy_ok='true'

   if [ -z "${boot_dir}" ] || [ -z "${src_dir}" ]; then
      return 1
   fi
   if [ -L "${boot_dir}" ]; then
      printf '%s\n' "persistent-boot: refusing to install boot files into a symlinked boot dir." >&2
      return 1
   fi

   for kernel_file in "${src_dir}"/vmlinuz-*; do
      if [ ! -f "${kernel_file}" ]; then
         continue
      fi
      kernel_version="${kernel_file##*/vmlinuz-}"
      kernel_name="vmlinuz-${kernel_version}"
      initrd_name="initrd.img-${kernel_version}"
      if [ ! -f "${boot_dir}/${kernel_name}" ] || [ ! -f "${boot_dir}/${initrd_name}" ]; then
        safe-rm --force -- "${boot_dir}/${kernel_name}" "${boot_dir}/${initrd_name}"
        cp --dereference --remove-destination --no-target-directory -- "${src_dir}/${kernel_name}" "${boot_dir}/.${kernel_name}.new" || copy_ok='false'
        cp --dereference --remove-destination --no-target-directory -- "${src_dir}/${initrd_name}" "${boot_dir}/.${initrd_name}.new" || copy_ok='false'
        if [ "${copy_ok}" = 'true' ]; then
          mv --force --no-target-directory -- "${boot_dir}/.${kernel_name}.new" "${boot_dir}/${kernel_name}" || copy_ok='false'
          mv --force --no-target-directory -- "${boot_dir}/.${initrd_name}.new" "${boot_dir}/${initrd_name}" || copy_ok='false'
        fi
        safe-rm --force -- "${boot_dir}/.${kernel_name}.new" "${boot_dir}/.${initrd_name}.new" 2>/dev/null || true
      fi

      if [ "${copy_ok}" = 'false' ]; then
        return 1
      fi
   done

   return 0
}

## Write persistent-overlay-aware GRUB configuration to
## ${boot_dir}/grub/grub.cfg.
persistent_boot_write_grub_cfg() {
   local boot_dir cmdline kernel_file kernel_version \
      sorted_kernel_version_list_str newest_kernel_version target_config_file \
      temp_config_file entry_param_data bit_list entry_name \
      extra_kernel_params require_confirmation
   local -a kernel_version_list entry_param_list

   boot_dir="${1}"
   cmdline="${2}"
   if [ -z "${boot_dir}" ] || [ -L "${boot_dir}" ]; then
      return 1
   fi
   if [ -z "${cmdline}" ]; then
      return 1
   fi
   if [[ "${cmdline}" == *[![:print:]]* ]]; then
      printf '%s\n' "persistent-boot: refusing cmdline '$(persistent_boot_log_safe "${cmdline}")' because it contains non-printing characters." >&2
      return 1
   fi
   if [ -L "${boot_dir}/grub" ]; then
      printf '%s\n' "persistent-boot: refusing a symlinked grub directory." >&2
      return 1
   fi

   target_config_file="${boot_dir}/grub/grub.cfg"
   kernel_version_list=()
   for kernel_file in "${boot_dir}"/vmlinuz-*; do
      if [ ! -f "${kernel_file}" ]; then
         continue
      fi
      kernel_version="${kernel_file##*/vmlinuz-}"
      if [ ! -f "${boot_dir}/initrd.img-${kernel_version}" ]; then
         continue
      fi
      if ! [[ "${kernel_version}" =~ ${persistent_boot_safe_token_re} ]]; then
         printf '%s\n' "persistent-boot: skipping unsafe kernel version '$(persistent_boot_log_safe "${kernel_version}")'." >&2
         continue
      fi
      kernel_version_list+=( "${kernel_version}" )
   done
   if [ "${#kernel_version_list[@]}" -eq 0 ]; then
      ## Remove any old grub.cfg as there are no upgraded kernels to boot.
      safe-rm --force -- "${target_config_file}" 2>/dev/null || true
      return 1
   fi
   sorted_kernel_version_list_str="$(printf '%s\n' "${kernel_version_list[@]}" | sort --version-sort --reverse)"
   newest_kernel_version="$(printf '%s\n' "${sorted_kernel_version_list_str}" | head --lines 1)"

   mkdir --parents -- "${boot_dir}/grub"

   ## TODO: Support grub-live mode on top of ISO live mode with updated kernel?
   temp_config_file="$(mktemp -- "${boot_dir}/grub/.grub.cfg.XXXXXX")" || return 1
   ## entry_name!extra_kernel_params!require_confirmation
   entry_param_list=(
     'PERSISTENT Mode | USER Session!!false'
     'PERSISTENT Mode | SYSMAINT Session!boot-role=sysmaint systemd.unit=sysmaint-boot.target!false'
     'RESET persistent overlay!rd.live.overlay.reset=1!true'
   )
   ## A failed write (e.g. ENOSPC) must not rename a truncated file over a
   ## still-valid grub.cfg. The disk stays full, so the final write also fails
   ## and the group returns nonzero. Rename only after the writes succeed;
   ## remove the temp file on failure. (errexit is deliberately NOT used inside:
   ## bash suppresses it in a subshell evaluated as an if-condition.)
   if ! {
      printf '%s\n' '## AUTO-GENERATED, do not edit.'
      printf '%s\n' 'set default=0'
      printf '%s\n' 'set timeout=5'
      for entry_param_data in "${entry_param_list[@]}"; do
         IFS='!' read -r -a bit_list <<< "${entry_param_data}"
         entry_name="${bit_list[0]}"
         extra_kernel_params="${bit_list[1]}"
         require_confirmation="${bit_list[2]}"
         if [ "${require_confirmation}" = 'true' ]; then
            printf '%s\n' "submenu \"${entry_name}\" {"
            printf '%s\n' '  menuentry "WARNING: This is destructive! Press Enter to continue, or Esc to cancel" {'
            printf '%s\n' "    linux /boot/vmlinuz-${newest_kernel_version} ${cmdline}${extra_kernel_params:+ }${extra_kernel_params}"
            printf '%s\n' "    initrd /boot/initrd.img-${newest_kernel_version}"
            printf '%s\n' '  }'
            printf '%s\n' '}'
         else
            printf '%s\n' "menuentry \"${entry_name}\" {"
            printf '%s\n' "  linux /boot/vmlinuz-${newest_kernel_version} ${cmdline}${extra_kernel_params:+ }${extra_kernel_params}"
            printf '%s\n' "  initrd /boot/initrd.img-${newest_kernel_version}"
            printf '%s\n' '}'
         fi
      done
      printf '%s\n' 'submenu "Boot with specific kernel..." {'
      for entry_param_data in "${entry_param_list[@]}"; do
         IFS='!' read -r -a bit_list <<< "${entry_param_data}"
         entry_name="${bit_list[0]}"
         extra_kernel_params="${bit_list[1]}"
         require_confirmation="${bit_list[2]}"
         printf '%s\n' "  submenu \"${entry_name} with specific kernel...\" {"
         if [ "${require_confirmation}" = 'true' ]; then
            while IFS= read -r kernel_version; do
               printf '%s\n' "    submenu \"Linux ${kernel_version}, ${entry_name}\" {"
               printf '%s\n' '      menuentry "WARNING: This is destructive! Press Enter to continue, or Esc to cancel" {'
               printf '%s\n' "        linux /boot/vmlinuz-${kernel_version} ${cmdline}${extra_kernel_params:+ }${extra_kernel_params}"
               printf '%s\n' "        initrd /boot/initrd.img-${kernel_version}"
               printf '%s\n' '      }'
               printf '%s\n' '    }'
            done <<< "${sorted_kernel_version_list_str}"
         else
            while IFS= read -r kernel_version; do
               printf '%s\n' "    menuentry \"Linux ${kernel_version}, ${entry_name}\" {"
               printf '%s\n' "      linux /boot/vmlinuz-${kernel_version} ${cmdline}${extra_kernel_params:+ }${extra_kernel_params}"
               printf '%s\n' "      initrd /boot/initrd.img-${kernel_version}"
               printf '%s\n' '    }'
            done <<< "${sorted_kernel_version_list_str}"
         fi
         printf '%s\n' "  }"
      done
      printf '%s\n' '}'
   } > "${temp_config_file}"; then
      safe-rm --force -- "${temp_config_file}" 2>/dev/null || true
      return 1
   fi
   if ! mv --force --no-target-directory -- "${temp_config_file}" "${target_config_file}"; then
      safe-rm --force -- "${temp_config_file}" 2>/dev/null || true
      return 1
   fi
}
