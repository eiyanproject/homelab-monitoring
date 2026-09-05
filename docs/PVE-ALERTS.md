# Proxmox guest alerts

The metric names from PVE's push match nothing that guides or community
dashboards assume, and rules written against guessed names silently never fire
— worse than having no rule, because you believe you are covered. So the names
below were read off a live cluster rather than inferred.

## The schema, confirmed on PVE 9.2

Read off a live cluster. **Nodes and guests use completely different
measurement families** — this is the thing that catches people out.

**`object="nodes"`**

| Metric | Notes |
| --- | --- |
| `cpustat_cpu` | **0–1 fraction, not a percent.** Multiply by 100 |
| `cpustat_cpus`, `cpustat_avg1/5/15` | core count and load average |
| `cpustat_iowait`, `idle`, `user`, `system`, `steal` | also fractions |
| `memory_memtotal/memused/memfree/memavailable` | bytes |
| `memory_swaptotal/swapused/swapfree` | bytes |
| `memory_arcsize/arcmin/arcmax` | ZFS ARC — zero without ZFS |
| `nics_receive`, `nics_transmit` | counters, use `rate()` |
| `blockstat_*` | the **node's** root filesystem, not any guest's |
| `system_uptime` | seconds |

**`object="lxc"` and `object="qemu"`**

| Metric | Notes |
| --- | --- |
| `system_cpu` | fraction; `system_cpus` is the core count |
| `system_mem` / `system_maxmem` | bytes used vs the configured limit |
| `system_disk` / `system_maxdisk` | **guest filesystem usage, with no agent installed** |
| `system_netin`, `system_netout` | counters |
| `system_diskread`, `system_diskwrite` | counters |
| `system_status` | guest state — see below |
| `system_pressure{cpu,io,memory}{some,full}` | PSI: time tasks spent *blocked* |
| `system_uptime`, `system_pid`, `system_name`, `system_tags` | |

QEMU adds `ballooninfo_*` (guest agent only), `blockstat_*` for virtual block
devices, and `nics_netin`/`nics_netout`.

**`object="storages"`**: `system_used`, `system_total`, `system_avail`,
plus `system_active`, `system_enabled`, `system_shared`.

Labels everywhere: `host` (node **or** guest **or** storage name, depending on
`object`), `vmid`, `nodename`, and `node` — which is *ours*, identifying the
vmagent that ingested the sample.

### Two things worth knowing

**`system_disk` / `system_maxdisk` means guest disk alerts need no agent.**
That removes most of the reason to install `node_exporter` in every guest.

**PSI is the best early warning here.** `system_pressureiosome` rises while a
disk is *starting* to struggle, well before any utilisation graph saturates.

> **Community dashboards do not work with this push.** 10347, 23855 and 24550
> all expect OTLP names or the `pve_*` series from `prometheus-pve-exporter`.
> `dashboards/proxmox.json` is built for the names above; add that exporter if
> you want the community ones, which also gives you a real `up` series.

## The guest-stopped rule

`system_status` exists for both `lxc` and `qemu`, which is the right signal —
but PVE's status is a *string* (`running` / `stopped`), and how VictoriaMetrics
stored it decides the rule. Check with:

```bash
curl -s 'http://<mon-ip>:8428/api/v1/query'   --data-urlencode 'query=system_status{object=~"lxc|qemu"}' | head -c 600
```

**If it returns numeric values** (e.g. `1` for running), alert on the
transition, so a guest you deliberately left off never alerts:

```promql
system_status{object=~"lxc|qemu"} == 0
  and max_over_time(system_status{object=~"lxc|qemu"}[2h]) == 1
```

**If it returns nothing, or every guest reads `0`**, the string was not stored
as a usable value. Then detect disappearance instead — seen in the last 2h,
absent for the last 5m:

```promql
max by (vmid, host, nodename) (max_over_time(system_cpu{object=~"lxc|qemu"}[2h]))
unless
max by (vmid, host, nodename) (last_over_time(system_cpu{object=~"lxc|qemu"}[5m]))
```

Either way, tag guests you toggle often with `noalert` in Proxmox and exclude
them, so the rule needs no maintenance as your guest list changes.

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
