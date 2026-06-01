#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
VENDOR_DIR="$ROOT_DIR/iOS/Vendor"
SRC_DIR="$VENDOR_DIR/hev-socks5-tunnel-src"
OUT="$VENDOR_DIR/HevSocks5Tunnel.xcframework"

mkdir -p "$VENDOR_DIR"
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --recursive https://github.com/heiher/hev-socks5-tunnel "$SRC_DIR"
fi

cd "$SRC_DIR"
git submodule update --init --recursive
./build-apple.sh

rm -rf "$OUT"
cp -R HevSocks5Tunnel.xcframework "$OUT"
echo "Wrote $OUT"
