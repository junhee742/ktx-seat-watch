#!/bin/bash
# 스케줄러(macOS launchd / Linux systemd user timer)가 주기적으로 호출한다.
# 1회만 조회하고 끝낸다.
# 설정은 전부 환경변수로 받는다(plist 의 EnvironmentVariables, unit 의 Environment=).
# 한 스크립트로 여러 감시를 돌리기 위함이다.
#
# 필수: KTX_DEP KTX_ARR KTX_DATE KTX_TRAINS KTX_STATE_DIR
# 선택: KTX_TIME(0000, 공백으로 여러 조회창 지정 가능) KTX_ADULTS(1) KTX_SEAT_OPTION(general-first)
#       KTX_TRY_WAITING(1) KTX_DEADLINE(YYYYMMDDHHMM) KTX_PYTHON
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

: "${KTX_DEP:?KTX_DEP 필요}"
: "${KTX_ARR:?KTX_ARR 필요}"
: "${KTX_DATE:?KTX_DATE 필요}"
: "${KTX_TRAINS:?KTX_TRAINS 필요}"
: "${KTX_STATE_DIR:?KTX_STATE_DIR 필요}"

KTX_TIME="${KTX_TIME:-0000}"
KTX_ADULTS="${KTX_ADULTS:-1}"
KTX_SEAT_OPTION="${KTX_SEAT_OPTION:-general-first}"
KTX_TRY_WAITING="${KTX_TRY_WAITING:-1}"
KTX_DEADLINE="${KTX_DEADLINE:-}"

mkdir -p "$KTX_STATE_DIR"
FOUND="$KTX_STATE_DIR/found.json"
LOG="$KTX_STATE_DIR/watch.log"
DONE="$KTX_STATE_DIR/purchased.marker"
WAIT="$KTX_STATE_DIR/waitlist.json"      # 잡아둔 예약대기. 좌석이 아니므로 검색을 멈추지 않는다
REVIEW="$KTX_STATE_DIR/review.marker"    # 사람이 확인해야 재개한다

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# 결제가 확인되면 마커를 남기고 다시는 예약하지 않는다.
# 이게 없으면 결제 직후 감시가 되살아나 중복 예약을 만든다.
if [[ -f "$DONE" ]]; then
  exit 0
fi

# 예약대기가 목록에서 사라지는 등, 추측으로 재예약하면 위험한 상태. 사람이 풀어줄 때까지 멈춘다.
if [[ -f "$REVIEW" ]]; then
  exit 0
fi

if [[ -n "$KTX_DEADLINE" ]]; then
  now=$(date +%Y%m%d%H%M)
  if [[ "$now" > "$KTX_DEADLINE" ]]; then
    log "마감 경과, 감시 종료"
    exit 0
  fi
fi

# 자격증명을 읽는다. 이 저장소의 설정이 우선이고, k-skill 쪽 설정도 받아준다.
secrets_loaded=0
for f in "$HOME/.config/ktx-seat-watch/secrets.env" \
         "$HOME/.config/k-skill/secrets.env"; do
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
    secrets_loaded=1
    break
  fi
done
if [[ $secrets_loaded -eq 0 ]]; then
  log "자격증명 파일이 없다: ~/.config/ktx-seat-watch/secrets.env"
  exit 1
fi

# helper 가 기대하는 이름으로 옮긴다. 예전 이름도 그대로 인식한다.
export KSKILL_KTX_ID="${KSKILL_KTX_ID:-${KTX_ID:-}}"
export KSKILL_KTX_PASSWORD="${KSKILL_KTX_PASSWORD:-${KTX_PASSWORD:-}}"
if [[ -z "$KSKILL_KTX_ID" || -z "$KSKILL_KTX_PASSWORD" ]]; then
  log "KTX_ID / KTX_PASSWORD 가 비어 있다"
  exit 1
fi

# launchd·systemd 의 PATH 는 빈약하다. korail2 를 실제로 import 할 수 있는 파이썬을
# 골라야 한다 — 아무 python3 나 잡으면 조용히 실패한다.
PY=""
for cand in "${KTX_PYTHON:-}" \
            "$(command -v python3 2>/dev/null)" \
            /opt/homebrew/bin/python3 \
            /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
            "$HOME/.local/bin/python3" \
            /usr/local/bin/python3 \
            /usr/bin/python3; do
  [[ -n "$cand" && -x "$cand" ]] || continue
  if "$cand" -c 'import korail2' 2>/dev/null; then
    PY="$cand"
    break
  fi
done
if [[ -z "$PY" ]]; then
  log "korail2 를 import 할 수 있는 python3 이 없다. pip install korail2 pycryptodome"
  exit 1
fi

# 코레일 통신을 담당하는 helper.
# 순서는 KTX_HELPER → 저장소 vendor/ → 플러그인 설치 경로.
# KTX_HELPER 는 plist 에 박혀 있고 플러그인이 업데이트되면 그 경로가 사라진다.
# 그래서 없으면 죽지 않고 다음 후보로 넘어간다.
HELPER=""
if [[ -n "${KTX_HELPER:-}" ]]; then
  if [[ -f "$KTX_HELPER" ]]; then
    HELPER="$KTX_HELPER"
  else
    log "KTX_HELPER 경로에 파일이 없다, 다른 후보를 찾는다: $KTX_HELPER"
  fi
fi
if [[ -z "$HELPER" && -f "$HERE/../vendor/ktx_booking.py" ]]; then
  HELPER="$HERE/../vendor/ktx_booking.py"
fi
if [[ -z "$HELPER" ]]; then
  HELPER=$(find "$HOME/.claude/plugins/marketplaces" "$HOME/.claude/plugins/cache" \
             -name ktx_booking.py -type f 2>/dev/null | head -1)
fi
if [[ ! -f "$HELPER" ]]; then
  log "ktx_booking.py 를 찾지 못했다. vendor/ktx_booking.py 가 있는지 확인할 것"
  exit 1
fi

# ── 예약대기 ─────────────────────────────────────────────────────────────
# 예약대기는 좌석이 아니다. 기한이 없고(buy_limit_date=00000000) 결제할 것도 없다.
# 아래 found.json 분기는 실제 좌석 전제로 만들어져 있어서, 예약대기를 거기 두면
#   (1) 검색이 멈추고
#   (2) 목록에서 사라졌을 때 "00000000" 과 비교해 늘 '소멸'로 판정 → 재예약한다.
# 그래서 예약대기는 waitlist.json 으로 따로 들고, 실제 좌석 검색은 계속한다.
jfield() {  # jfield <json파일> <키> : reservation 의 필드
  "$PY" -c "import json,sys;print((json.load(open(sys.argv[1],encoding='utf-8')).get('reservation') or {}).get(sys.argv[2],''))" "$1" "$2" 2>/dev/null
}

if [[ -f "$FOUND" && "$(jfield "$FOUND" buy_limit_date)" == "00000000" ]]; then
  if [[ -f "$WAIT" ]]; then
    mv "$FOUND" "$KTX_STATE_DIR/waitlist.extra-$(date +%m%d-%H%M).json"
    log "예약대기가 이미 있어 추가로 잡힌 예약대기는 별도 보관"
  else
    mv "$FOUND" "$WAIT"
    log "예약대기 $(jfield "$WAIT" reservation_id) 는 좌석이 아니므로 유지한 채 실제 좌석 검색을 계속한다"
  fi
fi

HOLDING_WAIT=0
if [[ -f "$WAIT" ]]; then
  wrid="$(jfield "$WAIT" reservation_id)"
  live="$("$PY" "$HELPER" reservations 2>/dev/null)"
  wstate="$(printf '%s' "$live" | "$PY" -c "
import json,sys
rid=sys.argv[1]
try: rs=json.load(sys.stdin).get('reservations') or []
except Exception: print('ERROR'); raise SystemExit
for r in rs:
    if r.get('reservation_id')==rid:
        print(r.get('buy_limit_date',''), r.get('buy_limit_time','')); break
else:
    print('MISSING')
" "$wrid")"

  case "$wstate" in
    ERROR|"")
      log "예약 목록 조회 실패 — 이번 회차는 예약대기 유지로 간주"
      HOLDING_WAIT=1 ;;
    MISSING)
      # 예약대기는 기한이 없어 '결제됨'과 '취소/소멸'을 시각으로 구분할 수 없다.
      # 배정 직후 결제까지 5분 안에 끝났을 수도 있으므로, 추측으로 재예약하지 않는다.
      touch "$REVIEW"
      log "예약대기 $wrid 가 목록에서 사라짐 — 결제/취소 구분 불가, 확인 전까지 감시 정지"
      "$HERE/notify_telegram.sh" "⏸️ 예약대기가 예약 목록에서 사라졌습니다.

$KTX_DEP→$KTX_ARR $KTX_DATE  예약번호 $wrid

좌석이 배정돼 결제하셨을 수도, 취소됐을 수도 있습니다.
예약대기는 구입기한이 없어 둘을 구분할 수 없으므로, 중복 예약을 막기 위해 이 여정의 감시를 멈췄습니다.
코레일톡에서 확인 후 알려주세요." >> "$LOG" 2>&1
      exit 0 ;;
    00000000\ *)
      HOLDING_WAIT=1 ;;
    *)
      # 좌석이 배정되어 구입기한이 생겼다. 결제 가능한 예약이 된 것이다.
      read -r nbld nblt <<< "$wstate"
      nlimit="$(echo "$nbld" | cut -c5-6 | sed 's/^0//')월 $(echo "$nbld" | cut -c7-8 | sed 's/^0//')일 $(echo "$nblt" | cut -c1-2):$(echo "$nblt" | cut -c3-4)"
      if [[ -f "$FOUND" ]]; then
        # 이미 실제 좌석을 따로 잡아둔 상태. 덮어쓰지 않고 하나만 결제하라고 알린다.
        if [[ ! -f "$KTX_STATE_DIR/waitlist.converted.notified" ]]; then
          touch "$KTX_STATE_DIR/waitlist.converted.notified"
          log "예약대기 $wrid 좌석 배정됨(기한 $nbld $nblt) — 이미 잡아둔 좌석이 있어 둘 중 하나만 결제 필요"
          "$HERE/notify_telegram.sh" "🚨 예약대기에 좌석이 배정됐습니다

$KTX_DEP→$KTX_ARR $KTX_DATE  예약번호 $wrid
구입기한 $nlimit

⚠️ 이 여정은 이미 다른 좌석도 잡혀 있습니다. 둘 중 하나만 결제하고 나머지는 취소하세요." >> "$LOG" 2>&1
        fi
      else
        "$PY" - "$WAIT" "$FOUND" "$nbld" "$nblt" <<'PYEOF'
import json, sys
src, dst, bld, blt = sys.argv[1:5]
d = json.load(open(src, encoding="utf-8"))
d.setdefault("reservation", {}).update(buy_limit_date=bld, buy_limit_time=blt)
d["converted_from_waitlist"] = True
json.dump(d, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
        mv "$WAIT" "$KTX_STATE_DIR/waitlist.converted-$(date +%m%d-%H%M).json"
        log "예약대기 $wrid 좌석 배정됨 — 구입기한 $nbld $nblt, 실제 좌석으로 승격"
        "$HERE/notify_telegram.sh" "🚨 예약대기에 좌석이 배정됐습니다 — 지금 결제하세요

$KTX_DEP→$KTX_ARR $KTX_DATE  예약번호 $wrid
구입기한 $nlimit

기한 안에 코레일톡에서 결제하지 않으면 취소됩니다." >> "$LOG" 2>&1
        /usr/bin/osascript -e 'display notification "예약대기 좌석 배정 — 코레일톡에서 결제하세요" with title "KTX 좌석 확보" sound name "Glass"' 2>/dev/null
        /usr/bin/say -v Yuna "케이티엑스 예약대기에 좌석이 배정됐습니다. 결제하세요." 2>/dev/null
      fi ;;
  esac
fi

# 이미 잡아둔 예약이 있으면 그 운명을 먼저 가린다.
#
# 예약 목록에서 사라지는 경우는 두 가지고, 목록만 봐서는 구분이 안 된다.
#   (1) 결제 완료 — 승차권으로 넘어가면서 예약 목록에서 빠진다
#   (2) 구입기한 경과 — 소멸한다
# 구분하는 유일한 단서는 시각이다. 기한 전에 사라졌으면 결제된 것이다.
# 이 구분을 빼먹으면 결제 직후 감시가 재개되어 좌석을 하나 더 잡는다.
if [[ -f "$FOUND" ]]; then
  read -r rid buy_limit < <("$PY" -c "
import json
try:
    r = (json.load(open('$FOUND', encoding='utf-8')).get('reservation') or {})
    print(r.get('reservation_id',''), r.get('buy_limit_date','') + r.get('buy_limit_time','')[:4])
except Exception:
    print(' ')
" 2>/dev/null)

  if [[ -n "${rid:-}" ]]; then
    if "$PY" "$HELPER" reservations 2>/dev/null | grep -q "$rid"; then
      log "예약 $rid 결제 대기 중 — 검색 보류"
      exit 0   # 아직 예약 목록에 있다. 결제 대기 중이므로 건드리지 않는다.
    fi

    now=$(date +%Y%m%d%H%M)
    if [[ -n "${buy_limit:-}" && "$now" < "$buy_limit" ]]; then
      # 구입기한 전에 사라졌다 = 결제되었다. 여기서 끝낸다.
      touch "$DONE"
      mv "$FOUND" "$KTX_STATE_DIR/found.purchased-$(date +%m%d-%H%M).json" 2>/dev/null
      log "예약 $rid 결제 확인(기한 전 목록에서 사라짐) — 감시 종료"
      "$HERE/notify_telegram.sh" "✅ 결제가 확인되어 좌석 감시를 종료합니다.

예약번호 $rid$([[ -f "$WAIT" ]] && printf '\n\n⚠️ 같은 여정의 예약대기(%s)가 아직 남아 있습니다. 필요 없으면 취소하세요.' "$(jfield "$WAIT" reservation_id)")" >> "$LOG" 2>&1
      exit 0
    fi

    mv "$FOUND" "$KTX_STATE_DIR/found.lapsed-$(date +%m%d-%H%M).json" 2>/dev/null
    log "예약 $rid 구입기한 경과로 소멸 — 감시 재개"
    "$HERE/notify_telegram.sh" "⚠️ 앞서 잡은 예약이 구입기한 경과로 소멸했습니다.

감시를 자동 재개합니다. 자리가 다시 나오면 알려드립니다." >> "$LOG" 2>&1
  fi
fi

# KTX_TRAINS 는 "208 206" 처럼 공백으로 여러 열차를 담는다. 여기서는 쪼개지는 것이 의도다.
# shellcheck disable=SC2206
watch_args=("$KTX_DEP" "$KTX_ARR" "$KTX_DATE"
            --train-no $KTX_TRAINS --time $KTX_TIME --adults "$KTX_ADULTS"
            --seat-option "$KTX_SEAT_OPTION" --once --reserve --emit "$FOUND")
# 예약대기를 이미 들고 있으면 또 대기를 걸지 않고 실제 좌석만 찾는다.
[[ "$KTX_TRY_WAITING" == "1" && $HOLDING_WAIT -eq 0 ]] && watch_args+=(--try-waiting)

out=$("$PY" -u "$HERE/watch_ktx_seat.py" "${watch_args[@]}" 2>&1)
rc=$?
echo "$out" >> "$LOG"

[[ $rc -ne 0 ]] && exit 0

# 코레일 구입기한은 10분이다. 놓치면 예약이 사라지므로 알림을 여러 경로로 건다.
msg=$("$PY" - "$FOUND" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
t = d["train"]
r = d.get("reservation") or {}
dd, dep, arr = t["dep_date"], t["dep_time"], t["arr_time"]
when = f"{int(dd[4:6])}/{int(dd[6:8])} {dep[:2]}:{dep[2:4]} → {arr[:2]}:{arr[2:4]}"
kinds = "/".join(d.get("openings") or []) or "-"
bld, blt = r.get("buy_limit_date", ""), r.get("buy_limit_time", "")
limit = f"{int(bld[4:6])}월 {int(bld[6:8])}일 {blt[:2]}:{blt[2:4]}" if bld else "-"
print(f"""🚨 KTX 좌석 확보 — 지금 결제하세요

{t['train_type']} {t['train_no']}  {t['dep_name']}→{t['arr_name']}
{when}

잡은 것: {kinds}
예약번호 {r.get('reservation_id','-')}
운임 {r.get('price','-')}원 ({r.get('seat_count','?')}석)
구입기한 {limit}

⏰ 10분 안에 코레일톡에서 결제하지 않으면 자동 취소됩니다.""")
PYEOF
)

if [[ -f "$WAIT" ]]; then
  msg="$msg

📌 같은 여정의 예약대기($(jfield "$WAIT" reservation_id))도 남아 있습니다. 좌석을 결제하면 예약대기는 취소하세요."
fi
"$HERE/notify_telegram.sh" "$msg" >> "$LOG" 2>&1 && log "텔레그램 전송 완료"

# 데스크톱 알림은 전부 best-effort 다. 없는 환경이면 조용히 넘어가고,
# 확실한 통로는 위의 텔레그램이다 — Linux 에서는 특히 그렇다.
if [[ "$(uname -s)" == "Darwin" ]]; then
  for _ in 1 2 3; do
    /usr/bin/osascript -e 'display notification "KTX 좌석 예약 완료 — 10분 안에 코레일톡에서 결제!" with title "KTX 좌석 확보" sound name "Glass"' 2>/dev/null
    /usr/bin/say -v Yuna "케이티엑스 자리 예약 완료. 십분 안에 결제하세요." 2>/dev/null
    sleep 3
  done

  /usr/bin/osascript -e 'display dialog "KTX 좌석 예약 완료

코레일톡에서 10분 안에 결제하세요.
결제하지 않으면 예약이 자동 취소됩니다." with title "KTX 좌석 확보" buttons {"확인"} default button 1 with icon caution' 2>/dev/null &
else
  # systemd user service 에는 DBUS 주소가 없을 수 있다. 표준 경로로 채워 준다.
  uid="$(id -u)"
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "/run/user/${uid}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus"
  fi
  # -u critical 은 대부분의 데스크톱에서 직접 닫을 때까지 남는다. 그래서 반복하지 않는다.
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "KTX 좌석 확보" \
      "KTX 좌석 예약 완료 — 10분 안에 코레일톡에서 결제하세요. 결제하지 않으면 자동 취소됩니다." \
      2>/dev/null || log "notify-send 실패(무시)"
  fi
fi
exit 0
