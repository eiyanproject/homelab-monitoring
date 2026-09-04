# Proxmox guest alerts

These are **not** shipped in `rules.yml`, deliberately. The metric names emitted
by the PVE 9 OpenTelemetry push differ from the `pve_*` series that
exporter-based guides use, and they can differ between PVE point releases.
Shipping rules against guessed names produces rules that silently never fire —
worse than having no rule, because you believe you are covered.

## Step 1 — find out what you actually have

After `setup-metric-server.sh`:

```bash
curl -s 'http://192.168.0.200:8428/api/v1/label/__name__/values' \
  | tr ',' '\n' | grep -iE 'proxmox|pve' | sort | head -40
```

Then inspect one to see its labels:

```bash
curl -s --data-urlencode 'query=<metric_name_you_found>' \
  'http://192.168.0.200:8428/api/v1/query' | head -c 800
```

You are looking for: a per-guest **running/status** gauge, a per-guest **memory
used vs max**, and a per-storage **used vs total**.

## Step 2 — the rule that matters most

Alert on the **transition**, not the state. A naive "guest is not running" rule
fires forever for every guest you intentionally left off, which is the fastest
way to train yourself to ignore your own alerts.

```promql
# fires only for something that WAS running recently and now is not
<guest_running_metric> == 0
  and max_over_time(<guest_running_metric>[2h]) == 1
```

A guest that has been off for weeks never alerts. Deliberately stopping
something costs you one notification that then self-resolves after two hours —
which is arguably correct, since you did just stop a thing.

For guests you toggle often, add a Proxmox **tag** (`noalert`) and exclude it:

```promql
... unless on(guest) <metric>{tags=~".*noalert.*"}
```

Check whether your push exposes tags as a label first; if not, exclude by name.

## Step 3 — the rest

Adapt to your metric names, then add to
`config/grafana/provisioning/alerting/rules.yml` following the shape of the
existing rules. Remember `noDataState: OK` and `execErrState: OK` on every one.

| Alert | Shape | Severity |
| --- | --- | --- |
| Guest stopped unexpectedly | transition rule above, `for: 5m` | warning |
| Cluster lost quorum | quorate gauge `== 0` | critical |
| Storage nearly full | used / total `> 0.9` | critical |
| Storage filling | `predict_linear(avail[6h], 4*86400) < 0` | warning |
| Guest memory pressure | used / max `> 0.95` for 15m | warning |
| Backup job failed | see below | critical |

## Backups

Your cluster may have **no backup jobs configured at all** — check with
`cat /etc/pve/jobs.cfg` on each node. An empty file means nothing is scheduled.

An alert on backup *failure* is worth little until backups exist. Set up
`vzdump` jobs first (Datacenter → Backup), then alert on the task result. The
pull-based `prometheus-pve-exporter` exposes backup and storage state that the
OTLP push does not, which is one of the better arguments for running it
alongside.

## Why bother with pve-exporter too

The OTLP push has **no `up` series** — a dead node stops sending, which is
indistinguishable from a quiet node. Adding `prometheus-pve-exporter` (~80 MB,
one container, read-only API token) gives you:

- a real `up{job="pve"}` for node-down detection
- cluster quorum state
- storage and backup-job state

Create the token with the least privilege that works:

```bash
pveum user add prometheus@pve
pveum aclmod / -user prometheus@pve -role PVEAuditor    # read-only
pveum user token add prometheus@pve monitoring --privsep 0
```

Scrape config, noting that the target is the **PVE node** and the exporter is
reached through relabelling:

```yaml
  - job_name: pve
    metrics_path: /pve
    params: { module: [default], cluster: ['1'], node: ['1'] }
    static_configs:
      - targets: ['192.168.0.10']
    relabel_configs:
      - { source_labels: [__address__],   target_label: __param_target }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: 'pve-exporter:9221' }
```
