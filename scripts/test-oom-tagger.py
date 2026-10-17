#!/usr/bin/python3
"""Unit test for overlay/usr/lib/steamos-orin/oom-tagger rule table (no /proc writes)."""
import sys; sys.dont_write_bytecode = True
import importlib.machinery, importlib.util
path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("tagger", path)
spec = importlib.util.spec_from_loader("tagger", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
cases = [("gamescope-wl", [], -500), ("Xwayland", [], -500), ("steam", [], -200),
         ("steamwebhelper", [b"SteamAppId=0"], 300), ("Hades.exe", [], 500), ("Cyberpunk2077.e", [], 500),
         ("wine64-preloade", [], 500), ("wineserver", [], 500), ("FEXInterpreter", [], 500),
         ("game.x86_64", [b"SteamAppId=1145360"], 500), ("reaper", [b"SteamGameId=0"], None),
         ("bash", [], None), ("xfce4-panel", [b"SteamAppId="], None)]
bad = [(c, m.target(c, e), t) for c, e, t in cases if m.target(c, e) != t]
for b in bad: print("FAIL", b)
print(f"oom-tagger rules: {len(cases)-len(bad)}/{len(cases)} PASS"); sys.exit(1 if bad else 0)
