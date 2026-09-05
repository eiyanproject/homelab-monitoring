#!/usr/bin/env bash
# Sets up the OUTSIDE tier: ntfy (alert delivery) and the deadman watchdog.
#
# Run on a small always-on host that is NOT part of the homelab - the whole
# point is that it survives the homelab dying.
#
#   sudo ./setup-oci.sh --domain ntfy.example.com --topic homelab-<random>
#   sudo ./setup-oci.sh --domain ntfy.example.com --topic homelab-<random> --yes
#
# Installs as native systemd services, not Docker: on a 1 GB VM the Docker
# daemon alone costs more than both of these together.
#
# It does NOT touch Caddy or cloudflared. Those configs are yours and already
# serving traffic; it prints exactly what to add and you apply it.
set -euo pipefail

DOMAIN=""; TOPIC=""; CONFIRM="no"; NTFY_PORT="2586"; WD_PORT="9911"
EXPECTED="mon-eiyan,mon-eiyan2"; STALE_AFTER="300"
# Pull, not push. A Tailscale subnet router gives this host a route INTO the
# LAN, but gives the LAN no route back - so the nodes cannot reach us, while we
# can reach them. Poll the direction that works.
POLL_TARGETS="mon-eiyan2=http://192.168.0.200:8428/health,mon-eiyan=http://192.168.0.201:8428/health"
POLL_INTERVAL="60"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)      DOMAIN="$2"; shift 2 ;;
    --topic)       TOPIC="$2"; shift 2 ;;
    --expected)    EXPECTED="$2"; shift 2 ;;
    --stale-after) STALE_AFTER="$2"; shift 2 ;;
    --poll)        POLL_TARGETS="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --yes)         CONFIRM="yes"; shift ;;
    -h|--help)     sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "$DOMAIN" ]] || die "--domain is required, e.g. ntfy.example.com"
[[ -n "$TOPIC"  ]] || die "--topic is required - make it long and random"
[[ ${#TOPIC} -ge 10 ]] || die "--topic is too short; anyone who guesses it can read your alerts"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

cat <<PLAN

  Plan
  ----
  ntfy            listens on 127.0.0.1:${NTFY_PORT}, public URL https://${DOMAIN}
  topic           ${TOPIC}
  access          deny-all by default; a token is issued for publishing
  watchdog        listens on 127.0.0.1:${WD_PORT}
  expecting       ${EXPECTED}
  polling         ${POLL_TARGETS}
  poll every      ${POLL_INTERVAL}s
  alerts after    ${STALE_AFTER}s without a sign of life

  Caddy and cloudflared are NOT modified. The snippets are printed at the end.

PLAN

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Re-run with --yes to apply."
  exit 0
fi

# --- ntfy ------------------------------------------------------------------
if ! command -v ntfy >/dev/null 2>&1; then
  echo "==> installing ntfy"
  # From the GitHub release rather than a third-party apt repo: one less key to
  # trust, and the version is visible in the log.
  URL=$(curl -fsSL https://api.github.com/repos/binwiederhier/ntfy/releases/latest \
        | grep -oE 'https://[^"]*linux_amd64\.deb' | head -1)
  [[ -n "$URL" ]] || die "could not find an ntfy .deb in the latest release"
  echo "    $URL"
  curl -fsSL -o /tmp/ntfy.deb "$URL"
  apt-get install -y -qq /tmp/ntfy.deb
  rm -f /tmp/ntfy.deb
else
  echo "==> ntfy already installed ($(ntfy --version 2>/dev/null | head -1))"
fi

echo "==> configuring ntfy"
install -d -m 755 /var/lib/ntfy
cat > /etc/ntfy/server.yml <<EOF
# Managed by setup-oci.sh
base-url: "https://${DOMAIN}"
listen-http: "127.0.0.1:${NTFY_PORT}"
behind-proxy: true

# deny-all means a topic name is not a password. Publishing needs a token,
# reading needs a login - so a leaked topic name alone gives nobody anything.
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"

cache-file: "/var/lib/ntfy/cache.db"
cache-duration: "12h"
attachment-cache-dir: "/var/lib/ntfy/attachments"
EOF
systemctl enable --now ntfy >/dev/null 2>&1 || true
systemctl restart ntfy
sleep 2
systemctl is-active --quiet ntfy || die "ntfy failed to start - journalctl -u ntfy"

echo "==> creating ntfy users"
# publisher: the homelab and the watchdog. Write-only, one topic.
if ! ntfy user list 2>/dev/null | grep -q '^user hm-publish'; then
  PUB_PW=$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
  NTFY_PASSWORD="$PUB_PW" ntfy user add --role=user hm-publish >/dev/null
  echo "    created hm-publish"
fi
ntfy access hm-publish "$TOPIC" write-only >/dev/null

TOKEN=$(ntfy token add --label "homelab publisher" hm-publish 2>/dev/null \
        | grep -oE 'tk_[A-Za-z0-9]+' | head -1 || true)

# reader: you, on your phone.
READER_PW=""
if ! ntfy user list 2>/dev/null | grep -q '^user hm-read'; then
  READER_PW=$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
  NTFY_PASSWORD="$READER_PW" ntfy user add --role=user hm-read >/dev/null
  echo "    created hm-read"
fi
ntfy access hm-read "$TOPIC" read-only >/dev/null

# --- watchdog --------------------------------------------------------------
echo "==> installing watchdog"
id -u hm-watchdog >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin hm-watchdog
install -d -m 755 /opt/hm-watchdog /etc/hm-watchdog
install -m 755 "${SRC_DIR}/watchdog.py" /opt/hm-watchdog/watchdog.py

cat > /etc/hm-watchdog/watchdog.env <<EOF
# Localhost, not the public hostname. The watchdog sits on the same box as
# ntfy, so going out to Cloudflare and back in through the tunnel is both
# slower and fragile - a host often cannot reach its own tunnelled hostname
# (hairpin), and a DNS hiccup would silently stop alerts from a service whose
# entire job is to alert. The public URL is for the nodes at home.
NTFY_URL=http://127.0.0.1:${NTFY_PORT}/${TOPIC}
NTFY_TOKEN=${TOKEN}
EXPECTED=${EXPECTED}
STALE_AFTER=${STALE_AFTER}
POLL_TARGETS=${POLL_TARGETS}
POLL_INTERVAL=${POLL_INTERVAL}
LISTEN=127.0.0.1:${WD_PORT}
STATE_FILE=/var/lib/hm-watchdog/state.json
EOF
chmod 640 /etc/hm-watchdog/watchdog.env
chown root:hm-watchdog /etc/hm-watchdog/watchdog.env

install -m 644 "${SRC_DIR}/hm-watchdog.service" /etc/systemd/system/hm-watchdog.service
systemctl daemon-reload
systemctl enable --now hm-watchdog >/dev/null 2>&1 || true
systemctl restart hm-watchdog
sleep 2
systemctl is-active --quiet hm-watchdog || die "watchdog failed - journalctl -u hm-watchdog"

# --- what you still have to do --------------------------------------------
cat <<NEXT

  Done. Both services are running and bound to localhost only.

  ntfy       127.0.0.1:${NTFY_PORT}
  watchdog   127.0.0.1:${WD_PORT}    $(curl -s "http://127.0.0.1:${WD_PORT}/healthz" || echo "not responding")

  --------------------------------------------------------------------------
  1. ADD TO YOUR Caddyfile
  --------------------------------------------------------------------------
  http://${DOMAIN} {
      reverse_proxy localhost:${NTFY_PORT}
  }

  Then:  sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy

  --------------------------------------------------------------------------
  2. ADD TO cloudflared ingress, ABOVE the http_status:404 catch-all
  --------------------------------------------------------------------------
    - hostname: ${DOMAIN}
      service: http://localhost:80

  Then:  sudo systemctl restart cloudflared
  And:   cloudflared tunnel route dns <TUNNEL_NAME_OR_ID> ${DOMAIN}

  --------------------------------------------------------------------------
  3. CREDENTIALS - save these now, they are not stored anywhere else
  --------------------------------------------------------------------------
  Public topic URL for the homelab nodes:
      https://${DOMAIN}/${TOPIC}
  (the watchdog itself uses http://127.0.0.1:${NTFY_PORT}/${TOPIC} - same topic,
   no round trip through Cloudflare)

  Publish token (goes in the homelab .env as NTFY_TOKEN):
      ${TOKEN:-<none - run: ntfy token add hm-publish>}

  Phone login:   user hm-read${READER_PW:+   password ${READER_PW}}
  Subscribe to:  ${TOPIC}   on server https://${DOMAIN}

  --------------------------------------------------------------------------
  4. ON EACH MONITORING NODE, in /srv/monitoring/.env
  --------------------------------------------------------------------------
  NTFY_URL=https://${DOMAIN}/${TOPIC}
  NTFY_TOKEN=${TOKEN}

  then:  sh scripts/render-alerting.sh /srv/monitoring
         docker restart hm-grafana

  No HEARTBEAT_URL is needed: this watchdog POLLS the nodes rather than waiting
  to be pushed to, because a subnet router routes tailnet -> LAN and not the
  reverse. Nothing has to be installed or opened on the nodes.

  Check what it sees:   curl -s localhost:${WD_PORT}/status

NEXT
