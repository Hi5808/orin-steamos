# Flashing orin-steamos (JetPack 7.2.1 / Jetson Linux r39.2.1) to an Orin Nano 8GB dev kit, NVMe

You do this yourself from your x86_64 laptop.

> **WARNING: flashing WIPES the NVMe SSD.** The flash repartitions `nvme0n1` and writes a new root filesystem over it, and it rewrites the QSPI bootloader on the module. Everything on the NVMe is lost. Back it up first, and make sure only this one Jetson is in recovery mode and connected.

## 0. What you need
- Jetson Orin Nano **8GB Developer Kit** with an NVMe SSD (64 GB or larger) in the M.2 slot.
- Firmware: this flash also writes the QSPI bootloader (the board config's internal layout is `bootloader/generic/cfg/flash_t234_qspi.xml`), so the kit's current firmware version shouldn't matter. If the kit has very old factory firmware and the flash fails, see NVIDIA's [BSP setup guide](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/setup_bsp.html).
- A USB-C **data** cable from the laptop to the dev kit's USB-C port, and a jumper wire.
- About 40 GB free on the laptop.

## 1. Host OS: Ubuntu 26.04 is not a supported flash host. Use a container.
NVIDIA's r39.2.1 Quick Start (Assumptions) requires a "separate Linux (Ubuntu 22.04 or Ubuntu 20.04) host system". 24.04 and 26.04 are not listed (a third-party report of 24.04 working is not verified here). The flash runs in an **Ubuntu 22.04 container** with `--privileged`, host networking (the flash creates a USB network link plus an NFS export) and `/dev` (the USB device re-enumerates during the flash).

NVIDIA does not document this container flow for r39.2. It is the standard community approach, but treat it as **untested here**. If it fails, a 22.04 live USB or VM with USB passthrough is the fallback.

```bash
# on the laptop

sudo tar --numeric-owner --xattrs --acls -I zstd -xpf orin-steamos-L4T-r39.2.1.tar.zst
./host-prereq-check.sh                                     # read-only checks
sudo modprobe nfsd ; sudo modprobe rndis_host ; sudo modprobe cdc_ncm
sudo systemctl stop ModemManager 2>/dev/null || true
# if the host runs its own rpcbind/NFS, stop it during the flash (port 111/2049 clash):
sudo systemctl stop nfs-server rpcbind rpcbind.socket 2>/dev/null || true
```

## 2. Put the Orin Nano into Force Recovery mode
1. Power off and unplug the barrel jack.
2. Jumper **FC REC** to **GND** (button header under the module, pins 9 and 10).
3. Connect USB-C to the laptop, then plug in power.
4. `lsusb | grep 0955:7523` should show the device (7523 = Orin Nano 8GB).
5. Remove the jumper after flashing.

## 3. Flash (inside the container)
```bash
cd /path/to/extracted          # contains Linux_for_Tegra/
docker run --rm -it --privileged --network host \
  -v /dev:/dev -v /dev/bus/usb:/dev/bus/usb -v /run/udev:/run/udev:ro \
  -v /lib/modules:/lib/modules:ro \
  -v "$PWD/Linux_for_Tegra:/Linux_for_Tegra" -w /Linux_for_Tegra \
  ubuntu:22.04 bash
# --- now inside the container ---
apt-get update && apt-get install -y sudo lsb-release kmod
./tools/l4t_flash_prerequisites.sh           # NVIDIA's host packages (nfs-kernel-server, etc.)
service rpcbind start; service nfs-kernel-server start
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
  --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  --network usb0 \
  jetson-orin-nano-devkit-super internal
```
`podman run` takes the same flags (use `sudo podman`).

How this command was checked (against the r39.2.1 tree in this tarball and the r39.2.1 Quick Start):
- NVIDIA's Quick Start line for "Jetson Orin Nano Developer Kit with Super Configuration (NVMe)" is `sudo ./l4t_initrd_flash.sh --erase-all jetson-orin-nano-devkit-super internal`. The short form works because `p3768-0000-p3767-0000-a0.conf`, which `jetson-orin-nano-devkit-super.conf` sources, sets these defaults:
  - `EXTERNAL_DEVICE="nvme0n1p1"`
  - `EXTERNAL_PT_LAYOUT="tools/kernel_flash/flash_l4t_nvme.xml"` (byte-identical to `flash_l4t_t234_nvme.xml`)
  - `INTERNAL_PT_LAYOUT="bootloader/generic/cfg/flash_t234_qspi.xml"`
- The command above spells out those same defaults, so it does exactly the same thing.
- `-p "-c bootloader/generic/cfg/flash_t234_qspi.xml"` is not needed. The script already adds `-c ${INTERNAL_PT_LAYOUT}` (`l4t_initrd_flash_internal.sh`, `generate_flash_package`), and passing it again just duplicates it.
- `--network usb0` is already the default. It's written out here for clarity.
- `--showlogs` is left out. It only applies to `--massflash` and opens a gnome-terminal, which won't work inside a container.
- `jetson-orin-nano-devkit-super` is the right board name: `jetson-orin-nano-devkit-super.conf` exists in the tree, and its Super overlay covers module SKU 0003 and 0005 (the 8GB Orin Nano, USB ID `0955:7523`).
- `--erase-all` ("Erase all storage devices before flashing") is optional, so it's left out. The flash rewrites the NVMe partition table and QSPI anyway. NVIDIA's Quick Start does include it. If a flash fails or the board won't boot because of leftover partitions or old firmware, run the command again with `--erase-all` added before the board name.
- The default T234 external layout assumes 64 GB or more of storage (the APP partition defaults to 57 GiB).
- If UEFI doesn't boot from NVMe on its own, choose the NVMe entry in the UEFI boot menu (NVIDIA's note).

Do **not** re-run `apply_binaries.sh` or `l4t_create_default_user.sh`: the rootfs is already customized and the user already exists.

On a native 22.04 host, skip the container and run the `l4t_initrd_flash.sh` command from `Linux_for_Tegra/`.

## 4. First boot
- The kit boots to a black screen, then SDDM logs in **steamos** automatically and Game Mode starts. On the very first boot it downloads Valve's ARM64 Steam client (public beta) from Valve's CDN, with a "Downloading Steam" progress box, so it needs Ethernet or Wi-Fi.
- No Wi-Fi is set up yet. Use Ethernet for first boot, or set up Wi-Fi from Steam's settings once it's up.
- If the download fails, it falls back to the XFCE desktop. "Return to Game Mode" is on the desktop.
- SSH (key-only): `ssh steamos@orin-steamos.local`. The sudo password is in `SECRETS.txt` from the build. Change it with `passwd`.
- Tailscale is installed but **not logged in and the daemon is disabled**. To opt in: `sudo systemctl enable --now tailscaled && sudo tailscale up`.

## 5. P0 checklist (on the Orin)
```bash
scp p0-checklist.sh steamos@orin-steamos.local:
ssh steamos@orin-steamos.local ./p0-checklist.sh            # add --suspend-test to try sleep/wake
scp steamos@orin-steamos.local:p0-report.txt .
```
The checklist records the release, page size, power mode, `vulkaninfo` with the DXVK/VKD3D extensions, GL, DRM planes, controller kernel modules, uinput, session and Steam state, and suspend support.

## 6. Sessions
| Session | File | Default? |
|---|---|---|
| Steam Game Mode (X11 kiosk, `steam -steamos3 -gamepadui`, restart-on-exit) | `steam-gamemode.desktop` | yes |
| Desktop (XFCE) | `xfce.desktop` | via Steam > Power > Switch to Desktop |
| Steam Game Mode via gamescope (**experimental, P2**) | `steam-gamescope.desktop` | no; try `steamos-session-select steam-gamescope` |

To make gamescope the Game Mode default once it works, set `GAMEMODE_SESSION_FILE="steam-gamescope.desktop"` in `/etc/default/steamos-orin`. If gamescope fails, it drops back to the X11 Game Mode automatically.

## 7. Memory and OOM behavior
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
