# syslog-zabbix

Zentraler Syslog-Empfänger für alle Zabbix-überwachten Geräte.
Syslog-Ereignisse ab **WARNING** werden als zusätzliche Alarme direkt in Zabbix eingespeist.

---

## Übersicht

```
Alle Geräte (LXC, Proxmox, OPNsense, MikroTik, Windows, IoT)
         │
         ▼  UDP/514  TCP/514
  ┌──────────────────────┐
  │      Vector          │  Syslog-Receiver (RFC 3164 + 5424)
  │  Severity-Filter ≤4  │  VRL-Normalisierung
  │  RAM-Buffer 25.000   │  → JSON per HTTP POST
  └──────────┬───────────┘
             │ http://127.0.0.1:8514/syslog
             ▼
  ┌──────────────────────┐
  │   Python-Processor   │  FastAPI · systemd-Service
  │   Host-Resolver      │  IP → Zabbix API → Host
  │   SQLite-Cache       │  TTL 60 min
  └──────────┬───────────┘
             │ zabbix_sender
             ▼
  ┌──────────────────────┐
  │   Zabbix (VM 103)    │  Template T_Syslog
  │   Trapper-Item       │  syslog.event
  │   5 Trigger          │  EMERG→Disaster bis WARN→Warning
  └──────────────────────┘
```

## Stack

| Komponente | Technologie | Version |
|---|---|---|
| Syslog-Receiver | [Vector](https://vector.dev) | 0.54.0 |
| Prozessor | Python 3.12 + FastAPI | — |
| Host-Cache | aiosqlite (SQLite) | — |
| Zabbix-Sender | zabbix_sender CLI | 7.4.8 |
| Service | systemd | — |

## Deployment-Ziel

| Parameter | Wert |
|---|---|
| Host | Zabbix VM 103 |
| IP | `10.1.1.103` |
| Basis-Pfad | `/opt/syslog-zabbix/` |
| Vector-Config | `/etc/vector/syslog-zabbix.toml` |
| Syslog-Port | UDP/514, TCP/514 |
| Processor-Port | `127.0.0.1:8514` (loopback only) |

## Projektstruktur

```
syslog-zabbix/
├── README.md
├── SPEC.md                          # Vollständige Spezifikation
├── deploy.sh                        # Deployment-Script (SSH zu VM 103)
├── setup_vm103.sh                   # Einmalige VM-Einrichtung
├── processor/
│   ├── main.py                      # FastAPI-App, /syslog + /health
│   ├── host_resolver.py             # Zabbix-API Lookup + SQLite-Cache
│   ├── zabbix_sender.py             # Async-Wrapper für zabbix_sender CLI
│   ├── config.yaml                  # Konfiguration (API-URL, Token, Pfade)
│   └── requirements.txt
├── vector/
│   ├── README.md                    # Vector-Installation und -Konfiguration
│   └── syslog-zabbix.toml          # Vector-Config (Sources, Transforms, Sink)
├── zabbix/
│   ├── README.md                    # Template-Import und -Konfiguration
│   └── T_Syslog.yaml               # Zabbix-Template (Trapper-Item + Trigger)
└── systemd/
    └── syslog-processor.service     # systemd-Unit für den Python-Processor
```

## Schnellstart

### Voraussetzungen

- VM 103 erreichbar via SSH (`root@10.1.1.103`)
- Python 3.12 + venv installiert (`python3.12-venv`)
- Vector installiert (Setup via `setup_vm103.sh`)
- Zabbix 7.x auf VM 103

### Einmalige Einrichtung

```bash
# Auf VM 103 einrichten (venv, User, Verzeichnisse, Vector-Install)
bash setup_vm103.sh
```

### Deployment

```bash
# Von Proxmox-Host oder Development-Machine
bash deploy.sh
```

Das Script:
1. Prüft SSH-Erreichbarkeit
2. Kopiert `processor/` via rsync
3. Kopiert systemd-Unit und Vector-Config
4. Führt `pip install` im venv aus
5. Aktiviert und startet beide Services
6. Prüft Status und Health-Endpoint

### Status prüfen

```bash
ssh root@10.1.1.103 systemctl status vector syslog-processor
ssh root@10.1.1.103 journalctl -u syslog-processor -f
```

## Konfiguration

`processor/config.yaml` auf VM 103 unter `/opt/syslog-zabbix/processor/config.yaml`:

```yaml
zabbix:
  api_url: "http://10.1.1.103/zabbix/api_jsonrpc.php"
  api_token: "<zabbix-api-token>"   # Bearer-Token (kein user.login)
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

## Severity-Mapping

| Syslog | Code | Zabbix-Trigger |
|--------|:----:|----------------|
| EMERG  | 0    | Disaster        |
| ALERT  | 1    | High            |
| CRIT   | 2    | High            |
| ERR    | 3    | Average         |
| WARN   | 4    | Warning         |
| NOTICE | 5    | — (gefiltert)   |
| INFO   | 6    | — (gefiltert)   |
| DEBUG  | 7    | — (gefiltert)   |

## Syslog-Forwarding einrichten

### Linux (rsyslog)

```
# /etc/rsyslog.d/50-syslog-zabbix.conf
*.warning @10.1.1.103:514
```

### OPNsense

System → Settings → Logging → Remote: `10.1.1.103:514 UDP`

### MikroTik

```
/system logging action add name=syslog-zabbix target=remote remote=10.1.1.103 remote-port=514
/system logging add topics=warning,error,critical action=syslog-zabbix
```

## Debugging

```bash
# Unaufgelöste Quellen anzeigen
ssh root@10.1.1.103 cat /opt/syslog-zabbix/logs/unresolved.log

# Vector-Statistiken
ssh root@10.1.1.103 vector top

# Manuell ein Event senden
ssh root@10.1.1.103 "zabbix_sender -z 127.0.0.1 -s <hostname> -k syslog.event -o 'WARN|Testmeldung'"

# End-to-End-Test per UDP-Syslog
echo '<36>Apr  3 12:00:00 host sshd: Test' | nc -u -w1 10.1.1.103 514
```

## Bekannte Einschränkungen

- Hosts ohne T_Syslog-Template: Events werden von zabbix_sender abgelehnt (unresolved.log)
- Host-Mapping basiert auf Zabbix-Interfaces — IoT-Geräte ohne Zabbix-Interface können nicht aufgelöst werden
- Bei Vector-Updates: `setcap` ggf. erneut setzen (Port-514-Binding)
