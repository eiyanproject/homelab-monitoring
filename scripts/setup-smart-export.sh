#!/usr/bin/env bash
# Exports SMART attributes as Prometheus metrics from inside a guest.
#
# RUN THIS INSIDE THE GUEST that owns the disks - typically a NAS VM. A disk
# passed through to a VM cannot be SMART-read from the hypervisor, so host-side
# checks silently cover nothing. This closes that gap.
#
# From the Proxmox host, without touching the VM console:
#
#   qm guest exec <vmid> -- bash -c \
#     "curl -fsSL https://raw.githubusercontent.com/eiyanproject/homelab-monitoring/main/scripts/setup-smart-export.sh -o /tmp/s.sh && bash /tmp/s.sh"
#
# Needs prometheus-node-exporter already installed.
set -euo pipefail

TEXTFILE_DIR="/var/lib/node_exporter/textfile"
EXPORT_SCRIPT="/usr/local/bin/smart-export"
DEFAULTS="/etc/default/prometheus-node-exporter"

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

echo "==> installing smartmontools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq smartmontools

echo "==> creating ${TEXTFILE_DIR}"
mkdir -p "$TEXTFILE_DIR"
chown -R prometheus:prometheus "$TEXTFILE_DIR" 2>/dev/null || true

echo "==> writing ${EXPORT_SCRIPT}"
cat > "$EXPORT_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# Writes SMART attributes as Prometheus metrics. Written to a temp file and
# moved into place so node_exporter never reads a half-written file.
set -uo pipefail
OUT="/var/lib/node_exporter/textfile/smart.prom"
TMP="${OUT}.$$"

{
  echo "# HELP smart_healthy 1 if SMART overall-health self-assessment passed"
  echo "# TYPE smart_healthy gauge"
  echo "# HELP smart_attr_raw Raw value of a SMART attribute"
  echo "# TYPE smart_attr_raw gauge"

  for dev in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    d="/dev/${dev}"
    smartctl -i "$d" &>/dev/null || continue
    model=$(smartctl -i "$d" 2>/dev/null | awk -F': +' '/Device Model|Model Number/{print $2; exit}')
    serial=$(smartctl -i "$d" 2>/dev/null | awk -F': +' '/Serial Number/{print $2; exit}')
    model="${model:-unknown}"; serial="${serial:-unknown}"

    if smartctl -H "$d" 2>/dev/null | grep -qiE 'PASSED|OK'; then h=1; else h=0; fi
    printf 'smart_healthy{disk="%s",model="%s",serial="%s"} %d\n' "$dev" "$model" "$serial" "$h"

    # Raw values are what matter: a rising reallocated or pending count is the
    # early warning, long before the overall assessment flips to FAILED.
    smartctl -A "$d" 2>/dev/null | awk -v dev="$dev" '
      /Reallocated_Sector_Ct/   {printf "smart_attr_raw{disk=\"%s\",attr=\"reallocated\"} %s\n", dev, $10}
      /Current_Pending_Sector/  {printf "smart_attr_raw{disk=\"%s\",attr=\"pending\"} %s\n",     dev, $10}
      /Offline_Uncorrectable/   {printf "smart_attr_raw{disk=\"%s\",attr=\"uncorrectable\"} %s\n", dev, $10}
      /UDMA_CRC_Error_Count/    {printf "smart_attr_raw{disk=\"%s\",attr=\"crc\"} %s\n",         dev, $10}
      /Temperature_Celsius/     {printf "smart_attr_raw{disk=\"%s\",attr=\"temperature\"} %s\n", dev, $10}
      /Power_On_Hours/          {printf "smart_attr_raw{disk=\"%s\",attr=\"power_on_hours\"} %s\n", dev, $10}
    '
  done
} > "$TMP" 2>/dev/null

mv "$TMP" "$OUT"
chmod 644 "$OUT"
SCRIPT
chmod 755 "$EXPORT_SCRIPT"

echo "==> enabling the textfile collector"
if [[ -f "$DEFAULTS" ]] && ! grep -q 'collector.textfile.directory' "$DEFAULTS"; then
  cp "$DEFAULTS" "${DEFAULTS}.bak.$(date +%F)"
  if grep -q '^ARGS=' "$DEFAULTS"; then
    sed -i "s|^ARGS=\"\(.*\)\"|ARGS=\"\1 --collector.textfile.directory=${TEXTFILE_DIR}\"|" "$DEFAULTS"
  else
    echo "ARGS=\"--collector.textfile.directory=${TEXTFILE_DIR}\"" >> "$DEFAULTS"
  fi
  echo "    added to ${DEFAULTS}"
else
  echo "    already configured (or no defaults file)"
fi

echo "==> scheduling every 15 minutes"
(crontab -l 2>/dev/null | grep -v smart-export; \
 echo 'MAILTO=""'; \
 echo "*/15 * * * * ${EXPORT_SCRIPT} 2>&1 | logger -t smart-export") | crontab -

echo "==> first run"
"$EXPORT_SCRIPT"
systemctl restart prometheus-node-exporter 2>/dev/null || true
sleep 2

echo
echo "  Exported:"
sed -n '/^smart_/p' "${TEXTFILE_DIR}/smart.prom" | sed 's/^/    /'
echo
echo "  Visible on :9100/metrics within a minute. Alert on smart_attr_raw"
echo "  {attr=\"reallocated\"} or {attr=\"pending\"} rising above zero - that is"
echo "  days of warning, whereas smart_healthy only flips once it is too late."
