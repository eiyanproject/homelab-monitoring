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
# It inserts a handle block and does NOT touch the existing reverse_proxy.
# Caddy evaluates `handle` before a bare `reverse_proxy`, and a matched handle
# is terminal, so /homelab is served by the new block and every other path
# falls through to what is already there.
#
# rewrite, not redir: the address bar stays on /homelab and the token never
# becomes visible. Grafana's page sets <base href="/">, so its assets resolve
# to /public/build/... whatever path the request arrived on.
#
# Access still challenges /homelab until you add it as a Bypass row - see the
# note this prints at the end. Caddy never sees the request otherwise.
set -euo pipefail

TOKEN=""; SITE=""; PATH_PREFIX="/homelab"; CADDYFILE="/etc/caddy/Caddyfile"; CONFIRM="no"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)     TOKEN="$2"; shift 2 ;;
    --path)      PATH_PREFIX="$2"; shift 2 ;;
    --site)      SITE="$2"; shift 2 ;;
    --caddyfile) CADDYFILE="$2"; shift 2 ;;
    --yes)       CONFIRM="yes"; shift ;;
    -h|--help)   sed -n '2,21p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$TOKEN" ]] || die "--token is required (the 32-hex string from the share URL)"
[[ "$TOKEN" =~ ^[0-9a-f]{32}$ ]] || die "--token does not look like a Grafana access token: $TOKEN"
[[ "$PATH_PREFIX" == /* ]] || die "--path must start with a slash"
[[ -f "$CADDYFILE" ]] || die "no Caddyfile at $CADDYFILE (pass --caddyfile)"
command -v caddy >/dev/null || die "caddy not on PATH - is this the right host?"
[[ $EUID -eq 0 ]] || die "run as root"

# Find the site block. A site address can carry a scheme (http://host, which is
# what a tunnel-terminated setup looks like) and can list several addresses, so
# match the whole opening line rather than a bare hostname. Without --site, take
# the one mentioning grafana; guessing between several would be worse than
# refusing.
MATCH="${SITE:-grafana}"
mapfile -t CANDIDATES < <(
  grep -E '^[^[:space:]#].*\{[[:space:]]*$' "$CADDYFILE"   | grep -F -- "$MATCH"   | sed 's/[[:space:]]*{[[:space:]]*$//'   | awk '{print $1}' | sort -u
)
(( ${#CANDIDATES[@]} == 1 ))   || die "found ${#CANDIDATES[@]} site blocks matching '${MATCH}' in ${CADDYFILE}; pass --site explicitly"
SITE="${CANDIDATES[0]}"
HOST="${SITE#*://}"

# Reuse the site's existing upstream verbatim rather than asking for it again.
UPSTREAM_LINE=$(awk -v site="$SITE" '
  index($0, site) && /\{[[:space:]]*$/ { depth=1; inblock=1; next }
  inblock {
    depth += gsub(/\{/, "{"); depth -= gsub(/\}/, "}")
    if (depth <= 0) { inblock=0; next }
    if ($1 == "reverse_proxy") { sub(/^[[:space:]]+/, ""); print; exit }
  }' "$CADDYFILE")

[[ -n "$UPSTREAM_LINE" ]] || die "no single-line reverse_proxy found inside the '${SITE}' block - add the handle block by hand"
[[ "$UPSTREAM_LINE" != *"{"* ]] || die "the reverse_proxy in '${SITE}' opens a block; too varied to edit safely - add the handle block by hand"

if grep -q "public-dashboards/${TOKEN}" "$CADDYFILE"; then
  echo "  ${CADDYFILE} already routes this token. Nothing to do."
  exit 0
fi

BLOCK=$(cat <<EOF
    # Clean URL for the public Grafana dashboard. handle runs before the bare
    # reverse_proxy below and is terminal, so only this path is affected.
    handle ${PATH_PREFIX}* {
        rewrite * /public-dashboards/${TOKEN}
        ${UPSTREAM_LINE}
    }
EOF
)

cat <<PLAN

  Plan
  ----
  caddyfile   ${CADDYFILE}
  site        ${SITE}
  upstream    ${UPSTREAM_LINE}
  public URL  https://${HOST}${PATH_PREFIX}

  To insert at the top of the site block:

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
awk -v site="$SITE" -v block="$BLOCK" '
  !done && index($0, site) && /\{[[:space:]]*$/ { print; print block; done=1; next }
  { print }
' "$CADDYFILE" > "$TMP"

grep -q "public-dashboards/${TOKEN}" "$TMP" || { rm -f "$TMP"; die "insertion produced no change - left ${CADDYFILE} alone"; }
cat "$TMP" > "$CADDYFILE"
rm -f "$TMP"

echo "==> validating"
if ! caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
  cp -a "$BACKUP" "$CADDYFILE"
  caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1 || true
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
      curl -s -o /dev/null -w '%{http_code}\n' https://${HOST}${PATH_PREFIX}

  Rollback at any point:
      cp -a ${BACKUP} ${CADDYFILE} && systemctl reload caddy

NEXT
