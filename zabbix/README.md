# T_Syslog — Zabbix Template

Zabbix-Template zum Empfang von Syslog-Events via **Zabbix Trapper**.

- **Zabbix-Version:** 7.x (getestet auf 7.4.8)
- **Template-ID:** 11032 (auf VM 103)
- **Item-Key:** `syslog.event`
- **Eingehendes Format:** `SEVERITY|MESSAGE`

---

## Import-Anleitung

### Zabbix Web-UI

1. *Configuration → Templates → Import*
2. Datei `T_Syslog.yaml` hochladen
3. Importoptionen: alle Haken setzen (Templates, Items, Triggers)
4. *Import* klicken

### Via API (Zabbix 7.x Bearer-Auth)

```bash
# Zabbix Admin-Token holen (user.login für einmaligen Import)
SESSION=$(curl -s -X POST http://10.1.1.103/zabbix/api_jsonrpc.php \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"<password>"},"id":1}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")

# Template importieren
python3 - <<EOF
import json, urllib.request

with open("T_Syslog.yaml") as f:
    yaml_content = f.read()

payload = {
    "jsonrpc": "2.0",
    "method": "configuration.import",
    "params": {
        "format": "yaml",
        "rules": {
            "template_groups": {"createMissing": True, "updateExisting": True},
            "templates": {"createMissing": True, "updateExisting": True},
            "items": {"createMissing": True, "updateExisting": True, "deleteMissing": False},
            "triggers": {"createMissing": True, "updateExisting": True, "deleteMissing": False},
        },
        "source": yaml_content,
    },
    "id": 2,
}

req = urllib.request.Request(
    "http://10.1.1.103/zabbix/api_jsonrpc.php",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "Authorization": "Bearer $SESSION"},
)
with urllib.request.urlopen(req) as r:
    print(json.loads(r.read()))
EOF
```

**Hinweis:** `configuration.import` erfordert Admin-Rechte (Super-Admin-Usergroup).
Der Syslog-Service-User hat nur Leserechte und kann das Template nicht importieren.

---

## Template einem Host zuweisen

### Web-UI

1. *Configuration → Hosts → [Ziel-Host] → Templates*
2. Template `T_Syslog` suchen und hinzufügen
3. *Update* klicken

### Via API (alle Hosts auf einmal)

```python
import json, urllib.request

api_url = "http://10.1.1.103/zabbix/api_jsonrpc.php"

# Admin-Session (user.login)
with urllib.request.urlopen(urllib.request.Request(
    api_url,
    data=json.dumps({"jsonrpc":"2.0","method":"user.login",
                     "params":{"username":"Admin","password":"<password>"},"id":1}).encode(),
    headers={"Content-Type":"application/json"}
)) as r:
    session = json.loads(r.read())["result"]

def api(method, params):
    with urllib.request.urlopen(urllib.request.Request(
        api_url,
        data=json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}).encode(),
        headers={"Content-Type":"application/json","Authorization":f"Bearer {session}"}
    )) as r:
        return json.loads(r.read())

# Template-ID holen
templates = api("template.get", {"filter": {"name": "T_Syslog"}, "output": ["templateid"]})
template_id = templates["result"][0]["templateid"]

# Alle echten Hosts (keine Templates) holen
hosts = api("host.get", {"output": ["hostid", "host"], "templated_hosts": False})["result"]

# Template auf jeden Host anwenden
for host in hosts:
    r = api("host.update", {"hostid": host["hostid"], "templates": [{"templateid": template_id}]})
    if "error" not in r:
        print(f"OK: {host['host']}")
    else:
        print(f"FEHLER {host['host']}: {r['error']['data']}")
```

---

## Trigger-Tabelle

| Trigger-Name | Zabbix-Severity | Auslösebedingung | Beschreibung |
|---|---|---|---|
| Syslog EMERG auf {HOST.NAME} | Disaster | Präfix `EMERG\|` | System nicht nutzbar |
| Syslog ALERT auf {HOST.NAME} | High | Präfix `ALERT\|` | Sofortige Aktion nötig |
| Syslog CRIT auf {HOST.NAME} | High | Präfix `CRIT\|` | Kritischer Zustand |
| Syslog ERR auf {HOST.NAME} | Average | Präfix `ERR\|` | Fehlerbedingung |
| Syslog WARN auf {HOST.NAME} | Warning | Präfix `WARN\|` | Warnzustand |

---

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
```

Nachrichten mit den Präfixen `NOTICE`, `INFO`, `DEBUG` erzeugen keine Trigger-Alarme
(werden von Vector bereits herausgefiltert, bevor sie Zabbix erreichen).

---

## Manuell testen

```bash
# Direkt per zabbix_sender (auf VM 103)
zabbix_sender -z 127.0.0.1 -p 10051 -s <zabbix-hostname> -k syslog.event -o 'WARN|Testmeldung'

# Erwartete Ausgabe:
# Response from "127.0.0.1:10051": "processed: 1; failed: 0; total: 1; seconds spent: 0.000055"
```

`processed: 0; failed: 1` bedeutet: Host hat kein T_Syslog-Template oder der Hostname
stimmt nicht mit dem Zabbix-Hostnamen überein.

---

## Zabbix API-User für syslog-processor

Der Python-Processor nutzt einen dedizierten API-User mit minimalen Rechten:

| Parameter | Wert |
|---|---|
| Username | `syslog-zabbix` |
| Usergroup | `Syslog-Service` (ID 15) |
| Rechte | Read-only auf alle Hostgruppen |
| Auth | Zabbix API-Token (Bearer, kein user.login) |
| Credentials | Vaultwarden → Org "Bots" → "Zabbix API syslog-zabbix" |

Der Token wird in `processor/config.yaml` unter `zabbix.api_token` hinterlegt.

---

## Hinweise

- Item-Typ **Zabbix Trapper** — kein Polling, nur Push via `zabbix_sender`
- Wert-Typ **Log** — alle Werte in Zabbix Log-Storage (History: 30 Tage, keine Trends)
- Trigger-Expressions: `find()` mit `regexp`-Matching auf den Log-Wert
- Tags `severity` + `component: syslog` für gezielte Filterung in Problem-Views
