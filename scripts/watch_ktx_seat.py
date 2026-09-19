#!/usr/bin/env python3
"""지정한 열차에 자리가 풀리는지 감시하고, 나오면 즉시 예약한다.

k-skill 의 ktx_booking.py helper 를 그대로 호출한다. 결제는 하지 않는다.
코레일 구입기한은 10분이므로, 예약이 잡히면 호출한 쪽에서 즉시 알려야 한다.

1인 예약이라 인접쌍을 따질 필요가 없다. 일반실·특실·예약대기 중
무엇이든 먼저 열리는 것을 잡는다.

사용 예:
    python3 watch_ktx_seat.py 창원중앙 서울 20260904 --train-no 208 --once
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time

PLUGIN_ROOTS = (
    "~/.claude/plugins/marketplaces",
    "~/.claude/plugins/cache",
)
HELPER_INSTALL_HINT = (
    "코레일 통신을 담당하는 ktx_booking.py 를 찾지 못했다.\n"
    "이 저장소의 vendor/ktx_booking.py 가 있어야 한다 — clone 이 온전한지 확인할 것.\n"
    "다른 위치의 것을 쓰려면 KTX_HELPER 에 경로를 지정한다."
)


def vendored_helper() -> str:
    """저장소에 함께 들어 있는 helper. scripts/ 의 한 층 위 vendor/ 에 있다."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(here), "vendor", "ktx_booking.py")


def resolve_helper() -> str:
    """ktx_booking.py 의 위치를 찾는다.

    순서는 KTX_HELPER → 저장소 vendor/ → 플러그인 설치 경로다.
    KTX_HELPER 는 plist 에 박혀 있을 수 있고, 그 경로는 플러그인이 업데이트되면
    사라진다. 그래서 없으면 죽지 않고 다음 후보로 넘어간다.
    """
    override = os.environ.get("KTX_HELPER")
    if override:
        if os.path.isfile(override):
            return override
        log(f"KTX_HELPER 경로에 파일이 없다, 다른 후보를 찾는다: {override}")

    vendored = vendored_helper()
    if os.path.isfile(vendored):
        return vendored

    for root in PLUGIN_ROOTS:
        base = os.path.expanduser(root)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            if "ktx_booking.py" in filenames:
                return os.path.join(dirpath, "ktx_booking.py")

    log(HELPER_INSTALL_HINT)
    raise SystemExit(2)


_helper_path: str | None = None


def run_helper(args: list[str]) -> tuple[dict | None, str | None]:
    global _helper_path
    if _helper_path is None:
        _helper_path = resolve_helper()
    proc = subprocess.run(
        [sys.executable, _helper_path, *args], capture_output=True, text=True
    )
    raw = proc.stdout.strip()
    if proc.returncode != 0:
        return None, (proc.stderr.strip() or raw)[:400]
    try:
        return json.loads(raw), None
    except json.JSONDecodeError:
        return None, raw[:400]


def log(msg: str) -> None:
    stamp = dt.datetime.now().strftime("%m-%d %H:%M:%S")
    print(f"[{stamp}] {msg}", flush=True)


def openings(train: dict) -> list[str]:
    """이 열차에서 지금 잡을 수 있는 것들."""
    kinds = []
    if train.get("has_general_seat"):
        kinds.append("일반실")
    if train.get("has_special_seat"):
        kinds.append("특실")
    if train.get("has_waiting_list"):
        kinds.append("예약대기")
    return kinds


def check_once(a: argparse.Namespace) -> dict | None:
    # 시간창마다 조회해 합친다. 열차가 어느 창에서 나왔는지도 같이 들고 있어야
    # 예약 호출에 같은 시각을 넘길 수 있다.
    seen: dict[str, tuple[dict, str]] = {}
    total = 0
    for window in a.time:
        search_args = [
            "search", a.dep, a.arr, a.date, window + "00",
            "--adults", str(a.adults),
            "--limit", str(a.limit),
            "--include-no-seats",
            "--include-waiting-list",
        ]
        result, err = run_helper(search_args)
        if result is None:
            log(f"search 실패({window}): {err}")
            continue
        total += result.get("count") or 0
        for t in result["trains"]:
            seen.setdefault(t["train_no"], (t, window))

    if not seen:
        log("조회 실패 — 모든 시간창에서 결과 없음")
        return None

    # --train-no 로 준 순서가 곧 우선순위다. 둘이 동시에 열리면 앞엣것을 잡는다.
    priority = {no: i for i, no in enumerate(a.train_no)}
    targets = [seen[no] for no in a.train_no if no in seen]
    missing = [no for no in a.train_no if no not in seen]
    if missing:
        log(f"조회 결과에 없는 열차: {' '.join(missing)}")
    if not targets:
        log(f"대상 열차 {a.train_no} 가 조회 결과에 없음 (전체 {total}편)")
        return None

    for train, window in targets:
        kinds = openings(train)
        tag = f"{train['train_no']} {train['dep_time'][:2]}:{train['dep_time'][2:4]}"
        if not kinds:
            log(f"  {tag} — 매진, 예약대기도 없음")
            continue

        log(f"★ {tag} — {'/'.join(kinds)} 열림!")
        found = {"train": train, "openings": kinds}
        if not a.reserve:
            return found

        reserve_args = [
            "reserve", a.dep, a.arr, a.date, window + "00",
            "--train-id", train["train_id"],
            "--adults", str(a.adults),
            "--seat-option", a.seat_option,
            "--include-no-seats",
            "--include-waiting-list",
        ]
        if a.try_waiting:
            reserve_args.append("--try-waiting")

        rsv, err = run_helper(reserve_args)
        if rsv is None:
            # 조회와 예약 사이에 팔렸을 수 있다. 감시를 계속한다.
            log(f"  예약 실패, 감시 계속: {err}")
            continue

        reservation = rsv.get("reservation") or {}
        log(f"☆ 예약 성공: {reservation.get('reservation_id')}")
        found["reservation"] = reservation
        return found
    return None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dep")
    p.add_argument("arr")
    p.add_argument("date", help="YYYYMMDD")
    p.add_argument("--train-no", nargs="+", required=True,
                   help="감시할 열차번호. 여러 개 지정 가능")
    p.add_argument("--time", nargs="+", default=["0000"],
                   help="검색 시작 시각 HHMM. 여러 개 지정하면 각각 조회해 합친다. "
                        "코레일 search 는 시작 시각 기준 2시간 남짓만 반환하므로 "
                        "넓은 시간대는 창을 나눠 줘야 한다")
    p.add_argument("--adults", type=int, default=1)
    p.add_argument("--limit", type=int, default=30)
    p.add_argument("--seat-option", default="general-first",
                   choices=["general-first", "general-only",
                            "special-first", "special-only"])
    p.add_argument("--try-waiting", action="store_true",
                   help="좌석이 없으면 예약대기를 시도")
    p.add_argument("--interval", type=int, default=5, help="재조회 간격(분)")
    p.add_argument("--once", action="store_true", help="1회만 확인하고 종료")
    p.add_argument("--reserve", action="store_true",
                   help="자리를 찾으면 즉시 예약한다(결제는 하지 않음)")
    p.add_argument("--emit", default=None, help="발견 결과를 저장할 JSON 경로")
    p.add_argument("--stop-at", default=None,
                   help="YYYYMMDDHHMM. 이 시각이 지나면 감시 종료")
    a = p.parse_args()

    # 코레일 자격증명은 KTX_ID/KTX_PASSWORD 로 받고, helper 가 기대하는
    # 이름으로 옮겨 넘긴다. 예전 이름(KSKILL_*)도 계속 인식한다.
    for ours, theirs in (("KTX_ID", "KSKILL_KTX_ID"),
                         ("KTX_PASSWORD", "KSKILL_KTX_PASSWORD")):
        if os.environ.get(ours) and not os.environ.get(theirs):
            os.environ[theirs] = os.environ[ours]

    if not os.environ.get("KSKILL_KTX_ID"):
        log("코레일 자격증명이 환경에 없다. "
            "~/.config/ktx-seat-watch/secrets.env 에 "
            "KTX_ID / KTX_PASSWORD 를 넣고 source 한 뒤 실행할 것.")
        return 2

    stop_at = None
    if a.stop_at:
        stop_at = dt.datetime.strptime(a.stop_at, "%Y%m%d%H%M")

    mode = "1회 확인" if a.once else f"{a.interval}분 간격"
    log(f"감시: {a.dep}→{a.arr} {a.date} 열차 {' '.join(a.train_no)} "
        f"(조회창 {' '.join(a.time)}) "
        f"{a.adults}명 {a.seat_option}, {mode}"
        + (", 발견 시 자동예약" if a.reserve else "")
        + (", 예약대기 허용" if a.try_waiting else "")
        + (f", {stop_at:%m-%d %H:%M} 까지" if stop_at else ""))

    cycle = 0
    while True:
        cycle += 1
        try:
            found = check_once(a)
        except Exception as exc:  # 네트워크/로그인 일시 오류로 감시가 죽지 않게
            log(f"cycle {cycle} 예외: {exc!r}")
            found = None

        if found:
            if a.emit:
                with open(a.emit, "w", encoding="utf-8") as fh:
                    json.dump(found, fh, ensure_ascii=False, indent=2)
            print("\n=== FOUND ===")
            print(json.dumps(found, ensure_ascii=False, indent=2))
            return 0

        if a.once:
            return 1
        if stop_at and dt.datetime.now() >= stop_at:
            log("stop-at 도달, 감시 종료")
            return 1

        time.sleep(a.interval * 60)


if __name__ == "__main__":
    raise SystemExit(main())
