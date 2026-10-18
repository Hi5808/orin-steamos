# Pinning the Steam client

The ARM64 Steam client is a public beta and has shipped regressions that break Game Mode on
this hardware (e.g. the x86-64 `steamrt64` files overwriting the arm64 runtime, see
`docs/live-board-changes.md` #1). To keep a flashed device on a client build that is known to
work here, the image can **pin** the client: block Steam's own self-update while still letting
you update it deliberately.

## How it works

`STEAM_CLIENT_PIN` in `/etc/default/steamos-orin` holds the build id (the `version` from
`~/.local/share/Steam/package/steam_client_*linuxarm64.manifest`) of a known-good client.

`/usr/lib/steamos-orin/steam-pin apply` runs from `steam-launch` before every Steam start:

- When the **installed** client's version equals `STEAM_CLIENT_PIN`, it writes
  `~/.local/share/Steam/steam.cfg` with Valve's switches
  `BootStrapperInhibitAll=enable` and `BootStrapperForceSelfUpdate=disable`, so the
  bootstrapper stops self-updating.
- When the versions differ (you updated on purpose, or the client isn't installed yet), it
  removes *our* `steam.cfg` so the client bootstraps / updates normally. Valve's CDN only
  serves the current client, so a pin can never force a downgrade — it only freezes a client
  that already matches.
- `STEAM_CLIENT_PIN=""` disables pinning entirely (Steam updates itself as usual).

Only a `steam.cfg` we wrote (it carries a `# steamos-orin: STEAM_CLIENT_PIN` marker) is ever
removed; a `steam.cfg` you created by hand is left alone.

## Commands

```bash
steam-pin status   # installed version, the pin, and whether updates are blocked
steam-pin apply    # (re)apply the pin for the current state; called automatically at launch
```

## Updating the pin

1. Unpin (`STEAM_CLIENT_PIN=""`) or run a one-off update, let Steam update, and confirm Game
   Mode still works on the device.
2. Read the new build id: `steam-pin status`.
3. Put that id in `STEAM_CLIENT_PIN` (in the image: `overlay/etc/default/steamos-orin`).
