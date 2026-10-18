# The Black Screensaver of Death — investigation log

A living dossier of the Game-Mode black-frame bug (idle screensaver + menu backdrop), to be
slain eventually. **Thesis:** the screensaver flicker, the menu-dim flicker, and the D3D12
device-creation failure are all faces of one thing — **the Jetson Orin Tegra GPU/display stack
advertising capabilities it cannot actually deliver.** Keep appending; never trim the trail.

Hardware/software: Jetson Orin Nano 8GB Super, JetPack 7.2.1 / L4T r39.2.1, NVIDIA driver
**595.78**, Vulkan **1.4.329**, kernel 6.8.12-tegra. Display: HP w2207, DP-1, 1680x1050@59.85,
60 Hz, no VRR. Session: gamescope (DRM backend) → Steam gamepadui (CEF, ANGLE-on-GL).

## The symptom

Animated Steam Big-Picture UI flickers hard between the correct frame and **pure black**:
- the **idle/screensaver** game-art slideshow (reproducible on demand: Steam Settings → test
  screensaver),
- the **quick-access menu** backdrop dim/blur.

Static screens (Big Picture home) are perfect. **Real games are unaffected.** Reproduced across
two monitors (so not the panel/cable).

## The decisive insight

`gamescopectl screenshot` dumps gamescope's **composited buffer** — and that buffer can be made
**clean** — yet the **physical monitor still flickers to black**. So the black is introduced
*after* compositing, at **DRM scanout to the display**. Capture never matches the display; that
mismatch is the tell that it's scanout, not compositing. (Credit: the user called "video output
issue" before the evidence confirmed it.)

Why games are fine: gamescope **direct-scans-out** a fullscreen game's own buffer, but it
**composites** the UI and flips *its own* composite buffer. It's that composited-output flip to
the display engine that glitches.

## Hard evidence (2026-10-18)

- `gamescopectl screenshot` during the test screensaver: frames alternate between the real art
  (full ~3 MB PNG) and a **byte-identical all-black 1080p frame** (~72 KB PNG,
  md5 `3ecb83d019dd519543835838d23e080e`), black ~7 of 10 frames. (Reliable black detector:
  count exact matches to that md5 — file size misleads because dark art compresses small too.)
- `dmesg` floods with NVIDIA **Display Control Engine** RPC failures:
  `NVRM: GPU0 rpcRmApiControl_dce: NVRM_RPC_DCE: Failed RM ctrl call cmd:0x731341 result 0xffff:
  Generic Error [NV_ERR_GENERIC]` — 862 of them in ~11 min after a session restart. All the same
  cmd `0x731341`. They come in bursts (0 in a given idle 6 s window) — a symptom of a sick
  display engine, not a per-frame 1:1 cause.
- Forcing a non-native output mode (1280x1024) gave **no video at all** — the display path can't
  even be driven off its EDID-preferred mode.
- `vkcube-wayland` test was inconclusive (gamescope in Steam mode wouldn't display a bare
  wayland client; I kept capturing the screensaver underneath).

## Paths walked — what did NOT change the on-screen flicker

Every one tried live, screensaver running as the oracle; none fixed the displayed flicker.

Compositor / present path (gamescope convars, runtime):
- `composite_force 1`, `drm_single_plane_optimizations 0`
- `drm_debug_syncobj_force_wait_on_commit 1`, `drm_debug_disable_in_fence_fd 1`,
  `drm_debug_disable_explicit_sync 1`
- `tearing_enabled 1` (immediate flips), `debug_set_fps_limit 30`
- all colour-pipeline chicken bits off: `drm_debug_disable_{ctm,degamma_tf,regamma_tf,output_tf,
  color_encoding,color_range,blend_tf}`
- the `GAMESCOPE_TUNEABLE_VBLANK_REDZONE` X atom is **dead-wired** in gamescope 3.16.28
  (writes global `g_uVblankDrawBufferRedZoneNS`; scheduler reads a different, never-updated
  `m_ulVBlankDrawBufferRedZone`). Rebuilt gamescope with `kDefaultVBlankRedZone` = 5 ms: cut
  "missed vblank" events but **not** the flicker.
- `GAMESCOPE_DISABLE_TIMERFD=1` (nudge-thread wakeups instead of timerfd).

Output mode:
- 1280x1024 → no video (reverted). Only EDID-preferred 1680x1050 produces a picture.

Steam CEF (`GAMESCOPE_STEAM_EXTRA_ARGS` and raw Chromium flags in `steamwebhelper.sh`):
- `-cef-disable-xcomposite-workaround` → no change.
- `-cef-use-vulkan` → **froze** the session.
- `--ui-disable-partial-swap`, `--disable-gpu-rasterization`, `--disable-gpu-vsync`,
  `--disable-frame-rate-limit`, `--disable-gpu-driver-bug-workarounds` → no change.
- `__GL_MaxFramesAllowed=1` on steamwebhelper → made gamescope's **composite buffer clean**
  (0 black in captures, was ~7/10) but **did not** stop the on-screen flicker. This is the
  experiment that proved the flicker is downstream of the composite.
- `-cef-disable-gpu-compositing` → stops it, but CPU-composites the whole UI (sluggish). Not a
  fix. (It bypasses the GL output/swapchain path entirely — consistent with the bug being in
  GL/scanout presentation.)

## Dead theories (disproven, keep them dead)

- "gamescope misses vblanks" — real (`vblank_debug` shows `!! missed vblank`), but **not the
  cause**: games animate fine through the same scheduler, and reducing misses didn't help.
- "Steam CEF composites black" — the composite can be made clean while the display still
  flickers, so CEF is not the final cause (though CEF is the only content that *exercises* the
  broken path, via gamescope's composited flip).
- "buffer-age / partial-swap" — `--ui-disable-partial-swap` did nothing.
- "colour-pipeline / CTM / TF property re-commit" — all chicken bits off did nothing.

## The link to D3D12 (same root suspected)

Separately, DX12 games fail: vkd3d-proton 3.0 `vkCreateDevice` returns
`VK_ERROR_INITIALIZATION_FAILED (-3)` on the Tegra driver though `vulkaninfo` reports every
required feature present (bufferDeviceAddress, descriptorIndexing, nullDescriptor,
robust*Access2, runtimeDescriptorArray, timelineSemaphore, samplerFilterMinmax, sparse…). DXVK
(DX11) creates a device fine with a leaner set. **Hot lead:** the Proton log shows gamescope's
WSI layer `[Gamescope WSI] Forcing on VK_EXT_swapchain_maintenance1` immediately before each
failed `vkCreateDevice`; the driver *does* list `VK_EXT/KHR_swapchain_maintenance1` as device
extensions. Next test (pending, board offline): disable `VK_LAYER_FROG_gamescope_wsi` (it has a
`disable_environment`) and retry DX12 — does the device then create? If yes, the WSI layer /
swapchain_maintenance1 on Tegra is a shared offender with the scanout flicker.

Common thread across all three: **the Tegra driver claims support (features/extensions/modes)
it cannot actually honour at the device/scanout level.**

## Conclusion so far

An NVIDIA Jetson Orin **display-engine (DCE) / Vulkan-driver bug** in JetPack 7.2.1, below
gamescope and Steam. No user-space fix found for the scanout flicker (~20 levers). Cosmetic:
only the idle screensaver and the menu backdrop; games and gameplay are unaffected.

## Leads still open / to try

1. **Disable the gamescope WSI layer** and re-test both D3D12 *and* the UI flicker (the layer
   forces swapchain_maintenance1; it also owns gamescope's own present path).
2. Correlate the `rpcRmApiControl_dce cmd:0x731341` bursts with on-screen black events (timestamp
   a flicker, diff dmesg) — is 0x731341 a mode/colorimetry/HDR query fired per composite flip?
3. Decode cmd `0x731341` (NV0073-class display control?) to learn what the DCE is being asked.
4. Enable gamescope `log_drm`/`drm_debug` and catch an actual failed atomic flip during a flicker
   (first attempt logged nothing — try longer, with the screensaver confirmed running).
5. Vulkan validation layer on the vkd3d device create (if installable) for the exact rejected
   feature.
6. Re-test on the next JetPack / L4T release (display + Vulkan driver); file with NVIDIA Jetson
   forums with: clean composite vs black scanout, DCE RPC failures, non-native mode = no video,
   vkCreateDevice INITIALIZATION_FAILED with features present.

## Reproduce quickly

- Flicker: Steam Settings → **test screensaver**. `gamescopectl screenshot /tmp/x.png`; count
  exact-black frames by md5 `3ecb83d019…`. Watch `dmesg | grep -c rpcRmApiControl_dce` grow.
- D3D12: launch a DX12 game (e.g. appid 1375400 with `config.ini` set back to DirectX12) with
  `PROTON_LOG=1 VKD3D_DEBUG=warn`; read `~/steam-<appid>.log` for `Failed to create Vulkan
  device, vr -3`.
