# sqyro-paperclip-substrate

This repository contains the dormant box-side Paperclip substrate for `Sqyro-AI/sqyro`: an idempotent Ubuntu installer plus runtime scripts that mint scoped GitHub App installation tokens, keep a canonical clone fresh, and create per-issue isolated worktrees for future engineer and CTO agents.

## Install

On the Hetzner box, with this repository checked out at `/opt/paperclip-substrate`, run:

```sh
sudo /opt/paperclip-substrate/install.sh
```

If the GitHub App private key has not been placed yet, the installer creates the target directories and stops with instructions. From Leif's Mac, transfer the private key with:

```sh
scp ~/Downloads/sqyro-paperclip-engineer.2026-05-23.private-key.pem \
  root@100.89.115.103:/etc/paperclip-substrate/github-app.pem
ssh root@100.89.115.103 'chown paperclip-engineer:paperclip-engineer /etc/paperclip-substrate/github-app.pem && chmod 600 /etc/paperclip-substrate/github-app.pem'
```

Then re-run:

```sh
sudo /opt/paperclip-substrate/install.sh
```

## What this does NOT do

This repository does not enable a Paperclip agent, register prompts, run tasks, or open pull requests. It prepares authentication, canonical checkout refresh, isolated worktree lifecycle primitives, and the closure-audit timer that guards against evidence-less agent closes.

## Smoke test: audit against the May 22 incident

Run the audit in dry-run mode against the window of the 28-false-closure incident:

```sh
sudo -u paperclip-engineer /srv/paperclip-substrate/bin/audit-closures.sh \
  --dry-run \
  --since 2026-05-22T00:00:00Z \
  --until 2026-05-23T00:00:00Z
```

Expected: ≥ 28 "would re-open" entries. The actual May 22 cancellation count
observed during API discovery was 104 across the full day, so the script may flag
more than the original manually identified set; review each entry before re-closing.

## Pointers

- Architecture: [docs/architecture.md](docs/architecture.md)
- Audit API reference: [docs/audit-api-reference.md](docs/audit-api-reference.md)
- Canonical build brief: `/Users/leh/worktrees/sqyro/paperclip/docs/plans/codex-brief-paperclip-substrate-a2.md`
