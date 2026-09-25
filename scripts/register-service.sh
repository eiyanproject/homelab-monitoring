#!/usr/bin/env bash
# Adds one service to a mon LXC's vmagent scrape target list.
#
# RUN THIS ON THE PROXMOX HOST, once per node, pointing at that node's own mon
# LXC. Services are registered on BOTH nodes on purpose: each vmagent scrapes
# the target and replicates to both stores, so one node being down does not
# lose the service. The cost is that every series exists twice under different
# node labels, which dashboards collapse with max without(node) - see
# dashboards/catalog.json.
#
#   ./register-service.sh --ctid 200 --service learnbox --target 192.168.0.116:8080
#   ./register-service.sh --ctid 200 --service learnbox --target 192.168.0.116:8080 --yes
#
# Idempotent: a service already listed is left alone, so this is safe to
# re-run. Unlike gen-targets.sh, which regenerates guests.json wholesale, this
# appends - services.json is hand-maintained and nothing else knows what
# belongs in it.
set -euo pipefail

CTID=""; SERVICE=""; TARGET=""; KIND="lxc"; APPLY="no"
FILE="/srv/monitoring/targets/services.json"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)    CTID="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --target)  TARGET="$2"; shift 2 ;;
    --kind)    KIND="$2"; shift 2 ;;
    --file)    FILE="$2"; shift 2 ;;
    --yes)     APPLY="yes"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pct >/dev/null || die "pct not found - run this on the Proxmox host"
[[ -n "$CTID"    ]] || die "--ctid is required (the mon LXC on this node)"
[[ -n "$SERVICE" ]] || die "--service is required"
[[ -n "$TARGET"  ]] || die "--target is required, as host:port"
[[ "$TARGET" == *:* ]] || die "--target must be host:port, got: $TARGET"
[[ "$SERVICE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "--service must be lowercase alphanumeric, - or _"

pct status "$CTID" 2>/dev/null | grep -q running || die "CT $CTID is not running"

CUR=$(pct exec "$CTID" -- cat "$FILE" 2>/dev/null || echo "")
STRIPPED="${CUR//[[:space:]]/}"

# A missing, empty or "[]" file all mean the same thing: no services yet. Give
# awk the multi-line form so it has a closing bracket on its own line to find.
if [[ -z "$STRIPPED" || "$STRIPPED" == "[]" ]]; then
  CUR=$(printf '[\n]\n')
elif [[ "$STRIPPED" != \[*\] ]]; then
  die "$FILE in CT $CTID is not a JSON array - fix it by hand"
fi

if grep -qE "\"service\"[[:space:]]*:[[:space:]]*\"${SERVICE}\"" <<<"$CUR"; then
  echo "${SERVICE} is already registered in CT ${CTID} - nothing to do"
  exit 0
fi

ENTRY="  { \"targets\": [\"${TARGET}\"], \"labels\": { \"job\": \"service\", \"service\": \"${SERVICE}\", \"kind\": \"${KIND}\" } }"

# Textual append rather than a JSON parse: neither the Proxmox host nor a
# Debian-standard LXC is guaranteed to have jq or python3, and awk is.
RESULT=$(awk -v entry="$ENTRY" '
  { line[NR] = $0 }
  END {
    # The array body is everything before the last line starting with "]".
    close_at = 0
    for (i = NR; i >= 1; i--) if (line[i] ~ /^[[:space:]]*\]/) { close_at = i; break }
    if (close_at == 0) exit 1

    # Squash the body to decide whether it holds any entry at all, and note
    # the last line with content so the comma lands on the right one.
    body = ""; last = 0
    for (i = 1; i < close_at; i++) {
      t = line[i]; gsub(/[[:space:]]/, "", t)
      body = body t
      if (t != "") last = i
    }
    sub(/^\[/, "", body)

    if (body == "") { print "["; print entry; print "]"; exit 0 }

    for (i = 1; i < close_at; i++) {
      if (i == last) { sub(/[[:space:]]+$/, "", line[i]); print line[i] "," }
      else print line[i]
    }
    print entry
    print "]"
  }
' <<<"$CUR") || die "could not find the closing ] in $FILE"

echo "CT ${CTID}  ${FILE}"
echo "adding: ${SERVICE} at ${TARGET} (kind=${KIND})"
echo
echo "--- resulting file ---"
echo "$RESULT"
echo "----------------------"

if [[ "$APPLY" != "yes" ]]; then
  echo
  echo "plan only. re-run with --yes to apply."
  exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$RESULT" > "$TMP"

pct exec "$CTID" -- cp "$FILE" "${FILE}.bak" 2>/dev/null || true
pct push "$CTID" "$TMP" "$FILE" --perms 644
echo "pushed. vmagent picks it up within 60 s (-promscrape.fileSDCheckInterval); no restart."
