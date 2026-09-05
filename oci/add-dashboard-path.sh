#!/usr/bin/env bash
# Puts a clean path in front of a Grafana shared dashboard, so the portfolio
# link is /homelab rather than /public-dashboards/<32-hex-token>.
#
# RUN ON THE OCI HOST, as root.
#
#   ./add-dashboard-path.sh --token 03bd...36f7                  # plan only
#   ./add-dashboard-path.sh --token 03bd...36f7 --yes            # apply
#   ./add-dashboard-path.sh --token 03bd...36f7 --path /demo --yes
#
# redir, not rewrite. A rewrite is invisible to the browser, and Grafana is a
# single-page app that routes on the browser's URL - it receives the correct
# HTML and then renders "Page not found" because the address bar still says
# /homelab. So the clean path is what you share; the token appears once the
# visitor lands. Only an iframe wrapper avoids that, and it needs
# allow_embedding turned on across all of Grafana.
#
# Re-running replaces the block it previously wrote, so changing --token or
# --path is just another run.
#
# Access still challenges the path until you add it as a Bypass row - see the
# note this prints at the end. Caddy never sees the request otherwise.
set -euo pipefail

TOKEN=""; SITE=""; PATH_PREFIX="/homelab"; CADDYFILE="/etc/caddy/Caddyfile"; CONFIRM="no"
MARKER="# managed by add-dashboard-path.sh"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)     TOKEN="$2"; shift 2 ;;
    --path)      PATH_PREFIX="$2"; shift 2 ;;
    --site)      SITE="$2"; shift 2 ;;
    --caddyfile) CADDYFILE="$2"; shift 2 ;;
    --yes)       CONFIRM="yes"; shift ;;
    -h|--help)   sed -n '2,23p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$TOKEN" ]] || die "--token is required (the 32-hex string from the share URL)"
[[ "$TOKEN" =~ ^[0-9a-f]{32}$ ]] || die "--token does not look like a Grafana access token: $TOKEN"
[[ "$PATH_PREFIX" == /* ]] || die "--path must start with a slash"
[[ -f "$CADDYFILE" ]] || die "no Caddyfile at $CADDYFILE (pass --caddyfile)"
command -v caddy >/dev/null || die "caddy not on PATH - is this the right host?"
[[ $EUID -eq 0 ]] || die "run as root"

# A site address can carry a scheme (http://host, which is what a
# tunnel-terminated setup looks like) and can list several addresses, so match
# the whole opening line rather than a bare hostname.
MATCH="${SITE:-grafana}"
mapfile -t CANDIDATES < <(
  grep -E '^[^[:space:]#].*\{[[:space:]]*$' "$CADDYFILE" | grep -F -- "$MATCH" \
  | sed 's/[[:space:]]*{[[:space:]]*$//' | awk '{print $1}' | sort -u
)
(( ${#CANDIDATES[@]} == 1 )) \
  || die "found ${#CANDIDATES[@]} site blocks matching '${MATCH}' in ${CADDYFILE}; pass --site explicitly"
SITE="${CANDIDATES[0]}"
HOST="${SITE#*://}"

BLOCK="    ${MARKER} - do not edit by hand, re-run the script
    handle ${PATH_PREFIX}* {
        redir * /public-dashboards/${TOKEN}
    }"

cat <<PLAN

  Plan
  ----
  caddyfile   ${CADDYFILE}
  site        ${SITE}
  public URL  https://${HOST}${PATH_PREFIX}   ->   /public-dashboards/${TOKEN}

  Any previous block for ${PATH_PREFIX} is removed first. To insert at the top
  of the site block:

${BLOCK}

PLAN

if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Dry run. Nothing changed. Re-run with --yes to apply."
  exit 0
fi

BACKUP="${CADDYFILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CADDYFILE" "$BACKUP"
echo "==> backed up to ${BACKUP}"

TMP=$(mktemp)
# Drop any existing handle block for this path, along with the comment lines
# immediately above it, then insert the new one. Comments are buffered rather
# than printed straight out, so the ones belonging to a removed block go with it.
awk -v site="$SITE" -v path="$PATH_PREFIX" -v block="$BLOCK" '
  function flush(  i) { for (i = 1; i <= nbuf; i++) print buf[i]; nbuf = 0 }
  skipping {
    depth += gsub(/\{/, "{"); depth -= gsub(/\}/, "}")
    if (depth <= 0) skipping = 0
    next
  }
  /^[[:space:]]*#/ { buf[++nbuf] = $0; next }
  {
    # Compare the matcher as a plain string. Building a regex out of a
    # user-supplied path means escaping it, and getting that wrong silently
    # matches the wrong block.
    line = $0; sub(/^[[:space:]]+/, "", line)
    if (line ~ /^handle[[:space:]]/ && line ~ /\{[[:space:]]*$/) {
      split(line, a, /[[:space:]]+/); m = a[2]; sub(/\*$/, "", m)
      if (m == path) { nbuf = 0; depth = 1; skipping = 1; next }
    }
  }
  { flush()
    print
    if (!done && index($0, site) && /\{[[:space:]]*$/) { print block; done = 1 }
  }
  END { flush() }
' "$CADDYFILE" > "$TMP"

grep -q "public-dashboards/${TOKEN}" "$TMP" || { rm -f "$TMP"; die "insertion produced no change - left ${CADDYFILE} alone"; }
cat "$TMP" > "$CADDYFILE"
rm -f "$TMP"

echo "==> validating"
if ! caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
  cp -a "$BACKUP" "$CADDYFILE"
  die "config did not validate; restored ${BACKUP} and changed nothing"
fi
echo "    ok"

echo "==> reloading caddy"
systemctl reload caddy || { cp -a "$BACKUP" "$CADDYFILE"; systemctl reload caddy || true; die "reload failed; restored ${BACKUP}"; }
echo "    ok"

cat <<NEXT

  Done. One step left, and it is not on this host:

  Cloudflare Zero Trust > Access controls > Applications > your
  "Grafana public dashboards" app - add a hostname row:

      ${HOST}   path: ${PATH_PREFIX#/}

  on the same Bypass / Everyone policy. Until then Access challenges
  ${PATH_PREFIX} before Caddy ever sees the request.

  Then check it from somewhere with no Access session:
      curl -sI https://${HOST}${PATH_PREFIX} | head -1

  Rollback:
      cp -a ${BACKUP} ${CADDYFILE} && systemctl reload caddy

NEXT
