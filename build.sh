#!/bin/bash
# Reproducible build of a SteamOS-style (Game Mode) image for Jetson Orin Nano
# on JetPack 7.2.1 / Jetson Linux r39.2.1. Runs on an x86_64 Linux build host.
# It never touches a Jetson; flashing is a separate step: sudo ./flash.sh (see docs/FLASH.md).
#
# Usage: sudo ./build.sh [all|release|fetch|extract|binaries|customize|modules|user|steam|tune|validate|package]
#   all      (default) fetch -> validate. Leaves a flash-ready tree in work/Linux_for_Tegra
#   release  all + package (a .tar.zst of the tree in output/, needs about 4 GB more)
# The steamos sudo password is generated here at build time and written to output/SECRETS.txt (0600).
# SSH public keys come from $SSH_AUTHORIZED_KEYS (a file) or the invoking user's ~/.ssh/id_ed25519.pub.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
. "$HERE/config.env"
DL="$HERE/downloads"; WORK="$HERE/work"; OUT="$HERE/output"
L4T="$WORK/Linux_for_Tegra"; ROOTFS="$L4T/rootfs"
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

preflight() {
  log "preflight"
  [[ $(uname -m) == x86_64 ]] || echo "warning: tested on x86_64 hosts only"
  case "${1:-all}" in all|release|fetch|extract)
    local free_gb; free_gb=$(df -BG --output=avail "$HERE" | tail -1 | tr -dc 0-9)
    (( free_gb >= MIN_FREE_GB )) || die "need ${MIN_FREE_GB}G free in $HERE, have ${free_gb}G" ;;
  esac
  for t in curl lbzip2 sha1sum sha256sum tar xz zstd openssl python3; do command -v $t >/dev/null || die "missing $t (see README-BUILD.md)"; done
  # NVIDIA's apply_binaries.sh / l4t_create_default_user.sh require exactly this path.
  # Ubuntu <=24.04: package qemu-user-static. Ubuntu >=25.04 / Debian 13: qemu-user (+ qemu-user-binfmt),
  # which provides /usr/bin/qemu-aarch64-static as a symlink to the static qemu-aarch64.
  [[ -x /usr/bin/qemu-aarch64-static ]] || die "missing /usr/bin/qemu-aarch64-static: install qemu-user-static (Ubuntu <=24.04) or qemu-user qemu-user-binfmt (Ubuntu >=25.04)"
  if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    mountpoint -q /proc/sys/fs/binfmt_misc || $SUDO mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    local conf=/usr/lib/binfmt.d/qemu-aarch64.conf
    [[ -f $conf ]] || die "qemu-aarch64 binfmt not registered: install binfmt-support / qemu-user-binfmt"
    $SUDO sh -c "cat '$conf' > /proc/sys/fs/binfmt_misc/register" || die "could not register qemu-aarch64 binfmt"
  fi
}

fetch() {
  log "fetch NVIDIA Jetson Linux r$L4T_RELEASE (public URLs)"
  mkdir -p "$DL"; cd "$DL"
  for f in "$SHA_FILE" "$BSP_TARBALL" "$ROOTFS_TARBALL"; do
    [[ -s $f ]] || curl -fSL --retry 3 -o "$f" "$L4T_URL_BASE/$f"
  done
  grep -E "($BSP_TARBALL|$ROOTFS_TARBALL)\$" "$SHA_FILE" | sha1sum -c - || die "checksum mismatch (NVIDIA sha1 list)"
  printf '%s  %s\n%s  %s\n' "$BSP_SHA256" "$BSP_TARBALL" "$ROOTFS_SHA256" "$ROOTFS_TARBALL" | sha256sum -c - \
    || die "sha256 mismatch against the pins in config.env"
}

extract() {
  log "extract BSP + sample rootfs"
  mkdir -p "$WORK"; cd "$WORK"
  $SUDO rm -rf "$L4T"
  tar -I lbzip2 -xf "$DL/$BSP_TARBALL"
  $SUDO tar -I lbzip2 -xpf "$DL/$ROOTFS_TARBALL" -C "$ROOTFS"
}

binaries() {
  log "apply_binaries.sh"
  cd "$L4T"; $SUDO ./apply_binaries.sh
}

mount_chroot() {
  for d in proc sys dev dev/pts run; do mountpoint -q "$ROOTFS/$d" || $SUDO mount --bind "/$d" "$ROOTFS/$d"; done
  $SUDO cp --remove-destination /etc/resolv.conf "$ROOTFS/etc/resolv.conf.build"
  $SUDO mount --bind "$ROOTFS/etc/resolv.conf.build" "$ROOTFS/etc/resolv.conf" 2>/dev/null || \
    $SUDO cp --remove-destination /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
  $SUDO cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
}
umount_chroot() {
  for d in etc/resolv.conf run dev/pts dev sys proc; do
    if mountpoint -q "$ROOTFS/$d" 2>/dev/null; then $SUDO umount -l "$ROOTFS/$d" || true; fi
  done
  $SUDO rm -f "$ROOTFS/etc/resolv.conf.build"
}
in_chroot() { $SUDO chroot "$ROOTFS" /usr/bin/env "$@"; }

customize() {
  log "customize rootfs in qemu-aarch64 chroot"
  trap umount_chroot EXIT
  mount_chroot
  $SUDO install -m755 "$HERE/scripts/chroot-customize.sh" "$ROOTFS/tmp/"
  in_chroot DESKTOP="$DESKTOP" WITH_GAMESCOPE="$WITH_GAMESCOPE" WITH_TAILSCALE="$WITH_TAILSCALE" \
    PURGE_DESKTOP_EXTRAS="$PURGE_DESKTOP_EXTRAS" \
    /bin/bash /tmp/chroot-customize.sh
  log "copy overlay"
  $SUDO cp -a --no-preserve=ownership "$HERE/overlay/." "$ROOTFS/"
  $SUDO chown -R root:root "$ROOTFS/usr/lib/steamos-orin" "$ROOTFS/usr/bin/steamos-polkit-helpers"
  $SUDO install -m755 "$HERE/scripts/chroot-enable.sh" "$ROOTFS/tmp/"
  in_chroot HOSTNAME_TARGET="$HOSTNAME_TARGET" /bin/bash /tmp/chroot-enable.sh
  $SUDO rm -f "$ROOTFS/tmp/chroot-customize.sh" "$ROOTFS/tmp/chroot-enable.sh"
  umount_chroot; trap - EXIT
}

# Resolve the SSH public key file: $SSH_AUTHORIZED_KEYS, else ~/.ssh/id_ed25519.pub of the
# user who invoked sudo (not root's). Prints the path, or nothing if none and allowed.
ssh_keys_file() {
  local f="${SSH_AUTHORIZED_KEYS:-}" home
  if [[ -z $f ]]; then
    home="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
    f="${home:-$HOME}/.ssh/id_ed25519.pub"
  fi
  if [[ -s $f ]]; then
    grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-ssh-ed25519@|sk-ecdsa-sha2-)' "$f" || die "$f does not look like an SSH public key file"
    grep -q 'PRIVATE KEY' "$f" && die "$f contains a PRIVATE key; pass the .pub file"
    echo "$f"; return
  fi
  [[ $ALLOW_NO_SSH_KEY == 1 ]] && return
  die "no SSH public key: set SSH_AUTHORIZED_KEYS=/path/key.pub (or ALLOW_NO_SSH_KEY=1)"
}

modules() {
  if [[ $WITH_INPUT_MODULES != 1 ]]; then log "input modules: skipped (WITH_INPUT_MODULES=0)"; return; fi
  log "build uinput + hid-steam/playstation/nintendo/sony modules (linux-$KSRC_VERSION sources)"
  local tarball="$DL/linux-$KSRC_VERSION.tar.xz" src="$ROOTFS/tmp/kmod-src" p="linux-$KSRC_VERSION"
  mkdir -p "$DL"
  [[ -s $tarball ]] || curl -fSL --retry 3 -o "$tarball" "$KSRC_URL"
  echo "$KSRC_SHA256  $tarball" | sha256sum -c - || die "kernel source sha256 mismatch"
  $SUDO rm -rf "$src"; $SUDO mkdir -p "$src"
  $SUDO tar -xJf "$tarball" -C "$src" --strip-components=1 \
    "$p/drivers/input/misc/uinput.c" "$p/drivers/input/input-compat.h" "$p/drivers/hid/hid-ids.h" \
    "$p/drivers/hid/hid-steam.c" "$p/drivers/hid/hid-playstation.c" \
    "$p/drivers/hid/hid-nintendo.c" "$p/drivers/hid/hid-sony.c"
  trap umount_chroot EXIT
  mount_chroot
  $SUDO install -m755 "$HERE/scripts/chroot-build-modules.sh" "$ROOTFS/tmp/"
  in_chroot /bin/bash /tmp/chroot-build-modules.sh
  $SUDO rm -rf "$src" "$ROOTFS/tmp/chroot-build-modules.sh"
  umount_chroot; trap - EXIT
}

user() {
  log "create default user '$STEAM_USER' (l4t_create_default_user.sh)"
  local keys; keys="$(ssh_keys_file)"
  local pw; pw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  mkdir -p "$OUT"
  umask 077
  printf 'orin-steamos build secrets (%s)\nuser: %s\npassword (sudo): %s\n' \
    "$(date -Is)" "$STEAM_USER" "$pw" > "$OUT/SECRETS.txt"
  chmod 600 "$OUT/SECRETS.txt"
  [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER:" "$OUT" "$OUT/SECRETS.txt"
  umask 022
  cd "$L4T"
  # No -a: autologin is handled by SDDM (10-steamos.conf); -a only edits GDM/getty.
  # pw is [A-Za-z0-9] only, so it is safe in the sed expression; keeps it out of logs
  $SUDO ./tools/l4t_create_default_user.sh -u "$STEAM_USER" -p "$pw" -n "$HOSTNAME_TARGET" --accept-license \
    2>&1 | sed "s/$pw/<REDACTED>/g"
  trap umount_chroot EXIT
  mount_chroot
  in_chroot /bin/bash -e -c "
    for g in sudo video render input audio plugdev netdev bluetooth; do
      getent group \$g >/dev/null && usermod -aG \$g $STEAM_USER; done
    install -d -m700 -o $STEAM_USER -g $STEAM_USER /home/$STEAM_USER/.ssh
    install -d -o $STEAM_USER -g $STEAM_USER /home/$STEAM_USER/Desktop
    install -m755 -o $STEAM_USER -g $STEAM_USER /usr/share/applications/steamos-return-to-gamemode.desktop /home/$STEAM_USER/Desktop/
  "
  umount_chroot; trap - EXIT
  # Copied as a file (never interpolated into a shell string)
  local ak="$ROOTFS/home/$STEAM_USER/.ssh/authorized_keys" uid
  uid="$(stat -c %u "$ROOTFS/home/$STEAM_USER")"
  if [[ -n $keys ]]; then
    $SUDO install -m600 -o "$uid" -g "$uid" "$keys" "$ak"
    echo "authorized_keys: $(grep -c . "$keys") key(s) from $keys"
  else
    $SUDO install -m600 -o "$uid" -g "$uid" /dev/null "$ak"
    echo "warning: no SSH key installed (ALLOW_NO_SSH_KEY=1)"
  fi
}

steam() {
  local info="$ROOTFS/etc/steamos-orin/build-info"
  $SUDO install -d "$ROOTFS/etc/steamos-orin"
  printf 'BUILD_DATE=%s\nL4T_RELEASE=%s\nPREINSTALL_STEAM=%s\n' "$(date -u +%FT%TZ)" "$L4T_RELEASE" "$PREINSTALL_STEAM" \
    | $SUDO tee "$info" >/dev/null
  if [[ $PREINSTALL_STEAM != 1 ]]; then
    log "Steam: not preinstalled (PREINSTALL_STEAM=0); the device downloads it on first boot"
    return
  fi
  log "Steam: preinstall Valve's ARM64 client bootstrap from Valve's CDN (PREINSTALL_STEAM=1)"
  echo "    This image then contains Valve software: for your own use, do not redistribute it."
  trap umount_chroot EXIT
  mount_chroot
  # Same script the device runs on first boot (manifest + sha256 check + backslash-path fix),
  # run as the Steam user under qemu-user. Only curl/awk/unzip run; no Steam binary is executed.
  if ! in_chroot runuser -u "$STEAM_USER" -- env HOME="/home/$STEAM_USER" /usr/lib/steamos-orin/steam-arm64-install; then
    echo "warning: Steam preinstall failed; the image falls back to downloading Steam on first boot"
    $SUDO rm -rf "$ROOTFS/home/$STEAM_USER/.local/share/Steam" "$ROOTFS/home/$STEAM_USER/.steam"
    $SUDO sed -i 's/^PREINSTALL_STEAM=.*/PREINSTALL_STEAM=0 # preinstall failed/' "$info"
  fi
  $SUDO rm -f "$ROOTFS/home/$STEAM_USER/.cache/steam-arm64-install.lock"
  umount_chroot; trap - EXIT
}

tune() {
  log "quiet boot (extlinux APPEND)"
  local ext="$ROOTFS/boot/extlinux/extlinux.conf"
  if [[ -f $ext ]]; then
    grep -q 'quiet' "$ext" || $SUDO sed -i '/^\s*APPEND/ s/$/ quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0/' "$ext"
    grep -n APPEND "$ext"
  else
    echo "warning: $ext not found; quiet boot not applied"
  fi
}

validate() { log "validate"; $SUDO env WITH_INPUT_MODULES="$WITH_INPUT_MODULES" "$HERE/scripts/validate.sh" "$ROOTFS"; }

package() {
  log "package Linux_for_Tegra"
  mkdir -p "$OUT"
  echo "NOTE: this tarball contains NVIDIA's BSP, your SSH key and your password hash: keep it private."
  cp "$HERE/docs/FLASH.md" "$HERE/flash.sh" "$HERE/scripts/host-prereq-check.sh" "$HERE/scripts/p0-checklist.sh" "$OUT/"
  $SUDO tar --numeric-owner --xattrs --acls -C "$WORK" -I 'zstd -T0 -10' \
    -cf "$OUT/orin-steamos-L4T-r${L4T_RELEASE}.tar.zst" Linux_for_Tegra
  (cd "$OUT" && sha256sum ./*.tar.zst > SHA256SUMS)
  ls -lh "$OUT"
}

done_msg() {
  log "done"
  echo "Flash-ready tree: $L4T"
  echo "steamos sudo password: $OUT/SECRETS.txt (0600, generated by this build, gitignored)"
  echo "Next: put the Orin in Force Recovery, then: sudo ./flash.sh   (docs/FLASH.md)"
}

stage="${1:-all}"
preflight "$stage"
case "$stage" in
  all) fetch; extract; binaries; customize; modules; user; steam; tune; validate; done_msg ;;
  release) fetch; extract; binaries; customize; modules; user; steam; tune; validate; package; done_msg ;;
  fetch|extract|binaries|customize|modules|user|steam|tune|validate|package) "$stage" ;;
  *) die "unknown stage $stage" ;;
esac
