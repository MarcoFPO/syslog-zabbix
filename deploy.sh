#!/usr/bin/env bash
# deploy.sh — Deployment von syslog-zabbix auf VM 103 (10.1.1.103)
#
# Ausfuehren lokal (Claude-LXC oder Proxmox-Host):
#   bash /opt/Projekte/syslog/deploy.sh
#
# Was dieses Script tut:
#   1. Erreichbarkeit von VM 103 pruefen
#   2. Verzeichnisse auf VM 103 anlegen
#   3. processor/ auf VM 103 kopieren (rsync via SSH)
#   4. systemd/syslog-processor.service auf VM 103 kopieren
#   5. Vector-Config auf VM 103 kopieren (/etc/vector/)
#   6. pip install im venv auf VM 103 ausfuehren
#   7. systemctl daemon-reload + enable + restart
#   8. Status-Check
#
# Voraussetzungen:
#   - VM 103 (KVM) laeuft und ist via SSH erreichbar (root@10.1.1.103)
#   - setup_vm103.sh wurde bereits einmalig ausgefuehrt

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Konstanten
# ---------------------------------------------------------------------------

readonly VM_HOST="root@10.1.1.103"
readonly DEPLOY_DIR="/opt/syslog-zabbix"
readonly SERVICE_USER="syslog-processor"
readonly SERVICE_NAME="syslog-processor"
readonly VENV_DIR="${DEPLOY_DIR}/venv"

# Quelldateien auf dem Proxmox-Host
readonly SOURCE_DIR="/opt/Projekte/syslog"
readonly PROCESSOR_SRC="${SOURCE_DIR}/processor"
readonly SERVICE_SRC="${SOURCE_DIR}/systemd/syslog-processor.service"
readonly VECTOR_CONFIG_SRC="${SOURCE_DIR}/vector/syslog-zabbix.toml"

# Zielpfade auf VM 103
readonly PROCESSOR_DST="${DEPLOY_DIR}/processor"
readonly SERVICE_DST="/etc/systemd/system/syslog-processor.service"
readonly VECTOR_CONFIG_DST="/etc/vector/syslog-zabbix.toml"

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

log_info() {
  printf '[INFO]  %s\n' "$*"
}

log_ok() {
  printf '[OK]    %s\n' "$*"
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

log_step() {
  printf '\n--- Schritt %s: %s ---\n' "$1" "$2"
}

die() {
  log_error "$*"
  exit 1
}

# SSH-Wrapper — fuehrt Befehl auf VM 103 aus
vm_exec() {
  ssh "${VM_HOST}" "$@"
}

# SCP-Wrapper — kopiert Datei auf VM 103
vm_push() {
  local src="$1"
  local dst="$2"
  scp -q "${src}" "${VM_HOST}:${dst}"
}

# ---------------------------------------------------------------------------
# Vorbedingungen pruefen
# ---------------------------------------------------------------------------

check_prerequisites() {
  log_info "Pruefe Vorbedingungen ..."

  # SSH-Erreichbarkeit pruefen
  if ! command -v ssh &>/dev/null; then
    die "ssh nicht gefunden."
  fi

  # Quelldateien vorhanden?
  local -a required_sources=(
    "${PROCESSOR_SRC}"
    "${SERVICE_SRC}"
    "${VECTOR_CONFIG_SRC}"
  )
  for src in "${required_sources[@]}"; do
    if [[ ! -e "${src}" ]]; then
      die "Quelldatei/-verzeichnis nicht gefunden: ${src}"
    fi
  done

  log_ok "Alle Quelldateien vorhanden."
}

# ---------------------------------------------------------------------------
# Schritt 1: VM 103 Erreichbarkeit pruefen
# ---------------------------------------------------------------------------

check_vm_reachable() {
  log_step "1" "VM 103 Erreichbarkeit pruefen (SSH)"

  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${VM_HOST}" true 2>/dev/null; then
    die "SSH zu ${VM_HOST} nicht moeglich. VM laeuft? SSH-Key hinterlegt?"
  fi
  log_ok "SSH zu ${VM_HOST} erfolgreich."
}

# ---------------------------------------------------------------------------
# Schritt 2: Verzeichnisse auf VM 103 anlegen
# ---------------------------------------------------------------------------

create_remote_directories() {
  log_step "2" "Verzeichnisse auf VM 103 anlegen"

  local -a dirs=(
    "${DEPLOY_DIR}/processor"
    "${DEPLOY_DIR}/db"
    "${DEPLOY_DIR}/logs"
    "${DEPLOY_DIR}/systemd"
    "/etc/vector"
  )

  for dir in "${dirs[@]}"; do
    vm_exec mkdir -p -- "${dir}"
    log_ok "${dir}"
  done
}

# ---------------------------------------------------------------------------
# Schritt 3: processor/ auf VM 103 kopieren
# ---------------------------------------------------------------------------

copy_processor() {
  log_step "3" "processor/ nach VM 103:${PROCESSOR_DST} kopieren"

  # rsync via SSH — effizienter als einzelne scp-Aufrufe
  rsync -az --delete "${PROCESSOR_SRC}/" "${VM_HOST}:${PROCESSOR_DST}/"
  log_ok "processor/ synchronisiert."

  # Permissions setzen
  vm_exec chown -R "root:${SERVICE_USER}" "${PROCESSOR_DST}"
  vm_exec chmod 755 "${PROCESSOR_DST}"
  log_ok "Permissions fuer processor/ gesetzt."
}

# ---------------------------------------------------------------------------
# Schritt 4: systemd-Service auf VM 103 kopieren
# ---------------------------------------------------------------------------

copy_service_file() {
  log_step "4" "syslog-processor.service nach VM 103:${SERVICE_DST} kopieren"

  vm_push "${SERVICE_SRC}" "${SERVICE_DST}"
  vm_exec chmod 644 "${SERVICE_DST}"
  log_ok "Service-Datei kopiert: ${SERVICE_DST}"
}

# ---------------------------------------------------------------------------
# Schritt 5: Vector-Config auf VM 103 kopieren
# ---------------------------------------------------------------------------

copy_vector_config() {
  log_step "5" "Vector-Config nach VM 103:${VECTOR_CONFIG_DST} kopieren"

  vm_push "${VECTOR_CONFIG_SRC}" "${VECTOR_CONFIG_DST}"
  vm_exec chmod 644 "${VECTOR_CONFIG_DST}"
  log_ok "Vector-Config kopiert: ${VECTOR_CONFIG_DST}"
}

# ---------------------------------------------------------------------------
# Schritt 6: pip install im venv
# ---------------------------------------------------------------------------

install_python_deps() {
  log_step "6" "pip install im venv auf VM 103"

  local requirements_remote="${PROCESSOR_DST}/requirements.txt"

  # Pruefen ob venv existiert
  if ! vm_exec test -d "${VENV_DIR}"; then
    die "venv nicht gefunden: ${VENV_DIR} — setup_vm103.sh wurde noch nicht ausgefuehrt?"
  fi

  vm_exec "${VENV_DIR}/bin/pip" install \
    --quiet \
    --no-cache-dir \
    --upgrade \
    -r "${requirements_remote}"
  log_ok "Python-Abhaengigkeiten installiert."
}

# ---------------------------------------------------------------------------
# Schritt 7: systemd aktivieren und starten
# ---------------------------------------------------------------------------

enable_and_start_services() {
  log_step "7" "systemd daemon-reload + enable + restart"

  # syslog-processor
  vm_exec systemctl daemon-reload
  log_ok "daemon-reload ausgefuehrt."

  vm_exec systemctl enable --now "${SERVICE_NAME}"
  log_ok "${SERVICE_NAME} enabled und gestartet."

  # Vector: nur neustarten wenn bereits enabled (setup_vm103.sh konfiguriert Vector)
  if vm_exec systemctl is-enabled vector &>/dev/null; then
    vm_exec systemctl restart vector
    log_ok "vector neugestartet."
  else
    log_info "Vector-Service nicht enabled — uebersprungen (manuell aktivieren nach Pruefung)."
  fi
}

# ---------------------------------------------------------------------------
# Schritt 8: Status-Check
# ---------------------------------------------------------------------------

check_service_status() {
  log_step "8" "Status-Check"

  # syslog-processor Status
  local processor_status
  processor_status="$(vm_exec systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
  if [[ "${processor_status}" == "active" ]]; then
    log_ok "${SERVICE_NAME}: active (running)"
  else
    log_error "${SERVICE_NAME}: Status = '${processor_status}'"
    log_info "Logs anzeigen: ssh ${VM_HOST} journalctl -u ${SERVICE_NAME} -n 30"
    die "Service ${SERVICE_NAME} ist nicht aktiv."
  fi

  # Erreichbarkeit des HTTP-Endpunkts pruefen
  log_info "Pruefe HTTP-Endpunkt 127.0.0.1:8514/health ..."
  if vm_exec curl -sf --max-time 5 "http://127.0.0.1:8514/health" &>/dev/null; then
    log_ok "HTTP-Endpunkt /health antwortet."
  else
    log_info "HTTP-Endpunkt /health nicht erreichbar — ggf. noch nicht implementiert oder Service startet noch."
  fi

  printf '\n'
  log_ok "Deployment abgeschlossen."
  printf '\nNuetzliche Befehle:\n'
  printf '  Logs:    ssh %s journalctl -u %s -f\n' "${VM_HOST}" "${SERVICE_NAME}"
  printf '  Status:  ssh %s systemctl status %s\n' "${VM_HOST}" "${SERVICE_NAME}"
  printf '  Restart: ssh %s systemctl restart %s\n' "${VM_HOST}" "${SERVICE_NAME}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  printf '=== syslog-zabbix Deployment → VM 103 ===\n' "103"
  printf 'Zeitstempel: %s\n\n' "$(date --iso-8601=seconds)"

  check_prerequisites
  check_vm_reachable
  create_remote_directories
  copy_processor
  copy_service_file
  copy_vector_config
  install_python_deps
  enable_and_start_services
  check_service_status
}

main "$@"
