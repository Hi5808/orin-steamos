#!/bin/bash
# Runs INSIDE the aarch64 rootfs (qemu-user chroot). Installs the SteamOS-style
# Game Mode stack on top of NVIDIA's Ubuntu 24.04 sample rootfs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
: "${DESKTOP:=xfce}" "${WITH_GAMESCOPE:=1}" "${WITH_TAILSCALE:=1}" "${PURGE_DESKTOP_EXTRAS:=1}"

# Don't start daemons inside the chroot
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

echo "sddm shared/default-x-display-manager select sddm" | debconf-set-selections
echo "gdm3 shared/default-x-display-manager select sddm" | debconf-set-selections

# Use HTTPS for the Ubuntu ports mirror (also works on networks that block plain HTTP)
sed -i 's#http://ports.ubuntu.com#https://ports.ubuntu.com#g' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
pkgs=(
  sddm xserver-xorg-core xinit x11-xserver-utils openbox unclutter zenity
  curl ca-certificates unzip jq pkexec polkitd
  openssh-server avahi-daemon libnss-mdns
  steam-devices vulkan-tools mesa-utils
  libgtk2.0-0t64 libvdpau1 libvpx9 ibus libxtst6 libnm0 libgl1 libegl1
  pipewire pipewire-pulse wireplumber bluez python3-dbus python3-gi
  systemd-zram-generator earlyoom systemd-timesyncd
)
[[ $DESKTOP == xfce ]] && pkgs+=(xfce4 xfce4-terminal thunar)
# gamescope: Ubuntu noble has no arm64 gamescope package; it is built on the device
# by /usr/lib/steamos-orin/build-gamescope (P2). Pre-install its runtime helpers here.
[[ $WITH_GAMESCOPE == 1 ]] && pkgs+=(xwayland git)
apt-get install -y --no-install-recommends "${pkgs[@]}"

if [[ $WITH_TAILSCALE == 1 ]]; then
  # Installed only. Not logged in, no auth key, daemon disabled until the user opts in.
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
  apt-get update
  apt-get install -y tailscale
  systemctl disable tailscaled.service || true
fi

# SDDM replaces GDM as the display manager
echo /usr/bin/sddm > /etc/X11/default-display-manager
systemctl disable gdm3.service gdm.service 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service
systemctl set-default graphical.target

# --- Bluetooth controllers (SteamOS-style) ---
# seatd is pulled in by the gamescope build deps but we use logind seats; its presence makes
# gamescope pick the libseat seatd backend and fight logind. Disable it (bt-fix 2026-10-17).
systemctl disable seatd.service 2>/dev/null || true
# BlueZ main.conf tuning for game controllers (applied live in round3 2026-10-17):
#   JustWorksRepairing=always  - controllers re-pair without a PIN prompt
#   FastConnectable=true        - quicker reconnect of bonded controllers
#   ConnectionSupervisionTimeout=400 - tolerate the RTL8822CE Wi-Fi/BT coexistence stalls
if [[ -f /etc/bluetooth/main.conf ]]; then
  sed -i -E \
    -e 's/^#?[[:space:]]*JustWorksRepairing[[:space:]]*=.*/JustWorksRepairing = always/' \
    -e 's/^#?[[:space:]]*FastConnectable[[:space:]]*=.*/FastConnectable = true/' \
    -e 's/^#?[[:space:]]*ConnectionSupervisionTimeout[[:space:]]*=.*/ConnectionSupervisionTimeout=400/' \
    /etc/bluetooth/main.conf
  grep -q '^JustWorksRepairing'   /etc/bluetooth/main.conf || printf '\n[General]\nJustWorksRepairing = always\nFastConnectable = true\n' >> /etc/bluetooth/main.conf
fi

# Steam wants libvpx.so.6 on some builds; noble ships .so.9 (community-installer workaround)
if [[ -e /usr/lib/aarch64-linux-gnu/libvpx.so.9 && ! -e /usr/lib/aarch64-linux-gnu/libvpx.so.6 ]]; then
  ln -s libvpx.so.9 /usr/lib/aarch64-linux-gnu/libvpx.so.6
fi

# zram: prefer systemd-zram-generator; disable NVIDIA's nvzramconfig if present to avoid double swap
if systemctl list-unit-files nvzramconfig.service >/dev/null 2>&1; then
  systemctl disable nvzramconfig.service 2>/dev/null || true
fi

# OOM: earlyoom is the single userspace OOM killer. Mask systemd-oomd so two killers
# don't act on the same pressure event (see /etc/default/earlyoom for the reasoning).
systemctl disable systemd-oomd.service systemd-oomd.socket 2>/dev/null || true
systemctl mask systemd-oomd.service systemd-oomd.socket

# --- Image cleanups (deep scan 2026-10-17) ---
# NVIDIA's nvidia-l4t-firstboot creates a 2 GiB /swapfile (priority -2) and an fstab line at
# first boot. We already have zram + /var/swap/swapfile, so keep it from ever running.
# The unit is a dpkg conffile in /etc/systemd/system, so it can't be masked: disable it and
# add a drop-in condition that is never true (survives package upgrades re-enabling it).
systemctl disable nvfb-swapfile.service 2>/dev/null || true
install -d /etc/systemd/system/nvfb-swapfile.service.d
printf '# orin-steamos: zram + /var/swap/swapfile replace NVIDIA'"'"'s 2 GiB /swapfile\n[Unit]\nConditionPathExists=/etc/steamos-orin/enable-nvfb-swapfile\n' \
  > /etc/systemd/system/nvfb-swapfile.service.d/10-steamos-orin-disable.conf
sed -i '\#^/swapfile[[:space:]]#d' /etc/fstab; rm -f /swapfile
# Services a game console does not need listening on the network
systemctl mask iperf3.service saned.socket saned.service 2>/dev/null || true
# NetworkManager owns networking; networkd-wait-online only times out (90 s) at boot
systemctl mask systemd-networkd-wait-online.service
# netplan warns when its files are world-readable
chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
# apport: Ubuntu's crash reporter pops a GTK "System program problem detected" dialog on the
# next session for any crash file in /var/crash (e.g. a one-off gamescope crash), which is noise
# on a console. overlay/etc/default/apport sets enabled=0; also disable the service and clear any
# crash files baked/leftover in the image so a fresh flash never shows the dialog.
systemctl disable apport.service 2>/dev/null || true
rm -f /var/crash/*.crash /var/crash/*.upload* 2>/dev/null || true
# Desktop extras that only cost RAM / boot time here
if [[ ${PURGE_DESKTOP_EXTRAS:-1} == 1 ]]; then
  # xdg-desktop-portal-{gnome,gtk}: on a gamescope console XDG_CURRENT_DESKTOP is not GNOME,
  # so xdg-desktop-portal falls back to the GTK backend, which hangs on D-Bus activation and
  # times out — leaving the user session `degraded`. A gamescope kiosk needs no desktop portal
  # backend (the base xdg-desktop-portal then answers immediately). Drop them like SteamOS does.
  for p in snapd gnome-remote-desktop deja-dup xdg-desktop-portal-gnome xdg-desktop-portal-gtk; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' && { apt-get purge -y "$p" || echo "warning: could not purge $p"; }
  done
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd
fi

# Real browser for Desktop Mode. Ubuntu's /usr/bin/firefox is only a snap
# transitional wrapper (deb `firefox 1:1snap1`) that execs /snap/bin/firefox;
# with snapd purged above it is a dead end ("requires the firefox snap"), so
# the desktop ships no working browser. Install Firefox from Mozilla's own APT
# repo (a real .deb) and pin it above the snap stub so it is never replaced.
if [[ ${WITH_FIREFOX_DEB:-1} == 1 ]]; then
  install -d -m0755 /etc/apt/keyrings
  if curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc; then
    echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' \
      > /etc/apt/sources.list.d/mozilla.list
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
      > /etc/apt/preferences.d/mozilla
    apt-get purge -y firefox 2>/dev/null || true   # drop the snap transitional stub
    apt-get update
    apt-get install -y --no-install-recommends firefox \
      || echo "warning: Firefox (Mozilla deb) install failed; desktop will have no browser"
  else
    echo "warning: could not fetch Mozilla APT signing key; skipping Firefox deb"
  fi
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /usr/sbin/policy-rc.d
