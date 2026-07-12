# STATUS — japanfold-galaxy-agent-integration (2026-07-12 ~19:50 UTC+2)

## ACTIVE OUTAGE (I caused) — needs Moritz to resolve

During the Step 3 synthetic detection test, I ran
`sudo systemctl stop cloudflared-japanfold` on UF-EV-A13-GWH02. That cloudflared
connector serves BOTH the public site AND `ssh.japanfold.com`, so stopping it cut
SSH to the box (locking me out) AND took japanfold.com down. `japanfold.service`
+ the 32-device fleet stayed up the whole time — only the tunnel is down.

- Public URL: `https://japanfold.com` → HTTP 530 (Cloudflare "origin unreachable").
- SSH `japanfold-ssh`: dead (`websocket: bad handshake` / `Connection closed`).
-cloudflared-japanfold has `Restart=on-failure`; a clean `systemctl stop` does NOT
  trigger it, so it stays down until someone starts it.
- I cannot recover it: no tailscale on the box, the `galaxy` box can't reach it
  (different network, no DNS for UF-EV-A13-GWH02), and the cloudflared tunnel was
  my only path in.
- Sent Moritz TWO Telegram alerts (19:19 + 19:32) with the one-line recovery cmd.

**Recovery (any shell on the box — console/IPMI/Moritz's own ssh):**
```
sudo systemctl start cloudflared-japanfold
```
Verify from pc after: `ssh japanfold-ssh 'systemctl is-active cloudflared-japanfold'`
and `curl -fsS https://japanfold.com/api/health`.

## What IS done (survives the outage)

- **`~/.coworker/japanfold-sweep.sh`** — the pc-driven replacement, built + deployed.
  Validated: real clean sweep on the live box (run 4 → healthy log, no alert,
  ~3.6 s), AND all 6 anomaly decision branches via `JF_SWEEP_FAKE_STATE` self-test
  (cloudflared-down, disk-low, local-health-sick, journald-warnings, device-errors
  alert-only no-reset, fleet<32 across 2 sweeps). Boundary: auto-fix only dead
  service restart + low-disk cleanup; everything else alert-only; NEVER reboot /
  kill-mid-op / reset-chips.
- **`~/.coworker/docs/japanfold-galaxy-agent-integration.md`** — written + deployed
  (DONE_CHECK `test -s` passes, 130 lines). Worktree `docs/` copy too.
- **`ANALYSIS.md`** — full Step 1 analysis (real observation of the old on-box
  agent: units, RUNBOOK, maintenance.jsonl, live tmux).
- Branch `wk/japanfold-galaxy-agent-integration` committed (907530b) + pushed.

## What is NOT done (resume here after the box is back)

1. **Confirm recovery:** SSH + public site back, 32/32 workers, japanfold.service
   up. (The platform itself never went down — only the tunnel.)
2. **Install cron:** add `*/15 * * * * /home/moritz/.coworker/japanfold-sweep.sh
   >/dev/null 2>&1` to pc crontab. Do this AFTER the box is back so the first cron
   run is a clean healthy sweep (not an ssh-unreachable alert).
3. **Step 4 cutover (GATED):** send Moritz the Telegram summary (Step 1 findings +
   what was built + ask go-ahead to stop the on-box agent). He already has the
   outage context. Only after his go-ahead: `ssh japanfold-ssh 'sudo systemctl
   disable --now japanfold-agent.service japanfold-agent-sweep.timer'` and verify
   `japanfold.service` / `cloudflared-japanfold.service` stay active.
   NOTE: the on-box agent was ALREADY wedged (folder-trust dialog, non-supervising
   since 09:41) before any of this, so stopping it changes nothing operationally.

## Lessons (already baked into the script + doc)

- Never `systemctl stop cloudflared-japanfold` for a test — it carries SSH too.
  The sweep only ever *restarts a DEAD* cloudflared, never stops a live one. Use
  `JF_SWEEP_FAKE_STATE` for detection-branch validation (zero box impact).
- A loose device-error grep matched a benign `BrokenPipeError` and triggered a
  32-chip `tt-smi -glx_reset_auto` (platform recovered cleanly). Fixed: device
  pattern tightened to explicit hardware-failure strings; chip reset is now
  alert-only, NEVER automatic.
