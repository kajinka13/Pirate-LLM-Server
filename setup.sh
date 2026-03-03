#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/Vendor"
LLAMA_DIR="$VENDOR_DIR/llama.cpp"
PACKAGE_DIR="$SCRIPT_DIR/Packages/LlamaLocal"

echo "============================================"
echo "  LLM Server - Setup"
echo "============================================"
echo ""

# 1. Check prerequisites
echo "[1/3] Checking prerequisites..."

if ! command -v cmake &>/dev/null; then
    echo ""
    echo "ERRORE: cmake non trovato."
    echo "Installalo con:  brew install cmake"
    echo ""
    exit 1
fi

echo "  cmake: $(cmake --version | head -1)"
echo "  xcode: $(xcodebuild -version 2>/dev/null | head -1)"
echo ""

# 2. Clone llama.cpp
echo "[2/3] Preparing llama.cpp..."

if [ -d "$LLAMA_DIR" ]; then
    echo "  Gia' clonato."
else
    echo "  Cloning llama.cpp..."
    mkdir -p "$VENDOR_DIR"
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
fi
echo ""

# 3. Build xcframework (iOS only)
echo "[3/3] Building llama.xcframework..."

XCFW="$LLAMA_DIR/build-apple/llama.xcframework"

if [ -d "$XCFW" ]; then
    echo "  XCFramework gia' presente. Per ricompilare: rm -rf Vendor/llama.cpp/build-apple"
else
    "$SCRIPT_DIR/build-llama.sh"
fi

# Link xcframework to local package
mkdir -p "$PACKAGE_DIR"
rm -rf "$PACKAGE_DIR/llama.xcframework"
ln -s "$XCFW" "$PACKAGE_DIR/llama.xcframework"

echo ""
echo "============================================"
echo "  Setup completato!"
echo "============================================"
echo ""
echo "Prossimi passi:"
echo "  1. open LLMServer.xcodeproj"
echo "  2. Imposta il tuo Team in Signing & Capabilities"
echo "  3. Seleziona il tuo iPhone come target"
echo "  4. Cmd+R per compilare e installare"
echo ""
