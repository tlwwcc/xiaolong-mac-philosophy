#!/usr/bin/env bash
set -euo pipefail

SWITCH_AUDIO="/Applications/SwitchAudio"
SYSTEM_PROFILER="/usr/sbin/system_profiler"

notify() {
  local message="$1"
  /usr/bin/osascript - "$message" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display notification (item 1 of argv) with title "小龙哥Mac哲学" subtitle "切换麦克风"
end run
APPLESCRIPT
  /bin/echo "$message"
}

if [[ ! -x "$SWITCH_AUDIO" ]]; then
  notify "没有找到 SwitchAudio"
  exit 1
fi

DEVICE_LIST="$("$SWITCH_AUDIO" -l 2>&1 || true)"
INPUT_DEVICES="$(/usr/bin/awk '
  /^Input Devices:/ { in_input = 1; next }
  /^Output Devices:/ { in_input = 0 }
  in_input && NF { sub(/^[[:space:]]+/, ""); print }
' <<< "$DEVICE_LIST")"

if [[ -z "$INPUT_DEVICES" ]]; then
  notify "没有检测到输入设备，请先连接 Studio Display 或 DJI 麦克风"
  exit 2
fi

MIC_STUDIO="$(/bin/echo "$INPUT_DEVICES" | /usr/bin/grep -Eim1 "Studio" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
MIC_WIRELESS="$(/bin/echo "$INPUT_DEVICES" | /usr/bin/grep -Eim1 "DJI|Wireless" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"

if [[ -z "$MIC_STUDIO" || -z "$MIC_WIRELESS" ]]; then
  notify "没有找到 Studio / DJI 麦克风；当前输入：$(/bin/echo "$INPUT_DEVICES" | /usr/bin/paste -sd '、' -)"
  exit 3
fi

CURRENT_INPUT="$(/usr/bin/python3 - "$SYSTEM_PROFILER" <<'PY'
import json
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "SPAudioDataType", "-json", "-detailLevel", "mini"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=4,
    )
    if len(result.stdout) > 4 * 1024 * 1024:
        raise ValueError("audio inventory is unexpectedly large")
    payload = json.loads(result.stdout)
    for group in payload.get("SPAudioDataType", []):
        for device in group.get("_items", []):
            if device.get("coreaudio_default_audio_input_device") == "spaudio_yes":
                name = device.get("_name")
                if isinstance(name, str) and 0 < len(name.encode("utf-8")) <= 1024:
                    print(name)
                    raise SystemExit(0)
except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError):
    pass
PY
)"

if [[ "$CURRENT_INPUT" == "$MIC_STUDIO" ]]; then
  TARGET_MIC="$MIC_WIRELESS"
  TARGET_LABEL="DJI 麦"
elif [[ "$CURRENT_INPUT" == "$MIC_WIRELESS" ]]; then
  TARGET_MIC="$MIC_STUDIO"
  TARGET_LABEL="Studio 麦"
else
  # When the current device is unavailable or neither preferred microphone is active,
  # converge on the portable microphone first instead of trusting stale local state.
  TARGET_MIC="$MIC_WIRELESS"
  TARGET_LABEL="DJI 麦"
fi

if ! "$SWITCH_AUDIO" -i "$TARGET_MIC"; then
  notify "切换到${TARGET_LABEL}失败"
  exit 4
fi
notify "已切到${TARGET_LABEL}"
