#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

ENV_FILE="/etc/paperclip-substrate/github-app.env"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

cleanup() {
  if [[ -n "${response_file:-}" ]]; then
    rm -f -- "$response_file"
  fi
}
trap cleanup EXIT

require_cmd curl
require_cmd jq
require_cmd openssl

[[ -r "$ENV_FILE" ]] || die "missing readable env file: $ENV_FILE"

# shellcheck source=/dev/null
. "$ENV_FILE"

[[ "${GITHUB_APP_ID:-}" =~ ^[0-9]+$ ]] || die "GITHUB_APP_ID must be numeric"
[[ "${GITHUB_INSTALLATION_ID:-}" =~ ^[0-9]+$ ]] || die "GITHUB_INSTALLATION_ID must be numeric"
[[ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]] || die "GITHUB_APP_PRIVATE_KEY_PATH is required"
[[ -r "$GITHUB_APP_PRIVATE_KEY_PATH" ]] || die "private key is not readable: $GITHUB_APP_PRIVATE_KEY_PATH"

now="$(date +%s)"
iat="$((now - 60))"
exp="$((now + 540))"

header='{"alg":"RS256","typ":"JWT"}'
payload="$(jq -cn \
  --argjson iss "$GITHUB_APP_ID" \
  --argjson iat "$iat" \
  --argjson exp "$exp" \
  '{iss:$iss,iat:$iat,exp:$exp}')"

header_b64="$(printf '%s' "$header" | base64url)"
payload_b64="$(printf '%s' "$payload" | base64url)"
signing_input="${header_b64}.${payload_b64}"
signature_b64="$(printf '%s' "$signing_input" \
  | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_PATH" -binary \
  | base64url)"
jwt="${signing_input}.${signature_b64}"

response_file="$(mktemp "${TMPDIR:-/tmp}/paperclip-gh-token.XXXXXX")"
http_status="$(curl -sS \
  -o "$response_file" \
  -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${GITHUB_INSTALLATION_ID}/access_tokens")" \
  || die "GitHub installation token request failed"

[[ "$http_status" == 2* ]] || die "GitHub installation token request returned HTTP ${http_status}"

token="$(jq -r '.token // empty' < "$response_file")"
[[ -n "$token" ]] || die "GitHub response did not include a token"

printf '%s\n' "$token"
