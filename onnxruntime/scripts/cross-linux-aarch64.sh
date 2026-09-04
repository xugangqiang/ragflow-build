#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Cross compile onnxruntime for linux-aarch64 from an x86_64 host using the
# distro provided aarch64 toolchain.
#
# Prefer running natively on an aarch64 machine/runner; this path exists for
# setups where no aarch64 runner is available.
#
# Usage: cross-linux-aarch64.sh <ort-src> <build-dir> <python> [ort args...]
# -----------------------------------------------------------------------------
set -euo pipefail

ORT_SRC="$1"; BUILD_DIR="$2"; PYTHON="$3"; shift 3
ORT_ARGS=("$@")

TRIPLE="aarch64-linux-gnu"
CC_BIN="${CC:-$TRIPLE-gcc}"
CXX_BIN="${CXX:-$TRIPLE-g++}"

if ! command -v "$CXX_BIN" >/dev/null 2>&1; then
    echo "==> installing cross toolchain $TRIPLE"
    if command -v apt-get >/dev/null 2>&1; then
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            sudo apt-get update -y
            sudo apt-get install -y crossbuild-essential-arm64
        else
            apt-get update -y
            apt-get install -y crossbuild-essential-arm64
        fi
    else
        echo "error: $CXX_BIN not found and no apt-get available to install it" >&2
        exit 1
    fi
fi

command -v "$CXX_BIN" >/dev/null 2>&1 || { echo "error: $CXX_BIN still missing" >&2; exit 1; }

CROSS_DEFINES=(
    "CMAKE_SYSTEM_NAME=Linux"
    "CMAKE_SYSTEM_PROCESSOR=aarch64"
    "CMAKE_C_COMPILER=$CC_BIN"
    "CMAKE_CXX_COMPILER=$CXX_BIN"
)

FULL_ARGS=()
for def in "${CROSS_DEFINES[@]}"; do
    FULL_ARGS+=(--cmake_extra_defines "$def")
done
FULL_ARGS+=("${ORT_ARGS[@]}")

mkdir -p "$BUILD_DIR"
( cd "$ORT_SRC" && "$PYTHON" "$ORT_SRC/tools/ci_build/build.py" --build_dir "$BUILD_DIR" "${FULL_ARGS[@]}" )
