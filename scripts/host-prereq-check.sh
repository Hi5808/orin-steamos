#!/bin/bash
# Run on the x86_64 FLASH HOST (your laptop) before flashing. Read-only checks.
set -uo pipefail
warn=0; fail=0
ok()   { echo "OK    $*"; }
wa()   { echo "WARN  $*"; warn=$((warn+1)); }
no()   { echo "FAIL  $*"; fail=$((fail+1)); }

if [[ $(uname -m) == x86_64 ]]; then ok "x86_64 host"; else no "host must be x86_64 (is $(uname -m))"; fi
. /etc/os-release 2>/dev/null || true
case "${VERSION_ID:-}" in
  20.04|22.04) ok "Ubuntu $VERSION_ID: listed by NVIDIA r39.2 Quick Start -> flash natively" ;;
  24.04)       wa "Ubuntu 24.04: flashing reported OK by Seeed for JP7.2, not in NVIDIA's Quick Start -> container recommended" ;;
  *)           wa "Ubuntu ${VERSION_ID:-unknown}: NOT a supported flash host -> use the Ubuntu 22.04 container flow in FLASH.md" ;;
esac
if command -v docker >/dev/null; then ok "docker: $(docker --version)"
elif command -v podman >/dev/null; then ok "podman: $(podman --version)"
else wa "neither docker nor podman installed (needed for the container flow)"; fi
free_gb=$(df -BG --output=avail . | tail -1 | tr -dc 0-9)
# Flash image generation needs extra space beyond the tree (not measured; estimate ~10G)
if (( free_gb >= 15 )); then ok "free space ${free_gb}G"
elif (( free_gb >= 8 )); then wa "only ${free_gb}G free; flash image generation may run out (aim for >=15G; delete downloads/ after the build)"
else no "need >=8G free here for flash images, have ${free_gb}G"; fi
for m in nfsd rndis_host cdc_ether cdc_ncm; do
  if lsmod | grep -qw "$m" || modinfo "$m" >/dev/null 2>&1; then ok "kernel module available: $m"
  else no "kernel module missing: $m (initrd flash needs NFS server + USB networking)"; fi
done
if lsusb 2>/dev/null | grep -qi '0955:7523'; then ok "Orin Nano 8GB in recovery mode detected (0955:7523)"
elif lsusb 2>/dev/null | grep -qi '0955:'; then wa "NVIDIA USB device present but not 0955:7523: $(lsusb | grep -i 0955:)"
else wa "no Jetson in recovery mode detected (connect USB-C, jumper FC REC to GND, power on)"; fi
if command -v ip >/dev/null && sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q 1; then
  no "IPv6 disabled; l4t_initrd_flash needs IPv6 on the USB link"
else ok "IPv6 not globally disabled"; fi
systemctl is-active --quiet ModemManager 2>/dev/null && wa "ModemManager running; it can grab the USB link (sudo systemctl stop ModemManager)"
command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active' && wa "ufw active; allow NFS/SSH on usb0 or disable during flash"
echo; echo "host-prereq-check: $fail fail, $warn warn"
[[ $fail -eq 0 ]]
