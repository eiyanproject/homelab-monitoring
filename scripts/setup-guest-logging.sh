#!/usr/bin/env bash
# Installs rsyslog in each running LXC and points it at VictoriaLogs.
#
# RUN THIS ON THE PROXMOX HOST.
#
#   ./setup-guest-logging.sh --collector 192.168.0.200          # plan only
#   ./setup-guest-logging.sh --collector 192.168.0.200 --yes    # apply
#   ./setup-guest-logging.sh --collector 192.168.0.200 --yes --only 113,114
#   ./setup-guest-logging.sh --collector 192.168.0.200 --yes --docker-journald
#
# --docker-journald: a container's stdout goes to Docker's own json-file by
# default, which rsyslog never sees - so a service that follows the contract
# (JSON lines on stdout) ships NOTHING but dockerd's own chatter. This sets
# Docker's log driver to journald in guests that run Docker and have no
# /etc/docker/daemon.json yet, and restarts Docker. Containers keep their old
# driver until they are recreated (docker compose up -d --force-recreate).
#
# Why rsyslog and not a real agent: Grafana Alloy or Vector cost 100-150 MB
# resident per guest. Across a dozen guests that is more memory than the entire
# monitoring stack. rsyslog is ~5-8 MB, reads the journal directly, and speaks
# RFC5424 which VictoriaLogs parses into structured fields on its own.
#
# Guests send to their OWN node's collector. The syslog path has no dual-write,
# so each node holds its own guests' logs - see docs/DEPLOY.md.
set -euo pipefail

COLLECTOR=""; PORT="29514"; CONFIRM="no"; ONLY=""; INCLUDE_HOST="yes"; HOST_COLLECTOR=""; DOCKER_JOURNALD="no"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --collector) COLLECTOR="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --only)      ONLY="$2"; shift 2 ;;
    --no-host)   INCLUDE_HOST="no"; shift ;;
    # Send THIS host's own journal somewhere else - normally the other node.
    # A node that dies takes its collector with it, so its own last log lines
    # are stranded on the machine that died. Cross-shipping puts them on the
    # survivor, which is the difference between diagnosing a crash and guessing.
    --host-collector) HOST_COLLECTOR="$2"; shift 2 ;;
    --docker-journald) DOCKER_JOURNALD="yes"; shift ;;
    --yes)       CONFIRM="yes"; shift ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pct >/dev/null || die "pct not found - run this on the Proxmox host"
[[ -n "$COLLECTOR" ]] || die "--collector is required (the mon LXC IP on THIS node)"

CONF_LINE="*.* -> ${COLLECTOR}:${PORT} (RFC5424, TCP, queued)"

# The forward action. Written as an action() rather than the one-line
# "*.* @@host:port" so it gets a queue: with the legacy form a collector that
# is restarting (a mon LXC update, a node reboot) suspends the action and the
# lines logged meanwhile are gone - a gap that looks like a quiet guest.
# In-memory only: a disk queue needs a work directory Alpine does not set, and
# its absence is itself logged at error level on every start.
# Plain TCP on the LAN. Newer rsyslog (Alpine, 8.26xx) logs one WARNING per
# start about TCP without TLS whatever is set here - warning, not error, so it
# stays out of level:error.
fwd_action() {  # $1 = collector
  cat <<CONF
action(type="omfwd" target="$1" port="${PORT}" protocol="tcp"
       template="RSYSLOG_SyslogProtocol23Format"
       queue.type="LinkedList" queue.size="20000"
       action.resumeRetryCount="-1" action.resumeInterval="10")
CONF
}

# Guest config: the forward, plus a filter for one line of container noise.
# systemd-networkd-wait-online times out in an LXC (the host owns the link, so
# "online" never comes) and logs it at ERROR. Seen in every guest on both
# nodes, ~3 a day each - a permanent false floor under level:error, the same
# trap as imklog below. Only that exact message is dropped; anything else from
# networkd still ships.
guest_conf() {
  cat <<'CONF'
# homelab-monitoring - written by setup-guest-logging.sh, re-run it to change.
if $programname == 'systemd-networkd-wait-online' and $msg contains 'Timeout occurred while waiting for network connectivity' then stop
CONF
  fwd_action "$COLLECTOR"
}

push_conf() {  # $1 = ctid; config on stdin
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  pct push "$1" "$tmp" /etc/rsyslog.d/90-victorialogs.conf --perms 644
  rm -f "$tmp"
}

# Docker's log driver in a guest: none (no docker), journald, json-file (the
# default - container stdout is NOT shipped) or custom (a daemon.json exists
# and does not say journald: left to you).
docker_state() {
  pct exec "$1" -- sh -c '
    command -v dockerd >/dev/null 2>&1 || { echo none; exit 0; }
    if [ -f /etc/docker/daemon.json ]; then
      grep -q "\"log-driver\"[[:space:]]*:[[:space:]]*\"journald\"" /etc/docker/daemon.json && echo journald || echo custom
    else
      echo json-file
    fi' 2>/dev/null || echo unknown
}

set_docker_journald() {  # $1 = ctid
  # tag = container name, which becomes app_name in VictoriaLogs.
  pct exec "$1" -- sh -c '
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<"JSON"
{"log-driver": "journald", "log-opts": {"tag": "{{.Name}}"}}
JSON
    if command -v systemctl >/dev/null 2>&1; then systemctl restart docker; else rc-service docker restart; fi
  '
}

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
echo "  Host        $( [[ "$INCLUDE_HOST" == "yes" ]] && echo "$(hostname) journal -> ${HOST_COLLECTOR:-$COLLECTOR}${HOST_COLLECTOR:+  (cross-shipped)}" || echo "skipped" )"
echo
printf "  %-6s %-22s %-30s %s\n" CTID HOSTNAME ACTION DOCKER
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
  dk=$(docker_state "$id")
  case "$dk" in
    json-file) if [[ "$DOCKER_JOURNALD" == yes ]]; then dk="json-file -> journald (restarts docker)"
               else dk="json-file: container logs NOT shipped (see --docker-journald)"; fi ;;
    custom)    dk="own daemon.json: set \"log-driver\": \"journald\" by hand" ;;
    none)      dk="-" ;;
  esac
  printf "  %-6s %-22s %-30s %s\n" "$id" "$hn" "$act" "$dk"
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
    guest_conf | push_conf "$id"
    disable_imklog "$id"
    pct exec "$id" -- sh -c 'systemctl restart rsyslog' \
      || echo "    warning: could not restart rsyslog"

  elif pct exec "$id" -- sh -c 'command -v apk' >/dev/null 2>&1; then
    pct exec "$id" -- sh -c '
      command -v rsyslogd >/dev/null 2>&1 && exit 0
      apk add --no-cache rsyslog
    ' || { echo "    install failed, skipping"; continue; }
    guest_conf | push_conf "$id"
    disable_imklog "$id"
    pct exec "$id" -- sh -c 'rc-update add rsyslog default >/dev/null 2>&1; rc-service rsyslog restart' \
      || echo "    warning: could not restart rsyslog"

  else
    echo "    no supported package manager, skipped"
    continue
  fi
  if [[ "$DOCKER_JOURNALD" == yes && "$(docker_state "$id")" == json-file ]]; then
    if set_docker_journald "$id"; then
      echo "    docker now logs to journald - recreate its containers to switch them over"
    else
      echo "    warning: could not switch docker to journald"
    fi
  fi
  echo "    ok"
done

if [[ "$INCLUDE_HOST" == "yes" ]]; then
  echo "==> Proxmox host $(hostname)"
  if ! command -v rsyslogd >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq rsyslog
  fi
  # The host ships to HOST_COLLECTOR when given, so a node that dies leaves
  # its final log lines on the OTHER node instead of on itself.
  if [[ -n "$HOST_COLLECTOR" ]]; then
    echo "    cross-shipping this host journal to ${HOST_COLLECTOR}"
  fi
  { echo "# homelab-monitoring - written by setup-guest-logging.sh, re-run it to change."
    fwd_action "${HOST_COLLECTOR:-$COLLECTOR}"; } > /etc/rsyslog.d/90-victorialogs.conf
  systemctl restart rsyslog && echo "    ok"
fi

cat <<NEXT

  Verify in Grafana > Explore > VictoriaLogs:

    *                          all recent lines
    hostname:"${hn:-<a-guest>}"   one guest
    level:error                only errors (parsed from syslog priority)
    app_name:"<container>"     one Docker container (after --docker-journald)

  A service's own JSON "level" is not the syslog priority: Docker sends stdout
  as info and stderr as err, whatever the JSON says. To filter on the JSON:
    hostname:"catalog" | unpack_json | level:error

  If nothing arrives, check the collector is listening:
    ss -lntp | grep ${PORT}

NEXT
