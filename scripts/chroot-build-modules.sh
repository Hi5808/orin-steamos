#!/bin/bash
# Runs INSIDE the aarch64 rootfs (qemu-user chroot). Builds controller/input kernel
# modules that NVIDIA's r39.2.1 kernel (6.8.12-*-tegra) does not enable:
#   uinput (Steam Input virtual controllers), hid-steam, hid-playstation, hid-nintendo, hid-sony.
# Sources: upstream linux-$KSRC_VERSION files copied to /tmp/kmod-src by build.sh, compiled
# against the rootfs's own kernel headers (nvidia-l4t-kernel-headers) with the rootfs gcc.
# xt_connmark is NOT built: it needs CONFIG_NF_CONNTRACK_MARK in the core nf_conntrack
# module, which this kernel does not enable (an add-on module cannot change that).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
SRC=/tmp/kmod-src
KREL="$(find /lib/modules -mindepth 1 -maxdepth 1 -printf "%f\n" | sort -V | tail -1)"
KDIR="/lib/modules/$KREL/build"
[[ -e $KDIR/Makefile ]] || { echo "kernel headers for $KREL not found at $KDIR" >&2; exit 1; }
gccver="$(sed -n 's/^CONFIG_GCC_VERSION=\([0-9][0-9]\)[0-9]\{4\}$/\1/p' "$KDIR/.config" | head -1)"
gccver="${gccver:-13}"

printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
# Toolchain matching the one the kernel was built with (CONFIG_CC_VERSION_TEXT); removed afterwards.
tool_pkgs=(make "gcc-$gccver" libc6-dev)
newly=()
for p in "${tool_pkgs[@]}"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || newly+=("$p"); done
if ((${#newly[@]})); then apt-get update; apt-get install -y --no-install-recommends "${newly[@]}"; fi

cd "$SRC"
cat > Kbuild <<'KB'
obj-m := drivers/input/misc/uinput.o drivers/hid/hid-steam.o drivers/hid/hid-playstation.o \
         drivers/hid/hid-nintendo.o drivers/hid/hid-sony.o
KB
make -C "$KDIR" M="$SRC" CC="gcc-$gccver" modules
dest="/lib/modules/$KREL/updates/steamos-orin"
install -d "$dest"
install -m644 drivers/input/misc/*.ko drivers/hid/*.ko "$dest/"
depmod -a "$KREL"
for m in uinput hid-steam hid-playstation hid-nintendo hid-sony; do
  modinfo -k "$KREL" -F vermagic "$m" | grep -q "^$KREL " || { echo "vermagic mismatch for $m" >&2; exit 1; }
done
echo "built: $(find "$dest" -name "*.ko" -printf "%f " ) for $KREL"

if ((${#newly[@]})); then apt-get purge -y --auto-remove "${newly[@]}"; apt-get clean; rm -rf /var/lib/apt/lists/*; fi
rm -f /usr/sbin/policy-rc.d
