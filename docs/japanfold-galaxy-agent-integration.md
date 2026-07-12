# JapanFold Galaxy agent — moved off-box into the coworker system

JapanFold production runs on a dedicated Galaxy (`UF-EV-A13-GWH02`, 32 Tenstorrent
devices), reachable from pc via `ssh japanfold-ssh`. It used to carry its own
autonomous maintenance agent running 24/7 directly on the production box. That
agent has been replaced by a deterministic, cron-driven sweep run from this pc.
This doc records what the old agent did, what replaced it, how to verify the new
mechanism, and how to roll back.

## What the old on-box agent actually did

(From reading the systemd units, the RUNBOOK, the agent's tmux session, and its
`maintenance.jsonl` history — real observation, not assumption.)

- **`japanfold-agent.service`** (systemd, `Restart=always`) kept a tmux session
  alive that ran a resumed Claude Code session (`claude --resume <session>
  --model claude-sonnet-5 --dangerously-skip-permissions`) in a respawn loop.
- **`japanfold-agent-sweep.timer`** fired every 6 h, injecting a sweep prompt
  into that tmux pane — but only when the pane was byte-stable (idle at the
  claude prompt), so it didn't garble a mid-task run.
- Each sweep checked: the two services (`japanfold`, `cloudflared-japanfold`),
  the 32-device fleet (`/api/cluster` → `online_workers`), public reachability
  (`https://japanfold.com/api/health`), disk (absolute free GB, not %), chips
  (only if a job hit a device error), and the logs (journald warnings,
  `~/.aiand-bio/jobs/_cluster/{workers,controller}.log`, `~/.aiand-bio/events.jsonl`,
  failed-job `run.log`s). It auto-fixed only safe things and alerted via Telegram
  on any anomaly; a clean sweep was logged only.
- **Real lifetime (Jun 29 → Jul 12, 77 sweeps, 4 alerts):** almost all sweeps
  were clean. The one real incident (2026-07-06): it detected 1/32 workers down
  (device tt27) after deploy restarts, diagnosed the root cause (systemd
  mass-SIGKILL during restart wedged chip 27), attempted one safe restart,
  **stopped short of a chip reset or reboot**, and alerted Moritz for the
  decision. Resolved by a user-initiated host reboot on 2026-07-08.

**Why move it off the box:** a live LLM session is a fragile supervisor. The
checks are all reachable over ssh and need no sub-second reaction (cadence was
6 h), so a deterministic pc-driven sweep covers them at $0/sweep. And on
2026-07-12 the on-box agent was found wedged at a Claude Code folder-trust
dialog (a Claude update re-required trust; `--dangerously-skip-permissions`
doesn't bypass that dialog) — it had been supervising nothing for ~9.5 h,
which is the fragility made concrete.

## What replaced it

A single bash script, **`~/.coworker/japanfold-sweep.sh`**, run from pc via cron
every 15 min (24× tighter than the old 6 h agent). It does all checks in one ssh
round-trip (`ssh japanfold-ssh`), reuses the existing `~/.coworker/tg.sh` for
Telegram alerts (same chat Moritz already uses), and logs every sweep to
`~/.coworker/state/japanfold/sweep.jsonl` (same shape as the old
`maintenance.jsonl`).

**Boundary (stricter than the old RUNBOOK's chip ladder):** it auto-fixes only
- restarting a **dead** `cloudflared-japanfold` or `japanfold` service (never a
  live one — a dead service has no workers to SIGKILL; the systemd-SIGKILL wedge
  only happens when *restarting a running* japanfold, which this script never does), and
- freeing disk below ~20 GB (clear stale `/tmp/tt-bio-*`, truncate a huge
  `/tmp/aiand_serve.log`).

Everything else — a dropped worker (`online_workers < 32` across two sweeps), a
sick platform (`/api/health != ok`), journald warnings, rejected/failed jobs, a
device/hardware error string in the logs — **alerts only**. It never reboots,
never kills a worker mid-op, and never resets chips. That matches what the old
agent actually did on its one real chip incident (alerted + waited for a human
decision); an unattended deterministic script resetting 32 chips on a live box
is too risky.

**Layering with the existing uptime watchdog:** `~/.japanfold-watchdog/check.sh`
(hourly system cron) still owns public-URL DOWN/RECOVERY detection. The sweep
owns the on-box + fleet + logs layer and restarts cloudflared if its service
dies. The two cover each other without double-alerting on the public URL.

### Self-test modes (no box impact)

- `JF_SWEEP_DRYRUN=1` — log + take fix actions, but skip the Telegram send.
- `JF_SWEEP_FAKE_STATE=$'SVC_JP=active\n...'` — run the decision/alert logic
  against a synthetic KEY=VALUE state, stubbing all fix-action ssh calls. Used to
  validate every alert branch without touching the live box.

## How to verify it's working

```bash
# one real sweep against the live box (logs to sweep.jsonl, alerts on anomaly)
bash ~/.coworker/japanfold-sweep.sh

# tail the sweep log
tail ~/.coworker/state/japanfold/sweep.jsonl

# confirm cron is installed (every 15 min)
crontab -l | grep japanfold-sweep
```

A healthy sweep logs one line like
`{"event":"sweep","status":"healthy (svc=active/active workers=32/32 health=ok disk=242GB ...)"}`.
An anomaly logs an `alert` line + an `anomaly` sweep line, and sends a Telegram
message. Standing anomalies re-notify every 6 h; a return to healthy clears the
notify timers.

To exercise a branch safely (no box impact):
```bash
JF_SWEEP_DRYRUN=1 JF_SWEEP_FAKE_STATE=$'SVC_JP=active\nSVC_CF=inactive\nONLINE=32\nTOTAL=32\nRUNS_RUNNING=0\nCTRL_ALIVE=1\nLOCAL_HEALTH=ok\nDISK_FREE_GB=242\nJWARN=0\nJWARN_LINES=\nJOB_ANOM=0\nJOB_LINES=\nDEV_ERR=0\nDEV_ERR_LINES=' bash ~/.coworker/japanfold-sweep.sh
```

## Rollback (re-enable the on-box agent)

The old unit files are still on the box under `/etc/systemd/system/`. If the new
mechanism turns out to miss something important, restore the on-box agent:

```bash
ssh japanfold-ssh 'sudo systemctl enable --now japanfold-agent.service japanfold-agent-sweep.timer'
```

Then disable the pc-side sweep cron (`crontab -l | grep -v japanfold-sweep | crontab -`).
The platform services (`japanfold.service`, `cloudflared-japanfold.service`) are
untouched by either side of this change.

## Incident log (transparency)

- **2026-07-12, during validation:** I ran `sudo systemctl stop cloudflared-japanfold`
  as a synthetic detection test. That cloudflared connector serves **both** the
  public site **and** `ssh.japanfold.com`, so stopping it also cut SSH to the box
  (locking me out) and took japanfold.com down briefly. Moritz was alerted
  immediately and restored it. Lesson learned: the sweep script only ever
  *restarts a dead* cloudflared — it never *stops* a live one, and no live
  service-stop should be used to test it. The safe `JF_SWEEP_FAKE_STATE` self-test
  mode was added so detection branches can be validated with zero box impact.
- An earlier buggy run of the sweep matched a benign `BrokenPipeError` as a
  "device error" and ran `tt-smi -glx_reset_auto`, which reset all 32 chips. The
  platform recovered cleanly (32/32, site ok), but the device-error pattern was
  tightened to explicit hardware-failure strings only, and chip reset is now
  **alert-only, never automatic**.
