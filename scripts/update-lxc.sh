#!/usr/bin/env bash
# Updates one node's monitoring from its Proxmox host, in one go:
#   1. pulls this checkout (the host-side scripts)
#   2. optional snapshot of the mon LXC
#   3. runs scripts/update.sh inside the mon LXC (pull, new .env settings,
#      re-render, restart, health check)
#   4. host jobs: installs the gen-targets and report-snapshots crons if they
#      are missing, and refreshes the scrape target list now
#   5. optional (--logging): re-applies guest logging, including Docker
#      container logs - this restarts Docker in guests that run it
#
# RUN THIS ON THE PROXMOX HOST, once per node. Standalone works too - it
# clones (or reuses) the host checkout at /srv/homelab-monitoring:
#
#   curl -fsSLO https://raw.githubusercontent.com/eiyanproject/homelab-monitoring/main/scripts/update-lxc.sh
#   bash update-lxc.sh --yes
#
# From the checkout:
#
#   ./scripts/update-lxc.sh                                  # plan only
#   ./scripts/update-lxc.sh --yes                            # update
#   ./scripts/update-lxc.sh --yes --role standby             # on the standby node, once
#   ./scripts/update-lxc.sh --yes --snapshot --logging       # everything
#
# The mon LXC is found by its /srv/monitoring/.env; pass --ctid if this node
# has more than one. Nothing is changed until you pass --yes.
set -euo pipefail

main() {
cd "$(dirname "$0")/.."
ROOT="$PWD"
CTID=""; ROLE=""; SNAPSHOT="no"; LOGGING="no"; CONFIRM="no"; SELF_PULL="yes"
ORIG_ARGS=("$@")

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)     CTID="$2"; shift 2 ;;
    --role)     ROLE="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="yes"; shift ;;
    --logging)  LOGGING="yes"; shift ;;
    --yes)      CONFIRM="yes"; shift ;;
    --no-self-pull) SELF_PULL="no"; shift ;;
    -h|--help)  sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pct >/dev/null || die "pct not found - run this on the Proxmox host"
[[ -z "$ROLE" || "$ROLE" == primary || "$ROLE" == standby ]] || die "--role must be primary or standby"

# ---- 0. downloaded on its own (curl) --------------------------------------
# This script drives the repo's other host scripts, so it needs a checkout.
# A copy fetched with curl uses (or clones) the host checkout and hands over
# to the copy in there.
HOST_DIR="/srv/homelab-monitoring"
REPO="https://github.com/eiyanproject/homelab-monitoring.git"
if [[ ! -f "$ROOT/scripts/gen-targets.sh" ]]; then
  if ! git -C "$HOST_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -e "$HOST_DIR" ]]; then
      mv "$HOST_DIR" "${HOST_DIR}.pre-git.$(date +%s)"
      echo "moved the old non-git $HOST_DIR aside"
    fi
    command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git >/dev/null; }
    echo "cloning $REPO into $HOST_DIR"
    git clone -q "$REPO" "$HOST_DIR"
  fi
  exec bash "$HOST_DIR/scripts/update-lxc.sh" "${ORIG_ARGS[@]}"
fi

# ---- 1. this checkout ------------------------------------------------------
# Pull first and re-run the new copy, so the host scripts and the container
# are always the same version.
if [[ "$CONFIRM" == yes && "$SELF_PULL" == yes ]] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
    before=$(git -C "$ROOT" rev-parse --short HEAD)
    git -C "$ROOT" pull --ff-only -q || die "could not pull $ROOT"
    after=$(git -C "$ROOT" rev-parse --short HEAD)
    if [[ "$before" != "$after" ]]; then
      echo "host checkout $before -> $after, re-running the new version"
      exec "$ROOT/scripts/update-lxc.sh" "${ORIG_ARGS[@]}" --no-self-pull
    fi
  else
    echo "note: $ROOT has local edits - not pulling the host checkout"
  fi
fi

# ---- find the mon LXC ------------------------------------------------------
if [[ -z "$CTID" ]]; then
  found=()
  while read -r id; do
    pct exec "$id" -- test -f /srv/monitoring/.env 2>/dev/null && found+=("$id")
  done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
  [[ ${#found[@]} -eq 1 ]] || die "found ${#found[@]} mon LXCs on this node (${found[*]:-none}) - pass --ctid"
  CTID=${found[0]}
fi
[[ "$(pct status "$CTID" 2>/dev/null)" == "status: running" ]] || die "CT $CTID is not running"
pct exec "$CTID" -- test -f /srv/monitoring/.env || die "CT $CTID has no /srv/monitoring/.env"

ct_env() { pct exec "$CTID" -- sh -c "grep -E '^$1=' /srv/monitoring/.env | head -1 | cut -d= -f2-" 2>/dev/null | sed 's/^"//; s/"$//' || true; }

HN=$(pct config "$CTID" | awk '/^hostname:/ {print $2}')
CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
PEER=$(ct_env PEER_IP)
pct exec "$CTID" -- git -C /srv/monitoring fetch -q 2>/dev/null || true
CURRENT=$(pct exec "$CTID" -- git -C /srv/monitoring rev-parse --short HEAD 2>/dev/null || echo "?")
LATEST=$(pct exec "$CTID" -- git -C /srv/monitoring rev-parse --short '@{u}' 2>/dev/null || echo "?")
case "$(ct_env ALERTING_DIR)" in *alerting-disabled*) CUR_ROLE=standby ;; *) CUR_ROLE=primary ;; esac
TZ_HOST=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
SNAPNAME="pre_hm_update_$(date +%Y%m%d_%H%M)"

# Cron lines. Output goes to syslog: a cron job whose output is discarded
# fails silently, which is how both stopped unnoticed.
CRON_TARGETS="*/5 * * * * ${ROOT}/scripts/gen-targets.sh --ctid ${CTID} --quiet 2>&1 | logger -t gen-targets"
CRON_SNAPS="7 * * * * ${ROOT}/scripts/report-snapshots.sh --target ${CT_IP} --quiet 2>&1 | logger -t report-snapshots"
CR=$(crontab -l 2>/dev/null || true)
cron_todo=()
grep -q 'MAILTO=""' <<<"$CR"       || cron_todo+=('MAILTO=""')
grep -q 'gen-targets' <<<"$CR"      || cron_todo+=("gen-targets every 5 min")
grep -q 'report-snapshots' <<<"$CR" || cron_todo+=("report-snapshots hourly")

cat <<PLAN

  Plan
  ----
  host scripts  $ROOT $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "(not a git checkout - clone the repo here so it can update itself)")
  mon LXC       $CTID  ($HN, ${CT_IP:-no ip})
  version       $CURRENT -> $LATEST
  role          $CUR_ROLE$( [[ -n "$ROLE" && "$ROLE" != "$CUR_ROLE" ]] && echo " -> $ROLE" )
  snapshot      $( [[ "$SNAPSHOT" == yes ]] && echo "$SNAPNAME" || echo "none (pass --snapshot for a rollback point)" )
  crons         $( [[ ${#cron_todo[@]} -eq 0 ]] && echo "already installed" || echo "add: ${cron_todo[*]}" )
  targets       regenerate guests.json now (only guests answering on :9100)
  guest logs    $( [[ "$LOGGING" == yes ]] && echo "re-apply to every running guest -> ${CT_IP}, this host's journal -> ${PEER:-$CT_IP}; Docker switched to journald (restarts Docker in those guests)" || echo "unchanged (pass --logging to re-apply)" )
  timezone      $TZ_HOST (used for ALERT_TIMEZONE if .env has none)

PLAN

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Nothing was changed. Re-run with --yes to apply."
  exit 0
fi

# ---- 2. snapshot -----------------------------------------------------------
if [[ "$SNAPSHOT" == yes ]]; then
  say "Snapshot $SNAPNAME"
  pct snapshot "$CTID" "$SNAPNAME" --description "before homelab-monitoring update ($CURRENT -> $LATEST)"
fi

# ---- 3. the stack ----------------------------------------------------------
say "Updating the stack in CT $CTID"
ROLE_ARG=(); [[ -n "$ROLE" ]] && ROLE_ARG=(--role "$ROLE")
pct exec "$CTID" -- env HM_TIMEZONE="$TZ_HOST" bash /srv/monitoring/scripts/update.sh "${ROLE_ARG[@]}"

# ---- 4. host jobs ----------------------------------------------------------
say "Host jobs"
chmod +x "$ROOT"/scripts/*.sh
if [[ ${#cron_todo[@]} -gt 0 ]]; then
  {
    grep -q 'MAILTO=""' <<<"$CR" || echo 'MAILTO=""'
    [[ -n "$CR" ]] && printf '%s\n' "$CR"
    grep -q 'gen-targets' <<<"$CR"      || echo "$CRON_TARGETS"
    grep -q 'report-snapshots' <<<"$CR" || echo "$CRON_SNAPS"
  } | crontab -
  echo "  crons installed: ${cron_todo[*]}"
else
  echo "  crons already installed"
fi
"$ROOT/scripts/gen-targets.sh" --ctid "$CTID" | sed 's/^/  /'
"$ROOT/scripts/report-snapshots.sh" --target "$CT_IP" --quiet || echo "  warning: report-snapshots failed"

# ---- 5. guest logging ------------------------------------------------------
if [[ "$LOGGING" == yes ]]; then
  say "Guest logging"
  HOST_ARGS=(); [[ -n "$PEER" ]] && HOST_ARGS=(--host-collector "$PEER")
  "$ROOT/scripts/setup-guest-logging.sh" --collector "$CT_IP" "${HOST_ARGS[@]}" --docker-journald --yes
  echo "  Docker guests switched to journald: recreate their containers"
  echo "  (docker compose up -d --force-recreate in each project) to move them over."
fi

say "Status"
"$ROOT/scripts/status.sh" --mon "$CT_IP" --ctid "$CTID" || true

if [[ "$SNAPSHOT" == yes ]]; then
  cat <<SNAP

  Roll back:         pct rollback $CTID $SNAPNAME
  Delete when happy: pct delsnapshot $CTID $SNAPNAME
  (snapshots older than 14 days raise a monitoring alert)
SNAP
fi
}

main "$@"
