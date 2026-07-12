#!/usr/bin/env bash
# japanfold-sweep.sh — periodic JapanFold-prod health check + safe auto-fix, driven
# FROM pc over `ssh japanfold-ssh`. Replaces the on-box `japanfold-agent.service`
# (a 24/7 resumed Claude session) with a deterministic, $0/sweep bash loop.
#
# Cadence: every 15 min via cron on pc (24x tighter than the old 6h on-box agent).
# Boundary (conservative — stricter than the old RUNBOOK's chip ladder): auto-fix
# ONLY restarting a DEAD service (cloudflared always; japanfold only when truly
# down, never while alive, to avoid the systemd SIGKILL wedge) and freeing disk.
# Chip/device issues and log/job anomalies ALERT ONLY — an unattended deterministic
# script never reboots, never kills a worker mid-op, never resets 32 chips. Those
# are a human call (exactly what the old agent did on its one real chip incident).
#
# Alerting: ~/.coworker/tg.sh send (same Telegram chat Moritz already uses). A
# fully clean sweep is logged to sweep.jsonl only (signal, not spam). Standing
# anomalies re-notify every 6h (matches the existing uptime watchdog). Public-URL
# DOWN/RECOVERY is owned by ~/.japanfold-watchdog/check.sh; this sweep owns the
# on-box + fleet + logs layer (and restarts cloudflared if its service dies).
set -u
D="$HOME/.coworker"
ST="$D/state/japanfold"; mkdir -p "$ST/notify"
LOG="$ST/sweep.jsonl"
SSH="ssh -o ConnectTimeout=20 -o BatchMode=yes -n japanfold-ssh"   # one-shot commands (no stdin)
SSH_IN="ssh -o ConnectTimeout=20 -o BatchMode=yes japanfold-ssh"   # heredoc check (needs stdin; NO -n)
RENOTIFY=$((6*3600))
ts(){ date '+%Y-%m-%dT%H:%M:%S'; }
now=$(date +%s)

# Alert (and record locally so it's never lost). Dedup: re-notify a standing issue
# at most once per RENOTIFY window; new issues alert immediately. Set
# JF_SWEEP_DRYRUN=1 to log + take fix actions but skip the Telegram send (validation).
alert(){
  local key="$1" msg="$2"; local f="$ST/notify/$key" last=0
  [ -f "$f" ] && last=$(cat "$f" 2>/dev/null || echo 0)
  if [ $((now - last)) -ge $RENOTIFY ] || [ "$last" = 0 ]; then
    [ "${JF_SWEEP_DRYRUN:-0}" = 1 ] || bash "$D/tg.sh" send "🛠 JapanFold sweep: $msg" 2>/dev/null
    echo "$now" > "$f"
  fi
  python3 - "$msg" >>"$LOG" 2>/dev/null <<'PY'
import sys,json,time
print(json.dumps({"ts":time.strftime("%Y-%m-%dT%H:%M:%S"),"event":"alert","detail":sys.argv[1]}))
PY
}
log_sweep(){ python3 - "$1" >>"$LOG" 2>/dev/null <<'PY'
import sys,json,time
print(json.dumps({"ts":time.strftime("%Y-%m-%dT%H:%M:%S"),"event":"sweep","status":sys.argv[1]}))
PY
}

# --- run all remote checks in ONE ssh round-trip, emit KEY=VALUE lines ---
# JF_SWEEP_FAKE_STATE: self-test mode. Set to a multi-line KEY=VALUE payload to
# bypass the real ssh check and run the decision/alert logic against a synthetic
# state (fix-action ssh calls are stubbed, so zero box impact). Used to validate
# every alert branch without touching the live box.
FAKE=0
if [ -n "${JF_SWEEP_FAKE_STATE:-}" ]; then
  raw="$JF_SWEEP_FAKE_STATE"; FAKE=1
else
raw=$($SSH_IN 'bash -s' <<'REMOTE' 2>/dev/null
b64(){ base64 -w0 2>/dev/null || base64; }
echo "SVC_JP=$(systemctl is-active japanfold 2>/dev/null)"
echo "SVC_CF=$(systemctl is-active cloudflared-japanfold 2>/dev/null)"
c=$(curl -s -m10 localhost:8090/api/cluster 2>/dev/null)
if [ -n "$c" ]; then
  echo "ONLINE=$(printf %s "$c" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("online_workers",-1))' 2>/dev/null)"
  echo "TOTAL=$(printf %s "$c" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("total_workers",-1))' 2>/dev/null)"
  echo "RUNS_RUNNING=$(printf %s "$c" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("runs") or {}).get("running",0))' 2>/dev/null)"
  echo "CTRL_ALIVE=$(printf %s "$c" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin).get("controller_alive") else 0)' 2>/dev/null)"
else
  echo "ONLINE=-1"; echo "TOTAL=-1"; echo "RUNS_RUNNING=-1"; echo "CTRL_ALIVE=0"
fi
echo "LOCAL_HEALTH=$(curl -s -m10 localhost:8090/api/health 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo unreachable)"
echo "DISK_FREE_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4);print $4}')"
# journald warnings: drop the "-- No entries --" / "-- No journal files --" banners
jw=$(journalctl -u japanfold -u cloudflared-japanfold --since "31 min ago" -p warning --no-pager 2>/dev/null | grep -vE '^-- ' | tail -20)
echo "JWARN=$(printf '%s' "$jw" | grep -c .)"
echo "JWARN_LINES=$(printf '%s' "$jw" | b64)"
# recent (31 min) failed/rejected jobs from events.jsonl + device-related errors
since=$(date -d '31 min ago' +%s 2>/dev/null)
ev=$(python3 -c '
import sys,json
since=int(sys.argv[1]); out=[]
try:
  for line in open("/home/cust-team/.aiand-bio/events.jsonl"):
    try: o=json.loads(line)
    except: continue
    if o.get("t",0)<since: continue
    e=o.get("event","")
    if e=="job_rejected": out.append("rejected: "+str(o.get("error") or o.get("job"))[:120])
    elif e=="job_done" and o.get("status")!="succeeded": out.append("failed: "+str(o.get("job"))[:20]+" err="+str(o.get("error") or "")[:120])
except Exception: pass
print("\n".join(out))
' "$since" 2>/dev/null)
echo "JOB_ANOM=$(printf '%s' "$ev" | grep -c .)"
echo "JOB_LINES=$(printf '%s' "$ev" | b64)"
# device/hardware errors in cluster logs (TIGHT: explicit hardware-failure strings
# only — NOT generic Python exceptions or code lines containing the word "error".
# A benign BrokenPipeError or a {"error":...} code line must NOT trip a chip alert.)
de=$(grep -iE 'wedg|uninitpci|uninit_pci|0 boards|arc is stuck|device (lost|dropped|wedge)|chip (lost|dropped|wedge|fail)|tenstorrent.*(error|fail)|tt-smi.*fail|hardware error|EIO' ~/.aiand-bio/jobs/_cluster/workers.log ~/.aiand-bio/jobs/_cluster/controller.log 2>/dev/null | tail -15)
echo "DEV_ERR=$(printf '%s' "$de" | grep -c .)"
echo "DEV_ERR_LINES=$(printf '%s' "$de" | b64)"
REMOTE
)
fi
ssh_rc=$?

if [ "$FAKE" = 0 ] && { [ "$ssh_rc" != 0 ] || [ -z "$raw" ]; }; then
  alert "ssh" "ssh japanfold-ssh unreachable — cannot run sweep (tunnel/network down?). Public uptime is still watched by the pc watchdog."
  exit 0
fi

# --- parse remote output (only lines that look like KEY=...) ---
declare -A R
while IFS='=' read -r k v; do
  case "$k" in SVC_JP|SVC_CF|ONLINE|TOTAL|RUNS_RUNNING|CTRL_ALIVE|LOCAL_HEALTH|DISK_FREE_GB|JWARN|JWARN_LINES|JOB_ANOM|JOB_LINES|DEV_ERR|DEV_ERR_LINES) R[$k]="$v";; esac
done <<< "$raw"

jb64decode(){ printf '%s' "$1" | base64 -d 2>/dev/null; }
# runfix: execute a fix ssh command for real, UNLESS in fake-state self-test mode.
runfix(){ if [ "$FAKE" = 1 ]; then echo "[fake] $*"; else $SSH "$@" 2>/dev/null; fi; }
# readfix: a read-only ssh probe (tt-smi board count etc); stubbed in fake mode.
readfix(){ if [ "$FAKE" = 1 ]; then echo "FAKE"; else $SSH "$@" 2>/dev/null; fi; }

findings=(); actions=()

# 1) services. Restart ONLY a truly-dead service (is-active != active). A dead
#    japanfold has no running workers (process gone), so there's nothing to SIGKILL —
#    the systemd-SIGKILL wedge only happens when RESTARTING a live japanfold, which
#    this script never does. If SVC_JP is active but sick, that's caught at step 3.
if [ "${R[SVC_JP]:-}" != "active" ]; then
  runfix 'sudo systemctl restart japanfold' && actions+=("restarted japanfold (was ${R[SVC_JP]})")
  alert "svc_jp" "japanfold service was ${R[SVC_JP]} — restarted. Verify it came back (32/32, site ok)."
fi
if [ "${R[SVC_CF]:-}" != "active" ]; then
  runfix 'sudo systemctl restart cloudflared-japanfold' && actions+=("restarted cloudflared-japanfold (was ${R[SVC_CF]})")
  alert "svc_cf" "cloudflared-japanfold was ${R[SVC_CF]} — restarted (public site was down until it came back)."
fi

# 2) fleet (online workers). Persist <32 across 2 sweeps before alerting (transient respawn guard).
prev_online=$(cat "$ST/last_online" 2>/dev/null || echo "")
echo "${R[ONLINE]:--1}" > "$ST/last_online"
if [ "${R[ONLINE]:--1}" != "-1" ] && [ "${R[TOTAL]:-0}" != "-1" ] && [ "${R[ONLINE]}" -lt "${R[TOTAL]}" ] 2>/dev/null; then
  if [ "$prev_online" != "" ] && [ "$prev_online" -lt "${R[TOTAL]}" ] 2>/dev/null; then
    findings+=("online_workers ${R[ONLINE]}/${R[TOTAL]} across 2 sweeps (supervisor did not recover)")
    alert "fleet" "workers ${R[ONLINE]}/${R[TOTAL]} for 2 sweeps — a device may have dropped. Site still serves at reduced capacity. (Not rebooting; past incidents show restart can wedge chips via SIGKILL.)"
  else
    findings+=("online_workers ${R[ONLINE]}/${R[TOTAL]} this sweep (1st — waiting 2nd before alerting)")
  fi
fi

# 3) local platform health (public URL is the watchdog's job)
if [ "${R[LOCAL_HEALTH]:-}" != "ok" ]; then
  findings+=("localhost:8090/api/health = ${R[LOCAL_HEALTH]} (platform not serving healthy)")
  alert "local_health" "platform local /api/health = ${R[LOCAL_HEALTH]} (japanfold service may be sick even if systemd says active)."
fi

# 4) disk (absolute free GB, not %)
if [ "${R[DISK_FREE_GB]:-999}" -lt 20 ] 2>/dev/null; then
  runfix 'rm -rf /tmp/tt-bio-* 2>/dev/null; [ -f /tmp/aiand_serve.log ] && [ "$(stat -c %s /tmp/aiand_serve.log)" -gt 1073741824 ] && truncate -s 0 /tmp/aiand_serve.log; df -BG / | awk "NR==2{print \$4\" free\"}"'
  actions+=("freed disk (cleared /tmp/tt-bio-*, truncated huge /tmp/aiand_serve.log)")
  alert "disk" "disk free ${R[DISK_FREE_GB]} GB (< 20 GB threshold) — cleared stale /tmp + truncated huge serve log. Check ~/.aiand-bio/jobs eviction."
fi

# 5) journald warnings
if [ "${R[JWARN]:-0}" -gt 0 ] 2>/dev/null; then
  jl=$(jb64decode "${R[JWARN_LINES]}")
  findings+=("journald warnings (31 min): ${R[JWARN]} — $jl")
  alert "jwarn" "journald warnings in last 31 min (${R[JWARN]}): $(printf '%s' "$jl" | tail -3 | tr '\n' ' | ')"
fi

# 6) job anomalies (rejected / failed)
if [ "${R[JOB_ANOM]:-0}" -gt 0 ] 2>/dev/null; then
  jl=$(jb64decode "${R[JOB_LINES]}")
  findings+=("job anomalies (31 min): ${R[JOB_ANOM]} — $jl")
  alert "jobs" "job rejected/failed in last 31 min (${R[JOB_ANOM]}): $(printf '%s' "$jl" | tail -3 | tr '\n' ' | ')"
fi

# 7) device/hardware errors → ALERT ONLY (report tt-smi board count). Never auto-reset
#    chips: a deterministic unattended script must not reset 32 chips on a live prod
#    box — the old agent's one real chip incident also alerted + waited for a human
#    decision (soft resets can fail → host reboot, which is a human call). The
#    online_workers<32 check (step 2) already catches a dropped worker; this catches
#    explicit wedge/ARC strings in the logs.
if [ "${R[DEV_ERR]:-0}" -gt 0 ] 2>/dev/null; then
  dl=$(jb64decode "${R[DEV_ERR_LINES]}")
  boards=$(readfix 'tt-smi -ls 2>/dev/null | grep -ciE "^┃ *[0-9]" || echo 0')
  findings+=("device/hardware error strings in cluster logs (31 min): ${R[DEV_ERR]} — $dl")
  alert "chip" "hardware error in cluster logs (31 min): $(printf '%s' "$dl" | tail -2 | tr '\n' ' | '). tt-smi boards=$boards. NOT auto-resetting (unattended reset of 32 chips is too risky). If a chip is ARC-stuck (0 boards), it needs a manual host reboot — your call."
fi

# --- conclude ---
if [ ${#findings[@]} -eq 0 ] && [ ${#actions[@]} -eq 0 ]; then
  log_sweep "healthy (svc=${R[SVC_JP]}/${R[SVC_CF]} workers=${R[ONLINE]}/${R[TOTAL]} health=${R[LOCAL_HEALTH]} disk=${R[DISK_FREE_GB]}GB jwarn=${R[JWARN]} jobanom=${R[JOB_ANOM]} deverr=${R[DEV_ERR]})"
  rm -f "$ST"/notify/* 2>/dev/null   # clear standing-issue notify timers when fully clean
else
  printf '%s\0' "${findings[@]}" > "$ST/.f"; printf '%s\0' "${actions[@]}" > "$ST/.a"
  python3 - "$ST/.f" "$ST/.a" >>"$LOG" 2>/dev/null <<'PY'
import sys,json,time
def rd(p):
    try: return [x for x in open(p,'rb').read().split(b'\0') if x]
    except: return []
print(json.dumps({"ts":time.strftime("%Y-%m-%dT%H:%M:%S"),"event":"sweep","status":"anomaly",
                  "findings":[x.decode() for x in rd(sys.argv[1])],
                  "actions":[x.decode() for x in rd(sys.argv[2])]}))
PY
  rm -f "$ST/.f" "$ST/.a"
fi
exit 0
