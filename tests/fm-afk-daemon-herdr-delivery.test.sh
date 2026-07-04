#!/usr/bin/env bash
# tests/fm-afk-daemon-herdr-delivery.test.sh - regression suite for incident
# LOM-119 (afk-daemon-herdr-delivery): away-mode supervision silently dead
# under the herdr backend.
#
# The failure it pins down: firstmate entered /afk inside a herdr pane. The
# daemon's supervisor discovery and startup validation were tmux-only, so with
# no $TMUX_PANE it fell back to the tmux target firstmate:0, the probe failed,
# and the daemon exited 1 at startup. Because /afk launched it fire-and-forget
# (`nohup ... >/dev/null 2>&1 &`), that exit vanished; the daemon owns the
# watcher during afk, so no watcher ran either, the liveness beacon went stale,
# and a crewmate's captain-relevant `done:` wake sat stranded in
# state/.wake-queue until the captain typed "Still alive?".
#
# Covered contracts, each in an isolated FM_STATE_OVERRIDE temp home (never the
# live fleet), against a fake `herdr` CLI (the fm-backend-herdr.test.sh
# convention) and a failing `tmux` stub that simulates "no tmux server":
#
#   1. Herdr delivery (the regression): a daemon launched with only herdr's
#      env markers (HERDR_ENV=1, HERDR_PANE_ID, no TMUX_PANE) starts, and a
#      captain-relevant status is delivered to the herdr pane as one
#      sentinel-prefixed digest - not stranded and not silently dropped.
#   2. Loud startup failure: with NO resolvable supervisor endpoint the daemon
#      exits non-zero AND leaves durable evidence
#      (state/.subsuper-startup-failed).
#   3. fm-afk-arm.sh honesty: FAILED (non-zero, evidence surfaced) when the
#      daemon cannot start; started -> healthy -> --stop lifecycle when it can.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
AFK_ARM="$ROOT/bin/fm-afk-arm.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-herdr)

DAEMON_PID=
ARM_PID=
cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then kill "$DAEMON_PID" 2>/dev/null || true; fi
  if [ -n "${ARM_PID:-}" ]; then kill "$ARM_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_all EXIT

# make_herdr_env <name>: an isolated case dir with a state home, a stateful fake
# `herdr` CLI, and a failing `tmux` stub. The fake herdr answers the calls the
# daemon's herdr arm makes (status, pane get, pane read, send-text, send-keys,
# agent get),
# logs every invocation unit-separated to $dir/herdr.log, and models the
# structural composer row current herdr submit verification reads.
make_herdr_env() {  # <name> -> echoes case dir
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  : > "$dir/herdr.log"
  printf 'idle prompt\n│ ❯ │\n' > "$dir/pane-content"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
LOG="$dir/herdr.log"
CONTENT="$dir/pane-content"
{
  printf 'HERDR_SESSION=%s' "\${HERDR_SESSION:-}"
  for a in "\$@"; do printf '\x1f%s' "\$a"; done
  printf '\n'
} >> "\$LOG"
case "\${1:-} \${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  "pane read")
    cat "\$CONTENT"
    ;;
  "pane send-text")
    text="\${!#}"
    printf 'idle prompt\n│ ❯ %s │\n' "\$text" > "\$CONTENT"
    ;;
  "pane send-keys")
    # Enter consumes the composer, leaving the structural composer row empty.
    # The adapter must confirm that row, not merely observe a raw pane delta.
    lines=\$(wc -l < "\$CONTENT" 2>/dev/null || echo 0)
    printf 'idle prompt\nsubmitted %s\n│ ❯ │\n' "\$lines" > "\$CONTENT"
    ;;
  "agent get")
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# No tmux server anywhere (the LOM-119 runtime): every tmux call fails.
[ -n "${FM_FAKE_TMUX_DELAY:-}" ] && sleep "$FM_FAKE_TMUX_DELAY"
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# run_in_env <dir> <herdr:0|1> <cmd...>: run a command with the case's fakebin
# first on PATH, the isolated state home, BOTH runtimes' env markers scrubbed
# (the test runner itself may live inside tmux or herdr - LOM-119's own runtime
# leaked HERDR_PANE_ID into an early version of this suite), and, when asked,
# herdr's markers set explicitly - the environment firstmate actually has inside
# a herdr pane. Daemon knobs are tightened so the suite runs in seconds.
run_in_env() {
  local dir=$1 herdr=$2
  shift 2
  local -a markers=()
  local -a extra_env=()
  if [ "$herdr" = 1 ]; then
    markers=(HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_SESSION=default)
  fi
  [ -n "${FM_FAKE_TMUX_DELAY:-}" ] && extra_env=(FM_FAKE_TMUX_DELAY="$FM_FAKE_TMUX_DELAY")
  env -u TMUX -u TMUX_PANE -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$dir/state" \
    "${markers[@]:-_FM_UNUSED=1}" \
    "${extra_env[@]}" \
    FM_ESCALATE_BATCH_SECS=0 \
    FM_HOUSEKEEPING_TICK=1 \
    FM_POLL=1 \
    FM_SIGNAL_GRACE=1 \
    FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 \
    FM_STALE_ESCALATE_SECS=999999 \
    FM_INJECT_CONFIRM_SLEEP=0.1 \
    "$@"
}

wait_for() {  # <tries> <sleep> <cmd...>
  local tries=$1 sleep_s=$2 i=0
  shift 2
  while [ "$i" -lt "$tries" ]; do
    "$@" && return 0
    sleep "$sleep_s"
    i=$((i + 1))
  done
  return 1
}

# --- 1. the regression: herdr delivery ---------------------------------------
# Before the fix the daemon exited at startup here (tmux-only validation), so
# this test both reproduces the incident (it fails on the old code) and pins the
# fixed behavior: the captain-relevant status reaches the herdr pane as one
# sentinel-prefixed digest.

test_herdr_delivery() {
  local dir state
  dir=$(make_herdr_env delivery)
  state="$dir/state"
  date '+%s' > "$state/.afk"

  run_in_env "$dir" 1 "$DAEMON" >"$dir/daemon.out" 2>"$dir/daemon.err" &
  DAEMON_PID=$!

  wait_for 30 0.2 test -f "$state/.supervise-daemon.ready" || {
    sed 's/^/  daemon.err: /' "$dir/daemon.err" >&2
    fail "herdr delivery: daemon did not start under herdr env markers (the LOM-119 silent death)"
  }
  [ "$(cat "$state/.supervise-daemon.ready" 2>/dev/null)" = "$(cat "$state/.supervise-daemon.pid" 2>/dev/null)" ] \
    || fail "herdr delivery: readiness marker does not match the daemon pid"
  [ ! -e "$state/.subsuper-startup-failed" ] \
    || fail "herdr delivery: startup-failed marker present despite a live herdr endpoint"

  # A crewmate finishing while the captain is away.
  echo "done: committed dashboard lifecycle boundary guard b1d94a0b" > "$state/lom-119.status"

  # The watcher child fires a signal wake; classification escalates; batch=0
  # flushes immediately through the herdr adapter.
  wait_for 60 0.5 grep -q 'Supervisor escalate' "$dir/herdr.log" || {
    sed 's/^/  daemon.err: /' "$dir/daemon.err" >&2
    fail "herdr delivery: captain-relevant status never reached the herdr pane"
  }

  # The digest went through pane send-text, sentinel-prefixed, and was followed
  # by a verified Enter submit. In the log a line reads
  # HERDR_SESSION=default<US>pane<US>send-text<US>w1:p2<US><MARK>Supervisor ...,
  # so the digest argument starting with the FM_INJECT_MARK sentinel shows as
  # two consecutive 0x1f bytes (field separator, then marker) before the text.
  local send_line
  send_line=$(grep 'send-text' "$dir/herdr.log" | grep 'Supervisor escalate' | head -1)
  [ -n "$send_line" ] \
    || fail "herdr delivery: digest was not sent via 'pane send-text'"
  case "$send_line" in
    *$'\x1f\x1f'"Supervisor escalate"*) ;;
    *) fail "herdr delivery: digest argument does not start with the sentinel marker (0x1f)" ;;
  esac
  wait_for 20 0.2 grep -q 'send-keys' "$dir/herdr.log" \
    || fail "herdr delivery: no Enter was sent to submit the digest"

  # Delivered = buffer cleared, no wedge alarm: the wake is not stranded.
  wait_for 20 0.2 test ! -s "$state/.subsuper-escalations" \
    || fail "herdr delivery: escalation buffer still holds the digest after delivery"
  [ ! -e "$state/.subsuper-inject-wedged" ] \
    || fail "herdr delivery: wedge alarm raised despite successful delivery"

  # The durable queue still holds the wake record for firstmate's catch-up
  # drain (enqueue-before-suppress; nothing lost) - but unlike the incident,
  # it is a delivered record, not a stranded one.
  grep -q 'lom-119' "$state/.wake-queue" 2>/dev/null \
    || fail "herdr delivery: the signal wake was never enqueued to .wake-queue"

  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=

  # The daemon's per-iteration liveness probe must stay read-only: across the
  # whole run (startup validation + every ~1s pane-gone guard) it must never
  # have launched `herdr server` as a probe side effect.
  ! grep -q $'\x1f''server' "$dir/herdr.log" \
    || fail "herdr delivery: the daemon launched 'herdr server' - the liveness probe is not read-only"
  pass "herdr delivery: captain-relevant status delivered to the herdr pane as one sentinel digest"
}

# --- 2. loud startup failure with durable evidence ---------------------------

test_startup_failure_is_loud() {
  local dir state rc
  dir=$(make_herdr_env no-endpoint)
  state="$dir/state"
  date '+%s' > "$state/.afk"

  run_in_env "$dir" 0 "$DAEMON" >"$dir/daemon.out" 2>"$dir/daemon.err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "startup failure: daemon exited 0 with no resolvable supervisor endpoint"
  assert_contains "$(cat "$dir/daemon.err")" "supervisor target" \
    "startup failure should name the unresolvable supervisor target on stderr"
  [ -e "$state/.subsuper-startup-failed" ] \
    || fail "startup failure: no durable .subsuper-startup-failed evidence marker"
  assert_contains "$(cat "$state/.subsuper-startup-failed")" "does not resolve" \
    "startup-failed marker should say why the daemon could not start"
  [ ! -f "$state/.supervise-daemon.pid" ] \
    || fail "startup failure: pid file left behind by a dead daemon"
  [ ! -f "$state/.supervise-daemon.ready" ] \
    || fail "startup failure: readiness marker left behind by a dead daemon"
  pass "startup failure: daemon exits non-zero and leaves a durable startup-failed marker"
}

# --- 3. fm-afk-arm.sh: FAILED is loud, started/healthy/stop are honest -------

test_arm_failed_is_loud() {
  local dir out rc
  dir=$(make_herdr_env arm-failed)
  date '+%s' > "$dir/state/.afk"

  out=$(FM_FAKE_TMUX_DELAY=0.6 run_in_env "$dir" 0 "$AFK_ARM")
  rc=$?
  [ "$rc" -ne 0 ] || fail "arm FAILED: fm-afk-arm.sh exited 0 though the daemon could not start"
  assert_contains "$out" "daemon: FAILED" \
    "arm should print the honest FAILED line when the daemon dies at startup"
  assert_not_contains "$out" "daemon: started" \
    "arm must not report started before supervisor endpoint validation completes"
  pass "arm FAILED: an unstartable daemon is reported loudly with a non-zero exit"
}

test_arm_lifecycle() {
  local dir state out
  dir=$(make_herdr_env arm-lifecycle)
  state="$dir/state"
  date '+%s' > "$state/.afk"

  # started: the arm launches the daemon, confirms it, and stays attached.
  run_in_env "$dir" 1 "$AFK_ARM" >"$dir/arm.out" 2>&1 &
  ARM_PID=$!
  wait_for 40 0.25 grep -q 'daemon: started pid=' "$dir/arm.out" || {
    sed 's/^/  arm.out: /' "$dir/arm.out" >&2
    fail "arm lifecycle: no 'daemon: started' confirmation"
  }
  [ "$(cat "$state/.supervise-daemon.ready" 2>/dev/null)" = "$(cat "$state/.supervise-daemon.pid" 2>/dev/null)" ] \
    || fail "arm lifecycle: readiness marker does not match the daemon pid"

  # healthy: a second arm sees the live daemon and does not start another.
  out=$(run_in_env "$dir" 1 "$AFK_ARM")
  expect_code 0 $? "a second arm against a live daemon should exit 0"
  assert_contains "$out" "daemon: healthy pid=" \
    "a second arm should report the live daemon as healthy"

  # stop: home-scoped, via this home's pid file + lock only.
  out=$(run_in_env "$dir" 1 "$AFK_ARM" --stop)
  expect_code 0 $? "--stop should exit 0"
  assert_contains "$out" "daemon: stopped pid=" "--stop should report the stopped pid"
  wait "$ARM_PID" 2>/dev/null
  ARM_PID=
  assert_contains "$(cat "$dir/arm.out")" "daemon: stopped (clean shutdown)" \
    "the attached arm should report the daemon's clean shutdown"
  [ ! -f "$state/.supervise-daemon.pid" ] \
    || fail "arm lifecycle: pid file survives a --stop"
  [ ! -f "$state/.supervise-daemon.ready" ] \
    || fail "arm lifecycle: readiness marker survives a --stop"

  # stop again: nothing to do, still honest.
  out=$(run_in_env "$dir" 1 "$AFK_ARM" --stop)
  expect_code 0 $? "--stop with no daemon should exit 0"
  assert_contains "$out" "daemon: not running" "--stop with no daemon should say so"
  pass "arm lifecycle: started -> healthy -> stopped, all verified and home-scoped"
}

test_herdr_delivery
test_startup_failure_is_loud
test_arm_failed_is_loud
test_arm_lifecycle

echo "all afk-daemon-herdr-delivery tests passed"
