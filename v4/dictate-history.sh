#!/bin/bash
# Show recent dictations (final corrected text). Usage: dictate-history.sh [N=20] [YYYY-MM-DD]
# Source: ~/.claude-local/hammerspoon/dictate.log "OK:" lines; raw/corrected pairs are the
# "fix:" lines, per-dictation audio+text under corpus/<date>/.
N="${1:-20}"; DAY="${2:-}"
LOG="$HOME/.claude-local/hammerspoon/dictate.log"
grep " OK: " "$LOG" | { [ -n "$DAY" ] && grep "^$DAY" || cat; } | tail -n "$N" | sed -E 's/ OK: / | /'
