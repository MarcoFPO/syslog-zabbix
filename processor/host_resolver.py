"""Zabbix Host Resolver mit aiosqlite Cache."""

from __future__ import annotations

import logging
import time
from pathlib import Path

import aiosqlite
import httpx

logger = logging.getLogger("syslog_processor.resolver")

CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS host_cache (
    source_ip  TEXT PRIMARY KEY,
    hostname   TEXT NOT NULL,
    zabbix_host TEXT NOT NULL,
    cached_at  REAL NOT NULL
)
"""


class HostResolver:
    """Loest source_ip / hostname zu einem Zabbix-Hostnamen auf.

    Zweistufig:
      1. source_ip  -> Zabbix host.get (filter: ip)
      2. hostname   -> Zabbix host.get (filter: host)

    Ergebnisse werden in einer SQLite-DB gecacht (TTL konfigurierbar).
    """

    def __init__(
        self,
        api_url: str,
        api_user: str,
        api_password: str,
        db_path: str,
        ttl_minutes: int = 60,
    ) -> None:
        self._api_url = api_url
        self._api_user = api_user
        self._api_password = api_password
        self._db_path = db_path
        self._ttl_seconds = ttl_minutes * 60
        self._auth_token: str | None = None
        self._db: aiosqlite.Connection | None = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def startup(self) -> None:
        Path(self._db_path).parent.mkdir(parents=True, exist_ok=True)
        self._db = await aiosqlite.connect(self._db_path)
        await self._db.execute(CREATE_TABLE)
        await self._db.commit()
        logger.info("Host-Resolver gestartet (Cache: %s)", self._db_path)

    async def shutdown(self) -> None:
        if self._db:
            await self._db.close()
            self._db = None
        self._auth_token = None
        logger.info("Host-Resolver gestoppt")

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def resolve(self, source_ip: str, hostname: str) -> str | None:
        """Gibt den Zabbix-Hostnamen zurueck oder None."""

        # 1. Cache pruefen
        cached = await self._cache_lookup(source_ip)
        if cached is not None:
            return cached

        # 2. Zabbix API: IP-Lookup
        zabbix_host = await self._api_lookup_by_ip(source_ip)

        # 3. Zabbix API: Hostname-Lookup
        if zabbix_host is None:
            zabbix_host = await self._api_lookup_by_name(hostname)

        # 4. Cache schreiben (nur positive Treffer)
        if zabbix_host is not None:
            await self._cache_store(source_ip, hostname, zabbix_host)

        return zabbix_host

    # ------------------------------------------------------------------
    # Cache
    # ------------------------------------------------------------------

    async def _cache_lookup(self, source_ip: str) -> str | None:
        assert self._db is not None
        cutoff = time.time() - self._ttl_seconds
        async with self._db.execute(
            "SELECT zabbix_host FROM host_cache WHERE source_ip = ? AND cached_at > ?",
            (source_ip, cutoff),
        ) as cursor:
            row = await cursor.fetchone()
        return row[0] if row else None

    async def _cache_store(
        self, source_ip: str, hostname: str, zabbix_host: str
    ) -> None:
        assert self._db is not None
        await self._db.execute(
            """
            INSERT INTO host_cache (source_ip, hostname, zabbix_host, cached_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(source_ip) DO UPDATE SET
                hostname = excluded.hostname,
                zabbix_host = excluded.zabbix_host,
                cached_at = excluded.cached_at
            """,
            (source_ip, hostname, zabbix_host, time.time()),
        )
        await self._db.commit()

    # ------------------------------------------------------------------
    # Zabbix JSON-RPC
    # ------------------------------------------------------------------

    async def _ensure_auth(self) -> str:
        """Authentifiziert sich bei der Zabbix API und gibt das Token zurueck."""
        if self._auth_token is not None:
            return self._auth_token

        payload = {
            "jsonrpc": "2.0",
            "method": "user.login",
            "params": {
                "username": self._api_user,
                "password": self._api_password,
            },
            "id": 1,
        }
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(self._api_url, json=payload)
            resp.raise_for_status()

        data = resp.json()
        if "error" in data:
            raise RuntimeError(f"Zabbix login fehlgeschlagen: {data['error']}")

        self._auth_token = data["result"]
        logger.info("Zabbix API authentifiziert")
        return self._auth_token

    async def _host_get(self, filter_params: dict) -> str | None:
        """Fuehrt host.get aus und gibt den ersten Hostnamen zurueck."""
        try:
            auth = await self._ensure_auth()
        except Exception:
            logger.exception("Zabbix API Authentifizierung fehlgeschlagen")
            return None

        payload = {
            "jsonrpc": "2.0",
            "method": "host.get",
            "params": {
                "filter": filter_params,
                "output": ["host"],
                "limit": 1,
            },
            "auth": auth,
            "id": 2,
        }

        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(self._api_url, json=payload)
                resp.raise_for_status()
        except Exception:
            logger.exception("Zabbix API Anfrage fehlgeschlagen")
            self._auth_token = None  # Token koennte abgelaufen sein
            return None

        data = resp.json()
        if "error" in data:
            logger.error("Zabbix API Fehler: %s", data["error"])
            self._auth_token = None
            return None

        hosts = data.get("result", [])
        if hosts:
            return hosts[0]["host"]
        return None

    async def _api_lookup_by_ip(self, ip: str) -> str | None:
        return await self._host_get({"ip": ip})

    async def _api_lookup_by_name(self, hostname: str) -> str | None:
        return await self._host_get({"host": hostname})
