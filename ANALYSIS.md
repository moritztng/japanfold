# JapanFold on-box agent — analysis (Step 1)

Real observation of `UF-EV-A13-GWH02` via `ssh japanfold-ssh` on 2026-07-12, not assumption.

## Mechanism (systemd units + scripts, read in full)

- `japanfold-agent.service` (systemd, `Restart=always`, `StartLimitBurst=10`) → `~/.japanfold-agent/launch.sh` keeps a tmux session `japanfold-agent` alive (blocks while it exists, exits so systemd recreates it on death).
- Inside tmux: `~/.japanfold-agent/run-agent.sh` runs `claude --resume eaab7bb1-… --model claude-sonnet-5 --dangerously-skip-permissions` in a `while true` loop (respawn 10s on exit). A live, resumed Claude Code session, 27 MB transcript.
- `japanfold-agent-sweep.timer` (`OnUnitActiveSec=6h`, `OnBootSec=10min`, `Persistent=true`) → `japanfold-agent-sweep.service` (oneshot) → `~/.japanfold-agent/sweep.sh`.
- `sweep.sh` injects `sweep-prompt.txt` into the tmux pane **only once the pane's bottom 6 lines are byte-stable across 4 s** (idle at the claude prompt, not loading/mid-task). No-op + log if the agent isn't ready after ~6 min.
- The agent reads `~/.japanfold-agent/RUNBOOK.md` each sweep and acts. (RUNBOOK says "every 30 min"; the actual timer is 6 h — RUNBOOK is stale on cadence, the timer is authoritative.)
- Alerting: `~/.japanfold-agent/notify.sh` → Telegram (bot `8637121393:…`, chat `8078069779` — Moritz; **same chat as the pc coworker `tg.sh`**), and always appends to `maintenance.jsonl`.

## What each sweep checks (RUNBOOK + observed jsonl schema)

1. `systemctl is-active japanfold cloudflared-japanfold` → restart if down (drain first: `curl /api/cluster` → `runs.running == 0`).
2. `curl -s localhost:8090/api/cluster` → `online_workers` (expect 32). <32 across two sweeps → note device + check journal. 31/32 acceptable; do NOT reboot.
3. `curl -fsS https://japanfold.com/api/health` → `status: ok`.
4. `df -h /` → act only if **free < ~20 GB absolute** (93 % used / 242 GB free is normal). Free via evicting old jobs, clear `/tmp/tt-bio-*`, truncate huge `/tmp/aiand_serve.log`.
5. Chips: only if a job failed with a device error → `tt-smi -ls`, reset ladder `tt-smi -glx_reset_auto` → `tt-smi -glx_reset`. ARC stuck (`UninitPciChip` / 0 boards) → **STOP, alert** (only a host reboot fixes it; reboot is a human decision).
6. Logs: `journalctl -u japanfold -u cloudflared-japanfold --since "31 min ago" -p warning`; `~/.aiand-bio/jobs/_cluster/{workers,controller}.log`; `~/.aiand-bio/events.jsonl` (`job_rejected` / errors); newest failed-job `run.log`s.
7. Checkpoints: corrupt ckpt self-heals (atomic re-fetch + integrity check); persistently corrupt = upstream HF → alert, don't loop.

## Autonomy boundary (conservative)

- Auto-fix: restart a dead service (drain first), free disk, soft-reset a wedged chip via the ladder, re-fetch a corrupt checkpoint, let the supervisor handle dropped workers.
- NEVER autonomous: full host reboot, anything that drops the whole box, killing a worker mid-op (wedges the chip — cardinal sin).

## Real lifetime behavior (Jun 29 → Jul 12; 77 sweeps, 4 alerts; from `maintenance.jsonl`)

- 72 `healthy`, 1 `anomaly`, 4 `known_degraded_unchanged`. Almost all sweeps are clean (log only, no alert).
- **The one real anomaly (2026-07-06 22:23):** detected 1/32 workers down (device/slot tt27) after that day's deploy restarts. Diagnosed root cause: both `japanfold.service` restarts triggered a systemd mass-SIGKILL fallback (400-800+ leftover procs killed forcefully instead of graceful SIGTERM), which wedged chip 27 mid-teardown (it then failed to init 10×/<1 min, deterministic). The agent attempted ONE safe `japanfold.service` restart (verified no jobs active first → no mid-op kill), did NOT recover the slot, and **stopped there** — did NOT attempt a 3rd restart or a tt-smi chip reset (past incidents show soft resets can fail → host reboot, which it won't do autonomously). Alerted Moritz for the decision (tt-smi reset vs maintenance-window reboot). Tracked `known_degraded_unchanged` across subsequent sweeps. Resolved by a **user-initiated host reboot** on 2026-07-08 ~00:06 → back to 32/32; agent confirmed the boltzgen empty-design-mask fix was deployed+live post-reboot.
- Other alerts: 2 test alerts (Jun 29, confirming the Telegram channel), 1 post-reboot validation (Jun 29).

## CURRENT STATE (observed live 2026-07-12 ~18:40 UTC+2)

- **The on-box agent is currently WEDGED and not supervising.** `agent.out` shows the last `claude` exit at `2026-07-12T09:41:03`; it respawned at 09:41:24 and is now stuck at a **Claude Code folder-trust dialog** ("Yes, I trust this folder / No, exit / Enter to confirm"). `--dangerously-skip-permissions` does NOT bypass the folder-trust dialog (a separate prompt), so a Claude Code update that re-required folder trust wedged the session. The 12:24 sweep was correctly SKIPPED (`sweep.sh`: "agent busy/not-ready after wait"). So the on-box agent has been non-functional for ~9.5 h and counting — this is itself a fragility of the live-LLM-on-box design.
- **The platform itself is fully healthy:** `japanfold` + `cloudflared-japanfold` active; `/api/cluster` → `online_workers: 32`, `total_workers: 32`, `controller_alive: true`, `runs.ok: 12`, `jobs.ok: 20`; `https://japanfold.com/api/health` → `{"service":"aiand-bio","status":"ok"}`; disk 242 GB free (93 % used, normal).
- `cust-team` has **passwordless full sudo** (`(ALL) NOPASSWD: ALL`), so a pc-driven ssh script CAN `sudo systemctl restart` services on the box. `tt-smi` at `/usr/local/bin/tt-smi`.
- `~/.aiand-bio/events.jsonl` event types: `server_started`×15, `job_submitted`×98, `job_started`×98, `job_rejected`×10, `job_done`×97, `job_canceled`×5, `job_killed`×1. Last event 2026-07-11 20:40.

## What needs on-box residency vs. pc-driven (Step 2 design input)

- **Everything the sweep does is reachable over ssh** (`systemctl`, `curl localhost:8090`, `df`, `journalctl`, `tt-smi`, `events.jsonl`). Restarts work via passwordless sudo. Nothing requires sub-second reaction (the old cadence was 6 h; the box sits fine between sweeps). Nothing requires surviving the ssh-tunnel being down: the platform's public reachability is via `cloudflared` (independent of the ssh tunnel), and the existing pc `~/.japanfold-watchdog/check.sh` already detects public down/recovery hourly via the public URL — and if the box is fully off-net, the on-box agent's Telegram can't get out either. So on-box residency buys nothing for alerting.
- **The LLM judgment the agent exercised** (diagnosing the tt27 wedge, deciding not to attempt a 3rd restart / chip reset) is, under the conservative boundary, exactly the case where it alerted Moritz and waited. A deterministic pc-driven sweep + alert covers that path: detect the anomaly, alert Moritz, let him decide. No 24/7 LLM session needed. (If richer LLM diagnosis is later wanted, the coworker orchestrator can spawn a one-shot worker on alert — out of scope here; the deterministic sweep + alert is the replacement.)

## Implication for cutover risk

The on-box agent is the "only thing supervising" only in theory — right now it is wedged and supervising nothing, and the platform has been fine for 9.5 h unsupervised. Cutover risk is lower than the task feared, but the GATED cutover (Telegram Moritz, get go-ahead) still applies because it's a live public service and stopping the unit is hard to reverse if the replacement has a gap.
