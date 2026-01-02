#!/usr/bin/env bash
set -euo pipefail

# GDMacro Build Script for iOS
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT="$SCRIPT_DIR"
OUT_DIR="$PROJECT_ROOT/build"
DYLIB_NAME="GDMacro.dylib"
SWIFT_SRC="$PROJECT_ROOT/GDMacro.swift"
FISHHOOK_C="$PROJECT_ROOT/fishhook.c"

mkdir -p "$OUT_DIR"

echo "[build] === Building GDMacro for iOS arm64 ==="
echo ""

# Check if fishhook exists
if [ ! -f "$FISHHOOK_C" ]; then
    echo "[build] Downloading fishhook..."
    curl -o "$PROJECT_ROOT/fishhook.c" https://raw.githubusercontent.com/facebook/fishhook/main/fishhook.c
    curl -o "$PROJECT_ROOT/fishhook.h" https://raw.githubusercontent.com/facebook/fishhook/main/fishhook.h
fi

# Compile fishhook
echo "[build] Compiling fishhook..."
xcrun -sdk iphoneos clang \
  -c \
  -arch arm64 \
  -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
  -miphoneos-version-min=14.0 \
  -o "$OUT_DIR/fishhook.o" \
  "$FISHHOOK_C"

if [ $? -ne 0 ]; then
    echo "[build] ✗ Failed to compile fishhook"
    exit 1
fi

# Create bridging header
cat > "$PROJECT_ROOT/GDMacro-Bridging-Header.h" << 'EOF'
#ifndef GDMacro_Bridging_Header_h
#define GDMacro_Bridging_Header_h

#import "fishhook.h"

#endif
EOF

# Compile Swift + link fishhook
echo "[build] Compiling Swift and linking..."
xcrun -sdk iphoneos swiftc \
  -emit-library \
  -target arm64-apple-ios14.0 \
  -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
  -O \
  -import-objc-header "$PROJECT_ROOT/GDMacro-Bridging-Header.h" \
  -Xlinker -rpath -Xlinker @executable_path \
  -o "$OUT_DIR/$DYLIB_NAME" \
  "$SWIFT_SRC" \
  "$OUT_DIR/fishhook.o"

if [ $? -ne 0 ]; then
    echo "[build] ✗ Failed to compile Swift"
    exit 1
fi

# Code sign (if possible)
if command -v codesign &> /dev/null; then
    echo "[build] Code signing..."
    codesign -f -s - "$OUT_DIR/$DYLIB_NAME" 2>/dev/null || echo "[build] ⚠️  Code signing failed (this is normal without a dev cert)"
fi

echo ""
echo "[build] ✓ Successfully built: $OUT_DIR/$DYLIB_NAME"
echo ""
echo "Next steps:"
echo "1. Copy $OUT_DIR/$DYLIB_NAME to your iOS device"
echo "2. Create directory: Documents/Flero/flero/replays/"
echo "3. Add your .gdr2 replay files to that directory"
echo "4. Inject using one of these methods:"
echo "   - insert_dylib for pre-patching the IPA"
echo "   - CydiaSubstrate for runtime injection"
echo "   - TrollStore/Sideloadly for sideloading"
echo ""
echo "File info:"
ls -lh "$OUT_DIR/$DYLIB_NAME"
