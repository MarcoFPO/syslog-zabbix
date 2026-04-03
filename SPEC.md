# SPEC: syslog-zabbix

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
             │ HTTP POST (JSON)
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

Wird auf **alle** Zabbix-überwachten Hosts angewendet:

```
Item:    syslog.event   (Typ: Zabbix Trapper, Wert: Text)
Trigger: Severity-abhängig aus dem Item-Wert
```

### Datenformat (zabbix_sender)

```
Host:  <zabbix-hostname>
Key:   syslog.event
Value: CRIT|sshd: authentication failure for root from 1.2.3.4
       ^^^^  ─────────────────────────────────────────────────
       Sev.  Original-Syslog-Message
```

### Zabbix API-Zugang

- **URL:** `http://10.1.1.103/api_jsonrpc.php`
- **Credentials:** Vaultwarden → Org "Bots" → "Zabbix API syslog-zabbix"
- **Berechtigungen:** Read-only (nur `host.get`)

---

## Stack

| Komponente | Technologie | Version |
|---|---|---|
| Syslog-Receiver | Vector | aktuell stable |
| Prozessor | Python 3 + FastAPI | Python ≥ 3.11 |
| Host-Cache | SQLite (aiosqlite) | — |
| Zabbix-Sender | zabbix_sender CLI | — |
| Service-Manager | systemd | — |
| Deployment | VM 103, `/opt/syslog-zabbix/` | — |

---

## Deployment-Ziel

| Parameter | Wert |
|---|---|
| Host | Zabbix VM 103 |
| IP | 10.1.1.103 |
| Pfad | `/opt/syslog-zabbix/` |
| Vector-Config | `/etc/vector/syslog-zabbix.toml` |
| Python-Service | `/opt/syslog-zabbix/processor/` |
| Systemd (Vector) | `vector.service` |
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
└── systemd/
    └── syslog-processor.service

/etc/vector/
└── syslog-zabbix.toml       # Vector-Konfiguration
```

---

## Vector-Konfiguration (Entwurf)

```toml
# /etc/vector/syslog-zabbix.toml

[sources.syslog_udp]
type = "syslog"
mode = "udp"
address = "0.0.0.0:514"

[sources.syslog_tcp]
type = "syslog"
mode = "tcp"
address = "0.0.0.0:514"

[transforms.severity_filter]
type = "filter"
inputs = ["syslog_udp", "syslog_tcp"]
condition = '.severity_code <= 4'

[sinks.python_processor]
type = "http"
inputs = ["severity_filter"]
uri = "http://127.0.0.1:8514/syslog"
method = "post"
encoding.codec = "json"

  [sinks.python_processor.buffer]
  type = "memory"
  max_events = 25000
  when_full = "drop_newest"
```

---

## Python-Prozessor API

### POST /syslog

**Request Body (von Vector):**
```json
{
  "host": "firewall-01",
  "hostname": "OPNsense",
  "source_ip": "10.1.1.254",
  "severity": "err",
  "severity_code": 3,
  "facility": "kern",
  "message": "filterlog: TCP:443 blocked from 1.2.3.4",
  "timestamp": "2026-04-03T10:15:30Z"
}
```

**Verarbeitung:**
1. Host-Lookup: IP → Zabbix API (Cache, TTL 60 min)
2. Fallback: Hostname → Zabbix API
3. Kein Treffer → `unresolved.log`
4. Treffer → `zabbix_sender -z 127.0.0.1 -s <host> -k syslog.event -o "<SEV>|<message>"`

---

## Konfigurationsdatei

```yaml
# /opt/syslog-zabbix/processor/config.yaml

zabbix:
  api_url: "http://10.1.1.103/api_jsonrpc.php"
  api_user: "syslog-zabbix"
  api_password: ""          # aus Vaultwarden laden
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

## Offene Punkte / Nächste Schritte

- [ ] Zabbix-Template `T_Syslog` definieren (Item + Trigger-Regeln)
- [ ] Zabbix API-User anlegen (Read-only, nur `host.get`)
- [ ] Credentials in Vaultwarden ablegen
- [ ] Vector installieren auf VM 103
- [ ] Python-Umgebung einrichten (venv, requirements)
- [ ] Port 514 in Firewall/OPNsense öffnen (UDP+TCP → VM 103)
- [ ] Alle Zabbix-Hosts mit Template `T_Syslog` verknüpfen
- [ ] Syslog-Forwarding auf Quellgeräten konfigurieren

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
