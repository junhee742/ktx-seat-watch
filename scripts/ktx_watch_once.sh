#!/bin/bash
# launchd 가 주기적으로 호출한다. 1회만 조회하고 끝낸다.
# 설정은 전부 환경변수로 받는다(plist 의 EnvironmentVariables). 한 스크립트로 여러 감시를 돌리기 위함이다.
#
# 필수: KTX_DEP KTX_ARR KTX_DATE KTX_TRAINS KTX_STATE_DIR
# 선택: KTX_TIME(0000) KTX_ADULTS(1) KTX_SEAT_OPTION(general-first)
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

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# 결제가 확인되면 마커를 남기고 다시는 예약하지 않는다.
# 이게 없으면 결제 직후 감시가 되살아나 중복 예약을 만든다.
if [[ -f "$DONE" ]]; then
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

# launchd 의 PATH 는 빈약하다. korail2 를 실제로 import 할 수 있는 파이썬을
# 골라야 한다 — 아무 python3 나 잡으면 조용히 실패한다.
PY=""
for cand in "${KTX_PYTHON:-}" \
            "$(command -v python3 2>/dev/null)" \
            /opt/homebrew/bin/python3 \
            /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
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
      exit 0   # 아직 예약 목록에 있다. 결제 대기 중이므로 건드리지 않는다.
    fi

    now=$(date +%Y%m%d%H%M)
    if [[ -n "${buy_limit:-}" && "$now" < "$buy_limit" ]]; then
      # 구입기한 전에 사라졌다 = 결제되었다. 여기서 끝낸다.
      touch "$DONE"
      mv "$FOUND" "$KTX_STATE_DIR/found.purchased-$(date +%m%d-%H%M).json" 2>/dev/null
      log "예약 $rid 결제 확인(기한 전 목록에서 사라짐) — 감시 종료"
      "$HERE/notify_telegram.sh" "✅ 결제가 확인되어 좌석 감시를 종료합니다.

예약번호 $rid" >> "$LOG" 2>&1
      exit 0
    fi

    mv "$FOUND" "$KTX_STATE_DIR/found.lapsed-$(date +%m%d-%H%M).json" 2>/dev/null
    log "예약 $rid 구입기한 경과로 소멸 — 감시 재개"
    "$HERE/notify_telegram.sh" "⚠️ 앞서 잡은 예약이 구입기한 경과로 소멸했습니다.

감시를 자동 재개합니다. 자리가 다시 나오면 알려드립니다." >> "$LOG" 2>&1
  fi
fi

watch_args=("$KTX_DEP" "$KTX_ARR" "$KTX_DATE"
            --train-no $KTX_TRAINS --time "$KTX_TIME" --adults "$KTX_ADULTS"
            --seat-option "$KTX_SEAT_OPTION" --once --reserve --emit "$FOUND")
[[ "$KTX_TRY_WAITING" == "1" ]] && watch_args+=(--try-waiting)

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

"$HERE/notify_telegram.sh" "$msg" >> "$LOG" 2>&1 && log "텔레그램 전송 완료"

for _ in 1 2 3; do
  /usr/bin/osascript -e 'display notification "KTX 좌석 예약 완료 — 10분 안에 코레일톡에서 결제!" with title "KTX 좌석 확보" sound name "Glass"' 2>/dev/null
  /usr/bin/say -v Yuna "케이티엑스 자리 예약 완료. 십분 안에 결제하세요." 2>/dev/null
  sleep 3
done

/usr/bin/osascript -e 'display dialog "KTX 좌석 예약 완료

코레일톡에서 10분 안에 결제하세요.
결제하지 않으면 예약이 자동 취소됩니다." with title "KTX 좌석 확보" buttons {"확인"} default button 1 with icon caution' 2>/dev/null &
exit 0
