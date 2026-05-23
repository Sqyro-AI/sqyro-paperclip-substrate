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
SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_BIN_DIR="${SOURCE_ROOT}/bin"
TMP_FILES=()

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
  install -m 0640 -o "$USER_NAME" -g "$GROUP_NAME" "$tmp" "${SUBSTRATE_ETC_DIR}/github-app.env"
}

install_runtime_scripts() {
  local script
  local scripts=(
    gh-app-token.sh
    create-worktree.sh
    cleanup-worktree.sh
    fetch-canonical.sh
  )

  for script in "${scripts[@]}"; do
    [[ -f "${SOURCE_BIN_DIR}/${script}" ]] || die "missing runtime script: ${SOURCE_BIN_DIR}/${script}"
    install -m 0750 -o "$USER_NAME" -g "$GROUP_NAME" "${SOURCE_BIN_DIR}/${script}" "${BIN_DIR}/${script}"
  done
}

seed_canonical_clone() {
  runuser -u "$USER_NAME" -- "${BIN_DIR}/fetch-canonical.sh"
}

smoke_test_token_mint() {
  runuser -u "$USER_NAME" -- "${BIN_DIR}/gh-app-token.sh" > /dev/null
  echo "token mint OK"
}

main() {
  require_root
  ensure_user
  ensure_dependencies
  create_directories
  verify_private_key
  write_github_app_env
  install_runtime_scripts
  seed_canonical_clone
  smoke_test_token_mint
  echo "Substrate ready at /srv/paperclip-substrate/"
}

main "$@"
