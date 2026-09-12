#!/bin/bash
# 감시를 launchd 에 등록한다. Orca·터미널·Claude 세션과 무관하게 돌아간다.
#
# 사용:
#   install_watch.sh --dep 창원중앙 --arr 서울 --date 20260904 --trains "208 206" \
#                    [--time 0900] [--adults 1] [--seat-option general-first] \
#                    [--no-waiting] [--deadline 202609041020] [--interval 300]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

DEP=""; ARR=""; DATE=""; TRAINS=""
TIME="0000"; ADULTS="1"; SEAT_OPTION="general-first"
TRY_WAITING="1"; DEADLINE=""; INTERVAL="300"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dep) DEP="$2"; shift 2 ;;
    --arr) ARR="$2"; shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    --trains) TRAINS="$2"; shift 2 ;;
    --time) TIME="$2"; shift 2 ;;
    --adults) ADULTS="$2"; shift 2 ;;
    --seat-option) SEAT_OPTION="$2"; shift 2 ;;
    --no-waiting) TRY_WAITING="0"; shift ;;
    --deadline) DEADLINE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

for v in DEP ARR DATE TRAINS; do
  [[ -n "${!v}" ]] || { echo "--${v,,} 가 필요합니다" >&2; exit 2; }
done

LABEL="ktx-seat-watch.${DATE}.$(echo "$TRAINS" | tr ' ' '-')"
STATE_DIR="$HOME/.local/state/ktx-seat-watch/${DATE}-$(echo "$TRAINS" | tr ' ' '-')"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"

# launchd 는 PATH 가 빈약해서 python3 를 못 찾거나 korail2 없는 것을 잡을 수 있다.
# 설치 시점에 제대로 된 것을 골라 plist 에 박아 둔다.
PY_BAKED=""
for cand in "${KTX_PYTHON:-}" "$(command -v python3 2>/dev/null)" \
            /opt/homebrew/bin/python3 \
            /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
            /usr/local/bin/python3 /usr/bin/python3; do
  [[ -n "$cand" && -x "$cand" ]] || continue
  "$cand" -c 'import korail2' 2>/dev/null && { PY_BAKED="$cand"; break; }
done
if [[ -z "$PY_BAKED" ]]; then
  echo "korail2 를 import 할 수 있는 python3 이 없습니다." >&2
  echo "  pip install korail2 pycryptodome" >&2
  exit 1
fi

HELPER_BAKED="${KTX_HELPER:-}"
if [[ -z "$HELPER_BAKED" ]]; then
  HELPER_BAKED=$(find "$HOME/.claude/plugins/marketplaces" "$HOME/.claude/plugins/cache" \
                   -name ktx_booking.py -type f 2>/dev/null | head -1)
fi
if [[ ! -f "$HELPER_BAKED" ]]; then
  echo "ktx_booking.py 를 찾지 못했습니다. k-skill 플러그인이 필요합니다:" >&2
  echo "  claude 안에서  /plugin marketplace add NomaDamas/k-skill" >&2
  exit 1
fi

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${HERE}/ktx_watch_once.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>KTX_DEP</key><string>${DEP}</string>
        <key>KTX_ARR</key><string>${ARR}</string>
        <key>KTX_DATE</key><string>${DATE}</string>
        <key>KTX_TRAINS</key><string>${TRAINS}</string>
        <key>KTX_TIME</key><string>${TIME}</string>
        <key>KTX_ADULTS</key><string>${ADULTS}</string>
        <key>KTX_SEAT_OPTION</key><string>${SEAT_OPTION}</string>
        <key>KTX_TRY_WAITING</key><string>${TRY_WAITING}</string>
        <key>KTX_DEADLINE</key><string>${DEADLINE}</string>
        <key>KTX_STATE_DIR</key><string>${STATE_DIR}</string>
        <key>KTX_PYTHON</key><string>${PY_BAKED}</string>
        <key>KTX_HELPER</key><string>${HELPER_BAKED}</string>
    </dict>
    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${STATE_DIR}/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${STATE_DIR}/launchd.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "등록 완료: $LABEL"
echo "  구간   : $DEP → $ARR  $DATE"
echo "  열차   : $TRAINS (앞엣것 우선)"
echo "  좌석   : $SEAT_OPTION, 예약대기 $([[ "$TRY_WAITING" == "1" ]] && echo 허용 || echo 제외), ${ADULTS}명"
echo "  주기   : ${INTERVAL}초${DEADLINE:+, 마감 $DEADLINE}"
echo "  파이썬 : $PY_BAKED"
echo "  상태   : $STATE_DIR"
echo "  로그   : $STATE_DIR/watch.log"
echo
echo "중지: $HERE/uninstall_watch.sh $LABEL"
