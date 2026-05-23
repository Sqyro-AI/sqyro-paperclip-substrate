#!/usr/bin/env bash
set -Eeuo pipefail

umask 027

SUBSTRATE_ROOT="/srv/paperclip-substrate"
CANONICAL_DIR="${SUBSTRATE_ROOT}/workspaces/sqyro-canonical"
WORKTREES_DIR="${SUBSTRATE_ROOT}/workspaces/sqyro-worktrees"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s <issue-id> [--force] [--abandon]\n' "$(basename "$0")" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

issue_id="$1"
shift

[[ "$issue_id" =~ ^[a-zA-Z0-9-]+$ ]] || die "invalid issue-id: must match ^[a-zA-Z0-9-]+$"

force=0
abandon=0

for arg in "$@"; do
  case "$arg" in
    --force)
      force=1
      ;;
    --abandon)
      abandon=1
      ;;
    *)
      die "unknown option: $arg"
      ;;
  esac
done

worktree_dir="${WORKTREES_DIR}/issue-${issue_id}"
branch="paperclip/issue-${issue_id}"

if [[ ! -d "${CANONICAL_DIR}/.git" ]]; then
  if [[ -d "$worktree_dir" ]]; then
    die "canonical clone missing: $CANONICAL_DIR"
  fi
  exit 0
fi

cd "$CANONICAL_DIR"

if [[ -d "$worktree_dir" ]]; then
  if [[ "$force" -eq 1 ]]; then
    git worktree remove --force "$worktree_dir" >/dev/null
  else
    git worktree remove "$worktree_dir" >/dev/null
  fi
fi

if git show-ref --verify --quiet "refs/heads/${branch}"; then
  if [[ "$abandon" -eq 1 ]]; then
    git branch -D "$branch" >/dev/null
  elif git show-ref --verify --quiet "refs/remotes/origin/main" \
    && git merge-base --is-ancestor "$branch" origin/main; then
    git branch -D "$branch" >/dev/null
  fi
fi
