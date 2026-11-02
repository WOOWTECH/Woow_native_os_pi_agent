#!/usr/bin/env bash
# Stress a tmux binary the way Omnigent drives it, and count server aborts.
#
#   tests/tmux-stress.sh <tmux> [seconds=300]
#
# WHY
#
# tmux issue 5385: on macOS, calloc(3) sometimes returns a large allocation that
# is not zeroed, and a tmux on the system allocator then aborts now and then --
# mostly on entering copy mode -- taking every session on that server with it.
# The bundled tmux is built with jemalloc as the default malloc zone for that
# reason (scripts/build-macos-tmux.sh). This drives the paths that allocate the
# most, on one private server configured the way Omnigent runs it (own socket,
# no config file, history-limit 50000, C.UTF-8):
#
#   - panes that fill their whole 50000-line history with wide CJK lines,
#   - split / kill / respawn churn,
#   - repeated copy-mode entries that walk the full history (top, search,
#     bottom) -- the path the abort reports name,
#   - full-history captures and the odd clear-history.
#
# A server that dies is counted as an abort, any crash report it left is noted,
# and a fresh server is started, so one run can show more than one abort.
# Exit status: 0 when the server never died, 1 otherwise.
set -u

BIN="${1:?usage: tests/tmux-stress.sh <tmux> [seconds]}"
DURATION="${2:-300}"
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }

# The socket path must fit in sun_path (104 bytes on macOS), so keep it short.
S="$(mktemp -d /private/tmp/tst.XXXXXX)"
REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
REPORTS="${REAL_HOME:-$HOME}/Library/Logs/DiagnosticReports"
MARK="$S/start-marker"; : > "$MARK"

T() { env -i HOME="$S" PATH=/usr/bin:/bin TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        "$BIN" -S "$S/sock" -f /dev/null "$@"; }
# 60000 lines, each wider than a narrow pane and carrying double-width
# characters, so every pane's 50000-line history is full and wraps.
FILL="awk 'BEGIN{for(i=1;i<=60000;i++) printf \"%06d 台灣報告 歷史紀錄 history line %d\\n\", i, i}'; exec cat"

start_server() {
  T set-option -g history-limit 50000 \; new-session -d -s st -x 220 -y 60 "$FILL"
  sleep 1
  SERVER_PID="$(T display-message -p '#{pid}' 2>/dev/null)"
}

iterations=0 splits=0 kills=0 respawns=0 copymodes=0 captures=0 clears=0 aborts=0
abort_times=""
start_server
first_pid="$SERVER_PID"
end=$(( $(date +%s) + DURATION ))

while [ "$(date +%s)" -lt "$end" ]; do
  iterations=$((iterations + 1))
  panes=()
  while IFS= read -r p; do panes+=("$p"); done < <(T list-panes -s -t st -F '#{pane_id}' 2>/dev/null)
  n=${#panes[@]}

  if [ "$n" -lt 6 ]; then
    if [ $((iterations % 2)) -eq 0 ]; then dir=-h; else dir=-v; fi
    T split-window -d "$dir" -t st "$FILL" \; select-layout -t st tiled >/dev/null 2>&1 && splits=$((splits + 1))
  elif [ "$n" -gt 1 ]; then
    T kill-pane -t "${panes[$((RANDOM % n))]}" \; select-layout -t st tiled >/dev/null 2>&1 && kills=$((kills + 1))
  fi

  if [ "$n" -gt 0 ]; then
    target="${panes[$((RANDOM % n))]}"
    if [ $((iterations % 3)) -eq 0 ]; then
      T respawn-pane -k -t "$target" "$FILL" >/dev/null 2>&1 && respawns=$((respawns + 1))
    fi
    target="${panes[$((RANDOM % n))]}"
    T copy-mode -t "$target" \; send-keys -t "$target" -X history-top \
      \; send-keys -t "$target" -X search-backward "4242" \
      \; send-keys -t "$target" -X history-bottom \
      \; send-keys -t "$target" -X cancel >/dev/null 2>&1 && copymodes=$((copymodes + 1))
    target="${panes[$((RANDOM % n))]}"
    T capture-pane -p -S - -t "$target" >/dev/null 2>&1 && captures=$((captures + 1))
    if [ $((iterations % 10)) -eq 0 ]; then
      T clear-history -t "${panes[$((RANDOM % n))]}" >/dev/null 2>&1 && clears=$((clears + 1))
    fi
  fi

  if ! T has-session -t st 2>/dev/null; then
    aborts=$((aborts + 1))
    abort_times="$abort_times $(date '+%H:%M:%S')(pid $SERVER_PID)"
    echo "server died at iteration $iterations (pid $SERVER_PID); starting a new one" >&2
    sleep 2
    start_server
  fi
done

footprint="$(footprint -p "$SERVER_PID" 2>/dev/null | awk '/phys_footprint:/{print $2, $3; exit}')"
T kill-server 2>/dev/null
reports="$(find "$REPORTS" -name 'tmux*' -newer "$MARK" 2>/dev/null | wc -l | tr -d ' ')"

echo "binary:      $BIN"
echo "duration:    ${DURATION}s, first server pid $first_pid"
echo "iterations:  $iterations (splits $splits, kills $kills, respawns $respawns, copy-mode entries $copymodes, full captures $captures, clear-history $clears)"
echo "footprint:   ${footprint:-unknown} (last server, at the end)"
echo "crash reports since start: $reports"
echo "RESULT: aborts=$aborts${abort_times:+ at$abort_times}"
rm -rf "$S"
[ "$aborts" -eq 0 ]
