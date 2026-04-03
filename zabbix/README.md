# T_Syslog — Zabbix Template

Zabbix-Template zum Empfang von Syslog-Events via **Zabbix Trapper**.

- **Zabbix-Version:** 7.x (getestet auf 7.4.8)
- **Item-Key:** `syslog.event`
- **Eingehendes Format:** `SEVERITY|MESSAGE`

## Import-Anleitung

### 1. Template importieren

**Zabbix Web-UI:**

1. *Configuration → Templates → Import*
2. Datei `T_Syslog.yaml` hochladen
3. Importoptionen: alle Haken setzen (Templates, Items, Triggers)
4. *Import* klicken

**Alternativ via API (curl):**

```bash
# Auth-Token holen
TOKEN=$(curl -s -X POST http://10.1.1.103/zabbix/api_jsonrpc.php \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"Admin\",\"password\":\"$ZABBIX_PASSWORD\"},\"id\":1}" \
  | jq -r '.result')

# Template importieren
curl -s -X POST http://10.1.1.103/zabbix/api_jsonrpc.php \
  -H "Content-Type: application/json" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"method\": \"configuration.import\",
    \"params\": {
      \"format\": \"yaml\",
      \"rules\": {
        \"templates\": {\"createMissing\": true, \"updateExisting\": true},
        \"items\": {\"createMissing\": true, \"updateExisting\": true},
        \"triggers\": {\"createMissing\": true, \"updateExisting\": true}
      },
      \"source\": $(cat T_Syslog.yaml | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    },
    \"auth\": \"$TOKEN\",
    \"id\": 1
  }"
```

### 2. Template einem Host zuweisen

1. *Configuration → Hosts → [Ziel-Host] → Templates*
2. Template `T_Syslog` suchen und hinzufügen
3. *Update* klicken

### 3. Syslog-Events senden (Zabbix Sender)

Der Sender-Agent (z.B. Vector, Logstash, rsyslog, oder direkter `zabbix_sender`-Aufruf) muss Events im Format `SEVERITY|MESSAGE` an den Item-Key `syslog.event` senden.

**Beispiel mit zabbix_sender:**

```bash
zabbix_sender \
  --zabbix-server 10.1.1.103 \
  --host "mein-host" \
  --key "syslog.event" \
  --value "CRIT|sshd: authentication failure for root from 10.0.0.1"
```

**Beispiel mit Python:**

```python
from pyzabbix import ZabbixMetric, ZabbixSender

sender = ZabbixSender(zabbix_server='10.1.1.103')
metrics = [
    ZabbixMetric('mein-host', 'syslog.event', 'ERR|kernel: Out of memory: Kill process 1234')
]
sender.send(metrics)
```

## Trigger-Tabelle

| Trigger-Name | Zabbix-Severity | Auslösebedingung | Beschreibung |
|---|---|---|---|
| Syslog EMERG auf {HOST.NAME} | Disaster | Präfix `EMERG\|` | System nicht nutzbar |
| Syslog ALERT auf {HOST.NAME} | High | Präfix `ALERT\|` | Sofortige Aktion nötig |
| Syslog CRIT auf {HOST.NAME} | High | Präfix `CRIT\|` | Kritischer Zustand |
| Syslog ERR auf {HOST.NAME} | Average | Präfix `ERR\|` | Fehlerbedingung |
| Syslog WARN auf {HOST.NAME} | Warning | Präfix `WARN\|` | Warnzustand |

## Eingehendes Datenformat

```
SEVERITY|MESSAGE
```

Beispiele:

```
EMERG|kernel: PANIC - CPU machine check error
ALERT|raid: Degraded array detected on /dev/md0
CRIT|sshd: Too many authentication failures
ERR|postfix: fatal: no SASL authentication mechanisms
WARN|ntpd: time stepped by 1.234 seconds
NOTICE|systemd: Starting daily cleanup of temporary directories
INFO|sshd: Accepted publickey for admin
DEBUG|dhclient: option domain-search: homelab.local
```

Nachrichten mit den Präfixen `NOTICE`, `INFO`, `DEBUG` erzeugen keine Trigger-Alarme.

## Hinweise

- Das Item `syslog.event` ist vom Typ **Zabbix Trapper** — es gibt kein Polling-Intervall. Daten werden ausschließlich per Push empfangen.
- Der Wert-Typ ist **Log**, daher werden alle eingehenden Werte im Zabbix Log-Storage gespeichert (History: 30 Tage, keine Trends).
- Trigger-Expressions verwenden `find()` mit `regexp`-Matching auf den Log-Wert.
- Der Host-Name im Trigger-Namen wird durch `{HOST.NAME}` dynamisch aufgelöst.
- Tags `severity` und `component: syslog` ermöglichen gezielte Filterung in Zabbix-Problem-Views.
