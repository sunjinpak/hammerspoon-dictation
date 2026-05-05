#!/bin/zsh
# Dictation pipeline v2: record -> 3 parallel whispers (ko/en/auto) -> Gemini merge
# Designed for code-switched (Korean + English) speech.
source ~/.zprofile 2>/dev/null

WAVFILE="/tmp/hs_dictate.wav"
MODEL="$HOME/whisper-models/ggml-large-v3-turbo.bin"

KO_OUT="/tmp/hs_dictate_ko.txt"
EN_OUT="/tmp/hs_dictate_en.txt"
AUTO_OUT="/tmp/hs_dictate_auto.txt"

# Record audio (stopped by SIGINT from Hammerspoon)
rec "$WAVFILE" rate 16k channels 1 2>/dev/null || true

# Step 1: Run 3 whisper transcriptions in parallel
#   -l ko   : Korean-locked (English will be mangled into Hangul)
#   -l en   : English-locked (Korean will be mangled into roman letters)
#   -l auto : Whisper picks one dominant language for the whole clip
whisper-cli -m "$MODEL" -f "$WAVFILE" -l ko   --no-timestamps 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$KO_OUT" &
PID_KO=$!
whisper-cli -m "$MODEL" -f "$WAVFILE" -l en   --no-timestamps 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$EN_OUT" &
PID_EN=$!
whisper-cli -m "$MODEL" -f "$WAVFILE" -l auto --no-timestamps 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$AUTO_OUT" &
PID_AUTO=$!

wait $PID_KO $PID_EN $PID_AUTO

KO=$(cat "$KO_OUT")
EN=$(cat "$EN_OUT")
AUTO=$(cat "$AUTO_OUT")

if [ -z "$KO" ] && [ -z "$EN" ] && [ -z "$AUTO" ]; then
    exit 1
fi

# Step 2: Gemini merges 3 transcripts into the most accurate code-switched output
RESULT=$(python3 ~/.hammerspoon/dictate-fix.py "$KO" "$EN" "$AUTO" 2>/dev/null)

# Fallback chain if Gemini fails: auto -> ko -> en
if [ -z "$RESULT" ]; then
    RESULT="${AUTO:-${KO:-$EN}}"
fi

echo -n "$RESULT" | pbcopy
echo "$RESULT"
