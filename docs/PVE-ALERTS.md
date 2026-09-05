# Proxmox guest alerts

The metric names from PVE's push match nothing that guides or community
dashboards assume, and rules written against guessed names silently never fire
— worse than having no rule, because you believe you are covered. So the names
below were read off a live cluster rather than inferred.

## The schema, confirmed on PVE 9.2

These are the real names from the InfluxDB push, not guesses:

| Measurement | Useful fields | Applies to |
| --- | --- | --- |
| `cpustat_*` | `cpu` (0–1), `cpus`, `avg1/5/15`, `iowait`, `idle`, `user`, `system`, `wait`, `steal` | nodes and guests |
| `blockstat_*` | `used`, `blocks`, `bavail`, `rd_bytes`, `wr_bytes`, `rd_operations`, `wr_operations` | guests |
| `ballooninfo_*` | `total_mem`, `free_mem`, `max_mem`, `mem_swapped_in/out` | QEMU guests **with the agent** |

Labels:

| Label | Values |
| --- | --- |
| `object` | `nodes`, `lxc`, `qemu`, `storages` |
| `host` | node name *or* guest name *or* storage name, depending on `object` |
| `vmid` | guest id |
| `nodename` | which PVE node a guest is on |
| `node` | **ours**, not PVE's — which vmagent ingested the sample |

Note `cpustat_cpu` is a **fraction, not a percent** — multiply by 100.

`config/grafana/provisioning/alerting/rules-pve.yml` already ships rules against
these, and `dashboards/proxmox.json` is built for them.

> **Community dashboards do not work with this push.** 10347, 23855 and 24550
> all expect either OTLP names or the `pve_*` series from
> `prometheus-pve-exporter`. Add that exporter if you want them, which also
> gives you a real `up` series — see the bottom of this page.

## The guest-stopped rule

Alert on the **transition**, not the state. A naive "guest is not running" rule
fires forever for every guest you intentionally left off, which is the fastest
way to train yourself to ignore your own alerts.

Which form is correct depends on whether PVE keeps reporting `cpustat` for a
stopped guest. Settle it with one query — compare the count to how many guests
are actually running:

```bash
curl -s 'http://<mon-ip>:8428/api/v1/query'   --data-urlencode 'query=count by (object) (cpustat_cpu)'
```

**If the count matches only running guests**, stopped guests stop reporting, so
detect the disappearance — seen in the last 2h, absent for 5m:

```promql
max by (vmid, host, nodename) (max_over_time(cpustat_cpu{object=~"lxc|qemu"}[2h]))
unless
max by (vmid, host, nodename) (last_over_time(cpustat_cpu{object=~"lxc|qemu"}[5m]))
```

A guest off for weeks never alerts, and a deliberate shutdown costs one
notification that self-clears after two hours.

**If the count matches every configured guest**, stopped guests report zeros, so
find the status field instead:

```bash
curl -s 'http://<mon-ip>:8428/api/v1/label/__name__/values'   | tr ',' '
' | grep -iE 'status|uptime|running'
```

and alert on that going to 0 with the same `max_over_time` / `last_over_time`
transition shape.

Either way, add a Proxmox **tag** (`noalert`) to guests you toggle often and
exclude them, so the rule needs no maintenance.

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
