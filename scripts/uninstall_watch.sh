#!/bin/bash
# 감시를 중지하고 스케줄러 등록을 제거한다.
#   macOS → launchd, Linux → systemd user timer
# 인자 없이 부르면 현재 등록된 ktx-watch 잡을 전부 보여준다.
set -uo pipefail

OS="$(uname -s)"
LA_DIR="$HOME/Library/LaunchAgents"
SD_DIR="$HOME/.config/systemd/user"

case "$OS" in
  Darwin|Linux) ;;
  *) echo "지원하지 않는 OS: $OS (macOS 와 Linux 만 됩니다)" >&2; exit 1 ;;
esac

list_labels() {
  if [[ "$OS" == "Darwin" ]]; then
    for p in "$LA_DIR"/ktx-seat-watch.*.plist; do
      [[ -e "$p" ]] || continue
      basename "$p" .plist
    done
  else
    for u in "$SD_DIR"/ktx-seat-watch.*.timer; do
      [[ -e "$u" ]] || continue
      basename "$u" .timer
    done
  fi
}

label_state() {
  local label="$1"
  if [[ "$OS" == "Darwin" ]]; then
    launchctl list | awk -v l="$label" '$3==l {print "실행중/대기"}'
  else
    if systemctl --user is-active --quiet "${label}.timer" 2>/dev/null; then
      echo "실행중/대기"
    fi
  fi
}

if [[ $# -eq 0 ]]; then
  echo "등록된 KTX 감시:"
  found=0
  while read -r label; do
    [[ -n "$label" ]] || continue
    found=1
    echo "  $label  $(label_state "$label" | head -1 || true)"
  done < <(list_labels)
  [[ $found -eq 0 ]] && echo "  없음"
  echo
  echo "중지: $(basename "$0") <label>   또는   $(basename "$0") --all"
  exit 0
fi

stop_one() {
  local label="$1"
  if [[ "$OS" == "Darwin" ]]; then
    local plist="$LA_DIR/${label}.plist"
    if [[ ! -e "$plist" ]]; then
      echo "없음: $label" >&2
      return 1
    fi
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
  else
    local timer="$SD_DIR/${label}.timer"
    if [[ ! -e "$timer" ]]; then
      echo "없음: $label" >&2
      return 1
    fi
    systemctl --user disable --now "${label}.timer" 2>/dev/null || true
    rm -f "$timer" "$SD_DIR/${label}.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  echo "중지 및 제거: $label"
}

if [[ "$1" == "--all" ]]; then
  while read -r label; do
    [[ -n "$label" ]] || continue
    stop_one "$label"
  done < <(list_labels)
else
  stop_one "$1"
fi

echo
echo "잔존 확인:"
if [[ "$OS" == "Darwin" ]]; then
  launchctl list | grep ktx-seat-watch || echo "  없음"
else
  systemctl --user list-timers --all 2>/dev/null | grep ktx-seat-watch || echo "  없음"
fi
