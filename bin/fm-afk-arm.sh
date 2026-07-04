#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the away-mode sub-supervisor daemon
# (bin/fm-supervise-daemon.sh), with honest verification - the daemon's
# counterpart to bin/fm-watch-arm.sh, born from the same failure mode.
#
# WHY THIS EXISTS (incident LOM-119 / afk-daemon-herdr-delivery): the /afk skill
# used to start the daemon with `nohup ... >/dev/null 2>&1 &` - fire-and-forget.
# When the daemon exited at startup (under herdr its supervisor-endpoint probe
# was tmux-only and always failed), both the non-zero exit and the stderr error
# vanished. Because the daemon owns the watcher while state/.afk exists, its
# silent death meant NO watcher, a stale liveness beacon, and captain-relevant
# wakes stranded in state/.wake-queue until the captain happened to type.
# Reliability requires the same discipline the watcher already has: launch
# through a mechanism that SURVIVES the call and NOTIFIES on exit (the
# harness's tracked background task), and VERIFY the outcome before settling in.
#
# Run this as the harness's OWN tracked background task, standalone, never
# bundled onto the tail of another command and never with a shell `&` inside
# another call. It forks the daemon as a tracked child, confirms the daemon
# genuinely holds this home's singleton lock and has published its post-startup
# readiness marker, and prints exactly one unambiguous status line:
#   daemon: started pid=<N>          - it launched one and confirmed it
#   daemon: healthy pid=<N>          - a genuinely live daemon already held the lock
#   daemon: FAILED - <reason>        - could not confirm one (exits non-zero)
# On started, this stays attached (`wait`) for the daemon's whole life, so a
# later daemon death completes the tracked task and re-notifies firstmate
# instead of passing unnoticed. The daemon's stdout/stderr are captured to
# state/.supervise-daemon.err so a failure always leaves readable evidence
# (alongside the daemon's own durable state/.subsuper-startup-failed marker).
#
# --stop: stop ONLY this FM_HOME's daemon (the pid recorded in THIS home's
# state/.supervise-daemon.pid, cross-checked against the lock). It resolves and
# signals exactly that pid, so it can never touch another home's daemon. NEVER
# `pkill -f fm-supervise-daemon.sh`: secondmate homes run the same script.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"
LOCK="$STATE/.supervise-daemon.lock"
PIDFILE="$STATE/.supervise-daemon.pid"
READYFILE="$STATE/.supervise-daemon.ready"
ERRFILE="$STATE/.supervise-daemon.err"
STARTUP_FAILED="$STATE/.subsuper-startup-failed"
# How long to wait for a freshly forked daemon to validate its supervisor
# endpoint and acquire the lock. The herdr probe may ensure a server first
# (bounded at ~10s inside the adapter), so this sits above that.
CONFIRM_TIMEOUT=${FM_AFK_ARM_CONFIRM_TIMEOUT:-15}

# A daemon is addressable iff the pidfile names a live process AND the singleton
# lock's owner pid agrees. This is enough for home-scoped --stop, but not enough
# to claim startup succeeded: the daemon publishes lock+pid before it validates
# the supervisor endpoint.
ADDRESSABLE_PID=
addressable_daemon() {
  local pid lock_pid
  ADDRESSABLE_PID=
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  ADDRESSABLE_PID=$pid
  return 0
}

# A daemon is "healthy" iff pidfile, lock, live pid, and readiness marker all
# agree. Sets HEALTHY_PID on success. This is the honesty gate: this script
# never reports a daemon that is only in its pre-validation startup window.
HEALTHY_PID=
healthy_daemon() {
  local ready_pid
  HEALTHY_PID=
  addressable_daemon || return 1
  ready_pid=$(cat "$READYFILE" 2>/dev/null || true)
  [ "$ready_pid" = "$ADDRESSABLE_PID" ] || return 1
  HEALTHY_PID=$ADDRESSABLE_PID
  return 0
}

failure_evidence() {
  if [ -s "$STARTUP_FAILED" ]; then
    sed 's/^/  /' "$STARTUP_FAILED"
  fi
  [ -s "$ERRFILE" ] && tail -5 "$ERRFILE" | sed 's/^/  /'
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --stop) mode=stop ;;
  *) echo "usage: $(basename "$0") [--stop]" >&2; exit 2 ;;
esac

if [ "$mode" = stop ]; then
  # Home-scoped stop: only the daemon pid recorded in THIS home's pidfile,
  # and only when this home's lock agrees it is the daemon. Readiness is not
  # required for stop: a daemon caught during startup is still this home's
  # addressable process and should be stoppable.
  if addressable_daemon; then
    stop_pid=$ADDRESSABLE_PID
    kill -TERM "$stop_pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 50 ] && fm_pid_alive "$stop_pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    if fm_pid_alive "$stop_pid"; then
      echo "daemon: FAILED - pid $stop_pid did not exit within 5s of SIGTERM"
      exit 1
    fi
    rm -f "$READYFILE" 2>/dev/null || true
    echo "daemon: stopped pid=$stop_pid"
  else
    rm -f "$READYFILE" 2>/dev/null || true
    echo "daemon: not running"
  fi
  exit 0
fi

# If a genuinely live daemon already holds the lock, do not start a second one -
# the singleton would refuse anyway. Report it honestly and return success.
if healthy_daemon; then
  echo "daemon: healthy pid=$HEALTHY_PID"
  exit 0
fi

# Start the daemon as a tracked child and confirm it before settling in. The
# child stays our child for its whole life: we wait on it, so its eventual exit
# (crash, --stop, captain-return shutdown) completes this tracked task and the
# harness re-notifies firstmate.
child=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

: > "$ERRFILE" 2>/dev/null || true
"$DAEMON" >>"$ERRFILE" 2>&1 &
child=$!

# Verify the outcome: poll until this child is the confirmed lock-holding
# daemon, or until some other daemon legitimately holds the singleton (a
# startup race), or until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_daemon; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "daemon: started pid=$child"
      wait "$child"
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "daemon: stopped (clean shutdown)"
      else
        echo "daemon: DIED rc=$rc - see $STATE/.supervise-daemon.log and $ERRFILE; re-arm with bin/fm-afk-arm.sh"
        err_tail
      fi
      exit "$rc"
    fi
    # Another daemon won the singleton; our child stood down. Report the live one.
    echo "daemon: healthy pid=$HEALTHY_PID"
    wait "$child" 2>/dev/null || true
    exit 0
  fi
  if ! fm_pid_alive "$child"; then
    wait "$child" 2>/dev/null
    rc=$?
    trap - HUP TERM INT
    echo "daemon: FAILED - exited rc=$rc during startup (see $ERRFILE)"
    failure_evidence
    exit 1
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "daemon: FAILED - no confirmed daemon within ${CONFIRM_TIMEOUT}s (see $ERRFILE)"
failure_evidence
cleanup_child
wait "$child" 2>/dev/null || true
exit 1
