# NVIDIA bug-report attachments

Evidence for [`../NVIDIA-BUG-REPORT.md`](../NVIDIA-BUG-REPORT.md).

| File | Status | Notes |
|------|--------|-------|
| `vulkaninfo.txt` | staged | Full `vulkaninfo` from the board, 2026-10-18. Device `apiVersion 1.4.329`, driver `595.78.0.0`, `NVIDIA Tegra Orin (nvgpu)`. |
| `dmesg-dce-flood.txt` | to capture | Needs the UI flickering + `sudo` (see the report's Capture checklist). Must contain `rpcRmApiControl_dce` lines. |
| `proton-vkd3d.log` | to capture | DX12 title with `PROTON_LOG=1 VKD3D_DEBUG=warn` and the `nodxr` workaround removed. |
