# Vector – Syslog-Receiver für syslog-zabbix

Vector empfängt Syslog-Meldungen (UDP + TCP, Port 514) von allen Zabbix-überwachten
Geräten, filtert auf WARNING und kritischere Events (severity ≤ 4) und leitet sie
als JSON per HTTP POST an den Python-Prozessor (`syslog-processor.service`) weiter.

**Deployment-Ziel:** VM 103, IP `10.1.1.103`
**Config-Pfad:** `/etc/vector/syslog-zabbix.toml`
**Getestete Version:** Vector 0.54.0

---

## Installation (Debian/Ubuntu, ohne Docker)

Vector stellt ein offizielles Shell-Installer-Skript bereit:

```bash
# 1. Installer ausführen (als root auf VM 103)
bash <(curl -fsSL https://setup.vector.dev)

# 2. Vector installieren
apt-get install -y vector

# 3. Version prüfen
vector --version
```

---

## systemd-Override konfigurieren

Die Standard-Unit lädt `/etc/vector/vector.yaml`. Da wir eine eigene Config nutzen,
braucht Vector einen systemd-Override mit explizitem Config-Pfad.

**Wichtig:** Die Standard-Config deaktivieren, damit Vector sie nicht zusätzlich lädt:

```bash
# Standard-Config deaktivieren
mv /etc/vector/vector.yaml /etc/vector/vector.yaml.disabled

# Override anlegen
mkdir -p /etc/systemd/system/vector.service.d
cat > /etc/systemd/system/vector.service.d/override.conf <<'EOF'
[Service]
ExecStartPre=
ExecStart=
ExecStartPre=/usr/bin/vector validate /etc/vector/syslog-zabbix.toml
ExecStart=/usr/bin/vector --config-toml /etc/vector/syslog-zabbix.toml
EOF

systemctl daemon-reload
```

**Warum beide Zeilen löschen?** `ExecStartPre=` und `ExecStart=` (leer) setzen
die entsprechenden Felder zurück. Die folgenden Zeilen fügen die neuen Werte hinzu.
Ohne den Rücksetz-Schritt würden die neuen Zeilen an die bestehenden angehängt.

---

## Konfiguration deployen

```bash
# Config auf VM 103 kopieren
scp vector/syslog-zabbix.toml root@10.1.1.103:/etc/vector/syslog-zabbix.toml
chmod 644 /etc/vector/syslog-zabbix.toml
```

---

## Konfiguration validieren

Vor dem Start immer prüfen:

```bash
vector validate /etc/vector/syslog-zabbix.toml

# Erwartete Ausgabe:
# √ Loaded ["/etc/vector/syslog-zabbix.toml"]
# √ Component configuration
# √ Health check "python_processor"
# -------------------------------------------
#                           Validated
```

Falls Fehler auftreten, zeigt `vector validate` genaue Zeilennummern und Fehlertypen.

---

## Service starten

```bash
# Aktivieren und starten
systemctl enable --now vector

# Status prüfen
systemctl status vector

# Logs beobachten
journalctl -u vector -f
```

---

## Live-Monitoring

```bash
vector top
```

Relevante Metriken:
- `syslog_udp` / `syslog_tcp`: Eingehende Events/s
- `severity_filter`: Durchsatzrate (nur severity ≤ 4 passieren)
- `normalize_fields`: Transform-Fehlerrate (sollte 0 sein)
- `python_processor`: HTTP-Fehlerrate + Buffer-Füllstand

Bei erhöhtem Buffer-Füllstand: `systemctl status syslog-processor` prüfen.

---

## Hinweis: Port 514 (privilegierter Port)

Die Standard-systemd-Unit enthält bereits `AmbientCapabilities=CAP_NET_BIND_SERVICE`,
sodass Vector als nicht-root-User Port 514 binden darf.

Bei einem manuellen Vector-Binary-Update muss die Capability ggf. neu gesetzt werden:

```bash
setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/vector
getcap /usr/bin/vector
```

---

## Payload-Format (Vector → Python-Processor)

Vector sendet Events als **JSON-Array** per HTTP POST, auch bei `max_events = 1`:

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

Interne Vector-Felder (`appname`, `procid`, `msgid`, `structured_data`, `version`,
`source_type`) werden im VRL-Transform entfernt.

---

## VRL-Besonderheiten (Vector 0.54.x)

Folgende Standard-Funktionen existieren in Vector 0.54.x **nicht**:

| Nicht verfügbar | Alternative |
|---|---|
| `strip_prefix(s, prefix)` | `slice!(s, length(prefix))` |
| `to_timestamp(value)` | Nicht nötig — `.timestamp` ist bereits Timestamp-Typ |

`.timestamp` aus dem `syslog`-Source ist ein nativer Timestamp-Typ und kann
direkt mit `format_timestamp!(.timestamp, format: "%+")` formatiert werden.

---

## Fehlerbehebung

**Vector startet nicht (duplicate source id):**
```
x duplicate source id found: syslog_tcp
```
Ursache: Config wird doppelt geladen (Standard-Config + eigene Config).
Lösung: `vector.yaml` umbenennen zu `vector.yaml.disabled`.

**HTTP 422 vom Python-Processor:**
Ursache: Payload-Format stimmt nicht mit Pydantic-Model überein.
Debug: `journalctl -u vector -n 20` zeigt HTTP-Status.
Direkttest:
```bash
curl -s -X POST http://127.0.0.1:8514/syslog \
  -H 'Content-Type: application/json' \
  -d '[{"source_ip":"10.1.1.1","hostname":"host","severity":"warning","severity_code":4,"facility":"daemon","message":"test","timestamp":"2026-01-01T00:00:00Z"}]'
```
