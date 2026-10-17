#!/bin/bash
# P0 checklist: run ON THE ORIN after first boot (ssh steamos@orin-steamos.local).
# Collects facts the design depends on. Writes ~/p0-report.txt. The suspend test
# is opt-in: ./p0-checklist.sh --suspend-test
set -uo pipefail
out="$HOME/p0-report.txt"; exec > >(tee "$out") 2>&1
sec() { printf '\n### %s\n' "$*"; }
sec "release";      cat /etc/nv_tegra_release 2>/dev/null; uname -a; # shellcheck source=/dev/null
. /etc/os-release; echo "$PRETTY_NAME"
sec "page size";    getconf PAGESIZE
sec "memory/zram";  free -h; swapon --show; zramctl 2>/dev/null
sec "memory tuning (sysctl)"; sysctl vm.swappiness vm.page-cluster vm.watermark_scale_factor vm.watermark_boost_factor vm.min_free_kbytes 2>&1
sec "OOM policy"
systemctl is-active earlyoom steamos-orin-oom-tagger 2>&1 | paste -sd' ' | sed 's/^/earlyoom, oom-tagger: /'
echo "systemd-oomd: $(systemctl is-enabled systemd-oomd 2>&1) (expected: masked)"
echo "swapfile: $(systemctl is-active var-swap-swapfile.swap 2>&1); $(swapon --show=NAME,PRIO --noheadings 2>/dev/null | paste -sd' ')"
for p in sshd sddm Xorg gamescope steam steamwebhelper; do
  for pid in $(pgrep -x "$p" 2>/dev/null | head -3); do echo "oom_score_adj ${p}[$pid] = $(cat "/proc/$pid/oom_score_adj" 2>/dev/null)"; done
done
sec "OOM kills (all boots in the persistent journal; steamos is in group adm)"
journalctl -k --no-pager -o short-iso 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -20 || true
# earlyoom logs its thresholds at startup as "sending SIGTERM when mem <= ..."; only
# "sending SIGxxx to process <pid>" lines are actual kills.
EO_KILL='sending SIG[A-Z]+ to process'
journalctl -u earlyoom --no-pager -o short-iso 2>/dev/null | grep -E "$EO_KILL|escalating" | tail -20 || true
echo "(kernel OOM kills: $(journalctl -k --no-pager 2>/dev/null | grep -ciE 'oom-kill|killed process'); earlyoom kills: $(journalctl -u earlyoom --no-pager 2>/dev/null | grep -cE "$EO_KILL"))"
sec "power mode";   sudo -n nvpmodel -q 2>/dev/null || nvpmodel -q 2>/dev/null || echo "nvpmodel -q needs sudo"
sec "vulkan";       vulkaninfo --summary 2>&1 | sed -n '1,60p'
sec "vulkan exts needed by DXVK/VKD3D"
# --summary has no extension lists: query the full device extension list once.
vkexts="$(DISPLAY=${DISPLAY:-:0} vulkaninfo 2>/dev/null | grep -oE '^[[:space:]]+VK_[A-Za-z0-9_]+' | sed 's/^[[:space:]]*//' | sort -u)"
[[ -z $vkexts ]] && echo "(vulkaninfo returned no extensions)"
for e in VK_KHR_maintenance5 VK_KHR_maintenance6 VK_EXT_robustness2 VK_EXT_transform_feedback \
         VK_EXT_depth_clip_enable VK_KHR_load_store_op_none VK_EXT_graphics_pipeline_library \
         VK_KHR_present_wait VK_EXT_descriptor_buffer VK_KHR_swapchain_maintenance1; do
  if grep -qx "$e" <<<"$vkexts"; then echo "yes $e"; else echo "NO  $e"; fi
done
sec "GL";           DISPLAY=${DISPLAY:-:0} glxinfo -B 2>&1 | sed -n '1,20p'
sec "DRM planes (gamescope relevance)"; ls -l /dev/dri; command -v modetest >/dev/null && sudo -n modetest -M nvidia-drm -p 2>/dev/null | grep -cE '^[0-9]+' || echo "modetest not installed (libdrm-tests)"
sec "controller kernel support"
for m in hid_steam xpad hid_playstation hid_nintendo hid_sony uinput; do
  if modinfo "$m" >/dev/null 2>&1 || grep -qw "$m" /proc/modules || [ -d "/sys/module/$m" ]; then echo "yes $m"; else echo "NO  $m"; fi
done
zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(HID_STEAM|JOYSTICK_XPAD|HID_PLAYSTATION|HID_NINTENDO|INPUT_UINPUT)=' || echo "(no /proc/config.gz)"
ls -l /dev/uinput
sec "session";      cat /etc/sddm.conf.d/*.conf; systemctl --no-pager status sddm | head -5
sec "steam";        ls -l ~/.local/share/Steam/steamrtarm64/steam 2>&1; systemctl --no-pager status steamos-orin-firstboot | head -6
sec "suspend support"; cat /sys/power/state; cat /sys/power/mem_sleep 2>/dev/null
if [[ "${1:-}" == "--suspend-test" ]]; then
  sec "suspend test (rtcwake 20 s)"
  sudo rtcwake -m mem -s 20 && echo "RESUMED OK" || echo "SUSPEND FAILED"
  journalctl -b -n 30 --no-pager | grep -iE 'suspend|resume|PM:' || true
fi
echo; echo "report saved to $out"
