# Deploy guide

Six phases. Each leaves something working and verifiable, so you can stop after
any of them and still have gained something.

Addresses below are examples. Substitute your own.

---

## Phase 1 — Foundation on node A (~1.5 h)

```bash
git clone https://github.com/eiyanproject/homelab-monitoring.git /srv/homelab-monitoring
cd /srv/homelab-monitoring/scripts
./bootstrap-lxc.sh --ctid 200 --hostname mon-a \
  --ip 192.168.0.200/24 --gw 192.168.0.1 \
  --peer 192.168.0.201 --role primary        # no --yes yet: read the plan
```

Re-run with `--yes` when the plan looks right. It creates the LXC with
`nesting=1,keyctl=1` (Docker in an unprivileged container fails without them,
with a cgroup error that explains nothing), installs Docker, clones this repo to
`/srv/monitoring`, writes `.env` with a generated Grafana password, and starts
the stack.

**Save the password it prints.** It is not stored anywhere else.

`PEER_IP` points at a container that does not exist yet. That is intentional —
vmagent will buffer to disk and log connection errors. Seeing that now means you
have already watched the mechanism the whole design rests on.

### Exit criteria

- [ ] Control panel loads on `:8080` and shows 5/5 services
- [ ] Grafana loads on `:3000` (or opens from the panel's link in lean mode)
- [ ] Both data sources test green (Connections → Data sources)
- [ ] **Stack Health** dashboard shows 4/4 components up
- [ ] `Replication backlog` is non-zero and rising — the peer is unreachable

---

## Phase 2 — Both nodes, zero agents (~1 h)

Run **on each Proxmox host**, pointing at that host's *own* mon LXC:

```bash
./setup-metric-server.sh --target 192.168.0.200        # plan
./setup-metric-server.sh --target 192.168.0.200 --yes  # apply
```

The script first prints your build's actual metric-server parameters
(`pvesh usage /cluster/metrics/server/{id} -v`). If they do not match the flags
it intends to use, configure it in the web UI instead and re-run to verify.

### If OTLP fails the connection test

PVE runs a connection test before saving, so this is a receiver rejection, not
a config error:

```
Connection test failed: 400 Bad Request at PVE/Status/OpenTelemetry.pm
```

VictoriaMetrics accepts OTLP over **protobuf only**. Confirm what it saw:

```bash
pct exec 200 -- docker logs hm-vmagent 2>&1 | grep -i opentelemetry | tail -5
```

If that says `json encoding isn't supported for opentelemetry format`, this PVE
build emits OTLP/JSON and the two cannot talk. Use InfluxDB line protocol —
same agentless push, natively ingested by vmagent, tags become labels:

```bash
./setup-metric-server.sh --target 192.168.0.200 --mode influx --yes
```

Metric names differ between the modes: Influx produces
`<measurement>_<field>`, so confirm the real names before writing alert rules.

### Find the real metric names

Do **not** copy metric names from a blog post. The OTLP push names differ from
the `pve_*` series that exporter-based guides assume:

```bash
curl -s 'http://192.168.0.200:8428/api/v1/label/__name__/values' \
  | tr ',' '\n' | grep -iE 'proxmox|pve' | head -40
```

Write your guest-state alert rules against what you see. See
[PVE-ALERTS.md](PVE-ALERTS.md).

### Exit criteria

- [ ] Both nodes and every running guest appear without you listing them
- [ ] Stopping a scratch LXC shows in Grafana within 60 s
- [ ] You have written down the real metric names
- [ ] You have decided how node-down is detected (README → Detecting "down")

---

## Phase 3 — Logs (~1 h)

```bash
./setup-guest-logging.sh --collector 192.168.0.200        # plan
./setup-guest-logging.sh --collector 192.168.0.200 --yes  # apply
```

Installs `rsyslog` where missing (apt and apk both handled), drops one
forwarding line, restarts the service, and includes the Proxmox host's own
journal. Use `--only 113,114` to do a subset first.

Verify in Grafana → Explore → VictoriaLogs:

```
*                       all recent lines
hostname:"catalog"      one guest
level:error             errors only, parsed from syslog priority
```

> **Logs are not replicated.** vmagent replicates metrics; the syslog path has
> no dual-write. Each node holds its own guests' logs, so a dead node takes its
> logs with it until it returns. Adding a second rsyslog target is possible but
> gives you duplicate entries to filter — usually not worth it.

### Exit criteria

- [ ] A guest's logs are queryable by hostname
- [ ] Both Proxmox hosts ship their own journals
- [ ] `level:error` returns something sensible
- [ ] Time sync runs everywhere — skewed clocks get log entries rejected

---

## Phase 4 — The mirror, and the test that matters (~1.5 h)

Bootstrap node B exactly like node A, with the peer reversed and
`--role standby`:

```bash
./bootstrap-lxc.sh --ctid 200 --hostname mon-b \
  --ip 192.168.0.201/24 --gw 192.168.0.1 \
  --peer 192.168.0.200 --role standby --yes
```

Then point node B's metric server at node B's own mon LXC, and run
`gen-targets.sh` and `setup-guest-logging.sh` there too with node B's collector.

### The failure test

Untested failover is a belief, not a capability. This half-hour is the most
valuable in the whole build.

```bash
pct stop 200                    # on node B
# wait 15 minutes
curl -s http://127.0.0.1:8429/metrics | grep pending_data_bytes   # on node A
pct start 200                   # on node B
# wait 5 minutes, then query the same range on BOTH Grafanas
```

They must match, with **no hole** across the outage. A gap means the buffer
flags are wrong.

### Exit criteria

- [ ] Both Grafanas return identical data for the same query
- [ ] Killing mon-b for 15 min leaves no gap in its copy afterwards
- [ ] `BUFFER_MAX` is set so a long outage cannot fill the healthy node's disk
- [ ] Both nodes build from this repo, differing only in `.env`

---

## Phase 5 — Your own services (~2 h)

See [SERVICE-CONTRACT.md](SERVICE-CONTRACT.md). Retrofit one service, then put
the contract in your `CLAUDE.md` so new services arrive instrumented.

Register targets in `targets/services.json` inside the mon LXC. vmagent reloads
the file every 60 s — no restart.

---

## Phase 6 — Alerting and the outside tier (~2 h)

Add your channels to `.env` on the **primary node only**, then
`docker compose up -d`:

```
NTFY_URL=https://ntfy.sh/your-secret-topic
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
```

Routing is provisioned already: `severity=critical` → all three channels,
`severity=warning` → Discord only.

Add a **mute timing** covering your backup window, or the nightly I/O spike will
train you to ignore your own alerts inside a week.

### The outside tier

Everything above is evaluated *inside* the cluster and is unavailable when the
cluster is. Put a watcher somewhere else — a small VPS is enough — doing two
jobs:

- **Heartbeat:** each mon LXC pings a push URL every minute. Miss two, get told.
  This is what fires when a node, the power, or the ISP dies.
- **Black-box checks** on anything you care about being reachable. CPU graphs
  can look perfect while a service returns 502.

Do not port-forward Grafana. A tunnel with an access policy, or a mesh VPN.

### Exit criteria

- [ ] All three contact points test successfully
- [ ] `pct stop` on a scratch LXC reaches your phone within 5 min
- [ ] Powering off node A alerts you **from outside** within 5 min
- [ ] Node B's `.env` still has `ALERTING_DIR` pointing at `alerting-disabled`
- [ ] Every rule has a runbook annotation
- [ ] This repo is backed up somewhere that is not the homelab

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `dockerd` fails with a cgroup error | LXC missing `nesting=1,keyctl=1` |
| vmagent restarts on boot | `scrape.yml` parse error — `docker compose logs vmagent` |
| `refresh_interval not found` | vmagent has no per-config field; it is global (`-promscrape.fileSDCheckInterval`) |
| `maxDiskUsagePerURL` silently larger | vmagent's minimum is 512 MB |
| victorialogs shows no healthcheck | Correct — distroless image, nothing to run inside. vmagent scrapes it instead |
| Spurious `DatasourceNoData` alerts | A rule is missing `noDataState: OK`. `up{...} == 0` returns *no data* when healthy |
| Alerts arrive twice | Both nodes have alerting enabled. Check `ALERTING_DIR` on the standby |
| Cannot start guests after a node dies | Expected: quorum lost. `pvecm expected 1` on the survivor |
