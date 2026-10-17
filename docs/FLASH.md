# Flashing orin-steamos to a Jetson Orin Nano 8GB dev kit (NVMe)

> **WARNING: flashing WIPES the NVMe SSD** (repartitioned, new root filesystem) and rewrites the QSPI bootloader on the module. Back up first, and have only one Jetson in recovery mode.

## 0. What you need
- Jetson Orin Nano **8GB Developer Kit**, NVMe SSD (64 GB or larger) in the M.2 slot.
- An x86_64 Linux host with Docker and about 15 GB free next to the build tree (image generation).
- A USB-C **data** cable from the host to the dev kit, and a jumper wire.
- A tree built with `./build.sh` (see [BUILD.md](BUILD.md)).

## 1. Put the Orin Nano into Force Recovery mode
1. Power off and unplug the barrel jack.
2. Jumper **FC REC** to **GND** (button header under the module, pins 9 and 10).
3. Connect USB-C to the host, then plug in power.
4. `lsusb | grep 0955:7523` shows the device (7523 = Orin Nano 8GB in recovery).

## 2. Flash (recommended: the wrapper)
```bash
./scripts/host-prereq-check.sh          # read-only checks
sudo ./flash.sh                          # first flash: generates images, then flashes
sudo ./flash.sh --flash-only             # retry with the images from the previous run
```
`flash.sh` does everything in section 3 for you, logs to `output/flash-*.log`, and removes the NFS export when it exits. Success ends with `Flash is successful`; the board then reboots into the new OS by itself. **Remove the FC REC jumper** afterwards.

Host packages: `docker.io` (or Docker CE), `nfs-kernel-server`, `usbutils`.

## 3. What the wrapper does, and why (lessons from the first flash)
NVIDIA's r39.2.1 Quick Start lists only Ubuntu 22.04/20.04 as flash hosts, and initrd flashing is fragile on anything else. These are the steps that made it work from an Ubuntu 26.04 host:

1. **Ubuntu 22.04 container** with `--privileged --network host -e USER=root`, `/dev`, `/run/udev` and `/lib/modules` mounted, and the `Linux_for_Tegra` tree mounted **at the same absolute path** as on the host (NVIDIA's script prints and NFS-mounts host paths). `USER=root` is needed because the scripts check `$USER`.
2. **NetworkManager must leave the Jetson's USB network alone.** During initrd flashing the device comes up as a USB NCM network (host `fc00:1:1::1`, device `fc00:1:1::2`). NetworkManager otherwise grabs the new interface and removes the address mid-flash, and the device can't reach the host. Fix (installed by `flash.sh`):
   ```
   # /etc/udev/rules.d/99-jetson-nm-unmanaged.rules
   SUBSYSTEM=="net", ACTION=="add|change", ATTRS{idVendor}=="0955", ENV{NM_UNMANAGED}="1"
   ```
   The same rule also stops NM from bringing up the board's normal USB network (`192.168.55.1`) later; delete the rule if you want that.
3. **Serve the images from the host's NFS server, exported to the device's exact address.** With `/run/nvidia_initrd_flash/docker_host_network` present, NVIDIA's script expects the host to export `tools/kernel_flash/images`. A subnet export (`[fc00:1:1::/48]`) was refused; exporting to the device's address works:
   ```bash
   sudo exportfs -o rw,nohide,insecure,no_subtree_check,async,no_root_squash "[fc00:1:1::2]:$PWD/work/Linux_for_Tegra/tools/kernel_flash/images"
   sudo exportfs -f
   ```
4. **The critical one: stop NVIDIA's script from starting NFS inside the container.** `l4t_network_flash.func` runs `rpcbind` and `service nfs-kernel-server restart`. In a `--network host` container that stops the host's kernel nfsd threads and starts a second `rpc.mountd` that only knows the container's (empty) `/etc/exports`, so it **refuses the device** and the flash sits at "Waiting for target to boot-up" or fails to mount. `flash.sh` puts no-op `service`/`rpcbind` shims first in the container's PATH, kills any container `rpc.mountd`, and keeps killing it for the duration of the flash.
5. The flash command itself (inside the container, from `Linux_for_Tegra/`):
   ```bash
   ./tools/kernel_flash/l4t_initrd_flash.sh [--flash-only] --external-device nvme0n1p1 \
     -c tools/kernel_flash/flash_l4t_t234_nvme.xml --network usb0 jetson-orin-nano-devkit-super internal
   ```
   This spells out the defaults that `jetson-orin-nano-devkit-super.conf` (via `p3768-0000-p3767-0000-a0.conf`) already sets. NVIDIA's Quick Start adds `--erase-all`; use `flash.sh --erase-all` if leftover partitions or old firmware cause trouble.
6. Do **not** re-run `apply_binaries.sh` or `l4t_create_default_user.sh`: the build already did both.

## 4. Manual flash (if you can't use the wrapper)
Follow section 3 step by step: install the udev rule, `sudo modprobe nfsd rndis_host cdc_ether cdc_ncm`, `sudo systemctl stop ModemManager`, start the host's `nfs-server`, export the images directory to `[fc00:1:1::2]` (create it first), start the container, run `./tools/l4t_flash_prerequisites.sh`, create the marker file, shim or kill the container's `rpc.mountd`, then run the command in step 5. Remove the export afterwards: `sudo exportfs -u "[fc00:1:1::2]:<images dir>"`.

## 5. First boot
- The kit boots to a black screen, then SDDM logs **steamos** in automatically and Game Mode starts. The dev kit's RTC resets on every cold boot; the image moves the clock to its build date and waits (up to 3 min) for NTP.
- **PREINSTALL_STEAM=1 (default for your own builds):** Steam's ARM64 client bootstrap is already in the image. Steam still needs the internet once, for its first self-update (about 300 MB) and to sign in.
- **PREINSTALL_STEAM=0:** first boot downloads the client bootstrap (about 105 MB) from Valve's CDN.
- Either way, if Steam can't be made ready you get a **full-screen setup screen**, not the desktop: it waits for a network (Ethernet works automatically), offers *Set up Wi-Fi* (`nmtui-connect`; needs a keyboard), retries the download with backoff, and lets you *Use the desktop this time* (one session only) or power off.
- SSH (key-only): `ssh steamos@orin-steamos.local`. The sudo password is in `output/SECRETS.txt` from your build; change it with `passwd`.
- Tailscale is installed but **not logged in and the daemon is disabled**. To opt in: `sudo systemctl enable --now tailscaled && sudo tailscale up`.

## 6. P0 checklist (on the Orin)
```bash
scp scripts/p0-checklist.sh steamos@orin-steamos.local:
ssh steamos@orin-steamos.local ./p0-checklist.sh            # add --suspend-test to try sleep/wake
scp steamos@orin-steamos.local:p0-report.txt .
```
The checklist records the release, page size, power mode, `vulkaninfo` with the DXVK/VKD3D extensions, GL, DRM planes, controller kernel modules, uinput, session and Steam state, and suspend support.

## 7. Sessions
| Session | File | Default? |
|---|---|---|
| Steam Game Mode (X11 kiosk, `steam -steamos3 -gamepadui`, restart-on-exit) | `steam-gamemode.desktop` | yes |
| Desktop (XFCE) | `xfce.desktop` | via Steam > Power > Switch to Desktop |
| Steam Game Mode via gamescope (**experimental, P2**) | `steam-gamescope.desktop` | no; try `steamos-session-select steam-gamescope` |

To make gamescope the Game Mode default once it works, set `GAMEMODE_SESSION_FILE="steam-gamescope.desktop"` in `/etc/default/steamos-orin`. If gamescope fails, it drops back to the X11 Game Mode automatically.

- Steam's *Switch to Desktop* runs `steamos-session-select plasma`: the desktop for now, Game Mode again after the next reboot (as on SteamOS). *Return to Gaming Mode* on the desktop goes back immediately.
- `steamos-session-select desktop` (or `plasma-persistent`) makes the desktop the boot session until you choose Game Mode again. It works from SSH too.
- If Steam crashes 5 times within 120 s, the desktop opens **for that session only**.

## 8. Memory and OOM behavior
- **Swap:**
  - zram (half of RAM, zstd, priority 100) is used first.
  - A **4 GiB NVMe swapfile** `/var/swap/swapfile` (priority 10) is created on first boot. It is not in the image, and it's skipped if less than 6 GiB is free.
- **Sysctl** (`/etc/sysctl.d/99-steamos-orin-memory.conf`): `vm.swappiness=180`, `page-cluster=0`, `watermark_scale_factor=125`, `watermark_boost_factor=0`, `min_free_kbytes=65536`.
- **OOM killer: earlyoom only.** `systemd-oomd` is masked. Steam starts games inside its own cgroup, and oomd kills whole cgroups, so it would take Steam or the session down with the game. earlyoom kills one process:
  - It prefers games (wine, `*.exe`, FEX) and `steamwebhelper`.
  - It avoids Xorg, gamescope, steam, sddm, sshd, systemd, pipewire and NetworkManager.
  - Thresholds are in `/etc/default/earlyoom`: 6%/15% for SIGTERM, 3%/5% for SIGKILL. These are starting values.
- **oom_score_adj** (the kernel OOM killer is the last resort):
  - sshd -900; sddm and Xorg -500.
  - `steamos-orin-oom-tagger` sets gamescope -500, steam -200, steamwebhelper +300 and games +500. Games are detected by name or by `SteamAppId`/`SteamGameId` in their environment, and processes are rescanned every 3 s.
  - Optional per-game launch option: `steamos-game-oom %command%` applies +500 right away.
- **Logs:** the journal is persistent. The P0 checklist reports kernel OOM kills and earlyoom kills from all boots. To check by hand: `journalctl -k | grep -i oom` and `journalctl -u earlyoom`.
