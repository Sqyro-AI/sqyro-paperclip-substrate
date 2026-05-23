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

This commit does not enable a Paperclip agent, register prompts, run tasks, or open pull requests. The substrate is intentionally dormant: it only prepares authentication, canonical checkout refresh, and isolated worktree lifecycle primitives for a later Paperclip phase.

## Pointers

- Architecture: [docs/architecture.md](docs/architecture.md)
- Canonical build brief: `/Users/leh/worktrees/sqyro/paperclip/docs/plans/codex-brief-paperclip-substrate-a2.md`
