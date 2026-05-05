#!/bin/bash
set -e

echo "=== Hammerspoon Dictation Installer ==="
echo ""

# ---- Parse args ----
VERSION="v2"
for arg in "$@"; do
    case "$arg" in
        --version=v1|-v1) VERSION="v1" ;;
        --version=v2|-v2) VERSION="v2" ;;
        -h|--help)
            echo "Usage: ./install.sh [--version=v1|--version=v2]"
            echo "  v1 (default-of-original): single whisper -l ko + Gemini correction"
            echo "  v2 (default now)        : 3-way parallel whisper (ko/en/auto) + Gemini merge"
            exit 0
            ;;
    esac
done

if [ ! -d "$(dirname "$0")/$VERSION" ]; then
    echo "Error: version folder '$VERSION' not found."
    exit 1
fi

echo "Installing pipeline version: $VERSION"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: This tool only works on macOS."
    exit 1
fi

# Check Homebrew
if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew is required. Install from https://brew.sh"
    exit 1
fi

# Install dependencies
echo "[1/4] Installing dependencies..."
brew install sox 2>/dev/null || true
brew install whisper-cpp 2>/dev/null || true

if ! command -v hammerspoon &>/dev/null; then
    echo "  -> Installing Hammerspoon..."
    brew install --cask hammerspoon 2>/dev/null || true
fi

# Download Whisper model
MODEL_DIR="$HOME/whisper-models"
MODEL_FILE="$MODEL_DIR/ggml-large-v3-turbo.bin"

if [ ! -f "$MODEL_FILE" ]; then
    echo "[2/4] Downloading Whisper large-v3-turbo model (~1.5 GB)..."
    mkdir -p "$MODEL_DIR"
    curl -L -o "$MODEL_FILE" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
else
    echo "[2/4] Whisper model already exists, skipping download."
fi

# Copy files to ~/.hammerspoon/
echo "[3/4] Setting up Hammerspoon config ($VERSION)..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
mkdir -p "$HS_DIR"

# Back up existing init.lua if it exists and isn't ours
if [ -f "$HS_DIR/init.lua" ]; then
    if ! grep -q "Hammerspoon Dictation" "$HS_DIR/init.lua" 2>/dev/null; then
        echo "  -> Backing up existing init.lua to init.lua.backup"
        cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.backup"
    fi
fi

cp "$SCRIPT_DIR/init.lua" "$HS_DIR/init.lua"
cp "$SCRIPT_DIR/$VERSION/dictate.sh" "$HS_DIR/dictate.sh"
cp "$SCRIPT_DIR/$VERSION/dictate-fix.py" "$HS_DIR/dictate-fix.py"
chmod +x "$HS_DIR/dictate.sh"

# Config file
if [ ! -f "$HS_DIR/dictate-config.json" ]; then
    cp "$SCRIPT_DIR/config.example.json" "$HS_DIR/dictate-config.json"
    echo "  -> Created dictate-config.json (edit with your personal context)"
else
    echo "  -> dictate-config.json already exists, skipping."
fi

# Check for Gemini API key
echo ""
echo "[4/4] Checking environment..."
if [ -z "$GEMINI_API_KEY" ]; then
    echo ""
    echo "  GEMINI_API_KEY not set. Add to your shell profile:"
    echo ""
    echo "    export GEMINI_API_KEY=\"your-api-key-here\""
    echo ""
    echo "  Get a free key at: https://aistudio.google.com/apikey"
    echo "  Without it, dictation still works but skips LLM correction/merge."
fi

echo ""
echo "=== Installation complete ($VERSION)! ==="
echo ""
echo "Switch versions later by running:  ./install.sh --version=v1   (or v2)"
echo ""
echo "Next steps:"
echo "  1. Open Hammerspoon and grant Accessibility permissions"
echo "  2. Set GEMINI_API_KEY in your shell profile (optional but recommended)"
echo "  3. Edit ~/.hammerspoon/dictate-config.json with your context"
echo "  4. Press Ctrl+D anywhere to start dictating!"
