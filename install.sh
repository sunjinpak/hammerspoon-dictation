#!/bin/bash
set -e

echo "=== Hammerspoon Dictation Installer ==="
echo ""

# ---- Parse args ----
VERSION="v3"
for arg in "$@"; do
    case "$arg" in
        --version=v1|-v1) VERSION="v1" ;;
        --version=v2|-v2) VERSION="v2" ;;
        --version=v3|-v3) VERSION="v3" ;;
        -h|--help)
            echo "Usage: ./install.sh [--version=v1|--version=v3]"
            echo "  v3 (default) : macOS 26 Speech framework. Offline, ~0.35s, no model file."
            echo "  v1           : single whisper pass. macOS 12+, needs a ~1.5 GB model."
            echo "  v2           : deprecated 3-way ensemble. Slower and does not work; see README."
            exit 0
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$SCRIPT_DIR/$VERSION" ]; then
    echo "Error: version folder '$VERSION' not found."
    exit 1
fi

if [ "$VERSION" = "v2" ]; then
    echo "WARNING: v2 is deprecated. Its 3-way ensemble is ~5x slower than a single"
    echo "pass and does not actually improve code-switching. See README. Use v3 or v1."
    echo ""
fi

echo "Installing pipeline version: $VERSION"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: This tool only works on macOS."
    exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$VERSION" = "v3" ] && [ "$MACOS_MAJOR" -lt 26 ]; then
    echo "Error: v3 needs macOS 26 or later (found $(sw_vers -productVersion))."
    echo "       Run './install.sh --version=v1' instead."
    exit 1
fi

# Check Homebrew
if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew is required. Install from https://brew.sh"
    exit 1
fi

# ---- Dependencies ----
echo "[1/4] Installing dependencies..."
brew install sox 2>/dev/null || true

if [ "$VERSION" != "v3" ]; then
    brew install whisper-cpp 2>/dev/null || true
fi

if [ ! -d "/Applications/Hammerspoon.app" ]; then
    echo "  -> Installing Hammerspoon..."
    brew install --cask hammerspoon 2>/dev/null || true
fi

# ---- Transcription backend ----
HS_DIR="$HOME/.hammerspoon"
mkdir -p "$HS_DIR"

if [ "$VERSION" = "v3" ]; then
    echo "[2/4] Building mac-stt (Swift, macOS Speech framework)..."
    if ! command -v swiftc &>/dev/null; then
        echo "Error: swiftc not found. Install the Xcode Command Line Tools:"
        echo "       xcode-select --install"
        exit 1
    fi
    swiftc -O "$SCRIPT_DIR/v3/mac-stt.swift" -o "$HS_DIR/mac-stt"
    echo "  -> Built $HS_DIR/mac-stt (no model download needed)"
else
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
fi

# ---- Config files ----
echo "[3/4] Setting up Hammerspoon config ($VERSION)..."

# Back up an existing init.lua unless it is already ours
if [ -f "$HS_DIR/init.lua" ]; then
    if ! grep -q "Hammerspoon Dictation" "$HS_DIR/init.lua" 2>/dev/null; then
        echo "  -> Backing up existing init.lua to init.lua.backup"
        cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.backup"
    fi
fi

# v3 ships its own init.lua (ESC cancel, watchdog, clipboard preservation);
# v1/v2 use the shared one at the repo root.
if [ -f "$SCRIPT_DIR/$VERSION/init.lua" ]; then
    cp "$SCRIPT_DIR/$VERSION/init.lua" "$HS_DIR/init.lua"
else
    cp "$SCRIPT_DIR/init.lua" "$HS_DIR/init.lua"
fi

cp "$SCRIPT_DIR/$VERSION/dictate.sh" "$HS_DIR/dictate.sh"
chmod +x "$HS_DIR/dictate.sh"

if [ -f "$SCRIPT_DIR/$VERSION/dictate-fix.py" ]; then
    cp "$SCRIPT_DIR/$VERSION/dictate-fix.py" "$HS_DIR/dictate-fix.py"
fi

# Personal-context config is only used by the v1/v2 Gemini correction step.
if [ "$VERSION" != "v3" ]; then
    if [ ! -f "$HS_DIR/dictate-config.json" ]; then
        cp "$SCRIPT_DIR/config.example.json" "$HS_DIR/dictate-config.json"
        echo "  -> Created dictate-config.json (edit with your personal context)"
    else
        echo "  -> dictate-config.json already exists, skipping."
    fi
fi

# ---- Environment ----
echo ""
echo "[4/4] Checking environment..."

if [ "$VERSION" = "v3" ]; then
    echo "  -> v3 needs no API key and makes no network calls."
    echo "  -> Default locale is ko-KR. To change it:"
    echo "       launchctl setenv DICTATE_LOCALE en-US"
    echo "     (Hammerspoon does not read your shell profile, so 'export' will not work.)"
elif [ -z "$GEMINI_API_KEY" ]; then
    echo ""
    echo "  GEMINI_API_KEY not set. For the $VERSION correction step, set it with:"
    echo ""
    echo "    launchctl setenv GEMINI_API_KEY \"your-api-key-here\""
    echo ""
    echo "  Get a free key at: https://aistudio.google.com/apikey"
    echo "  Without it, dictation still works but skips LLM correction."
    echo ""
    echo "  NOTE: exporting it in ~/.zshrc is NOT enough. Hammerspoon runs scripts"
    echo "  without reading your shell profile, so the key would be invisible and"
    echo "  the correction step would silently do nothing."
fi

echo ""
echo "=== Installation complete ($VERSION)! ==="
echo ""
echo "Switch versions later:  ./install.sh --version=v1   (or v3)"
echo ""
echo "Next steps:"
echo "  1. Open Hammerspoon and grant Accessibility AND Microphone permissions"
echo "  2. Reload Hammerspoon (Cmd+Alt+Ctrl+R, or use the menu bar icon)"
echo "  3. Press Ctrl+D anywhere to start dictating (Ctrl+D again to stop, ESC to cancel)"
