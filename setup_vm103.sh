#!/usr/bin/env bash
# setup_vm103.sh — Einmaliges Setup auf VM 103 (Zabbix, 10.1.1.103)
#
# Ausfuehren via Proxmox-Host:
#   pct exec 103 -- bash -s < /opt/Projekte/syslog/setup_vm103.sh
#
# Was dieses Script tut:
#   - System-User syslog-processor anlegen
#   - Verzeichnisstruktur /opt/syslog-zabbix/ anlegen
#   - Python3-venv unter /opt/syslog-zabbix/venv/ anlegen
#   - Vector installieren (apt, vector.dev-Repo)
#   - zabbix-sender installieren (Zabbix apt-Repo)
#   - CAP_NET_BIND_SERVICE fuer Vector setzen (Port 514 < 1024)
#
# Voraussetzungen: Debian 11/12, root-Rechte, Internet-Zugang

set -Eeuo pipefail

readonly DEPLOY_DIR="/opt/syslog-zabbix"
readonly SERVICE_USER="syslog-processor"
readonly VENV_DIR="${DEPLOY_DIR}/venv"

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

die() {
  log_error "$*"
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "Dieses Script muss als root ausgefuehrt werden."
  fi
}

# ---------------------------------------------------------------------------
# System-User anlegen
# ---------------------------------------------------------------------------

create_service_user() {
  log_info "Pruefe Service-User '${SERVICE_USER}' ..."
  if id "${SERVICE_USER}" &>/dev/null; then
    log_ok "User '${SERVICE_USER}' existiert bereits."
    return 0
  fi
  useradd \
    --system \
    --no-create-home \
    --shell /usr/sbin/nologin \
    --comment "syslog-zabbix processor service" \
    "${SERVICE_USER}"
  log_ok "User '${SERVICE_USER}' angelegt."
}

# ---------------------------------------------------------------------------
# Verzeichnisstruktur
# ---------------------------------------------------------------------------

create_directories() {
  log_info "Lege Verzeichnisstruktur an ..."
  local -a dirs=(
    "${DEPLOY_DIR}/processor"
    "${DEPLOY_DIR}/db"
    "${DEPLOY_DIR}/logs"
    "${DEPLOY_DIR}/systemd"
  )
  for dir in "${dirs[@]}"; do
    mkdir -p -- "${dir}"
    log_ok "Verzeichnis: ${dir}"
  done

  # Permissions: processor darf db und logs schreiben
  chown -R "root:${SERVICE_USER}" "${DEPLOY_DIR}/db" "${DEPLOY_DIR}/logs"
  chmod 770 "${DEPLOY_DIR}/db" "${DEPLOY_DIR}/logs"
  log_ok "Permissions fuer db/ und logs/ gesetzt."
}

# ---------------------------------------------------------------------------
# Python3 + venv
# ---------------------------------------------------------------------------

setup_python_venv() {
  log_info "Pruefe Python3 ..."
  if ! command -v python3 &>/dev/null; then
    log_info "Installiere python3 + python3-venv ..."
    apt-get install -y --no-install-recommends python3 python3-venv python3-pip
  fi

  local python_version
  python_version="$(python3 --version)"
  log_ok "Python: ${python_version}"

  log_info "Lege venv an: ${VENV_DIR} ..."
  if [[ ! -d "${VENV_DIR}" ]]; then
    python3 -m venv "${VENV_DIR}"
    log_ok "venv erstellt: ${VENV_DIR}"
  else
    log_ok "venv existiert bereits: ${VENV_DIR}"
  fi

  chown -R "root:${SERVICE_USER}" "${VENV_DIR}"
  chmod -R 755 "${VENV_DIR}"
}

# ---------------------------------------------------------------------------
# Vector installieren
# ---------------------------------------------------------------------------

install_vector() {
  log_info "Pruefe Vector ..."
  if command -v vector &>/dev/null; then
    log_ok "Vector bereits installiert: $(vector --version 2>/dev/null || echo 'unbekannt')"
    return 0
  fi

  log_info "Installiere Vector via apt (vector.dev-Repo) ..."

  # Debian-Version ermitteln
  local debian_codename
  debian_codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-bookworm}")"
  log_info "Debian Codename: ${debian_codename}"

  # Abhaengigkeiten
  apt-get install -y --no-install-recommends curl gnupg apt-transport-https

  # GPG-Key
  local keyring="/usr/share/keyrings/vector-archive-keyring.gpg"
  if [[ ! -f "${keyring}" ]]; then
    curl -fsSL "https://apt.vector.dev/gpg.3543DB2D0A2BC4B8.asc" \
      | gpg --dearmor -o "${keyring}"
    log_ok "Vector GPG-Key installiert."
  fi

  # Repo-Eintrag
  local sources_file="/etc/apt/sources.list.d/vector.list"
  if [[ ! -f "${sources_file}" ]]; then
    printf 'deb [signed-by=%s] https://apt.vector.dev/ubuntu focal main\n' \
      "${keyring}" > "${sources_file}"
    log_ok "Vector apt-Repo hinzugefuegt."
  fi

  apt-get update -qq
  apt-get install -y --no-install-recommends vector
  log_ok "Vector installiert: $(vector --version 2>/dev/null || echo 'ok')"

  # Vector-Config-Verzeichnis
  mkdir -p /etc/vector
  log_ok "Verzeichnis /etc/vector/ angelegt."

  # CAP_NET_BIND_SERVICE setzen (Port 514 < 1024)
  set_vector_capabilities
}

# ---------------------------------------------------------------------------
# CAP_NET_BIND_SERVICE fuer Vector
# ---------------------------------------------------------------------------

set_vector_capabilities() {
  log_info "Setze CAP_NET_BIND_SERVICE fuer vector-Binary ..."

  local vector_bin
  vector_bin="$(command -v vector)"
  if [[ -z "${vector_bin}" ]]; then
    log_error "vector-Binary nicht gefunden — Capabilities nicht gesetzt."
    return 1
  fi

  if ! command -v setcap &>/dev/null; then
    log_info "Installiere libcap2-bin fuer setcap ..."
    apt-get install -y --no-install-recommends libcap2-bin
  fi

  setcap 'cap_net_bind_service=+ep' "${vector_bin}"
  log_ok "CAP_NET_BIND_SERVICE gesetzt: ${vector_bin}"
}

# ---------------------------------------------------------------------------
# zabbix-sender installieren
# ---------------------------------------------------------------------------

install_zabbix_sender() {
  log_info "Pruefe zabbix-sender ..."
  if command -v zabbix_sender &>/dev/null; then
    log_ok "zabbix-sender bereits installiert: $(zabbix_sender --version 2>/dev/null | head -1 || echo 'ok')"
    return 0
  fi

  log_info "Installiere zabbix-sender aus Zabbix-Repo ..."

  # Debian-Version fuer Zabbix-Paket ermitteln
  local debian_version
  debian_version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-12}")"
  log_info "Debian Version: ${debian_version}"

  # Zabbix-Release-Paket herunterladen und installieren
  local zabbix_release_url="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian${debian_version}_all.deb"
  local tmp_deb
  tmp_deb="$(mktemp --suffix=.deb)"
  trap 'rm -f -- "${tmp_deb}"' RETURN

  if curl -fsSL "${zabbix_release_url}" -o "${tmp_deb}"; then
    dpkg -i "${tmp_deb}" || apt-get install -f -y
    log_ok "Zabbix-Release-Paket installiert."
  else
    log_error "Zabbix-Release-Paket konnte nicht heruntergeladen werden: ${zabbix_release_url}"
    log_info "Versuche zabbix-sender direkt aus aktuellem Repo zu installieren ..."
  fi

  apt-get update -qq
  apt-get install -y --no-install-recommends zabbix-sender
  log_ok "zabbix-sender installiert."
}

# ---------------------------------------------------------------------------
# Zusammenfassung
# ---------------------------------------------------------------------------

print_summary() {
  printf '\n'
  printf '=%.0s' {1..60}
  printf '\n'
  printf 'Setup abgeschlossen.\n\n'
  printf 'Naechste Schritte:\n'
  printf '  1. deploy.sh auf Proxmox-Host ausfuehren:\n'
  printf '       bash /opt/Projekte/syslog/deploy.sh\n'
  printf '  2. Vector-Config pruefen:\n'
  printf '       cat /etc/vector/syslog-zabbix.toml\n'
  printf '  3. Services starten:\n'
  printf '       systemctl start syslog-processor vector\n'
  printf '  4. Status pruefen:\n'
  printf '       systemctl status syslog-processor vector\n'
  printf '=%.0s' {1..60}
  printf '\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  require_root
  log_info "=== syslog-zabbix Setup auf VM 103 ==="

  apt-get update -qq

  create_service_user
  create_directories
  setup_python_venv
  install_vector
  install_zabbix_sender

  print_summary
}

main "$@"
