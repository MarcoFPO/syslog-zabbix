"""Syslog-Zabbix Processor — FastAPI Service.

Empfaengt Syslog-Events von Vector per HTTP POST,
loest den Absender auf einen Zabbix-Host auf und
leitet den Event per zabbix_sender weiter.
"""

from __future__ import annotations

import logging
import sys
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import AsyncIterator

import yaml
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, ValidationError

from host_resolver import HostResolver
from zabbix_sender import ZabbixSender

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("syslog_processor")

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

CONFIG_PATH = Path("/opt/syslog-zabbix/processor/config.yaml")


def load_config(path: Path | None = None) -> dict:
    p = path or CONFIG_PATH
    if not p.exists():
        logger.warning("Config %s nicht gefunden, nutze Defaults", p)
        return {}
    with open(p) as f:
        return yaml.safe_load(f) or {}


# ---------------------------------------------------------------------------
# Pydantic Models
# ---------------------------------------------------------------------------


class SyslogEvent(BaseModel):
    source_ip: str
    hostname: str
    severity: str
    severity_code: int = Field(ge=0, le=7)
    facility: str
    message: str
    timestamp: datetime


# ---------------------------------------------------------------------------
# App Globals (werden im Lifespan gesetzt)
# ---------------------------------------------------------------------------

resolver: HostResolver | None = None
sender: ZabbixSender | None = None
unresolved_log: Path = Path("/opt/syslog-zabbix/logs/unresolved.log")


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    global resolver, sender, unresolved_log

    cfg = load_config()

    zabbix_cfg = cfg.get("zabbix", {})
    cache_cfg = cfg.get("cache", {})
    log_cfg = cfg.get("logging", {})

    unresolved_log = Path(log_cfg.get("unresolved_log", "/opt/syslog-zabbix/logs/unresolved.log"))
    unresolved_log.parent.mkdir(parents=True, exist_ok=True)

    resolver = HostResolver(
        api_url=zabbix_cfg.get("api_url", "http://10.1.1.103/zabbix/api_jsonrpc.php"),
        api_token=zabbix_cfg.get("api_token", ""),
        db_path=cache_cfg.get("db_path", "/opt/syslog-zabbix/db/host_cache.db"),
        ttl_minutes=cache_cfg.get("ttl_minutes", 60),
    )
    await resolver.startup()

    sender = ZabbixSender(
        server=zabbix_cfg.get("sender_host", "127.0.0.1"),
        port=zabbix_cfg.get("sender_port", 10051),
    )

    logger.info("Syslog-Processor gestartet")
    yield

    await resolver.shutdown()
    logger.info("Syslog-Processor gestoppt")


# ---------------------------------------------------------------------------
# FastAPI App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Syslog-Zabbix Processor",
    version="1.0.0",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


async def _process_event(event: SyslogEvent) -> dict:
    """Verarbeitet ein einzelnes Syslog-Event."""
    assert resolver is not None
    assert sender is not None

    try:
        zabbix_host = await resolver.resolve(event.source_ip, event.hostname)
    except Exception:
        logger.exception("Host-Aufloesung fehlgeschlagen fuer %s / %s", event.source_ip, event.hostname)
        _log_unresolved(event, reason="resolver_error")
        return {"status": "error", "detail": "host resolution failed"}

    if zabbix_host is None:
        logger.warning(
            "Kein Zabbix-Host fuer ip=%s hostname=%s",
            event.source_ip,
            event.hostname,
        )
        _log_unresolved(event, reason="no_match")
        return {"status": "unresolved", "detail": "no zabbix host found"}

    ok = await sender.send(zabbix_host, event.severity_code, event.message)
    if not ok:
        logger.error("zabbix_sender fehlgeschlagen fuer host=%s", zabbix_host)
        return {"status": "send_failed", "host": zabbix_host}

    return {"status": "accepted", "host": zabbix_host}


@app.post("/syslog", status_code=202)
async def receive_syslog(request: Request) -> dict:
    """Empfaengt Syslog-Events von Vector (JSON-Array oder einzelnes Objekt)."""
    body = await request.json()

    # Vector sendet immer ein JSON-Array auch bei max_events=1
    try:
        if isinstance(body, list):
            events = [SyslogEvent(**e) for e in body]
        else:
            events = [SyslogEvent(**body)]
    except (ValidationError, TypeError) as exc:
        return JSONResponse(status_code=422, content={"detail": str(exc)})

    results = []
    for event in events:
        result = await _process_event(event)
        results.append(result)

    if len(results) == 1:
        return results[0]
    return {"status": "accepted", "processed": len(results)}


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unbehandelte Exception: %s", exc)
    return JSONResponse(
        status_code=500,
        content={"detail": "internal server error"},
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _log_unresolved(event: SyslogEvent, reason: str) -> None:
    """Schreibt nicht aufgeloeste Events in das Unresolved-Log."""
    line = (
        f"{event.timestamp.isoformat()} | {reason} | "
        f"ip={event.source_ip} host={event.hostname} "
        f"sev={event.severity}({event.severity_code}) "
        f"msg={event.message}\n"
    )
    try:
        with open(unresolved_log, "a") as f:
            f.write(line)
    except OSError:
        logger.exception("Konnte unresolved.log nicht schreiben")


# ---------------------------------------------------------------------------
# Standalone Start
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    cfg = load_config()
    proc_cfg = cfg.get("processor", {})
    uvicorn.run(
        "main:app",
        host=proc_cfg.get("listen_host", "127.0.0.1"),
        port=proc_cfg.get("listen_port", 8514),
        log_level="info",
    )
