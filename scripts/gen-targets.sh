#!/usr/bin/env bash
# Regenerates the vmagent scrape target list from what is actually running on
# this Proxmox node, and pushes it into the local mon LXC.
#
# RUN THIS ON THE PROXMOX HOST. Safe to run from cron:
#   */5 * * * * /srv/homelab-monitoring/scripts/gen-targets.sh --ctid 200 --quiet
#
# Only RUNNING guests are listed. A stopped guest is not a failing target -
# guest-down detection comes from the PVE metrics instead, so the two signals
# stay separate and neither creates noise for the other.
set -euo pipefail

CTID=""; PORT="9100"; QUIET="no"; OUT=""

die() { echo "error: $*" >&2; exit 1; }
log() { [[ "$QUIET" == "yes" ]] || echo "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)  CTID="$2"; shift 2 ;;
    --port)  PORT="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    --quiet) QUIET="yes"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pct >/dev/null || die "pct not found - run this on the Proxmox host"
[[ -n "$CTID" || -n "$OUT" ]] || die "--ctid (mon LXC to push into) or --out is required"

NODE=$(hostname)
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

{
  echo "["
  first=1

  # --- LXC guests: read the IP straight from the config where it is static.
  while read -r id; do
    [[ -z "$id" ]] && continue
    cfg=$(pct config "$id" 2>/dev/null) || continue
    name=$(awk -F': ' '/^hostname:/{print $2}' <<<"$cfg")
    ip=$(grep -oE 'ip=([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$cfg" | head -1 | cut -d= -f2)
    # DHCP guests: ask the running container for its own address.
    if [[ -z "$ip" ]]; then
      ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    [[ -z "$ip" ]] && continue
    [[ $first -eq 0 ]] && echo ","
    first=0
    printf '  {"targets":["%s:%s"],"labels":{"job":"node","guest":"%s","kind":"lxc","ctid":"%s","node":"%s"}}' \
      "$ip" "$PORT" "$name" "$id" "$NODE"
  done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')

  # --- VMs: only reachable if the qemu guest agent is enabled.
  while read -r id; do
    [[ -z "$id" ]] && continue
    grep -q '^agent:' <(qm config "$id" 2>/dev/null) || continue
    name=$(qm config "$id" 2>/dev/null | awk -F': ' '/^name:/{print $2}')
    ip=$(qm guest cmd "$id" network-get-interfaces 2>/dev/null \
         | grep -oE '"ip-address" *: *"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
         | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
         | grep -v '^127\.' | head -1) || true
    [[ -z "$ip" ]] && continue
    [[ $first -eq 0 ]] && echo ","
    first=0
    printf '  {"targets":["%s:%s"],"labels":{"job":"node","guest":"%s","kind":"vm","ctid":"%s","node":"%s"}}' \
      "$ip" "$PORT" "$name" "$id" "$NODE"
  done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')

  echo
  echo "]"
} > "$TMP"

count=$(grep -c '"targets"' "$TMP" || true)
log "discovered ${count} running guest(s) on ${NODE}"

if [[ -n "$OUT" ]]; then
  cp "$TMP" "$OUT"
  log "wrote ${OUT}"
fi

if [[ -n "$CTID" ]]; then
  # Only rewrite when the content actually changed, so vmagent is not asked to
  # reload a file that is byte-identical every five minutes.
  cur=$(pct exec "$CTID" -- cat /srv/monitoring/targets/guests.json 2>/dev/null || echo "")
  if [[ "$cur" == "$(cat "$TMP")" ]]; then
    log "unchanged"
  else
    pct push "$CTID" "$TMP" /srv/monitoring/targets/guests.json --perms 644
    log "pushed to CT ${CTID}"
  fi
fi
