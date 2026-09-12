# vendor/

여기 있는 것은 **내가 쓴 코드가 아니다.** 출처와 라이선스를 그대로 남긴다.

## ktx_booking.py

| | |
|---|---|
| 원저작 | [NomaDamas/k-skill](https://github.com/NomaDamas/k-skill) |
| 라이선스 | MIT — 전문은 [LICENSE-k-skill](LICENSE-k-skill) |
| 가져온 커밋 | `86096dabb9a53a8bbe85cd5f8d4f2233089aef2c` (2026-08-11) |
| 원래 경로 | `scripts/ktx_booking.py` |
| git blob | `308d0ecd5dc6a89084ed086249dfd293091c4e71` |
| sha256 | `95acdbd379f1e2de69a628e8747f5e108bebab95e57767eeeb83c855015ae7e9` |
| 크기 | 50,220 bytes |
| 수정 | **없음.** 위 커밋의 내용 그대로다 |

코레일과 실제로 통신하는 층이다. 로그인, 열차 조회, **호차별 잔여 좌석**, 예약,
예약 목록, 취소를 하고 결과를 JSON 으로 낸다. 이 저장소의 스크립트는 이걸
하위 프로세스로 부르기만 한다.

## 왜 복사해 두었나

**upstream 에서 삭제됐다.** 2026-09-12 확인 기준, NomaDamas/k-skill 의 현재 main
트리에는 `ktx_booking.py` 가 없다. `railway-timetable` 로 대체되었고 그쪽은
공개 시간표만 파싱한다 — 실시간 잔여석과 예약을 제공하지 않는다.

즉 `/plugin marketplace add NomaDamas/k-skill` 를 지금 하는 사람은 이 파일을
받지 못한다. 복사해 두지 않으면 이 저장소는 clone 해도 동작하지 않는다.

상류에서 고쳐지기를 기대할 수 없다는 뜻이기도 하다. 코레일이 API 를 바꾸면
이 복사본을 직접 고쳐야 한다.

## 원본을 다시 확인하는 방법

```bash
git clone https://github.com/NomaDamas/k-skill.git
git -C k-skill show 86096da:scripts/ktx_booking.py | shasum -a 256
# 95acdbd379f1e2de69a628e8747f5e108bebab95e57767eeeb83c855015ae7e9 가 나와야 한다
```

## korail2

`ktx_booking.py` 가 의존한다. 복사하지 않았고 PyPI 에서 설치한다.
[carpedm20/korail2](https://github.com/carpedm20/korail2), BSD License.

```bash
pip install korail2 pycryptodome
```
