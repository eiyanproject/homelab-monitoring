#!/usr/bin/env bash
# Where am I? Read-only check of every step, on whichever node you run it.
#
#   ./status.sh              # auto-detects the mon LXC on this node
#   ./status.sh --mon 192.168.0.200 --ctid 200
#
# Changes nothing. Ends with the single next thing to do.
set -uo pipefail

MON=""; CTID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mon)  MON="$2"; shift 2 ;;
    --ctid) CTID="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v pct >/dev/null || { echo "run this on a Proxmox host" >&2; exit 1; }

G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
ok()   { printf "  ${G}[ok]${N}   %s\n" "$1"; }
todo() { printf "  ${Y}[todo]${N} %s\n" "$1"; NEXT+=("$1"); }
bad()  { printf "  ${R}[!!]${N}   %s\n" "$1"; NEXT+=("$1"); }
info() { printf "         ${D}%s${N}\n" "$1"; }
hdr()  { printf "\n%s\n" "$1"; }
NEXT=()

# --- locate the mon LXC on this node ---------------------------------------
if [[ -z "$CTID" ]]; then
  for c in /etc/pve/lxc/*.conf; do
    [[ -f "$c" ]] || continue
    if grep -qE '^hostname: mon-' "$c" 2>/dev/null; then
      CTID=$(basename "$c" .conf); break
    fi
  done
fi
if [[ -z "$MON" && -n "$CTID" ]]; then
  MON=$(grep -oE 'ip=([0-9]{1,3}\.){3}[0-9]{1,3}' "/etc/pve/lxc/${CTID}.conf" 2>/dev/null | head -1 | cut -d= -f2)
fi

echo "================ $(hostname) ================"
[[ -n "$CTID" ]] && info "mon LXC ${CTID} at ${MON:-unknown}" \
                 || info "no mon-* LXC found on this node"

# --- 1. stack --------------------------------------------------------------
hdr "1. Monitoring stack"
if [[ -z "$CTID" ]] || ! pct status "$CTID" &>/dev/null; then
  todo "mon LXC does not exist on this node - run bootstrap-lxc.sh"
else
  st=$(pct status "$CTID" | awk '{print $2}')
  if [[ "$st" != "running" ]]; then
    bad "mon LXC ${CTID} is ${st}"
  else
    n=$(pct exec "$CTID" -- docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^hm-')
    [[ "$n" -ge 5 ]] && ok "mon LXC ${CTID} running, ${n}/5 containers" \
                     || bad "mon LXC ${CTID} running but only ${n}/5 containers"
    gs=$(pct exec "$CTID" -- docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^hm-grafana')
    [[ "$gs" -eq 1 ]] && ok "Grafana running (http://${MON}:3000)" \
                      || info "Grafana stopped - lean mode. Start it from the panel."
    curl -fsS --max-time 4 -o /dev/null "http://${MON}:8080/" 2>/dev/null \
      && ok "control panel up (http://${MON}:8080)" \
      || info "control panel needs auth or is unreachable"
  fi
fi

# --- 2. PVE metric push ----------------------------------------------------
hdr "2. Proxmox metric push  ${D}(cluster-wide setting)${N}"
ids=$(pvesh get /cluster/metrics/server --output-format json 2>/dev/null \
      | grep -oE '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
if [[ -n "$ids" ]]; then
  ok "metric server(s): ${ids}"
  cnt=$(wc -w <<<"$ids")
  [[ "$cnt" -ge 2 ]] && ok "two targets - push survives either mon LXC dying" \
                     || todo "only one push target: if that mon LXC dies, NO node collects. Add a second once the other node is up."
else
  todo "no metric server - run setup-metric-server.sh"
fi
if [[ -n "$MON" ]]; then
  objs=$(curl -fsS --max-time 4 "http://${MON}:8428/api/v1/label/object/values" 2>/dev/null \
         | grep -oE 'lxc|qemu|nodes|storages' | sort -u | tr '\n' ' ')
  [[ -n "$objs" ]] && ok "PVE metrics arriving: ${objs}" \
                   || todo "no PVE metrics in the store yet"
fi

# --- 3. cron ---------------------------------------------------------------
hdr "3. Scheduled jobs"
cr=$(crontab -l 2>/dev/null)
grep -q 'MAILTO=""' <<<"$cr" && ok 'MAILTO="" set - cron will not queue undeliverable mail' \
                             || todo 'MAILTO="" not set: cron mails every job output to a queue that cannot drain'
if grep -q gen-targets <<<"$cr"; then
  grep -q 'gen-targets.*logger' <<<"$cr" && ok "gen-targets cron (output to syslog)" \
                                         || todo "gen-targets cron present but output is discarded - pipe it to logger"
else todo "gen-targets cron not installed"; fi
if grep -q report-snapshots <<<"$cr"; then
  ok "report-snapshots cron"
else todo "report-snapshots cron not installed (forgotten snapshots go unnoticed)"; fi

# --- 4. snapshots ----------------------------------------------------------
hdr "4. Snapshots"
now=$(date +%s); snaps=0; oldest=0
for c in /etc/pve/lxc/*.conf /etc/pve/qemu-server/*.conf; do
  [[ -f "$c" ]] || continue
  while read -r t; do
    [[ -z "$t" ]] && continue
    snaps=$((snaps+1)); age=$(( (now - t) / 86400 ))
    (( age > oldest )) && oldest=$age
  done < <(awk '/^\[/{n=1} /^snaptime:/ && n {print $2}' "$c" 2>/dev/null)
done
if [[ "$snaps" -eq 0 ]]; then
  ok "no snapshots held"
elif (( oldest > 14 )); then
  todo "${snaps} snapshot(s), oldest ${oldest}d - delete them, they grow and can fill the thin pool"
else
  ok "${snaps} snapshot(s), oldest ${oldest}d"
  info "delete when you no longer need the rollback: pct delsnapshot <id> <name>"
fi

# --- 5. logging ------------------------------------------------------------
hdr "5. Log shipping"
g=0; r=0
for id in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}'); do
  g=$((g+1))
  pct exec "$id" -- test -f /etc/rsyslog.d/90-victorialogs.conf 2>/dev/null && r=$((r+1))
done
[[ "$g" -gt 0 && "$r" -eq "$g" ]] && ok "all ${g} running guests forward logs" \
                                  || todo "${r}/${g} guests forward logs - run setup-guest-logging.sh"
[[ -f /etc/rsyslog.d/90-victorialogs.conf ]] && ok "this host ships its own journal" \
                                             || todo "this host does not ship its journal"
if [[ -n "$MON" ]]; then
  l=$(curl -fsS --max-time 5 "http://${MON}:9428/select/logsql/query" \
        --data-urlencode 'query=_time:10m' --data-urlencode 'limit=1' 2>/dev/null | grep -c '_msg')
  [[ "${l:-0}" -gt 0 ]] && ok "logs arriving (last 10 min)" \
                        || todo "no logs in the last 10 minutes"
fi

# --- 6. alerting -----------------------------------------------------------
hdr "6. Alerting"
if [[ -n "$CTID" ]] && pct status "$CTID" &>/dev/null; then
  if pct exec "$CTID" -- test -f /srv/monitoring/config/grafana/provisioning/alerting/contact-points.yml 2>/dev/null; then
    ch=$(pct exec "$CTID" -- grep -cE '^\s+type: (webhook|discord|telegram)' /srv/monitoring/config/grafana/provisioning/alerting/contact-points.yml 2>/dev/null)
    ok "alert channels configured (${ch} receiver(s))"
  else
    todo "NO alert channels - every rule evaluates but nothing can reach you"
  fi
  mode=$(pct exec "$CTID" -- sh -c 'grep "^ALERTING_DIR=" /srv/monitoring/.env' 2>/dev/null)
  grep -q 'alerting-disabled' <<<"$mode" && info "this node is alerting STANDBY (correct for the second node)" \
                                         || info "this node is alerting PRIMARY"
fi

# --- 7. mirror -------------------------------------------------------------
hdr "7. Mirror"
peer=""
[[ -n "$CTID" ]] && peer=$(pct exec "$CTID" -- sh -c 'grep "^PEER_IP=" /srv/monitoring/.env | cut -d= -f2' 2>/dev/null | tr -d '\r')
for s in "$MON" "$peer"; do
  [[ -z "$s" ]] && continue
  v=$(curl -fsS --max-time 4 "http://${s}:8428/api/v1/label/node/values" 2>/dev/null \
      | grep -oE 'mon-[a-zA-Z0-9-]*' | tr '\n' ' ')
  [[ -n "$v" ]] && ok "store ${s} holds data from: ${v}" \
                || todo "store ${s} unreachable (expected until that node is built)"
done
if [[ -n "$MON" ]]; then
  b=$(curl -fsS --max-time 4 "http://${MON}:8429/metrics" 2>/dev/null \
      | awk '/^vmagent_remotewrite_pending_data_bytes/{s+=$2} END{print int(s)}')
  if [[ -n "$b" && "$b" -gt 10000000 ]]; then
    todo "replication backlog $(( b / 1048576 )) MB - the peer is not accepting writes"
  elif [[ -n "$b" ]]; then
    ok "replication backlog $(( b / 1024 )) KB"
  fi
fi

# --- summary ---------------------------------------------------------------
hdr "================ next ================"
if [[ ${#NEXT[@]} -eq 0 ]]; then
  printf "  ${G}Everything on this node is done.${N}\n\n"
else
  printf "  %d thing(s) outstanding. Start here:\n\n" "${#NEXT[@]}"
  printf "  ${Y}->${N} %s\n" "${NEXT[0]}"
  [[ ${#NEXT[@]} -gt 1 ]] && printf "     %s\n" "${NEXT[@]:1}"
  echo
fi
