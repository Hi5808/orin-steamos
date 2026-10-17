#!/bin/bash
# Runs INSIDE the aarch64 rootfs (qemu-user chroot). Installs the SteamOS-style
# Game Mode stack on top of NVIDIA's Ubuntu 24.04 sample rootfs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
: "${DESKTOP:=xfce}" "${WITH_GAMESCOPE:=1}" "${WITH_TAILSCALE:=1}"

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
  pipewire pipewire-pulse wireplumber bluez
  systemd-zram-generator earlyoom
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

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /usr/sbin/policy-rc.d
