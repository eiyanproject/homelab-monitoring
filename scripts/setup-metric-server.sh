#!/usr/bin/env bash
# Points this Proxmox node's built-in OpenTelemetry metric server at the local
# vmagent. No agent is installed on the hypervisor - PVE 9 pushes by itself.
#
# RUN THIS ON THE PROXMOX HOST, once per node.
#
#   ./setup-metric-server.sh --target 192.168.0.200          # show the plan
#   ./setup-metric-server.sh --target 192.168.0.200 --yes    # apply
#
# Each node should point at its OWN local mon LXC, never the peer's: local
# collection has no network dependency, so a link failure between nodes cannot
# lose data - the local agent keeps collecting and buffering.
set -euo pipefail

TARGET=""; PORT="8429"; NAME="vmagent"; CONFIRM="no"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --name)   NAME="$2"; shift 2 ;;
    --yes)    CONFIRM="yes"; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pvesh >/dev/null || die "pvesh not found - run this on the Proxmox host"
[[ -n "$TARGET" ]] || die "--target is required (the mon LXC IP on THIS node)"

if ! ls /usr/share/perl5/PVE/Status/OpenTelemetry.pm >/dev/null 2>&1; then
  die "OpenTelemetry.pm not present - this PVE build has no OTLP metric server. Use prometheus-pve-exporter instead (see docs/DEPLOY.md)."
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

echo "  Would run:"
printf '    %s\n' "${CMD[*]}"
echo
echo "  Resulting endpoint: http://${TARGET}:${PORT}/opentelemetry/v1/metrics"
echo "  Config is written to /etc/pve/status.cfg (cluster-replicated)."
echo

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Re-run with --yes to apply."
  echo
  echo "  If the parameter list printed above does not match these flags, set it"
  echo "  up in the web UI instead: Datacenter > Metric Server > Add >"
  echo "  OpenTelemetry, then re-run this script to verify."
  exit 0
fi

"${CMD[@]}"

echo
echo "==> configured. verifying data arrives (up to 90s)..."
for i in $(seq 1 18); do
  if curl -fsS "http://${TARGET}:8428/api/v1/label/__name__/values" 2>/dev/null \
      | grep -qE 'proxmox|pve'; then
    echo "    metrics are arriving."
    break
  fi
  sleep 5
done

cat <<NEXT

  Now find out what the push actually named things - do NOT assume, the names
  differ from the pve-exporter pve_* series that older guides use:

    curl -s 'http://${TARGET}:8428/api/v1/label/__name__/values' \\
      | tr ',' '\\n' | grep -iE 'proxmox|pve' | head -40

  Write your guest-state alert rules against those names. See docs/PVE-ALERTS.md.

NEXT
