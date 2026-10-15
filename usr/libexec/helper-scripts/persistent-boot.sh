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
## helpers resolve that partition on the BOOTED stick, build the boot cmdline, and
## (re)write its grub.cfg so an UPGRADED kernel boots. Sourced by persistence-setup
## (initial seed) and the kernel postinst hook (maintenance). Functions only.

## Build the persistent-boot kernel cmdline. Start from the REALIZED cmdline (the
## one that actually booted), drop the bootloader-injected, overlay, luks and
## overlay-RESET tokens we re-add (or deliberately omit) deterministically, then
## append the canonical persistence overlay and -- only when encrypted -- the LUKS
## uuid. Dropping rd.live.overlay.reset is load-bearing: if the current boot
## carried it, baking it into a persistent entry would wipe the overlay every
## boot. Args: overlay_label [luks_uuid]. Honors PERSISTENT_BOOT_CMDLINE_FILE.
persistent_boot_cmdline() {
   local overlay_label luks_uuid src raw token out
   local -a tokens
   overlay_label="${1}"
   luks_uuid="${2:-}"
   src="${PERSISTENT_BOOT_CMDLINE_FILE:-/proc/cmdline}"
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
      out="${out:+${out} }${token}"
   done
   out="${out} rd.live.overlay=LABEL=${overlay_label}:/live/overlay"
   if [ -n "${luks_uuid}" ]; then
      out="${out} rd.luks.uuid=${luks_uuid}"
   fi
   printf '%s\n' "${out}"
}

## Echo the FIRST valid rd.luks.uuid on the realized cmdline and return 0
## (encrypted overlay); return 1 when no rd.luks.uuid is present (plaintext); and
## return 2 when a rd.luks.uuid token is present but NONE is a well-formed UUID
## (a malformed/crafted value -- the caller must refuse, never bake it into
## grub.cfg where grub metacharacters would inject). Honors the cmdline seam.
persistent_boot_luks_uuid() {
   local src raw token val seen
   local -a tokens
   src="${PERSISTENT_BOOT_CMDLINE_FILE:-/proc/cmdline}"
   raw="$(cat -- "${src}" 2>/dev/null)" || true
   read -r -a tokens <<< "${raw}"
   seen='false'
   for token in "${tokens[@]}"; do
      case "${token}" in
         rd.luks.uuid=*)
            seen='true'
            val="${token#rd.luks.uuid=}"
            val="${val#luks-}"
            if [[ "${val}" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
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

## Resolve the partition carrying GPT PARTLABEL <partlabel> on the BOOTED live
## stick's own disk. Scoping to the booted disk is load-bearing: a plain
## `blkid --label` would also match a second attached device with the same label,
## or the open LUKS mapper (whose inner fs is labelled 'persistence' but which
## grub cannot read). PARTLABEL is the GPT name persistence-setup assigns, which
## the mapper does not carry. Echoes the device path, or nothing. Honors
## PERSISTENT_BOOT_DEVICE (forced device, tests) and PERSISTENT_BOOT_MEDIUM_DIR.
persistent_boot_device() {
   local partlabel medium_dir medium_src booted_disk name plabel
   partlabel="${1}"
   if [ -n "${PERSISTENT_BOOT_DEVICE:-}" ]; then
      printf '%s\n' "${PERSISTENT_BOOT_DEVICE}"
      return 0
   fi
   medium_src=''
   for medium_dir in "${PERSISTENT_BOOT_MEDIUM_DIR:-}" /run/initramfs/live /run/rootfsbase; do
      if [ -z "${medium_dir}" ]; then
         continue
      fi
      medium_src="$(findmnt --noheadings --first-only --output SOURCE --target "${medium_dir}" 2>/dev/null)" || medium_src=''
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
   while read -r name plabel; do
      if [ "${plabel}" = "${partlabel}" ]; then
         printf '%s\n' "${name}"
         return 0
      fi
   done < <(lsblk --noheadings --raw --paths --output NAME,PARTLABEL "${booted_disk}" 2>/dev/null)
}

## Remove boot-area kernel pairs whose kernel is no longer installed in <src_dir>
## (normally /boot), so the small persistbootx partition does not fill up over
## successive upgrades. Best-effort: a removal failure is ignored. Args:
## boot_dir src_dir.
persistent_boot_prune() {
   local boot_dir src_dir vmlinuz ver
   boot_dir="${1}"
   src_dir="${2}"
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
## entry. A version string that is not a safe kernel-version token is SKIPPED:
## it is interpolated into grub.cfg, so a crafted filename on the unencrypted boot
## area must not inject grub syntax. Paths are relative to grub's $root (the boot
## partition the ISO grub configfiled into). Args: boot_dir cmdline. Returns 1 if
## no safe kernel pair is found.
persistent_boot_write_grub_cfg() {
   local boot_dir cmdline vmlinuz ver sorted newest
   local -a versions
   boot_dir="${1}"
   cmdline="${2}"
   versions=()
   for vmlinuz in "${boot_dir}"/vmlinuz-*; do
      if [ ! -e "${vmlinuz}" ]; then
         continue
      fi
      ver="${vmlinuz##*/vmlinuz-}"
      if [ ! -e "${boot_dir}/initrd.img-${ver}" ]; then
         continue
      fi
      if ! [[ "${ver}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
         printf '%s\n' "persistent-boot: skipping unsafe kernel version '${ver}'." >&2
         continue
      fi
      versions+=( "${ver}" )
   done
   if [ "${#versions[@]}" -eq 0 ]; then
      return 1
   fi
   sorted="$(printf '%s\n' "${versions[@]}" | sort --version-sort --reverse)"
   newest="$(printf '%s\n' "${sorted}" | head --lines 1)"
   mkdir --parents -- "${boot_dir}/grub"
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
   } > "${boot_dir}/grub/grub.cfg"
}
