# homelab-monitoring

Metrics, logs and alerting for a two-node Proxmox VE 9 cluster, in about
**448 MB per node, measured**, with a **complete second copy of all metrics** — and
without needing the HA manager, a QDevice, ZFS, or shared storage.

One repo builds both nodes. The only difference between them is three lines in
`.env`.

```
VictoriaMetrics · VictoriaLogs · vmagent · Grafana · control panel
```

## Why not Prometheus, Loki and the HA manager

Three deliberate departures from the usual homelab guide:

**Proxmox VE 9 pushes its own metrics.** `Datacenter → Metric Server →
OpenTelemetry` sends node, guest and storage metrics to an OTLP endpoint with
nothing installed on the hypervisor, and it picks up guests you create later
without being told. Most guides predate this and start with
`prometheus-pve-exporter`. That exporter is still useful — but as a *second*
source, not the first (see [Detecting "down"](#detecting-down)).

**No agent in the guests.** Grafana Alloy and Vector cost 100–150 MB resident
*each*. Across a dozen guests that is more memory than the entire monitoring
stack. `rsyslog` is 5–8 MB, reads the journal directly, and emits RFC5424 that
VictoriaLogs parses into structured fields by itself. Promtail is not an option
either way — it reached end of life on 2 March 2026.

**Replication at the application layer, not the hypervisor layer.** A two-node
cluster without a QDevice cannot do HA: each node holds one vote, so a survivor
has 1 of 2 and is not quorate. Worse, an HA-enabled node that loses quorum
*fences itself* — the watchdog reboots it — so you would lose the surviving node
too. Instead, `vmagent` takes a repeatable `-remoteWrite.url` flag that
**replicates** every sample to both nodes and **buffers to disk** when one is
unreachable, replaying on reconnect. Both stacks are already running before
anything fails, so quorum never enters into it.

> **Do not enable Proxmox HA on a two-node cluster without a QDevice.** Also
> worth knowing: when one node dies the survivor's `/etc/pve` goes read-only.
> Running guests keep running, but you cannot start or migrate anything until
> you run `pvecm expected 1`.

## Architecture

```
  NODE A                                    NODE B
  ┌───────────────────────────┐             ┌───────────────────────────┐
  │ guests ──rsyslog──┐       │             │       ┌──rsyslog── guests │
  │ PVE OTLP push ──┐ │       │             │       │ ┌── PVE OTLP push │
  │                 ▼ ▼       │             │       ▼ ▼                 │
  │        ┌──────────────┐   │             │   ┌──────────────┐        │
  │        │ vmagent      │───┼── dual ─────┼──▶│ VictoriaMetr │        │
  │        │ VictoriaMetr │◀──┼── write ────┼───│ vmagent      │        │
  │        │ VictoriaLogs │   │             │   │ VictoriaLogs │        │
  │        │ Grafana      │   │             │   │ Grafana      │        │
  │        │ alerting: ON │   │             │   │ alerting:OFF │        │
  │        └──────────────┘   │             │   └──────────────┘        │
  └───────────────────────────┘             └───────────────────────────┘
              └──────────── heartbeat ─────────────┘
                                 ▼
                   external watcher (off-site)
       the only tier that survives both nodes, a power cut, or the ISP
```

Each node pushes to its **own local** vmagent, never the peer's. Local
collection has no network dependency, so a link failure between the nodes
cannot lose data.

## Quick start

On each Proxmox host:

```bash
git clone https://github.com/eiyanproject/homelab-monitoring.git /srv/homelab-monitoring
cd /srv/homelab-monitoring/scripts
```

**Node A (primary — runs alerting):**

```bash
./bootstrap-lxc.sh --ctid 200 --hostname mon-a \
  --ip 192.168.0.200/24 --gw 192.168.0.1 \
  --peer 192.168.0.201 --role primary --yes
```

**Node B (standby — identical, alerting off):**

```bash
./bootstrap-lxc.sh --ctid 200 --hostname mon-b \
  --ip 192.168.0.201/24 --gw 192.168.0.1 \
  --peer 192.168.0.200 --role standby --lean --yes
```

Then on each host, in order:

```bash
./setup-metric-server.sh  --target 192.168.0.200 --yes   # agentless PVE push
./gen-targets.sh          --ctid 200                     # then add to cron
./setup-guest-logging.sh  --collector 192.168.0.200 --yes
```

Every script prints its plan and changes nothing until you add `--yes`.

Full walkthrough with verification steps: [docs/DEPLOY.md](docs/DEPLOY.md).

## Control panel

A small always-on web UI on **:8080**, so routine work needs no console.

It is deliberately **separate from Grafana**, for the obvious reason: a button
inside Grafana cannot start Grafana. It is the smallest service here (~15 MB,
Alpine + Python stdlib, no dependencies) precisely because it has to be up when
nothing else is.

- **Open Grafana** — a link, built from whatever hostname you reached the panel
  on, so it is correct over LAN, Tailscale or a tunnel with nothing configured
- **Start / Stop / Restart** any stack service, with a live progress bar that
  tracks the real container state through to its health check passing
- **Promote / demote** this node's alerting role — rewrites `.env` and recreates
  Grafana, so the change survives a reboot
- **Replication backlog** per destination, straight from vmagent — the single
  number that tells you whether the mirror is healthy
- **Logs** for any service, without SSH

### Lean mode

Grafana is **317 MB of the ~450 MB** stack, and it is the one component you do
not need running until you want to look at something. `--lean` creates it and
leaves it stopped:

```bash
./bootstrap-lxc.sh ... --role standby --lean --yes
```

That node still receives and stores **every metric**, continuously — it just
does not render them until you press Start. Roughly 130–250 MB instead of
450 MB, which matters on a node that is short of RAM. `restart: unless-stopped`
respects a manual stop, so it stays down across reboots until you start it.

> The panel can reach the Docker socket and nothing else. Operations that need
> the hypervisor — `pct`, `pvesh`, `pvecm expected 1` — are **not** exposed, so
> compromising the container does not hand over the cluster. Treat
> `CONTROL_PASSWORD` as root on this container, and put the panel behind
> Tailscale or a tunnel rather than on the open LAN.

## Per-node configuration

Three lines in `.env` are all that differ:

| Variable | Node A | Node B |
| --- | --- | --- |
| `NODE_NAME` | `mon-a` | `mon-b` |
| `PEER_IP` | node B's mon LXC | node A's mon LXC |
| `ALERTING_DIR` | `…/alerting` | `…/alerting-disabled` |

Alerting runs on **one** node, or every alert arrives twice forever. Promote
the standby with the control panel button, or by editing `ALERTING_DIR` and
running `docker compose up -d`.

## Verifying it actually works

Untested failover is a belief, not a capability. The test that matters:

```bash
# 1. on node B
pct stop 200

# 2. wait 15 minutes, then on node A confirm the queue is filling
curl -s http://127.0.0.1:8429/metrics | grep pending_data_bytes

# 3. start node B again, wait 5 minutes
pct start 200

# 4. query the same time range on BOTH Grafanas - they must match,
#    with no hole across the outage
```

If step 4 shows a gap, the buffer flags are wrong. Far better to learn that now
than during a real outage.

The **Stack Health** dashboard ships with the repo and answers this at a glance
— it uses only metrics the stack emits about itself, so it works from first
boot with no exporters installed.

## Detecting "down"

The OTLP push has **no `up` series** — a dead node simply stops sending, which
looks identical to a quiet one. Three ways to cover it, in order of preference:

1. An **external watcher** on a host outside the cluster, watching a heartbeat.
   The only option that survives both nodes dying.
2. **`prometheus-pve-exporter`** (~80 MB) — pull-based, so it gives a real
   `up{job="pve"}`, plus storage and backup-job state.
3. `absent_over_time()` on a series you know should always be present.

## What ships here

| Path | |
| --- | --- |
| `docker-compose.yml` | The four services, pinned |
| `config/vmagent/` | Scrape config, file-based service discovery |
| `config/grafana/provisioning/` | Datasources, dashboards, contact points, alert rules |
| `dashboards/` | Stack Health |
| `control/` | The always-on control panel (Alpine + Python stdlib) |
| `scripts/` | Bootstrap and the three host-side helpers |
| `docs/` | Deploy guide, service contract, PVE alert notes |

Community dashboards worth importing once the PVE push is live: **23855**
(built for the PVE 9 OTel metrics), **1860** (Node Exporter Full), **24550** and
**10347** (pve-exporter based).

## Adding your own services

There is a contract rather than per-service integration work — roughly fifteen
lines gets a service into dashboards, alerts and log search. See
[docs/SERVICE-CONTRACT.md](docs/SERVICE-CONTRACT.md).

## Requirements

- Proxmox VE 9.0+ (check `ls /usr/share/perl5/PVE/Status/OpenTelemetry.pm`)
- ~1.5 GB RAM and 40 GB disk per node
- Debian LXC template downloaded (`pveam available --section system | grep debian`)

## Licence

MIT
