# JapanFold skill

Fold proteins, co-fold with ligands (+ affinity), and design binders from your
AI agent, via the free public [JapanFold](https://japanfold.com) API — no API
key, no local GPU. Runs Boltz-2 / ESMFold2 / Protenix / BoltzGen on Tenstorrent.

## Install

**Claude Code, Cursor, Codex, and other agents** (one command):

```bash
npx skills add moritztng/japanfold
```

**Claude Science:** open **Customize → Skills → Add**, and point it at this repo
(`github.com/moritztng/japanfold`) — or paste [`SKILL.md`](SKILL.md). Then just
ask, e.g. *"fold this sequence with Boltz-2 and report the confidence."*

No key needed. The API is `https://api.japanfold.com` (contract at
`/v1/openapi.json`). See [`SKILL.md`](SKILL.md) for the full usage.
