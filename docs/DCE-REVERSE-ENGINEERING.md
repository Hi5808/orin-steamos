# DCE firmware RE — locating the `cmd:0x731341 → 0xffff` failure

Reverse-engineering notes for the Big-Picture flicker (see [KNOWN-ISSUES.md](KNOWN-ISSUES.md)).
Goal: find what the kernel's flood means —
`NVRM: GPU0 rpcRmApiControl_dce: … Failed RM ctrl call cmd:0x731341 result 0xffff … [NV_ERR_GENERIC]`.

**This does not fix the bug.** The DCE firmware is NVIDIA-signed and loaded by the boot chain; it
cannot be rebuilt or reflashed by us. What the RE buys is (a) an exact, citable root cause for the
NVIDIA bug report and (b) a testable workaround hypothesis.

> Scope / legal: this is black-box analysis of a shipped firmware image for **interoperability and
> defect reporting** (diagnosing a scanout failure to file with NVIDIA). **No NVIDIA firmware binary
> is included in or redistributed by this repository** — reproduce these notes against your own copy
> of `display-t234-dce.bin` from the Jetson Linux BSP. Addresses are for JetPack 7.2.1 / L4T
> r39.2.1 and will differ on other releases.

## Target

`Linux_for_Tegra/bootloader/display-t234-dce.bin` from Jetson Linux R39.2.1 (JetPack 7.2.1).
It is the firmware for the Orin **DCE (Display Control Engine)**, a Cortex-R5 coprocessor.

- Raw ARMv7-R image, little-endian. File offset 0 = `08 f0 9f e5` (`ldr pc,[pc,#8]`) reset vector;
  offset 0x10 holds `0x408030a8` (entry). **Load base `0x40000000`**, entry `0x408030a8`.
- Header magic `"DCE0"` + `0x234` (t234). Debug build: carries source paths
  (`display/dce/ipc/dce-ipc-signal.c`, `.../tasks/ShaTask.c`, …) and the full `NV_ERR_*` string table.
- Ghidra `ARM:LE:32:v7`, 3964 functions recovered.

## The RM-control dispatch table (NV0073 / NV04_DISPLAY_COMMON)

`cmd:0x731341` is an **`NV0073` display-common** RM control (`0x0073` = `NV04_DISPLAY_COMMON`).
The firmware dispatches these through a table at **`0x4007e430`**, 16-byte entries:

```
struct { u32 cmd_id; u32 param_size; u32 iface_ptr; u32 handler_ptr; }
```

Observed entries (cmd / size / handler):

| cmd_id | param_size | handler (Thumb) |
|--------|-----------|-----------------|
| 0x00731180 | 0x4c | 0x4085f690 |
| **0x00731341** | **0x30** | **0x4085f7a8** |
| 0x00731343 | 0x1c | 0x4085fe64 |
| 0x00731345 | 0x2c | 0x4085f690 |

So the code that processes `0x731341` is **`FUN_4085f7a8`** (48-byte parameter block).

## The exact failing branch

`FUN_4085f7a8` has **exactly one** `return 0xffff`, and `0xffff` is what the kernel logs as
`NV_ERR_GENERIC`. The path:

```c
int handler_0x731341(ctx *param_1, u32 *param_2 /* 0x30-byte request */) {
    ...
    if ((param_2[2] & 0x1800) == 0) {                 // request flag bits 11,12 both clear
        r = FUN_4084ee80(head, dev, cli, 1, &cStack_42);
        if (r != 0) return r;
        if (!bVar9 && cStack_42 == '\0') {            // not the special-case request, helper said "no"
            if (*(char *)(dev + 0x14f8) == '\0') {    // a display/head CAPABILITY byte is false
                return 0xffff;                        // <-- NV_ERR_GENERIC  (the flood)
            }
            ...                                        // else: do work, return 0x55 (retry/again)
        }
    }
    ...                                                // normal path, eventually returns 0 / iVar4
}
```

where `bVar9 = (param_2[2] & 1) && ((param_2[3] & 0x1f) == 0)`.

**Interpretation.** For this display-common control, when the request's flag word `param_2[2]` has
bits `0x1800` clear and it is not the `bVar9` special case, the firmware consults a per-device /
per-head capability byte at `ctx+0x14f8`. If that byte is **0 (feature not available)**, it rejects
the call with `NV_ERR_GENERIC` instead of a specific error. The request parameters (a `bpc`-like
switch over `6/8/9/10/12/16/20/30`, masks `0x780000`, `0x1f`) point to a **mode / scanout-config or
"is this mode possible" type control** — consistent with the symptom: during continuous composited
scanout the driver issues this control per update, the DCE says "capability off → generic error,"
and the frame drops to black.

## Workaround hypothesis (untested — board offline at time of writing)

The entire reject block is guarded by `(param_2[2] & 0x1800) == 0`. If the **request** set bit
`0x800` or `0x1000` in that flag word (`param_2[2]`), the firmware skips the capability check and the
`0xffff` path entirely (and `return 0x55` / normal paths take over). That flag word originates in the
**kernel-side** `rpcRmApiControl_dce` marshalling of this NV0073 control — i.e. a driver/RM change,
not a userspace/gamescope knob — so it is a lead for NVIDIA or for kernel-side experimentation, not a
setting we can flip from Steam. Likewise, identifying what *should* set `ctx+0x14f8` (the capability)
would show why it is false on this panel/mode (HP w2207, 1680×1050@59.94, no VRR).

## What to do with this

1. **Bug report:** quote the command (`NV0073` display-common `0x731341`), the handler
   (`display-t234-dce.bin` `FUN_4085f7a8`), the single `0xffff` branch, and the `ctx+0x14f8`
   capability condition. This turns "it flickers" into "your DCE firmware returns `NV_ERR_GENERIC`
   from *this* branch when *this* capability is false" — hard to dismiss.
2. **Experiment (needs the board + more RE):** trace the writer of `ctx+0x14f8` to learn which
   display capability is involved, and whether a supported mode / different output config makes it
   non-zero (i.e. a mode the DCE is actually happy to scan out while compositing).
