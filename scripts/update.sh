#!/usr/bin/env bash
# Updates this monitoring stack in place: pull, fill in new .env settings,
# re-render the generated config, restart what changed. Run as root INSIDE the
# mon LXC (update-lxc.sh does this for you from the Proxmox host):
#
#   /srv/monitoring/scripts/update.sh
#   /srv/monitoring/scripts/update.sh --role standby    # this node holds no alert rules
#   /srv/monitoring/scripts/update.sh --no-pull         # re-apply the working tree as-is
#
# Safe to re-run. Your .env values, Grafana's database and all stored metrics
# and logs are kept; .env only ever gains settings it did not have.
#
# --role primary|standby sets ALERTING_DIR. Only one node may evaluate rules,
# or every alert arrives twice. On a standby, the rules Grafana already holds
# are removed too (an empty folder does not remove them - Grafana keeps
# provisioned rules after their file disappears).
set -euo pipefail

# Everything is inside main() so bash parses the whole file before running
# any of it - `git pull` may rewrite this very script mid-run.
main() {
cd "$(dirname "$0")/.."
ROOT="$PWD"
PULL=1; ROLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull) PULL=0; shift ;;
    --role)    ROLE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout"
[[ -f "$ROOT/.env" ]] || die "no $ROOT/.env - this node was never bootstrapped (scripts/bootstrap-lxc.sh)"
[[ -z "$ROLE" || "$ROLE" == primary || "$ROLE" == standby ]] || die "--role must be primary or standby"

ENABLED_DIR="./config/grafana/provisioning/alerting"
DISABLED_DIR="./config/grafana/provisioning/alerting-disabled"

# Never fails: a missing key is an empty value (set -e would otherwise stop
# the script on the first absent key).
env_get() { grep -E "^$1=" "$ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//' || true; }
# Every rule uid this node's Grafana holds, one per line; empty if Grafana is
# down or its admin password was changed in Grafana rather than in .env.
grafana_rule_uids() {
  local user; user=$(env_get GRAFANA_ADMIN_USER); user=${user:-admin}
  curl -fsS --max-time 10 -u "${user}:$(env_get GRAFANA_ADMIN_PASSWORD)" \
    http://127.0.0.1:3000/api/v1/provisioning/alert-rules 2>/dev/null \
    | grep -oE '"uid":"[^"]+"' | cut -d'"' -f4 || true
}
env_set() {  # replace or append KEY=VALUE, keeping the file's mode
  if grep -qE "^$1=" "$ROOT/.env"; then
    sed -i "s|^$1=.*|$1=$2|" "$ROOT/.env"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ROOT/.env"
  fi
}

# ---- 1. code ---------------------------------------------------------------
BEFORE=$(git -C "$ROOT" rev-parse --short HEAD)
if [[ "$PULL" -eq 1 ]]; then
  say "Pulling"
  # Generated files are gitignored, so "dirty" means someone edited a tracked
  # file on the node - that edit would be lost or block the pull.
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]] \
    || die "tracked files were edited on this node (git -C $ROOT status). Commit or revert them, or re-run with --no-pull."
  git -C "$ROOT" pull --ff-only -q
fi
AFTER=$(git -C "$ROOT" rev-parse --short HEAD)
if [[ "$BEFORE" == "$AFTER" ]]; then
  echo "  at $AFTER (no new commits)"
else
  echo "  $BEFORE -> $AFTER"
  git -C "$ROOT" --no-pager log --oneline "$BEFORE..$AFTER" | sed 's/^/    /'
fi

# ---- 2. .env ---------------------------------------------------------------
# .env drifted from .env.example silently before this existed. New settings
# are appended with the example's default, which is what the stack used when
# the key was absent anyway - so this changes no behaviour, it just makes the
# setting visible. Existing values are never touched.
say "Settings (.env)"
added=(); skipped=()
# The mute window is local time: take the Proxmox host's zone (update-lxc.sh
# passes it as HM_TIMEZONE), else this container's, never a blind UTC.
TZ_LOCAL=${HM_TIMEZONE:-$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}
while IFS= read -r line; do
  key=${line%%=*}
  grep -qE "^${key}=" "$ROOT/.env" && continue
  # Placeholders must be set by a person, not copied.
  case "$line" in *change-me*|*192.168.0.0*|NODE_NAME=*) skipped+=("$key"); continue ;; esac
  [[ "$key" == ALERT_TIMEZONE ]] && line="ALERT_TIMEZONE=${TZ_LOCAL}"
  [[ ${#added[@]} -eq 0 ]] && printf '\n# --- added by update.sh %s (defaults from .env.example) ---\n' "$(date +%F)" >> "$ROOT/.env"
  printf '%s\n' "$line" >> "$ROOT/.env"
  added+=("$key")
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$ROOT/.env.example")
if [[ ${#added[@]} -gt 0 ]]; then
  echo "  added: ${added[*]}"
else
  echo "  nothing new"
fi
[[ ${#skipped[@]} -eq 0 ]] || warn "not set, needs a real value: ${skipped[*]} (see .env.example)"
chmod 600 "$ROOT/.env"

if [[ -n "$ROLE" ]]; then
  if [[ "$ROLE" == primary ]]; then env_set ALERTING_DIR "$ENABLED_DIR"; else env_set ALERTING_DIR "$DISABLED_DIR"; fi
fi
case "$(env_get ALERTING_DIR)" in
  *alerting-disabled*) CUR_ROLE=standby ;;
  *)                   CUR_ROLE=primary ;;
esac
echo "  role: $CUR_ROLE (ALERTING_DIR=$(env_get ALERTING_DIR))"
[[ -n "$(env_get NTFY_URL)" && -z "$(env_get NTFY_TOKEN)" && "$CUR_ROLE" == primary ]] \
  && warn "NTFY_TOKEN is empty - a deny-all ntfy rejects every alert. Set it in .env or the control panel."

# ---- 3. standby: remove the rules Grafana still holds ----------------------
# Rule uids come from the repo's rule files plus whatever Grafana reports, so
# rules from groups that were renamed or removed (the old `proxmox` group)
# go as well. The file is gitignored and harmless to keep: deleting a uid
# that no longer exists is a no-op.
if [[ "$CUR_ROLE" == standby ]]; then
  say "Standby: clearing alert rules"
  DEL="$ROOT/config/grafana/provisioning/alerting-disabled/delete-rules.yml"
  uids=$(grep -hE '^[[:space:]]*- uid: ' "$ROOT"/config/grafana/provisioning/alerting/rules*.yml 2>/dev/null \
           | awk '{print $3}')
  api_uids=$(grafana_rule_uids)
  [[ -n "$api_uids" ]] || warn "could not list Grafana's rules (not running, or its admin password differs from .env) - only the repo's rule uids are removed"
  {
    echo "# GENERATED by scripts/update.sh on a standby node - do not edit."
    echo "# Removes every alert rule from this Grafana: only the primary evaluates."
    echo "apiVersion: 1"
    echo "deleteRules:"
    printf '%s\n%s\n' "$uids" "$api_uids" | grep -v '^$' | sort -u | sed 's/.*/  - {orgId: 1, uid: "&"}/'
  } > "$DEL"
  echo "  $(grep -c 'uid:' "$DEL") rule uid(s) listed for removal"
else
  rm -f "$ROOT/config/grafana/provisioning/alerting-disabled/delete-rules.yml"
fi

# ---- 4. generated config ---------------------------------------------------
say "Rendering config"
sh "$ROOT/scripts/render-scrape.sh"   "$ROOT" | sed 's/^/  /'
sh "$ROOT/scripts/render-alerting.sh" "$ROOT" | sed 's/^/  /'

# ---- 5. containers ---------------------------------------------------------
# up -d recreates only containers whose image or settings changed. Grafana and
# vmagent read their provisioning/scrape files at start, so they are restarted
# explicitly: an edited rule or scrape file changes neither image nor settings.
say "Restarting the stack"
cd "$ROOT"
docker compose up -d --build --remove-orphans
docker compose restart grafana vmagent >/dev/null

say "Waiting for health"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:8428/health >/dev/null 2>&1 \
     && curl -fsS --max-time 3 http://127.0.0.1:3000/api/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done
[[ "$ok" -eq 1 ]] || die "stack not healthy after 90 s - docker compose ps; docker compose logs --tail 50"
docker compose ps --format '  {{.Name}}  {{.Status}}'

# Grafana answers /api/health before provisioning finishes; give it a moment.
sleep 5
rules=$(grafana_rule_uids | grep -c . || true)

cat <<DONE

  Done: $(env_get NODE_NAME) at $AFTER, role $CUR_ROLE, ${rules:-?} alert rule(s) loaded.
$( [[ "$CUR_ROLE" == primary ]] && echo "  Test the alert channels:  sh $ROOT/scripts/test-alert.sh $ROOT" )
$( [[ "$CUR_ROLE" == standby && "${rules:-1}" != 0 ]] && echo "  Rules still loaded on a standby - check docker logs hm-grafana for provisioning errors." )
DONE
}

main "$@"
