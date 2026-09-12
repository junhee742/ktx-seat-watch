# 출처

이 저장소는 **감시와 알림**만 한다. 코레일과 실제로 통신하는 부분은 직접 구현하지 않았고,
복사해 오지도 않았다. 설치된 것을 찾아 호출한다.

## 코레일 클라이언트

| 대상 | 출처 | 라이선스 | 역할 |
|---|---|---|---|
| `ktx_booking.py` | [NomaDamas/k-skill](https://github.com/NomaDamas/k-skill) | MIT | 로그인, 열차 조회, 호차별 잔여 좌석, 예약, 예약 목록, 취소 |
| `korail2` | [carpedm20/korail2](https://github.com/carpedm20/korail2) | BSD | 코레일 모바일 API 파이썬 클라이언트 |

`ktx_booking.py` 는 k-skill 플러그인을 설치하면 함께 깔린다. 이 저장소는 `~/.claude/plugins/`
아래에서 그 파일을 찾아 하위 프로세스로 호출하기만 한다. 경로는 `KTX_HELPER` 로 덮어쓸 수 있다.

**왜 복사하지 않았나.** 호차별 잔여 좌석 조회는 `korail2` 에 없는 기능이고,
`ktx_booking.py` 가 코레일 모바일 앱의 비공개 호출 주소를 직접 다뤄서 구현한 것이다.
코레일이 API 를 바꾸면 그 수정은 상류에서 이뤄져야 한다. 복사해 두면 상류가 고쳐도
이쪽 복사본은 고장난 채로 남는다.

## 이 저장소가 직접 만든 것

- 취소표 감시 루프와 우선순위 열차 선택 (`scripts/watch_ktx_seat.py`)
- 결제 완료와 구입기한 소멸을 구분하는 판정 (`scripts/ktx_watch_once.sh`)
- launchd 등록·해제 (`scripts/install_watch.sh`, `scripts/uninstall_watch.sh`)
- 텔레그램·데스크톱·음성 알림 (`scripts/notify_telegram.sh`, `scripts/ktx_watch_once.sh`)
- Claude Code 스킬 정의 (`SKILL.md`)
