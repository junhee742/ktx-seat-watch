#!/bin/bash
# 감시를 OS 스케줄러에 등록한다. Orca·터미널·Claude 세션과 무관하게 돌아간다.
#   macOS → launchd        (~/Library/LaunchAgents/*.plist)
#   Linux → systemd user timer (~/.config/systemd/user/*.timer)
#
# 사용:
#   install_watch.sh --dep 창원중앙 --arr 서울 --date 20260904 --trains "208 206" \
#                    [--time 0900] [--adults 1] [--seat-option general-first] \
#                    [--no-waiting] [--deadline 202609041020] [--interval 300] [--name me]
#   --name : 같은 열차 목록으로 여러 장을 따로 잡을 때 감시를 구분하는 이름
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"

DEP=""; ARR=""; DATE=""; TRAINS=""
TIME="0000"; ADULTS="1"; SEAT_OPTION="general-first"
TRY_WAITING="1"; DEADLINE=""; INTERVAL="300"; NAME=""

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
    --name) NAME="$2"; shift 2 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

# macOS 기본 bash 는 3.2 라 ${v,,} 를 못 쓴다(bad substitution). tr 로 내린다.
for v in DEP ARR DATE TRAINS; do
  [[ -n "${!v}" ]] || { echo "--$(echo "$v" | tr 'A-Z' 'a-z') 가 필요합니다" >&2; exit 2; }
done

case "$OS" in
  Darwin|Linux) ;;
  *) echo "지원하지 않는 OS: $OS (macOS 와 Linux 만 됩니다)" >&2; exit 1 ;;
esac

LABEL="ktx-seat-watch.${DATE}.${NAME:+$NAME.}$(echo "$TRAINS" | tr ' ' '-')"
STATE_DIR="$HOME/.local/state/ktx-seat-watch/${DATE}-${NAME:+$NAME-}$(echo "$TRAINS" | tr ' ' '-')"
mkdir -p "$STATE_DIR"

# 스케줄러는 PATH 가 빈약해서 python3 를 못 찾거나 korail2 없는 것을 잡을 수 있다.
# 설치 시점에 제대로 된 것을 골라 유닛/plist 에 박아 둔다.
PY_BAKED=""
for cand in "${KTX_PYTHON:-}" "$(command -v python3 2>/dev/null)" \
            /opt/homebrew/bin/python3 \
            /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
            "$HOME/.local/bin/python3" \
            /usr/local/bin/python3 /usr/bin/python3; do
  [[ -n "$cand" && -x "$cand" ]] || continue
  "$cand" -c 'import korail2' 2>/dev/null && { PY_BAKED="$cand"; break; }
done
if [[ -z "$PY_BAKED" ]]; then
  echo "korail2 를 import 할 수 있는 python3 이 없습니다." >&2
  echo "  pip install korail2 pycryptodome" >&2
  exit 1
fi

# 저장소에 함께 들어 있는 것을 기본으로 쓴다. 플러그인 업데이트에 휘둘리지 않는다.
HELPER_BAKED="${KTX_HELPER:-}"
if [[ -n "$HELPER_BAKED" && ! -f "$HELPER_BAKED" ]]; then
  echo "KTX_HELPER 경로에 파일이 없습니다: $HELPER_BAKED" >&2
  HELPER_BAKED=""
fi
if [[ -z "$HELPER_BAKED" && -f "$HERE/../vendor/ktx_booking.py" ]]; then
  HELPER_BAKED="$(cd "$HERE/../vendor" && pwd)/ktx_booking.py"
fi
if [[ -z "$HELPER_BAKED" ]]; then
  HELPER_BAKED=$(find "$HOME/.claude/plugins/marketplaces" "$HOME/.claude/plugins/cache" \
                   -name ktx_booking.py -type f 2>/dev/null | head -1)
fi
if [[ ! -f "$HELPER_BAKED" ]]; then
  echo "ktx_booking.py 를 찾지 못했습니다. vendor/ktx_booking.py 가 있는지 확인하세요." >&2
  exit 1
fi

# Linux 에는 osascript 알림이 없다. 텔레그램이 사실상 유일한 통로가 되므로 미리 일러둔다.
if [[ "$OS" == "Linux" ]]; then
  tg_ok=0
  for f in "$HOME/.config/ktx-seat-watch/secrets.env" \
           "$HOME/.config/k-skill/secrets.env"; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*TELEGRAM_BOT_TOKEN=.+' "$f" \
       && grep -qE '^[[:space:]]*TELEGRAM_CHAT_ID=.+' "$f"; then
      tg_ok=1
    fi
    break
  done
  if [[ $tg_ok -eq 0 ]]; then
    echo "경고: 텔레그램이 설정되지 않았습니다." >&2
    echo "  Linux 에는 macOS 의 osascript 알림·음성이 없습니다. 자리를 잡아도 알 방법이 없습니다." >&2
    echo "  ~/.config/ktx-seat-watch/secrets.env 에 TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID 를 채우세요." >&2
    echo >&2
  fi
fi

if [[ "$OS" == "Darwin" ]]; then
  # ---- macOS: launchd ----
  PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
  mkdir -p "$HOME/Library/LaunchAgents"

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
  SCHEDULER="launchd  ($PLIST)"
  CHECK_CMD="launchctl list | grep ktx-seat-watch"
else
  # ---- Linux: systemd user timer ----
  # $USER 는 systemd·cron·컨테이너에서 비어 있는 일이 흔하다. set -u 와 만나면 죽는다.
  WHO="$(id -un)"
  SD_DIR="$HOME/.config/systemd/user"
  SERVICE="$SD_DIR/${LABEL}.service"
  TIMER="$SD_DIR/${LABEL}.timer"
  mkdir -p "$SD_DIR"

  # StandardOutput=append: 는 systemd 240(2018-12) 부터다. 그 아래면 journald 로 보낸다.
  # 어차피 핵심 로그인 watch.log 는 스크립트가 직접 쓴다.
  SD_VER="$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')"
  LOG_LINES=""
  if [[ "${SD_VER:-x}" =~ ^[0-9]+$ ]] && [[ "$SD_VER" -ge 240 ]]; then
    LOG_LINES="StandardOutput=append:${STATE_DIR}/systemd.out.log
StandardError=append:${STATE_DIR}/systemd.err.log"
  fi

  # 값에 공백이 있다(KTX_TRAINS="208 206"). Environment= 는 따옴표로 감싼다.
  cat > "$SERVICE" <<SERVICEEOF
[Unit]
Description=KTX 취소표 감시 ${DEP}→${ARR} ${DATE} (${TRAINS})

[Service]
Type=oneshot
Environment="KTX_DEP=${DEP}"
Environment="KTX_ARR=${ARR}"
Environment="KTX_DATE=${DATE}"
Environment="KTX_TRAINS=${TRAINS}"
Environment="KTX_TIME=${TIME}"
Environment="KTX_ADULTS=${ADULTS}"
Environment="KTX_SEAT_OPTION=${SEAT_OPTION}"
Environment="KTX_TRY_WAITING=${TRY_WAITING}"
Environment="KTX_DEADLINE=${DEADLINE}"
Environment="KTX_STATE_DIR=${STATE_DIR}"
Environment="KTX_PYTHON=${PY_BAKED}"
Environment="KTX_HELPER=${HELPER_BAKED}"
ExecStart=/bin/bash ${HERE}/ktx_watch_once.sh
${LOG_LINES}
SERVICEEOF

  # OnActiveSec  = 타이머를 켠 직후 1회 (launchd 의 RunAtLoad 대응)
  # OnUnitActiveSec = 직전 실행이 끝난 뒤 INTERVAL (launchd 의 StartInterval 대응)
  # Persistent= 는 OnCalendar 타이머에만 듣는다. 여기선 안 쓴다.
  cat > "$TIMER" <<TIMEREOF
[Unit]
Description=KTX 취소표 감시 타이머 ${DEP}→${ARR} ${DATE} (${TRAINS})

[Timer]
Unit=${LABEL}.service
OnActiveSec=10s
OnUnitActiveSec=${INTERVAL}s
AccuracySec=10s

[Install]
WantedBy=timers.target
TIMEREOF

  if ! systemctl --user daemon-reload 2>/dev/null; then
    echo "systemctl --user 를 쓸 수 없습니다 (user manager 없음)." >&2
    echo "  SSH 로 붙은 세션이면 먼저:" >&2
    echo "    sudo loginctl enable-linger $WHO" >&2
    exit 1
  fi
  systemctl --user enable --now "${LABEL}.timer"

  # 로그아웃해도 계속 돌게 한다. 권한이 없으면 경고만 남기고 진행한다.
  if ! loginctl enable-linger "$WHO" 2>/dev/null; then
    echo "경고: lingering 을 못 켰습니다. 로그아웃하면 감시가 멈춥니다." >&2
    echo "  sudo loginctl enable-linger $WHO" >&2
    echo >&2
  fi
  SCHEDULER="systemd user timer  ($TIMER)"
  CHECK_CMD="systemctl --user list-timers | grep ktx-seat-watch"
fi

echo "등록 완료: $LABEL"
echo "  구간   : $DEP → $ARR  $DATE"
echo "  열차   : $TRAINS (앞엣것 우선)"
echo "  좌석   : $SEAT_OPTION, 예약대기 $([[ "$TRY_WAITING" == "1" ]] && echo 허용 || echo 제외), ${ADULTS}명"
echo "  주기   : ${INTERVAL}초${DEADLINE:+, 마감 $DEADLINE}"
echo "  스케줄러: $SCHEDULER"
echo "  파이썬 : $PY_BAKED"
echo "  helper : $HELPER_BAKED"
echo "  상태   : $STATE_DIR"
echo "  로그   : $STATE_DIR/watch.log"
echo
echo "확인: $CHECK_CMD"
echo "중지: $HERE/uninstall_watch.sh $LABEL"
