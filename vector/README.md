# Vector – Syslog-Receiver für syslog-zabbix

Vector empfängt Syslog-Meldungen (UDP + TCP, Port 514) von allen Zabbix-überwachten
Geräten, filtert auf WARNING und kritischere Events (severity ≤ 4) und leitet sie
als JSON per HTTP POST an den Python-Prozessor (`syslog-processor.service`) weiter.

**Deployment-Ziel:** VM 103, IP `10.1.1.103`
**Config-Pfad:** `/etc/vector/syslog-zabbix.toml`

---

## Installation (Debian/Ubuntu, ohne Docker, ohne problematische apt-Keys)

Vector stellt ein offizielles Shell-Installer-Skript bereit, das direkt ein
signiertes Paket installiert — kein manuelles Key-Management nötig.

```bash
# 1. Installer herunterladen und ausführen (als root)
curl -1sLf 'https://repositories.vector.dev/setup.bash' | bash

# 2. Vector installieren
apt-get install -y vector

# 3. Vector-Version prüfen
vector --version
```

Alternativ: Manueller Download des Debian-Pakets von
https://github.com/vectordotdev/vector/releases/latest
(Datei: `vector_<version>_amd64.deb`) und Installation via `dpkg -i`.

### systemd-Service konfigurieren

Vector bringt eine systemd-Unit mit, die beim apt-Install automatisch angelegt
wird. Vor dem Start muss das Log-Level gesetzt werden:

```bash
# Override-Verzeichnis anlegen
mkdir -p /etc/systemd/system/vector.service.d

# Log-Level auf WARN setzen (kein Debug im Normalbetrieb)
cat > /etc/systemd/system/vector.service.d/log-level.conf <<EOF
[Service]
Environment=VECTOR_LOG=warn
EOF

systemctl daemon-reload
```

---

## Konfiguration deployen

```bash
# Config-Datei deployen
cp /opt/syslog-zabbix/vector/syslog-zabbix.toml /etc/vector/syslog-zabbix.toml

# Standard-Config deaktivieren (falls vorhanden — kollidiert mit Port 514)
# Vector lädt alle *.toml-Dateien in /etc/vector/ — entweder löschen oder umbenennen:
mv /etc/vector/vector.toml /etc/vector/vector.toml.disabled 2>/dev/null || true
```

---

## Konfiguration validieren

Vor dem Start immer die Config syntaktisch und semantisch prüfen:

```bash
# Syntax und Schema prüfen (ohne Vector zu starten)
vector validate /etc/vector/syslog-zabbix.toml

# Erwartete Ausgabe:
# √ Loaded ["/etc/vector/syslog-zabbix.toml"]
# √ Component configuration
# √ Health checks
# ...
# Configuration valid.
```

Falls Fehler auftreten, zeigt `vector validate` genaue Zeilennummern.

---

## Service starten und überwachen

```bash
# Service starten und für Autostart aktivieren
systemctl enable --now vector

# Status prüfen
systemctl status vector

# Live-Logs beobachten (Log-Level ist warn — nur Fehler und Warnungen)
journalctl -u vector -f
```

---

## vector top — Live-Monitoring

`vector top` zeigt eine interaktive Echtzeit-Ansicht aller Components mit
Durchsatz, Fehlerrate und Buffer-Füllstand:

```bash
vector top
```

Relevante Metriken im Betrieb:
- `syslog_udp` / `syslog_tcp`: Eingehende Events pro Sekunde
- `severity_filter`: Verhältnis gefilterte/weitergeleitetete Events
- `normalize_fields`: Transform-Fehlerrate (sollte 0 sein)
- `python_processor`: HTTP-Fehlerrate, Buffer-Füllstand (max 25.000)

Bei erhöhtem Buffer-Füllstand: Python-Prozessor prüfen (`systemctl status syslog-processor`).

---

## Hinweis: Port 514 (privilegierter Port)

Port 514 ist ein privilegierter Port (< 1024). Vector muss entweder als root
laufen oder die Capability `CAP_NET_BIND_SERVICE` gesetzt haben.

**Option A: Capability setzen (empfohlen, kein root-Prozess):**

```bash
# Capability auf das Vector-Binary setzen
setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/vector

# Prüfen
getcap /usr/bin/vector
# Erwartete Ausgabe: /usr/bin/vector cap_net_bind_service=eip
```

Hinweis: Bei Vector-Updates muss `setcap` erneut gesetzt werden.
Alternativ: systemd-Unit mit `AmbientCapabilities=CAP_NET_BIND_SERVICE` konfigurieren:

```bash
cat > /etc/systemd/system/vector.service.d/cap-bind.conf <<EOF
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
EOF

systemctl daemon-reload
systemctl restart vector
```

**Option B: Als root ausführen (einfacher, weniger sicher):**

Die Standard-systemd-Unit läuft als `root` — Port 514 funktioniert ohne
weitere Anpassungen. Für eine Produktionsumgebung ist Option A vorzuziehen.

---

## Zusammenspiel mit dem Python-Prozessor

Vector sendet pro Event einen HTTP POST an `http://127.0.0.1:8514/syslog`.
Das JSON-Payload enthält folgende Felder:

| Feld | Typ | Beispiel |
|---|---|---|
| `source_ip` | String | `"10.1.1.254"` |
| `hostname` | String | `"opnsense"` |
| `severity` | String | `"err"`, `"crit"`, `"warning"` |
| `severity_code` | Integer | `3` |
| `facility` | String | `"kern"`, `"daemon"` |
| `message` | String | `"filterlog: TCP:443 blocked..."` |
| `timestamp` | String (ISO 8601) | `"2026-04-03T10:15:30+00:00"` |

Der Python-Prozessor erwartet **ein Event pro Request** — kein Array.
