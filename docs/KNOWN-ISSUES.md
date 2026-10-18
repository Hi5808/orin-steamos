# Known issues

## Steam Big-Picture UI flickers to black (menu dim + screensaver) — CEF content, games unaffected

**Symptom.** In Game Mode, *animated* Steam Big Picture UI flickers hard: the quick-access
menu's background dim/blur, and the idle/screensaver game-art slideshow. The screen rapidly
alternates between the correct frame and a **fully black** frame. Static screens (the Big
Picture home) are perfect. **Actual games are unaffected** — they render smoothly through
gamescope. Confirmed not the monitor (reproduced on two displays; HP w2207, DP-1, 60 Hz).

**What it is (measured 2026-10-18).** Using `gamescopectl screenshot` to dump gamescope's
*composited output* during Steam's test screensaver: the frames alternate between the real art
(a full ~3 MB PNG) and a **pure-black 1080p frame** (~72 KB PNG), with black roughly 7 of every
10 captured frames. So gamescope is faithfully compositing black frames that Steam's CEF
renderer is handing it — the black originates in **Steam's CEF (gamepadui) GPU rendering**, only
for continuously-animated Big-Picture layers (the screensaver, the menu backdrop blur/dim).
Static CEF content and non-CEF content (games) are fine. The CEF GPU path here is ANGLE on
OpenGL (`ANGLE (… NVIDIA Tegra Orin (nvgpu) …, OpenGL 4.5.0 NVIDIA 595.78)`), `gpu_compositing:
enabled`.

**Ruled out (tried live, no effect on the flicker):**

- gamescope compositing path: `composite_force 1`, `drm_single_plane_optimizations 0`.
- gamescope present timing: `drm_debug_syncobj_force_wait_on_commit 1`,
  `drm_debug_disable_in_fence_fd 1`; raising the draw-buffer redzone to 5 ms (rebuilt gamescope,
  `kDefaultVBlankRedZone`) — it cut "missed vblank" events but not the flicker; the
  nudge-thread wakeup path (`GAMESCOPE_DISABLE_TIMERFD=1`). (An earlier revision of this file
  blamed gamescope missed vblanks — that theory is **disproven**: games animate fine through the
  same compositor, and the black frames come from the CEF content, not gamescope's scheduling.)
- Steam CEF switches via `GAMESCOPE_STEAM_EXTRA_ARGS`:
  - `-cef-disable-xcomposite-workaround` → no change.
  - `-cef-use-vulkan` (ANGLE_VULKAN) → **froze** the session.
  - `-cef-disable-gpu-compositing` → **does** stop it, but CPU-composites the whole UI so the
    menu becomes sluggish. Not acceptable as the default.

**Where it points.** A Chromium/CEF GPU-compositing bug on the NVIDIA ARM64 (Tegra, ANGLE-GL)
path for animated Big-Picture layers (backdrop blur / fullscreen crossfade present as black on
alternate frames). Likely needs an upstream fix (Steam ARM64 client beta and/or the NVIDIA
driver), not something gamescope or our image can cleanly patch.

### Mitigations / next steps (not yet confirmed)

1. **Reduce it in Steam settings** (per-device, no perf cost): disable the Big-Picture
   screensaver, and turn down interface animations / background effects if the client exposes
   the toggle. Removes the flickering layers without the software-compositing slowdown.
2. **Pass a targeted Chromium flag** if a channel exists to inject arbitrary CEF command-line
   (beyond Steam's fixed `-cef-*` switches): candidates are `--disable-partial-raster`,
   `--ui-disable-partial-swap`, `--disable-gpu-driver-bug-workarounds`. Not reachable via the
   known `-cef-*` switches; needs investigation of `STEAM_CEF_*` env or a CEF config file.
3. Re-test on each Steam ARM64 beta / NVIDIA JetPack update; file upstream with the
   screenshot evidence (art ↔ black composite during the test screensaver).

Reproduce quickly: Steam Settings has a **test screensaver** mode that triggers the glitch on
demand; capture with `gamescopectl screenshot <path>` and compare frame sizes (≈72 KB = black).
