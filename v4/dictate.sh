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
LOGFILE="${DICTATE_LOG:-$HOME/.claude-local/hammerspoon/dictate.log}"
MAX_SECONDS="${DICTATE_MAX_SECONDS:-300}"

# Minimum RMS amplitude to count as speech. Measured on this mic: room silence
# = 0.000154, normal speech = 0.0578 (a 375x gap), so 0.003 is far from both.
MIN_RMS="${DICTATE_MIN_RMS:-0.003}"
MIN_BYTES=8000  # ~0.25s of 16kHz mono 16-bit PCM (32000 B/s), incl. 44-byte header

CORPUS_DIR="${DICTATE_CORPUS:-$HSDIR/corpus}"
# Fraction of *unchanged* utterances to keep, as 1-in-N. Changed ones are always
# kept; without a sample of the unchanged ones there is no way to see errors that
# both the recognizer and the corrector missed.
CORPUS_SAMPLE_N="${DICTATE_CORPUS_SAMPLE:-20}"
FIXSTATUS="/tmp/hs_dictate_fix.json"

# The log records full transcripts, which are as sensitive as anything the user
# dictates (student records, IRB material). Create it owner-only and cap it,
# instead of leaving a world-readable file that grows without bound.
log() {
    [ "${DICTATE_DEBUG:-0}" = "1" ] || return 0
    if [ ! -e "$LOGFILE" ]; then
        (umask 077; : >> "$LOGFILE")
    fi
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
# -b 16: rec defaults to 32-bit, which is 4 bytes/sample for no benefit -- the
# recognizer takes 16-bit and the corpus below stores these clips. Halves both
# the byte-size gate arithmetic below and the corpus footprint.
rec -q -b 16 "$WAVFILE" rate 16k channels 1 trim 0 "$MAX_SECONDS" 2>/dev/null &
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
STT_ERROR=0  # a real engine failure, as opposed to genuine silence

# Primary: macOS 26 Speech (offline, no API key, no token cost).
if [ -x "$MAC_STT" ]; then
    RESULT=$("$MAC_STT" "$WAVFILE" "$LOCALE" 2>/dev/null)
    MAC_RC=$?
    if [ "$MAC_RC" -eq 2 ]; then
        log "mac-stt: no speech"
        exit 2
    fi
    if [ "$MAC_RC" -ne 0 ]; then
        log "mac-stt failed rc=$MAC_RC, trying whisper"
        STT_ERROR=1
    fi
fi

# Fallback: local whisper (older macOS, or locale asset missing).
if [ -z "$RESULT" ] && [ -f "$WHISPER_MODEL" ]; then
    WLANG="${LOCALE%%-*}"
    RESULT=$(whisper-cli -m "$WHISPER_MODEL" -f "$WAVFILE" -l "$WLANG" \
                --no-timestamps 2>/dev/null)
    log "whisper fallback used"
fi

# Flatten to a single line and strip control characters.
#
# This must run on whatever is about to be pasted, which is why it is a function
# called again after the correction step rather than a one-off here. init.lua
# pastes the result into whatever window had focus, terminals included: a
# multi-line paste executes every line but the last wherever bracketed paste is
# off (older shells, some TUIs), and \r does it even where bracketed paste is on.
# tr '\n' alone does not catch \r.
sanitize() {
    printf '%s' "$1" \
        | tr '\n\r\t' '   ' \
        | tr -d '\000-\010\013\014\016-\037\177' \
        | sed 's/  */ /g; s/^ *//; s/ *$//'
}

RESULT=$(sanitize "$RESULT")

if [ -z "$RESULT" ]; then
    # Same principle as the missing-`rec` check above: a broken engine reported
    # as "no speech" sends the user hunting for a mic problem. Only claim
    # silence when the engine actually ran and found none.
    if [ "$STT_ERROR" -eq 1 ]; then
        log "mac-stt errored and no whisper fallback available"
        print -u2 "dictate: speech engine failed (see dictate.log)"
        exit 1
    fi
    log "empty result"
    exit 2
fi

# Restore English words the ko-KR engine wrote in Hangul ("앤서 키" -> "answer key").
# The engine is locale-locked and macOS 26 ships no code-switching locale, so this
# cannot be fixed engine-side; running a second en-US pass does not work either,
# because on Korean audio it returns either nothing or fluent nonsense, giving no
# signal for picking a winner. Costs ~0.7s and ~$0.4/month.
#
# fail-open: dictate-fix.py echoes its input on any failure, so a network outage
# degrades to v3 behaviour instead of losing the dictation. Guard the assignment
# anyway in case the script itself is missing or unrunnable.
RAW_RESULT="$RESULT"  # kept for the corpus record: what the recognizer alone produced
rm -f "$FIXSTATUS"
if [ "${DICTATE_FIX:-1}" = "1" ] && [ -f "$HSDIR/dictate-fix.py" ]; then
    # v6: the corrector also gets the audio (to hear the English the ko-KR
    # engine wrote in Hangul) and the context init.lua captured at record start.
    FIXED=$(printf '%s' "$RESULT" | DICTATE_AUDIO="$WAVFILE" DICTATE_CTX_FILE="/tmp/hs_dictate.ctx" \
        /usr/bin/python3 "$HSDIR/dictate-fix.py" 2>/dev/null)
    # Sanitize again: the model's output is the thing that actually gets pasted,
    # and a rule-5 violation (answering instead of correcting) is exactly the
    # case that produces multi-line text.
    FIXED=$(sanitize "$FIXED")
    if [ -n "$FIXED" ]; then
        RESULT="$FIXED"
    else
        log "fix step returned empty; keeping raw transcript"
    fi
fi

log "OK: $RESULT"

# Corpus capture, for the review loop that feeds the substitution glossary.
#
# Sampled, not exhaustive: nobody reviews 150 clips a day, and a queue that
# outgrows the reviewer stops being reviewed at all. Keep every utterance the
# corrector touched (or tried to and had rejected), plus 1-in-N of the untouched
# ones so that errors *both* stages missed remain visible.
if [ "${DICTATE_CORPUS_OFF:-0}" != "1" ]; then
    FIX_CHANGED=0
    FIX_REJECTED=0
    if [ -f "$FIXSTATUS" ]; then
        grep -q '"changed": *true' "$FIXSTATUS" && FIX_CHANGED=1
        grep -q '"rejected": *true' "$FIXSTATUS" && FIX_REJECTED=1
    fi

    KEEP=0
    [ "$FIX_CHANGED" -eq 1 ] && KEEP=1
    [ "$FIX_REJECTED" -eq 1 ] && KEEP=1
    if [ "$KEEP" -eq 0 ] && [ $((RANDOM % CORPUS_SAMPLE_N)) -eq 0 ]; then
        KEEP=1
    fi

    if [ "$KEEP" -eq 1 ]; then
        DAY=$(date '+%Y-%m-%d')
        STAMP=$(date '+%H%M%S')
        OUTDIR="$CORPUS_DIR/$DAY"
        # umask must cover sox too, not just mkdir: these clips are recordings of
        # everything dictated, so they are owner-only like the log and the audio.
        umask 077
        mkdir -p "$OUTDIR"
        # FLAC is lossless and ~2.2x smaller than the 16-bit WAV.
        if sox "$WAVFILE" "$OUTDIR/$STAMP.flac" 2>/dev/null; then
            RAW_FOR_JSON="${RAW_RESULT:-$RESULT}"
            (umask 077
             /usr/bin/python3 -c '
import json, sys
path, raw, fixed, changed, rejected = sys.argv[1:6]
json.dump({"raw": raw, "fixed": fixed, "truth": None,
           "changed": changed == "1", "rejected": rejected == "1",
           "reviewed": False},
          open(path, "w"), ensure_ascii=False, indent=1)
' "$OUTDIR/$STAMP.json" "$RAW_FOR_JSON" "$RESULT" "$FIX_CHANGED" "$FIX_REJECTED" 2>/dev/null)
            log "corpus: $DAY/$STAMP (changed=$FIX_CHANGED rejected=$FIX_REJECTED)"
        fi
    fi
fi

printf '%s' "$RESULT"
