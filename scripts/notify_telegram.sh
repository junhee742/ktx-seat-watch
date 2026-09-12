#!/bin/bash
# 텔레그램으로 한 줄 알림을 보낸다. 토큰은 인자로 받지 않고 환경에서만 읽는다.
# 사용: notify_telegram.sh "보낼 메시지"
set -u

MSG="${1:-}"
[[ -z "$MSG" ]] && exit 1

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID 없음" >&2
  exit 1
fi

# --data-urlencode 로 보내 토큰이 URL 인자로 노출되지 않게 한다.
code=$(curl -s -o /tmp/tg_resp.$$ -w '%{http_code}' -m 20 \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "disable_web_page_preview=true")

if [[ "$code" != "200" ]]; then
  echo "텔레그램 전송 실패 (HTTP $code): $(head -c 200 /tmp/tg_resp.$$)" >&2
  rm -f /tmp/tg_resp.$$
  exit 1
fi
rm -f /tmp/tg_resp.$$
exit 0
