# JapanFold skill

Fold proteins, co-fold with ligands (+ binding affinity), design binders, and
compute protein embeddings from your AI agent, via the free public
[JapanFold](https://japanfold.com) API. **No API key, no local GPU.** Runs
Boltz-2 / ESMFold2 / Protenix / BoltzGen / ESMC on Tenstorrent.

It's a single [`SKILL.md`](SKILL.md) built on the open [Agent Skills](https://agentskills.io)
standard, so it installs into **any** compatible harness with one command.

## Install

One line installs it everywhere the open standard is supported: **Claude Code,
Cursor, Codex, Gemini CLI, Cline, Windsurf, Copilot, Amp, and 60+ more**:

```bash
npx skills add moritztng/japanfold          # this project
npx skills add moritztng/japanfold -g       # global: every project / new chat
```

- Target specific agents: `-a claude-code`, `-a cursor`, `-a codex`, `-a '*'` (all).
- Prefer not to use the installer? It's just a file. Drop `SKILL.md` into your
  agent's skills directory (e.g. `~/.claude/skills/japanfold/SKILL.md`).

### Claude Code plugin marketplace

Claude Code users can also install it as a managed plugin (auto-updates via
`/plugin marketplace update`):

```bash
claude plugin marketplace add moritztng/japanfold
claude plugin install japanfold@japanfold
```

Restart Claude Code, then just ask it to fold or design. Same skill either way.
The plugin tracks this repo, so `marketplace update` pulls new versions.

**Claude Science** manages skills in-app (no installer): **Customize → Skills**,
add from this repo (or paste `SKILL.md`) and **publish** it. Or skip install
entirely: the API is public and self-describing, so just ask:
*"use the JapanFold API at `api.japanfold.com` to fold …"*.

## Use

Once installed, just ask your agent in plain language:

> *"Fold this sequence with Boltz-2 and report the confidence: MKTAYIAK…"*
> *"Design 10 nanobody binders against this target."*

Or invoke it explicitly where supported: `/japanfold`.

## The API

`https://api.japanfold.com`: public, keyless, async (submit → poll → download).
Full contract at [`/v1/openapi.json`](https://api.japanfold.com/v1/openapi.json).
See [`SKILL.md`](SKILL.md) for endpoints, examples, and limits.
