#!/usr/bin/env bash
set -Eeuo pipefail

umask 027

APP_ID="3830905"
INSTALLATION_ID="135022924"
USER_NAME="paperclip-engineer"
GROUP_NAME="paperclip-engineer"
ETC_DIR="/etc/paperclip-substrate"
PEM_PATH="${ETC_DIR}/github-app.pem"
SUBSTRATE_ROOT="/srv/paperclip-substrate"
BIN_DIR="${SUBSTRATE_ROOT}/bin"
SUBSTRATE_ETC_DIR="${SUBSTRATE_ROOT}/etc"
WORKSPACES_DIR="${SUBSTRATE_ROOT}/workspaces"
WORKTREES_DIR="${WORKSPACES_DIR}/sqyro-worktrees"
AUDIT_ENV_PATH="${ETC_DIR}/audit.env"
AUDIT_STATE_DIR="/var/lib/paperclip-audit"
SYSTEMD_DIR="/etc/systemd/system"
SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_BIN_DIR="${SOURCE_ROOT}/bin"
SOURCE_ETC_DIR="${SOURCE_ROOT}/etc"
SOURCE_SYSTEMD_DIR="${SOURCE_ROOT}/systemd"
TMP_FILES=()
NO_AUDIT=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local file

  for file in "${TMP_FILES[@]}"; do
    rm -f -- "$file"
  done
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
usage: install.sh [--no-audit]

Installs the Paperclip substrate runtime. By default this also installs and
enables the closure-audit systemd timer. Use --no-audit to leave the audit timer
disabled during a substrate-only upgrade.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-audit)
        NO_AUDIT=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root: sudo /opt/paperclip-substrate/install.sh"
}

ensure_user() {
  if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
    groupadd -r "$GROUP_NAME"
  fi

  if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    useradd -r -g "$GROUP_NAME" -s /usr/sbin/nologin "$USER_NAME"
  fi
}

ensure_dependencies() {
  local packages=()

  command -v git >/dev/null 2>&1 || packages+=(git)
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  command -v openssl >/dev/null 2>&1 || packages+=(openssl)
  command -v runuser >/dev/null 2>&1 || packages+=(util-linux)

  if [[ "${#packages[@]}" -gt 0 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi
}

create_directories() {
  install -d -m 0750 -o root -g "$GROUP_NAME" "$ETC_DIR"
  install -d -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "$SUBSTRATE_ROOT"
  install -d -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "$BIN_DIR"
  install -d -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "$SUBSTRATE_ETC_DIR"
  install -d -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "$WORKSPACES_DIR"
  install -d -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "$WORKTREES_DIR"

  if [[ "$NO_AUDIT" -eq 0 ]]; then
    install -d -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "$AUDIT_STATE_DIR"
  fi
}

verify_private_key() {
  if [[ ! -f "$PEM_PATH" ]]; then
    cat >&2 <<'MSG'
ERROR: /etc/paperclip-substrate/github-app.pem missing.
On your Mac, run:
  scp ~/Downloads/sqyro-paperclip-engineer.2026-05-23.private-key.pem \
    root@100.89.115.103:/etc/paperclip-substrate/github-app.pem
  ssh root@100.89.115.103 'chown paperclip-engineer:paperclip-engineer /etc/paperclip-substrate/github-app.pem && chmod 600 /etc/paperclip-substrate/github-app.pem'
Then re-run install.sh.
MSG
    exit 1
  fi

  chown "${USER_NAME}:${GROUP_NAME}" "$PEM_PATH"
  chmod 0600 "$PEM_PATH"

  [[ "$(stat -c '%U:%G %a' "$PEM_PATH")" == "${USER_NAME}:${GROUP_NAME} 600" ]] \
    || die "${PEM_PATH} must be owned by ${USER_NAME}:${GROUP_NAME} with mode 0600"
}

write_github_app_env() {
  local tmp

  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")

  {
    printf 'GITHUB_APP_ID=%s\n' "$APP_ID"
    printf 'GITHUB_INSTALLATION_ID=%s\n' "$INSTALLATION_ID"
    printf 'GITHUB_APP_PRIVATE_KEY_PATH=%s\n' "$PEM_PATH"
  } > "$tmp"

  install -m 0640 -o root -g "$GROUP_NAME" "$tmp" "${ETC_DIR}/github-app.env"
}

install_runtime_scripts() {
  local script
  local scripts=(
    gh-app-token.sh
    create-worktree.sh
    cleanup-worktree.sh
    fetch-canonical.sh
    audit-closures.sh
  )

  for script in "${scripts[@]}"; do
    [[ -f "${SOURCE_BIN_DIR}/${script}" ]] || die "missing runtime script: ${SOURCE_BIN_DIR}/${script}"
    install -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "${SOURCE_BIN_DIR}/${script}" "${BIN_DIR}/${script}"
  done
}

write_audit_env_if_missing() {
  local example="${SOURCE_ETC_DIR}/audit.env.example"

  [[ -f "$example" ]] || die "missing audit env example: $example"

  if [[ ! -f "$AUDIT_ENV_PATH" ]]; then
    install -m 0640 -o root -g "$GROUP_NAME" "$example" "$AUDIT_ENV_PATH"
  else
    chown "root:${GROUP_NAME}" "$AUDIT_ENV_PATH"
    chmod 0640 "$AUDIT_ENV_PATH"
  fi
}

verify_audit_env() {
  # shellcheck source=/dev/null
  . "$AUDIT_ENV_PATH"

  if [[ -z "${PAPERCLIP_AUDIT_API_KEY:-}" || "${PAPERCLIP_AUDIT_API_KEY:-}" == "<paste here>" ]]; then
    cat >&2 <<'MSG'
ERROR: /etc/paperclip-substrate/audit.env needs PAPERCLIP_AUDIT_API_KEY.
In the Paperclip web UI at http://100.89.115.103:3210:
  1. Navigate to Agents -> Create Agent.
  2. Use role "auditor" if selectable; otherwise stop and ask Leif whether "engineer" is acceptable.
  3. Mint an API key with read+write issue access.
  4. Paste only the key into PAPERCLIP_AUDIT_API_KEY in /etc/paperclip-substrate/audit.env.
  5. Run:
       chown root:paperclip-engineer /etc/paperclip-substrate/audit.env
       chmod 0640 /etc/paperclip-substrate/audit.env
Then re-run install.sh, or use install.sh --no-audit to skip the audit timer.
MSG
    exit 1
  fi
}

install_audit_systemd_units() {
  local unit
  local units=(
    paperclip-audit.service
    paperclip-audit.timer
  )

  for unit in "${units[@]}"; do
    [[ -f "${SOURCE_SYSTEMD_DIR}/${unit}" ]] || die "missing systemd unit: ${SOURCE_SYSTEMD_DIR}/${unit}"
    install -m 0644 -o root -g root "${SOURCE_SYSTEMD_DIR}/${unit}" "${SYSTEMD_DIR}/${unit}"
  done

  systemctl daemon-reload
  systemctl enable --now paperclip-audit.timer
}

setup_audit() {
  if [[ "$NO_AUDIT" -eq 1 ]]; then
    echo "audit timer skipped (--no-audit)"
    return
  fi

  write_audit_env_if_missing
  verify_audit_env
  install_audit_systemd_units
}

seed_canonical_clone() {
  runuser -u "$USER_NAME" -- "${BIN_DIR}/fetch-canonical.sh"
}

smoke_test_token_mint() {
  runuser -u "$USER_NAME" -- "${BIN_DIR}/gh-app-token.sh" > /dev/null
  echo "token mint OK"
}

main() {
  parse_args "$@"
  require_root
  ensure_user
  ensure_dependencies
  create_directories
  verify_private_key
  write_github_app_env
  install_runtime_scripts
  setup_audit
  seed_canonical_clone
  smoke_test_token_mint
  echo "Substrate ready at /srv/paperclip-substrate/"
}

main "$@"
