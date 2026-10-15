#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## style-ok: R-010 -- pure sourced library (never executed); a top-level
## strict-mode block would leak into the sourcing shell (see R-010a).

## Writable-boot management for a persistent live overlay. The signed ISO grub
## hands off (search --label + configfile) to a grub.cfg on the unencrypted,
## grub-readable ext4 'persistbootx' partition (always carved, encrypted overlay
## or not -- grub reads ext4 but not LUKS, and not necessarily btrfs). These
## helpers resolve that partition, build the boot cmdline, and (re)write its
## grub.cfg so an UPGRADED kernel boots. Because that boot area is UNENCRYPTED
## (an offline attacker can write it), everything pasted into grub.cfg is
## sanitized -- a grub.cfg is executed by grub, so an unquoted metacharacter is a
## grub command. Sourced by persistence-setup (seed) and the kernel postinst hook
## (maintenance). Functions only.

## A token safe to paste UNQUOTED into a grub.cfg 'linux' line. Covers every
## realistic kernel cmdline token (root=live:CDLABEL=..., iso-scan/filename=/x,
## rd.*, hardening flags) while excluding grub metacharacters (; newline $ ` { }
## quotes space).
persistent_boot_safe_token_re='^[A-Za-z0-9._:/=,@%+-]+$'
persistent_boot_uuid_re='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

## Build the persistent-boot kernel cmdline from the REALIZED cmdline: drop the
## bootloader-injected, overlay, luks and overlay-RESET tokens we re-add (or
## deliberately omit), drop any token that is not a safe grub token, then append
## the canonical persistence overlay and -- only when encrypted -- the LUKS uuid.
## The overlay label and luks uuid are validated too (never an injection sink).
## Dropping rd.live.overlay.reset is load-bearing: baking it into a persistent
## entry would wipe the overlay every boot. Args: overlay_label [luks_uuid].
## Honors PERSISTENT_BOOT_CMDLINE_FILE. Returns 1 on an unreadable cmdline or an
## unsafe label/uuid.
persistent_boot_cmdline() {
   local overlay_label luks_uuid src raw token out
   local -a tokens
   local IFS=$' \t\n'
   overlay_label="${1}"
   luks_uuid="${2:-}"
   if ! [[ "${overlay_label}" =~ ${persistent_boot_safe_token_re} ]]; then
      printf '%s\n' "persistent-boot: refusing unsafe overlay label '${overlay_label}'." >&2
      return 1
   fi
   if [ -n "${luks_uuid}" ] && ! [[ "${luks_uuid}" =~ ${persistent_boot_uuid_re} ]]; then
      printf '%s\n' "persistent-boot: refusing malformed luks uuid." >&2
      return 1
   fi
   src="${PERSISTENT_BOOT_CMDLINE_FILE:-/proc/cmdline}"
   if [ ! -r "${src}" ]; then
      return 1
   fi
   raw="$(cat -- "${src}")"
   read -r -a tokens <<< "${raw}"
   out=''
   for token in "${tokens[@]}"; do
      case "${token}" in
         BOOT_IMAGE=*|initrd=*|rd.live.overlay=*|rd.luks.uuid=*)
            continue
            ;;
         rd.live.overlay.reset=*|rd.live.overlay.reset)
            continue
            ;;
      esac
      if ! [[ "${token}" =~ ${persistent_boot_safe_token_re} ]]; then
         printf '%s\n' "persistent-boot: dropping an unsafe cmdline token." >&2
         continue
      fi
      out="${out:+${out} }${token}"
   done
   out="${out} rd.live.overlay=LABEL=${overlay_label}:/live/overlay"
   if [ -n "${luks_uuid}" ]; then
      out="${out} rd.luks.uuid=${luks_uuid}"
   fi
   printf '%s\n' "${out}"
}

## Echo the FIRST valid rd.luks.uuid on the realized cmdline and return 0
## (encrypted); return 1 when no rd.luks.uuid is present (plaintext); return 2
## when a rd.luks.uuid token is present but none is a well-formed UUID, OR the
## cmdline is unreadable (ambiguous -> the caller must refuse, never assume
## plaintext and silently drop the uuid). Honors the cmdline seam.
persistent_boot_luks_uuid() {
   local src raw token val seen
   local -a tokens
   local IFS=$' \t\n'
   src="${PERSISTENT_BOOT_CMDLINE_FILE:-/proc/cmdline}"
   if [ ! -r "${src}" ]; then
      return 2
   fi
   raw="$(cat -- "${src}")"
   read -r -a tokens <<< "${raw}"
   seen='false'
   for token in "${tokens[@]}"; do
      case "${token}" in
         rd.luks.uuid=*)
            seen='true'
            val="${token#rd.luks.uuid=}"
            val="${val#luks-}"
            if [[ "${val}" =~ ${persistent_boot_uuid_re} ]]; then
               printf '%s\n' "${val}"
               return 0
            fi
            ;;
      esac
   done
   if [ "${seen}" = 'true' ]; then
      return 2
   fi
   return 1
}

## Resolve the partition carrying GPT PARTLABEL <partlabel> (the GPT name
## persistence-setup assigns -- the open LUKS mapper does not carry it, so the
## mapper is never selected). The usual case has exactly one such partition -- on
## the booted USB (usb-freespace) or on a dedicated second disk (--target disk)
## -- and it is used directly. If SEVERAL disks carry the label, the one on the
## BOOTED stick's disk is preferred; a remaining tie is refused, not guessed.
## Echoes the device path, or nothing. Honors PERSISTENT_BOOT_DEVICE (forced,
## tests) + PERSISTENT_BOOT_MEDIUM_DIR. --nofsroot keeps a bind/subvol '[/x]'
## suffix out of the findmnt SOURCE so lsblk can resolve the parent disk.
persistent_boot_device() {
   local partlabel name plabel medium_dir medium_src booted_disk cand_disk
   local -a candidates
   partlabel="${1}"
   if [ -n "${PERSISTENT_BOOT_DEVICE:-}" ]; then
      printf '%s\n' "${PERSISTENT_BOOT_DEVICE}"
      return 0
   fi
   candidates=()
   while read -r name plabel; do
      if [ "${plabel}" = "${partlabel}" ]; then
         candidates+=( "${name}" )
      fi
   done < <(lsblk --noheadings --raw --paths --output NAME,PARTLABEL 2>/dev/null)
   if [ "${#candidates[@]}" -eq 0 ]; then
      return 0
   fi
   if [ "${#candidates[@]}" -eq 1 ]; then
      printf '%s\n' "${candidates[0]}"
      return 0
   fi
   medium_src=''
   for medium_dir in "${PERSISTENT_BOOT_MEDIUM_DIR:-}" /run/initramfs/live /run/rootfsbase; do
      if [ -z "${medium_dir}" ]; then
         continue
      fi
      medium_src="$(findmnt --noheadings --first-only --nofsroot --output SOURCE --target "${medium_dir}" 2>/dev/null)" || medium_src=''
      if [ -n "${medium_src}" ]; then
         break
      fi
   done
   if [ -z "${medium_src}" ]; then
      return 0
   fi
   booted_disk="$(lsblk --noheadings --paths --output PKNAME "${medium_src}" 2>/dev/null | head --lines 1)"
   if [ -z "${booted_disk}" ]; then
      return 0
   fi
   for name in "${candidates[@]}"; do
      cand_disk="$(lsblk --noheadings --paths --output PKNAME "${name}" 2>/dev/null | head --lines 1)"
      if [ "${cand_disk}" = "${booted_disk}" ]; then
         printf '%s\n' "${name}"
         return 0
      fi
   done
}

## Remove boot-area kernel pairs whose kernel is no longer installed in <src_dir>
## (normally /boot), so the small persistbootx partition does not fill up over
## successive upgrades. Best-effort. Args: boot_dir src_dir. Refuses an empty
## boot_dir (would otherwise sweep the host root).
persistent_boot_prune() {
   local boot_dir src_dir vmlinuz ver
   boot_dir="${1}"
   src_dir="${2}"
   if [ -z "${boot_dir}" ] || [ -z "${src_dir}" ]; then
      return 0
   fi
   for vmlinuz in "${boot_dir}"/vmlinuz-*; do
      if [ ! -e "${vmlinuz}" ]; then
         continue
      fi
      ver="${vmlinuz##*/vmlinuz-}"
      if [ ! -e "${src_dir}/vmlinuz-${ver}" ]; then
         safe-rm --force -- "${boot_dir}/vmlinuz-${ver}" "${boot_dir}/initrd.img-${ver}" 2>/dev/null || true
      fi
   done
}

## (Re)write <boot_dir>/grub/grub.cfg to boot every kernel present in <boot_dir>
## (vmlinuz-<ver> + initrd.img-<ver> pairs), version-sorted newest-first (default),
## older kernels kept as user-selectable fallbacks, plus an amnesic overlay-reset
## entry. A version string that is not a safe token is SKIPPED (a crafted filename
## on the unencrypted boot area must not inject grub syntax). Paths are relative
## to grub's $root (the boot partition the ISO grub configfiled into). Args:
## boot_dir cmdline. Returns 1 on an empty/symlinked boot_dir or no safe pair.
persistent_boot_write_grub_cfg() {
   local boot_dir cmdline vmlinuz ver sorted newest cfg
   local -a versions
   boot_dir="${1}"
   cmdline="${2}"
   if [ -z "${boot_dir}" ]; then
      return 1
   fi
   versions=()
   for vmlinuz in "${boot_dir}"/vmlinuz-*; do
      if [ ! -e "${vmlinuz}" ]; then
         continue
      fi
      ver="${vmlinuz##*/vmlinuz-}"
      if [ ! -e "${boot_dir}/initrd.img-${ver}" ]; then
         continue
      fi
      if ! [[ "${ver}" =~ ${persistent_boot_safe_token_re} ]]; then
         printf '%s\n' "persistent-boot: skipping unsafe kernel version." >&2
         continue
      fi
      versions+=( "${ver}" )
   done
   if [ "${#versions[@]}" -eq 0 ]; then
      return 1
   fi
   ## A symlinked grub dir or grub.cfg would let the '>' redirect escape the boot
   ## area (O_TRUNC, no O_NOFOLLOW); refuse the dir and remove the file first.
   if [ -L "${boot_dir}/grub" ]; then
      printf '%s\n' "persistent-boot: refusing a symlinked grub directory." >&2
      return 1
   fi
   sorted="$(printf '%s\n' "${versions[@]}" | sort --version-sort --reverse)"
   newest="$(printf '%s\n' "${sorted}" | head --lines 1)"
   mkdir --parents -- "${boot_dir}/grub"
   cfg="${boot_dir}/grub/grub.cfg"
   safe-rm --force -- "${cfg}"
   {
      printf '%s\n' '## AUTO-GENERATED by persistent-boot.sh -- do not edit.'
      printf '%s\n' '## A kernel upgrade in the persistent live session rewrites this.'
      printf '%s\n' 'set default=0'
      printf '%s\n' 'set timeout=5'
      while IFS= read -r ver; do
         if [ -z "${ver}" ]; then
            continue
         fi
         printf '%s\n' "menuentry \"Persistent | kernel ${ver}\" {"
         printf '%s\n' "  linux /boot/vmlinuz-${ver} ${cmdline}"
         printf '%s\n' "  initrd /boot/initrd.img-${ver}"
         printf '%s\n' '}'
      done <<< "${sorted}"
      printf '%s\n' "menuentry \"Amnesic (reset overlay) | kernel ${newest}\" {"
      printf '%s\n' "  linux /boot/vmlinuz-${newest} ${cmdline} rd.live.overlay.reset=1"
      printf '%s\n' "  initrd /boot/initrd.img-${newest}"
      printf '%s\n' '}'
   } > "${cfg}"
}
