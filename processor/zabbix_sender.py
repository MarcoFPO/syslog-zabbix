"""Async Wrapper fuer das zabbix_sender CLI Tool."""

from __future__ import annotations

import asyncio
import logging
import shlex

logger = logging.getLogger("syslog_processor.sender")

SEVERITY_MAP: dict[int, str] = {
    0: "EMERG",
    1: "ALERT",
    2: "CRIT",
    3: "ERR",
    4: "WARN",
}


class ZabbixSender:
    """Sendet Syslog-Events per zabbix_sender CLI an Zabbix."""

    def __init__(self, server: str = "127.0.0.1", port: int = 10051) -> None:
        self._server = server
        self._port = port

    async def send(
        self,
        zabbix_host: str,
        severity_code: int,
        message: str,
    ) -> bool:
        """Sendet einen Event. Gibt True bei Erfolg zurueck."""
        sev_label = SEVERITY_MAP.get(severity_code, f"SEV{severity_code}")
        value = f"{sev_label}|{message}"

        cmd = [
            "zabbix_sender",
            "-z", self._server,
            "-p", str(self._port),
            "-s", zabbix_host,
            "-k", "syslog.event",
            "-o", value,
        ]

        logger.debug("zabbix_sender: %s", shlex.join(cmd))

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
        except FileNotFoundError:
            logger.error("zabbix_sender Binary nicht gefunden — ist zabbix-sender installiert?")
            return False
        except Exception:
            logger.exception("zabbix_sender Aufruf fehlgeschlagen")
            return False

        if proc.returncode != 0:
            logger.error(
                "zabbix_sender Fehler (rc=%d): stdout=%s stderr=%s",
                proc.returncode,
                stdout.decode(errors="replace").strip(),
                stderr.decode(errors="replace").strip(),
            )
            return False

        logger.info(
            "Event gesendet: host=%s sev=%s msg=%s",
            zabbix_host,
            sev_label,
            message[:120],
        )
        return True
