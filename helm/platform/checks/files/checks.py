#!/usr/bin/env python3
"""kien/stack checks: one short run every 15 minutes (CronJob), standard library only.

Reads the Kubernetes API with its own read-only ServiceAccount and looks for what loses data or takes
the site down without anyone noticing:
  - Postgres (CloudNativePG): cluster not healthy, WAL archiving failing, last base backup too old or failed.
    A healthy cluster whose last base backup failed, is missing or too old gets a new one (at most once an
    hour): the first backup after switching backups on races the Postgres restart, a nightly one can hit an
    S3 outage, and CloudNativePG does not retry either;
  - free space on the disk that holds the volumes (hostPath mounted read-only at DISK_PATH);
  - TLS certificates (cert-manager) expiring in less than CERT_MIN_DAYS days, or not ready.
Then:
  - all OK: GET HEARTBEAT_URL. The external service (healthchecks.io, Uptime Kuma push, Better Stack...)
    alerts when the pings stop: a problem below, or the whole node is down (which nothing inside can report);
  - a problem: POST WEBHOOK_URL ({"text", "content"}: Slack, Mattermost, Google Chat, Discord...), when the
    list of problems changes and again every REPEAT_HOURS, then once more when it is resolved.
Warnings (backups off, a Postgres without WAL archiving) are only printed. Exit 0 unless the script fails.
"""
import datetime as dt
import hashlib
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"
STATE = "checks-state"  # ConfigMap in our namespace: last problems sent, and when


def env(key, default=""):
    return os.environ.get(key, default).strip()


NOW = dt.datetime.now(dt.timezone.utc)
CLUSTER = env("CLUSTER_NAME", "kien/stack")
BACKUP_ON = env("BACKUP_ENABLED") == "true"
BACKUP_MAX_AGE_H = float(env("BACKUP_MAX_AGE_HOURS", "26"))
DISK_PATH = env("DISK_PATH", "/host/volumes")
DISK_MIN_FREE = float(env("DISK_MIN_FREE_PERCENT", "15"))
CERT_MIN_DAYS = float(env("CERT_MIN_DAYS", "14"))
REPEAT_H = float(env("REPEAT_HOURS", "6"))
RETRY_MIN = float(env("BACKUP_RETRY_MINUTES", "60"))
PLUGIN = "barman-cloud.cloudnative-pg.io"
CREATED_BY = "kien-stack.io/created-by"

with open(f"{SA}/token") as f:
    TOKEN = f.read().strip()
with open(f"{SA}/namespace") as f:
    NAMESPACE = f.read().strip()
TLS = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def api(path, method="GET", body=None):
    """Kubernetes API call; None on 404 (missing CRD or object)."""
    data = json.dumps(body).encode() if body is not None else None
    ctype = "application/merge-patch+json" if method == "PATCH" else "application/json"
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, context=TLS, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def items(path):
    return (api(path) or {}).get("items") or []


def when(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def ago(t):
    h = (NOW - t).total_seconds() / 3600
    return f"{h:.0f}h ago" if h < 48 else f"{h / 24:.0f} days ago"


def condition(obj, ctype):
    for c in (obj.get("status") or {}).get("conditions") or []:
        if c.get("type") == ctype:
            return c
    return None


problems, warnings = [], []

# ------------------------------------------------------------------ Postgres
clusters = items("/apis/postgresql.cnpg.io/v1/clusters")
backups = items("/apis/postgresql.cnpg.io/v1/backups")
if not BACKUP_ON:
    warnings.append("BACKUPS OFF: set global.backup.s3 in cluster.yaml (docs/BACKUP.md)")
for c in clusters:
    ns, name = c["metadata"]["namespace"], c["metadata"]["name"]
    pg = f"Postgres {ns}/{name}"
    spec, status = c.get("spec") or {}, c.get("status") or {}
    phase = status.get("phase", "")
    if phase and phase != "Cluster in healthy state":
        problems.append(f"{pg}: {phase}")
    archiver = any(p.get("isWALArchiver") for p in spec.get("plugins") or []) or \
        bool((spec.get("backup") or {}).get("barmanObjectStore"))
    if not archiver:
        if BACKUP_ON:
            warnings.append(f"{pg}: no WAL archiving, no point-in-time recovery")
        continue
    arch = condition(c, "ContinuousArchiving")
    if arch and arch.get("status") == "False":
        problems.append(f"{pg}: WAL archiving failing ({arch.get('message') or arch.get('reason')}). "
                        "WAL piles up on the disk until it works again")
    mine = [b for b in backups if b["metadata"]["namespace"] == ns
            and ((b.get("spec") or {}).get("cluster") or {}).get("name") == name]
    mine.sort(key=lambda b: b["metadata"]["creationTimestamp"])
    phase_of = lambda b: (b.get("status") or {}).get("phase", "")
    done = [when((b.get("status") or {}).get("stoppedAt")) for b in mine if phase_of(b) == "completed"]
    done = [t for t in done if t]
    last = mine[-1] if mine else None
    running = any(phase_of(b) in ("", "pending", "started", "running", "finalizing") for b in mine)
    retries = [when(b["metadata"]["creationTimestamp"]) for b in mine
               if (b["metadata"].get("labels") or {}).get(CREATED_BY) == "checks"]
    can_retry = phase == "Cluster in healthy state" and not running and \
        any(p.get("name") == PLUGIN and p.get("isWALArchiver") for p in spec.get("plugins") or []) and \
        not any((NOW - t).total_seconds() < RETRY_MIN * 60 for t in retries)
    created = when(c["metadata"]["creationTimestamp"])
    first = when(mine[0]["metadata"]["creationTimestamp"]) if mine else created
    issue = None
    if last and phase_of(last) == "failed":
        issue = f"last base backup failed ({(last.get('status') or {}).get('error', '?')[:200]})"
    elif done and (NOW - max(done)).total_seconds() > BACKUP_MAX_AGE_H * 3600:
        issue = f"last base backup {ago(max(done))} (limit {BACKUP_MAX_AGE_H:.0f}h)"
    elif not done and not running and (NOW - max(created, first)).total_seconds() > 15 * 60:
        issue = "no completed base backup yet"
    if issue and running:
        warnings.append(f"{pg}: {issue}; a base backup is running")
    elif issue and can_retry:
        api(f"/apis/postgresql.cnpg.io/v1/namespaces/{ns}/backups", "POST", {
            "apiVersion": "postgresql.cnpg.io/v1", "kind": "Backup",
            "metadata": {"generateName": f"{name}-checks-", "labels": {CREATED_BY: "checks"}},
            "spec": {"cluster": {"name": name}, "method": "plugin", "pluginConfiguration": {"name": PLUGIN}}})
        warnings.append(f"{pg}: {issue}; started a new base backup")
    elif issue:
        problems.append(f"{pg}: {issue}")

# ------------------------------------------------------------------ Disk
try:
    st = os.statvfs(DISK_PATH)
    free = 100.0 * st.f_bavail / st.f_blocks if st.f_blocks else 100.0
    gib = st.f_bavail * st.f_frsize / 2**30
    line = f"disk ({DISK_PATH}): {free:.0f}% free, {gib:.1f} GiB"
    print(line)
    if free < DISK_MIN_FREE:
        problems.append(f"{line} (limit {DISK_MIN_FREE:.0f}%)")
except OSError as e:
    warnings.append(f"disk: cannot read {DISK_PATH}: {e}")

# ------------------------------------------------------------------ Certificates
for crt in items("/apis/cert-manager.io/v1/certificates"):
    ns, name = crt["metadata"]["namespace"], crt["metadata"]["name"]
    st = crt.get("status") or {}
    not_after = when(st.get("notAfter"))
    ready = condition(crt, "Ready")
    if not_after and (not_after - NOW).total_seconds() < CERT_MIN_DAYS * 86400:
        problems.append(f"certificate {ns}/{name}: expires {not_after:%Y-%m-%d %H:%M} UTC "
                        f"(renewal not done: {(ready or {}).get('message', '?')[:200]})")
    elif ready and ready.get("status") == "False" and \
            (NOW - when(ready.get("lastTransitionTime") or crt["metadata"]["creationTimestamp"])).total_seconds() > 3600:
        problems.append(f"certificate {ns}/{name}: not ready for over 1h ({ready.get('message', '?')[:200]})")

# ------------------------------------------------------------------ Report
for w in warnings:
    print(f"WARN {w}")
for p in problems:
    print(f"KO   {p}")
print(f"{len(clusters)} Postgres, {len(problems)} problem(s), {len(warnings)} warning(s)")


def http(url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET",
                                 headers={"Content-Type": "application/json", "User-Agent": "kien-stack-checks"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status


def notify(text):
    url = env("WEBHOOK_URL")
    if not url:
        print("no WEBHOOK_URL: problems are only in this log")
        return False
    http(url, {"text": text, "content": text[:1900]})
    return True


state_path = f"/api/v1/namespaces/{NAMESPACE}/configmaps/{STATE}"
state = (api(state_path) or {}).get("data") or {}
fingerprint = hashlib.sha256("\n".join(sorted(problems)).encode()).hexdigest()[:16] if problems else ""
new_state = dict(state)
if problems:
    last_sent = when(state.get("sent"))
    due = state.get("fingerprint") != fingerprint or not last_sent or \
        (NOW - last_sent).total_seconds() >= REPEAT_H * 3600
    if due and notify(f"[{CLUSTER}] {len(problems)} problem(s):\n" + "\n".join(f"- {p}" for p in problems)):
        new_state = {"fingerprint": fingerprint, "sent": NOW.isoformat()}
else:
    if state.get("fingerprint"):
        notify(f"[{CLUSTER}] resolved: all checks OK")
        new_state = {}
    if env("HEARTBEAT_URL"):
        http(env("HEARTBEAT_URL"))
        print("heartbeat sent")
    else:
        print("no HEARTBEAT_URL: nothing outside the cluster knows it is alive")
if new_state != state:
    if api(state_path) is None:
        api(f"/api/v1/namespaces/{NAMESPACE}/configmaps", "POST",
            {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": STATE}, "data": new_state})
    else:
        api(state_path, "PATCH", {"data": {**{k: None for k in state}, **new_state}})
sys.exit(0)
