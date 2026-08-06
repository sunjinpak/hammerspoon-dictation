#!/bin/zsh
# Dictation pipeline v3: record -> macOS 26 SpeechTranscriber (offline, no API).
#
# Why v3: the macOS 26 Speech engine is ~4.5x faster than whisper-cli on this
# machine (0.35s vs 1.56s), needs no model file, and returns empty on silence
# instead of hallucinating ("감사합니다"). whisper-cli stays as the fallback for
# older macOS or if the locale asset is missing.
#
# Exit codes: 0 = text on stdout, 2 = no speech, 1 = error.
# Env: DICTATE_LOCALE (default ko-KR), DICTATE_WHISPER_MODEL, DICTATE_DEBUG=1
#
# NOTE: no angle-bracket wrapping here; init.lua decides that per target app.

set -u

# Hammerspoon runs this with a minimal PATH (/bin:/usr/bin:/usr/ucb:/usr/local/bin)
# and does not read ~/.zshrc or ~/.zprofile, so Homebrew tools (rec, sox,
# whisper-cli) are invisible unless we add them explicitly. Absolute paths below
# make the script independent of the caller's environment.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

HSDIR="${0:A:h}"
WAVFILE="${DICTATE_WAV:-/tmp/hs_dictate.wav}"
PIDFILE="${DICTATE_PIDFILE:-/tmp/hs_dictate.pid}"
LOCALE="${DICTATE_LOCALE:-ko-KR}"
MAC_STT="$HSDIR/mac-stt"
WHISPER_MODEL="${DICTATE_WHISPER_MODEL:-$HOME/whisper-models/ggml-large-v3-turbo.bin}"
LOGFILE="${DICTATE_LOG:-$HSDIR/dictate.log}"
MAX_SECONDS="${DICTATE_MAX_SECONDS:-300}"

# Minimum RMS amplitude to count as speech. Measured on this mic: room silence
# = 0.000154, normal speech = 0.0578 (a 375x gap), so 0.003 is far from both.
MIN_RMS="${DICTATE_MIN_RMS:-0.003}"
MIN_BYTES=8000  # ~0.25s of 16kHz mono 16-bit PCM, incl. 44-byte header

log() {
    [ "${DICTATE_DEBUG:-0}" = "1" ] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"
}

# A missing tool must not masquerade as "no speech" - that sent the user hunting
# for a mic problem when the real cause was PATH.
if ! command -v rec >/dev/null 2>&1; then
    log "FATAL: rec not found (PATH=$PATH)"
    print -u2 "dictate: rec (SoX) not found"
    exit 1
fi

# Stale artifacts must go before recording: if `rec` fails to open the device we
# must NOT fall through and re-transcribe the previous recording as if it were new.
rm -f "$WAVFILE" "$PIDFILE"

# Record until SIGINT from init.lua. The PID file lets init.lua signal this exact
# process instead of pattern-matching with pkill, which loses the signal when the
# user double-taps before `rec` has spawned.
rec -q "$WAVFILE" rate 16k channels 1 trim 0 "$MAX_SECONDS" 2>/dev/null &
REC_PID=$!
printf '%s' "$REC_PID" > "$PIDFILE"
wait $REC_PID 2>/dev/null
rm -f "$PIDFILE"

if [ ! -s "$WAVFILE" ]; then
    log "no wav produced"
    exit 2
fi

BYTES=$(/usr/bin/stat -f%z "$WAVFILE" 2>/dev/null || echo 0)
if [ "$BYTES" -lt "$MIN_BYTES" ]; then
    log "too short: ${BYTES}B"
    exit 2
fi

# Energy gate. Both engines invent text from near-silence, and no model-side
# setting reliably suppresses it, so gate before transcribing.
RMS=$(sox "$WAVFILE" -n stat 2>&1 | awk '/RMS[[:space:]]+amplitude/ {print $NF}')

# A gate that silently disables itself is worse than no gate: it turns a hard
# failure into hallucinated text pasted into the user's document. If sox does not
# yield a parseable number, fall back to peak amplitude, then to a byte-size
# heuristic, and log loudly either way.
if ! printf '%s' "$RMS" | grep -qE '^[0-9]+\.?[0-9]*([eE][-+]?[0-9]+)?$'; then
    log "WARN: RMS unparseable ('$RMS'), trying peak amplitude"
    RMS=$(sox "$WAVFILE" -n stat 2>&1 | awk '/Maximum[[:space:]]+amplitude/ {print $NF}')
    if ! printf '%s' "$RMS" | grep -qE '^[0-9]+\.?[0-9]*([eE][-+]?[0-9]+)?$'; then
        # No usable energy measure. Require a longer clip (~1.5s) before trusting
        # it, since hallucination is worst on very short near-silent input.
        log "WARN: no energy measure available; byte-size fallback (${BYTES}B)"
        if [ "$BYTES" -lt 48000 ]; then
            log "silence gate (byte fallback): ${BYTES}B < 48000"
            exit 2
        fi
        RMS=""
    else
        # Peak runs ~5-10x higher than RMS on speech, so scale the threshold.
        MIN_RMS=$(awk -v m="$MIN_RMS" 'BEGIN {print m * 5}')
        log "using peak amplitude with threshold $MIN_RMS"
    fi
fi

if [ -n "$RMS" ]; then
    if awk -v r="$RMS" -v m="$MIN_RMS" 'BEGIN {exit !(r < m)}'; then
        log "silence gate: rms=$RMS < $MIN_RMS"
        exit 2
    fi
fi

RESULT=""

# Primary: macOS 26 Speech (offline, no API key, no token cost).
if [ -x "$MAC_STT" ]; then
    RESULT=$("$MAC_STT" "$WAVFILE" "$LOCALE" 2>/dev/null)
    MAC_RC=$?
    if [ "$MAC_RC" -eq 2 ]; then
        log "mac-stt: no speech"
        exit 2
    fi
    [ "$MAC_RC" -ne 0 ] && log "mac-stt failed rc=$MAC_RC, trying whisper"
fi

# Fallback: local whisper (older macOS, or locale asset missing).
if [ -z "$RESULT" ] && [ -f "$WHISPER_MODEL" ]; then
    WLANG="${LOCALE%%-*}"
    RESULT=$(whisper-cli -m "$WHISPER_MODEL" -f "$WAVFILE" -l "$WLANG" \
                --no-timestamps 2>/dev/null)
    log "whisper fallback used"
fi

# Collapse to one line; the caller pastes this verbatim.
RESULT=$(printf '%s' "$RESULT" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

if [ -z "$RESULT" ]; then
    log "empty result"
    exit 2
fi

log "OK: $RESULT"
printf '%s' "$RESULT"
