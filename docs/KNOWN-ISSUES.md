# Known issues

## Game Mode UI flickers during animation (gamescope misses vblanks on nvidia-drm)

**Symptom.** In the gamescope Game Mode session, animated Steam Big Picture content
flickers/judders: the left slide-in quick-access menu and the idle game-art slideshow.
Static screens are fine. Confirmed not the monitor (reproduced across two displays; HP w2207,
DP-1, 60 Hz only, no VRR).

**Not the cause (ruled out live, 2026-10-18):**

- gamescope compositing path — `composite_force 1`, `drm_single_plane_optimizations 0`: no change.
- explicit-sync waits — `drm_debug_syncobj_force_wait_on_commit 1`, `drm_debug_disable_in_fence_fd 1`: no change.
- Steam CEF renderer — `GAMESCOPE_STEAM_EXTRA_ARGS`:
  - `-cef-disable-gpu-compositing` → kills GPU compositing, menu becomes CPU-composited and **slow**; flicker not fixed.
  - `-cef-use-vulkan` (ANGLE_VULKAN via gamescope WSI) → **froze** the session.
  - empty (ANGLE_OPENGL + GPU compositing) is the fast, usable state and the current default; it is the one that flickers.

**Root cause (measured).** `gamescopectl vblank_debug 1` during the flicker shows repeated
`!! missed vblank`. drawTime is only ~4–10 ms (well inside the 16.68 ms frame) but the scheduler's
`offset` is ~9–11 ms and it still misses the flip deadline — i.e. gamescope's predicted vblank
time drifts from nvidia-drm's actual vblank/pageflip event timing. Each missed frame lands a
cycle late (dropped/doubled), which on 60 fps animation reads as flicker.

**Why the obvious knob doesn't work.** The draw-buffer "redzone" (how early gamescope wakes to
composite; default `kDefaultVBlankRedZone` = 1.65 ms) is the natural mitigation — wake earlier,
more margin. But in gamescope 3.16.28 the runtime tuneable is **dead-wired**: the X atom
`GAMESCOPE_TUNEABLE_VBLANK_REDZONE` handler sets the global `g_uVblankDrawBufferRedZoneNS`
(`src/steamcompmgr.cpp:6443`), while the scheduler reads the unrelated, never-updated member
`m_ulVBlankDrawBufferRedZone` (`src/vblankmanager.cpp:117`, init from `kDefaultVBlankRedZone` in
`src/vblankmanager.hpp`). Setting the atom at runtime (verified read-back = 5 ms) does not change
the scheduler's redzone. So the redzone can only be changed at build time.

### Candidate fixes (not yet tried — need a gamescope rebuild and/or a session restart)

1. **Bump the compile-time redzone.** In `build-gamescope`'s Tegra patch, raise
   `kDefaultVBlankRedZone` (e.g. 1.65 ms → 4–6 ms) so the compositor wakes earlier. Cheapest to
   test; costs a little latency. (Optionally also fix the dead atom wiring so it's tunable live.)
2. **Force the nudge-thread wakeup path** instead of timerfd: start gamescope with
   `GAMESCOPE_DISABLE_TIMERFD=1` (needs exporting from `steam-gamescope-session` + a session
   restart). Tests whether timerfd wakeup imprecision on this kernel is the drift source.
3. **Investigate nvidia-drm vblank timestamps.** If the driver reports inaccurate pageflip
   completion times, gamescope's `GetLastVBlank()` prediction will always drift; the redzone only
   masks it. Longer-term / upstream.

Order to try: (1), then (2); (3) if neither holds. Test each by re-running `vblank_debug` and
counting `missed vblank` during the menu/art animation, and by eye on the monitor.
