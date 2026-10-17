-- orin-steamos: never suspend ALSA output sinks (WirePlumber 0.4.x, Ubuntu 24.04).
-- Suspending an idle HDMI sink and resuming it makes an audible thump on the TV/monitor
-- every time a UI sound plays. Costs a little power; a console stays plugged in anyway.
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.*" },
    },
  },
  apply_properties = {
    ["session.suspend-timeout-seconds"] = 0,
  },
})
