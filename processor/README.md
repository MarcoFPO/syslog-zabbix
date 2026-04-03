# syslog-processor — Python FastAPI Service

Empfängt Syslog-Events von Vector per HTTP POST, löst den Absender zu einem
Zabbix-Host auf und leitet den Event per `zabbix_sender` weiter.

**Deployment-Pfad:** `/opt/syslog-zabbix/processor/`
**Port:** `127.0.0.1:8514` (loopback only)
**Service:** `syslog-processor.service`

---

## Endpoints

### GET /health

```json
{"status": "ok"}
```

### POST /syslog

Empfängt ein oder mehrere Syslog-Events von Vector.

**Request Body** (JSON-Array, wie Vector sendet):
```json
[{
  "source_ip": "10.1.1.254",
  "hostname": "opnsense",
  "severity": "err",
  "severity_code": 3,
  "facility": "kern",
  "message": "filterlog: TCP:443 blocked from 1.2.3.4",
  "timestamp": "2026-04-03T10:15:30+00:00"
}]
```

Einzelnes Objekt (ohne Array) wird ebenfalls akzeptiert.

**Response:**
```json
{"status": "accepted", "host": "WI-FW01"}
{"status": "unresolved", "detail": "no zabbix host found"}
{"status": "send_failed", "host": "WI-FW01"}
{"status": "error", "detail": "host resolution failed"}
```

---

## Module

### main.py

FastAPI-App mit Lifespan (Startup/Shutdown), `/health` und `/syslog` Endpoints.

Der `/syslog`-Endpoint akzeptiert sowohl JSON-Arrays als auch einzelne Objekte,
da Vector immer Arrays sendet (auch bei `max_events = 1`).

### host_resolver.py

Zweistufiger Lookup:
1. `source_ip` → Zabbix API `host.get(filter={ip: ...})`
2. `hostname` → Zabbix API `host.get(filter={host: ...})`

Ergebnisse werden in SQLite gecacht (TTL konfigurierbar, Standard 60 min).
Positive Treffer werden gecacht. Negative Treffer (None) werden **nicht** gecacht —
neue Geräte werden beim nächsten Event erneut gesucht.

**Auth:** Zabbix 7.x Bearer Token (`Authorization: Bearer <token>`), kein user.login.

### zabbix_sender.py

Async-Wrapper für das `zabbix_sender` CLI-Tool.

Format: `SEVERITY|MESSAGE` (z.B. `WARN|sshd: authentication failure`)

Severity-Mapping:
```
0 (emerg)   → EMERG
1 (alert)   → ALERT
2 (crit)    → CRIT
3 (err)     → ERR
4 (warning) → WARN
```

---

## Konfiguration

`config.yaml` (auf VM 103 unter `/opt/syslog-zabbix/processor/config.yaml`):

```yaml
zabbix:
  api_url: "http://10.1.1.103/zabbix/api_jsonrpc.php"
  api_token: "<bearer-token>"
  sender_host: "127.0.0.1"
  sender_port: 10051

cache:
  db_path: "/opt/syslog-zabbix/db/host_cache.db"
  ttl_minutes: 60

processor:
  listen_host: "127.0.0.1"
  listen_port: 8514

logging:
  unresolved_log: "/opt/syslog-zabbix/logs/unresolved.log"
```

---

## Installation / Deployment

```bash
# Abhängigkeiten installieren (im venv auf VM 103)
/opt/syslog-zabbix/venv/bin/pip install -r requirements.txt

# Service starten
systemctl restart syslog-processor

# Status prüfen
systemctl status syslog-processor
journalctl -u syslog-processor -f
```

Vollständiges Deployment via `deploy.sh` im Projekt-Root.

---

## Debugging

**Nicht aufgelöste Hosts anzeigen:**
```bash
cat /opt/syslog-zabbix/logs/unresolved.log
```

Format:
```
2026-04-03T12:00:00+00:00 | no_match | ip=192.168.1.50 host=unknown sev=warning(4) msg=...
2026-04-03T12:01:00+00:00 | resolver_error | ip=10.1.1.x ...
```

**Direkttest:**
```bash
curl -s -X POST http://127.0.0.1:8514/syslog \
  -H 'Content-Type: application/json' \
  -d '[{
    "source_ip": "10.1.1.103",
    "hostname": "zabbix",
    "severity": "warning",
    "severity_code": 4,
    "facility": "daemon",
    "message": "Testmeldung",
    "timestamp": "2026-04-03T12:00:00Z"
  }]'
```

**Cache leeren (nach neuen Zabbix-Hosts):**
```bash
# Cache-DB löschen — wird beim nächsten Event neu aufgebaut
rm /opt/syslog-zabbix/db/host_cache.db
systemctl restart syslog-processor
```
