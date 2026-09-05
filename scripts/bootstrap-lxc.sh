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
CONFIRM="no"; LEAN="no"; CONTROL_PORT="8080"

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
    --control-port) CONTROL_PORT="$2"; shift 2 ;;
    --lean)     LEAN="yes"; shift ;;
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

# VMIDs are unique across the whole CLUSTER, not per node. `pct status` only
# knows about guests on this host, so on a cluster it would happily accept an
# ID already used on the other node, and pct create then fails confusingly.
if pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
     | grep -qE "\"vmid\":\s*${CTID}[,}]"; then
  suggested=$(pvesh get /cluster/nextid 2>/dev/null || true)
  die "CTID $CTID is already in use somewhere in this cluster${suggested:+ - next free id is $suggested}"
fi
# Fallback for a standalone node where /cluster/resources is unavailable.
pct status "$CTID" &>/dev/null && die "CTID $CTID already exists on this node - pick another"

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
  lean mode     ${LEAN}  $( [[ "$LEAN" == "yes" ]] && echo "(Grafana created but left stopped, saves ~317 MB)" )
  control panel http://${IP%%/*}:${CONTROL_PORT}
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
CONTROL_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
LOCAL_IP="${IP%%/*}"
pct exec "$CTID" -- bash -lc "
  cat > /srv/monitoring/.env <<EOF
NODE_NAME=${HOSTNAME_}
PEER_IP=${PEER}
ALERTING_DIR=${ALERTING_DIR}
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PW}
GRAFANA_ROOT_URL=http://${LOCAL_IP}:3000
BIND_ADDR=0.0.0.0
CONTROL_USER=admin
CONTROL_PASSWORD=${CONTROL_PW}
CONTROL_PORT=${CONTROL_PORT}
PROJECT_DIR=/srv/monitoring
LEAN_MODE=${LEAN}
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

# Alert channels are empty at this point. Generating the provisioning files
# from .env means Grafana starts with no contact points at all, rather than
# with empty ones - which it refuses to load, crash-looping the container.
echo "==> generating alert provisioning"
pct exec "$CTID" -- bash -lc 'sh /srv/monitoring/scripts/render-alerting.sh /srv/monitoring'

# vmagent cannot expand env vars inside -promscrape.config, so the node name is
# substituted into the scrape config here instead.
echo "==> generating scrape config"
pct exec "$CTID" -- bash -lc 'sh /srv/monitoring/scripts/render-scrape.sh /srv/monitoring'

echo "==> starting the stack (first pull and build take a few minutes)"
pct exec "$CTID" -- bash -lc 'cd /srv/monitoring && docker compose up -d --build'

if [[ "$LEAN" == "yes" ]]; then
  # Create Grafana, then stop it. `restart: unless-stopped` respects a manual
  # stop, so it stays down across reboots until you start it from the panel.
  echo "==> lean mode: stopping Grafana (it stays created, ready to start)"
  pct exec "$CTID" -- bash -lc 'docker stop hm-grafana >/dev/null'
fi

cat <<DONE

  Done.

  Control panel  http://${LOCAL_IP}:${CONTROL_PORT}
  user           admin
  password       ${CONTROL_PW}

  Grafana        http://${LOCAL_IP}:3000  $( [[ "$LEAN" == "yes" ]] && echo "(stopped - start it from the panel)" )
  user           admin
  password       ${GRAFANA_PW}

  SAVE BOTH PASSWORDS NOW. They are generated here and stored nowhere else.

  The control panel starts and stops Grafana, promotes this node to primary,
  shows replication backlog, and tails logs - so you do not need a console for
  routine work. It cannot reach the Proxmox host; the steps below still need
  one, and are run HERE, not in the container:

    1. ./setup-metric-server.sh --target ${LOCAL_IP}     (agentless PVE push)
    2. ./gen-targets.sh --ctid ${CTID}                   (then add it to cron)
    3. ./setup-guest-logging.sh --collector ${LOCAL_IP}  (installs rsyslog in guests)

  Alert channels are set in the control panel (Alert channels section). It
  writes .env, regenerates the provisioning files and restarts Grafana. You
  can also change both sets of credentials there.

DONE
