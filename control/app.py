#!/usr/bin/env python3
"""
Control panel for the homelab-monitoring stack.

Deliberately separate from Grafana: a button inside Grafana cannot start
Grafana. This service is tiny (~15 MB) and always runs, so it is there when
the thing it controls is not.

Standard library only - no pip install, no dependency updates to chase.
"""
import base64
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT_DIR = os.environ.get("PROJECT_DIR", "/srv/monitoring")
CONTROL_USER = os.environ.get("CONTROL_USER", "admin")
CONTROL_PASSWORD = os.environ.get("CONTROL_PASSWORD", "")
PORT = int(os.environ.get("CONTROL_PORT", "8080"))
NODE_NAME = os.environ.get("NODE_NAME", "unknown")
PEER_IP = os.environ.get("PEER_IP", "")
VMAGENT_URL = os.environ.get("VMAGENT_URL", "http://vmagent:8429")
# Optional explicit Grafana URL. Left empty, the UI builds one from the
# hostname the browser is already using, which works over LAN, Tailscale or a
# tunnel without anything being configured.
GRAFANA_ROOT_URL = os.environ.get("GRAFANA_ROOT_URL", "")
GRAFANA_PORT = os.environ.get("GRAFANA_PORT", "3000")
GRAFANA_API = os.environ.get("GRAFANA_API", "http://grafana:3000")
GRAFANA_ADMIN_USER = os.environ.get("GRAFANA_ADMIN_USER", "admin")
GRAFANA_ADMIN_PASSWORD = os.environ.get("GRAFANA_ADMIN_PASSWORD", "")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# The panel never acts on itself - stopping the control service from the
# control service leaves you with no way to start it again.
MANAGED = {
    "grafana": {
        "container": "hm-grafana",
        "label": "Grafana",
        "desc": "Dashboards, Explore, alert rules",
        "ram": "~317 MB",
        "optional": True,
    },
    "victoriametrics": {
        "container": "hm-victoriametrics",
        "label": "VictoriaMetrics",
        "desc": "Metric store - holds a full copy of both nodes",
        "ram": "~68 MB",
        "optional": False,
    },
    "victorialogs": {
        "container": "hm-victorialogs",
        "label": "VictoriaLogs",
        "desc": "Log store - this node's guests only",
        "ram": "~6 MB",
        "optional": False,
    },
    "vmagent": {
        "container": "hm-vmagent",
        "label": "vmagent",
        "desc": "Collects and dual-writes to both nodes",
        "ram": "~57 MB",
        "optional": False,
    },
}
CONTAINERS = {m["container"]: name for name, m in MANAGED.items()}

JOBS = {}
JOBS_LOCK = threading.Lock()


def run(args, timeout=300, cwd=None):
    """
    Run a command and return (rc, stdout, stderr).

    cwd defaults to None, not PROJECT_DIR: plain `docker` calls need no
    particular directory, and forcing one that does not exist makes every
    command fail with a confusing "not created" instead of a real error.
    Only compose needs the project directory, and it asks for it explicitly.
    """
    if cwd and not os.path.isdir(cwd):
        return 1, "", "project directory %s not found in this container" % cwd
    try:
        p = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ds" % timeout
    except Exception as exc:  # noqa: BLE001
        return 1, "", str(exc)


def compose(*args, timeout=300):
    """
    Compose needs the project directory, and the path must be identical inside
    this container and on the host - compose resolves the relative bind mounts
    in docker-compose.yml here, then hands absolute host paths to the daemon.
    Hence the /srv/monitoring:/srv/monitoring mount.
    """
    return run(["docker", "compose", *args], timeout=timeout, cwd=PROJECT_DIR)


def docker_ps():
    """
    Service name -> {state, health, status}, for created containers.

    Uses `docker ps` on fixed container names rather than `docker compose ps`.
    Compose would resolve the project's relative bind mounts against this
    container's filesystem, which only works when the project path is identical
    inside and out. Plain docker needs no such agreement.
    """
    rc, out, _ = run(
        ["docker", "ps", "--all", "--no-trunc", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}"],
        timeout=25,
    )
    result = {}
    if rc != 0:
        return result
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        cname, state, status = parts[0].strip(), parts[1].strip(), parts[2].strip()
        service = CONTAINERS.get(cname)
        if not service:
            continue
        health = ""
        low = status.lower()
        if "(healthy)" in low:
            health = "healthy"
        elif "(unhealthy)" in low:
            health = "unhealthy"
        elif "health: starting" in low:
            health = "starting"
        result[service] = {"state": state, "health": health, "status": status, "name": cname}
    return result


# `docker stats --no-stream` takes 2-3 seconds even on an idle host, because it
# waits a sampling interval. Calling it inline made /api/status take ~3s, which
# reads as a dead page. Refresh it on a background thread and serve the cache.
MEM_CACHE = {}
MEM_CACHE_AT = 0.0


def _mem_refresh_loop():
    global MEM_CACHE, MEM_CACHE_AT
    while True:
        rc, out, _ = run(
            ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.MemUsage}}"],
            timeout=40,
        )
        if rc == 0:
            fresh = {}
            for line in out.splitlines():
                if "\t" in line:
                    name, usage = line.split("\t", 1)
                    fresh[name.strip()] = usage.split("/")[0].strip()
            MEM_CACHE, MEM_CACHE_AT = fresh, time.time()
        time.sleep(20)


def docker_mem():
    """Container name -> memory string, from cache. Never blocks a request."""
    # Stale readings are worse than none: a stopped container must not keep
    # showing the memory it used to hold.
    if time.time() - MEM_CACHE_AT > 90:
        return {}
    return MEM_CACHE


def replication():
    """Pending bytes per remote-write destination, straight from vmagent."""
    try:
        with urllib.request.urlopen(VMAGENT_URL + "/metrics", timeout=5) as resp:
            body = resp.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, TimeoutError):
        return {"available": False, "destinations": []}

    dests = []
    for m in re.finditer(
        r'^vmagent_remotewrite_pending_data_bytes\{([^}]*)\}\s+([0-9.e+-]+)',
        body,
        re.M,
    ):
        labels, value = m.group(1), m.group(2)
        url_m = re.search(r'url="([^"]*)"', labels)
        try:
            pending = int(float(value))
        except ValueError:
            pending = 0
        dests.append({"url": url_m.group(1) if url_m else "?", "pending_bytes": pending})
    dests.sort(key=lambda d: d["url"])
    return {"available": True, "destinations": dests}


def alerting_mode():
    """primary if ALERTING_DIR points at the real rules, else standby."""
    path = os.path.join(PROJECT_DIR, ".env")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.strip().startswith("ALERTING_DIR="):
                    return "standby" if "disabled" in line else "primary"
    except OSError:
        pass
    return "unknown"


def set_alerting_mode(mode):
    """Rewrite ALERTING_DIR in .env so the change survives a reboot."""
    path = os.path.join(PROJECT_DIR, ".env")
    target = (
        "./config/grafana/provisioning/alerting"
        if mode == "primary"
        else "./config/grafana/provisioning/alerting-disabled"
    )
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    found = False
    for i, line in enumerate(lines):
        if line.strip().startswith("ALERTING_DIR="):
            lines[i] = "ALERTING_DIR=%s\n" % target
            found = True
    if not found:
        lines.append("ALERTING_DIR=%s\n" % target)
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)


# --------------------------------------------------------------------------
# settings - credentials and alert channels, written back to .env
# --------------------------------------------------------------------------

ENV_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")


def env_read():
    values = {}
    try:
        with open(os.path.join(PROJECT_DIR, ".env"), "r", encoding="utf-8") as fh:
            for line in fh:
                m = ENV_KEY_RE.match(line)
                if m:
                    values[m.group(1)] = line.split("=", 1)[1].rstrip("\n")
    except OSError:
        pass
    return values


def env_write(updates):
    """Update or append keys in .env, preserving comments and ordering."""
    path = os.path.join(PROJECT_DIR, ".env")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        lines = []
    seen = set()
    out = []
    for line in lines:
        m = ENV_KEY_RE.match(line)
        if m and m.group(1) in updates:
            key = m.group(1)
            out.append("%s=%s\n" % (key, updates[key]))
            seen.add(key)
        else:
            out.append(line)
    for key, value in updates.items():
        if key not in seen:
            out.append("%s=%s\n" % (key, value))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(out)
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def grafana_api(method, path, body=None, user=None, password=None):
    url = GRAFANA_API + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    creds = "%s:%s" % (
        user if user is not None else GRAFANA_ADMIN_USER,
        password if password is not None else GRAFANA_ADMIN_PASSWORD,
    )
    req.add_header("Authorization", "Basic " + base64.b64encode(creds.encode()).decode())
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def do_control_creds(jid, new_user, new_password):
    """Change the panel's own credentials, then restart the panel."""
    try:
        updates = {}
        if new_user:
            updates["CONTROL_USER"] = new_user
        if new_password:
            updates["CONTROL_PASSWORD"] = new_password
        if not updates:
            upd(jid, state="error", step="nothing to change", percent=100)
            return
        upd(jid, step="writing .env", percent=35)
        env_write(updates)
        upd(
            jid,
            state="done",
            percent=100,
            step="saved - panel restarting, sign in again",
            line="The panel restarts in a moment. Your browser will ask for the new credentials.",
        )

        # Restart after responding, or the request dies before the UI sees it.
        def _restart():
            time.sleep(3)
            run(["docker", "restart", "hm-control"], timeout=60)

        threading.Thread(target=_restart, daemon=True).start()
    except Exception as exc:  # noqa: BLE001
        upd(jid, state="error", step="failed", percent=100, line=str(exc))


def do_grafana_creds(jid, new_user, new_password):
    """
    Change Grafana's admin credentials through its API.

    GF_SECURITY_ADMIN_* only apply when the database is first created, so
    editing .env alone would silently do nothing to a running install. We
    change it live, then write .env so a rebuilt volume matches.
    """
    global GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD
    try:
        if not docker_ps().get("grafana", {}).get("state") == "running":
            upd(
                jid,
                state="error",
                percent=100,
                step="Grafana is not running",
                line="Start Grafana first - its credentials live in its own database.",
            )
            return

        upd(jid, step="looking up admin user", percent=20)
        _, body = grafana_api(
            "GET", "/api/users/lookup?loginOrEmail=" + urllib.parse.quote(GRAFANA_ADMIN_USER)
        )
        user = json.loads(body)
        uid = user["id"]

        # Rename first, while the old password is still valid.
        if new_user and new_user != GRAFANA_ADMIN_USER:
            upd(jid, step="changing username", percent=45)
            grafana_api(
                "PUT",
                "/api/users/%d" % uid,
                {
                    "login": new_user,
                    "email": user.get("email") or new_user,
                    "name": user.get("name") or new_user,
                },
            )
            GRAFANA_ADMIN_USER = new_user
            upd(jid, line="username changed")

        if new_password:
            upd(jid, step="changing password", percent=70)
            grafana_api("PUT", "/api/admin/users/%d/password" % uid, {"password": new_password})
            GRAFANA_ADMIN_PASSWORD = new_password
            upd(jid, line="password changed")

        upd(jid, step="writing .env", percent=90)
        updates = {}
        if new_user:
            updates["GRAFANA_ADMIN_USER"] = new_user
        if new_password:
            updates["GRAFANA_ADMIN_PASSWORD"] = new_password
        env_write(updates)
        upd(jid, state="done", step="Grafana credentials updated", percent=100)
    except urllib.error.HTTPError as exc:
        upd(
            jid,
            state="error",
            percent=100,
            step="Grafana rejected the change (HTTP %s)" % exc.code,
            line=exc.read().decode("utf-8", "replace")[:400],
        )
    except Exception as exc:  # noqa: BLE001
        upd(jid, state="error", step="failed", percent=100, line=str(exc))


def do_channels(jid, values):
    """Write alert channels to .env, regenerate provisioning, restart Grafana."""
    try:
        upd(jid, step="writing .env", percent=20)
        env_write(
            {
                "NTFY_URL": values.get("ntfy", ""),
                "DISCORD_WEBHOOK_URL": values.get("discord", ""),
                "TELEGRAM_BOT_TOKEN": values.get("telegram_token", ""),
                "TELEGRAM_CHAT_ID": values.get("telegram_chat", ""),
            }
        )
        upd(jid, step="generating contact points", percent=45)
        rc, out, err = run(
            ["sh", os.path.join(PROJECT_DIR, "scripts", "render-alerting.sh"), PROJECT_DIR],
            timeout=60,
        )
        for line in (out + err).splitlines():
            if line.strip():
                upd(jid, line=line.strip())
        if rc != 0:
            upd(jid, state="error", step="could not generate config", percent=100)
            return

        if docker_ps().get("grafana", {}).get("state") == "running":
            upd(jid, step="restarting Grafana", percent=65)
            run(["docker", "restart", "hm-grafana"], timeout=180)
            ok = wait_healthy(jid, "grafana", 70, 97)
            upd(
                jid,
                state="done" if ok else "error",
                step="channels applied" if ok else "restarted but not healthy",
                percent=100,
            )
        else:
            upd(
                jid,
                state="done",
                percent=100,
                step="saved - applies when Grafana starts",
            )
    except Exception as exc:  # noqa: BLE001
        upd(jid, state="error", step="failed", percent=100, line=str(exc))


# --------------------------------------------------------------------------
# jobs - every action runs in a thread so the UI can render real progress
# --------------------------------------------------------------------------

def new_job(service, action):
    jid = uuid.uuid4().hex[:12]
    with JOBS_LOCK:
        JOBS[jid] = {
            "id": jid,
            "service": service,
            "action": action,
            "state": "running",
            "percent": 3,
            "step": "queued",
            "log": [],
            "started": time.time(),
        }
        # Keep the map from growing without bound.
        if len(JOBS) > 40:
            for old in sorted(JOBS.values(), key=lambda j: j["started"])[:10]:
                JOBS.pop(old["id"], None)
    return jid


def upd(jid, **kw):
    with JOBS_LOCK:
        job = JOBS.get(jid)
        if not job:
            return
        line = kw.pop("line", None)
        if line:
            job["log"].append(line)
            job["log"] = job["log"][-60:]
        job.update(kw)


def wait_healthy(jid, service, start_pct, end_pct, timeout=180):
    """Poll compose state, moving the bar from start_pct toward end_pct."""
    deadline = time.time() + timeout
    running_since = None
    while time.time() < deadline:
        row = docker_ps().get(service, {})
        state = (row.get("state") or "").lower()
        health = (row.get("health") or "").lower()
        frac = 1 - max(0.0, (deadline - time.time()) / timeout)
        upd(jid, percent=int(start_pct + (end_pct - start_pct) * min(frac * 3, 0.95)))

        if state == "running":
            if health == "healthy":
                upd(jid, step="healthy", line="health check passing")
                return True
            if not health:
                # No healthcheck defined (VictoriaLogs is distroless). Treat a
                # few seconds of continuous running as good enough.
                running_since = running_since or time.time()
                if time.time() - running_since > 5:
                    upd(jid, step="running", line="running (no healthcheck defined)")
                    return True
            else:
                upd(jid, step="waiting for health check (%s)" % health)
        elif state in ("exited", "dead"):
            upd(jid, step="container exited", line="container exited unexpectedly")
            return False
        time.sleep(2)
    upd(jid, step="timed out waiting for health")
    return False


def do_action(jid, service, action):
    container = MANAGED.get(service, {}).get("container", service)
    try:
        if action == "stop":
            upd(jid, step="stopping container", percent=30, line="docker stop " + container)
            rc, out, err = run(["docker", "stop", container], timeout=120)
            for line in (out + err).splitlines():
                if line.strip():
                    upd(jid, line=line.strip())
            if rc != 0:
                upd(jid, state="error", step="stop failed", percent=100)
                return
            upd(jid, state="done", step="stopped - memory released", percent=100)
            return

        if action in ("start", "restart"):
            verb = "restart" if action == "restart" else "start"
            if not docker_ps().get(service):
                upd(
                    jid,
                    state="error",
                    percent=100,
                    step="container does not exist",
                    line="Run `docker compose up -d` once on the host to create it.",
                )
                return

            upd(jid, step="%sing container" % verb, percent=30, line="docker %s %s" % (verb, container))
            rc, out, err = run(["docker", verb, container], timeout=180)
            for line in (out + err).splitlines():
                if line.strip():
                    upd(jid, line=line.strip())
            if rc != 0:
                upd(jid, state="error", step="%s failed" % verb, percent=100)
                return

            upd(jid, step="waiting for service", percent=60)
            ok = wait_healthy(jid, service, 60, 97)
            upd(
                jid,
                state="done" if ok else "error",
                step="ready" if ok else "started but not healthy",
                percent=100,
            )
            return

        if action in ("promote", "demote"):
            mode = "primary" if action == "promote" else "standby"
            upd(jid, step="rewriting .env", percent=15, line="ALERTING_DIR -> %s" % mode)
            set_alerting_mode(mode)
            upd(jid, step="recreating Grafana", percent=40)
            rc, out, err = compose("up", "-d", "--force-recreate", "grafana", timeout=600)
            for line in (out + err).splitlines():
                if line.strip():
                    upd(jid, line=line.strip())
            if rc != 0:
                upd(jid, state="error", step="recreate failed", percent=100)
                return
            ok = wait_healthy(jid, "grafana", 60, 97)
            upd(
                jid,
                state="done" if ok else "error",
                step="alerting %s" % mode if ok else "recreated but not healthy",
                percent=100,
            )
            return

        upd(jid, state="error", step="unknown action", percent=100)
    except Exception as exc:  # noqa: BLE001
        upd(jid, state="error", step="internal error", percent=100, line=str(exc))


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "hm-control"

    def log_message(self, *args):
        pass  # quiet; the container log is for real problems

    def _auth_ok(self):
        if not CONTROL_PASSWORD:
            return True  # no password set: open. Documented in .env.example.
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            return False
        user, _, pw = decoded.partition(":")
        return user == CONTROL_USER and pw == CONTROL_PASSWORD

    def _deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="homelab-monitoring"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if not self._auth_ok():
            return self._deny()
        path = self.path.split("?")[0]

        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(STATIC_DIR, "index.html"), "rb") as fh:
                    body = fh.read()
            except OSError:
                return self._json({"error": "ui missing"}, 500)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/api/status":
            ps = docker_ps()
            mem = docker_mem()
            services = []
            for name, meta in MANAGED.items():
                row = ps.get(name, {})
                services.append(
                    {
                        "name": name,
                        "label": meta["label"],
                        "desc": meta["desc"],
                        "optional": meta["optional"],
                        "expected_ram": meta["ram"],
                        "state": (row.get("state") or "not created").lower(),
                        "health": (row.get("health") or "").lower(),
                        "status": row.get("status") or "",
                        "memory": mem.get(meta["container"], ""),
                    }
                )
            return self._json(
                {
                    "node": NODE_NAME,
                    "peer": PEER_IP,
                    "grafana_url": GRAFANA_ROOT_URL,
                    "grafana_port": GRAFANA_PORT,
                    "alerting": alerting_mode(),
                    "services": services,
                    "replication": replication(),
                    "time": int(time.time()),
                }
            )

        if path == "/api/settings":
            env = env_read()
            # Secrets are never sent back to the browser - only whether each
            # channel is configured. Blank fields in the form mean "clear".
            return self._json(
                {
                    "control_user": CONTROL_USER,
                    "grafana_user": GRAFANA_ADMIN_USER,
                    "channels": {
                        "ntfy": bool(env.get("NTFY_URL")),
                        "discord": bool(env.get("DISCORD_WEBHOOK_URL")),
                        "telegram": bool(
                            env.get("TELEGRAM_BOT_TOKEN") and env.get("TELEGRAM_CHAT_ID")
                        ),
                    },
                }
            )

        if path.startswith("/api/job/"):
            jid = path.rsplit("/", 1)[-1]
            with JOBS_LOCK:
                job = JOBS.get(jid)
                return self._json(dict(job) if job else {"error": "no such job"}, 200 if job else 404)

        if path.startswith("/api/logs/"):
            service = path.rsplit("/", 1)[-1]
            if service not in MANAGED:
                return self._json({"error": "unknown service"}, 400)
            container = MANAGED[service]["container"]
            _, out, err = run(["docker", "logs", "--tail", "120", container], timeout=30)
            return self._json({"service": service, "log": (out + err)[-20000:]})

        return self._json({"error": "not found"}, 404)

    def do_POST(self):  # noqa: N802
        if not self._auth_ok():
            return self._deny()
        path = self.path.split("?")[0]

        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._json({"error": "bad json"}, 400)

        if path == "/api/settings/control":
            user = (payload.get("user") or "").strip()
            pw = payload.get("password") or ""
            if pw and len(pw) < 8:
                return self._json({"error": "password must be at least 8 characters"}, 400)
            if not user and not pw:
                return self._json({"error": "nothing to change"}, 400)
            jid = new_job("control", "credentials")
            threading.Thread(
                target=do_control_creds, args=(jid, user, pw), daemon=True
            ).start()
            return self._json({"job": jid})

        if path == "/api/settings/grafana":
            user = (payload.get("user") or "").strip()
            pw = payload.get("password") or ""
            if pw and len(pw) < 8:
                return self._json({"error": "password must be at least 8 characters"}, 400)
            if not user and not pw:
                return self._json({"error": "nothing to change"}, 400)
            jid = new_job("grafana", "credentials")
            threading.Thread(
                target=do_grafana_creds, args=(jid, user, pw), daemon=True
            ).start()
            return self._json({"job": jid})

        if path == "/api/settings/channels":
            jid = new_job("grafana", "channels")
            threading.Thread(target=do_channels, args=(jid, payload), daemon=True).start()
            return self._json({"job": jid})

        if path != "/api/action":
            return self._json({"error": "not found"}, 404)

        action = payload.get("action")
        service = payload.get("service")

        if action in ("promote", "demote"):
            service = "grafana"
        elif service not in MANAGED:
            return self._json({"error": "unknown service"}, 400)
        if action not in ("start", "stop", "restart", "promote", "demote"):
            return self._json({"error": "unknown action"}, 400)

        jid = new_job(service, action)
        threading.Thread(target=do_action, args=(jid, service, action), daemon=True).start()
        return self._json({"job": jid})


if __name__ == "__main__":
    if not CONTROL_PASSWORD:
        print("WARNING: CONTROL_PASSWORD is empty - the panel is unauthenticated.")
    threading.Thread(target=_mem_refresh_loop, daemon=True).start()
    print("control panel on :%d (project %s, node %s)" % (PORT, PROJECT_DIR, NODE_NAME))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
