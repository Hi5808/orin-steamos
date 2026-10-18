#!/bin/bash
# Runs INSIDE the chroot after the overlay is copied: enable services, set hostname.
set -euo pipefail
: "${HOSTNAME_TARGET:=orin-steamos}"
systemctl enable ssh.service avahi-daemon.service sddm.service \
  steamos-orin-firstboot.service steamos-orin-maxn-super.service steamos-orin-session-reset.service \
  steamos-orin-bt-agent.service \
  earlyoom.service steamos-orin-oom-tagger.service \
  steamos-orin-swapfile.service var-swap-swapfile.swap \
  systemd-timesyncd.service systemd-time-wait-sync.service
# The dev kit RTC starts at 1970 on every cold boot. timesyncd moves the clock forward to
# the mtime of this file at boot, so the image never starts earlier than its build time.
if getent passwd systemd-timesync >/dev/null; then
  install -d -o systemd-timesync -g systemd-timesync /var/lib/systemd/timesync
  touch /var/lib/systemd/timesync/clock
  chown systemd-timesync:systemd-timesync /var/lib/systemd/timesync/clock
fi
echo "$HOSTNAME_TARGET" > /etc/hostname
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t$HOSTNAME_TARGET/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$HOSTNAME_TARGET" >> /etc/hosts
fi
# mDNS resolution for *.local
grep -q mdns4_minimal /etc/nsswitch.conf || \
  sed -i 's/^hosts:.*/hosts:          files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
