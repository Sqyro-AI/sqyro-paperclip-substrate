#!/usr/bin/env bash
set -Eeuo pipefail

umask 027

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_ROOT="/srv/paperclip-substrate"
CANONICAL_DIR="${SUBSTRATE_ROOT}/workspaces/sqyro-canonical"
WORKTREES_DIR="${SUBSTRATE_ROOT}/workspaces/sqyro-worktrees"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s <issue-id>\n' "$(basename "$0")" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

issue_id="$1"
[[ "$issue_id" =~ ^[a-zA-Z0-9-]+$ ]] || die "invalid issue-id: must match ^[a-zA-Z0-9-]+$"

worktree_dir="${WORKTREES_DIR}/issue-${issue_id}"
branch="paperclip/issue-${issue_id}"

if [[ -d "$worktree_dir" ]]; then
  printf 'worktree already exists at %s\n' "$worktree_dir"
  exit 0
fi

if [[ -e "$worktree_dir" ]]; then
  die "worktree path exists but is not a directory: $worktree_dir"
fi

mkdir -p "$WORKTREES_DIR"
"${SCRIPT_DIR}/fetch-canonical.sh" 1>&2

[[ -d "${CANONICAL_DIR}/.git" ]] || die "canonical clone missing after fetch: $CANONICAL_DIR"

cd "$CANONICAL_DIR"

if git show-ref --verify --quiet "refs/heads/${branch}"; then
  git worktree add "$worktree_dir" "$branch" 1>&2
else
  git worktree add -b "$branch" "$worktree_dir" origin/main 1>&2
fi

printf '%s\n' "$worktree_dir"
