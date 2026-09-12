# 출처

이 저장소가 직접 만든 것은 **감시와 알림**이다. 코레일과 실제로 통신하는 층은 가져온 것이고,
수정하지 않았다.

## 가져온 것

| 대상 | 위치 | 출처 | 라이선스 |
|---|---|---|---|
| `ktx_booking.py` | `vendor/` | [NomaDamas/k-skill](https://github.com/NomaDamas/k-skill) 커밋 `86096da` | MIT |
| `korail2` | PyPI (설치) | [carpedm20/korail2](https://github.com/carpedm20/korail2) | BSD |

`ktx_booking.py` 가 하는 일: 코레일 로그인, 열차 조회, **호차별 잔여 좌석**, 예약,
예약 목록, 취소. 결과를 JSON 으로 낸다. 이 저장소의 스크립트는 하위 프로세스로 부르기만 한다.

커밋·해시·크기와 원본 대조 방법은 [vendor/README.md](vendor/README.md) 에 있다.
MIT 라이선스 전문은 [vendor/LICENSE-k-skill](vendor/LICENSE-k-skill) 에 그대로 두었다.

## 왜 복사해 넣었나

처음에는 k-skill 플러그인을 설치해 쓰게 만들었다. 그런데 그 파일이 **upstream 에서 삭제됐다.**
2026-09-12 확인 기준 현재 main 트리에 `ktx_booking.py` 가 없고, `railway-timetable` 로
대체되었다 — 그쪽은 공개 시간표만 파싱하고 실시간 잔여석과 예약을 제공하지 않는다.

따라서 복사해 넣지 않으면 이 저장소는 clone 해도 동작하지 않는다.
동시에, 상류에서 고쳐지기를 기대할 수 없다는 뜻이다. 코레일이 API 를 바꾸면
`vendor/ktx_booking.py` 를 직접 고쳐야 한다.

호차별 잔여 좌석 조회는 `korail2` 에 없는 기능이다. `ktx_booking.py` 가 코레일 모바일 앱의
비공개 호출 주소를 직접 다뤄 구현한 것이고, 이게 없으면 "몇 호차 몇 번이 비었는지"를
알 수 없어 2명을 붙여 앉히는 판정이 불가능하다.

## 이 저장소가 직접 만든 것

- 취소표 감시 루프와 우선순위 열차 선택 (`scripts/watch_ktx_seat.py`)
- 결제 완료와 구입기한 소멸을 구분하는 판정 (`scripts/ktx_watch_once.sh`)
- launchd 등록·해제 (`scripts/install_watch.sh`, `scripts/uninstall_watch.sh`)
- 텔레그램·데스크톱·음성 알림 (`scripts/notify_telegram.sh`, `scripts/ktx_watch_once.sh`)
- Claude Code 스킬 정의 (`SKILL.md`)
