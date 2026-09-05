#!/usr/bin/env bash
# Reports the age of every guest snapshot on this node as a metric, so a
# snapshot you took before some change and forgot about becomes an alert
# instead of a slow leak in the thin pool.
#
# RUN THIS ON THE PROXMOX HOST, from cron:
#   0 * * * * /srv/homelab-monitoring/scripts/report-snapshots.sh --target 192.168.0.200 --quiet
#
# Why report rather than auto-delete: a snapshot is a safety net, and deleting
# safety nets on a timer fails exactly when you need one. --prune exists, but
# it is opt-in, it only ever touches names matching --match, and it refuses to
# run without an explicit age.
#
#   ./report-snapshots.sh --target 192.168.0.200                    # report
#   ./report-snapshots.sh --target ... --prune --older-than 30 --match 'pre-*'
set -euo pipefail

TARGET=""; PORT="8429"; QUIET="no"; PRUNE="no"; OLDER_THAN=""; MATCH="pre-*"

die() { echo "error: $*" >&2; exit 1; }
log() { [[ "$QUIET" == "yes" ]] || echo "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     TARGET="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --prune)      PRUNE="yes"; shift ;;
    --older-than) OLDER_THAN="$2"; shift 2 ;;
    --match)      MATCH="$2"; shift 2 ;;
    --quiet)      QUIET="yes"; shift ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pct >/dev/null || die "pct not found - run this on the Proxmox host"
[[ -n "$TARGET" ]] || die "--target is required (the mon LXC IP on this node)"
if [[ "$PRUNE" == "yes" && -z "$OLDER_THAN" ]]; then
  die "--prune requires --older-than <days>; refusing to guess"
fi

NODE=$(hostname)
NOW=$(date +%s)
PAYLOAD=""
COUNT=0
OLDEST=0

# Snapshot metadata lives in the guest config as [name] sections with a
# snaptime: epoch. `pct listsnapshot` does not give a machine-readable time.
scan() {
  local conf="$1" kind="$2" id name
  id=$(basename "$conf" .conf)
  local guest
  if [[ "$kind" == "lxc" ]]; then
    guest=$(awk -F': ' '/^hostname:/{print $2; exit}' "$conf")
  else
    guest=$(awk -F': ' '/^name:/{print $2; exit}' "$conf")
  fi
  [[ -z "$guest" ]] && guest="$id"

  # Walk sections, remembering the current [name] and its snaptime.
  awk -v id="$id" -v guest="$guest" -v kind="$kind" -v node="$NODE" -v now="$NOW" '
    /^\[/ { name = substr($0, 2, length($0) - 2); next }
    /^snaptime:/ && name != "" && name != "current" {
      age = now - $2
      printf "pve_snapshot_age_seconds{vmid=\"%s\",guest=\"%s\",kind=\"%s\",snapshot=\"%s\",nodename=\"%s\"} %d\n",
             id, guest, kind, name, node, age
    }
  ' "$conf"
}

while read -r conf; do
  [[ -f "$conf" ]] || continue
  PAYLOAD+=$(scan "$conf" lxc)$'\n'
done < <(ls /etc/pve/lxc/*.conf 2>/dev/null || true)

while read -r conf; do
  [[ -f "$conf" ]] || continue
  PAYLOAD+=$(scan "$conf" qemu)$'\n'
done < <(ls /etc/pve/qemu-server/*.conf 2>/dev/null || true)

PAYLOAD=$(printf '%s' "$PAYLOAD" | grep -v '^$' || true)

if [[ -n "$PAYLOAD" ]]; then
  COUNT=$(printf '%s\n' "$PAYLOAD" | wc -l)
  OLDEST=$(printf '%s\n' "$PAYLOAD" | awk '{print $NF}' | sort -n | tail -1)
fi

# Always send the count, so "zero snapshots" is a reported fact rather than an
# absent series that alert rules cannot distinguish from a broken reporter.
PAYLOAD+=$'\n'"pve_snapshot_count{nodename=\"${NODE}\"} ${COUNT}"

if printf '%s\n' "$PAYLOAD" \
     | curl -fsS --max-time 15 --data-binary @- \
       "http://${TARGET}:${PORT}/api/v1/import/prometheus" >/dev/null 2>&1; then
  log "reported ${COUNT} snapshot(s); oldest $(( OLDEST / 86400 ))d"
else
  echo "warning: could not reach http://${TARGET}:${PORT} - metrics not sent" >&2
fi

[[ "$PRUNE" != "yes" ]] && exit 0

# ---- opt-in pruning -------------------------------------------------------
CUTOFF=$(( OLDER_THAN * 86400 ))
log "pruning snapshots matching '${MATCH}' older than ${OLDER_THAN} days"

printf '%s\n' "$PAYLOAD" | grep '^pve_snapshot_age_seconds' | while read -r line; do
  vmid=$(sed -n 's/.*vmid="\([^"]*\)".*/\1/p' <<<"$line")
  kind=$(sed -n 's/.*kind="\([^"]*\)".*/\1/p' <<<"$line")
  snap=$(sed -n 's/.*snapshot="\([^"]*\)".*/\1/p' <<<"$line")
  age=${line##* }
  # shellcheck disable=SC2053
  [[ "$snap" == $MATCH ]] || continue
  (( age > CUTOFF )) || continue
  if [[ "$kind" == "lxc" ]]; then
    pct delsnapshot "$vmid" "$snap" && log "  removed ${snap} on CT ${vmid}"
  else
    qm delsnapshot "$vmid" "$snap" && log "  removed ${snap} on VM ${vmid}"
  fi
done
