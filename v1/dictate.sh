#!/bin/zsh
# Dictation pipeline: record -> whisper (local) -> Gemini correction
source ~/.zprofile 2>/dev/null

WAVFILE="/tmp/hs_dictate.wav"
MODEL="$HOME/whisper-models/ggml-large-v3-turbo.bin"
LANG="${DICTATE_LANG:-ko}"

# Record audio (stopped by SIGINT from Hammerspoon)
rec "$WAVFILE" rate 16k channels 1 2>/dev/null || true

# Step 1: Local Whisper transcription (~2-3s on Apple Silicon)
RAW=$(whisper-cli -m "$MODEL" -f "$WAVFILE" -l "$LANG" --no-timestamps 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

if [ -z "$RAW" ]; then
    exit 1
fi

# Step 2: Gemini text correction (fixes proper nouns, homophones, etc.)
RESULT=$(python3 ~/.hammerspoon/dictate-fix.py "$RAW" 2>/dev/null)

# Fallback to raw whisper output if Gemini fails
if [ -z "$RESULT" ]; then
    RESULT="$RAW"
fi

echo -n "$RESULT" | pbcopy
echo "$RESULT"
