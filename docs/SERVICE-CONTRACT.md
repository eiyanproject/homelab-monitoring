# Service contract

Not per-service integration work — one contract every service satisfies, so
joining the monitoring system costs about fifteen lines.

## The endpoints

```
GET /healthz   200 {"status":"ok","version":"1.4.2"}
               Process is alive. No dependency checks. Never authenticated.

GET /readyz    200 only when DB, queue and upstreams are reachable.
               This is what the external watcher polls.

GET /metrics   Prometheus text format, on a port registered in targets/.
```

## The logs

One JSON object per line, to **stdout**. Never a log file — nothing to rotate,
nothing to run out of disk.

```json
{"ts":"2026-09-05T01:20:56Z","level":"error","msg":"upstream timeout","svc":"catalog","route":"/api/search","dur_ms":30001}
```

Required keys: `ts`, `level`, `msg`, `svc`. Run under systemd, and
journald → rsyslog → VictoriaLogs carries it with no extra work. VictoriaLogs
derives `level` from syslog priority automatically, so `level:error` works
immediately.

## The four metrics

| Metric | Type | Labels | Answers |
| --- | --- | --- | --- |
| `<svc>_build_info` | gauge | `version`, `commit` | Which version is actually running? |
| `<svc>_requests_total` | counter | `route`, `method`, `status` | Rate, and the error ratio |
| `<svc>_request_duration_seconds` | histogram | `route` | p50 / p95 latency |
| `<svc>_errors_total` | counter | `kind` | What is failing, by category |

Rate, errors, duration — the RED method. Build the three panels once as a
Grafana library dashboard and every future service gets a working dashboard by
changing one variable.

> **Never label with a request ID, user ID, session, or a full URL path.** Each
> distinct value becomes a stored time series. One unbounded label will take the
> metric store down. Label with the route *template* (`/api/items/:id`), never
> the value (`/api/items/8134`).

## Python

```python
from prometheus_client import Counter, Histogram, start_http_server

REQS = Counter("catalog_requests_total", "", ["route", "method", "status"])
DUR  = Histogram("catalog_request_duration_seconds", "", ["route"])

start_http_server(9101)          # that is the whole integration
```

## Node

```js
const client = require('prom-client');
client.collectDefaultMetrics();

const reqs = new client.Counter({
  name: 'catalog_requests_total',
  help: '',
  labelNames: ['route', 'method', 'status'],
});

require('http')
  .createServer(async (_, res) => res.end(await client.register.metrics()))
  .listen(9101);
```

## Registering it

In the mon LXC, add to `/srv/monitoring/targets/services.json`:

```json
[
  {
    "targets": ["192.168.0.42:9101"],
    "labels": { "job": "service", "service": "catalog-api", "kind": "lxc" }
  }
]
```

vmagent reloads it within 60 s. No restart.

## Make it automatic

Put this in `CLAUDE.md` in each service repo so new services arrive
instrumented instead of needing a retrofit:

```markdown
## Observability

Every HTTP service in this repo exposes:
  - GET /healthz  - liveness, no dependency checks, unauthenticated
  - GET /readyz   - 200 only when dependencies are reachable
  - GET /metrics  - Prometheus text format via prometheus_client / prom-client

Metrics: <svc>_build_info, <svc>_requests_total{route,method,status},
<svc>_request_duration_seconds{route}, <svc>_errors_total{kind}.
Label with route templates, never with IDs or full paths.

Logs: single-line JSON to stdout with keys ts, level, msg, svc. Never log files.

Register new services in the monitoring repo's targets/services.json.
```
