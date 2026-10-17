# Building orin-steamos on your own machine (x86_64 Linux)

This repo builds the Orin Nano "SteamOS-style" image: JetPack 7.2.1 / Jetson Linux r39.2.1, Ubuntu 24.04, NVMe, Steam Game Mode.
- It downloads NVIDIA's public BSP and sample rootfs and customizes them in a qemu-aarch64 chroot.
- It leaves a flash-ready `work/Linux_for_Tegra`.
- It never touches a Jetson. Flashing is a separate step (below and FLASH.md).
- No Steam binaries are shipped: Steam downloads itself on the Orin's first boot.

## 1. Host prerequisites
- x86_64 Linux with sudo, and internet access (about 3.1 GB from NVIDIA, plus Ubuntu ports packages from inside the chroot).
- **Disk:**
  - About **16 GB free** in this directory. `build.sh` refuses to start with less (`MIN_FREE_GB` in config.env). Measured: downloads 3.1 GB plus work tree 8.8 GB.
  - `./build.sh release` (which also builds a `.tar.zst`) needs about 4 GB more.
  - Flashing then generates images inside `work/Linux_for_Tegra`. That size hasn't been measured; plan for several GB more.
  - Once the build passes, `sudo rm -rf downloads` frees 3.1 GB.
- **Packages:**
  - **Ubuntu ≤ 24.04:** `sudo apt install qemu-user-static binfmt-support zstd lbzip2 curl openssl python3`
  - **Ubuntu ≥ 25.04 (including 26.04) / Debian 13:** `qemu-user-static` no longer exists. Use `sudo apt install qemu-user qemu-user-binfmt binfmt-support zstd lbzip2 curl openssl python3`. `qemu-user` provides `/usr/bin/qemu-aarch64-static` (a symlink), which is the path NVIDIA's scripts require.
  - Optional, for extra checks in `validate`: `shellcheck nodejs desktop-file-utils`.
- Check: `ls -l /usr/bin/qemu-aarch64-static && cat /proc/sys/fs/binfmt_misc/qemu-aarch64` (it should say `enabled` and include the `F` flag).
- On the original build host (Ubuntu 26.04.1), the required packages above were already installed when checked.

## 2. Build
```bash
cd orin-steamos
sudo ./build.sh            # = fetch, extract, binaries, customize, user, tune, validate
# or: sudo ./build.sh release   # also writes output/orin-steamos-L4T-r39.2.1.tar.zst + SHA256SUMS
```
- Stages can be re-run one at a time: `sudo ./build.sh customize`, `sudo ./build.sh validate`, and so on.
- **Runtime estimate** (from the box build; not measured on the laptop): about 20–40 min plus download time.
  - About 5 min for extract + apply_binaries.
  - About 7 min for the chroot customize (apt under qemu).
  - About 2 min for user, tune and validate.
- **Success looks like:** `validate: 71 passed, 0 failed`, then `==> done`.
- **Outputs:**
  - Flash-ready tree: `work/Linux_for_Tegra/`. You flash from here, so there's no need to package.
  - `SECRETS.txt` (0600, owned by you): the **steamos sudo password**, generated randomly by *your* build. It's never printed or logged (the build log redacts it).
  - `logs/`: nothing is written there unless you redirect output yourself, e.g. `sudo ./build.sh 2>&1 | tee build.log`.
- Settings are in `config.env`: hostname `orin-steamos`, user `steamos`, the SSH public key (key-only login), XFCE desktop, optional gamescope, Tailscale (installed, not logged in).

### Does the build need a container on Ubuntu 26.04?
**Probably not.**
- NVIDIA's `apply_binaries.sh` and `tools/l4t_create_default_user.sh` (r39.2.1) don't check the host Ubuntu version. They only need `/usr/bin/qemu-aarch64-static` and a working aarch64 binfmt.
- `nv_qemu_setup_helper.sh` already works around the known ldconfig problem in qemu ≥ 8.1.1.
- The box build used qemu 10.0 natively; the laptop has qemu 10.2.
- The container is needed only for **flashing** (NVIDIA lists 22.04/20.04 flash hosts).

If the native build fails in apply_binaries or create_user, run the build inside a 22.04 container. The host's binfmt registration (F flag) makes the chroot work inside it:
```bash
cd orin-steamos
sudo docker run --rm -it --privileged \
  -e HOST_QEMU_VERSION="$(qemu-aarch64-static --version | awk '/version/{print $3; exit}')" \
  -v "$PWD:/build" -w /build ubuntu:22.04 bash -c \
  'apt-get update && apt-get install -y qemu-user-static binfmt-support zstd lbzip2 curl openssl python3 sudo ca-certificates && ./build.sh'
sudo chown "$USER:" SECRETS.txt     # inside the container it is created as root
```
`HOST_QEMU_VERSION` is NVIDIA's documented variable: it tells their helper which qemu version the host is running.

## 3. Flash (after a successful build)
Full details, warnings and the recovery-mode steps are in **FLASH.md**. In short:

> **Flashing WIPES the NVMe SSD** and rewrites the QSPI bootloader on the module.

1. `./host-prereq-check.sh` (read-only checks).
2. Put the Orin in Force Recovery: jumper FC REC to GND, connect USB-C, power on. `lsusb | grep 0955:7523` should show it.
3. Host prep (from FLASH.md §1): `sudo modprobe nfsd rndis_host cdc_ncm`; stop ModemManager and any host NFS/rpcbind.
4. Flash from the build tree inside an Ubuntu 22.04 container:
```bash
cd orin-steamos
sudo docker run --rm -it --privileged --network host \
  -v /dev:/dev -v /dev/bus/usb:/dev/bus/usb -v /run/udev:/run/udev:ro -v /lib/modules:/lib/modules:ro \
  -v "$PWD/work/Linux_for_Tegra:/Linux_for_Tegra" -w /Linux_for_Tegra ubuntu:22.04 bash
# inside the container:
apt-get update && apt-get install -y sudo lsb-release kmod
./tools/l4t_flash_prerequisites.sh
service rpcbind start; service nfs-kernel-server start
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml --network usb0 \
  jetson-orin-nano-devkit-super internal
```
   Don't re-run `apply_binaries.sh` or `l4t_create_default_user.sh` before flashing; the build already did both.
5. First boot (Ethernet connected): Game Mode starts and downloads Steam. Then:
   - `ssh steamos@orin-steamos.local`
   - `scp p0-checklist.sh steamos@orin-steamos.local:` and `ssh steamos@orin-steamos.local ./p0-checklist.sh`
   - The sudo password is in `SECRETS.txt`.

## Layout
`build.sh`, `config.env`, `scripts/` (chroot steps, validate, tests, host/P0 checks), `overlay/` (files copied into the rootfs), `FLASH.md`, `output/` (FLASH.md + the host-prereq and P0 scripts).
