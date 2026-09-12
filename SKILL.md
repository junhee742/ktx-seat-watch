---
name: ktx-seat-watch
description: 매진된 KTX 열차의 취소표를 주기적으로 감시해 자리가 나면 즉시 자동 예약하고 텔레그램으로 알린다. 결제는 하지 않는다. 사용자가 "KTX 예매", "기차표 추적", "취소표 감시", "자리 나면 잡아줘", "KTX 예약대기", 또는 특정 구간·날짜·시각의 기차표를 구해달라고 할 때 반드시 이 스킬을 쓴다. 코레일 홈페이지를 브라우저로 열거나 k-skill 의 npx 버전 ktx-booking 을 쓰려 하지 말 것 — 그 경로들은 실시간 잔여석과 예약을 지원하지 않는다. 감시 중지·상태 확인·예약 취소 요청에도 이 스킬을 쓴다.
---

# KTX 좌석 감시·자동예약

매진된 열차에 취소표가 나오는 순간을 잡는다. 사람이 새로고침을 반복하는 대신 launchd 가 주기적으로 조회하고, 자리가 열리면 **예약까지 자동으로 마친 뒤 알린다.** 결제는 하지 않는다 — 코레일 구입기한 10분 안에 사용자가 직접 결제해야 한다.

## 왜 이 스킬이 필요한가

KTX 잔여석을 실시간으로 볼 수 있는 경로는 사실상 하나뿐인데, 그게 눈에 잘 안 띈다.

| 경로 | 실시간 잔여석 | 예약 | 비고 |
|---|---|---|---|
| k-skill 플러그인의 `scripts/ktx_booking.py` | O | O | **이것만 된다** |
| `npx @nomadamas/k-skill@0 exec ktx-booking` | X | X | 공개 XLSX 시간표 전용 |
| 코레일 웹사이트 브라우저 자동화 | 조회만 | X | 로그인·예약대기 확인 불가 |
| `srt-booking` | 설계상 O | X | SRT 전용, endpoint 무응답 상태 |

npx 버전만 보고 "불가능하다"고 판단하기 쉬운데 틀린 결론이다. 반드시 플러그인으로 설치된 helper 를 쓴다.

## 시작 전에 확인할 것

**k-skill 플러그인이 필요하다.** 코레일 통신을 하는 `ktx_booking.py` 가 거기서 온다.
없으면 `claude` 안에서 `/plugin marketplace add NomaDamas/k-skill` 로 설치한다.
스크립트가 `~/.claude/plugins/` 아래를 알아서 뒤지고, 특이한 위치라면 `KTX_HELPER` 로 지정할 수 있다.

`korail2` 와 `pycryptodome` 이 설치된 python3 도 있어야 한다: `pip install korail2 pycryptodome`

`~/.config/ktx-seat-watch/secrets.env` 에 코레일 자격증명을 넣는다. 텔레그램 두 줄은 선택이다 — 없으면 알림만 건너뛴다.

```
KTX_ID=<코레일 회원번호 또는 이메일>
KTX_PASSWORD=<비밀번호>
TELEGRAM_BOT_TOKEN=<선택>
TELEGRAM_CHAT_ID=<선택>
```

예전 이름(`KSKILL_KTX_ID`/`KSKILL_KTX_PASSWORD`)과 `~/.config/k-skill/secrets.env` 위치도 계속 인식한다.

텔레그램은 **메시지를 보내지 말고** 검증한다. 테스트 발송은 사용자에게 불필요한 알림을 남긴다.

```bash
set -a; . ~/.config/ktx-seat-watch/secrets.env; set +a
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getChat" --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
```

## 절차

### 1. 사용자가 원하는 것을 확정한다

구간, 날짜, 열차번호 또는 희망 시각, 인원. 좌석 등급과 예약대기 허용 여부는 기본값(일반실 우선 → 특실 → 예약대기)이 대개 맞지만, 사용자가 "일반실만" 같은 제약을 두면 반영한다.

"이번주 금요일" 같은 상대 날짜는 `date` 로 계산해 확정하고, 사용자에게 절대 날짜로 되짚어 확인한다.

### 2. 지금 상태를 먼저 조회한다

감시를 걸기 전에 현황을 보여준다. 이미 자리가 있으면 감시가 필요 없다.

```bash
set -a; . ~/.config/ktx-seat-watch/secrets.env; set +a
export KSKILL_KTX_ID="$KTX_ID" KSKILL_KTX_PASSWORD="$KTX_PASSWORD"
PY=$(command -v python3)
H=$(find ~/.claude/plugins/marketplaces ~/.claude/plugins/cache \
         -name ktx_booking.py -type f 2>/dev/null | head -1)
$PY "$H" search 창원중앙 서울 20260904 000000 --adults 1 --limit 30 \
    --include-no-seats --include-waiting-list
```

각 열차의 `has_general_seat` / `has_special_seat` / `has_waiting_list` 를 표로 정리해 보여준다. 대상 열차가 매진이고 예약대기도 없으면 감시가 유일한 방법임을 설명한다.

전 열차가 매진이면 못 잡을 가능성이 실재한다는 점을 숨기지 말고 말한다. 대안(다른 시간대 열차, 고속버스)을 함께 제시한다.

### 3. 감시를 등록한다

열차번호는 **우선순위 순서대로** 준다. 여러 편이 동시에 열리면 앞엣것을 잡는다.

```bash
~/.claude/skills/ktx-seat-watch/scripts/install_watch.sh \
  --dep 창원중앙 --arr 서울 --date 20260904 --trains "208 206" \
  --time 0900 --adults 1 --deadline 202609041020
```

주요 옵션: `--seat-option {general,special}-{first,only}`, `--no-waiting`(예약대기 제외), `--interval`(초, 기본 300).

`--deadline` 은 출발 20분 전쯤으로 잡는다. 그 이후엔 잡아도 결제할 시간이 없다.

등록 직후 `RunAtLoad` 로 1회 실행되므로, 로그를 확인해 정상 동작을 보여준다.

```bash
sleep 20 && tail -5 ~/.local/state/ktx-seat-watch/20260904-208-206/watch.log
```

### 4. 자리가 잡히면

스크립트가 알아서 예약하고 텔레그램·데스크톱 알림·음성·모달을 띄운다. 사용자가 결제하면 끝이다.

사용자가 "예약했다" / "결제했다" 고 하면 **말만 믿지 말고 확인한다.** 결제 여부는 예약 목록에서 사라졌는지로 판별한다.

```bash
$PY $H reservations     # 미결제 예약만 나온다. 결제되면 승차권으로 넘어가 목록에서 빠진다
```

목록에 아직 있으면 미결제다. 구입기한까지 남은 시간을 계산해 알린다. 10분은 짧아서 이 확인이 실제로 사고를 막는다.

### 5. 감시를 중지한다

```bash
~/.claude/skills/ktx-seat-watch/scripts/uninstall_watch.sh            # 목록 보기
~/.claude/skills/ktx-seat-watch/scripts/uninstall_watch.sh <label>    # 개별 중지
~/.claude/skills/ktx-seat-watch/scripts/uninstall_watch.sh --all      # 전부 중지
```

중지 후 미결제 예약이 남아 있는지 반드시 확인한다. 남아 있으면 좌석을 붙잡고 있는 것이므로 사용자에게 알리고, 취소할지 묻는다. 취소는 되돌릴 수 없으니 임의로 실행하지 않는다.

```bash
$PY $H cancel <예약번호>
```

## 중복 예약을 만들지 않는 법

이 스킬이 해결하는 가장 중요한 문제다. 실제로 사고가 났던 지점이다.

예약이 코레일 예약 목록에서 사라지는 경우는 두 가지인데 **목록만 봐서는 구분되지 않는다.**

1. 결제 완료 — 승차권으로 넘어가면서 예약 목록에서 빠진다
2. 구입기한 경과 — 소멸한다

"목록에 없으면 소멸"로 판단하면, 결제 직후 감시가 되살아나 **좌석을 하나 더 잡는다.** 사용자는 결제를 마쳤는데 계정에 미결제 예약이 또 생기고, 그만큼 남의 좌석을 붙잡는다.

`ktx_watch_once.sh` 는 구입기한과 현재 시각을 비교해 구분한다 — 기한 **전**에 사라졌으면 결제된 것이므로 `purchased.marker` 를 남기고 감시를 완전히 종료한다. 이 로직을 건드릴 일이 있으면 이 구분을 반드시 유지한다.

## 운영상 알아둘 것

- **launchd 는 Orca·터미널·Claude 세션과 무관하게 돈다.** plist 가 `~/Library/LaunchAgents/` 에 있으므로 로그인할 때마다 자동으로 뜬다.
- **맥이 잠들면 그동안 멈춘다.** `pmset -g custom` 으로 잠자기 설정을 확인하고, 밤새 감시가 필요하면 사용자에게 알린다. 전원 설정 변경은 반드시 확인받고 한다.
- **재부팅하면 로그인해야 다시 뜬다.**
- 상태와 로그는 `~/.local/state/ktx-seat-watch/<날짜>-<열차>/` 에 쌓인다.

## 경계

- 자격증명을 채팅에 출력하거나 인자로 넘기지 않는다. `secrets.env` 를 source 해서 환경으로만 넘긴다.
- 코레일 이용약관은 자동화 접근을 금지한다. 계정 제재 위험을 사용자에게 먼저 알린 뒤 진행한다.
- **결제는 하지 않는다.** 예약(좌석 선점)까지가 끝이다.
- 사용자 본인 계정으로만 동작한다. 다른 사람 계정 자격증명은 다루지 않는다.
- CAPTCHA·본인인증이 뜨면 우회하지 않고 중단한 뒤 사용자에게 넘긴다.
- 조회 주기를 무리하게 줄이지 않는다. 기본 5분이면 취소표를 잡기에 충분하고, 코레일은 매크로 예매를 금지한다. 과도한 조회는 계정 제재 사유가 될 수 있다.
