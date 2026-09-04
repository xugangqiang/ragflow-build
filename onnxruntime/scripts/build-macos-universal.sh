#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build onnxruntime twice (arm64 + x86_64) and merge every static library with
# lipo into a single universal set.
#
# Both the onnxruntime component libs and the third party deps (abseil, onnx,
# protobuf, re2 ...) are merged, otherwise the x86_64 slice would link against
# arm64 objects.
#
# Usage: build-macos-universal.sh <ort-src> <build-dir> <python> [ort args...]
# -----------------------------------------------------------------------------
set -euo pipefail

ORT_SRC="$1"; BUILD_DIR="$2"; PYTHON="$3"; shift 3
ORT_ARGS=("$@")

command -v lipo >/dev/null 2>&1 || { echo "error: lipo not found, run this on macOS" >&2; exit 1; }

for arch in arm64 x86_64; do
    echo "==> building slice: $arch"
    mkdir -p "$BUILD_DIR/$arch"
    ( cd "$ORT_SRC" && "$PYTHON" "$ORT_SRC/tools/ci_build/build.py" \
        --build_dir "$BUILD_DIR/$arch" --osx_arch "$arch" "${ORT_ARGS[@]}" )
done

UNIVERSAL_DIR="$BUILD_DIR/universal"
rm -rf "$UNIVERSAL_DIR"
mkdir -p "$UNIVERSAL_DIR"

# while-read instead of mapfile: bash 3.2 on macOS has no mapfile
REL_LIBS=()
while IFS= read -r rel_lib; do
    [ -n "$rel_lib" ] && REL_LIBS+=("$rel_lib")
done < <(cd "$BUILD_DIR/arm64" && find . -type f -name '*.a' \
    -not -path '*/CMakeFiles/*' | sort)

if [ ${#REL_LIBS[@]} -eq 0 ]; then
    echo "error: no static libraries found in $BUILD_DIR/arm64" >&2
    exit 1
fi

echo "==> merging ${#REL_LIBS[@]} libraries with lipo"
merged=0
for rel in "${REL_LIBS[@]}"; do
    arm_lib="$BUILD_DIR/arm64/$rel"
    x86_lib="$BUILD_DIR/x86_64/$rel"
    out_lib="$UNIVERSAL_DIR/$rel"
    if [ ! -f "$x86_lib" ]; then
        echo "warning: $rel missing from the x86_64 slice, copying arm64 only" >&2
        mkdir -p "$(dirname "$out_lib")"
        cp -f "$arm_lib" "$out_lib"
        continue
    fi
    # already universal (some deps are built without CMAKE_OSX_ARCHITECTURES)
    if [ "$(lipo -archs "$arm_lib" 2>/dev/null | wc -w | tr -d ' ')" -ge 2 ]; then
        mkdir -p "$(dirname "$out_lib")"
        cp -f "$arm_lib" "$out_lib"
        continue
    fi
    mkdir -p "$(dirname "$out_lib")"
    lipo -create "$arm_lib" "$x86_lib" -output "$out_lib"
    merged=$((merged + 1))
done

echo "==> universal libraries in $UNIVERSAL_DIR (lipo merged: $merged)"
