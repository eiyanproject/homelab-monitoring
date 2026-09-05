#!/usr/bin/env bash
# Installs rsyslog in each running LXC and points it at VictoriaLogs.
#
# RUN THIS ON THE PROXMOX HOST.
#
#   ./setup-guest-logging.sh --collector 192.168.0.200          # plan only
#   ./setup-guest-logging.sh --collector 192.168.0.200 --yes    # apply
#   ./setup-guest-logging.sh --collector 192.168.0.200 --yes --only 113,114
#
# Why rsyslog and not a real agent: Grafana Alloy or Vector cost 100-150 MB
# resident per guest. Across a dozen guests that is more memory than the entire
# monitoring stack. rsyslog is ~5-8 MB, reads the journal directly, and speaks
# RFC5424 which VictoriaLogs parses into structured fields on its own.
#
# Guests send to their OWN node's collector. The syslog path has no dual-write,
# so each node holds its own guests' logs - see docs/DEPLOY.md.
set -euo pipefail

COLLECTOR=""; PORT="29514"; CONFIRM="no"; ONLY=""; INCLUDE_HOST="yes"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --collector) COLLECTOR="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --only)      ONLY="$2"; shift 2 ;;
    --no-host)   INCLUDE_HOST="no"; shift ;;
    --yes)       CONFIRM="yes"; shift ;;
    -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pct >/dev/null || die "pct not found - run this on the Proxmox host"
[[ -n "$COLLECTOR" ]] || die "--collector is required (the mon LXC IP on THIS node)"

CONF_LINE="*.* @@${COLLECTOR}:${PORT};RSYSLOG_SyslogProtocol23Format"

# imklog reads the kernel ring buffer, which an unprivileged LXC does not have.
# rsyslog then logs "activation of module imklog failed" at ERROR level on every
# start, in every guest - which would pollute `level:error` searches forever.
# Harmless to disable: nothing in a container can read the host's kernel log.
# Left alone on the PVE host itself, where it is real and useful.
disable_imklog() {
  pct exec "$1" -- sh -c '
    for f in /etc/rsyslog.conf /etc/rsyslog.d/*.conf; do
      [ -f "$f" ] || continue
      sed -i -e "s/^module(load=\"imklog\")/#&/"              -e "s/^\$ModLoad imklog/#&/" "$f" 2>/dev/null || true
    done
  ' 2>/dev/null || true
}

if [[ -n "$ONLY" ]]; then
  IDS=$(tr ',' ' ' <<<"$ONLY")
else
  IDS=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
fi

echo
echo "  Collector   ${COLLECTOR}:${PORT}  (RFC5424 over TCP)"
echo "  Config      ${CONF_LINE}"
echo "  Host        $( [[ "$INCLUDE_HOST" == "yes" ]] && echo "yes - $(hostname) journal included" || echo "skipped" )"
echo
printf "  %-6s %-22s %s\n" CTID HOSTNAME ACTION
for id in $IDS; do
  hn=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')
  if pct exec "$id" -- sh -c 'command -v rsyslogd' >/dev/null 2>&1; then
    act="configure (rsyslog present)"
  elif pct exec "$id" -- sh -c 'command -v apt-get' >/dev/null 2>&1; then
    act="apt install rsyslog, then configure"
  elif pct exec "$id" -- sh -c 'command -v apk' >/dev/null 2>&1; then
    act="apk add rsyslog, then configure"
  else
    act="SKIP - no apt or apk"
  fi
  printf "  %-6s %-22s %s\n" "$id" "$hn" "$act"
done
echo

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Nothing changed. Re-run with --yes to apply."
  exit 0
fi

for id in $IDS; do
  hn=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')
  echo "==> CT ${id} (${hn})"

  if pct exec "$id" -- sh -c 'command -v apt-get' >/dev/null 2>&1; then
    pct exec "$id" -- sh -c '
      command -v rsyslogd >/dev/null 2>&1 && exit 0
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq rsyslog
    ' || { echo "    install failed, skipping"; continue; }
    pct exec "$id" -- sh -c "printf '%s\n' '${CONF_LINE}' > /etc/rsyslog.d/90-victorialogs.conf"
    disable_imklog "$id"
    pct exec "$id" -- sh -c 'systemctl restart rsyslog' \
      || echo "    warning: could not restart rsyslog"

  elif pct exec "$id" -- sh -c 'command -v apk' >/dev/null 2>&1; then
    pct exec "$id" -- sh -c '
      command -v rsyslogd >/dev/null 2>&1 && exit 0
      apk add --no-cache rsyslog
    ' || { echo "    install failed, skipping"; continue; }
    pct exec "$id" -- sh -c "printf '%s\n' '${CONF_LINE}' > /etc/rsyslog.d/90-victorialogs.conf"
    disable_imklog "$id"
    pct exec "$id" -- sh -c 'rc-update add rsyslog default >/dev/null 2>&1; rc-service rsyslog restart' \
      || echo "    warning: could not restart rsyslog"

  else
    echo "    no supported package manager, skipped"
    continue
  fi
  echo "    ok"
done

if [[ "$INCLUDE_HOST" == "yes" ]]; then
  echo "==> Proxmox host $(hostname)"
  if ! command -v rsyslogd >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq rsyslog
  fi
  printf '%s\n' "$CONF_LINE" > /etc/rsyslog.d/90-victorialogs.conf
  systemctl restart rsyslog && echo "    ok"
fi

cat <<NEXT

  Verify in Grafana > Explore > VictoriaLogs:

    *                          all recent lines
    hostname:"${hn:-<a-guest>}"   one guest
    level:error                only errors (parsed from syslog priority)

  If nothing arrives, check the collector is listening:
    ss -lntp | grep ${PORT}

NEXT
