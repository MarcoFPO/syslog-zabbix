# SPEC: syslog-zabbix

## Status

**Deployed — produktiv auf VM 103 (10.1.1.103) seit 2026-04-03**

| Komponente | Status |
|---|---|
| Vector 0.54.0 | aktiv, Port 514 UDP/TCP |
| syslog-processor | aktiv, Port 8514 loopback |
| T_Syslog Template | importiert (ID 11032), auf 38 Hosts angewendet |

---

## Übersicht

Zentraler Syslog-Empfänger für alle Zabbix-überwachten Geräte.
Syslog-Meldungen ab WARNING-Severity werden als eigenständige Alarme in Zabbix eingespeist.
Syslog dient als **zweite, ergänzende Alarmquelle** neben dem nativen Zabbix-Monitoring.

---

## Ziele

- Syslog-Meldungen (UDP/TCP Port 514) von allen Zabbix-überwachten Geräten empfangen
- WARNING und kritischere Ereignisse (Severity ≤ 4) filtern
- Gefilterte Events dem passenden Zabbix-Host zuordnen (Host-Mapping)
- Events via `zabbix_sender` als Trapper-Items in Zabbix einspeisen
- Deduplizierung und Bewertung von Meldungen übernimmt Zabbix selbst
- Kein eigenes Web-UI — alle Alarmdarstellung läuft über Zabbix

---

## Nicht-Ziele

- Keine Langzeitspeicherung von Logs (kein ELK, kein Loki)
- Keine eigene Alarmlogik — Zabbix übernimmt Trigger, Eskalation, Acknowledge
- Keine Visualisierung außerhalb von Zabbix
- Kein Docker

---

## Architektur

```
Alle Geräte (LXC, Proxmox, OPNsense, MikroTik, Windows, IoT)
         │
         ▼  UDP/514  TCP/514
  ┌──────────────────────┐
  │      Vector          │  Syslog-Receiver
  │                      │  • RFC 3164 + RFC 5424
  │  source: syslog      │  • Severity-Filter (≤ WARNING)
  │  transform: VRL      │  • RAM-Buffer (25.000 Events)
  │  sink: http          │  • Strukturiertes JSON → HTTP POST
  └──────────┬───────────┘
             │ HTTP POST (JSON-Array)
             ▼
  ┌──────────────────────┐
  │   Python-Prozessor   │  systemd-Service
  │   (FastAPI)          │
  │                      │  • Host-Resolver:
  │  /syslog  (POST)     │    1. Quell-IP  → Zabbix API
  │                      │    2. Hostname  → Zabbix API (Fallback)
  │  SQLite Cache        │    3. TTL: 60 min
  │  (Host-Mapping)      │
  └──────────┬───────────┘
             │ zabbix_sender
             ▼
  ┌──────────────────────┐
  │   Zabbix (VM 103)    │
  │                      │
  │  Template T_Syslog   │  Trapper-Item + Trigger pro Host
  │  → Problem-Event     │  Severity-Mapping → Zabbix-Severity
  └──────────────────────┘
```

---

## Quellen (Gerätetypen)

| Typ | Protokoll | Beispiele |
|-----|-----------|-----------|
| Linux LXC / VMs | UDP/TCP Syslog, journald | Alle LXCs auf Proxmox |
| Proxmox-Host | UDP Syslog | VM 103, Hypervisor |
| Netzwerkgeräte | UDP Syslog (RFC 3164) | OPNsense, MikroTik |
| Windows-Hosts | UDP/TCP Syslog (NXLog o.ä.) | Windows-Systeme |
| IoT / Switches | UDP Syslog | Shelly, Managed Switches |

Alle Quellen = alle Geräte, die in Zabbix überwacht werden.

---

## Severity-Filter & Mapping

Nur Meldungen mit Severity **≤ 4 (WARNING)** werden weitergeleitet.

| Syslog-Level | Wert | Zabbix-Severity |
|---|:---:|---|
| EMERGENCY | 0 | Disaster |
| ALERT | 1 | High |
| CRITICAL | 2 | High |
| ERROR | 3 | Average |
| WARNING | 4 | Warning |
| NOTICE | 5 | — (gefiltert) |
| INFO | 6 | — (gefiltert) |
| DEBUG | 7 | — (gefiltert) |

---

## Host-Mapping

Zuordnung Syslog-Absender → Zabbix-Host (zweistufig):

```
1. Quell-IP des Syslog-Pakets
   └─► Zabbix API: host.get(filter={ip: <quell-ip>})
       ├── Treffer → Host gefunden ✅
       └── kein Treffer → Schritt 2

2. Hostname aus Syslog-Header (HOSTNAME-Feld)
   └─► Zabbix API: host.get(filter={host: <hostname>})
       ├── Treffer → Host gefunden ✅
       └── kein Treffer → unresolved.log 📝
```

**Cache:** SQLite, TTL 60 Minuten — Zabbix API wird nicht pro Event abgefragt.

**Unresolved:** Nicht zuordenbare Quellen werden in `/opt/syslog-zabbix/logs/unresolved.log`
geloggt (IP + Hostname) zur manuellen Nachpflege.

---

## Buffer-Spezifikation

| Parameter | Wert |
|---|---|
| Typ | RAM (In-Memory) |
| Größe | 25.000 Events |
| ca. RAM-Bedarf | ~8 MB |
| Verhalten bei Voll | `drop_newest` |
| Zweck | Ausfallpuffer bei Zabbix/Python-Downtime |
| Maximale Abdeckung | ~60 min bei 400 Events/min (Incident) |

Keine Disk-I/O für den Buffer — ausschließlich RAM.

---

## Zabbix-Integration

### Template: T_Syslog

- **Zabbix-ID:** 11032
- **Importiert:** 2026-04-03
- **Auf Hosts angewendet:** 38

```
Item:    syslog.event   (Typ: Zabbix Trapper, Wert-Typ: Log)
History: 30 Tage
Trends:  deaktiviert
```

### Datenformat (zabbix_sender)

```
Host:  <zabbix-hostname>
Key:   syslog.event
Value: WARN|sshd: authentication failure for root from 10.0.0.1
       ^^^^  ─────────────────────────────────────────────────
       Sev.  Original-Syslog-Message
```

### Zabbix API-Zugang

- **URL:** `http://10.1.1.103/zabbix/api_jsonrpc.php`
- **Auth:** Bearer Token (Zabbix 7.x API-Token, kein user.login)
- **Credentials:** Vaultwarden → Org "Bots" → "Zabbix API syslog-zabbix"
- **Berechtigungen:** Read-only (nur `host.get`) via Usergroup "Syslog-Service" (ID 15)

---

## Stack

| Komponente | Technologie | Version |
|---|---|---|
| Syslog-Receiver | Vector | 0.54.0 |
| Prozessor | Python 3.12 + FastAPI | — |
| Host-Cache | SQLite (aiosqlite) | — |
| Zabbix-Sender | zabbix_sender CLI | 7.4.8 |
| Service-Manager | systemd | — |
| Deployment | VM 103, `/opt/syslog-zabbix/` | — |

---

## Deployment-Ziel

| Parameter | Wert |
|---|---|
| Host | Zabbix VM 103 (KVM, kein LXC) |
| IP | 10.1.1.103 |
| Pfad | `/opt/syslog-zabbix/` |
| Vector-Config | `/etc/vector/syslog-zabbix.toml` |
| Python-Service | `/opt/syslog-zabbix/processor/` |
| Systemd (Vector) | `vector.service` + Override `/etc/systemd/system/vector.service.d/override.conf` |
| Systemd (Python) | `syslog-processor.service` |
| Syslog-Port | UDP/514, TCP/514 |
| Python HTTP | `127.0.0.1:8514` (nur loopback) |

---

## Verzeichnisstruktur

```
/opt/syslog-zabbix/
├── processor/
│   ├── main.py              # FastAPI App + Endpunkt /syslog
│   ├── host_resolver.py     # Zabbix-API Lookup + SQLite Cache
│   ├── zabbix_sender.py     # Wrapper für zabbix_sender CLI
│   ├── config.yaml          # Konfiguration
│   └── requirements.txt
├── db/
│   └── host_cache.db        # SQLite Host-Mapping Cache
├── logs/
│   └── unresolved.log       # Nicht zuordenbare Syslog-Quellen
└── venv/                    # Python Virtual Environment

/etc/vector/
├── syslog-zabbix.toml       # Vector-Konfiguration
└── vector.yaml.disabled     # Standard-Config deaktiviert

/etc/systemd/system/vector.service.d/
└── override.conf            # ExecStart mit explizitem Config-Pfad
```

---

## HTTP-Payload (Vector → Python)

Vector sendet Events immer als **JSON-Array** (auch bei `max_events = 1`):

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

Der Python-Endpoint `/syslog` akzeptiert sowohl Arrays als auch einzelne Objekte.

---

## Konfigurationsdatei

```yaml
# /opt/syslog-zabbix/processor/config.yaml

zabbix:
  api_url: "http://10.1.1.103/zabbix/api_jsonrpc.php"
  api_token: "<bearer-token>"   # Zabbix 7.x API-Token
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

## Deployment-Ablauf

```bash
# 1. Einmalige VM-Einrichtung (User, venv, Vector-Install)
bash setup_vm103.sh

# 2. Jedes weitere Deployment
bash deploy.sh
```

`deploy.sh` arbeitet vollständig via SSH (kein pct — VM 103 ist KVM, kein LXC).

---

## Bekannte Probleme & Lösungen

| Problem | Ursache | Lösung |
|---|---|---|
| Vector lädt Config doppelt | `VECTOR_CONFIG` Env + `--config-toml` Flag | Nur systemd-Override mit explizitem Pfad |
| `strip_prefix()` nicht gefunden | VRL 0.54 kennt diese Funktion nicht | `slice!(inner, 1)` für IPv6 |
| `to_timestamp()` nicht gefunden | VRL 0.54 kennt diese Funktion nicht | `format_timestamp!(.timestamp, ...)` direkt |
| HTTP 422 von Processor | Vector sendet JSON-Array, nicht Objekt | Endpoint akzeptiert beide Formate |
| Bearer-Auth fehlgeschlagen | Alter Code nutzte `user.login` Session | Zabbix 7.x: API-Token in `Authorization: Bearer` Header |
| zabbix_sender failed: 1 | Template nicht auf Host angewendet | T_Syslog auf alle Hosts deployen |

---

## Offene Punkte / Nächste Schritte

- [ ] Syslog-Forwarding auf Quellgeräten konfigurieren:
  - [ ] OPNsense (WI-FW01): System → Logging → Remote → `10.1.1.103:514 UDP`
  - [ ] MikroTik (C-R01, HU-R01): `/system logging action`
  - [ ] LXCs: rsyslog.d-Drop-in `*.warning @10.1.1.103:514`
  - [ ] Proxmox-Host: rsyslog forwarding
- [ ] T_Syslog auf weitere Hosts nachpflegen (Hosts ohne Interface-IP)
- [ ] `unresolved.log` nach ersten echten Events prüfen
- [ ] Port 514 UDP/TCP in OPNsense-Firewall für alle VLANs freigeben
- [ ] Vector-Update-Prozedur dokumentieren (setcap nach Update)

---

## Entscheidungsprotokoll

| Entscheidung | Gewählt | Begründung |
|---|---|---|
| Receiver | Vector | Moderner Stack, RFC 3164/5424 nativ, VRL für Filter |
| Prozessor | Python + FastAPI | Zabbix-API Integration einfach, gering Aufwand |
| Buffer | RAM (25.000 Events) | Kein Disk-I/O, ausreichend für 1h bei Incident |
| Host-Mapping | IP primär, Hostname Fallback | Robusteste Lösung für gemischte Infrastruktur |
| UI | Keine | Alles über Zabbix |
| Deployment | VM 103 (neben Zabbix) | Kurze Wege, zabbix_sender lokal verfügbar |
| Auth | API-Token (Bearer) | Zabbix 7.x Standard, kein Session-Management |
| Deploy-Methode | SSH + rsync | VM 103 ist KVM, kein LXC (kein pct möglich) |
