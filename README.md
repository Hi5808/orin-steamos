# orin-steamos

A SteamOS-style console OS for the **NVIDIA Jetson Orin Nano 8GB Developer Kit**: power on and land in Steam's Game Mode (Big Picture / gamepad UI), like a Steam Deck, with a desktop one menu away.

It is a set of build scripts, not a disk image. The build downloads NVIDIA's Jetson Linux (JetPack 7.2.1 / L4T r39.2.1, Ubuntu 24.04) from NVIDIA, customizes it in a qemu chroot, and flashes it to the NVMe from an x86_64 Linux PC. Valve's native **ARM64 Steam client** (public beta) comes from Valve's CDN.

> Not affiliated with Valve or NVIDIA. "Steam" and "SteamOS" are trademarks of Valve Corporation; this project only mimics SteamOS's session behaviour.

## Status
Working on real hardware (flashed 2026-10-17): boots to SDDM autologin → Steam Game Mode, SSH (key-only), Wi-Fi/Ethernet, Tailscale (opt-in), earlyoom/zram OOM protection.

| Area | State |
|---|---|
| Boot to Steam Game Mode (gamescope DRM, `steam -steamos3 -gamepadui`) | **default session** (flashed 2026-10-17); under gamescope Xwayland has DRI3 + NVIDIA GLX so CEF Big Picture composites cleanly. X11 kiosk is the oneshot fallback when gamescope can't start |
| gamescope on NVIDIA's display driver (single usable plane) | works with `--force-composition --disable-layers`; exit segfault patched out (Tegra patch) |
| Bluetooth game controllers | works: fallback BlueZ pairing agent + `JustWorksRepairing`/`FastConnectable`; 8BitDo paired and reconnects |
| First-boot setup screen, one-time desktop fallback, session switching | new in this repo, **not yet tested on hardware** |
| Controller modules (uinput, hid-steam/playstation/nintendo/sony) | build-tested, **not yet loaded on hardware** |
| FEX / Proton (x86 games) with NVIDIA's Vulkan driver | works: DX11 (DXVK) and **DX12** (vkd3d-proton, needs `VKD3D_CONFIG=nodxr` — baked in; see docs/KNOWN-ISSUES.md). Ghosts 'n Goblins Resurrection runs. DXR ray-tracing unavailable on this driver |
| Suspend / resume | **untested** (`p0-checklist.sh --suspend-test`) |
| OS updates (A/B, like SteamOS) | not implemented (`steamos-update` is a "no update" stub) |
| Tailscale `xt_connmark` | not available in NVIDIA's kernel (`CONFIG_NF_CONNTRACK_MARK` off); Tailscale works, with a warning |

## Hardware / software
- Jetson Orin Nano **8GB** Developer Kit (Super config, `jetson-orin-nano-devkit-super`), NVMe SSD ≥ 64 GB.
- JetPack **7.2.1** / Jetson Linux **r39.2.1**, kernel 6.8.12-tegra, Ubuntu 24.04 userspace, Vulkan 1.4.
- Build/flash host: x86_64 Linux (built on Ubuntu 26.04; flashing runs in an Ubuntu 22.04 container).

## Quick start
```bash
git clone <this repo> orin-steamos && cd orin-steamos
sudo ./build.sh                       # ~30 min, needs ~16 GB free; see docs/BUILD.md
# Orin in Force Recovery (FC REC jumper), USB-C to this PC:
sudo ./flash.sh                       # WIPES the Orin's NVMe; see docs/FLASH.md
ssh steamos@orin-steamos.local        # key-only; sudo password in output/SECRETS.txt
```

## How it behaves
- **Boot:** SDDM autologins `steamos` into the Game Mode session (Steam restarts if it exits).
- **First boot:** if Steam isn't ready (not installed, or never run and no network), a full-screen setup screen waits for the network, offers Wi-Fi setup, retries the download with backoff and shows progress. It never drops you on the desktop unless you choose it.
- **Switch to Desktop** (Steam power menu) opens XFCE until the next reboot, as on SteamOS; **Return to Gaming Mode** on the desktop goes back. `steamos-session-select desktop` makes the desktop persistent (works over SSH).
- **Crash loop** (5 Steam crashes in 120 s): desktop for that session only.
- **Clock:** the dev kit's RTC resets every cold boot; the image starts at its build date, waits for NTP, and downloads only after the clock is sane.
- **Memory:** zram + NVMe swapfile, earlyoom as the only userspace OOM killer, games preferred as OOM victims over Steam/Xorg/sshd (details in docs/FLASH.md §8).

## Licensing
**Our code** (build scripts, overlay files, docs) is under the MIT License (see `LICENSE`). Third-party components keep their own licenses and are **not** in this repository: the build downloads them from their publishers.

| Component | Where it comes from | Redistribution |
|---|---|---|
| NVIDIA Jetson Linux BSP + sample rootfs | NVIDIA's public download server at build time (sha256-pinned) | NVIDIA's license terms apply to anything you redistribute; this repo ships none of it |
| Linux kernel sources (6 files, for add-on modules) | kernel.org at build time | GPL-2.0 |
| Ubuntu packages, Tailscale | Ubuntu ports / pkgs.tailscale.com at build time | their own licenses |
| **Valve Steam client** | Valve's CDN (`client-update.steamstatic.com`), at build time (`PREINSTALL_STEAM=1`) or on the device's first boot | **do not redistribute** (below) |

**Steam.** The Steam client is Valve software covered by the [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/), which says you may not "copy, reproduce, publish, distribute … any software accessed via Steam without the prior consent, in writing, of Valve". Valve's 2013 Linux redistribution license for the launcher ([steam-for-linux#66](https://github.com/ValveSoftware/steam-for-linux/issues/66), [text](https://lists.debian.org/debian-devel-games/2013/02/msg00028.html)) no longer appears in the current launcher's `COPYING`, so the redistribution right is unclear even for the bootstrap. Distributions handle this by **not shipping Valve's files**:
- Debian's `steam-installer` downloads the proprietary bootstrapper and client on first run and states "We're no longer shipping files under Valve's proprietary license: those are now downloaded on-demand" ([changelog](https://packages.debian.org/changelog:steam-installer), [copyright](https://tracker.debian.org/media/packages/s/steam-installer/copyright-11.0.0.87ds-3)).
- Arch's [`steam`](https://archlinux.org/packages/multilib/x86_64/steam/) package ships Valve's x86 launcher under `LicenseRef-steam-subscriber-agreement`. Arch has had contact with Valve about this; that is not a general permission.
- There is no official ARM64 Steam launcher package at all; our `steam-arm64-install` is our own MIT-licensed downloader that fetches Valve's client from Valve.

So:
- **Building and flashing for yourself** with `PREINSTALL_STEAM=1` (the default) downloads Valve's client from Valve for your own use. That is the same as Steam installing itself.
- **Any image you publish** (release tarball, `.img`, torrent) must be built with **`PREINSTALL_STEAM=0`**. It then contains only our downloader, and each device fetches Steam from Valve on first boot, like Debian's `steam-installer`. It must also not contain your SSH key or a shared password (published images are not supported yet: see TODO).

This is a reading of public terms, not legal advice.

## Repository layout
```
build.sh            build stages (fetch → validate), config.env for settings
flash.sh            flashing wrapper (Ubuntu 22.04 container + host NFS + fixes)
config.env          settings, all overridable from the environment
scripts/            chroot steps, kernel module build, validate + tests, host and P0 checks
overlay/            files copied into the rootfs (sessions, setup screen, polkit, OOM policy, …)
docs/               BUILD.md, FLASH.md, live-board-changes.md
.github/workflows/  CI: shellcheck, unit tests, secrets scan (no image build)
```

## TODO
- Test the new first-boot screen, one-time desktop and controller modules on hardware.
- Suspend/resume. (FEX/Proton DX11+DX12 validated — Ghosts 'n Goblins Resurrection runs.)
- A/B OS updates (RAUC), a real `steamos-update`.
- Published images: first-boot SSH key / password setup instead of build-time secrets.
- Gamepad navigation for the setup screen (it needs a keyboard or mouse today).
