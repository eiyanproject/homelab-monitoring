#!/usr/bin/env bash
# Daily vzdump on this node, mirrored to the other node, plus a metric so a
# backup that quietly stopped becomes an alert.
#
# RUN THIS ON THE PROXMOX HOST, once per node.
#
#   ./setup-backups.sh --peer 192.168.0.5 --peer-name eiyan
#   ./setup-backups.sh --peer 192.168.0.5 --peer-name eiyan --yes
#
# Why not NFS or PBS: both are more moving parts than this needs. Cluster nodes
# already have passwordless root SSH to each other, so rsync is free and has no
# daemon to hang. A backup on the same disk as the guest is not a backup, so the
# mirror is the point - the local copy is only there to make restores fast.
#
# Deliberately NOT off-site. This protects against a disk or a node dying, not
# against fire or theft. See docs for the restic-to-object-storage tier.
set -euo pipefail

PEER=""; PEER_NAME=""; CONFIRM="no"
SCHEDULE="02:30"; KEEP="3"; STORAGE="local"; MODE="snapshot"; COMPRESS="zstd"
EXCLUDE=""; MIRROR_DIR="/var/lib/vz/backup-mirror"
DUMP_DIR="/var/lib/vz/dump"
MON_IP=""

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer)      PEER="$2"; shift 2 ;;
    --peer-name) PEER_NAME="$2"; shift 2 ;;
    --schedule)  SCHEDULE="$2"; shift 2 ;;
    --keep)      KEEP="$2"; shift 2 ;;
    --storage)   STORAGE="$2"; shift 2 ;;
    --exclude)   EXCLUDE="$2"; shift 2 ;;
    --mon)       MON_IP="$2"; shift 2 ;;
    --yes)       CONFIRM="yes"; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v vzdump >/dev/null || die "run this on a Proxmox host"
[[ -n "$PEER" ]]      || die "--peer is required (the other node's IP)"
[[ -n "$PEER_NAME" ]] || die "--peer-name is required (the other node's hostname)"

NODE=$(hostname)

# Find the local mon LXC so the freshness metric goes somewhere.
if [[ -z "$MON_IP" ]]; then
  for c in /etc/pve/lxc/*.conf; do
    [[ -f "$c" ]] || continue
    grep -qE '^hostname: mon-' "$c" 2>/dev/null || continue
    MON_IP=$(grep -oE 'ip=([0-9]{1,3}\.){3}[0-9]{1,3}' "$c" | head -1 | cut -d= -f2)
    break
  done
fi

AVAIL=$(df -BG --output=avail "$DUMP_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
GUESTS=$(pct list 2>/dev/null | awk 'NR>1{print $1}'; qm list 2>/dev/null | awk 'NR>1{print $1}')
GUESTS=$(echo $GUESTS)

cat <<PLAN

  Plan
  ----
  node          ${NODE}
  guests        ${GUESTS:-none found}
  exclude       ${EXCLUDE:-none}
  schedule      daily at ${SCHEDULE}, keep ${KEEP}
  local copy    ${STORAGE}  (${DUMP_DIR}, ${AVAIL:-?} GB free)
  mirrored to   ${PEER_NAME} (${PEER}) at ${MIRROR_DIR}/${NODE}
  freshness     pushed to ${MON_IP:-<no mon LXC found>} as backup_age_seconds

  A backup on the same disk as the guest is not a backup. The mirror is what
  makes this one - and it matters most for a node whose storage is unreliable.

PLAN

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Re-run with --yes to apply."
  exit 0
fi

# --- reachability ----------------------------------------------------------
echo "==> checking SSH to ${PEER}"
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    "root@${PEER}" "mkdir -p ${MIRROR_DIR}/${NODE} && echo ok" >/dev/null \
  || die "cannot ssh to root@${PEER}. Cluster nodes normally have this already; check 'pvecm status'."
echo "    ok"

# --- vzdump job ------------------------------------------------------------
echo "==> creating the backup job"
JOB_ARGS=(--schedule "$SCHEDULE" --storage "$STORAGE" --mode "$MODE"
          --compress "$COMPRESS" --all 1 --node "$NODE"
          --prune-backups "keep-last=${KEEP}"
          --notes-template "{{guestname}} {{node}}"
          --enabled 1)
[[ -n "$EXCLUDE" ]] && JOB_ARGS+=(--exclude "$EXCLUDE")

if pvesh get /cluster/backup --output-format json 2>/dev/null | grep -q "\"comment\":\"hm-${NODE}\""; then
  echo "    a job for this node already exists, leaving it alone"
else
  pvesh create /cluster/backup "${JOB_ARGS[@]}" --comment "hm-${NODE}" >/dev/null \
    && echo "    created" \
    || die "could not create the backup job"
fi

# --- mirror ----------------------------------------------------------------
echo "==> installing the mirror job"
cat > /usr/local/bin/hm-backup-mirror <<EOF
#!/usr/bin/env bash
# Mirrors this node's vzdump output to the other node, then reports freshness.
set -uo pipefail
PEER="${PEER}"
NODE="${NODE}"
MIRROR_DIR="${MIRROR_DIR}"
DUMP_DIR="${DUMP_DIR}"
MON_IP="${MON_IP}"

# --delete keeps the mirror in step with local retention, so pruning here
# prunes there too rather than growing forever on the peer.
rsync -a --delete --timeout=1800 \\
      -e "ssh -o BatchMode=yes -o ConnectTimeout=15" \\
      "\${DUMP_DIR}/" "root@\${PEER}:\${MIRROR_DIR}/\${NODE}/"
rc=\$?

if [ -n "\${MON_IP}" ]; then
  newest=\$(find "\${DUMP_DIR}" -name '*.tar.zst' -o -name '*.vma.zst' 2>/dev/null \\
            | xargs -r stat -c %Y 2>/dev/null | sort -n | tail -1)
  now=\$(date +%s)
  age=\$(( now - \${newest:-0} ))
  [ -z "\${newest}" ] && age=-1
  printf 'backup_age_seconds{node="%s"} %s\\nbackup_mirror_ok{node="%s"} %s\\n' \\
    "\${NODE}" "\${age}" "\${NODE}" "\$([ \$rc -eq 0 ] && echo 1 || echo 0)" \\
    | curl -s --max-time 15 --data-binary @- \\
      "http://\${MON_IP}:8429/api/v1/import/prometheus" >/dev/null 2>&1
fi
exit \$rc
EOF
chmod 755 /usr/local/bin/hm-backup-mirror

# An hour after the backup window, and again mid-morning so a failed run has a
# second chance before a whole day passes unnoticed.
MIR_H=$(( 10#${SCHEDULE%%:*} + 2 )); (( MIR_H > 23 )) && MIR_H=$(( MIR_H - 24 ))
(crontab -l 2>/dev/null | grep -v hm-backup-mirror; \
 echo 'MAILTO=""'; \
 echo "0 ${MIR_H},11 * * * /usr/local/bin/hm-backup-mirror 2>&1 | logger -t hm-backup-mirror") | crontab -
echo "    mirror runs at ${MIR_H}:00 and 11:00"

cat <<NEXT

  Done.

  Run one now to prove it end to end (this takes a while):
      vzdump --all 1 --storage ${STORAGE} --mode ${MODE} --compress ${COMPRESS}
      /usr/local/bin/hm-backup-mirror

  Then check the mirror landed:
      ssh root@${PEER} ls -lh ${MIRROR_DIR}/${NODE}/

  And that freshness is being reported:
      curl -s 'http://${MON_IP}:8428/api/v1/query' --data-urlencode 'query=backup_age_seconds'

  Alert on backup_age_seconds > 172800 - a backup that silently stopped two
  months ago is the usual way people discover they had none.

NEXT
