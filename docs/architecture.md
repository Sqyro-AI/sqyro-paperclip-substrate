# Paperclip Substrate Architecture

```text
Paperclip Issues
      |
      v
CEO agent
      |
      v
CTO agent
      |
      v
engineer agent
      |
      v
/srv/paperclip-substrate/bin/create-worktree.sh <issue-id>
      |
      v
/srv/paperclip-substrate/workspaces/sqyro-worktrees/issue-<id>
      |
      v
engineer commits and pushes paperclip/issue-<id>
      |
      v
gh pr create
      |
      v
PR against Sqyro-AI/sqyro
```

## Roles

The CEO agent owns triage and dispatch. The CTO agent reviews issues and delegates implementation work to the engineer agent. The engineer agent receives an issue id, asks `create-worktree.sh` for an isolated checkout, performs the implementation inside that worktree, commits to `paperclip/issue-<id>`, pushes, and uses `gh pr create` to open a pull request against `Sqyro-AI/sqyro`.

The CTO agent uses the same substrate in read-only mode. It gets repo context from the canonical clone or an issue worktree, reviews the real checked-out files, and reports on concrete code state without mutating the workspace.

## Authentication Flow

```text
/etc/paperclip-substrate/github-app.pem
      |
      v
/srv/paperclip-substrate/bin/gh-app-token.sh
      |
      v
short-lived GitHub App installation token
      |
      v
git fetch / git push / gh CLI
```

`gh-app-token.sh` signs an RS256 JWT with the GitHub App private key, exchanges it for an installation token, and prints only that token to stdout. Runtime git operations mint a fresh token instead of relying on stored credentials.

## Isolation

`fetch-canonical.sh` keeps `/srv/paperclip-substrate/workspaces/sqyro-canonical` pinned to `origin/main`. Each issue gets its own worktree under `/srv/paperclip-substrate/workspaces/sqyro-worktrees/issue-<id>` on branch `paperclip/issue-<id>`.

Isolation matters because Paperclip agents must operate against real repository state. The anti-fabrication principle from `feedback_agents_fabricate_in_empty_workspace.md` applies here: an engineer agent with no checked-out repo can invent verdicts, while an isolated worktree gives it concrete files, diffs, tests, and git history to inspect.
