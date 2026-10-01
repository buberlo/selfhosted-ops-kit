"""notes-api: a deliberately small stateful demo service.

It exists only to give the Helm chart something realistic to operate:
a stateless HTTP tier in front of PostgreSQL, with separate liveness and
readiness semantics and an explicit, lock-protected schema migration step.

Endpoints
  GET  /healthz  liveness  - process is up (never touches the database)
  GET  /readyz   readiness - database reachable and schema migrated
  GET  /version  app version and applied schema version
  GET  /notes    list notes (newest first, max 100)
  POST /notes    create a note, body = plain text (max 1000 chars)

Usage
  python app.py serve     run the HTTP server (default)
  python app.py migrate   apply pending migrations and exit
"""

import json
import logging
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

APP_VERSION = os.environ.get("APP_VERSION", "dev")
PORT = int(os.environ.get("PORT", "8080"))

# Expand-only migrations: every migration must keep the previous app version
# working, otherwise `helm rollback` of the app tier is not safe.
# See docs/runbooks/upgrade.md ("Schema changes and rollback safety").
MIGRATIONS = [
    (1, "CREATE TABLE IF NOT EXISTS notes ("
        " id BIGSERIAL PRIMARY KEY,"
        " body TEXT NOT NULL,"
        " created_at TIMESTAMPTZ NOT NULL DEFAULT now())"),
    (2, "ALTER TABLE notes ADD COLUMN IF NOT EXISTS source TEXT NULL"),
]
MIGRATION_LOCK_ID = 4242  # pg_advisory_lock key, serialises concurrent pods

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
)
log = logging.getLogger("notes-api")


def dsn() -> str:
    return (
        f"host={os.environ.get('DB_HOST', 'localhost')} "
        f"port={os.environ.get('DB_PORT', '5432')} "
        f"dbname={os.environ.get('DB_NAME', 'notes')} "
        f"user={os.environ.get('DB_USER', 'notes')} "
        f"password={os.environ.get('DB_PASSWORD', '')} "
        f"connect_timeout={os.environ.get('DB_CONNECT_TIMEOUT', '3')} "
        f"application_name=notes-api"
    )


def connect():
    return psycopg.connect(dsn(), autocommit=True)


def migrate() -> int:
    with connect() as conn:
        conn.execute("SELECT pg_advisory_lock(%s)", (MIGRATION_LOCK_ID,))
        try:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS schema_version ("
                " version INT PRIMARY KEY,"
                " applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"
            )
            applied = {r[0] for r in conn.execute("SELECT version FROM schema_version")}
            for version, sql in MIGRATIONS:
                if version in applied:
                    continue
                log.info("applying migration %s", version)
                with conn.transaction():
                    conn.execute(sql)
                    conn.execute("INSERT INTO schema_version (version) VALUES (%s)", (version,))
            current = conn.execute("SELECT max(version) FROM schema_version").fetchone()[0]
            log.info("schema at version %s", current)
            return current
        finally:
            conn.execute("SELECT pg_advisory_unlock(%s)", (MIGRATION_LOCK_ID,))


class Handler(BaseHTTPRequestHandler):
    server_version = "notes-api"

    def log_message(self, fmt, *args):  # route access log through logging
        log.debug("%s %s", self.address_string(), fmt % args)

    def _send(self, code: int, payload) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            return self._send(200, {"status": "ok"})
        try:
            with connect() as conn:
                if self.path == "/readyz":
                    row = conn.execute("SELECT max(version) FROM schema_version").fetchone()
                    if not row or row[0] is None:
                        return self._send(503, {"status": "schema not migrated"})
                    return self._send(200, {"status": "ready", "schema": row[0]})
                if self.path == "/version":
                    row = conn.execute("SELECT max(version) FROM schema_version").fetchone()
                    return self._send(200, {"version": APP_VERSION, "schema": row[0]})
                if self.path == "/notes":
                    rows = conn.execute(
                        "SELECT id, body, created_at FROM notes ORDER BY id DESC LIMIT 100"
                    ).fetchall()
                    return self._send(200, [
                        {"id": r[0], "body": r[1], "created_at": r[2].isoformat()} for r in rows
                    ])
        except psycopg.Error as exc:
            log.warning("database error on %s: %s", self.path, exc.__class__.__name__)
            return self._send(503, {"status": "database unavailable"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path != "/notes":
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 1000:
            return self._send(400, {"error": "body must be 1..1000 bytes"})
        text = self.rfile.read(length).decode("utf-8", errors="replace").strip()
        try:
            with connect() as conn:
                row = conn.execute(
                    "INSERT INTO notes (body) VALUES (%s) RETURNING id", (text,)
                ).fetchone()
        except psycopg.Error as exc:
            log.warning("database error on insert: %s", exc.__class__.__name__)
            return self._send(503, {"status": "database unavailable"})
        return self._send(201, {"id": row[0]})


def serve() -> None:
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)

    def shutdown(signum, _frame):
        # Kubernetes sends SIGTERM; stop accepting and let in-flight requests finish.
        log.info("received signal %s, shutting down", signum)
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    log.info("notes-api %s listening on :%s", APP_VERSION, PORT)
    httpd.serve_forever()
    httpd.server_close()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "migrate":
        migrate()
    elif cmd == "serve":
        serve()
    else:
        sys.exit(f"unknown command: {cmd}")
