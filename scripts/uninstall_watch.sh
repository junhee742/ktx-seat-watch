#!/bin/bash
# 감시를 중지하고 launchd 등록을 제거한다.
# 인자 없이 부르면 현재 등록된 ktx-watch 잡을 전부 보여준다.
set -uo pipefail

if [[ $# -eq 0 ]]; then
  echo "등록된 KTX 감시:"
  found=0
  for p in "$HOME"/Library/LaunchAgents/ktx-seat-watch.*.plist; do
    [[ -e "$p" ]] || continue
    found=1
    label="$(basename "$p" .plist)"
    state="$(launchctl list | awk -v l="$label" '$3==l {print "실행중/대기"}')"
    echo "  $label  ${state:-미로드}"
  done
  [[ $found -eq 0 ]] && echo "  없음"
  echo
  echo "중지: $(basename "$0") <label>   또는   $(basename "$0") --all"
  exit 0
fi

stop_one() {
  local label="$1"
  local plist="$HOME/Library/LaunchAgents/${label}.plist"
  if [[ ! -e "$plist" ]]; then
    echo "없음: $label" >&2
    return 1
  fi
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  echo "중지 및 제거: $label"
}

if [[ "$1" == "--all" ]]; then
  for p in "$HOME"/Library/LaunchAgents/ktx-seat-watch.*.plist; do
    [[ -e "$p" ]] || continue
    stop_one "$(basename "$p" .plist)"
  done
else
  stop_one "$1"
fi

echo
echo "잔존 확인:"
launchctl list | grep ktx-seat-watch || echo "  없음"
