#!/bin/sh
# Renders config/vmagent/scrape.yml (a template) into scrape.active.yml with
# this node's name substituted, because vmagent does not expand environment
# variables inside -promscrape.config.
#
#   ./render-scrape.sh [project_dir]      default: /srv/monitoring
set -eu

PROJECT_DIR="${1:-/srv/monitoring}"
ENV_FILE="${PROJECT_DIR}/.env"
SRC="${PROJECT_DIR}/config/vmagent/scrape.yml"
OUT="${PROJECT_DIR}/config/vmagent/scrape.active.yml"

[ -f "$ENV_FILE" ] || { echo "render-scrape: no $ENV_FILE" >&2; exit 1; }
[ -f "$SRC" ]      || { echo "render-scrape: no $SRC" >&2; exit 1; }

NODE=$(grep -E '^NODE_NAME=' "$ENV_FILE" | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')
[ -n "$NODE" ] || { echo "render-scrape: NODE_NAME is empty in $ENV_FILE" >&2; exit 1; }

sed "s/__NODE_NAME__/${NODE}/g" "$SRC" > "$OUT"
echo "render-scrape: node=${NODE} -> ${OUT}"
