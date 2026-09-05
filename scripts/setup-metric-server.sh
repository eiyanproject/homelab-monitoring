#!/usr/bin/env bash
# Points this Proxmox node's built-in metric server at the local vmagent, so
# nothing is installed on the hypervisor - PVE pushes by itself.
#
# RUN THIS ON THE PROXMOX HOST, once per node.
#
#   ./setup-metric-server.sh --target 192.168.0.200              # plan only
#   ./setup-metric-server.sh --target 192.168.0.200 --yes        # apply
#   ./setup-metric-server.sh --target 192.168.0.200 --mode otlp  # see below
#
# Two push modes:
#   influx  (default) InfluxDB line protocol, natively ingested by vmagent on
#           /write. Tags become labels; a measurement's fields become
#           <measurement>_<field> metric names.
#   otlp    OpenTelemetry. DOES NOT WORK with VictoriaMetrics on PVE 9.2:
#           /usr/share/perl5/PVE/Status/OpenTelemetry.pm sends
#           'Content-Type' => 'application/json' and has no protobuf path at
#           all, while VictoriaMetrics accepts OTLP over protobuf only. PVE's
#           connection test fails with 400 Bad Request. Kept only in case a
#           later PVE adds protobuf, or you point it at an OTel Collector.
#
# NOTE: /etc/pve/status.cfg is CLUSTER-REPLICATED, so this is not a per-node
# setting. Running this once configures every node, and every node then pushes
# to every enabled target. Each node reports only its own metrics, so a single
# target receives one complete, non-duplicated view of the cluster.
#
# For redundancy, create one entry per mon LXC with different --name values:
#
#   ./setup-metric-server.sh --target 192.168.0.200 --name vmagent-a --yes
#   ./setup-metric-server.sh --target 192.168.0.201 --name vmagent-b --yes
#
# Both nodes then push to both stores. If one mon LXC is down the other still
# receives everything from both nodes, so the push path stops being a single
# point of failure - the same property vmagent's dual-write gives the scrape
# path. Run these from ONE node; the cluster replicates them.
set -euo pipefail

TARGET=""; PORT="8429"; NAME="vmagent"; CONFIRM="no"; MODE="influx"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --name)   NAME="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --yes)    CONFIRM="yes"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pvesh >/dev/null || die "pvesh not found - run this on the Proxmox host"
[[ -n "$TARGET" ]] || die "--target is required (the mon LXC IP on THIS node)"
[[ "$MODE" == "otlp" || "$MODE" == "influx" ]] || die "--mode must be otlp or influx"

if [[ "$MODE" == "otlp" ]] && ! ls /usr/share/perl5/PVE/Status/OpenTelemetry.pm >/dev/null 2>&1; then
  die "OpenTelemetry.pm not present - this build has no OTLP metric server. Use --mode influx."
fi

echo
echo "  This build's metric-server parameters:"
echo "  ---------------------------------------------------------------"
pvesh usage /cluster/metrics/server/{id} --verbose 2>&1 | sed 's/^/  /' || true
echo "  ---------------------------------------------------------------"
echo

if pvesh get /cluster/metrics/server --output-format json 2>/dev/null | grep -q "\"id\":\"${NAME}\""; then
  echo "  A metric server named '${NAME}' already exists. Delete it first with:"
  echo "    pvesh delete /cluster/metrics/server/${NAME}"
  exit 1
fi

if [[ "$MODE" == "otlp" ]]; then
  # Three non-obvious defaults, all confirmed from `pvesh usage` on PVE 9.2:
  #   --otel-protocol defaults to https, and vmagent serves plain http
  #   --otel-path     defaults to /v1/metrics, but vmagent listens on
  #                   /opentelemetry/v1/metrics
  #   there is no --enable; the flag is --disable <boolean>
  CMD=(pvesh create "/cluster/metrics/server/${NAME}"
       --type opentelemetry
       --server "$TARGET"
       --port "$PORT"
       --otel-protocol http
       --otel-path /opentelemetry/v1/metrics
       --disable 0)
  ENDPOINT="http://${TARGET}:${PORT}/opentelemetry/v1/metrics"
else
  # InfluxDB line protocol. vmagent accepts it on /write, /influx/write,
  # /api/v2/write and /influx/api/v2/write, so it does not matter which API
  # version this PVE build chooses. Tags become labels; a measurement's fields
  # become <measurement>_<field> metric names.
  #
  # influxdbproto defaults to UDP, which silently drops data on any error, so
  # http is set explicitly.
  CMD=(pvesh create "/cluster/metrics/server/${NAME}"
       --type influxdb
       --server "$TARGET"
       --port "$PORT"
       --influxdbproto http
       --bucket proxmox
       --disable 0)
  ENDPOINT="http://${TARGET}:${PORT}/write?db=proxmox"
fi

echo "  Mode: ${MODE}"
echo "  Would run:"
printf '    %s\n' "${CMD[*]}"
echo
echo "  Resulting endpoint: ${ENDPOINT}"
echo "  Config is written to /etc/pve/status.cfg (cluster-replicated)."
echo

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Re-run with --yes to apply."
  echo
  echo "  If the parameter list printed above does not match these flags, set it"
  echo "  up in the web UI instead: Datacenter > Metric Server > Add, then"
  echo "  re-run this script to verify."
  exit 0
fi

if ! "${CMD[@]}"; then
  echo
  if [[ "$MODE" == "otlp" ]]; then
    cat <<'FALLBACK'
  The OTLP push was rejected. PVE runs a connection test before saving, so a
  "Connection test failed: 400 Bad Request" means the receiver refused the
  test payload rather than that anything is misconfigured here.

  VictoriaMetrics accepts OTLP over protobuf only, and rejects OTLP/JSON with
  "json encoding isn't supported for opentelemetry format". Check which one
  your receiver saw:

      docker logs hm-vmagent 2>&1 | grep -i opentelemetry | tail -5

  If it says exactly that, this PVE build sends JSON and the two cannot talk.
  Use InfluxDB line protocol instead - same push model, no agent on the host,
  and vmagent ingests it natively:

      ./setup-metric-server.sh --target <ip> --mode influx --yes

FALLBACK
  fi
  exit 1
fi

echo
echo "==> configured. verifying data arrives (up to 90s)..."
# Influx mode names metrics <measurement>_<field> (cpustat_cpu, memory_used),
# so grepping metric names for proxmox|pve finds nothing. PVE does not send a
# db label either - confirmed empty on a real cluster - so the reliable marker
# is the `object` label, which only PVE emits: lxc, qemu, nodes, storages.
if [[ "$MODE" == "influx" ]]; then
  CHECK_URL="http://${TARGET}:8428/api/v1/label/object/values"
  CHECK_PAT='lxc|qemu|nodes|storages'
else
  CHECK_URL="http://${TARGET}:8428/api/v1/label/__name__/values"
  CHECK_PAT='proxmox|pve'
fi

ARRIVED=no
for i in $(seq 1 18); do
  if curl -fsS "$CHECK_URL" 2>/dev/null | grep -qE "$CHECK_PAT"; then
    echo "    metrics are arriving."
    ARRIVED=yes
    break
  fi
  sleep 5
done

if [[ "$ARRIVED" != "yes" ]]; then
  echo "    nothing yet. PVE pushes on its own timer, so give it a few minutes,"
  echo "    then check: curl -s ${CHECK_URL}"
fi

cat <<NEXT

  Now find out what the push actually named things - do NOT assume. The names
  differ from the pve-exporter pve_* series that older guides use, and they
  differ between the two modes as well.

    curl -s 'http://${TARGET}:8428/api/v1/label/__name__/values' \\
      | tr ',' '\\n' | grep -iE 'proxmox|pve|system|cpu|mem' | head -40

  Write your guest-state alert rules against those names. See docs/PVE-ALERTS.md.

  To undo this:  pvesh delete /cluster/metrics/server/${NAME}

NEXT
