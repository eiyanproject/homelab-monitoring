#!/usr/bin/env python3
"""
Deadman watchdog. Runs OUTSIDE the homelab, on a host the homelab cannot take
down with it.

Every monitoring stack reports in on a timer. If one stops reporting, this
notifies you. That is the whole job, and it is the one thing nothing inside the
cluster can do: a stack cannot tell you it is dead.

Standard library only - it runs on a 1 GB VM already hosting other things, so
it costs ~15 MB and has no dependencies to keep patched.

Config comes from the environment (see watchdog.env):
    NTFY_URL        where to send alerts, e.g. https://ntfy.example.com/topic
    NTFY_TOKEN      optional bearer token if ntfy requires auth
    EXPECTED        comma-separated node names that must report in
    STALE_AFTER     seconds without a beat before alerting (default 300)
    LISTEN          host:port to listen on (default 127.0.0.1:9911)
    STATE_FILE      where last-seen times persist across restarts
"""
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NTFY_URL = os.environ.get("NTFY_URL", "").rstrip("/")
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "")
EXPECTED = [n.strip() for n in os.environ.get("EXPECTED", "").split(",") if n.strip()]
STALE_AFTER = int(os.environ.get("STALE_AFTER", "300"))
LISTEN = os.environ.get("LISTEN", "127.0.0.1:9911")
STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/hm-watchdog/state.json")

LOCK = threading.Lock()
STATE = {}          # node -> {"last": epoch, "alerted": bool, "info": {...}}


def human_age(seconds):
    """"0 minutes" reads like a bug in an alert. Say what it actually was."""
    seconds = int(seconds)
    if seconds < 120:
        return "%d seconds" % seconds
    if seconds < 7200:
        return "%d minutes" % (seconds // 60)
    return "%.1f hours" % (seconds / 3600.0)


def log(msg):
    print("%s  %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg), flush=True)


def load_state():
    global STATE
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            STATE = json.load(fh)
        log("loaded state for %d node(s)" % len(STATE))
    except (OSError, json.JSONDecodeError):
        STATE = {}


def save_state():
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(STATE, fh)
        os.replace(tmp, STATE_FILE)
    except OSError as exc:
        log("could not save state: %s" % exc)


def notify(title, message, priority="default", tags=""):
    """Post to ntfy. Never raise - a failed notification must not stop the loop."""
    if not NTFY_URL:
        log("NTFY_URL not set, would have sent: %s - %s" % (title, message))
        return False
    req = urllib.request.Request(NTFY_URL, data=message.encode("utf-8"), method="POST")
    req.add_header("Title", title)
    req.add_header("Priority", priority)
    if tags:
        req.add_header("Tags", tags)
    if NTFY_TOKEN:
        req.add_header("Authorization", "Bearer " + NTFY_TOKEN)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        log("notify failed: %s" % exc)
        return False


def checker():
    """The actual deadman. Alert on transition, once, and again on recovery."""
    # Check several times per staleness window. A fixed 30s interval against a
    # short STALE_AFTER can step straight over the healthy period, so a node
    # that recovered never gets noticed as recovered.
    interval = max(5, min(30, STALE_AFTER // 3))
    while True:
        time.sleep(interval)
        now = time.time()
        with LOCK:
            # A node that has never reported is not necessarily down - it may
            # not be built yet. Only alert on nodes we have heard from at least
            # once, or that are explicitly EXPECTED.
            known = set(STATE) | set(EXPECTED)
            changed = False
            for node in sorted(known):
                st = STATE.setdefault(node, {"last": 0, "alerted": False, "info": {}})
                age = now - st["last"]

                if st["last"] == 0:
                    # Expected but never seen. Say so once, then stay quiet.
                    if not st["alerted"]:
                        st["alerted"] = True
                        changed = True
                        notify(
                            "Never reported: %s" % node,
                            "%s is in EXPECTED but has never sent a heartbeat.\n"
                            "Either it is not built yet, or it cannot reach this watchdog." % node,
                            priority="default", tags="warning",
                        )
                    continue

                if age > STALE_AFTER and not st["alerted"]:
                    st["alerted"] = True
                    changed = True
                    notify(
                        "DOWN: %s" % node,
                        "No heartbeat from %s for %d minutes.\n"
                        "The node, its monitoring stack, the power or the network is gone.\n"
                        "Nothing inside the cluster can tell you this - that is why it runs out here."
                        % (node, human_age(age)),
                        priority="urgent", tags="rotating_light",
                    )
                    log("ALERT %s stale for %ds" % (node, age))

                elif age <= STALE_AFTER and st["alerted"]:
                    st["alerted"] = False
                    changed = True
                    notify(
                        "Recovered: %s" % node,
                        "%s is reporting again." % node,
                        priority="default", tags="white_check_mark",
                    )
                    log("RECOVERED %s" % node)

            if changed:
                save_state()


class Handler(BaseHTTPRequestHandler):
    server_version = "hm-watchdog"

    def log_message(self, *args):
        pass  # the journal is for real problems, not one line per heartbeat

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        path = self.path.split("?")[0].rstrip("/")
        if not path.startswith("/beat/"):
            return self._json({"error": "not found"}, 404)
        node = path[len("/beat/"):]
        if not node or "/" in node or len(node) > 64:
            return self._json({"error": "bad node name"}, 400)

        info = {}
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if 0 < length < 65536:
                info = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            info = {}

        with LOCK:
            st = STATE.setdefault(node, {"last": 0, "alerted": False, "info": {}})
            st["last"] = time.time()
            st["info"] = info if isinstance(info, dict) else {}
            save_state()
        return self._json({"ok": True, "node": node})

    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0].rstrip("/")
        if path in ("", "/status"):
            now = time.time()
            with LOCK:
                nodes = {
                    n: {
                        "seconds_since_beat": int(now - s["last"]) if s["last"] else None,
                        "healthy": bool(s["last"]) and (now - s["last"]) <= STALE_AFTER,
                        "alerted": s["alerted"],
                        "info": s.get("info", {}),
                    }
                    for n, s in sorted(STATE.items())
                }
            return self._json({"stale_after": STALE_AFTER, "expected": EXPECTED, "nodes": nodes})
        if path == "/healthz":
            return self._json({"status": "ok"})
        return self._json({"error": "not found"}, 404)


if __name__ == "__main__":
    host, _, port = LISTEN.rpartition(":")
    load_state()
    if not NTFY_URL:
        log("WARNING: NTFY_URL is empty - alerts will be logged, not sent")
    log("watchdog on %s, stale after %ds, expecting: %s"
        % (LISTEN, STALE_AFTER, ", ".join(EXPECTED) or "(anything that reports)"))
    threading.Thread(target=checker, daemon=True).start()
    ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler).serve_forever()
