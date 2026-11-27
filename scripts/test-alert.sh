#!/bin/sh
# Send one test message to every alert channel configured in .env, and print
# what each one answered. Run it on the mon LXC.
#
#   sh scripts/test-alert.sh [project_dir]      default: /srv/monitoring
#
# Why: Grafana's counters can say "63 of 63 notifications failed" without
# saying why. This posts through the SAME url and token Grafana uses, twice:
# from inside the Grafana container (its DNS and network, which is what
# actually fails) and from the LXC itself. If the container fails and the LXC
# works, the problem is Docker's DNS or network, not ntfy.
#
# Read-only apart from the messages it sends. Exit status is non-zero if any
# configured channel failed.
set -u

PROJECT_DIR="${1:-/srv/monitoring}"
ENV_FILE="${PROJECT_DIR}/.env"
[ -f "$ENV_FILE" ] || { echo "test-alert: no $ENV_FILE" >&2; exit 1; }

env_get() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

NTFY=$(env_get NTFY_URL)
NTFY_TOKEN=$(env_get NTFY_TOKEN)
DISCORD=$(env_get DISCORD_WEBHOOK_URL)
TG_TOKEN=$(env_get TELEGRAM_BOT_TOKEN)
TG_CHAT=$(env_get TELEGRAM_CHAT_ID)
NODE=$(env_get NODE_NAME)
MSG="Test from homelab-monitoring on ${NODE:-this node} at $(date '+%Y-%m-%d %H:%M %Z'). If you can read this, the channel works."
FAILED=0
TESTED=0

ok()   { echo "  OK    $*"; }
bad()  { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }

# ---- ntfy ------------------------------------------------------------------
if [ -n "$NTFY" ]; then
  TESTED=$((TESTED + 1))
  echo "ntfy  ${NTFY%%\?*}"
  [ -n "$NTFY_TOKEN" ] || echo "  note  NTFY_TOKEN is empty - a deny-all ntfy answers 403"

  # 1. From inside the Grafana container: the path alerts really take.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx hm-grafana; then
    if [ -n "$NTFY_TOKEN" ]; then
      OUT=$(docker exec hm-grafana wget -S -q -O /dev/null \
              --header "Title: homelab-monitoring test" \
              --header "Authorization: Bearer ${NTFY_TOKEN}" \
              --post-data "$MSG (via Grafana container)" "$NTFY" 2>&1)
    else
      OUT=$(docker exec hm-grafana wget -S -q -O /dev/null \
              --header "Title: homelab-monitoring test" \
              --post-data "$MSG (via Grafana container)" "$NTFY" 2>&1)
    fi
    CODE=$(printf '%s\n' "$OUT" | sed -n 's/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -1)
    case "$CODE" in
      2??) ok "from hm-grafana: HTTP $CODE" ;;
      401|403) bad "from hm-grafana: HTTP $CODE - NTFY_TOKEN missing, wrong, or lacks write access to this topic (ntfy access hm-publish <topic> write-only)" ;;
      413) bad "from hm-grafana: HTTP 413 - message too large for this ntfy" ;;
      "") bad "from hm-grafana: no HTTP answer - $(printf '%s' "$OUT" | tail -1)  (DNS or route from the container; check docker logs hm-grafana and the host resolv.conf)" ;;
      *)  bad "from hm-grafana: HTTP $CODE" ;;
    esac
  else
    echo "  skip  hm-grafana is not running - cannot test the container path"
  fi

  # 2. From the LXC itself.
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$NTFY_TOKEN" ]; then
      CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
               -H "Title: homelab-monitoring test" -H "Authorization: Bearer ${NTFY_TOKEN}" \
               -d "$MSG (via LXC)" "$NTFY")
    else
      CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
               -H "Title: homelab-monitoring test" -d "$MSG (via LXC)" "$NTFY")
    fi
    case "$CODE" in
      2??) ok "from the LXC: HTTP $CODE" ;;
      000) bad "from the LXC: no answer (DNS, route, or the OCI tunnel is down)" ;;
      *)   bad "from the LXC: HTTP $CODE" ;;
    esac
  fi
fi

# ---- Discord ---------------------------------------------------------------
if [ -n "$DISCORD" ]; then
  TESTED=$((TESTED + 1))
  echo "discord"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H 'Content-Type: application/json' \
           -d "{\"content\": \"$MSG\"}" "$DISCORD")
  case "$CODE" in
    2??) ok "HTTP $CODE" ;;
    *)   bad "HTTP $CODE - 401/404 means the webhook was deleted or the URL is wrong" ;;
  esac
fi

# ---- Telegram --------------------------------------------------------------
if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  TESTED=$((TESTED + 1))
  echo "telegram"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
           --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=${MSG}" \
           "https://api.telegram.org/bot${TG_TOKEN}/sendMessage")
  case "$CODE" in
    2??) ok "HTTP $CODE" ;;
    400) bad "HTTP 400 - wrong TELEGRAM_CHAT_ID, or you have not sent the bot a message yet" ;;
    401) bad "HTTP 401 - wrong TELEGRAM_BOT_TOKEN" ;;
    *)   bad "HTTP $CODE" ;;
  esac
fi

echo ""
if [ "$TESTED" -eq 0 ]; then
  echo "test-alert: no channels configured in $ENV_FILE"
  exit 1
fi
if [ "$FAILED" -gt 0 ]; then
  echo "test-alert: $FAILED check(s) failed. Grafana -> Alerting -> Contact points shows Grafana's own last error."
  exit 1
fi
echo "test-alert: every configured channel accepted the message. Check the phone."
echo "            If Grafana's counter still climbs, its rendered payload is the problem:"
echo "            Alerting -> Contact points -> Test, on the primary node."
