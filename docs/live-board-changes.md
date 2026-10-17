# Live-board changes (hotfixes applied to the running Orin)

Changes made by hand on the first flashed board (image built 2026-10-16, flashed 2026-10-17), and where each one stands in this repo. Board-specific items (network profiles, accounts) are recorded without addresses, SSIDs or keys.

Times are Pacific/Honolulu (HST). Backups were kept on the board with the suffix `.bak-20261017`.

| # | Change on the board | In the repo |
|---|---|---|
| 1 | `steam-arm64-install`: removed `ln -sfn "$STEAMROOT/steamrtarm64" "$STEAMROOT/steamrt64"`. The ARM64 update ships a real `steamrt64/` (x86-64), so the alias let x86-64 files overwrite arm64 ones; the bootstrapper looped in `BVerifyInstalledFiles` with no UI. | Fixed: commit "steam-arm64-install: stop aliasing steamrt64…" (also removes an old alias) |
| 2 | `~/.local/share/Steam` moved to `Steam.broken-20261017` (1,061 x86-64 files found inside `steamrtarm64/`) and Steam re-bootstrapped clean. | One-time repair of a board built with the bug; fresh builds don't need it. The broken copy can be deleted once Steam works. |
| 3 | Enabled `systemd-timesyncd` and `systemd-time-wait-sync` (RTC resets to 1970 every boot). | Fixed: commit "Set the clock before downloading…" (also seeds the clock file and orders first boot after `time-sync.target`) |
| 4 | Disabled `iperf3.service` and `saned.socket`. | Fixed (masked at build): commit "Image cleanups…" |
| 5 | Removed the stray 2 GiB `/swapfile` and its fstab line (backup `fstab.bak-20261017`). It comes from NVIDIA's `nvfb-swapfile.service` (nvidia-l4t-firstboot). | Fixed (service masked, file and line removed at build): commit "Image cleanups…" |
| 6 | `/etc/default/steamos-orin`: `STEAM_EXTRA_ARGS="-cef-disable-gpu-compositing"` for the black Big Picture screen (steamwebhelper `GLXBadPixmap`/`BadDrawable`, "dri3 extension not supported", Xorg "No path to DRM device" on nvgpu). | Repo default: commit "Default Steam to -cef-disable-gpu-compositing…". **Pending on-screen confirmation**; revert that commit if it doesn't help. |
| 7 | NetworkManager profiles added: a static profile for a direct Ethernet link to the build laptop (laptop shares its Wi-Fi via NAT) and the home Wi-Fi profile. | Board-specific: **not** in the image defaults. Wi-Fi is set up per device from Steam's settings or the first-boot screen. |
| 8 | Tailscale logged in (`tailscaled` enabled, node `orin-steamos`). | Board-specific: images ship Tailscale installed, **not** logged in, daemon disabled. |

## Board vs. repo differences still open
- The board has the old first-boot/session scripts (sticky-desktop bug, no setup screen), no `uinput`/HID add-on modules, and no updater stubs. Reflash with a new build to get them, or copy the changed overlay files by hand.
- systemd-networkd-wait-online, netplan permissions and snapd/gnome-remote-desktop/deja-dup are cleaned up in new builds only.
