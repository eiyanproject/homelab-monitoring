#!/usr/bin/env bash
# Creates the monitoring LXC on a Proxmox node, installs Docker inside it,
# clones this repo and starts the stack.
#
# RUN THIS ON THE PROXMOX HOST (not inside a container).
#
#   ./bootstrap-lxc.sh --ctid 200 --hostname mon-a --ip 192.168.0.200/24 \
#       --gw 192.168.0.1 --peer 192.168.0.201 --role primary
#
# Nothing is created until you pass --yes. Without it you get the plan only.
set -euo pipefail

CTID=""; HOSTNAME_=""; IP=""; GW=""; PEER=""; ROLE="primary"
STORAGE="local-lvm"; DISK="40"; MEMORY="1536"; CORES="2"; BRIDGE="vmbr0"
REPO="https://github.com/eiyanproject/homelab-monitoring.git"
CONFIRM="no"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)     CTID="$2"; shift 2 ;;
    --hostname) HOSTNAME_="$2"; shift 2 ;;
    --ip)       IP="$2"; shift 2 ;;
    --gw)       GW="$2"; shift 2 ;;
    --peer)     PEER="$2"; shift 2 ;;
    --role)     ROLE="$2"; shift 2 ;;
    --storage)  STORAGE="$2"; shift 2 ;;
    --disk)     DISK="$2"; shift 2 ;;
    --memory)   MEMORY="$2"; shift 2 ;;
    --cores)    CORES="$2"; shift 2 ;;
    --bridge)   BRIDGE="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --yes)      CONFIRM="yes"; shift ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pct >/dev/null || die "pct not found - run this on the Proxmox host"
[[ -n "$CTID"      ]] || die "--ctid is required"
[[ -n "$HOSTNAME_" ]] || die "--hostname is required"
[[ -n "$IP"        ]] || die "--ip is required (CIDR, e.g. 192.168.0.200/24)"
[[ -n "$GW"        ]] || die "--gw is required"
[[ -n "$PEER"      ]] || die "--peer is required (the OTHER node's mon LXC IP)"
[[ "$ROLE" == "primary" || "$ROLE" == "standby" ]] || die "--role must be primary or standby"

pct status "$CTID" &>/dev/null && die "CTID $CTID already exists - pick another"

# Find a Debian template that is already downloaded, newest first.
TEMPLATE=$(pveam list local 2>/dev/null | awk '/debian-1[0-9]-standard/ {print $1}' | sort -V | tail -1 || true)
if [[ -z "$TEMPLATE" ]]; then
  echo "No Debian template found locally. Available to download:"
  pveam available --section system | grep debian | tail -5
  die "run: pveam update && pveam download local <template-name>, then re-run"
fi

if [[ "$ROLE" == "primary" ]]; then
  ALERTING_DIR="./config/grafana/provisioning/alerting"
else
  ALERTING_DIR="./config/grafana/provisioning/alerting-disabled"
fi

cat <<PLAN

  Plan
  ----
  node          $(hostname)
  container     $CTID  ($HOSTNAME_)
  resources     ${CORES} cores, ${MEMORY} MB RAM, ${DISK} GB on ${STORAGE}
  network       ${IP} via ${GW} on ${BRIDGE}
  features      nesting=1,keyctl=1  (required for Docker in an unprivileged LXC)
  peer          ${PEER}
  alerting      ${ROLE}  ->  ${ALERTING_DIR}
  template      ${TEMPLATE}
  repo          ${REPO}

PLAN

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Nothing was created. Re-run with --yes to apply."
  exit 0
fi

echo "==> creating container $CTID"
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME_" \
  --cores "$CORES" --memory "$MEMORY" --swap 512 \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW}" \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 --onboot 1

echo "==> starting"
pct start "$CTID"

echo "==> waiting for network"
for _ in $(seq 1 30); do
  pct exec "$CTID" -- getent hosts github.com &>/dev/null && break
  sleep 2
done

echo "==> installing prerequisites"
pct exec "$CTID" -- bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git rsyslog >/dev/null
'

echo "==> installing Docker"
pct exec "$CTID" -- bash -lc 'curl -fsSL https://get.docker.com | sh' >/dev/null

echo "==> cloning repo"
pct exec "$CTID" -- bash -lc "
  set -e
  rm -rf /srv/monitoring
  git clone --depth 1 '${REPO}' /srv/monitoring
"

echo "==> writing .env"
GRAFANA_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
LOCAL_IP="${IP%%/*}"
pct exec "$CTID" -- bash -lc "
  cat > /srv/monitoring/.env <<EOF
NODE_NAME=${HOSTNAME_}
PEER_IP=${PEER}
ALERTING_DIR=${ALERTING_DIR}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PW}
GRAFANA_ROOT_URL=http://${LOCAL_IP}:3000
BIND_ADDR=0.0.0.0
METRICS_RETENTION=90d
LOGS_RETENTION=30d
BUFFER_MAX=2GB
NTFY_URL=
DISCORD_WEBHOOK_URL=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
EOF
  chmod 600 /srv/monitoring/.env
  cp -n /srv/monitoring/targets/guests.json.example   /srv/monitoring/targets/guests.json
  cp -n /srv/monitoring/targets/services.json.example /srv/monitoring/targets/services.json
"

echo "==> starting the stack (first pull takes a few minutes)"
pct exec "$CTID" -- bash -lc 'cd /srv/monitoring && docker compose up -d'

cat <<DONE

  Done.

  Grafana    http://${LOCAL_IP}:3000
  user       admin
  password   ${GRAFANA_PW}          <- save this now, it is not stored anywhere else

  Next:
    1. Add your alert channels to /srv/monitoring/.env on the PRIMARY node,
       then: cd /srv/monitoring && docker compose up -d
    2. ./setup-metric-server.sh --target ${LOCAL_IP}     (on THIS Proxmox host)
    3. ./gen-targets.sh --ctid ${CTID}                   (then add it to cron)
    4. ./setup-guest-logging.sh --collector ${LOCAL_IP}  (installs rsyslog in guests)

DONE
