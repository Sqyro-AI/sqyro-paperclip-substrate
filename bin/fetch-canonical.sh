#!/usr/bin/env bash
set -Eeuo pipefail

umask 027

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_ROOT="/srv/paperclip-substrate"
WORKSPACES_DIR="${SUBSTRATE_ROOT}/workspaces"
CANONICAL_DIR="${WORKSPACES_DIR}/sqyro-canonical"
REPO_URL="https://github.com/Sqyro-AI/sqyro.git"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

app_auth_header() {
  local token
  local basic

  token="$("${SCRIPT_DIR}/gh-app-token.sh")"
  [[ -n "$token" ]] || die "failed to mint GitHub App installation token"

  basic="$(printf 'x-access-token:%s' "$token" | openssl base64 -A)"
  printf 'Authorization: Basic %s' "$basic"
}

git_with_app_auth() {
  local header

  header="$(app_auth_header)"
  git -c "http.https://github.com/.extraHeader=${header}" "$@"
}

require_cmd git
require_cmd openssl

mkdir -p "$WORKSPACES_DIR"

if [[ -e "$CANONICAL_DIR" && ! -d "${CANONICAL_DIR}/.git" ]]; then
  die "canonical path exists but is not a git clone: $CANONICAL_DIR"
fi

if [[ ! -d "${CANONICAL_DIR}/.git" ]]; then
  git_with_app_auth clone "$REPO_URL" "$CANONICAL_DIR" 1>&2
  git -C "$CANONICAL_DIR" remote set-url origin "$REPO_URL"
else
  git -C "$CANONICAL_DIR" remote set-url origin "$REPO_URL"
  git_with_app_auth -C "$CANONICAL_DIR" fetch origin --prune 1>&2
  git -C "$CANONICAL_DIR" reset --hard origin/main 1>&2
fi
