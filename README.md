# ktx-seat-watch

매진된 KTX 열차의 취소표를 주기적으로 감시해, 자리가 나오면 **즉시 예약하고 알린다.**
결제는 하지 않는다 — 코레일 구입기한 10분 안에 본인이 코레일톡에서 결제해야 한다.

사람이 새로고침을 반복하는 대신 launchd 가 5분마다 조회한다. 터미널을 닫아도,
Claude 세션을 끝내도 계속 돈다.

Claude Code 스킬로 쓰는 것을 전제로 만들었지만, `scripts/` 안의 스크립트는
Claude 없이 직접 실행해도 된다.

## 먼저 읽을 것

- **코레일 이용약관은 자동화 프로그램 접근을 금지한다.** 계정 정지를 포함한 모든 위험은
  사용하는 사람이 진다. 이 저장소는 어떤 보증도 하지 않는다.
- **공개되지 않은 내부 API 를 쓴다.** 코레일이 바꾸면 예고 없이 멈춘다.
- **본인 승차 목적으로만 쓸 것.** 매크로 예매는 국내에서 암표로 규제되며 입건 사례가 있다.
  조회 주기를 기본값(300초)보다 줄이지 말 것. 5분이면 취소표를 잡기에 충분하다.
- **macOS 전용.** launchd, `osascript`, `say` 에 의존한다. Linux 는 지원하지 않는다.

## 필요한 것

| | |
|---|---|
| macOS | launchd 로 주기 실행 |
| python3 + `korail2` + `pycryptodome` | `pip install korail2 pycryptodome` |
| k-skill 플러그인 | 코레일 통신을 하는 `ktx_booking.py` 를 제공한다 |
| 코레일 계정 | 본인 계정 |
| 텔레그램 봇 | 선택. 없으면 데스크톱 알림만 뜬다 |

코레일 통신은 직접 구현하지 않았다. [NomaDamas/k-skill](https://github.com/NomaDamas/k-skill) 의
`ktx_booking.py` 가 하고, 그 아래 [korail2](https://github.com/carpedm20/korail2) 가 있다.
자세한 출처는 [CREDITS.md](CREDITS.md) 를 보라.

## 설치

```bash
git clone https://github.com/junhee742/ktx-seat-watch.git ~/.claude/skills/ktx-seat-watch
pip install korail2 pycryptodome
```

k-skill 플러그인은 `claude` 안에서 설치한다.

```
/plugin marketplace add NomaDamas/k-skill
```

자격증명을 넣는다.

```bash
mkdir -p ~/.config/ktx-seat-watch
cat > ~/.config/ktx-seat-watch/secrets.env <<'ENV'
KTX_ID=코레일_회원번호_또는_이메일
KTX_PASSWORD=비밀번호
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
ENV
chmod 600 ~/.config/ktx-seat-watch/secrets.env
```

## 사용

Claude Code 를 쓰면 그냥 말하면 된다 — "9월 25일 서울에서 부산 가는 KTX 자리 나면 잡아줘".
스킬이 현황을 조회하고 감시를 등록한다.

직접 쓰려면:

```bash
scripts/install_watch.sh \
  --dep 서울 --arr 부산 --date 20260925 --trains "101 103" \
  --time 0900 --adults 1 --deadline 202609250840
```

| 옵션 | 뜻 |
|---|---|
| `--trains` | 감시할 열차번호. **우선순위 순서대로.** 여러 편이 동시에 열리면 앞엣것을 잡는다 |
| `--time` | 검색 시작 시각 `HHMM` |
| `--adults` | 인원. 기본 1 |
| `--seat-option` | `general-first`(기본) `general-only` `special-first` `special-only` |
| `--no-waiting` | 예약대기를 시도하지 않는다 |
| `--deadline` | `YYYYMMDDHHMM`. 이 시각이 지나면 감시를 멈춘다. 출발 20분 전쯤으로 잡는다 |
| `--interval` | 조회 주기(초). 기본 300. **줄이지 말 것** |

상태 확인과 중지:

```bash
scripts/uninstall_watch.sh          # 등록된 감시 목록
scripts/uninstall_watch.sh --all    # 전부 중지
tail -f ~/.local/state/ktx-seat-watch/<날짜>-<열차>/watch.log
```

## 자리가 잡히면

텔레그램, 데스크톱 알림 3회, 음성 안내, 그리고 닫을 때까지 남는 모달이 뜬다.
**10분 안에 코레일톡에서 결제하지 않으면 예약이 자동 취소된다.** 알림을 여러 경로로
거는 이유가 이것이다.

## 중복 예약을 만들지 않는 법

이 도구가 실제로 해결하는 문제다. 사고가 났던 지점이라 적어 둔다.

예약이 코레일 예약 목록에서 사라지는 경우는 두 가지인데, **목록만 봐서는 구분되지 않는다.**

1. 결제 완료 — 승차권으로 넘어가면서 예약 목록에서 빠진다
2. 구입기한 경과 — 소멸한다

"목록에 없으면 소멸"로 판단하면 결제 직후 감시가 되살아나 **좌석을 하나 더 잡는다.**
결제를 마쳤는데 계정에 미결제 예약이 또 생기고, 그만큼 남의 자리를 붙잡는다.

`ktx_watch_once.sh` 는 구입기한과 현재 시각을 비교해 구분한다. 기한 **전에** 사라졌으면
결제된 것이므로 `purchased.marker` 를 남기고 감시를 완전히 종료한다.
이 로직을 고칠 때 이 구분을 반드시 유지할 것.

## 알아둘 것

- 맥이 잠들면 그동안 멈춘다. 밤새 감시하려면 `pmset` 설정을 확인할 것
- 재부팅하면 로그인해야 다시 뜬다
- 상태와 로그는 `~/.local/state/ktx-seat-watch/<날짜>-<열차>/` 에 쌓인다
- CAPTCHA 나 본인인증이 뜨면 우회하지 않고 멈춘다

## 라이선스

MIT. [LICENSE](LICENSE) 참고.
