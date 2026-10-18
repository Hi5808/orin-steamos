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
