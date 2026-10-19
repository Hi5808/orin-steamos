# Known issues

## Steam Big-Picture UI flickers to black (menu dim + screensaver) — NVIDIA display-engine (DCE) scanout bug

**Status:** open, no software fix found on-device. Cosmetic: only the idle screensaver and the
menu backdrop. Games and gameplay are unaffected.

**Symptom.** In the gamescope Game Mode session, *animated* Steam Big Picture UI flickers hard
to black: the quick-access menu's background dim/blur, and the idle/screensaver game-art
slideshow. The screen rapidly alternates between the correct frame and black. Static screens
(the Big Picture home) are perfect. **Games are unaffected.** Not the monitor (reproduced on two
displays; HP w2207, DP-1, 1680x1050@59.85, 60 Hz, no VRR). Steam Settings has a **test
screensaver** mode that triggers it on demand.

**Where it actually is: scanout / the NVIDIA display engine — not the compositor or Steam.**
The decisive observation (2026-10-18): `gamescopectl screenshot` dumps gamescope's *composited
buffer*, and with the right tweak that buffer is **clean** (see below) — yet the physical
monitor still flickers to black. So the bad black frames are introduced **after** gamescope
composites, at **DRM scanout to the display**. The kernel log confirms a sick display path:
hundreds of

```
NVRM: GPU0 rpcRmApiControl_dce: NVRM_RPC_DCE: Failed RM ctrl call cmd:0x731341 result 0xffff: Generic Error
```

`DCE` is the Orin's **Display Control Engine** (the microcontroller that drives the display);
its RM control calls (cmd `0x731341`) fail repeatedly. This is why **games are fine but the UI
is not**: gamescope *direct-scans-out* a fullscreen game's buffer, but it *composites* the UI
and flips its own composite buffer — and it is that composited-output flip to the display engine
that glitches. Forcing a non-native output mode (1280x1024) produced **no video at all**,
further pointing at the display/mode driver.

**Ruled out (none changed the on-screen flicker), 2026-10-18:**

- Steam CEF: `-cef-disable-xcomposite-workaround`, `-cef-use-vulkan` (froze the session),
  raw Chromium flags via `steamwebhelper.sh` (`--ui-disable-partial-swap`,
  `--disable-gpu-rasterization`, `--disable-gpu-vsync`, `--disable-frame-rate-limit`,
  `--disable-gpu-driver-bug-workarounds`). `-cef-disable-gpu-compositing` CPU-composites the
  whole UI (sluggish) and is not a fix.
- NVIDIA GL buffering: `__GL_MaxFramesAllowed=1` on steamwebhelper **made gamescope's composite
  buffer clean** (0 black frames in `gamescopectl screenshot` vs ~7/10 before) but did **not**
  stop the on-screen flicker — proving the flicker is downstream of the composite.
- gamescope compositing: `composite_force 1`, `drm_single_plane_optimizations 0`.
- gamescope present/flip: `drm_debug_syncobj_force_wait_on_commit`, `drm_debug_disable_in_fence_fd`,
  `drm_debug_disable_explicit_sync`, `tearing_enabled 1` (immediate flips), `debug_set_fps_limit 30`,
  larger draw-buffer redzone (rebuilt gamescope, 5 ms), nudge-thread wakeups
  (`GAMESCOPE_DISABLE_TIMERFD=1`).
- gamescope DRM colour pipeline: disabled all of CTM / degamma / regamma / output-TF / blend-TF /
  colour-encoding / colour-range (`drm_debug_disable_*`).

**Conclusion.** An NVIDIA Jetson Orin **display-driver / DCE bug** in JetPack 7.2.1 (L4T r39.2.1)
that corrupts gamescope's composited-output scanout to black during continuous updates. Not
fixable from user space / our image.

### Realistic next steps

1. Re-test on the next JetPack / L4T release (display-engine/DCE firmware fix).
2. File with NVIDIA (Jetson forums) with this evidence: clean composite buffer, black on
   scanout, `rpcRmApiControl_dce` cmd `0x731341` failures flooding dmesg, games unaffected,
   non-native modes give no video.
3. Try other displays / a real DP or HDMI sink and other EDID-preferred modes (one monitor
   already reproduced it; more data helps the bug report).
4. Workaround for daily use: disable Steam's screensaver so the most visible instance never
   runs; the menu-backdrop flicker remains but is brief.

Reproduce: Steam Settings → test screensaver. Capturing `gamescopectl screenshot` shows a
*clean* composite (so capture never matches the flickering display — the tell that it is scanout,
not compositing). Watch `dmesg | grep rpcRmApiControl_dce` grow.

## DirectX 12 games fail to create a device — FIXED with a vkd3d-proton config

**Status: FIXED (2026-10-18)** in the image default (`overlay/etc/default/steamos-orin`).

**Symptom.** A DX12 game launches through Proton 11 (ARM64) — FEX runs the x86-64 code, the prefix
sets up, wineserver/winedevice start — then the renderer dies with a dialog like
`D3D12CreateDeviceFailed / Please restart your computer` (seen in Ghosts 'n Goblins Resurrection,
`renderdevicedx12.cpp`). vkd3d-proton 3.0's `vkCreateDevice` returns
`VK_ERROR_INITIALIZATION_FAILED (-3)`, even though `vulkaninfo` reports every feature present.

**Root cause.** The Orin Tegra Vulkan driver (595.78) **advertises cooperative-matrix /
ray-tracing / optical-flow capabilities it cannot actually enable** — a Vulkan-spec violation
(`vkCreateDevice` MUST NOT return `INITIALIZATION_FAILED` for features it reports as supported).
The log tell is `vkd3d_supports_minimum_coopmat_caps: Missing sufficient features to expose WMMA`.
Same class of bug as the desktop RTX 50-series coopmat issue (vkd3d-proton #3076). vkd3d's own
retry (stripping NVX extensions) isn't enough because ray-tracing is still enabled.

**Fix.** Drop ray-tracing and the offending NV extensions from vkd3d's device request:

```sh
VKD3D_CONFIG=nodxr
VKD3D_DISABLE_EXTENSIONS=VK_NV_optical_flow,VK_NVX_binary_import,VK_NVX_image_view_handle
```

These are exported session-wide in `overlay/etc/default/steamos-orin`, so **all** DX12 games get
them. They affect only vkd3d (DX12); DXVK (DX11) and native games are untouched. Verified:
Ghosts 'n Goblins Resurrection (appid 1375400) boots to its intro and runs **in DirectX 12**.
(We lose DXR ray-tracing, which the Tegra driver can't do here anyway.)

**Fallback: force DirectX 11** (if a specific DX12 game still misbehaves). RE Engine titles keep
the API in `steamapps/common/<game>/config.ini` (`Capability`/`TargetPlatform` = `DirectX11`);
the game and **Steam Cloud** re-sync it to DirectX12 on launch, so lock it with
`sudo chattr +i <that config.ini>`. D3D11 goes through DXVK, which always worked here.

Re-test the DXR path (drop `nodxr`) on JetPack updates; include the coopmat/optical-flow
advertisement bug in the NVIDIA report (see `NVIDIA-BUG-REPORT.md`, `BLACK-SCREEN-LOG.md`).

## gamescope aborts on session restart/switch (X0 socket collision) — FIXED

**Status: FIXED 2026-10-18.** Root-caused in a QA sweep via an Apport crash report
(`/var/crash/_opt_gamescope_bin_gamescope.1000.crash`, SIGABRT) and the session log; fixed by a
pre-launch guard in `steam-gamescope-session` and validated live (see end of section).

**Symptom.** On a session **restart or desktop→Game-Mode switch**, gamescope aborts at startup:
```
[gamescope] Error wlserver: [xwayland/sockets.c:47] Failed to bind socket @/tmp/.X11-unix/X0: Address already in use
[gamescope] Error xwm: X11 I/O error! This is fatal. Aborting...
```
accompanied by `drmModeRmFB failed: Bad file descriptor` and libseat `Could not close device:
Connection timed out`. The crash trips the `GAMESCOPE_FALLBACK_WINDOW` path → X11 kiosk for that
boot (seen live: gamescope died ~12:09 HST, X11 fallback engaged ~12:11, hence the stale
`-cef-disable-gpu-compositing`/GLX errors in that window). The console **recovers**, so it is easy
to miss, but gamescope is genuinely crashing on transitions.

**Root cause.** Both the desktop session's real Xorg and gamescope's Xwayland (`--xwayland-count 2`)
use display `:0`. When the previous X server's `/tmp/.X11-unix/X0` socket + `/tmp/.X0-lock` linger
past SDDM teardown (or a prior gamescope exited without releasing them), the new gamescope's
Xwayland cannot bind `:0` and aborts. The exit-segfault fix (`_exit(0)` after child reap, live
change #14) **skips Xwayland teardown**, which makes gamescope more likely to leave the X0 socket
behind — so the segfault fix and this restart-abort are linked.

**Fix (applied).** In `steam-gamescope-session`, before launching gamescope: bounded-wait (~10 s)
for `:0`/`:1` to be free, and remove only `/tmp/.X{0,1}-lock` + sockets whose owning PID is already
dead (never kill a live X server).

**Validated live 2026-10-18** on the board over 4 desktop↔Game-Mode cycles (2 gamescope restarts):
the guard fired (`clearing stale X`), there were **0** `X11 I/O error … Aborting`, **0** new
`/var/crash` reports, **0** fallbacks to the X11 kiosk, and the final session came up healthy
(gamescope + steamwebhelper up). A few non-fatal `Failed to bind … X0` retry lines still appear but
no longer escalate to the fatal abort.

---

## One suspend hang traced to a wedged USB-C NVMe enclosure (not a suspend bug)

**Status:** resolved/understood 2026-10-19. Suspend/resume works — re-verified with
`sudo rtcwake -m mem -s 30`: the board suspended and auto-resumed, uptime did **not** reset, and
gamescope/Steam/WiFi all survived. A single earlier no-resume hang was observed, where the journal
reached:
```
systemd-logind: The system will suspend now!
systemd-sleep: Performing sleep operation 'suspend'...
```
and then nothing until a hard reset.

**Root cause — a dead USB-storage device, not the PM stack.** A USB-C NVMe enclosure (Realtek
**RTL9210**, USB Attached SCSI / `uas`) was attached and had wedged during an earlier write
(`mkfs`), and was still in a failed state at suspend time:
```
sd 0:0:0:0: [sda] tag#21 timing out command, waited 180s
sd 0:0:0:0: [sda] uas_zap_pending ... inflight: CMD
sd 0:0:0:0: [sda] Synchronize Cache(10) failed: Result: hostbyte=0x07
```
During the suspend freeze the kernel must quiesce and flush every block device; it cannot flush a
UAS device whose commands are timing out, so the suspend (and therefore the resume) hangs. With the
enclosure removed, suspend/resume behaves normally.

**Takeaways.**
- Do **not** disable sleep to "fix" this — the PM stack was fine; a faulty USB device poisoned it.
- The RTL9210 enclosure itself is the thing to address: it wedges on sustained writes on this board.
  A common workaround for flaky RTL9210/UAS bridges is to force BOT (disable UAS) via
  `usb-storage.quirks=0bda:9210:u` on the kernel cmdline; a different cable/port is also worth trying.
- `mem_sleep` is `s2idle [deep]` (deep selected) — note for any future, *actually-reproducible*
  suspend investigation, but not implicated here.

## Game controller drivers not in NVIDIA's kernel — built out-of-tree (resolved)

**Status:** resolved. NVIDIA's `6.8.12-tegra` kernel ships with `CONFIG_INPUT_UINPUT`,
`CONFIG_HID_STEAM`, `HID_PLAYSTATION`, `HID_NINTENDO` and `HID_SONY` all unset (confirmed in
`/proc/config.gz`), so a stock flash has no `/dev/uinput` and only generic-HID gamepad support —
which means **Steam Input (virtual controllers / remapping) does not work** and DualSense /
Switch Pro / Steam Controller get buttons+axes only (no gyro / rumble / touchpad).

**Fix — no full kernel rebuild needed.** The build compiles these five drivers as *out-of-tree*
modules from the matching upstream `linux-6.8.12` sources against NVIDIA's kernel headers
(`scripts/chroot-build-modules.sh`, run by `build.sh` when `WITH_INPUT_MODULES=1`, the default),
installs them to `/lib/modules/<krel>/updates/steamos-orin`, `depmod`s, and loads them via
`overlay/etc/modules-load.d/steamos-orin.conf` (now lists `uinput` + the four `hid-*`). vermagic is
checked against the running kernel at build time.

**Verified on hardware 2026-10-19.** Built and loaded all five on the live board (which was flashed
before this feature existed): `/dev/uinput` is present (with a udev ACL for the session user) and
`lsmod` shows `uinput`, `hid_steam`, `hid_playstation`, `hid_nintendo`, `hid_sony`. Only images
built *before* this feature lack them — rebuild, or build the modules on-device the same way.

> Note: `xt_connmark` (Tailscale) genuinely cannot be fixed this way — it needs
> `CONFIG_NF_CONNTRACK_MARK` inside the core `nf_conntrack` module, which an add-on module can't
> change. That one does need a kernel rebuild.
