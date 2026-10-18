# Draft bug report — Jetson Orin display/Vulkan driver (JetPack 7.2.1 / L4T r39.2.1)

Draft for the NVIDIA Jetson developer forum. Two issues on one unit, both consistent with the
GPU/display stack **advertising capabilities it cannot actually deliver**. Fill the `TODO` spots
and attach the referenced logs before posting.

## Environment

- Board: Jetson Orin Nano 8GB Developer Kit (Super), `jetson-orin-nano-devkit-super`
- JetPack **7.2.1** / Jetson Linux **r39.2.1**, kernel 6.8.12-tegra, Ubuntu 24.04
- GPU/display driver: **595.78**, Vulkan **1.4.329**
- Display: HP w2207 over DisplayPort (DP-1), EDID-preferred 1680x1050 @ 59.85 Hz, no VRR
- Compositor: gamescope 3.16.28 (DRM/KMS atomic backend) running Steam Big Picture
- Reproduced across two different monitors (rules out the panel/cable)

---

## Issue 1 — Display Control Engine (DCE) RPC failures + black scanout during compositor flips

**Summary.** When a KMS/atomic compositor (gamescope) continuously flips a *composited* buffer to
the display, the scanned-out image intermittently goes **fully black** (≈70% of frames during an
animated scene), while the buffer the compositor produced is correct. Meanwhile the kernel log
floods with DCE RM-control failures.

**Kernel log (repeats, hundreds per session):**
```
NVRM: GPU0 rpcRmApiControl_dce: NVRM_RPC_DCE: Failed RM ctrl call cmd:0x731341 result 0xffff: Failure: Generic Error [NV_ERR_GENERIC]
```
All failures use the same `cmd:0x731341`. 862 occurrences in ~11 minutes after one session start.

**Evidence that it is scanout, not the compositor:**
- Capturing the compositor's *composited output* (gamescope's own screenshot of the buffer it
  presents) shows a **clean** frame, yet the physical display shows black on the same frames.
- A fullscreen 3D game, which the compositor **direct-scans-out** (no per-frame composite), is
  **unaffected**. Only the *composited* UI flips glitch.
- Forcing any **non-EDID-preferred mode** (e.g. 1280x1024) results in **no video output at all**.

**Repro:** run a KMS atomic compositor that composites + flips a continuously-updating surface at
60 Hz to DP-1 on this board; observe black-frame flicker on animated content and the DCE RPC
failures growing in `dmesg`.

**Ask:** what is `cmd:0x731341` to the DCE, why does it return `NV_ERR_GENERIC`, and why does the
composited-flip scanout drop to black? Is there a known DCE firmware fix?

Attach: full `dmesg`, the compositor DRM log, two screenshots (composited buffer = correct art;
simultaneous photo of the display = black). TODO: attach files.

---

## Issue 2 — `vkCreateDevice` returns `VK_ERROR_INITIALIZATION_FAILED` with a full feature set

**Summary.** Creating a Vulkan device that enables the broad feature/extension set a modern D3D12
translation layer (vkd3d-proton 3.0) requests **fails with `VK_ERROR_INITIALIZATION_FAILED (-3)`**,
even though `vulkaninfo` reports every one of those features as supported. A device created with a
leaner set (DXVK / D3D11) succeeds on the same driver, so the GPU and basic Vulkan path work.

**From the translation layer's log (`VKD3D_DEBUG=warn`):**
```
vkd3d-proton: Found device: NVIDIA Tegra Orin (nvgpu) (NVIDIA 595.78.0)
vkd3d-proton: vkd3d_create_vk_device: Disabled extensions that can cause Vulkan device creation to fail, retrying.
vkd3d-proton: vkd3d_create_vk_device: Failed to create Vulkan device, vr -3.
vkd3d-proton: hresult_from_vk_result: Unhandled VkResult -3.
```
(`-3` = `VK_ERROR_INITIALIZATION_FAILED`.) The layer's own retry, which strips known-problematic
extensions, still fails.

**Ruled out:**
- Missing features — `vulkaninfo` reports all present: `bufferDeviceAddress`, `descriptorIndexing`,
  `nullDescriptor`, `robustBufferAccess2`/`robustImageAccess2`, `runtimeDescriptorArray`,
  `timelineSemaphore`, `samplerFilterMinmax`, full sparse residency, `VK_EXT_descriptor_indexing`,
  `VK_EXT_robustness2`, `VK_KHR_buffer_device_address`, `VK_EXT/KHR_swapchain_maintenance1`.
- The compositor's WSI layer forcing `VK_EXT_swapchain_maintenance1` (disabling that layer did not
  change the failure).
- Vulkan validation finds no usage violation (the failure is driver-internal).

**Identified cause + workaround.** This matches vkd3d-proton #3076 and an NVIDIA forum thread on
desktop RTX 50-series: the driver advertises **cooperative-matrix / ray-tracing / optical-flow**
capabilities it cannot enable at device creation (log tell: `vkd3d_supports_minimum_coopmat_caps:
Missing sufficient features to expose WMMA`). Disabling them —
`VKD3D_CONFIG=nodxr VKD3D_DISABLE_EXTENSIONS=VK_NV_optical_flow,VK_NVX_binary_import,VK_NVX_image_view_handle`
— makes `vkCreateDevice` succeed and DX12 games run. So the GPU works; the driver just
over-advertises.

**Ask:** please fix the capability advertisement so `vkCreateDevice` does not return
`INITIALIZATION_FAILED` for features/extensions the driver reports as supported (a Vulkan-spec
violation), so the `nodxr`/disable-extensions workaround isn't needed. A minimal repro
(device-create enabling the full advertised feature set) can be provided.

Attach: full `PROTON_LOG` with `VKD3D_DEBUG=warn`, `vulkaninfo` output. TODO: attach files.

---

## Why we think these are related

Both are the driver reporting a capability it cannot honour at the moment of use — a display
control call the DCE rejects during scanout, and a Vulkan feature set the driver accepts in query
but rejects at device creation. A fix to the Orin display/Vulkan driver conformance would likely
address both. Happy to test patched drivers / a newer JetPack on this unit.
